# Unit + integration tests for the MVCC retry helper (C8) in
# fboltp.tcl. Verifies:
#   1. fb_is_retryable_error pattern-matches all known Firebird
#      conflict markers (deadlock, lock conflict, update conflict,
#      SQLSTATE 40001, etc.) and rejects non-retryable errors.
#   2. fb_with_retry retries a body that fails with a retryable
#      error and succeeds on subsequent attempt.
#   3. fb_with_retry propagates non-retryable errors immediately.
#   4. fb_with_retry gives up after max_retries.
#
# Inputs:
#   HAMMERDB_ROOT - HammerDB repo checkout

set root [string trim $::env(HAMMERDB_ROOT)]
if {$root eq ""} { puts stderr "HAMMERDB_ROOT must be set"; exit 2 }

::tcl::tm::path add [file join $root modules]
package require xml 1.1
package require tdbc::odbc

# Loading firebird modules requires the config dicts even though our
# tests don't open a DB.
set ::dbdict [::XML::To_Dict [file join $root config database.xml]]
set ::configfirebird [::XML::To_Dict [file join $root config firebird.xml]]
foreach f {fbci.tcl fbmet.tcl fbotc.tcl fbopt.tcl fboltp.tcl fbolap.tcl} {
    source [file join $root src firebird $f]
}

set fails 0

# --- Test 1: fb_is_retryable_error pattern matching --------------------------
set retryable_samples {
    {deadlock}
    {[ODBC Firebird Driver][Firebird]deadlock}
    {lock conflict on no wait transaction}
    {update conflicts with concurrent update}
    {concurrent transaction number is 12345}
    {SQLSTATE = 40001}
    {isc_update_conflict (335544574)}
    {DEADLOCK detected on TPC-C}
}
foreach msg $retryable_samples {
    if {![fb_is_retryable_error $msg]} {
        puts stderr "FAIL: retryable not detected: $msg"
        incr fails
    } else {
        puts "OK: retryable detected: [string range $msg 0 50]..."
    }
}

set non_retryable_samples {
    {Token unknown - SUBSTR}
    {Table unknown - CUSTOMER_X}
    {Dynamic SQL Error: column does not exist}
    {division by zero}
    {connection refused}
}
foreach msg $non_retryable_samples {
    if {[fb_is_retryable_error $msg]} {
        puts stderr "FAIL: non-retryable misclassified: $msg"
        incr fails
    } else {
        puts "OK: non-retryable rejected: [string range $msg 0 50]..."
    }
}

# --- Test 2: fb_with_retry succeeds after a retryable failure ---------------
# Simulate a body that fails on first attempt with a deadlock-style error
# and succeeds on the second attempt.
set ::test_counter 0
# NOTE: error messages use brace-quoted literals because [brackets]
# inside double-quoted strings trigger Tcl command substitution.
set result [fb_with_retry 3 attempt_no {
    incr ::test_counter
    if {$::test_counter < 2} {
        error {[ODBC Firebird Driver][Firebird]deadlock simulated for test}
    }
    return "ok_after_retry"
}]
if {$result ne "ok_after_retry"} {
    puts stderr "FAIL: fb_with_retry returned '$result' (expected ok_after_retry)"
    incr fails
} elseif {$::test_counter != 2} {
    puts stderr "FAIL: expected 2 attempts, got $::test_counter"
    incr fails
} else {
    puts "OK: fb_with_retry retried once then succeeded ($::test_counter attempts)"
}

# --- Test 3: fb_with_retry propagates non-retryable errors immediately ------
set ::test_counter 0
set propagated 0
if {[catch {
    fb_with_retry 3 attempt_no {
        incr ::test_counter
        error "Token unknown - WIDGET"
    }
} errmsg]} {
    set propagated 1
}
if {!$propagated} {
    puts stderr "FAIL: non-retryable error was swallowed"
    incr fails
} elseif {$::test_counter != 1} {
    puts stderr "FAIL: non-retryable was retried $::test_counter times (expected 1)"
    incr fails
} else {
    puts "OK: non-retryable propagated after $::test_counter attempt"
}

# --- Test 4: fb_with_retry exhausts max_retries on persistent failure --------
set ::test_counter 0
set caught 0
if {[catch {
    fb_with_retry 2 attempt_no {
        incr ::test_counter
        error {[ODBC Firebird Driver][Firebird]lock conflict on no wait transaction}
    }
} errmsg]} {
    set caught 1
}
if {!$caught} {
    puts stderr "FAIL: persistent retryable error was not re-raised after max retries"
    incr fails
} elseif {$::test_counter != 3} {
    # max_retries=2 means 3 total attempts (attempt 0, 1, 2)
    puts stderr "FAIL: expected 3 attempts (max_retries=2 means 0..2), got $::test_counter"
    incr fails
} else {
    puts "OK: persistent retryable was re-raised after $::test_counter attempts"
}

# --- Test 5: empty/missing error message does not crash ----------------------
if {[fb_is_retryable_error ""]} {
    puts stderr "FAIL: empty error string was classified as retryable"
    incr fails
} else {
    puts "OK: empty error string rejected"
}

if {$fails > 0} {
    puts stderr "$fails MVCC-retry test(s) failed"
    exit 3
}
puts "OK: all MVCC retry helper tests passed"
