# S2G - DBA runbook: five everyday cases

## Lab objective

Give Oracle DBAs a PostgreSQL-first incident reflex:

> symptom -> first check -> confirming evidence -> likely root cause -> safe first action -> proof it improved

The point is not to memorize views. The point is to know which evidence to collect first and avoid panic actions such as "add vCores," "restart," "rebuild replica," or "create indexes blindly."

## Required extension

```sql
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
```

## Case 1: CPU spike from inefficient SQL

**First check:** Azure Monitor CPU chart and incident time window.

**Confirming evidence:**

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

```sql
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_aw_salesorderheader_customerid
ON sales.salesorderheader (customerid);

CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_aw_salesorderdetail_salesorderid
ON sales.salesorderdetail (salesorderid);

ANALYZE sales.salesorderheader;
ANALYZE sales.salesorderdetail;
```

**Proof:** same `EXPLAIN (ANALYZE, BUFFERS)` shows lower time/buffers and a better access path.

## Case 2: Bad plan from stale or insufficient statistics

**First check:** estimated rows vs actual rows in `EXPLAIN`.

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

```sql
ANALYZE VERBOSE sales.salesorderheader;

CREATE STATISTICS IF NOT EXISTS st_aw_salesorderheader_status_orderdate
  (dependencies, ndistinct)
ON status, orderdate
FROM sales.salesorderheader;

ANALYZE sales.salesorderheader;
```

**Proof:** re-run the same `EXPLAIN` and compare estimates, actual rows, time and buffers.

## Case 3: Blocking chain / idle-in-transaction

**First check:** live sessions and blockers.

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

## Case 4: Connection saturation / pooling

**First check:** active and idle sessions vs `max_connections`.

```sql
SELECT count(*) AS total_connections,
       count(*) FILTER (WHERE state = 'active') AS active_connections,
       count(*) FILTER (WHERE state = 'idle') AS idle_connections,
       count(*) FILTER (WHERE state = 'idle in transaction') AS idle_in_txn_connections,
       current_setting('max_connections')::int AS max_connections
FROM pg_stat_activity;
```

**Confirming evidence:**

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

## Case 5: WAL growth / replica lag risk

**First check:** replication lag, primary-side transaction age, and replication slot retention.

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

## Participant output

For every case, each group should answer:

1. What is the symptom?
2. What is the first check?
3. What confirms the root cause?
4. What is the safest first action?
5. What metric or view proves it improved?
