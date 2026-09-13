# Workload 2: PGBench CPU

This workload calls AdventureWorks search functions with randomized letters to generate database CPU activity. The launcher runs the setup script first to create or replace the required functions.

## Prerequisites

The AdventureWorks schemas and these views must exist:

- `humanresources.vemployee`
- `humanresources.vemployeedepartmenthistory`

The connected role must be allowed to create the `test` schema and functions. The launcher executes `SQL/AdventureWorks_CPU - setup.sql` before starting pgbench and stops if setup fails.

## Run the Workload

Start `Generate-PGSQL-Workload.ps1` and select:

```text
Workload: 2 CPU
Port: 5432
Clients: 10
Threads: 4
Limit: Time
Duration: 60 seconds
```

Start conservatively and increase clients only while watching CPU and latency. Select **Reset PGSTATS before run** only when resetting shared statistics is acceptable.

The launcher runs:

```text
Setup:    SQL/AdventureWorks_CPU - setup.sql
Workload: SQL/AdventureWorks_CPU.sql
```

The workload application name is `PGBench_CPU_Stress`, and results are written under `Results/PGBench_CPU_Stress/<timestamp>`.

## Monitor the Workload

While pgbench is running, execute:

```text
SQL/DBA/DBA_ActivityReview.sql
```

Focus on:

- Active `PGBench_CPU_Stress` sessions
- Active sessions with no wait event, indicating CPU execution or runnable work
- Query and transaction age
- I/O or lock waits that show the test is not purely CPU-bound
- Azure CPU Percent and Memory Percent
- Throughput and latency reported by pgbench

A successful CPU demonstration raises CPU utilization while most workload sessions remain active without sustained lock or I/O waits. Keep the client count, threads, duration, server tier, and database unchanged when comparing runs.
