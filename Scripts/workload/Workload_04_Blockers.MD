# Workload 4: Blockers

This workload starts a blocker and a blocked workload concurrently. The blocker locks one randomized row in `person.person`, waits briefly, and rolls back. The blocked workload requests locks on a range that includes the blocker's row, making lock waits visible.

## Run the Workload

Start `Generate-PGSQL-Workload.ps1` and select:

```text
Workload: 4 Blockers
Port: 5432
Clients: 5
Threads: 2
Limit: Time
Duration: 120 seconds
```

Use more than one client so repeated blocking pairs are easy to observe. The selected client count applies to both pgbench processes. Select **Reset PGSTATS before run** only when resetting shared statistics is acceptable.

The launcher starts these scripts:

```text
Blocker: SQL/AdventureWorks_blockers_2A.sql
Blocked: SQL/AdventureWorks_blocked_2A.sql
```

Their application names and result folders are:

| Role | Application name | Result folder |
| --- | --- | --- |
| Blocker | `PGBench_blockers_2A` | `Results/PGBench_blockers_2A/<timestamp>` |
| Blocked | `PGBench_blocked_2A` | `Results/PGBench_blocked_2A/<timestamp>` |

Both scripts use transactions and finish with `ROLLBACK`, so they release locks without retaining data changes.

## Monitor the Workload

While both pgbench processes are running, execute:

```text
SQL/DBA/DBA_BlockingReview.sql
```

Focus on:

- Sessions waiting on `wait_event_type = 'Lock'`
- Blocked PID and blocker PID relationships
- Blocked duration
- Number of sessions blocked by each blocker
- Lock type, mode, relation, and granted state
- The `PGBench_blockers_2A` and `PGBench_blocked_2A` application names

The blocking queries are most useful while the workload is active; after rollback, the lock relationships disappear. Use a separate DBA session and rerun the blocked-session sections several times during the test.
