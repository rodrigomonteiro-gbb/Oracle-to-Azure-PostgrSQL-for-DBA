-- PART II — Creating partitions
-- 5. Lab setup
CREATE SCHEMA IF NOT EXISTS partlab;
SET search_path TO partlab, public;
\timing on

DROP TABLE IF EXISTS sales CASCADE;

-- 6. Partitioning an empty table — the easy path
-- 6.1 RANGE partitioning
-- The PARENT. Note: no storage, and the PK must include the partition key.
CREATE TABLE sales (
    sale_id     bigint      GENERATED ALWAYS AS IDENTITY,
    order_date  date        NOT NULL,
    customer_id int         NOT NULL,
    amount      numeric(12,2) NOT NULL,
    region      text        NOT NULL,
    PRIMARY KEY (sale_id, order_date)        -- partition key REQUIRED in the PK
) PARTITION BY RANGE (order_date);


-- Children. Bounds are [inclusive, exclusive).
CREATE TABLE sales_2024_q1 PARTITION OF sales
    FOR VALUES FROM ('2024-01-01') TO ('2024-04-01');
CREATE TABLE sales_2024_q2 PARTITION OF sales
    FOR VALUES FROM ('2024-04-01') TO ('2024-07-01');
CREATE TABLE sales_2024_q3 PARTITION OF sales
    FOR VALUES FROM ('2024-07-01') TO ('2024-10-01');
CREATE TABLE sales_2024_q4 PARTITION OF sales
    FOR VALUES FROM ('2024-10-01') TO ('2025-01-01');

-- A DEFAULT partition catches anything outside every defined range
CREATE TABLE sales_default PARTITION OF sales DEFAULT;

-- Verify the structure
SELECT c.relname AS partition_name,
       pg_get_expr(c.relpartbound, c.oid) AS bounds,
       pg_size_pretty(pg_relation_size(c.oid)) AS size
FROM pg_class c
JOIN pg_inherits i ON i.inhrelid = c.oid
WHERE i.inhparent = 'sales'::regclass
ORDER BY c.relname;


-- 6.2 Routing happens automatically
INSERT INTO sales (order_date, customer_id, amount, region) VALUES
  ('2024-02-15', 101,  250.00, 'US'),
  ('2024-05-20', 102, 1200.50, 'EU'),
  ('2024-08-03', 103,  875.25, 'APAC'),
  ('2024-11-11', 104, 3400.00, 'US');

-- tableoid reveals WHICH partition each row landed in
SELECT tableoid::regclass AS lives_in, sale_id, order_date, amount
FROM sales ORDER BY order_date;


-- 6.3 LIST partitioning
--------------------------------------------------------
DROP TABLE IF EXISTS events CASCADE;

CREATE TABLE events (
    event_id  bigint GENERATED ALWAYS AS IDENTITY,
    region    text NOT NULL,
    payload   jsonb,
    logged_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (event_id, region)
) PARTITION BY LIST (region);

CREATE TABLE events_us   PARTITION OF events FOR VALUES IN ('US','CA','MX');
CREATE TABLE events_eu   PARTITION OF events FOR VALUES IN ('UK','DE','FR','ES','IT');
CREATE TABLE events_apac PARTITION OF events FOR VALUES IN ('JP','AU','SG','IN');
CREATE TABLE events_other PARTITION OF events DEFAULT;

-- Verify the structure
SELECT c.relname AS partition_name,
       pg_get_expr(c.relpartbound, c.oid) AS bounds,
       pg_size_pretty(pg_relation_size(c.oid)) AS size
FROM pg_class c
JOIN pg_inherits i ON i.inhrelid = c.oid
WHERE i.inhparent = 'events'::regclass
ORDER BY c.relname;


--------------------------------------------------------
-- 6.4 HASH partitioning
DROP TABLE IF EXISTS accounts CASCADE;

CREATE TABLE accounts (
    account_id bigint NOT NULL,
    owner_name text   NOT NULL,
    balance    numeric(14,2) NOT NULL DEFAULT 0,
    PRIMARY KEY (account_id)
) PARTITION BY HASH (account_id);

CREATE TABLE accounts_p0 PARTITION OF accounts FOR VALUES WITH (MODULUS 4, REMAINDER 0);
CREATE TABLE accounts_p1 PARTITION OF accounts FOR VALUES WITH (MODULUS 4, REMAINDER 1);
CREATE TABLE accounts_p2 PARTITION OF accounts FOR VALUES WITH (MODULUS 4, REMAINDER 2);
CREATE TABLE accounts_p3 PARTITION OF accounts FOR VALUES WITH (MODULUS 4, REMAINDER 3);


-- Verify the structure
SELECT c.relname AS partition_name,
       pg_get_expr(c.relpartbound, c.oid) AS bounds,
       pg_size_pretty(pg_relation_size(c.oid)) AS size
FROM pg_class c
JOIN pg_inherits i ON i.inhrelid = c.oid
WHERE i.inhparent = 'accounts'::regclass
ORDER BY c.relname;


-------------------------------------------------
-- 6.5 Sub-partitioning
DROP TABLE IF EXISTS metrics CASCADE;

CREATE TABLE metrics (
    ts       timestamptz NOT NULL,
    region   text        NOT NULL,
    device   int         NOT NULL,
    reading  numeric(10,3)
) PARTITION BY RANGE (ts);

-- This partition is ITSELF partitioned
CREATE TABLE metrics_2024_10 PARTITION OF metrics
    FOR VALUES FROM ('2024-10-01') TO ('2024-11-01')
    PARTITION BY LIST (region);

CREATE TABLE metrics_2024_10_us PARTITION OF metrics_2024_10 FOR VALUES IN ('US');
CREATE TABLE metrics_2024_10_eu PARTITION OF metrics_2024_10 FOR VALUES IN ('EU');
CREATE TABLE metrics_2024_10_def PARTITION OF metrics_2024_10 DEFAULT;


-- Verify the structure
SELECT c.relname AS partition_name,
       pg_get_expr(c.relpartbound, c.oid) AS bounds,
       pg_size_pretty(pg_relation_size(c.oid)) AS size
FROM pg_class c
JOIN pg_inherits i ON i.inhrelid = c.oid
WHERE i.inhparent = 'metrics'::regclass
ORDER BY c.relname;

-- Verify the structure
SELECT c.relname AS partition_name,
       pg_get_expr(c.relpartbound, c.oid) AS bounds,
       pg_size_pretty(pg_relation_size(c.oid)) AS size
