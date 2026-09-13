/*
    DBA analysis for workload 6: AdventureWorks_ExecutionPlan.sql

    Purpose
    -------
    Run these queries during or after the PGBench_ExecutionPlan workload to
    identify expensive statements, unstable execution times, physical I/O,
    temporary-file spills, blocking, and inefficient table or index access.

    Most important metrics
    ----------------------
    1. total_exec_time and calls: total workload impact and execution frequency.
    2. mean/max/stddev_exec_time: typical latency, worst latency, and variability.
    3. rows_per_call: whether row volume explains the observed execution cost.
    4. shared_blks_read versus shared_blks_hit: physical reads versus cache reuse.
    5. temp_blks_read/written: sort or hash spills that may indicate low work_mem
       or inaccurate estimates.
    6. total_plan_time and plans: planning overhead and repeated replanning.
    7. seq_scan/seq_tup_read and index usage: access methods used by each table.
    8. wait_event_type/wait_event and blocking PIDs: current bottlenecks.
    9. parallel workers and JIT time: whether expensive plans use these features
       and whether their startup cost is worthwhile for the query duration.
    10. WAL bytes: write activity; this SELECT-only workload should produce little
       or no WAL from its application statements.

    Requirements and reset scope
    ----------------------------
    - pg_stat_statements must be installed and loaded.
    - track_io_timing should be on for meaningful block read/write timing.
    - pg_stat_statements.track_planning should be on before the test if planning
      metrics are required.
    - The workload generator's "Reset PGSTATS before run" option now runs
      pg_stat_reset(), pg_stat_reset_shared('io'), pg_stat_statements_reset(),
      and pg_stat_clear_snapshot(). The workload does not start if a reset fails.
    - pg_stat_reset() resets current-database, table, index, and table-I/O counters.
      pg_stat_reset_shared('io') resets cluster-wide I/O counters for every database.
      Use the shared reset only when its impact on other monitoring is acceptable.
    - If policy or permissions prevent resets, use sections 13 through 19. Run
      section 13 before the workload, keep that database session open, run pgbench
      from another session, and then run sections 14 through 19 in the first session.
    - Statistics can lag briefly. Re-run the post-workload sections after a few
      seconds if the workload has just stopped.
    - PostgreSQL system views do not retain complete execution-plan trees. After
      identifying a queryid here, run its SQL separately with EXPLAIN (ANALYZE,
      BUFFERS, WAL, SETTINGS, SUMMARY) using representative parameter values, or
      configure auto_explain before the test when historical plans are required.

    Suggested workflow
    ------------------
    - With reset enabled: run sections 1 and 2 to verify configuration/reset time.
    - During: run sections 3 through 5 for sessions, waits, and blocking.
    - After: run sections 6 through 12 for statement and object-level analysis.
    - Without reset privileges: use sections 13 through 19 for interval deltas.
    - Run this script in the same database used by workload 6.
*/

-- Improve readability in psql. These commands do not change server state.
\pset pager off
\timing on

-- 1. Verify the database, PostgreSQL version, extension version, and collection
-- settings. Look for pg_stat_statements to be present, track_io_timing = on,
-- and track_planning = on when planning-time analysis is needed.
SELECT current_database() AS database_name,
       current_setting('server_version') AS server_version,
       ext.extversion AS pg_stat_statements_version,
       current_setting('track_io_timing') AS track_io_timing,
       current_setting('pg_stat_statements.track', true) AS statements_tracked,
       current_setting('pg_stat_statements.track_planning', true) AS track_planning,
       pg_postmaster_start_time() AS server_started_at,
       clock_timestamp() AS observed_at
FROM pg_extension AS ext
WHERE ext.extname = 'pg_stat_statements';

-- 2. Confirm reset times for statement, current-database, and cluster I/O stats.
-- With the reset checkbox enabled, all timestamps should be just before this run.
-- Different or old timestamps mean the corresponding results may be cumulative.
SELECT database_stats.stats_reset AS database_stats_reset,
     statement_stats.stats_reset AS statement_stats_reset,
     statement_stats.dealloc AS statements_deallocated_since_reset,
     io_stats.oldest_reset AS io_oldest_reset,
     io_stats.newest_reset AS io_newest_reset,
     clock_timestamp() AS observed_at
