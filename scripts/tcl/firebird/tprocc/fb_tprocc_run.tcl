#!/bin/tclsh
# Run a timed Firebird TPROC-C workload against an already-built
# embedded schema.

if {![info exists ::env(TMP)] || $::env(TMP) eq ""} {
    set ::env(TMP) "[pwd]/TMP"
}
set tmpdir $::env(TMP)

puts "SETTING CONFIGURATION"
dbset db firebird
dbset bm TPC-C

diset connection fb_host localhost
diset connection fb_port 3050
diset connection fb_odbc_driver "Firebird ODBC Driver"
diset connection fb_charset UTF8
diset connection fb_embedded true

diset tpcc fb_user SYSDBA
diset tpcc fb_pass masterkey
diset tpcc fb_dbase "$tmpdir/tpcc.fdb"
diset tpcc fb_driver timed
diset tpcc fb_total_iterations 10000000
diset tpcc fb_rampup 2
diset tpcc fb_duration 5
diset tpcc fb_timeprofile true
diset tpcc fb_allwarehouse true

loadscript
puts "TEST STARTED"
vuset vu vcpu
vucreate
tcstart
tcstatus
set jobid [ vurun ]
vudestroy
tcstop
puts "TEST COMPLETE"
set of [ open $tmpdir/fb_tprocc w ]
puts $of $jobid
close $of
