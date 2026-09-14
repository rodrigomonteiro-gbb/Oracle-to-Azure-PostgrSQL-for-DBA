# Reading `pg_stat_activity`

For PostgreSQL troubleshooting, four fields usually provide the fastest first assessment of a session:

1. `state`
2. `wait_event_type`
3. `wait_event`
4. `pg_blocking_pids(pid)`

Use them together. `state` describes the backend's overall state, while `wait_event_type` and `wait_event` describe what it is waiting for at the instant the view is sampled. A backend can therefore be `active` and still be waiting.

## Quick Triage Query

```sql
SELECT pid,
       usename,
       application_name,
       client_addr,
       state,
       wait_event_type,
       wait_event,
       clock_timestamp() - xact_start AS transaction_age,
       clock_timestamp() - query_start AS query_age,
       pg_blocking_pids(pid) AS blocking_pids,
       query
FROM pg_stat_activity
WHERE datname = current_database()
  AND pid <> pg_backend_pid()
ORDER BY query_start NULLS LAST;
```

A role with `pg_monitor`, `pg_read_all_stats`, or equivalent privileges provides the most complete cross-user query visibility. Without those permissions, some query text and session details can be hidden.

## 1. `state`

`state` describes what the backend is doing at a high level. It does not by itself identify whether an active query is using CPU or waiting on another resource.

| Value | Meaning | Typical interpretation |
| --- | --- | --- |
| `active` | The backend is executing a query. | Check the wait columns to determine whether it is running/runnable or currently waiting. |
| `idle` | The previous query completed and the backend is waiting for a new client command. | Usually normal for pooled or persistent connections. A very large idle population can indicate an oversized pool. |
| `idle in transaction` | The previous statement completed, but its transaction remains open. | Investigate when old. It can retain locks, preserve an old snapshot, and interfere with VACUUM cleanup. |
| `idle in transaction (aborted)` | A statement failed inside a transaction, and the client has not issued `ROLLBACK`. | Usually an application error-handling problem. The transaction cannot perform normal work until rolled back. |
| `fastpath function call` | The backend is executing a fast-path function. | Rare in typical application troubleshooting. |
| `disabled` | Activity tracking is disabled for the backend. | Check `track_activities` and monitoring configuration. |

### Important state details

For an `active` backend, `query` is the currently executing statement. For a backend that is not active, `query` normally contains its last statement, not necessarily work still running.

`state = 'idle'` is not automatically a problem. Judge idle connections against pool design, connection limits, backend memory, and how long they remain idle.

`idle in transaction` is more significant than ordinary idle because the transaction is still open. Prioritize sessions with long `transaction_age`, old `backend_xmin`, held locks, or business-impacting blockers.

## 2. `wait_event_type`

`wait_event_type` is the broad category of the backend's current wait. Available values and individual events can change between PostgreSQL versions, so always interpret them using the documentation for the server version being monitored.

| Common type | Meaning | First troubleshooting direction |
| --- | --- | --- |
| `Lock` | Waiting for a heavyweight lock held or queued by another process. | Use `pg_blocking_pids(pid)`, inspect the blocker transaction and query, and review `pg_locks`. |
| `LWLock` | Waiting for a PostgreSQL lightweight lock protecting shared-memory structures. | Look for concurrency hot spots involving buffers, WAL, relation extension, or other internal structures. |
| `IO` | Waiting for an I/O operation. | Correlate with query access paths, block reads/writes, cache behavior, storage latency, checkpoints, and `pg_stat_io`. |
| `Client` | Waiting to read from or write to the connected client. | Often means the database is waiting on the application or network rather than the application waiting on PostgreSQL. |
| `IPC` | Waiting for another PostgreSQL process. | Inspect parallel workers, background workers, synchronization, and the specific event name. |
| `Activity` | Waiting in a background-process activity loop. | Often normal for an idle background process. Interpret the specific event and backend type. |
| `Timeout` | Waiting for a configured timer or deliberate delay. | Can be normal, such as `PgSleep`, vacuum delay, or checkpoint pacing. |
| `BufferPin` | Waiting for another backend to release a pin on a shared buffer. | Investigate the other session and operations holding access to the page. |
| `Extension` | Waiting inside extension-defined code. | Consult the extension's documentation and the specific event name. |

A `NULL` `wait_event_type` means PostgreSQL is not reporting a wait event at that instant. For an active backend, this commonly means it is running on CPU or runnable and waiting to be scheduled. It does not prove the query is healthy or continuously consuming CPU.

## 3. `wait_event`

`wait_event` is the specific reason within `wait_event_type`. Always read the two columns together.

