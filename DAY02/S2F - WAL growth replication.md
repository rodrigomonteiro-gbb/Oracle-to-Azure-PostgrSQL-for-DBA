# S2F - WAL growth and replication

## Lab objective

Using AdventureWorks data, participants answer three support questions with evidence:

1. Why is WAL growing?
2. Why is replica lag increasing?
3. What can be done without destructive reload or rebuild?

## Key message for the room

WAL is not just a log file. It is the durability and replication stream. Every commit, replica catch-up and recovery path depends on it.

Use careful Oracle comparison language:

- HA standby = availability target.
- Read replica = read scaling with asynchronous lag.
- PITR = restore to a new server/endpoint, not a live failover target.

## Lab steps

### 1. Baseline database and transaction activity

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

```sql
SELECT pg_is_in_recovery() AS is_replica,
       now() - pg_last_xact_replay_timestamp() AS replay_delay;
```

### 3. Check long-running transactions before blaming the replica

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

### 7. Re-check the same evidence

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

### 8. Write the safe action

| Symptom | First evidence | Safe first action |
|---|---|---|
| WAL growing fast | Write volume, long transactions, replication slots | Address write source; confirm no inactive slot retaining WAL. |
| Replica lag rising | `pg_stat_replication` lag columns and replica replay delay | Confirm replica is connected and catching up; check long transactions. |
| CDC consumer disconnected | `pg_replication_slots.active = false` and retained WAL | Restart/fix CDC consumer or follow the approved slot cleanup process. |
| Request to rebuild replica immediately | Lag trend and primary health | Treat rebuild as last resort; prove root cause first. |

## Participant output

Each group produces a WAL/replica-lag mini playbook:

1. What grew WAL fastest?
2. Which view showed primary-to-replica status?
3. Which query detects long-running transactions?
4. Which query detects inactive CDC slot risk?
5. What is the first safe action before replica rebuild?
