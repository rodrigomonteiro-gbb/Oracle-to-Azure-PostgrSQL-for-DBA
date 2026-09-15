-- =====================================================================
-- 04_maintenance_and_bloat.sql
--
-- The operational half: what indexes COST to maintain, how they bloat,
-- how to rebuild them without an outage, and the PostgreSQL-specific
-- concepts (HOT updates, fillfactor, visibility map) that have no
-- Oracle equivalent.
--
-- All writes are inside BEGIN/ROLLBACK or confined to schema idx_lab.
-- AdventureWorks data is never permanently modified.
-- =====================================================================

-- \pset pager off
-- \timing on

CREATE SCHEMA IF NOT EXISTS idx_lab;

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART A - WRITE AMPLIFICATION, measured in WAL                 #'
-- \echo '################################################################'
-- \echo '  "Add an index, queries get faster" is the easy half. Here is'
-- \echo '  the bill.'
-- \echo ''

DROP INDEX IF EXISTS sales.ix_lab_wa_1;
DROP INDEX IF EXISTS sales.ix_lab_wa_2;
DROP INDEX IF EXISTS sales.ix_lab_wa_3;
DROP INDEX IF EXISTS sales.ix_lab_wa_4;

-- \echo '  -- A1. BASELINE: UPDATE with no extra indexes (rolled back)'
BEGIN;
EXPLAIN (ANALYZE, BUFFERS, WAL)
UPDATE sales.salesorderheader SET totaldue = totaldue
WHERE salesorderid BETWEEN 43659 AND 45659;
ROLLBACK;

-- \echo ''
-- \echo '      Record: WAL records = ____   WAL bytes = ____   dirtied = ____'
-- \echo ''

-- \echo '  -- A2. Add FOUR indexes that all cover the updated column:'
CREATE INDEX ix_lab_wa_1 ON sales.salesorderheader (totaldue);
CREATE INDEX ix_lab_wa_2 ON sales.salesorderheader (totaldue, orderdate);
CREATE INDEX ix_lab_wa_3 ON sales.salesorderheader (totaldue, customerid);
CREATE INDEX ix_lab_wa_4 ON sales.salesorderheader (customerid, totaldue, status);
ANALYZE sales.salesorderheader;

-- \echo '  -- A3. IDENTICAL update, identical rows:'
BEGIN;
EXPLAIN (ANALYZE, BUFFERS, WAL)
UPDATE sales.salesorderheader SET totaldue = totaldue
WHERE salesorderid BETWEEN 43659 AND 45659;
ROLLBACK;

-- \echo ''
-- \echo '  >>> COMPARE WAL bytes, WAL records, and shared dirtied.'
-- \echo ''
-- \echo '      Every index on an updated column must ALSO be updated, and'
-- \echo '      every one of those updates is WAL-logged, replicated to your'
-- \echo '      standby, and shipped to backup.'
-- \echo ''
-- \echo '      Say: "An index is a permanent tax on every write, paid to'
-- \echo '       make certain reads faster. Worth it when you collect.'
-- \echo '       Pure loss when the index is never used - which is why the'
-- \echo '       unused-index audit matters more than the next new index."'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART B - HOT UPDATES: the PostgreSQL-only optimisation         #'
-- \echo '################################################################'
-- \echo '  Heap-Only Tuple update: if NO indexed column changed AND the'
-- \echo '  page has free space, PostgreSQL writes the new row version on'
-- \echo '  the SAME page and skips index maintenance entirely.'
-- \echo ''
-- \echo '  More indexes = fewer HOT updates = more write amplification.'
-- \echo '  No Oracle equivalent - Oracle updates in place.'
-- \echo ''

DROP TABLE IF EXISTS idx_lab.hot_demo;
CREATE TABLE idx_lab.hot_demo (
  id         bigserial PRIMARY KEY,
  indexed_col   int,
  unindexed_col int,
  payload    text
) WITH (fillfactor = 70);           -- leave 30% free for HOT updates

INSERT INTO idx_lab.hot_demo (indexed_col, unindexed_col, payload)
SELECT i, i, repeat('x', 100) FROM generate_series(1, 50000) i;

CREATE INDEX ix_lab_hot_indexed ON idx_lab.hot_demo (indexed_col);
VACUUM (ANALYZE) idx_lab.hot_demo;

-- \echo '  -- B1. Update an UNINDEXED column -> should be HOT'
SELECT n_tup_upd AS updates_before, n_tup_hot_upd AS hot_before
FROM pg_stat_user_tables WHERE relname = 'hot_demo';

UPDATE idx_lab.hot_demo SET unindexed_col = unindexed_col + 1
WHERE id <= 10000;

