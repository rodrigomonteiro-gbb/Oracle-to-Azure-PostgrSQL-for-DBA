/*
    DBA review for PostgreSQL query history using pg_stat_statements

    PostgreSQL pg_stat_statements is the closest built-in equivalent to SQL Server
    Query Store. It records normalized SQL and cumulative resource statistics. It
    does not retain complete execution plans, application_name, per-execution rows,
    or native plan-forcing metadata.

    Run this script in the database being analyzed. pg_monitor or
    pg_read_all_stats provides the most complete cross-user visibility.
*/

\pset pager off
\timing on

-- 1. Verify extension, collection settings, privileges, and reset history.
SELECT current_database() AS database_name,
       current_user AS monitoring_role,
       current_setting('server_version') AS server_version,
       extension.extversion,
       current_setting('shared_preload_libraries') AS shared_preload_libraries,
       current_setting('compute_query_id') AS compute_query_id,
       current_setting('pg_stat_statements.track', true) AS statements_tracked,
       current_setting('pg_stat_statements.track_planning', true) AS planning_tracked,
       current_setting('pg_stat_statements.track_utility', true) AS utility_tracked,
       current_setting('track_io_timing') AS io_timing_tracked,
       current_setting('pg_stat_statements.max', true) AS statement_capacity,
       info.stats_reset,
       info.dealloc AS statements_deallocated,
       pg_has_role(current_user, 'pg_monitor', 'MEMBER') AS is_pg_monitor,
       pg_has_role(current_user, 'pg_read_all_stats', 'MEMBER') AS can_read_all_stats,
       clock_timestamp() AS observed_at
FROM pg_extension AS extension
CROSS JOIN pg_stat_statements_info AS info
WHERE extension.extname = 'pg_stat_statements';

-- 2. Capacity and churn. A high deallocation count means old entries were evicted;
-- increase pg_stat_statements.max only after confirming memory and restart impact.
SELECT count(*) AS current_database_entries,
       current_setting('pg_stat_statements.max')::bigint AS cluster_entry_limit,
       round(
           100.0 * count(*) / current_setting('pg_stat_statements.max')::numeric,
           2
       ) AS current_database_capacity_pct,
       info.dealloc AS statements_deallocated_since_reset,
       info.stats_reset
FROM pg_stat_statements
CROSS JOIN pg_stat_statements_info AS info
WHERE dbid = (SELECT oid
              FROM pg_database
              WHERE datname = current_database())
GROUP BY info.dealloc,
         info.stats_reset;

-- 3. Top total execution cost: prioritize statements consuming the most aggregate
-- time, then compare frequency, mean latency, variability, rows, and block access.
SELECT queryid,
       calls,
       plans,
       round(total_plan_time::numeric, 2) AS total_plan_ms,
       round(total_exec_time::numeric, 2) AS total_exec_ms,
       round(mean_exec_time::numeric, 2) AS mean_exec_ms,
       round(max_exec_time::numeric, 2) AS max_exec_ms,
       round(stddev_exec_time::numeric, 2) AS stddev_exec_ms,
       rows,
       round((rows::numeric / NULLIF(calls, 0)), 2) AS rows_per_call,
       shared_blks_hit,
       shared_blks_read,
       temp_blks_read,
       temp_blks_written,
       pg_size_pretty(wal_bytes::bigint) AS wal_size,
       left(query, 2000) AS normalized_query
FROM pg_stat_statements
WHERE dbid = (SELECT oid
              FROM pg_database
              WHERE datname = current_database())
  AND query NOT ILIKE '%pg_stat_statements%'
ORDER BY total_exec_time DESC
LIMIT 50;

-- 4. Highest mean latency, excluding one-off statements.
SELECT queryid,
       calls,
       round(mean_exec_time::numeric, 2) AS mean_exec_ms,
       round(min_exec_time::numeric, 2) AS min_exec_ms,
       round(max_exec_time::numeric, 2) AS max_exec_ms,
       round(stddev_exec_time::numeric, 2) AS stddev_exec_ms,
       rows,
       left(query, 1500) AS normalized_query
FROM pg_stat_statements
WHERE dbid = (SELECT oid
              FROM pg_database
              WHERE datname = current_database())
  AND calls >= 5
  AND query NOT ILIKE '%pg_stat_statements%'
ORDER BY mean_exec_time DESC
LIMIT 50;

-- 5. Most frequently executed statements. Small per-call cost can still have a
-- large aggregate effect when calls are high.
SELECT queryid,
       calls,
       round(total_exec_time::numeric, 2) AS total_exec_ms,
       round(mean_exec_time::numeric, 3) AS mean_exec_ms,
       rows,
       left(query, 1500) AS normalized_query
FROM pg_stat_statements
WHERE dbid = (SELECT oid
              FROM pg_database
              WHERE datname = current_database())
  AND query NOT ILIKE '%pg_stat_statements%'
ORDER BY calls DESC
LIMIT 50;

