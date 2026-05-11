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

# ---------------------------------------------------------------------
# TPROC-C bulk loader.
#
# Firebird has no COPY/BCP equivalent, so we use prepared INSERT
# statements with positional `?` placeholders and commit in batches
# (default 1000 rows). The generated row data follows the same TPC-C
# spec the postgres/mssqls drivers use; helper procs come from the
# tpcccommon module.
# ---------------------------------------------------------------------

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
        VALUES (?, ?, ?, ?, ?)
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
        $stmt execute [list $i_id $i_im_id $i_name $i_price $i_data]
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
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    } [list $w_id $name [lindex $addr 0] [lindex $addr 1] [lindex $addr 2] \
            [lindex $addr 3] [lindex $addr 4] \
            [format "%4.4f" [expr {[RandomNumber 0 2000]/10000.0}]] \
            300000.00]
    return 1
}

proc fb_load_districts { conn w_id DIST_PER_WARE CUST_PER_DIST } {
    namespace import -force ::tpcccommon::*
    set chArr $::fb_loader::chArr; set chLen $::fb_loader::chLen
    set stmt [$conn prepare {
        INSERT INTO DISTRICT (D_ID, D_W_ID, D_NAME, D_STREET_1, D_STREET_2,
                              D_CITY, D_STATE, D_ZIP, D_TAX, D_YTD,
                              D_NEXT_O_ID)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    }]
    $conn begintransaction
    for {set d_id 1} {$d_id <= $DIST_PER_WARE} {incr d_id} {
        set name [MakeAlphaString 6 10 $chArr $chLen]
        set addr [MakeAddress $chArr $chLen]
        $stmt execute [list $d_id $w_id $name \
            [lindex $addr 0] [lindex $addr 1] [lindex $addr 2] \
            [lindex $addr 3] [lindex $addr 4] \
            [format "%4.4f" [expr {[RandomNumber 0 2000]/10000.0}]] \
            30000.00 \
            [expr {$CUST_PER_DIST + 1}]]
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
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    }]
    set stmtHist [$conn prepare {
        INSERT INTO HISTORY (H_C_ID, H_C_D_ID, H_C_W_ID, H_W_ID, H_D_ID,
                             H_DATE, H_AMOUNT, H_DATA)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
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
            $stmtCust execute [list $c_id $d_id $w_id $c_first OE $c_last \
                [lindex $addr 0] [lindex $addr 1] [lindex $addr 2] \
                [lindex $addr 3] [lindex $addr 4] $phone $ts $credit \
                50000.00 $discount -10.00 $c_data 10.00 1 0]
            set h_data [MakeAlphaString 12 24 $chArr $chLen]
            $stmtHist execute [list $c_id $d_id $w_id $w_id $d_id \
                $ts 10.00 $h_data]
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
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
        $stmt execute [concat [list $s_i_id $w_id $qty] $dists \
                              [list $s_data 0 0 0]]
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
                $stmtOrders execute $ord
                $stmtNewOrder execute [dict create no_o_id $o_id \
                                                   no_d_id $d_id no_w_id $w_id]
            } else {
                dict set ord o_carrier_id [RandomNumber 1 10]
                $stmtOrders execute $ord
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
                $stmtOrderLine execute $olRow
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

# Driver procs (stubs until C5/C6 land)
proc neword   { conn no_w_id w_id_input RAISEERROR fb_storedprocs } { error "fb neword not yet implemented" }
proc payment  { conn p_w_id w_id_input RAISEERROR fb_storedprocs } { error "fb payment not yet implemented" }
proc delivery { conn w_id RAISEERROR fb_storedprocs }              { error "fb delivery not yet implemented" }
proc ostat    { conn w_id RAISEERROR fb_storedprocs }              { error "fb ostat not yet implemented" }
proc slev     { conn w_id stock_level_d_id RAISEERROR fb_storedprocs } { error "fb slev not yet implemented" }
