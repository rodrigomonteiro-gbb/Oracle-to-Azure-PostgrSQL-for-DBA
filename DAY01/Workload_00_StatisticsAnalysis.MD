# Statistics Analysis and Monitoring

## Purpose

Use `DBA_StatisticsAnalysis.sql` to review the planner statistics PostgreSQL uses to estimate row counts and choose execution plans. The script covers:

- Table statistics freshness and autoanalyze thresholds
- Column statistics targets and collected distributions
- Statistics for columns used as index keys
- Multicolumn extended statistics
- Partitioned-table statistics
- Active `ANALYZE` operations
- Tables whose scan and modification activity deserve plan review
- `ANALYZE` and statistics maintenance captured by `pg_stat_statements`

The script is read-only. Proposed `ANALYZE` commands are returned as text. The optional examples that alter statistics targets or create extended statistics are commented out and must be run separately.

## Statistics Versus Indexes

PostgreSQL does not maintain a separate SQL Server-style statistics object automatically for each index. The planner normally uses statistics collected from table columns, expressions, and optional extended-statistics objects when deciding whether an index is useful.

These are different data families:

| Data | Primary source | Purpose |
| --- | --- | --- |
| Table and column planner statistics | `pg_class`, `pg_stats`, `pg_statistic` | Estimate rows, selectivity, joins, grouping, and sort cost. |
| Extended planner statistics | `pg_statistic_ext`, `pg_stats_ext` | Model relationships between multiple columns or expressions. |
| Index usage statistics | `pg_stat_user_indexes` | Count index scans and entries or heap tuples read. |
| Index I/O statistics | `pg_statio_user_indexes` | Count index block reads and shared-buffer hits. |
| Index physical condition | `pgstatindex(...)` from `pgstattuple` | Inspect B-tree density, pages, and fragmentation. |

Use `DBA_StatisticsAnalysis.sql` for planner statistics and `DBA_IndexAnalysis.sql` for index inventory, usage, I/O, duplication, and physical condition.

## Requirements

No extension is required for Sections 1 through 11. Section 12 requires `pg_stat_statements` in the database and configured in `shared_preload_libraries`.

Run the script separately in each database. For the most complete monitoring visibility, use a role with `pg_monitor`, `pg_read_all_stats`, or equivalent privileges.

The AdventureWorks examples expect the lower-case PostgreSQL schemas and objects used by this repository, such as `sales.salesorderheader`.

## Run the Script

Open `DBA_StatisticsAnalysis.sql` in pgAdmin Query Tool and execute the whole file or individual numbered sections.

The script contains no `psql` backslash commands and is compatible with pgAdmin. Run Section 12 separately only when Section 1 reports `pg_stat_statements_installed = true` and the extension view is visible to the current role.

## Recommended Workflow

1. Run Sections 1 through 3 to establish settings, freshness, and immediate analysis candidates.
2. Run the selected table command as Section 3A, then use Section 3B only when a target change, vacuum, database-wide refresh, or extended-statistics object is justified.
3. Use Sections 4 and 5 to inspect statistics targets and column distributions.
4. Use Section 6 when investigating estimates for predicates or joins involving indexed columns.
5. Use Sections 7 and 8 for correlated columns and multicolumn predicates.
6. Use Section 9 for partitioned tables.
7. Use Section 10 while `ANALYZE` is running.
8. Correlate Sections 11 and 12 with `EXPLAIN (ANALYZE, BUFFERS, SETTINGS, SUMMARY)` for problematic queries.

## Section Guide

### Section 1: Environment

Reports the database, server version, monitoring privileges, statistics reset time, and settings that control statistics collection.

| Column | Interpretation |
| --- | --- |
| `track_counts` | Must normally be `on` for autovacuum and table statistics counters to work correctly. |
| `default_statistics_target` | Default amount of detail collected for columns without an override. PostgreSQL defaults to `100`. |
| `autovacuum_analyze_threshold` | Minimum changed-row component of the autoanalyze trigger. |
| `autovacuum_analyze_scale_factor` | Fraction of the estimated table rows added to the trigger. |
| `stats_reset` | Start of the current cumulative database-statistics interval. It is not the age of the column-distribution data. |

