# S2F - WAL growth and replication

## Lab objective

Using AdventureWorks data, participants answer three support questions with evidence:

1. Why is WAL growing?
2. Why is replica lag increasing?
3. What can be done without destructive reload or rebuild?

## Key message for the room

WAL is not just a log file. It is the durability and replication stream. Every commit, replica catch-up and recovery path depends on it.

For Oracle DBAs, the closest mental model is redo: PostgreSQL writes WAL before data pages are persisted so it can recover committed changes after failure. WAL is also used to feed replicas and point-in-time restore. If WAL generation is high, replicas or CDC consumers can fall behind. If WAL cannot be recycled because a replica or slot still needs it, storage can grow.

Use careful Oracle comparison language:

- HA standby = availability target.
- Read replica = read scaling with asynchronous lag.
- PITR = restore to a new server/endpoint, not a live failover target.

## Lab prerequisites and operating notes

This lab uses built-in PostgreSQL views and functions only. No extension allow-list is required.

Some evidence depends on the server topology:

- `pg_stat_replication` returns rows only on a primary server with connected replicas.
- `pg_replication_slots` returns rows only when physical or logical replication slots exist.
- `pg_last_xact_replay_timestamp()` is useful only on a read replica.

If the workshop server has no replica or CDC slot, those result sets can be empty. That is still a valid teaching moment: the DBA should explain what the empty result means instead of assuming the query failed.

Basic incident flow:

1. Confirm the database and baseline counters.
2. Check whether replicas are connected and lagging.
3. Check whether old transactions are holding resources.
4. Check whether replication slots are retaining WAL.
5. Generate a controlled write workload.
6. Re-check the same evidence and choose the safest action.

## Lab steps

### 1. Baseline database and transaction activity

DBA question: "Which database am I troubleshooting, and what were the counters before the workload?"

First evidence to collect: run the database-size query and the `pg_stat_database` query for the current database. These are the baseline values used later to prove whether transaction activity, temp files, or database size changed.

What each query shows:

1. `current_database()` and `pg_database_size` identify the database under test and its starting size.
2. `pg_stat_database` captures transaction, rollback, buffer and temp-file counters before the write workload.

How to read the result:

1. `xact_commit` increasing means normal committed activity is happening.
2. `xact_rollback` increasing quickly may indicate application errors or failed retries.
3. `blks_hit` vs `blks_read` gives a basic cache signal. Many reads from disk can add pressure during incidents.
4. `temp_files` increasing means queries are spilling to temp files, often from sorts or hashes that do not fit in memory.

Possible whys:

1. A normal batch job, ETL process, index maintenance operation, or application release increased write volume.
2. A retry loop is causing many commits or rollbacks.
3. Large reporting queries are spilling to temp files and adding I/O pressure while replicas are trying to catch up.
4. Database size increased because updates/deletes created new row versions and later cleanup has not reused or compacted the space yet.

Safe DBA action:

Do not change anything yet. This is the baseline you will compare against after the workload.

```sql
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
```

### 2. Check replication status on the primary

DBA question: "If this is the primary, are replicas connected and are they keeping up?"

First evidence to collect: run `pg_stat_replication` on the primary. This is the main view for primary-to-replica streaming status.

This query shows connected replicas from the primary server perspective. The LSN columns show how far WAL has been sent, written, flushed and replayed; the lag columns show whether the replica is falling behind.

How to read the result:

1. No rows usually means no connected replicas from this primary. That is not an error if the lab server has no replica.
2. `state = streaming` is the normal healthy state for a connected streaming replica.
3. `sent_lsn`, `write_lsn`, `flush_lsn`, and `replay_lsn` show the replica pipeline. If replay is far behind sent, the replica received WAL but has not applied it yet.
4. `write_lag`, `flush_lag`, and `replay_lag` show where delay is happening.

Possible whys:

1. Write volume increased and the replica is temporarily catching up.
2. The replica is undersized for the workload or is busy serving read queries.
3. Network or service issues are delaying WAL delivery.
4. A long-running query on the read replica is slowing replay.
5. The replica connection is broken or reconnecting.

