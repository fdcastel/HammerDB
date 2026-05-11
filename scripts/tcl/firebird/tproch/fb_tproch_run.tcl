#!/bin/tclsh
if {![info exists ::env(TMP)] || $::env(TMP) eq ""} {
    set ::env(TMP) "[pwd]/TMP"
}
set tmpdir $::env(TMP)

puts "SETTING CONFIGURATION"
dbset db firebird
dbset bm TPC-H

diset connection fb_host localhost
diset connection fb_port 3050
diset connection fb_odbc_driver "Firebird ODBC Driver"
diset connection fb_charset UTF8
diset connection fb_embedded true

diset tpch fb_scale_fact 1
diset tpch fb_tpch_user SYSDBA
diset tpch fb_tpch_pass masterkey
diset tpch fb_tpch_dbase "$tmpdir/tpch.fdb"
diset tpch fb_total_querysets 1

loadscript
puts "TEST STARTED"
vuset vu 1
vucreate
set jobid [ vurun ]
vudestroy
puts "TEST COMPLETE"
set of [ open $tmpdir/fb_tproch w ]
puts $of $jobid
close $of
