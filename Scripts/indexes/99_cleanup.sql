-- =====================================================================
-- 99_cleanup.sql    Removes EVERY object the index/statistics demos made.
--
-- Safe and idempotent. Drops only:
--   indexes         named ix_lab_*
--   statistics      named stx_lab_*
--   schema          idx_lab   (all demo tables live there)
-- and resets the per-column statistics targets and per-table autovacuum
-- options the demos changed.
--
-- It does NOT touch:
--   - any adventureworks table, row, or original index
--   - primary keys, foreign keys, unique constraints
--   - anything named ix_demo_* (that belongs to the execution-plan set;
--     run plans/99_cleanup.sql for those)
--   - any server-level setting
-- =====================================================================

-- \pset pager off

-- \echo ''
-- \echo '=== What will be removed ==='

SELECT schemaname || '.' || indexname AS index_name,
       pg_size_pretty(pg_relation_size((schemaname||'.'||indexname)::regclass)) AS size
FROM pg_indexes WHERE indexname LIKE 'ix\_lab\_%'
ORDER BY 1;

SELECT statistics_schema || '.' || statistics_name AS extended_stats
FROM pg_stats_ext WHERE statistics_name LIKE 'stx\_lab\_%';

SELECT 'idx_lab.' || tablename AS demo_table
FROM pg_tables WHERE schemaname = 'idx_lab';

-- \echo ''
-- \echo '=== Dropping demo indexes ==='

DO $cleanup$
DECLARE r record; n int := 0;
BEGIN
    FOR r IN SELECT schemaname, indexname FROM pg_indexes
             WHERE indexname LIKE 'ix\_lab\_%'
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
DECLARE r record; n int := 0;
BEGIN
    FOR r IN SELECT statistics_schema AS sch, statistics_name AS nm
             FROM pg_stats_ext WHERE statistics_name LIKE 'stx\_lab\_%'
    LOOP
        EXECUTE format('DROP STATISTICS IF EXISTS %I.%I', r.sch, r.nm);
        RAISE NOTICE 'dropped statistics %.%', r.sch, r.nm;
        n := n + 1;
    END LOOP;
    RAISE NOTICE '% demo statistics object(s) dropped', n;
END
$cleanup$;

-- \echo ''
-- \echo '=== Dropping the idx_lab sandbox schema ==='
DROP SCHEMA IF EXISTS idx_lab CASCADE;

-- \echo ''
-- \echo '=== Resetting per-column statistics targets (-1 = default) ==='

DO $cleanup$
DECLARE r record; n int := 0;
BEGIN
    FOR r IN
        SELECT n.nspname AS sch, c.relname AS tbl, a.attname AS col
        FROM pg_attribute a
        JOIN pg_class c     ON c.oid = a.attrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname IN ('sales','person','production','humanresources','purchasing')
          AND c.relkind = 'r'
          AND a.attnum > 0 AND NOT a.attisdropped
          AND a.attstattarget >= 0
    LOOP
        EXECUTE format('ALTER TABLE %I.%I ALTER COLUMN %I SET STATISTICS -1',
                       r.sch, r.tbl, r.col);
        RAISE NOTICE 'reset statistics target on %.%.%', r.sch, r.tbl, r.col;
        n := n + 1;
    END LOOP;
    RAISE NOTICE '% column target(s) reset to default', n;
END
$cleanup$;

-- \echo ''
-- \echo '=== Resetting per-table autovacuum overrides ==='

DO $cleanup$
DECLARE r record; n int := 0;
BEGIN
    FOR r IN
        SELECT n.nspname AS sch, c.relname AS tbl
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname IN ('sales','person','production')
          AND c.relkind = 'r'
          AND c.reloptions IS NOT NULL
    LOOP
        EXECUTE format('ALTER TABLE %I.%I RESET (
            autovacuum_analyze_scale_factor,
            autovacuum_analyze_threshold,
            autovacuum_vacuum_scale_factor)', r.sch, r.tbl);
        RAISE NOTICE 'reset autovacuum options on %.%', r.sch, r.tbl;
        n := n + 1;
    END LOOP;
    RAISE NOTICE '% table option set(s) reset', n;
END
$cleanup$;

-- \echo ''
-- \echo '=== Refreshing statistics ==='
ANALYZE sales.salesorderheader;
ANALYZE sales.salesorderdetail;
ANALYZE sales.customer;
ANALYZE person.person;
ANALYZE production.product;

-- \echo ''
-- \echo '=== VERIFICATION - every count must be 0 ==='

SELECT 'ix_lab_* indexes remaining' AS check_name, count(*) AS should_be_zero
FROM pg_indexes WHERE indexname LIKE 'ix\_lab\_%'
UNION ALL
SELECT 'stx_lab_* statistics remaining', count(*)
FROM pg_stats_ext WHERE statistics_name LIKE 'stx\_lab\_%'
UNION ALL
SELECT 'idx_lab schema remaining', count(*)
FROM pg_namespace WHERE nspname = 'idx_lab'
UNION ALL
SELECT 'non-default statistics targets', count(*)
FROM pg_attribute a
JOIN pg_class c ON c.oid = a.attrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname IN ('sales','person','production')
  AND a.attstattarget >= 0
UNION ALL
SELECT 'invalid indexes (should always be 0)', count(*)
FROM pg_index WHERE NOT indisvalid;

-- \echo ''
-- \echo '=== Indexes that remain (AdventureWorks originals) ==='
SELECT schemaname || '.' || tablename AS table_name, indexname
FROM pg_indexes
WHERE schemaname IN ('sales','person','production')
ORDER BY 1, 2 LIMIT 30;

-- \echo ''
-- \echo '>>> Cleanup complete. The database is back to its pre-demo state.'
-- \echo ''
-- \echo '>>> Extensions are NOT dropped - pg_trgm / pgstattuple, if created,'
-- \echo '>>> are left in place because they are harmless and other demos may'
-- \echo '>>> use them. To remove: DROP EXTENSION pg_trgm;'
-- \echo ''
-- \echo '>>> Every SET in the demo scripts was SESSION scoped. Closing psql'
-- \echo '>>> clears them. Nothing was changed at the server level.'
-- \echo ''
