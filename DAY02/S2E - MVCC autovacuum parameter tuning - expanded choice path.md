# S2E - MVCC, autovacuum and parameter tuning - expanded choice path

## Final objective

Prove that updates create old row versions, demonstrate that a long transaction can prevent cleanup, and distinguish routine `VACUUM` from physical table shrinkage.

This version keeps a **core attendee path** and adds optional examples so Oracle DBAs can choose what to run after the scheduled session.

Run `diagnostics/day2_adventureworks_preflight.sql` before this lab to confirm the target database, extensions, and source AdventureWorks tables.

## Evidence contract

| Stage | Required artifact |
|---|---|
| Baseline | Tuple counts, table size, and `pgstattuple` output before churn |
| Symptom | Dead tuples or free space appear after updates |
| Hypothesis | One sentence naming why old row versions exist |
| Change | One cleanup action: routine `VACUUM` first |
| Proof | Same evidence query rerun after cleanup |
| Cleanup | Scratch table dropped or retained state documented |

## Oracle DBA framing

1. PostgreSQL does not overwrite updated rows in place; it creates a new row version.
2. Old row versions remain in the table until `VACUUM` can clean them.
3. This is not the same as Oracle undo. Use "closest operational equivalent" language only.
4. `pg_stat_user_tables.n_dead_tup` is an estimate and may lag.
5. `pgstattuple` directly inspects the table and is the stronger measurement in this lab.

## Required extension

This lab uses `pgstattuple` for direct table inspection. On Azure Database for PostgreSQL Flexible Server, read the current allow-list first and preserve existing entries.

PowerShell:

```powershell
az postgres flexible-server parameter show `
  --resource-group <resource-group> `
  --server-name <server-name> `
  --name azure.extensions

az postgres flexible-server parameter set `
  --resource-group <resource-group> `
  --server-name <server-name> `
  --name azure.extensions `
  --value "pg_stat_statements,pg_trgm,uuid-ossp,pgcrypto,pgstattuple"
```

Bash:

```bash
az postgres flexible-server parameter show \
  --resource-group <resource-group> \
  --server-name <server-name> \
  --name azure.extensions

az postgres flexible-server parameter set \
  --resource-group <resource-group> \
  --server-name <server-name> \
  --name azure.extensions \
  --value "pg_stat_statements,pg_trgm,uuid-ossp,pgcrypto,pgstattuple"
```

Then connect to `AdventureWorks` and run:

```sql
CREATE EXTENSION IF NOT EXISTS pgstattuple;
```

`pgstattuple` does not need `shared_preload_libraries` or a restart.

## Core path for class

### 1. Create a disposable MVCC table

DBA question: "How do we test MVCC without changing real AdventureWorks data?"

```sql
DROP TABLE IF EXISTS public.d2mvcc_salesorderheader;

CREATE TABLE public.d2mvcc_salesorderheader AS
SELECT row_number() OVER (ORDER BY h.salesorderid)::bigint AS d2mvcc_id,
       h.*
FROM sales.salesorderheader h
LIMIT 20000;

ALTER TABLE public.d2mvcc_salesorderheader
  ADD PRIMARY KEY (d2mvcc_id);

ANALYZE public.d2mvcc_salesorderheader;
```

Why `ANALYZE` is here: it refreshes planner statistics after the table is created. It does **not** guarantee exact dead-tuple counts.

Expected result: the table exists, has about 20,000 rows, and can be safely dropped after the lab.

### 2. Capture baseline evidence

First evidence to collect: table-level statistics, physical size, and direct tuple inspection.

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
  AND relname = 'd2mvcc_salesorderheader';

SELECT pg_size_pretty(pg_total_relation_size('public.d2mvcc_salesorderheader')) AS table_size_before;

SELECT *
FROM pgstattuple('public.d2mvcc_salesorderheader');
```

What to look for:

1. `n_live_tup` is an estimate of visible rows.
2. `n_dead_tup` is an estimate of dead row versions.
3. `pgstattuple.dead_tuple_percent` is direct evidence from table inspection.
4. Baseline dead tuples should be low or zero on a fresh scratch table.

### 3. Generate row churn

DBA question: "Can updates create dead tuples even if the business value is unchanged?"

```sql
UPDATE public.d2mvcc_salesorderheader
SET freight = freight + 0
WHERE d2mvcc_id <= 10000;

ANALYZE public.d2mvcc_salesorderheader;
```

Why this works: PostgreSQL still creates new row versions for the updated rows. The old versions become dead once no active transaction needs them.

### 4. Prove dead tuples accumulated

```sql
SELECT relname,
       n_live_tup,
       n_dead_tup,
       round(n_dead_tup * 100.0 / NULLIF(n_live_tup + n_dead_tup, 0), 2) AS dead_pct,
       last_vacuum,
       last_autovacuum,
       last_analyze
FROM pg_stat_user_tables
WHERE schemaname = 'public'
  AND relname = 'd2mvcc_salesorderheader';

SELECT pg_size_pretty(pg_total_relation_size('public.d2mvcc_salesorderheader')) AS table_size_after_update;

SELECT *
FROM pgstattuple('public.d2mvcc_salesorderheader');
```

Possible whys:

1. Old row versions exist because PostgreSQL preserved MVCC visibility.
2. Table size may grow if the new row versions needed additional pages.
3. Table size may stay similar if PostgreSQL reused free space already available.
4. `n_dead_tup` and `pgstattuple` may differ because one is an estimate and the other inspects the table.

### 5. Run routine VACUUM and compare

DBA question: "What does routine `VACUUM` fix, and what does it not fix?"

