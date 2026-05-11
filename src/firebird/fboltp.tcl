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

proc fb_tpcc_table_ddl {} {
    # Returns a list of CREATE TABLE statements for the 9 TPC-C tables,
    # in dependency-safe order. Types are the Firebird SQL dialect
    # equivalents of the canonical TPC-C schema used by other HammerDB
    # drivers (see src/postgresql/pgoltp.tcl::CreateTables).
    set ddl [list]
    lappend ddl {CREATE TABLE WAREHOUSE (
        W_ID INTEGER NOT NULL,
        W_NAME VARCHAR(10) NOT NULL,
        W_STREET_1 VARCHAR(20) NOT NULL,
        W_STREET_2 VARCHAR(20) NOT NULL,
        W_CITY VARCHAR(20) NOT NULL,
        W_STATE CHAR(2) NOT NULL,
        W_ZIP CHAR(9) NOT NULL,
        W_TAX NUMERIC(4,4) NOT NULL,
        W_YTD NUMERIC(16,2) NOT NULL,
        CONSTRAINT WAREHOUSE_I1 PRIMARY KEY (W_ID))}
    lappend ddl {CREATE TABLE DISTRICT (
        D_W_ID INTEGER NOT NULL,
        D_NEXT_O_ID INTEGER NOT NULL,
        D_ID SMALLINT NOT NULL,
        D_YTD NUMERIC(12,2) NOT NULL,
        D_TAX NUMERIC(4,4) NOT NULL,
        D_NAME VARCHAR(10) NOT NULL,
        D_STREET_1 VARCHAR(20) NOT NULL,
        D_STREET_2 VARCHAR(20) NOT NULL,
        D_CITY VARCHAR(20) NOT NULL,
        D_STATE CHAR(2) NOT NULL,
        D_ZIP CHAR(9) NOT NULL,
        CONSTRAINT DISTRICT_I1 PRIMARY KEY (D_W_ID, D_ID))}
    lappend ddl {CREATE TABLE CUSTOMER (
        C_SINCE TIMESTAMP NOT NULL,
        C_ID INTEGER NOT NULL,
        C_W_ID INTEGER NOT NULL,
        C_D_ID SMALLINT NOT NULL,
        C_PAYMENT_CNT SMALLINT NOT NULL,
        C_DELIVERY_CNT SMALLINT NOT NULL,
        C_FIRST VARCHAR(16) NOT NULL,
        C_MIDDLE CHAR(2) NOT NULL,
        C_LAST VARCHAR(16) NOT NULL,
        C_STREET_1 VARCHAR(20) NOT NULL,
        C_STREET_2 VARCHAR(20) NOT NULL,
        C_CITY VARCHAR(20) NOT NULL,
        C_STATE CHAR(2) NOT NULL,
        C_ZIP CHAR(9) NOT NULL,
        C_PHONE CHAR(16) NOT NULL,
        C_CREDIT CHAR(2) NOT NULL,
        C_CREDIT_LIM NUMERIC(12,2) NOT NULL,
        C_DISCOUNT NUMERIC(4,4) NOT NULL,
        C_BALANCE NUMERIC(12,2) NOT NULL,
        C_YTD_PAYMENT NUMERIC(12,2) NOT NULL,
        C_DATA VARCHAR(500) NOT NULL,
        CONSTRAINT CUSTOMER_I1 PRIMARY KEY (C_W_ID, C_D_ID, C_ID))}
    lappend ddl {CREATE TABLE HISTORY (
        H_DATE TIMESTAMP NOT NULL,
        H_C_ID INTEGER,
        H_C_W_ID INTEGER NOT NULL,
        H_W_ID INTEGER NOT NULL,
        H_C_D_ID SMALLINT NOT NULL,
        H_D_ID SMALLINT NOT NULL,
        H_AMOUNT NUMERIC(6,2) NOT NULL,
        H_DATA VARCHAR(24) NOT NULL)}
    lappend ddl {CREATE TABLE NEW_ORDER (
        NO_W_ID INTEGER NOT NULL,
        NO_O_ID INTEGER NOT NULL,
        NO_D_ID SMALLINT NOT NULL,
        CONSTRAINT NEW_ORDER_I1 PRIMARY KEY (NO_W_ID, NO_D_ID, NO_O_ID))}
    lappend ddl {CREATE TABLE ORDERS (
        O_ENTRY_D TIMESTAMP NOT NULL,
        O_ID INTEGER NOT NULL,
        O_W_ID INTEGER NOT NULL,
        O_C_ID INTEGER NOT NULL,
        O_D_ID SMALLINT NOT NULL,
        O_CARRIER_ID SMALLINT,
        O_OL_CNT SMALLINT NOT NULL,
        O_ALL_LOCAL SMALLINT NOT NULL,
        CONSTRAINT ORDERS_I1 PRIMARY KEY (O_W_ID, O_D_ID, O_ID))}
    lappend ddl {CREATE TABLE ORDER_LINE (
        OL_DELIVERY_D TIMESTAMP,
        OL_O_ID INTEGER NOT NULL,
        OL_W_ID INTEGER NOT NULL,
        OL_I_ID INTEGER NOT NULL,
        OL_SUPPLY_W_ID INTEGER NOT NULL,
        OL_D_ID SMALLINT NOT NULL,
        OL_NUMBER SMALLINT NOT NULL,
        OL_QUANTITY SMALLINT NOT NULL,
        OL_AMOUNT NUMERIC(6,2),
        OL_DIST_INFO CHAR(24),
        CONSTRAINT ORDER_LINE_I1 PRIMARY KEY (OL_W_ID, OL_D_ID, OL_O_ID, OL_NUMBER))}
    lappend ddl {CREATE TABLE ITEM (
        I_ID INTEGER NOT NULL,
        I_IM_ID INTEGER NOT NULL,
        I_NAME VARCHAR(24) NOT NULL,
        I_PRICE NUMERIC(5,2) NOT NULL,
        I_DATA VARCHAR(50) NOT NULL,
        CONSTRAINT ITEM_I1 PRIMARY KEY (I_ID))}
    lappend ddl {CREATE TABLE STOCK (
        S_I_ID INTEGER NOT NULL,
        S_W_ID INTEGER NOT NULL,
        S_YTD INTEGER NOT NULL,
        S_QUANTITY SMALLINT NOT NULL,
        S_ORDER_CNT SMALLINT NOT NULL,
        S_REMOTE_CNT SMALLINT NOT NULL,
        S_DIST_01 CHAR(24) NOT NULL,
        S_DIST_02 CHAR(24) NOT NULL,
        S_DIST_03 CHAR(24) NOT NULL,
        S_DIST_04 CHAR(24) NOT NULL,
        S_DIST_05 CHAR(24) NOT NULL,
        S_DIST_06 CHAR(24) NOT NULL,
        S_DIST_07 CHAR(24) NOT NULL,
        S_DIST_08 CHAR(24) NOT NULL,
        S_DIST_09 CHAR(24) NOT NULL,
        S_DIST_10 CHAR(24) NOT NULL,
        S_DATA VARCHAR(50) NOT NULL,
        CONSTRAINT STOCK_I1 PRIMARY KEY (S_I_ID, S_W_ID))}
    return $ddl
}