| Type | Example event | Typical meaning |
| --- | --- | --- |
| `Lock` | `transactionid` | Waiting for a transaction to finish, commonly because of conflicting row changes. |
| `Lock` | `relation` | Waiting for a table or other relation-level lock. |
| `Lock` | `tuple` | Waiting for tuple-level lock coordination. Row-lock waits can also appear as `transactionid`. |
| `IO` | `DataFileRead` | Waiting to read a relation data page from storage. |
| `IO` | `DataFileWrite` | Waiting to write a relation data page. |
| `IO` | `WALWrite` | Waiting for WAL data to be written. The category can vary by PostgreSQL version. |
| `Client` | `ClientRead` | Waiting for the client to send the next command or more data. |
| `Client` | `ClientWrite` | Waiting for the client or network to accept result data. |
| `LWLock` | `BufferMapping` | Contention while mapping shared-buffer pages. |
| `Timeout` | `PgSleep` | Waiting because `pg_sleep` or a related sleep function was called. |

This table contains examples, not an exhaustive catalog. Use the exact PostgreSQL-version documentation when an unfamiliar event appears.

### Common combinations

| State | Wait type and event | Interpretation |
| --- | --- | --- |
| `active` | Both wait columns are `NULL` | Running on CPU or runnable at the sampling instant. |
| `active` | `Lock` / `transactionid` | Waiting for another transaction, often due to conflicting row changes. |
| `active` | `IO` / `DataFileRead` | Waiting for a data page from storage. |
| `active` | `Client` / `ClientWrite` | Query execution may be waiting for the client to consume results. |
| `idle` | `Client` / `ClientRead` | Connected and waiting for the next client command; commonly normal. |
| `idle in transaction` | `Client` / `ClientRead` | The server is waiting for the client while a transaction remains open; investigate when old. |
| `active` | `Timeout` / `PgSleep` | Deliberately sleeping; expected in workloads that call `pg_sleep`. |

Wait events are instantaneous samples. Repeated samples or monitoring history are needed to distinguish a brief normal wait from a sustained bottleneck.

## 4. `pg_blocking_pids(pid)`

`pg_blocking_pids(integer)` returns an array of backend process IDs that are blocking the specified backend from acquiring a lock.

```sql
SELECT pg_blocking_pids(200);
```

Example result:

```text
{150}
```

This means PID `200` is waiting for a lock and PID `150` is currently blocking it. An empty array (`{}`) means PostgreSQL did not identify a lock blocker for that PID at the sampling instant.

The function reports lock blockers, not every possible cause of waiting. A session waiting on storage, the client, a timeout, CPU scheduling, or some internal synchronization can have an empty blocker array.

PostgreSQL can report:

- **Hard blockers** that hold a conflicting granted lock.
- **Soft blockers** that are ahead in the lock wait queue and prevent the requested lock from being granted.

With parallel queries, PostgreSQL reports the client backend or parallel leader PID rather than treating each parallel worker as an independent client session. The same PID can appear more than once in unusual parallel-worker cases, so use `DISTINCT` when expanding arrays for summaries.

### Blocking chains

If the samples show:

```text
PID 300 -> {250}
PID 250 -> {100}
PID 100 -> {}
```

PID `100` is the root blocker, PID `250` is both blocked and blocking, and PID `300` is farther down the chain. Resolve the root cause before treating downstream sessions.

Do not terminate a blocker based only on its PID. First inspect its user, application, transaction age, state, query, and business purpose. A blocker can be idle because its last statement finished while its transaction and locks remain open.

## Understanding `cardinality()`

`cardinality(anyarray)` returns the total number of elements in an array across all dimensions.

```sql
SELECT cardinality(ARRAY[150, 175]);
```

Result:

```text
2
```

For `pg_blocking_pids(pid)`:

- `cardinality(...) = 0` means the blocker array is empty.
- `cardinality(...) > 0` means one or more blocker PIDs were returned.
- `cardinality(NULL)` returns `NULL`.

This predicate therefore retains only sessions with identified lock blockers:

```sql
WHERE cardinality(pg_blocking_pids(pid)) > 0
```

Calling `pg_blocking_pids(pid)` in both the `SELECT` list and `WHERE` clause repeats the function call. For a clearer query and a consistent sample, calculate it once with `CROSS JOIN LATERAL`.

## Most Useful Blocking Query

