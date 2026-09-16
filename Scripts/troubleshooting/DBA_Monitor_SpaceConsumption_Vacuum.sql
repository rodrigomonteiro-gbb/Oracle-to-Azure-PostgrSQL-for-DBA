-- 1A verify azure setup

SHOW server_version;
SHOW azure.extensions;

-- 1B install extension on current database
CREATE EXTENSION IF NOT EXISTS pg_repack;

-- 1C verify:
SELECT extname, extversion
FROM pg_extension
WHERE extname = 'pg_repack';


-- 2A -- create demo table
DROP TABLE IF EXISTS sales.salesorderdetail_bloat_demo;

CREATE TABLE sales.salesorderdetail_bloat_demo AS
SELECT *
FROM sales.salesorderdetail
WHERE FALSE;

-- 2B create a new column to be used for pg_repack
ALTER TABLE sales.salesorderdetail_bloat_demo
ADD COLUMN demo_id BIGSERIAL PRIMARY KEY;

--3A enlarge the table
INSERT INTO sales.salesorderdetail_bloat_demo
SELECT sod.*
FROM sales.salesorderdetail sod
CROSS JOIN generate_series(1, 100);

-- 3B analyze the table
ANALYZE sales.salesorderdetail_bloat_demo;

--4A baseline
SELECT
    pg_size_pretty(
        pg_relation_size('sales.salesorderdetail_bloat_demo')
    ) AS table_size,

    pg_size_pretty(
        pg_indexes_size('sales.salesorderdetail_bloat_demo')
    ) AS indexes_size,

    pg_size_pretty(
        pg_total_relation_size('sales.salesorderdetail_bloat_demo')
    ) AS total_size;

-- 4B tuple statistics
SELECT
    relname,
    n_live_tup,
    n_dead_tup,
    last_vacuum,
    last_autovacuum
FROM pg_stat_user_tables
WHERE relname = 'salesorderdetail_bloat_demo';    


--5A generate serious table bloat
UPDATE sales.salesorderdetail_bloat_demo
SET orderqty = orderqty + 1;

UPDATE sales.salesorderdetail_bloat_demo
SET orderqty = orderqty + 1;

UPDATE sales.salesorderdetail_bloat_demo
SET orderqty = orderqty + 1;

-- 5B checK
SELECT
    relname,
    n_live_tup,
    n_dead_tup
FROM pg_stat_user_tables
WHERE relname = 'salesorderdetail_bloat_demo';

-- 6A change it further:
DELETE FROM sales.salesorderdetail_bloat_demo
WHERE demo_id % 3 <> 0;

-- 6B ANALYZE
ANALYZE sales.salesorderdetail_bloat_demo;

-- 6C tuple statistics after deletion
SELECT
    relname,
    n_live_tup,
    n_dead_tup,
    last_vacuum,
    last_autovacuum
FROM pg_stat_user_tables
WHERE relname = 'salesorderdetail_bloat_demo';

SELECT
    pg_size_pretty(
        pg_relation_size('sales.salesorderdetail_bloat_demo')
    ) AS table_size,

    pg_size_pretty(
        pg_indexes_size('sales.salesorderdetail_bloat_demo')
    ) AS indexes_size,

    pg_size_pretty(
        pg_total_relation_size('sales.salesorderdetail_bloat_demo')
    ) AS total_size;

-- 7A run VACUUM normal
VACUUM (VERBOSE, ANALYZE)
sales.salesorderdetail_bloat_demo;

/*
    visibility map: 0 pages set all-visible, 0 pages set all-frozen (0 were all-visible)
    index scan not needed: 0 pages from table (100.00% of total) had 0 dead item identifiers removed
    I/O timings: read: 0.347 ms, write: 0.000 ms
    avg read rate: 17.246 MB/s, avg write rate: 0.000 MB/s
    buffer usage: 10 hits, 1 reads, 0 dirtied
    WAL usage: 1 records, 0 full page images, 258 bytes, 0 buffers full
    system usage: CPU: user: 0.00 s, system: 0.00 s, elapsed: 0.00 s
    INFO: analyzing "sales.salesorderdetail_bloat_demo"
    INFO: "salesorderdetail_bloat_demo": scanned 30000 of 669960 pages, containing 181100 live rows and 1992183 dead rows; 30000 rows in sample, 4044325 estimated total rows
    INFO: finished analyzing table "adventureworks.sales.salesorderdetail_bloat_demo"
    I/O timings: read: 74.811 ms, write: 0.029 ms
    avg read rate: 221.544 MB/s, avg write rate: 0.049 MB/s
    buffer usage: 21242 hits, 8961 reads, 2 dirtied
    WAL usage: 36 records, 2 full page images, 22526 bytes, 0 buffers full
    system usage: CPU: user: 0.22 s, system: 0.01 s, elapsed: 0.31 s
    VACUUM
    Total execution time: 00:00:05.442
*/

