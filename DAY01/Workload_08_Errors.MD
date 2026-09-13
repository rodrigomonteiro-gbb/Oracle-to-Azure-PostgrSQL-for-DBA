# Workload 8: Intentional Errors

This workload repeatedly generates eight PostgreSQL error types inside a PL/pgSQL exception block. The errors are caught on the server so pgbench continues for the configured duration, while each event is recorded in `public.pgbench_error_log`.

Each iteration updates rows in `person.person`, `production.product`, and `sales.customer`, waits from one through five seconds, and then raises an error. The exception subtransaction rolls back those updates. The outer transaction records the error and commits.

## Prerequisites

Run this workload only against a test or disposable AdventureWorks database. The connected role must be able to:

- Create a table and indexes in the `public` schema.
- Create or replace a PL/pgSQL function.
- Update the three AdventureWorks tables.
- Insert into `public.pgbench_error_log`.

`pg_stat_statements` should be installed and loaded for statement context. On Azure Database for PostgreSQL, use PostgreSQL diagnostic logs when authoritative server-side error history is required.

## Run the Workload

Start `Generate-PGSQL-Workload.ps1` and select:

```text
Workload: 8 Errors
Port: 5432
Clients: 4
Threads: 2
Limit: Time
Duration: 60 seconds
```

Start with modest concurrency. Every iteration includes a random one-to-five-second delay, so low transaction throughput is expected.

Select **Reset PGSTATS before run** only when resetting database, statement, and cluster-wide I/O statistics is acceptable. The workload's own error log is persistent and is not cleared by that option.

The launcher first runs this setup once through `psql`:

```text
SQL/AdventureWorks_Errors_Setup.sql
```

The setup creates or updates:

- `public.pgbench_error_log`
- `public.demo_error_transaction(...)`

The launcher then runs:

```text
SQL/AdventureWorks_Errors.sql
```

The application name is `PGBench_Errors`, and results are written under `Results/PGBench_Errors/<timestamp>`.

## Monitor the Workload

Open a separate DBA connection to the same database and run:

```text
SQL/DBA/DBA_ErrorsReview.sql
```

Use one persistent DBA session when using the baseline:

1. Before starting workload 8, run Sections 1 and 2.
2. Start the workload, then repeatedly run Sections 3 through 5.
3. During or after the workload, run Sections 6, 7, 9, and 10.
4. After completion, run Section 8 in the same DBA session used for Section 2.

The live activity queries use `application_name LIKE 'PGBench%'`. Run no other pgbench workloads concurrently when you need workload-8-only session results.

## What to Look For

### Expected errors

Section 9 should show a distribution across these SQLSTATE values:

| SQLSTATE | Error |
| --- | --- |
| `42P01` | undefined_table |
| `42883` | undefined_function |
| `22012` | division_by_zero |
| `22P02` | invalid_text_representation |
| `23502` | not_null_violation |
| `23503` | foreign_key_violation |
| `23505` | unique_violation |
| `22007` | invalid_datetime_format |

Random selection does not guarantee equal counts in a short run. Section 10 shows the latest individual events, backend PIDs, delays, messages, and SQLSTATE values.

### Session health

`Timeout/PgSleep` waits lasting up to approximately five seconds are expected. Investigate:

- `idle in transaction (aborted)` sessions
- Blocking PIDs
- Lock waits
- Query ages substantially longer than five seconds
- Fatal, killed, or abandoned sessions

### Transaction outcomes

A caught error rolls back only the inner PL/pgSQL subtransaction. The outer transaction normally commits, so `xact_rollback` and the Section 8 rollback delta can remain zero even when many intentional errors were captured. Use `public.pgbench_error_log`, not rollback counts, as the workload's authoritative event count.

### Log interpretation

pgbench should report successful outer transactions and warning messages rather than terminating on each intentional error. `pg_stat_statements` may omit failed inner statements. For uncaught errors or full server context, review Azure PostgreSQL diagnostic logs or the configured PostgreSQL server logs.

## Repeatable Tests

Record clients, threads, duration, server tier, statistics settings, and the error-log time window for every run. Because `public.pgbench_error_log` persists, compare runs by timestamp or truncate it before a controlled test when retaining previous events is unnecessary:

```sql
TRUNCATE TABLE public.pgbench_error_log;
```
