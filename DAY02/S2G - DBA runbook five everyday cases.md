# S2G - DBA runbook: five everyday cases

## Lab objective

Give Oracle DBAs a PostgreSQL-first incident reflex:

> symptom -> first check -> confirming evidence -> likely root cause -> safe first action -> proof it improved

The point is not to memorize views. The point is to know which evidence to collect first and avoid panic actions such as "add vCores," "restart," "rebuild replica," or "create indexes blindly."

## Required extension

This runbook uses `pg_stat_statements` for Case 1 because PostgreSQL DBAs need query-level evidence before creating indexes or changing capacity. On Azure Database for PostgreSQL Flexible Server, this extension has three requirements:

1. Allow it in `azure.extensions`.
2. Preload it in `shared_preload_libraries`.
3. Enable collection with `pg_stat_statements.track = all`.

If `pg_stat_statements.track = none`, the extension can be installed and preloaded but still return zero rows.

Important: `shared_preload_libraries` is a comma-separated server parameter. Preserve the existing Azure-managed entries and add `pg_stat_statements` if it is missing; do not replace the value with only `pg_stat_statements`.

Azure CLI setup, PowerShell:

```powershell
az postgres flexible-server parameter set `
  --resource-group <resource-group> `
  --server-name <server-name> `
  --name azure.extensions `
  --value "pg_stat_statements,pg_trgm,uuid-ossp,pgcrypto,pgstattuple"

az postgres flexible-server parameter set `
  --resource-group <resource-group> `
  --server-name <server-name> `
  --name shared_preload_libraries `
  --value "pg_cron,pg_stat_statements,azure,pg_qs,pgaadauth,pgms_stats,pgms_wait_sampling,pg_availability"

az postgres flexible-server parameter set `
  --resource-group <resource-group> `
  --server-name <server-name> `
  --name pg_stat_statements.track `
  --value "all"
```

Azure CLI setup, Bash:

```bash
az postgres flexible-server parameter set \
  --resource-group <resource-group> \
  --server-name <server-name> \
  --name azure.extensions \
  --value "pg_stat_statements,pg_trgm,uuid-ossp,pgcrypto,pgstattuple"

az postgres flexible-server parameter set \
  --resource-group <resource-group> \
  --server-name <server-name> \
  --name shared_preload_libraries \
  --value "pg_cron,pg_stat_statements,azure,pg_qs,pgaadauth,pgms_stats,pgms_wait_sampling,pg_availability"

az postgres flexible-server parameter set \
  --resource-group <resource-group> \
  --server-name <server-name> \
  --name pg_stat_statements.track \
  --value "all"
```

Restart the Flexible Server after changing `shared_preload_libraries` or if `pg_stat_statements.track` does not change after reconnecting. Then connect to the AdventureWorks database and create the extension:

```sql
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

SHOW shared_preload_libraries;
SHOW pg_stat_statements.track;
```

Continue only when `shared_preload_libraries` includes `pg_stat_statements` and `pg_stat_statements.track` returns `all`.

## Optional pgbench activity for Case 1

Use this only when `pg_stat_statements` has too little activity for the CPU-spike case. Run `pgbench` from PowerShell or Bash, not from inside `psql`.

DBA question: "How do I generate safe query activity so `pg_stat_statements` has evidence?"

Best practice: keep the run short, use a disposable or known lab workload, and confirm `pg_stat_statements.track = all` before running `pgbench`.

PowerShell:

```powershell
$env:PGPASSWORD = "<password>"

@"
SELECT c.customerid,
       count(DISTINCT h.salesorderid) AS total_orders,
       sum(d.linetotal) AS lifetime_value
FROM sales.customer c
JOIN sales.salesorderheader h
  ON h.customerid = c.customerid
JOIN sales.salesorderdetail d
  ON d.salesorderid = h.salesorderid
GROUP BY c.customerid
ORDER BY lifetime_value DESC
LIMIT 100;
"@ | Set-Content -Path "$env:TEMP\pgbench_runbook_case1.sql" -Encoding ascii

pgbench `
  -h <server-name>.postgres.database.azure.com `
  -U <admin-user> `
  -d AdventureWorks `
  -c 4 `
  -j 2 `
  -T 60 `
  -f "$env:TEMP\pgbench_runbook_case1.sql"
```

Bash:

```bash
export PGPASSWORD="<password>"

cat > /tmp/pgbench_runbook_case1.sql <<'SQL'
SELECT c.customerid,
       count(DISTINCT h.salesorderid) AS total_orders,
       sum(d.linetotal) AS lifetime_value
