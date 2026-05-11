# Build the TPC-H schema on a fresh embedded Firebird database and
# verify the 8 expected tables exist with primary keys.
#
# Inputs:
#   HAMMERDB_ROOT  - HammerDB repo checkout
#   FB_ODBC_DRIVER - registered driver name
#   FB_DB_PATH     - absolute path to the .fdb (forward slashes)

set root [string trim $::env(HAMMERDB_ROOT)]
set driver [string trim $::env(FB_ODBC_DRIVER)]
set dbpath [string trim $::env(FB_DB_PATH)]
foreach {n v} [list HAMMERDB_ROOT $root FB_ODBC_DRIVER $driver FB_DB_PATH $dbpath] {
    if {$v eq ""} { puts stderr "$n must be set"; exit 2 }
}

::tcl::tm::path add [file join $root modules]
package require xml 1.1
package require tdbc::odbc

set ::dbdict [::XML::To_Dict [file join $root config database.xml]]
set ::configfirebird [::XML::To_Dict [file join $root config firebird.xml]]
foreach f {fbci.tcl fbmet.tcl fbotc.tcl fbopt.tcl fboltp.tcl fbolap.tcl} {
    source [file join $root src firebird $f]
}

set conn [ConnectToFirebird $driver true "" "" $dbpath SYSDBA "" UTF8]
puts "Connected to $dbpath"

set t0 [clock milliseconds]
fb_create_tpch_schema $conn
puts "Schema built in [expr {[clock milliseconds] - $t0}] ms"

set expected_tables {REGION NATION SUPPLIER PART PARTSUPP CUSTOMER ORDERS LINEITEM}
set actual_tables [list]
$conn foreach -as lists row {
    SELECT TRIM(RDB$RELATION_NAME) FROM RDB$RELATIONS
    WHERE RDB$SYSTEM_FLAG = 0 AND RDB$VIEW_BLR IS NULL
    ORDER BY RDB$RELATION_NAME
} { lappend actual_tables [lindex $row 0] }

set missing [list]
foreach t $expected_tables { if {$t ni $actual_tables} { lappend missing $t } }
if {[llength $missing] > 0} {
    puts stderr "FAIL: missing TPC-H tables: $missing"
    puts stderr "actual: $actual_tables"
    $conn close
    exit 3
}
puts "OK: all 8 TPC-H tables present"

# Confirm primary keys
set expected_pk {REGION_PK NATION_PK SUPPLIER_PK PART_PK PARTSUPP_PK CUSTOMER_PK ORDERS_PK LINEITEM_PK}
set actual_pk [list]
$conn foreach -as lists row {
    SELECT TRIM(RDB$INDEX_NAME) FROM RDB$INDICES
    WHERE RDB$SYSTEM_FLAG = 0 AND RDB$INDEX_NAME LIKE '%_PK'
    ORDER BY RDB$INDEX_NAME
} { lappend actual_pk [lindex $row 0] }

set missing [list]
foreach pk $expected_pk { if {$pk ni $actual_pk} { lappend missing $pk } }
if {[llength $missing] > 0} {
    puts stderr "FAIL: missing PK indexes: $missing"
    $conn close
    exit 3
}
puts "OK: all 8 TPC-H primary-key indexes present"

$conn close
puts "OK: TPC-H schema build verified"
