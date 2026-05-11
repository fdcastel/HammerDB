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
| TPROC-H schema        | ✅ Complete (8 tables + named PK constraints)       |
| TPROC-H queries       | ✅ All 22 queries adapted to Firebird SQL dialect   |
| TPROC-H bulk loader   | ❌ Not implemented (dbgen-style data generation)    |
| TPROC-H driver        | ❌ Not implemented                                  |
| GUI options dialog    | ❌ Stub only (`setlocalfb*vars` helpers exist)      |
| Transaction counter   | ❌ Stub `tcount_fb` (no `MON$STATEMENTS` polling)   |
| MVCC retry helper     | ❌ Not implemented                                  |
| CI on Windows         | ✅ 10 verification steps green per push             |
| CI on Linux (Docker)  | ✅ Image builds + inspects on `ubuntu-latest`       |
| End-to-end via real `hammerdbcli` | ⏯️ Blocked: the Windows release ships as a self-contained `.exe` with the source bundled in zipfs; needs a Bawt rebuild to test our additions |

## Architectural choices

### Embedded by default

`config/firebird.xml` ships with `fb_embedded=true`. HammerDB loads
`fbclient.dll` / `libfbclient.so` and opens the `.fdb` directly,
without contacting a Firebird server daemon. No `FIREBIRD_ROOT_PASSWORD`
or service start is needed.

The CI pipeline uses [PSFirebird](https://github.com/fdcastel/PSFirebird)
to download the Firebird 5.0.x binaries on demand; users who already
have Firebird installed can point `fb_dbase` at their existing path.

For server-mode (remote `.fdb`), set `fb_embedded=false` and provide
`fb_host` + `fb_port`.

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
Driver={Firebird ODBC Driver};Dbname=<absolute-path>;Client=fbclient.dll;User=SYSDBA;
```

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

## File layout

| File           | Purpose                                                      |
| -------------- | ------------------------------------------------------------ |
| `fboltp.tcl`   | TPROC-C: schema DDL, bulk loader, 5 client-side driver procs, stored-proc DDL strings, `ConnectToFirebird` helper |
| `fbolap.tcl`   | TPROC-H: schema DDL, the 22 queries (`fb_tpch_queries`)      |
| `fbopt.tcl`    | Options helpers (`setlocalfbtpccvars`, `setlocalfbtpchvars`); GUI dialog stub |
| `fbotc.tcl`    | Transaction counter stub (`tcount_fb`); GUI dispatch only    |
| `fbci.tcl`     | CI hook stub (mirrors MSSQL pattern)                         |
| `fbmet.tcl`    | Database-metrics stub (mirrors MSSQL pattern)                |

Per-DB CLI entry points live in [`scripts/tcl/firebird/{tprocc,tproch}/`](../../scripts/tcl/firebird/)
(Tcl) and [`scripts/python/firebird/{tprocc,tproch}/`](../../scripts/python/firebird/)
(Python). They follow the same shape as the existing `pg_*` scripts.

## Deferred items

Tracked individually in `tmp/THE_PLAN.md`, summarised here:

* **Full GUI options dialog** (C1 in the plan). The `setlocalfbtpccvars` /
  `setlocalfbtpchvars` helpers are wired up so `fboltp.tcl` /
  `fbolap.tcl` can read settings from `configfirebird`, but the
  Tk-based connection / TPROC-C / TPROC-H tabs (mirroring
  `src/postgresql/pgopt.tcl`) are not built yet.
* **MVCC retry helper** (C8). The client-side driver procs catch and
  re-raise on conflict, but a transparent retry loop matching the
  pattern in `pgoltp.tcl` is not in place.
* **TPROC-H bulk loader + driver** (C10/C11). The 8-table schema is
  in and the 22 queries are in `fb_tpch_queries`, but the dbgen-style
  data loader and the per-stream driver are not implemented.
* **Real `tcount_fb`** (C12). The current proc is a stub. A real
  implementation would poll `MON$STATEMENTS` from a background thread
  to feed the GUI's TPM/NOPM display.
* **`hammerdbcli` end-to-end on CI** (Phase G in the plan). Permanently
  blocked unless the upstream Windows `.exe` is rebuilt with our
  Firebird files (the binary uses Tcl `zipfs` to bundle src/, modules/
  etc., so on-disk overlays are ignored). The standalone tdbc::odbc
  CI verifications cover the same code paths.
* **Linux smoke run inside the Docker image** (F4 second-half). The
  `ubuntu-latest` job builds the image and inspects the installed
  files, but does not run the full smoke against a `.fdb` inside the
  container yet.

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

Each subsequent CI script (`fb_register.tcl`, `fb_modules.tcl`,
`fb_schema.tcl`, `fb_load1w.tcl`, `fb_runtxn.tcl`, `fb_tpch_schema.tcl`,
`fb_tpch_queries.tcl`, `fb_storedprocs.tcl`) follows the same env-var
contract.