FROM sales.customer c
JOIN sales.salesorderheader h
  ON h.customerid = c.customerid
JOIN sales.salesorderdetail d
  ON d.salesorderid = h.salesorderid
GROUP BY c.customerid
ORDER BY lifetime_value DESC
LIMIT 100;
SQL

pgbench \
  -h <server-name>.postgres.database.azure.com \
  -U <admin-user> \
  -d AdventureWorks \
  -c 4 \
  -j 2 \
  -T 60 \
  -f /tmp/pgbench_runbook_case1.sql
```

Then reconnect with `psql` and query `pg_stat_statements`.

## How to Read EXPLAIN (ANALYZE, BUFFERS)

Use this section before Case 1 and Case 2. The goal is not to understand every line of the plan. The goal is to find the first few clues that explain why the query is slow or why the planner chose a bad path.

Why we use `ANALYZE`:

1. `EXPLAIN` alone shows the estimated plan only; it does not run the query.
2. `EXPLAIN ANALYZE` runs the query and shows actual rows and actual time.
3. Comparing estimated rows to actual rows tells the DBA whether the optimizer had good information.
4. Because it runs the query, do this carefully on production systems, especially for `INSERT`, `UPDATE`, `DELETE`, or very expensive reports.

Why we use `BUFFERS`:

1. `BUFFERS` shows how much work came from memory vs disk/cache reads.
2. High shared buffer hits can still be CPU-heavy if the query scans or joins too many rows.
3. High reads can indicate I/O pressure or a query that is touching more data than expected.
4. Temp reads/writes indicate sorts, hashes, or aggregates spilled to disk.

What to look for first:

| Plan clue | What it usually means | DBA question |
|---|---|---|
| `Seq Scan` on a large table | PostgreSQL is scanning the table instead of using an index. | Is there a useful filter or join index? |
| `Rows Removed by Filter` is high | The query read many rows and discarded most of them. | Would an index reduce the rows scanned? |
| Estimated rows very different from actual rows | Statistics may be stale, too coarse, or missing correlation. | Should we run `ANALYZE` or create extended statistics? |
| `Nested Loop` with many loops | A small lookup may be repeating many times. | Is the inner side indexed? Is the estimate wrong? |
| `Hash Join` or `HashAggregate` with temp writes | Memory was not enough for the operation. | Is `work_mem` too low for this workload, or is the query too large? |
| High `Execution Time` | The query actually ran slowly. | Which operator consumed most time? |
| High planning time | Planning itself is expensive. | Are there too many partitions, indexes, or complex predicates? |

Best practice:

Read the plan from the most expensive or most suspicious node, not only from top to bottom. Fix one cause at a time, rerun the same `EXPLAIN (ANALYZE, BUFFERS)`, and compare actual rows, buffers, and execution time.

## Case 1: CPU spike from inefficient SQL

**Issue:** CPU is high because one or more SQL statements are doing too much work. The database may not need more vCores yet; first prove which statement is responsible and whether it is scanning, joining, sorting, or aggregating too much data.

**First check:** Azure Monitor CPU chart and incident time window.

**First evidence to collect:** run the `pg_stat_statements` query for top total execution time, then run `EXPLAIN (ANALYZE, BUFFERS)` for the suspect statement.

**Confirming evidence:**

This query ranks statements by total execution time so the DBA can identify the SQL consuming the most runtime during the incident window. It tells you which statement to inspect next with `EXPLAIN (ANALYZE, BUFFERS)`.

**Why:** CPU incidents should start with the SQL consuming the most time, not with random index creation or immediate scale-up.

**What to look for:** high `total_exec_time` means the statement consumed the most total time across all calls. High `mean_exec_time` means each execution is expensive. High `calls` with moderate time can still create CPU pressure through volume.

**How to fix:** take the top suspect query, run `EXPLAIN (ANALYZE, BUFFERS)`, identify whether the cost is from scans, joins, sorts, aggregation, or bad estimates, then make one targeted change and compare again.

**Possible whys:**

1. Missing join/filter indexes.
2. A report query is running too often.
3. The query returns or aggregates more rows than expected.
4. Stale statistics caused a poor plan.
5. A recent release changed query shape or parameter values.

```sql
SELECT calls,
       total_exec_time,
       mean_exec_time,
       rows,
       left(query, 160) AS query
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 10;
```

**AdventureWorks suspect statement:**

This query is the statement to diagnose. `EXPLAIN (ANALYZE, BUFFERS)` shows the actual plan, actual timing and buffer usage so the DBA can prove whether missing indexes or inefficient joins are contributing to CPU pressure.

What to look for in the `EXPLAIN` output:

1. Look for `Seq Scan` on `sales.salesorderheader` or `sales.salesorderdetail`.
2. Look for high row counts flowing into the join and aggregate.
3. Compare estimated rows to actual rows. Large differences can mean stale or insufficient statistics.
4. Check `Buffers:`. Many shared hits can still mean CPU pressure because PostgreSQL is processing many pages from memory.
5. Check whether the join columns have useful indexes before creating anything new.

```sql
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
```

**Safe first action:** state the missing access path, create one index at a time, run `ANALYZE`, and re-run the exact same statement.

These statements add targeted join indexes and refresh statistics. `CONCURRENTLY` reduces blocking risk compared with a regular index build.

Why these indexes:

1. `sales.salesorderheader.customerid` supports joining orders back to customers.
2. `sales.salesorderdetail.salesorderid` supports joining order detail rows to order headers.
3. The goal is to reduce repeated scans and make the join path cheaper.

```sql
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_aw_salesorderheader_customerid
ON sales.salesorderheader (customerid);

CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_aw_salesorderdetail_salesorderid
ON sales.salesorderdetail (salesorderid);

ANALYZE sales.salesorderheader;
ANALYZE sales.salesorderdetail;
```

**Proof:** same `EXPLAIN (ANALYZE, BUFFERS)` shows lower time/buffers and a better access path.

**Best practice:** do not create many indexes blindly. Prove the access path, add the smallest useful index, refresh statistics, and compare the same query before and after.

## Case 2: Bad plan from stale or insufficient statistics

**Issue:** the SQL text may be reasonable, but PostgreSQL may choose the wrong plan because its statistics do not describe the current data well enough.

**First check:** estimated rows vs actual rows in `EXPLAIN`.

**First evidence to collect:** run `EXPLAIN (ANALYZE, BUFFERS)` and compare estimated rows to actual rows. Then inspect `pg_stats` for the columns used in filters and joins.

This query uses `EXPLAIN (ANALYZE, BUFFERS)` to compare estimated rows to actual rows. Large estimate errors are a sign that statistics are stale or not detailed enough.

**How to read it:** if PostgreSQL expected a few rows but got many, or expected many but got a few, the planner may choose the wrong join type, scan type, or sort strategy.

What to look for in the `EXPLAIN` output:

1. Compare `rows=` estimates with `actual rows=` for each major node.
2. If estimated and actual rows are far apart near the table scan, start with table/column statistics.
3. If the estimate becomes wrong after combining predicates, consider extended statistics.
4. If the plan sorts a large result, check whether the query needs an index, better filtering, or more targeted memory.
5. Check `Buffers:` to see whether the bad estimate caused PostgreSQL to touch many more pages than expected.

**Possible whys:**

1. Table changed a lot since the last `ANALYZE`.
2. Data is skewed and default statistics are not detailed enough.
3. Two columns are correlated, but the planner is estimating them independently.
4. A major load or purge happened without statistics refresh.

```sql
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
```

**Confirming evidence:**

This query reads column statistics for the filter and join columns so the DBA can see distinct values, null fraction and physical correlation.

**Why:** PostgreSQL uses statistics to estimate how many rows a filter or join will return. If the statistics are stale or incomplete, the planner can pick the wrong scan type, join order, or join algorithm.

**What to look for:**

1. `n_distinct` helps PostgreSQL estimate how selective a predicate is.
2. `null_frac` matters when predicates include or exclude null values.
3. `correlation` helps the planner understand whether table order matches column order, which can affect scan choices.
4. These are single-column statistics; they do not fully describe relationships between columns like `status` and `orderdate`.

**How to fix:**

1. Run `ANALYZE` after large data changes.
2. Use extended statistics when multiple columns are correlated and estimates are wrong after combined predicates.
3. Increase statistics target only for specific columns when default sampling is not enough.
4. Rerun the same `EXPLAIN (ANALYZE, BUFFERS)` and confirm estimates are closer to actual rows.

```sql
SELECT attname,
       n_distinct,
       null_frac,
       correlation
FROM pg_stats
WHERE schemaname = 'sales'
  AND tablename = 'salesorderheader'
  AND attname IN ('status', 'orderdate', 'customerid');
```

**Safe first action:**

These statements refresh base statistics, create multicolumn extended statistics for correlated predicates, and refresh statistics again so the planner can use them.

Why these actions:

1. `ANALYZE VERBOSE` refreshes current single-column statistics and shows what PostgreSQL analyzed.
2. `CREATE STATISTICS ... (dependencies, ndistinct)` helps PostgreSQL estimate combined predicates across `status` and `orderdate`.
3. The second `ANALYZE` populates the new extended statistics object.

```sql
ANALYZE VERBOSE sales.salesorderheader;

