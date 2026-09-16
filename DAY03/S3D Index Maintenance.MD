# PostgreSQL Index Maintenance

## Usage review · bloat · REINDEX · statistics · what VACUUM really does

---

## 0. The headline answers

Four questions new PostgreSQL DBAs always ask, answered before the detail.

| Question | Answer |
|---|---|
| **Does `VACUUM` rebuild indexes?** | ❌ **No.** It removes dead *entries* from index pages and marks the space reusable. The index file never shrinks. |
| **Does `VACUUM` reorganize/defragment indexes?** | ❌ **No.** No page merging, no re-packing, no re-ordering. |
| **Does anything rebuild an index?** | ✅ **`REINDEX`**, **`VACUUM FULL`**, **`CLUSTER`**, and `pg_repack`. Those are the only four. |
| **Is there a "reorganize" like SQL Server's `ALTER INDEX ... REORGANIZE`?** | ❌ **No such operation exists in PostgreSQL.** There is only rebuild. |

**Mental model:**

> A PostgreSQL B-tree page splits when it fills, but **two half-empty sibling pages are never merged back together**. A page that becomes *completely* empty is marked deleted and recycled **for that index only** — never returned to the operating system. So an index's file size is a **high-water mark**: it tracks the worst bloat the index has ever seen, and the only way to reset it is a full rebuild. `VACUUM` keeps the index *correct* and stops it growing further; it does not make it *smaller*.

| Operation | Removes dead index entries | Reclaims space for reuse **inside** the index | Shrinks the file on disk | Lock |
|---|---|---|---|---|
| `VACUUM` | ✅ | ✅ | ❌ | `SHARE UPDATE EXCLUSIVE` (non-blocking) |
| `VACUUM (INDEX_CLEANUP OFF)` | ❌ | ❌ | ❌ | `SHARE UPDATE EXCLUSIVE` |
| `VACUUM FULL` | ✅ | ✅ | ✅ **rebuilds everything** | 🔴 `ACCESS EXCLUSIVE` |
| `CLUSTER` | ✅ | ✅ | ✅ **rebuilds everything** | 🔴 `ACCESS EXCLUSIVE` |
| `REINDEX` | ✅ | ✅ | ✅ (that index) | 🔴 blocks writes |
| `REINDEX CONCURRENTLY` | ✅ | ✅ | ✅ (that index) | 🟢 brief lock only |
| `pg_repack` | ✅ | ✅ | ✅ | 🟢 brief lock only |

---

## 1. Setup — the maintenance lab

```sql
CREATE SCHEMA IF NOT EXISTS maintlab;
SET search_path TO maintlab, public;
\timing on

-- Optional but strongly recommended: real bloat measurement instead of estimates
-- On Azure Flexible Server, add PGSTATTUPLE to the azure.extensions server
-- parameter first, then run this in the database.
CREATE EXTENSION IF NOT EXISTS pgstattuple;
```

```sql
DROP TABLE IF EXISTS maint_demo;

CREATE TABLE maint_demo (
    id          bigserial PRIMARY KEY,
    account_id  int          NOT NULL,
    status      text         NOT NULL,
    amount      numeric(12,2) NOT NULL,
    updated_at  timestamptz  NOT NULL DEFAULT now(),
    payload     text
);

INSERT INTO maint_demo (account_id, status, amount, payload)
SELECT (random() * 50000)::int + 1,
       (ARRAY['NEW','OPEN','CLOSED'])[1 + (g % 3)],
       (random() * 5000)::numeric(12,2),
       repeat('x', 100)
FROM generate_series(1, 2000000) g;

CREATE INDEX ix_maint_account ON maint_demo (account_id);
CREATE INDEX ix_maint_status  ON maint_demo (status);
CREATE INDEX ix_maint_updated ON maint_demo (updated_at);

ANALYZE maint_demo;
```

**Record the clean baseline — every later measurement is compared against it:**

```sql
SELECT indexrelname AS index_name,
       pg_size_pretty(pg_relation_size(indexrelid)) AS size,
       pg_relation_size(indexrelid) AS bytes
FROM pg_stat_user_indexes
WHERE schemaname = 'maintlab'
ORDER BY bytes DESC;
```

---

# PART I — Reviewing index usage

## 2. Is this index being used at all?

### 2.1 The core view: `pg_stat_user_indexes`

```sql
SELECT relname                               AS table_name,
       indexrelname                          AS index_name,
       idx_scan                              AS times_used,
       idx_tup_read                          AS entries_read,
       idx_tup_fetch                         AS rows_fetched,
       pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes
WHERE schemaname = 'maintlab'
ORDER BY idx_scan ASC, pg_relation_size(indexrelid) DESC;
```

| Column | Means |
|---|---|
| **`idx_scan`** | How many times the planner *chose* this index. **The single most important number.** |
| `idx_tup_read` | Index entries returned by those scans |
| `idx_tup_fetch` | Live table rows fetched as a result |

> ⚠️ **`idx_scan` counts scans, not rows.** One scan reading a million entries and one scan reading a single row both increment it by 1. Use it to answer *"is this used?"* — never *"how expensive is this?"*

### 2.2 Find unused indexes — the storage and write-cost audit

```sql
SELECT s.schemaname,
       s.relname                                    AS table_name,
       s.indexrelname                               AS index_name,
       s.idx_scan                                   AS times_used,
       pg_size_pretty(pg_relation_size(s.indexrelid)) AS wasted_space,
       'DROP INDEX CONCURRENTLY ' || quote_ident(s.schemaname)
         || '.' || quote_ident(s.indexrelname) || ';' AS drop_statement
FROM pg_stat_user_indexes s
JOIN pg_index i ON i.indexrelid = s.indexrelid
WHERE s.idx_scan = 0
  AND NOT i.indisunique                       -- never drop a uniqueness guarantee
  AND NOT i.indisprimary
  AND s.indexrelid NOT IN (
        SELECT conindid FROM pg_constraint WHERE conindid <> 0)
ORDER BY pg_relation_size(s.indexrelid) DESC;
```

