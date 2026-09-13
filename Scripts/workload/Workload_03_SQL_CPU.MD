# Workload 3: SQL CPU

This option starts three concurrent CPU workloads. They perform power calculations, cosine calculations, and number-table calculations to create distinguishable CPU-heavy statements.

## Run the Workload

Start `Generate-PGSQL-Workload.ps1` and select:

```text
Workload: 3 SQL CPU
Port: 5432
Clients: 5
Threads: 2
Limit: Time
Duration: 60 seconds
```

The selected client count applies to each of the three pgbench processes, so five clients create up to fifteen workload sessions in total. Increase load carefully. Select **Reset PGSTATS before run** only when resetting shared statistics is acceptable.

The launcher starts these workloads concurrently:

```text
SQL/CPU Busy - Power.sql
SQL/CPU Busy - COSine.sql
SQL/CPU Busy - Numbers Table.sql
```

Their application names and result folders are:

| Application name | Result folder |
| --- | --- |
| `PGBench_SQLCPUPower` | `Results/PGBench_SQLCPUPower/<timestamp>` |
| `PGBench_SQLCPUCosine` | `Results/PGBench_SQLCPUCosine/<timestamp>` |
| `PGBench_SQLCPUNumbers` | `Results/PGBench_SQLCPUNumbers/<timestamp>` |

## Monitor the Workload

While the workloads are running, execute:

```text
SQL/DBA/DBA_ActivityReview.sql
```

Focus on:

- Session counts for each of the three application names
- Active sessions with no wait event, indicating CPU execution or runnable work
- Query age for each calculation type
- Azure CPU Percent and whether it approaches the server limit
- Pgbench latency and throughput for each result folder
- Unexpected lock, I/O, or client waits

Use `pg_stat_statements` after the run to rank the three statement families by total and mean execution time. A useful comparison keeps the database, clients, threads, duration, and server tier unchanged.
