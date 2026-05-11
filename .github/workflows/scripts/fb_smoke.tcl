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

# The Client= attribute is dlopen'd by the Firebird ODBC driver, so
# the file extension is platform-specific.
if {[info exists ::env(FB_CLIENT_LIB)] && $::env(FB_CLIENT_LIB) ne ""} {
    set client $::env(FB_CLIENT_LIB)
} elseif {$::tcl_platform(platform) eq "windows"} {
    set client "fbclient.dll"
} else {
    set client "libfbclient.so.2"
}
set connStr "Driver={$driver};Dbname=$dbpath;Client=$client;UID=SYSDBA;"
# Optional explicit password. Embedded mode on Linux with FB3 Legacy_Auth
# still authenticates against security.fdb / Legacy_UserManager and the
# default SYSDBA/masterkey lives there; on Windows, Trusted_Auth makes
# the password unnecessary, so FB_PASSWORD stays unset there.
if {[info exists ::env(FB_PASSWORD)] && $::env(FB_PASSWORD) ne ""} {
    append connStr "PWD=$::env(FB_PASSWORD);"
}
puts "connection string: $connStr"

# Trap the connection error so we can inspect exactly what the driver
# returned to tdbc::odbc - on Linux the upstream Firebird ODBC driver
# (both v3-0-1-release and v3.5.0-rc1) has historically returned an
# empty SQLSTATE + non-deterministic native code + a single-byte
# message; we want to see whether the v3.5.1-rc1 patched build
# changes that.
if {[catch {tdbc::odbc::connection new $connStr} conn errdict]} {
    puts stderr "tdbc::odbc::connection failed:"
    puts stderr "  -message: <<<$conn>>> (strlen=[string length $conn])"
    foreach k [list -errorcode -errorinfo] {
        if {[dict exists $errdict $k]} {
            set v [dict get $errdict $k]
            puts stderr "  $k: <<<$v>>>"
        }
    }
    # Hex dump the first 64 bytes of the message - reveals embedded
    # nulls, control characters, anything strcpy would have truncated.
    binary scan $conn H* hex
    set hex [string range $hex 0 127]
    puts stderr "  -message hex (first 64B): $hex"
    exit 3
}
# Firebird upper-cases unquoted identifiers, so tdbc returns dict
# keys like ONE, not one. Read the first column by position to stay
# dialect-neutral.
set stmt [$conn prepare {SELECT 1 AS one FROM RDB$DATABASE}]
set ok 0
$stmt foreach row {
    puts "row: $row"
    set first [lindex [dict values $row] 0]
    if {$first eq "1"} { set ok 1 }
}
$stmt close
$conn close

if {!$ok} {
    puts stderr "smoke test failed: SELECT 1 did not return 1"
    exit 3
}
puts "OK"