> ⚠️ **Read this before you drop anything.**
>
> 1. **Check when statistics were last reset.** An index "unused" since a reset 3 hours ago tells you nothing:
>    ```sql
>    SELECT stats_reset FROM pg_stat_database WHERE datname = current_database();
>    ```
>    You need **at least one full business cycle** — including month-end and quarterly reporting.
> 2. **Statistics are per-instance.** A read replica's usage is counted separately. An index unused on the primary may be critical on a replica.
> 3. **Unique indexes enforce correctness**, not just speed. The query above excludes them deliberately.
> 4. **An unused index still costs you** on every `INSERT`/`UPDATE`/`DELETE`, in WAL volume, in vacuum time, and in storage.

**The safe alternative to dropping — make it invisible to the planner first:**

```sql
-- PostgreSQL has no "invisible index" (Oracle 11g+). Simulate it:
BEGIN;
  DROP INDEX ix_maint_status;
  -- run your critical queries here and check the plans
ROLLBACK;   -- index is restored, nothing was lost
```

> **This is the safest index-removal test that exists.** `DROP INDEX` is transactional in PostgreSQL — inside a transaction you can drop, test, and roll back. It does take an `ACCESS EXCLUSIVE` lock for the duration, so do it in a maintenance window, not at peak.

### 2.3 Find redundant and duplicate indexes

```sql
-- Exact duplicates: same columns, same opclass, same predicate
SELECT indrelid::regclass                          AS table_name,
       array_agg(indexrelid::regclass)             AS duplicate_indexes,
       pg_size_pretty(sum(pg_relation_size(indexrelid))) AS total_size
FROM pg_index
GROUP BY indrelid, indkey, indclass, indpred, indisunique
HAVING count(*) > 1;
```

```sql
-- Redundant by prefix: index on (a) is redundant when (a, b) exists
SELECT a.indexrelid::regclass  AS redundant_index,
       b.indexrelid::regclass  AS covered_by,
       pg_size_pretty(pg_relation_size(a.indexrelid)) AS reclaimable
FROM pg_index a
JOIN pg_index b
  ON a.indrelid = b.indrelid
 AND a.indexrelid <> b.indexrelid
 AND a.indnatts < b.indnatts
 AND a.indkey::int2[] = (b.indkey::int2[])[0 : a.indnatts - 1]
 AND a.indpred IS NULL AND b.indpred IS NULL
WHERE NOT a.indisprimary AND NOT a.indisunique
ORDER BY pg_relation_size(a.indexrelid) DESC;
```

> **The leftmost-prefix rule (index guide §4.1) cuts both ways.** If `(a, b)` exists, an index on `(a)` alone adds nothing but write cost — every query `(a)` serves, `(a, b)` serves too.

### 2.4 Cache behavior — is the index actually in memory?

```sql
SELECT s.relname                AS table_name,
       s.indexrelname           AS index_name,
       io.idx_blks_read         AS disk_reads,
       io.idx_blks_hit          AS cache_hits,
       CASE WHEN io.idx_blks_hit + io.idx_blks_read > 0
            THEN round(100.0 * io.idx_blks_hit /
                       (io.idx_blks_hit + io.idx_blks_read), 2)
       END                      AS cache_hit_pct,
       pg_size_pretty(pg_relation_size(s.indexrelid)) AS size
FROM pg_stat_user_indexes s
JOIN pg_statio_user_indexes io USING (indexrelid)
WHERE s.schemaname = 'maintlab'
ORDER BY io.idx_blks_read DESC;
```

> **Below ~95% cache hit on a hot index** means it does not fit in `shared_buffers`, or it is bloated enough that the useful part no longer fits. Bloat and cache pressure are the same problem wearing two hats — a 3× bloated index needs 3× the memory to stay resident.

### 2.5 Find invalid indexes (failed `CONCURRENTLY` builds)

```sql
SELECT indexrelid::regclass AS invalid_index,
       indrelid::regclass   AS on_table,
       pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_index
WHERE NOT indisvalid;
```

> ⚠️ **An invalid index is the worst of both worlds: it is maintained on every write but never used by the planner.** A failed `CREATE INDEX CONCURRENTLY` or `REINDEX CONCURRENTLY` leaves one behind (often named `*_ccnew`). **Drop it and retry** — do not leave it sitting there.

---

# PART II — Index bloat ("fragmentation")

## 3. What "fragmentation" actually means in PostgreSQL

**Terminology first**, because the SQL Server vocabulary does not map cleanly:

| SQL Server term | PostgreSQL reality |
|---|---|
| **Logical fragmentation** (page order ≠ key order) | Exists, but far less relevant — PostgreSQL tracks it as table **`correlation`** (index guide §2.4), not as an index property |
| **Internal fragmentation** (pages partly empty) | **This is "bloat"** — the thing you actually care about |
| `avg_fragmentation_in_percent` | Closest equivalent: **`leaf_fragmentation`** from `pgstatindex` |
| `ALTER INDEX ... REORGANIZE` | ❌ **No equivalent** |
| `ALTER INDEX ... REBUILD` | `REINDEX` |

**Three things cause index bloat:**

1. **`UPDATE`s.** MVCC writes a *new row version*, so every non-HOT update adds a **new index entry** while the old one lingers until vacuumed.
2. **`DELETE`s.** Entries stay until `VACUUM` removes them.
3. **Page splits.** A full page splits into two half-full pages. **They are never merged back.**

> **Point 3 is the one that surprises everyone.** Even with perfect vacuuming, a workload that inserts in random key order leaves a B-tree averaging ~70% page density. Vacuum cannot fix that — only a rebuild can.

## 4. Measuring bloat

### 4.1 Exact measurement with `pgstattuple` (preferred)

```sql
-- Per-index truth. NOTE: this reads the whole index -- do not run it
-- against a 500 GB index during peak hours.
SELECT * FROM pgstatindex('ix_maint_account');
```

