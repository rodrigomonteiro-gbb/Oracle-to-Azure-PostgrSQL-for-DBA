-- Oracle to Azure PostgreSQL Workshop - Day 2 pre-flight
-- Target database: AdventureWorks
--
-- Run before the Day 2 labs so prerequisites are checked once instead of
-- rediscovered during each lab.

-- 1) Confirm target.
SELECT current_database() AS database_name,
       current_user      AS current_role,
       now()             AS checked_at;

-- 2) Confirm required Day 2 extensions are installed in this database.
SELECT extname,
       extversion
FROM pg_extension
WHERE extname IN ('pg_stat_statements', 'pgstattuple')
ORDER BY extname;

-- Expected:
-- pg_stat_statements is required for top-SQL/runbook evidence.
-- pgstattuple is required for direct MVCC/dead-tuple inspection.

-- 3) Confirm pg_stat_statements server settings.
SHOW shared_preload_libraries;
SHOW pg_stat_statements.track;

-- Expected:
-- shared_preload_libraries includes pg_stat_statements.
-- pg_stat_statements.track returns all.

-- 4) Confirm pg_stat_statements is collecting rows.
SELECT count(*) AS captured_statements
FROM pg_stat_statements;

-- If captured_statements is 0 after running test queries, use captured sample
-- evidence for the runbook and troubleshoot extension setup outside lab time.

-- 5) Confirm AdventureWorks source tables.
SELECT 'sales.salesorderheader' AS table_name, count(*) AS row_count
FROM sales.salesorderheader
UNION ALL
SELECT 'sales.salesorderdetail', count(*)
FROM sales.salesorderdetail
UNION ALL
SELECT 'sales.customer', count(*)
FROM sales.customer
UNION ALL
SELECT 'person.person', count(*)
FROM person.person
ORDER BY table_name;

-- 6) Optional: remove leftover Day 2 scratch objects before a clean run.
-- DROP INDEX CONCURRENTLY cannot run inside a transaction block.
--
-- DROP TABLE IF EXISTS public.d2mvcc_salesorderheader;
-- DROP TABLE IF EXISTS public.d2wal_salesorderdetail;
-- DROP TABLE IF EXISTS public.d2wal_lsn_baseline;
-- DROP TABLE IF EXISTS public.d2runbook_salesorderheader;
-- DROP TABLE IF EXISTS public.d2runbook_salesorderdetail;
-- DROP TABLE IF EXISTS public.d2runbook_customer;
-- DROP TABLE IF EXISTS public.d2runbook_person;
-- DROP INDEX CONCURRENTLY IF EXISTS public.d2runbook_soh_orderdate_customerid_idx;
-- DROP INDEX CONCURRENTLY IF EXISTS public.d2runbook_sod_salesorderid_idx;
-- DROP STATISTICS IF EXISTS public.d2runbook_soh_status_orderdate_stats;
