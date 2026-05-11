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
| C5 | ❌ OPEN |  | TPROC-C PSQL stored procedures: `NEWORD`, `PAYMENT`, `DELIVERY`, `OSTAT`, `SLEV` | `CREATE OR ALTER PROCEDURE … AS BEGIN … END`. Use `EXCEPTION WHEN …` for handled errors. Reference [src/postgresql/pgoltp.tcl](src/postgresql/pgoltp.tcl) lines 47–200 for the canonical procedure bodies — translate PL/pgSQL → Firebird PSQL. |
| C6 | 🔧 IN PROGRESS |  | TPROC-C client-side prepared statements (fallback when `fb_storedprocs=false`) | `neword/payment/delivery/ostat/slev` ported from the TPC-C spec into Tcl in fboltp.tcl. Each opens an explicit transaction, runs the canonical SQL stream via tdbc::odbc + named params, commits (rollbacks on exception). `fb_select`/`fb_select1`/`fb_dml` helpers handle resultset closing. CI step `Run 200 TPC-C transactions` verifies the mix runs without failures. |
| C7 | ❌ OPEN |  | TPROC-C driver loop with virtual users, key/think time, mix ratios | Reuse [modules/tpcccommon-1.0.tm](modules/tpcccommon-1.0.tm) (`RandomNumber`, `NURand`, `Lastname`, `keytime`, `thinktime`). Mix: 45% NewOrder / 43% Payment / 4% Delivery / 4% OrderStatus / 4% StockLevel via `RandomNumber 1 23` switch. |
| C8 | ❌ OPEN |  | Update-conflict retry logic for MVCC | Wrap each transaction in a retry loop that catches Firebird `isc_update_conflict` (SQLSTATE `40001` family). Mirror PostgreSQL's serialisation-failure handling in pgoltp.tcl. Cap retries (e.g. 5) before raising. |
| C9 | ❌ OPEN |  | Create `src/firebird/fbolap.tcl` skeleton + TPROC-H schema build | Tables: REGION, NATION, SUPPLIER, CUSTOMER, PART, PARTSUPP, ORDERS, LINEITEM. Bulk load via batched INSERTs (same pattern as C4). |
| C10 | ❌ OPEN |  | TPROC-H queries 1–22 in Firebird SQL dialect | Source SQL: [src/postgresql/pgolap.tcl](src/postgresql/pgolap.tcl) `set sql(N)` blocks. Adapt: window functions OK (FB 3+), recursive CTE OK, `EXTRACT` OK, `INTERVAL` syntax differs. Q15 = view+select multi-statement (split on `;`). |
| C11 | ❌ OPEN |  | TPROC-H driver: query stream, refresh streams (RF1 inserts / RF2 deletes) | Mirror PostgreSQL `pgolap.tcl` driver structure. Use `tpchcommon-1.0.tm` for parameter substitution. |
| C12 | 🔧 IN PROGRESS | 08939b2 | Create `src/firebird/fbotc.tcl` (transaction counter) | Stub `tcount_fb` proc defined so the GUI dispatcher resolves; real impl (worker thread polling `MON$STATEMENTS`) deferred. Mirrors [src/postgresql/pgotc.tcl](src/postgresql/pgotc.tcl). |
| C13 | ✅ DONE | 08939b2 | Create `src/firebird/fbci.tcl` + `fbmet.tcl` stubs | One-line stubs matching MSSQL's pattern (`#ci`, `#database metrics`); CI pipeline + metrics work tracked separately under Phase F / Phase H. |

## Phase D — Tcl test scripts (`scripts/tcl/firebird/`)

For both TPROC-C and TPROC-H, mirror the 10-file PostgreSQL set: `*_buildschema.tcl`, `*_checkschema.tcl`, `*_deleteschema.tcl`, `*_run.tcl`, `*_run_profile.tcl`, `*_result.tcl`, `*_profile.sh`, `*_single.sh`, `*.sh`, `*.ps1`. Naming: `fb_tprocc_buildschema.tcl`, etc.

| # | Status | Commit | Task | Notes / Files |
|---|---|---|---|---|
| D1 | ❌ OPEN |  | `scripts/tcl/firebird/tprocc/` — 10 files | Template: [scripts/tcl/postgres/tprocc/](scripts/tcl/postgres/tprocc/). Replace `pg_*` settings with `fb_*` from `firebird.xml`. |
| D2 | ❌ OPEN |  | `scripts/tcl/firebird/tproch/` — equivalent file set | Template: [scripts/tcl/postgres/tproch/](scripts/tcl/postgres/tproch/). |
| D3 | ❌ OPEN |  | Add a workflow job that smoke-runs each script via `./hammerdbcli auto <script>` on the CI runner | Runs after A1–A4 succeed. 1-warehouse TPROC-C / scale-1 TPROC-H against an embedded `.fdb` provisioned by `New-FirebirdDatabase`. Each script must parse, connect, and exit 0. Failures fail the workflow. |

## Phase E — Python parallel scripts (`scripts/python/firebird/`)

