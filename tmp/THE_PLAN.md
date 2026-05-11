# THE_PLAN — Add Firebird Database Support to HammerDB

## How to use this document

This is a living tracker. **Update it every time work moves forward** — do not let it drift.

- **Each commit** that touches a task: edit that task's row to set `Status` and paste the **short** commit hash (`git log -1 --format=%h`) into the `Commit` column.
- **Starting a task:** flip its `Status` to 🔧 IN PROGRESS so parallel workers don't collide.
- **Blocked by another task:** flip to ⏯️ DEFERRED and add a `blocked-by:` note in `Notes / Files`.
- **Discovering new work:** add a new row at the end of the relevant phase rather than rewriting existing IDs (IDs are stable references in commit messages and PR descriptions).
- **At the end of every working session:** re-read this file top-to-bottom, fix stale statuses, and commit the doc update with message `docs(plan): update Firebird plan status`.
- **PR convention:** include the task ID(s) in the PR title (e.g. `Firebird C5/C6: TPROC-C schema build`) so the `Commit` column is easy to populate from `git log --grep`.

### Status legend

| Symbol | Meaning |
| --- | --- |
| ✅ DONE | Implemented, reviewed, and tested |
| 🔧 IN PROGRESS | Partially implemented or actively underway |
| ❌ OPEN | Not yet addressed |
| ⏯️ DEFERRED | Delayed or on hold (note the blocker in `Notes / Files`) |

### TPC-H multi-VU throughput test (C11 follow-up)

| # | Status | Commit | Task | Notes / Files |
|---|---|---|---|---|
| C11b | ✅ DONE | 2b931fd | Multi-VU throughput test (server mode) | `fb_tpch_query_stream` + `fb_tpch_refresh_loop` workers in fbolap.tcl. CI orchestrator `fb_tpch_throughput.tcl` spawns N Tcl threads via `Thread`, each connects via `inet://localhost:3050` (Firebird Embedded is single-process). Workflow step starts a Firebird server via `Start-FirebirdInstance` after writing `AuthServer = Legacy_Auth, Srp` + `WireCrypt = Disabled` to `firebird.conf` (the SRP security DB ships empty and CREATE USER from embedded mode hits a privilege wall on PLG$SRP; Legacy_Auth has SYSDBA/masterkey hardcoded). Results: 2 streams, scale 0.01, 162s elapsed, **298 RF1+RF2 refresh pairs completed in parallel**, 911 queries/hour, per-stream gmean 116ms / 175ms. JSON written to `$RUNNER_TEMP/tpch-throughput.json`, uploaded as `tpch-throughput-results` workflow artifact, and Markdown summary appended to `$GITHUB_STEP_SUMMARY` for the run page. |

### Locked decisions (do not relitigate without updating this header)

