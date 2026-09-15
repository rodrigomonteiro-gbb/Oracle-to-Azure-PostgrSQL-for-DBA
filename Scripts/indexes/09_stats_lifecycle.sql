-- =====================================================================
-- 09_stats_lifecycle.sql    When statistics go stale, and who fixes them
--
-- The operational half of statistics: autovacuum/autoanalyze thresholds,
-- the bulk-load trap, per-table tuning, and how to monitor staleness.
--
-- Oracle mapping:
--   automatic stats gathering job  -> autoanalyze (part of autovacuum)
--   STALE_PERCENT (10%)            -> autovacuum_analyze_scale_factor (0.1)
--   DBMS_STATS.LOCK_TABLE_STATS    -> (no equivalent - see PART F)
--
-- Writes are confined to schema idx_lab.
-- =====================================================================

-- \pset pager off
-- \timing on

CREATE SCHEMA IF NOT EXISTS idx_lab;

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART A - The autoanalyze formula                              #'
-- \echo '################################################################'

SELECT name, setting, boot_val AS default_value
FROM pg_settings
WHERE name IN ('autovacuum','autovacuum_naptime',
               'autovacuum_analyze_threshold','autovacuum_analyze_scale_factor',
               'autovacuum_vacuum_threshold','autovacuum_vacuum_scale_factor',
               'autovacuum_vacuum_insert_threshold',
               'autovacuum_max_workers')
ORDER BY name;

-- \echo ''
-- \echo '   AUTOANALYZE FIRES WHEN:'
-- \echo ''
-- \echo '     rows_changed > analyze_threshold + (scale_factor x total_rows)'
-- \echo '                  = 50 + (0.10 x total_rows)'
-- \echo ''
-- \echo '   *** THE SCALING TRAP - this is the part that matters. ***'
-- \echo '   10% is a PERCENTAGE, so the bigger the table, the longer it'
-- \echo '   waits:'
-- \echo '        10,000 rows    ->  analyze after ~1,050 changes'
-- \echo '     1,000,000 rows    ->  analyze after ~100,050 changes'
-- \echo '   100,000,000 rows    ->  analyze after ~10,000,050 changes'
-- \echo ''
-- \echo '   On your LARGEST, most important tables, statistics go stale'
-- \echo '   for the LONGEST. Exactly backwards from what you want.'
-- \echo ''

-- \echo '  -- Where does each table stand right now?'
SELECT schemaname || '.' || relname                AS table_name,
       n_live_tup                                  AS live_rows,
       n_mod_since_analyze                         AS changed_since_analyze,
       (50 + 0.1 * n_live_tup)::bigint             AS autoanalyze_threshold,
       CASE WHEN n_mod_since_analyze > 50 + 0.1 * n_live_tup
            THEN 'DUE' ELSE 'ok' END               AS status,
       last_analyze, last_autoanalyze
FROM pg_stat_user_tables
WHERE schemaname IN ('sales','person','production','idx_lab')
ORDER BY n_mod_since_analyze DESC
LIMIT 15;

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART B - THE BULK LOAD TRAP                                   #'
-- \echo '################################################################'
-- \echo '  The most common statistics failure in the real world, and the'
-- \echo '  one every migration hits on day one.'
-- \echo ''

DROP TABLE IF EXISTS idx_lab.stats_demo;
CREATE TABLE idx_lab.stats_demo (
  id     bigserial PRIMARY KEY,
  grp    int,
  amount numeric(12,2),
  ts     timestamptz
);

-- \echo '  -- B1. Load 200,000 rows, then query IMMEDIATELY - no ANALYZE:'
INSERT INTO idx_lab.stats_demo (grp, amount, ts)
SELECT (random()*100)::int, (random()*1000)::numeric(12,2),
       now() - (random()*365) * interval '1 day'
FROM generate_series(1, 200000);

SELECT c.reltuples::bigint AS planner_thinks_rows,
       (SELECT count(*) FROM idx_lab.stats_demo) AS actual_rows,
       c.relpages AS planner_thinks_pages
