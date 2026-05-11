# Firebird TPROC-H (TPC-H-like OLAP) implementation.
#
# Provides the TPC-H schema build, the 22 TPC-H queries adapted for
# Firebird SQL dialect, and the refresh streams (RF1/RF2).
#
# Connection plumbing reuses fb_build_connstr / ConnectToFirebird from
# fboltp.tcl, which is sourced before this file by hammerdbcli.

proc fb_tpch_table_ddl {} {
    # 8 TPC-H tables in Firebird SQL dialect. BIGINT for keys
    # (NUMERIC without precision is unfriendly to ODBC clients),
    # NUMERIC(12,2) for money, TIMESTAMP for dates, explicit
    # VARCHAR/CHAR lengths.
    set ddl [list]
    lappend ddl {CREATE TABLE REGION (
        R_REGIONKEY BIGINT NOT NULL,
        R_NAME      CHAR(25),
        R_COMMENT   VARCHAR(152),
        CONSTRAINT REGION_PK PRIMARY KEY (R_REGIONKEY))}
    lappend ddl {CREATE TABLE NATION (
        N_NATIONKEY BIGINT NOT NULL,
        N_NAME      CHAR(25),
        N_REGIONKEY BIGINT,
        N_COMMENT   VARCHAR(152),
        CONSTRAINT NATION_PK PRIMARY KEY (N_NATIONKEY))}
    lappend ddl {CREATE TABLE SUPPLIER (
        S_SUPPKEY   BIGINT NOT NULL,
        S_NATIONKEY BIGINT,
        S_COMMENT   VARCHAR(102),
        S_NAME      CHAR(25),
        S_ADDRESS   VARCHAR(40),
        S_PHONE     CHAR(15),
        S_ACCTBAL   NUMERIC(12,2),
        CONSTRAINT SUPPLIER_PK PRIMARY KEY (S_SUPPKEY))}
    lappend ddl {CREATE TABLE PART (
        P_PARTKEY     BIGINT NOT NULL,
        P_TYPE        VARCHAR(25),
        P_SIZE        BIGINT,
        P_BRAND       CHAR(10),
        P_NAME        VARCHAR(55),
        P_CONTAINER   CHAR(10),
        P_MFGR        CHAR(25),
        P_RETAILPRICE NUMERIC(12,2),
        P_COMMENT     VARCHAR(23),
        CONSTRAINT PART_PK PRIMARY KEY (P_PARTKEY))}
    lappend ddl {CREATE TABLE PARTSUPP (
        PS_PARTKEY    BIGINT NOT NULL,
        PS_SUPPKEY    BIGINT NOT NULL,
        PS_SUPPLYCOST NUMERIC(12,2) NOT NULL,
        PS_AVAILQTY   BIGINT,
        PS_COMMENT    VARCHAR(199),
        CONSTRAINT PARTSUPP_PK PRIMARY KEY (PS_PARTKEY, PS_SUPPKEY))}
    lappend ddl {CREATE TABLE CUSTOMER (
        C_CUSTKEY    BIGINT NOT NULL,
        C_MKTSEGMENT CHAR(10),
        C_NATIONKEY  BIGINT,
        C_NAME       VARCHAR(25),
        C_ADDRESS    VARCHAR(40),
        C_PHONE      CHAR(15),
        C_ACCTBAL    NUMERIC(12,2),
        C_COMMENT    VARCHAR(118),
        CONSTRAINT CUSTOMER_PK PRIMARY KEY (C_CUSTKEY))}
    lappend ddl {CREATE TABLE ORDERS (
        O_ORDERDATE     TIMESTAMP,
        O_ORDERKEY      BIGINT NOT NULL,
        O_CUSTKEY       BIGINT NOT NULL,
        O_ORDERPRIORITY CHAR(15),
        O_SHIPPRIORITY  BIGINT,
        O_CLERK         CHAR(15),
        O_ORDERSTATUS   CHAR(1),
        O_TOTALPRICE    NUMERIC(12,2),
        O_COMMENT       VARCHAR(79),
        CONSTRAINT ORDERS_PK PRIMARY KEY (O_ORDERKEY))}
    lappend ddl {CREATE TABLE LINEITEM (
        L_SHIPDATE      TIMESTAMP,
        L_ORDERKEY      BIGINT NOT NULL,
        L_DISCOUNT      NUMERIC(12,2) NOT NULL,
        L_EXTENDEDPRICE NUMERIC(12,2) NOT NULL,
        L_SUPPKEY       BIGINT NOT NULL,
        L_QUANTITY      NUMERIC(12,2) NOT NULL,
        L_RETURNFLAG    CHAR(1),
        L_PARTKEY       BIGINT NOT NULL,
        L_LINESTATUS    CHAR(1),
        L_TAX           NUMERIC(12,2) NOT NULL,
        L_COMMITDATE    TIMESTAMP,
        L_RECEIPTDATE   TIMESTAMP,
        L_SHIPMODE      CHAR(10),
        L_LINENUMBER    BIGINT NOT NULL,
        L_SHIPINSTRUCT  CHAR(25),
        L_COMMENT       VARCHAR(44),
        CONSTRAINT LINEITEM_PK PRIMARY KEY (L_ORDERKEY, L_LINENUMBER))}
    return $ddl
}

proc fb_create_tpch_schema { conn } {
    set count 0
    foreach stmt [fb_tpch_table_ddl] {
        $conn allrows $stmt
        incr count
    }
    return $count
}

# ---------------------------------------------------------------------
# TPROC-H bulk loader. Follows the same approach as TPROC-C C4: tdbc::
# odbc prepared INSERTs with `:name` params, batched in transactions.
# Generation logic comes from tpchcommon-1.0.tm (mk_time, mk_sparse,
# pick_str_1, V_STR, TEXT_1, gen_phone, RandomNumber, etc.) - the
# same helpers used by every other HammerDB TPROC-H driver.
# ---------------------------------------------------------------------

namespace eval ::fb_tpch_loader {
    variable BATCH 1000
}

proc fb_tpch_load_region { conn } {
    namespace import -force ::tpchcommon::*
    set stmt [$conn prepare {
        INSERT INTO REGION (R_REGIONKEY, R_NAME, R_COMMENT)
        VALUES (:k, :n, :c)
    }]
    $conn begintransaction
    for {set i 1} {$i <= 5} {incr i} {
        set code [expr {$i - 1}]
        set text [lindex [lindex [get_dists regions] $code] 0]
        set comment [TEXT_1 72]
        fb_exec $stmt [dict create k $code n $text c $comment]
    }
    $conn commit
    $stmt close
    return 5
}

