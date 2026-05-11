# Run a full TPROC-H power test: RF1 → 22 queries (in spec order) →
# RF2. Reports per-query timing, geometric mean, and refresh-stream
# counts. Asserts:
#   - RF1 inserted SF*1500 orders
#   - RF2 deleted the same orders (round-trip)
#   - All 22 queries executed (rows >= 0); at least one returned > 0
#   - Geometric mean is positive
#
# Inputs:
#   HAMMERDB_ROOT  - HammerDB repo checkout
#   FB_ODBC_DRIVER - registered driver name
#   FB_DB_PATH     - .fdb with TPC-H schema + scale-0.01 data already loaded

set root [string trim $::env(HAMMERDB_ROOT)]
set driver [string trim $::env(FB_ODBC_DRIVER)]
set dbpath [string trim $::env(FB_DB_PATH)]
foreach {n v} [list HAMMERDB_ROOT $root FB_ODBC_DRIVER $driver FB_DB_PATH $dbpath] {
    if {$v eq ""} { puts stderr "$n must be set"; exit 2 }
}

::tcl::tm::path add [file join $root modules]
package require xml 1.1
package require tdbc::odbc
package require tpchcommon

::tpchcommon::set_dists
foreach dn [array names ::dists] {
    ::tpchcommon::set_dist_list $dn
}
# Same fractional-scale workaround as fb_tpch_load.tcl.
proc ::tpchcommon::PART_SUPP_BRIDGE { p s scale_factor } {
    set tot_scnt [expr {int(10000 * $scale_factor)}]
    if {$tot_scnt < 1} { set tot_scnt 1 }
    return [expr {(int($p) + int($s) * ($tot_scnt / 4 + (int($p) - 1) / $tot_scnt)) % $tot_scnt + 1}]
}

set ::dbdict [::XML::To_Dict [file join $root config database.xml]]
set ::configfirebird [::XML::To_Dict [file join $root config firebird.xml]]
foreach f {fbci.tcl fbmet.tcl fbotc.tcl fbopt.tcl fboltp.tcl fbolap.tcl} {
    source [file join $root src firebird $f]
}

set conn [ConnectToFirebird $driver true "" "" $dbpath SYSDBA "" UTF8]
puts "Connected to $dbpath"

# Confirm the .fdb has the schema + data we expect.
set rows 0
$conn foreach -as lists row {SELECT COUNT(*) FROM ORDERS} { set rows [lindex $row 0] }
if {$rows == 0} {
    puts stderr "FAIL: ORDERS is empty - power test needs a loaded .fdb"
    $conn close
    exit 3
}
puts "Pre-test ORDERS count: $rows"

set scale 0.01
set t0 [clock milliseconds]
set result [fb_tpch_power_test $conn $scale 0 true]
set total [expr {[clock milliseconds] - $t0}]
puts "Power test elapsed: $total ms"
puts "  RF1: [dict get $result rf1_rows] rows in [dict get $result rf1_ms] ms"
puts "  RF2: [dict get $result rf2_rows] rows in [dict get $result rf2_ms] ms"
puts "  Queries returning rows: [dict get $result queries_with_rows]/22"
puts "  Geometric mean (ms): [format {%.2f} [dict get $result gmean_ms]]"
puts "  Per-query times: [dict get $result query_times_ms]"
puts "  Per-query rows:  [dict get $result query_rows]"

set fails 0
set sfrows [expr {int($scale * 1500)}]
if {$sfrows < 1} { set sfrows 1 }
if {[dict get $result rf1_rows] != $sfrows} {
    puts stderr "FAIL RF1: expected $sfrows orders inserted, got [dict get $result rf1_rows]"
    incr fails
}
if {[dict get $result rf2_rows] != $sfrows} {
    puts stderr "FAIL RF2: expected $sfrows orders deleted, got [dict get $result rf2_rows]"
    incr fails
}
# Confirm RF1+RF2 round-tripped: post-test ORDERS count == pre-test
set rows2 0
$conn foreach -as lists row {SELECT COUNT(*) FROM ORDERS} { set rows2 [lindex $row 0] }
if {$rows2 != $rows} {
    puts stderr "FAIL: ORDERS count drifted: pre=$rows post=$rows2"
    incr fails
} else {
    puts "OK: ORDERS round-tripped ($rows == $rows2)"
}
# Sanity: gmean must be positive and at least one query must return rows
if {[dict get $result queries_with_rows] < 1} {
    puts stderr "FAIL: zero queries returned rows"
    incr fails
}
if {[dict get $result gmean_ms] <= 0} {
    puts stderr "FAIL: gmean <= 0"
    incr fails
}
# Detect query failures (rows = -1 from the runner)
dict for {qno r} [dict get $result query_rows] {
    if {$r < 0} {
        puts stderr "FAIL: Q$qno raised an exception"
        incr fails
    }
}

$conn close
if {$fails > 0} {
    puts stderr "$fails power-test assertion(s) failed"
    exit 3
}
puts "OK: TPROC-H power test verified"
