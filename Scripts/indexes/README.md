# Indexes & Statistics Demos — AdventureWorks on PostgreSQL

## The scripts

### Indexes

| # | File | Covers |
|---|---|---|
| 00 | `00_index_inventory.sql` | Read-only audit: sizes, **never-used**, **redundant**, stats health |
| 01 | `01_btree_and_column_order.sql` | Leading-column rule, column order, ASC/DESC, **NULLs are indexed** |
| 02 | `02_index_types.sql` | **BRIN size demo**, Hash, GIN+trigram, full-text, jsonb |
| 03 | `03_special_indexes.sql` | **Partial**, expression, covering (`INCLUDE`), **partial-unique** |
| 04 | `04_maintenance_and_bloat.sql` | **WAL write cost measured**, HOT updates, bloat, `REINDEX CONCURRENTLY` |
| 05 | `05_antipatterns.sql` | Eight ways an index silently does nothing |

### Statistics

| # | File | Covers |
|---|---|---|
| 06 | `06_statistics_anatomy.sql` | `pg_stats` field by field; **recompute the estimate by hand** |
| 07 | `07_statistics_targets.sql` | Resolution; **fix an estimate with no index and no SQL change** |
| 08 | `08_extended_statistics.sql` | `CREATE STATISTICS` — dependencies, ndistinct, mcv, expressions |
| 09 | `09_stats_lifecycle.sql` | Autoanalyze thresholds, **the bulk-load trap**, per-table tuning |
| 10 | `10_full_scenario.sql` | **Finale** — one query, six rounds, stats before indexes |
| 99 | `99_cleanup.sql` | Drops every `ix_lab_*` / `stx_lab_*` / the `idx_lab` schema |

---

## Oracle → PostgreSQL reference

| Oracle | PostgreSQL |
|---|---|
| `USER_INDEXES` / `DBA_INDEXES` | `pg_indexes`, `pg_index` |
| `V$OBJECT_USAGE` (index monitoring) | `pg_stat_user_indexes.idx_scan` |
| `DBA_TAB_COL_STATISTICS` | `pg_stats` |
| `NUM_DISTINCT` | `n_distinct` (negative = ratio — scales with the table) |
| frequency histogram | `most_common_vals` / `most_common_freqs` |
| height-balanced histogram | `histogram_bounds` |
| `CLUSTERING_FACTOR` | `correlation` (inverted sense) |
| `DBMS_STATS.GATHER_TABLE_STATS` | `ANALYZE` |
| `METHOD_OPT … SIZE 254` | `ALTER TABLE … SET STATISTICS 500` |
| extended stats / column groups | `CREATE STATISTICS` |
| function-based index | expression index — `CREATE INDEX ON t ((expr))` |
| bitmap index | *(none persistent)* — Bitmap Heap Scan is built on the fly |
| `ONLINE` index rebuild | `REINDEX INDEX CONCURRENTLY` |
| automatic stats job | autoanalyze (part of autovacuum) |
| `STALE_PERCENT` (10%) | `autovacuum_analyze_scale_factor` (0.1) |
| `DBMS_STATS.LOCK_TABLE_STATS` | **no equivalent** — see 09 Part F |

---