| Column | Means | Healthy value |
|---|---|---|
| `version`, `tree_level` | B-tree metadata; `tree_level` is the depth | 2–4 for most indexes |
| `index_size` | Bytes on disk | — |
| `internal_pages` / `leaf_pages` | Structure | leaf ≫ internal |
| **`avg_leaf_density`** | **% of leaf page space actually used** | **> 70%** |
| **`leaf_fragmentation`** | **% of leaf pages out of physical order** | **< 20%** |
| `deleted_pages` | Pages marked dead, awaiting reuse | Low |

```sql
-- Table-level bloat, for context
SELECT * FROM pgstattuple('maint_demo');
-- dead_tuple_percent and free_percent are the numbers to read
```

**A faster, sampling-based variant for very large objects:**

```sql
SELECT * FROM pgstattuple_approx('maint_demo');
```

### 4.2 Bloat *estimation* without `pgstattuple`

Use this when the extension is unavailable, or for a cheap fleet-wide sweep. It reads only statistics — **no table access, instant** — but it is an **estimate**.

```sql
SELECT current_database() AS db,
       nspname            AS schema_name,
       tblname            AS table_name,
       idxname            AS index_name,
       pg_size_pretty(real_size::bigint)  AS index_size,
       pg_size_pretty(GREATEST(bloat_size, 0)::bigint) AS estimated_bloat,
       round(GREATEST(bloat_pct, 0)::numeric, 1)       AS bloat_pct
FROM (
  SELECT nspname, tblname, idxname, real_size,
         real_size - est_size          AS bloat_size,
         100 * (real_size - est_size) / NULLIF(real_size, 0) AS bloat_pct
  FROM (
    SELECT n.nspname, ct.relname AS tblname, ci.relname AS idxname,
           pg_relation_size(ci.oid)::float8 AS real_size,
           (  (reltuples * (6 + 8
              + sum(CASE WHEN s.null_frac > 0 THEN 1 ELSE 0 END)
              + sum((1 - s.null_frac) * COALESCE(s.avg_width, 8))))
              / (8192 * 0.9)
           )::float8 * 8192 AS est_size
    FROM pg_index i
    JOIN pg_class ci      ON ci.oid = i.indexrelid
    JOIN pg_class ct      ON ct.oid = i.indrelid
    JOIN pg_namespace n   ON n.oid = ct.relnamespace
    JOIN LATERAL unnest(i.indkey) WITH ORDINALITY AS k(attnum, ord) ON true
    LEFT JOIN pg_stats s  ON s.schemaname = n.nspname
                         AND s.tablename  = ct.relname
                         AND s.attname    = (SELECT attname FROM pg_attribute
                                             WHERE attrelid = ct.oid AND attnum = k.attnum)
    WHERE n.nspname NOT IN ('pg_catalog','information_schema')
      AND ci.relpages > 100                      -- ignore tiny indexes
    GROUP BY n.nspname, ct.relname, ci.relname, ci.oid, ct.reltuples
  ) raw
) est
WHERE bloat_pct > 20
ORDER BY bloat_size DESC
LIMIT 40;
```

> **Treat the estimate as a triage tool, not a verdict.** It can be off by tens of percent, especially with variable-length columns. Use it to pick candidates, then confirm the shortlist with `pgstatindex`.

### 4.3 Demo — create bloat and watch it happen

```sql
-- Baseline
SELECT pg_size_pretty(pg_relation_size('ix_maint_account')) AS before_size;
SELECT round(avg_leaf_density::numeric, 1) AS before_density,
       round(leaf_fragmentation::numeric, 1) AS before_fragmentation
FROM pgstatindex('ix_maint_account');
```

```sql
-- Churn the indexed column. Every UPDATE writes a NEW index entry
-- and leaves the old one dead. Run this 3-4 times.
UPDATE maint_demo
SET account_id = (random() * 50000)::int + 1
WHERE id % 3 = 0;

VACUUM (ANALYZE) maint_demo;   -- removes dead entries -- but NOT the bloat
```

```sql
-- After
SELECT pg_size_pretty(pg_relation_size('ix_maint_account')) AS after_size;
SELECT round(avg_leaf_density::numeric, 1) AS after_density,
       round(leaf_fragmentation::numeric, 1) AS after_fragmentation,
       deleted_pages
FROM pgstatindex('ix_maint_account');
```

> **The result to draw attention to:** the index is now **larger** and **less dense**, and it stayed that way **even after `VACUUM`**. That is the entire lesson of this document. `VACUUM` reclaimed the space *for reuse inside the index*; it did not give it back.

### 4.4 Does bloat actually hurt? — measure it

> **👁 What to look for in these plans**
>
> Run the same query before and after a `REINDEX` and compare **`Buffers`**, not time.
>
> | In the plan | What bloat does to it |
> |---|---|
> | **`Buffers: shared hit/read`** | **The honest metric.** A bloated index spreads the same entries over more pages, so the tree is deeper and each scan touches more buffers. |
> | **`Index Scan` / `Bitmap Index Scan`** node | The access method does not change — bloat makes the *same plan* slower. There is no plan-shape clue that you have a bloat problem. |
> | **`actual time=`** | Moves too, but is noisy; if the whole index is cached, a 2× bloated index may show almost no time difference while doing twice the work. |
>
> **This is why bloat is insidious:** it never shows up as a bad plan. It shows up as gradually rising buffer counts and memory pressure that nobody attributes to the index.

```sql
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT count(*) FROM maint_demo WHERE account_id BETWEEN 1000 AND 1100;
```

---

# PART III — Rebuilding indexes

## 5. `REINDEX` — the only "rebuild" you have

### 5.1 Syntax and scope

```sql
REINDEX INDEX    ix_maint_account;      -- one index
REINDEX TABLE    maint_demo;            -- every index on one table
REINDEX SCHEMA   maintlab;              -- every index in a schema
REINDEX DATABASE postgres;              -- everything (rarely appropriate)
REINDEX SYSTEM   postgres;              -- catalog indexes only
```

> ⚠️ **Plain `REINDEX` blocks writes.** It takes an `ACCESS EXCLUSIVE` lock on the index and a `SHARE` lock on the table: reads continue, **all writes stop** for the duration. On a large production table that is an outage.

### 5.2 `REINDEX CONCURRENTLY` — the production form (PG 12+)

