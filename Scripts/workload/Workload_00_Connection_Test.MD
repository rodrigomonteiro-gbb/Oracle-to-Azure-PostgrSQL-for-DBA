# Recommended Demonstration

This workload creates persistent pgbench clients that repeatedly execute a trivial query and then wait for one second. The think time creates many mostly idle client sessions, which clearly demonstrates how PostgreSQL per-session memory and process overhead adds up, and how PgBouncer reduces server backends.

Run two phases with the same client count, threads, and duration. Change only the port: use `5432` for direct PostgreSQL and `6432` for PgBouncer.

## Azure Setup

In Azure PostgreSQL Server parameters, configure:

```text
pgbouncer.enabled = true
pgbouncer.pool_mode = transaction
pgbouncer.default_pool_size = 20 or 50
pgbouncer.max_client_conn = greater than the test client count
metrics.pgbouncer_diagnostics = on
pgbouncer.stats_users = postgres or the monitoring login
```

PgBouncer is supported on General Purpose and Memory Optimized compute tiers, not Burstable. PgBouncer and its diagnostic metrics are dynamic settings and do not require a server restart. Azure Monitor metrics are emitted at one-minute intervals, so allow enough test duration for them to appear.

## Test 1: Direct PostgreSQL

In `Generate-PGSQL-Workload.ps1`, select:

```text
Workload: 0 Connection Test
Port: 5432
Clients: start with 100, then 250, then 500
Threads: 10 or 20
Limit: Time
Duration: 180 seconds
```

While the workload runs, execute Queries 3 through 7 in `SQL/DBA/DBA_ConnectionAnalysis.SQL`.

Expected result:

- Approximately one PostgreSQL backend per pgbench client.
- Backend count rises close to the configured client count.
- Most backend processes are idle or waiting on `ClientRead` during `\sleep`.
- Connection slots decline as client count rises.
- Azure Memory Percent can increase as backend count grows.

Capture these values for comparison:

- `client_sessions`
- `remaining_regular_slots`
- `usable_connection_pct`
- Active versus idle sessions
- Azure Active Connections
- Azure Memory Percent
- Azure CPU Percent

## Test 2: PgBouncer

Repeat the test with exactly the same settings, changing only:

```text
Port: 6432
```

Expected result with transaction pooling:

- Pgbench still maintains 100 to 500 client connections.
- PostgreSQL sees approximately the configured pool size rather than one backend for every client.
- PostgreSQL backend-process and connection-slot pressure are lower.
- Memory pressure should be lower than the direct test.
- Clients can wait in PgBouncer when concurrent demand exceeds pool size.

In Azure Monitor, graph these PgBouncer metrics:

- Active client connections
- Waiting client connections
- Active server connections
- Idle server connections
- Total pooled connections
- Number of connection pools

## Pooling Ratio

Calculate the main comparison as:

```text
Pooling ratio = PgBouncer client connections / PostgreSQL server connections
```

Example:

```text
500 clients / 50 server connections = 10:1 pooling ratio
```

The most persuasive demonstration shows hundreds of PgBouncer clients while PostgreSQL maintains only 20 to 50 backend processes.

## PgBouncer Admin Console

First add the monitoring login to the Azure Server parameter `pgbouncer.stats_users`.

Connect to the PgBouncer administration database through port `6432`:

```powershell
psql -h <server> -p 6432 -U postgres -d pgbouncer
```

Run these commands during the pooled test:

```sql
SHOW POOLS;
SHOW STATS;
SHOW DATABASES;
```

In `SHOW POOLS`, focus on:

- `cl_active`: Client connections active in the pool.
- `cl_waiting`: Clients waiting for a PostgreSQL server connection.
- `sv_active`: PostgreSQL server connections currently in use.
- `sv_idle`: PostgreSQL server connections ready for reuse.

## Interpreting Memory

PostgreSQL core views expose backend PIDs but not per-process operating-system RSS/private memory. Query 11 in `DBA_ConnectionAnalysis.SQL` reports only the DBA session executing that query, not all pgbench backend processes. On Azure, use Memory Percent for the direct-versus-pooled memory comparison and use Queries 3 through 7 for server backend counts, states, and waits.

Keep unrelated activity low during both phases. Use the same server tier, database, credentials, client count, thread count, duration, and think time so that the port and connection-pooling path are the only material differences.