# S2E - MVCC, autovacuum and parameter tuning

## Lab objective

Help Oracle DBAs understand why PostgreSQL cleanup is a normal operating responsibility. Participants will use AdventureWorks-derived scratch tables to prove that updates create old row versions, dead tuples accumulate, VACUUM makes space reusable, long transactions can hold cleanup back, and `work_mem` must be tested carefully before becoming a server-wide setting.

## Key message for the room

The read-consistency goal is familiar from Oracle. The implementation is different: PostgreSQL keeps old row versions in the table until VACUUM can clean them. That is why dead tuples, bloat, autovacuum and transaction age are DBA topics here.

Use **closest operational equivalent** language. Do not say MVCC cleanup is "the same as undo."

## Required extension

This lab uses `pgstattuple` to measure live tuples, dead tuples, free space and bloat inside the disposable AdventureWorks lab table. On Azure Database for PostgreSQL Flexible Server, the extension must be allowed at the server level before it can be created inside the database.

`pgstattuple` does not require `shared_preload_libraries` or a server restart. It only needs to be listed in `azure.extensions`, then created in the target database.

Azure CLI setup, PowerShell:

```powershell
az postgres flexible-server parameter set `
  --resource-group <resource-group> `
  --server-name <server-name> `
  --name azure.extensions `
  --value "pg_stat_statements,pg_trgm,uuid-ossp,pgcrypto,pgstattuple"
```

Azure CLI setup, Bash:

```bash
az postgres flexible-server parameter set \
  --resource-group <resource-group> \
  --server-name <server-name> \
  --name azure.extensions \
  --value "pg_stat_statements,pg_trgm,uuid-ossp,pgcrypto,pgstattuple"
```

Then connect to the AdventureWorks database and create the extension:

```sql
CREATE EXTENSION IF NOT EXISTS pgstattuple;
```

## Lab steps

### 1. Create a disposable MVCC lab table

DBA question: "How do we create a safe table for MVCC testing without changing real AdventureWorks data?"

First evidence to collect: after the table is created, confirm the table exists and statistics are fresh by using the baseline queries in step 2.

What each statement does:

1. `DROP TABLE IF EXISTS` resets the lab table if the participant already ran the script.
2. `CREATE TABLE AS` copies a small AdventureWorks sample into a disposable table so the lab does not modify source data.
3. `ALTER TABLE ... ADD PRIMARY KEY` gives the lab table a realistic key for updates and lookups.
4. `ANALYZE` samples the table and updates planner statistics, such as row counts and value distribution, so PostgreSQL can choose better execution plans.

```sql
DROP TABLE IF EXISTS public.mvcc_lab_salesorderheader;

CREATE TABLE public.mvcc_lab_salesorderheader AS
SELECT *
FROM sales.salesorderheader
LIMIT 20000;

ALTER TABLE public.mvcc_lab_salesorderheader
  ADD PRIMARY KEY (salesorderid);

ANALYZE public.mvcc_lab_salesorderheader;
```

### 2. Capture baseline tuple and size evidence

DBA question: "What does the table look like before we create churn?"

First evidence to collect: run `pg_stat_user_tables`, `pg_total_relation_size`, and `pgstattuple` before any update workload. These become the baseline for live tuples, dead tuples, table size, and free space.

What each query shows:

1. `pg_stat_user_tables` shows the current live/dead tuple estimates and when PostgreSQL last vacuumed or analyzed the table.
2. `pg_total_relation_size` captures the starting physical size of the table plus indexes.
3. `pgstattuple` reads the table directly and gives baseline tuple, dead tuple and free-space percentages.

How to read the result:

1. `n_live_tup` is PostgreSQL's estimate of rows currently visible.
2. `n_dead_tup` is PostgreSQL's estimate of dead row versions waiting for cleanup.
3. `last_vacuum` and `last_autovacuum` show whether cleanup has happened.
4. `last_analyze` and `last_autoanalyze` show whether statistics have been refreshed.
5. `pgstattuple` is more direct evidence than estimates because it inspects the table.

```sql
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

SELECT pg_size_pretty(pg_total_relation_size('public.mvcc_lab_salesorderheader')) AS table_size_before;

SELECT *
FROM pgstattuple('public.mvcc_lab_salesorderheader');
```

### 3. Create row churn without changing business meaning

DBA question: "Can an update create dead tuples even when the business value does not really change?"

What each statement does:

1. `UPDATE ... SET freight = freight + 0` rewrites rows without changing the business value. PostgreSQL still creates new row versions, which leaves old versions behind as dead tuples.
2. `ANALYZE` refreshes statistics after the row churn so the next evidence query sees current table estimates in `pg_stat_user_tables`.

