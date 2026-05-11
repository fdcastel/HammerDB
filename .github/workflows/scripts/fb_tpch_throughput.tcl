# TPC-H multi-VU throughput test driver.
#
# Spawns N Tcl threads that each connect to a running Firebird server
# (started by the workflow via PSFirebird's Start-FirebirdInstance)
# over inet:// and run their own permuted ordering of the 22 queries
# (`tpchcommon::ordered_set $myposition`). One additional thread runs
# RF1+RF2 refresh pairs continuously until all query streams finish.
#
# Embedded mode is single-process; this test requires server mode.
#
# Inputs:
#   HAMMERDB_ROOT       - HammerDB repo checkout
#   FB_ODBC_DRIVER      - registered driver name
#   FB_TPCH_SERVER_HOST - host (usually localhost)
#   FB_TPCH_SERVER_PORT - port (default 3050)
#   FB_TPCH_DBPATH      - absolute path to the loaded .fdb (Windows-style)
#   FB_TPCH_STREAMS     - number of query streams (default 2)
#   FB_TPCH_SCALE       - scale factor (default 0.01)
#   FB_TPCH_RESULTS_OUT - JSON output path for actions/upload-artifact
#   GITHUB_STEP_SUMMARY - if set, write a Markdown summary

set root [string trim $::env(HAMMERDB_ROOT)]
set driver [string trim $::env(FB_ODBC_DRIVER)]
set host [string trim $::env(FB_TPCH_SERVER_HOST)]
set port [string trim $::env(FB_TPCH_SERVER_PORT)]
set dbpath [string trim $::env(FB_TPCH_DBPATH)]
set num_streams 2
if {[info exists ::env(FB_TPCH_STREAMS)]} { set num_streams $::env(FB_TPCH_STREAMS) }
set scale 0.01
if {[info exists ::env(FB_TPCH_SCALE)]} { set scale $::env(FB_TPCH_SCALE) }
set results_out ""
if {[info exists ::env(FB_TPCH_RESULTS_OUT)]} { set results_out $::env(FB_TPCH_RESULTS_OUT) }
foreach {n v} [list HAMMERDB_ROOT $root FB_ODBC_DRIVER $driver \
        FB_TPCH_SERVER_HOST $host FB_TPCH_SERVER_PORT $port FB_TPCH_DBPATH $dbpath] {
    if {$v eq ""} { puts stderr "$n must be set"; exit 2 }
}

::tcl::tm::path add [file join $root modules]
package require Thread
package require xml 1.1
package require tdbc::odbc
package require tpchcommon

::tpchcommon::set_dists
foreach dn [array names ::dists] {
    ::tpchcommon::set_dist_list $dn
}
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

# Server-mode connection string. fb_build_connstr handles the
# host/port:path formatting when fb_embedded=false; pass it the raw
# .fdb path.
set connstr [fb_build_connstr $driver false $host $port $dbpath SYSDBA masterkey UTF8]
puts "Connection string template: [string map [list masterkey ***] $connstr]"

# Sanity-check the master can talk to the server.
set conn [tdbc::odbc::connection new $connstr]
$conn allrows {SELECT 1 AS one FROM RDB$DATABASE}
$conn close
puts "Server reachable on $host:$port"

# tsv stop flag for the refresh loop.
tsv::set application throughput_stop 0

# Build the worker init script that each thread runs once on creation.
# It sources the firebird modules + sets up tpchcommon dists with the
# fractional-scale PART_SUPP_BRIDGE override, the same way the master
# did above. Variables are passed in via [list ...] interpolation.
set worker_init [list \
    apply {{root} {
        ::tcl::tm::path add [file join $root modules]
        package require tdbc::odbc
        package require xml 1.1
        package require tpchcommon
        ::tpchcommon::set_dists
        foreach dn [array names ::dists] {
            ::tpchcommon::set_dist_list $dn
        }
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
    }} $root]

# Spawn refresh thread.
set refresh_tid [thread::create]
thread::send $refresh_tid $worker_init
thread::send -async $refresh_tid \
    [list apply {{connstr scale} {
        package require tdbc::odbc
        set conn [tdbc::odbc::connection new $connstr]
        set result [fb_tpch_refresh_loop $conn $scale 1 throughput_stop]
        $conn close
        tsv::set application refresh_result $result
    }} $connstr $scale]

# Spawn N query stream threads.
set qtids [list]
for {set i 1} {$i <= $num_streams} {incr i} {
    set t [thread::create]
    thread::send $t $worker_init
    lappend qtids $t
}

# Kick off all query streams in parallel. Each stream writes its result
# into a tsv slot keyed by stream position.
set start_ms [clock milliseconds]
set positions [list]
for {set i 0} {$i < [llength $qtids]} {incr i} {
    set tid [lindex $qtids $i]
    # Use positions 1..N (ordered_set 0 is the power-test default; we
    # leave it for the standalone power test).
    set pos [expr {$i + 1}]
    lappend positions $pos
    tsv::set application stream_done_$pos 0
    thread::send -async $tid \
        [list apply {{connstr scale pos} {
            package require tdbc::odbc
            set conn [tdbc::odbc::connection new $connstr]
            set result [fb_tpch_query_stream $conn $scale $pos false]
            $conn close
            tsv::set application stream_result_$pos $result
            tsv::set application stream_done_$pos 1
        }} $connstr $scale $pos]
}

