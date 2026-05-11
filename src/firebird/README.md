# HammerDB — Firebird database driver

This directory implements HammerDB support for [Firebird](https://firebirdsql.org/),
the open-source relational database descended from InterBase.

## Status

| Aspect                | Status                                              |
| --------------------- | --------------------------------------------------- |
| TPROC-C schema        | ✅ Complete (9 tables + 2 secondary indexes)        |
| TPROC-C bulk loader   | ✅ Complete (batched INSERTs, no COPY in Firebird)  |
| TPROC-C client-side   | ✅ All 5 transactions (NewOrder/Payment/Delivery/   |
|                       |    OrderStatus/StockLevel)                          |
| TPROC-C stored procs  | ✅ All 5 PSQL procs (PAYMENT_SP/OSTAT_SP/SLEV_SP/   |
|                       |    DELIVERY_SP/NEWORD_SP)                           |
| MVCC retry helper     | ✅ `fb_with_retry` wraps all 5 client-side procs    |
| TPROC-H schema        | ✅ Complete (8 tables + named PK constraints)       |
| TPROC-H queries       | ✅ All 22 queries adapted to Firebird SQL dialect   |
| TPROC-H bulk loader   | ✅ Complete (8 tables, scale-parameterised)         |
| TPROC-H power test    | ✅ RF1 + 22 queries + RF2 with geometric mean       |
| TPROC-H throughput    | ✅ Multi-VU streams + parallel refresh (server mode)|
| CI on Windows         | ✅ 12 verification steps + bundled JSON artifact    |
| CI on Linux (Docker)  | ✅ Image builds + inspects on `ubuntu-latest`       |
| GUI options dialog    | ❌ Stub only (`setlocalfb*vars` helpers exist)      |
| Transaction counter   | ❌ Stub `tcount_fb` (no `MON$STATEMENTS` polling)   |
| End-to-end via real `hammerdbcli` | ⏯️ Blocked: the Windows release ships as a self-contained `.exe` with the source bundled in zipfs; needs a Bawt rebuild to test our additions |

## Architectural choices

### Embedded by default — server mode for multi-VU

`config/firebird.xml` ships with `fb_embedded=true`. HammerDB loads
`fbclient.dll` / `libfbclient.so` and opens the `.fdb` directly,
without contacting a Firebird server daemon. No `FIREBIRD_ROOT_PASSWORD`
or service start is needed.

**Firebird Embedded is single-process** — only one OS process can hold
a given `.fdb` open at a time. The TPC-H multi-VU throughput test
therefore switches to **server mode**: the CI workflow uses
[PSFirebird](https://github.com/fdcastel/PSFirebird)'s
`Start-FirebirdInstance` to launch a Firebird server on port 3050,
then every Tcl thread opens its own `inet://localhost:3050/...`
connection.

The modern Firebird SRP security database ships empty and `CREATE
USER SYSDBA` from an embedded session fails (no privilege to create
`PLG$SRP`). For server mode the workflow enables `Legacy_Auth` in
`firebird.conf` via PSFirebird's `Write-FirebirdConfiguration`,
which has SYSDBA/masterkey baked in.

For server-mode setups outside CI, set `fb_embedded=false` and
provide `fb_host` + `fb_port` in `config/firebird.xml`.

### tdbc::odbc + the Firebird ODBC driver

The driver uses [tdbc::odbc](https://www.tcl-lang.org/man/tcl/TdbcodbcCmd/contents.htm)
(the same Tcl ODBC binding HammerDB already uses for SQL Server),
talking to the official [Firebird ODBC driver](https://github.com/FirebirdSQL/firebird-odbc-driver).
This avoids writing a new TDBC driver wrapping `fbclient`.

The ODBC driver is registered as the literal name **`Firebird ODBC Driver`**
(matches both the Windows `choco install firebird-odbc` registration
and our Linux Dockerfile entry in `/etc/odbcinst.ini`). The connection
string template, baked into `fb_build_connstr`:

```
Driver={Firebird ODBC Driver};Dbname=<absolute-path>;Client=<fbclient-lib>;User=SYSDBA;
```

`Client=` is dlopen'd by the ODBC driver, so the file name is
platform-specific. `fb_default_client_lib` in `fboltp.tcl` picks
`fbclient.dll` on Windows and `libfbclient.so.2` elsewhere (matches
the Firebird 3 client package the Docker image installs). Set the
`FB_CLIENT_LIB` env var to override — e.g. `libfbclient.so.5` if
linking against a Firebird 5 client on Linux.

> **Linux SQL coverage caveat.** The CI matrix exercises the full
> SQL/PSQL paths only on Windows. The official Firebird ODBC driver
> (libOdbcFb.so, both v3-0-1-release and v3.5.0-rc1) returns garbage
> native error codes and empty SQLSTATEs on any `SQLDriverConnect`
> from `tdbc::odbc`, regardless of embedded vs server mode, even
> when `isql` against the same `.fdb` succeeds. Linux CI verifies
> the image builds and the binaries load (`Docker/firebird/`), but
> does not exercise SQL round-trips through the driver.

`fb_build_connstr` also emits the server-mode form
`Dbname=<host>/<port>:<path>;User=SYSDBA;Password=<pw>;` when
`fb_embedded=false`.

### Two parameter conventions

tdbc::odbc treats `:NAME` as a bind parameter placeholder and rewrites
the SQL before sending. This is great for INSERT/UPDATE/SELECT, but it
clashes with Firebird **PSQL** where `:NAME` references a procedure
parameter or local variable inside the procedure body — tdbc's
prepare-time scanner mis-treats those as binds and fails.

The split:

* **DSQL** (INSERT/UPDATE/SELECT, including `SELECT FROM <proc>(:p)`):
  go through `tdbc::odbc` `prepare` + `execute`, with `:NAME` binds and
  a dict of values. The bulk loader and the 5 client-side TPC-C
  transactions all use this path.
* **DDL containing PSQL** (CREATE OR ALTER PROCEDURE bodies that
  reference `:NAME`): submit via `isql` (we use PSFirebird's
  `Invoke-FirebirdIsql`) with `SET TERM ^ ;` wrapping. The 5 stored
  procedures land this way; once installed, they are invoked from
  Tcl via `SELECT FROM <PROC>(:params)` (selectable procedures, all
  use `SUSPEND`).

### S_DIST_NN without dynamic SQL

TPC-C's NewOrder reads one of `S_DIST_01` … `S_DIST_10` depending on
the district id. Postgres uses arrays + UNNEST; MSSQL uses dynamic
SQL. Firebird PSQL has neither in a friendly form, so `NEWORD_SP`
picks the column with a 10-branch `CASE` expression:

```sql
SELECT S_QUANTITY,
       CASE :P_D_ID
           WHEN 1 THEN S_DIST_01
           WHEN 2 THEN S_DIST_02
           ...
           ELSE S_DIST_10
       END
  FROM STOCK
 WHERE S_W_ID = :W AND S_I_ID = :I
  INTO :S_QTY, :S_DIST;
```

### MVCC retry

All 5 client-side TPC-C driver procs wrap their transaction body in
a 3-attempt retry loop with 5-40 ms randomised back-off. `fb_with_retry`
in `fboltp.tcl` catches Firebird's update-conflict markers
(`deadlock`, `lock conflict`, `update conflict`, `concurrent update`,
SQLSTATE `40001`, `isc_update_conflict`) and retries; anything else
propagates. Delivery does per-district retry so a transient conflict
on one district doesn't abort the rest.

## File layout

| File           | Purpose                                                      |
| -------------- | ------------------------------------------------------------ |
| `fboltp.tcl`   | TPROC-C: schema DDL, bulk loader, 5 client-side driver procs, stored-proc DDL strings, `ConnectToFirebird` helper, `fb_with_retry` |
| `fbolap.tcl`   | TPROC-H: schema DDL, bulk loader (8 tables), 22 queries (`fb_tpch_queries`), `fb_tpch_sub_query`, `fb_tpch_rf1`/`fb_tpch_rf2`, `fb_tpch_power_test`, `fb_tpch_query_stream`/`fb_tpch_refresh_loop` (for multi-VU throughput) |
| `fbopt.tcl`    | Options helpers (`setlocalfbtpccvars`, `setlocalfbtpchvars`); GUI dialog stub |
| `fbotc.tcl`    | Transaction counter stub (`tcount_fb`); GUI dispatch only    |
| `fbci.tcl`     | CI hook stub (mirrors MSSQL pattern)                         |
| `fbmet.tcl`    | Database-metrics stub (mirrors MSSQL pattern)                |

Per-DB CLI entry points live in [`scripts/tcl/firebird/{tprocc,tproch}/`](../../scripts/tcl/firebird/)
(Tcl) and [`scripts/python/firebird/{tprocc,tproch}/`](../../scripts/python/firebird/)
(Python). They follow the same shape as the existing `pg_*` scripts.

## CI benchmark results

Every push runs the full benchmark matrix on Windows + Linux Docker
build. Each instrumented step:

1. Logs human-readable output to the workflow log.
2. Appends a Markdown table to `$GITHUB_STEP_SUMMARY` so the run
   summary page shows headline numbers without log diving.
3. Writes a structured JSON file into a results dir; all JSONs are
   bundled as the `firebird-benchmark-results` workflow artifact.

The JSON files emitted per run:

| File                      | What it captures                              |
| ------------------------- | --------------------------------------------- |
| `tpcc-load-1w.json`       | Per-table row counts after the TPC-C load     |
| `tpcc-transactions.json`  | 200-txn mix, elapsed, tps, rollbacks          |
| `tpcc-stored-procs.json`  | Install + invocation status for the 5 procs   |
| `tpch-load.json`          | Per-table row counts for TPC-H load           |
| `tpch-power.json`         | Power-test gmean + RF1/RF2 timings + rows     |
| `tpch-throughput.json`    | Multi-VU streams, refresh pairs, qph metric   |

## Deferred items

* **Full GUI options dialog.** The `setlocalfbtpccvars` /
  `setlocalfbtpchvars` helpers are wired up so `fboltp.tcl` /
  `fbolap.tcl` can read settings from `configfirebird`, but the
  Tk-based connection / TPROC-C / TPROC-H tabs (mirroring
  `src/postgresql/pgopt.tcl`) are not built yet.
* **Real `tcount_fb`.** The current proc is a stub. A real
  implementation would poll `MON$STATEMENTS` from a background thread
  to feed the GUI's TPM/NOPM display.
* **`hammerdbcli` end-to-end on CI.** Permanently blocked unless the
  upstream Windows `.exe` is rebuilt with our Firebird files (the
  binary uses Tcl `zipfs` to bundle src/, modules/ etc., so on-disk
  overlays are ignored). The standalone tdbc::odbc CI verifications
  cover the same code paths.
* **Linux ODBC driver pin.** The Docker image pulls the Firebird
  ODBC driver from the unofficial `v3.5.1-rc1` build at
  [github.com/fdcastel/firebird-odbc-driver](https://github.com/fdcastel/firebird-odbc-driver/releases/tag/v3.5.1-rc1),
  which applies the fix for an unchecked C-style downcast in the
  `OdbcConnection::connect` catch block. The official releases
  (`v3-0-1-release` and `v3.5.0-rc1`) reinterpret-cast every caught
  `std::exception &` to `SQLException &`, so on Linux any path that
  raises a `Firebird::FbException` or `std::bad_alloc` lands in
  `SQLGetDiagRec` as empty SQLSTATE + non-deterministic native code
  + a one-character message — making the driver unusable behind
  `tdbc::odbc`. Once the fix lands in an upstream release, the
  `FB_ODBC_URL` ARG in `Docker/firebird/Dockerfile` should be moved
  back to `github.com/FirebirdSQL/firebird-odbc-driver`.

## Local testing

The CI workflow at [`.github/workflows/firebird.yml`](../../.github/workflows/firebird.yml)
runs on every push to `feature/firebird-**` and on PRs touching the
firebird files. To reproduce the Windows verifications locally:

```pwsh
# Provision Firebird 5.0.x Embedded
Install-Module PSFirebird
$env:FB = "$env:TEMP/fb"
New-FirebirdEnvironment -Version 5.0.3 -Path $env:FB
$env:Path = "$env:FB;$env:Path"
$env:FIREBIRD_ENVIRONMENT = $env:FB

# Install the ODBC driver
choco install firebird-odbc -y

# Smoke a connection
$env:FB_ODBC_DRIVER = "Firebird ODBC Driver"
$env:HAMMERDB_ROOT  = (Resolve-Path .).Path
$db = "$env:TEMP/fb/smoke.fdb"
New-FirebirdDatabase -Database $db -Force
$env:FB_DB_PATH = ($db -replace '\\','/')
tclsh .github/workflows/scripts/fb_smoke.tcl
```

Other CI scripts follow the same `HAMMERDB_ROOT` + `FB_ODBC_DRIVER` +
`FB_DB_PATH` env-var contract: `fb_register.tcl`, `fb_modules.tcl`,
`fb_retry.tcl`, `fb_schema.tcl`, `fb_load1w.tcl`, `fb_runtxn.tcl`,
`fb_storedprocs.tcl`, `fb_tpch_schema.tcl`, `fb_tpch_queries.tcl`,
`fb_tpch_load.tcl`, `fb_tpch_power.tcl`. The multi-VU
`fb_tpch_throughput.tcl` adds `FB_TPCH_SERVER_HOST`/`FB_TPCH_SERVER_PORT`
/`FB_TPCH_DBPATH` (server mode required).

Set `FB_RESULTS_OUT=<path-to-json>` on any instrumented script to
capture structured benchmark output the same way CI does.
