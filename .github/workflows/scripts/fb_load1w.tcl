# Build the TPC-C schema and bulk-load 1 warehouse worth of data
# (~600k rows across 9 tables) on a fresh embedded Firebird .fdb.
# Asserts row counts match TPC-C spec at the end.
#
# Inputs:
#   HAMMERDB_ROOT  - HammerDB repo checkout
#   FB_ODBC_DRIVER - registered driver name
#   FB_DB_PATH     - absolute path to the .fdb (forward slashes)

set root [string trim $::env(HAMMERDB_ROOT)]
set driver [string trim $::env(FB_ODBC_DRIVER)]
set dbpath [string trim $::env(FB_DB_PATH)]
foreach {n v} [list HAMMERDB_ROOT $root FB_ODBC_DRIVER $driver FB_DB_PATH $dbpath] {
    if {$v eq ""} { puts stderr "$n must be set"; exit 2 }
}

::tcl::tm::path add [file join $root modules]
package require xml 1.1
package require tdbc::odbc
package require tpcccommon

set ::dbdict [::XML::To_Dict [file join $root config database.xml]]
set ::configfirebird [::XML::To_Dict [file join $root config firebird.xml]]
foreach f {fbci.tcl fbmet.tcl fbotc.tcl fbopt.tcl fboltp.tcl fbolap.tcl} {
    source [file join $root src firebird $f]
}

set conn [ConnectToFirebird $driver true "" "" $dbpath SYSDBA "" UTF8]
puts "Connected to $dbpath"

set t0 [clock milliseconds]
fb_create_tpcc_schema $conn
puts "Schema built in [expr {[clock milliseconds] - $t0}] ms"

set t0 [clock milliseconds]
set itemRows [fb_load_item $conn 100000]
puts "ITEM:    $itemRows rows in [expr {[clock milliseconds] - $t0}] ms"

set t0 [clock milliseconds]
set per [fb_load_warehouse_data $conn 1 10 3000 100000]
puts "warehouse 1 loaded in [expr {[clock milliseconds] - $t0}] ms: $per"

# Verify row counts match TPC-C spec for 1 warehouse.
set expected {
    WAREHOUSE  1
    DISTRICT   10
    CUSTOMER   30000
    HISTORY    30000
    ITEM       100000
    STOCK      100000
    ORDERS     30000
    NEW_ORDER  9000
}
set fails 0
foreach {tbl want} $expected {
    set got 0
    $conn foreach -as lists row "SELECT COUNT(*) FROM $tbl" { set got [lindex $row 0] }
    if {$got ne $want} {
        puts stderr "FAIL: $tbl expected $want, got $got"
        incr fails
    } else {
        puts "OK:   $tbl = $got"
    }
}

# ORDER_LINE row count is variable (5-15 lines per order, mean 10);
# verify it's within a reasonable range.
set olCount 0
$conn foreach -as lists row {SELECT COUNT(*) FROM ORDER_LINE} {
    set olCount [lindex $row 0]
}
if {$olCount < 150000 || $olCount > 450000} {
    puts stderr "FAIL: ORDER_LINE count $olCount outside expected range \[150000, 450000\]"
    incr fails
} else {
    puts "OK:   ORDER_LINE = $olCount (within \[150000, 450000\])"
}

$conn close

if {$fails > 0} {
    puts stderr "$fails table(s) failed row-count check"
    exit 3
}
puts "OK: 1-warehouse TPC-C load verified"

# Structured results for actions/upload-artifact + step summary
if {[info exists ::env(FB_RESULTS_OUT)] && $::env(FB_RESULTS_OUT) ne ""} {
    set fd [open $::env(FB_RESULTS_OUT) w]
    puts -nonewline $fd "{\"test\":\"tpcc_load_1w\",\"warehouses\":1,\"order_line_rows\":$olCount,\"row_counts\":{\"WAREHOUSE\":1,\"DISTRICT\":10,\"CUSTOMER\":30000,\"HISTORY\":30000,\"ITEM\":100000,\"STOCK\":100000,\"ORDERS\":30000,\"NEW_ORDER\":9000,\"ORDER_LINE\":$olCount}}"
    close $fd
}
if {[info exists ::env(GITHUB_STEP_SUMMARY)] && $::env(GITHUB_STEP_SUMMARY) ne ""} {
    set md "## TPC-C 1-Warehouse Load\n\n"
    append md "| Table | Rows |\n| --- | ---: |\n"
    append md "| WAREHOUSE | 1 |\n| DISTRICT | 10 |\n| CUSTOMER | 30,000 |\n"
    append md "| HISTORY | 30,000 |\n| ITEM | 100,000 |\n| STOCK | 100,000 |\n"
    append md "| ORDERS | 30,000 |\n| NEW_ORDER | 9,000 |\n| ORDER_LINE | $olCount |\n\n"
    set fd [open $::env(GITHUB_STEP_SUMMARY) a]
    puts $fd $md
    close $fd
}