-- 6. Planning overhead and re-planning frequency. Meaningful values require
-- pg_stat_statements.track_planning = on before the workload starts.
SELECT queryid,
       calls,
       plans,
       round((plans::numeric / NULLIF(calls, 0)), 3) AS plans_per_call,
       round(total_plan_time::numeric, 2) AS total_plan_ms,
       round(mean_plan_time::numeric, 3) AS mean_plan_ms,
       round(total_exec_time::numeric, 2) AS total_exec_ms,
       round(
           100.0 * total_plan_time /
           NULLIF(total_plan_time + total_exec_time, 0),
           2
       ) AS planning_time_pct,
       left(query, 1500) AS normalized_query
FROM pg_stat_statements
WHERE dbid = (SELECT oid
              FROM pg_database
              WHERE datname = current_database())
  AND query NOT ILIKE '%pg_stat_statements%'
ORDER BY total_plan_time DESC
LIMIT 50;

-- 7. Physical reads and cache reuse. Low hit percentage can reflect cold cache,
-- broad scans, or a working set larger than available cache.
SELECT queryid,
       calls,
       shared_blks_hit,
       shared_blks_read,
       round(
           100.0 * shared_blks_hit /
           NULLIF(shared_blks_hit + shared_blks_read, 0),
           2
       ) AS shared_hit_pct,
       round(shared_blk_read_time::numeric, 2) AS shared_read_ms,
       round(shared_blk_write_time::numeric, 2) AS shared_write_ms,
       left(query, 1500) AS normalized_query
FROM pg_stat_statements
WHERE dbid = (SELECT oid
              FROM pg_database
              WHERE datname = current_database())
  AND shared_blks_read > 0
  AND query NOT ILIKE '%pg_stat_statements%'
ORDER BY shared_blks_read DESC
LIMIT 50;

-- 8. Temporary-file spills. Investigate sorts and hashes with representative
-- EXPLAIN (ANALYZE, BUFFERS, SETTINGS) after identifying the normalized query.
SELECT queryid,
       calls,
       temp_blks_read,
       temp_blks_written,
       round(temp_blk_read_time::numeric, 2) AS temp_read_ms,
       round(temp_blk_write_time::numeric, 2) AS temp_write_ms,
       round(total_exec_time::numeric, 2) AS total_exec_ms,
       left(query, 1500) AS normalized_query
FROM pg_stat_statements
WHERE dbid = (SELECT oid
              FROM pg_database
              WHERE datname = current_database())
  AND (temp_blks_read > 0 OR temp_blks_written > 0)
  AND query NOT ILIKE '%pg_stat_statements%'
ORDER BY temp_blks_written DESC,
         temp_blks_read DESC
LIMIT 50;

-- 9. Write and WAL-heavy statements.
SELECT queryid,
       calls,
       rows,
       shared_blks_dirtied,
       shared_blks_written,
       wal_records,
       wal_fpi,
       pg_size_pretty(wal_bytes::bigint) AS wal_size,
       round(total_exec_time::numeric, 2) AS total_exec_ms,
       left(query, 1500) AS normalized_query
FROM pg_stat_statements
WHERE dbid = (SELECT oid
              FROM pg_database
              WHERE datname = current_database())
  AND (wal_bytes > 0 OR shared_blks_dirtied > 0)
  AND query NOT ILIKE '%pg_stat_statements%'
ORDER BY wal_bytes DESC
LIMIT 50;

-- 10. Latency variability. A high coefficient of variation can indicate changing
-- parameters, cache state, blocking, resource pressure, or different plan choices.
SELECT queryid,
       calls,
       round(mean_exec_time::numeric, 2) AS mean_exec_ms,
       round(stddev_exec_time::numeric, 2) AS stddev_exec_ms,
       round(
           (stddev_exec_time / NULLIF(mean_exec_time, 0))::numeric,
           3
       ) AS coefficient_of_variation,
       round(min_exec_time::numeric, 2) AS min_exec_ms,
       round(max_exec_time::numeric, 2) AS max_exec_ms,
       left(query, 1500) AS normalized_query
FROM pg_stat_statements
WHERE dbid = (SELECT oid
              FROM pg_database
              WHERE datname = current_database())
  AND calls >= 10
  AND mean_exec_time > 0
  AND query NOT ILIKE '%pg_stat_statements%'
ORDER BY coefficient_of_variation DESC
LIMIT 50;

-- 11. Live activity complements historical totals. application_name is available
-- here but is not retained in pg_stat_statements after a session disconnects.
SELECT pid,
       usename,
       application_name,
       state,
       wait_event_type,
       wait_event,
       clock_timestamp() - query_start AS query_age,
       pg_blocking_pids(pid) AS blocking_pids,
       left(query, 1000) AS current_query
FROM pg_stat_activity
WHERE datname = current_database()
  AND pid <> pg_backend_pid()
ORDER BY query_start NULLS LAST;

-- After selecting a queryid, obtain the original SQL and representative parameters,
-- then run EXPLAIN (ANALYZE, BUFFERS, WAL, SETTINGS, SUMMARY). pg_stat_statements
-- does not preserve complete historical plan trees or support native plan forcing.