SELECT pg_sleep(1);
SELECT n_tup_upd AS updates_after, n_tup_hot_upd AS hot_after,
       round(100.0 * n_tup_hot_upd / NULLIF(n_tup_upd,0), 1) AS hot_pct
FROM pg_stat_user_tables WHERE relname = 'hot_demo';

-- \echo ''
-- \echo '  -- B2. Update an INDEXED column -> CANNOT be HOT'
UPDATE idx_lab.hot_demo SET indexed_col = indexed_col + 1
WHERE id <= 10000;

SELECT pg_sleep(1);
SELECT n_tup_upd AS updates_total, n_tup_hot_upd AS hot_total,
       round(100.0 * n_tup_hot_upd / NULLIF(n_tup_upd,0), 1) AS hot_pct
FROM pg_stat_user_tables WHERE relname = 'hot_demo';

-- \echo ''
-- \echo '  >>> hot_pct should DROP after B2. Each non-HOT update touches'
-- \echo '      every index on the table.'
-- \echo ''
-- \echo '      PRACTICAL ADVICE THAT SAVES REAL MONEY:'
-- \echo '        - do not index columns that are updated frequently'
-- \echo '        - lower fillfactor (70-90) on hot-update tables to leave'
-- \echo '          room on the page for HOT updates'
-- \echo '        - monitor n_tup_hot_upd / n_tup_upd - a falling ratio is'
-- \echo '          an early warning of over-indexing'
-- \echo ''

SELECT relname,
       n_tup_upd, n_tup_hot_upd,
       round(100.0 * n_tup_hot_upd / NULLIF(n_tup_upd,0),1) AS hot_pct
FROM pg_stat_user_tables
WHERE schemaname IN ('sales','person','production','idx_lab')
  AND n_tup_upd > 0
ORDER BY n_tup_upd DESC LIMIT 10;

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART C - INDEX BLOAT                                          #'
-- \echo '################################################################'
-- \echo '  PostgreSQL never updates in place: an UPDATE writes a new row'
-- \echo '  version and leaves the old one dead. Indexes accumulate entries'
-- \echo '  pointing at dead tuples until VACUUM cleans them up - and even'
-- \echo '  then the pages are reused, not returned to the OS.'
-- \echo ''

DROP TABLE IF EXISTS idx_lab.bloat_demo;
CREATE TABLE idx_lab.bloat_demo (id bigserial PRIMARY KEY, val int, payload text);
INSERT INTO idx_lab.bloat_demo (val, payload)
SELECT i, repeat('y', 200) FROM generate_series(1, 100000) i;
CREATE INDEX ix_lab_bloat_val ON idx_lab.bloat_demo (val);
VACUUM (ANALYZE) idx_lab.bloat_demo;

-- \echo '  -- C1. Clean index size:'
SELECT 'after initial load' AS state,
       pg_size_pretty(pg_relation_size('idx_lab.ix_lab_bloat_val')) AS index_size,
       pg_size_pretty(pg_relation_size('idx_lab.bloat_demo'))       AS heap_size;

-- \echo ''
-- \echo '  -- C2. Churn the indexed column repeatedly:'
UPDATE idx_lab.bloat_demo SET val = val + 100000;
UPDATE idx_lab.bloat_demo SET val = val + 100000;
UPDATE idx_lab.bloat_demo SET val = val + 100000;

SELECT 'after 3 full-table updates' AS state,
       pg_size_pretty(pg_relation_size('idx_lab.ix_lab_bloat_val')) AS index_size,
       pg_size_pretty(pg_relation_size('idx_lab.bloat_demo'))       AS heap_size;

-- \echo ''
-- \echo '  -- C3. VACUUM removes dead entries but does NOT shrink the file:'
VACUUM (ANALYZE) idx_lab.bloat_demo;
SELECT 'after VACUUM' AS state,
       pg_size_pretty(pg_relation_size('idx_lab.ix_lab_bloat_val')) AS index_size;

-- \echo ''
-- \echo '      VACUUM makes the space REUSABLE. It does not give it back'
-- \echo '      to the filesystem. That is the distinction people miss.'
-- \echo ''

-- \echo '  -- C4. REINDEX actually rebuilds and shrinks it:'
REINDEX INDEX idx_lab.ix_lab_bloat_val;
SELECT 'after REINDEX' AS state,
       pg_size_pretty(pg_relation_size('idx_lab.ix_lab_bloat_val')) AS index_size;

