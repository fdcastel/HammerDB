#!/usr/bin/env bash
# Linux smoke test for the Firebird Docker image. Runs inside the
# container with the workspace mounted at /work. Avoids the
# bash-single-quote nesting pitfalls of writing this inline in YAML.
set -eux

# Diagnostic: what tdbc::odbc package version is on the system, and
# where does its shared lib live? Helps narrow down whether the C
# vs Tcl asymmetry is a tdbcodbc behavior.
tclsh <<EOF
package require tdbc::odbc
puts "tdbc::odbc version : [package require tdbc::odbc]"
puts "tdbc::odbc library : [package ifneeded tdbc::odbc [package require tdbc::odbc]]"
EOF
find / -name "libtdbcodbc*.so*" 2>/dev/null | head -5 || true
ldd $(find / -name "libtdbcodbc*.so*" 2>/dev/null | head -1) 2>/dev/null | head -20 || true

# 1. Diagnostic: tcl smoke FIRST on a private .fdb, before the C probe
# touches anything (so there's no chance the C probe is leaving
# Engine12 state behind that affects subsequent opens).
rm -f /tmp/tcl_first.fdb
echo "CREATE DATABASE '/tmp/tcl_first.fdb' USER 'SYSDBA' PASSWORD 'masterkey'; QUIT;" | isql-fb -q

echo "--- tcl-only on a fresh .fdb (no prior probe) ---"
FB_DB_PATH=/tmp/tcl_first.fdb \
  tclsh .github/workflows/scripts/fb_smoke.tcl || true

# 2. Bare unixODBC SQLDriverConnect via a tiny C program. Walks every
# diag record and hex-dumps the message so we see exactly what the
# Firebird ODBC driver returned (tdbc::odbc wraps the diagnostic
# record and has been obscuring this).
rm -f /tmp/smoke.fdb
echo "CREATE DATABASE '/tmp/smoke.fdb' USER 'SYSDBA' PASSWORD 'masterkey'; QUIT;" | isql-fb -q
ls -la /tmp/smoke.fdb

gcc -O0 -g -o /tmp/fb_odbc_probe .github/workflows/scripts/fb_odbc_probe.c -lodbc
echo "--- C probe ---"
/tmp/fb_odbc_probe "Driver={Firebird ODBC Driver};Dbname=/tmp/smoke.fdb;Client=libfbclient.so.2;UID=SYSDBA;PWD=masterkey;" || true

# Diagnostic: enable unixODBC driver-manager tracing during the tcl
# smoke. Captures every SQL* call tdbc::odbc makes, so we can compare
# against the C probe's call sequence and see what tdbc does
# differently. /etc/odbcinst.ini already exists; append [ODBC]
# section if missing.
mkdir -p /tmp/odbc
cat >> /etc/odbcinst.ini <<'TRACECONF'

[ODBC]
Trace=Yes
TraceFile=/tmp/odbc/trace.log
TRACECONF

# 3. Tcl smoke after the C probe, on a fresh .fdb to rule out any
# leftover state.
echo "--- tcl smoke (real, against a fresh .fdb after probe) ---"
rm -f /tmp/smoke2.fdb
echo "CREATE DATABASE '/tmp/smoke2.fdb' USER 'SYSDBA' PASSWORD 'masterkey'; QUIT;" | isql-fb -q
FB_DB_PATH=/tmp/smoke2.fdb \
  tclsh .github/workflows/scripts/fb_smoke.tcl || true

# Diagnostic: dump the ODBC trace produced during the tcl smoke.
echo "--- ODBC trace (last 100 lines) ---"
tail -n 100 /tmp/odbc/trace.log 2>/dev/null || echo "(no trace file produced)"

exit 1  # stop here; the schema step below would also fail until tcl is fixed.

# 4. Schema: build the full 9-table TPC-C schema
rm -f /tmp/schema.fdb
echo "CREATE DATABASE '/tmp/schema.fdb' USER 'SYSDBA' PASSWORD 'masterkey'; QUIT;" | isql-fb -q
FB_DB_PATH=/tmp/schema.fdb \
  tclsh .github/workflows/scripts/fb_schema.tcl
