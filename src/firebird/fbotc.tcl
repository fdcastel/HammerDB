# Firebird transaction counter (otc).
#
# Stub: real implementation will spin up a worker thread that polls the
# embedded database via MON$ tables and updates the GUI LCD/graph,
# mirroring src/postgresql/pgotc.tcl. For now the proc is defined so
# that the GUI dispatcher (tcount_$prefix) can find it without
# crashing.
proc tcount_fb {bm interval masterthread} {
    puts "tcount_fb: not yet implemented (bm=$bm interval=$interval)"
    return
}