The approximate autoanalyze trigger is:

$$
\text{threshold} + \text{scale factor} \times \text{estimated live rows}
$$

PostgreSQL uses internal estimates, so report calculations based on `n_live_tup` are approximations.

### Section 2: Table freshness

Ranks tables by progress toward their effective autoanalyze threshold. Per-table storage parameters override server defaults.

| Column | Interpretation |
| --- | --- |
| `n_live_tup` | Estimated current live rows. This is not an exact `COUNT(*)`. |
| `planner_row_estimate` | `pg_class.reltuples`, updated by `VACUUM`, `ANALYZE`, and selected DDL operations. |
| `n_mod_since_analyze` | Estimated inserts, updates, and deletes since the last analysis. |
| `estimated_autoanalyze_trigger` | Approximate number of modifications needed to trigger autoanalyze. |
| `estimated_analyze_threshold_exceeded` | Whether the current estimates meet the calculated effective threshold. |
| `trigger_progress_pct` | Approximate progress toward that threshold. Values can exceed 100% while autoanalyze is waiting or unable to run. |
| `last_analyze` | Last manual `ANALYZE` time recorded in the current statistics state. |
| `last_autoanalyze` | Last autovacuum-worker analysis time recorded in the current statistics state. |

A threshold crossing does not prove that plans are poor. It means enough data changed that recollecting distributions is appropriate.

### Section 3: Missing or stale candidates

Returns tables that meet at least one review condition:

- No manual or automatic analysis timestamp is recorded
- The estimated effective autoanalyze threshold is reached
- At least 100,000 modifications are recorded since analysis

`proposed_analyze_command` is reviewable text and is not executed. A missing timestamp means no analysis has been recorded since statistics reset or startup; it does not prove the table has never been analyzed during its lifetime.

### Sections 3A and 3B: Refresh or create statistics

Run the selected `proposed_analyze_command` as Section 3A. When it returns `ANALYZE`, ordinary table and column planner statistics have already been refreshed. The verbose output describes the sampling work; it is not a recommendation to run another statistics update.

The reported live and dead rows require separate interpretation:

- `ANALYZE` samples rows and updates planner statistics but does not remove dead tuples.
- `VACUUM (VERBOSE, ANALYZE)` removes or marks dead-tuple space reusable and also refreshes planner statistics.
- A high dead-row count alone does not prove planner statistics are stale.

Section 3B contains commented commands for these maintenance choices:

| Goal | Command pattern |
| --- | --- |
| Refresh one table | `ANALYZE VERBOSE schema.table;` |
| Refresh selected columns | `ANALYZE VERBOSE schema.table (column1, column2);` |
| Vacuum and refresh | `VACUUM (VERBOSE, ANALYZE) schema.table;` |
| Refresh the current database | `ANALYZE VERBOSE;` |
| Collect more detail for one column | `ALTER TABLE ... ALTER COLUMN ... SET STATISTICS target;`, then `ANALYZE` |
| Restore the default target | `ALTER TABLE ... ALTER COLUMN ... SET STATISTICS -1;`, then `ANALYZE` |
| Model related columns | `CREATE STATISTICS ...`, then table-level `ANALYZE` |

PostgreSQL automatically creates ordinary statistics data for eligible table columns when `ANALYZE` runs. Unlike SQL Server, it does not use a separate `CREATE STATISTICS` object for one ordinary column. PostgreSQL `CREATE STATISTICS` defines extended statistics for relationships among columns or expressions; the object remains empty until the table is analyzed.

### Section 4: Column targets

Lists every user column and its configured and effective statistics target.

| Configured value | Meaning |
| --- | --- |
| `-1` | Use `default_statistics_target`. |
| `0` | Do not collect planner statistics for the column. Use with care. |
| Positive integer | Explicit per-column target. Higher values can capture more detail. |

`has_pg_stats_row = false` can mean the table or column has not been analyzed, the target is zero, the relation is a partitioned parent without collected inherited statistics, or the current role cannot see the row.

