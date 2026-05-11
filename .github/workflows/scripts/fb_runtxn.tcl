# Run a small number of TPC-C transactions against the loaded
# embedded database, exercising the 5 client-side driver procs at
# the standard mix ratio (10/10/1/1/1 out of 23 = NewOrder, Payment,
# Delivery, OrderStatus, StockLevel).
#
# Inputs:
#   HAMMERDB_ROOT  - HammerDB repo checkout
#   FB_ODBC_DRIVER - registered driver name
#   FB_DB_PATH     - path to the .fdb that already has 1 warehouse loaded
#   FB_TXN_COUNT   - how many transactions to run (default 200)

set root [string trim $::env(HAMMERDB_ROOT)]
set driver [string trim $::env(FB_ODBC_DRIVER)]
set dbpath [string trim $::env(FB_DB_PATH)]
set count [expr {[info exists ::env(FB_TXN_COUNT)] ? $::env(FB_TXN_COUNT) : 200}]
foreach {n v} [list HAMMERDB_ROOT $root FB_ODBC_DRIVER $driver FB_DB_PATH $dbpath] {
    if {$v eq ""} { puts stderr "$n must be set"; exit 2 }
}

::tcl::tm::path add [file join $root modules]
package require xml 1.1
package require tdbc::odbc
package require tpcccommon
namespace import ::tpcccommon::*

set ::dbdict [::XML::To_Dict [file join $root config database.xml]]
set ::configfirebird [::XML::To_Dict [file join $root config firebird.xml]]
foreach f {fbci.tcl fbmet.tcl fbotc.tcl fbopt.tcl fboltp.tcl fbolap.tcl} {
    source [file join $root src firebird $f]
}

set conn [ConnectToFirebird $driver true "" "" $dbpath SYSDBA "" UTF8]
puts "Connected to $dbpath"

# Counters
set counts [dict create neword 0 payment 0 delivery 0 ostat 0 slev 0]
set failures 0
set t0 [clock milliseconds]

for {set i 0} {$i < $count} {incr i} {
    set choice [RandomNumber 1 23]
    if {$choice <= 10} {
        set name neword
        set ok [neword $conn 1 1 false false]
    } elseif {$choice <= 20} {
        set name payment
        set ok [payment $conn 1 1 false false]
    } elseif {$choice <= 21} {
        set name delivery
        set ok [delivery $conn 1 false false]
    } elseif {$choice <= 22} {
        set name ostat
        set ok [ostat $conn 1 false false]
    } else {
        set name slev
        set ok [slev $conn 1 [RandomNumber 1 10] false false]
    }
    dict incr counts $name
    if {!$ok} { incr failures }
}
set elapsed [expr {[clock milliseconds] - $t0}]
$conn close

puts "Ran $count transactions in $elapsed ms"
puts "Mix: $counts"
puts "Failures: $failures (of $count)"

# Per TPC-C spec, ~1% of NewOrder transactions intentionally
# rollback (invalid item id 100001 when rbk == 1). Payment/OrderStatus
# by-name lookups can also legitimately match zero customers depending
# on random NURand distribution. Allow up to 5% rollback rate.
set thresh [expr {int($count * 0.05)}]
if {$failures > $thresh} {
    puts stderr "FAIL: $failures rollbacks exceed 5% threshold ($thresh)"
    exit 3
}
if {[dict get $counts neword] == 0} {
    puts stderr "FAIL: no NewOrder transactions ran"
    exit 3
}
puts "OK: client-side TPC-C driver procs verified ($failures rollbacks within 5% threshold)"