CREATE STATISTICS IF NOT EXISTS st_aw_salesorderheader_status_orderdate
  (dependencies, ndistinct)
ON status, orderdate
FROM sales.salesorderheader;

ANALYZE sales.salesorderheader;
```

**Proof:** re-run the same `EXPLAIN` and compare estimates, actual rows, time and buffers.

**Best practice:** run `ANALYZE` after large data changes. Use extended statistics for correlated columns; do not raise statistics targets globally unless evidence shows many columns need it.

## Case 3: Blocking chain / idle-in-transaction

**First check:** live sessions and blockers.

**First evidence to collect:** run the blocking query first. If no blocking row appears, run the idle-in-transaction query to find sessions that may still be holding locks or old snapshots.

This query joins blocked sessions to their blockers using `pg_blocking_pids`, making the blocking chain visible without guessing from application symptoms.

**Why:** blocking incidents should identify the blocker before canceling sessions or restarting services.

**What to look for:** `blocked_pid` is waiting. `blocking_pid` is the session causing the wait. The query snippets show what each side was doing. `wait_event_type = Lock` confirms the blocked session is waiting on a lock.

**How to fix:** contact the owner of the blocking session first. If it is safe, ask them to commit or roll back. Use `pg_cancel_backend` for a running statement, or `pg_terminate_backend` only when the approved process allows it.

**Possible whys:**

1. A transaction updated rows and did not commit.
2. A schema change or index operation is blocking application work.
3. A manual DBA session left a transaction open.
4. Application retry logic increased lock contention.

```sql
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
```

**Idle-in-transaction evidence:**

This query finds sessions that are doing no work but still holding an open transaction. Those sessions can hold locks and delay cleanup.

**Why:** an idle transaction can hold locks and old MVCC snapshots even when it looks inactive.

**What to look for:** focus on the oldest `xact_age` and sessions in `idle in transaction`. Normal `idle` sessions are less concerning than `idle in transaction`.

**How to fix:** close the transaction with `COMMIT` or `ROLLBACK`, fix the application code path that leaves transactions open, and consider `idle_in_transaction_session_timeout` for protection.

```sql
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
```

**Safe first action:** identify owner/application first. Cancel or terminate only through the agreed operational process.

```sql
-- Less disruptive: cancel current query.
-- SELECT pg_cancel_backend(<pid>);

-- More disruptive: terminate the session.
-- SELECT pg_terminate_backend(<pid>);
```

**Proof:** blocker disappears, waiting query proceeds, and oldest transaction age drops.

**Best practice:** fix the transaction pattern in the application. Use short transactions and consider `idle_in_transaction_session_timeout` where appropriate.

## Case 4: Connection saturation / pooling

**First check:** active and idle sessions vs `max_connections`.

**First evidence to collect:** run the connection-count query, then group sessions by user/application/client to find the source.

This query compares total, active, idle and idle-in-transaction sessions against the configured connection limit.

**Why:** connection incidents are often caused by application connection behavior, not by the database needing a higher connection limit.

**What to look for:** high total connections near `max_connections` is risk. Many `idle` sessions usually point to pooling or application connection management. Any `idle in transaction` sessions are higher priority.

**How to fix:** reduce unnecessary idle sessions, right-size application pools, add PgBouncer when appropriate, and avoid raising `max_connections` until memory impact is understood.

**Possible whys:**

1. Application opens a new database connection per request.
2. Pool size is too large for the database tier.
3. Multiple app instances each have their own oversized pool.
4. A connection leak leaves sessions open.
5. Reporting or admin tools are holding many sessions.

```sql
SELECT count(*) AS total_connections,
       count(*) FILTER (WHERE state = 'active') AS active_connections,
       count(*) FILTER (WHERE state = 'idle') AS idle_connections,
       count(*) FILTER (WHERE state = 'idle in transaction') AS idle_in_txn_connections,
       current_setting('max_connections')::int AS max_connections
FROM pg_stat_activity;
```

**Confirming evidence:**

This query groups client sessions by user, application, client address and state so the DBA can identify which application or host is consuming connections.

**Why:** grouping sessions shows whether the issue is one application, one host, one user, or a general workload pattern.

**What to look for:** one application/client with many sessions, many idle sessions from app servers, or unexpected admin/reporting tools holding connections.

**How to fix:** tune that client or application pool first. If many clients are involved, review global pool architecture before changing database limits.

```sql
SELECT usename,
       application_name,
       client_addr,
       state,
       count(*) AS sessions
