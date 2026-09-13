# Workload 9: Temporary Tables

This workload repeatedly creates, populates, queries, and drops a PostgreSQL temporary table. It demonstrates session-local temporary-table activity, catalog work, transaction overhead, buffer usage, and possible temporary-relation I/O under concurrent pgbench sessions.

PostgreSQL has no separate `tempdb` database. Each pgbench session creates its own `sales_report` table, and `ON COMMIT DROP` removes that table when the iteration commits.

## Prerequisites

The AdventureWorks database must contain:

- `sales.salesorderheader`
- `sales.salesorderdetail`
- `production.product`

The connected role must have `TEMP` privilege on the database and `SELECT` privilege on those tables.

For useful I/O and statement metrics, install and load `pg_stat_statements` and configure these settings when permitted:

```text
track_io_timing = on
pg_stat_statements.track = all
```

On Azure Database for PostgreSQL, configure server-level settings through Server parameters when the login cannot change them through SQL.

## Run the Workload

Start `Generate-PGSQL-Workload.ps1` and select:

```text
Workload: 9 TempDB
Port: 5432
Clients: 10
Threads: 4
Limit: Time
Duration: 120 seconds
```

Begin with moderate concurrency and increase clients gradually while observing latency, client-backend I/O, and connection capacity. Threads should not exceed clients.

Select **Reset PGSTATS before run** for an isolated test only when resetting database, statement, and cluster-wide I/O statistics is acceptable. Otherwise use the baseline and delta sections described below.

The launcher runs:

```text
SQL/Stress_TempDB.sql
```

The application name is `PGBench_TempDBResults`, and results are written under `Results/PGBench_TempDBResults/<timestamp>`.

Each pgbench iteration:

1. Chooses a random customer ID from `11000` through `30118`.
2. Begins a transaction.
3. Creates `sales_report` with column types inferred from the source tables.
4. Inserts that customer's sales-order rows.
5. Reads and orders the temporary rows.
6. Commits, causing `ON COMMIT DROP` to remove the table.

## Monitor the Workload

Open a separate DBA connection to the same database and run:

```text
SQL/DBA/DBA_TempDBReview.sql
```

With **Reset PGSTATS before run** enabled:

1. Run Sections 1 and 2 to verify settings and confirm that reset timestamps align with the test.
2. Start workload 9 and repeatedly run Sections 3 through 6 for sessions, waits, blocking, and currently visible temporary relations.
3. During or after the workload, run Sections 7 through 10 for statement cost, source-table scans, database temporary files, and PostgreSQL 16+ I/O counters.

Without reset privileges:

1. Run all of Section 11 before starting workload 9.
2. Keep that DBA session connected and run pgbench from another session.
3. After the workload, run Section 12 and confirm every validity result is true.
4. Run Sections 13 through 16 for statement, database, source-table, and cluster-I/O deltas.

Do not rerun Section 11 after starting the workload because that replaces the original baseline. The live queries use `application_name LIKE 'PGBench%'`; run no other pgbench workloads concurrently when workload-9-only results are required.

Database statistics include all activity in the current database. `pg_stat_io` is cluster-wide and cannot be filtered by database or application name, so keep unrelated activity low or account for it separately.

## What to Look For

### Session activity

During a run, sessions should alternate among temporary table creation, source-table reads, inserts, report reads, and commit. Investigate:

- Persistent lock waits
- Blocking PIDs
- Long transaction or query ages
- Sessions left idle in transaction
- Connection saturation at higher client counts

### Temporary-relation I/O

In Section 10 or 16, focus on rows where:

```text
backend_type = client backend
object = temp relation
```

Rising reads, writes, extends, evictions, or fsyncs indicate work against temporary relations. Section 16 is preferable when statistics cannot be reset because it reports the measurement interval instead of lifetime totals.

### Temporary files and blocks

Review:

- `pg_stat_database.temp_files` and `temp_bytes`
- `pg_stat_statements.temp_blks_read` and `temp_blks_written`
- Temporary block read/write time when `track_io_timing` is enabled
- pgbench latency and transactions per second

Explicit temporary tables and executor temporary files are different signals. `pg_stat_io` rows where `object = 'temp relation'` describe temporary-relation I/O. `pg_stat_database.temp_files`, `temp_bytes`, and `pg_stat_statements.temp_blks_*` mainly describe temporary files produced by operations such as sorts and hashes.

The selected customer's result set may be small enough to remain in `temp_buffers`, and its final sort may fit in `work_mem`. In that case, disk-oriented counters can remain zero even though temporary tables are being created and used correctly. Increase concurrency or use larger source sets only when the goal is specifically to force storage pressure.

### Source-table access

The workload joins SalesOrderHeader, SalesOrderDetail, and Product. High shared reads, broad scans, or rising latency can indicate cold-cache behavior, insufficient indexing, or storage pressure. Use `EXPLAIN (ANALYZE, BUFFERS, SETTINGS, SUMMARY)` on the source `SELECT` with a representative customer ID when its access path needs investigation.

## Test Controls

Keep the database, server tier, clients, threads, duration, cache conditions, and statistics settings unchanged when comparing runs. Record whether PGSTATS was reset and whether other activity was present.

Do not compare cumulative `pg_stat_database` or `pg_stat_io` values directly across tests of different duration. Prefer pgbench latency and transactions per second, normalized per-call statement metrics, or validated after-minus-before deltas from Sections 13 through 16.