Possible whys for MVCC churn in production:

1. An application updates a row even when values did not materially change.
2. A batch job touches many rows to refresh timestamps, statuses, or audit columns.
3. Repeated updates to hot rows create dead tuples faster than autovacuum can clean them.
4. Updates to indexed columns add both table churn and index maintenance.

```sql
UPDATE public.mvcc_lab_salesorderheader
SET freight = freight + 0
WHERE salesorderid IN (
  SELECT salesorderid
  FROM public.mvcc_lab_salesorderheader
  ORDER BY salesorderid
  LIMIT 10000
);

ANALYZE public.mvcc_lab_salesorderheader;
```

### 4. Optional: create concurrent row churn with pgbench

The previous update is enough for a classroom demo. If you want a more realistic workload, run `pgbench` from PowerShell or Bash after the lab table has been created. Do not run `pgbench` inside `psql`.

Why this step matters:

Single-session updates prove the MVCC concept. `pgbench` makes the workload look more like a real application by running the same write pattern concurrently from multiple client sessions. This helps DBAs connect dead tuples and vacuum behavior to normal OLTP activity, not only to one manual `UPDATE`.

Best practice:

Keep the workload short and bounded in a workshop or shared environment. Increase concurrency only when you are intentionally testing capacity, and always run it against disposable lab tables, not production tables.

PowerShell:

```powershell
$env:PGPASSWORD = "<password>"

@"
\set order_offset random(0, 19999)
UPDATE public.mvcc_lab_salesorderheader
SET freight = freight + 0
WHERE salesorderid = (
  SELECT salesorderid
  FROM public.mvcc_lab_salesorderheader
  ORDER BY salesorderid
  OFFSET :order_offset
  LIMIT 1
);
"@ | Set-Content -Path "$env:TEMP\pgbench_mvcc_churn.sql" -Encoding ascii

pgbench `
  -h <server-name>.postgres.database.azure.com `
  -U <admin-user> `
  -d AdventureWorks `
  -c 4 `
  -j 2 `
  -T 60 `
  -f "$env:TEMP\pgbench_mvcc_churn.sql"
```

Bash:

```bash
export PGPASSWORD="<password>"

cat > /tmp/pgbench_mvcc_churn.sql <<'SQL'
\set order_offset random(0, 19999)
UPDATE public.mvcc_lab_salesorderheader
SET freight = freight + 0
WHERE salesorderid = (
  SELECT salesorderid
  FROM public.mvcc_lab_salesorderheader
  ORDER BY salesorderid
  OFFSET :order_offset
  LIMIT 1
);
SQL

pgbench \
  -h <server-name>.postgres.database.azure.com \
  -U <admin-user> \
  -d AdventureWorks \
  -c 4 \
  -j 2 \
  -T 60 \
  -f /tmp/pgbench_mvcc_churn.sql
```

Reconnect with `psql` and refresh table statistics before checking the evidence:

```sql
ANALYZE public.mvcc_lab_salesorderheader;
```

### 5. Prove old row versions accumulated

DBA question: "What evidence proves the updates created old row versions?"

First evidence to collect: compare the same `pg_stat_user_tables`, `pg_total_relation_size`, and `pgstattuple` results from the baseline.

What each query shows:

1. `pg_stat_user_tables` shows PostgreSQL's table-level live/dead tuple counters and the last manual or automatic maintenance time.
2. `pg_total_relation_size` shows whether the physical table and index footprint changed after row churn.
3. `pgstattuple` reads the table directly and gives stronger evidence of tuple percent, dead tuple percent and free space.

Possible whys:

1. `n_dead_tup` increased because PostgreSQL kept old row versions for MVCC visibility.
2. Table size increased because new row versions needed space.
3. Table size stayed similar because PostgreSQL reused free space already available inside the table.
4. `pg_stat_user_tables` and `pgstattuple` may not match exactly because one is statistics-based and the other inspects the table.

```sql
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

SELECT pg_size_pretty(pg_total_relation_size('public.mvcc_lab_salesorderheader')) AS table_size_after_update;