proc fb_tpch_load_nation { conn } {
    namespace import -force ::tpchcommon::*
    # Nation-to-region mapping per TPC-H spec.
    set stmt [$conn prepare {
        INSERT INTO NATION (N_NATIONKEY, N_NAME, N_REGIONKEY, N_COMMENT)
        VALUES (:k, :n, :r, :c)
    }]
    $conn begintransaction
    for {set i 1} {$i <= 25} {incr i} {
        set code [expr {$i - 1}]
        set text [lindex [lindex [get_dists nations] $code] 0]
        switch -- $code {
            0 - 4 - 5 - 14 - 15 - 16 { set rcode 0 }
            1 - 2 - 3 - 17 - 24      { set rcode 1 }
            8 - 9 - 12 - 18 - 21     { set rcode 2 }
            6 - 7 - 19 - 22 - 23     { set rcode 3 }
            10 - 11 - 13 - 20        { set rcode 4 }
            default                  { set rcode 0 }
        }
        set comment [TEXT_1 72]
        fb_exec $stmt [dict create k $code n $text r $rcode c $comment]
    }
    $conn commit
    $stmt close
    return 25
}

proc fb_tpch_load_supplier { conn start_row end_row } {
    namespace import -force ::tpchcommon::*
    variable ::fb_tpch_loader::BATCH
    set BBB_COMMEND  "Recommends"
    set BBB_COMPLAIN "Complaints"
    set stmt [$conn prepare {
        INSERT INTO SUPPLIER
            (S_SUPPKEY, S_NATIONKEY, S_COMMENT, S_NAME,
             S_ADDRESS, S_PHONE, S_ACCTBAL)
        VALUES (:k, :n, :c, :nm, :a, :p, :ab)
    }]
    $conn begintransaction
    set inBatch 0
    for {set i $start_row} {$i <= $end_row} {incr i} {
        set name [format "Supplier#%09d" $i]
        set address [V_STR 25]
        set nation_code [RandomNumber 0 24]
        set phone [gen_phone]
        set acctbal [format "%4.2f" [expr {[RandomNumber -99999 999999] / 100.0}]]
        set comment [TEXT_1 63]
        # Spec: ~0.1% of suppliers have a flagged comment.
        set bad_press [RandomNumber 1 10000]
        if {$bad_press <= 10} {
            set type [RandomNumber 0 100]
            set noise [RandomNumber 0 19]
            set offset [RandomNumber 0 [expr {19 + $noise}]]
            set st [expr {9 + $offset + $noise}]
            set fi [expr {$st + 10}]
            set marker [expr {$type < 50 ? $BBB_COMPLAIN : $BBB_COMMEND}]
            set comment [string replace $comment $st $fi $marker]
        }
        fb_exec $stmt [dict create k $i n $nation_code c $comment \
            nm $name a $address p $phone ab $acctbal]
        incr inBatch
        if {$inBatch >= $::fb_tpch_loader::BATCH} {
            $conn commit; $conn begintransaction
            set inBatch 0
        }
    }
    $conn commit
    $stmt close
    return [expr {$end_row - $start_row + 1}]
}

proc fb_tpch_load_customer { conn start_row end_row } {
    namespace import -force ::tpchcommon::*
    variable ::fb_tpch_loader::BATCH
    set stmt [$conn prepare {
        INSERT INTO CUSTOMER
            (C_CUSTKEY, C_MKTSEGMENT, C_NATIONKEY, C_NAME,
             C_ADDRESS, C_PHONE, C_ACCTBAL, C_COMMENT)
        VALUES (:k, :m, :n, :nm, :a, :p, :ab, :c)
    }]
    $conn begintransaction
    set inBatch 0
    for {set i $start_row} {$i <= $end_row} {incr i} {
        set name [format "Customer#%09d" $i]
        set address [V_STR 25]
        set nation_code [RandomNumber 0 24]
        set phone [gen_phone]
        set acctbal [format "%4.2f" [expr {[RandomNumber -99999 999999] / 100.0}]]
        set mktsegment [pick_str_1 msegmnt]
        set comment [TEXT_1 73]
        fb_exec $stmt [dict create k $i m $mktsegment n $nation_code \
            nm $name a $address p $phone ab $acctbal c $comment]
        incr inBatch
        if {$inBatch >= $::fb_tpch_loader::BATCH} {
            $conn commit; $conn begintransaction
            set inBatch 0
        }
    }
    $conn commit
    $stmt close
    return [expr {$end_row - $start_row + 1}]
}

proc fb_tpch_load_part_partsupp { conn start_row end_row scale_factor } {
    # Each PART row generates 4 PARTSUPP rows (one per supplier number
    # 0..3, picked via PART_SUPP_BRIDGE so foreign keys land on real
    # supplier IDs).
    namespace import -force ::tpchcommon::*
    variable ::fb_tpch_loader::BATCH
    set stmtPart [$conn prepare {
        INSERT INTO PART
            (P_PARTKEY, P_TYPE, P_SIZE, P_BRAND, P_NAME,
             P_CONTAINER, P_MFGR, P_RETAILPRICE, P_COMMENT)
        VALUES (:k, :t, :sz, :b, :n, :ct, :mf, :rp, :c)
    }]
    set stmtPartSupp [$conn prepare {
        INSERT INTO PARTSUPP
            (PS_PARTKEY, PS_SUPPKEY, PS_SUPPLYCOST, PS_AVAILQTY, PS_COMMENT)
        VALUES (:pk, :sk, :sc, :aq, :c)
    }]
    $conn begintransaction
    set inBatch 0
    for {set i $start_row} {$i <= $end_row} {incr i} {
        set partkey $i
        set name ""
        for {set j 0} {$j < 4} {incr j} {
            append name [pick_str_1 colors] " "
        }
        append name [pick_str_1 colors]
        set mf [RandomNumber 1 5]
        set mfgr "Manufacturer#$mf"
        set brand "Brand#[expr {$mf * 10 + [RandomNumber 1 5]}]"
        set type [pick_str_1 p_types]
        set size [RandomNumber 1 50]
        set container [pick_str_1 p_cntr]
        set price [rpb_routine $i]
        set comment [TEXT_1 14]
        fb_exec $stmtPart [dict create k $partkey t $type sz $size \
            b $brand n $name ct $container mf $mfgr rp $price c $comment]
        for {set k 0} {$k < 4} {incr k} {
            set suppkey [PART_SUPP_BRIDGE $i $k $scale_factor]
            set qty [RandomNumber 1 9999]
            set scost [format "%4.2f" [expr {[RandomNumber 100 100000] / 100.0}]]
            set pscomment [TEXT_1 124]
            fb_exec $stmtPartSupp [dict create pk $partkey sk $suppkey \
                sc $scost aq $qty c $pscomment]
        }
        incr inBatch
        if {$inBatch >= $::fb_tpch_loader::BATCH} {
            $conn commit; $conn begintransaction
            set inBatch 0
        }
    }
    $conn commit
    $stmtPart close
    $stmtPartSupp close
    return [expr {$end_row - $start_row + 1}]
}

