/* monitoring activity */
SELECT *
FROM pg_stat_activity
WHERE
	datname = 'adventureworks'
	AND
	application_name like 'PGBench%'
	AND
	state != 'idle'

/* Show All Sessions */
-- Something equivalent of SQL Server's sp_whoisactive view:
SELECT
	pid,
	usename,
	application_name,
	state,
	wait_event_type,
	wait_event,
	now() - xact_start AS txn_age,
	now() - query_start AS query_age,
	pg_blocking_pids(pid) AS blocking_pids,
	query
FROM 
	pg_stat_activity
WHERE 
	pid <> pg_backend_pid()
ORDER BY 
	query_start;
