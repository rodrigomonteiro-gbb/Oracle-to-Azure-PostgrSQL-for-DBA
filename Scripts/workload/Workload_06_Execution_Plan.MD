# Workload 6: Execution Plan

This workload executes seven randomized AdventureWorks query patterns to demonstrate planning and execution behavior, latency variation, joins, scans, physical I/O, temporary-file use, parallel workers, and JIT activity.

## Prerequisites

`pg_stat_statements` must be installed and loaded. For complete metrics, configure these Azure PostgreSQL Server parameters before the test:

```text
track_io_timing = on
pg_stat_statements.track = all
pg_stat_statements.track_planning = on
```

These managed-service settings cannot be enabled by the workload launcher when the login lacks the required server-level privileges.

## Run the Workload

Start `Generate-PGSQL-Workload.ps1` and select:

```text
Workload: 6 Execution Plan
Port: 5432
Clients: 10
Threads: 4
Limit: Time
Duration: 120 seconds
```

Select **Reset PGSTATS before run** for an isolated measurement only when resetting database, statement, and cluster-wide I/O statistics is acceptable. Otherwise use the baseline/delta sections in the DBA script.

The launcher runs:

```text
SQL/AdventureWorks_ExecutionPlan.sql
```

The workload application name is `PGBench_ExecutionPlan`, and results are written under `Results/PGBench_ExecutionPlan/<timestamp>`.

## Monitor the Workload

Execute this script in the same database as workload 6:

```text
SQL/DBA/DBA_ExecutionPlan_Analysis.sql
```

Follow its suggested workflow:

- With reset enabled, run Sections 1 and 2 to verify configuration and reset times.
- During the workload, run Sections 3 through 5 for sessions, waits, and blocking.
- After the workload, run Sections 6 through 12 for statement and object statistics.
- Without reset privileges, run Section 13 before the workload, keep that session open, and run Sections 14 through 19 afterward for interval deltas.

Focus on:

- Calls and total execution time
- Mean, maximum, and standard-deviation execution time
- Planning count and planning time
- Rows per call
- Shared block hits and reads
- Temporary block reads and writes
- Sequential scans and index usage
- Wait events and blocking PIDs
- Parallel-worker and JIT metrics
- WAL bytes, which should be minimal for this SELECT-only workload

PostgreSQL statistics do not retain full execution-plan trees. After identifying an expensive query, run it separately with representative parameters using `EXPLAIN (ANALYZE, BUFFERS, WAL, SETTINGS, SUMMARY)`, or configure `auto_explain` before the test when historical plans are required.
