# Install + invoke the Firebird PSQL stored procs against a loaded
# TPC-C database. Initial cut: PAYMENT_SP only. Verifies that:
#   1. CREATE OR ALTER PROCEDURE syntax is accepted by Firebird via
#      tdbc::odbc (no SET TERM needed).
#   2. EXECUTE PROCEDURE returns the expected output columns.
#
# Inputs:
#   HAMMERDB_ROOT  - HammerDB repo checkout
#   FB_ODBC_DRIVER - registered driver name
#   FB_DB_PATH     - .fdb with TPC-C schema + 1 warehouse loaded

set root [string trim $::env(HAMMERDB_ROOT)]
set driver [string trim $::env(FB_ODBC_DRIVER)]
set dbpath [string trim $::env(FB_DB_PATH)]
foreach {n v} [list HAMMERDB_ROOT $root FB_ODBC_DRIVER $driver FB_DB_PATH $dbpath] {
    if {$v eq ""} { puts stderr "$n must be set"; exit 2 }
}

::tcl::tm::path add [file join $root modules]
package require xml 1.1
package require tdbc::odbc

set ::dbdict [::XML::To_Dict [file join $root config database.xml]]
set ::configfirebird [::XML::To_Dict [file join $root config firebird.xml]]
foreach f {fbci.tcl fbmet.tcl fbotc.tcl fbopt.tcl fboltp.tcl fbolap.tcl} {
    source [file join $root src firebird $f]
}

set conn [ConnectToFirebird $driver true "" "" $dbpath SYSDBA "" UTF8]
puts "Connected to $dbpath"

set installed [fb_create_tpcc_stored_procs $conn]
puts "OK: installed $installed stored procedure(s)"

# Verify PAYMENT_SP exists in the catalog
set found 0
$conn foreach -as lists row {
    SELECT TRIM(RDB$PROCEDURE_NAME) FROM RDB$PROCEDURES
    WHERE RDB$SYSTEM_FLAG = 0
} { if {[lindex $row 0] eq "PAYMENT_SP"} { set found 1 } }
if {!$found} {
    puts stderr "FAIL: PAYMENT_SP not in RDB\$PROCEDURES"
    $conn close
    exit 3
}
puts "OK: PAYMENT_SP visible in RDB\$PROCEDURES"

# Invoke PAYMENT_SP for warehouse 1 / district 1 / customer 1.
$conn begintransaction
set ts [clock format [clock seconds] -format "%Y-%m-%d %H:%M:%S"]
set rs [$conn prepare {
    EXECUTE PROCEDURE PAYMENT_SP (:w_id, :d_id, :cw_id, :cd_id, :c_id, :amt, :ts)
}]
set out [$rs execute [dict create w_id 1 d_id 1 cw_id 1 cd_id 1 c_id 1 amt 12.34 ts $ts]]
set rows [list]
$out foreach -as dicts -- r { lappend rows $r }
$out close
$rs close
$conn commit

if {[llength $rows] == 0} {
    puts stderr "FAIL: PAYMENT_SP returned no rows"
    $conn close
    exit 3
}
puts "OK: PAYMENT_SP returned [lindex $rows 0]"

$conn close
puts "OK: stored-proc smoke verified"