proc fb_tpch_load_orders_lineitem { conn start_row end_row scale_factor } {
    # Per-order, generates 1..7 LINEITEM rows. Spec totals: scale 1
    # has 1.5M ORDERS, average 4 lineitems each = ~6M LINEITEM rows.
    namespace import -force ::tpchcommon::*
    variable ::fb_tpch_loader::BATCH
    set L_PKEY_MAX  [expr {int(200000 * $scale_factor)}]
    set O_CKEY_MAX  [expr {int(150000 * $scale_factor)}]
    set O_ODATE_MAX [expr {(92001 + 2557 - (121 + 30) - 1)}]

    # Pre-compute the date table once per VU to amortise mk_time_bcp.
    array set ascdate {}
    for {set d 1} {$d <= 2557} {incr d} {
        set ascdate($d) [mk_time_bcp $d]
    }

    set stmtOrders [$conn prepare {
        INSERT INTO ORDERS
            (O_ORDERDATE, O_ORDERKEY, O_CUSTKEY, O_ORDERPRIORITY,
             O_SHIPPRIORITY, O_CLERK, O_ORDERSTATUS, O_TOTALPRICE, O_COMMENT)
        VALUES (:d, :k, :ck, :op, :sp, :cl, :os, :tp, :c)
    }]
    set stmtLine [$conn prepare {
        INSERT INTO LINEITEM
            (L_SHIPDATE, L_ORDERKEY, L_DISCOUNT, L_EXTENDEDPRICE,
             L_SUPPKEY, L_QUANTITY, L_RETURNFLAG, L_PARTKEY,
             L_LINESTATUS, L_TAX, L_COMMITDATE, L_RECEIPTDATE,
             L_SHIPMODE, L_LINENUMBER, L_SHIPINSTRUCT, L_COMMENT)
        VALUES (:sd, :ok, :dc, :ep, :sk, :q, :rf, :pk, :ls, :tx,
                :cd, :rd, :sm, :ln, :si, :c)
    }]
    set delta 1
    $conn begintransaction
    set inBatch 0
    for {set i $start_row} {$i <= $end_row} {incr i} {
        set okey [mk_sparse $i 0]
        set custkey [RandomNumber 1 $O_CKEY_MAX]
        while {$custkey % 3 == 0} {
            set custkey [expr {$custkey + $delta}]
            if {$custkey > $O_CKEY_MAX} { set custkey $O_CKEY_MAX }
            set delta [expr {$delta * -1}]
        }
        set tmp_date [RandomNumber 92002 $O_ODATE_MAX]
        set odate $ascdate([expr {$tmp_date - 92001}])
        set opriority [pick_str_1 o_oprio]
        set clk_num [RandomNumber 1 [expr {int($scale_factor * 1000)}]]
        if {$clk_num < 1} { set clk_num 1 }
        set clerk [format "Clerk#%09d" $clk_num]
        set comment [TEXT_1 49]
        set spriority 0
        set totalprice 0
        set ocnt 0
        set lcnt [RandomNumber 1 7]
        # Generate lineitems first to compute totalprice.
        set lines [list]
        for {set l 0} {$l < $lcnt} {incr l} {
            set lnum [expr {$l + 1}]
            set lq [RandomNumber 1 50]
            set ld [format "%1.2f" [expr {[RandomNumber 0 10] / 100.0}]]
            set ltax [format "%1.2f" [expr {[RandomNumber 0 8] / 100.0}]]
            set linstruct [pick_str_1 instruct]
            set lsmode [pick_str_1 smode]
            set lcomment [TEXT_1 27]
            set lpk [RandomNumber 1 $L_PKEY_MAX]
            set rprice [rpb_routine $lpk]
            set supp_num [RandomNumber 0 3]
            set lsk [PART_SUPP_BRIDGE $lpk $supp_num $scale_factor]
            set lep [format "%4.2f" [expr {$rprice * $lq}]]
            set ldi [expr {int(round($ld * 100))}]
            set lti [expr {int(round($ltax * 100))}]
            set lei [expr {int(round($lep * 100))}]
            set totalprice [expr {$totalprice + (($lei * (100 - $ldi)) / 100) * (100 + $lti) / 100}]
            set s_off [expr {[RandomNumber 1 121] + $tmp_date}]
            set c_off [expr {[RandomNumber 30 90] + $tmp_date}]
            set r_off [expr {[RandomNumber 1 30] + $s_off}]
            set lsd $ascdate([expr {$s_off - 92001}])
            set lcd $ascdate([expr {$c_off - 92001}])
            set lrd $ascdate([expr {$r_off - 92001}])
            set lrflag [expr {[julian $r_off] <= 95168 ? [pick_str_1 rflag] : "N"}]
            if {[julian $s_off] <= 95168} {
                incr ocnt
                set lstatus "F"
            } else {
                set lstatus "O"
            }
            lappend lines [dict create sd $lsd ok $okey dc $ld ep $lep \
                sk $lsk q $lq rf $lrflag pk $lpk ls $lstatus tx $ltax \
                cd $lcd rd $lrd sm $lsmode ln $lnum si $linstruct c $lcomment]
        }
        set totalprice [format "%.2f" [expr {double($totalprice) / 100}]]
        set orderstatus [expr {$ocnt == 0 ? "O" : ($ocnt == $lcnt ? "F" : "P")}]
        fb_exec $stmtOrders [dict create d $odate k $okey ck $custkey \
            op $opriority sp $spriority cl $clerk os $orderstatus \
            tp $totalprice c $comment]
        foreach line $lines { fb_exec $stmtLine $line }
        incr inBatch
        if {$inBatch >= 100} {
            $conn commit; $conn begintransaction
            set inBatch 0
        }
    }
    $conn commit
    $stmtOrders close
    $stmtLine close
    return [expr {$end_row - $start_row + 1}]
}

proc fb_load_tpch { conn scale_factor } {
    # Orchestrator: load all 8 TPC-H tables for the given scale.
    set sup [expr {int(10000 * $scale_factor)}]
    set cust [expr {int(150000 * $scale_factor)}]
    set part [expr {int(200000 * $scale_factor)}]
    set ord [expr {int(1500000 * $scale_factor)}]
    set out [dict create]
    dict set out region    [fb_tpch_load_region $conn]
    dict set out nation    [fb_tpch_load_nation $conn]
    dict set out supplier  [fb_tpch_load_supplier $conn 1 $sup]
    dict set out customer  [fb_tpch_load_customer $conn 1 $cust]
    dict set out part_partsupp \
        [fb_tpch_load_part_partsupp $conn 1 $part $scale_factor]
    dict set out orders_lineitem \
        [fb_tpch_load_orders_lineitem $conn 1 $ord $scale_factor]
    return $out
}

