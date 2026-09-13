/*
    DBA review for workload 8: intentional errors

    Target application
    ------------------
    Generate-PGSQL-Workload.ps1 launches AdventureWorks_Errors.sql with:
      application_name = 'PGBench_Errors'

    The workload randomly generates and catches these PostgreSQL errors:
      42P01 - undefined_table
      42883 - undefined_function
      22012 - division_by_zero
      22P02 - invalid_text_representation
      23502 - not_null_violation
      23503 - foreign_key_violation
      23505 - unique_violation
      22007 - invalid_datetime_format

    Each iteration updates three tables, waits 1 through 5 seconds, and raises an
    error inside a PL/pgSQL exception subtransaction. Catching the error rolls back
    those test updates, allows pgbench to continue for its configured duration,
    and records the SQLSTATE in public.pgbench_error_log.

    Important limitation
    --------------------
    PostgreSQL statistics views do not retain a statement-error history or the
    SQLSTATE for each failed query. This demonstration therefore records caught
    errors in public.pgbench_error_log. PostgreSQL/Azure logs remain authoritative
    for uncaught production errors and server-side context.

    Suggested workflow
    ------------------
    - Run sections 1 and 2 before the workload.
    - Keep the same DBA session open if using the rollback baseline in section 2.
    - Run sections 3 through 5 while PGBench_Errors is active.
    - Run sections 6 through 9 after or during the workload.
    - Run section 8 in the same session after the workload for rollback deltas.
*/

\pset pager off
\timing on

-- 1. Verify database identity, monitoring privileges, statistics reset time, and
-- logging settings. log_min_error_statement = error or lower records the failing
-- SQL text. log_error_verbosity controls detail included with each server error.
SELECT current_database() AS database_name,
       current_user AS monitoring_role,
       current_setting('server_version') AS server_version,
       current_setting('log_min_messages') AS log_min_messages,
       current_setting('log_min_error_statement') AS log_min_error_statement,
       current_setting('log_error_verbosity') AS log_error_verbosity,
       current_setting('log_destination') AS log_destination,
       current_setting('logging_collector') AS logging_collector,
       pg_has_role(current_user, 'pg_monitor', 'MEMBER') AS is_pg_monitor,
       pg_has_role(current_user, 'pg_read_all_stats', 'MEMBER')
           AS can_read_all_stats,
       database_stats.stats_reset,
       clock_timestamp() AS observed_at
FROM pg_stat_database AS database_stats
WHERE database_stats.datname = current_database();

-- 2. Capture a rollback baseline before starting workload 8. This temporary table
-- belongs to the current DBA session, so keep this session open through section 8.
DROP TABLE IF EXISTS pg_temp.error_workload_baseline;

CREATE TEMP TABLE error_workload_baseline AS
SELECT datid,
       datname,
       xact_commit,
       xact_rollback,
       sessions,
       sessions_abandoned,
       sessions_fatal,
       sessions_killed,
       stats_reset,
       clock_timestamp() AS captured_at
FROM pg_stat_database
WHERE datname = current_database();

SELECT *
FROM error_workload_baseline;

-- 3. Inspect workload sessions while pgbench is running. Most sessions should be
-- waiting in pg_sleep or briefly executing the function and its updates.
SELECT pid,
       usename,
       client_addr,
       client_port,
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

-- 4. Summarize workload session states and waits. Timeout/PgSleep waits are expected.
-- Sessions should not remain idle in transaction or idle in transaction (aborted).
SELECT state,
       COALESCE(wait_event_type, 'CPU or runnable') AS wait_type,
       COALESCE(wait_event, 'none') AS wait_event,
       count(*) AS sessions,
       max(clock_timestamp() - state_change) AS longest_state_age
FROM pg_stat_activity
WHERE datname = current_database()
  AND application_name LIKE 'PGBench%'
GROUP BY state,
         COALESCE(wait_event_type, 'CPU or runnable'),
         COALESCE(wait_event, 'none')
ORDER BY sessions DESC,
         state,
         wait_type;

-- 5. Flag unhealthy error-workload sessions. Query ages up to about five seconds
-- are expected because of pg_sleep; longer queries, open failed transactions, or
-- blockers indicate an issue outside the intended demonstration behavior.
SELECT pid,
       usename,
       state,
       wait_event_type,
       wait_event,
       clock_timestamp() - xact_start AS transaction_age,
       clock_timestamp() - query_start AS query_age,
       clock_timestamp() - state_change AS state_age,
       pg_blocking_pids(pid) AS blocking_pids,
       left(query, 1000) AS current_or_last_query
FROM pg_stat_activity
WHERE datname = current_database()
  AND application_name LIKE 'PGBench%'
  AND (
      state = 'idle in transaction (aborted)'
      OR cardinality(pg_blocking_pids(pid)) > 0
      OR clock_timestamp() - query_start > interval '5 seconds'
  )
ORDER BY query_start NULLS LAST;

