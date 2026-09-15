-- =====================================================================
-- 00_index_inventory.sql    READ-ONLY. Run this FIRST, once.
--
-- The index audit you should be able to run on any customer database in
-- under five minutes. Every query here is safe on production.
--
-- Oracle equivalents:
--   USER_INDEXES / DBA_INDEXES          -> pg_indexes, pg_index
--   V$OBJECT_USAGE (index monitoring)   -> pg_stat_user_indexes.idx_scan
--   DBA_TAB_STATISTICS                  -> pg_stats, pg_class.reltuples
--   INDEX_STATS / VALIDATE STRUCTURE    -> pgstattuple, pgstatindex
-- =====================================================================

--\pset pager off
--\timing on

-- \echo ''
-- \echo '################################################################'
-- \echo '# 1. What indexes exist, and what do they cost in storage?      #'
-- \echo '################################################################'

SELECT s.schemaname || '.' || s.relname                     AS table_name,
       s.indexrelname                                       AS index_name,
       pg_size_pretty(pg_relation_size(s.indexrelid))       AS index_size,
       s.idx_scan                                           AS times_used,
       CASE WHEN i.indisprimary THEN 'PK'
            WHEN i.indisunique  THEN 'UNIQUE'
            WHEN i.indpred IS NOT NULL THEN 'PARTIAL'
            WHEN i.indexprs IS NOT NULL THEN 'EXPRESSION'
            ELSE 'regular' END                              AS kind,
       am.amname                                            AS index_type
FROM pg_stat_user_indexes s
JOIN pg_index  i  ON i.indexrelid = s.indexrelid
JOIN pg_class  c  ON c.oid = s.indexrelid
JOIN pg_am     am ON am.oid = c.relam
WHERE s.schemaname IN ('sales','person','production','humanresources','purchasing')
ORDER BY pg_relation_size(s.indexrelid) DESC
LIMIT 25;

-- \echo ''
-- \echo '   NOTE which columns are ALREADY indexed. AdventureWorks ports'
-- \echo '   differ - some create only PK/FK, others include the SQL Server'
-- \echo '   secondary indexes. That decides which before/after demos work.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# 2. Index-to-heap ratio per table                              #'
-- \echo '################################################################'

SELECT schemaname || '.' || relname                     AS table_name,
       pg_size_pretty(pg_relation_size(relid))          AS heap,
       pg_size_pretty(pg_indexes_size(relid))           AS indexes,
       round(100.0 * pg_indexes_size(relid) /
             NULLIF(pg_relation_size(relid),0), 1)      AS pct_of_heap,
       (SELECT count(*) FROM pg_index WHERE indrelid = relid) AS index_count
FROM pg_stat_user_tables
WHERE schemaname IN ('sales','person','production','humanresources','purchasing')
ORDER BY pg_indexes_size(relid) DESC
LIMIT 25;

-- \echo ''
-- \echo '   pct_of_heap over ~100% means more index than data. Sometimes'
-- \echo '   justified on a read-heavy table. Always worth a conversation.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# 3. NEVER-USED INDEXES - the drop-candidate list               #'
-- \echo '################################################################'

SELECT s.schemaname || '.' || s.relname            AS table_name,
       s.indexrelname                              AS index_name,
       pg_size_pretty(pg_relation_size(s.indexrelid)) AS wasted_space,
       s.idx_scan                                  AS times_used
FROM pg_stat_user_indexes s
JOIN pg_index i ON i.indexrelid = s.indexrelid
WHERE s.idx_scan = 0
  AND NOT i.indisprimary
  AND NOT i.indisunique
  AND s.schemaname IN ('sales','person','production','humanresources','purchasing')
ORDER BY pg_relation_size(s.indexrelid) DESC;

-- \echo ''
-- \echo '   *** SAY THIS OUT LOUD BEFORE ANYONE DROPS ANYTHING: ***'
-- \echo '   idx_scan counts since the last statistics reset. A quarter-end'
-- \echo '   report index looks unused in July. Check the reset date first:'
SELECT datname, stats_reset,
       now() - stats_reset AS stats_age
FROM pg_stat_database WHERE datname = current_database();

-- \echo ''
-- \echo '   And NEVER drop a unique or PK index - it enforces a constraint.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# 4. DUPLICATE / REDUNDANT INDEXES                              #'
-- \echo '################################################################'
-- \echo '   An index on (a) is REDUNDANT if an index on (a,b) exists - the'
-- \echo '   leading-column rule means the composite already serves it.'
-- \echo ''

SELECT a.indrelid::regclass                AS table_name,
       a.indexrelid::regclass              AS redundant_index,
       b.indexrelid::regclass              AS covered_by,
       pg_size_pretty(pg_relation_size(a.indexrelid)) AS reclaimable
FROM pg_index a
JOIN pg_index b
  ON  a.indrelid = b.indrelid
  AND a.indexrelid <> b.indexrelid
  AND a.indkey::text || ' ' = left(b.indkey::text, length(a.indkey::text) + 1)
  AND a.indpred IS NULL AND b.indpred IS NULL
  AND NOT a.indisprimary AND NOT a.indisunique