# ---------------------------------------------------------------------
# TPROC-H power test: RF1 (insert refresh), 22 queries, RF2 (delete).
#
# Per TPC-H 5.3.4 a power test runs RF1 → all 22 queries in their
# ordered sequence → RF2, then reports the geometric mean of query
# times. Multi-VU "throughput" tests are implemented separately in
# `fb_tpch_query_stream` / `fb_tpch_refresh_loop` for server-mode
# execution (see `.github/workflows/scripts/fb_tpch_throughput.tcl`).
# ---------------------------------------------------------------------

proc fb_tpch_rf1 { conn scale_factor upd_num } {
    # Insert SF*1500 new orders and their lineitems (1-7 per order).
    # Orderkeys are produced by mk_sparse with upd_num >= 1, ensuring
    # they don't collide with the original load (upd_num=0).
    namespace import -force ::tpchcommon::*
    set L_PKEY_MAX [expr {int(200000 * $scale_factor)}]
    set O_CKEY_MAX [expr {int(150000 * $scale_factor)}]
    set O_ODATE_MAX [expr {(92001 + 2557 - (121 + 30) - 1)}]
    set sfrows [expr {int($scale_factor * 1500)}]
    if {$sfrows < 1} { set sfrows 1 }
    set startindex [expr {(($upd_num * $sfrows) - $sfrows) + 1}]
    set endindex [expr {$upd_num * $sfrows}]

    array set ascdate {}
    for {set d 1} {$d <= 2557} {incr d} { set ascdate($d) [mk_time_bcp $d] }

    set stmtO [$conn prepare {
        INSERT INTO ORDERS
            (O_ORDERDATE, O_ORDERKEY, O_CUSTKEY, O_ORDERPRIORITY,
             O_SHIPPRIORITY, O_CLERK, O_ORDERSTATUS, O_TOTALPRICE, O_COMMENT)
        VALUES (:d, :k, :ck, :op, :sp, :cl, :os, :tp, :c)
    }]
    set stmtL [$conn prepare {
        INSERT INTO LINEITEM
            (L_SHIPDATE, L_ORDERKEY, L_DISCOUNT, L_EXTENDEDPRICE,
             L_SUPPKEY, L_QUANTITY, L_RETURNFLAG, L_PARTKEY,
             L_LINESTATUS, L_TAX, L_COMMITDATE, L_RECEIPTDATE,
             L_SHIPMODE, L_LINENUMBER, L_SHIPINSTRUCT, L_COMMENT)
        VALUES (:sd, :ok, :dc, :ep, :sk, :q, :rf, :pk, :ls, :tx,
                :cd, :rd, :sm, :ln, :si, :c)
    }]
    set delta 1
    $conn begintransaction
    set inBatch 0
    set inserted 0
    for {set i $startindex} {$i <= $endindex} {incr i} {
        set okey [mk_sparse $i [expr {1 + $upd_num / 100}]]
        set custkey [RandomNumber 1 $O_CKEY_MAX]
        while {$custkey % 3 == 0} {
            set custkey [expr {$custkey + $delta}]
            if {$custkey > $O_CKEY_MAX} { set custkey $O_CKEY_MAX }
            set delta [expr {$delta * -1}]
        }
        set tmp_date [RandomNumber 92002 $O_ODATE_MAX]
        set odate $ascdate([expr {$tmp_date - 92001}])
        set opriority [pick_str_1 o_oprio]
        set clk_num [RandomNumber 1 [expr {int($scale_factor * 1000)}]]
        if {$clk_num < 1} { set clk_num 1 }
        set clerk [format "Clerk#%09d" $clk_num]
        set comment [TEXT_1 49]
        set totalprice 0
        set ocnt 0
        set lcnt [RandomNumber 1 7]
        for {set l 0} {$l < $lcnt} {incr l} {
            set lnum [expr {$l + 1}]
            set lq [RandomNumber 1 50]
            set ld [format "%1.2f" [expr {[RandomNumber 0 10] / 100.0}]]
            set ltax [format "%1.2f" [expr {[RandomNumber 0 8] / 100.0}]]
            set linstruct [pick_str_1 instruct]
            set lsmode [pick_str_1 smode]
            set lcomment [TEXT_1 27]
            set lpk [RandomNumber 1 $L_PKEY_MAX]
            set rprice [rpb_routine $lpk]
            set supp_num [RandomNumber 0 3]
            set lsk [PART_SUPP_BRIDGE $lpk $supp_num $scale_factor]
            set lep [format "%4.2f" [expr {$rprice * $lq}]]
            set ldi [expr {int(round($ld * 100))}]
            set lti [expr {int(round($ltax * 100))}]
            set lei [expr {int(round($lep * 100))}]
            set totalprice [expr {$totalprice + (($lei * (100 - $ldi)) / 100) * (100 + $lti) / 100}]
            set s_off [expr {[RandomNumber 1 121] + $tmp_date}]
            set c_off [expr {[RandomNumber 30 90] + $tmp_date}]
            set r_off [expr {[RandomNumber 1 30] + $s_off}]
            set lsd $ascdate([expr {$s_off - 92001}])
            set lcd $ascdate([expr {$c_off - 92001}])
            set lrd $ascdate([expr {$r_off - 92001}])
            set lrflag [expr {[julian $r_off] <= 95168 ? [pick_str_1 rflag] : "N"}]
            if {[julian $s_off] <= 95168} { incr ocnt; set lstatus "F" } else { set lstatus "O" }
            fb_exec $stmtL [dict create sd $lsd ok $okey dc $ld ep $lep \
                sk $lsk q $lq rf $lrflag pk $lpk ls $lstatus tx $ltax \
                cd $lcd rd $lrd sm $lsmode ln $lnum si $linstruct c $lcomment]
        }
        set totalprice [format "%.2f" [expr {double($totalprice) / 100}]]
        set orderstatus [expr {$ocnt == 0 ? "O" : ($ocnt == $lcnt ? "F" : "P")}]
        fb_exec $stmtO [dict create d $odate k $okey ck $custkey \
            op $opriority sp 0 cl $clerk os $orderstatus \
            tp $totalprice c $comment]
        incr inserted
        incr inBatch
        if {$inBatch >= 100} { $conn commit; $conn begintransaction; set inBatch 0 }
    }
    $conn commit
    $stmtO close
    $stmtL close
    return $inserted
}