FROM pg_stat_database AS database_stats
CROSS JOIN pg_stat_statements_info AS statement_stats
CROSS JOIN (
  SELECT min(stats_reset) AS oldest_reset,
       max(stats_reset) AS newest_reset
  FROM pg_stat_io
) AS io_stats
WHERE database_stats.datname = current_database();

-- 3. Inspect workload sessions while pgbench is running. Look for long query_age,
-- long transaction_age, non-CPU waits, idle-in-transaction sessions, and blockers.
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
ORDER BY query_start NULLS LAST;

-- 4. Summarize current workload waits. A high count for Lock means contention;
-- IO waits indicate storage pressure, and Client waits often mean pgbench/client
-- pacing rather than slow SQL. Active rows with no wait may be consuming CPU.
SELECT state,
       COALESCE(wait_event_type, 'CPU or runnable') AS wait_type,
       COALESCE(wait_event, 'none') AS wait_event,
       count(*) AS sessions
FROM pg_stat_activity
WHERE datname = current_database()
  AND application_name LIKE 'PGBench%'
GROUP BY state,
         COALESCE(wait_event_type, 'CPU or runnable'),
         COALESCE(wait_event, 'none')
ORDER BY sessions DESC,
         state,
         wait_type;

-- 5. Show blocked workload sessions and their blockers. Any returned row deserves
-- investigation; focus first on the longest blocked duration and blocker query.
SELECT blocked.pid AS blocked_pid,
       blocked.wait_event_type,
       blocked.wait_event,
       clock_timestamp() - blocked.query_start AS blocked_duration,
       blocker.pid AS blocker_pid,
       blocker.application_name AS blocker_application,
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

-- 6. Rank workload statements by total execution time. Start with high total time,
-- then inspect high mean/max/stddev time, low cache-hit percentage, temp blocks,
-- rows per call, unused requested parallel workers, and JIT cost. Zero I/O timing
-- can mean data was cached or timing is disabled.
SELECT queryid,
       calls,
       plans,
       round(total_plan_time::numeric, 2) AS total_plan_ms,
       round((total_plan_time / NULLIF(plans, 0))::numeric, 2) AS mean_plan_ms,
       round(total_exec_time::numeric, 2) AS total_exec_ms,
       round(mean_exec_time::numeric, 2) AS mean_exec_ms,
       round(max_exec_time::numeric, 2) AS max_exec_ms,
       round(stddev_exec_time::numeric, 2) AS stddev_exec_ms,
       rows,
       round((rows::numeric / NULLIF(calls, 0)), 2) AS rows_per_call,
       shared_blks_hit,
       shared_blks_read,
       round(
           100.0 * shared_blks_hit /
           NULLIF(shared_blks_hit + shared_blks_read, 0),
           2
       ) AS shared_hit_pct,
       shared_blks_dirtied,
       shared_blks_written,
       temp_blks_read,
       temp_blks_written,
       round(shared_blk_read_time::numeric, 2) AS shared_read_ms,
       round(shared_blk_write_time::numeric, 2) AS shared_write_ms,
       round(temp_blk_read_time::numeric, 2) AS temp_read_ms,
       round(temp_blk_write_time::numeric, 2) AS temp_write_ms,
      parallel_workers_to_launch,
      parallel_workers_launched,
      jit_functions,
      round((jit_generation_time
        + jit_inlining_time
        + jit_optimization_time
        + jit_emission_time)::numeric, 2) AS total_jit_ms,
       wal_records,
       wal_fpi,
       pg_size_pretty(wal_bytes::bigint) AS wal_size,
       query
FROM pg_stat_statements
WHERE dbid = (SELECT oid
              FROM pg_database
              WHERE datname = current_database())
  AND query NOT ILIKE '%pg_stat%'
  AND (query ILIKE '%person.person%'
       OR query ILIKE '%humanresources.employee%'
       OR query ILIKE '%sales.customer%'
       OR query ILIKE '%purchasing.purchaseorderheader%'
       OR query ILIKE '%sales.creditcard%'
       OR query ILIKE '%production.product%')
ORDER BY total_exec_time DESC
LIMIT 50;