WHERE a.indrelid::regclass::text NOT LIKE 'pg\_%'
ORDER BY pg_relation_size(a.indexrelid) DESC;

-- \echo ''
-- \echo '   Empty result = no obvious redundancy. Good.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# 5. How are the indexes actually being USED?                   #'
-- \echo '################################################################'

SELECT s.relname                                   AS table_name,
       s.seq_scan                                  AS seq_scans,
       s.seq_tup_read                              AS rows_read_sequentially,
       s.idx_scan                                  AS index_scans,
       s.idx_tup_fetch                             AS rows_via_index,
       CASE WHEN s.seq_scan + s.idx_scan = 0 THEN NULL
            ELSE round(100.0 * s.idx_scan / (s.seq_scan + s.idx_scan), 1)
       END                                         AS pct_index_access,
       CASE WHEN s.seq_scan > 0 THEN s.seq_tup_read / s.seq_scan END
                                                   AS avg_rows_per_seq_scan
FROM pg_stat_user_tables s
WHERE s.schemaname IN ('sales','person','production')
  AND (s.seq_scan + s.idx_scan) > 0
ORDER BY s.seq_tup_read DESC
LIMIT 15;

-- \echo ''
-- \echo '   HIGH avg_rows_per_seq_scan on a LARGE table = repeated full'
-- \echo '   scans. That is your index candidate list, ranked by pain.'
-- \echo '   A high seq_scan count on a SMALL table is fine and expected.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# 6. STATISTICS health                                          #'
-- \echo '################################################################'

SELECT schemaname || '.' || relname   AS table_name,
       n_live_tup                     AS live_rows,
       n_dead_tup                     AS dead_rows,
       n_mod_since_analyze            AS rows_changed_since_analyze,
       CASE WHEN n_live_tup > 0
            THEN round(100.0 * n_mod_since_analyze / n_live_tup, 1) END
                                      AS pct_stale,
       last_analyze, last_autoanalyze,
       last_vacuum,  last_autovacuum
FROM pg_stat_user_tables
WHERE schemaname IN ('sales','person','production')
ORDER BY n_mod_since_analyze DESC
LIMIT 15;

-- \echo ''
-- \echo '   A large pct_stale with an old last_analyze is the "stale'
-- \echo '   statistics" smoking gun. Fix:  ANALYZE <table>;'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# 7. Extended statistics objects already defined                #'
-- \echo '################################################################'

SELECT statistics_schemaname || '.' || statistics_name AS stats_object,
       tablename, attnames, kinds
FROM pg_stats_ext
ORDER BY 1;


-- \echo ''
-- \echo '##################################################################'
-- \echo '# 8. Create a copy of salesorderheader and define extended stats #'
-- \echo '##################################################################'

DROP TABLE IF EXISTS public.d2runbook_salesorderheader;
CREATE TABLE public.d2runbook_salesorderheader AS
SELECT *FROM sales.salesorderheader;
ALTER TABLE public.d2runbook_salesorderheader  ADD PRIMARY KEY (salesorderid);ANALYZE public.d2runbook_salesorderheader;

CREATE STATISTICS IF NOT EXISTS public.d2runbook_soh_status_orderdate_stats  (dependencies, ndistinct) ON status, orderdate 
FROM public.d2runbook_salesorderheader;
ANALYZE public.d2runbook_salesorderheader;

SELECT schemaname,
       tablename,
       statistics_name,
       attnames,
       kinds
FROM pg_stats_ext
WHERE schemaname = 'public'
  AND tablename = 'd2runbook_salesorderheader';

SELECT statistics_schemaname || '.' || statistics_name AS stats_object,
       tablename, attnames, kinds
FROM pg_stats_ext
ORDER BY 1;



-- \echo ''
-- \echo '   Usually empty on a migrated database - and that is exactly the'
-- \echo '   gap script 08 fills. Oracle called these column groups /'
-- \echo '   extended stats; almost nobody creates them in PostgreSQL'
-- \echo '   because they do not know the feature exists.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# 9. Global settings that govern all of this                    #'
-- \echo '################################################################'

SELECT name, setting, unit, boot_val AS default_value
FROM pg_settings
WHERE name IN ('default_statistics_target','random_page_cost','seq_page_cost',
               'effective_cache_size','maintenance_work_mem','work_mem',
               'autovacuum_analyze_scale_factor','autovacuum_analyze_threshold',
               'autovacuum_vacuum_scale_factor','max_parallel_maintenance_workers')
ORDER BY name;

-- \echo ''
-- \echo '   *** random_page_cost = 4.0 is a SPINNING DISK default. ***'
-- \echo '   On Azure Premium SSD it should be 1.1-2.0. Leaving it at 4.0'
-- \echo '   systematically biases the planner AWAY from your indexes.'
-- \echo '   Highest-value, lowest-risk change on most migrated workloads.'
-- \echo ''
-- \echo '   default_statistics_target = 100 means ~30,000 rows sampled and'
-- \echo '   up to 100 histogram buckets. Oracle METHOD_OPT SIZE analogue.'
-- \echo ''

-- \echo ''
-- \echo '>>> NEXT: 01_btree_and_column_order.sql'
-- \echo ''
