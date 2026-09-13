CREATE OR REPLACE FUNCTION demo_address_cursor()
RETURNS TABLE(
    message_text TEXT,
    row_count INTEGER
) AS $$
DECLARE
    cur_address CURSOR FOR
        SELECT addressid, addressline1
        FROM person.address
        ORDER BY addressid;

    v_addrid INTEGER;
    v_addrline1 VARCHAR(100);
    v_message VARCHAR(200);
    v_row_count INTEGER := 0;
BEGIN
    OPEN cur_address;

    LOOP
        FETCH cur_address INTO v_addrid, v_addrline1;
        EXIT WHEN NOT FOUND;

        v_message := 'my Address is: ' || v_addrline1;
        v_row_count := v_row_count + 1;
    END LOOP;

    CLOSE cur_address;

    RETURN QUERY SELECT
        'Processed ' || v_row_count || ' addresses via cursor'::TEXT,
        v_row_count;
END;
$$ LANGUAGE plpgsql;

DROP FUNCTION IF EXISTS demo_salesorderheader_update_cursor(INTEGER);

CREATE FUNCTION demo_salesorderheader_update_cursor(p_salespersonid INTEGER)
RETURNS TABLE(
    salesorderid INTEGER,
    salespersonid INTEGER,
    modifieddate TIMESTAMP,
    freight NUMERIC,
    totaldue NUMERIC
) AS $$
DECLARE
    cur_salesorderheader_update CURSOR FOR
        SELECT soh.salesorderid
        FROM sales.salesorderheader AS soh
        WHERE soh.salespersonid = p_salespersonid
        ORDER BY soh.salesorderid
        FOR UPDATE;

    v_salesorderid sales.salesorderheader.salesorderid%TYPE;
BEGIN
    OPEN cur_salesorderheader_update;

    LOOP
        FETCH cur_salesorderheader_update INTO v_salesorderid;
        EXIT WHEN NOT FOUND;

           UPDATE sales.salesorderheader AS soh
           SET freight = soh.freight + 1.00,
            modifieddate = CURRENT_TIMESTAMP
        WHERE CURRENT OF cur_salesorderheader_update
           RETURNING soh.salesorderid,
                   soh.salespersonid,
                   soh.modifieddate,
                   soh.freight,
                   soh.totaldue
           INTO salesorderid,
               salespersonid,
               modifieddate,
               freight,
               totaldue;

        RETURN NEXT;
    END LOOP;

    CLOSE cur_salesorderheader_update;
END;
$$ LANGUAGE plpgsql;

-- Active version: return every SalesOrderHeader row traversed by the cursor.
DROP FUNCTION IF EXISTS demo_salesorderheader_cursor(INTEGER);

CREATE FUNCTION demo_salesorderheader_cursor(p_salespersonid INTEGER)
RETURNS TABLE(
    salesorderid INTEGER,
    salespersonid INTEGER,
    modifieddate TIMESTAMP,
    freight NUMERIC,
    totaldue NUMERIC
) AS $$
DECLARE
    cur_salesorderheader CURSOR FOR
        SELECT soh.salesorderid,
               soh.salespersonid,
               soh.modifieddate,
               soh.freight,
               soh.totaldue
        FROM sales.salesorderheader AS soh
        WHERE soh.salespersonid = p_salespersonid
        ORDER BY soh.salesorderid;

    v_salesorderid sales.salesorderheader.salesorderid%TYPE;
    v_salespersonid sales.salesorderheader.salespersonid%TYPE;
    v_modifieddate sales.salesorderheader.modifieddate%TYPE;
    v_freight sales.salesorderheader.freight%TYPE;
    v_totaldue sales.salesorderheader.totaldue%TYPE;
BEGIN
    OPEN cur_salesorderheader;

    LOOP
        FETCH cur_salesorderheader
        INTO v_salesorderid,
             v_salespersonid,
             v_modifieddate,
             v_freight,
             v_totaldue;
        EXIT WHEN NOT FOUND;

        salesorderid := v_salesorderid;
        salespersonid := v_salespersonid;
        modifieddate := v_modifieddate;
        freight := v_freight;
        totaldue := v_totaldue;
        RETURN NEXT;
    END LOOP;

    CLOSE cur_salesorderheader;
END;
$$ LANGUAGE plpgsql;

/*
-- Alternative version: traverse every matching row but return only a summary.
-- To use it, comment out the active version above and uncomment this block.
DROP FUNCTION IF EXISTS demo_salesorderheader_cursor(INTEGER);

CREATE FUNCTION demo_salesorderheader_cursor(p_salespersonid INTEGER)
RETURNS TABLE(
    salesperson_id INTEGER,
    row_count INTEGER
) AS $$
DECLARE
    cur_salesorderheader CURSOR FOR
        SELECT soh.salesorderid,
               soh.salespersonid,
               soh.modifieddate,
               soh.freight,
               soh.totaldue
        FROM sales.salesorderheader AS soh
        WHERE soh.salespersonid = p_salespersonid
        ORDER BY soh.salesorderid;

    v_salesorderid sales.salesorderheader.salesorderid%TYPE;
    v_salespersonid sales.salesorderheader.salespersonid%TYPE;
    v_modifieddate sales.salesorderheader.modifieddate%TYPE;
    v_freight sales.salesorderheader.freight%TYPE;
    v_totaldue sales.salesorderheader.totaldue%TYPE;
    v_row_count INTEGER := 0;
BEGIN
    OPEN cur_salesorderheader;

    LOOP
        FETCH cur_salesorderheader
        INTO v_salesorderid,
             v_salespersonid,
             v_modifieddate,
             v_freight,
             v_totaldue;
        EXIT WHEN NOT FOUND;

        v_row_count := v_row_count + 1;
    END LOOP;

    CLOSE cur_salesorderheader;

    RETURN QUERY SELECT p_salespersonid, v_row_count;
END;
$$ LANGUAGE plpgsql;
*/