-- 7. Compare aggregate workload cost. Use execution time per call, blocks read per
-- call, and temp blocks per call to compare runs with different client counts or
-- durations. plans_per_call near 1 can indicate repeated planning overhead.
SELECT sum(calls) AS total_calls,
       sum(plans) AS total_plans,
       round((sum(plans)::numeric / NULLIF(sum(calls), 0)), 3) AS plans_per_call,
       round(sum(total_plan_time)::numeric, 2) AS total_plan_ms,
       round(sum(total_exec_time)::numeric, 2) AS total_exec_ms,
       round((sum(total_exec_time) / NULLIF(sum(calls), 0))::numeric, 2)
           AS weighted_exec_ms_per_call,
       sum(rows) AS total_rows,
       round((sum(shared_blks_read)::numeric / NULLIF(sum(calls), 0)), 2)
           AS shared_reads_per_call,
       round((sum(temp_blks_written)::numeric / NULLIF(sum(calls), 0)), 2)
           AS temp_writes_per_call,
         sum(parallel_workers_to_launch) AS parallel_workers_requested,
         sum(parallel_workers_launched) AS parallel_workers_launched,
         sum(jit_functions) AS jit_functions,
         round(sum(jit_generation_time
             + jit_inlining_time
             + jit_optimization_time
             + jit_emission_time)::numeric, 2) AS total_jit_ms,
       pg_size_pretty(sum(wal_bytes)::bigint) AS total_wal_size
FROM pg_stat_statements
WHERE dbid = (SELECT oid
              FROM pg_database
              WHERE datname = current_database())
  AND query NOT ILIKE '%pg_stat%'
  AND (query ILIKE '%person.person%'
       OR query ILIKE '%humanresources.employee%'
       OR query ILIKE '%sales.customer%'
       OR query ILIKE '%purchasing.purchaseorderheader%'
       OR query ILIKE '%sales.creditcard%'
       OR query ILIKE '%production.product%');

-- 8. Review table access counters for every workload relation. Large seq_tup_read
-- relative to returned rows can reveal broad scans. Compare seq_scan and idx_scan,
-- after pg_stat_reset(), or use the fallback deltas when reset is unavailable.
WITH target_tables(schemaname, relname) AS (
    VALUES ('person', 'person'),
           ('sales', 'customer'),
           ('sales', 'store'),
           ('humanresources', 'employee'),
           ('person', 'businessentityaddress'),
           ('sales', 'salesorderheader'),
           ('purchasing', 'purchaseorderheader'),
           ('purchasing', 'purchaseorderdetail'),
           ('sales', 'salesorderdetail'),
           ('sales', 'creditcard'),
           ('production', 'product')
)
SELECT stats.schemaname,
       stats.relname,
       stats.seq_scan,
       stats.seq_tup_read,
       stats.idx_scan,
       stats.idx_tup_fetch,
       stats.n_live_tup,
       stats.n_dead_tup,
       stats.last_analyze,
       stats.last_autoanalyze
FROM pg_stat_user_tables AS stats
JOIN target_tables AS target
  ON target.schemaname = stats.schemaname
 AND target.relname = stats.relname
ORDER BY stats.seq_tup_read DESC,
         stats.schemaname,
         stats.relname;

-- 9. Review heap, index, and TOAST cache behavior by table. High physical reads
-- (the *_blks_read columns) identify relations driving storage I/O. These counters
-- are clean after pg_stat_reset(); otherwise use the fallback deltas below.
WITH target_tables(schemaname, relname) AS (
    VALUES ('person', 'person'),
           ('sales', 'customer'),
           ('sales', 'store'),
           ('humanresources', 'employee'),
           ('person', 'businessentityaddress'),
           ('sales', 'salesorderheader'),
           ('purchasing', 'purchaseorderheader'),
           ('purchasing', 'purchaseorderdetail'),
           ('sales', 'salesorderdetail'),
           ('sales', 'creditcard'),
           ('production', 'product')
)
SELECT io.schemaname,
       io.relname,
       io.heap_blks_read,
       io.heap_blks_hit,
       io.idx_blks_read,
       io.idx_blks_hit,
       io.toast_blks_read,
       io.toast_blks_hit,
       io.tidx_blks_read,
       io.tidx_blks_hit
FROM pg_statio_user_tables AS io
JOIN target_tables AS target
  ON target.schemaname = io.schemaname
 AND target.relname = io.relname
ORDER BY io.heap_blks_read + io.idx_blks_read DESC,
         io.schemaname,
         io.relname;

