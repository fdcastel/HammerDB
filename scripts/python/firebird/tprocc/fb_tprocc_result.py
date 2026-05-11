import os
tmpdir = os.getenv('TMP') or (os.getcwd() + '/TMP')
outputfile = os.path.join(tmpdir, "fb_tprocc")
tclpy.eval('source ./scripts/python/generic/generic_tprocc_result.py')
exit()
