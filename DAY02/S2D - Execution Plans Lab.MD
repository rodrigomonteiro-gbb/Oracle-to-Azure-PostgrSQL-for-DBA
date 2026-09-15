# S2D - Execution Plans Lab

## Purpose

In this lab, you will use PostgreSQL execution plans to investigate how queries access data and how the planner chooses between competing strategies.

You will learn how to:

- Read plans from the bottom up
- Compare estimated rows with actual rows
- Recognize sequential, index, index-only, and bitmap scans
- Understand nested loop, hash, and merge joins
- Identify sort and hash spills
- Examine parallel plans, CTEs, and subplans
- Diagnose incorrect row estimates
- Measure the benefits and costs of indexes
- Tune a query by changing one thing at a time

The scripts use the AdventureWorks database and are located in the `plans` folder.

## Important: How to Run These Scripts

Run the scripts in the **VS Code PostgreSQL query editor** while connected to the AdventureWorks database.

The original `psql` display commands in these scripts have been commented out. Lines such as `-- \echo`, `-- \timing`, and `-- \pset` are explanatory comments and should not be uncommented.

Run each file as a complete script unless your instructor asks you to execute one section at a time. Keep the SQL comments visible because they describe what to inspect in each plan.

## Prerequisites

Before starting, confirm that you have:

- VS Code open at the workshop repository folder
- A PostgreSQL extension installed and enabled in VS Code
- A working connection to the PostgreSQL server
- The AdventureWorks database installed
- A PostgreSQL account that can create and drop indexes and statistics
- Permission to run `ANALYZE`, `VACUUM`, and `ALTER TABLE` on the lab tables

## 1. Connect with VS Code

1. Open the VS Code PostgreSQL extension or database connections view.
2. Connect to the PostgreSQL workshop server.
3. Select the `adventureworks` database.
4. Open a new PostgreSQL query editor.
5. Run the following connection check:

```sql
SELECT current_database(), current_user, version();
```

Confirm that `current_database()` returns the AdventureWorks database before continuing.

## 2. Open and Run a Script

From the VS Code Explorer:

1. Expand the `plans` folder.
2. Open `00_discovery.sql`.
3. Confirm that the editor is connected to the correct PostgreSQL server and database.
4. Use the extension's **Execute Query** or **Run Query** command to execute the entire file.
5. Review every result set before opening the next script.

Do not run all files simultaneously. Several scripts create indexes that later scripts inspect or replace.

## 3. Lab Sequence

Run the scripts in this order:

| Step | Script | Topic |
| ---: | --- | --- |
| 1 | `00_discovery.sql` | Read-only inventory of tables, existing indexes, statistics, row counts, and planner settings |
| 2 | `01_reading_plans.sql` | `EXPLAIN`, `EXPLAIN ANALYZE`, buffers, costs, and plan-reading basics |
| 3 | `02_seqscan_vs_index.sql` | Sequential scan versus index access and selectivity |
| 4 | `03_index_only_and_bitmap.sql` | Index Only Scan, heap fetches, Bitmap Heap Scan, and `BitmapAnd` |
| 5 | `04_joins.sql` | Nested Loop, Hash Join, Merge Join, and the meaning of `loops` |
| 6 | `05_sorts_and_aggregates.sql` | Sort spills, hash and group aggregates, and removing a sort with an index |
| 7 | `06_parallel_and_cte.sql` | Parallel plans, Gather, Memoize, CTE behavior, InitPlan, and SubPlan |
| 8 | `07_row_estimates.sql` | Incorrect estimates caused by statistics, correlation, and expressions |
| 9 | `08_index_tradeoffs.sql` | Index storage, write amplification, partial and expression indexes, and unused-index auditing |
| 10 | `09_full_scenario.sql` | Complete five-round query-tuning scenario |
| 11 | `99_cleanup.sql` | Remove all objects created by the execution-plan lab |

### Recommended Core Path

If workshop time is limited, run:

1. `00_discovery.sql`
2. `01_reading_plans.sql`
3. `02_seqscan_vs_index.sql`
4. `03_index_only_and_bitmap.sql`
5. `04_joins.sql`
6. `07_row_estimates.sql`
7. `09_full_scenario.sql`
8. `99_cleanup.sql`

## 4. Read Every Plan Bottom Up

For each `EXPLAIN (ANALYZE, BUFFERS)` result, ask these questions in order:

1. Where are `actual rows` very different from the estimated `rows`?
2. Which operation is at the bottom of the affected branch?
3. Which node has the largest `actual time` after considering `loops`?
4. Is a Sequential Scan reading many rows and discarding most of them?
5. Is `Rows Removed by Filter` unexpectedly high?
6. Does an Index Only Scan still show heap fetches?
7. Do buffers show mostly cache hits or physical reads?
8. Is a sort using memory or writing to disk?
9. Does a hash operation show more than one batch?
10. Were all planned parallel workers launched?

Remember:

- Planner cost is measured in internal cost units, not milliseconds.
- Compare costs only between alternatives for the same query.
- `EXPLAIN` estimates without executing the query.
- `EXPLAIN ANALYZE` executes the query and reports actual behavior.