FROM pg_class c WHERE c.oid = 'idx_lab.stats_demo'::regclass;

-- \echo ''
-- \echo '  >>> reltuples is often -1 or 0 on a freshly created table.'
-- \echo '      The planner literally does not know the table has data.'
-- \echo ''

EXPLAIN (ANALYZE)
SELECT grp, count(*), sum(amount) FROM idx_lab.stats_demo
WHERE grp BETWEEN 10 AND 20 GROUP BY grp;

-- \echo ''
-- \echo '      Look at rows= versus actual rows=. Enormous gap.'
-- \echo ''

-- \echo '  -- B2. One ANALYZE:'
ANALYZE idx_lab.stats_demo;

SELECT c.reltuples::bigint AS planner_thinks_rows,
       (SELECT count(*) FROM idx_lab.stats_demo) AS actual_rows
FROM pg_class c WHERE c.oid = 'idx_lab.stats_demo'::regclass;

EXPLAIN (ANALYZE)
SELECT grp, count(*), sum(amount) FROM idx_lab.stats_demo
WHERE grp BETWEEN 10 AND 20 GROUP BY grp;

-- \echo ''
-- \echo '  >>> *** THE RULE TO PUT ON A SLIDE: ***'
-- \echo ''
-- \echo '      ALWAYS RUN ANALYZE AFTER A BULK LOAD, A RESTORE, OR A'
-- \echo '      MIGRATION CUTOVER. DO NOT WAIT FOR AUTOVACUUM.'
-- \echo ''
-- \echo '      pg_restore does NOT gather statistics. Neither does COPY,'
-- \echo '      nor most migration tools. Autoanalyze will get there'
-- \echo '      eventually - possibly hours later, after your go-live'
-- \echo '      window, after the first angry phone call.'
-- \echo ''
-- \echo '      "vacuumdb --analyze-only --jobs=8 --all" belongs in every'
-- \echo '      migration runbook, immediately after the data load.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART C - Watching statistics drift out of date                #'
-- \echo '################################################################'

-- \echo '  -- C1. Change the data distribution completely:'
UPDATE idx_lab.stats_demo SET grp = 999 WHERE id <= 100000;

SELECT n_mod_since_analyze AS changes_since_analyze,
       n_live_tup          AS live_rows,
       (50 + 0.1*n_live_tup)::bigint AS threshold,
       CASE WHEN n_mod_since_analyze > 50 + 0.1*n_live_tup
            THEN 'autoanalyze IS DUE' ELSE 'below threshold' END AS status
FROM pg_stat_user_tables WHERE relname='stats_demo';

-- \echo ''
-- \echo '  -- C2. Query on the NEW distribution using the OLD statistics:'
EXPLAIN (ANALYZE)
SELECT count(*) FROM idx_lab.stats_demo WHERE grp = 999;

-- \echo ''
-- \echo '      Half the table is now grp=999, but the statistics still'
-- \echo '      describe a world where grp was uniform 0-100. The estimate'
-- \echo '      is catastrophically low.'
-- \echo ''

-- \echo '  -- C3. Refresh:'
ANALYZE idx_lab.stats_demo;
EXPLAIN (ANALYZE)
SELECT count(*) FROM idx_lab.stats_demo WHERE grp = 999;

-- \echo ''
-- \echo '      This is what "the query was fine yesterday" looks like from'
-- \echo '      the inside. The data moved; the statistics did not.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART D - Per-table autovacuum tuning                          #'
-- \echo '################################################################'
-- \echo '  Do not change the global scale factor. Override it on the few'
-- \echo '  tables that need it.'
-- \echo ''

ALTER TABLE idx_lab.stats_demo SET (
  autovacuum_analyze_scale_factor  = 0.02,   -- 2% instead of 10%
  autovacuum_analyze_threshold     = 1000,
  autovacuum_vacuum_scale_factor   = 0.05
);

SELECT relname, reloptions
FROM pg_class WHERE relname = 'stats_demo';

