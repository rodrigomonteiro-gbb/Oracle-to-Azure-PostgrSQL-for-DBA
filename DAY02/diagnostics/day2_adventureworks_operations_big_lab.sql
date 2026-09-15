-- Oracle to Azure PostgreSQL Workshop - Day 2
-- AdventureWorks operations lab
--
-- Target database: adventureworks
-- Topics: MVCC, autovacuum, parameter tuning, WAL/replication, DBA runbook cases
--
-- Run against the workshop database only.
-- EXPLAIN (ANALYZE, BUFFERS) executes the statement.
-- CREATE INDEX CONCURRENTLY cannot run inside a transaction block.


-- ============================================================
-- 0) Extensions used in this lab
-- ============================================================

CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS pgstattuple;


-- ============================================================
-- 1) AdventureWorks sanity check
-- ============================================================

SELECT current_database() AS database_name;

SELECT schemaname,
       relname,
       n_live_tup,
       pg_size_pretty(pg_total_relation_size(relid)) AS total_size
FROM pg_stat_user_tables
WHERE (schemaname, relname) IN (
  ('sales', 'salesorderheader'),
  ('sales', 'salesorderdetail'),
  ('sales', 'customer'),
  ('person', 'person'),
  ('production', 'product')
)
ORDER BY schemaname, relname;


-- ============================================================
-- 2) First-look triage
-- ============================================================

SELECT count(*)                                              AS total,
       count(*) FILTER (WHERE state = 'active')              AS active,
       count(*) FILTER (WHERE state = 'idle')                AS idle,
       count(*) FILTER (WHERE state = 'idle in transaction') AS idle_in_txn,
       current_setting('max_connections')::int               AS max_connections
FROM pg_stat_activity;

SELECT pid,
       usename,
       application_name,
       client_addr,
       state,
       wait_event_type,
       wait_event,
       now() - query_start AS running_for,
       left(query, 120)    AS query
FROM pg_stat_activity
WHERE state <> 'idle'
ORDER BY query_start;

SELECT calls,
       total_exec_time,
       mean_exec_time,
       rows,
       left(query, 160) AS query
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 10;


-- ============================================================
-- 3) MVCC, dead tuples, and VACUUM
-- ============================================================

DROP TABLE IF EXISTS public.mvcc_lab_salesorderheader;

CREATE TABLE public.mvcc_lab_salesorderheader AS
SELECT *
FROM sales.salesorderheader
LIMIT 20000;

ALTER TABLE public.mvcc_lab_salesorderheader
  ADD PRIMARY KEY (salesorderid);

ANALYZE public.mvcc_lab_salesorderheader;

SELECT relname,
       n_live_tup,
       n_dead_tup,
       last_vacuum,
       last_autovacuum,
       last_analyze,
       last_autoanalyze
FROM pg_stat_user_tables
WHERE schemaname = 'public'
  AND relname = 'mvcc_lab_salesorderheader';

SELECT pg_size_pretty(pg_total_relation_size('public.mvcc_lab_salesorderheader')) AS size_before_update;

SELECT *
FROM pgstattuple('public.mvcc_lab_salesorderheader');

UPDATE public.mvcc_lab_salesorderheader
SET freight = freight + 0
WHERE salesorderid IN (
  SELECT salesorderid
  FROM public.mvcc_lab_salesorderheader
  ORDER BY salesorderid
  LIMIT 10000
);

ANALYZE public.mvcc_lab_salesorderheader;

SELECT relname,
       n_live_tup,
       n_dead_tup,
       round(n_dead_tup * 100.0 / NULLIF(n_live_tup + n_dead_tup, 0), 2) AS dead_pct,
       last_vacuum,
       last_autovacuum,
       last_analyze,
       last_autoanalyze
FROM pg_stat_user_tables
WHERE schemaname = 'public'
  AND relname = 'mvcc_lab_salesorderheader';

SELECT pg_size_pretty(pg_total_relation_size('public.mvcc_lab_salesorderheader')) AS size_after_update;

SELECT *
FROM pgstattuple('public.mvcc_lab_salesorderheader');

VACUUM (VERBOSE, ANALYZE) public.mvcc_lab_salesorderheader;

SELECT relname,
       n_live_tup,
       n_dead_tup,
       last_vacuum,
       last_autovacuum,
       last_analyze,
       last_autoanalyze
FROM pg_stat_user_tables
WHERE schemaname = 'public'
  AND relname = 'mvcc_lab_salesorderheader';

SELECT *
FROM pgstattuple('public.mvcc_lab_salesorderheader');


-- ============================================================
-- 4) Autovacuum settings and cleanup horizon
-- ============================================================

SELECT name,
       setting,
       unit
