# S2E - MVCC, autovacuum and parameter tuning

## Lab objective

Help Oracle DBAs understand why PostgreSQL cleanup is a normal operating responsibility. Participants will use AdventureWorks-derived scratch tables to prove that updates create old row versions, dead tuples accumulate, VACUUM makes space reusable, long transactions can hold cleanup back, and `work_mem` must be tested carefully before becoming a server-wide setting.

## Key message for the room

The read-consistency goal is familiar from Oracle. The implementation is different: PostgreSQL keeps old row versions in the table until VACUUM can clean them. That is why dead tuples, bloat, autovacuum and transaction age are DBA topics here.

Use **closest operational equivalent** language. Do not say MVCC cleanup is "the same as undo."

## Required extension

```sql
CREATE EXTENSION IF NOT EXISTS pgstattuple;
```

## Lab steps

### 1. Create a disposable MVCC lab table

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

### 4. Prove old row versions accumulated

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

### 5. Run routine cleanup and compare

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

Routine `VACUUM` makes space reusable inside the table. It does not usually return space to storage. `VACUUM FULL` is not part of this lab because it rewrites the table and takes an exclusive lock.

### 6. Inspect autovacuum settings and show a per-table override

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

### 7. Check the cleanup horizon and idle-in-transaction risk

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

### 8. Demonstrate `work_mem` as a session-level experiment

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