-- \echo ''
-- \echo '   WHEN TO OVERRIDE:'
-- \echo '     - very large tables (10% is too long to wait)'
-- \echo '     - high-churn tables where the distribution shifts fast'
-- \echo '     - tables whose queries are extremely plan-sensitive'
-- \echo ''
-- \echo '   Revert with:'
-- \echo '     ALTER TABLE t RESET (autovacuum_analyze_scale_factor);'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART E - Is autovacuum keeping up?                            #'
-- \echo '################################################################'

SELECT schemaname || '.' || relname        AS table_name,
       n_live_tup, n_dead_tup,
       CASE WHEN n_live_tup > 0
            THEN round(100.0*n_dead_tup/n_live_tup,1) END AS dead_pct,
       last_vacuum, last_autovacuum,
       last_analyze, last_autoanalyze,
       vacuum_count, autovacuum_count, analyze_count, autoanalyze_count
FROM pg_stat_user_tables
WHERE schemaname IN ('sales','person','production','idx_lab')
ORDER BY n_dead_tup DESC
LIMIT 10;

-- \echo ''
-- \echo '   dead_pct climbing while last_autovacuum stays old = autovacuum'
-- \echo '   is falling behind. Consequences: bloat, worse estimates, AND'
-- \echo '   Index Only Scans degrading because the visibility map goes'
-- \echo '   stale (heap fetches climb).'
-- \echo ''

-- \echo '  -- Anything running right now?'
SELECT pid, datname, relid::regclass AS table_name, phase,
       heap_blks_scanned, heap_blks_total
FROM pg_stat_progress_vacuum;

-- \echo ''
-- \echo '   On Azure Flexible Server, enable metrics.autovacuum_diagnostics'
-- \echo '   and you get autovacuum counters as Azure Monitor metrics -'
-- \echo '   chartable and alertable alongside CPU and IOPS.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART F - A difference from Oracle worth naming                #'
-- \echo '################################################################'
-- \echo '  Oracle has DBMS_STATS.LOCK_TABLE_STATS to pin a known-good set'
-- \echo '  of statistics, plus SQL plan baselines to pin a plan.'
-- \echo ''
-- \echo '  PostgreSQL has NEITHER in core. Your options are:'
-- \echo '    - keep statistics ACCURATE (the intended answer)'
-- \echo '    - raise per-column statistics targets on sensitive columns'
-- \echo '    - CREATE STATISTICS for correlated predicates'
-- \echo '    - pg_hint_plan for a targeted, documented override'
-- \echo ''
-- \echo '  Be straight about this with an Oracle audience. They will ask,'
-- \echo '  and a confident honest answer earns far more credibility than'
-- \echo '  a vague one. The PostgreSQL philosophy is "fix the estimate,'
-- \echo '  do not freeze the plan" - which is defensible, and also means'
-- \echo '  the operational discipline around ANALYZE matters more.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART G - The statistics runbook to leave behind               #'
-- \echo '################################################################'

SELECT 1 AS step, 'After every bulk load / restore / migration' AS trigger_event,
       'vacuumdb --analyze-only --jobs=8 --all'                 AS action
UNION ALL SELECT 2, 'After creating an index',
       'ANALYZE the table - especially for EXPRESSION indexes'
UNION ALL SELECT 3, 'After a major data-distribution change',
       'ANALYZE the affected tables'
UNION ALL SELECT 4, 'Weekly health check',
       'review n_mod_since_analyze vs the autoanalyze threshold'
UNION ALL SELECT 5, 'On very large or high-churn tables',
       'ALTER TABLE ... SET (autovacuum_analyze_scale_factor = 0.02)'
UNION ALL SELECT 6, 'On skewed, heavily-filtered columns',
       'ALTER TABLE ... ALTER COLUMN ... SET STATISTICS 500'
UNION ALL SELECT 7, 'On correlated predicate pairs',
       'CREATE STATISTICS (dependencies, ndistinct, mcv)'
ORDER BY 1;

-- \echo ''
-- \echo '>>> NEXT: 10_full_scenario.sql   - the finale'
-- \echo ''
