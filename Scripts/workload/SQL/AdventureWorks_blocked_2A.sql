/*
    AdventureWorks blocked session version 2 for pgbench.

    One active query is sufficient to demonstrate blocking. Start
    AdventureWorks_blockers_2A.sql first. This query requests locks on at
    least the first 100 person.person rows, including the blocker's row.
*/

\set person_limit random(100, 500)

BEGIN;

    SELECT p.businessentityid,
        p.firstname,
        p.lastname,
        be.modifieddate
    FROM person.person AS p
    INNER JOIN person.businessentity AS be
            ON be.businessentityid = p.businessentityid
    ORDER BY p.businessentityid
    LIMIT :person_limit
    FOR UPDATE OF p;

    /* Optional customer query; leave commented for the one-table test.
    \set customer_limit random(100, 500)

    SELECT c.customerid,
        c.accountnumber,
        s.name AS store_name
    FROM sales.customer AS c
    LEFT JOIN sales.store AS s
        ON s.businessentityid = c.storeid
    ORDER BY c.customerid
    LIMIT :customer_limit
    FOR UPDATE OF c;
    */

    /* Optional sales-order query; leave commented for the one-table test.
    \set salesorder_limit random(100, 500)

    SELECT soh.salesorderid,
        soh.customerid,
        sod.salesorderdetailid,
        p.productid,
        p.name AS product_name,
        c.accountnumber
    FROM sales.salesorderheader AS soh
    INNER JOIN LATERAL (
        SELECT salesorderdetailid,
            productid
        FROM sales.salesorderdetail
        WHERE salesorderid = soh.salesorderid
        ORDER BY salesorderdetailid
        LIMIT 1
    ) AS sod ON true
    INNER JOIN production.product AS p
            ON p.productid = sod.productid
    INNER JOIN sales.customer AS c
            ON c.customerid = soh.customerid
    ORDER BY soh.salesorderid,
            sod.salesorderdetailid
    LIMIT :salesorder_limit
    FOR UPDATE OF soh;
    */

ROLLBACK;