SELECT *
FROM pgstattuple('public.mvcc_lab_salesorderheader');
```

### 6. Run routine cleanup and compare

DBA question: "What does regular VACUUM fix, and what does it not fix?"

First evidence to collect: run `VACUUM (VERBOSE, ANALYZE)`, then rerun `pg_stat_user_tables`, `pg_total_relation_size`, and `pgstattuple`.

What each query does:

1. `VACUUM (VERBOSE, ANALYZE)` removes dead tuples that are safe to clean and refreshes planner statistics.
2. `pg_stat_user_tables` confirms that vacuum/analyze ran and shows the updated dead-tuple estimate.
3. `pg_total_relation_size` proves that routine vacuum usually reuses internal space instead of shrinking the table file.
4. `pgstattuple` verifies how much dead tuple and free space remains after cleanup.

```sql
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

SELECT pg_size_pretty(pg_total_relation_size('public.mvcc_lab_salesorderheader')) AS table_size_after_vacuum;

SELECT *
FROM pgstattuple('public.mvcc_lab_salesorderheader');
```

Routine `VACUUM` makes space reusable inside the table. It does not usually return space to storage, so `table_size_after_vacuum` can stay the same even when dead tuples drop.

What improved:

1. Future inserts and updates can reuse the cleaned space.
2. Autovacuum pressure and dead-tuple risk are reduced.
3. Query plans can improve because `VACUUM (ANALYZE)` refreshes table statistics.

What did not necessarily improve:

1. The storage bill or allocated database size may not drop immediately.
2. Scans can still touch a large table file if the table remains physically large.
3. Index bloat may remain and may need separate analysis.

`VACUUM FULL` is not part of the normal lab run because it rewrites the table and takes an exclusive lock. Use it only when there is a clear operational reason to physically shrink a table, such as after a one-time archival/delete event where the table will not quickly grow back, and only during an approved maintenance window.

Getting space back helps only when the real problem is physical storage pressure or a permanently oversized table. If the workload will reuse the space soon, regular `VACUUM` is usually better because it avoids the exclusive lock and table rewrite cost.

Possible whys if dead tuples do not drop:

1. A long-running transaction still needs the old row versions.
2. A session is `idle in transaction` and holding an old snapshot.
3. The table has active workload while vacuum is running.
4. The statistics estimate has not caught up yet; use `pgstattuple` for stronger evidence.

### 7. Optional small-table demo: physically shrink with VACUUM FULL

DBA question: "What changes when the goal is to physically return table space?"

Run this only after the regular `VACUUM` comparison, so participants first see that routine cleanup can remove dead tuples without returning physical space.

This is safe for the workshop because `public.mvcc_lab_salesorderheader` is a small disposable lab table. Do not present this as routine production maintenance.

What each statement does:

1. `VACUUM FULL` rewrites the table into a new compact physical file and returns unused space to storage.
2. `ANALYZE` refreshes planner statistics after the rewrite.
3. `pg_total_relation_size` shows whether the physical table footprint became smaller after the rewrite.
4. `pgstattuple` confirms that the rewritten table has little or no dead tuple space.

Impact to explain:

1. `VACUUM FULL` takes an exclusive lock on the table.
2. It rewrites the whole table and indexes, so it needs time, I/O and temporary free space.
3. It is useful after a one-time large purge or archival event when the table will not immediately grow back.
4. It is not useful as a routine fix for normal churn if the workload will reuse the free space.

```sql
VACUUM FULL public.mvcc_lab_salesorderheader;

ANALYZE public.mvcc_lab_salesorderheader;

SELECT pg_size_pretty(pg_total_relation_size('public.mvcc_lab_salesorderheader')) AS table_size_after_vacuum_full;