proc fb_tpch_rf2 { conn scale_factor upd_num } {
    # Delete SF*1500 orders + their lineitems by orderkey, using the
    # same mk_sparse formula as RF1 with the same upd_num so we
    # round-trip the inserts.
    namespace import -force ::tpchcommon::*
    set sfrows [expr {int($scale_factor * 1500)}]
    if {$sfrows < 1} { set sfrows 1 }
    set startindex [expr {(($upd_num * $sfrows) - $sfrows) + 1}]
    set endindex [expr {$upd_num * $sfrows}]
    set stmtL [$conn prepare {DELETE FROM LINEITEM WHERE L_ORDERKEY = :k}]
    set stmtO [$conn prepare {DELETE FROM ORDERS WHERE O_ORDERKEY = :k}]
    $conn begintransaction
    set inBatch 0
    set deleted 0
    for {set i $startindex} {$i <= $endindex} {incr i} {
        set okey [mk_sparse $i [expr {1 + $upd_num / 100}]]
        fb_exec $stmtL [dict create k $okey]
        fb_exec $stmtO [dict create k $okey]
        incr deleted
        incr inBatch
        if {$inBatch >= 100} { $conn commit; $conn begintransaction; set inBatch 0 }
    }
    $conn commit
    $stmtL close
    $stmtO close
    return $deleted
}

# Substitute :N placeholders in a TPC-H query template with concrete
# values per spec. Direct port of pgolap.tcl::sub_query, but pulls
# the template from fb_tpch_queries instead of the postgres `sql`
# global, and uses pick_str_1 (we don't have the pick_str_2 dist
# preloaded the way postgres does at namespace init).
proc fb_tpch_sub_query { query_no scale_factor myposition } {
    namespace import -force ::tpchcommon::*
    set queries [fb_tpch_queries]
    set q [dict get $queries $query_no]
    switch $query_no {
        1 { regsub -all {:1} $q [RandomNumber 60 120] q }
        2 {
            regsub -all {:1} $q [RandomNumber 1 50] q
            set qc [lindex [split [pick_str_1 p_types]] 2]
            regsub -all {:2} $q $qc q
            regsub -all {:3} $q [pick_str_1 regions] q
        }
        3 {
            regsub -all {:1} $q [pick_str_1 msegmnt] q
            set d [RandomNumber 1 31]
            if {[string length $d] eq 1} { set d "0$d" }
            regsub -all {:2} $q "1995-03-$d" q
        }
        4 {
            set tmp [RandomNumber 1 58]
            set yr [expr {93 + $tmp / 12}]
            set mon [expr {$tmp % 12 + 1}]
            if {[string length $mon] eq 1} { set mon "0$mon" }
            regsub -all {:1} $q "19$yr-$mon-01" q
        }
        5 {
            regsub -all {:1} $q [pick_str_1 regions] q
            regsub -all {:2} $q "19[RandomNumber 93 97]-01-01" q
        }
        6 {
            regsub -all {:1} $q "19[RandomNumber 93 97]-01-01" q
            regsub -all {:2} $q "0.0[RandomNumber 2 9]" q
            regsub -all {:3} $q [RandomNumber 24 25] q
        }
        7 {
            set qc [pick_str_1 nations2]
            regsub -all {:1} $q $qc q
            set qc2 $qc
            while {$qc2 eq $qc} { set qc2 [pick_str_1 nations2] }
            regsub -all {:2} $q $qc2 q
        }
        8 {
            set qc [pick_str_1 nations2]
            regsub -all {:1} $q $qc q
            # Map nation to its region (same switch as mk_nation).
            set nlist [get_dists nations2]
            set nind [lsearch -glob $nlist "*$qc*"]
            switch -- $nind {
                0 - 4 - 5 - 14 - 15 - 16 { set rg "AFRICA" }
                1 - 2 - 3 - 17 - 24      { set rg "AMERICA" }
                8 - 9 - 12 - 18 - 21     { set rg "ASIA" }
                6 - 7 - 19 - 22 - 23     { set rg "EUROPE" }
                10 - 11 - 13 - 20        { set rg "MIDDLE EAST" }
                default                  { set rg "AFRICA" }
            }
            regsub -all {:2} $q $rg q
            regsub -all {:3} $q [pick_str_1 p_types] q
        }
        9  { regsub -all {:1} $q [pick_str_1 colors] q }
        10 {
            set tmp [RandomNumber 1 24]
            set yr [expr {93 + $tmp / 12}]
            set mon [expr {$tmp % 12 + 1}]
            if {[string length $mon] eq 1} { set mon "0$mon" }
            regsub -all {:1} $q "19$yr-$mon-01" q
        }
        11 {
            regsub -all {:1} $q [pick_str_1 nations2] q
            set frac [format "%11.10f" [expr {0.0001 / $scale_factor}]]
            regsub -all {:2} $q $frac q
        }
        12 {
            set qc [pick_str_1 smode]
            regsub -all {:1} $q $qc q
            set qc2 $qc
            while {$qc2 eq $qc} { set qc2 [pick_str_1 smode] }
            regsub -all {:2} $q $qc2 q
            regsub -all {:3} $q "19[RandomNumber 93 97]-01-01" q
        }
        13 {
            regsub -all {:1} $q [pick_str_1 Q13a] q
            regsub -all {:2} $q [pick_str_1 Q13b] q
        }
        14 {
            set tmp [RandomNumber 1 60]
            set yr [expr {93 + $tmp / 12}]
            set mon [expr {$tmp % 12 + 1}]
            if {[string length $mon] eq 1} { set mon "0$mon" }
            regsub -all {:1} $q "19$yr-$mon-01" q
        }
        15 {
            # :VID is the per-stream view-name suffix.
            regsub -all {:VID} $q $myposition q
            set tmp [RandomNumber 1 58]
            set yr [expr {93 + $tmp / 12}]
            set mon [expr {$tmp % 12 + 1}]
            if {[string length $mon] eq 1} { set mon "0$mon" }
            regsub -all {:1} $q "19$yr-$mon-01" q
        }
        16 {
            # IMPORTANT: substitute :10 first, then descend - otherwise
            # `regsub :1` matches the leading `:1` of `:10` and breaks
            # the IN clause (Token unknown `#` if Brand# leaks through).
            set qc [lindex [split [pick_str_1 p_types]] 0]
            for {set i 10} {$i >= 3} {incr i -1} {
                regsub -all ":$i" $q [RandomNumber 1 50] q
            }
            regsub -all {:2} $q $qc q
            regsub -all {:1} $q "Brand#[RandomNumber 1 5][RandomNumber 1 5]" q
        }
        17 {
            regsub -all {:1} $q "Brand#[RandomNumber 1 5][RandomNumber 1 5]" q
            regsub -all {:2} $q [pick_str_1 p_cntr] q
        }
        18 { regsub -all {:1} $q [RandomNumber 312 315] q }
        19 {
            regsub -all {:1} $q "Brand#[RandomNumber 1 5][RandomNumber 1 5]" q
            regsub -all {:2} $q "Brand#[RandomNumber 1 5][RandomNumber 1 5]" q
            regsub -all {:3} $q "Brand#[RandomNumber 1 5][RandomNumber 1 5]" q
            regsub -all {:4} $q [RandomNumber 1 10] q
            regsub -all {:5} $q [RandomNumber 10 20] q
            regsub -all {:6} $q [RandomNumber 20 30] q
        }
        20 {
            regsub -all {:1} $q [pick_str_1 colors] q
            regsub -all {:2} $q "19[RandomNumber 93 97]-01-01" q
            regsub -all {:3} $q [pick_str_1 nations2] q
        }
        21 { regsub -all {:1} $q [pick_str_1 nations2] q }
        22 {
            for {set i 1} {$i <= 7} {incr i} {
                regsub -all ":$i" $q [RandomNumber 10 34] q
            }
        }
    }
    return $q
}