FROM pg_class c
JOIN pg_inherits i ON i.inhrelid = c.oid
WHERE i.inhparent = 'metrics_2024_10'::regclass
ORDER BY c.relname;




-- 7. Partitioning a table that already has data
--------------------------------------------------------------------------
-- Partitioning a table that already has data
-- This is the hard case, and the one that matters in a migration.
--------------------------------------------------------------------------

-- 7.1 Build the demo table — a large salesorderdetail
-- Shaped like AdventureWorks Sales.SalesOrderDetail, enlarged to be worth partitioning.

SET search_path TO partlab, public;

DROP TABLE IF EXISTS salesorderdetail CASCADE;

CREATE TABLE salesorderdetail (
    salesorderid           int           NOT NULL,
    salesorderdetailid     bigint        GENERATED ALWAYS AS IDENTITY,
    carriertrackingnumber  varchar(25),
    orderqty               smallint      NOT NULL,
    productid              int           NOT NULL,
    specialofferid         int           NOT NULL,
    unitprice              numeric(19,4) NOT NULL,
    unitpricediscount      numeric(19,4) NOT NULL DEFAULT 0,
    linetotal              numeric(38,6) NOT NULL,
    rowguid                uuid          NOT NULL DEFAULT gen_random_uuid(),
    modifieddate           timestamp     NOT NULL DEFAULT now(),
    orderdate              date          NOT NULL          -- our partition key
);

-- populate data
-- option A -- about 2:30 to 3:00 minutes
INSERT INTO salesorderdetail
    (salesorderid, carriertrackingnumber, orderqty, productid, specialofferid,
     unitprice, unitpricediscount, linetotal, orderdate, modifieddate)
SELECT (g / 4) + 43659,
       upper(substr(md5(random()::text), 1, 4)) || '-' ||
       upper(substr(md5(random()::text), 1, 4)) || '-' ||
       upper(substr(md5(random()::text), 1, 2)),
       (random() * 10)::smallint + 1,
       (random() * 500)::int + 707,
       (random() * 15)::int + 1,
       round((random() * 2000 + 5)::numeric, 4),
       round((random() * 0.2)::numeric, 4),
       round((random() * 3000 + 10)::numeric, 6),
       d.order_date,
       d.order_date + (random() * interval '12 hours')
FROM generate_series(1, 12000000) g
CROSS JOIN LATERAL (
    SELECT (DATE '2022-01-01' + ((g * 7) % 1095) * interval '1 day')::date AS order_date
) d;

ANALYZE salesorderdetail;

SELECT count(*) AS rows,
       pg_size_pretty(pg_total_relation_size('salesorderdetail')) AS total_size,
       min(orderdate) AS from_date, max(orderdate) AS to_date
FROM salesorderdetail;

-- option b 
-- enlarge sales.salesorderdetail if you have AdventureWorks loaded:

-- Multiply the real table 200x, spreading dates across 3 years
INSERT INTO partlab.salesorderdetail
    (salesorderid, carriertrackingnumber, orderqty, productid, specialofferid,
     unitprice, unitpricediscount, linetotal, orderdate, modifieddate)
SELECT d.salesorderid + (m.n * 100000),
       d.carriertrackingnumber,
       d.orderqty,
       d.productid,
       d.specialofferid,
       d.unitprice,
       d.unitpricediscount,
       d.linetotal,
       (DATE '2022-01-01' + ((m.n * 5 + d.salesorderdetailid) % 1095) * interval '1 day')::date,
       now()
FROM sales.salesorderdetail d
CROSS JOIN generate_series(1, 200) AS m(n);

ANALYZE partlab.salesorderdetail;

-- Index it the way an unpartitioned table would be
CREATE INDEX ix_sod_orderdate ON salesorderdetail (orderdate); -- 10 sec
CREATE INDEX ix_sod_productid ON salesorderdetail (productid); -- 10 sec
ANALYZE salesorderdetail; -- 0.5 sec

-- 7.2 The impact of partitioning existing data
-- measuring The impact of partitioning existing data
/*
You cannot convert a table in place. ALTER TABLE ... PARTITION BY does not exist. Your options:

Method			Downtime		Disk needed		Complexity
------			---------		----------- 	-----------
A — Create new 	Minutes to
	+ copy 		hours
	+ rename	(write outage)	2× table size	Low

B — Create new Seconds 			Minimal			Medium
	+ ATTACH 	
the old table 
as one 
partition		

C — Online w/	Near-zero		2×				High 	
logical replication 
/ pg_partman	

*/

-- 7.2.1 Method A — copy into a new partitioned table
-- Method A — copy into a new partitioned table
-- 1. Build the partitioned shell
DROP TABLE IF EXISTS sod_part CASCADE;

CREATE TABLE sod_part (LIKE partlab.salesorderdetail INCLUDING DEFAULTS INCLUDING CONSTRAINTS)
PARTITION BY RANGE (orderdate);

-- 2. Create partitions covering the full data range (quarterly here)
DO $$
DECLARE
    d date := DATE '2022-01-01';
BEGIN
    WHILE d < DATE '2025-01-01' LOOP
        EXECUTE format(
            'CREATE TABLE %I PARTITION OF sod_part FOR VALUES FROM (%L) TO (%L)',
            'sod_part_' || to_char(d, 'YYYY') || '_q' || to_char(d, 'Q'),
            d, d + interval '3 months');
        d := (d + interval '3 months')::date;
    END LOOP;
END $$;

-- 2B
-- Verify the structure
SELECT c.relname AS partition_name,
       pg_get_expr(c.relpartbound, c.oid) AS bounds,
       pg_size_pretty(pg_relation_size(c.oid)) AS size
FROM pg_class c
JOIN pg_inherits i ON i.inhrelid = c.oid
WHERE i.inhparent = 'sod_part'::regclass
ORDER BY c.relname;

-- 3. Copy. THIS is the expensive step.
INSERT INTO sod_part SELECT * FROM partlab.salesorderdetail; -- about 30 sec

-- 4. Index AFTER loading -- far faster than loading into indexed partitions
CREATE INDEX ix_sodpart_orderdate ON sod_part (orderdate);
CREATE INDEX ix_sodpart_productid ON sod_part (productid); -- 15 sec

ANALYZE sod_part;

-- 5. Swap (inside a transaction -- brief ACCESS EXCLUSIVE)
BEGIN;
  ALTER TABLE salesorderdetail 	RENAME TO salesorderdetail_old;
  ALTER TABLE sod_part         			RENAME TO salesorderdetail;
