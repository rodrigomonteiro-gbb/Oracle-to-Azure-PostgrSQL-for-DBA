/*
    DBA review for workload 9: PostgreSQL temporary-table processing

    Target workload
    ---------------
    Generate-PGSQL-Workload.ps1 launches Stress_TempDB.sql with an application
    name beginning with PGBench. Each transaction creates, populates, reads, and
    drops the session-local temporary table sales_report.

    PostgreSQL terminology
    -----------------------
    PostgreSQL has no separate tempdb database. Explicit temporary tables use
    session-local schemas and temp buffers. pg_stat_io reports temporary-relation
    I/O, while pg_stat_database.temp_bytes and pg_stat_statements.temp_blks_* mainly
    describe temporary files created by operations such as sorts and hashes. These
    counters measure different forms of temporary processing and can legitimately
    remain zero when the workload fits in memory.

    Requirements and scope
    ----------------------
    - PostgreSQL 16 or later is required for pg_stat_io.
    - pg_stat_statements must be installed and loaded for sections 7, 11, and 13.
    - track_io_timing should be on for meaningful I/O timing columns.
    - A role with pg_monitor or pg_read_all_stats provides the best visibility.
    - Live session queries use application_name LIKE 'PGBench%'. Run other pgbench
      workloads separately when workload-9-only results are required.
    - Database statistics include all work in the current database. pg_stat_io is
      cluster-wide and cannot be filtered by database or application name.

    Suggested workflow
    ------------------
    With Reset PGSTATS enabled:
    - Run sections 1 and 2 to verify configuration and reset times.
    - Run sections 3 through 6 while the workload is active.
    - Run sections 7 through 10 during or after the workload.

    Without reset privileges:
    - Run section 11 before the workload and keep this DBA session connected.
    - Run sections 12 through 16 after the workload in the same DBA session.
*/

\pset pager off
\timing on

-- 1. Verify server identity, monitoring privileges, extension availability, and
-- settings that influence temporary processing. temp_buffers is allocated per
-- session as needed; work_mem applies per sort or hash operation.
SELECT current_database() AS database_name,
       current_user AS monitoring_role,
       current_setting('server_version') AS server_version,
       current_setting('temp_buffers') AS temp_buffers,
       current_setting('work_mem') AS work_mem,
       current_setting('hash_mem_multiplier') AS hash_mem_multiplier,
       current_setting('temp_file_limit') AS temp_file_limit,
       current_setting('log_temp_files') AS log_temp_files,
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

-- 2. Check reset times before interpreting cumulative counters. When the launcher's
-- reset option was selected, these should be immediately before the workload.
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

-- 3. Inspect active pgbench sessions. Temporary tables are private to their owning
-- sessions, but activity, transaction age, waits, and blockers are cluster-visible.
SELECT pid,
       usename,
       application_name,
       client_addr,
       state,
       wait_event_type,
       wait_event,
       clock_timestamp() - backend_start AS backend_age,
       clock_timestamp() - xact_start AS transaction_age,
       clock_timestamp() - query_start AS query_age,
       pg_blocking_pids(pid) AS blocking_pids,
       left(query, 1000) AS current_or_last_query
FROM pg_stat_activity
WHERE datname = current_database()
  AND application_name LIKE 'PGBench%'
ORDER BY query_start NULLS LAST,
         pid;

-- 4. Summarize pgbench states and waits. IO/DataFileRead or DataFileWrite can show
-- storage pressure. Lock waits or long idle-in-transaction states are unexpected.
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

-- 5. Show blocked pgbench sessions and their blockers. Catalog or relation lock
-- contention can become visible when many sessions repeatedly create/drop objects.
SELECT blocked.pid AS blocked_pid,
       blocked.application_name AS blocked_application,
       blocked.wait_event_type,
       blocked.wait_event,
       clock_timestamp() - blocked.query_start AS blocked_duration,
       blocker.pid AS blocker_pid,
       blocker.application_name AS blocker_application,
       blocker.state AS blocker_state,
       clock_timestamp() - blocker.xact_start AS blocker_transaction_age,
       left(blocked.query, 1000) AS blocked_query,
       left(blocker.query, 1000) AS blocker_query
FROM pg_stat_activity AS blocked
CROSS JOIN LATERAL unnest(pg_blocking_pids(blocked.pid)) AS blockers(blocker_pid)
JOIN pg_stat_activity AS blocker
  ON blocker.pid = blockers.blocker_pid
WHERE blocked.datname = current_database()
  AND blocked.application_name LIKE 'PGBench%'
ORDER BY blocked_duration DESC;

-- 6. Inventory currently visible temporary relations. This is a point-in-time,
-- cluster-wide catalog view and can change rapidly as transactions commit.
SELECT namespace.nspname AS temp_schema,
       relation.relkind,
       count(*) AS relation_count
FROM pg_class AS relation
JOIN pg_namespace AS namespace
  ON namespace.oid = relation.relnamespace