```sql
REINDEX INDEX CONCURRENTLY ix_maint_account;
REINDEX TABLE CONCURRENTLY maint_demo;
```

**How it works:** builds a complete new index alongside the old one, waits for all transactions that could still see the old one, swaps them atomically, then drops the old index. Only the brief swap requires a strong lock.

| | `REINDEX` | `REINDEX CONCURRENTLY` |
|---|---|---|
| Blocks writes | ✅ Yes, throughout | ❌ Brief lock at swap only |
| Speed | Faster | Slower (two passes) |
| Disk needed | ~1× index size | **~2× index size simultaneously** |
| Can fail leaving debris | ❌ | ✅ leaves an **invalid** `*_ccnew` index |
| Works inside a transaction block | ✅ | ❌ **No** |

> ⚠️ **Three practical constraints on `CONCURRENTLY`:**
> 1. **You need free space for both copies at once.** Check before starting.
> 2. **It cannot run inside a transaction block** — no `BEGIN`/`COMMIT` wrapper, and many deployment tools wrap statements in transactions by default.
> 3. **On failure it leaves an invalid index.** Always re-check §2.5 afterwards and drop any `*_ccnew` leftovers.

### 5.3 Demo — prove `REINDEX` reclaims what `VACUUM` could not

```sql
-- State after the bloat demo in §4.3
SELECT pg_size_pretty(pg_relation_size('ix_maint_account')) AS bloated_size,
       round(avg_leaf_density::numeric, 1)                  AS bloated_density
FROM pgstatindex('ix_maint_account');

REINDEX INDEX CONCURRENTLY ix_maint_account;

SELECT pg_size_pretty(pg_relation_size('ix_maint_account')) AS rebuilt_size,
       round(avg_leaf_density::numeric, 1)                  AS rebuilt_density,
       round(leaf_fragmentation::numeric, 1)                AS rebuilt_fragmentation
FROM pgstatindex('ix_maint_account');
```

**Expected:** size drops back toward the original baseline, `avg_leaf_density` jumps to ~90% (the default B-tree `fillfactor`), and `leaf_fragmentation` collapses toward zero.

Then re-run the §4.4 query and compare `Buffers`. **That delta is the value of the rebuild, in the only unit that is hardware-independent.**

### 5.4 Generate a rebuild script for the worst offenders

```sql
SELECT 'REINDEX INDEX CONCURRENTLY '
         || quote_ident(schemaname) || '.' || quote_ident(indexrelname) || ';'
         AS rebuild_statement,
       pg_size_pretty(pg_relation_size(indexrelid)) AS current_size
FROM pg_stat_user_indexes
WHERE schemaname NOT IN ('pg_catalog','information_schema')
  AND pg_relation_size(indexrelid) > 100 * 1024 * 1024    -- > 100 MB only
ORDER BY pg_relation_size(indexrelid) DESC
LIMIT 20;
```

> **Rebuild selectively.** A `REINDEX DATABASE` on a large system is hours of I/O for indexes that mostly did not need it. **Measure with `pgstatindex`, rebuild the ones above threshold, leave the rest alone.**

### 5.5 `FILLFACTOR` — reduce future bloat at the cost of size

```sql
-- Default for B-tree indexes is 90 (leave 10% free on each leaf page)
-- Lower it for tables with heavy updates to the indexed column
ALTER INDEX ix_maint_account SET (fillfactor = 70);
REINDEX INDEX CONCURRENTLY ix_maint_account;   -- fillfactor applies on rebuild

-- Raise it for append-only / read-mostly data to pack pages tighter
ALTER INDEX ix_maint_updated SET (fillfactor = 100);
REINDEX INDEX CONCURRENTLY ix_maint_updated;
```

| Workload | Suggested `fillfactor` | Why |
|---|---|---|
| Heavy updates to the indexed column | **70–80** | Room for new entries on the existing page → fewer splits |
| Mixed OLTP | **90** *(default)* | Balanced |
| Append-only, monotonic key (timestamps, sequences) | **100** | New entries always go to the right-hand edge; free space is wasted |

> **`fillfactor` only takes effect on a build or rebuild.** Setting it alone changes nothing until you `REINDEX`.

### 5.6 The alternatives to `REINDEX`

| Operation | What it does to indexes | Lock | When to use |
|---|---|---|---|
| **`VACUUM FULL`** | Rewrites the table **and rebuilds every index** | 🔴 `ACCESS EXCLUSIVE` | Emergency space reclaim, maintenance window only |
| **`CLUSTER`** | Same as `VACUUM FULL` **plus** physical row ordering | 🔴 `ACCESS EXCLUSIVE` | When you also want correlation (index guide §2) |
| **`pg_repack`** | Same result online — table **and** indexes rebuilt | 🟢 Brief lock | The production tool of choice, if available |
| **`REINDEX CONCURRENTLY`** | Indexes only, online | 🟢 Brief lock | Index bloat without table bloat |

> 💡 **On Azure Flexible Server**, check whether `pg_repack` is on the supported-extensions list for your version and add it to the **`azure.extensions`** server parameter before `CREATE EXTENSION`. It needs ~2× the table size in free space and runs as a client-side utility, not a SQL command.

---

# PART IV — What VACUUM actually does to indexes

## 6. The vacuum lifecycle, phase by phase

This is the section that answers the original question properly.

```
PHASE 1  Scan the heap
         -> find dead tuples, collect their TIDs into memory
            (memory bounded by maintenance_work_mem / autovacuum_work_mem)

PHASE 2  Vacuum the indexes          <-- THE INDEX PHASE
         -> for EACH index, scan it and remove entries pointing at dead TIDs
         -> freed slots become reusable WITHIN that index page
         -> pages that end up COMPLETELY empty are marked deleted and
            recycled for future use by this index
         -> NO page merging.  NO re-packing.  NO file shrink.

PHASE 3  Vacuum the heap
         -> mark the dead line pointers reusable

PHASE 4  (if PHASE 1 hit the memory limit, loop back to 1 and repeat)

PHASE 5  Truncate
         -> return only trailing EMPTY pages at the END of the table
            to the OS.  Requires a brief ACCESS EXCLUSIVE lock.
            This applies to the TABLE, not to indexes.
```

