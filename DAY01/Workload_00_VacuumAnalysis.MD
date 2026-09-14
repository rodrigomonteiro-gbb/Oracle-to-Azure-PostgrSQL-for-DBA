# VACUUM Analysis and Optimization

Use `DBA_VacuumAnalysis.sql` to assess VACUUM and autovacuum health, identify tables needing maintenance, detect cleanup blockers, evaluate transaction ID wraparound risk, and generate maintenance or tuning commands for DBA review.

The script is diagnostic and read-only. It does not run `VACUUM`, `ANALYZE`, or `ALTER TABLE`. The final sections return proposed commands as text so they can be reviewed before execution.

## Prerequisites

Run the script in each database that requires analysis because table statistics are database-specific.

For complete cross-session visibility, use a role with `pg_monitor`, `pg_read_all_stats`, or equivalent permissions. Less-privileged users may see incomplete activity and query details.

The script targets PostgreSQL 16 or later. Execute it with `psql` because it includes `\pset` and `\timing` commands.

Example:

```powershell
$env:PGSSLMODE = "require"
psql.exe `
    --host="server.postgres.database.azure.com" `
    --port=5432 `
    --username="adminuser" `
    --dbname="adventureworks" `
    --file="SQL\DBA\DBA_VacuumAnalysis.sql"