proc fb_tpcc_index_ddl {} {
    # Secondary indexes that match the canonical TPC-C set used by
    # other HammerDB drivers.
    return [list \
        {CREATE UNIQUE INDEX CUSTOMER_I2 ON CUSTOMER (C_W_ID, C_D_ID, C_LAST, C_FIRST, C_ID)} \
        {CREATE UNIQUE INDEX ORDERS_I2 ON ORDERS (O_W_ID, O_D_ID, O_C_ID, O_ID)}]
}

proc fb_create_tpcc_schema { conn } {
    # Issues the TPC-C DDL on $conn (a tdbc::odbc connection). Each
    # CREATE TABLE/INDEX runs in its own implicit transaction.
    set count 0
    foreach stmt [fb_tpcc_table_ddl] {
        $conn allrows $stmt
        incr count
    }
    foreach stmt [fb_tpcc_index_ddl] {
        $conn allrows $stmt
        incr count
    }
    return $count
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
    error "build_fbtpcc: GUI build flow not yet wired up; the DDL is implemented in fb_create_tpcc_schema. Tracking row loaders in THE_PLAN.md task C4-C5"
}

# Driver procs (stubs until C5/C6 land)
proc neword   { conn no_w_id w_id_input RAISEERROR fb_storedprocs } { error "fb neword not yet implemented" }
proc payment  { conn p_w_id w_id_input RAISEERROR fb_storedprocs } { error "fb payment not yet implemented" }
proc delivery { conn w_id RAISEERROR fb_storedprocs }              { error "fb delivery not yet implemented" }
proc ostat    { conn w_id RAISEERROR fb_storedprocs }              { error "fb ostat not yet implemented" }
proc slev     { conn w_id stock_level_d_id RAISEERROR fb_storedprocs } { error "fb slev not yet implemented" }
