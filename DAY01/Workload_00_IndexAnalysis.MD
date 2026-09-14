# Index Analysis and Monitoring

## Extensions to Enable

**No extension is required for the core index monitoring sections.** PostgreSQL provides `pg_stat_user_indexes`, `pg_statio_user_indexes`, `pg_stat_user_tables`, `pg_index`, `pg_class`, and index-progress views as part of the server.

Enable these extensions when the additional capabilities are needed:

| Extension | Requirement | Purpose |
| --- | --- | --- |
| `pg_stat_statements` | Recommended | Correlates expensive normalized SQL with index opportunities and records index maintenance statements. It must also be added to `shared_preload_libraries`. |
| `pgstattuple` | Optional | Measures tuple/page density, dead items, and B-tree leaf fragmentation for a selected table or index. |
| `pg_buffercache` | Optional | Shows which table and index blocks currently reside in shared buffers. This is an instantaneous cache sample. |
| `hypopg` | Optional | Creates session-local hypothetical indexes for `EXPLAIN` testing without building physical indexes. Availability depends on the PostgreSQL service and installed packages. |

Install available extensions in each database where they will be used:

```sql
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS pgstattuple;
CREATE EXTENSION IF NOT EXISTS pg_buffercache;
CREATE EXTENSION IF NOT EXISTS hypopg;
```

Do not execute the entire block blindly. Check extension availability and organizational policy first:

```sql
SELECT name,
       default_version,
       installed_version
FROM pg_available_extensions
WHERE name IN ('pg_stat_statements', 'pgstattuple', 'pg_buffercache', 'hypopg')
ORDER BY name;
```

On Azure Database for PostgreSQL, an extension may need to be allow-listed before `CREATE EXTENSION` succeeds. Configure `shared_preload_libraries = 'pg_stat_statements'` through Azure Server parameters and restart when required. Managed-service support for `hypopg` varies by service version and configuration.

## Purpose

Use `DBA_IndexAnalysis.sql` to review index inventory, usage, physical reads, potentially unused indexes, invalid indexes, duplicate definitions, foreign keys without matching indexes, write-maintenance cost, and active index builds.

The script is read-only. It does not create, drop, rebuild, or alter indexes. The foreign-key section generates proposed `CREATE INDEX` commands as text for review only.

## Run the Script

Open `DBA_IndexAnalysis.sql` in pgAdmin Query Tool, connect to the database being analyzed, and execute the whole file or individual numbered sections.

The script intentionally contains no `psql` backslash commands, so it is compatible with pgAdmin.

Run it separately in every database that requires analysis. For full cross-user statistics visibility, use a role with `pg_monitor`, `pg_read_all_stats`, or equivalent privileges.

## Recommended Workflow

1. Run Sections 1 and 2 to confirm the database, statistics age, extensions, index definitions, validity, and sizes.
2. Run Sections 3 through 6 after a representative workload to analyze use, non-use, cache behavior, and table scan balance.
3. Run Sections 7 and 8 to find invalid and exact duplicate index definitions.
4. Run Section 9 to identify foreign keys without a matching leading-column index.
5. Run Section 10 to compare index count and size with table write activity.
6. Run Section 11 while `CREATE INDEX` or `REINDEX` is active to monitor progress.
7. Use Section 12 and the optional extension examples for deeper investigation.

## Statistics Collection Period

Index counters are cumulative since the statistics reset shown in Section 1. An index with zero scans is only unused during the observed period.

Before changing an index, ensure the interval includes:

- Normal daily traffic
- Month-end, quarter-end, and year-end processing
- Reporting and maintenance jobs
- Failover or replica workloads when applicable
- Rare administrative and emergency queries

Resetting statistics can disrupt other monitoring. When resets are not acceptable, capture the output before and after a controlled workload and compare the counters.

## Section Guide

### Section 1: Environment

Confirms the database, PostgreSQL version, monitoring privileges, statistics reset time, and availability of optional extensions.

An old `stats_reset` means the values cover a long interval. A recent reset means zero or low counters are not yet strong evidence.

### Section 2: Index inventory

Lists every user index with:

- Table and index name
- Physical size
- Primary and unique flags
- Valid, ready, and live status
- Constraint ownership
- Scan and tuple counters
- Complete index definition

Use this section as the ownership and definition check before acting on findings from later sections.

#### Inventory column reference