COMMIT;
--ROLLBACK

-- 7.2.2 Method B — attach the existing table as a partition (minimal downtime)
-- for large tables: keep the historical data exactly where it is.

-- Remove only an empty parent left by a failed attempt. Refuse to continue if
-- any partition is already attached, because dropping the tree risks data loss.
DO $$
BEGIN
    IF to_regclass('partlab.sod_live') IS NOT NULL THEN
        IF EXISTS (
            SELECT 1
            FROM pg_inherits
            WHERE inhparent = 'partlab.sod_live'::regclass
        ) THEN
            RAISE EXCEPTION
                'partlab.sod_live already has attached partitions; stop and inspect it';
        END IF;

        DROP TABLE partlab.sod_live;
    END IF;
END $$;

-- 1. New partitioned parent
-- 1. New partitioned parent. The parent owns the identity definition and
--    receives a new sequence; partitions cannot own identity definitions.
CREATE TABLE partlab.sod_live (
    LIKE partlab.salesorderdetail_old INCLUDING DEFAULTS INCLUDING IDENTITY
)
PARTITION BY RANGE (orderdate);

SELECT conname AS constraint_name,
       pg_get_constraintdef(oid) AS definition
FROM pg_constraint
WHERE --conrelid = 'public.my_table'::regclass
  		--AND 
		  contype = 'c'
		  AND
		  conname = 'ck_sod_hist';
		  
SELECT n.nspname AS schema_name,
       t.relname AS table_name,
       c.conname AS constraint_name,
       pg_get_constraintdef(c.oid) AS definition
FROM pg_constraint AS c
JOIN pg_class AS t
  ON t.oid = c.conrelid
JOIN pg_namespace AS n
  ON n.oid = t.relnamespace
WHERE c.conname = 'ck_sod_hist'
ORDER BY n.nspname, t.relname;

-- DROP CONSTRAINT ck_sod_hist
-- 2. CRITICAL: add a CHECK constraint matching the future partition bound.
--    Without it, ATTACH must scan the whole table to prove every row fits.
--    With it, PostgreSQL trusts the constraint and ATTACH is nearly instant.
-- 2. CRITICAL: add a CHECK constraint matching the future partition bound.
--    Without it, ATTACH must scan the whole table to prove every row fits.
--    With it, PostgreSQL trusts the constraint and ATTACH is nearly instant.
--    The catalog check makes this step safe to repeat after a failed ATTACH.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'partlab.salesorderdetail_old'::regclass
          AND conname = 'ck_sod_hist'
    ) THEN
        ALTER TABLE partlab.salesorderdetail_old
            ADD CONSTRAINT ck_sod_hist
            CHECK (orderdate >= DATE '2022-01-01'
               AND orderdate <  DATE '2025-01-01')
            NOT VALID;
    END IF;
END $$;

ALTER TABLE partlab.salesorderdetail_old
    VALIDATE CONSTRAINT ck_sod_hist;  -- no rescan if already valid
	
-- 2B
-- Verify the structure
SELECT c.relname AS partition_name,
       pg_get_expr(c.relpartbound, c.oid) AS bounds,
       pg_size_pretty(pg_relation_size(c.oid)) AS size
FROM pg_class c
JOIN pg_inherits i ON i.inhrelid = c.oid
WHERE i.inhparent = 'partlab.sod_live'::regclass
ORDER BY c.relname;

-- 3. The standalone table still owns its original identity definition.
--    A partition must inherit identity behavior from its partitioned parent
--    and may not retain an identity definition of its own.
ALTER TABLE partlab.salesorderdetail_old
    ALTER COLUMN salesorderdetailid DROP IDENTITY IF EXISTS;

-- 4. Attach. Fast, because the CHECK already proves the bound.
ALTER TABLE partlab.sod_live
    ATTACH PARTITION partlab.salesorderdetail_old
    FOR VALUES FROM ('2022-01-01') TO ('2025-01-01');
	

-- 5. Advance the new parent identity sequence beyond the historical IDs.
SELECT setval(
    pg_get_serial_sequence('partlab.sod_live', 'salesorderdetailid'),
    GREATEST(COALESCE(max_id, 1), 1),
    max_id IS NOT NULL
)
FROM (
    SELECT max(salesorderdetailid) AS max_id
    FROM partlab.sod_live
) AS existing_ids;

-- 6. Add forward partitions for new data
CREATE TABLE partlab.sod_live_2025_q1 PARTITION OF partlab.sod_live
    FOR VALUES FROM ('2025-01-01') TO ('2025-04-01');

-- 7. The redundant CHECK can now be dropped
ALTER TABLE partlab.salesorderdetail_old
    DROP CONSTRAINT ck_sod_hist;

-- Verify the structure
SELECT c.relname AS partition_name,
       pg_get_expr(c.relpartbound, c.oid) AS bounds,
       pg_size_pretty(pg_relation_size(c.oid)) AS size
FROM pg_class c
JOIN pg_inherits i ON i.inhrelid = c.oid
WHERE i.inhparent = 'partlab.sod_live'::regclass
ORDER BY c.relname;


-- 7.2.3 pg_partman — automated partition lifecycle+
-- 7.2.4 Method C - pg_partman

-- Manual DO blocks do not scale operationally. 
-- pg_partman creates partitions ahead of time and retires old ones on a schedule.

-- On Azure Flexible Server: add PG_PARTMAN (and PG_CRON for scheduling) to the
-- azure.extensions server parameter first, then create them here.
CREATE EXTENSION IF NOT EXISTS pg_partman;

-- pg_partman objects are commonly installed in public on Azure, not in a
-- schema named partman. Discover the extension schema instead of assuming it.
SELECT e.extversion,
       n.nspname AS extension_schema
FROM pg_extension e
JOIN pg_namespace n ON n.oid = e.extnamespace
WHERE e.extname = 'pg_partman';

-- Put the actual extension schema first for the rest of this session. This
-- makes the example work whether pg_partman is in public, partman, or another
-- allowed schema.
SELECT set_config(
    'search_path',
    quote_ident(n.nspname) || ', partlab, public',
    false
) AS effective_search_path
FROM pg_extension e
JOIN pg_namespace n ON n.oid = e.extnamespace
WHERE e.extname = 'pg_partman';

-- Verify the structure before partman
SELECT c.relname AS partition_name,
       pg_get_expr(c.relpartbound, c.oid) AS bounds,
       pg_size_pretty(pg_relation_size(c.oid)) AS size