Safe DBA action:

If lag is visible, do not rebuild the replica first. Check workload, network/replica health, long transactions, and replication slots before deciding on a rebuild.

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

If connected to a read replica:

First evidence to collect on a replica: run `pg_is_in_recovery()` and compare current time to `pg_last_xact_replay_timestamp()`.

This query confirms whether the session is on a replica and estimates replay delay from the last replayed transaction timestamp.

How to read the result:

1. `is_replica = true` means the session is connected to a read replica.
2. A small `replay_delay` is usually normal for asynchronous replicas.
3. A growing `replay_delay` means the replica is falling behind or has stopped replaying changes.

Possible whys:

1. The primary generated more WAL than the replica can replay quickly.
2. Read workload on the replica is competing with replay.
3. The replica is paused, disconnected, or unhealthy.
4. A large transaction committed on the primary and the replica is still applying it.

```sql
SELECT pg_is_in_recovery() AS is_replica,
       now() - pg_last_xact_replay_timestamp() AS replay_delay;
```

### 3. Check long-running transactions before blaming the replica

DBA question: "Is an old transaction contributing to cleanup, WAL, or replica pressure?"

First evidence to collect: run the `pg_stat_activity` query ordered by `xact_start`. This shows the oldest open transactions first.

This query finds open transactions by age. Long transactions can delay cleanup and interact badly with WAL retention or replica catch-up.

How to read the result:

1. Rows at the top are the oldest transactions.
2. `state = active` means the session is currently running work.
3. `state = idle in transaction` means the client opened a transaction and stopped without commit or rollback. This is often more dangerous than normal idle.
4. A very old `txn_age` is a warning signal because PostgreSQL must preserve visibility for that transaction.

Possible whys:

1. An application opened a transaction and did not close it.
2. A DBA or developer left a `psql` session open after running `BEGIN`.
3. A reporting query or batch process is running longer than expected.
4. Application connection pooling is reusing sessions incorrectly and leaving transactions open.

Safe DBA action:

Identify the application and owner first. Ask for commit/rollback or fix the application behavior. Cancel or terminate only through the approved operational process.

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

### 4. Check replication slots and CDC WAL retention risk

DBA question: "Is WAL being retained because a replica or CDC consumer still needs it?"

First evidence to collect: run `pg_replication_slots` and sort by retained WAL. This shows whether a slot is preventing WAL cleanup.

This query shows physical or logical slots and estimates how much WAL each slot is retaining. An inactive slot with growing retained WAL is a storage-risk signal.

How to read the result:

1. No rows means no replication slots exist on this server. That is fine if CDC or slot-based replication is not configured.
2. `slot_type = physical` usually supports physical replication.
3. `slot_type = logical` is commonly used by CDC or logical replication tools.
4. `active = false` means the consumer is not connected.
5. `wal_retained` shows how much WAL cannot be recycled because the slot may still need it.
6. `wal_status` helps identify whether the slot is healthy, retained, or at risk.

Possible whys:

1. A CDC tool stopped, but its logical replication slot still exists.
2. A replica or consumer is offline and has not acknowledged WAL.
3. A migration or integration test created a slot and did not clean it up.
4. The consumer is connected through the wrong path, such as a pooler that does not support the required replication behavior.
5. The consumer is slow and cannot keep up with the primary's WAL generation rate.

Safe DBA action:

Do not drop a slot blindly. First confirm which replica or CDC tool owns it. If it is valid, restart or repair the consumer. Drop a slot only after the application owner confirms it is abandoned or can be reinitialized.

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

CDC tools usually need a direct replication connection, not a transaction pooler. That exception is acceptable only if the slot is monitored. An inactive slot can retain WAL and consume storage.

### 5. Create a disposable AdventureWorks write target

DBA question: "How do we create write activity safely without touching the real AdventureWorks tables?"

What each statement does:

