#!/bin/tclsh
# Firebird TPROC-C schema build entry point.
#
# Default targets a Firebird Embedded .fdb at $TMP/tpcc.fdb. Override
# fb_dbase to point at a different path (e.g. for a remote server).

if {![info exists ::env(TMP)] || $::env(TMP) eq ""} {
    set ::env(TMP) "[pwd]/TMP"
    file mkdir $::env(TMP)
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

set vu [ numberOfCPUs ]
set warehouse [ expr {$vu * 5} ]
diset tpcc fb_count_ware $warehouse
diset tpcc fb_num_vu $vu
diset tpcc fb_user SYSDBA
diset tpcc fb_pass masterkey
diset tpcc fb_dbase "$tmpdir/tpcc.fdb"
diset tpcc fb_storedprocs false
diset tpcc fb_partition false

puts "SCHEMA BUILD STARTED"
buildschema
puts "SCHEMA BUILD COMPLETED"
