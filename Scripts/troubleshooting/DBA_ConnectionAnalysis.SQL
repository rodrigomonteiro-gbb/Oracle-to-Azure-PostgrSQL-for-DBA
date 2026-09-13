/*
    DBA connection, process, and memory analysis

    Target workload
    ---------------
    Generate-PGSQL-Workload.ps1 launches Connection_test.sql with:
      application_name = 'PGBench_TestConnection'

    The workload executes SELECT 1 repeatedly. Its main diagnostic value is
    validating connection capacity, backend process behavior, wait states, and
    the overhead of concurrent user sessions rather than query complexity.

    Memory visibility
    -----------------
    PostgreSQL creates one backend process per direct client connection. Core
    statistics views expose backend PIDs and activity but not per-process RSS.
    pg_get_backend_memory_contexts() reports only the session executing it.
    Sections 10 and 11 provide summarized and complete views of that session's
    memory contexts. On Azure Database for PostgreSQL, cross-backend memory logging
    is restricted to the service-owned superuser and is unavailable to normal DBAs.

    For actual per-process RSS/private memory, correlate pg_stat_activity.pid with
    operating-system process tools. On managed Azure Database for PostgreSQL, use
    Azure Monitor memory/CPU metrics because host process tools are unavailable.

    Permissions
    -----------
    A role with pg_read_all_stats, pg_monitor, or equivalent privileges provides
    the most complete session/query visibility. Without it, query text and some
    details belonging to other users can be hidden.

    Suggested workflow
    ------------------
    - Run sections 1 through 3 before the workload for capacity and baseline state.
    - Run sections 4 through 9 while PGBench_TestConnection is active.
    - Run sections 10 through 14 during or after the workload for memory and
      cumulative resource context.
    - Run this script in the same database selected in the workload generator.
*/

\pset pager off
\timing on

-- 1. Verify server identity and monitoring privileges. Look for membership in
-- pg_monitor or pg_read_all_stats when cross-user query details are required.
SELECT current_database() AS database_name,
       current_user AS monitoring_role,
       current_setting('server_version') AS server_version,
       pg_has_role(current_user, 'pg_monitor', 'MEMBER') AS is_pg_monitor,
       pg_has_role(current_user, 'pg_read_all_stats', 'MEMBER')
           AS can_read_all_stats,
       pg_postmaster_start_time() AS server_started_at,
       clock_timestamp() AS observed_at;

-- 2. Review connection and memory settings. max_connections controls the backend
-- process ceiling. work_mem is per sort/hash operation, not per connection, and
-- hash operations can use work_mem multiplied by hash_mem_multiplier. temp_buffers
-- is a per-session ceiling once temporary tables are used. shared_buffers is shared
-- by the cluster and must not be multiplied by session count.
SELECT name,
       setting,
       unit,
       context,
       source,
       pending_restart
FROM pg_settings
WHERE name IN ('max_connections',
               'reserved_connections',
               'superuser_reserved_connections',
               'shared_buffers',
               'work_mem',
               'hash_mem_multiplier',
               'temp_buffers',
               'maintenance_work_mem',
               'max_worker_processes',
               'max_parallel_workers')
ORDER BY name;

-- 3. Measure cluster connection saturation. Pay attention to usable_connection_pct,
-- remaining_regular_slots, and reserved slots. Sustained usage above roughly 80%
-- leaves little room for traffic spikes, monitoring, and administrative access.
WITH limits AS (
    SELECT current_setting('max_connections')::integer AS max_connections,
           COALESCE(current_setting('reserved_connections', true), '0')::integer
               AS reserved_connections,
           current_setting('superuser_reserved_connections')::integer
               AS superuser_reserved_connections
), sessions AS (
    SELECT count(*) FILTER (WHERE backend_type = 'client backend') AS client_sessions,
           count(*) FILTER (
               WHERE backend_type = 'client backend'
                 AND state = 'active'
           ) AS active_sessions,
           count(*) FILTER (
               WHERE backend_type = 'client backend'
                 AND state = 'idle'
           ) AS idle_sessions,
           count(*) FILTER (
               WHERE backend_type = 'client backend'
                 AND state = 'idle in transaction'
           ) AS idle_in_transaction_sessions
    FROM pg_stat_activity
)
SELECT sessions.client_sessions,
       sessions.active_sessions,
       sessions.idle_sessions,
       sessions.idle_in_transaction_sessions,
       limits.max_connections,
       limits.reserved_connections,
       limits.superuser_reserved_connections,
       limits.max_connections
           - limits.reserved_connections
           - limits.superuser_reserved_connections AS regular_connection_limit,
       GREATEST(
           limits.max_connections
               - limits.reserved_connections
               - limits.superuser_reserved_connections
               - sessions.client_sessions,
           0
       ) AS remaining_regular_slots,
       round(
           100.0 * sessions.client_sessions /
           NULLIF(limits.max_connections
                  - limits.reserved_connections
                  - limits.superuser_reserved_connections, 0),
           2
       ) AS usable_connection_pct
FROM limits
CROSS JOIN sessions;