**So, precisely:**

- ✅ `VACUUM` **does** remove dead index entries — this is essential; without it indexes grow without limit.
- ✅ `VACUUM` **does** make that space reusable by future inserts *into the same index*.
- ❌ `VACUUM` **does not** merge partially-empty pages.
- ❌ `VACUUM` **does not** re-sort or re-pack anything.
- ❌ `VACUUM` **does not** shrink the index file.
- ❌ `VACUUM` **does not** return index space to the operating system.

### 6.1 Demo — watch vacuum touch the indexes

```sql
-- Make dead tuples
DELETE FROM maint_demo WHERE id % 10 = 0;

SELECT n_live_tup, n_dead_tup, last_vacuum, last_autovacuum
FROM pg_stat_user_tables WHERE relname = 'maint_demo';

-- VERBOSE prints per-index work
VACUUM (VERBOSE, ANALYZE) maint_demo;
```

> **👁 What to look for in the `VERBOSE` output**
>
> ```
> INFO:  vacuuming "maintlab.maint_demo"
> INFO:  scanned index "maint_demo_pkey" to remove 200000 row versions
> INFO:  scanned index "ix_maint_account" to remove 200000 row versions
> INFO:  scanned index "ix_maint_status" to remove 200000 row versions
> INFO:  scanned index "ix_maint_updated" to remove 200000 row versions
> INFO:  "maint_demo": removed 200000 row versions in NNNN pages
> ```
>
> | Line | What it tells you |
> |---|---|
> | **`scanned index "X" to remove N row versions`** | **Phase 2 in action.** Every index is scanned **in full**, once per vacuum cycle. This is why *the number of indexes on a table directly drives vacuum cost.* |
> | **One line per index** | Ten indexes = ten full index scans, every vacuum. A strong argument for dropping unused ones (§2.2). |
> | **`index scans: N`** in the summary | If **greater than 1**, `maintenance_work_mem` was too small to hold all dead TIDs and vacuum had to loop — **re-scanning every index each pass**. Raise the memory setting. |
> | **`removed N row versions in NNNN pages`** | Phase 3, the heap. |
> | **No mention of size reduction** | Because there is none. Confirm with the query below. |

```sql
-- Sizes are unchanged -- prove it
SELECT indexrelname,
       pg_size_pretty(pg_relation_size(indexrelid)) AS size_after_vacuum
FROM pg_stat_user_indexes WHERE schemaname = 'maintlab';
```

### 6.2 VACUUM options that affect indexes

```sql
-- Skip the index phase entirely (PG 12+). Emergency use only.
VACUUM (INDEX_CLEANUP OFF) maint_demo;

-- Force it even when PostgreSQL would skip
VACUUM (INDEX_CLEANUP ON) maint_demo;

-- Default (PG 14+): let PostgreSQL decide
VACUUM (INDEX_CLEANUP AUTO) maint_demo;

-- Parallel index vacuuming -- one worker per index, PG 13+
VACUUM (PARALLEL 4) maint_demo;

-- Freeze aggressively (wraparound work); still does index cleanup
VACUUM (FREEZE) maint_demo;

-- Analyze in the same pass -- almost always what you want
VACUUM (ANALYZE) maint_demo;
```

| Option | Effect on indexes |
|---|---|
| **`INDEX_CLEANUP AUTO`** *(default, PG 14+)* | Skips the index phase when very few pages contain dead items — a large speedup on lightly-churned tables |
| **`INDEX_CLEANUP OFF`** | ⚠️ **No index cleanup at all.** Dead entries accumulate and indexes bloat faster. Reserve for emergency anti-wraparound vacuums where finishing fast is all that matters |
| **`INDEX_CLEANUP ON`** | Forces the full index phase |
| **`PARALLEL n`** | Vacuums multiple indexes concurrently. **Only helps tables with several indexes**, and only for manual `VACUUM` — autovacuum does not use it |
| **`FULL`** | 🔴 Different operation entirely — see §6.4 |

### 6.3 Two modern optimizations worth knowing

**Bottom-up index deletion (PG 14+)** — B-trees now opportunistically delete dead entries **at the moment a page is about to split**, rather than waiting for vacuum. For the classic "repeatedly update the same rows" workload, this dramatically slows index growth. It is automatic, needs no configuration, and is one of the strongest reasons to be on PG 14 or later.

**Index vacuum bypass (PG 14+)** — if fewer than ~2% of heap pages contain dead items, vacuum skips the index phase entirely. This is what `INDEX_CLEANUP AUTO` decides.

> **Migration talking point:** if a customer's PostgreSQL bloat horror stories come from PG 11/12, **PG 14+ materially changes the picture.** Do not let old experience drive the target-version decision.

### 6.4 `VACUUM FULL` — the one that *does* rebuild indexes

```sql
VACUUM FULL maint_demo;
```

**What it actually does:** writes an entirely new copy of the table, then **rebuilds every index from scratch**. The old files are dropped at the end.

| | `VACUUM` | `VACUUM FULL` |
|---|---|---|
| Rebuilds indexes | ❌ | ✅ **Yes, all of them** |
| Shrinks files | ❌ | ✅ |
| Lock | `SHARE UPDATE EXCLUSIVE` (concurrent reads **and** writes) | 🔴 `ACCESS EXCLUSIVE` (**everything blocked**) |
| Extra disk needed | None | **~2× table + indexes** |
| Safe to run routinely | ✅ | ❌ **Never routine** |

```sql
-- Prove it rebuilds the indexes
SELECT indexrelname, pg_size_pretty(pg_relation_size(indexrelid)) AS size_before
FROM pg_stat_user_indexes WHERE schemaname = 'maintlab';

VACUUM FULL maint_demo;

SELECT indexrelname, pg_size_pretty(pg_relation_size(indexrelid)) AS size_after
FROM pg_stat_user_indexes WHERE schemaname = 'maintlab';
-- Every index shrank -- because every index was rebuilt
```