| Column | Possible values | Definition and interpretation |
| --- | --- | --- |
| `is_ready` | `true`, `false` | Comes from `pg_index.indisready`. `true` means the index is ready to receive entries from `INSERT` and `UPDATE` operations. `false` means PostgreSQL is not maintaining it for new changes, commonly during certain phases of concurrent index creation or after a failed operation. Investigate a persistent `false` value before using or removing the index. |
| `is_live` | `true`, `false` | Comes from `pg_index.indislive`. `true` means the index is considered live. `false` means it is being dropped and PostgreSQL ignores it for normal purposes. A persistent `false` value outside active DDL deserves investigation. |
| `constraint_type` | `p`, `u`, `x`, or `NULL` in this join | Comes from `pg_constraint.contype`. `p` means primary key, `u` means unique constraint, and `x` means exclusion constraint. `NULL` means this query found no constraint whose `conindid` points to the index; it does not mean the index is unused. Foreign-key constraints do not identify a supporting index through `conindid`. |
| `idx_scan` | Integer from `0` upward, or `NULL` | Number of index scans initiated since statistics were reset. `0` means no scan was recorded during that interval, not that the index has never been useful. `NULL` means no matching row was available from `pg_stat_user_indexes`, which can occur for objects without per-index statistics such as partitioned parent indexes. |
| `idx_tup_read` | Integer from `0` upward, or `NULL` | Number of index entries returned by scans on this index since reset. It can be much larger than `idx_scan` when each scan examines many entries. It includes entries read by ordinary, bitmap, and index-only scans and can include entries that are later found not to be visible. |
| `idx_tup_fetch` | Integer from `0` upward, or `NULL` | Number of live table rows fetched by simple index scans using this index since reset. It does not include heap rows fetched by bitmap scans, because those are attributed at table level. Index-only scans can increase `idx_tup_read` without increasing this counter when no heap fetch is needed. |

These counters are cumulative and are not exact per-query measurements. Check the Section 1 `stats_reset` timestamp and observe a representative workload period before interpreting low or zero values.

The following combinations are common:

- High `idx_scan` with low `idx_tup_read` per scan often indicates selective lookups.
- Low `idx_scan` with high `idx_tup_read` can indicate occasional broad index scans.
- High `idx_tup_read` with low `idx_tup_fetch` can result from index-only scans, bitmap scans, or entries rejected after visibility checks.
- `is_ready = false`, `is_live = false`, or `is_valid = false` outside active index DDL should be investigated using server logs and `pg_stat_progress_create_index`.
- A non-`NULL` `constraint_type` means the index supports a primary, unique, or exclusion constraint; do not drop it based only on usage counters.

### Section 3: Usage ranking

Key columns:

- `idx_scan`: number of index scans initiated.
- `idx_tup_read`: index entries returned by scans.
- `idx_tup_fetch`: live heap rows fetched by simple index scans.
- `tuples_read_per_scan`: average index entries examined per scan.
- `heap_tuples_fetched_per_scan`: average heap rows fetched per scan.

High use does not prove an index is optimal. A frequently used index can still perform broad scans or duplicate another index.

Index-only scans can increase `idx_tup_read` without a matching increase in `idx_tup_fetch`, so the two counters should not be expected to match.

### Section 4: Potentially unused indexes

This section reports indexes with `idx_scan = 0` while excluding:

- Primary keys
- Unique indexes
- Constraint-backed indexes
- Invalid or incomplete indexes

A returned row is a review candidate, not a drop recommendation. An unused index still adds storage, WAL, cache, vacuum, insert, update, and delete overhead, but it may support rare or replica-only queries.

### Section 5: Cache and reads

`idx_blks_read` counts index blocks read from storage and `idx_blks_hit` counts blocks found in PostgreSQL shared buffers.

A low hit percentage can reflect a cold cache, one-time scan, oversized working set, or storage pressure. It is not independently proof of a bad index.

### Section 6: Table scan balance

This compares sequential and index scans by table. Large `seq_tup_read` values identify tables that deserve query-plan review, but sequential scans are often correct for small tables or queries reading a large fraction of rows.

Use `EXPLAIN (ANALYZE, BUFFERS, WAL, SETTINGS, SUMMARY)` with representative parameters before proposing an index.

### Section 7: Invalid indexes

Invalid or not-ready indexes can remain after failed concurrent index operations. Investigate server logs and active sessions before deciding whether to rebuild or remove one.

Typical repair patterns include:

```sql
REINDEX INDEX CONCURRENTLY schema.index_name;
```

or dropping and recreating the index. Validate PostgreSQL version, available disk space, locking behavior, uniqueness failures, and production change procedures first.

### Section 8: Exact duplicate definitions

This compares access method, keys, included columns, collation, operator classes, sort options, uniqueness, predicates, and expressions.

Even exact duplicates require an ownership check. One may support a constraint or deployment dependency. Review both definitions and `pg_constraint` before removing anything.

This section does not flag every overlapping index. For example, `(customer_id)` can overlap with `(customer_id, order_date)` for some queries, but workload and ordering requirements determine whether both are necessary.

### Section 9: Foreign keys without supporting indexes

PostgreSQL does not automatically create an index on the referencing side of a foreign key. A matching index can improve:

- Parent-row `DELETE` and key `UPDATE` checks
- Joins from child to parent
- Queries filtering on the foreign-key columns

The script generates a proposed command but does not execute it. A small or rarely modified table may not need that index. Test the query workload and write overhead first.

### Section 10: Write-maintenance cost

Tables with many indexes and heavy insert, update, or delete activity can spend significant resources maintaining indexes.

Review:

- Index count and total index size
- Insert, update, and delete totals
- HOT update percentage
- Dead tuples

HOT updates can avoid new index entries when indexed columns are unchanged and page space is available. Adding indexes to frequently modified columns can reduce HOT update opportunities.

### Section 11: Index build progress

Run this section while `CREATE INDEX`, `CREATE INDEX CONCURRENTLY`, or `REINDEX` is active. It reports phase, processed blocks or tuples, lock progress, wait events, and elapsed time.

Progress percentages can be `NULL` when PostgreSQL does not know the total for the current phase.

### Section 12: Captured maintenance statements

When `pg_stat_statements` is installed, this section returns a standard result grid containing expensive index DDL, reindexing, and vacuum statements. Run Section 12 only when Section 1 reports `pg_stat_statements_installed = true`; otherwise PostgreSQL reports that the `pg_stat_statements` relation does not exist.

`pg_stat_statements` does not record which indexes a `SELECT` used. Determine that with `EXPLAIN` and correlate the normalized query with representative parameter values.

## Optional Extension Analysis

### `pgstattuple`

The SQL script contains examples for the primary B-tree indexes on `sales.salesorderheader`, `sales.salesorderdetail`, and `production.product`. Each example finds the actual index name from the catalog and passes its OID to `pgstatindex(...)`, so it does not assume a particular index naming convention.

`pgstatindex(...)` returns one row with these measurements:

| Column | Meaning |
| --- | --- |
| `version` | Internal B-tree metapage version. This describes the on-disk format, not the PostgreSQL server version. |
| `tree_level` | B-tree height above the leaf level. `0` means the root is also a leaf; larger values indicate additional internal levels. |
| `index_size` | Total index size in bytes at the time of inspection. Use `pg_size_pretty(index_size)` when a human-readable value is needed. |
| `root_block_no` | Block number of the B-tree root page. This is diagnostic metadata rather than a tuning target. |
| `internal_pages` | Number of non-leaf pages used to navigate the B-tree. |
| `leaf_pages` | Number of leaf pages containing index entries. Most of a mature B-tree normally resides here. |
| `empty_pages` | Number of pages currently containing no index entries. A few are not automatically a problem. |
| `deleted_pages` | Number of deleted pages waiting to be recycled. Persistent growth can justify trend analysis, but one sample is not proof that a rebuild is needed. |
| `avg_leaf_density` | Average percentage of usable leaf-page space occupied by entries. Interpret it with `fillfactor`, write patterns, index age, and growth direction. |
| `leaf_fragmentation` | Percentage of leaf pages that are not in logical key order relative to physical page order. Higher values can matter for range scans, but do not justify reindexing without workload evidence. |

The examples also return `table_name` and `index_name` to identify the inspected object. Review density, deleted or empty pages, fragmentation, index growth, and query behavior together. `pgstatindex(...)` reads the index and can be expensive on large objects, so use targeted analysis and an appropriate maintenance window.

#### Ranked fragmentation report

The SQL script also includes a report that runs `pgstatindex(...)` against valid, ready, physical B-tree indexes in the standard AdventureWorks schemas and ranks them by `leaf_fragmentation` and size. Partitioned parent indexes are excluded because they have no physical index storage of their own. Important output columns are:

| Column | Interpretation |
| --- | --- |
| `avg_leaf_density_pct` | Average occupied percentage of usable leaf-page space. Low density may indicate page splits, deletes, an intentional low `fillfactor`, or room reserved for future inserts. |
| `leaf_fragmentation_pct` | Percentage of leaf pages whose physical order differs from logical key order. This is the closest `pgstatindex` measure to SQL Server logical fragmentation for a B-tree, but the implementations and maintenance models are not identical. |
| `empty_pages` | Empty pages that remain allocated to the index. |
| `deleted_pages` | Deleted B-tree pages available for later recycling. They are not necessarily wasted permanently. |
| `index_size` | Current total size, used to distinguish tiny indexes from large indexes where fragmentation could have measurable impact. |

Do not apply SQL Server percentage thresholds mechanically. PostgreSQL normally reuses free index space, and routine `VACUUM` removes dead index entries but does not compact the index into physical key order. Consider `REINDEX INDEX CONCURRENTLY` only when a large index has sustained poor density or fragmentation and measured query or storage impact. Also compare index growth, range-scan workload, write rate, available disk space, lock behavior, and maintenance duration.

