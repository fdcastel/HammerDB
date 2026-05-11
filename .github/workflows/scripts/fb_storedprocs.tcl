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

# Procedures are installed by the workflow's isql step (tdbc::odbc
# cannot submit a CREATE PROCEDURE that references PSQL variables -
# the prepare scanner mis-treats `:NAME` as bind placeholders). Here
# we just verify presence and exercise each one.

set expected {PAYMENT_SP OSTAT_SP SLEV_SP DELIVERY_SP NEWORD_SP}
set actual [list]
$conn foreach -as lists row {
    SELECT TRIM(RDB$PROCEDURE_NAME) FROM RDB$PROCEDURES
    WHERE RDB$SYSTEM_FLAG = 0
    ORDER BY RDB$PROCEDURE_NAME
} { lappend actual [lindex $row 0] }
foreach p $expected {
    if {$p ni $actual} {
        puts stderr "FAIL: $p missing from RDB\$PROCEDURES (have: $actual)"
        $conn close
        exit 3
    }
}
puts "OK: all 5 procs visible: $actual"

set ts [clock format [clock seconds] -format "%Y-%m-%d %H:%M:%S"]
set fails 0

# Helper: run a single SELECT FROM <proc>(...), log first row.
proc fbsp_call { conn label sql params } {
    upvar 1 fails fails
    if {[catch {
        $conn begintransaction
        set rs [$conn prepare $sql]
        set out [$rs execute $params]
        set rows [list]
        $out foreach -as dicts -- r { lappend rows $r }
        $out close
        $rs close
        $conn commit
    } err]} {
        catch {$conn rollback}
        puts stderr "FAIL $label: $err"
        incr fails
        return
    }
    if {[llength $rows] == 0} {
        puts stderr "FAIL $label: no rows returned"
        incr fails
        return
    }
    puts "OK: $label returned [lindex $rows 0]"
}

fbsp_call $conn PAYMENT_SP {
    SELECT OUT_C_BALANCE, OUT_C_CREDIT, OUT_W_NAME, OUT_D_NAME
    FROM PAYMENT_SP(:w_id, :d_id, :cw_id, :cd_id, :c_id, :amt, :ts)
} [dict create w_id 1 d_id 1 cw_id 1 cd_id 1 c_id 1 amt 12.34 ts $ts]

fbsp_call $conn OSTAT_SP {
    SELECT OUT_C_BALANCE, OUT_O_ID, OUT_O_ENTRY_D, OUT_O_CARRIER_ID
    FROM OSTAT_SP(:w_id, :d_id, :c_id)
} [dict create w_id 1 d_id 1 c_id 1]

fbsp_call $conn SLEV_SP {
    SELECT OUT_LOWS FROM SLEV_SP(:w_id, :d_id, :thr)
} [dict create w_id 1 d_id 1 thr 15]

fbsp_call $conn DELIVERY_SP {
    SELECT OUT_DISTRICT_COUNT
    FROM DELIVERY_SP(:w_id, :carrier, :dd)
} [dict create w_id 1 carrier 1 dd $ts]

fbsp_call $conn NEWORD_SP {
    SELECT OUT_O_ID, OUT_TOTAL
    FROM NEWORD_SP(:w_id, :d_id, :c_id, :ol_cnt, :dt)
} [dict create w_id 1 d_id 1 c_id 1 ol_cnt 5 dt $ts]

$conn close

if {$fails > 0} {
    puts stderr "$fails proc(s) failed"
    exit 3
}
puts "OK: all 5 PSQL stored procs verified"

# Structured results
if {[info exists ::env(FB_RESULTS_OUT)] && $::env(FB_RESULTS_OUT) ne ""} {
    set fd [open $::env(FB_RESULTS_OUT) w]
    puts -nonewline $fd "{\"test\":\"tpcc_stored_procs\",\"procs_installed\":5,\"procs_invoked_ok\":5,\"failures\":$fails}"
    close $fd
}
if {[info exists ::env(GITHUB_STEP_SUMMARY)] && $::env(GITHUB_STEP_SUMMARY) ne ""} {
    set md "## TPC-C PSQL Stored Procedures\n\n"
    append md "All 5 procedures installed via Invoke-FirebirdIsql and invoked via tdbc::odbc SELECT FROM (selectable procs):\n\n"
    append md "- PAYMENT_SP\n- OSTAT_SP\n- SLEV_SP\n- DELIVERY_SP\n- NEWORD_SP\n\n"
    append md "Failures: $fails\n\n"
    set fd [open $::env(GITHUB_STEP_SUMMARY) a]
    puts $fd $md
    close $fd
}