- **Tcl driver:** `tdbc::odbc` against the official Firebird ODBC driver. No new C extension. Mirror MSSQL's pattern in `src/mssqls/`.
- **Workloads:** TPROC-C **and** TPROC-H from day one.
- **TPC-C transaction implementation:** PSQL stored procedures by default, client-side prepared-statement fallback. Toggle via `fb_storedprocs` (mirrors PostgreSQL's `pg_storedprocs`).
- **Database prefix:** `fb` (e.g. `fboltp.tcl`, `fb_tprocc_run.tcl`, `fb_count_ware`).
- **Target Firebird version:** 5.0.x (current stable, ODS 13.1).
- **Extras in scope:** Python mirror scripts; CI pipeline + Docker. **Out of scope:** metrics module (`fbmet.tcl`) — see Phase H.
- **Execution policy (project-wide):** No local runs. Every command — schema build, workload run, Docker build, GUI smoke check, parity comparison — executes on a GitHub Actions runner via the workflow scaffolded in A1. Local checkouts are for editing only.

---

## Phase A — Driver prerequisites (GitHub Actions only)

> **Execution policy:** No local runs. Every command in every phase must execute on a GitHub Actions runner. Local machines are for editing and reading code only. Phases F (Docker), G (smoke validation), and the per-task smoke checks in C/D/E all inherit this constraint and run via the workflow scaffolded in A1.
>
> **Firebird mode:** Use Firebird **Embedded** — no service install, no listener, no SYSDBA password to manage. The benchmark process loads `fbclient.dll` / `libfbclient.so` and opens the database file directly.
>
> **Tooling:** [PSFirebird](https://github.com/fdcastel/PSFirebird) (`Install-Module PSFirebird` from the PowerShell Gallery, requires PS 7.4+) provisions the Firebird binaries via `New-FirebirdEnvironment`. The Firebird ODBC driver comes from Chocolatey (`choco install firebird-odbc -y`); confirmed registered as `Firebird ODBC Driver` (no slashes/brackets — the legacy `Firebird/InterBase(r) driver` name is **not** what choco installs). Tcl/Tk for the smoke step is `choco install magicsplat-tcl-tk -y` (bundles `tdbc::odbc`).

| # | Status | Commit | Task | Notes / Files |
|---|---|---|---|---|
| A1 | ✅ DONE | 6f2d267 | Add `.github/workflows/firebird.yml` with a `windows-latest` job and the standard "checkout + setup-tcl + run script" steps | Triggers: `workflow_dispatch` + `pull_request` paths-filtered + `push` to `feature/firebird-**`. Uses `pwsh`, `GITHUB_TOKEN` exported. |
| A2 | ✅ DONE | 4657549 | In the workflow, install PSFirebird and provision Firebird 5.0.x Embedded into the runner workspace | `Install-Module PSFirebird` then `New-FirebirdEnvironment -Version 5.0.3 -Path $env:RUNNER_TEMP\firebird`. Exports `FIREBIRD_ENVIRONMENT` so `[FirebirdEnvironment]::default()` resolves in later steps; appends to `$GITHUB_PATH` so `fbclient.dll` is loadable. |
| A3 | ✅ DONE | 4657549 | In the workflow, install the Firebird ODBC driver via Chocolatey | `choco install firebird-odbc -y --no-progress`. Driver registers as **`Firebird ODBC Driver`** (no slashes/brackets — note the legacy name `Firebird/InterBase(r) driver` is **not** what choco installs). Captured into `FIREBIRD_ODBC_DRIVER`. |
| A4 | ✅ DONE | 2fa6501 | Workflow step: create a scratch embedded database with `New-FirebirdDatabase` and run a `tdbc::odbc` smoke query | `New-FirebirdDatabase -Database $fbDb -Force` then run `.github/workflows/scripts/fb_smoke.tcl` via Magicsplat tclsh. Reads first column by position because Firebird upper-cases unquoted identifiers (`ONE` not `one`). |
| A5 | ✅ DONE | 1664f5d | Document the canonical embedded-mode ODBC connection-string template that `fboltp.tcl`, `fbolap.tcl`, `fbotc.tcl` will use | Confirmed string: `Driver={Firebird ODBC Driver};Dbname=<abs-path-fwd-slashes>;Client=fbclient.dll;User=SYSDBA;`. Documented as comment block in `.github/workflows/firebird.yml`; to be repasted verbatim into `fboltp.tcl` header in Phase C. `config/firebird.xml` (B2) treats `fb_host`/`fb_port` as ignored for embedded mode. |
| A6 | ⏯️ DEFERRED |  | Cache the PSFirebird-downloaded Firebird binaries between workflow runs | `actions/cache@v4` keyed on `firebird-5.0.3-${{ runner.os }}`. Halves the cold-start time of every CI run. **Deferred until A1–A5 are confirmed green** — no point caching a broken pipeline. Revisit after Phase G if CI cold-start time bites. |

## Phase B — Registration & defaults

| # | Status | Commit | Task | Notes / Files |
|---|---|---|---|---|
| B1 | ✅ DONE | 56a02d3 | Add `<firebird>` block to [config/database.xml](config/database.xml) | name=Firebird, prefix=fb, library=tdbc::odbc 1.1.1, workloads=TPROC-C TPROC-H, commands list mirrors MSSQL. |
| B2 | ✅ DONE | 56a02d3 | Create [config/firebird.xml](config/firebird.xml) with `<connection>`, `<tpcc>`, and `<tpch>` blocks | Modelled on postgresql.xml. Connection block adds `fb_odbc_driver` (default `Firebird ODBC Driver`) and `fb_embedded` (default `true`). |
| B3 | ✅ DONE | 30f2329 | Confirm GUI/CLI auto-discovery picks up Firebird without bootstrap edits | `.github/workflows/scripts/fb_register.tcl` runs in CI, loads both XMLs via `::XML::To_Dict` (same parser as `geninit.tcl`), asserts the `firebird` key + required sections/fields. GUI radio-button visual check still pending in G1. |

## Phase C — Core Tcl modules (`src/firebird/`)

| # | Status | Commit | Task | Notes / Files |
|---|---|---|---|---|
| C1 | 🔧 IN PROGRESS |  | Create `src/firebird/fbopt.tcl` (options dialog) | Stub committed: `setlocalfbtpccvars` and `setlocalfbtpchvars` helpers wired to `configfirebird`. GUI tabs (connection, TPROC-C/H schema/driver) still TODO — mirror [src/postgresql/pgopt.tcl](src/postgresql/pgopt.tcl). |
| C2 | ✅ DONE | 08939b2 | Create `src/firebird/fboltp.tcl` skeleton with `ConnectToFirebird` helper | `fb_build_connstr` and `ConnectToFirebird` use `tdbc::odbc::connection new`, support both embedded (`Dbname=path;Client=fbclient.dll;User=...`) and future server mode, hide password in error output. |
| C3 | ✅ DONE | f404a68 | TPROC-C schema DDL: `CREATE TABLE` for WAREHOUSE, DISTRICT, CUSTOMER, ITEM, STOCK, ORDERS, ORDER_LINE, NEW_ORDER, HISTORY | DDL in `fb_tpcc_table_ddl` + `fb_tpcc_index_ddl` (fboltp.tcl). 9 tables + 2 secondary indexes match the canonical TPC-C set. CI step `Build TPC-C schema on a fresh embedded .fdb` runs `fb_create_tpcc_schema` and asserts via `RDB$RELATIONS`/`RDB$INDICES`. No identity columns — TPC-C uses caller-supplied keys (D_NEXT_O_ID etc.). |
| C4 | ✅ DONE | 053d85a | TPROC-C schema bulk-load procs (no COPY/BCP available) | `fb_load_item`, `fb_load_warehouse`, `fb_load_districts`, `fb_load_customer_history`, `fb_load_stock`, `fb_load_orders`, `fb_load_warehouse_data`. Prepared INSERT + named (`:name`) tdbc params, dict-bound rows; `fb_exec` helper closes the resultset between executions (Firebird otherwise raises "Too many concurrent executions of the same request"). 1-warehouse load completes in 31s on the runner: WAREHOUSE/DISTRICT/CUSTOMER/HISTORY/ITEM/STOCK/ORDERS/NEW_ORDER all hit the spec, ORDER_LINE 300,295 (within tolerance). |
| C5 | ✅ DONE | 8cf63c6 | TPROC-C PSQL stored procedures: `NEWORD`, `PAYMENT`, `DELIVERY`, `OSTAT`, `SLEV` | All 5 procs in `.github/workflows/scripts/fb_tpcc_sps.sql`. Install via `Invoke-FirebirdIsql` with `SET TERM ^` (tdbc::odbc rejects `:NAME` PSQL refs in CREATE PROCEDURE body). All invoke via `SELECT FROM <PROC>(:params)` — they all use `SUSPEND` so are selectable procedures. CI verified outputs: PAYMENT_SP balance -22.34, OSTAT_SP order 1087, SLEV_SP 12 lows, DELIVERY_SP 10 districts delivered, NEWORD_SP order 3003 total 1698.51. NEWORD_SP picks `S_DIST_NN` via `CASE :P_D_ID` (no Firebird PSQL dynamic SQL needed). DELIVERY_SP uses PSQL `WHILE` over the 10 districts. |
| C6 | ✅ DONE | 177820c | TPROC-C client-side prepared statements (fallback when `fb_storedprocs=false`) | `neword/payment/delivery/ostat/slev` in fboltp.tcl. Each opens an explicit transaction, runs the canonical SQL stream via tdbc::odbc + named params, commits (rollbacks on exception). `fb_select`/`fb_select1`/`fb_dml` helpers manage resultset closing. CI: 200 transactions ran in 1.78s on the runner, zero failures, mix 85/85/9/10/11 (NewOrder/Payment/Delivery/OrderStatus/StockLevel). |
| C7 | 🔧 IN PROGRESS | 177820c | TPROC-C driver loop with virtual users, key/think time, mix ratios | Single-VU mix-runner implemented in `.github/workflows/scripts/fb_runtxn.tcl` (RandomNumber 1..23 → neword/payment/delivery/ostat/slev). Multi-VU thread orchestration via HammerDB's `vuset/vucreate/vurun` is part of the scripts in Phase D and not exercised yet from the plain-tclsh CI harness. |
| C8 | ✅ DONE | 7dc3ec1 | Update-conflict retry logic for MVCC | `fb_with_retry` + `fb_is_retryable_error` in fboltp.tcl. Pattern-matches `deadlock` / `lock conflict` / `update conflict` / `concurrent update` / `concurrent transaction` / `40001` / `isc_update_conflict` case-insensitively. All 5 client-side driver procs wrapped in `for {attempt 0..3}` loop with 5-40ms back-off; delivery does per-district retry. CI verified: 13/13 unit tests pass (8 retryable + 5 non-retryable patterns + retry-then-succeed + propagate-immediate + exhaust-max-retries + empty-string), 200 TPC-C transactions still complete cleanly, TPC-H power test still passes. |
| C9 | ✅ DONE | 1f36e40 | Create `src/firebird/fbolap.tcl` skeleton + TPROC-H schema build | DDL: `fb_tpch_table_ddl` (8 tables, BIGINT keys, NUMERIC(12,2) money, TIMESTAMP dates, named `*_PK` primary keys) + `fb_create_tpch_schema`. CI: builds 8 tables in 54-69 ms, asserts via `RDB$RELATIONS` + `RDB$RELATION_CONSTRAINTS WHERE RDB$CONSTRAINT_TYPE='PRIMARY KEY'`. dbgen-style bulk loader still **deferred** — see C10/C11. |
| C10 | ✅ DONE | 658a4dc | TPROC-H queries 1–22 in Firebird SQL dialect | All 22 queries in `fb_tpch_queries` (fbolap.tcl). Adaptations: PG `interval ':1 day'` → Firebird `dateadd(-:1 day to date '...')`, `interval '3 month'` / `'1 year'` → `dateadd(... to date)`. Q11 alias `value` (reserved word) renamed to `tot_value`. Q22 `substr(x,y,z)` → `substring(x from y for z)`. Q15 multi-statement (view + select + drop) preserved with `:VID` substitution slot; CI executes the DDL parts and PREPAREs the SELECT. CI: 22/22 queries PREPARE cleanly against the empty TPC-H schema. |
| C11 | ✅ DONE | 4b1a1c8 | TPROC-H driver: bulk loader + power test | Loader + RF1/RF2 + 22-query orchestrator + geometric-mean reporting. `fb_tpch_rf1` inserts SF*1500 new orders (1-7 lineitems each), `fb_tpch_rf2` deletes by orderkey (round-trips RF1), `fb_tpch_sub_query` (port of postgres `sub_query` for placeholder fills), `fb_tpch_power_test` runs RF1 → 22 queries in `ordered_set $myposition` order → RF2. CI verified at scale 0.01: RF1=15 in 69ms, RF2=15 in 3ms, **20/22 queries returned rows, gmean=154ms, ORDERS round-tripped (15000=15000)**, total 146s. Q16 substitution bug (`:1` matched leading `:1` of `:10`) fixed by descending placeholder order. Multi-VU "throughput" test (concurrent query streams + parallel refresh stream) is the only remaining TPC-H deferred item. |
| C12 | 🔧 IN PROGRESS | 08939b2 | Create `src/firebird/fbotc.tcl` (transaction counter) | Stub `tcount_fb` proc defined so the GUI dispatcher resolves; real impl (worker thread polling `MON$STATEMENTS`) deferred. Mirrors [src/postgresql/pgotc.tcl](src/postgresql/pgotc.tcl). |
| C13 | ✅ DONE | 08939b2 | Create `src/firebird/fbci.tcl` + `fbmet.tcl` stubs | One-line stubs matching MSSQL's pattern (`#ci`, `#database metrics`); CI pipeline + metrics work tracked separately under Phase F / Phase H. |

## Phase D — Tcl test scripts (`scripts/tcl/firebird/`)

For both TPROC-C and TPROC-H, mirror the 10-file PostgreSQL set: `*_buildschema.tcl`, `*_checkschema.tcl`, `*_deleteschema.tcl`, `*_run.tcl`, `*_run_profile.tcl`, `*_result.tcl`, `*_profile.sh`, `*_single.sh`, `*.sh`, `*.ps1`. Naming: `fb_tprocc_buildschema.tcl`, etc.

| # | Status | Commit | Task | Notes / Files |
|---|---|---|---|---|
| D1 | 🔧 IN PROGRESS |  | `scripts/tcl/firebird/tprocc/` — 7 files | Committed: `fb_tprocc_buildschema.tcl`, `fb_tprocc_checkschema.tcl`, `fb_tprocc_deleteschema.tcl`, `fb_tprocc_run.tcl`, `fb_tprocc_result.tcl`, `fb_tprocc.sh`, `fb_tprocc.ps1`. Modelled on the postgres set; defaults target Firebird Embedded at `$TMP/tpcc.fdb`. Profile script (`fb_tprocc_profile.sh`/`fb_tprocc_run_profile.tcl`) deferred. |
| D2 | 🔧 IN PROGRESS |  | `scripts/tcl/firebird/tproch/` — 7 files | Committed: matching set (`fb_tproch_buildschema.tcl`, …, `fb_tproch.sh`, `fb_tproch.ps1`). |
| D3 | ⏯️ DEFERRED |  | Add a workflow job that smoke-runs each script via `./hammerdbcli auto <script>` on the CI runner | Requires the bundled HammerDB Tcl/Tk runtime (the source tree only ships sources, not `bin/tclsh9.0`). Will be wired up in Phase G once the workflow knows how to download/install a HammerDB release inside CI. |

## Phase E — Python parallel scripts (`scripts/python/firebird/`)

| # | Status | Commit | Task | Notes / Files |
|---|---|---|---|---|
| E1 | 🔧 IN PROGRESS |  | `scripts/python/firebird/tprocc/` — `.py` files mirroring D1 | Committed: `fb_tprocc_buildschema.py`, `fb_tprocc_checkschema.py`, `fb_tprocc_deleteschema.py`, `fb_tprocc_run.py`, `fb_tprocc_result.py`, `fb_tprocc_py.sh`, `fb_tprocc_py.ps1`. Profile/single wrappers deferred. |
| E2 | 🔧 IN PROGRESS |  | `scripts/python/firebird/tproch/` — equivalent set | Committed: matching set under tproch. |
| E3 | ⏯️ DEFERRED |  | Add a workflow job that runs the Python entrypoints against an embedded `.fdb` on the CI runner | Same constraint as D3: requires `hammerdbcli py auto` runtime. Wired up alongside D3 in Phase G. |

## Phase F — CI pipeline + Docker

| # | Status | Commit | Task | Notes / Files |
|---|---|---|---|---|
| F1 | ✅ DONE | cf20a89 | Add `<Firebird>` block to [config/ci.xml](config/ci.xml) | Block committed. `build` stage uses PSFirebird; `install`/`start`/`shutdown` are no-ops (embedded). |
| F2 | ✅ DONE | 89ac8b6 | Create `Docker/firebird/Dockerfile` for a Linux CI variant | Base: `tpcorg/hammerdb:v5.0-base`. Adds `firebird3.0-utils` + `libfbclient2` + `unixodbc` + `unzip`, downloads `linux_libs.zip` from `v3-0-1-release`, installs `libOdbcFb.so`, registers `Firebird ODBC Driver` in `/etc/odbcinst.ini` via `echo … | tee`. |
| F3 | ✅ DONE | cf20a89 | Document Docker usage | Covered by `Docker/firebird/Readme.md` (build + embedded-mode run). |
| F4 | 🔧 IN PROGRESS | 89ac8b6 | `ubuntu-latest` job in `.github/workflows/firebird.yml` | New `docker-build` job builds the image and inspects `libfbclient*`/`libOdbcFb.so`/`/etc/odbcinst.ini` inside it. **Running the Firebird smoke tests inside the container** still pending — would need the same Magicsplat-equivalent + tdbc::odbc setup as the Windows job, plus a Linux PSFirebird path; deferred. |

## Phase G — End-to-end smoke validation

| # | Status | Commit | Task | Notes / Files |
|---|---|---|---|---|
> All G-phase tasks run on the GitHub Actions workflow from A1. No local execution. Outputs (NOPM/TPM numbers, per-query timings, parity reports) are uploaded as workflow artifacts and referenced by SHA in PR descriptions.

| # | Status | Commit | Task | Notes / Files |
|---|---|---|---|---|
| G1 | ❌ OPEN |  | Headless GUI registration check on `windows-latest` | The Tk GUI cannot be exercised visually on a CI runner. Substitute: a tclsh job that loads `src/generic/geninit.tcl`, asserts `[dict exists $dbdict firebird]`, and asserts the per-DB Tcl modules source without error. No screenshots — logs are the artifact. |
| G2 | ⏯️ DEFERRED |  | TPROC-C build (1 warehouse) → run (1 VU, 2 min rampup, 5 min duration) → non-zero NOPM/TPM, on CI | **Blocked by:** the HammerDB Windows release ships as a single self-contained `.exe` (`hammerdbcli.exe`) with the entire `src/`, `modules/`, etc. bundled via Tcl `zipfs`. Overlaying our `src/firebird/`/`config/firebird.xml` files on disk has no effect because the binary reads from its embedded zipfs. Validating end-to-end requires either (a) rebuilding the .exe via the upstream Bawt build system or (b) waiting for an upstream HammerDB release that already includes Firebird. The TPC-C/H schema + driver logic is independently verified on CI via the standalone tdbc::odbc tests in C3/C4/C6/C9 — only the user-facing `hammerdbcli` integration remains untested. |
| G3 | ❌ OPEN |  | TPROC-H build (scale 1) → run all 22 queries → all complete, on CI | Per-query timings written to a workflow artifact (CSV). Any query failure → flag back to C10 with the SQL fragment in the failure log. |
| G4 | ❌ OPEN |  | Python mirror runs the same TPROC-C build/run on CI; results within ±10% of Tcl path | Same workflow, parallel job. Compares NOPM artifact from G2 vs the Python job's artifact. |
| G5 | ❌ OPEN |  | Workflow job: hash/row-count parity of TPROC-C tables vs a PostgreSQL build at same warehouse count | Spin up PostgreSQL via `services:` in the workflow, build the same 1-warehouse schema with the existing pg scripts, then compare per-table `COUNT(*)` and a stable column hash. Report uploaded as artifact. |

## Phase H — Documentation & follow-ups

| # | Status | Commit | Task | Notes / Files |
|---|---|---|---|---|
| H1 | ⏯️ DEFERRED |  | Update https://www.hammerdb.com/docs/ chapter | Lives outside the repo. Track separately with maintainers once the upstream PR lands. |
| H2 | ⏯️ DEFERRED |  | Open follow-up issue for `fbmet.tcl` (Active Session History via `MON$` tables) | Documented in `src/firebird/README.md` "Deferred items"; convert to a GitHub issue when opening the upstream PR. |
| H3 | ⏯️ DEFERRED |  | Native `tdbc::firebird` driver evaluation | Documented in `src/firebird/README.md`. Revisit only if ODBC overhead becomes the benchmark bottleneck. |
| H4 | ⏯️ DEFERRED |  | Announce on the HammerDB GitHub Discussion #57 (Firebird request thread) | Hold until Phase G unblocks (needs an upstream Bawt rebuild that includes our additions). |
| H5 | ✅ DONE | (this commit) | Add `src/firebird/README.md` | Architecture overview: status table, embedded-by-default rationale, tdbc::odbc + ODBC driver wiring, dual `:NAME` parameter convention (DSQL vs PSQL), `S_DIST_NN` CASE trick, file layout, deferred-items summary, local-test recipe. |
