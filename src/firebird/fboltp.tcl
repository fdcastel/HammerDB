# Firebird TPROC-C (TPC-C-like OLTP) implementation.
#
# Embedded-mode ODBC connection string (canonical):
#   Driver={Firebird ODBC Driver};
#   Dbname=<absolute path to .fdb, forward slashes>;
#   Client=fbclient.dll;
#   User=SYSDBA;
# (Embedded mode: no host/port, no password required.)
#
# Build status: skeleton. Connection helper and config plumbing are
# wired up so that scripts/tcl/firebird/tprocc/* can stand up. Schema
# DDL, stored procedures, driver procs (neword/payment/delivery/ostat/
# slev), bulk-load batching and update-conflict retry land in
# subsequent commits (THE_PLAN tasks C3-C8).

proc fb_library_version {} {
    upvar #0 dbdict dbdict
    set library "tdbc::odbc"
    set version ""
    if {[dict exists $dbdict firebird library]} {
        set lv [dict get $dbdict firebird library]
        if {[llength $lv] > 1} {
            set library [lindex $lv 0]
            set version [lindex $lv 1]
        } else {
            set library $lv
        }
    }
    return [list $library $version]
}

proc fb_build_connstr { fb_odbc_driver fb_embedded fb_host fb_port fb_dbase fb_user fb_pass fb_charset } {
    # Builds the ODBC connection string for either embedded or remote
    # Firebird. Caller passes resolved scalars (no upvar) so this proc
    # can be invoked from worker threads where configfirebird is absent.
    set connstr "Driver={$fb_odbc_driver};"
    if {[string is true -strict $fb_embedded]} {
        # Embedded mode: Dbname is an absolute path on the local host.
        # Convert backslashes to forward slashes so the ODBC parser
        # doesn't choke on Windows-style paths inside the Dbname token.
        set dbpath [string map {\\ /} $fb_dbase]
        append connstr "Dbname=$dbpath;Client=fbclient.dll;User=$fb_user;"
    } else {
        # Server mode (future): host:port path.
        append connstr "Dbname=$fb_host/$fb_port:$fb_dbase;User=$fb_user;Password=$fb_pass;"
    }
    if {$fb_charset ne ""} {
        append connstr "Charset=$fb_charset;"
    }
    return $connstr
}

proc ConnectToFirebird { fb_odbc_driver fb_embedded fb_host fb_port fb_dbase fb_user fb_pass fb_charset } {
    # Returns a tdbc::odbc connection object on success, or raises with
    # the underlying ODBC error message.
    package require tdbc::odbc
    set connstr [fb_build_connstr $fb_odbc_driver $fb_embedded $fb_host $fb_port $fb_dbase $fb_user $fb_pass $fb_charset]
    if {[catch {tdbc::odbc::connection new $connstr} conn errdict]} {
        error "Firebird connection failed: $conn (connection string: [string map [list $fb_pass {***}] $connstr])"
    }
    return $conn
}

proc build_fbtpcc {} {
    # GUI entry point for "Build" on the TPROC-C tab. Will:
    #   1. resolve config via setlocalfbtpccvars
    #   2. bring up the editor with a ready-to-run schema-build script
    #   3. spawn N virtual users to load warehouses in parallel
    # Currently a stub that surfaces a clear "not yet implemented" error
    # rather than hanging the GUI.
    upvar #0 dbdict dbdict
    upvar #0 configfirebird configfirebird
    setlocalfbtpccvars $configfirebird
    error "build_fbtpcc: schema build is not yet implemented; tracking in THE_PLAN.md task C3-C5"
}

# Driver procs (stubs until C5/C6 land)
proc neword   { conn no_w_id w_id_input RAISEERROR fb_storedprocs } { error "fb neword not yet implemented" }
proc payment  { conn p_w_id w_id_input RAISEERROR fb_storedprocs } { error "fb payment not yet implemented" }
proc delivery { conn w_id RAISEERROR fb_storedprocs }              { error "fb delivery not yet implemented" }
proc ostat    { conn w_id RAISEERROR fb_storedprocs }              { error "fb ostat not yet implemented" }
proc slev     { conn w_id stock_level_d_id RAISEERROR fb_storedprocs } { error "fb slev not yet implemented" }