FROM pg_settings
WHERE name IN (
  'autovacuum',
  'autovacuum_max_workers',
  'autovacuum_naptime',
  'autovacuum_vacuum_scale_factor',
  'autovacuum_analyze_scale_factor',
  'autovacuum_vacuum_cost_limit',
  'autovacuum_vacuum_cost_delay'
)
ORDER BY name;

ALTER TABLE public.mvcc_lab_salesorderheader SET (
  autovacuum_vacuum_scale_factor  = 0.02,
  autovacuum_analyze_scale_factor = 0.01,
  autovacuum_vacuum_cost_limit    = 2000
);

SELECT relname,
       reloptions
FROM pg_class
WHERE oid = 'public.mvcc_lab_salesorderheader'::regclass;

ALTER TABLE public.mvcc_lab_salesorderheader RESET (
  autovacuum_vacuum_scale_factor,
  autovacuum_analyze_scale_factor,
  autovacuum_vacuum_cost_limit
);

SELECT max(age(backend_xmin)) AS oldest_xmin_age
FROM pg_stat_activity
WHERE backend_xmin IS NOT NULL;

SELECT pid,
       usename,
       application_name,
       client_addr,
       state,
       now() - xact_start   AS xact_age,
       now() - state_change AS in_this_state_for,
       left(query, 120)     AS query
FROM pg_stat_activity
WHERE xact_start IS NOT NULL
ORDER BY xact_start
LIMIT 20;


-- ============================================================
-- 5) work_mem session experiment
-- ============================================================

SHOW work_mem;

SET work_mem = '64MB';

EXPLAIN (ANALYZE, BUFFERS)
SELECT h.customerid,
       h.salesorderid,
       h.orderdate,
       h.totaldue,
       row_number() OVER (
         PARTITION BY h.customerid
         ORDER BY h.totaldue DESC, h.orderdate DESC
       ) AS order_rank
FROM sales.salesorderheader h
JOIN sales.salesorderdetail d
  ON d.salesorderid = h.salesorderid
ORDER BY h.customerid, h.totaldue DESC;

RESET work_mem;


-- ============================================================
-- 6) WAL growth and replication
-- ============================================================

SELECT current_database() AS database_name,
       pg_size_pretty(pg_database_size(current_database())) AS db_size;

SELECT datname,
       xact_commit,
       xact_rollback,
       blks_read,
       blks_hit,
       temp_files
FROM pg_stat_database
WHERE datname = current_database();

SELECT client_addr,
       application_name,
       state,
       sent_lsn,
       write_lsn,
       flush_lsn,
       replay_lsn,
       write_lag,
       flush_lag,
       replay_lag
FROM pg_stat_replication;

SELECT slot_name,
       plugin,
       slot_type,
       database,
       active,
       wal_status,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS wal_retained
FROM pg_replication_slots
ORDER BY pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) DESC NULLS LAST;

DROP TABLE IF EXISTS public.wal_growth_lab_salesorderdetail;

CREATE TABLE public.wal_growth_lab_salesorderdetail AS
SELECT *
FROM sales.salesorderdetail
LIMIT 50000;

ALTER TABLE public.wal_growth_lab_salesorderdetail
  ADD PRIMARY KEY (salesorderid, salesorderdetailid);

ANALYZE public.wal_growth_lab_salesorderdetail;

UPDATE public.wal_growth_lab_salesorderdetail
SET unitprice = unitprice * 1.001,
    modifieddate = now()
WHERE salesorderdetailid IN (
  SELECT salesorderdetailid
  FROM public.wal_growth_lab_salesorderdetail
  ORDER BY salesorderdetailid
  LIMIT 20000
);

DELETE FROM public.wal_growth_lab_salesorderdetail
WHERE salesorderdetailid IN (
  SELECT salesorderdetailid
  FROM public.wal_growth_lab_salesorderdetail
  ORDER BY salesorderdetailid DESC
  LIMIT 5000
);

SELECT current_database() AS database_name,
       pg_size_pretty(pg_database_size(current_database())) AS db_size_after_write;

SELECT datname,
       xact_commit,
       xact_rollback,
       blks_read,
       blks_hit,
       temp_files
FROM pg_stat_database
WHERE datname = current_database();

SELECT client_addr,
       application_name,
       state,
       write_lag,
       flush_lag,
       replay_lag
FROM pg_stat_replication;

SELECT slot_name,
       active,
       wal_status,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS wal_retained
FROM pg_replication_slots
ORDER BY pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) DESC NULLS LAST;

-- ============================================================
-- 7) DBA runbook: five cases
-- ============================================================

-- Case 1: CPU spike from inefficient SQL.
SELECT calls,
       total_exec_time,
       mean_exec_time,
       rows,
       left(query, 160) AS query
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 10;

