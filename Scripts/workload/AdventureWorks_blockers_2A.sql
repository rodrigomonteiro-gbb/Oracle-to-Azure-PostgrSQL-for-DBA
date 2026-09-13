/*
    AdventureWorks blocking session version 2 for pgbench.

    This version locks only one row in person.person. Run this workload before
    AdventureWorks_blocked_2A.sql. ROLLBACK releases the row lock after the
    delay; it behaves like COMMIT for lock release because no data is changed.
*/

\set person_offset random(0, 99)
\set delay_seconds random(5, 15)

BEGIN;

    SELECT businessentityid,
        firstname,
        lastname
    FROM person.person
    ORDER BY businessentityid
    LIMIT 1
    OFFSET :person_offset
    FOR UPDATE;

    SELECT pg_sleep(:delay_seconds/100);

    /* Optional second lock target; leave commented for a one-table test.
    \set customer_offset random(0, 99)

    SELECT customerid,
        personid,
        storeid,
        accountnumber
    FROM sales.customer
    ORDER BY customerid
    LIMIT 1
    OFFSET :customer_offset
    FOR UPDATE;

    SELECT pg_sleep(:delay_seconds/100);
    */

    /* Optional third lock target; leave commented for a one-table test.
    \set salesorder_offset random(0, 99)

    SELECT salesorderid,
        customerid,
        orderdate,
        status
    FROM sales.salesorderheader
    ORDER BY salesorderid
    LIMIT 1
    OFFSET :salesorder_offset
    FOR UPDATE;

    SELECT pg_sleep(:delay_seconds/100);
    */

ROLLBACK;