```

It can also be opened and executed section by section in a PostgreSQL-aware SQL editor. Remove or omit the `psql` meta-commands when the editor does not support them.

## Recommended Workflow

### 1. Establish configuration and urgency

Run Sections 1 through 4.

- **Section 1** verifies the database, PostgreSQL version, monitoring privileges, server start time, and statistics reset time.
- **Section 2** displays global VACUUM and autovacuum configuration, including worker count, wake-up interval, thresholds, scale factors, cost limits, freeze ages, memory, and logging.
- **Section 3** evaluates transaction ID and multixact wraparound risk across databases.
- **Section 4** ranks user tables by dead tuples, maintenance thresholds, size, and maintenance history.

Do not compare statistics from different periods without checking `stats_reset`. Values may also lag briefly after heavy activity.

### 2. Check autovacuum operation

Run Sections 5 through 8 while maintenance is active or when a backlog is suspected.

- **Section 5** finds tables where autovacuum is explicitly disabled.
- **Section 6** reports active VACUUM progress and its current phase.
- **Section 7** lists autovacuum workers, waits, elapsed time, and blocking PIDs.
- **Section 8** identifies sessions blocking an active VACUUM.

Empty results in Sections 6 through 8 mean no matching VACUUM operation or blocker was visible at that moment. They do not prove that autovacuum never runs.

### 3. Find cleanup horizons

Run Sections 9 through 11 before increasing autovacuum frequency or resource usage.

- **Section 9** finds old transactions and `backend_xmin` values that can prevent dead-row cleanup.
- **Section 10** lists prepared transactions that remain open without their original session.
- **Section 11** reviews replication slots that may retain row versions, catalog tuples, or WAL.

Resolve the business owner and purpose of a session, prepared transaction, or replication slot before terminating, committing, rolling back, or dropping it.

### 4. Review freezing and proposed actions

Run Sections 12 through 15.

- **Section 12** ranks tables by transaction ID and multixact age.
- **Section 13** generates targeted `VACUUM (VERBOSE, ANALYZE)` or `ANALYZE VERBOSE` commands.
- **Section 14** generates example per-table autovacuum settings and matching rollback commands for large tables using global defaults.
- **Section 15** provides database-level I/O, cache, temporary-file, transaction, and deadlock context.

Copy only the commands that have been reviewed for the target workload and maintenance window. The script does not execute them.

## Interpreting the Results

### Wraparound risk

Section 3 assigns these levels:

- `OK`: below 75% of the configured XID and multixact limits.
- `WARNING`: at or above 75%.
- `CRITICAL`: at or above 90%.

Treat `CRITICAL` as urgent. Identify old transactions, prepared transactions, replication slots, and the oldest table freeze ages before attempting broad tuning. Wraparound protection is a correctness requirement, not only a performance concern.

### Dead tuples and thresholds

In Section 4, focus on:

- `n_dead_tup`: estimated dead rows awaiting cleanup.
- `dead_tuple_pct`: dead rows relative to estimated live and dead rows.
- `estimated_vacuum_trigger`: approximate global autovacuum threshold.
- `vacuum_threshold_exceeded`: whether the estimate has passed that threshold.
- `n_mod_since_analyze`: changes since the last analysis.
- `analyze_threshold_exceeded`: whether planner statistics may need refresh.
- `last_autovacuum` and `autovacuum_count`: recent automatic maintenance history.
- `table_options`: per-table settings that override global values.

`n_dead_tup` is an estimate and does not directly measure file bloat. A table may need frequent vacuuming without being badly bloated, and regular VACUUM usually makes space reusable inside the table rather than returning it to the operating system.

### VACUUM progress

Section 6 shows the current phase and heap scan progress. Review:

- `phase`
- `heap_blks_scanned_pct`
- `heap_blks_vacuumed`
- `index_vacuum_count`
- `num_dead_tuples` and `max_dead_tuples`
- Wait events and elapsed time

Repeated index vacuum cycles can indicate that available maintenance memory cannot hold all dead tuple identifiers. A wait event may instead indicate lock or storage pressure.

### Long-running transactions

Old transactions and old `backend_xmin` values can prevent VACUUM from removing rows that are no longer visible to newer transactions. Pay particular attention to:

- `idle in transaction` sessions
- Large `transaction_age`
- Large `xmin_age`
- Old prepared transactions
- Inactive replication slots with old `xmin` or `catalog_xmin`

Fixing the cleanup horizon can be more effective than making autovacuum run more frequently.

## Applying Generated Commands

### Manual maintenance

Section 13 may generate a command such as:

```sql
VACUUM (VERBOSE, ANALYZE) sales.salesorderheader;
```

Execute selected commands individually during an appropriate window and monitor Sections 6 through 8. `VACUUM` can increase I/O and CPU usage even though standard VACUUM permits normal reads and writes.

Use `ANALYZE VERBOSE` alone when planner statistics are stale but dead-row cleanup is not required.

### Per-table autovacuum tuning

Section 14 proposes example settings for large, changing tables:

```sql
ALTER TABLE sales.salesorderheader SET (
    autovacuum_vacuum_scale_factor = 0.02,
    autovacuum_analyze_scale_factor = 0.01
);
```

Lower scale factors trigger maintenance after a smaller percentage of the table changes. This is often useful for large tables, but it can increase maintenance frequency and I/O. Treat the generated values as starting points, not universal recommendations.

The result includes a rollback command:

```sql
ALTER TABLE sales.salesorderheader RESET (
    autovacuum_vacuum_scale_factor,
    autovacuum_analyze_scale_factor
);
```

Change one table or a small group at a time, then compare maintenance frequency, dead tuples, query latency, storage I/O, and WAL generation over a representative workload period.

## Important Safety Notes

- Do not disable autovacuum permanently on active tables.
- Do not drop replication slots without confirming they are unused.
- Do not terminate sessions solely because they are old; identify their owner and business impact first.
- Do not run every generated command automatically.
- Do not reset PostgreSQL statistics merely to make counters easier to read unless the monitoring impact is acceptable.
- Do not use `VACUUM FULL` as routine maintenance. It rewrites the table and requires an `ACCESS EXCLUSIVE` lock.
- On Azure Database for PostgreSQL, change server-level parameters through Azure Server parameters when SQL privileges do not permit configuration changes.

## Validation After Changes

After manual maintenance or configuration changes:

1. Rerun Sections 2 through 4 to confirm effective settings and table state.
2. Monitor Sections 6 through 8 during subsequent autovacuum activity.
3. Confirm old cleanup horizons in Sections 9 through 11 have been resolved.
4. Compare `n_dead_tup`, maintenance timestamps, autovacuum counts, query latency, and storage metrics over a representative interval.
5. Verify that wraparound percentages in Section 3 continue to decrease or remain safely controlled.

Evaluate trends over time rather than relying on a single snapshot. The goal is to keep dead tuples and freeze age controlled without causing unacceptable workload latency or storage pressure.
