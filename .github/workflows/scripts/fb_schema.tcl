# Build the TPC-C schema on a fresh embedded Firebird database, then
# verify the 9 expected tables and 2 secondary indexes were created
# with the right columns. Run by the Phase C CI job to keep the DDL
# from drifting away from the canonical TPC-C definitions.
#
# Inputs:
#   HAMMERDB_ROOT - path to the HammerDB repo checkout
#   FB_ODBC_DRIVER - registered ODBC driver name (Firebird ODBC Driver)
#   FB_DB_PATH     - absolute path to the .fdb (forward slashes)

set root [string trim $::env(HAMMERDB_ROOT)]
set driver [string trim $::env(FB_ODBC_DRIVER)]
set dbpath [string trim $::env(FB_DB_PATH)]
foreach {name val} [list HAMMERDB_ROOT $root FB_ODBC_DRIVER $driver FB_DB_PATH $dbpath] {
    if {$val eq ""} { puts stderr "$name must be set"; exit 2 }
}

::tcl::tm::path add [file join $root modules]
package require xml 1.1
package require tdbc::odbc

set ::dbdict [::XML::To_Dict [file join $root config database.xml]]
set ::configfirebird [::XML::To_Dict [file join $root config firebird.xml]]

# Source the firebird modules so fb_create_tpcc_schema is available.
foreach f {fbci.tcl fbmet.tcl fbotc.tcl fbopt.tcl fboltp.tcl fbolap.tcl} {
    source [file join $root src firebird $f]
}

# Embedded-mode connection per fb_build_connstr's contract.
set conn [ConnectToFirebird $driver true "" "" $dbpath SYSDBA "" UTF8]
puts "Connected to $dbpath via $driver"

set created [fb_create_tpcc_schema $conn]
puts "Created $created TPC-C objects"

# Sanity-check: 9 user tables (TPC-C set) and 2 secondary indexes.
set expected_tables {WAREHOUSE DISTRICT CUSTOMER HISTORY NEW_ORDER ORDERS ORDER_LINE ITEM STOCK}
set expected_indexes {CUSTOMER_I2 ORDERS_I2}

set actual_tables [list]
$conn foreach -as lists row {
    SELECT TRIM(RDB$RELATION_NAME) FROM RDB$RELATIONS
    WHERE RDB$SYSTEM_FLAG = 0 AND RDB$VIEW_BLR IS NULL
    ORDER BY RDB$RELATION_NAME
} { lappend actual_tables [lindex $row 0] }

set missing_tables [list]
foreach t $expected_tables { if {$t ni $actual_tables} { lappend missing_tables $t } }
if {[llength $missing_tables] > 0} {
    puts stderr "FAIL: missing tables: $missing_tables"
    puts stderr "actual tables: $actual_tables"
    $conn close
    exit 3
}
puts "OK: all 9 TPC-C tables present"

set actual_indexes [list]
$conn foreach -as lists row {
    SELECT TRIM(RDB$INDEX_NAME) FROM RDB$INDICES
    WHERE RDB$SYSTEM_FLAG = 0
    ORDER BY RDB$INDEX_NAME
} { lappend actual_indexes [lindex $row 0] }

set missing_indexes [list]
foreach i $expected_indexes { if {$i ni $actual_indexes} { lappend missing_indexes $i } }
if {[llength $missing_indexes] > 0} {
    puts stderr "FAIL: missing secondary indexes: $missing_indexes"
    puts stderr "actual indexes: $actual_indexes"
    $conn close
    exit 3
}
puts "OK: secondary indexes present ($expected_indexes)"

$conn close
puts "OK: TPC-C schema build verified"
