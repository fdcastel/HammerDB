# Verify the 22 TPC-H queries are present in fb_tpch_queries and that
# the 21 single-statement queries can be PREPAREd against an empty
# Firebird TPC-H schema. Q15 is multi-statement (view + select + drop)
# and is checked separately.
#
# PREPARE-only validation: catches SQL syntax errors and column-name
# mismatches without needing actual data. Parameters (`:1`, `:2`, ...)
# in the query templates are substitution slots, not tdbc named params,
# so we replace them with safe defaults before preparing.
#
# Inputs:
#   HAMMERDB_ROOT  - HammerDB repo checkout
#   FB_ODBC_DRIVER - registered driver name
#   FB_DB_PATH     - .fdb with the TPC-H schema already built

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

set queries [fb_tpch_queries]
if {[dict size $queries] != 22} {
    puts stderr "FAIL: expected 22 queries, got [dict size $queries]"
    exit 3
}
puts "OK: 22 queries present"

# Substitute :N placeholders + the special :VID token (q15) with
# concrete safe values so PREPARE will parse them.
proc sub_placeholders { sql {vid 1} } {
    set sql [string map [list :VID $vid] $sql]
    # Replace :1..:10 with literal values that fit common contexts
    # (numeric or string-quoted in the original template).
    foreach n {1 2 3 4 5 6 7 8 9 10} {
        set sql [regsub -all ":$n\\b" $sql 1]
    }
    return $sql
}

set conn [ConnectToFirebird $driver true "" "" $dbpath SYSDBA "" UTF8]
puts "Connected to $dbpath"

set fails 0
dict for {qno raw} $queries {
    if {$qno == 15} {
        # Q15: view + select + drop. Split on `;`, prepare each piece
        # independently, then drop the view if it survived.
        set parts [split [sub_placeholders $raw 9999] ";"]
        set partOk 0
        foreach p $parts {
            set p [string trim $p]
            if {$p eq ""} { continue }
            if {[catch {set s [$conn prepare $p]; $s close} err]} {
                puts stderr "FAIL Q15 part '[string range $p 0 60]...': $err"
                incr fails
                break
            }
            incr partOk
        }
        if {$partOk == 3} { puts "OK: Q15 (3 parts prepared)" }
        # Best-effort cleanup
        catch {$conn allrows {DROP VIEW REVENUE9999}}
        continue
    }
    set sql [sub_placeholders $raw]
    if {[catch {set s [$conn prepare $sql]; $s close} err]} {
        puts stderr "FAIL Q$qno: $err"
        puts stderr "  SQL: [string range $sql 0 100]..."
        incr fails
    } else {
        puts "OK: Q$qno prepared"
    }
}
$conn close

if {$fails > 0} {
    puts stderr "$fails query/queries failed PREPARE"
    exit 3
}
puts "OK: all 22 TPC-H queries prepared cleanly"