```sql
SELECT activity.pid,
       activity.usename,
       activity.application_name,
       activity.client_addr,
       activity.state,
       activity.wait_event_type,
       activity.wait_event,
       clock_timestamp() - activity.xact_start AS transaction_age,
       clock_timestamp() - activity.query_start AS query_age,
       blockers.blocking_pids,
       cardinality(blockers.blocking_pids) AS blocker_count,
       activity.query
FROM pg_stat_activity AS activity
CROSS JOIN LATERAL (
    SELECT pg_blocking_pids(activity.pid) AS blocking_pids
) AS blockers
WHERE activity.datname = current_database()
  AND cardinality(blockers.blocking_pids) > 0
ORDER BY activity.query_start NULLS LAST;
```

`CROSS JOIN LATERAL` allows the subquery to use `activity.pid`. It computes the blocker array once per activity row and gives that result the name `blockers.blocking_pids`. `cardinality()` then counts the returned PIDs and filters out empty arrays.

## Blocked Sessions with Blocker Details

Use this query when the blocker identity and SQL text are needed:

```sql
SELECT blocked.pid AS blocked_pid,
       blocked.usename AS blocked_user,
       blocked.application_name AS blocked_application,
       blocked.state AS blocked_state,
       blocked.wait_event_type,
       blocked.wait_event,
       clock_timestamp() - blocked.query_start AS blocked_duration,
       blocker.pid AS blocker_pid,
       blocker.usename AS blocker_user,
       blocker.application_name AS blocker_application,
       blocker.state AS blocker_state,
       clock_timestamp() - blocker.xact_start AS blocker_transaction_age,
       left(blocked.query, 1000) AS blocked_query,
       left(blocker.query, 1000) AS blocker_query
FROM pg_stat_activity AS blocked
CROSS JOIN LATERAL
     unnest(pg_blocking_pids(blocked.pid)) AS blocking(blocker_pid)
JOIN pg_stat_activity AS blocker
  ON blocker.pid = blocking.blocker_pid
WHERE blocked.datname = current_database()
ORDER BY blocked_duration DESC;
```

`unnest()` converts the blocker PID array into rows. This returns one row for each blocked-session/blocker pair, so a blocked session with multiple blockers appears multiple times.

## DBA Triage Rules

### Usually healthy or expected

- `active` with no wait event: running or runnable; assess duration and resource use.
- `idle` with `ClientRead`: waiting for the next client command.
- Short-lived `IO`, `LWLock`, or `Lock` waits: normal when they do not accumulate or affect latency.

### Lock problem

Indicators:

```text
state = active
wait_event_type = Lock
blocking_pids is not empty
```

Inspect the root blocker, open transaction age, locked objects, and both queries. Do not assume the blocked query is at fault.

### Application transaction problem

Indicators:

```text
state = idle in transaction
```

or:

```text
state = idle in transaction (aborted)
```

Review connection handling, missing commits or rollbacks, transaction timeouts, held locks, and `backend_xmin` age.

### Storage pressure

Indicators:

```text
state = active
wait_event_type = IO
```

Correlate the specific event with `pg_stat_statements`, `pg_stat_io`, query plans, block-read timing, cache behavior, checkpoints, and platform storage metrics. One sampled I/O wait is not enough to diagnose a storage problem.

### Client or network bottleneck

Indicators:

```text
wait_event_type = Client
wait_event = ClientWrite
```

PostgreSQL may be producing results faster than the client or network can consume them. For `ClientRead`, PostgreSQL is usually waiting for the application to send more work.

### Internal contention

Indicators:

```text
wait_event_type = LWLock
```

Use the specific wait event, repeated samples, workload concurrency, and server metrics to identify the contended subsystem. Avoid tuning based on one transient observation.

## Practical Sampling Guidance

`pg_stat_activity` is a live snapshot, not historical wait statistics. A session can change state immediately after the query returns.

For reliable diagnosis:

1. Capture repeated samples during the performance problem.
2. Include timestamps, PID, application name, transaction age, query age, and query text.
3. Separate lock waits from non-lock waits using `pg_blocking_pids(pid)`.
4. Find the root blocker in a blocking chain.
5. Correlate live activity with `pg_stat_statements`, table/index statistics, `pg_stat_io`, PostgreSQL logs, and platform metrics.

These four fields provide a strong first classification: the backend is running, waiting for a lock, waiting for storage, waiting for the client, deliberately sleeping, or experiencing internal contention. They identify the direction of investigation, but sustained evidence is still required before changing configuration or terminating sessions.

## References

- [PostgreSQL: The Statistics Collector](https://www.postgresql.org/docs/current/monitoring-stats.html)
- [PostgreSQL: System Information Functions and Operators](https://www.postgresql.org/docs/current/functions-info.html)
- [PostgreSQL: Array Functions and Operators](https://www.postgresql.org/docs/current/functions-array.html)
- [PostgreSQL: Explicit Locking](https://www.postgresql.org/docs/current/explicit-locking.html)
