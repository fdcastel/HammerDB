SET TERM ^ ;

-- =========================================================================
-- PAYMENT_SP: TPC-C 2.5 Payment (by-id customer lookup path).
-- =========================================================================
CREATE OR ALTER PROCEDURE PAYMENT_SP (
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
END
^

-- =========================================================================
-- OSTAT_SP: TPC-C 2.6 Order-Status (by-id customer lookup, latest order).
-- Returns one row with the customer balance and the latest order details.
-- =========================================================================
CREATE OR ALTER PROCEDURE OSTAT_SP (
    P_W_ID INTEGER,
    P_D_ID SMALLINT,
    P_C_ID INTEGER)
RETURNS (
    OUT_C_BALANCE    NUMERIC(12,2),
    OUT_O_ID         INTEGER,
    OUT_O_ENTRY_D    TIMESTAMP,
    OUT_O_CARRIER_ID SMALLINT)
AS
BEGIN
    SELECT C_BALANCE FROM CUSTOMER
        WHERE C_W_ID = :P_W_ID AND C_D_ID = :P_D_ID AND C_ID = :P_C_ID
        INTO :OUT_C_BALANCE;

    SELECT FIRST 1 O_ID, O_ENTRY_D, O_CARRIER_ID FROM ORDERS
        WHERE O_W_ID = :P_W_ID AND O_D_ID = :P_D_ID AND O_C_ID = :P_C_ID
        ORDER BY O_ID DESC
        INTO :OUT_O_ID, :OUT_O_ENTRY_D, :OUT_O_CARRIER_ID;

    SUSPEND;
END
^

-- =========================================================================
-- SLEV_SP: TPC-C 2.8 Stock-Level. Counts distinct items in the most
-- recent 20 orders of the district whose stock falls below the threshold.
-- =========================================================================
CREATE OR ALTER PROCEDURE SLEV_SP (
    P_W_ID      INTEGER,
    P_D_ID      SMALLINT,
    P_THRESHOLD INTEGER)
RETURNS (OUT_LOWS INTEGER)
AS
DECLARE VARIABLE NEXT_O_ID INTEGER;
BEGIN
    SELECT D_NEXT_O_ID FROM DISTRICT
        WHERE D_W_ID = :P_W_ID AND D_ID = :P_D_ID
        INTO :NEXT_O_ID;

    SELECT COUNT(DISTINCT S_I_ID) FROM ORDER_LINE, STOCK
        WHERE OL_W_ID = :P_W_ID AND OL_D_ID = :P_D_ID
          AND OL_O_ID < :NEXT_O_ID
          AND OL_O_ID >= :NEXT_O_ID - 20
          AND S_W_ID = :P_W_ID
          AND S_I_ID = OL_I_ID
          AND S_QUANTITY < :P_THRESHOLD
        INTO :OUT_LOWS;

    SUSPEND;
END
^

-- =========================================================================
-- DELIVERY_SP: TPC-C 2.7 Delivery. Iterates the 10 districts of the
-- warehouse, picks the oldest NEW_ORDER per district, marks it delivered,
-- updates customer balance/delivery_cnt. Returns count of districts that
-- successfully delivered an order.
-- =========================================================================
CREATE OR ALTER PROCEDURE DELIVERY_SP (
    P_W_ID       INTEGER,
    P_CARRIER_ID SMALLINT,
    P_DELIVERY_D TIMESTAMP)
RETURNS (OUT_DISTRICT_COUNT INTEGER)
AS
DECLARE VARIABLE D_ID  SMALLINT;
DECLARE VARIABLE O_ID  INTEGER;
DECLARE VARIABLE C_ID  INTEGER;
DECLARE VARIABLE TOTAL NUMERIC(12,2);
BEGIN
    OUT_DISTRICT_COUNT = 0;
    D_ID = 1;
    WHILE (D_ID <= 10) DO BEGIN
        O_ID = NULL;
        SELECT FIRST 1 NO_O_ID FROM NEW_ORDER
            WHERE NO_W_ID = :P_W_ID AND NO_D_ID = :D_ID
            ORDER BY NO_O_ID
            INTO :O_ID;

        IF (O_ID IS NOT NULL) THEN BEGIN
            DELETE FROM NEW_ORDER
                WHERE NO_W_ID = :P_W_ID AND NO_D_ID = :D_ID AND NO_O_ID = :O_ID;

            SELECT O_C_ID FROM ORDERS
                WHERE O_W_ID = :P_W_ID AND O_D_ID = :D_ID AND O_ID = :O_ID
                INTO :C_ID;

            UPDATE ORDERS SET O_CARRIER_ID = :P_CARRIER_ID
                WHERE O_W_ID = :P_W_ID AND O_D_ID = :D_ID AND O_ID = :O_ID;

            UPDATE ORDER_LINE SET OL_DELIVERY_D = :P_DELIVERY_D
                WHERE OL_W_ID = :P_W_ID AND OL_D_ID = :D_ID AND OL_O_ID = :O_ID;

            SELECT SUM(OL_AMOUNT) FROM ORDER_LINE
                WHERE OL_W_ID = :P_W_ID AND OL_D_ID = :D_ID AND OL_O_ID = :O_ID
                INTO :TOTAL;

            UPDATE CUSTOMER SET
                C_BALANCE = C_BALANCE + :TOTAL,
                C_DELIVERY_CNT = C_DELIVERY_CNT + 1
                WHERE C_W_ID = :P_W_ID AND C_D_ID = :D_ID AND C_ID = :C_ID;

            OUT_DISTRICT_COUNT = OUT_DISTRICT_COUNT + 1;
        END
        D_ID = D_ID + 1;
    END
    SUSPEND;
END
^

-- =========================================================================
-- NEWORD_SP: TPC-C 2.4 New-Order. Allocates a new o_id, inserts ORDERS +
-- NEW_ORDER, then iterates ol_cnt items: read item price, update stock,
-- insert order_line. Picks S_DIST_NN by district id via a CASE expression
-- (no Firebird PSQL dynamic SQL needed). Returns the new o_id and total.
--
-- Simplified vs. full TPC-C spec: skips the rbk == 1 / item 100001
-- intentional-rollback case, treats all items as local-warehouse, and
-- skips C_LAST/C_DISCOUNT lookups (caller may apply discount client-side
-- if needed).
-- =========================================================================
CREATE OR ALTER PROCEDURE NEWORD_SP (
    P_W_ID    INTEGER,
    P_D_ID    SMALLINT,
    P_C_ID    INTEGER,
    P_OL_CNT  SMALLINT,
    P_DATE    TIMESTAMP)
RETURNS (
    OUT_O_ID INTEGER,
    OUT_TOTAL NUMERIC(12,2))
AS
DECLARE VARIABLE C_DISCOUNT     NUMERIC(4,4);
DECLARE VARIABLE W_TAX          NUMERIC(4,4);
DECLARE VARIABLE D_TAX          NUMERIC(4,4);
DECLARE VARIABLE I              INTEGER;
DECLARE VARIABLE OL_I_ID        INTEGER;
DECLARE VARIABLE OL_QUANTITY    SMALLINT;
DECLARE VARIABLE I_PRICE        NUMERIC(5,2);
DECLARE VARIABLE S_QTY          INTEGER;
DECLARE VARIABLE S_DIST         VARCHAR(24);
DECLARE VARIABLE NEW_QTY        INTEGER;
DECLARE VARIABLE OL_AMT         NUMERIC(12,2);
BEGIN
    OUT_TOTAL = 0;

    SELECT C.C_DISCOUNT, W.W_TAX FROM CUSTOMER C, WAREHOUSE W
        WHERE W.W_ID = :P_W_ID AND C.C_W_ID = :P_W_ID
          AND C.C_D_ID = :P_D_ID AND C.C_ID = :P_C_ID
        INTO :C_DISCOUNT, :W_TAX;

    UPDATE DISTRICT SET D_NEXT_O_ID = D_NEXT_O_ID + 1
        WHERE D_W_ID = :P_W_ID AND D_ID = :P_D_ID
        RETURNING D_NEXT_O_ID - 1, D_TAX INTO :OUT_O_ID, :D_TAX;

    INSERT INTO ORDERS (O_ID, O_D_ID, O_W_ID, O_C_ID, O_ENTRY_D,
                        O_OL_CNT, O_ALL_LOCAL)
        VALUES (:OUT_O_ID, :P_D_ID, :P_W_ID, :P_C_ID, :P_DATE,
                :P_OL_CNT, 1);
    INSERT INTO NEW_ORDER (NO_O_ID, NO_D_ID, NO_W_ID)
        VALUES (:OUT_O_ID, :P_D_ID, :P_W_ID);

    I = 1;
    WHILE (I <= P_OL_CNT) DO BEGIN
        OL_I_ID     = CAST(RAND() * 100000 + 1 AS INTEGER);
        OL_QUANTITY = CAST(RAND() * 10 + 1 AS SMALLINT);

        SELECT I_PRICE FROM ITEM WHERE I_ID = :OL_I_ID INTO :I_PRICE;
        IF (I_PRICE IS NULL) THEN BEGIN
            -- Item missing - skip this line rather than rollback, so the
            -- smoke test can complete even if a random id misses.
            I = I + 1;
            CONTINUE;
        END

        SELECT S_QUANTITY,
            CASE :P_D_ID
                WHEN 1 THEN S_DIST_01
                WHEN 2 THEN S_DIST_02
                WHEN 3 THEN S_DIST_03
                WHEN 4 THEN S_DIST_04
                WHEN 5 THEN S_DIST_05
                WHEN 6 THEN S_DIST_06
                WHEN 7 THEN S_DIST_07
                WHEN 8 THEN S_DIST_08
                WHEN 9 THEN S_DIST_09
                ELSE S_DIST_10
            END
            FROM STOCK
            WHERE S_W_ID = :P_W_ID AND S_I_ID = :OL_I_ID
            INTO :S_QTY, :S_DIST;

        IF (S_QTY - OL_QUANTITY >= 10) THEN
            NEW_QTY = S_QTY - OL_QUANTITY;
        ELSE
            NEW_QTY = S_QTY - OL_QUANTITY + 91;

        UPDATE STOCK SET
            S_QUANTITY = :NEW_QTY,
            S_YTD = S_YTD + :OL_QUANTITY,
            S_ORDER_CNT = S_ORDER_CNT + 1
            WHERE S_W_ID = :P_W_ID AND S_I_ID = :OL_I_ID;

        OL_AMT = OL_QUANTITY * I_PRICE * (1 + W_TAX + D_TAX) * (1 - C_DISCOUNT);
        OUT_TOTAL = OUT_TOTAL + OL_AMT;

        INSERT INTO ORDER_LINE (OL_O_ID, OL_D_ID, OL_W_ID, OL_NUMBER, OL_I_ID,
                                OL_SUPPLY_W_ID, OL_QUANTITY, OL_AMOUNT,
                                OL_DIST_INFO)
            VALUES (:OUT_O_ID, :P_D_ID, :P_W_ID, :I, :OL_I_ID,
                    :P_W_ID, :OL_QUANTITY, :OL_AMT, :S_DIST);

        I = I + 1;
    END

    SUSPEND;
END
^

SET TERM ; ^

COMMIT;