SELECT
    pg_size_pretty(
        pg_relation_size('sales.salesorderdetail_bloat_demo')
    ) AS table_size,

    pg_size_pretty(
        pg_indexes_size('sales.salesorderdetail_bloat_demo')
    ) AS indexes_size,

    pg_size_pretty(
        pg_total_relation_size('sales.salesorderdetail_bloat_demo')
    ) AS total_size;

-- Talking point
-- This is the distinction I'd emphasize:
-- VACUUM reclaimed the dead tuples so PostgreSQL can reuse that space, but that does not mean the operating-system-level 
--      files become correspondingly smaller.
-- Microsoft specifically describes regular VACUUM as reclaiming space within the database files for PostgreSQL reuse 
--      rather than necessarily reducing the physical database files. Operations that rewrite the table, including 
--      VACUUM FULL and pg_repack, are options for returning that space.


-- 8 optional VACUUM FULL as alternative
VACUUM FULL sales.salesorderdetail_bloat_demo;

/*
    Why?

    Because the more interesting Azure production conversation is pg_repack.
    Microsoft documents that pg_repack creates a new version of the object, builds the indexes, captures changes occurring 
        during the operation, applies them, and ultimately swaps the old and new versions. Exclusive locking is required 
        briefly during setup and again during the final swap.

    That gives you a much better transition:
    "What if this is a production table and we don't want the extended locking implications of VACUUM FULL?"

*/


-- 9 pg_repack
pg_repack --version

pg_repack 
  --host=YOURSERVER.postgres.database.azure.com \
  --port=5432 \
  --username=YOURUSER \
  --dbname=AdventureWorks \
  --table=sales.salesorderdetail_bloat_demo

-- 10 measure results
SELECT
    pg_size_pretty(
        pg_relation_size('sales.salesorderdetail_bloat_demo')
    ) AS table_size,

    pg_size_pretty(
        pg_indexes_size('sales.salesorderdetail_bloat_demo')
    ) AS indexes_size,

    pg_size_pretty(
        pg_total_relation_size('sales.salesorderdetail_bloat_demo')
    ) AS total_size;

SELECT
    relname,
    n_live_tup,
    n_dead_tup,
    last_vacuum,
    last_autovacuum
FROM pg_stat_user_tables
WHERE relname = 'salesorderdetail_bloat_demo';

-- 11 reusable query
SELECT
    c.relname                                                AS table_name,
    s.n_live_tup,
    s.n_dead_tup,
    pg_size_pretty(pg_relation_size(c.oid))                 AS table_size,
    pg_size_pretty(pg_indexes_size(c.oid))                  AS index_size,
    pg_size_pretty(pg_total_relation_size(c.oid))           AS total_size
FROM pg_class c
JOIN pg_namespace n
    ON n.oid = c.relnamespace
LEFT JOIN pg_stat_user_tables s
    ON s.relid = c.oid
WHERE n.nspname = 'sales'
  AND c.relname = 'salesorderdetail_bloat_demo';

/*
Demo narrative

Stage	        Dead tuples	Physical size	    Point
-----           ----------- -------------       -------------
Initial load	Low	        Baseline	        Healthy table
UPDATE/DELETE	High	    Large	            Bloat created
VACUUM	        Low	        Often still large	Space becomes reusable
pg_repack	    Low	        Reduced	            Relation physically rewritten

The actual values will depend on your AdventureWorks dataset and the operations performed, so I would not hard-code expected MB/GB savings into workshop material.
*/

-- 12 clean-up
DROP TABLE IF EXISTS sales.salesorderdetail_bloat_demo;

DROP EXTENSION pg_repack;

/* enhanced demo */
/*
enhancement I'd strongly recommend for your workshop

Given the PostgreSQL monitoring/blocking demos you've already been building, I'd turn this into a two-session concurrency demo:

Session 1: repeatedly query or modify salesorderdetail_bloat_demo.

Session 2: run pg_repack.

Then demonstrate that the workload can continue through most of the repack process, while explaining the brief exclusive-lock phases at startup and final swap documented by Microsoft.

That makes the comparison with VACUUM FULL much more compelling than simply showing disk-size numbers.
*/