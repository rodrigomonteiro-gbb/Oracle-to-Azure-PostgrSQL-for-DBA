/*
    DBA review for workload 7: Cursors

    Run this script in the same database used by Generate-PGSQL-Workload.ps1.
    Sections 1 through 6 are most useful while the workload is running. Sections
    7 through 11 use cumulative statistics and can also be run after completion.

    PostgreSQL does not expose cursors from other sessions through pg_cursors.
    That view reports only cursors open in the session querying it, and these
    functions open and close their cursors within a single function call. Monitor
    other backends through pg_stat_activity, locks, pg_stat_statements, function
    statistics, and table statistics instead.

    Requirements
    ------------
    - pg_stat_statements is required for statement-level history.
    - pg_stat_statements.track = all is recommended to capture statements nested
      inside PL/pgSQL functions.
    - track_functions = pl is recommended for pg_stat_user_functions metrics.
    - track_io_timing = on is recommended for meaningful I/O timing.
    - pg_monitor or pg_read_all_stats provides complete cross-user visibility.
*/

\pset pager off
\timing on

-- 1. Verify monitoring configuration and extension availability.
SELECT current_database() AS database_name,
       current_user AS monitoring_role,
       current_setting('server_version') AS server_version,
       current_setting('track_functions') AS track_functions,
       current_setting('track_io_timing') AS track_io_timing,
       current_setting('pg_stat_statements.track', true) AS statements_tracked,
       EXISTS (
           SELECT 1
           FROM pg_extension
           WHERE extname = 'pg_stat_statements'
       ) AS pg_stat_statements_installed,
       pg_has_role(current_user, 'pg_monitor', 'MEMBER') AS is_pg_monitor,
       pg_has_role(current_user, 'pg_read_all_stats', 'MEMBER')
           AS can_read_all_stats,
       clock_timestamp() AS observed_at;

-- 2. Show cursor workload sessions. Long query or transaction ages can indicate
-- slow row-by-row processing, lock waits, or a large salesperson result set.
SELECT pid,
       usename,
       application_name,
       state,
       wait_event_type,
       wait_event,
       clock_timestamp() - xact_start AS transaction_age,
       clock_timestamp() - query_start AS query_age,
       pg_blocking_pids(pid) AS blocking_pids,
       left(query, 500) AS current_query
FROM pg_stat_activity
WHERE datname = current_database()
  AND application_name LIKE 'PGBench%'
ORDER BY query_start NULLS LAST,
         pid;

-- 3. Summarize states and waits by cursor workload. Lock waits on the update
-- workload indicate write contention. IO waits indicate storage pressure. Active
-- sessions with no wait are running or runnable on CPU.
SELECT application_name,
       state,
       COALESCE(wait_event_type, 'CPU or runnable') AS wait_type,
       COALESCE(wait_event, 'none') AS wait_event,
       count(*) AS sessions,
       max(clock_timestamp() - query_start) AS longest_query_age
FROM pg_stat_activity
WHERE datname = current_database()
  AND application_name LIKE 'PGBench%'
GROUP BY application_name,
         state,
         COALESCE(wait_event_type, 'CPU or runnable'),
         COALESCE(wait_event, 'none')
ORDER BY sessions DESC,
         application_name,
         state;

-- 4. Identify blocked cursor sessions and their blockers. The update workload can
-- block another update when concurrent clients choose the same salesperson.
SELECT blocked.pid AS blocked_pid,
       blocked.application_name AS blocked_application,
       blocked.wait_event_type,
       blocked.wait_event,
       clock_timestamp() - blocked.query_start AS blocked_duration,
       blocker.pid AS blocker_pid,
       blocker.application_name AS blocker_application,
       blocker.state AS blocker_state,
       clock_timestamp() - blocker.xact_start AS blocker_transaction_age,
       left(blocked.query, 500) AS blocked_query,
       left(blocker.query, 500) AS blocker_query
FROM pg_stat_activity AS blocked
CROSS JOIN LATERAL unnest(pg_blocking_pids(blocked.pid)) AS blockers(blocker_pid)
JOIN pg_stat_activity AS blocker
  ON blocker.pid = blockers.blocker_pid
WHERE blocked.datname = current_database()
  AND blocked.application_name LIKE 'PGBench%'
ORDER BY blocked_duration DESC;

-- 5. Inspect locks held or awaited by cursor workloads. granted = false identifies
-- a waiting lock. Relation and tuple locks are especially relevant to updates.
SELECT activity.pid,
       activity.application_name,
       activity.state,
       locks.locktype,
       locks.mode,
       locks.granted,
       locks.waitstart,
         CASE
           WHEN namespace.nspname IS NOT NULL
          AND relation.relname IS NOT NULL
           THEN format('%I.%I', namespace.nspname, relation.relname)
           ELSE '<not a relation lock>'
         END AS locked_object,
       locks.page,
       locks.tuple,
       locks.transactionid
FROM pg_locks AS locks
JOIN pg_stat_activity AS activity
  ON activity.pid = locks.pid
LEFT JOIN pg_class AS relation
  ON relation.oid = locks.relation
LEFT JOIN pg_namespace AS namespace
  ON namespace.oid = relation.relnamespace
WHERE activity.datname = current_database()
  AND activity.application_name LIKE 'PGBench%'
ORDER BY locks.granted,
         activity.pid,
         locks.locktype,
         locks.mode;

-- 6. pg_cursors is intentionally session-local. It will normally return no rows
-- here because this DBA session did not open the workload cursors.
SELECT name,
       statement,
       is_holdable,
       is_binary,
       is_scrollable,
       creation_time