-- \echo ''
-- \echo '  >>> IN PRODUCTION, ALWAYS USE CONCURRENTLY:'
-- \echo '        REINDEX INDEX CONCURRENTLY idx_lab.ix_lab_bloat_val;'
-- \echo '        REINDEX TABLE CONCURRENTLY idx_lab.bloat_demo;'
-- \echo ''
-- \echo '      Plain REINDEX takes an ACCESS EXCLUSIVE lock - it blocks'
-- \echo '      reads AND writes for the whole rebuild. CONCURRENTLY is'
-- \echo '      slower and uses more space, but does not block. On a'
-- \echo '      customer production system there is no debate.'
-- \echo ''

-- \echo '  -- Measuring bloat properly (needs pgstattuple):'
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name='pgstattuple') THEN
    CREATE EXTENSION IF NOT EXISTS pgstattuple;
    RAISE NOTICE 'pgstattuple ready - run: SELECT * FROM pgstatindex(''idx_lab.ix_lab_bloat_val'');';
  ELSE
    RAISE NOTICE 'pgstattuple not available - add PGSTATTUPLE to azure.extensions';
  END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'pgstattuple unavailable: %', SQLERRM;
END $$;

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART D - CREATE INDEX CONCURRENTLY, and INVALID indexes       #'
-- \echo '################################################################'
-- \echo '  Plain CREATE INDEX blocks WRITES for the whole build. On a big'
-- \echo '  production table that is an outage.'
-- \echo ''
-- \echo '    CREATE INDEX CONCURRENTLY ix_name ON tbl (col);'
-- \echo ''
-- \echo '  Trade-offs you must state:'
-- \echo '    - two table passes, so roughly 2-3x slower'
-- \echo '    - CANNOT run inside a transaction block'
-- \echo '    - if it FAILS it leaves an INVALID index behind, which still'
-- \echo '      costs writes but is never used for reads'
-- \echo ''
-- \echo '  -- Find invalid indexes (run this after any failed build):'

SELECT i.indexrelid::regclass AS invalid_index,
       i.indrelid::regclass   AS on_table,
       pg_size_pretty(pg_relation_size(i.indexrelid)) AS wasted
FROM pg_index i
WHERE NOT i.indisvalid;

-- \echo ''
-- \echo '      Empty = healthy. Any row here should be DROPped and rebuilt.'
-- \echo '      This check belongs in your customer''s runbook.'
-- \echo ''
-- \echo '  -- Build speed lever - maintenance_work_mem (session scoped):'
SHOW maintenance_work_mem;
SHOW max_parallel_maintenance_workers;
-- \echo ''
-- \echo '      SET maintenance_work_mem = ''1GB'';   -- before a big build'
-- \echo '      SET max_parallel_maintenance_workers = 4;'
-- \echo '      Both are session-level, so you can raise them for a'
-- \echo '      maintenance window without touching the server config.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART E - Watch an index build live                            #'
-- \echo '################################################################'
-- \echo '  PG12+ exposes progress. Run this from a SECOND session while a'
-- \echo '  large CREATE INDEX is running - excellent on a split screen.'
-- \echo ''
-- \echo '    SELECT pid, command, phase,'
-- \echo '           blocks_done, blocks_total,'
-- \echo '           round(100.0*blocks_done/NULLIF(blocks_total,0),1) AS pct'
-- \echo '    FROM pg_stat_progress_create_index;'
-- \echo ''
-- \echo '  Same family of views for VACUUM and ANALYZE:'
-- \echo '    pg_stat_progress_vacuum'
-- \echo '    pg_stat_progress_analyze'
-- \echo '    pg_stat_progress_cluster'
-- \echo ''

SELECT * FROM pg_stat_progress_create_index;

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART F - The maintenance checklist to leave behind            #'
-- \echo '################################################################'

SELECT 1 AS step, 'Find never-used indexes'  AS task,
       'pg_stat_user_indexes WHERE idx_scan = 0'      AS how,
       'check stats_reset age first'                  AS caveat
UNION ALL SELECT 2, 'Find redundant indexes',
       'leading-column overlap query in 00_index_inventory.sql',
       'an index on (a) is covered by one on (a,b)'
UNION ALL SELECT 3, 'Find invalid indexes',
       'pg_index WHERE NOT indisvalid',
       'left behind by a failed CONCURRENTLY build'
UNION ALL SELECT 4, 'Watch HOT update ratio',
       'n_tup_hot_upd / n_tup_upd',
       'falling ratio = over-indexing'
UNION ALL SELECT 5, 'Rebuild bloated indexes',
       'REINDEX INDEX CONCURRENTLY',
       'never plain REINDEX in production'
UNION ALL SELECT 6, 'Keep autovacuum healthy',
       'last_autovacuum / last_autoanalyze in pg_stat_user_tables',
       'VACUUM is what keeps Index Only Scans index-only'
ORDER BY 1;

-- \echo ''
-- \echo '>>> NEXT: 05_antipatterns.sql'
-- \echo ''
