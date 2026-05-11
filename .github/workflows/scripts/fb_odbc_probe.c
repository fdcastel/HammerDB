/* Minimal SQLDriverConnect probe used by the Linux CI smoke step to
 * see what the Firebird ODBC driver actually returns through
 * SQLGetDiagRec. The Tcl driver (tdbc::odbc) wraps the diagnostic
 * record in its own error format, which has obscured prior debugging.
 * This program walks the entire diag-record list and hex-dumps the
 * message so we can see truncation / embedded nulls / mojibake
 * directly.
 *
 * Build:  gcc -O0 -g -o fb_odbc_probe fb_odbc_probe.c -lodbc
 * Run:    fb_odbc_probe "Driver={...};Dbname=...;UID=...;PWD=...;"
 */
#include <stdio.h>
#include <string.h>
#include <sql.h>
#include <sqlext.h>

int main(int argc, char **argv)
{
    if (argc != 2) {
        fprintf(stderr, "usage: %s <ODBC connection string>\n", argv[0]);
        return 2;
    }

    SQLHENV env = SQL_NULL_HENV;
    SQLHDBC dbc = SQL_NULL_HDBC;

    SQLAllocHandle(SQL_HANDLE_ENV, SQL_NULL_HANDLE, &env);
    SQLSetEnvAttr(env, SQL_ATTR_ODBC_VERSION, (void*)SQL_OV_ODBC3, 0);
    SQLAllocHandle(SQL_HANDLE_DBC, env, &dbc);

    printf("SQLDriverConnect: %s\n", argv[1]);

    SQLCHAR     out[2048] = {0};
    SQLSMALLINT outlen    = 0;
    SQLRETURN rc = SQLDriverConnect(dbc, NULL,
                                    (SQLCHAR*)argv[1], SQL_NTS,
                                    out, sizeof(out), &outlen,
                                    SQL_DRIVER_NOPROMPT);
    printf("  rc=%d  (SQL_SUCCESS=%d  SQL_SUCCESS_WITH_INFO=%d  SQL_ERROR=%d)\n",
           rc, SQL_SUCCESS, SQL_SUCCESS_WITH_INFO, SQL_ERROR);

    /* Walk every diag record so we see whether there's more than one. */
    for (SQLSMALLINT i = 1; ; ++i) {
        SQLCHAR     state[16]  = {0};
        SQLINTEGER  native     = 0;
        SQLCHAR     msg[2048]  = {0};
        SQLSMALLINT msglen     = 0;

        SQLRETURN diagRc = SQLGetDiagRec(SQL_HANDLE_DBC, dbc, i,
                                         state, &native,
                                         msg, sizeof(msg), &msglen);
        if (diagRc != SQL_SUCCESS && diagRc != SQL_SUCCESS_WITH_INFO)
            break;

        size_t real_len = strlen((char*)msg);
        printf("  [diag %d]\n", (int)i);
        printf("    SQLSTATE  : '%s' (strlen=%zu)\n",
               (char*)state, strlen((char*)state));
        printf("    native    : %ld (0x%lx)\n",
               (long)native, (long)native);
        printf("    msg       : '%s'\n", (char*)msg);
        printf("    msglen    : reported=%d  actual strlen=%zu\n",
               (int)msglen, real_len);

        /* Hex dump up to 96 bytes - reveals embedded nulls / controls. */
        size_t dump_len = real_len > 96 ? 96 : real_len;
        if (msglen > 0 && (size_t)msglen > dump_len)
            dump_len = (size_t)msglen > 96 ? 96 : (size_t)msglen;
        printf("    hex (%zuB):", dump_len);
        for (size_t j = 0; j < dump_len; ++j)
            printf(" %02x", msg[j]);
        printf("\n");
    }

    SQLFreeHandle(SQL_HANDLE_DBC, dbc);
    SQLFreeHandle(SQL_HANDLE_ENV, env);
    return (rc == SQL_SUCCESS || rc == SQL_SUCCESS_WITH_INFO) ? 0 : 1;
}