-- 10. Review index definitions and use on the workload tables. Look for indexes
-- supporting person/business entity, customer, product, and join keys. An idx_scan
-- value of zero after pg_stat_reset(), or a zero delta, means it was not chosen.
WITH target_tables(schemaname, relname) AS (
    VALUES ('person', 'person'),
           ('sales', 'customer'),
           ('sales', 'store'),
           ('humanresources', 'employee'),
           ('person', 'businessentityaddress'),
           ('sales', 'salesorderheader'),
           ('purchasing', 'purchaseorderheader'),
           ('purchasing', 'purchaseorderdetail'),
           ('sales', 'salesorderdetail'),
           ('sales', 'creditcard'),
           ('production', 'product')
)
SELECT indexes.schemaname,
       indexes.relname,
       indexes.indexrelname AS index_name,
       indexes.idx_scan,
       indexes.idx_tup_read,
       indexes.idx_tup_fetch,
       pg_size_pretty(pg_relation_size(indexes.indexrelid)) AS index_size,
       pg_get_indexdef(indexes.indexrelid) AS index_definition
FROM pg_stat_user_indexes AS indexes
JOIN target_tables AS target
  ON target.schemaname = indexes.schemaname
 AND target.relname = indexes.relname
ORDER BY indexes.schemaname,
         indexes.relname,
         indexes.idx_scan DESC,
         indexes.indexrelname;

-- 11. Review database-wide totals. Temp bytes/files indicate spills, deadlocks
-- indicate concurrency failures, and block timing helps quantify storage latency.
-- With the reset option enabled, stats_reset should mark the start of this run.
SELECT datname,
       stats_reset,
       xact_commit,
       xact_rollback,
       blks_read,
       blks_hit,
       round(
           100.0 * blks_hit / NULLIF(blks_hit + blks_read, 0),
           2
       ) AS database_cache_hit_pct,
       temp_files,
       pg_size_pretty(temp_bytes) AS temp_size,
       deadlocks,
       conflicts,
       round(blk_read_time::numeric, 2) AS block_read_ms,
       round(blk_write_time::numeric, 2) AS block_write_ms
FROM pg_stat_database
WHERE datname = current_database();

-- 12. PostgreSQL 16 and later: review server I/O operations for client backends.
-- Look for relation reads, temporary relation reads/writes, evictions, and fsyncs.
-- The reset option clears this cluster-wide view; concurrent databases can still
-- contribute, so use the fallback delta when strict workload isolation is needed.
SELECT backend_type,
       object,
       context,
       reads,
       writes,
       writebacks,
       extends,
       hits,
       evictions,
       reuses,
       fsyncs
FROM pg_stat_io
WHERE backend_type = 'client backend'
  AND object IN ('relation', 'temp relation')
ORDER BY object,
         context;

/*
    No-reset fallback
    -----------------
    Temporary tables exist only in the session that creates them. Run section 13
    before starting pgbench and leave this session connected. Run pgbench from a
    different session, then execute sections 14 through 19 here. Do not reconnect.

    Deltas isolate time, not workload identity. Other activity against the same
    database contributes to database/relation deltas, and pg_stat_io remains
    cluster-wide. Keep unrelated activity low or account for it separately.

    Run these statements in autocommit mode, not inside one long transaction.
*/

  -- 13a. Remove an older baseline from this session before taking a new one.
  -- Do not run this section after the workload or the original baseline will be lost.
DROP TABLE IF EXISTS execution_plan_reset_before,
                     execution_plan_statements_before,
                     execution_plan_database_before,
                     execution_plan_tables_before,
                     execution_plan_indexes_before,
                     execution_plan_table_io_before,
                     execution_plan_cluster_io_before;

-- 13b. Refresh the statistics snapshot, then capture reset markers. Section 14
-- compares them after the workload; any changed marker invalidates its deltas.
SELECT pg_stat_clear_snapshot();

CREATE TEMP TABLE execution_plan_reset_before
ON COMMIT PRESERVE ROWS
AS
SELECT database_stats.stats_reset AS database_stats_reset,
       statement_stats.stats_reset AS statement_stats_reset,
  statement_stats.dealloc AS statement_dealloc,
       io_stats.oldest_reset AS io_oldest_reset,
       io_stats.newest_reset AS io_newest_reset,
       clock_timestamp() AS captured_at
