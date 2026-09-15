-- =====================================================================
-- 00_discovery.sql   READ-ONLY. Run this FIRST, once.
--
-- AdventureWorks ports to PostgreSQL differ. Some create only primary and
-- foreign keys; others also create the secondary indexes from the SQL Server
-- original. Which one you have decides which demos land.
--
-- This script tells you:
--   1. which schemas/tables exist and how big they are
--   2. which indexes ALREADY exist (a column that is already indexed will
--      not give you a "no index -> index" before/after)
--   3. whether statistics are present
--   4. your memory settings, which decide Hash vs Merge vs external sort
--
-- Oracle equivalent: USER_TABLES / USER_INDEXES / USER_TAB_STATISTICS
-- =====================================================================

-- \pset pager off
-- \timing on

-- \echo ''
-- \echo '=== 1. Schemas ==='
SELECT nspname AS schema
FROM pg_namespace
WHERE nspname NOT IN ('pg_catalog','information_schema','pg_toast')
  AND nspname NOT LIKE 'pg_temp%'
ORDER BY 1;

-- \echo ''
-- \echo '=== 2. Largest tables - your demo targets live here ==='
SELECT schemaname || '.' || relname                      AS table_name,
       n_live_tup                                        AS approx_rows,
       pg_size_pretty(pg_relation_size(relid))           AS heap_size,
       pg_size_pretty(pg_indexes_size(relid))            AS index_size,
       pg_size_pretty(pg_total_relation_size(relid))     AS total_size
FROM pg_stat_user_tables
ORDER BY pg_total_relation_size(relid) DESC
LIMIT 20;

-- \echo ''
-- \echo '=== 3. Existing indexes on the tables these demos use ==='
-- \echo '    If a column below is ALREADY indexed, the matching demo will show'
-- \echo '    an Index Scan from the start. Use the ALTERNATE query noted in that'
-- \echo '    script, or drop nothing - just narrate it as "already tuned".'
SELECT schemaname || '.' || tablename AS table_name,
       indexname,
       indexdef
FROM pg_indexes
WHERE (schemaname, tablename) IN (
        ('sales','salesorderheader'), ('sales','salesorderdetail'),
        ('sales','customer'),         ('person','person'),
        ('person','address'),         ('production','product'),
        ('production','transactionhistory'))
ORDER BY 1, 2;

-- \echo ''
-- \echo '=== 4. Statistics freshness - stale stats = wrong row estimates ==='
SELECT schemaname || '.' || relname AS table_name,
       n_live_tup, n_dead_tup,
       last_analyze, last_autoanalyze
FROM pg_stat_user_tables
WHERE schemaname IN ('sales','person','production','humanresources','purchasing')
ORDER BY n_live_tup DESC
LIMIT 15;

-- \echo ''
-- \echo '=== 5. Settings that decide which operators the planner picks ==='
SELECT name, setting, unit, short_desc
FROM pg_settings
WHERE name IN ('work_mem','shared_buffers','effective_cache_size',
               'random_page_cost','seq_page_cost','cpu_tuple_cost',
               'max_parallel_workers_per_gather','jit',
               'default_statistics_target','enable_seqscan')
ORDER BY name;

-- \echo ''
-- \echo '=== 6. Row counts for the demo tables ==='
-- \echo '    Under ~50k rows the planner may prefer a Seq Scan even WITH an index.'
-- \echo '    That is correct behaviour - and itself a good teaching moment.'
SELECT 'sales.salesorderheader' AS t, count(*) FROM sales.salesorderheader
UNION ALL SELECT 'sales.salesorderdetail', count(*) FROM sales.salesorderdetail
UNION ALL SELECT 'person.person',          count(*) FROM person.person
UNION ALL SELECT 'person.address',         count(*) FROM person.address
UNION ALL SELECT 'production.product',     count(*) FROM production.product
ORDER BY 1;

-- \echo ''
-- \echo '>>> If any table above errored, your port uses different names.'
-- \echo '>>> Re-run section 2 and adjust the demo scripts to match.'
-- \echo ''
-- \echo '>>> Before demoing, make estimates trustworthy:'
-- \echo '>>>   ANALYZE sales.salesorderheader;'
-- \echo '>>>   ANALYZE sales.salesorderdetail;'
-- \echo '>>>   ANALYZE person.person;'
-- \echo ''
