# Firebird Embedded smoke test for the CI workflow.
# Inputs (env vars):
#   FB_ODBC_DRIVER  - registered driver name, e.g. "Firebird/InterBase(r) driver"
#   FB_DB_PATH      - absolute path to the embedded .fdb (forward slashes)
#
# Asserts that tdbc::odbc can connect to a Firebird Embedded database via the
# canonical connection string and that SELECT 1 FROM RDB$DATABASE returns 1.

package require tdbc::odbc

set driver [string trim $::env(FB_ODBC_DRIVER)]
set dbpath [string trim $::env(FB_DB_PATH)]
if {$driver eq "" || $dbpath eq ""} {
    puts stderr "FB_ODBC_DRIVER and FB_DB_PATH must be set"
    exit 2
}

set connStr "Driver={$driver};Dbname=$dbpath;Client=fbclient.dll;User=SYSDBA;"
puts "connection string: $connStr"

set conn [tdbc::odbc::connection new $connStr]
set stmt [$conn prepare {SELECT 1 AS one FROM RDB$DATABASE}]
set ok 0
$stmt foreach row {
    puts "row: $row"
    if {[dict get $row one] eq "1"} { set ok 1 }
}
$stmt close
$conn close

if {!$ok} {
    puts stderr "smoke test failed: SELECT 1 did not return 1"
    exit 3
}
puts "OK"
