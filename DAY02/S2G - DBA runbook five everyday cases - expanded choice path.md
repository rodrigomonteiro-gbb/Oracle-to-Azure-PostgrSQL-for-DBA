# S2G - DBA runbook: five everyday cases - expanded choice path

## Final objective

Practice the production support pattern:

> symptom -> first check -> confirming evidence -> likely root cause -> safe first action -> proof

This version preserves all five cases, but the recommended classroom flow is **two live cases plus three rapid triage cards**. Participants with extra time can run more cases hands-on.

Run `diagnostics/day2_adventureworks_preflight.sql` before this lab to confirm the target database, extensions, and source AdventureWorks tables.

## Evidence contract

| Stage | Required artifact |
|---|---|
| Baseline | Query output or metric before action |
| Symptom | Evidence proving the issue exists |
| Hypothesis | One sentence naming likely cause |
| Change | Exactly one safe change |
| Proof | Same query or metric rerun |
| Cleanup | Lab-created objects removed |

## Pre-flight

Complete extension setup before the runbook. Do not spend the capstone restarting the server.

```sql
SELECT extname,
       extversion
FROM pg_extension
WHERE extname = 'pg_stat_statements';

SHOW shared_preload_libraries;
SHOW pg_stat_statements.track;

SELECT count(*) AS captured_statements
FROM pg_stat_statements;
```

Expected:

1. `pg_stat_statements` is installed in `AdventureWorks`.
2. `shared_preload_libraries` includes `pg_stat_statements`.
3. `pg_stat_statements.track` returns `all`.
4. `captured_statements` is greater than zero after workload runs.

If the setup is not ready, use captured evidence cards and fix the extension outside runbook time.

## Create disposable runbook tables

This avoids changing shared AdventureWorks tables and makes reruns deterministic.

```sql
DROP TABLE IF EXISTS public.d2runbook_salesorderheader;
DROP TABLE IF EXISTS public.d2runbook_salesorderdetail;
DROP TABLE IF EXISTS public.d2runbook_customer;
DROP TABLE IF EXISTS public.d2runbook_person;

CREATE TABLE public.d2runbook_salesorderheader AS
SELECT *
FROM sales.salesorderheader;

CREATE TABLE public.d2runbook_salesorderdetail AS
SELECT *
FROM sales.salesorderdetail;

CREATE TABLE public.d2runbook_customer AS
SELECT *
FROM sales.customer;

CREATE TABLE public.d2runbook_person AS
SELECT *
FROM person.person;

ALTER TABLE public.d2runbook_salesorderheader
  ADD PRIMARY KEY (salesorderid);

ALTER TABLE public.d2runbook_salesorderdetail
  ADD PRIMARY KEY (salesorderid, salesorderdetailid);

ANALYZE public.d2runbook_salesorderheader;
ANALYZE public.d2runbook_salesorderdetail;
ANALYZE public.d2runbook_customer;
ANALYZE public.d2runbook_person;
```

## How to read EXPLAIN (ANALYZE, BUFFERS)

Why `ANALYZE`:

1. `EXPLAIN` alone shows the estimated plan only.
2. `EXPLAIN ANALYZE` executes the query and shows actual rows and time.
3. Estimated-vs-actual row gaps show whether planner information was good.

Why `BUFFERS`:

1. Shared hits can still mean CPU work if many pages are processed from memory.
2. Shared reads show pages read into cache.
3. Temp reads/writes show sort/hash spill to disk.

What to look for:

| Plan clue | Meaning | What to ask |
|---|---|---|
| `Seq Scan` on large table | Table scan | Is an index justified or is most of the table needed? |
| `Rows Removed by Filter` high | Many rows discarded | Can a predicate index reduce scanned rows? |
| Estimated rows far from actual rows | Bad estimate | Do statistics need refresh or extension? |
| `Nested Loop` with many loops | Repeated lookup | Is the inner side indexed? |
| Temp reads/writes | Spill to disk | Is memory too low or query too broad? |

Best practice: the desired outcome is not "the plan uses an index." The desired outcome is "the plan does less work and the same evidence improves."

## Recommended delivery

| Delivery block | Mode | Cases |
|---|---|---|
| Live case 1 | Hands-on | CPU / expensive SQL |
| Live case 2 | Hands-on | Blocking / idle-in-transaction |
| Rapid cards | Group discussion | Bad stats, connection saturation, WAL/replica lag |
| Extra time | Participant choice | Any remaining case hands-on |