# ---------------------------------------------------------------------
# Multi-VU throughput test (TPC-C 5.3.5).
#
# The companion to the power test: N concurrent QUERY streams, each
# running its own permuted ordering of the 22 queries, run in
# parallel with a single REFRESH stream that loops RF1/RF2 pairs.
# Reports per-stream gmean + the overall elapsed.
#
# Embedded Firebird allows only one process to open a .fdb on disk,
# so the throughput test cannot use the embedded engine. The CI
# script (fb_tpch_throughput.tcl) launches a server instance via
# PSFirebird's Start-FirebirdInstance and connects every Tcl thread
# over inet://. fb_build_connstr already supports server mode when
# fb_embedded=false.
#
# fb_tpch_query_stream / fb_tpch_refresh_loop are the worker bodies
# the CI script sends to each Tcl thread. fbolap.tcl itself does NOT
# spawn threads - keeping the threading orchestration in the CI
# script makes it easier to fold in alternative drivers (HammerDB
# vuset/vurun, etc.) later without touching this file.
# ---------------------------------------------------------------------

proc fb_tpch_query_stream { conn scale_factor myposition {verbose false} } {
    namespace import -force ::tpchcommon::*
    set qorder [ordered_set $myposition]
    set qtimes [dict create]
    set qrows [dict create]
    set timings [list]
    foreach qno $qorder {
        set sql [fb_tpch_sub_query $qno $scale_factor [expr {$myposition + 1}]]
        set t0 [clock milliseconds]
        set rows 0
        if {$qno == 15} {
            set parts [split $sql ";"]
            set i 0
            foreach p $parts {
                set p [string trim $p]
                if {$p eq ""} { continue }
                incr i
                if {$i == 2} {
                    set t0 [clock milliseconds]
                    set rs [$conn prepare $p]
                    $rs foreach -as lists row { incr rows }
                    $rs close
                } else {
                    catch {$conn allrows $p}
                }
            }
        } else {
            if {[catch {
                set rs [$conn prepare $sql]
                $rs foreach -as lists row { incr rows }
                $rs close
            } err]} {
                if {$verbose} { puts stderr "stream $myposition Q$qno failed: $err" }
                set rows -1
            }
        }
        set elapsed [expr {[clock milliseconds] - $t0}]
        dict set qtimes $qno $elapsed
        dict set qrows $qno $rows
        if {$rows > 0} { lappend timings $elapsed }
    }
    return [dict create \
        myposition $myposition \
        query_order $qorder \
        query_times_ms $qtimes \
        query_rows $qrows \
        gmean_ms [expr {[llength $timings] > 0 ? [gmean $timings] : 0}] \
        queries_with_rows [llength $timings]]
}

proc fb_tpch_refresh_loop { conn scale_factor base_upd_num stop_tsv } {
    # Loops (RF1, RF2) pairs against the given connection until the
    # named tsv variable in the application namespace becomes 1. Each
    # pair uses its own upd_num so subsequent inserts don't collide
    # with prior refresh sets.
    namespace import -force ::tpchcommon::*
    set pairs 0
    set upd $base_upd_num
    while {1} {
        if {[tsv::get application $stop_tsv]} { break }
        incr upd
        if {[catch {
            fb_tpch_rf1 $conn $scale_factor $upd
            fb_tpch_rf2 $conn $scale_factor $upd
        } err]} {
            puts stderr "refresh-loop pair $pairs ($upd) failed: $err"
            break
        }
        incr pairs
    }
    return [dict create pairs_completed $pairs last_upd_num $upd]
}

proc fb_tpch_power_test { conn scale_factor {myposition 0} {verbose false} } {
    # Run RF1, then the 22 queries in the spec'd order for this stream
    # position, then RF2. Returns dict with per-query timings (ms),
    # rows returned, and geometric mean of timings for queries that
    # returned rows.
    namespace import -force ::tpchcommon::*
    set out [dict create]

    set t0 [clock milliseconds]
    set rf1_rows [fb_tpch_rf1 $conn $scale_factor 1]
    dict set out rf1_rows $rf1_rows
    dict set out rf1_ms [expr {[clock milliseconds] - $t0}]

    set qorder [ordered_set $myposition]
    set qtimes [dict create]
    set qrows [dict create]
    set timings [list]
    foreach qno $qorder {
        set sql [fb_tpch_sub_query $qno $scale_factor [expr {$myposition + 1}]]
        set t0 [clock milliseconds]
        set rows 0
        if {$qno == 15} {
            # View + select + drop. Run the DDL parts, time only the select.
            set parts [split $sql ";"]
            set i 0
            foreach p $parts {
                set p [string trim $p]
                if {$p eq ""} { continue }
                incr i
                if {$i == 2} {
                    set t0 [clock milliseconds]
                    set rs [$conn prepare $p]
                    $rs foreach -as lists row { incr rows }
                    $rs close
                    set elapsed [expr {[clock milliseconds] - $t0}]
                } else {
                    catch {$conn allrows $p}
                }
            }
        } else {
            if {[catch {
                set rs [$conn prepare $sql]
                $rs foreach -as lists row { incr rows }
                $rs close
            } err]} {
                if {$verbose} { puts stderr "Q$qno failed: $err" }
                set rows -1
            }
            set elapsed [expr {[clock milliseconds] - $t0}]
        }
        dict set qtimes $qno $elapsed
        dict set qrows $qno $rows
        if {$rows > 0} { lappend timings $elapsed }
        if {$verbose} { puts "Q$qno: $rows rows in $elapsed ms" }
    }
    dict set out query_order $qorder
    dict set out query_times_ms $qtimes
    dict set out query_rows $qrows
    dict set out gmean_ms [expr {[llength $timings] > 0 ? [gmean $timings] : 0}]
    dict set out queries_with_rows [llength $timings]

    set t0 [clock milliseconds]
    set rf2_rows [fb_tpch_rf2 $conn $scale_factor 1]
    dict set out rf2_rows $rf2_rows
    dict set out rf2_ms [expr {[clock milliseconds] - $t0}]
    return $out
}