Increasing a target can improve estimates for skewed data, large distinct sets, and uneven distributions. It also increases `ANALYZE` work, catalog storage, and planning overhead. Change targets only for columns tied to demonstrated estimation problems.

### Section 5: Column distributions

`pg_stats` is a readable view over the internal `pg_statistic` catalog. Its key columns are:

| Column | Meaning |
| --- | --- |
| `null_frac` | Estimated fraction of rows containing `NULL`. |
| `avg_width` | Average stored width in bytes. |
| `n_distinct` | Positive values estimate an absolute count. Negative values represent a fraction of table rows, such as `-1` for nearly unique values. |
| `estimated_distinct_values` | Report conversion of positive or proportional `n_distinct` into an approximate count. |
| `correlation` | Statistical correlation between physical row order and the column's logical order, from `-1` to `1`. Values near either extreme can make ordered index access cheaper. |
| `most_common_value_count` | Number of values represented in the most-common-values list. |
| `histogram_boundary_count` | Number of boundaries in the histogram describing values outside the most-common-values list. |

To inspect the full arrays for one column, use the commented AdventureWorks example at the end of the SQL file. Most-common values and histogram boundaries can contain sensitive application values, and `pg_stats` limits visibility accordingly.

### Section 6: Index-key coverage

Joins each physical index key position to the underlying table-column statistics. This answers whether ordinary columns used by an index have a visible `pg_stats` row and shows their selectivity context.

This section does not mean the statistics belong to the index. They belong to the table columns and are consumed when PostgreSQL costs index, sequential, bitmap, and other access paths.

`<expression>` indicates an expression index key. Expression indexes maintain statistics associated with the index relation internally, but they do not map to an ordinary table-column row in `pg_stats`. Investigate the expression through plans and the index definition.

Included columns are excluded because they do not define index search order or selectivity.

### Section 7: Extended-statistics definitions

Lists objects created with `CREATE STATISTICS`.

| Kind code | SQL keyword | Purpose |
| --- | --- | --- |
| `d` | `ndistinct` | Estimates distinct combinations across columns. Useful for grouping and combined uniqueness. |
| `f` | `dependencies` | Models functional dependencies, where one column helps determine another. |
| `m` | `mcv` | Stores common combinations of values across columns. Useful for correlated predicates. |
| `e` | `expressions` | Indicates statistics collected for expressions included in the object. |

`CREATE STATISTICS` creates the definition but does not populate data. Run `ANALYZE` on the table afterward.

### Section 8: Extended-statistics data

Shows whether definitions have collected multivariate distinct counts, dependencies, or most-common-value combinations. `NULL` data can mean the table has not been analyzed since the object was created or that the requested statistics kind produced no usable data.

Extended statistics help when the independence assumption is inaccurate. For example, `customerid` and `territoryid` may be correlated, so multiplying their independent selectivities can produce a poor row estimate.

Extended statistics improve selectivity estimates. They do not force a particular plan and currently do not replace every type of join-correlation estimate.

### Section 9: Partitioned tables

Reports leaf-partition count, parent row estimate, timestamps, and inherited column-statistics rows.

Autovacuum analyzes individual modified partitions, but it does not automatically analyze a partitioned parent. Run manual `ANALYZE` on the parent after significant partition or data changes so queries planned across partitions have useful parent-level statistics. Continue analyzing individual partitions according to their own activity.

### Section 10: Active ANALYZE

Uses `pg_stat_progress_analyze` to show active manual and automatic analysis work.

| Column | Meaning |
| --- | --- |
| `phase` | Current operation stage. |
| `sample_blks_total` | Number of table blocks selected for sampling. |
| `sample_blks_scanned` | Sample blocks processed so far. |
| `ext_stats_total` | Extended-statistics objects to compute. |
| `ext_stats_computed` | Extended-statistics objects completed. |
| `child_tables_total` | Child relations to process for inherited statistics. |
| `child_tables_done` | Child relations completed. |
| `current_child_table` | Child relation currently being processed. |

Progress percentages can be `NULL` when the total is zero or unavailable for the current phase.

### Section 11: Workload context

Ranks tables by sequential rows read, modifications since analysis, and size. Use it to choose where to compare planner estimates with actual rows.

