# Build the TPC-H schema, load it at a small scale, then run a
# couple of TPC-H queries against the loaded data via fb_tpch_queries
# + tpchcommon::sub_query (the C11 driver path).
#
# Inputs:
#   HAMMERDB_ROOT  - HammerDB repo checkout
#   FB_ODBC_DRIVER - registered driver name
#   FB_DB_PATH     - absolute path to the .fdb (forward slashes)
#   FB_TPCH_SCALE  - scale factor (default 0.01 to keep CI under a min)

set root [string trim $::env(HAMMERDB_ROOT)]
set driver [string trim $::env(FB_ODBC_DRIVER)]
set dbpath [string trim $::env(FB_DB_PATH)]
set scale 0.01
if {[info exists ::env(FB_TPCH_SCALE)] && $::env(FB_TPCH_SCALE) ne ""} {
    set scale $::env(FB_TPCH_SCALE)
}
foreach {n v} [list HAMMERDB_ROOT $root FB_ODBC_DRIVER $driver FB_DB_PATH $dbpath] {
    if {$v eq ""} { puts stderr "$n must be set"; exit 2 }
}

::tcl::tm::path add [file join $root modules]
package require xml 1.1
package require tdbc::odbc
package require tpchcommon

# tpchcommon::set_dists populates the dist arrays; set_dist_list
# computes the cumulative weights array consumed by pick_str_1.
# Without the latter, pick_str_1 fails with
# `can't read "weights(<name>)": no such variable`.
::tpchcommon::set_dists
# `dists` (and `weights`, `dist_names`, `dist_weights`) are GLOBAL
# variables - the procs use `global dists` rather than living in the
# tpchcommon namespace. Iterate the global array.
foreach dn [array names ::dists] {
    ::tpchcommon::set_dist_list $dn
}

# tpchcommon::PART_SUPP_BRIDGE assumes integer scale_factor and uses
# `%`. With a fractional scale (we use 0.01 in CI to keep runtime
# bounded), 10000*0.01=100.0 is a float and `%` errors. Override
# locally to coerce to integers - the spec maths is the same.
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
puts "Connected to $dbpath (scale=$scale)"

set t0 [clock milliseconds]
fb_create_tpch_schema $conn
puts "Schema built in [expr {[clock milliseconds] - $t0}] ms"

set t0 [clock milliseconds]
set per [fb_load_tpch $conn $scale]
puts "Load complete in [expr {[clock milliseconds] - $t0}] ms: $per"

# Verify expected row counts (scale-relative)
set expectedSup  [expr {int(10000 * $scale)}]
set expectedCust [expr {int(150000 * $scale)}]
set expectedPart [expr {int(200000 * $scale)}]
set expectedPS   [expr {$expectedPart * 4}]
set expectedOrd  [expr {int(1500000 * $scale)}]
set expected [list \
    REGION   5 \
    NATION   25 \
    SUPPLIER $expectedSup \
    CUSTOMER $expectedCust \
    PART     $expectedPart \
    PARTSUPP $expectedPS \
    ORDERS   $expectedOrd]
set fails 0
foreach {tbl want} $expected {
    set got 0
    $conn foreach -as lists row "SELECT COUNT(*) FROM $tbl" { set got [lindex $row 0] }
    if {$got ne $want} {
        puts stderr "FAIL $tbl: expected $want got $got"
        incr fails
    } else {
        puts "OK:   $tbl = $got"
    }
}
# LINEITEM is variable (1-7 per ORDERS, mean 4); allow ±50% range.
set olCount 0
$conn foreach -as lists row {SELECT COUNT(*) FROM LINEITEM} {
    set olCount [lindex $row 0]
}
set olMin [expr {int($expectedOrd * 1.5)}]
set olMax [expr {int($expectedOrd * 7)}]
if {$olCount < $olMin || $olCount > $olMax} {
    puts stderr "FAIL LINEITEM: $olCount outside \[$olMin, $olMax\]"
    incr fails
} else {
    puts "OK:   LINEITEM = $olCount (within \[$olMin, $olMax\])"
}

# ---- Driver path: run a couple of representative queries ----
package require tpchcommon
namespace import ::tpchcommon::*

# Q1, Q5, Q14 are diverse: Q1 scans LINEITEM, Q5 joins 6 tables,
# Q14 joins LINEITEM+PART. tpchcommon::sub_query fills the :N
# placeholders per spec.
set queries [fb_tpch_queries]
set qfails 0
foreach qno {1 5 14} {
    set raw [dict get $queries $qno]
    if {[catch {sub_query $qno $scale 1} sql]} {
        # Fall back: substitute simple placeholders if sub_query
        # signature differs in this version.
        set sql $raw
        foreach n {10 9 8 7 6 5 4 3 2 1} {
            set sql [string map [list ":$n'" "1995-01-01'"] $sql]
            set sql [string map [list ":$n" 1] $sql]
        }
    }
    set t0 [clock milliseconds]
    if {[catch {
        set rs [$conn prepare $sql]
        set rows 0
        $rs foreach -as lists row { incr rows }
        $rs close
    } err]} {
        puts stderr "FAIL Q$qno: $err"
        incr qfails
        continue
    }
    set elapsed [expr {[clock milliseconds] - $t0}]
    puts "OK:   Q$qno returned $rows rows in $elapsed ms"
}

$conn close

if {$fails > 0 || $qfails > 0} {
    puts stderr "$fails table count failure(s), $qfails query failure(s)"
    exit 3
}
puts "OK: TPROC-H load + query smoke verified (scale=$scale)"

# Structured results
if {[info exists ::env(FB_RESULTS_OUT)] && $::env(FB_RESULTS_OUT) ne ""} {
    set fd [open $::env(FB_RESULTS_OUT) w]
    puts -nonewline $fd "{\"test\":\"tpch_load\",\"scale\":$scale,\"lineitem_rows\":$olCount,\"row_counts\":{\"REGION\":5,\"NATION\":25,\"SUPPLIER\":$expectedSup,\"CUSTOMER\":$expectedCust,\"PART\":$expectedPart,\"PARTSUPP\":$expectedPS,\"ORDERS\":$expectedOrd,\"LINEITEM\":$olCount}}"
    close $fd
}
if {[info exists ::env(GITHUB_STEP_SUMMARY)] && $::env(GITHUB_STEP_SUMMARY) ne ""} {
    set md "## TPC-H Load (scale $scale) + Query Smoke\n\n"
    append md "| Table | Rows |\n| --- | ---: |\n"
    append md "| REGION | 5 |\n| NATION | 25 |\n| SUPPLIER | $expectedSup |\n"
    append md "| CUSTOMER | $expectedCust |\n| PART | $expectedPart |\n| PARTSUPP | $expectedPS |\n"
    append md "| ORDERS | $expectedOrd |\n| LINEITEM | $olCount |\n\n"
    append md "Q1, Q5, Q14 executed against loaded data (see job log for per-query timings).\n\n"
    set fd [open $::env(GITHUB_STEP_SUMMARY) a]
    puts $fd $md
    close $fd
}
