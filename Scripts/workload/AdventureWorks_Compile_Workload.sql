/* 
	PostgreSQL/pgbench version of AdventureWorks Compile Workload
	
	This script is designed to be executed with pgbench to simulate compile-intensive workloads
	that were originally designed for SQL Server with OSTRESS.
	
	Original T-SQL script converted to PostgreSQL with pgbench random variable support.
	
	Usage:
	  pgbench -c <num_clients> -j <num_threads> -T <duration_seconds> -f AdventureWorks_Compile_Workload_pgbench.sql -r adventureworks
	
	Example:
	  pgbench -c 10 -j 4 -T 60 -f AdventureWorks_Compile_Workload_pgbench.sql -r adventureworks
	
	This Sample Code is provided for the purpose of illustration only and is not intended
	to be used in a production environment. THIS SAMPLE CODE AND ANY RELATED INFORMATION ARE
	PROVIDED "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER EXPRESSED OR IMPLIED, INCLUDING BUT
	NOT LIMITED TO THE IMPLIED WARRANTIES OF MERCHANTABILITY AND/OR FITNESS FOR A PARTICULAR
	PURPOSE.
*/

-- Set random variables using the actual ranges from the database
-- These will be regenerated for each iteration by pgbench
\set customerid random(11000, 30118)
\set personid random(1, 20777)
\set productid random(316, 999)
\set birthyear random(1951, 1991)
\set territoryid random(1, 10)
\set salesyear random(2011, 2014)

-- Query 1: Person/Customer/Store join by LastName
-- Note: In the original script, this used dynamic SQL with LastName from a random person
-- In pgbench, we'll query by PersonID directly for simplicity
SELECT p.title || ' ' || p.firstname || ' ' || p.lastname AS fullname,
       c.accountnumber,
       s.name
FROM   person.person AS p
       INNER JOIN sales.customer AS c
       ON c.personid = p.businessentityid
       INNER JOIN sales.store AS s
       ON s.businessentityid = c.storeid
WHERE  p.businessentityid = :personid;

-- Query 2: Hash match - Customer/SalesOrderHeader join
SELECT soh.billtoaddressid
FROM   sales.customer AS c
       LEFT OUTER JOIN sales.salesorderheader AS soh
       ON c.customerid = soh.customerid
WHERE  c.customerid = :customerid;

-- Query 3: Hash match - SalesOrderHeader/SalesOrderDetail/CreditCard join
SELECT soh.purchaseordernumber,
       soh.accountnumber,
       sod.orderqty,
       sod.linetotal,
       c.cardnumber
FROM   sales.salesorderheader AS soh
       INNER JOIN sales.salesorderdetail AS sod
       ON soh.salesorderid = sod.salesorderid
       INNER JOIN sales.creditcard AS c
       ON soh.creditcardid = c.creditcardid
WHERE  soh.customerid = :customerid;

-- Query 4: Merge join - PurchaseOrderHeader/PurchaseOrderDetail join
SELECT poh.purchaseorderid,
       poh.orderdate,
       pod.productid,
       pod.duedate,
       poh.vendorid,
       pod.*
FROM   purchasing.purchaseorderheader AS poh
       INNER JOIN purchasing.purchaseorderdetail AS pod
       ON poh.purchaseorderid = pod.purchaseorderid
WHERE  pod.productid = :productid;

-- Query 5: Hash + parallelism with ORDER BY - Product/SalesOrderDetail join
SELECT p.name,
       sod.orderqty,
       sod.unitprice,
       sod.*
FROM   production.product AS p
       INNER JOIN sales.salesorderdetail AS sod
       ON p.productid = sod.productid
WHERE  sod.productid = :productid
ORDER BY p.name DESC;

-- Query 6: Hash + parallelism without ORDER BY - Product/SalesOrderDetail join
-- This query tests the cost difference when ORDER BY is removed
SELECT p.name,
       sod.orderqty,
       sod.unitprice
FROM   production.product AS p
       INNER JOIN sales.salesorderdetail AS sod
       ON p.productid = sod.productid
WHERE  sod.productid = :productid;

-- Query 7: Loop joins - Person/Employee/BusinessEntityAddress join by birth year
SELECT p.firstname,
       p.lastname,
       a.modifieddate
FROM   person.person AS p
       INNER JOIN humanresources.employee AS e
       ON p.businessentityid = e.businessentityid
       INNER JOIN person.businessentityaddress AS a
       ON e.businessentityid = a.businessentityid
WHERE  EXTRACT(YEAR FROM e.birthdate) = :birthyear;

-- Query 8: SalesTerritoryHistory by territory and date range
SELECT *
FROM   sales.salesterritoryhistory
WHERE  territoryid = :territoryid
       AND startdate >= (:salesyear || '-01-01')::date
       AND startdate <= (:salesyear || '-12-31')::date;

-- Query 9: Hash match - SalesOrderDetail/SalesOrderHeader join by territory and product
SELECT soh.*
FROM   sales.salesorderdetail AS sod
       INNER JOIN sales.salesorderheader AS soh
       ON soh.salesorderid = sod.salesorderid
WHERE  soh.territoryid = :territoryid
       AND sod.productid = :productid;