-- 4. Summarize user backend processes. High idle counts suggest oversized pools or
-- leaked connections; high active counts identify concurrency pressure. Compare the
-- oldest backend and transaction ages to find sessions retaining resources.
SELECT COALESCE(datname, '<none>') AS database_name,
       COALESCE(usename, '<none>') AS user_name,
       count(*) AS backend_processes,
       count(*) FILTER (WHERE state = 'active') AS active,
       count(*) FILTER (WHERE state = 'idle') AS idle,
       count(*) FILTER (WHERE state = 'idle in transaction')
           AS idle_in_transaction,
       count(*) FILTER (WHERE wait_event_type IS NOT NULL) AS waiting,
       max(clock_timestamp() - backend_start) AS oldest_backend_age,
       max(clock_timestamp() - xact_start) AS oldest_transaction_age
FROM pg_stat_activity
WHERE backend_type = 'client backend'
GROUP BY datname,
         usename
ORDER BY backend_processes DESC,
         database_name,
         user_name;

-- 5. Break connections down by user, application, and client. This is usually the
-- best view for finding which pool, application host, or login owns the processes.
SELECT COALESCE(usename, '<none>') AS user_name,
       COALESCE(NULLIF(application_name, ''), '<unset>') AS application_name,
       COALESCE(client_addr::text, '<local>') AS client_address,
       state,
       count(*) AS sessions,
       max(clock_timestamp() - backend_start) AS oldest_backend_age,
       max(clock_timestamp() - state_change) AS longest_state_age
FROM pg_stat_activity
WHERE backend_type = 'client backend'
GROUP BY usename,
         application_name,
         client_addr,
         state
ORDER BY sessions DESC,
         user_name,
         application_name,
         client_address;

-- 6. Inspect only the Connection Test workload while it is running. Look for the
-- expected client count, unexpectedly old sessions, non-Client waits, blockers,
-- or sessions stuck idle in transaction. SELECT 1 should normally finish quickly.
SELECT pid,
       leader_pid,
       usename,
       client_addr,
       client_port,
       state,
       wait_event_type,
       wait_event,
       clock_timestamp() - backend_start AS backend_age,
       clock_timestamp() - xact_start AS transaction_age,
       clock_timestamp() - query_start AS query_age,
       clock_timestamp() - state_change AS state_age,
       pg_blocking_pids(pid) AS blocking_pids,
       left(query, 300) AS current_query
FROM pg_stat_activity
WHERE datname = current_database()
      AND application_name LIKE 'PGBench%'
ORDER BY backend_start,
         pid;

-- 7. Summarize waits for the Connection Test workload. ClientRead is normal when
-- pgbench is between commands; Lock indicates contention, IO indicates storage
-- waiting, and active sessions with no wait event are running or runnable on CPU.
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
         wait_type,
         wait_event;

-- 8. Find potentially unhealthy user sessions across the database. Focus on idle
-- transactions, long transaction/query ages, and old backend_xmin values because
-- they can retain locks or prevent vacuum from removing dead tuples.
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
       clock_timestamp() - state_change AS state_age,
       backend_xid,
       backend_xmin,
       pg_blocking_pids(pid) AS blocking_pids,
       left(query, 500) AS current_query
FROM pg_stat_activity
WHERE datname = current_database()
  AND backend_type = 'client backend'
  AND pid <> pg_backend_pid()
  AND (state = 'idle in transaction'
       OR clock_timestamp() - xact_start > interval '1 minute'
       OR clock_timestamp() - query_start > interval '1 minute')
ORDER BY transaction_age DESC NULLS LAST,
         query_age DESC NULLS LAST;

-- 9. Show blocked user processes and their blockers. Any row returned during a
-- SELECT 1 connection test is unexpected; investigate the blocker application,
-- transaction age, and query before terminating anything.
SELECT blocked.pid AS blocked_pid,
       blocked.usename AS blocked_user,
       blocked.application_name AS blocked_application,
       clock_timestamp() - blocked.query_start AS blocked_duration,
       blocked.wait_event_type,
       blocked.wait_event,
       blocker.pid AS blocker_pid,
       blocker.usename AS blocker_user,
       blocker.application_name AS blocker_application,
       clock_timestamp() - blocker.xact_start AS blocker_transaction_age,
       left(blocked.query, 500) AS blocked_query,
       left(blocker.query, 500) AS blocker_query
FROM pg_stat_activity AS blocked
CROSS JOIN LATERAL unnest(pg_blocking_pids(blocked.pid)) AS blockers(blocker_pid)
JOIN pg_stat_activity AS blocker
  ON blocker.pid = blockers.blocker_pid
WHERE blocked.datname = current_database()
ORDER BY blocked_duration DESC;

-- 10. Inspect memory contexts for this DBA session only. Large CacheMemoryContext,
-- ExecutorState, TupleSort, or Hash contexts can explain this session's allocation.
-- This result is not the memory consumed by every backend and is not OS RSS.
SELECT name,
       ident,
       type,
       level,
       pg_size_pretty(total_bytes) AS total_size,
       pg_size_pretty(used_bytes) AS used_size,
       pg_size_pretty(free_bytes) AS free_size,
       total_nblocks,
       free_chunks
