# Source-load every src/firebird/*.tcl file and report which procs
# each one defines. A clean exit means the modules at least parse and
# their top-level commands run without raising.
#
# Inputs:
#   HAMMERDB_ROOT - path to the HammerDB repo checkout

set root [string trim $::env(HAMMERDB_ROOT)]
if {$root eq ""} {
    puts stderr "HAMMERDB_ROOT must be set"
    exit 2
}
set fbdir [file join $root src firebird]

# Make the same modules HammerDB ships available so things like
# 'package require xml 1.1' resolve when the firebird modules need
# them later.
::tcl::tm::path add [file join $root modules]

# Load minimum config that fboltp.tcl/fbolap.tcl will need at top
# level once they grow: the dbdict that database.xml is parsed into.
package require xml 1.1
set ::dbdict [::XML::To_Dict [file join $root config database.xml]]
set ::configfirebird [::XML::To_Dict [file join $root config firebird.xml]]

set order {fbci.tcl fbmet.tcl fbotc.tcl fbopt.tcl fboltp.tcl fbolap.tcl}
set failures 0
foreach f $order {
    set path [file join $fbdir $f]
    if {![file exists $path]} {
        puts stderr "FAIL: missing $path"
        incr failures
        continue
    }
    set before [info procs]
    if {[catch {source $path} err]} {
        puts stderr "FAIL: sourcing $f: $err"
        incr failures
        continue
    }
    set after [info procs]
    set added [list]
    foreach p $after { if {$p ni $before} { lappend added $p } }
    puts "OK: [file tail $f] (defines: [lsort $added])"
}

if {$failures > 0} {
    puts stderr "$failures module(s) failed to load"
    exit 3
}
puts "OK: all [llength $order] firebird modules sourced cleanly"