WHERE relation.relpersistence = 't'
GROUP BY namespace.nspname,
         relation.relkind
ORDER BY namespace.nspname,
         relation.relkind;

-- 7. Rank captured workload statements. temp_blks_* represent executor temporary
-- files such as sort/hash spills, not all blocks belonging to explicit temp tables.
SELECT queryid,
       calls,
       rows,
       round(total_exec_time::numeric, 2) AS total_exec_ms,
       round(mean_exec_time::numeric, 2) AS mean_exec_ms,
       round(max_exec_time::numeric, 2) AS max_exec_ms,
       shared_blks_hit,
       shared_blks_read,
       shared_blks_dirtied,
       shared_blks_written,
       temp_blks_read,
       temp_blks_written,
       round(temp_blk_read_time::numeric, 2) AS temp_read_ms,
       round(temp_blk_write_time::numeric, 2) AS temp_write_ms,
       pg_size_pretty(wal_bytes::bigint) AS wal_size,
       left(query, 2000) AS query
FROM pg_stat_statements
WHERE dbid = (
          SELECT oid
          FROM pg_database
          WHERE datname = current_database()
      )
  AND query NOT ILIKE '%pg_stat_statements%'
  AND (
      query ILIKE '%sales_report%'
      OR query ILIKE '%sales.salesorderheader%'
      OR query ILIKE '%sales.salesorderdetail%'
      OR query ILIKE '%production.product%'
  )
ORDER BY total_exec_time DESC
LIMIT 50;

-- 8. Review source-table access. These counters are cumulative since stats_reset;
-- use section 15 for interval deltas when reset is unavailable.
WITH target_tables(schemaname, relname) AS (
    VALUES ('sales', 'salesorderheader'),
           ('sales', 'salesorderdetail'),
           ('production', 'product')
)
SELECT stats.schemaname,
       stats.relname,
       stats.seq_scan,
       stats.seq_tup_read,
       stats.idx_scan,
       stats.idx_tup_fetch,
       stats.n_live_tup,
       stats.last_analyze,
       stats.last_autoanalyze
FROM pg_stat_user_tables AS stats
JOIN target_tables AS target
  ON target.schemaname = stats.schemaname
 AND target.relname = stats.relname
ORDER BY stats.schemaname,
         stats.relname;

-- 9. Review database-wide temporary-file and transaction totals. temp_files and
-- temp_bytes do not measure every explicit temporary-table block operation.
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
       temp_bytes,
       pg_size_pretty(temp_bytes) AS temp_size,
       deadlocks,
       round(blk_read_time::numeric, 2) AS block_read_ms,
       round(blk_write_time::numeric, 2) AS block_write_ms,
       clock_timestamp() AS observed_at
FROM pg_stat_database
WHERE datname = current_database();

-- 10. Review PostgreSQL 16+ I/O counters. The temp relation row is the closest
-- cumulative server metric for explicit temporary-table relation I/O.
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
       fsyncs,
       stats_reset
FROM pg_stat_io
WHERE backend_type = 'client backend'
  AND object IN ('relation', 'temp relation')
ORDER BY object,
         context;

/*
    No-reset baseline
    -----------------
    Run all of section 11 before starting pgbench. Keep this DBA session open and
    execute sections 12 through 16 afterward. Run in autocommit mode.
*/

-- 11a. Remove a prior baseline from this DBA session.
DROP TABLE IF EXISTS tempdb_review_reset_before,
                     tempdb_review_statements_before,
                     tempdb_review_database_before,
                     tempdb_review_tables_before,
                     tempdb_review_io_before;

-- 11b. Capture reset markers so section 12 can detect invalid deltas.
SELECT pg_stat_clear_snapshot();

CREATE TEMP TABLE tempdb_review_reset_before
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

-- 11c. Capture matching statement counters.
CREATE TEMP TABLE tempdb_review_statements_before
ON COMMIT PRESERVE ROWS
AS
SELECT userid,
       dbid,
       toplevel,
       queryid,
       calls,
       total_exec_time,
       rows,
       shared_blks_hit,
       shared_blks_read,
       temp_blks_read,
       temp_blks_written,
       temp_blk_read_time,
       temp_blk_write_time,
       wal_bytes,
       query
FROM pg_stat_statements
WHERE dbid = (
          SELECT oid
          FROM pg_database
          WHERE datname = current_database()
      )
  AND query NOT ILIKE '%pg_stat_statements%'
  AND (
      query ILIKE '%sales_report%'
      OR query ILIKE '%sales.salesorderheader%'
      OR query ILIKE '%sales.salesorderdetail%'
      OR query ILIKE '%production.product%'
  );

-- 11d. Capture current-database counters.
CREATE TEMP TABLE tempdb_review_database_before
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
       blk_read_time,
       blk_write_time
FROM pg_stat_database
WHERE datname = current_database();