FROM pg_get_backend_memory_contexts()
ORDER BY total_bytes DESC
LIMIT 50;

-- 11. Show the complete raw memory-context inventory for this DBA session.
-- What to look for:
--   - total_bytes: memory obtained by the context. Sort by this first to find the
--     largest allocations.
--   - used_bytes: memory actively used. A value that grows across repeated samples
--     after work completes can indicate retained state that deserves investigation.
--   - free_bytes and free_chunks: reusable memory retained by the allocator. A high
--     value alone is not a leak; PostgreSQL commonly keeps memory for later reuse.
--   - total_nblocks: many blocks can indicate allocation churn or fragmentation,
--     especially when used_bytes is small relative to total_bytes.
--   - name and ident: identify the owning subsystem or object. Pay attention to
--     large ExecutorState, TupleSort, Hash, CacheMemoryContext, and portal contexts.
--   - level and path: show parent/child ownership. Use them to trace a large child
--     context back to its top-level operation rather than assessing it in isolation.
-- Compare snapshots at idle, during work, and after work. Persistent growth is more
-- meaningful than one large reading. This query also allocates some memory itself
-- and reports only this DBA session, not PGBench_TestConnection backend processes
-- or operating-system RSS/private memory.
SELECT *
FROM pg_get_backend_memory_contexts()
ORDER BY total_bytes DESC,
         level,
         name;

-- 12. Review query resource use by role from pg_stat_statements. This is cumulative
-- since its last reset and is not application-name aware. High temp blocks suggest
-- spill activity; high shared reads and execution time identify resource consumers.
SELECT roles.rolname AS user_name,
       sum(stats.calls) AS calls,
       round(sum(stats.total_plan_time)::numeric, 2) AS total_plan_ms,
       round(sum(stats.total_exec_time)::numeric, 2) AS total_exec_ms,
       sum(stats.rows) AS rows,
       sum(stats.shared_blks_hit) AS shared_blocks_hit,
       sum(stats.shared_blks_read) AS shared_blocks_read,
       sum(stats.temp_blks_read) AS temp_blocks_read,
       sum(stats.temp_blks_written) AS temp_blocks_written,
       pg_size_pretty(sum(stats.wal_bytes)::bigint) AS wal_size
FROM pg_stat_statements AS stats
JOIN pg_roles AS roles
  ON roles.oid = stats.userid
WHERE stats.dbid = (SELECT oid
                    FROM pg_database
                    WHERE datname = current_database())
  AND stats.query NOT ILIKE '%pg_stat%'
GROUP BY roles.rolname
ORDER BY total_exec_ms DESC;

-- 13. Review role-level connection limits. A value of -1 means no role-specific
-- limit, so the server's regular connection limit applies. Compare current sessions
-- with rolconnlimit to identify roles near their own cap.
SELECT roles.rolname AS user_name,
       roles.rolconnlimit AS role_connection_limit,
       count(activity.pid) AS current_sessions,
       CASE
           WHEN roles.rolconnlimit < 0 THEN NULL
           ELSE GREATEST(roles.rolconnlimit - count(activity.pid), 0)
       END AS remaining_role_slots
FROM pg_roles AS roles
LEFT JOIN pg_stat_activity AS activity
  ON activity.usesysid = roles.oid
 AND activity.backend_type = 'client backend'
WHERE roles.rolcanlogin
GROUP BY roles.oid,
         roles.rolname,
         roles.rolconnlimit
ORDER BY current_sessions DESC,
         roles.rolname;

-- 14. Review process amplification from parallel workers. A client backend can
-- temporarily own additional PostgreSQL processes. High worker counts increase
-- CPU and memory concurrency even though they do not consume connection slots.
WITH process_groups AS (
  SELECT COALESCE(leader_pid, pid) AS leader_pid,
       count(*) FILTER (WHERE backend_type = 'client backend')
         AS client_backend_processes,
       count(*) FILTER (WHERE backend_type = 'parallel worker')
         AS parallel_worker_processes,
       array_agg(pid ORDER BY pid) AS process_pids
  FROM pg_stat_activity
  WHERE backend_type IN ('client backend', 'parallel worker')
  GROUP BY COALESCE(leader_pid, pid)
)
SELECT leader.pid AS leader_pid,
     leader.usename,
     leader.application_name,
     leader.client_addr,
     leader.state,
     groups.client_backend_processes,
     groups.parallel_worker_processes,
     groups.client_backend_processes + groups.parallel_worker_processes
       AS total_session_processes,
     groups.process_pids,
     clock_timestamp() - leader.query_start AS query_age,
     left(leader.query, 300) AS current_query
FROM process_groups AS groups
JOIN pg_stat_activity AS leader
  ON leader.pid = groups.leader_pid
WHERE groups.parallel_worker_processes > 0
ORDER BY groups.parallel_worker_processes DESC,
     leader.pid;
