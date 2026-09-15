# S2F - WAL growth and replication - expanded choice path

## Final objective

Measure WAL generation directly, distinguish generation from retention, diagnose replica or slot pressure, and choose a safe first response without rebuilding anything.

Run `diagnostics/day2_adventureworks_preflight.sql` before this lab to confirm the target database and source AdventureWorks tables.

## Evidence contract

| Stage | Required artifact |
|---|---|
| Baseline | Current LSN, database counters, replica/slot status |
| Symptom | WAL generated, lag, or retained WAL shown by query output |
| Hypothesis | One sentence naming generation or retention cause |
| Change | One safe action or controlled workload |
| Proof | Same LSN/replica/slot query rerun after change |
| Cleanup | Scratch table and LSN baseline dropped |

## Oracle DBA framing

WAL is the closest mental bridge to Oracle redo: PostgreSQL writes WAL before data pages are persisted so it can recover committed changes. WAL also feeds replicas and point-in-time recovery.

Important distinction:

> High WAL generation and high WAL retention are not the same problem. First determine whether the workload is producing WAL quickly or whether an inactive consumer is preventing WAL cleanup.

Use this wording:

1. Long transactions hold MVCC visibility and delay cleanup.
2. Replication slots and lagging replicas directly retain WAL.
3. Large or long-running write transactions generate substantial WAL and create catch-up pressure.

## Topology options

| Topology | What participants can run | What to do if missing |
|---|---|---|
| No replica and no slot | WAL generation and transaction counters | Use captured sample evidence for replica/slot diagnosis |
| Read replica exists | WAL generation plus replica lag checks | Compare primary `pg_stat_replication` and replica replay delay |
| Logical slot exists | WAL generation plus retained-WAL checks | Confirm slot owner before any cleanup |

Do not depend on customer topology appearing on workshop day. The WAL-generation path is always hands-on; replica and slot cases can be hands-on or evidence-card exercises.

## Core path for class

### 1. Baseline: identify database, counters, and current WAL position

DBA question: "Before the workload, where is the database and WAL stream?"

```sql
SELECT current_database() AS database_name,
       pg_size_pretty(pg_database_size(current_database())) AS db_size_context;

SELECT datname,
       xact_commit,
       xact_rollback,
       blks_read,
       blks_hit,
       temp_files
FROM pg_stat_database
WHERE datname = current_database();

DROP TABLE IF EXISTS public.d2wal_lsn_baseline;

CREATE TABLE public.d2wal_lsn_baseline AS
SELECT pg_current_wal_lsn() AS start_lsn,
       clock_timestamp()    AS captured_at;

SELECT *
FROM public.d2wal_lsn_baseline;
```

What to look for:

1. `pg_database_size` is context only; it is not proof of current WAL volume.
2. `xact_commit` and `xact_rollback` are transaction counters.
3. `pg_current_wal_lsn()` is the starting point for measuring WAL generated.

### 2. Check replica status on the primary

DBA question: "Are replicas connected and keeping up?"

```sql
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
```

Expected-result guidance:

| Result | Meaning | Do not conclude |
|---|---|---|
| No rows | No connected replica from this primary | Do not assume the query failed |
| `state = streaming` | Replica is connected | Do not assume zero lag without checking lag columns |
| Replay LSN behind sent LSN | Replica has not applied all WAL | Do not rebuild until cause is proven |

If connected to a read replica:

```sql
SELECT pg_is_in_recovery() AS is_replica,
       now() - pg_last_xact_replay_timestamp() AS replay_delay;
```

### 3. Check long transactions

DBA question: "Is an old transaction contributing to cleanup or catch-up pressure?"

```sql
SELECT pid,
       usename,
       application_name,
       client_addr,
       state,
       now() - xact_start AS txn_age,
       left(query, 120) AS query
FROM pg_stat_activity
WHERE xact_start IS NOT NULL
ORDER BY xact_start;
```

What to look for:

1. Old `xact_start` values.
2. `idle in transaction` sessions.
3. Batch or reporting sessions running longer than expected.

Safe action: identify owner/application first. Close or terminate only through the approved process.

### 4. Check replication slots and WAL retention

DBA question: "Is WAL being retained because a replica or CDC consumer still needs it?"

```sql
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

Expected-result guidance:

| Result | Meaning | Safe action |
|---|---|---|
| No rows | No slots configured | Continue with WAL-generation lab |
| `active = true` | Consumer is connected | Monitor retained WAL trend |
| `active = false` with retained WAL | Consumer may be disconnected | Find slot owner; repair consumer before dropping slot |

### 5. Create a disposable write target

```sql
DROP TABLE IF EXISTS public.d2wal_salesorderdetail;

CREATE TABLE public.d2wal_salesorderdetail AS
SELECT row_number() OVER (ORDER BY d.salesorderid, d.salesorderdetailid)::bigint AS d2wal_id,
       d.*