-- 11e. Capture source-table counters.
CREATE TEMP TABLE tempdb_review_tables_before
ON COMMIT PRESERVE ROWS
AS
WITH target_tables(schemaname, relname) AS (
    VALUES ('sales', 'salesorderheader'),
           ('sales', 'salesorderdetail'),
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

-- 11f. Capture cluster-wide I/O counters.
CREATE TEMP TABLE tempdb_review_io_before
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

-- 12. Refresh statistics and validate the baseline. Every validity value should
-- be true before interpreting sections 13 through 16.
SELECT pg_stat_clear_snapshot();

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
FROM tempdb_review_reset_before AS before
CROSS JOIN pg_stat_statements_info AS statement_stats
CROSS JOIN (
    SELECT min(stats_reset) AS oldest_reset,
           max(stats_reset) AS newest_reset
    FROM pg_stat_io
) AS io_stats
JOIN pg_stat_database AS database_stats
  ON database_stats.datname = current_database();

-- 13. Calculate statement deltas for the measurement interval.
WITH current_stats AS (
    SELECT *
    FROM pg_stat_statements
    WHERE dbid = (
              SELECT oid
              FROM pg_database
              WHERE datname = current_database()
          )
      AND query NOT ILIKE '%pg_stat_statements%'
      AND (
          query ILIKE '%sales_report%'
          OR query ILIKE '%sales.salesorderheader%'
          OR query ILIKE '%sales.salesorderdetail%'
          OR query ILIKE '%production.product%'
      )
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
       COALESCE(after.shared_blks_read, 0) - COALESCE(before.shared_blks_read, 0)
           AS shared_reads_delta,
       COALESCE(after.temp_blks_read, 0) - COALESCE(before.temp_blks_read, 0)
           AS temp_reads_delta,
       COALESCE(after.temp_blks_written, 0) - COALESCE(before.temp_blks_written, 0)
           AS temp_writes_delta,
       round((COALESCE(after.temp_blk_read_time, 0)
              - COALESCE(before.temp_blk_read_time, 0))::numeric, 2)
           AS temp_read_ms_delta,
       round((COALESCE(after.temp_blk_write_time, 0)
              - COALESCE(before.temp_blk_write_time, 0))::numeric, 2)
           AS temp_write_ms_delta,
       COALESCE(after.wal_bytes, 0) - COALESCE(before.wal_bytes, 0)
           AS wal_bytes_delta,
       COALESCE(after.query, before.query) AS query
FROM current_stats AS after
FULL JOIN tempdb_review_statements_before AS before
  ON before.userid = after.userid
 AND before.dbid = after.dbid
 AND before.toplevel = after.toplevel
 AND before.queryid = after.queryid
WHERE COALESCE(after.calls, 0) - COALESCE(before.calls, 0) <> 0
ORDER BY total_exec_ms_delta DESC;

-- 14. Calculate current-database deltas. Other sessions in this database contribute
-- to these values, so keep unrelated activity low during a controlled test.
SELECT after.xact_commit - before.xact_commit AS commits_delta,
       after.xact_rollback - before.xact_rollback AS rollbacks_delta,
       after.blks_read - before.blks_read AS blocks_read_delta,
       after.blks_hit - before.blks_hit AS blocks_hit_delta,
       after.temp_files - before.temp_files AS temp_files_delta,
       after.temp_bytes - before.temp_bytes AS temp_bytes_delta,
       pg_size_pretty(after.temp_bytes - before.temp_bytes) AS temp_size_delta,
       after.deadlocks - before.deadlocks AS deadlocks_delta,
       round((after.blk_read_time - before.blk_read_time)::numeric, 2)
           AS block_read_ms_delta,
       round((after.blk_write_time - before.blk_write_time)::numeric, 2)
           AS block_write_ms_delta
FROM pg_stat_database AS after
JOIN tempdb_review_database_before AS before
  ON before.datid = after.datid
WHERE after.datname = current_database();

-- 15. Calculate source-table scan deltas.
SELECT after.schemaname,
       after.relname,
       after.seq_scan - before.seq_scan AS seq_scan_delta,
       after.seq_tup_read - before.seq_tup_read AS seq_tup_read_delta,
       after.idx_scan - before.idx_scan AS idx_scan_delta,
       after.idx_tup_fetch - before.idx_tup_fetch AS idx_tup_fetch_delta
FROM pg_stat_user_tables AS after
JOIN tempdb_review_tables_before AS before
  ON before.relid = after.relid
ORDER BY seq_tup_read_delta DESC,
         after.schemaname,
         after.relname;

-- 16. Calculate cluster-wide I/O deltas. Focus on client backend/temp relation.
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
       after.fsyncs - before.fsyncs AS fsyncs_delta
FROM pg_stat_io AS after
JOIN tempdb_review_io_before AS before
  ON before.backend_type = after.backend_type
 AND before.object = after.object
 AND before.context = after.context
WHERE after.backend_type = 'client backend'
  AND after.object IN ('relation', 'temp relation')
ORDER BY after.object,
         after.context;
