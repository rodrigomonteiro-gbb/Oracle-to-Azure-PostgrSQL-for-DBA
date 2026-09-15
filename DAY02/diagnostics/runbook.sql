-- The DBA runbook — the five everyday cases, mapped from Oracle GV$ habits.

-- 1) Blocking / locks (v$lock)  -> who blocks whom
SELECT blocked.pid          AS blocked_pid,
       blocked.query        AS blocked_query,
       blocking.pid         AS blocking_pid,
       blocking.query       AS blocking_query
FROM pg_stat_activity blocked
JOIN pg_stat_activity blocking
  ON blocking.pid = ANY (pg_blocking_pids(blocked.pid))
WHERE cardinality(pg_blocking_pids(blocked.pid)) > 0;

-- 2) Active sessions & wait events (v$session / v$session_wait)
SELECT pid, usename, state, wait_event_type, wait_event,
       now() - query_start AS running_for, left(query, 80) AS query
FROM pg_stat_activity
WHERE state <> 'idle'
ORDER BY running_for DESC NULLS LAST;

-- 3) Runaway session -> cancel the query, or terminate the backend
--    SELECT pg_cancel_backend(<pid>);      -- cancel current query
--    SELECT pg_terminate_backend(<pid>);   -- kill the session

-- 4) Space & bloat (dba_segments / segment advisor)
SELECT relname,
       pg_size_pretty(pg_total_relation_size(relid)) AS total,
       n_dead_tup, n_live_tup,
       round(100 * n_dead_tup / nullif(n_live_tup + n_dead_tup, 0), 1) AS dead_pct,
       last_autovacuum
FROM pg_stat_user_tables
ORDER BY pg_total_relation_size(relid) DESC
LIMIT 15;

-- 5) Slow query root cause (autotrace)  -> EXPLAIN (ANALYZE, BUFFERS)
--    EXPLAIN (ANALYZE, BUFFERS) SELECT ...;