FROM pg_stat_database AS database_stats
CROSS JOIN pg_stat_statements_info AS statement_stats
CROSS JOIN (
    SELECT min(stats_reset) AS oldest_reset,
           max(stats_reset) AS newest_reset
    FROM pg_stat_io
) AS io_stats
WHERE database_stats.datname = current_database();

-- 13c. Capture statement counters. This supports deltas when permission to call
-- pg_stat_statements_reset() is unavailable. New queryids will use a zero baseline.
CREATE TEMP TABLE execution_plan_statements_before
ON COMMIT PRESERVE ROWS
AS
SELECT userid,
       dbid,
       toplevel,
       queryid,
       calls,
       plans,
       total_plan_time,
       total_exec_time,
       rows,
       shared_blks_hit,
       shared_blks_read,
       temp_blks_read,
       temp_blks_written,
       wal_bytes,
       query
FROM pg_stat_statements
WHERE dbid = (SELECT oid
              FROM pg_database
              WHERE datname = current_database())
  AND query NOT ILIKE '%pg_stat%'
  AND (query ILIKE '%person.person%'
       OR query ILIKE '%humanresources.employee%'
       OR query ILIKE '%sales.customer%'
       OR query ILIKE '%purchasing.purchaseorderheader%'
       OR query ILIKE '%sales.creditcard%'
       OR query ILIKE '%production.product%');

-- 13d. Capture current-database counters. The after-minus-before values show only
-- the interval, provided the database reset marker does not change.
CREATE TEMP TABLE execution_plan_database_before
ON COMMIT PRESERVE ROWS
AS
SELECT datid,
       xact_commit,
       xact_rollback,
       blks_read,
       blks_hit,
       temp_files,
       temp_bytes,
       deadlocks,
       conflicts,
       blk_read_time,
       blk_write_time
FROM pg_stat_database
WHERE datname = current_database();

-- 13e. Capture table scan counters for only the relations used by workload 6.
CREATE TEMP TABLE execution_plan_tables_before
ON COMMIT PRESERVE ROWS
AS
WITH target_tables(schemaname, relname) AS (
    VALUES ('person', 'person'),
           ('sales', 'customer'),
           ('sales', 'store'),
           ('humanresources', 'employee'),
           ('person', 'businessentityaddress'),
           ('sales', 'salesorderheader'),
           ('purchasing', 'purchaseorderheader'),
           ('purchasing', 'purchaseorderdetail'),
           ('sales', 'salesorderdetail'),
           ('sales', 'creditcard'),
           ('production', 'product')
)
SELECT stats.relid,
       stats.schemaname,
       stats.relname,
       stats.seq_scan,
       stats.seq_tup_read,
       stats.idx_scan,
       stats.idx_tup_fetch
FROM pg_stat_user_tables AS stats
JOIN target_tables AS target
  ON target.schemaname = stats.schemaname
 AND target.relname = stats.relname;

-- 13f. Capture index usage counters for indexes on the workload relations.
CREATE TEMP TABLE execution_plan_indexes_before
ON COMMIT PRESERVE ROWS
AS
SELECT indexes.indexrelid,
       indexes.schemaname,
       indexes.relname,
       indexes.indexrelname,
       indexes.idx_scan,
       indexes.idx_tup_read,
       indexes.idx_tup_fetch
FROM pg_stat_user_indexes AS indexes
JOIN execution_plan_tables_before AS target
  ON target.relid = indexes.relid;

-- 13g. Capture heap, index, and TOAST block counters for workload relations.
CREATE TEMP TABLE execution_plan_table_io_before
ON COMMIT PRESERVE ROWS
AS
SELECT io.relid,
       io.schemaname,
       io.relname,
       io.heap_blks_read,
       io.heap_blks_hit,
       io.idx_blks_read,
       io.idx_blks_hit,
       io.toast_blks_read,
       io.toast_blks_hit,
       io.tidx_blks_read,
       io.tidx_blks_hit
FROM pg_statio_user_tables AS io
JOIN execution_plan_tables_before AS target
  ON target.relid = io.relid;

-- 13h. Capture cluster I/O counters. This baseline includes all databases because
-- pg_stat_io does not expose a database identifier.
CREATE TEMP TABLE execution_plan_cluster_io_before
ON COMMIT PRESERVE ROWS
AS
SELECT backend_type,
       object,
       context,
       reads,
       writes,
       writebacks,
       extends,
       hits,
       evictions,
       reuses,
       fsyncs
