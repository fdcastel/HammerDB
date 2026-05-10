# Firebird options dialog and config helpers.
#
# Stub. Real implementation will mirror src/postgresql/pgopt.tcl:
# - Connection tab (fb_host, fb_port, fb_odbc_driver, fb_user, fb_pass,
#   fb_dbase, fb_embedded)
# - TPROC-C schema/driver tabs (fb_count_ware, fb_num_vu,
#   fb_storedprocs, fb_total_iterations, fb_rampup, fb_duration, ...)
# - TPROC-H schema/driver tabs (fb_scale_fact, fb_total_querysets, ...)
#
# For now we expose the canonical setlocal* helpers so fboltp.tcl /
# fbolap.tcl can pull values out of $configfirebird without GUI code.

proc setlocalfbtpccvars { configfirebird } {
    upvar 1 fb_host fb_host
    upvar 1 fb_port fb_port
    upvar 1 fb_odbc_driver fb_odbc_driver
    upvar 1 fb_charset fb_charset
    upvar 1 fb_embedded fb_embedded
    upvar 1 fb_count_ware fb_count_ware
    upvar 1 fb_num_vu fb_num_vu
    upvar 1 fb_user fb_user
    upvar 1 fb_pass fb_pass
    upvar 1 fb_dbase fb_dbase
    upvar 1 fb_storedprocs fb_storedprocs
    upvar 1 fb_partition fb_partition
    upvar 1 fb_total_iterations fb_total_iterations
    upvar 1 fb_raiseerror fb_raiseerror
    upvar 1 fb_keyandthink fb_keyandthink
    upvar 1 fb_driver fb_driver
    upvar 1 fb_rampup fb_rampup
    upvar 1 fb_duration fb_duration
    upvar 1 fb_allwarehouse fb_allwarehouse
    upvar 1 fb_timeprofile fb_timeprofile
    upvar 1 fb_async_scale fb_async_scale
    upvar 1 fb_async_client fb_async_client
    upvar 1 fb_async_verbose fb_async_verbose
    upvar 1 fb_async_delay fb_async_delay
    upvar 1 fb_connect_pool fb_connect_pool

    set fb_host [dict get $configfirebird connection fb_host]
    set fb_port [dict get $configfirebird connection fb_port]
    set fb_odbc_driver [dict get $configfirebird connection fb_odbc_driver]
    set fb_charset [dict get $configfirebird connection fb_charset]
    set fb_embedded [dict get $configfirebird connection fb_embedded]
    set fb_count_ware [dict get $configfirebird tpcc schema fb_count_ware]
    set fb_num_vu [dict get $configfirebird tpcc schema fb_num_vu]
    set fb_user [dict get $configfirebird tpcc schema fb_user]
    set fb_pass [dict get $configfirebird tpcc schema fb_pass]
    set fb_dbase [dict get $configfirebird tpcc schema fb_dbase]
    set fb_storedprocs [dict get $configfirebird tpcc schema fb_storedprocs]
    set fb_partition [dict get $configfirebird tpcc schema fb_partition]
    set fb_total_iterations [dict get $configfirebird tpcc driver fb_total_iterations]
    set fb_raiseerror [dict get $configfirebird tpcc driver fb_raiseerror]
    set fb_keyandthink [dict get $configfirebird tpcc driver fb_keyandthink]
    set fb_driver [dict get $configfirebird tpcc driver fb_driver]
    set fb_rampup [dict get $configfirebird tpcc driver fb_rampup]
    set fb_duration [dict get $configfirebird tpcc driver fb_duration]
    set fb_allwarehouse [dict get $configfirebird tpcc driver fb_allwarehouse]
    set fb_timeprofile [dict get $configfirebird tpcc driver fb_timeprofile]
    set fb_async_scale [dict get $configfirebird tpcc driver fb_async_scale]
    set fb_async_client [dict get $configfirebird tpcc driver fb_async_client]
    set fb_async_verbose [dict get $configfirebird tpcc driver fb_async_verbose]
    set fb_async_delay [dict get $configfirebird tpcc driver fb_async_delay]
    set fb_connect_pool [dict get $configfirebird tpcc driver fb_connect_pool]
}

proc setlocalfbtpchvars { configfirebird } {
    upvar 1 fb_host fb_host
    upvar 1 fb_port fb_port
    upvar 1 fb_odbc_driver fb_odbc_driver
    upvar 1 fb_charset fb_charset
    upvar 1 fb_embedded fb_embedded
    upvar 1 fb_scale_fact fb_scale_fact
    upvar 1 fb_tpch_user fb_tpch_user
    upvar 1 fb_tpch_pass fb_tpch_pass
    upvar 1 fb_tpch_dbase fb_tpch_dbase
    upvar 1 fb_num_tpch_threads fb_num_tpch_threads
    upvar 1 fb_total_querysets fb_total_querysets
    upvar 1 fb_raise_query_error fb_raise_query_error
    upvar 1 fb_verbose fb_verbose
    upvar 1 fb_refresh_on fb_refresh_on
    upvar 1 fb_update_sets fb_update_sets
    upvar 1 fb_trickle_refresh fb_trickle_refresh
    upvar 1 fb_refresh_verbose fb_refresh_verbose

    set fb_host [dict get $configfirebird connection fb_host]
    set fb_port [dict get $configfirebird connection fb_port]
    set fb_odbc_driver [dict get $configfirebird connection fb_odbc_driver]
    set fb_charset [dict get $configfirebird connection fb_charset]
    set fb_embedded [dict get $configfirebird connection fb_embedded]
    set fb_scale_fact [dict get $configfirebird tpch schema fb_scale_fact]
    set fb_tpch_user [dict get $configfirebird tpch schema fb_tpch_user]
    set fb_tpch_pass [dict get $configfirebird tpch schema fb_tpch_pass]
    set fb_tpch_dbase [dict get $configfirebird tpch schema fb_tpch_dbase]
    set fb_num_tpch_threads [dict get $configfirebird tpch schema fb_num_tpch_threads]
    set fb_total_querysets [dict get $configfirebird tpch driver fb_total_querysets]
    set fb_raise_query_error [dict get $configfirebird tpch driver fb_raise_query_error]
    set fb_verbose [dict get $configfirebird tpch driver fb_verbose]
    set fb_refresh_on [dict get $configfirebird tpch driver fb_refresh_on]
    set fb_update_sets [dict get $configfirebird tpch driver fb_update_sets]
    set fb_trickle_refresh [dict get $configfirebird tpch driver fb_trickle_refresh]
    set fb_refresh_verbose [dict get $configfirebird tpch driver fb_refresh_verbose]
}