1. `DROP TABLE IF EXISTS` resets the lab safely.
2. `CREATE TABLE AS` copies a bounded AdventureWorks sample so the lab does not modify source tables.
3. `ALTER TABLE ... ADD PRIMARY KEY` gives the scratch table a realistic key.
4. `ANALYZE` refreshes statistics before the write workload.

```sql
DROP TABLE IF EXISTS public.wal_growth_lab_salesorderdetail;

CREATE TABLE public.wal_growth_lab_salesorderdetail AS
SELECT *
FROM sales.salesorderdetail
LIMIT 50000;

ALTER TABLE public.wal_growth_lab_salesorderdetail
  ADD PRIMARY KEY (salesorderid, salesorderdetailid);

ANALYZE public.wal_growth_lab_salesorderdetail;
```

### 6. Generate controlled write activity

Keep this bounded. The goal is a visible WAL and transaction signal, not a destructive stress test.

DBA question: "What kinds of changes generate WAL?"

What each statement does:

1. `UPDATE` changes many rows, which generates WAL for row versions and index maintenance.
2. `DELETE` removes a bounded set of rows, generating more WAL and giving the follow-up evidence something to measure.

How to read this step:

Every changed row must be written to WAL. PostgreSQL also keeps old row versions for MVCC until vacuum can clean them. Even a simple update can create table changes, index maintenance, WAL volume, and later vacuum work.

Possible whys for high WAL from application changes:

1. Large updates touch many rows even when the business change looks small.
2. Updates to indexed columns generate table WAL and index WAL.
3. Deletes generate WAL and leave cleanup work for vacuum.
4. Bulk loads, rebuilds, and maintenance jobs can create short bursts of WAL.
5. Repeated updates to the same hot rows can create continuous WAL and dead tuples.

Safe DBA action:

Keep write tests small. In production, first identify the write source and business process before trying to reduce WAL. Do not disable durability settings to "fix" WAL growth.

```sql
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
```

### 7. Optional: generate concurrent write activity with pgbench

The SQL in step 6 is enough for a bounded classroom demo. If you want stronger transaction and WAL activity, run `pgbench` from PowerShell or Bash after the disposable table has been created. Do not run `pgbench` inside `psql`.

DBA question: "What happens when the same write pattern runs from multiple clients?"

Use this only if the single-session update is too small to make the counters visibly move. The workload updates one existing row per transaction across several clients, which creates a clearer transaction and WAL signal.

Best practice:

Run `pgbench` only against disposable lab objects unless you are performing an approved load test. Start with low concurrency and a short duration.

PowerShell:

```powershell
$env:PGPASSWORD = "<password>"

@"
\set row_offset random(0, 44999)
UPDATE public.wal_growth_lab_salesorderdetail
SET unitprice = unitprice * 1.0001,
    modifieddate = now()
WHERE ctid = (
  SELECT ctid
  FROM public.wal_growth_lab_salesorderdetail
  ORDER BY salesorderid, salesorderdetailid
  OFFSET :row_offset
  LIMIT 1
);
"@ | Set-Content -Path "$env:TEMP\pgbench_wal_growth.sql" -Encoding ascii

pgbench `
  -h <server-name>.postgres.database.azure.com `
  -U <admin-user> `
  -d AdventureWorks `
  -c 4 `
  -j 2 `
  -T 60 `
  -f "$env:TEMP\pgbench_wal_growth.sql"
```

Bash:

```bash
export PGPASSWORD="<password>"

cat > /tmp/pgbench_wal_growth.sql <<'SQL'
\set row_offset random(0, 44999)
UPDATE public.wal_growth_lab_salesorderdetail
SET unitprice = unitprice * 1.0001,
    modifieddate = now()