> **Warning:** Never add `ANALYZE` to an `INSERT`, `UPDATE`, or `DELETE` plan unless the change is intentionally allowed or protected by `BEGIN` and `ROLLBACK`. The write demonstrations in `08_index_tradeoffs.sql` are already wrapped in transactions and rolled back.

## 5. Plan Observation Worksheet

Use this table for the main before-and-after comparisons:

| Script | Query or Section | Scan or Join Type | Estimated Rows | Actual Rows | Cost | Buffers | Key Observation |
| --- | --- | --- | ---: | ---: | ---: | ---: | --- |
| `01_reading_plans.sql` | | | | | | | |
| `02_seqscan_vs_index.sql` | Before index | | | | | | |
| `02_seqscan_vs_index.sql` | After index | | | | | | |
| `03_index_only_and_bitmap.sql` | Index Only Scan | | | | | | |
| `04_joins.sql` | Hash Join | | | | | | |
| `04_joins.sql` | Nested Loop | | | | | | |
| `04_joins.sql` | Merge Join | | | | | | |
| `05_sorts_and_aggregates.sql` | Sort or aggregate | | | | | | |
| `07_row_estimates.sql` | Before statistics fix | | | | | | |
| `07_row_estimates.sql` | After statistics fix | | | | | | |

### Full Scenario Worksheet

Record the result of each round in `09_full_scenario.sql`:

| Round | Change | Plan Shape | Total Cost | Actual Time | Shared Buffers | Observation |
| ---: | --- | --- | ---: | ---: | ---: | --- |
| 1 | Baseline | | | | | |
| 2 | Index the date filter | | | | | |
| 3 | Index the child-table join key | | | | | |
| 4 | Add a covering index and run `VACUUM` | | | | | |
| 5 | Test `work_mem` | | | | | |

The AdventureWorks tables may fit in memory, so execution times can be small. Focus on plan shape, estimated versus actual rows, cost, buffers, rows removed by filters, spills, and heap fetches.

## 6. Safety and Expected Changes

The lab creates temporary demonstration objects in the AdventureWorks schemas:

- Indexes named `ix_demo_*`
- Extended statistics named `stx_demo_*`
- Temporary per-column statistics targets

The scripts may also change session settings such as:

- `work_mem`
- `enable_seqscan`
- `enable_hashjoin`
- `enable_mergejoin`
- `enable_nestloop`
- `max_parallel_workers_per_gather`

These settings are session-scoped. Most scripts reset them after the relevant demonstration. Closing the VS Code database session also clears any remaining session settings.

The lab does not intentionally modify AdventureWorks rows or original indexes. The write tests in `08_index_tradeoffs.sql` use `BEGIN` and `ROLLBACK`.

## 7. Clean Up

Always run `plans/99_cleanup.sql` after completing the lab, even if an earlier script stopped with an error.

From the VS Code Explorer:

1. Open `plans/99_cleanup.sql`.
2. Confirm the correct PostgreSQL connection and AdventureWorks database.
3. Execute the entire file.
4. Confirm that the verification result reports `0` for all three checks.

Cleanup removes only:

- Indexes named `ix_demo_*`
- Extended statistics named `stx_demo_*`
- Statistics targets changed by the row-estimates lab

It does not remove AdventureWorks data, original indexes, primary keys, foreign keys, unique constraints, or server-level settings.

You can verify cleanup independently:

```sql
SELECT count(*) AS indexes_remaining
FROM pg_indexes
WHERE indexname LIKE 'ix\_demo\_%';

SELECT count(*) AS statistics_remaining
FROM pg_stats_ext
WHERE statistics_name LIKE 'stx\_demo\_%';

SELECT count(*) AS non_default_statistics_targets
FROM pg_attribute a
JOIN pg_class c ON c.oid = a.attrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname IN ('sales', 'person', 'production')
  AND a.attstattarget >= 0;
```

Each count should be `0`.

## Troubleshooting

| Problem | Action |
| --- | --- |
| Query runs against the wrong database | Stop and select the AdventureWorks database in the VS Code connection selector |
| `relation does not exist` | Run `00_discovery.sql` and confirm that your AdventureWorks port uses the expected schema and table names |
| Permission denied | Confirm that your account can create indexes and statistics and can run `ANALYZE`, `VACUUM`, and `ALTER TABLE` |
| An expected Index Scan does not appear | Check whether the table is small, the filter is not selective, or a similar index already existed before the lab |
| A Sequential Scan remains after creating an index | Compare estimated rows and costs; the planner may correctly prefer the sequential scan |
| Actual and estimated rows differ greatly | Check statistics freshness, column statistics targets, correlated columns, and expression predicates |
| Sort reports `Disk` or buffers report `temp read/written` | The operation spilled; inspect the script's `work_mem` comparison |
| Index Only Scan has heap fetches | Run the script's `VACUUM (ANALYZE)` step and inspect the visibility-map explanation |
| A script stops partway through | Run `99_cleanup.sql`, reconnect if necessary, then restart with `00_discovery.sql` |
| VS Code underlines valid PostgreSQL syntax | Confirm that the editor and language mode are configured for PostgreSQL rather than SQL Server |

## Key Principle

> Read the plan bottom up. Find where estimates diverge from reality, change one thing, and measure again.