> ⚠️ **`VACUUM FULL` also resets index statistics** (`idx_scan` back to 0 for the rebuilt indexes). If you are mid-way through an unused-index audit (§2.2), a `VACUUM FULL` destroys your evidence.
>
> ⚠️ **It needs roughly double the space during the rewrite.** Running it on a table larger than your free space fails partway — after taking the exclusive lock.

### 6.5 Monitoring a running vacuum

```sql
SELECT p.pid,
       a.query,
       p.phase,
       p.heap_blks_total, p.heap_blks_scanned, p.heap_blks_vacuumed,
       p.index_vacuum_count,
       p.max_dead_tuples, p.num_dead_tuples,
       round(100.0 * p.heap_blks_scanned / NULLIF(p.heap_blks_total, 0), 1) AS pct_scanned
FROM pg_stat_progress_vacuum p
JOIN pg_stat_activity a USING (pid);
```

> **The column to watch is `index_vacuum_count`.** If it climbs above 1, vacuum ran out of `maintenance_work_mem` and is re-scanning every index on each pass. **That is the single most common cause of "vacuum takes forever."** The fix is more memory, not more patience.

```sql
-- Watch an index build too (PG 12+)
SELECT pid, phase, blocks_total, blocks_done, tuples_total, tuples_done
FROM pg_stat_progress_create_index;
```

### 6.6 Autovacuum — tuning for index health

```sql
-- Current settings
SELECT name, setting, unit, short_desc
FROM pg_settings
WHERE name LIKE 'autovacuum%' OR name IN ('maintenance_work_mem','vacuum_cost_limit')
ORDER BY name;
```

```sql
-- Which tables are falling behind?
SELECT relname,
       n_live_tup, n_dead_tup,
       round(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 1) AS dead_pct,
       last_vacuum, last_autovacuum, last_analyze, last_autoanalyze,
       vacuum_count, autovacuum_count
FROM pg_stat_user_tables
WHERE n_dead_tup > 1000
ORDER BY dead_pct DESC NULLS LAST;
```

**Per-table tuning for a hot, heavily-updated table:**

```sql
ALTER TABLE maint_demo SET (
    autovacuum_vacuum_scale_factor  = 0.02,   -- default 0.2 -- vacuum at 2% dead
    autovacuum_vacuum_threshold     = 1000,
    autovacuum_analyze_scale_factor = 0.01,   -- default 0.1
    autovacuum_analyze_threshold    = 500,
    autovacuum_vacuum_cost_limit    = 2000    -- let it work faster
);
```

> **Why the default is wrong for large tables.** `autovacuum_vacuum_scale_factor = 0.2` means *"wait until 20% of the table is dead."* On a 500-million-row table that is **100 million dead tuples** before vacuum starts — by which time every index is badly bloated and the vacuum itself is enormous. **Override the scale factor per-table on anything large and hot.** This is the single highest-value autovacuum change you can make.

> 💡 **Azure Flexible Server:** set instance-wide autovacuum parameters under **Settings → Server parameters** (most are dynamic). Per-table overrides via `ALTER TABLE` work normally and take precedence. There is also an **autovacuum metrics** set (`metrics.autovacuum_diagnostics = ON`) — see the KQL pack §5.9 for dead-tuple and bloat monitoring.

---

# PART V — Statistics

## 7. Statistics are not indexes — and they matter just as much

An index the planner does not understand statistically will not be used. **Roughly half of all "my index isn't working" tickets are stale statistics, not missing indexes.**

### 7.1 `ANALYZE`

```sql
ANALYZE maint_demo;                       -- one table
ANALYZE maint_demo (account_id, status);  -- specific columns
ANALYZE;                                  -- whole database
ANALYZE VERBOSE maint_demo;               -- show sampling detail
```

```sql
-- When was each table last analyzed?
SELECT relname, last_analyze, last_autoanalyze,
       n_mod_since_analyze AS rows_changed_since
FROM pg_stat_user_tables
ORDER BY n_mod_since_analyze DESC NULLS LAST;
```

> ⚠️ **`ANALYZE` after every bulk load, restore, or major-version upgrade.** `pg_upgrade` does **not** carry statistics forward — a freshly upgraded database has *no* statistics until you analyze, and will produce terrible plans until you do. Put `ANALYZE` in the upgrade runbook as a mandatory step.

### 7.2 Inspecting what the planner knows

```sql
SELECT attname                AS column_name,
       n_distinct,
       null_frac,
       avg_width,
       correlation,
       array_length(most_common_vals, 1) AS mcv_count
FROM pg_stats
WHERE schemaname = 'maintlab' AND tablename = 'maint_demo'
ORDER BY attname;
```

| Column | What the planner does with it |
|---|---|
| **`n_distinct`** | Estimates how many rows an equality predicate returns. **Negative values are a ratio** (`-1` = every value unique) |
| `null_frac` | Fraction of NULLs |
| `avg_width` | Average bytes — drives memory and sort estimates |
| **`correlation`** | Physical vs logical ordering — **decides index vs seq scan, and BRIN viability** (index guide §2.4) |
| `most_common_vals` / `most_common_freqs` | Skew handling |
| `histogram_bounds` | Range selectivity |

### 7.3 Statistics target — more samples for skewed columns

```sql
-- Instance default
SHOW default_statistics_target;     -- 100

-- Raise for a column with heavy skew or many distinct values
ALTER TABLE maint_demo ALTER COLUMN account_id SET STATISTICS 500;
ANALYZE maint_demo;                 -- required -- the change is not retroactive

-- Reset to the default
ALTER TABLE maint_demo ALTER COLUMN account_id SET STATISTICS -1;
```

| Target | Use when |
|---|---|
| **100** *(default)* | Most columns |
| **250–500** | Skewed distributions, high-cardinality join keys |
| **1000** | Severe skew, and only after proving it helps |

> ⚠️ **Cost:** higher targets make `ANALYZE` slower and planning slightly slower. **Raise it per-column where you have evidence of a bad estimate — never globally as a reflex.**

### 7.4 Extended statistics — the fix for correlated columns

The planner assumes columns are **independent**. When they are not, estimates collapse.

