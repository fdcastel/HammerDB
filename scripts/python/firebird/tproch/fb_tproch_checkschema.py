#!/bin/tclsh
import os
tmpdir = os.getenv('TMP') or (os.getcwd() + '/TMP')

dbset('db','firebird')
dbset('bm','TPC-H')

diset('connection','fb_host','localhost')
diset('connection','fb_port','3050')
diset('connection','fb_odbc_driver','Firebird ODBC Driver')
diset('connection','fb_charset','UTF8')
diset('connection','fb_embedded','true')

diset('tpch','fb_tpch_user','SYSDBA')
diset('tpch','fb_tpch_pass','masterkey')
diset('tpch','fb_tpch_dbase', tmpdir + '/tpch.fdb')

print("CHECK SCHEMA STARTED")
checkschema()
print("CHECK SCHEMA COMPLETED")
exit()