-- 6. Review current database transaction outcomes. Caught PL/pgSQL subtransaction
-- errors do not necessarily increase xact_rollback because the outer transaction
-- commits. Use sections 8 and 9 for authoritative counts from this workload.
SELECT datname,
       xact_commit,
       xact_rollback,
       round(
           100.0 * xact_rollback /
           NULLIF(xact_commit + xact_rollback, 0),
           2
       ) AS rollback_pct,
       sessions,
       sessions_abandoned,
       sessions_fatal,
       sessions_killed,
       stats_reset,
       clock_timestamp() AS observed_at
FROM pg_stat_database
WHERE datname = current_database();

-- 7. Show any captured context from the target statements. Failed statements may
-- be absent from pg_stat_statements; absence is expected and is not evidence that
-- no errors occurred. Server/Azure logs remain authoritative for error history.
SELECT queryid,
       calls,
       rows,
       round(total_exec_time::numeric, 2) AS total_exec_ms,
       round(mean_exec_time::numeric, 2) AS mean_exec_ms,
       left(query, 1000) AS query
FROM pg_stat_statements
WHERE dbid = (
          SELECT oid
          FROM pg_database
          WHERE datname = current_database()
      )
  AND (
      query ILIKE '%nonexistent_error_demo_table%'
      OR query ILIKE '%nonexistent_error_demo_function%'
      OR query ILIKE '%not-an-integer%'
  )
  AND query NOT ILIKE '%pg_stat_statements%'
ORDER BY total_exec_time DESC;

-- 8. Calculate changes since section 2. Caught workload errors can coexist with a
-- zero rollback_delta because pgbench commits after the function handles the error.
-- If stats_reset changed, the baseline is invalid and the deltas are suppressed.
SELECT current_stats.datname,
       baseline.captured_at AS baseline_captured_at,
       clock_timestamp() AS observed_at,
       baseline.stats_reset AS baseline_stats_reset,
       current_stats.stats_reset AS current_stats_reset,
       baseline.stats_reset IS NOT DISTINCT FROM current_stats.stats_reset
           AS baseline_is_valid,
       CASE
           WHEN baseline.stats_reset IS NOT DISTINCT FROM current_stats.stats_reset
           THEN current_stats.xact_commit - baseline.xact_commit
       END AS commit_delta,
       CASE
           WHEN baseline.stats_reset IS NOT DISTINCT FROM current_stats.stats_reset
           THEN current_stats.xact_rollback - baseline.xact_rollback
       END AS rollback_delta,
       CASE
           WHEN baseline.stats_reset IS NOT DISTINCT FROM current_stats.stats_reset
           THEN current_stats.sessions - baseline.sessions
       END AS session_delta,
       CASE
           WHEN baseline.stats_reset IS NOT DISTINCT FROM current_stats.stats_reset
           THEN current_stats.sessions_abandoned - baseline.sessions_abandoned
       END AS abandoned_session_delta,
       CASE
           WHEN baseline.stats_reset IS NOT DISTINCT FROM current_stats.stats_reset
           THEN current_stats.sessions_fatal - baseline.sessions_fatal
       END AS fatal_session_delta,
       CASE
           WHEN baseline.stats_reset IS NOT DISTINCT FROM current_stats.stats_reset
           THEN current_stats.sessions_killed - baseline.sessions_killed
       END AS killed_session_delta
FROM error_workload_baseline AS baseline
JOIN pg_stat_database AS current_stats
  ON current_stats.datid = baseline.datid;

-- 9. Summarize errors captured by the workload function. This table is specific
-- to workload 8 and provides the SQLSTATE distribution unavailable from core views.
SELECT sqlstate,
       error_message,
       count(*) AS error_count,
       min(error_time) AS first_seen,
       max(error_time) AS last_seen,
       round(avg(delay_seconds)::numeric, 2) AS mean_delay_seconds,
       count(DISTINCT backend_pid) AS backend_count
FROM public.pgbench_error_log
WHERE application_name LIKE 'PGBench%'
GROUP BY sqlstate,
         error_message
ORDER BY error_count DESC,
         sqlstate;

-- 10. Show the most recent individual error events for timing and backend review.
SELECT error_time,
       backend_pid,
       error_type,
       sqlstate,
       error_message,
       delay_seconds
FROM public.pgbench_error_log
WHERE application_name LIKE 'PGBench%'
ORDER BY error_time DESC
LIMIT 100;

-- Authoritative error review outside SQL:
-- 1. In pgbench output, review warnings and transaction throughput. Errors are
--    caught intentionally, so pgbench counts these outer transactions as successful.
-- 2. In Azure Portal, enable PostgreSQLLogs diagnostic logs and query them in the
--    configured Log Analytics workspace. Filter by database/user/application when
--    those fields are available, then search for the SQLSTATE values above.
-- 3. On self-managed PostgreSQL, inspect the configured server log destination.
