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
    error "build_fbtpch: GUI build flow not yet wired up; DDL is in fb_create_tpch_schema, queries in fb_tpch_queries. Bulk loader (C10) tracked in THE_PLAN.md."
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
