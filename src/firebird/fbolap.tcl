# Firebird TPROC-H (TPC-H-like OLAP) implementation.
#
# Build status: skeleton. Real schema build, the 22 TPC-H queries
# adapted for Firebird SQL dialect, and the refresh streams (RF1/RF2)
# land in subsequent commits (THE_PLAN tasks C9-C11).
#
# Connection plumbing reuses fb_build_connstr / ConnectToFirebird from
# fboltp.tcl, which is sourced before this file by hammerdbcli.

proc build_fbtpch {} {
    upvar #0 dbdict dbdict
    upvar #0 configfirebird configfirebird
    setlocalfbtpchvars $configfirebird
    error "build_fbtpch: schema build is not yet implemented; tracking in THE_PLAN.md task C9-C11"
}