WHERE ctid = (
  SELECT ctid
  FROM public.wal_growth_lab_salesorderdetail
  ORDER BY salesorderid, salesorderdetailid
  OFFSET :row_offset
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
  -f /tmp/pgbench_wal_growth.sql
```

### 8. Re-check the same evidence

DBA question: "What changed after the write workload?"

First evidence to collect: rerun the same baseline, replication, and slot queries from steps 1, 2, and 4. The point is to compare the same measurements before and after the workload.

What each query shows:

1. Database size after the workload shows whether the write activity changed the database footprint.
2. `pg_stat_database` shows changed transaction, buffer and temp-file counters.
3. `pg_stat_replication` shows whether connected replicas are keeping up after the workload.
4. `pg_replication_slots` shows whether any slot is retaining WAL after the workload.

How to read the result:

1. Compare `db_size_after_write` to the starting size. It may grow because updates/deletes create new row versions and WAL activity.
2. Compare `xact_commit`, `xact_rollback`, `blks_read`, `blks_hit`, and `temp_files` to the baseline.
3. If `pg_stat_replication` now shows lag, decide whether the replica is still catching up or stuck.
4. If `pg_replication_slots` shows retained WAL growing for an inactive slot, focus on the CDC/replication consumer.

Possible whys:

1. Counters increased because the lab workload generated normal write activity.
2. Replica lag appeared because the replica is applying changes asynchronously and may need time to catch up.
3. Slot retention increased because a CDC/replication consumer has not acknowledged the WAL yet.
4. Database size increased because updates and deletes create row versions before cleanup can reuse the space.
5. Temp files increased because another query needed disk for sort/hash work during the same window.

Safe DBA action:

Use the same evidence before and after. Do not jump from "WAL grew" to "rebuild the replica." First classify the cause: normal write volume, long transaction, disconnected replica, inactive slot, or slow replay.

```sql
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
```

### 9. Write the safe action

Use this as the DBA decision table. The point is to map symptom -> evidence -> first safe action, not to memorize one emergency command.

| Symptom | First evidence query to run | Safe first action |
|---|---|---|
| WAL growing fast | Run step 1 again: `pg_database_size(current_database())` and `pg_stat_database` for transaction counters. Then run step 3 and step 4 to check old transactions and retained WAL. | Identify the write source, confirm whether growth matches expected workload, and check for old transactions or slots before changing capacity. |
| Replica lag rising | Run step 2 on the primary: `pg_stat_replication`. If connected to the replica, run the replica replay-delay query. | Confirm the replica is connected, check whether replay is progressing, then check primary workload and long transactions. |
| CDC consumer disconnected | Run step 4: `pg_replication_slots`, focusing on `active`, `wal_status`, and `wal_retained`. | Restart or repair the CDC consumer. Drop the slot only after confirming it is abandoned or safe to reinitialize. |
| Long transaction present | Run step 3: `pg_stat_activity` ordered by `xact_start`, focusing on old `txn_age` and `idle in transaction`. | Identify owner/application and get the transaction closed. Use cancel/terminate only through the approved process. |
| Request to rebuild replica immediately | Run step 2, step 3, and step 4 first: prove whether lag is from replay, old transactions, or retained WAL. | Treat rebuild as last resort. Prove whether the problem is workload, replay speed, connection, slot retention, or replica health first. |

Production best practices:

1. Monitor WAL/storage trend, not just one snapshot.
2. Alert on replica lag and inactive slots that retain WAL.
3. Keep transactions short; avoid long idle transactions.
4. Use direct replication connections for CDC tools that require slots.
5. Do not drop replication slots, rebuild replicas, or restart servers until the owner and impact are understood.
6. Use scale-up or storage changes only after proving the workload really needs more capacity.

## Participant output

Each group produces a WAL/replica-lag mini playbook:

1. What grew WAL fastest?
2. Which view showed primary-to-replica status?
3. Which query detects long-running transactions?
4. Which query detects inactive CDC slot risk?
5. What is the first safe action before replica rebuild?

## Cleanup

Run this at the end of the lab if participants need to reset the database and run the lab again.

What this cleanup does:

1. Drops the disposable WAL lab table.
2. Leaves the original AdventureWorks tables unchanged.
3. Does not change replicas, replication slots, or server settings.

```sql
DROP TABLE IF EXISTS public.wal_growth_lab_salesorderdetail;
```
