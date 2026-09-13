# Workload 1: PGBench Compile Workload

This workload repeatedly runs seven parameterized AdventureWorks queries with randomized customer, person, product, territory, birth-year, and sales-year values. It is useful for observing planning activity, statement diversity, latency, and database activity under concurrent query execution.

## Run the Workload

Start `Generate-PGSQL-Workload.ps1` and select:

```text
Workload: 1 Compile Workload
Port: 5432
Clients: 10
Threads: 4
Limit: Time
Duration: 60 seconds
```

Increase clients and duration gradually if more load is needed. Select **Reset PGSTATS before run** only when resetting shared statistics is acceptable in the target environment.

The launcher runs:

```text
SQL/AdventureWorks_Compile_Workload.sql
```

The workload application name is `PGBench_CompileWorkload`, and results are written under `Results/PGBench_CompileWorkload/<timestamp>`.

## Monitor the Workload

While pgbench is running, execute:

```text
SQL/DBA/DBA_ActivityReview.sql
```

Use the first query to isolate `PGBench%` sessions in the `adventureworks` database. Use the second query to inspect query age, transaction age, waits, and blocking PIDs across sessions.

Focus on:

- Number of active `PGBench_CompileWorkload` sessions
- Queries with the highest query age
- Active sessions with no wait event, which may be CPU-bound
- I/O or lock waits
- Unexpected blocking or idle-in-transaction sessions

For historical statement totals, inspect `pg_stat_statements` after the run and compare calls, planning time, execution time, and block reads. Planning metrics require `pg_stat_statements.track_planning` to be enabled through the Azure server parameters before the test.

Keep the database, client count, threads, duration, and server tier unchanged when comparing runs.