FROM pg_class c
JOIN pg_inherits i ON i.inhrelid = c.oid
WHERE i.inhparent = 'partlab.sod_live'::regclass
ORDER BY c.relname;

SELECT create_parent(
    p_parent_table => 'partlab.sod_live',
    p_control      => 'orderdate',
    p_interval     => '1 month',
    p_premake      => 4                -- keep 4 future partitions ready
);

-- Verify the structure after partman
SELECT c.relname AS partition_name,
       pg_get_expr(c.relpartbound, c.oid) AS bounds,
       pg_size_pretty(pg_relation_size(c.oid)) AS size
FROM pg_class c
JOIN pg_inherits i ON i.inhrelid = c.oid
WHERE i.inhparent = 'partlab.sod_live'::regclass
ORDER BY c.relname;

-- Retention: drop partitions older than 24 months
UPDATE part_config
SET retention = '24 months',
    retention_keep_table = false
WHERE parent_table = 'partlab.sod_live';

-- Verify the structure after partman
SELECT c.relname AS partition_name,
       pg_get_expr(c.relpartbound, c.oid) AS bounds,
       pg_size_pretty(pg_relation_size(c.oid)) AS size
FROM pg_class c
JOIN pg_inherits i ON i.inhrelid = c.oid
WHERE i.inhparent = 'partlab.sod_live'::regclass
ORDER BY c.relname;

-- Run maintenance (schedule with pg_cron)
SELECT run_maintenance();

-- Restore the workshop search path after the extension calls.
SET search_path TO partlab, public;















-- PART III - indexes on partitioned tables
-- 8. How indexes work across partitions
-- 8.1 Creating on the parent cascades to every child

SET search_path TO partlab, public;

-- ONE statement, but it creates an index on EVERY partition
CREATE INDEX ix_sales_customer ON sales (customer_id);

-- The parent index is a "partitioned index" -- metadata only, zero bytes.
-- The real indexes are the per-partition children.
SELECT c.relname                                AS index_name,
       c.relkind,                               -- 'I' = partitioned, 'i' = real
       CASE c.relkind WHEN 'I' THEN 'partitioned (metadata only)'
                      WHEN 'i' THEN 'physical index' END AS kind,
       pg_size_pretty(pg_relation_size(c.oid))  AS size,
       i.inhparent::regclass                    AS parent_index
FROM pg_class c
LEFT JOIN pg_inherits i ON i.inhrelid = c.oid
WHERE c.relname LIKE 'ix_sales_customer%' OR c.relname LIKE 'sales%customer%'
ORDER BY c.relkind DESC, c.relname;

-- 8.2 YES, index a single partition
-- This is a real capability and a genuine advantage over a monolithic table.

-- Index that exists ONLY on the current quarter
CREATE INDEX ix_sales_q4_region ON sales_2024_q4 (region);

-- Verify it is local
SELECT tablename, indexname
FROM pg_indexes
WHERE schemaname = 'partlab' AND tablename LIKE 'sales_2024%'
ORDER BY tablename, indexname;

-- There are two different kinds of child indexes, and the distinction determines whether they can be dropped independently:
-- 1. **Independent local index:** created directly on one partition, such as `ix_sales_q4_region`. It can be dropped normally.
-- 2. **Attached child index:** created by a parent partitioned index, such as the Q1 child of `ix_sales_customer`. It is a required dependency of the parent and **cannot be dropped by itself**.

-- Supported: this index was created directly on one partition and is independent.
DROP INDEX IF EXISTS partlab.ix_sales_q4_region;

-- To change an existing parent-managed index into a hot-partition-only strategy, drop the **parent index** and then create independent indexes only where they are needed:
-- Drops the metadata-only parent and every attached customer_id child index.
DROP INDEX partlab.ix_sales_customer;
-- Recreate customer_id coverage only on the hot partition.
CREATE INDEX ix_sales_q4_customer_hot
    ON partlab.sales_2024_q4 (customer_id);

----------------------------------------------------
-- 8.3 Building parent indexes without a long lock
----------------------------------------------------
-- CREATE INDEX on the parent locks **every** partition for the whole build. For a large table, do it partition by partition:

-- 1. Create the parent index as metadata ONLY -- instant, no build
CREATE INDEX ix_sales_amount ON ONLY sales (amount);
-- The parent index is marked INVALID until every partition has one attached

-- Show the parent index state. Run this again after each ATTACH below:
-- attached_child_indexes increases, and status changes to VALID only when
-- every table partition has a matching attached index.
SELECT i.indexrelid::regclass AS parent_index,
       i.indisvalid,
       i.indisready,
       count(ci.inhrelid) AS attached_child_indexes,
       (
           SELECT count(*)
           FROM pg_inherits ti
           WHERE ti.inhparent = 'partlab.sales'::regclass
       ) AS required_child_indexes,
       CASE
           WHEN i.indisvalid THEN 'VALID'
           ELSE 'INVALID - missing child indexes'
       END AS status
FROM pg_index i
LEFT JOIN pg_inherits ci ON ci.inhparent = i.indexrelid
WHERE i.indexrelid = 'partlab.ix_sales_amount'::regclass
GROUP BY i.indexrelid, i.indisvalid, i.indisready;

/*
Execution requirement for step 2: CREATE INDEX CONCURRENTLY cannot run inside either an explicit transaction or the implicit transaction created when several commands are submitted as one batch.
==================================================================================================================================================================================================
In pgAdmin Query Tool, make sure Auto-commit is on.
If you previously issued BEGIN, run ROLLBACK; separately first.
Run each of the following five code blocks separately. Do not select and execute all five statements together.
*/

-- 2. Build each partition's index CONCURRENTLY -- no write blocking
-- run each line separately
CREATE INDEX CONCURRENTLY ix_sales_q1_amount ON sales_2024_q1 (amount);
CREATE INDEX CONCURRENTLY ix_sales_q2_amount ON sales_2024_q2 (amount);
CREATE INDEX CONCURRENTLY ix_sales_q3_amount ON sales_2024_q3 (amount);
CREATE INDEX CONCURRENTLY ix_sales_q4_amount ON sales_2024_q4 (amount);
CREATE INDEX CONCURRENTLY ix_sales_def_amount ON sales_default (amount);
-- after creating these indexes run the previous query to see if the status has changed