High sequential-scan activity is not automatically a statistics defect. Sequential scans are often correct for small tables or queries that return a large percentage of rows.

For a representative query, compare `rows=` estimates with `actual rows=` using:

```sql
EXPLAIN (ANALYZE, BUFFERS, SETTINGS, SUMMARY)
SELECT ...;
```

Large estimate errors that persist after `ANALYZE` can indicate skew, correlation, unsuitable targets, parameter sensitivity, expressions, or missing extended statistics.

#### Sections 11A through 11E: Investigation workflow

Section 11 identifies investigation candidates, not automatically defective tables or plans. For each selected row:

##### Section 11A columns

Section 11A returns one row per column with visible `pg_stats` data. The table-level values repeat on each row.

| Column | Meaning | What to look for |
| --- | --- | --- |
| `schemaname` | Schema containing the table. | Confirm that you selected the intended table, especially when identical table names exist in multiple schemas. |
| `table_name` | Table whose statistics are being inspected. | Use the schema-qualified name in maintenance commands. |
| `column_name` | Column represented by the `pg_stats` row. | Concentrate on columns used by problematic filters, joins, grouping, and ordering. A `NULL` value can mean no visible `pg_stats` rows exist for the table. |
| `null_frac` | Estimated fraction of rows containing `NULL`, from `0` to `1`. | A large fraction matters when predicates use `IS NULL`, `IS NOT NULL`, or joins exclude nulls. Confirm its effect through plan estimates rather than treating a high value as a defect. |
| `n_distinct` | Estimated number of distinct non-null values. A positive value is an estimated count; a negative value is the negative fraction of table rows; `-1` means approximately unique. | Check whether the value is plausible for the data and predicate. Poor distinct-value estimates can distort equality, join, and grouping estimates. |
| `correlation` | Correlation between the column's logical ordering and physical row order, from `-1` to `1`. Values near either endpoint indicate strong ordering; values near `0` indicate little physical ordering. | This affects index-scan cost, not statistics freshness. Do not run `ANALYZE` merely because correlation is low. |
| `most_common_value_count` | Number of values retained in the most-common-values list. | For skewed columns, a small list may omit frequently queried values. Inspect the full `most_common_vals` and `most_common_freqs` in Section 5 before raising the target. |
| `histogram_boundary_count` | Number of histogram boundaries retained for values outside the most-common-values list. | A small histogram can produce coarse range estimates. Consider a higher target only when range-predicate estimates are materially wrong after a fresh `ANALYZE`. |
| `n_live_tup` | Estimated live-row count from `pg_stat_user_tables`. | Compare it with the scale implied by the actual plan. It is approximate and does not need to equal `COUNT(*)`. |
| `n_mod_since_analyze` | Estimated inserts, updates, and deletes since the last `ANALYZE`. | Compare it with the effective autoanalyze trigger in Section 2. A threshold crossing supports recollection but does not prove a bad plan. |
| `last_analyze` | Last manual analysis recorded in the current cumulative-statistics state. | A recent value confirms manual collection, but timestamp age alone does not measure distribution change. |
| `last_autoanalyze` | Last autovacuum-worker analysis recorded in the current cumulative-statistics state. | Use the newer of this and `last_analyze`. Both can be `NULL` after a statistics reset even when planner data exists. |

##### When to recollect or enhance statistics

PostgreSQL replaces ordinary column statistics when `ANALYZE` runs; there is no separate statistics rebuild command. Use the smallest response supported by evidence:

| Evidence | Appropriate action |
| --- | --- |
| Section 2 shows the effective autoanalyze threshold has been reached, both analysis timestamps are absent, or substantial data distribution changes occurred | Run `ANALYZE VERBOSE schema.table;`, then rerun the same plan. |
| Dead tuples also require cleanup | Run `VACUUM (VERBOSE, ANALYZE) schema.table;`. Dead tuples alone are not evidence that planner statistics need a special rebuild. |
| Estimates become accurate after ordinary `ANALYZE` | Stop statistics maintenance and evaluate whether the chosen plan is actually expensive. |
| One filter or join column remains badly estimated and its important skew or range detail is absent from `pg_stats` | Raise that column's statistics target, rerun `ANALYZE`, and compare the identical plan. Avoid increasing targets for every column. |
| Estimates are wrong only when two or more columns are used together and those columns are related | Test an extended-statistics object with the appropriate `dependencies`, `ndistinct`, or `mcv` kinds, then run table-level `ANALYZE`. |
| Estimates are accurate but execution remains slow | Statistics are probably not the root cause. Investigate indexes, query formulation, memory, I/O, locking, and result volume. |