FROM pg_stat_activity
WHERE backend_type = 'client backend'
GROUP BY 1, 2, 3, 4
ORDER BY sessions DESC;
```

**Likely root cause:** application is not pooling, or pool size is wrong. Many `idle` app connections are different from `idle in transaction`.

**Safe first action:** introduce or resize PgBouncer/app-side pooling. Do not simply raise `max_connections` as the first move.

**Proof:** fewer idle app connections, stable active connections, no connection errors.

**Best practice:** size pools from expected concurrency, not maximum theoretical users. Raising `max_connections` can increase memory pressure and make the database less stable.

## Case 5: WAL growth / replica lag risk

**First check:** replication lag, primary-side transaction age, and replication slot retention.

**First evidence to collect:** run `pg_stat_replication`, then `pg_stat_activity`, then `pg_replication_slots`. These separate replica replay delay, long transactions, and retained WAL.

What each query shows:

1. `pg_stat_replication` shows whether connected replicas are caught up or lagging.
2. `pg_stat_activity` shows long-running primary-side transactions that may contribute to WAL pressure.
3. `pg_replication_slots` shows inactive or lagging slots that can retain WAL and grow storage.

**Why:** WAL growth and replica lag have different root causes. These queries separate normal write volume, replica replay delay, long transactions, and slot retention.

**What to look for:** empty `pg_stat_replication` means no connected replica from this primary. Empty `pg_replication_slots` means no slots exist. Non-empty slot rows with `active = false` and growing retained WAL are a CDC/replication risk. Old `xact_start` values show transactions that may be holding resources.

**How to fix:** if lag is from normal write volume, let the replica catch up or scale appropriately. If a CDC slot is inactive, repair the consumer. If a long transaction is holding resources, close that transaction through the approved process. Do not drop slots or rebuild replicas until ownership and impact are clear.

**Possible whys:**

1. Normal write volume increased after a batch or release.
2. Replica is undersized or busy with read workload.
3. CDC consumer is stopped or slow.
4. A logical replication slot was created for testing and abandoned.
5. Long transactions are holding resources and delaying cleanup.

```sql
SELECT client_addr,
       application_name,
       state,
       write_lag,
       flush_lag,
       replay_lag
FROM pg_stat_replication;

SELECT pid,
       usename,
       application_name,
       state,
       now() - xact_start AS txn_age,
       left(query, 120) AS query
FROM pg_stat_activity
WHERE xact_start IS NOT NULL
ORDER BY xact_start;

SELECT slot_name,
       plugin,
       slot_type,
       database,
       active,
       wal_status,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS wal_retained
FROM pg_replication_slots
ORDER BY pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) DESC NULLS LAST;
```

**Safe first action:** address the write source or disconnected CDC consumer first; confirm replica is connected and catching up before considering rebuild.

**Proof:** lag stabilizes/decreases, slot retained WAL stops growing, application read path is healthy.

**Best practice:** do not drop slots or rebuild replicas as the first reaction. Identify owner, prove the cause, and monitor lag/retention trends over time.

## Participant output

For every case, each group should answer:

1. What is the symptom?
2. What is the first check?
3. What confirms the root cause?
4. What is the safest first action?
5. What metric or view proves it improved?

## Cleanup

Run this at the end of the runbook lab if participants need to return AdventureWorks to the pre-lab state.

How to drop the indexes:

```sql
DROP INDEX CONCURRENTLY IF EXISTS sales.ix_aw_salesorderheader_customerid;
DROP INDEX CONCURRENTLY IF EXISTS sales.ix_aw_salesorderdetail_salesorderid;
```

`CONCURRENTLY` avoids taking the strongest lock on the table, but it cannot run inside an explicit transaction block. In other words, do not wrap these commands in `BEGIN` / `COMMIT`.

Drop the extended statistics object created in Case 2:

```sql
DROP STATISTICS IF EXISTS public.st_aw_salesorderheader_status_orderdate;
DROP STATISTICS IF EXISTS st_aw_salesorderheader_status_orderdate;
```

Refresh statistics after cleanup:

```sql
ANALYZE sales.salesorderheader;
ANALYZE sales.salesorderdetail;
```

What this cleanup does:

1. Removes the two lab-created indexes.
2. Removes the lab-created extended statistics object.
3. Refreshes planner statistics on the affected AdventureWorks tables.
4. Leaves `pg_stat_statements` installed because it is a workshop prerequisite and may be used by other labs.