-- 3. Attach each one to the parent
ALTER INDEX ix_sales_amount ATTACH PARTITION ix_sales_q1_amount;
ALTER INDEX ix_sales_amount ATTACH PARTITION ix_sales_q2_amount;
ALTER INDEX ix_sales_amount ATTACH PARTITION ix_sales_q3_amount;
ALTER INDEX ix_sales_amount ATTACH PARTITION ix_sales_q4_amount;
ALTER INDEX ix_sales_amount ATTACH PARTITION ix_sales_def_amount;

-- 4. Once ALL partitions are attached, the parent index becomes valid
SELECT indexrelid::regclass AS index_name, indisvalid
FROM pg_index WHERE indexrelid = 'ix_sales_amount'::regclass;

-- 4. Once ALL partitions are attached, confirm that the parent is valid
SELECT i.indexrelid::regclass AS parent_index,
       i.indisvalid,
       i.indisready,
       count(ci.inhrelid) AS attached_child_indexes,
       CASE WHEN i.indisvalid THEN 'VALID' ELSE 'INVALID' END AS status
FROM pg_index i
LEFT JOIN pg_inherits ci ON ci.inhparent = i.indexrelid
WHERE i.indexrelid = 'partlab.ix_sales_amount'::regclass
GROUP BY i.indexrelid, i.indisvalid, i.indisready;



-- 8.4 Unique constraints — the hard limitation

-- Fails: partition key not in the unique key
ALTER TABLE sales ADD CONSTRAINT uq_sales_customer UNIQUE (customer_id);
-- ERROR: unique constraint on partitioned table must include all partitioning columns

-- Works:
ALTER TABLE sales ADD CONSTRAINT uq_sales_cust_date UNIQUE (customer_id, order_date);


-- 8.5. Foreign keys and CHECK constraints
-- PostgreSQL 12+ allows foreign keys from and to partitioned tables. The normal uniqueness rule still applies: a referenced primary key or unique constraint on a partitioned parent must include every partition-key column.
CREATE TABLE sale_items (
    sale_id     bigint NOT NULL,
    order_date  date   NOT NULL,
    line_no     int    NOT NULL,
    PRIMARY KEY (sale_id, order_date, line_no),
    FOREIGN KEY (sale_id, order_date)
        REFERENCES sales (sale_id, order_date)
);


































-- PART IV — Querying partitioned tables

-- 9. Partition pruning 
-- 9.1 Plan-time pruning
SET search_path TO partlab, public;

-- GOOD: filters on the partition key -- prunes to one partition
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT count(*), sum(linetotal)
FROM partlab.salesorderdetail
WHERE orderdate >= DATE '2023-04-01' AND orderdate < DATE '2023-07-01';

-- BAD: no partition key predicate -- scans EVERY partition
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT count(*) FROM partlab.salesorderdetail WHERE productid = 870;

> Compare these two plans side by side — this is the core demonstration**
>
> The first shows an `Append` with **one** child. The second shows an `Append` with **twelve**, each with its own scan, each contributing buffers. Same table, same data. **The only difference is whether the WHERE clause names the partition key.**

-- The subtle trap: a function on the partition key defeats plan-time pruning
EXPLAIN (COSTS OFF)
SELECT count(*) FROM partlab.salesorderdetail
WHERE extract(year FROM orderdate) = 2023;
-- Scans everything.

-- The rewrite that prunes:
EXPLAIN (COSTS OFF)
SELECT count(*) FROM partlab.salesorderdetail
WHERE orderdate >= DATE '2023-01-01' AND orderdate < DATE '2024-01-01';

-- 9.2 Run-time pruning
-- When the value is not known at plan time — a parameter, or a join key — PostgreSQL prunes during execution (PG 11+).
PREPARE q(date, date) AS
SELECT count(*) FROM partlab.salesorderdetail
WHERE orderdate >= $1 AND orderdate < $2;

EXPLAIN (ANALYZE, COSTS OFF)
EXECUTE q(DATE '2023-04-01', DATE '2023-07-01');


-- 9.3. Querying one partition directly

-- Partitions are real tables -- query them by name
SELECT count(*) FROM sod_part_2023_q2;

-- ONLY restricts to the parent alone (which holds no rows)
SELECT count(*) FROM ONLY partlab.salesorderdetail;      -- always 0

-- Which partition does each row live in?
SELECT tableoid::regclass AS partition, count(*)
FROM partlab.salesorderdetail
GROUP BY 1
ORDER BY 1;

-- Filter by partition using tableoid
SELECT * FROM partlab.salesorderdetail
WHERE tableoid = 'sod_part_2023_q2'::regclass
LIMIT 10;

> Querying a partition by name bypasses the parent and is marginally faster** — no `Append`, no pruning logic. But it **hard-codes physical layout into application SQL.** Use it for maintenance and ad-hoc investigation; **never in application code**, which should always address the parent.

--- 9.4 Row counts and sizes per partition
SELECT c.relname                                   AS partition,
       pg_get_expr(c.relpartbound, c.oid)          AS bounds,
       c.reltuples::bigint                         AS est_rows,
       pg_size_pretty(pg_relation_size(c.oid))     AS heap_size,
       pg_size_pretty(pg_indexes_size(c.oid))      AS index_size,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS total
FROM pg_class c
JOIN pg_inherits i ON i.inhrelid = c.oid
WHERE i.inhparent = 'partlab.salesorderdetail'::regclass
ORDER BY c.relname;

-- 9.5 Partition-wise joins and aggregates — off by default
SHOW enable_partitionwise_join;       -- off
SHOW enable_partitionwise_aggregate;  -- off

SET enable_partitionwise_join = on;
SET enable_partitionwise_aggregate = on;

> What changes in the plan**
>
> Without: `Append` all partitions → then one big `Hash Join` / `HashAggregate` at the top.
> With: the `Hash Join` / `HashAggregate` appears **inside each `Append` child** — the join runs per partition pair, on much smaller inputs.
>
> Why it is off by default:** it increases planning time and memory, and only pays off when both tables share an identical partitioning scheme. **Enable it per-session or per-workload after measuring — not globally as a default.**

---

-- PART V — Maintenance
-- 10. VACUUM and partitioned tables
-- 10.1 The fundamental rule
-- Each partition is an independent table for vacuum purposes.** The parent holds no rows and needs no heap vacuum.

-- Vacuums EVERY partition (the parent itself has nothing to vacuum)
VACUUM (VERBOSE, ANALYZE) partlab.salesorderdetail;

-- Vacuum one partition only -- the normal maintenance unit
VACUUM (VERBOSE, ANALYZE) sod_part_2023_q2;

