/*
    PostgreSQL workload troubleshooting queries.

    pg_stat_statements must be installed and loaded for section 2:
        CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

    Reset before a controlled test when appropriate:
        SELECT pg_stat_statements_reset();
*/

-- 1. Statements executing now for the SARGability workload.
SELECT pid,
       usename,
       application_name,
       state,
       wait_event_type,
       wait_event,
       now() - query_start AS query_duration,
       query
FROM pg_stat_activity
WHERE datname = current_database()
  AND state <> 'idle'
  AND application_name LIKE 'PGBench%'
ORDER BY query_duration DESC;

-- 2. Most expensive captured statements from the target table.
-- High block reads, temporary writes, mean time, or rows per call are signals
-- to investigate; they do not prove that a statement is poorly optimized.
SELECT queryid,
       calls,
       round(total_exec_time::numeric, 2) AS total_exec_ms,
       round(mean_exec_time::numeric, 2) AS mean_exec_ms,
       round(stddev_exec_time::numeric, 2) AS stddev_exec_ms,
       rows,
       round((rows::numeric / NULLIF(calls, 0)), 2) AS rows_per_call,
       shared_blks_hit,
       shared_blks_read,
       temp_blks_read,
       temp_blks_written,
      round(shared_blk_read_time::numeric, 2) AS block_read_ms,
       query
FROM pg_stat_statements
WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
  AND query ILIKE '%productdescription_sarg%'
  AND query NOT ILIKE '%pg_stat_statements%'
ORDER BY total_exec_time DESC
LIMIT 25;

-- 3. Table-level scan totals since statistics were last reset.
-- Compare these counters before and after running workload 5.
SELECT schemaname,
       relname,
       seq_scan,
       seq_tup_read,
       idx_scan,
       idx_tup_fetch,
       n_live_tup,
       stats_reset
FROM pg_stat_user_tables
CROSS JOIN LATERAL (
    SELECT stats_reset
    FROM pg_stat_database
    WHERE datname = current_database()
) AS database_stats
WHERE schemaname = 'public'
  AND relname IN ('productdescription_sarg', 'productdescription_sarg_fixed')
ORDER BY relname;

-- 4. Index definitions and usage totals for the target table.
SELECT schemaname,
       indexrelname AS index_name,
       idx_scan,
       idx_tup_read,
       idx_tup_fetch,
       pg_get_indexdef(indexrelid) AS index_definition
FROM pg_stat_user_indexes
WHERE schemaname = 'public'
  AND relname IN ('productdescription_sarg', 'productdescription_sarg_fixed')
ORDER BY relname,
         idx_scan DESC,
         indexrelname;