#!/bin/tclsh
import os
tmpdir = os.getenv('TMP') or (os.getcwd() + '/TMP')

dbset('db','firebird')
dbset('bm','TPC-C')

diset('connection','fb_host','localhost')
diset('connection','fb_port','3050')
diset('connection','fb_odbc_driver','Firebird ODBC Driver')
diset('connection','fb_charset','UTF8')
diset('connection','fb_embedded','true')

diset('tpcc','fb_user','SYSDBA')
diset('tpcc','fb_pass','masterkey')
diset('tpcc','fb_dbase', tmpdir + '/tpcc.fdb')

print("CHECK SCHEMA STARTED")
checkschema()
print("CHECK SCHEMA COMPLETED")
exit()