## Case 1: CPU spike from inefficient SQL

### Issue

CPU is high because one or more SQL statements are doing too much work. Do not assume the database needs more vCores until top SQL and plan evidence prove the cause.

### First evidence

```sql
SELECT calls,
       round(total_exec_time::numeric, 2) AS total_ms,
       round(mean_exec_time::numeric, 2) AS mean_ms,
       rows,
       left(query, 160) AS query
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 10;
```

Why: find the highest-impact SQL before changing indexes or capacity.

What to look for:

1. High `total_ms`: most total runtime.
2. High `mean_ms`: expensive per execution.
3. High `calls`: moderate query cost multiplied by volume.

How to fix: inspect the suspect SQL with `EXPLAIN (ANALYZE, BUFFERS)`, make one targeted change, and rerun the same evidence.

### Suspect query with selective predicate

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT h.customerid,
       count(DISTINCT h.salesorderid) AS order_count,
       sum(d.linetotal) AS revenue
FROM public.d2runbook_salesorderheader h
JOIN public.d2runbook_salesorderdetail d
  ON d.salesorderid = h.salesorderid
WHERE h.orderdate >= DATE '2014-05-01'
  AND h.orderdate <  DATE '2014-06-01'
GROUP BY h.customerid
ORDER BY revenue DESC
LIMIT 100;
```

What to look for in `EXPLAIN`:

1. Whether the date predicate scans too many header rows.
2. Whether the detail join repeats too much work.
3. Whether estimated rows are close to actual rows.
4. Whether buffers drop after indexing.

### One targeted change

```sql
CREATE INDEX CONCURRENTLY IF NOT EXISTS public.d2runbook_soh_orderdate_customerid_idx
ON public.d2runbook_salesorderheader (orderdate, customerid, salesorderid);

CREATE INDEX CONCURRENTLY IF NOT EXISTS public.d2runbook_sod_salesorderid_idx
ON public.d2runbook_salesorderdetail (salesorderid);

ANALYZE public.d2runbook_salesorderheader;
ANALYZE public.d2runbook_salesorderdetail;
```

Why these indexes:

1. `orderdate` supports the selective date range.
2. `customerid` supports grouping after the date filter.
3. `salesorderid` supports the join to details.

Proof: rerun the same `EXPLAIN (ANALYZE, BUFFERS)` and compare rows, buffers, and execution time. If the plan still prefers a sequential scan, the correct conclusion may be that no index is justified for that query shape.

## Case 2: Bad plan from stale or insufficient statistics

### Issue

The SQL may be reasonable, but PostgreSQL may choose the wrong plan because it estimates row counts incorrectly.

### First evidence

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT salesorderid,
       customerid,
       orderdate,
       status,
       totaldue
FROM public.d2runbook_salesorderheader
WHERE status = 5
  AND orderdate >= DATE '2013-01-01'
ORDER BY orderdate DESC
LIMIT 100;
```

Why: estimated rows vs actual rows is the main clue for stale or insufficient statistics.

What to look for:

1. `rows=` estimate far from `actual rows=`.
2. Bad estimate appearing after combined predicates.
3. More buffers touched than expected.

### Confirming evidence

```sql
SELECT attname,
       n_distinct,
       null_frac,
       correlation
FROM pg_stats
WHERE schemaname = 'public'
  AND tablename = 'd2runbook_salesorderheader'
  AND attname IN ('status', 'orderdate', 'customerid');
```

Why: PostgreSQL uses statistics to estimate filter and join result sizes.

What to look for:

1. `n_distinct` indicates selectivity.
2. `null_frac` affects null-sensitive predicates.
3. `correlation` affects scan choices.
4. Single-column statistics may not describe relationships between `status` and `orderdate`.

How to fix:

```sql
ANALYZE VERBOSE public.d2runbook_salesorderheader;

CREATE STATISTICS IF NOT EXISTS public.d2runbook_soh_status_orderdate_stats
  (dependencies, ndistinct)
ON status, orderdate
FROM public.d2runbook_salesorderheader;

ANALYZE public.d2runbook_salesorderheader;
```

Proof: rerun the same `EXPLAIN` and compare estimates to actual rows.

## Case 3: Blocking chain / idle-in-transaction

### Issue

One session is waiting because another session holds a lock. PostgreSQL can look "hung" while it is actually waiting correctly.

### Create the incident with two sessions

