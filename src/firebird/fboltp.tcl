# Firebird TPROC-C (TPC-C-like OLTP) implementation.
#
# Embedded-mode ODBC connection string (canonical):
#   Driver={Firebird ODBC Driver};
#   Dbname=<absolute path to .fdb, forward slashes>;
#   Client=fbclient.dll;        (Windows; libfbclient.so.5 on Linux)
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

proc fb_default_client_lib {} {
    # Pick the Firebird client library file name that the ODBC driver
    # should dlopen. The Firebird ODBC driver's Client= attribute is
    # passed straight to the platform loader (LoadLibrary on Windows,
    # dlopen on POSIX), so the file extension matters: a Linux build
    # given "fbclient.dll" will fail with "cannot open shared object".
    # FB_CLIENT_LIB env var overrides for non-default installs (e.g.
    # vendored fbclient next to the binary).
    if {[info exists ::env(FB_CLIENT_LIB)] && $::env(FB_CLIENT_LIB) ne ""} {
        return $::env(FB_CLIENT_LIB)
    }
    if {$::tcl_platform(platform) eq "windows"} {
        return "fbclient.dll"
    }
    return "libfbclient.so.2"
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
        set client [fb_default_client_lib]
        append connstr "Dbname=$dbpath;Client=$client;User=$fb_user;"
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

# ---------------------------------------------------------------------
# TPC-C PSQL stored procedures (Firebird).
#
# Initial cut implements PAYMENT only - the simplest of the 5 (no
# loops, no per-line cursor work). NEWORD / DELIVERY / OSTAT / SLEV
# are scaffolded as stubs that raise so the install path is exercised
# end-to-end on CI before each is fleshed out.
#
# Procs use Firebird PSQL syntax:
#   CREATE OR ALTER PROCEDURE name (input_params) RETURNS (output_params)
#   AS DECLARE VARIABLE v TYPE; BEGIN ... END
# tdbc::odbc submits the whole CREATE PROCEDURE as a single statement;
# Firebird parses the procedure body without needing isql `SET TERM`.
# ---------------------------------------------------------------------

proc fb_tpcc_sp_ddl {} {
    set ddl [list]
    # PAYMENT: by-id only path (caller passes c_id; by-name lookups
    # stay client-side until a future revision wires the cursor work
    # in PSQL).
    lappend ddl {CREATE OR ALTER PROCEDURE PAYMENT_SP (
        P_W_ID    INTEGER,
        P_D_ID    SMALLINT,
        P_C_W_ID  INTEGER,
        P_C_D_ID  SMALLINT,
        P_C_ID    INTEGER,
        P_AMOUNT  NUMERIC(12,2),
        P_DATE    TIMESTAMP)
    RETURNS (
        OUT_C_BALANCE NUMERIC(12,2),
        OUT_C_CREDIT  CHAR(2),
        OUT_W_NAME    VARCHAR(10),
        OUT_D_NAME    VARCHAR(10))
    AS
    DECLARE VARIABLE H_DATA VARCHAR(24);
    BEGIN
        UPDATE WAREHOUSE
            SET W_YTD = W_YTD + :P_AMOUNT
            WHERE W_ID = :P_W_ID
            RETURNING W_NAME INTO :OUT_W_NAME;

        UPDATE DISTRICT
            SET D_YTD = D_YTD + :P_AMOUNT
            WHERE D_W_ID = :P_W_ID AND D_ID = :P_D_ID
            RETURNING D_NAME INTO :OUT_D_NAME;

        SELECT C_BALANCE, C_CREDIT FROM CUSTOMER
            WHERE C_W_ID = :P_C_W_ID
              AND C_D_ID = :P_C_D_ID
              AND C_ID   = :P_C_ID
            INTO :OUT_C_BALANCE, :OUT_C_CREDIT;

        OUT_C_BALANCE = OUT_C_BALANCE - :P_AMOUNT;

        UPDATE CUSTOMER
            SET C_BALANCE     = :OUT_C_BALANCE,
                C_YTD_PAYMENT = C_YTD_PAYMENT + :P_AMOUNT,
                C_PAYMENT_CNT = C_PAYMENT_CNT + 1
            WHERE C_W_ID = :P_C_W_ID
              AND C_D_ID = :P_C_D_ID
              AND C_ID   = :P_C_ID;

        H_DATA = :OUT_W_NAME || '    ' || :OUT_D_NAME;
        INSERT INTO HISTORY
            (H_C_ID, H_C_D_ID, H_C_W_ID, H_W_ID, H_D_ID,
             H_DATE, H_AMOUNT, H_DATA)
        VALUES (:P_C_ID, :P_C_D_ID, :P_C_W_ID, :P_W_ID, :P_D_ID,
                :P_DATE, :P_AMOUNT, :H_DATA);

        SUSPEND;
    END}
    return $ddl
}

proc fb_create_tpcc_stored_procs { conn } {
    # NOTE: tdbc::odbc cannot submit a CREATE PROCEDURE body that
    # contains `:NAME` PSQL variable references because its prepare
    # scanner treats those as bind placeholders. Use isql (e.g. via
    # PSFirebird's Invoke-FirebirdIsql) with a SET TERM ^ wrapper to
    # install these procs. The ddl strings here are kept for
    # documentation and isql piping; the count returned is just the
    # statement count, not a guarantee the install succeeded.
    set count 0
    foreach stmt [fb_tpcc_sp_ddl] {
        if {[catch {$conn allrows $stmt} err]} {
            puts stderr "fb_create_tpcc_stored_procs: install via tdbc failed (expected, use isql): $err"
        }
        incr count
    }
    return $count
}

# ---------------------------------------------------------------------
# TPROC-C bulk loader.
#
# Firebird has no COPY/BCP equivalent, so we use prepared INSERT
# statements with `:name` parameter placeholders (tdbc::odbc rejects
# positional `?`) and commit in batches (default 1000 rows). The
# generated row data follows the same TPC-C spec the postgres/mssqls
# drivers use; helper procs come from the tpcccommon module.
#
# IMPORTANT: tdbc's $stmt execute returns a resultset object that
# holds the underlying ODBC cursor. For Firebird, calling execute
# again before that resultset is closed yields "Too many concurrent
# executions of the same request". The fb_exec helper closes the
# resultset immediately so the statement can be reused in a tight
# insert loop.
# ---------------------------------------------------------------------

proc fb_exec { stmt params } {
    set rs [$stmt execute $params]
    $rs close
    return
}

# ---------------------------------------------------------------------
# MVCC retry helper (C8). Firebird is MVCC and surfaces concurrent-
# update conflicts as exceptions: "deadlock", "lock conflict on no
# wait transaction", "update conflicts with concurrent update", or
# SQLSTATE 40001. The 5 TPC-C transactions wrap their bodies in this
# helper so a transient conflict triggers an automatic retry with a
# small randomised back-off, matching the postgres serialization
# retry pattern.
# ---------------------------------------------------------------------

proc fb_is_retryable_error { msg } {
    # Case-insensitive match on the well-known Firebird conflict
    # markers. Anything else is propagated as a real error.
    set patterns {
        deadlock
        "lock conflict"
        "update conflict"
        "concurrent update"
        "concurrent transaction"
        "40001"
        isc_update_conflict
    }
    foreach p $patterns {
        if {[string match -nocase "*$p*" $msg]} { return 1 }
    }
    return 0
}

proc fb_with_retry { max_retries body_var body } {
    # Run $body up to $max_retries+1 times. On a retryable error, wait
    # a small randomised back-off then retry. On any other error,
    # re-raise immediately. body_var is the name of a variable in the
    # caller's frame that receives the attempt number (0-based) before
    # each invocation.
    upvar 1 $body_var attempt
    for {set attempt 0} {$attempt <= $max_retries} {incr attempt} {
        if {[catch {uplevel 1 $body} result errdict]} {
            if {$attempt < $max_retries && [fb_is_retryable_error $result]} {
                # Back off 5..40 ms before retrying so concurrent VUs
                # don't lock-step into the same conflict.
                after [expr {5 + int(rand() * 35)}]
                continue
            }
            # Non-retryable or retries exhausted - propagate.
            return -options $errdict $result
        }
        return $result
    }
    error "fb_with_retry: max retries ($max_retries) exceeded"
}

namespace eval ::fb_loader {
    variable BATCH_SIZE 1000
    # Cached character array used by tpcccommon::MakeAlphaString /
    # MakeAddress so each loader proc doesn't rebuild it.
    variable chArr [list 0 1 2 3 4 5 6 7 8 9 \
                         A B C D E F G H I J K L M N O P Q R S T U V W X Y Z \
                         a b c d e f g h i j k l m n o p q r s t u v w x y z]
    variable chLen [llength $chArr]
    variable nameArr [list BAR OUGHT ABLE PRI PRES ESE ANTI CALLY ATION EING]
}

proc fb_iso_ts {} {
    # Firebird accepts 'YYYY-MM-DD HH:MM:SS' for TIMESTAMP literals via
    # parameter binding (string -> TIMESTAMP coercion).
    return [clock format [clock seconds] -format "%Y-%m-%d %H:%M:%S"]
}

proc fb_load_item { conn MAXITEMS } {
    if {[catch {package require tpcccommon}]} {
        error "fb_load_item: tpcccommon module unavailable"
    }
    namespace import -force ::tpcccommon::*
    variable ::fb_loader::chArr; variable ::fb_loader::chLen
    variable ::fb_loader::BATCH_SIZE
    set chArr $::fb_loader::chArr
    set chLen $::fb_loader::chLen

    # Mark 1/10 of items as carrying the literal "original" in i_data.
    set originalSet [dict create]
    for {set i 0} {$i < [expr {$MAXITEMS/10}]} {incr i} {
        dict set originalSet [RandomNumber 1 $MAXITEMS] 1
    }

    set stmt [$conn prepare {
        INSERT INTO ITEM (I_ID, I_IM_ID, I_NAME, I_PRICE, I_DATA)
        VALUES (:i_id, :i_im_id, :i_name, :i_price, :i_data)
    }]
    set inBatch 0
    $conn begintransaction
    for {set i_id 1} {$i_id <= $MAXITEMS} {incr i_id} {
        set i_im_id [RandomNumber 1 10000]
        set i_name [MakeAlphaString 14 24 $chArr $chLen]
        set i_price [format "%4.2f" [expr {[RandomNumber 100 10000]/100.0}]]
        set i_data [MakeAlphaString 26 50 $chArr $chLen]
        if {[dict exists $originalSet $i_id]} {
            set first [RandomNumber 0 [expr {[string length $i_data] - 8}]]
            set last [expr {$first + 8}]
            set i_data [string replace $i_data $first $last "original"]
        }
        fb_exec $stmt [dict create i_id $i_id i_im_id $i_im_id \
            i_name $i_name i_price $i_price i_data $i_data]
        incr inBatch
        if {$inBatch >= $::fb_loader::BATCH_SIZE} {
            $conn commit; $conn begintransaction
            set inBatch 0
        }
    }
    $conn commit
    $stmt close
    return $MAXITEMS
}

proc fb_load_warehouse { conn w_id } {
    namespace import -force ::tpcccommon::*
    set chArr $::fb_loader::chArr; set chLen $::fb_loader::chLen
    set name [MakeAlphaString 6 10 $chArr $chLen]
    set addr [MakeAddress $chArr $chLen]
    $conn allrows -- {
        INSERT INTO WAREHOUSE (W_ID, W_NAME, W_STREET_1, W_STREET_2, W_CITY,
                               W_STATE, W_ZIP, W_TAX, W_YTD)
        VALUES (:w_id, :w_name, :w_street_1, :w_street_2, :w_city,
                :w_state, :w_zip, :w_tax, :w_ytd)
    } [dict create w_id $w_id w_name $name \
        w_street_1 [lindex $addr 0] w_street_2 [lindex $addr 1] \
        w_city [lindex $addr 2] w_state [lindex $addr 3] w_zip [lindex $addr 4] \
        w_tax [format "%4.4f" [expr {[RandomNumber 0 2000]/10000.0}]] \
        w_ytd 300000.00]
    return 1
}

proc fb_load_districts { conn w_id DIST_PER_WARE CUST_PER_DIST } {
    namespace import -force ::tpcccommon::*
    set chArr $::fb_loader::chArr; set chLen $::fb_loader::chLen
    set stmt [$conn prepare {
        INSERT INTO DISTRICT (D_ID, D_W_ID, D_NAME, D_STREET_1, D_STREET_2,
                              D_CITY, D_STATE, D_ZIP, D_TAX, D_YTD,
                              D_NEXT_O_ID)
        VALUES (:d_id, :d_w_id, :d_name, :d_street_1, :d_street_2,
                :d_city, :d_state, :d_zip, :d_tax, :d_ytd, :d_next_o_id)
    }]
    $conn begintransaction
    for {set d_id 1} {$d_id <= $DIST_PER_WARE} {incr d_id} {
        set name [MakeAlphaString 6 10 $chArr $chLen]
        set addr [MakeAddress $chArr $chLen]
        fb_exec $stmt [dict create d_id $d_id d_w_id $w_id d_name $name \
            d_street_1 [lindex $addr 0] d_street_2 [lindex $addr 1] \
            d_city [lindex $addr 2] d_state [lindex $addr 3] \
            d_zip [lindex $addr 4] \
            d_tax [format "%4.4f" [expr {[RandomNumber 0 2000]/10000.0}]] \
            d_ytd 30000.00 d_next_o_id [expr {$CUST_PER_DIST + 1}]]
    }
    $conn commit
    $stmt close
    return $DIST_PER_WARE
}

proc fb_load_customer_history { conn w_id DIST_PER_WARE CUST_PER_DIST } {
    namespace import -force ::tpcccommon::*
    variable ::fb_loader::BATCH_SIZE
    set chArr $::fb_loader::chArr; set chLen $::fb_loader::chLen
    set nameArr $::fb_loader::nameArr
    set stmtCust [$conn prepare {
        INSERT INTO CUSTOMER (C_ID, C_D_ID, C_W_ID, C_FIRST, C_MIDDLE, C_LAST,
                              C_STREET_1, C_STREET_2, C_CITY, C_STATE, C_ZIP,
                              C_PHONE, C_SINCE, C_CREDIT, C_CREDIT_LIM,
                              C_DISCOUNT, C_BALANCE, C_DATA, C_YTD_PAYMENT,
                              C_PAYMENT_CNT, C_DELIVERY_CNT)
        VALUES (:c_id, :c_d_id, :c_w_id, :c_first, :c_middle, :c_last,
                :c_street_1, :c_street_2, :c_city, :c_state, :c_zip,
                :c_phone, :c_since, :c_credit, :c_credit_lim,
                :c_discount, :c_balance, :c_data, :c_ytd_payment,
                :c_payment_cnt, :c_delivery_cnt)
    }]
    set stmtHist [$conn prepare {
        INSERT INTO HISTORY (H_C_ID, H_C_D_ID, H_C_W_ID, H_W_ID, H_D_ID,
                             H_DATE, H_AMOUNT, H_DATA)
        VALUES (:h_c_id, :h_c_d_id, :h_c_w_id, :h_w_id, :h_d_id,
                :h_date, :h_amount, :h_data)
    }]
    set total 0
    for {set d_id 1} {$d_id <= $DIST_PER_WARE} {incr d_id} {
        $conn begintransaction
        set inBatch 0
        for {set c_id 1} {$c_id <= $CUST_PER_DIST} {incr c_id} {
            set c_first [MakeAlphaString 8 16 $chArr $chLen]
            if {$c_id <= 1000} {
                set c_last [Lastname [expr {$c_id - 1}] $nameArr]
            } else {
                set c_last [Lastname [NURand 255 0 999 123] $nameArr]
            }
            set addr [MakeAddress $chArr $chLen]
            set phone [MakeNumberString]
            set credit [expr {[RandomNumber 0 1] eq 1 ? "GC" : "BC"}]
            set discount [format "%4.4f" [expr {[RandomNumber 0 5000]/10000.0}]]
            set c_data [MakeAlphaString 300 500 $chArr $chLen]
            set ts [fb_iso_ts]
            fb_exec $stmtCust [dict create c_id $c_id c_d_id $d_id c_w_id $w_id \
                c_first $c_first c_middle OE c_last $c_last \
                c_street_1 [lindex $addr 0] c_street_2 [lindex $addr 1] \
                c_city [lindex $addr 2] c_state [lindex $addr 3] \
                c_zip [lindex $addr 4] c_phone $phone c_since $ts \
                c_credit $credit c_credit_lim 50000.00 c_discount $discount \
                c_balance -10.00 c_data $c_data c_ytd_payment 10.00 \
                c_payment_cnt 1 c_delivery_cnt 0]
            set h_data [MakeAlphaString 12 24 $chArr $chLen]
            fb_exec $stmtHist [dict create h_c_id $c_id h_c_d_id $d_id \
                h_c_w_id $w_id h_w_id $w_id h_d_id $d_id h_date $ts \
                h_amount 10.00 h_data $h_data]
            incr inBatch
            incr total
            if {$inBatch >= $::fb_loader::BATCH_SIZE} {
                $conn commit; $conn begintransaction
                set inBatch 0
            }
        }
        $conn commit
    }
    $stmtCust close
    $stmtHist close
    return $total
}

proc fb_load_stock { conn w_id MAXITEMS } {
    namespace import -force ::tpcccommon::*
    variable ::fb_loader::BATCH_SIZE
    set chArr $::fb_loader::chArr; set chLen $::fb_loader::chLen
    set originalSet [dict create]
    for {set i 0} {$i < [expr {$MAXITEMS/10}]} {incr i} {
        dict set originalSet [RandomNumber 1 $MAXITEMS] 1
    }
    set stmt [$conn prepare {
        INSERT INTO STOCK (S_I_ID, S_W_ID, S_QUANTITY,
                           S_DIST_01, S_DIST_02, S_DIST_03, S_DIST_04, S_DIST_05,
                           S_DIST_06, S_DIST_07, S_DIST_08, S_DIST_09, S_DIST_10,
                           S_DATA, S_YTD, S_ORDER_CNT, S_REMOTE_CNT)
        VALUES (:s_i_id, :s_w_id, :s_quantity,
                :s_dist_01, :s_dist_02, :s_dist_03, :s_dist_04, :s_dist_05,
                :s_dist_06, :s_dist_07, :s_dist_08, :s_dist_09, :s_dist_10,
                :s_data, :s_ytd, :s_order_cnt, :s_remote_cnt)
    }]
    $conn begintransaction
    set inBatch 0
    for {set s_i_id 1} {$s_i_id <= $MAXITEMS} {incr s_i_id} {
        set qty [RandomNumber 10 100]
        set dists [list]
        for {set d 0} {$d < 10} {incr d} {
            lappend dists [MakeAlphaString 24 24 $chArr $chLen]
        }
        set s_data [MakeAlphaString 26 50 $chArr $chLen]
        if {[dict exists $originalSet $s_i_id]} {
            set first [RandomNumber 0 [expr {[string length $s_data] - 8}]]
            set last [expr {$first + 8}]
            set s_data [string replace $s_data $first $last "original"]
        }
        fb_exec $stmt [dict create s_i_id $s_i_id s_w_id $w_id s_quantity $qty \
            s_dist_01 [lindex $dists 0] s_dist_02 [lindex $dists 1] \
            s_dist_03 [lindex $dists 2] s_dist_04 [lindex $dists 3] \
            s_dist_05 [lindex $dists 4] s_dist_06 [lindex $dists 5] \
            s_dist_07 [lindex $dists 6] s_dist_08 [lindex $dists 7] \
            s_dist_09 [lindex $dists 8] s_dist_10 [lindex $dists 9] \
            s_data $s_data s_ytd 0 s_order_cnt 0 s_remote_cnt 0]
        incr inBatch
        if {$inBatch >= $::fb_loader::BATCH_SIZE} {
            $conn commit; $conn begintransaction
            set inBatch 0
        }
    }
    $conn commit
    $stmt close
    return $MAXITEMS
}

proc fb_load_orders { conn w_id DIST_PER_WARE ORD_PER_DIST MAXITEMS } {
    namespace import -force ::tpcccommon::*
    set chArr $::fb_loader::chArr; set chLen $::fb_loader::chLen
    # ORDERS and ORDER_LINE have nullable columns (O_CARRIER_ID,
    # OL_DELIVERY_D), so we use named tdbc parameters: missing dict
    # keys are bound as NULL.
    set stmtOrders [$conn prepare {
        INSERT INTO ORDERS (O_ID, O_C_ID, O_D_ID, O_W_ID, O_ENTRY_D,
                            O_CARRIER_ID, O_OL_CNT, O_ALL_LOCAL)
        VALUES (:o_id, :o_c_id, :o_d_id, :o_w_id, :o_entry_d,
                :o_carrier_id, :o_ol_cnt, :o_all_local)
    }]
    set stmtNewOrder [$conn prepare {
        INSERT INTO NEW_ORDER (NO_O_ID, NO_D_ID, NO_W_ID)
        VALUES (:no_o_id, :no_d_id, :no_w_id)
    }]
    set stmtOrderLine [$conn prepare {
        INSERT INTO ORDER_LINE (OL_O_ID, OL_D_ID, OL_W_ID, OL_NUMBER,
                                OL_I_ID, OL_SUPPLY_W_ID, OL_QUANTITY,
                                OL_AMOUNT, OL_DIST_INFO, OL_DELIVERY_D)
        VALUES (:ol_o_id, :ol_d_id, :ol_w_id, :ol_number,
                :ol_i_id, :ol_supply_w_id, :ol_quantity,
                :ol_amount, :ol_dist_info, :ol_delivery_d)
    }]
    set total 0
    for {set d_id 1} {$d_id <= $DIST_PER_WARE} {incr d_id} {
        # Permute customer ids 1..ORD_PER_DIST so each customer gets
        # exactly one order, in random order.
        set cust [list]
        for {set i 1} {$i <= $ORD_PER_DIST} {incr i} { lappend cust $i }
        for {set i 0} {$i < $ORD_PER_DIST} {incr i} {
            set j [RandomNumber $i [expr {$ORD_PER_DIST - 1}]]
            set tmp [lindex $cust $i]
            lset cust $i [lindex $cust $j]
            lset cust $j $tmp
        }
        $conn begintransaction
        set inBatch 0
        for {set o_id 1} {$o_id <= $ORD_PER_DIST} {incr o_id} {
            set o_c_id [lindex $cust [expr {$o_id - 1}]]
            set o_ol_cnt [RandomNumber 5 15]
            set ts [fb_iso_ts]
            set ord [dict create o_id $o_id o_c_id $o_c_id o_d_id $d_id \
                                 o_w_id $w_id o_entry_d $ts \
                                 o_ol_cnt $o_ol_cnt o_all_local 1]
            if {$o_id > 2100} {
                # First 900 orders per district are unfulfilled
                # NEW_ORDERs - O_CARRIER_ID stays NULL (key absent).
                fb_exec $stmtOrders $ord
                fb_exec $stmtNewOrder [dict create no_o_id $o_id \
                                                   no_d_id $d_id no_w_id $w_id]
            } else {
                dict set ord o_carrier_id [RandomNumber 1 10]
                fb_exec $stmtOrders $ord
            }
            for {set ol 1} {$ol <= $o_ol_cnt} {incr ol} {
                set ol_i_id [RandomNumber 1 $MAXITEMS]
                set ol_dist_info [MakeAlphaString 24 24 $chArr $chLen]
                set olRow [dict create ol_o_id $o_id ol_d_id $d_id \
                    ol_w_id $w_id ol_number $ol ol_i_id $ol_i_id \
                    ol_supply_w_id $w_id ol_quantity 5 \
                    ol_dist_info $ol_dist_info]
                if {$o_id > 2100} {
                    # Unfulfilled order line: ol_amount = 0,
                    # ol_delivery_d NULL.
                    dict set olRow ol_amount 0.00
                } else {
                    dict set olRow ol_amount [format "%6.2f" \
                        [expr {[RandomNumber 10 10000]/100.0}]]
                    dict set olRow ol_delivery_d $ts
                }
                fb_exec $stmtOrderLine $olRow
            }
            incr total
            incr inBatch
            if {$inBatch >= 100} {
                $conn commit; $conn begintransaction
                set inBatch 0
            }
        }
        $conn commit
    }
    $stmtOrders close; $stmtNewOrder close; $stmtOrderLine close
    return $total
}

proc fb_load_warehouse_data { conn w_id { DIST_PER_WARE 10 } { CUST_PER_DIST 3000 } { MAXITEMS 100000 } } {
    # Loads ALL per-warehouse data for warehouse $w_id. Caller is
    # expected to have already invoked fb_load_item once for the
    # database (item is shared).
    set ORD_PER_DIST $CUST_PER_DIST
    set out [dict create]
    dict set out warehouse [fb_load_warehouse $conn $w_id]
    dict set out districts [fb_load_districts $conn $w_id $DIST_PER_WARE $CUST_PER_DIST]
    dict set out customers [fb_load_customer_history $conn $w_id $DIST_PER_WARE $CUST_PER_DIST]
    dict set out stock     [fb_load_stock $conn $w_id $MAXITEMS]
    dict set out orders    [fb_load_orders $conn $w_id $DIST_PER_WARE $ORD_PER_DIST $MAXITEMS]
    return $out
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

# ---------------------------------------------------------------------
# TPC-C transaction procedures (client-side, prepared-statement mode).
#
# Each proc opens an explicit transaction, runs the SQL stream
# specified by the TPC-C standard chapter 2, commits, and closes.
# tdbc::odbc emits cursors for INSERT/UPDATE/DELETE returning RETURNING
# rows; fb_exec closes the resultset between calls so the prepared
# statement stays reusable.
#
# fb_storedprocs=true is reserved for when C5 lands the PSQL EXECUTE
# PROCEDURE path; for now both modes go through the SQL stream below.
# ---------------------------------------------------------------------

# Helper: run a SELECT and return a list of dicts (one per row).
proc fb_select { conn sql params } {
    set stmt [$conn prepare $sql]
    set rows [list]
    if {[catch {$stmt foreach -as dicts -- row $params { lappend rows $row }} err]} {
        $stmt close
        error $err
    }
    $stmt close
    return $rows
}

# Helper: run a SELECT, return the first row (or {} if no rows).
proc fb_select1 { conn sql params } {
    set rows [fb_select $conn $sql $params]
    if {[llength $rows] == 0} { return {} }
    return [lindex $rows 0]
}

# Helper: run UPDATE/DELETE/INSERT, optionally with RETURNING.
proc fb_dml { conn sql params } {
    set stmt [$conn prepare $sql]
    set rows [list]
    if {[catch {$stmt foreach -as dicts -- row $params { lappend rows $row }} err]} {
        $stmt close
        error $err
    }
    $stmt close
    return $rows
}

# NewOrder transaction (TPC-C 2.4)
proc neword { conn w_id w_id_input RAISEERROR fb_storedprocs } {
    namespace import -force ::tpcccommon::*
    set d_id [RandomNumber 1 10]
    set c_id [NURand 1023 1 3000 8191]
    set ol_cnt [RandomNumber 5 15]
    set rbk [RandomNumber 1 100]
    set entry_d [fb_iso_ts]

    set max_retries 3
    for {set attempt 0} {$attempt <= $max_retries} {incr attempt} {
    $conn begintransaction
    if {[catch {
        # Read customer + warehouse (single join, like the spec query)
        set custw [fb_select1 $conn {
            SELECT C.C_DISCOUNT AS C_DISCOUNT, C.C_LAST AS C_LAST,
                   C.C_CREDIT AS C_CREDIT, W.W_TAX AS W_TAX
            FROM CUSTOMER C, WAREHOUSE W
            WHERE W.W_ID = :w_id AND C.C_W_ID = :w_id
              AND C.C_D_ID = :d_id AND C.C_ID = :c_id
        } [dict create w_id $w_id d_id $d_id c_id $c_id]]
        if {$custw eq ""} { error "neword: no customer ($w_id,$d_id,$c_id)" }
        set c_discount [dict get $custw C_DISCOUNT]
        set w_tax [dict get $custw W_TAX]

        # Allocate next o_id and read d_tax
        set distRow [fb_select1 $conn {
            SELECT D_NEXT_O_ID AS D_NEXT_O_ID, D_TAX AS D_TAX
            FROM DISTRICT WHERE D_W_ID = :w_id AND D_ID = :d_id
        } [dict create w_id $w_id d_id $d_id]]
        set o_id [dict get $distRow D_NEXT_O_ID]
        set d_tax [dict get $distRow D_TAX]
        fb_dml $conn {
            UPDATE DISTRICT SET D_NEXT_O_ID = D_NEXT_O_ID + 1
            WHERE D_W_ID = :w_id AND D_ID = :d_id
        } [dict create w_id $w_id d_id $d_id]

        # Generate order lines
        set all_local 1
        set ol_data [list]
        for {set ol 1} {$ol <= $ol_cnt} {incr ol} {
            if {$ol == $ol_cnt && $rbk == 1} {
                set ol_i_id 100001
            } else {
                set ol_i_id [NURand 8191 1 100000 7911]
            }
            if {[RandomNumber 1 100] > 1} {
                set ol_supply_w_id $w_id
            } else {
                set all_local 0
                set ol_supply_w_id [RandomNumber 1 $w_id_input]
            }
            set ol_quantity [RandomNumber 1 10]
            lappend ol_data $ol_i_id $ol_supply_w_id $ol_quantity
        }

        # Insert ORDERS + NEW_ORDER
        fb_dml $conn {
            INSERT INTO ORDERS (O_ID, O_D_ID, O_W_ID, O_C_ID, O_ENTRY_D,
                                O_OL_CNT, O_ALL_LOCAL)
            VALUES (:o_id, :d_id, :w_id, :c_id, :entry_d, :ol_cnt, :all_local)
        } [dict create o_id $o_id d_id $d_id w_id $w_id c_id $c_id \
                       entry_d $entry_d ol_cnt $ol_cnt all_local $all_local]
        fb_dml $conn {
            INSERT INTO NEW_ORDER (NO_O_ID, NO_D_ID, NO_W_ID)
            VALUES (:o_id, :d_id, :w_id)
        } [dict create o_id $o_id d_id $d_id w_id $w_id]

        # For each line: read item, update stock, insert order_line
        set distCol [format "S_DIST_%02d" $d_id]
        for {set i 0} {$i < $ol_cnt} {incr i} {
            set ol_number [expr {$i + 1}]
            set ol_i_id [lindex $ol_data [expr {$i*3}]]
            set ol_supply_w_id [lindex $ol_data [expr {$i*3+1}]]
            set ol_quantity [lindex $ol_data [expr {$i*3+2}]]

            set itemRow [fb_select1 $conn {
                SELECT I_PRICE AS I_PRICE, I_NAME AS I_NAME, I_DATA AS I_DATA
                FROM ITEM WHERE I_ID = :ol_i_id
            } [dict create ol_i_id $ol_i_id]]
            if {$itemRow eq ""} {
                # Spec: rollback the whole transaction on missing item.
                error "neword: invalid item $ol_i_id"
            }
            set i_price [dict get $itemRow I_PRICE]

            set stockRow [fb_select1 $conn "
                SELECT S_QUANTITY AS S_QUANTITY,
                       S_DATA AS S_DATA,
                       $distCol AS S_DIST,
                       S_YTD AS S_YTD,
                       S_ORDER_CNT AS S_ORDER_CNT,
                       S_REMOTE_CNT AS S_REMOTE_CNT
                FROM STOCK
                WHERE S_W_ID = :w_id AND S_I_ID = :i_id
            " [dict create w_id $ol_supply_w_id i_id $ol_i_id]]
            set s_quantity [dict get $stockRow S_QUANTITY]
            set s_dist [dict get $stockRow S_DIST]
            if {$s_quantity - $ol_quantity >= 10} {
                set new_qty [expr {$s_quantity - $ol_quantity}]
            } else {
                set new_qty [expr {$s_quantity - $ol_quantity + 91}]
            }
            set remote_inc [expr {$ol_supply_w_id == $w_id ? 0 : 1}]
            fb_dml $conn {
                UPDATE STOCK SET
                    S_QUANTITY = :new_qty,
                    S_YTD = S_YTD + :ol_quantity,
                    S_ORDER_CNT = S_ORDER_CNT + 1,
                    S_REMOTE_CNT = S_REMOTE_CNT + :remote_inc
                WHERE S_W_ID = :w_id AND S_I_ID = :i_id
            } [dict create new_qty $new_qty ol_quantity $ol_quantity \
                           remote_inc $remote_inc \
                           w_id $ol_supply_w_id i_id $ol_i_id]

            set ol_amount [format "%6.2f" [expr {$ol_quantity * $i_price * \
                (1 + $w_tax + $d_tax) * (1 - $c_discount)}]]
            fb_dml $conn {
                INSERT INTO ORDER_LINE
                    (OL_O_ID, OL_D_ID, OL_W_ID, OL_NUMBER,
                     OL_I_ID, OL_SUPPLY_W_ID, OL_QUANTITY,
                     OL_AMOUNT, OL_DIST_INFO)
                VALUES (:o_id, :d_id, :w_id, :ol_number,
                        :i_id, :s_w_id, :ol_quantity,
                        :ol_amount, :s_dist)
            } [dict create o_id $o_id d_id $d_id w_id $w_id \
                ol_number $ol_number i_id $ol_i_id s_w_id $ol_supply_w_id \
                ol_quantity $ol_quantity ol_amount $ol_amount s_dist $s_dist]
        }
        $conn commit
    } err]} {
        catch {$conn rollback}
        if {$attempt < $max_retries && [fb_is_retryable_error $err]} {
            after [expr {5 + int(rand() * 35)}]
            continue
        }
        if {$RAISEERROR} { error $err }
        return 0
    }
    return 1
    }
}

# Payment transaction (TPC-C 2.5)
proc payment { conn w_id w_id_input RAISEERROR fb_storedprocs } {
    namespace import -force ::tpcccommon::*
    set d_id [RandomNumber 1 10]
    set x [RandomNumber 1 100]
    if {$x <= 85} {
        set c_d_id $d_id
        set c_w_id $w_id
    } else {
        set c_d_id [RandomNumber 1 10]
        set c_w_id [RandomNumber 1 $w_id_input]
        while {$c_w_id == $w_id && $w_id_input != 1} {
            set c_w_id [RandomNumber 1 $w_id_input]
        }
    }
    set y [RandomNumber 1 100]
    set byname [expr {$y <= 60 ? 1 : 0}]
    set h_amount [format "%6.2f" [expr {[RandomNumber 100 500000]/100.0}]]
    set h_date [fb_iso_ts]

    set max_retries 3
    for {set attempt 0} {$attempt <= $max_retries} {incr attempt} {
    $conn begintransaction
    if {[catch {
        fb_dml $conn {
            UPDATE WAREHOUSE SET W_YTD = W_YTD + :amount WHERE W_ID = :w_id
        } [dict create amount $h_amount w_id $w_id]
        set wRow [fb_select1 $conn {
            SELECT W_NAME AS W_NAME, W_STREET_1 AS W_STREET_1,
                   W_STREET_2 AS W_STREET_2, W_CITY AS W_CITY,
                   W_STATE AS W_STATE, W_ZIP AS W_ZIP
            FROM WAREHOUSE WHERE W_ID = :w_id
        } [dict create w_id $w_id]]
        fb_dml $conn {
            UPDATE DISTRICT SET D_YTD = D_YTD + :amount
            WHERE D_W_ID = :w_id AND D_ID = :d_id
        } [dict create amount $h_amount w_id $w_id d_id $d_id]
        set dRow [fb_select1 $conn {
            SELECT D_NAME AS D_NAME, D_STREET_1 AS D_STREET_1,
                   D_STREET_2 AS D_STREET_2, D_CITY AS D_CITY,
                   D_STATE AS D_STATE, D_ZIP AS D_ZIP
            FROM DISTRICT WHERE D_W_ID = :w_id AND D_ID = :d_id
        } [dict create w_id $w_id d_id $d_id]]

        if {$byname == 1} {
            set nrnd [NURand 255 0 999 123]
            set name [randname $nrnd]
            set cntRow [fb_select1 $conn {
                SELECT COUNT(*) AS NMATCH FROM CUSTOMER
                WHERE C_W_ID = :w_id AND C_D_ID = :d_id AND C_LAST = :name
            } [dict create w_id $c_w_id d_id $c_d_id name $name]]
            set namecnt [dict get $cntRow NMATCH]
            if {$namecnt == 0} { set namecnt 1 }
            set custList [fb_select $conn {
                SELECT C_ID AS C_ID, C_FIRST AS C_FIRST, C_BALANCE AS C_BALANCE,
                       C_CREDIT AS C_CREDIT, C_CREDIT_LIM AS C_CREDIT_LIM,
                       C_DISCOUNT AS C_DISCOUNT, C_DATA AS C_DATA
                FROM CUSTOMER
                WHERE C_W_ID = :w_id AND C_D_ID = :d_id AND C_LAST = :name
                ORDER BY C_FIRST
            } [dict create w_id $c_w_id d_id $c_d_id name $name]]
            set midx [expr {($namecnt - 1) / 2}]
            set custRow [lindex $custList $midx]
            if {$custRow eq ""} { error "payment: no customer named $name" }
        } else {
            set c_id [NURand 1023 1 3000 8191]
            set custRow [fb_select1 $conn {
                SELECT C_ID AS C_ID, C_FIRST AS C_FIRST, C_BALANCE AS C_BALANCE,
                       C_CREDIT AS C_CREDIT, C_CREDIT_LIM AS C_CREDIT_LIM,
                       C_DISCOUNT AS C_DISCOUNT, C_DATA AS C_DATA
                FROM CUSTOMER
                WHERE C_W_ID = :w_id AND C_D_ID = :d_id AND C_ID = :c_id
            } [dict create w_id $c_w_id d_id $c_d_id c_id $c_id]]
            if {$custRow eq ""} { error "payment: no customer ($c_w_id,$c_d_id,$c_id)" }
        }
        set the_c_id [dict get $custRow C_ID]
        set new_balance [expr {[dict get $custRow C_BALANCE] - $h_amount}]
        if {[dict get $custRow C_CREDIT] eq "BC"} {
            set old_data [dict get $custRow C_DATA]
            set new_data "$the_c_id $c_d_id $c_w_id $d_id $w_id $h_amount $old_data"
            set new_data [string range $new_data 0 499]
            fb_dml $conn {
                UPDATE CUSTOMER SET
                    C_BALANCE = :balance,
                    C_YTD_PAYMENT = C_YTD_PAYMENT + :amount,
                    C_PAYMENT_CNT = C_PAYMENT_CNT + 1,
                    C_DATA = :new_data
                WHERE C_W_ID = :w_id AND C_D_ID = :d_id AND C_ID = :c_id
            } [dict create balance $new_balance amount $h_amount \
                new_data $new_data w_id $c_w_id d_id $c_d_id c_id $the_c_id]
        } else {
            fb_dml $conn {
                UPDATE CUSTOMER SET
                    C_BALANCE = :balance,
                    C_YTD_PAYMENT = C_YTD_PAYMENT + :amount,
                    C_PAYMENT_CNT = C_PAYMENT_CNT + 1
                WHERE C_W_ID = :w_id AND C_D_ID = :d_id AND C_ID = :c_id
            } [dict create balance $new_balance amount $h_amount \
                w_id $c_w_id d_id $c_d_id c_id $the_c_id]
        }
        set h_data "[dict get $wRow W_NAME]    [dict get $dRow D_NAME]"
        fb_dml $conn {
            INSERT INTO HISTORY
                (H_C_ID, H_C_D_ID, H_C_W_ID, H_W_ID, H_D_ID,
                 H_DATE, H_AMOUNT, H_DATA)
            VALUES (:c_id, :c_d_id, :c_w_id, :w_id, :d_id,
                    :h_date, :h_amount, :h_data)
        } [dict create c_id $the_c_id c_d_id $c_d_id c_w_id $c_w_id \
            w_id $w_id d_id $d_id h_date $h_date h_amount $h_amount \
            h_data $h_data]
        $conn commit
    } err]} {
        catch {$conn rollback}
        if {$attempt < $max_retries && [fb_is_retryable_error $err]} {
            after [expr {5 + int(rand() * 35)}]
            continue
        }
        if {$RAISEERROR} { error $err }
        return 0
    }
    return 1
    }
}

# OrderStatus transaction (TPC-C 2.6) - read-only
proc ostat { conn w_id RAISEERROR fb_storedprocs } {
    namespace import -force ::tpcccommon::*
    set d_id [RandomNumber 1 10]
    set y [RandomNumber 1 100]
    set byname [expr {$y <= 60 ? 1 : 0}]

    set max_retries 3
    for {set attempt 0} {$attempt <= $max_retries} {incr attempt} {
    $conn begintransaction
    if {[catch {
        if {$byname == 1} {
            set nrnd [NURand 255 0 999 123]
            set name [randname $nrnd]
            set cntRow [fb_select1 $conn {
                SELECT COUNT(*) AS NMATCH FROM CUSTOMER
                WHERE C_W_ID = :w_id AND C_D_ID = :d_id AND C_LAST = :name
            } [dict create w_id $w_id d_id $d_id name $name]]
            set namecnt [dict get $cntRow NMATCH]
            if {$namecnt == 0} { set namecnt 1 }
            set custList [fb_select $conn {
                SELECT C_ID AS C_ID, C_FIRST AS C_FIRST, C_BALANCE AS C_BALANCE
                FROM CUSTOMER
                WHERE C_W_ID = :w_id AND C_D_ID = :d_id AND C_LAST = :name
                ORDER BY C_FIRST
            } [dict create w_id $w_id d_id $d_id name $name]]
            set custRow [lindex $custList [expr {($namecnt - 1) / 2}]]
        } else {
            set c_id [NURand 1023 1 3000 8191]
            set custRow [fb_select1 $conn {
                SELECT C_ID AS C_ID, C_FIRST AS C_FIRST, C_BALANCE AS C_BALANCE
                FROM CUSTOMER
                WHERE C_W_ID = :w_id AND C_D_ID = :d_id AND C_ID = :c_id
            } [dict create w_id $w_id d_id $d_id c_id $c_id]]
        }
        if {$custRow eq ""} { error "ostat: customer not found" }
        set the_c_id [dict get $custRow C_ID]
        set ordRow [fb_select1 $conn {
            SELECT FIRST 1 O_ID AS O_ID, O_ENTRY_D AS O_ENTRY_D,
                            O_CARRIER_ID AS O_CARRIER_ID
            FROM ORDERS
            WHERE O_W_ID = :w_id AND O_D_ID = :d_id AND O_C_ID = :c_id
            ORDER BY O_ID DESC
        } [dict create w_id $w_id d_id $d_id c_id $the_c_id]]
        if {$ordRow ne ""} {
            set o_id [dict get $ordRow O_ID]
            fb_select $conn {
                SELECT OL_I_ID AS OL_I_ID, OL_SUPPLY_W_ID AS OL_SUPPLY_W_ID,
                       OL_QUANTITY AS OL_QUANTITY, OL_AMOUNT AS OL_AMOUNT,
                       OL_DELIVERY_D AS OL_DELIVERY_D
                FROM ORDER_LINE
                WHERE OL_W_ID = :w_id AND OL_D_ID = :d_id AND OL_O_ID = :o_id
            } [dict create w_id $w_id d_id $d_id o_id $o_id]
        }
        $conn commit
    } err]} {
        catch {$conn rollback}
        if {$attempt < $max_retries && [fb_is_retryable_error $err]} {
            after [expr {5 + int(rand() * 35)}]
            continue
        }
        if {$RAISEERROR} { error $err }
        return 0
    }
    return 1
    }
}

# Delivery transaction (TPC-C 2.7) - iterates 10 districts.
proc delivery { conn w_id RAISEERROR fb_storedprocs } {
    namespace import -force ::tpcccommon::*
    set carrier_id [RandomNumber 1 10]
    set delivery_d [fb_iso_ts]

    if {[catch {
        # Per-district retry: each district's transaction is retried
        # independently on Firebird MVCC conflicts so a transient
        # collision on one district doesn't abort the whole delivery.
        for {set d_id 1} {$d_id <= 10} {incr d_id} {
            set max_retries 3
            for {set attempt 0} {$attempt <= $max_retries} {incr attempt} {
            $conn begintransaction
            if {[catch {
                set noRow [fb_select1 $conn {
                    SELECT FIRST 1 NO_O_ID AS NO_O_ID FROM NEW_ORDER
                    WHERE NO_W_ID = :w_id AND NO_D_ID = :d_id
                    ORDER BY NO_O_ID
                } [dict create w_id $w_id d_id $d_id]]
                if {$noRow eq ""} {
                    $conn commit
                    break
                }
                set o_id [dict get $noRow NO_O_ID]
                fb_dml $conn {
                    DELETE FROM NEW_ORDER
                    WHERE NO_W_ID = :w_id AND NO_D_ID = :d_id AND NO_O_ID = :o_id
                } [dict create w_id $w_id d_id $d_id o_id $o_id]
                set ordRow [fb_select1 $conn {
                    SELECT O_C_ID AS O_C_ID FROM ORDERS
                    WHERE O_W_ID = :w_id AND O_D_ID = :d_id AND O_ID = :o_id
                } [dict create w_id $w_id d_id $d_id o_id $o_id]]
                set c_id [dict get $ordRow O_C_ID]
                fb_dml $conn {
                    UPDATE ORDERS SET O_CARRIER_ID = :cid
                    WHERE O_W_ID = :w_id AND O_D_ID = :d_id AND O_ID = :o_id
                } [dict create cid $carrier_id w_id $w_id d_id $d_id o_id $o_id]
                fb_dml $conn {
                    UPDATE ORDER_LINE SET OL_DELIVERY_D = :dd
                    WHERE OL_W_ID = :w_id AND OL_D_ID = :d_id AND OL_O_ID = :o_id
                } [dict create dd $delivery_d w_id $w_id d_id $d_id o_id $o_id]
                set sumRow [fb_select1 $conn {
                    SELECT SUM(OL_AMOUNT) AS TOTAL FROM ORDER_LINE
                    WHERE OL_W_ID = :w_id AND OL_D_ID = :d_id AND OL_O_ID = :o_id
                } [dict create w_id $w_id d_id $d_id o_id $o_id]]
                set total [dict get $sumRow TOTAL]
                fb_dml $conn {
                    UPDATE CUSTOMER SET
                        C_BALANCE = C_BALANCE + :amt,
                        C_DELIVERY_CNT = C_DELIVERY_CNT + 1
                    WHERE C_W_ID = :w_id AND C_D_ID = :d_id AND C_ID = :c_id
                } [dict create amt $total w_id $w_id d_id $d_id c_id $c_id]
                $conn commit
                break
            } innerErr]} {
                catch {$conn rollback}
                if {$attempt < $max_retries && [fb_is_retryable_error $innerErr]} {
                    after [expr {5 + int(rand() * 35)}]
                    continue
                }
                error $innerErr
            }
            }
        }
    } err]} {
        if {$RAISEERROR} { error $err }
        return 0
    }
    return 1
}

# StockLevel transaction (TPC-C 2.8) - read-only
proc slev { conn w_id stock_level_d_id RAISEERROR fb_storedprocs } {
    namespace import -force ::tpcccommon::*
    set threshold [RandomNumber 10 20]
    set max_retries 3
    for {set attempt 0} {$attempt <= $max_retries} {incr attempt} {
    $conn begintransaction
    if {[catch {
        set distRow [fb_select1 $conn {
            SELECT D_NEXT_O_ID AS D_NEXT_O_ID FROM DISTRICT
            WHERE D_W_ID = :w_id AND D_ID = :d_id
        } [dict create w_id $w_id d_id $stock_level_d_id]]
        set next_o_id [dict get $distRow D_NEXT_O_ID]
        fb_select $conn {
            SELECT COUNT(DISTINCT S_I_ID) AS LOWS
            FROM ORDER_LINE, STOCK
            WHERE OL_W_ID = :w_id AND OL_D_ID = :d_id
              AND OL_O_ID < :hi AND OL_O_ID >= :lo
              AND S_W_ID = :w_id AND S_I_ID = OL_I_ID
              AND S_QUANTITY < :thr
        } [dict create w_id $w_id d_id $stock_level_d_id \
                       hi $next_o_id lo [expr {$next_o_id - 20}] thr $threshold]
        $conn commit
    } err]} {
        catch {$conn rollback}
        if {$attempt < $max_retries && [fb_is_retryable_error $err]} {
            after [expr {5 + int(rand() * 35)}]
            continue
        }
        if {$RAISEERROR} { error $err }
        return 0
    }
    return 1
    }
}