# Wait for all query streams to finish (tsv-poll).
foreach pos $positions {
    while {![tsv::get application stream_done_$pos]} {
        after 200
    }
}
set total_ms [expr {[clock milliseconds] - $start_ms}]

# Tell the refresh loop to stop and wait briefly.
tsv::set application throughput_stop 1
set wait_attempts 0
while {![tsv::exists application refresh_result] && $wait_attempts < 100} {
    after 100
    incr wait_attempts
}

# Collect per-stream results.
set per_stream [list]
foreach pos $positions {
    if {[tsv::exists application stream_result_$pos]} {
        lappend per_stream [tsv::get application stream_result_$pos]
    }
}
set refresh_pairs 0
set last_upd 0
if {[tsv::exists application refresh_result]} {
    set rd [tsv::get application refresh_result]
    set refresh_pairs [dict get $rd pairs_completed]
    set last_upd [dict get $rd last_upd_num]
}

# Cleanup threads.
foreach tid [concat $qtids $refresh_tid] {
    catch {thread::release -wait $tid}
}

# Aggregate metrics.
set gmeans [list]
foreach r $per_stream { lappend gmeans [dict get $r gmean_ms] }
set total_queries 0
set total_with_rows 0
foreach r $per_stream {
    incr total_queries 22
    incr total_with_rows [dict get $r queries_with_rows]
}
# Throughput-per-stream: queries that returned rows / total elapsed seconds.
set elapsed_sec [expr {$total_ms / 1000.0}]
set qph [expr {$elapsed_sec > 0 ? ($total_with_rows * 3600.0) / $elapsed_sec : 0}]

puts ""
puts "==== TPROC-H Throughput Test ===="
puts "Streams:        $num_streams"
puts "Scale:          $scale"
puts "Elapsed:        ${total_ms} ms ([format %.2f $elapsed_sec] s)"
puts "Refresh pairs:  $refresh_pairs (last upd_num=$last_upd)"
puts "Queries / hour: [format %.1f $qph]  (returned-rows queries across all streams)"
foreach r $per_stream {
    set p [dict get $r myposition]
    set g [dict get $r gmean_ms]
    set wr [dict get $r queries_with_rows]
    puts "  Stream $p: ${wr}/22 queries returned rows, gmean=[format %.1f $g] ms"
}

# Emit JSON for the upload-artifact step.
proc as_json_dict {d} {
    set parts [list]
    dict for {k v} $d {
        if {[string is integer -strict $v]} {
            lappend parts "\"$k\":$v"
        } elseif {[string is double -strict $v]} {
            lappend parts "\"$k\":$v"
        } else {
            lappend parts "\"$k\":\"[string map {\\ \\\\ \" \\\"} $v]\""
        }
    }
    return "{[join $parts ,]}"
}
proc as_json_inner {d} {
    # Used for nested per-stream dicts that contain qtimes/qrows dicts
    # as values. Keep it simple: stringify nested dicts.
    set parts [list]
    dict for {k v} $d {
        set sv [string map {\\ \\\\ \" \\\"} $v]
        lappend parts "\"$k\":\"$sv\""
    }
    return "{[join $parts ,]}"
}

set streams_json [list]
foreach r $per_stream {
    lappend streams_json [as_json_inner $r]
}
set json "{\"streams\":$num_streams,\"scale\":$scale,\"elapsed_ms\":$total_ms,\"refresh_pairs\":$refresh_pairs,\"queries_per_hour\":[format %.2f $qph],\"per_stream\":\[[join $streams_json ,]\]}"

if {$results_out ne ""} {
    set fd [open $results_out w]
    puts -nonewline $fd $json
    close $fd
    puts "Wrote results JSON to $results_out"
}

# Emit Markdown summary for the GitHub Actions run page.
if {[info exists ::env(GITHUB_STEP_SUMMARY)] && $::env(GITHUB_STEP_SUMMARY) ne ""} {
    set md "## TPROC-H Throughput Test\n\n"
    append md "| Metric | Value |\n| --- | --- |\n"
    append md "| Streams | $num_streams |\n"
    append md "| Scale factor | $scale |\n"
    append md "| Elapsed | [format %.2f $elapsed_sec] s |\n"
    append md "| Refresh pairs (RF1/RF2) | $refresh_pairs |\n"
    append md "| Queries/hour (returning rows) | [format %.1f $qph] |\n\n"
    append md "### Per-stream results\n\n"
    append md "| Stream | Queries with rows | Geometric mean (ms) |\n| --- | --- | --- |\n"
    foreach r $per_stream {
        append md "| [dict get $r myposition] | [dict get $r queries_with_rows]/22 | [format %.1f [dict get $r gmean_ms]] |\n"
    }
    set fd [open $::env(GITHUB_STEP_SUMMARY) a]
    puts $fd $md
    close $fd
}

# Assertions
set fails 0
if {$num_streams != [llength $per_stream]} {
    puts stderr "FAIL: expected $num_streams stream results, got [llength $per_stream]"
    incr fails
}
if {$refresh_pairs == 0} {
    puts stderr "FAIL: refresh stream completed zero RF1/RF2 pairs"
    incr fails
}
foreach r $per_stream {
    if {[dict get $r queries_with_rows] == 0} {
        puts stderr "FAIL: stream [dict get $r myposition] returned zero rows from any query"
        incr fails
    }
}

if {$fails > 0} {
    puts stderr "$fails throughput-test assertion(s) failed"
    exit 3
}
puts "OK: TPROC-H throughput test verified"