proc build_fbtpch {} {
    upvar #0 dbdict dbdict
    upvar #0 configfirebird configfirebird
    setlocalfbtpchvars $configfirebird
    error "build_fbtpch: GUI build flow not yet wired up; DDL is in fb_create_tpch_schema, the 22 queries in fb_tpch_queries, and the bulk loader in fb_load_tpch."
}

# ---------------------------------------------------------------------
# 22 TPC-H queries adapted from PostgreSQL to Firebird SQL dialect.
# Adaptations applied:
#   - PG `interval ':1 day'` / `interval '1 year'` → Firebird `DATEADD`
#     with explicit unit
#   - PG `LIMIT N` → Firebird `ROWS N` (top-level) or `FETCH FIRST N
#     ROWS ONLY` (works in Firebird 4+)
#   - `date '1997-01-01'` → `DATE '1997-01-01'` (case-insensitive in
#     practice, kept as-is)
#   - All other syntax (substr, extract(year from ...), avg/sum/count,
#     between, in, group by/order by/having, left outer join) is
#     dialect-portable
# Placeholders `:1`, `:2`, ... are substitution slots filled at run
# time by tpchcommon::sub_query, NOT tdbc named parameters.
# Q15 (view + select + drop) stays multi-statement; the runner splits
# on `;` like the postgres/mssqls drivers do.
# ---------------------------------------------------------------------