FROM pg_stat_io;

-- 14a. Refresh the session's cached snapshot immediately after the workload.
SELECT pg_stat_clear_snapshot();

-- 14b. Validate the baseline before trusting any delta. Every value should be true.
-- False means a collector was reset, or tracked statements were deallocated,
-- during the test. Recapture the baseline and rerun before trusting the deltas.
SELECT before.captured_at,
       clock_timestamp() AS compared_at,
     before.database_stats_reset IS NOT DISTINCT FROM database_stats.stats_reset
           AS database_counters_valid,
     before.statement_stats_reset IS NOT DISTINCT FROM statement_stats.stats_reset
           AS statement_counters_valid,
     before.statement_dealloc = statement_stats.dealloc
       AS no_statement_deallocation,
     before.io_oldest_reset IS NOT DISTINCT FROM io_stats.oldest_reset
       AND before.io_newest_reset IS NOT DISTINCT FROM io_stats.newest_reset
           AS io_counters_valid
FROM execution_plan_reset_before AS before
CROSS JOIN pg_stat_statements_info AS statement_stats
CROSS JOIN (
    SELECT min(stats_reset) AS oldest_reset,
           max(stats_reset) AS newest_reset
    FROM pg_stat_io
) AS io_stats
JOIN pg_stat_database AS database_stats
  ON database_stats.datname = current_database();

-- 15. Calculate statement deltas. Sort first by interval execution time; compare
-- calls, mean time, rows, physical reads, temp writes, and WAL for each queryid.
WITH current_stats AS (
    SELECT *
    FROM pg_stat_statements
    WHERE dbid = (SELECT oid
                  FROM pg_database
                  WHERE datname = current_database())
      AND query NOT ILIKE '%pg_stat%'
      AND (query ILIKE '%person.person%'
           OR query ILIKE '%humanresources.employee%'
           OR query ILIKE '%sales.customer%'
           OR query ILIKE '%purchasing.purchaseorderheader%'
           OR query ILIKE '%sales.creditcard%'
           OR query ILIKE '%production.product%')
)
SELECT COALESCE(after.queryid, before.queryid) AS queryid,
       COALESCE(after.calls, 0) - COALESCE(before.calls, 0) AS calls_delta,
       round((COALESCE(after.total_exec_time, 0)
              - COALESCE(before.total_exec_time, 0))::numeric, 2)
           AS total_exec_ms_delta,
       round(((COALESCE(after.total_exec_time, 0)
               - COALESCE(before.total_exec_time, 0)) /
              NULLIF(COALESCE(after.calls, 0)
                     - COALESCE(before.calls, 0), 0))::numeric, 2)
           AS mean_exec_ms_delta,
       COALESCE(after.rows, 0) - COALESCE(before.rows, 0) AS rows_delta,
       COALESCE(after.shared_blks_hit, 0) - COALESCE(before.shared_blks_hit, 0)
           AS shared_hits_delta,
       COALESCE(after.shared_blks_read, 0) - COALESCE(before.shared_blks_read, 0)
           AS shared_reads_delta,
       COALESCE(after.temp_blks_written, 0) - COALESCE(before.temp_blks_written, 0)
           AS temp_writes_delta,
       COALESCE(after.wal_bytes, 0) - COALESCE(before.wal_bytes, 0)
           AS wal_bytes_delta,
       COALESCE(after.query, before.query) AS query
FROM current_stats AS after
FULL JOIN execution_plan_statements_before AS before
  ON before.userid = after.userid
 AND before.dbid = after.dbid
 AND before.toplevel = after.toplevel
 AND before.queryid = after.queryid
WHERE COALESCE(after.calls, 0) - COALESCE(before.calls, 0) <> 0
ORDER BY total_exec_ms_delta DESC;

-- 16. Calculate current-database deltas. Focus on physical reads, temp bytes/files,
-- block I/O time, rollbacks, and deadlocks added during the workload interval.
SELECT after.xact_commit - before.xact_commit AS commits_delta,
       after.xact_rollback - before.xact_rollback AS rollbacks_delta,
       after.blks_read - before.blks_read AS blocks_read_delta,
       after.blks_hit - before.blks_hit AS blocks_hit_delta,
       after.temp_files - before.temp_files AS temp_files_delta,
       pg_size_pretty(after.temp_bytes - before.temp_bytes) AS temp_size_delta,
       after.deadlocks - before.deadlocks AS deadlocks_delta,
       after.conflicts - before.conflicts AS conflicts_delta,
       round((after.blk_read_time - before.blk_read_time)::numeric, 2)
           AS block_read_ms_delta,
       round((after.blk_write_time - before.blk_write_time)::numeric, 2)
           AS block_write_ms_delta
