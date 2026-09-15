# Indexes & Statistics Demos — AdventureWorks on PostgreSQL

Companion set to `plans/`. Same conventions, same audience of Oracle/SQL Server
DBAs, same message:

> **The vocabulary changed. The expertise did not.**
> But PostgreSQL has index types and statistics features Oracle simply doesn't
> have — **BRIN**, **partial indexes**, and `CREATE STATISTICS` — and almost
> nobody on a migrated database is using them.

The through-line of the whole session:

> **Fix what the planner KNOWS before you change how it READS.**
> Statistics are free and reversible. Indexes are a permanent tax on every write.

---

## Run them

```powershell
cd "<folder with the scripts>"
$env:PGPASSWORD = "<admin password>"

.\04_indexes.ps1 -Script list          # all scripts + running order
.\04_indexes.ps1 -Script inventory     # ALWAYS run this first
.\04_indexes.ps1 -Script types -Capture
.\04_indexes.ps1 -Interactive          # live psql, step through with \i
.\04_indexes.ps1 -Script cleanup       # when finished
```

Or straight from psql: `\i indexes/02_index_types.sql`

---

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

## Safety

- Indexes are named `ix_lab_*`, extended statistics `stx_lab_*`, demo tables live
  in schema `idx_lab` — cleanup finds them all by pattern.
- **Namespaces don't collide with `plans/`** (which uses `ix_demo_*`), so both
  sets can coexist and be cleaned independently.
- Every `SET` is session-scoped. Closing psql clears them.
- Writes to AdventureWorks tables are wrapped in `BEGIN; … ROLLBACK;`. All other
  writes go to `idx_lab`.
- Per-column `SET STATISTICS` and per-table autovacuum overrides are reset by
  `99_cleanup.sql`.

Verify nothing is left behind:
```sql
SELECT * FROM pg_indexes WHERE indexname LIKE 'ix\_lab\_%';
SELECT * FROM pg_stats_ext WHERE statistics_name LIKE 'stx\_lab\_%';
```

---

## Before you present

**1. Run `-Script inventory` first.** It tells you which columns are already
indexed — if `orderdate` already has an index, several before/after demos lose
their punch.

**2. Two optional extensions.** `02_index_types.sql` uses `pg_trgm` (trigram
search) and `04_maintenance_and_bloat.sql` mentions `pgstattuple`. On Azure
Flexible Server both must be in `azure.extensions` first:

```powershell
az postgres flexible-server parameter show -g $RG -s $PG --name azure.extensions --query value -o tsv
az postgres flexible-server parameter set -g $RG -s $PG `
  --name azure.extensions --value "<existing>,PG_TRGM,PGSTATTUPLE"
```
No restart needed for these two. **Both scripts detect absence and skip
cleanly** — they will not error out mid-demo.

**3. Table size sets expectations.** `salesorderheader` is ~31k rows, so elapsed
times are small and everything fits in cache. Read **cost, buffers, and index
size** instead of milliseconds, and say so up front:

> "These tables fit in memory, so I'll read cost and buffer counts rather than
> milliseconds. On your 400 GB table the same shapes produce the same decisions —
> the ratios hold, the absolute numbers don't."

The BRIN size comparison in script 02 works regardless of table size, which is
why it's the best single demo in this set.

---

## The five moments that land hardest

**1. BRIN size (02 Part A)** — same column, a fraction of the storage. Then the
honest caveat: it only works when `pg_stats.correlation` is near 1.0. *"On an
append-only 2 TB audit table, a B-tree on the timestamp might be 60 GB. BRIN is
maybe 600 MB and costs almost nothing to maintain."*

**2. Partial-unique for soft deletes (03 Part D)** — email unique among *active*
rows only, so deleted rows can reuse the address. Every soft-delete schema needs
this and most people don't know it exists.

**3. Recomputing the estimate by hand (06 Part C)** — pull the MCV frequency out
of `pg_stats`, multiply by `reltuples`, and show it matches what `EXPLAIN`
printed. *"The planner isn't guessing. It's doing arithmetic on numbers we can
read — and when the plan is wrong, one of these numbers is wrong."*

**4. `CREATE STATISTICS` (08 Part B)** — correlated `orderdate`/`duedate`, bad
estimate, one statement, estimate fixed. **No index. No SQL change.** Oracle
DBAs recognise this instantly as extended stats / column groups and are
surprised PostgreSQL has it.

**5. The bulk-load trap (09 Part B)** — load 200k rows, query immediately,
`reltuples` says 0. *"`pg_restore` does not gather statistics. Neither does
`COPY`, nor most migration tools."* `vacuumdb --analyze-only --jobs=8 --all`
belongs in every migration runbook.

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

**No Oracle equivalent — lead with these:** BRIN · partial indexes ·
`INCLUDE` covering · HOT updates · indexed NULLs.

---

## Talking points

**On `random_page_cost`:** the 4.0 default is a spinning-disk assumption. On
Azure Premium SSD it should be 1.1–2.0. Leaving it at 4.0 systematically biases
the planner *away* from your indexes. Highest-value, lowest-risk change on most
migrated workloads.

**On `VACUUM`:** "In PostgreSQL, row visibility lives in the heap, not the index.
So `VACUUM` isn't just space reclamation — it's what keeps your Index Only Scans
index-only." Watch `Heap Fetches` go to zero after a vacuum in script 03 Part C.

**On indexed NULLs:** Oracle B-trees don't store entirely-NULL keys, so
`WHERE col IS NULL` can't use a single-column index. PostgreSQL B-trees do.
Genuine advantage, and it surprises migrating DBAs (script 01 Part D).

**On write cost (04 Part A):** "An index is a permanent tax on every write, paid
to make certain reads faster. Worth it when you collect. Pure loss when the index
is never used — which is why the unused-index audit matters more than the next
new index."

**On plan stability (09 Part F):** PostgreSQL has no `LOCK_TABLE_STATS` and no
plan baselines in core. Be straight about it — they *will* ask. The philosophy is
"fix the estimate, don't freeze the plan," which is defensible and also means the
operational discipline around `ANALYZE` matters more.

**The close (10):** "Notice the order we worked in. Rounds 2 and 3 cost nothing
but a little `ANALYZE` time and are instantly reversible. Rounds 4, 5 and 6 buy
speed with storage and a permanent tax on every write. So fix what the planner
*knows* before you change how it *reads*. Most teams do it backwards — they add
indexes to compensate for statistics that were never gathered, then pay for those
indexes forever."
