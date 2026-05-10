# Verify the Firebird registration in config/database.xml + firebird.xml.
# Uses HammerDB's own XML::To_Dict parser to mirror what geninit*.tcl do at
# startup, so a parse error here means the GUI/CLI will fail too.
#
# Inputs:
#   HAMMERDB_ROOT - path to the HammerDB repo checkout

set root [string trim $::env(HAMMERDB_ROOT)]
if {$root eq ""} {
    puts stderr "HAMMERDB_ROOT must be set"
    exit 2
}

::tcl::tm::path add [file join $root modules]
package require xml 1.1

set dbdict [::XML::To_Dict [file join $root config database.xml]]
if {![dict exists $dbdict firebird]} {
    puts stderr "FAIL: 'firebird' key missing from database.xml dbdict"
    puts "dbdict keys: [dict keys $dbdict]"
    exit 3
}
foreach field {name description prefix library workloads commands} {
    if {![dict exists $dbdict firebird $field]} {
        puts stderr "FAIL: 'firebird.$field' missing from database.xml"
        exit 3
    }
}
set prefix [dict get $dbdict firebird prefix]
if {$prefix ne "fb"} {
    puts stderr "FAIL: expected prefix=fb, got $prefix"
    exit 3
}

set fbdict [::XML::To_Dict [file join $root config firebird.xml]]
foreach section {connection tpcc tpch} {
    if {![dict exists $fbdict $section]} {
        puts stderr "FAIL: '$section' section missing from firebird.xml"
        exit 3
    }
}
foreach field {fb_host fb_port fb_odbc_driver fb_embedded} {
    if {![dict exists $fbdict connection $field]} {
        puts stderr "FAIL: 'connection.$field' missing from firebird.xml"
        exit 3
    }
}

puts "OK: firebird registered (prefix=[dict get $dbdict firebird prefix],"
puts "    workloads=[dict get $dbdict firebird workloads],"
puts "    library=[dict get $dbdict firebird library])"
puts "    connection.fb_odbc_driver=[dict get $fbdict connection fb_odbc_driver]"
puts "    connection.fb_embedded=[dict get $fbdict connection fb_embedded]"
