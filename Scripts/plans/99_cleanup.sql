-- =====================================================================
-- 99_cleanup.sql   Removes EVERY object the plan demos created.
--
-- Safe and idempotent. Drops only objects named ix_demo_* / stx_demo_*,
-- and resets the statistics targets that script 07 changed.
--
-- It does NOT touch:
--   - any adventureworks table, row, or original index
--   - primary keys, foreign keys, unique constraints
--   - any server-level setting (every SET in the demos was session-scoped)
-- =====================================================================

-- \pset pager off

-- \echo ''
-- \echo '=== Objects that will be dropped ==='
SELECT schemaname || '.' || indexname AS index_name,
       pg_size_pretty(pg_relation_size((schemaname||'.'||indexname)::regclass)) AS size
FROM pg_indexes
WHERE indexname LIKE 'ix\_demo\_%'
ORDER BY 1;

SELECT statistics_schema || '.' || statistics_name AS extended_stats
FROM pg_stats_ext
WHERE statistics_name LIKE 'stx\_demo\_%';

-- \echo ''
-- \echo '=== Dropping demo indexes ==='

DO $cleanup$
DECLARE
    r record;
    n int := 0;
BEGIN
    FOR r IN
        SELECT schemaname, indexname
        FROM pg_indexes
        WHERE indexname LIKE 'ix\_demo\_%'
    LOOP
        EXECUTE format('DROP INDEX IF EXISTS %I.%I', r.schemaname, r.indexname);
        RAISE NOTICE 'dropped index %.%', r.schemaname, r.indexname;
        n := n + 1;
    END LOOP;
    RAISE NOTICE '% demo index(es) dropped', n;
END
$cleanup$;

-- \echo ''
-- \echo '=== Dropping demo extended statistics ==='

DO $cleanup$
DECLARE
    r record;
    n int := 0;
BEGIN
    FOR r IN
        SELECT statistics_schema AS sch, statistics_name AS nm
        FROM pg_stats_ext
        WHERE statistics_name LIKE 'stx\_demo\_%'
    LOOP
        EXECUTE format('DROP STATISTICS IF EXISTS %I.%I', r.sch, r.nm);
        RAISE NOTICE 'dropped statistics %.%', r.sch, r.nm;
        n := n + 1;
    END LOOP;
    RAISE NOTICE '% demo statistics object(s) dropped', n;
END
$cleanup$;

-- \echo ''
-- \echo '=== Resetting statistics targets changed by 07_row_estimates.sql ==='
-- \echo '    (-1 means "use default_statistics_target")'

ALTER TABLE sales.salesorderheader ALTER COLUMN orderdate  SET STATISTICS -1;
ALTER TABLE sales.salesorderheader ALTER COLUMN duedate    SET STATISTICS -1;
ALTER TABLE sales.salesorderheader ALTER COLUMN customerid SET STATISTICS -1;
ALTER TABLE sales.salesorderheader ALTER COLUMN totaldue   SET STATISTICS -1;

-- \echo ''
-- \echo '=== Refreshing statistics ==='
ANALYZE sales.salesorderheader;
ANALYZE sales.salesorderdetail;
ANALYZE sales.customer;
ANALYZE person.person;
ANALYZE production.product;

-- \echo ''
-- \echo '=== VERIFICATION - all three counts must be 0 ==='

SELECT 'demo indexes remaining' AS check_name, count(*) AS should_be_zero
FROM pg_indexes WHERE indexname LIKE 'ix\_demo\_%'
UNION ALL
SELECT 'demo statistics remaining', count(*)
FROM pg_stats_ext WHERE statistics_name LIKE 'stx\_demo\_%'
UNION ALL
SELECT 'non-default statistics targets', count(*)
FROM pg_attribute a
JOIN pg_class c ON c.oid = a.attrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname IN ('sales','person','production')
  AND a.attstattarget >= 0;

-- \echo ''
-- \echo '=== Indexes that remain (these are AdventureWorks originals) ==='
SELECT schemaname || '.' || tablename AS table_name, indexname
FROM pg_indexes
WHERE schemaname IN ('sales','person','production')
ORDER BY 1, 2
LIMIT 30;

-- \echo ''
-- \echo '>>> Cleanup complete. The database is back to its pre-demo state.'
-- \echo ''
-- \echo '>>> NOTE: every SET in the demo scripts (work_mem, enable_seqscan,'
-- \echo '>>> enable_hashjoin, max_parallel_workers_per_gather) was SESSION'
-- \echo '>>> scoped. Closing your psql session clears them. Nothing was'
-- \echo '>>> changed at the server level.'
-- \echo ''