> **👁 What to look for — the estimate error**
>
> Run the query below and compare **`rows=` (estimated) against `actual rows=`** on the scan node.
>
> A classic case: `city` and `state` are not independent — every row with `city = 'Seattle'` also has `state = 'WA'`. The planner multiplies the two selectivities as if they were unrelated and **under-estimates by orders of magnitude**. That bad estimate then causes a nested loop where a hash join was right, and the query is 100× slower — **with a perfectly good index in place.**
>
> **The diagnostic signature:** estimated rows and actual rows differ by 10× or more on a multi-column predicate. That is the cue to reach for `CREATE STATISTICS`.

```sql
DROP TABLE IF EXISTS corr_demo;

CREATE TABLE corr_demo AS
SELECT g AS id,
       (ARRAY['Seattle','Portland','Austin','Boston'])[1 + (g % 4)]  AS city,
       (ARRAY['WA','OR','TX','MA'])[1 + (g % 4)]                     AS state
FROM generate_series(1, 1000000) g;

CREATE INDEX ix_corr ON corr_demo (city, state);
ANALYZE corr_demo;

-- BEFORE: estimate will be far too low
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT count(*) FROM corr_demo WHERE city = 'Seattle' AND state = 'WA';
```

```sql
-- Teach the planner that these columns are related
CREATE STATISTICS stx_corr_city_state (dependencies, ndistinct, mcv)
    ON city, state FROM corr_demo;

ANALYZE corr_demo;

-- AFTER: estimate should now be close to actual
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT count(*) FROM corr_demo WHERE city = 'Seattle' AND state = 'WA';
```

```sql
-- Inspect what it learned
SELECT stxname, stxkeys, stxkind
FROM pg_statistic_ext WHERE stxname = 'stx_corr_city_state';

SELECT * FROM pg_stats_ext WHERE statistics_name = 'stx_corr_city_state';
```

| Statistics kind | Fixes |
|---|---|
| **`dependencies`** | Functional dependency — "city determines state" |
| **`ndistinct`** | Multi-column distinct counts — helps `GROUP BY` estimates |
| **`mcv`** | Most-common *combinations* of values — the strongest, and the most expensive |

> **Oracle equivalent:** extended statistics / column groups (`DBMS_STATS.CREATE_EXTENDED_STATS`). Same problem, same solution, different syntax. **SQL Server** has multi-column statistics but no direct `dependencies` equivalent.

### 7.5 Statistics on expression indexes — a free bonus

```sql
CREATE INDEX ix_maint_lower_status ON maint_demo (lower(status));
ANALYZE maint_demo;

-- PostgreSQL gathers SEPARATE statistics for the indexed expression
SELECT attname, n_distinct, most_common_vals
FROM pg_stats
WHERE tablename = 'ix_maint_lower_status';   -- note: the INDEX name, not the table
```

> **Creating an expression index improves estimates for that expression, even beyond the access-path benefit.** Sometimes worth creating for the statistics alone.

### 7.6 Partitioned tables — the statistics gap

```sql
-- Partition-level statistics are gathered by autovacuum.
-- PARENT-level statistics are NOT maintained automatically -- you must
-- ANALYZE the parent explicitly, and they matter for cross-partition planning.
ANALYZE my_partitioned_table;
```

> ⚠️ **Autoanalyze does not maintain parent-table statistics on partitioned tables.** Schedule an explicit `ANALYZE <parent>` — this is a genuine gap that bites teams migrating large partitioned Oracle schemas.

---

# PART VI — Operations

## 8. A maintenance schedule that actually works

| Frequency | Task | Command / query |
|---|---|---|
| **Continuous** | Autovacuum + autoanalyze | Tuned per-table (§6.6) |
| **Daily** | Check for invalid indexes | §2.5 |
| **Daily** | Check vacuum is keeping up | §6.6 second query |
| **Weekly** | Review index usage | §2.1, §2.2 |
| **Weekly** | Bloat estimate sweep | §4.2 |
| **Monthly** | Confirm shortlist with `pgstatindex`, rebuild > 30% bloat | §4.1, §5.2 |
| **Monthly** | Duplicate / redundant index review | §2.3 |
| **Quarterly** | Review statistics targets on problem columns | §7.3 |
| **After bulk load** | `VACUUM (ANALYZE)` | §6 |
| **After major upgrade** | ⚠️ **`ANALYZE` the whole database** | §7.1 |

## 9. A one-shot health report

```sql
WITH idx AS (
    SELECT s.schemaname, s.relname, s.indexrelname, s.idx_scan,
           pg_relation_size(s.indexrelid) AS bytes,
           i.indisunique, i.indisprimary, i.indisvalid
    FROM pg_stat_user_indexes s
    JOIN pg_index i ON i.indexrelid = s.indexrelid
    WHERE s.schemaname NOT IN ('pg_catalog','information_schema')
)
SELECT schemaname || '.' || relname                AS table_name,
       indexrelname                                AS index_name,
       pg_size_pretty(bytes)                       AS size,
       idx_scan                                    AS times_used,
       CASE
         WHEN NOT indisvalid                     THEN '🔴 INVALID - drop and rebuild'
         WHEN idx_scan = 0 AND indisprimary      THEN '⚪ PK - keep regardless'
         WHEN idx_scan = 0 AND indisunique       THEN '⚪ Unique - enforces correctness'
         WHEN idx_scan = 0 AND bytes > 100000000 THEN '🔴 Unused and large - candidate to drop'
         WHEN idx_scan = 0                       THEN '🟠 Unused - verify over a full cycle'
         WHEN idx_scan < 50                      THEN '🟡 Rarely used - review'
         ELSE                                         '🟢 Active'
       END                                         AS assessment
FROM idx
ORDER BY CASE WHEN NOT indisvalid THEN 0
              WHEN idx_scan = 0 THEN 1
              ELSE 2 END,
         bytes DESC
LIMIT 50;
```

## 10. Azure Flexible Server specifics