SELECT *
FROM pgstattuple('public.mvcc_lab_salesorderheader');
```

For a real production table, run this only during an approved maintenance window after proving that returning physical space is the actual goal.

Possible whys to use `VACUUM FULL`:

1. A one-time purge or archive removed a large percentage of a table.
2. The table will not grow back soon, so keeping the free space is wasteful.
3. Storage pressure is urgent and reclaiming physical space is worth a maintenance window.

Possible whys not to use it:

1. The table has normal daily churn and will reuse the space.
2. The application cannot tolerate an exclusive table lock.
3. The server does not have enough temporary free space or I/O headroom for the rewrite.

### 8. Inspect autovacuum settings and show a per-table override

DBA question: "Should I tune autovacuum globally or only for the hot table?"

First evidence to collect: run the `pg_settings` query to see the current server defaults, then inspect `pg_class.reloptions` after the table override to prove the override exists only on this lab table.

Why this step matters:

Autovacuum is PostgreSQL's normal cleanup mechanism. It removes dead tuples, prevents transaction ID wraparound risk, and runs `ANALYZE` so the optimizer has current statistics. Oracle DBAs should treat autovacuum as a core health process, not as optional background noise.

What each query does:

1. `pg_settings` shows the server-level autovacuum thresholds and cost settings that apply by default.
2. `ALTER TABLE ... SET` demonstrates a safer per-table override for a table with heavier churn.
3. `pg_class.reloptions` confirms the override was stored on the table.
4. `ALTER TABLE ... RESET` removes the workshop override so the lab does not leave tuning changes behind.

What the key settings mean:

1. `autovacuum` turns the background cleanup process on or off. Best practice is to keep it on.
2. `autovacuum_max_workers` controls how many autovacuum workers can run at the same time across the server.
3. `autovacuum_naptime` controls how often PostgreSQL wakes up to look for tables needing maintenance.
4. `autovacuum_vacuum_scale_factor` controls how much table change triggers vacuum. Lower values make vacuum run sooner on high-churn tables.
5. `autovacuum_analyze_scale_factor` controls how much table change triggers statistics refresh. Lower values make planner stats refresh sooner.
6. `autovacuum_vacuum_cost_limit` and `autovacuum_vacuum_cost_delay` control how aggressively vacuum can do I/O.

Possible whys to tune autovacuum:

1. One table has much heavier update/delete churn than the rest of the database.
2. Dead tuples build up between autovacuum runs.
3. Planner estimates become stale before autoanalyze runs.
4. Autovacuum runs, but too slowly for the table's change rate.
5. Server-wide defaults are fine for most tables but not for a specific hot OLTP table.

Best practice:

Start with evidence from `pg_stat_user_tables`, `pgstattuple`, query performance, and workload patterns. Do not disable autovacuum. Avoid changing server-wide values first unless many tables have the same problem. For one hot table, prefer a per-table override like this lab shows, monitor the result, and adjust gradually.

For large or high-churn OLTP tables, common tuning is to lower the vacuum/analyze scale factors so maintenance starts before dead tuples become a performance or storage issue. For small or low-churn tables, the defaults are often enough.

```sql
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
```

### 9. Check the cleanup horizon and idle-in-transaction risk

DBA question: "Is a session holding back cleanup even after VACUUM runs?"

First evidence to collect: run the `backend_xmin` and `pg_stat_activity` queries before assuming autovacuum is broken.

Why this step matters:

PostgreSQL cannot remove a dead row version if an older active transaction might still need to see it. A session that is `idle in transaction` can therefore block cleanup even when it is not currently running a query. This is one of the most important PostgreSQL operational differences for Oracle DBAs to understand.

What each query shows:

1. `backend_xmin` age shows whether any active session is holding back tuple cleanup.
2. `pg_stat_activity` identifies the oldest transactions, including sessions that may be idle but still inside an open transaction.

What the key fields mean:

1. `backend_xmin` is the oldest transaction ID that a backend still needs for MVCC visibility. If it stays old, vacuum may be unable to remove some dead tuples.
2. `xact_start` shows when the current transaction began. Older transactions are more likely to hold back cleanup.
3. `state = 'idle in transaction'` means the client opened a transaction and stopped sending work without committing or rolling back.
4. `state_change` helps show how long the session has been in its current state.

Best practice:

Monitor for old transactions and `idle in transaction` sessions. Fix the application pattern first: transactions should be short, explicit, and closed with `COMMIT` or `ROLLBACK`. Use timeouts such as `idle_in_transaction_session_timeout` where appropriate, and terminate sessions only through the approved operational process after identifying the owner/application.

```sql
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
```

### 10. Demonstrate `work_mem` as a session-level experiment

DBA question: "Should memory tuning be tested at session/workload scope before changing the whole server?"

First evidence to collect: run the same query with `EXPLAIN (ANALYZE, BUFFERS)` before and after the session-level `work_mem` change, then compare sort/hash behavior, execution time, and buffer usage.

Why this step matters:

`work_mem` controls memory available to operations such as sorts, hashes, aggregates and some joins. More memory can help one query, but setting it too high globally can multiply memory usage across many sessions and plan nodes.

What each statement does:

1. `SHOW work_mem` captures the current session setting.
2. `SET work_mem = '64MB'` changes memory only for this session so the test does not affect other users.
3. `EXPLAIN (ANALYZE, BUFFERS)` shows actual execution time, buffer usage and whether sort/hash behavior changes.
4. `RESET work_mem` returns the session to the original server default.

Possible whys to tune `work_mem`:

1. Sort or hash operations spill to disk.
2. Reporting queries need more memory than short OLTP lookups.
3. A specific role or workload has predictable larger analytical queries.
4. The server has enough memory headroom for a targeted increase.

Possible whys not to raise it globally:

1. `work_mem` can be used multiple times per query plan.
2. Every active session can consume it at the same time.
3. A safe value for one query can become unsafe under concurrency.
4. Raising it globally can create memory pressure instead of fixing the root cause.

Best practice:

Test `work_mem` at the session or role/workload level before changing it server-wide. Estimate worst-case memory as `work_mem` times active sessions times sort/hash nodes in each plan. For mixed OLTP systems, avoid large global values; tune specific workloads only after proving spill or sort pressure with execution plans and monitoring.

Parameter tuning scope:

| Scope | How to configure | When to use | Risk |
|---|---|---|---|
| Current session | `SET parameter = value;` | Safest for a lab or one troubleshooting session. | Goes away when the session ends or after `RESET`. |
| Current transaction | `SET LOCAL parameter = value;` | Safe test inside one transaction. | Goes away at `COMMIT` or `ROLLBACK`. |
| Specific role | `ALTER ROLE role_name SET parameter = value;` | Good for one application user or reporting role. | Affects every new session for that role. |
| Specific database | `ALTER DATABASE db_name SET parameter = value;` | Good when one database has different workload needs. | Affects all new sessions to that database. |
| Server parameter | Azure portal or `az postgres flexible-server parameter set` | Use only after testing and when the setting should apply broadly. | Broadest blast radius; some settings require restart. |

Useful parameters DBAs should know:

| Parameter | Why use it | How to test safely | Best practice |
|---|---|---|---|
| `work_mem` | Memory for sort, hash, aggregate and join operations. | `SET work_mem = '64MB';` then rerun `EXPLAIN (ANALYZE, BUFFERS)`. | Tune per session, role, or workload first. Avoid large global values. |
| `statement_timeout` | Stops runaway queries. | `SET statement_timeout = '30s';` | Use as a safety guard for app/reporting users. Do not set so low that normal maintenance fails. |
| `idle_in_transaction_session_timeout` | Closes sessions left idle inside a transaction. | `SET idle_in_transaction_session_timeout = '60s';` | Useful protection for OLTP apps; test app behavior before enforcing broadly. |
| `lock_timeout` | Prevents DDL or maintenance from waiting forever on locks. | `SET lock_timeout = '10s';` | Good for deployment scripts and admin sessions. Handle timeout errors explicitly. |
| `search_path` | Controls schema resolution order. | `SET search_path = sales, public;` | Prefer explicit schema names in production code. Be careful with security-sensitive functions. |
| `max_parallel_workers_per_gather` | Controls parallel workers available to one query. | `SET max_parallel_workers_per_gather = 2;` | Test for reporting/analytics queries. More parallelism is not always faster under concurrency. |
| `enable_seqscan` | Diagnostic toggle to test whether an index path could help. | `SET enable_seqscan = off;` | Use only for troubleshooting. Do not leave disabled as a production default. |
| `enable_nestloop`, `enable_hashjoin`, `enable_mergejoin` | Diagnostic toggles to compare join strategies. | `SET enable_hashjoin = off;` then compare plans. | Use to learn planner behavior, not as a permanent fix. Fix stats, indexes, or SQL first. |
| `default_statistics_target` | Increases detail collected by `ANALYZE`. | Prefer `ALTER TABLE ... ALTER COLUMN ... SET STATISTICS` for a specific column. | Avoid raising globally unless many columns need better statistics. |
| `effective_cache_size` | Planner estimate of cache available for data/index pages. | Review current value with `SHOW effective_cache_size;`. | Server-level planning hint; change only with evidence and platform guidance. |

For this workshop, we only perform the hands-on demo with `work_mem` because it is easy to show safely in one session. The other parameters are included so DBAs know what exists, how to test safely, and which settings should remain diagnostic-only.

```sql
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
```

Close with the risk: `work_mem` applies per sort/hash node, per connection. A value that looks safe in one session can become a memory incident under real concurrency.

## Participant output

Each participant should be able to answer:

1. What changed after the update?
2. What did `n_dead_tup` and `pgstattuple` show?
3. What did routine `VACUUM` fix?
4. What did it not fix?
5. Which session state can silently block cleanup?
6. Why is global `work_mem` tuning dangerous?

## Cleanup

Run this at the end of the lab if participants need to reset the database and run the lab again.

What this cleanup does:

1. Drops the disposable MVCC lab table.
2. Removes any per-table autovacuum options with the table.
3. Leaves the original AdventureWorks tables unchanged.
4. Leaves `pgstattuple` installed because it is a workshop prerequisite and may be used by other labs.

```sql
DROP TABLE IF EXISTS public.mvcc_lab_salesorderheader;
```
