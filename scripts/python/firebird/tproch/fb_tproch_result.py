import os
tmpdir = os.getenv('TMP') or (os.getcwd() + '/TMP')
outputfile = os.path.join(tmpdir, "fb_tproch")
tclpy.eval('source ./scripts/python/generic/generic_tproch_result.py')
exit()