> What to look for in the `VERBOSE` output**
>
> Vacuuming the parent produces a **separate block of output per partition**:
>
> 
> INFO:  vacuuming "partlab.sod_part_2022_q1"
> INFO:  scanned index "sod_part_2022_q1_orderdate_idx" to remove N row versions
> ...
> INFO:  vacuuming "partlab.sod_part_2022_q2"
> ...
> ```
>
> **Each partition is vacuumed serially, with its own index phase.** This is exactly why partitioning helps maintenance: you can vacuum one 85 GB partition in a window instead of one 2 TB table, and you can run several in parallel from separate sessions.

--- 10.2 Autovacuum treats partitions individually

-- Per-partition vacuum health
SELECT relname,
       n_live_tup, n_dead_tup,
       round(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 1) AS dead_pct,
       last_vacuum, last_autovacuum, last_analyze, last_autoanalyze
FROM pg_stat_user_tables
WHERE schemaname = 'partlab'
  AND (relname = 'salesorderdetail' OR relname LIKE 'sod_part_%')
ORDER BY relname;


-- The operational benefit:** autovacuum thresholds are evaluated **per partition**. On a 2 TB unpartitioned table, `autovacuum_vacuum_scale_factor = 0.2` means waiting for 400 GB of dead rows. **Partitioned, the same setting triggers at 20% of an 85 GB partition** — far sooner, and the resulting vacuum is far smaller. Partitioning fixes the large-table autovacuum problem almost for free.
-- Per-partition tuning — aggressive on hot, relaxed on cold:**

-- Current partition: heavy writes, vacuum eagerly
ALTER TABLE sod_part_2024_q4 SET (
    autovacuum_vacuum_scale_factor  = 0.02,
    autovacuum_analyze_scale_factor = 0.01,
    autovacuum_vacuum_cost_limit    = 2000
);

-- Archive partition: read-only, almost never needs vacuum
ALTER TABLE sod_part_2022_q1 SET (
    autovacuum_vacuum_scale_factor  = 0.4,
    autovacuum_enabled              = true    -- keep ON for wraparound freezing
);

-- > Never set `autovacuum_enabled = false` on an archive partition.** It stops anti-wraparound freezing, and a never-frozen archive partition eventually forces an emergency vacuum — or a shutdown. **Relax the thresholds; do not disable the mechanism.**

-- 10.3 VACUUM options with partitions

-- Parallel index vacuuming WITHIN one partition
VACUUM (PARALLEL 4) sod_part_2023_q2;

-- Freeze an archive partition once, then it needs almost nothing forever
VACUUM (FREEZE, ANALYZE) sod_part_2022_q1;

-- Skip index cleanup -- emergency only
VACUUM (INDEX_CLEANUP OFF) sod_part_2024_q4;

-- VACUUM FULL rebuilds ONE partition -- lock is scoped to that partition
VACUUM FULL sod_part_2022_q1;

-- `VACUUM FULL` on a single partition is dramatically more practical than on a monolithic table.** It takes `ACCESS EXCLUSIVE` on **that partition only** — queries touching other partitions continue. Combined with `VACUUM (FREEZE)` on archives, this is the standard pattern: freeze cold partitions once, and they largely stop needing maintenance.
-- `VACUUM FULL` on the *parent* rewrites every partition, holding locks across all of them.** Almost never what you want. **Always name the specific partition.**

-- 10.4 Monitoring
SELECT p.pid, a.query, p.relid::regclass AS current_partition,
       p.phase, p.heap_blks_total, p.heap_blks_scanned, p.index_vacuum_count
FROM pg_stat_progress_vacuum p
JOIN pg_stat_activity a USING (pid);

-- **`relid::regclass` shows which partition vacuum is currently on.** When vacuuming a parent, you watch it walk through the children one at a time.

-- 11. Statistics on partitioned tables
-- 11.1 Two levels of statistics

| Level | Used for | Maintained by autovacuum? |
| --- | --- | --- |
| **Per-partition** | Estimating within a partition after pruning | ✅ **Yes** |
| **Parent (inheritance) statistics** | Estimating across partitions, join planning, `GROUP BY` | ❌ **NO** |

-- 11.2 Demo — see both levels

ANALYZE partlab.salesorderdetail;   -- gathers parent and partition statistics

-- Parent-level: inherited = true
SELECT tablename, attname, n_distinct, correlation, inherited
FROM pg_stats
WHERE schemaname = 'partlab' AND tablename = 'salesorderdetail'
  AND attname IN ('orderdate','productid')
ORDER BY attname, inherited;

-- Per-partition
SELECT tablename, attname, n_distinct, correlation
FROM pg_stats
WHERE schemaname = 'partlab' AND tablename = 'sod_part_2023_q2'
  AND attname IN ('orderdate','productid')
ORDER BY attname;

-- 11.3 The parent-statistics gap — the one that bites people
-- Autovacuum analyzes each partition. It does NOT analyze the parent partitioned table.**

-- Proof: the parent never shows an autoanalyze timestamp
SELECT relname, last_analyze, last_autoanalyze, n_mod_since_analyze
FROM pg_stat_user_tables
WHERE schemaname = 'partlab'
  AND (relname = 'salesorderdetail' OR relname LIKE 'sod_part_%')
ORDER BY relname;

/*
> Consequences of stale parent statistics:**
>
> - Bad row estimates for queries spanning partitions
> - Poor join order when the partitioned table joins to others
> - Wrong `GROUP BY` and aggregate strategies
>
> **And the estimate error is invisible in the usual places** — each partition's own statistics are perfectly fresh, so nothing looks wrong until you compare `rows=` against `actual rows=` on the `Append` node.
*/

-- The fix — schedule it explicitly:**

-- Add to your maintenance job. This is NOT optional on a partitioned schema.
ANALYZE partlab.salesorderdetail;


-- Find partitioned parents that have never been analyzed
SELECT c.relname AS partitioned_table,
       s.last_analyze, s.last_autoanalyze,
       CASE WHEN s.last_analyze IS NULL AND s.last_autoanalyze IS NULL
            THEN '🔴 NEVER ANALYZED - parent stats missing'
            WHEN COALESCE(s.last_analyze, s.last_autoanalyze) < now() - interval '7 days'
            THEN '🟠 Stale'
            ELSE '🟢 Current' END AS status,
       'ANALYZE ' || c.relname::regclass || ';' AS fix
FROM pg_class c
LEFT JOIN pg_stat_user_tables s ON s.relid = c.oid
WHERE c.relkind = 'p'
ORDER BY c.relname;

-- > The diagnostic signature of missing parent statistics
-- >
-- > In `EXPLAIN ANALYZE`, look at the **`Append` node**: estimated `rows=` far off `actual rows=`, while each **individual child scan** has accurate estimates. **Children accurate, parent wrong** = run `ANALYZE <parent>`.

-- 11.4 Statistics targets and extended statistics

-- Per-partition target
ALTER TABLE sod_part_2023_q2 ALTER COLUMN productid SET STATISTICS 500;
ANALYZE sod_part_2023_q2;

-- On the parent -- inherited by future partitions
ALTER TABLE partlab.salesorderdetail
    ALTER COLUMN productid SET STATISTICS 500;
ANALYZE partlab.salesorderdetail;

-- Extended statistics (`CREATE STATISTICS`) must be created per partition.** They are **not** inherited from the parent. If correlated columns matter, script their creation into your partition-creation routine.

-- 12. Partition lifecycle operations
-- 12.1 Adding a partition

CREATE TABLE sod_part_2025_q1 PARTITION OF partlab.salesorderdetail
    FOR VALUES FROM ('2025-01-01') TO ('2025-04-01');
-- Inherits every parent index automatically

-- **Fast pattern for a large pre-built partition — load detached, then attach:**

-- 1. Build standalone (no partition overhead during load)
CREATE TABLE sod_part_2025_q2_new
    (LIKE partlab.salesorderdetail INCLUDING DEFAULTS);

-- 2. Load and index it offline
--    INSERT / COPY ...
CREATE INDEX ON sod_part_2025_q2_new (orderdate);
CREATE INDEX ON sod_part_2025_q2_new (productid);
ANALYZE sod_part_2025_q2_new;

-- 3. CHECK constraint so ATTACH skips the validation scan
ALTER TABLE sod_part_2025_q2_new
    ADD CONSTRAINT ck_bound
    CHECK (orderdate >= DATE '2025-04-01' AND orderdate < DATE '2025-07-01');

-- 4. Attach -- fast
ALTER TABLE partlab.salesorderdetail ATTACH PARTITION sod_part_2025_q2_new
    FOR VALUES FROM ('2025-04-01') TO ('2025-07-01');

ALTER TABLE sod_part_2025_q2_new DROP CONSTRAINT ck_bound;

-- 12.2 Removing a partition

-- Detach and keep the data as a standalone table (archival)
ALTER TABLE partlab.salesorderdetail DETACH PARTITION sod_part_2022_q1;

-- PG 14+: detach without a long lock
ALTER TABLE partlab.salesorderdetail
    DETACH PARTITION sod_part_2022_q2 CONCURRENTLY;

-- Or drop outright -- instant, regardless of size
DROP TABLE sod_part_2022_q3;

-- This is the headline benefit.** `DROP TABLE` on a 200 GB partition is a catalog operation and a file unlink — **effectively instant, minimal WAL, zero bloat.** A `DELETE` of the same 200 GB would run for hours, generate 200 GB+ of WAL, and leave a table that needs vacuuming for days.

-- 12.3 Archiving — detach, compress, retain

BEGIN;
  ALTER TABLE partlab.salesorderdetail DETACH PARTITION sod_part_2022_q4;
  ALTER TABLE sod_part_2022_q4 RENAME TO archive_sod_2022_q4;
COMMIT;

-- Now an ordinary table: export it, move it, or drop indexes to reclaim space
DROP INDEX IF EXISTS sod_part_2022_q4_productid_idx;

VACUUM (FULL, FREEZE, ANALYZE) archive_sod_2022_q4;

-- 12.4 Merging and splitting
-- PostgreSQL 16 and earlier have **no `MERGE PARTITION` or `SPLIT PARTITION`**. Do it manually:

-- Merge two still-attached 2023 quarters into a half-year partition
BEGIN;
  ALTER TABLE partlab.salesorderdetail DETACH PARTITION sod_part_2023_q1;
  ALTER TABLE partlab.salesorderdetail DETACH PARTITION sod_part_2023_q2;

  CREATE TABLE sod_part_2023_h1
      (LIKE partlab.salesorderdetail INCLUDING DEFAULTS);
  INSERT INTO sod_part_2023_h1 SELECT * FROM sod_part_2023_q1;
  INSERT INTO sod_part_2023_h1 SELECT * FROM sod_part_2023_q2;

  ALTER TABLE partlab.salesorderdetail ATTACH PARTITION sod_part_2023_h1
      FOR VALUES FROM ('2023-01-01') TO ('2023-07-01');

  DROP TABLE sod_part_2023_q1, sod_part_2023_q2;
COMMIT;

-- > **Oracle and SQL Server both have native `MERGE`/`SPLIT`.** This is a genuine gap — factor the manual effort into any migration estimate. (`SPLIT`/`MERGE PARTITION` arrived in PostgreSQL 17; confirm your Azure version before relying on it.)

---

-- Part VI — Locking

-- 13. How partition locking differs from table locking

-- **This is one of partitioning's strongest operational advantages**, and it is poorly understood.

-- 13.1 The core principle
-- DDL on one partition takes a lock on that partition only.** Queries touching *other* partitions are unaffected. On a monolithic table, the same DDL blocks everything.

-- 13.2 Lock levels by operation
-- 13.3 Demo — prove partition-scoped locking

--Session 1:

BEGIN;
LOCK TABLE partlab.sod_part_2024_q1 IN ACCESS EXCLUSIVE MODE;

SELECT pg_backend_pid() AS session_1_pid,
       l.relation::regclass AS locked_object,
       l.mode,
       l.granted
FROM pg_locks l
WHERE l.pid = pg_backend_pid()
  AND l.relation = 'partlab.sod_part_2024_q1'::regclass
  AND l.mode = 'AccessExclusiveLock';
-- Leave this transaction open. Run ROLLBACK after completing the demo.
-- 

-- The verification query must return one row with `mode = AccessExclusiveLock` and `granted = true`. If it returns no rows, do not continue—the lock is not being held.

> `VACUUM FULL` also takes `ACCESS EXCLUSIVE`, but it cannot run inside a transaction block and releases its lock when the statement finishes. `LOCK TABLE` is used here because it holds the same lock mode predictably until `COMMIT` or `ROLLBACK`.

-- Session 2 — runs normally, unblocked:**

SELECT pg_backend_pid() AS session_2_pid;  -- must differ from Session 1

SELECT count(*) FROM partlab.salesorderdetail
WHERE orderdate >= DATE '2024-04-01' AND orderdate < DATE '2024-07-01';
-- Completes immediately: pruning means it never touches sod_part_2024_q1


-- Session 3 — this one waits, then times out:**
SELECT pg_backend_pid() AS session_3_pid;  -- must differ from Sessions 1 and 2

SET lock_timeout = '30s';  -- prevents an accidental indefinite wait
SELECT count(*) FROM partlab.sod_part_2024_q1;
-- Waits, then reports SQLSTATE 55P03 if Session 1 still holds the lock.

-- While Session 3 is waiting, run the following in Session 2:
SELECT l.pid,
       l.locktype,
       l.relation::regclass AS locked_object,
       l.mode,
       l.granted,
       left(a.query, 60)    AS query
FROM pg_locks l
JOIN pg_stat_activity a USING (pid)
JOIN pg_class c ON c.oid = l.relation
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'partlab'
  AND (c.relname = 'salesorderdetail' OR c.relname LIKE 'sod_part_%')
ORDER BY l.granted, l.pid;


/* What to observe

 - `granted = false` rows are **waiting** — that is your blocked session.
 - **The `locked_object` column names the specific partition**, not the parent. That is the entire point: the blast radius of the lock is one partition.
 - On a monolithic table, the equivalent `ACCESS EXCLUSIVE` lock would have blocked **every** query in sessions 2 *and* 3.
 - If Session 3 completes immediately, compare the three backend PIDs and rerun the test with separate connections. Shared-connection tabs use the same PID and therefore cannot block each other.
*/

-- Cleanup — Session 1:**

ROLLBACK;

-- If Session 3 is still waiting, it completes when Session 1 releases the lock. If it already timed out, reset its session setting with `RESET lock_timeout;`.

-- 13.4 Finding blocking chains

SELECT blocked.pid            AS blocked_pid,
       blocked.relation::regclass AS blocked_on,
       blocked.mode           AS wants,
       blocking.pid           AS blocking_pid,
       blocking.mode          AS holds,
       left(ba.query, 80)     AS blocking_query,
       now() - ba.query_start AS blocking_duration
FROM pg_locks blocked
JOIN pg_locks blocking
  ON blocking.relation = blocked.relation
 AND blocking.granted AND NOT blocked.granted
 AND blocking.pid <> blocked.pid
JOIN pg_stat_activity ba ON ba.pid = blocking.pid
ORDER BY blocking_duration DESC;

-- 13.5 Lock traps specific to partitioning
1. **`ALTER TABLE` on the parent cascades.** Adding a column takes `ACCESS EXCLUSIVE` on the parent **and every partition** — with 200 partitions that is 201 exclusive locks acquired together. **Schedule it like a full-table DDL, because that is what it is.**
2. **`DETACH PARTITION` (non-concurrent) needs `ACCESS EXCLUSIVE` on the parent** — briefly blocking *all* queries against the table. **Use `DETACH ... CONCURRENTLY` on PG 14+.**
3. **Lock queues cascade.** One long query holding `ACCESS SHARE` on the parent delays a waiting `ACCESS EXCLUSIVE`, which in turn queues every subsequent query behind it. Always set a timeout for maintenance DDL:

   SET lock_timeout = '5s';
   ALTER TABLE partlab.salesorderdetail DETACH PARTITION sod_part_2024_q2;
   

4. **`max_locks_per_transaction`.** A query touching hundreds of partitions acquires hundreds of locks. Wide scans across many partitions can exhaust the lock table — the error is `out of shared memory` with a hint about this parameter. **Another reason not to over-partition.**

---

--- Health-check query pack

-- 1. Every partitioned table and its partition count
SELECT c.relname                        AS partitioned_table,
       count(i.inhrelid)                AS partitions,
       pg_size_pretty(sum(pg_total_relation_size(i.inhrelid))) AS total_size
FROM pg_class c
JOIN pg_inherits i ON i.inhparent = c.oid
WHERE c.relkind = 'p'
GROUP BY c.relname
ORDER BY sum(pg_total_relation_size(i.inhrelid)) DESC;

-- 2. Default partitions that have collected rows -- a future ATTACH failure
SELECT c.relname AS default_partition, c.reltuples::bigint AS est_rows
FROM pg_class c
JOIN pg_inherits i ON i.inhrelid = c.oid
WHERE pg_get_expr(c.relpartbound, c.oid) = 'DEFAULT'
  AND c.reltuples > 0;

-- 3. Skew -- are partitions wildly uneven?
SELECT i.inhparent::regclass AS parent,
       c.relname             AS partition,
       c.reltuples::bigint   AS est_rows,
       round(
           (
               100.0 * c.reltuples /
               NULLIF(sum(c.reltuples) OVER (PARTITION BY i.inhparent), 0)
           )::numeric,
           1
       ) AS pct_of_total
FROM pg_class c
JOIN pg_inherits i ON i.inhrelid = c.oid
WHERE c.relkind = 'r'
ORDER BY i.inhparent::regclass::text, c.reltuples DESC;

-- 4. Partitions missing an index the parent has
SELECT p.relname AS partition, pi.relname AS missing_index_from_parent
FROM pg_class parent
JOIN pg_inherits ti ON ti.inhparent = parent.oid
JOIN pg_class p ON p.oid = ti.inhrelid
JOIN pg_index parent_idx ON parent_idx.indrelid = parent.oid
JOIN pg_class pi ON pi.oid = parent_idx.indexrelid
WHERE parent.relkind = 'p'
  AND NOT EXISTS (
      SELECT 1 FROM pg_inherits ii
      JOIN pg_index ci ON ci.indexrelid = ii.inhrelid
      WHERE ii.inhparent = parent_idx.indexrelid AND ci.indrelid = p.oid);

DROP SCHEMA partlab CASCADE;

DO $$
DECLARE
    extension_schema name;
BEGIN
    SELECT n.nspname
    INTO extension_schema
    FROM pg_extension e
    JOIN pg_namespace n ON n.oid = e.extnamespace
    WHERE e.extname = 'pg_partman';

    IF extension_schema IS NOT NULL THEN
        EXECUTE format(
            'DELETE FROM %I.part_config WHERE parent_table = $1',
            extension_schema
        )
        USING 'partlab.sod_live';
    END IF;
END $$;

DROP SCHEMA IF EXISTS partlab CASCADE;