```sql
VACUUM (VERBOSE, ANALYZE) public.d2mvcc_salesorderheader;

SELECT relname,
       n_live_tup,
       n_dead_tup,
       last_vacuum,
       last_autovacuum,
       last_analyze
FROM pg_stat_user_tables
WHERE schemaname = 'public'
  AND relname = 'd2mvcc_salesorderheader';

SELECT pg_size_pretty(pg_total_relation_size('public.d2mvcc_salesorderheader')) AS table_size_after_vacuum;

SELECT *
FROM pgstattuple('public.d2mvcc_salesorderheader');
```

Expected result:

1. Dead tuple evidence should drop.
2. Free space inside the table may increase.
3. Physical table size may stay the same.

Conclusion: routine `VACUUM` makes space reusable inside the table. It usually does not return space to storage.

### 6. Guaranteed two-session long-transaction demo

This is the most important operational lesson for Oracle DBAs: a session can look idle but still hold a transaction snapshot that prevents cleanup.

#### Session A: hold a snapshot open

```sql
BEGIN;

SELECT count(*)
FROM public.d2mvcc_salesorderheader;

-- Keep this transaction open. Do not COMMIT yet.
```

#### Session B: create churn and try cleanup

```sql
UPDATE public.d2mvcc_salesorderheader
SET freight = freight + 0
WHERE d2mvcc_id <= 5000;

VACUUM (VERBOSE, ANALYZE) public.d2mvcc_salesorderheader;
```

#### Diagnostic session: find cleanup blockers

```sql
SELECT pid,
       state,
       backend_xmin,
       age(backend_xmin) AS xmin_age,
       now() - xact_start AS transaction_age,
       left(query, 100) AS query
FROM pg_stat_activity
WHERE backend_xmin IS NOT NULL
ORDER BY age(backend_xmin) DESC NULLS LAST;
```

What to look for:

1. Session A has an open transaction.
2. `backend_xmin` shows an old MVCC visibility horizon.
3. Vacuum may not be able to remove all dead tuples while that transaction is open.

#### Session A: release the snapshot

```sql
COMMIT;
```

#### Session B: rerun cleanup and proof

```sql
VACUUM (VERBOSE, ANALYZE) public.d2mvcc_salesorderheader;

SELECT *
FROM pgstattuple('public.d2mvcc_salesorderheader');
```

Best practice: keep transactions short. Fix application paths that leave sessions `idle in transaction`. Consider `idle_in_transaction_session_timeout` where appropriate.

## Optional examples participants can choose

### Option A: concurrent churn with pgbench

Use only against the scratch table. `pgbench` runs in PowerShell or Bash, not inside `psql`.

PowerShell:

```powershell
$env:PGPASSWORD = "<password>"

@"
\set target_id random(1, 20000)
UPDATE public.d2mvcc_salesorderheader
SET freight = freight + 0
WHERE d2mvcc_id = :target_id;
"@ | Set-Content -Path "$env:TEMP\pgbench_d2mvcc_churn.sql" -Encoding ascii

pgbench `
  -h <server-name>.postgres.database.azure.com `
  -U <admin-user> `
  -d AdventureWorks `
  -c 4 `
  -j 2 `
  -T 60 `
  -f "$env:TEMP\pgbench_d2mvcc_churn.sql"
```

Bash:

```bash
export PGPASSWORD="<password>"

cat > /tmp/pgbench_d2mvcc_churn.sql <<'SQL'
\set target_id random(1, 20000)
UPDATE public.d2mvcc_salesorderheader
SET freight = freight + 0
WHERE d2mvcc_id = :target_id;
SQL

pgbench \
  -h <server-name>.postgres.database.azure.com \
  -U <admin-user> \
  -d AdventureWorks \
  -c 4 \
  -j 2 \
  -T 60 \
  -f /tmp/pgbench_d2mvcc_churn.sql
```

### Option B: physically shrink with VACUUM FULL

Run this only after showing routine `VACUUM`, so participants first see cleanup without physical shrink.

```sql
VACUUM FULL public.d2mvcc_salesorderheader;

ANALYZE public.d2mvcc_salesorderheader;

SELECT pg_size_pretty(pg_total_relation_size('public.d2mvcc_salesorderheader')) AS table_size_after_vacuum_full;

SELECT *
FROM pgstattuple('public.d2mvcc_salesorderheader');
```

Use `VACUUM FULL` only when physical shrink is the goal and an exclusive table lock is acceptable. It rewrites the table and needs time, I/O, and free space.

### Option C: autovacuum settings

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

ALTER TABLE public.d2mvcc_salesorderheader SET (
  autovacuum_vacuum_scale_factor  = 0.02,
  autovacuum_analyze_scale_factor = 0.01,
  autovacuum_vacuum_cost_limit    = 2000
);

SELECT relname,
       reloptions
FROM pg_class
WHERE oid = 'public.d2mvcc_salesorderheader'::regclass;

ALTER TABLE public.d2mvcc_salesorderheader RESET (
  autovacuum_vacuum_scale_factor,
  autovacuum_analyze_scale_factor,
  autovacuum_vacuum_cost_limit
);
```

Best practice: tune per table first when one table has abnormal churn. Do not disable autovacuum.

### Option D: work_mem session experiment

This is useful context but not the core MVCC story.

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

Best practice: test memory changes at session, role, or workload scope before changing server-wide defaults. `work_mem` can be consumed multiple times per query and multiplied across concurrent sessions.

## Cleanup

```sql
DROP TABLE IF EXISTS public.d2mvcc_salesorderheader;
```