| Topic | Detail |
|---|---|
| **Extensions** | `pgstattuple`, and `pg_repack` if supported for your version, must be added to the **`azure.extensions`** server parameter before `CREATE EXTENSION` |
| **No superuser** | `VACUUM FULL` on system catalogs and some maintenance operations are unavailable. Table owner privileges cover normal maintenance |
| **`maintenance_work_mem`** | Raise it for the session before a large `REINDEX`, and instance-wide if `index_vacuum_count > 1` is common |
| **Scale for maintenance** | Index rebuilds are I/O-bound. **Scale up compute/IOPS, rebuild, scale back** — near-zero-downtime scaling makes this cheap |
| **Autovacuum metrics** | Set `metrics.autovacuum_diagnostics = ON` to expose bloat and dead-tuple metrics; query them via the KQL pack (§5.9) |
| **Index Tuning** | Azure's Query Store–based index recommendations are a useful cross-check against your own analysis — **not a replacement for it** |
| **Backup interaction** | A large `REINDEX` generates substantial WAL, which inflates backup storage. Account for it before a bulk rebuild |

```sql
-- Session settings for a large rebuild
SET maintenance_work_mem = '2GB';
SET max_parallel_maintenance_workers = 4;
REINDEX INDEX CONCURRENTLY ix_maint_account;
```

## 11. Cross-platform translation

| Task | **PostgreSQL** | **Oracle** | **SQL Server** |
|---|---|---|---|
| Rebuild an index | `REINDEX [CONCURRENTLY]` | `ALTER INDEX ... REBUILD [ONLINE]` | `ALTER INDEX ... REBUILD` |
| **Reorganize / defragment in place** | ❌ **Does not exist** | `ALTER INDEX ... COALESCE` / `SHRINK SPACE` | `ALTER INDEX ... REORGANIZE` |
| Measure fragmentation | `pgstatindex` | `DBMS_SPACE`, `INDEX_STATS` | `sys.dm_db_index_physical_stats` |
| Update statistics | `ANALYZE` | `DBMS_STATS.GATHER_*` | `UPDATE STATISTICS` |
| Automatic statistics | autoanalyze | Auto Optimizer Stats task | Auto Update Statistics |
| Multi-column statistics | `CREATE STATISTICS` | Extended stats / column groups | Multi-column statistics |
| Reclaim table space | `VACUUM FULL` / `CLUSTER` / `pg_repack` | `ALTER TABLE ... MOVE` / `SHRINK` | `ALTER INDEX ... REBUILD` |
| Space reclamation for MVCC | **`VACUUM`** | *(undo segments — no equivalent)* | *(no equivalent)* |
| Invisible index for testing | ❌ (use `DROP` + `ROLLBACK`) | `ALTER INDEX ... INVISIBLE` | `DISABLE` |
| Fill factor | `fillfactor` (default 90) | `PCTFREE` | `FILLFACTOR` (default 0 = 100) |

> **The two most important lines in this table for an Oracle or SQL Server DBA:**
> 1. **There is no reorganize.** Any runbook step that says "reorganize if fragmentation is 10–30%, rebuild if above 30%" collapses to a single branch in PostgreSQL: **rebuild, or do nothing.**
> 2. **`VACUUM` has no equivalent in either platform.** It is not a defragmenter — it is MVCC garbage collection, doing the job Oracle's undo segments do automatically. Teams that map `VACUUM` onto "reorg" will mis-tune it badly.

## 12. Maintenance checklist

**Usage review**
- [ ] `idx_scan` reviewed over a **full business cycle**, not a single week
- [ ] `stats_reset` timestamp checked before acting on any "unused" finding
- [ ] Read-replica usage considered separately
- [ ] Duplicate and prefix-redundant indexes identified (§2.3)
- [ ] No invalid indexes left in place (§2.5)
- [ ] Removal candidates tested with `DROP` inside a rolled-back transaction

**Bloat**
- [ ] `pgstattuple` available, or the estimation query scheduled
- [ ] Rebuild threshold agreed (commonly `avg_leaf_density < 60%` or bloat > 30%)
- [ ] Rebuilds use `REINDEX CONCURRENTLY`, with free space verified first
- [ ] `fillfactor` reviewed on update-heavy indexes

**Vacuum**
- [ ] `autovacuum_vacuum_scale_factor` overridden per-table on large hot tables
- [ ] `index_vacuum_count` monitored — consistently > 1 means raise `maintenance_work_mem`
- [ ] `VACUUM FULL` **not** in any routine schedule
- [ ] Unused indexes dropped — each one is a full index scan on every vacuum

**Statistics**
- [ ] `ANALYZE` in every bulk-load and upgrade runbook
- [ ] Statistics targets raised only where a bad estimate was proven
- [ ] Extended statistics created for correlated column pairs
- [ ] Partitioned tables get an explicit parent-level `ANALYZE`

## 13. Teardown

```sql
DROP SCHEMA maintlab CASCADE;
DROP TABLE IF EXISTS corr_demo;
```

---

## Reference

- Routine vacuuming — https://www.postgresql.org/docs/current/routine-vacuuming.html
- `VACUUM` — https://www.postgresql.org/docs/current/sql-vacuum.html
- `REINDEX` — https://www.postgresql.org/docs/current/sql-reindex.html
- Routine reindexing — https://www.postgresql.org/docs/current/routine-reindex.html
- `ANALYZE` — https://www.postgresql.org/docs/current/sql-analyze.html
- Planner statistics — https://www.postgresql.org/docs/current/planner-stats.html
- Extended statistics — https://www.postgresql.org/docs/current/planner-stats.html#PLANNER-STATS-EXTENDED
- `CREATE STATISTICS` — https://www.postgresql.org/docs/current/sql-createstatistics.html
- `pgstattuple` — https://www.postgresql.org/docs/current/pgstattuple.html
- Monitoring statistics views — https://www.postgresql.org/docs/current/monitoring-stats.html
- B-tree implementation notes — https://www.postgresql.org/docs/current/btree-implementation.html
- Azure — extensions — https://learn.microsoft.com/en-us/azure/postgresql/extensions/concepts-extensions
- Azure — autovacuum tuning — https://learn.microsoft.com/en-us/azure/postgresql/how-to-high-cpu-utilization