The decisive test is a repeatable `EXPLAIN (ANALYZE, BUFFERS, SETTINGS, SUMMARY)` comparison with realistic values. Large differences between estimated and actual rows at important nodes justify statistics investigation; large scan counters, old timestamps, low correlation, or small histograms do not independently prove that recollection will improve a plan.

1. **11A:** Set the target schema and table and inspect freshness plus collected column distributions.
2. **11B:** Use `pg_stat_statements`, when available, to find costly candidate statements referencing the table. Text matching is approximate, so verify each result.
3. **11C:** Run a representative statement with realistic values under `EXPLAIN (ANALYZE, BUFFERS, WAL, SETTINGS, VERBOSE, SUMMARY)` and compare estimated rows with actual rows at important plan nodes.
4. **11D:** Run table-level `ANALYZE VERBOSE`, then capture the same plan again. Use `VACUUM (VERBOSE, ANALYZE)` only when dead-tuple cleanup is also appropriate.
5. **11E:** If a material estimate error remains, test a higher target for the specific skewed column or extended statistics for columns used together. Recollect statistics and compare the identical workload again.

Do not optimize for the absence of sequential scans. They are often the cheapest plan for small tables or queries that return much of a table. If estimates are accurate but runtime remains poor, investigate indexes, query shape, memory, storage I/O, locking, and result volume instead of repeatedly analyzing the table.

### Section 12: Captured maintenance

When `pg_stat_statements` is available, this section returns normalized `ANALYZE` and `VACUUM ... ANALYZE` statements with cumulative calls, rows, and execution time.

`pg_stat_statements` does not retain the last execution timestamp, the resulting statistics distributions, or the table's exact modification state at execution time. Its rows are cumulative and can be evicted or reset.

## AdventureWorks Examples

### Inspect one column

```sql
SELECT *
FROM pg_stats
WHERE schemaname = 'sales'
  AND tablename = 'salesorderheader'
  AND attname = 'customerid';
```

Use this to inspect full most-common-value frequencies and histogram bounds after the summary report identifies a column of interest.

### Increase a column target

```sql
ALTER TABLE sales.salesorderheader
    ALTER COLUMN customerid SET STATISTICS 500;

ANALYZE VERBOSE sales.salesorderheader (customerid);
```

The target affects the next statistics collection, so changing it without running or waiting for `ANALYZE` does not immediately improve planner data.

Restore the database default with:

```sql
ALTER TABLE sales.salesorderheader
    ALTER COLUMN customerid SET STATISTICS -1;
```

### Create extended statistics

```sql
CREATE STATISTICS sales.st_salesorderheader_customer_territory
    (dependencies, ndistinct, mcv)
    ON customerid, territoryid
    FROM sales.salesorderheader;

ANALYZE VERBOSE sales.salesorderheader;
```

Test the same representative predicates before and after collection and compare estimates. Remove the demonstration object with:

```sql
DROP STATISTICS IF EXISTS
    sales.st_salesorderheader_customer_territory;
```

## Safe Decision Process

Before changing a statistics target or creating extended statistics:

1. Capture a representative query and its actual plan.
2. Identify the specific node with a material estimate error.
3. Confirm the relevant table has fresh statistics.
4. Inspect skew, distinctness, null fraction, correlation, and multicolumn relationships.
5. Make one targeted change and run `ANALYZE`.
6. Compare estimates, execution time, buffers, planning time, and plan stability.
7. Measure the additional analysis and planning overhead.

Do not increase `default_statistics_target` globally as the first response to one problematic column. Prefer a focused per-column target or an extended-statistics object supported by measured estimation evidence.
