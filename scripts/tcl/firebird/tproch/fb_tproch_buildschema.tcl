#!/bin/tclsh
# Firebird TPROC-H schema build entry point.

if {![info exists ::env(TMP)] || $::env(TMP) eq ""} {
    set ::env(TMP) "[pwd]/TMP"
    file mkdir $::env(TMP)
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
diset tpch fb_num_tpch_threads [ numberOfCPUs ]
diset tpch fb_tpch_user SYSDBA
diset tpch fb_tpch_pass masterkey
diset tpch fb_tpch_dbase "$tmpdir/tpch.fdb"

puts "SCHEMA BUILD STARTED"
buildschema
puts "SCHEMA BUILD COMPLETED"