FROM pg_cursors
ORDER BY creation_time;

-- 7. Function-level cost. This returns one row for every expected function even
-- when statistics are unavailable. track_functions must be pl or all before the
-- workload starts. Enabling it after execution cannot recover earlier calls.
WITH expected_functions(funcname) AS (
    VALUES ('demo_address_cursor'),
           ('demo_salesorderheader_cursor'),
           ('demo_salesorderheader_update_cursor')
), installed_functions AS (
    SELECT expected.funcname,
           function_definition.oid AS funcid,
           function_schema.nspname AS schemaname
    FROM expected_functions AS expected
    LEFT JOIN pg_proc AS function_definition
      ON function_definition.proname = expected.funcname
     AND function_definition.prokind = 'f'
    LEFT JOIN pg_namespace AS function_schema
      ON function_schema.oid = function_definition.pronamespace
)
SELECT installed.schemaname,
       installed.funcname,
       COALESCE(stats.calls, 0) AS calls,
       round(COALESCE(stats.total_time, 0)::numeric, 2) AS total_time_ms,
       round(COALESCE(stats.self_time, 0)::numeric, 2) AS self_time_ms,
       round(
           (stats.total_time / NULLIF(stats.calls, 0))::numeric,
           2
       ) AS mean_time_ms,
       CASE
           WHEN installed.funcid IS NULL
           THEN 'Function is not installed in this database'
           WHEN current_setting('track_functions') NOT IN ('pl', 'all')
           THEN 'No metrics: set track_functions = pl before the workload'
           WHEN stats.funcid IS NULL OR stats.calls = 0
           THEN 'No calls captured since the last statistics reset'
           ELSE 'Metrics captured'
       END AS metrics_status
FROM installed_functions AS installed
LEFT JOIN pg_stat_user_functions AS stats
  ON stats.funcid = installed.funcid
ORDER BY COALESCE(stats.total_time, 0) DESC,
         installed.funcname;

-- 8. Rank captured cursor statements. pg_stat_statements.track = all is needed to
-- capture nested FETCH/UPDATE statements; otherwise only outer function calls may
-- be visible. High mean time, reads, writes, WAL, or temporary blocks need review.
SELECT queryid,
       calls,
       round(total_exec_time::numeric, 2) AS total_exec_ms,
       round(mean_exec_time::numeric, 2) AS mean_exec_ms,
       round(max_exec_time::numeric, 2) AS max_exec_ms,
       rows,
       shared_blks_hit,
       shared_blks_read,
       shared_blks_dirtied,
       shared_blks_written,
       temp_blks_read,
       temp_blks_written,
       wal_records,
       wal_fpi,
       wal_bytes,
       left(query, 1000) AS query
FROM pg_stat_statements
WHERE dbid = (
          SELECT oid
          FROM pg_database
          WHERE datname = current_database()
      )
  AND (
      query ILIKE '%demo_address_cursor%'
      OR query ILIKE '%demo_salesorderheader_cursor%'
      OR query ILIKE '%demo_salesorderheader_update_cursor%'
      OR query ILIKE '%sales.salesorderheader%'
      OR query ILIKE '%person.address%'
  )
  AND query NOT ILIKE '%pg_stat_statements%'
ORDER BY total_exec_time DESC
LIMIT 50;

-- 9. Review Person.Address read activity and SalesOrderHeader read/update activity.
-- High n_tup_upd and n_dead_tup on SalesOrderHeader indicate update churn and
-- future vacuum work.
SELECT schemaname,
       relname,
       seq_scan,
       seq_tup_read,
       idx_scan,
       idx_tup_fetch,
       n_tup_upd,
       n_tup_hot_upd,
       n_dead_tup,
       last_autovacuum,
       autovacuum_count,
       last_autoanalyze,
       autoanalyze_count
FROM pg_stat_user_tables
WHERE (schemaname = 'person' AND relname = 'address')
   OR (schemaname = 'sales' AND relname = 'salesorderheader')
ORDER BY schemaname,
         relname;

-- 10. Review index use for cursor predicates and ordering. Repeated sequential
-- scans or high tuples read per scan can indicate missing/ineffective indexes.
SELECT schemaname,
       relname,
       indexrelname AS index_name,
       idx_scan,
       idx_tup_read,
       idx_tup_fetch,
       pg_size_pretty(pg_relation_size(indexrelid)) AS index_size,
       pg_get_indexdef(indexrelid) AS index_definition
FROM pg_stat_user_indexes
WHERE (schemaname = 'person' AND relname = 'address')
   OR (schemaname = 'sales' AND relname = 'salesorderheader')
ORDER BY schemaname,
         relname,
         idx_scan DESC,
         indexrelname;

-- 11. Check SalesOrderHeader health after update tests. A growing dead-tuple count,
-- delayed autovacuum, and large table size can indicate sustained update overhead.
SELECT stats.schemaname,
       stats.relname,
       stats.n_live_tup,
       stats.n_dead_tup,
       round(
           100.0 * stats.n_dead_tup /
           NULLIF(stats.n_live_tup + stats.n_dead_tup, 0),
           2
       ) AS dead_tuple_pct,
       stats.n_tup_upd,
       stats.n_tup_hot_upd,
       stats.last_autovacuum,
       stats.autovacuum_count,
       pg_size_pretty(pg_total_relation_size(stats.relid)) AS total_table_size
FROM pg_stat_user_tables AS stats
WHERE stats.schemaname = 'sales'
  AND stats.relname = 'salesorderheader';