FROM pg_stat_database AS after
JOIN execution_plan_database_before AS before
  ON before.datid = after.datid
WHERE after.datname = current_database();

-- 17. Calculate table-access deltas. Large sequential tuple reads with few index
-- fetches identify relations whose workload plans favored broad scans.
SELECT after.schemaname,
       after.relname,
       after.seq_scan - before.seq_scan AS seq_scan_delta,
       after.seq_tup_read - before.seq_tup_read AS seq_tup_read_delta,
       after.idx_scan - before.idx_scan AS idx_scan_delta,
       after.idx_tup_fetch - before.idx_tup_fetch AS idx_tup_fetch_delta
FROM pg_stat_user_tables AS after
JOIN execution_plan_tables_before AS before
  ON before.relid = after.relid
ORDER BY seq_tup_read_delta DESC,
         after.schemaname,
         after.relname;

-- 18. Calculate index deltas. Zero scans mean an index was not selected during
-- the interval; high tuples read versus fetched can indicate extra index filtering.
SELECT after.schemaname,
       after.relname,
       after.indexrelname AS index_name,
       after.idx_scan - before.idx_scan AS idx_scan_delta,
       after.idx_tup_read - before.idx_tup_read AS idx_tup_read_delta,
       after.idx_tup_fetch - before.idx_tup_fetch AS idx_tup_fetch_delta,
       pg_get_indexdef(after.indexrelid) AS index_definition
FROM pg_stat_user_indexes AS after
JOIN execution_plan_indexes_before AS before
  ON before.indexrelid = after.indexrelid
ORDER BY idx_scan_delta DESC,
         after.schemaname,
         after.relname,
         after.indexrelname;

-- 19a. Calculate table-I/O deltas. Physical heap/index reads show storage demand;
-- hit deltas show buffer-cache reuse during the workload interval.
SELECT after.schemaname,
       after.relname,
       after.heap_blks_read - before.heap_blks_read AS heap_reads_delta,
       after.heap_blks_hit - before.heap_blks_hit AS heap_hits_delta,
       after.idx_blks_read - before.idx_blks_read AS index_reads_delta,
       after.idx_blks_hit - before.idx_blks_hit AS index_hits_delta,
       after.toast_blks_read - before.toast_blks_read AS toast_reads_delta,
       after.toast_blks_hit - before.toast_blks_hit AS toast_hits_delta,
       after.tidx_blks_read - before.tidx_blks_read AS toast_index_reads_delta,
       after.tidx_blks_hit - before.tidx_blks_hit AS toast_index_hits_delta
FROM pg_statio_user_tables AS after
JOIN execution_plan_table_io_before AS before
  ON before.relid = after.relid
 ORDER BY (after.heap_blks_read - before.heap_blks_read) + (after.idx_blks_read - before.idx_blks_read) DESC,
        -- heap_reads_delta + index_reads_delta DESC,
         after.schemaname,
         after.relname;

-- 19b. Calculate cluster-I/O deltas. These values include concurrent work from
-- every database; focus on client-backend relation and temporary-relation rows.
SELECT after.backend_type,
       after.object,
       after.context,
       after.reads - before.reads AS reads_delta,
       after.writes - before.writes AS writes_delta,
       after.writebacks - before.writebacks AS writebacks_delta,
       COALESCE(after.extends, 0) - COALESCE(before.extends, 0) AS extends_delta,
       after.hits - before.hits AS hits_delta,
       after.evictions - before.evictions AS evictions_delta,
       after.reuses - before.reuses AS reuses_delta,
       COALESCE(after.fsyncs, 0) - COALESCE(before.fsyncs, 0) AS fsyncs_delta
FROM pg_stat_io AS after
JOIN execution_plan_cluster_io_before AS before
  ON before.backend_type = after.backend_type
 AND before.object = after.object
 AND before.context = after.context
WHERE after.backend_type = 'client backend'
  AND after.object IN ('relation', 'temp relation')
ORDER BY after.object,
         after.context;
