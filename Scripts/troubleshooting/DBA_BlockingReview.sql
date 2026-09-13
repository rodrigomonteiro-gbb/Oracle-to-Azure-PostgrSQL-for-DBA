/* monitoring blocking */
SELECT
	pid,
	usename,
	state,
	wait_event_type,
	wait_event,
	query
FROM 
	pg_stat_activity
WHERE 
	state <> 'idle';

SELECT
	pid,
	usename,
	state,
	wait_event_type,
	wait_event,
	query
FROM pg_stat_activity
WHERE wait_event_type = 'Lock';

SELECT
    blocked.pid AS blocked_pid,
    blocked.usename AS blocked_user,
    blocked.state AS blocked_state,
    blocker.pid AS blocker_pid,
    blocker.usename AS blocker_user,
    blocker.state AS blocker_state,
    blocked.query AS blocked_query,
    blocker.query AS blocker_query
FROM pg_stat_activity AS blocked
CROSS JOIN LATERAL unnest(pg_blocking_pids(blocked.pid)) AS blocker_pid
JOIN pg_stat_activity AS blocker
    ON blocker.pid = blocker_pid
WHERE cardinality(pg_blocking_pids(blocked.pid)) > 0;

/* Lock Inventory */
-- To see the actual locks:
SELECT
	a.pid,
	a.usename,
	l.locktype,
	l.mode,
	l.granted,
	c.relname,
	a.query
FROM pg_locks l
	JOIN pg_stat_activity a
		ON l.pid = a.pid
	LEFT JOIN pg_class c
		ON l.relation = c.oid
ORDER BY a.pid;





/* Blocked Sessions with Blocking Details*/
SELECT
    blocked.pid AS blocked_pid,
    blocked.usename AS blocked_user,
    blocked.application_name,
    blocked.client_addr,
    blocked.state AS blocked_state,
    blocked.wait_event_type,
    blocked.wait_event,
    now() - blocked.query_start AS blocked_duration,
    blockers.blocking_pids,
    blocker.pid AS blocker_pid,
    blocker.usename AS blocker_user,
    blocker.state AS blocker_state,
    now() - blocker.query_start AS blocker_duration,
    blocked.query AS blocked_query,
    blocker.query AS blocker_query
FROM pg_stat_activity AS blocked
CROSS JOIN LATERAL (
    SELECT pg_blocking_pids(blocked.pid) AS blocking_pids
) AS blockers
LEFT JOIN pg_stat_activity AS blocker
    ON blocker.pid = ANY(blockers.blocking_pids)
WHERE cardinality(blockers.blocking_pids) > 0
ORDER BY blocked_duration DESC;















/*  quick count of blocked sessions: */
SELECT count(*)
FROM pg_stat_activity
WHERE cardinality(pg_blocking_pids(pid)) > 0;

/* check whether previous pgbench processes are still connected: */
SELECT
    application_name,
    count(*) AS sessions
FROM pg_stat_activity
WHERE pid <> pg_backend_pid()
GROUP BY application_name
ORDER BY sessions DESC;


/* Returns one row per blocked PID and retain all blocker details: */
WITH blocked_sessions AS MATERIALIZED (
    SELECT
        activity.*,
        pg_blocking_pids(activity.pid) AS blocker_pids
    FROM pg_stat_activity AS activity
)
SELECT
    blocked.pid AS blocked_pid,
    blocked.usename AS blocked_user,
    blocked.application_name,
    blocked.client_addr,
    blocked.state AS blocked_state,
    blocked.wait_event_type,
    blocked.wait_event,
    now() - blocked.query_start AS blocked_duration,
    blocked.blocker_pids,
    array_agg(DISTINCT blocker.pid)
        FILTER (WHERE blocker.pid IS NOT NULL) AS blocker_pids_found,
    string_agg(
        DISTINCT blocker.pid || ': ' || blocker.query,
        E'\n'
    ) FILTER (WHERE blocker.pid IS NOT NULL) AS blocker_queries,
    blocked.query AS blocked_query
FROM blocked_sessions AS blocked
LEFT JOIN pg_stat_activity AS blocker
    ON blocker.pid = ANY(blocked.blocker_pids)
WHERE cardinality(blocked.blocker_pids) > 0
GROUP BY
    blocked.pid,
    blocked.usename,
    blocked.application_name,
    blocked.client_addr,
    blocked.state,
    blocked.wait_event_type,
    blocked.wait_event,
    blocked.query_start,
    blocked.blocker_pids,
    blocked.query
ORDER BY blocked_duration DESC;

/* This returns one row per blocking session, aggregating all sessions blocked by it: */
WITH blocking_pairs AS MATERIALIZED (
    SELECT DISTINCT
        blocked.pid AS blocked_pid,
        blocker_pid
    FROM pg_stat_activity AS blocked
    CROSS JOIN LATERAL
        unnest(pg_blocking_pids(blocked.pid)) AS blockers(blocker_pid)
)
SELECT
    blocker.pid AS blocker_pid,
    blocker.usename AS blocker_user,
    blocker.application_name,
    blocker.client_addr,
    blocker.state AS blocker_state,
    blocker.wait_event_type,
    blocker.wait_event,
    now() - blocker.xact_start AS transaction_duration,
    count(DISTINCT pair.blocked_pid) AS blocked_session_count,
    array_agg(DISTINCT pair.blocked_pid) AS blocked_pids,
    string_agg(
        DISTINCT pair.blocked_pid || ': ' || blocked.query,
        E'\n'
    ) AS blocked_queries,
    blocker.query AS blocker_query
FROM blocking_pairs AS pair
JOIN pg_stat_activity AS blocker
    ON blocker.pid = pair.blocker_pid
JOIN pg_stat_activity AS blocked
    ON blocked.pid = pair.blocked_pid
GROUP BY
    blocker.pid,
    blocker.usename,
    blocker.application_name,
    blocker.client_addr,
    blocker.state,
    blocker.wait_event_type,
    blocker.wait_event,
    blocker.xact_start,
    blocker.query
ORDER BY
    blocked_session_count DESC,
    transaction_duration DESC;
