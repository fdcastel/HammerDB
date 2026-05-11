#!/bin/tclsh
import os
tmpdir = os.getenv('TMP') or (os.getcwd() + '/TMP')

print("SETTING CONFIGURATION")
dbset('db','firebird')
dbset('bm','TPC-H')

diset('connection','fb_host','localhost')
diset('connection','fb_port','3050')
diset('connection','fb_odbc_driver','Firebird ODBC Driver')
diset('connection','fb_charset','UTF8')
diset('connection','fb_embedded','true')

diset('tpch','fb_scale_fact','1')
diset('tpch','fb_tpch_user','SYSDBA')
diset('tpch','fb_tpch_pass','masterkey')
diset('tpch','fb_tpch_dbase', tmpdir + '/tpch.fdb')
diset('tpch','fb_total_querysets','1')

loadscript()
print("TEST STARTED")
vuset('vu','1')
vucreate()
jobid = tclpy.eval('vurun')
vudestroy()
print("TEST COMPLETE")
file_path = os.path.join(tmpdir, "fb_tproch")
fd = open(file_path, "w")
fd.write(jobid)
fd.close()
exit()