| # | Status | Commit | Task | Notes / Files |
|---|---|---|---|---|
| E1 | ❌ OPEN |  | `scripts/python/firebird/tprocc/` — `.py` files mirroring D1 | Template: [scripts/python/postgres/tprocc/](scripts/python/postgres/tprocc/). 7 `.py` + 3 shell wrappers (`*_py.sh`, `*_py.ps1`, `*_single_py.sh`, `*_profile_py.sh`). |
| E2 | ❌ OPEN |  | `scripts/python/firebird/tproch/` — equivalent set | Template: [scripts/python/postgres/tproch/](scripts/python/postgres/tproch/). |
| E3 | ❌ OPEN |  | Add a workflow job that runs the Python entrypoints against an embedded `.fdb` on the CI runner | HammerDB embeds Tcl-via-Python; ensure the Python entrypoint environment sees `fbclient.dll` (PATH from A2) and the registered ODBC driver (A3). Job runs after E1–E2 land and gates merging. |

## Phase F — CI pipeline + Docker

| # | Status | Commit | Task | Notes / Files |
|---|---|---|---|---|
| F1 | ❌ OPEN |  | Add `<Firebird>` block to [config/ci.xml](config/ci.xml) | Stages: `clone` (PSFirebird `New-FirebirdEnvironment -Version 5.0.3`), `build` (skip — upstream binary), `install`, `init` (`New-FirebirdDatabase` on a fresh `.fdb`), `start` (no-op for embedded), `test`. Reference commit `bca921d` (MySQL CI) for the exact element layout. |
| F2 | ❌ OPEN |  | Create `Docker/firebird/Dockerfile` for a Linux CI variant | Base: `firebirdsql/firebird:5` (Alpine variant). Layer: install Firebird ODBC driver (`apk add --no-cache firebird-odbc` or build from source), copy HammerDB tree. **No** `FIREBIRD_ROOT_PASSWORD` — image is consumed by an embedded-mode workload, not a server. Image is built and pushed only by the GitHub Actions workflow, never locally. |
| F3 | ❌ OPEN |  | Document the GitHub Actions snippet that pulls + runs the image (no local docker invocations) | Inline Markdown in this file under Phase F. Show the `actions/checkout` + `docker/build-push-action` + `docker run` steps that exercise the Firebird CI pipeline. |
| F4 | ❌ OPEN |  | Add a `ubuntu-latest` matrix leg to `.github/workflows/firebird.yml` that runs the Firebird CI pipeline inside the F2 container | Confirms F1–F2 work end-to-end. Runs the same TPROC-C build + 1 VU run as G2 but on Linux/embedded. Logs become a workflow artifact. |

## Phase G — End-to-end smoke validation

| # | Status | Commit | Task | Notes / Files |
|---|---|---|---|---|
> All G-phase tasks run on the GitHub Actions workflow from A1. No local execution. Outputs (NOPM/TPM numbers, per-query timings, parity reports) are uploaded as workflow artifacts and referenced by SHA in PR descriptions.

| # | Status | Commit | Task | Notes / Files |
|---|---|---|---|---|
| G1 | ❌ OPEN |  | Headless GUI registration check on `windows-latest` | The Tk GUI cannot be exercised visually on a CI runner. Substitute: a tclsh job that loads `src/generic/geninit.tcl`, asserts `[dict exists $dbdict firebird]`, and asserts the per-DB Tcl modules source without error. No screenshots — logs are the artifact. |
| G2 | ❌ OPEN |  | TPROC-C build (1 warehouse) → run (1 VU, 2 min rampup, 5 min duration) → non-zero NOPM/TPM, on CI | Workflow runs both `fb_storedprocs=true` and `fb_storedprocs=false` legs. Numbers captured from the run log artifact and posted to the PR via `actions/github-script`. |
| G3 | ❌ OPEN |  | TPROC-H build (scale 1) → run all 22 queries → all complete, on CI | Per-query timings written to a workflow artifact (CSV). Any query failure → flag back to C10 with the SQL fragment in the failure log. |
| G4 | ❌ OPEN |  | Python mirror runs the same TPROC-C build/run on CI; results within ±10% of Tcl path | Same workflow, parallel job. Compares NOPM artifact from G2 vs the Python job's artifact. |
| G5 | ❌ OPEN |  | Workflow job: hash/row-count parity of TPROC-C tables vs a PostgreSQL build at same warehouse count | Spin up PostgreSQL via `services:` in the workflow, build the same 1-warehouse schema with the existing pg scripts, then compare per-table `COUNT(*)` and a stable column hash. Report uploaded as artifact. |

## Phase H — Documentation & follow-ups

| # | Status | Commit | Task | Notes / Files |
|---|---|---|---|---|
| H1 | ❌ OPEN |  | Update https://www.hammerdb.com/docs/ chapter mentioning supported databases | Coordinate with maintainers via PR — docs live outside this repo. |
| H2 | ❌ OPEN |  | Open follow-up issue for `fbmet.tcl` (Active Session History via `MON$` tables) | Explicitly out of scope for this initial integration. Link to [src/postgresql/pgmet.tcl](src/postgresql/pgmet.tcl) and [src/mysql/mysqlmet.tcl](src/mysql/mysqlmet.tcl) as references. |
| H3 | ⏯️ DEFERRED |  | Native `tdbc::firebird` driver evaluation | Blocked by: ODBC route validated in Phases C–G first. Revisit only if ODBC overhead becomes the benchmark bottleneck. |
| H4 | ❌ OPEN |  | Announce on the HammerDB GitHub Discussion #57 (Firebird request thread) | After Phase G passes. |