Session A:

```sql
BEGIN;

UPDATE public.d2runbook_salesorderheader
SET freight = freight
WHERE salesorderid = (
  SELECT min(salesorderid)
  FROM public.d2runbook_salesorderheader
);

-- Leave this transaction open.
```

Session B:

```sql
UPDATE public.d2runbook_salesorderheader
SET freight = freight
WHERE salesorderid = (
  SELECT min(salesorderid)
  FROM public.d2runbook_salesorderheader
);
```

### First evidence

Diagnostic session:

```sql
SELECT blocked.pid AS blocked_pid,
       blocking.pid AS blocking_pid,
       blocked.wait_event_type,
       blocked.wait_event,
       now() - blocked.query_start AS blocked_for,
       left(blocked.query, 120) AS blocked_query,
       left(blocking.query, 120) AS blocking_query
FROM pg_stat_activity blocked
JOIN LATERAL unnest(pg_blocking_pids(blocked.pid)) p(pid)
  ON true
JOIN pg_stat_activity blocking
  ON blocking.pid = p.pid;
```

Why: identify the blocker before canceling, terminating, or restarting.

What to look for:

1. `blocked_pid` is waiting.
2. `blocking_pid` is causing the wait.
3. `wait_event_type = Lock` confirms lock wait.
4. The blocking query often looks idle because the lock was taken earlier in the transaction.

How to fix: return to Session A and run:

```sql
ROLLBACK;
```

Proof: Session B completes, and the blocking query returns no rows.

Best practice: fix application transaction handling first. Use cancel/terminate only through the approved operational process.

## Case 4: Connection saturation / pooling

### Issue

The database is near its connection limit, but the root cause may be application connection behavior rather than CPU or database size.

### Evidence card or live query

```sql
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
```

Why: connection incidents are often caused by app pool size, connection leaks, or no pooling.

What to look for:

1. Total connections close to `max_connections`.
2. Many idle sessions from one app host.
3. Multiple app instances each holding oversized pools.
4. Any `idle in transaction` sessions.

How to fix: right-size app pools or introduce PgBouncer. Do not simply raise `max_connections` until memory impact is understood.

## Case 5: WAL growth / replica lag risk

### Issue

Replica lag and WAL growth can come from write volume, slow replay, old transactions, or retained WAL from a slot.

### Evidence card or live query

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

Why: these separate replica replay lag, old transactions, and retained WAL.

What to look for:

1. Empty `pg_stat_replication` means no connected replica from this primary.
2. Empty `pg_replication_slots` means no slots exist.
3. `active = false` with retained WAL means a disconnected consumer may be retaining WAL.
4. Old `xact_start` means long transactions may be contributing to pressure.

How to fix: address the write source, long transaction, or CDC consumer first. Rebuild replica only after proving it is necessary.

## Rapid triage worksheet

| Case | Symptom | First evidence query | Likely why | Safe first action | Proof |
|---|---|---|---|---|---|
| CPU | High CPU | `pg_stat_statements`, then `EXPLAIN` | Query doing too much work | One targeted SQL/index/stat change | Same plan improves |
| Stats | Bad estimate | `EXPLAIN`, then `pg_stats` | Stale or insufficient stats | `ANALYZE` or extended stats | Estimate closer to actual |
| Blocking | Query waits | `pg_blocking_pids()` | Transaction holds lock | Owner closes transaction | Wait clears |
| Connections | Max connections risk | `pg_stat_activity` counts | Pool/leak/no pooling | Resize pool/PgBouncer | Idle sessions drop |
| WAL | Lag or retained WAL | replication + slot views | Write burst, slow replay, inactive slot | Fix source/consumer | Lag or retention drops |

## Cleanup

Do not wrap `DROP INDEX CONCURRENTLY` in `BEGIN` / `COMMIT`.

```sql
DROP INDEX CONCURRENTLY IF EXISTS public.d2runbook_soh_orderdate_customerid_idx;
DROP INDEX CONCURRENTLY IF EXISTS public.d2runbook_sod_salesorderid_idx;

DROP STATISTICS IF EXISTS public.d2runbook_soh_status_orderdate_stats;

DROP TABLE IF EXISTS public.d2runbook_salesorderheader;
DROP TABLE IF EXISTS public.d2runbook_salesorderdetail;
DROP TABLE IF EXISTS public.d2runbook_customer;
DROP TABLE IF EXISTS public.d2runbook_person;
```
