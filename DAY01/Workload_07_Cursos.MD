# Workload 7: Cursors

This demonstration compares row-by-row cursor activity across three concurrent pgbench workloads:

1. Read every row from `person.address`.
2. Read `sales.salesorderheader` rows for a randomized salesperson.
3. Update `sales.salesorderheader` rows for a randomized salesperson.

The update cursor increases `freight` by `1.00` and sets `modifieddate` to the current timestamp for every matching order. These changes are committed and accumulate on every execution. Use a disposable or restorable demonstration database.

## Prerequisites

The connected role must be able to create functions and update `sales.salesorderheader`. The AdventureWorks tables must exist.

For complete DBA metrics, configure these PostgreSQL settings before the test:

```text
pg_stat_statements.track = all
track_functions = pl
track_io_timing = on
```

On Azure Database for PostgreSQL, configure these through Server parameters when SQL-level changes are not permitted. `pg_stat_statements` must be installed and loaded.

## Run the Workload

Start `Generate-PGSQL-Workload.ps1` and select:

```text
Workload: 7 Cursors
Port: 5432
Clients: 2
Threads: 2
Limit: Time
Duration: 60 seconds
```

Start with low concurrency because each selected client count is applied to all three pgbench processes, and the update workload can contend when clients choose the same salesperson. Increase clients gradually after observing locks, latency, WAL, and dead tuples.

Select **Reset PGSTATS before run** only when resetting database, statement, and cluster-wide I/O statistics is acceptable.

The launcher first runs this setup once through `psql`:

```text
SQL/AdventureWorks_Cursors_Setup.sql
```

It then starts these pgbench workloads:

| Purpose | Script | Application name |
| --- | --- | --- |
| Read Person.Address | `SQL/AdventureWorks_Cursors_PersonAddress.sql` | `PGBench_Cursors_PersonAddress` |
| Read SalesOrderHeader | `SQL/AdventureWorks_Cursors_SalesOrderHeader.sql` | `PGBench_Cursors_SalesOrderHeader` |
| Update SalesOrderHeader | `SQL/AdventureWorks_Cursors_UpdateSalesOrderHeader.sql` | `PGBench_Cursors_UpdateSalesOrderHeader` |

The SalesOrderHeader workloads randomly choose a salesperson ID from `274` through `290`. Both return `salesorderid`, `salespersonid`, `modifieddate`, `freight`, and `totaldue`. The update workload returns post-update values.

Results are written to timestamped folders beneath each corresponding `Results/PGBench_Cursors_*` directory.

## Monitor the Workload

Open a separate DBA connection to the same database and run:

```text
SQL/DBA/DBA_CursorsReview.SQL
```

Use the sections as follows:

- Before the run, use Section 1 to verify monitoring configuration and permissions.
- During the run, repeatedly execute Sections 2 through 5 for sessions, waits, blocking, and locks.
- Section 6 demonstrates that `pg_cursors` is session-local and cannot list cursors opened in other pgbench backends.
- During or after the run, use Sections 7 and 8 for function and statement cost.
- After the run, use Sections 9 through 11 for scans, index use, updates, dead tuples, autovacuum, and table size.

## What to Look For

### Row-by-row overhead

Compare function calls, total time, mean time, and pgbench latency. Cursor functions process one row at a time, so latency grows with the number of rows returned for a salesperson or scanned from `person.address`.

### Lock contention

Pay close attention to the update application:

```text
PGBench_Cursors_UpdateSalesOrderHeader
```

`wait_event_type = 'Lock'`, blocked PIDs, ungranted locks, or increasing blocked duration indicate concurrent clients selected overlapping SalesOrderHeader rows.

### Write amplification

The update cursor writes every matching order separately. In `pg_stat_statements` and table statistics, review:

- `shared_blks_dirtied` and `shared_blks_written`
- `wal_records`, `wal_fpi`, and `wal_bytes`
- `n_tup_upd` and `n_tup_hot_upd`
- `n_dead_tup` and `dead_tuple_pct`
- Autovacuum and autoanalyze activity

Because `totaldue` is derived from order amounts, increasing `freight` also changes the returned `totaldue`.

### Access paths

Review sequential scans and index usage for `person.address` and `sales.salesorderheader`. The SalesOrderHeader cursors filter by `salespersonid` and order by `salesorderid`; repeated high tuple reads can indicate that available indexes do not efficiently support the cursor query.

## Test Controls

Keep the database, server tier, clients, threads, duration, and statistics settings unchanged when comparing runs. Restore the database or reset the modified SalesOrderHeader data before repeating a baseline, because Freight increases by `1.00` on every matching update.
