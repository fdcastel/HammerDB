# Firebird TPROC-H (TPC-H-like OLAP) implementation.
#
# Build status: skeleton. Real schema build, the 22 TPC-H queries
# adapted for Firebird SQL dialect, and the refresh streams (RF1/RF2)
# land in subsequent commits (THE_PLAN tasks C9-C11).
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

proc build_fbtpch {} {
    upvar #0 dbdict dbdict
    upvar #0 configfirebird configfirebird
    setlocalfbtpchvars $configfirebird
    error "build_fbtpch: GUI build flow not yet wired up; DDL is implemented in fb_create_tpch_schema. Loaders + 22 queries tracked in THE_PLAN.md task C10-C11"
}