The ranked report scans every qualifying B-tree index. On a large database, add schema, table, or index predicates and run it outside peak workload periods.

### Index creation and maintenance dates

Unlike SQL Server, PostgreSQL does not record these timestamps in `pg_class`, `pg_index`, or the statistics views:

- Index creation date
- Last index reorganization date
- Last `REINDEX` or rebuild date

PostgreSQL also has no direct equivalent to SQL Server `ALTER INDEX ... REORGANIZE`. `VACUUM` cleans dead entries and makes space reusable; `REINDEX` builds a replacement index structure. Neither operation stores a last-maintenance timestamp in the system catalog.

For authoritative dates, capture DDL prospectively using deployment records, PostgreSQL server logs with DDL logging, Azure PostgreSQL diagnostic logs, or an approved event-trigger audit table. `pg_stat_statements` can show that `CREATE INDEX` or `REINDEX` ran and how much cumulative execution time it used, but it does not retain the last execution timestamp. The SQL script intentionally does not query server filesystem metadata because Azure Database for PostgreSQL restricts that access.

### `pg_buffercache`

Use the commented example at the bottom of the SQL script to summarize current index blocks in shared buffers.

- `cached_buffers` is the number of shared-buffer slots currently containing blocks from the index. It is a current cache-residency count, not a cumulative hit counter.
- `cached_size` multiplies `cached_buffers` by the server's `block_size` and formats the result with `pg_size_pretty`. With the usual 8 KiB block size, 1,000 cached buffers represent about 7.8 MiB.

These columns cover PostgreSQL shared buffers only; they do not include operating-system or storage caches. Cache residency is transient. A low cached size does not mean an index is unused, and reading the cache view does not provide historical residency.

### `hypopg`

HypoPG tests whether the PostgreSQL planner might choose a proposed index without paying the time, storage, locking, WAL, or write-maintenance cost of building it. It creates only planner metadata in the current session; it does not create a physical index and cannot make a query execute faster.

The SQL script contains AdventureWorks examples for these workload patterns:

- Customer orders filtered by `customerid` and sorted by `orderdate`
- Salesperson orders filtered by `salespersonid` and sorted by `orderdate`
- Products filtered by `productline` and `daystomanufacture`, then sorted by `name`

Use `EXPLAIN` before creating a hypothetical index to capture the baseline plan. Create the hypothetical index, then run the same `EXPLAIN` again and compare scan type, sort operations, row estimates, and estimated cost. A plan referencing an index with a generated name such as `<13504>btree_sales_salesorderheader_customerid_orderdate` is using a HypoPG index.

For example:

```sql
EXPLAIN
SELECT customerid, orderdate, subtotal, totaldue
FROM sales.salesorderheader
WHERE customerid = 11000
ORDER BY orderdate;

SELECT *
FROM hypopg_create_index(
    'CREATE INDEX ON sales.salesorderheader (customerid, orderdate)'
);

EXPLAIN
SELECT *
FROM sales.salesorderheader
WHERE customerid = 11000
ORDER BY orderdate;

SELECT hypopg_reset();
```

`EXPLAIN SELECT ...` plans the statement without executing it. This is the correct first test for a hypothetical index because HypoPG can influence planning but supplies no physical index data. Do not use `EXPLAIN ANALYZE` to prove HypoPG runtime improvement: `ANALYZE` executes the query, while the hypothetical index itself cannot service execution.

`hypopg_list_indexes` is a view, not a function. Use `SELECT * FROM hypopg_list_indexes;` to review the hypothetical indexes active in the current session. Adding parentheses produces `function hypopg_list_indexes() does not exist`.

`SELECT hypopg_reset();` removes all hypothetical indexes in the current session. The function returns `void`, so successful completion without an error confirms the reset. Run it after testing to restore normal planner behavior. Hypothetical indexes also disappear automatically when the session ends.

A lower estimated cost or selection of the hypothetical index is evidence for controlled testing, not proof that the physical index should be created. Validate with a real index in a non-production environment and measure execution time, buffers, WAL, storage, and write overhead.

## Safe Decision Process

Before creating an index:

1. Identify expensive or frequent queries.
2. Capture the actual execution plan with representative parameters.
3. Check existing indexes for compatible leading columns, included columns, predicates, and ordering.
4. Estimate index size and write overhead.
5. Test with `hypopg` when available.
6. Build and benchmark in a controlled environment.

Before dropping an index:

1. Observe a representative statistics period.
2. Confirm it is not primary, unique, exclusion, or constraint-backed.
3. Check replicas and infrequent workloads.
4. Check for exact and partial overlap with other indexes.
5. Prepare the original `CREATE INDEX` definition and rollback plan.
6. Monitor query latency and plans after the change.

Never automate index creation or removal solely from one statistics snapshot. Index value depends on the complete read and write workload, not only scan count.