FROM sales.salesorderdetail d
LIMIT 50000;

ALTER TABLE public.d2wal_salesorderdetail
  ADD PRIMARY KEY (d2wal_id);

ANALYZE public.d2wal_salesorderdetail;
```

Why this shape: the generated `d2wal_id` gives pgbench a deterministic key range and avoids teaching an expensive `OFFSET` lookup as the workload pattern.

### 6. Generate controlled write activity

```sql
UPDATE public.d2wal_salesorderdetail
SET unitprice = unitprice * 1.001,
    modifieddate = now()
WHERE d2wal_id <= 20000;

DELETE FROM public.d2wal_salesorderdetail
WHERE d2wal_id > 45000;
```

Possible whys for high WAL:

1. Large updates touch many rows.
2. Updates to indexed columns create table WAL and index WAL.
3. Deletes generate WAL and leave cleanup work for vacuum.
4. Bulk loads and maintenance jobs create WAL bursts.

### 7. Measure WAL generated directly

This is the primary proof for "WAL grew."

```sql
SELECT b.start_lsn,
       pg_current_wal_lsn() AS end_lsn,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), b.start_lsn)) AS wal_generated,
       clock_timestamp() - b.captured_at AS elapsed
FROM public.d2wal_lsn_baseline b;
```

What to conclude:

1. This measures WAL generated since the baseline LSN.
2. It is better proof of WAL activity than database size.
3. It does not prove WAL is retained; use replica and slot queries for retention.

### 8. Re-check replica, slot, and transaction evidence

```sql
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
```

Decision guide:

| Issue | Evidence | Likely why | First safe action |
|---|---|---|---|
| WAL generation | `wal_generated` is high | Workload changed many rows | Identify write source and business process |
| Replica lag | `replay_lag` grows | Replica cannot apply WAL fast enough | Check replica health, read workload, and primary write burst |
| WAL retention | Slot `wal_retained` grows | Slot/consumer still needs old WAL | Repair consumer; do not drop blindly |
| Long transaction | Old `xact_start` | Open transaction holds visibility | Close transaction through approved process |

## Optional pgbench workload

PowerShell:

```powershell
$env:PGPASSWORD = "<password>"

@"
\set target_id random(1, 45000)
UPDATE public.d2wal_salesorderdetail
SET unitprice = unitprice * 1.0001,
    modifieddate = now()
WHERE d2wal_id = :target_id;
"@ | Set-Content -Path "$env:TEMP\pgbench_d2wal_growth.sql" -Encoding ascii

pgbench `
  -h <server-name>.postgres.database.azure.com `
  -U <admin-user> `
  -d AdventureWorks `
  -c 4 `
  -j 2 `
  -T 60 `
  -f "$env:TEMP\pgbench_d2wal_growth.sql"
```

Bash:

```bash
export PGPASSWORD="<password>"

cat > /tmp/pgbench_d2wal_growth.sql <<'SQL'
\set target_id random(1, 45000)
UPDATE public.d2wal_salesorderdetail
SET unitprice = unitprice * 1.0001,
    modifieddate = now()
WHERE d2wal_id = :target_id;
SQL

pgbench \
  -h <server-name>.postgres.database.azure.com \
  -U <admin-user> \
  -d AdventureWorks \
  -c 4 \
  -j 2 \
  -T 60 \
  -f /tmp/pgbench_d2wal_growth.sql
```

After pgbench, rerun the WAL generated query from step 7.

## Captured evidence cards for missing topology

Use these if the workshop server has no replica or slot.

### Healthy streaming replica

| state | write_lag | flush_lag | replay_lag |
|---|---:|---:|---:|
| streaming | 00:00:00.020 | 00:00:00.025 | 00:00:00.050 |

Conclusion: replica is connected and close to current.

### Growing replay lag

| state | write_lag | flush_lag | replay_lag |
|---|---:|---:|---:|
| streaming | 00:00:00.100 | 00:00:00.200 | 00:03:45.000 |

Conclusion: WAL arrives, but replay is behind. Check replica workload and primary write burst.

### Inactive logical slot retaining WAL

| slot_name | slot_type | active | wal_status | wal_retained |
|---|---|---|---|---:|
| cdc_meridian_test | logical | false | reserved | 8 GB |

Conclusion: slot retention, not just generation. Repair or remove the consumer only after owner approval.

## What not to do under pressure

1. Do not rebuild a replica as the first action.
2. Do not drop a replication slot blindly.
3. Do not restart the server before checking live activity.
4. Do not treat database size as proof of WAL volume.
5. Do not disable durability settings to reduce WAL.

## Cleanup

```sql
DROP TABLE IF EXISTS public.d2wal_salesorderdetail;
DROP TABLE IF EXISTS public.d2wal_lsn_baseline;
```