proc fb_tpch_queries {} {
    set q [dict create]
    dict set q 1 {select l_returnflag, l_linestatus, sum(l_quantity) as sum_qty, sum(l_extendedprice) as sum_base_price, sum(l_extendedprice * (1 - l_discount)) as sum_disc_price, sum(l_extendedprice * (1 - l_discount) * (1 + l_tax)) as sum_charge, avg(l_quantity) as avg_qty, avg(l_extendedprice) as avg_price, avg(l_discount) as avg_disc, count(*) as count_order from lineitem where l_shipdate <= dateadd(-:1 day to date '1998-12-01') group by l_returnflag, l_linestatus order by l_returnflag, l_linestatus}
    dict set q 2 {select s_acctbal, s_name, n_name, p_partkey, p_mfgr, s_address, s_phone, s_comment from part, supplier, partsupp, nation, region where p_partkey = ps_partkey and s_suppkey = ps_suppkey and p_size = :1 and p_type like '%:2' and s_nationkey = n_nationkey and n_regionkey = r_regionkey and r_name = ':3' and ps_supplycost = ( select min(ps_supplycost) from partsupp, supplier, nation, region where p_partkey = ps_partkey and s_suppkey = ps_suppkey and s_nationkey = n_nationkey and n_regionkey = r_regionkey and r_name = ':3') order by s_acctbal desc, n_name, s_name, p_partkey}
    dict set q 3 {select l_orderkey, sum(l_extendedprice * (1 - l_discount)) as revenue, o_orderdate, o_shippriority from customer, orders, lineitem where c_mktsegment = ':1' and c_custkey = o_custkey and l_orderkey = o_orderkey and o_orderdate < date ':2' and l_shipdate > date ':2' group by l_orderkey, o_orderdate, o_shippriority order by revenue desc, o_orderdate}
    dict set q 4 {select o_orderpriority, count(*) as order_count from orders where o_orderdate >= date ':1' and o_orderdate < dateadd(3 month to date ':1') and exists ( select * from lineitem where l_orderkey = o_orderkey and l_commitdate < l_receiptdate) group by o_orderpriority order by o_orderpriority}
    dict set q 5 {select n_name, sum(l_extendedprice * (1 - l_discount)) as revenue from customer, orders, lineitem, supplier, nation, region where c_custkey = o_custkey and l_orderkey = o_orderkey and l_suppkey = s_suppkey and c_nationkey = s_nationkey and s_nationkey = n_nationkey and n_regionkey = r_regionkey and r_name = ':1' and o_orderdate >= date ':2' and o_orderdate < dateadd(1 year to date ':2') group by n_name order by revenue desc}
    dict set q 6 {select sum(l_extendedprice * l_discount) as revenue from lineitem where l_shipdate >= date ':1' and l_shipdate < dateadd(1 year to date ':1') and l_discount between :2 - 0.01 and :2 + 0.01 and l_quantity < :3}
    dict set q 7 {select supp_nation, cust_nation, l_year, sum(volume) as revenue from ( select n1.n_name as supp_nation, n2.n_name as cust_nation, extract(year from l_shipdate) as l_year, l_extendedprice * (1 - l_discount) as volume from supplier, lineitem, orders, customer, nation n1, nation n2 where s_suppkey = l_suppkey and o_orderkey = l_orderkey and c_custkey = o_custkey and s_nationkey = n1.n_nationkey and c_nationkey = n2.n_nationkey and ( (n1.n_name = ':1' and n2.n_name = ':2') or (n1.n_name = ':2' and n2.n_name = ':1')) and l_shipdate between date '1995-01-01' and date '1996-12-31') shipping group by supp_nation, cust_nation, l_year order by supp_nation, cust_nation, l_year}
    dict set q 8 {select o_year, sum(case when nation = ':1' then volume else 0 end) / sum(volume) as mkt_share from ( select extract(year from o_orderdate) as o_year, l_extendedprice * (1 - l_discount) as volume, n2.n_name as nation from part, supplier, lineitem, orders, customer, nation n1, nation n2, region where p_partkey = l_partkey and s_suppkey = l_suppkey and l_orderkey = o_orderkey and o_custkey = c_custkey and c_nationkey = n1.n_nationkey and n1.n_regionkey = r_regionkey and r_name = ':2' and s_nationkey = n2.n_nationkey and o_orderdate between date '1995-01-01' and date '1996-12-31' and p_type = ':3') all_nations group by o_year order by o_year}
    dict set q 9 {select nation, o_year, sum(amount) as sum_profit from ( select n_name as nation, extract(year from o_orderdate) as o_year, l_extendedprice * (1 - l_discount) - ps_supplycost * l_quantity as amount from part, supplier, lineitem, partsupp, orders, nation where s_suppkey = l_suppkey and ps_suppkey = l_suppkey and ps_partkey = l_partkey and p_partkey = l_partkey and o_orderkey = l_orderkey and s_nationkey = n_nationkey and p_name like '%:1%') profit group by nation, o_year order by nation, o_year desc}
    dict set q 10 {select c_custkey, c_name, sum(l_extendedprice * (1 - l_discount)) as revenue, c_acctbal, n_name, c_address, c_phone, c_comment from customer, orders, lineitem, nation where c_custkey = o_custkey and l_orderkey = o_orderkey and o_orderdate >= date ':1' and o_orderdate < dateadd(3 month to date ':1') and l_returnflag = 'R' and c_nationkey = n_nationkey group by c_custkey, c_name, c_acctbal, c_phone, n_name, c_address, c_comment order by revenue desc}
    dict set q 11 {select ps_partkey, sum(ps_supplycost * ps_availqty) as tot_value from partsupp, supplier, nation where ps_suppkey = s_suppkey and s_nationkey = n_nationkey and n_name = ':1' group by ps_partkey having sum(ps_supplycost * ps_availqty) > ( select sum(ps_supplycost * ps_availqty) * :2 from partsupp, supplier, nation where ps_suppkey = s_suppkey and s_nationkey = n_nationkey and n_name = ':1') order by tot_value desc}
    dict set q 12 {select l_shipmode, sum(case when o_orderpriority = '1-URGENT' or o_orderpriority = '2-HIGH' then 1 else 0 end) as high_line_count, sum(case when o_orderpriority <> '1-URGENT' and o_orderpriority <> '2-HIGH' then 1 else 0 end) as low_line_count from orders, lineitem where o_orderkey = l_orderkey and l_shipmode in (':1', ':2') and l_commitdate < l_receiptdate and l_shipdate < l_commitdate and l_receiptdate >= date ':3' and l_receiptdate < dateadd(1 year to date ':3') group by l_shipmode order by l_shipmode}
    dict set q 13 {select c_count, count(*) as custdist from ( select c_custkey, count(o_orderkey) as c_count from customer left outer join orders on c_custkey = o_custkey and o_comment not like '%:1%:2%' group by c_custkey) c_orders group by c_count order by custdist desc, c_count desc}
    dict set q 14 {select 100.00 * sum(case when p_type like 'PROMO%' then l_extendedprice * (1 - l_discount) else 0 end) / sum(l_extendedprice * (1 - l_discount)) as promo_revenue from lineitem, part where l_partkey = p_partkey and l_shipdate >= date ':1' and l_shipdate < dateadd(1 month to date ':1')}
    dict set q 15 {create or alter view revenue:VID (supplier_no, total_revenue) as select l_suppkey, sum(l_extendedprice * (1 - l_discount)) from lineitem where l_shipdate >= date ':1' and l_shipdate < dateadd(3 month to date ':1') group by l_suppkey; select s_suppkey, s_name, s_address, s_phone, total_revenue from supplier, revenue:VID where s_suppkey = supplier_no and total_revenue = ( select max(total_revenue) from revenue:VID) order by s_suppkey; drop view revenue:VID}
    dict set q 16 {select p_brand, p_type, p_size, count(distinct ps_suppkey) as supplier_cnt from partsupp, part where p_partkey = ps_partkey and p_brand <> ':1' and p_type not like ':2%' and p_size in (:3, :4, :5, :6, :7, :8, :9, :10) and ps_suppkey not in ( select s_suppkey from supplier where s_comment like '%Customer%Complaints%') group by p_brand, p_type, p_size order by supplier_cnt desc, p_brand, p_type, p_size}
    dict set q 17 {select sum(l_extendedprice) / 7.0 as avg_yearly from lineitem, part where p_partkey = l_partkey and p_brand = ':1' and p_container = ':2' and l_quantity < ( select 0.2 * avg(l_quantity) from lineitem where l_partkey = p_partkey)}
    dict set q 18 {select c_name, c_custkey, o_orderkey, o_orderdate, o_totalprice, sum(l_quantity) from customer, orders, lineitem where o_orderkey in ( select l_orderkey from lineitem group by l_orderkey having sum(l_quantity) > :1) and c_custkey = o_custkey and o_orderkey = l_orderkey group by c_name, c_custkey, o_orderkey, o_orderdate, o_totalprice order by o_totalprice desc, o_orderdate}
    dict set q 19 {select sum(l_extendedprice* (1 - l_discount)) as revenue from lineitem, part where ( p_partkey = l_partkey and p_brand = ':1' and p_container in ('SM CASE', 'SM BOX', 'SM PACK', 'SM PKG') and l_quantity >= :4 and l_quantity <= :4 + 10 and p_size between 1 and 5 and l_shipmode in ('AIR', 'AIR REG') and l_shipinstruct = 'DELIVER IN PERSON') or ( p_partkey = l_partkey and p_brand = ':2' and p_container in ('MED BAG', 'MED BOX', 'MED PKG', 'MED PACK') and l_quantity >= :5 and l_quantity <= :5 + 10 and p_size between 1 and 10 and l_shipmode in ('AIR', 'AIR REG') and l_shipinstruct = 'DELIVER IN PERSON') or ( p_partkey = l_partkey and p_brand = ':3' and p_container in ('LG CASE', 'LG BOX', 'LG PACK', 'LG PKG') and l_quantity >= :6 and l_quantity <= :6 + 10 and p_size between 1 and 15 and l_shipmode in ('AIR', 'AIR REG') and l_shipinstruct = 'DELIVER IN PERSON')}
    dict set q 20 {select s_name, s_address from supplier, nation where s_suppkey in ( select ps_suppkey from partsupp where ps_partkey in ( select p_partkey from part where p_name like ':1%') and ps_availqty > ( select 0.5 * sum(l_quantity) from lineitem where l_partkey = ps_partkey and l_suppkey = ps_suppkey and l_shipdate >= date ':2' and l_shipdate < dateadd(1 year to date ':2'))) and s_nationkey = n_nationkey and n_name = ':3' order by s_name}
    dict set q 21 {select s_name, count(*) as numwait from supplier, lineitem l1, orders, nation where s_suppkey = l1.l_suppkey and o_orderkey = l1.l_orderkey and o_orderstatus = 'F' and l1.l_receiptdate > l1.l_commitdate and exists ( select * from lineitem l2 where l2.l_orderkey = l1.l_orderkey and l2.l_suppkey <> l1.l_suppkey) and not exists ( select * from lineitem l3 where l3.l_orderkey = l1.l_orderkey and l3.l_suppkey <> l1.l_suppkey and l3.l_receiptdate > l3.l_commitdate) and s_nationkey = n_nationkey and n_name = ':1' group by s_name order by numwait desc, s_name}
    dict set q 22 {select cntrycode, count(*) as numcust, sum(c_acctbal) as totacctbal from ( select substring(c_phone from 1 for 2) as cntrycode, c_acctbal from customer where substring(c_phone from 1 for 2) in (':1', ':2', ':3', ':4', ':5', ':6', ':7') and c_acctbal > ( select avg(c_acctbal) from customer where c_acctbal > 0.00 and substring(c_phone from 1 for 2) in (':1', ':2', ':3', ':4', ':5', ':6', ':7')) and not exists ( select * from orders where o_custkey = c_custkey)) custsale group by cntrycode order by cntrycode}
    return $q
}