EXPLAIN (ANALYZE, BUFFERS)
SELECT c.customerid,
       p.firstname,
       p.lastname,
       count(DISTINCT h.salesorderid) AS total_orders,
       sum(d.linetotal) AS lifetime_value
FROM sales.customer c
JOIN person.person p
  ON p.businessentityid = c.personid
JOIN sales.salesorderheader h
  ON h.customerid = c.customerid
JOIN sales.salesorderdetail d
  ON d.salesorderid = h.salesorderid
GROUP BY c.customerid, p.firstname, p.lastname
ORDER BY lifetime_value DESC
LIMIT 100;

CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_aw_salesorderheader_customerid
ON sales.salesorderheader (customerid);

CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_aw_salesorderdetail_salesorderid
ON sales.salesorderdetail (salesorderid);

ANALYZE sales.salesorderheader;
ANALYZE sales.salesorderdetail;

-- Case 2: Bad plan from stale or insufficient statistics.
EXPLAIN (ANALYZE, BUFFERS)
SELECT h.salesorderid,
       h.customerid,
       h.orderdate,
       h.status,
       h.totaldue
FROM sales.salesorderheader h
WHERE h.status = 5
  AND h.orderdate >= DATE '2013-01-01'
ORDER BY h.orderdate DESC
LIMIT 100;

SELECT attname,
       n_distinct,
       null_frac,
       correlation
FROM pg_stats
WHERE schemaname = 'sales'
  AND tablename = 'salesorderheader'
  AND attname IN ('status', 'orderdate', 'customerid');

ANALYZE VERBOSE sales.salesorderheader;

CREATE STATISTICS IF NOT EXISTS st_aw_salesorderheader_status_orderdate
  (dependencies, ndistinct)
ON status, orderdate
FROM sales.salesorderheader;

ANALYZE sales.salesorderheader;

-- Case 3: Blocking chain / idle-in-transaction.
SELECT blocked.pid              AS blocked_pid,
       blocked.usename          AS blocked_user,
       blocking.pid             AS blocking_pid,
       blocking.usename         AS blocking_user,
       blocked.wait_event_type,
       blocked.wait_event,
       left(blocked.query, 100)  AS blocked_query,
       left(blocking.query, 100) AS blocking_query
FROM pg_stat_activity blocked
JOIN LATERAL unnest(pg_blocking_pids(blocked.pid)) AS bpid ON true
JOIN pg_stat_activity blocking ON blocking.pid = bpid;

SELECT pid,
       usename,
       application_name,
       client_addr,
       state,
       now() - xact_start AS xact_age,
       now() - state_change AS in_this_state_for,
       left(query, 120) AS query
FROM pg_stat_activity
WHERE state = 'idle in transaction'
ORDER BY xact_start;

-- Case 4: Connection saturation / pooling.
SELECT count(*) AS total_connections,
       count(*) FILTER (WHERE state = 'active') AS active_connections,
       count(*) FILTER (WHERE state = 'idle') AS idle_connections,
       count(*) FILTER (WHERE state = 'idle in transaction') AS idle_in_txn_connections,
       current_setting('max_connections')::int AS max_connections
FROM pg_stat_activity;

SELECT usename,
       application_name,
       client_addr,
       state,
       count(*) AS sessions
FROM pg_stat_activity
WHERE backend_type = 'client backend'
GROUP BY 1, 2, 3, 4
ORDER BY sessions DESC;

-- Case 5: WAL growth / replica lag risk.
SELECT client_addr,
       application_name,
       state,
       write_lag,
       flush_lag,
       replay_lag
FROM pg_stat_replication;

SELECT slot_name,
       active,
       wal_status,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS wal_retained
FROM pg_replication_slots
ORDER BY pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) DESC NULLS LAST;


-- ============================================================
-- 8) Cleanup after all labs
-- ============================================================
--
-- Run this section when participants need to reset the database
-- and run the labs again.
--
-- DROP INDEX CONCURRENTLY cannot run inside a transaction block.

DROP TABLE IF EXISTS public.mvcc_lab_salesorderheader;
DROP TABLE IF EXISTS public.wal_growth_lab_salesorderdetail;

DROP INDEX CONCURRENTLY IF EXISTS sales.ix_aw_salesorderheader_customerid;
DROP INDEX CONCURRENTLY IF EXISTS sales.ix_aw_salesorderdetail_salesorderid;

DROP STATISTICS IF EXISTS public.st_aw_salesorderheader_status_orderdate;
DROP STATISTICS IF EXISTS st_aw_salesorderheader_status_orderdate;

ANALYZE sales.salesorderheader;
ANALYZE sales.salesorderdetail;
