#!/bin/tclsh
# Firebird TPROC-C schema build (Python entry point).

import os
tmpdir = os.getenv('TMP') or (os.getcwd() + '/TMP')
os.makedirs(tmpdir, exist_ok=True)

print("SETTING CONFIGURATION")
dbset('db','firebird')
dbset('bm','TPC-C')

diset('connection','fb_host','localhost')
diset('connection','fb_port','3050')
diset('connection','fb_odbc_driver','Firebird ODBC Driver')
diset('connection','fb_charset','UTF8')
diset('connection','fb_embedded','true')

vu = tclpy.eval('numberOfCPUs')
warehouse = int(vu) * 5
diset('tpcc','fb_count_ware',warehouse)
diset('tpcc','fb_num_vu',vu)
diset('tpcc','fb_user','SYSDBA')
diset('tpcc','fb_pass','masterkey')
diset('tpcc','fb_dbase', tmpdir + '/tpcc.fdb')
diset('tpcc','fb_storedprocs','false')
diset('tpcc','fb_partition','false')

print("SCHEMA BUILD STARTED")
buildschema()
print("SCHEMA BUILD COMPLETED")
exit()
