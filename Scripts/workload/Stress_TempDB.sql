-- PostgreSQL temporary-table workload for pgbench.
-- pgbench repeats this script, replacing the original T-SQL WHILE loop.
-- PostgreSQL temporary tables are session-local and use temporary files when
-- their data exceeds memory; there is no separate tempdb database.

\set customerid random(11000, 30118)

BEGIN;

CREATE TEMP TABLE sales_report ON COMMIT DROP AS
SELECT sod.salesorderid,
                   sod.orderqty,
                   sod.productid,
                   p.name,
                   p.class,
                   sod.unitprice,
                   sod.linetotal
FROM sales.salesorderdetail AS sod
JOIN production.product AS p
      ON p.productid = sod.productid
WHERE false;

INSERT INTO sales_report (
            salesorderid,
            orderqty,
            productid,
            name,
            class,
            unitprice,
            linetotal
)
SELECT sod.salesorderid,
                   sod.orderqty,
                   sod.productid,
                   p.name,
                   p.class,
                   sod.unitprice,
                   sod.linetotal
FROM sales.salesorderheader AS soh
JOIN sales.salesorderdetail AS sod
      ON sod.salesorderid = soh.salesorderid
JOIN production.product AS p
      ON p.productid = sod.productid
WHERE soh.customerid = :customerid;

SELECT :customerid AS customerid,
                   salesorderid,
                   orderqty,
                   productid,
                   name,
                   class,
                   unitprice,
                   linetotal
FROM sales_report
ORDER BY salesorderid,
                         productid;

COMMIT;



