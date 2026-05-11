#!/bin/tclsh
# CI-only hammerdbcli script. Builds a 1-warehouse TPROC-C schema
# against an embedded Firebird .fdb (path from the FB_DBASE env var,
# falls back to /tmp/tpcc.fdb).
#
# Validates that the user-facing hammerdbcli surface (dbset/diset/
# buildschema with the firebird db) works end-to-end inside an
# overlayed HammerDB installation.

set fbDb "/tmp/tpcc.fdb"
if {[info exists ::env(FB_DBASE)] && $::env(FB_DBASE) ne ""} {
    set fbDb $::env(FB_DBASE)
}

puts "SETTING CONFIGURATION (CI: 1 warehouse, 1 VU, fbDb=$fbDb)"
dbset db firebird
dbset bm TPC-C

diset connection fb_host localhost
diset connection fb_port 3050
diset connection fb_odbc_driver "Firebird ODBC Driver"
diset connection fb_charset UTF8
diset connection fb_embedded true

diset tpcc fb_count_ware 1
diset tpcc fb_num_vu 1
diset tpcc fb_user SYSDBA
diset tpcc fb_pass masterkey
diset tpcc fb_dbase $fbDb
diset tpcc fb_storedprocs false
diset tpcc fb_partition false

puts "SCHEMA BUILD STARTED"
if {[catch {buildschema} err]} {
    puts stderr "buildschema raised: $err"
    exit 3
}
puts "SCHEMA BUILD COMPLETED"
