# PostgreSQL Query Store Demo

PostgreSQL does not provide SQL Server Query Store as a core feature. This demo uses `pg_stat_statements`, PostgreSQL's closest built-in equivalent for normalized query text and cumulative planning, execution, I/O, temporary-file, and WAL statistics.

`pg_stat_statements` does not retain complete execution-plan trees, application names, individual execution records, or SQL Server-style forced plans. Use `EXPLAIN`, `auto_explain`, and PostgreSQL logs when those details are required.

## Files

Run these files in order:

1. `QueryStoreDemo_ 01_Cleanup.sql` clears captured statements for the current database.
2. `QueryStoreDemo_ 02_Settings.sql` inspects or applies collection settings.
3. Run a representative workload, such as workload 6 from the launcher.
4. `QueryStoreDemo_ 03_ShowContents.sql` displays a concise captured-data summary.
5. `DBA/DBA_QueryStore_Review.sql` performs deeper DBA analysis.

## Prerequisites

The server must preload `pg_stat_statements`:

```text
shared_preload_libraries = pg_stat_statements
```

Changing `shared_preload_libraries` or `pg_stat_statements.max` requires a server restart. Install the extension in every database where its view will be queried:

```sql
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
```

The settings script reports whether the extension is installed but does not create
it. Install it explicitly before using apply mode.

Recommended controlled-demo values are:

```text
compute_query_id = auto
pg_stat_statements.max = 5000
pg_stat_statements.track = all
pg_stat_statements.track_planning = on
pg_stat_statements.track_utility = on
pg_stat_statements.save = on
track_io_timing = on
```

On Azure Database for PostgreSQL, configure server parameters in the Azure portal, CLI, ARM/Bicep, or Terraform. Managed-service roles may not be allowed to use `ALTER SYSTEM`. Restart the server when Azure marks a parameter as requiring restart, then reconnect before validating values.

Tracking planning and I/O timing adds overhead. Enable the detailed settings for a controlled demonstration first and measure overhead before adopting them in production.

## Step 1: Clear Existing History

Run:

```text
SQL/QueryStoreDemo_ 01_Cleanup.sql
```

The script calls `pg_stat_statements_reset` for the current database. It removes captured statistics for every user and application in that database, so do not run it on a shared production database without approval.

The verification statements executed after the reset may immediately create a few new entries. This is expected.

## Step 2: Configure Tracking

Inspection-only mode makes no configuration changes:

```powershell
psql.exe --dbname="adventureworks" `
    --file="SQL\QueryStoreDemo_ 02_Settings.sql"
```

On a self-managed server with sufficient privileges, apply reloadable settings with:

```powershell
psql.exe --dbname="adventureworks" `
    --variable="apply_changes=on" `
    --file="SQL\QueryStoreDemo_ 02_Settings.sql"
```

The script intentionally does not modify `shared_preload_libraries` or `pg_stat_statements.max` because changing the preload list incorrectly can disable other libraries and both settings require a restart.

Reconnect after applying settings. Confirm that the effective values shown by the script match the recommended values before generating the workload.

## Step 3: Generate Query Activity

A useful existing workload is:

```text
Workload: 6 Execution Plan
Clients: 10
Threads: 4
Limit: Time
Duration: 120 seconds
```

For a clean Query Store demonstration, avoid selecting **Reset PGSTATS before run** after Step 1 because the launcher would reset `pg_stat_statements` again immediately before the workload. Either approach is valid, but record exactly when the reset occurred.

You can use any workload. Keep the database, duration, concurrency, cache conditions, and server configuration consistent when comparing runs.

## Step 4: Show Captured Contents

Run:

```text
SQL/QueryStoreDemo_ 03_ShowContents.sql
```

Review:

- `stats_reset` to confirm the measurement start.
- `dealloc` to detect entries evicted because the statement limit was reached.
- Total execution time for aggregate workload impact.
- Calls for execution frequency.
- Mean, maximum, and standard-deviation time for latency and variability.
- Planning time and plan count for compilation overhead.
- Shared block reads and hits for physical I/O and cache reuse.
- Temporary blocks for sort or hash spills.
- WAL bytes for write activity.

Query text is normalized. Literal values usually appear as placeholders such as `$1`, allowing structurally equivalent statements to share a `queryid`.

## Step 5: Perform DBA Analysis

Run:

```text
SQL/DBA/DBA_QueryStore_Review.sql
```

Its sections cover:

1. Configuration, extension version, permissions, and reset history.
2. Statement capacity and deallocation pressure.
3. Highest total execution cost.
4. Highest mean latency.
5. Most frequently executed statements.
6. Planning overhead.
7. Physical reads and cache reuse.
8. Temporary-file spills.
9. WAL and write activity.
10. Latency variability.
11. Current sessions, waits, and blockers.

Start with total execution time rather than mean latency alone. A moderately expensive statement called thousands of times can have more impact than a single slow statement.

## Investigate a Query

After identifying a `queryid`:

Obtain the original SQL and representative parameter values from the application or logs. Run it safely with:

```sql
EXPLAIN (ANALYZE, BUFFERS, WAL, SETTINGS, SUMMARY)
SELECT ...;
```

Compare estimates with actual rows, scan methods, joins, buffers, spills, planning time, and execution time. Test indexing, SQL, statistics, or configuration changes in a controlled environment, then reset or record a new baseline and repeat the same workload.

`EXPLAIN ANALYZE` executes the statement. Use a transaction with rollback for test DML when safe, and do not execute production-changing SQL merely to obtain a plan.

## Important Limitations

- Statistics are cumulative between resets, not individual execution records.
- Complete historical execution plans are not stored.
- `application_name` is not retained in `pg_stat_statements`.
- Similar normalized queries can share one `queryid`.
- A `queryid` can change across major PostgreSQL versions or other environmental changes.
- Entries can be deallocated when `pg_stat_statements.max` is too small.
- Server restart with `pg_stat_statements.save = off` loses collected entries.
- Failed statements may not be represented as expected; use PostgreSQL or Azure diagnostic logs for authoritative error history.

Use reset timestamps, consistent workloads, and normalized per-call metrics when comparing tests.
