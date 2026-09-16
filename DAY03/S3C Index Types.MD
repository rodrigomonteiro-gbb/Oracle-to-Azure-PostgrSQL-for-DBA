# PostgreSQL Index Types — Complete Guide with Hands-On Demos

## For DBAs coming from SQL Server and Oracle

---

## 0. Setup — run this once

Everything below lives in a dedicated schema so you can drop the whole lab in one statement.

```sql
-- Lab schema
CREATE SCHEMA IF NOT EXISTS idxlab;
SET search_path TO idxlab, public;

-- Timing and plan readability
\timing on

-- Confirm version and key settings
SELECT version();
SHOW shared_buffers;
SHOW work_mem;
SHOW effective_cache_size;
```

### 0.1 The measurement toolkit — learn these four before anything else

Every demo in this guide uses the same four instruments. Learn them once.

```sql
-- 1. THE PLAN + REAL EXECUTION NUMBERS (your primary tool)
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT ...;

-- 2. INDEX SIZE -- indexes are not free; always price the gain
SELECT indexrelname AS index_name,
       pg_size_pretty(pg_relation_size(indexrelid)) AS index_size
FROM pg_stat_user_indexes
WHERE schemaname = 'idxlab'
ORDER BY pg_relation_size(indexrelid) DESC;

-- 3. IS THE INDEX ACTUALLY USED? -- find dead weight
SELECT relname AS table_name,
       indexrelname AS index_name,
       idx_scan  AS times_used,
       idx_tup_read,
       idx_tup_fetch,
       pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes
WHERE schemaname = 'idxlab'
ORDER BY idx_scan;

-- 4. TABLE-LEVEL ACCESS PATTERN -- seq scans vs index scans
SELECT relname, seq_scan, seq_tup_read, idx_scan, idx_tup_fetch,
       n_live_tup, n_dead_tup, last_autovacuum, last_autoanalyze
FROM pg_stat_user_tables
WHERE schemaname = 'idxlab';
```

> **Reading `EXPLAIN (ANALYZE, BUFFERS)` — the three numbers that matter**
> - **`actual time=x..y`** — real milliseconds. The last number on the top node is your answer.
> - **`rows=` estimated vs actual** — if these diverge by 10× or more, your statistics are stale. Run `ANALYZE`. A bad estimate causes a bad plan far more often than a missing index does.
> - **`Buffers: shared hit=... read=...`** — pages touched. **This is the most honest metric**, because it is immune to cache warmth and machine noise. A good index reduces buffers by orders of magnitude.

### 0.2 Three rules to state before the first demo

1. **`ANALYZE` after every bulk load.** An index the planner does not know about statistically will not be used. Half of all "my index isn't working" tickets are stale statistics.
2. **Use `CREATE INDEX CONCURRENTLY` in production.** A plain `CREATE INDEX` takes an `ACCESS EXCLUSIVE`-blocking share lock that stops all writes on the table. `CONCURRENTLY` does not, at the cost of two table passes and the possibility of leaving an **INVALID** index if it fails (drop and retry).
3. **Every index costs write throughput and storage.** An unused index is pure overhead on every `INSERT`, `UPDATE`, and `DELETE`. Instrument #3 above finds them.

---

# PART I — The foundations: heap, clustered, nonclustered

---

## 1. The heap table — where PostgreSQL starts

### 1.1 Concept

**In PostgreSQL, every table is a heap. Always. There is no such thing as a clustered table.**

A heap is an unordered collection of 8 KB pages. Rows land wherever there is free space. Each row version (tuple) is addressed by a **`ctid`** — a `(block_number, tuple_index)` pair — which is a *physical* address, not a stable identity.

| Concept | SQL Server | Oracle | PostgreSQL |
|---|---|---|---|
| Default table structure | Heap, *until* you add a clustered index | Heap | **Heap — permanently** |
| Physical row address | RID | `ROWID` (stable) | **`ctid` (NOT stable — changes on UPDATE)`** |
| Table organized by key | Clustered index | Index-Organized Table (IOT) | **No equivalent** (see §2) |

> ⚠️ **The single most important difference for both audiences:** `ctid` is **not** an Oracle `ROWID`. PostgreSQL's MVCC creates a **new row version** on every `UPDATE`, at a new physical location. A row's `ctid` changes whenever it is updated or the table is vacuumed/reorganized. Never store it, never build application logic on it.

### 1.2 Why this matters for indexing

Because every index entry points at a `ctid`, and `ctid`s move, PostgreSQL indexes have three properties that surprise both SQL Server and Oracle DBAs:

1. **All indexes are "secondary" indexes.** There is no index whose leaf level *is* the table.
2. **An index scan is always followed by a heap fetch** — unless the query qualifies for an **index-only scan** (§4.3).
3. **Updating an indexed column requires updating every index.** This is why PostgreSQL has **HOT (Heap-Only Tuple)** updates: if no indexed column changed *and* the new version fits on the same page, PostgreSQL skips index maintenance entirely. **Indexing a hot, frequently-updated column silently disables HOT and can be a significant write regression.**

### 1.3 Demo — see the heap for yourself

```sql
SET search_path TO idxlab, public;

DROP TABLE IF EXISTS heap_demo;

CREATE TABLE heap_demo (
    id          bigint,
    status      text,
    amount      numeric(12,2),
    updated_at  timestamptz DEFAULT now()
);

INSERT INTO heap_demo (id, status, amount)
SELECT g,
       (ARRAY['NEW','OPEN','CLOSED'])[1 + (g % 3)],
       (random() * 1000)::numeric(12,2)
FROM generate_series(1, 10) g;

-- ctid is a PHYSICAL address: (page, slot)
SELECT ctid, id, status, amount FROM heap_demo ORDER BY id;
```

Now prove the address is not stable:

```sql
-- Note the ctid of row 5
SELECT ctid, id, amount FROM heap_demo WHERE id = 5;

UPDATE heap_demo SET amount = amount + 1 WHERE id = 5;

-- Same logical row, DIFFERENT physical address -- a new row version was written
SELECT ctid, id, amount FROM heap_demo WHERE id = 5;
```

And prove that "heap" means "no guaranteed order":

```sql
-- Rows come back in physical order, not insert order, after updates
SELECT ctid, id FROM heap_demo;
```

> This is why `SELECT` without `ORDER BY` has **no** ordering guarantee in PostgreSQL — stronger than in Oracle or SQL Server, because MVCC actively relocates rows. There is no "it usually comes back in clustered-index order" fallback, because there is no clustered index.

```sql
DROP TABLE heap_demo;
```

---

## 2. "Clustered index" — the SQL Server concept, and PostgreSQL's answer

### 2.1 What SQL Server and Oracle give you

- **SQL Server clustered index:** the table *is* the B-tree. Leaf level = data rows, physically ordered by the key, **continuously maintained**.
- **Oracle IOT:** same idea — rows stored in the primary-key B-tree.

### 2.2 What PostgreSQL gives you: `CLUSTER` — and why it is NOT the same

PostgreSQL's `CLUSTER` command physically rewrites the table in the order of a chosen index.

> ⚠️ **`CLUSTER` is a ONE-TIME physical reorganization, not a maintained structure.** After `CLUSTER`, new and updated rows go wherever there is free space, exactly as before. Correlation decays with every write. There is **no** PostgreSQL feature that continuously maintains physical order.

| | SQL Server clustered index | PostgreSQL `CLUSTER` |
|---|---|---|
| Order maintained on write | **Yes, continuously** | **No — decays immediately** |
| Number per table | One | One index may be *marked* for clustering; re-run manually |
| Lock taken | Online rebuild options exist | **`ACCESS EXCLUSIVE` — table fully locked** |
| Storage during operation | — | Rewrites the table; needs free space for a full copy |

### 2.3 The benefit — correlation, and why it is worth measuring

The gain is not "ordered output". It is **physical correlation**: when rows matching a range predicate sit on adjacent pages, one range query reads a handful of pages instead of thousands scattered across the heap. This is exactly the metric `BRIN` also depends on (§10).

**Use case:** a large append-mostly table queried heavily by date range, where the natural insert order has been scrambled — or any table where a range query on an indexed column still shows huge `Buffers: read` counts despite using the index.

### 2.4 What is `correlation`? (read this before the demo)

`correlation` is a **statistic PostgreSQL stores about one column**, exposed in the `pg_stats` view. It answers a single question:

> **"If I sort the rows by this column's value, how closely does that order match the order the rows are physically stored in on disk?"**

It is a number between **-1.0 and +1.0**:

| Value | Meaning | What it implies for a range query |
|---|---|---|
| **+1.0** | Perfect match — ascending values stored in ascending physical order | Matching rows are **packed together** on consecutive pages. Best case. |
| **~0.0** | No relationship — values scattered randomly across pages | Every matching row is likely on its **own separate page**. Worst case. |
| **-1.0** | Perfectly *reversed* — descending values in ascending physical order | Also excellent: rows are still packed together, just in reverse. |

> **What matters is the distance from zero, not the sign.** Both `+1.0` and `-1.0` mean "physically clustered". Only values near `0` mean "scattered".

#### Why it exists: PostgreSQL isn't describing your data — it's describing your disk

Remember from §1 that a PostgreSQL table is a **heap**: rows sit wherever there was free space when they were written. Correlation measures how lucky — or how deliberately arranged — that physical layout happens to be, relative to one column.

**A concrete picture.** Say a table holds 900 rows across 9 pages, 100 rows per page.

*Correlation ≈ 1.0 (rows inserted in `customer_id` order):*

```
Page 1: customer_id 1......100
Page 2: customer_id 101....200
Page 3: customer_id 201....300     <-- WHERE customer_id BETWEEN 150 AND 250
...                                    reads Page 2 + Page 3.  2 pages.
```

*Correlation ≈ 0.0 (rows inserted in random order):*

```
Page 1: 847, 12, 503, 91, 288, ...
Page 2: 33, 771, 150, 604, 219, ...   <-- WHERE customer_id BETWEEN 150 AND 250
Page 3: 455, 180, 999, 27, 241, ...       matching rows are smeared across
...                                        ALL 9 pages.  9 pages.
```

The index finds the same 101 rows in both cases. **The difference is entirely in how many 8 KB pages must be read to collect them.** Scale that from 9 pages to a 2,000,000-row table and it becomes the 10–50× buffer reduction the demo measures.

#### Why it matters *twice*

**1. The planner uses it to decide whether your index is worth using at all.** Correlation feeds directly into PostgreSQL's cost model. With low correlation the planner assumes an index scan means one random page read per row — expensive enough that it will frequently **reject a perfectly good index and pick a sequential scan instead.** This is one of the genuine answers to "why is my index being ignored?"

**2. It decides whether BRIN is viable.** A BRIN index (§10) stores only min/max per block range, so it can only skip ranges when values are physically grouped — exactly what correlation measures. That's why §10 checks correlation *before* building the index, and why this same query appears in both sections.

#### Where the number comes from

Correlation is computed by **`ANALYZE`** (and autoanalyze) from a *sample* of the table, stored in `pg_statistic`, and read through the `pg_stats` view. Three consequences:

- **It's an estimate from a sample**, not an exact measurement.
- **It goes stale.** Bulk-load, `CLUSTER`, or a large `UPDATE` without `ANALYZE` leaves the planner working from the *old* physical reality. This is why every step of the demo re-runs `ANALYZE`.
- **`pg_stats` returns nothing for a never-analyzed table.** An empty result means "run `ANALYZE`" — not "correlation is zero".

#### Reading the demo query line by line

```sql
SELECT attname, correlation
FROM pg_stats
WHERE schemaname = 'idxlab' AND tablename = 'cluster_demo'
  AND attname = 'customer_id';        -- now close to 1.0
```

| Element | Meaning |
|---|---|
| `pg_stats` | Human-readable view over the planner's column statistics |
| `attname` | *Attribute name* — PostgreSQL's internal term for a column |
| `correlation` | The value explained above, for **that one column** |
| `schemaname` / `tablename` | Scopes it to one table — `pg_stats` covers the entire database |

The demo runs this query **three times on purpose**, and that sequence is the whole lesson:

1. **After the random insert** → near `0`. The table is scattered.
2. **After `CLUSTER` + `ANALYZE`** → near `1.0`. The table was physically rewritten in index order.
3. **After a batch of `UPDATE`s + `ANALYZE`** → **drifting back toward `0`.**

Step 3 is the point of the entire section. Each `UPDATE` writes a **new row version** wherever free space exists — not back in sorted position. **PostgreSQL does nothing to preserve the ordering `CLUSTER` created.** That is the measurable proof that `CLUSTER` is periodic maintenance, not a SQL Server clustered index.

#### A useful extra: survey every column at once

```sql
-- Good first stop whenever a range query is slower than it should be
SELECT attname                          AS column_name,
       correlation,
       abs(correlation)                 AS clustering_strength,
       CASE
         WHEN abs(correlation) > 0.9 THEN 'Excellent - BRIN candidate, great range scans'
         WHEN abs(correlation) > 0.5 THEN 'Moderate - B-tree fine, BRIN marginal'
         ELSE                             'Poor - scattered; consider CLUSTER, use B-tree'
       END                              AS assessment,
       n_distinct
FROM pg_stats
WHERE schemaname = 'idxlab' AND tablename = 'cluster_demo'
ORDER BY abs(correlation) DESC NULLS LAST;
```

> **Two caveats worth saying out loud to the room.**
> - A table can have high correlation on **only one** column — physical order is one-dimensional. Clustering by `customer_id` necessarily scrambles `order_date`. **Choosing what to cluster on is choosing which query to favour.**
> - Correlation is meaningless for types with no natural ordering, and `pg_stats` may report `NULL` for them. It is a statistic about *ordered* data.

### 2.5 Demo — measure clustering, then fix it

```sql
SET search_path TO idxlab, public;

DROP TABLE IF EXISTS cluster_demo;

CREATE TABLE cluster_demo (
    id          bigserial PRIMARY KEY,
    customer_id int         NOT NULL,
    order_date  date        NOT NULL,
    amount      numeric(12,2) NOT NULL,
    notes       text
);

-- 2,000,000 rows inserted in RANDOM customer order -- deliberately uncorrelated
INSERT INTO cluster_demo (customer_id, order_date, amount, notes)
SELECT (random() * 50000)::int + 1,
       DATE '2020-01-01' + (random() * 2000)::int,
       (random() * 5000)::numeric(12,2),
       repeat('x', 40)
FROM generate_series(1, 2000000);

ANALYZE cluster_demo;

CREATE INDEX ix_cluster_demo_customer ON cluster_demo (customer_id);
ANALYZE cluster_demo;
```

**Step 1 — measure correlation.** `correlation` is the statistical relationship between logical key order and physical row order: `1.0` = perfect, `0` = random.

```sql
SELECT attname, n_distinct, correlation
FROM pg_stats
WHERE schemaname = 'idxlab' AND tablename = 'cluster_demo'
  AND attname IN ('customer_id','order_date','id');
```

Expect `customer_id` correlation near **0** — random insert order.

**Step 2 — baseline the range query**

> **👁 What to look for in this plan**
>
> This is the "before" measurement for the whole section. You are **not** looking at whether the index is used — it will be. You are looking at **how many pages it costs to use it**.
>
> | In the plan | What it tells you here |
> |---|---|
> | **`Bitmap Heap Scan`** on `cluster_demo` | The planner knows the rows are scattered, so it collects all matching `ctid`s first, sorts them into physical order, then fetches. **Seeing `Bitmap` instead of a plain `Index Scan` is itself the symptom of poor correlation.** |
> | **`Bitmap Index Scan on ix_cluster_demo_customer`** | The index is being used to find the rows — confirming the slowness is *not* a missing index. |
> | **`Buffers: shared hit=N read=M`** | **The number that matters.** `hit` = pages found in cache, `read` = pages fetched from storage. Add them: that total is roughly how many distinct 8 KB pages held your ~200 customers' rows. Expect it to be close to the *row count*, because almost every row lives on its own page. |
> | **`Heap Blocks: exact=N`** | Explicitly counts heap pages visited. Compare this to `rows=` on the same node — when they are nearly equal, you have found textbook scattering. |
> | **`rows=` estimated vs actual** | Should be close. If they diverge wildly, your problem is stale statistics, not correlation — stop and `ANALYZE`. |
> | **`actual time=`** on the top node | Wall-clock ms. Useful, but **less trustworthy than `Buffers`** because it moves with cache warmth and machine noise.
>
> **Write down the buffer total before continuing.** Steps 4 and 5 are meaningless without it.

**Step 3 — cluster the table**

```sql
-- ACCESS EXCLUSIVE lock -- maintenance window only
CLUSTER cluster_demo USING ix_cluster_demo_customer;

-- CLUSTER invalidates statistics
ANALYZE cluster_demo;
```

**Step 4 — re-measure**

```sql
SELECT attname, correlation
FROM pg_stats
WHERE schemaname = 'idxlab' AND tablename = 'cluster_demo'
  AND attname = 'customer_id';        -- now close to 1.0
```

> **👁 What to look for in this plan — compare it line by line against Step 2**
>
> Same query, same index, same row count. **Only the physical layout changed.** That is what makes this a clean experiment.
>
> | In the plan | What changed and why |
> |---|---|
> | **`Buffers: shared hit/read`** | **The headline.** Expect a drop of roughly 10–50× on this data shape. The ~200 matching customers now sit on a handful of consecutive pages instead of hundreds of scattered ones. *One index entry per row still gets read — but many rows now share a page.* |
> | **`Heap Blocks: exact=N`** | Should collapse dramatically. Compare it to `rows=`: previously nearly 1:1, now many rows per block. |
> | **Node type may change** | With high correlation the planner may now choose a plain **`Index Scan`** instead of `Bitmap Heap Scan` — it now believes sequential-ish access is cheap. **A change in node type is a change in the planner's mind, caused purely by the `correlation` statistic.** |
> | **`actual time=`** | Will drop, but by less than buffers do if the data was already cached. **Trust the buffer drop as the real result.** |
> | **`rows=` estimated vs actual** | Should still match — you ran `ANALYZE` after `CLUSTER`. If estimates are now wrong, the `ANALYZE` did not happen. |
>
> You did not add an index, tune a parameter, or rewrite the query. **You reorganized the heap** — and the same index became far more effective.

**Step 5 — prove the decay (the part that matters most)**

```sql
-- Simulate ongoing write activity
UPDATE cluster_demo
SET amount = amount + 1
WHERE id % 10 = 0;

ANALYZE cluster_demo;

-- Correlation has already dropped -- CLUSTER is not maintained
SELECT attname, correlation
FROM pg_stats
WHERE schemaname = 'idxlab' AND tablename = 'cluster_demo'
  AND attname = 'customer_id';
```

**Expected result:** buffers read drops sharply after `CLUSTER` (often 10–50× on this shape of data), then correlation degrades as soon as writes resume.

**Operational conclusion:** treat `CLUSTER` as **periodic maintenance** (like an Oracle table reorg), scheduled in a window — never as a design substitute for a clustered index.

```sql
-- Keep this table; §10 (BRIN) reuses the pattern. Otherwise:
-- DROP TABLE cluster_demo;
```

---

## 3. "Nonclustered index" — the PostgreSQL B-tree

### 3.1 Concept

A SQL Server nonclustered index and an Oracle normal B-tree index are the same thing as a **PostgreSQL B-tree index**: a separate balanced-tree structure whose leaves hold key values plus a pointer to the row.

One structural difference worth naming: a SQL Server nonclustered index leaf points to the *clustered key* (if one exists); a PostgreSQL B-tree leaf always points to a **`ctid`**.

**B-tree is the default** — `CREATE INDEX ... ON t (col)` builds a B-tree — and it is the only type that supports **all** of: `=`, `<`, `<=`, `>`, `>=`, `BETWEEN`, `IN`, `IS NULL`, `ORDER BY` optimization, uniqueness, and `LIKE 'prefix%'` (with the right collation).

### 3.2 Benefit and use case

**Benefit:** turns an O(n) sequential scan into an O(log n) tree descent, and can satisfy `ORDER BY`/`LIMIT` without a sort.

**Use case:** the default answer for OLTP selective lookups, foreign keys, range filters, and sort avoidance. **Roughly 90%+ of PostgreSQL indexes in production are B-trees**, and that is correct — reach for an exotic type only when the data type or query shape demands it.

### 3.3 Demo — the fundamental win

```sql
SET search_path TO idxlab, public;

DROP TABLE IF EXISTS btree_demo;

CREATE TABLE btree_demo (
    id           bigserial PRIMARY KEY,
    email        text        NOT NULL,
    last_name    text        NOT NULL,
    signup_date  timestamptz NOT NULL,
    country      char(2)     NOT NULL,
    lifetime_val numeric(12,2) NOT NULL
);

INSERT INTO btree_demo (email, last_name, signup_date, country, lifetime_val)
SELECT 'user' || g || '@example.com',
       (ARRAY['Silva','Smith','Nakamura','Okafor','Dubois','Rossi','Kim','Muller'])[1 + (g % 8)] || g % 997,
       now() - ((random() * 1500) || ' days')::interval,
       (ARRAY['US','BR','DE','JP','IN','GB'])[1 + (g % 6)],
       (random() * 10000)::numeric(12,2)
FROM generate_series(1, 3000000) g;

ANALYZE btree_demo;

SELECT pg_size_pretty(pg_total_relation_size('btree_demo')) AS table_size;
```

**Step 1 — baseline (no index on `email`)**

> **👁 What to look for in this plan**
>
> This is the "no index at all" case — the worst-case shape every later demo is measured against.
>
> | In the plan | What it means |
> |---|---|
> | **`Seq Scan`** or **`Parallel Seq Scan`** on `btree_demo` | PostgreSQL is reading **every row in the table** to find one. There is no alternative — no index exists on `email`. |
> | **`Filter: (email = '...')`** | The predicate is applied *after* reading each row, not used to locate rows. **`Filter` means "examined and discarded"; the contrast is `Index Cond`, which means "never examined at all".** |
> | **`Rows Removed by Filter: ~2,999,999`** | The cost of the whole approach in one number: three million rows read to return one. |
> | **`Buffers: shared hit/read`** | Expect **hundreds of thousands** — essentially the entire table, since a seq scan touches every page. |
> | **`Workers Planned/Launched`** | If parallel, PostgreSQL threw multiple CPUs at the problem. **Note this: parallelism is the engine compensating for a missing index by burning cores.** After indexing, workers disappear — the work is too small to be worth parallelizing. |
> | **`actual time=`** | Hundreds of ms. Record it. |
>
> **Note the `rows=1` on the top node against the buffer count.** That ratio — one row returned, an entire table read — is the single clearest justification for an index you can show a room.

**Step 2 — create the index**

```sql
-- Production form:
-- CREATE INDEX CONCURRENTLY ix_btree_demo_email ON btree_demo (email);
CREATE INDEX ix_btree_demo_email ON btree_demo (email);
ANALYZE btree_demo;
```

**Step 3 — re-measure**

> **👁 What to look for in this plan — the four changes that define what an index does**
>
> | In the plan | What changed |
> |---|---|
> | **`Seq Scan` → `Index Scan using ix_btree_demo_email`** | The access method itself changed. PostgreSQL now navigates directly to the row. |
> | **`Filter:` → `Index Cond:`** | **The most important single line in this plan.** `Index Cond` means the predicate was used to *locate* rows inside the B-tree. Nothing was read and thrown away. Correspondingly, **`Rows Removed by Filter` disappears entirely** — a line vanishing from a plan is a result. |
> | **`Buffers: shared hit=4..6`** | From hundreds of thousands to a handful. Those ~4–6 pages are the B-tree **root → internal → leaf** descent plus **one heap page** to fetch the row. **This is what O(log n) looks like in page counts** — and why a deeper table barely costs more. |
> | **No `Workers` line** | Parallelism gone. The work is now trivially small. |
> | **`actual time=0.0xx ms`** | Sub-millisecond. |
>
> **How to quantify the win for a slide:** divide the Step 1 buffer total by this one. On a 3M-row table that ratio is typically **10,000× or better**. Express the gain in *pages*, not milliseconds — page counts are reproducible on any hardware, timings are not.

**Step 4 — price the index**

```sql
SELECT pg_size_pretty(pg_relation_size('ix_btree_demo_email')) AS index_size,
       pg_size_pretty(pg_relation_size('btree_demo'))          AS heap_size;
```

**Step 5 — sort avoidance, the benefit people forget**

> **👁 What to look for across this pair of plans**
>
> Both queries below ask for the 20 newest signups. **Neither has a `WHERE` clause** — so this demonstrates a benefit that has nothing to do with filtering. A B-tree stores its keys *in order*, so it can hand back sorted rows for free.
>
> **In the FIRST plan (before the index), look for:**
> - **`Sort`** node, with **`Sort Method: external merge  Disk: NNNNkB`** or `quicksort  Memory: NNNNkB`. **`Disk` means the sort spilled out of `work_mem` and wrote temporary files to storage** — a hidden I/O cost that never appears in row counts.
> - **`Sort Key: signup_date DESC`** — confirming PostgreSQL is doing the ordering work itself.
> - The `Seq Scan` beneath it reading **all 3,000,000 rows** — because to find the top 20 by date, every row must be examined and sorted first.
> - High `Buffers` and a `actual rows=3000000` on the scan node feeding a `rows=20` result.
>
> **In the SECOND plan (after the index), look for:**
> - **The `Sort` node is GONE.** This is the entire point — watch for its *absence*.
> - **`Index Scan Backward using ix_btree_demo_signup`** (or forward, given the `DESC` index). PostgreSQL walks the leaf level, takes 20 entries, and stops.
> - **`Buffers`** measured in single or low double digits instead of hundreds of thousands.
> - The scan node's `actual rows=20`, not 3,000,000 — **`LIMIT` now genuinely limits the work done**, rather than limiting output after all the work.
>
> **Why this matters operationally:** "top N", "most recent", and paginated screens are everywhere in OLTP. Each one is a full sort unless an index provides the order. Sorts consume `work_mem` per concurrent query — so this optimization protects memory across the whole server, not just one query's latency.
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT id, signup_date FROM btree_demo ORDER BY signup_date DESC LIMIT 20;

CREATE INDEX ix_btree_demo_signup ON btree_demo (signup_date DESC);
ANALYZE btree_demo;

-- Now: walk 20 entries off the end of the index. No sort at all.
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT id, signup_date FROM btree_demo ORDER BY signup_date DESC LIMIT 20;
```

**Step 6 — the write cost, so the trade-off is honest**

> **👁 What to look for across this pair of plans — reading `EXPLAIN` on a write**
>
> `EXPLAIN ANALYZE` on an `UPDATE` **actually performs the update**. Run these inside a transaction you roll back if you want to repeat the lab.
>
> Both statements modify 50,000 rows. The first changes a **non-indexed** column; the second writes the same value back to an **indexed** column. Logically the second does nothing at all — yet it is measurably more expensive, and the plan shows why.
>
> | In the plan | What to compare |
> |---|---|
> | **`Buffers: shared ... dirtied=N`** | **The key metric for writes.** `dirtied` counts pages modified and therefore owed to disk. The second statement dirties **more** pages — the extra ones are **index leaf pages**. |
> | **`Buffers: shared ... written=N`** | Pages the backend flushed itself. Also expected to rise in the second case. |
> | **`actual time=`** on the `Update` node | The second statement is typically noticeably slower for identical logical work. |
> | **The `Update` node itself** | Both show `Update on btree_demo`. **The plan shape is identical — the cost difference lives entirely in the buffer counters.** That is precisely why `BUFFERS` is not optional. |
>
> **What is happening underneath:** in the first statement, no indexed column changed, so PostgreSQL can use a **HOT (Heap-Only Tuple)** update — the new row version goes on the same page and **no index is touched**. In the second, `email` is indexed, HOT is disabled, and every index on the table must receive a new entry pointing at the new `ctid`.
>
> **The lesson to state out loud:** an index is not a read-only optimization. Indexing a frequently-updated column silently disables HOT and taxes every write to that table, forever. Measure before you add.
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
UPDATE btree_demo SET lifetime_val = lifetime_val + 1 WHERE id BETWEEN 1 AND 50000;

-- Time an update that DOES touch an indexed column (every index must be maintained)
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
UPDATE btree_demo SET email = email WHERE id BETWEEN 50001 AND 100000;
```

> **Discussion:** the second statement writes the same logical data but must update index entries too. This is HOT being disabled. It is the concrete reason "just add an index" is never free.

---

# PART II — Index features shared by PostgreSQL and Oracle

Everything in this part exists in some form in Oracle. The syntax and the operational details differ; the concepts transfer.

---

## 4. Composite, unique, and covering indexes

### 4.1 Composite (multicolumn) indexes — and the leftmost-prefix rule

**Benefit:** one index satisfies a multi-predicate query, and can drive both filtering and ordering.
**Use case:** `WHERE tenant_id = ? AND status = ? ORDER BY created_at DESC` — extremely common in multi-tenant OLTP.

**The rule (identical to Oracle and SQL Server):** a B-tree can use a **leading prefix** of its column list. An index on `(a, b, c)` serves `a`, `(a,b)`, `(a,b,c)` — but **not** `b` alone or `(b,c)`.

```sql
SET search_path TO idxlab, public;

DROP TABLE IF EXISTS composite_demo;

CREATE TABLE composite_demo (
    id         bigserial PRIMARY KEY,
    tenant_id  int         NOT NULL,
    status     text        NOT NULL,
    created_at timestamptz NOT NULL,
    payload    text
);

INSERT INTO composite_demo (tenant_id, status, created_at, payload)
SELECT (random() * 500)::int + 1,
       (ARRAY['NEW','PROCESSING','SHIPPED','CANCELLED'])[1 + (g % 4)],
       now() - ((random() * 730) || ' days')::interval,
       repeat('p', 60)
FROM generate_series(1, 2000000) g;

ANALYZE composite_demo;
```

**Baseline:**

> **👁 What to look for in this plan**
>
> This query does three things at once — **two equality filters, a sort, and a limit** — and with no index, PostgreSQL must do all three the hard way.
>
> | In the plan | What it means |
> |---|---|
> | **`Limit`** at the top | Returns 50 rows — but look at the `actual rows` on the nodes *below* it to see how much work produced them. |
> | **`Sort`** with `Sort Key: created_at DESC` | The ordering is being computed at runtime. Check **`Sort Method:`** — `external merge  Disk:` means it spilled to temporary files. |
> | **`Seq Scan`** (or `Parallel Seq Scan`) | All 2,000,000 rows read. |
> | **`Filter: ((tenant_id = 42) AND (status = 'SHIPPED'))`** | Both predicates applied *after* reading. Neither is locating rows. |
> | **`Rows Removed by Filter:`** | Should be very close to 2,000,000 — the scale of wasted work. |
> | **`Buffers:`** | The full table's worth of pages. |
>
> **The subtle point worth drawing out:** even after filtering, PostgreSQL must sort **every matching row** before it can know which 50 are newest. The `LIMIT 50` saves nothing yet. A well-ordered composite index removes the scan *and* the sort in one move.
WHERE tenant_id = 42 AND status = 'SHIPPED'
ORDER BY created_at DESC
LIMIT 50;
```

**Column order matters — build both and compare:**

```sql
-- Good: equality columns first, then the ORDER BY column
CREATE INDEX ix_comp_good ON composite_demo (tenant_id, status, created_at DESC);
ANALYZE composite_demo;
```

> **👁 What to look for in the "good" plan**
>
> The column order `(tenant_id, status, created_at DESC)` matches the query exactly: equality, equality, then sort.
>
> | In the plan | What to confirm |
> |---|---|
> | **`Index Scan using ix_comp_good`** | The index is driving the query. |
> | **`Index Cond: ((tenant_id = 42) AND (status = 'SHIPPED'))`** | **Both** predicates appear in `Index Cond`. If one of them shows up as a separate `Filter:` line instead, your column order is wrong — the index narrowed on one column and then examined-and-discarded on the other. |
> | **NO `Sort` node** | The third index column already provides `created_at DESC` order *within* each `(tenant_id, status)` group, so the rows emerge pre-sorted. **The absence of `Sort` is the payoff for putting the ORDER BY column last.** |
> | **`actual rows=50`** on the index scan | PostgreSQL read exactly 50 index entries and stopped. `LIMIT` is now doing real work. |
> | **`Buffers:`** | A handful of pages — compare directly to the baseline. |

```sql
SELECT id, created_at FROM composite_demo
WHERE tenant_id = 42 AND status = 'SHIPPED'
ORDER BY created_at DESC LIMIT 50;

-- Poor: leading with the low-selectivity column, ORDER BY column stranded
CREATE INDEX ix_comp_poor ON composite_demo (status, created_at DESC, tenant_id);
ANALYZE composite_demo;

-- Force a comparison
SET enable_indexscan = on;
DROP INDEX ix_comp_good;
```

> **👁 What to look for in the "poor" plan — the same query, a worse index**
>
> Now only `ix_comp_poor (status, created_at DESC, tenant_id)` exists. `status` has just four values, so leading with it is leading with the **least** selective column.
>
> | In the plan | The tell |
> |---|---|
> | **`Index Cond: (status = 'SHIPPED')` only** | `tenant_id` has fallen out of the index condition. Because `created_at` sits *between* the two equality columns, the B-tree cannot skip ahead to a specific tenant — the leftmost-prefix rule stops at `status`. |
> | **`Filter: (tenant_id = 42)`** as a separate line | **This is the smoking gun.** PostgreSQL is now reading roughly 500,000 `SHIPPED` index entries, fetching each row, and discarding ~499,950 of them. |
> | **`Rows Removed by Filter:`** | A large number where the good plan had none. |
> | **`Buffers:`** | Far higher than the good plan — often by two orders of magnitude — despite "using an index" in both cases. |
> | Possible **`Sort`** node reappearing | Ordering may no longer be usable directly. |
>
> **The lesson:** "there is an index on those columns" is not the same as "there is a *usable* index". Both plans say `Index Scan`. Only `Index Cond` versus `Filter` reveals which one actually works — **this comparison is the best argument in the document for reading plans instead of trusting index lists.**

```sql
SELECT id, created_at FROM composite_demo
WHERE tenant_id = 42 AND status = 'SHIPPED'
ORDER BY created_at DESC LIMIT 50;
```

**Prove the leftmost-prefix rule:**

```sql
CREATE INDEX ix_comp_prefix ON composite_demo (tenant_id, status, created_at);
ANALYZE composite_demo;

-- USES the index (leading column present)
EXPLAIN (COSTS OFF) SELECT count(*) FROM composite_demo WHERE tenant_id = 42;

-- Usually does NOT use it efficiently (leading column absent)
EXPLAIN (COSTS OFF) SELECT count(*) FROM composite_demo WHERE status = 'SHIPPED';
```

> **👁 What to look for across these two plans**
>
> Note these use **`EXPLAIN (COSTS OFF)` without `ANALYZE`** — the queries are not executed. That is deliberate: here you only care **which access path the planner chooses**, not how fast it runs. Use this cheap form when the question is "will my index be used?"
>
> **First query (`WHERE tenant_id = 42`) — the leading column:**
> - Expect **`Index Only Scan`** or `Bitmap Index Scan` on `ix_comp_prefix`.
> - **`Index Cond: (tenant_id = 42)`** — the B-tree descends straight to the right subtree.
> - This works because `tenant_id` is the **first** column: the index is sorted by it, so all matching entries are contiguous.
>
> **Second query (`WHERE status = 'SHIPPED'`) — a non-leading column:**
> - Expect **`Seq Scan`** with `Filter: (status = 'SHIPPED')`.
> - **Why:** the index is sorted by `tenant_id` first. All the `SHIPPED` rows are scattered across all 500 tenants' sections of the index. There is no contiguous range to scan.
> - **If you instead see a `Bitmap Index Scan`**, PostgreSQL chose a **full index scan** — reading every entry because the index is still narrower than the heap. That is a consolation prize, not a win: watch for `Rows Removed by Filter` and a high buffer count confirming it read the whole index.
>
> **The mental model to hand your audience:** a composite index is a phone book sorted by *(last name, first name)*. Searching for a last name is instant. Searching for a first name means reading the entire book.

**Design guidance:** equality predicates first, then range/sort columns. Order the equality columns by how often they appear in queries, not purely by cardinality.

### 4.2 Unique indexes

**Benefit:** enforces a business rule in the engine *and* gives the planner a "at most one row" guarantee, which produces better plans.
**Use case:** natural keys — email, order number, tax ID.

```sql
CREATE UNIQUE INDEX ux_btree_demo_email ON btree_demo (email);

-- Proves enforcement
INSERT INTO btree_demo (email, last_name, signup_date, country, lifetime_val)
VALUES ('user1@example.com','Dup', now(), 'US', 0);   -- ERROR: duplicate key
```

> **NULL behavior — a real difference from SQL Server.** PostgreSQL unique indexes treat `NULL`s as distinct, so **multiple NULLs are allowed** (SQL Server allows only one). From PG 15 you can request the SQL Server behavior explicitly:
> ```sql
> CREATE UNIQUE INDEX ux_demo ON t (col) NULLS NOT DISTINCT;
> ```

### 4.3 Covering indexes with `INCLUDE` — and index-only scans

**Benefit:** the query is answered **entirely from the index**, with no heap fetch at all. `INCLUDE` columns are stored only in the leaf level, so they add payload without bloating the tree or affecting uniqueness.

**Use case:** a hot query that filters on one or two columns and returns a few more — the classic SQL Server "covering index" pattern, available in PostgreSQL 11+ for B-tree.

```sql
SET search_path TO idxlab, public;

-- Filter on country, return lifetime_val
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT country, sum(lifetime_val)
FROM btree_demo
WHERE country = 'BR'
GROUP BY country;
```

> **👁 What to look for in this baseline plan**
>
> `country` has only six values, so **one sixth of the table** (~500,000 rows) matches. This is deliberately *not* a selective query — it is the shape where a plain index usually loses to a sequential scan, and where a covering index shines.
>
> | In the plan | What it means |
> |---|---|
> | **`Seq Scan`** (most likely) | With 1-in-6 selectivity, the planner calculates that random heap access for 500,000 rows costs more than reading the table sequentially. **This is correct reasoning — note that "the index wasn't used" is not always a bug.** |
> | **`Filter: (country = 'BR'::bpchar)`** | Rows read, then discarded. |
> | **`Aggregate` / `GroupAggregate`** | The `sum()` being computed. |
> | **`Buffers:`** | The whole table — tens of thousands of pages, because the heap rows carry `email`, `last_name`, `signup_date` and everything else, even though the query needs only two columns. |
>
> **Fix the idea of "row width" in the room here:** the query needs 2 columns; the heap forces PostgreSQL to read pages containing all 6. That wasted width is exactly what the covering index eliminates.

```sql
-- Covering index: key = country, payload = lifetime_val
CREATE INDEX ix_btree_demo_cover
    ON btree_demo (country) INCLUDE (lifetime_val);
ANALYZE btree_demo;
```

> **👁 What to look for in the covering-index plan — and the one line that can betray you**
>
> | In the plan | What to confirm |
> |---|---|
> | **`Index Only Scan using ix_btree_demo_cover`** | The words **"Only"** are the whole point. `Index Scan` = index + heap. **`Index Only Scan` = index alone.** If you see plain `Index Scan`, the index is not covering the query — some referenced column is missing from it. |
> | **`Index Cond: (country = 'BR')`** | Rows located, not filtered. |
> | **`Heap Fetches: 0`** ← **read this line every single time** | The number of times PostgreSQL had to visit the heap *anyway*. **`0` means the optimization fully worked.** A large number means it silently degraded to an ordinary index scan plus random heap I/O — while still saying "Index Only Scan" at the top. |
> | **`Buffers:`** | Should drop sharply versus the baseline. The index holds only `country` + `lifetime_val`, so far more rows fit per page than in the heap. |
>
> **If `Heap Fetches` is high, the index is not at fault — the visibility map is.** After bulk loading or heavy updates, pages are not yet marked all-visible, so PostgreSQL cannot trust the index alone and must confirm visibility in the heap. Run `VACUUM (ANALYZE)` (see the callout immediately below) and re-run.
>
> **This is a PostgreSQL-only failure mode.** Neither Oracle nor SQL Server has an equivalent — their covering indexes do not depend on vacuum state. It is the most common reason a covering index "works in the lab and not in production".

```sql
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT country, sum(lifetime_val)
FROM btree_demo
WHERE country = 'BR'
GROUP BY country;
```

Look for **`Index Only Scan`** and a `Heap Fetches:` line.

> ⚠️ **The PostgreSQL-specific catch nobody warns you about: `Heap Fetches`.**
> An index-only scan still consults the **visibility map** to confirm a row is visible to all transactions. If the table has been written to recently and not vacuumed, the visibility map is not set and PostgreSQL **must visit the heap anyway** — your index-only scan silently degrades.
>
> ```sql
> VACUUM (ANALYZE) btree_demo;      -- sets the visibility map
>
> EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
> SELECT country, sum(lifetime_val) FROM btree_demo WHERE country = 'BR' GROUP BY country;
> -- Heap Fetches should now be 0 (or near it)
> ```
>
> **A covering index on a write-heavy table needs aggressive autovacuum to keep delivering its benefit.** This has no Oracle or SQL Server equivalent — it is pure PostgreSQL MVCC.

---

## 5. Expression indexes (Oracle: function-based indexes)

### 5.1 Concept and benefit

Index the **result of an expression** rather than a raw column. Oracle calls these function-based indexes; the semantics are the same.

**Benefit:** makes a predicate that would otherwise be non-sargable — `WHERE lower(email) = ...`, `WHERE date_trunc('day', ts) = ...` — fully indexable.

**Use case:** case-insensitive lookup, computed keys, extracting a JSON field, date truncation for daily reporting.

> **The rule:** the indexed expression must appear in the query **exactly as written in the index definition**. `lower(email)` in the index serves `WHERE lower(email) = $1`; it does **not** serve `WHERE email ILIKE $1`.

### 5.2 Demo

```sql
SET search_path TO idxlab, public;

-- Non-sargable: the function defeats a plain index on email
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT id FROM btree_demo WHERE lower(email) = 'user2500000@example.com';
```

> **👁 What to look for in this plan — "non-sargable" made visible**
>
> An ordinary B-tree on `email` **already exists** from §3. Watch it be completely ignored.
>
> | In the plan | What it means |
> |---|---|
> | **`Seq Scan`** despite an index on `email` | The index stores `email` values as written: `'User1@Example.com'`. The query asks for rows where `lower(email)` equals something. **PostgreSQL cannot use a sorted structure to answer a question about a transformed value** — the sort order of `email` tells it nothing about the sort order of `lower(email)`. |
> | **`Filter: (lower(email) = '...'::text)`** | The function is evaluated **once per row**, 3,000,000 times. You are paying for both the scan *and* three million function calls. |
> | **`Rows Removed by Filter:`** | ~2,999,999. |
> | **`Buffers:`** | The entire table. |
>
> **"Sargable" = Search-ARGument-able.** The rule transfers directly from Oracle and SQL Server: **wrapping an indexed column in a function disables the index on that column.** The difference is the remedy — PostgreSQL lets you simply index the function's output.

```sql
-- Expression index
CREATE INDEX ix_btree_demo_lower_email ON btree_demo (lower(email));
ANALYZE btree_demo;
```

> **👁 What to look for now**
>
> | In the plan | What to confirm |
> |---|---|
> | **`Index Scan using ix_btree_demo_lower_email`** | The **expression** index is used — not the plain `email` index, which remains unusable for this query. |
> | **`Index Cond: (lower(email) = '...'::text)`** | **Look closely: the function appears inside `Index Cond`, not `Filter`.** That is the whole demonstration. PostgreSQL pre-computed `lower(email)` for every row *at index build time* and stored the results sorted, so at query time it evaluates the function **once** — on your search argument — and descends the tree. |
> | **`Buffers:`** | Back to a handful of pages. |
> | **`Rows Removed by Filter`** | Gone. |
>
> **The matching rule to stress:** the expression in the query must match the index definition **textually**. `lower(email)` in both places works. `upper(email)`, `email ILIKE ...`, or `lower(trim(email))` would each fall back to a `Seq Scan` — the planner does no algebraic rewriting to bridge the gap.

```sql
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT id FROM btree_demo WHERE lower(email) = 'user2500000@example.com';
```

**Date truncation — the reporting workhorse:**

> **👁 What to look for across this pair of plans**
>
> This is the single most common real-world expression index — "give me everything from one day" on a `timestamptz` column.
>
> **BEFORE (first plan):**
> - **`Seq Scan`** with **`Filter: (date_trunc('day', signup_date) = ...)`** — note that an index on `signup_date` itself, which also exists, is useless here for exactly the reason above.
> - `date_trunc` evaluated 3,000,000 times.
> - Full-table `Buffers`.
>
> **AFTER (second plan):**
> - **`Index Scan`** (or `Bitmap Index Scan` — a day's worth of rows may be numerous enough that the planner prefers bitmap collection) **`using ix_btree_demo_signup_day`**.
> - **`Index Cond: (date_trunc('day', signup_date) = ...)`** — the expression has moved from `Filter` to `Index Cond`.
> - `Buffers` drops to roughly the number of pages holding that day's rows.
>
> **Two things worth pointing out while the plans are on screen:**
> 1. **Bitmap vs plain Index Scan is not a failure.** When ~2,000 rows match, collecting `ctid`s and fetching them in physical order is genuinely cheaper than 2,000 random seeks. The planner switching between the two is it doing its job.
> 2. **`now()` is allowed on the query side, never on the index side.** Here `now()` appears only in the search argument, which is fine — it is evaluated once per query. Putting a non-`IMMUTABLE` function inside the index definition is what PostgreSQL rejects, and for good reason (see the warning below).
>
> **The better alternative when you control the query:** `WHERE signup_date >= $1 AND signup_date < $1 + interval '1 day'` is sargable against a plain index on `signup_date` and needs no expression index at all. Reach for the expression index when you cannot change the SQL — packaged applications, ORMs, reporting tools.

```sql
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT count(*) FROM btree_demo
WHERE date_trunc('day', signup_date) = date_trunc('day', now() - interval '30 days');

CREATE INDEX ix_btree_demo_signup_day ON btree_demo (date_trunc('day', signup_date));
ANALYZE btree_demo;

EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT count(*) FROM btree_demo
WHERE date_trunc('day', signup_date) = date_trunc('day', now() - interval '30 days');
```

> ⚠️ **Only `IMMUTABLE` functions can be indexed.** `now()` and `current_date` are not immutable. A common workaround — wrapping a `STABLE` function in a fake `IMMUTABLE` wrapper — produces **silently corrupt index results**. Do not do it.
>
> **Bonus:** PostgreSQL gathers separate statistics for an expression index, which often improves cardinality estimates for that expression — a side benefit Oracle DBAs will recognize from extended statistics.

---

## 6. Hash indexes

### 6.1 Concept and benefit

Stores a 32-bit hash of the value. Supports **`=` only** — no ranges, no ordering, no `ORDER BY` support, no uniqueness enforcement, no multicolumn.

**Benefit:** for **long** values, the index stores a small hash rather than the full key, so it can be meaningfully smaller than the equivalent B-tree and deliver faster equality probes.

**Use case:** equality-only lookup on long text — a URL, a file path, a long token, a session key.

> **History matters here:** before PostgreSQL 10, hash indexes were **not WAL-logged** — they did not survive a crash and were not replicated. That era produced the "never use hash indexes" folklore. **Since PG 10 they are crash-safe and replicated.** They remain niche, but they are no longer dangerous.

### 6.2 Demo — where hash actually wins

```sql
SET search_path TO idxlab, public;

DROP TABLE IF EXISTS hash_demo;

CREATE TABLE hash_demo (
    id       bigserial PRIMARY KEY,
    long_url text NOT NULL,
    hits     int  NOT NULL DEFAULT 0
);

-- Deliberately long keys -- this is the scenario where hash pays
INSERT INTO hash_demo (long_url, hits)
SELECT 'https://www.example.com/catalog/department/' || (g % 100)
       || '/category/' || (g % 1000)
       || '/product/' || g
       || '?utm_source=demo&utm_campaign=indexlab&session=' || md5(g::text),
       (random() * 1000)::int
FROM generate_series(1, 2000000) g;

ANALYZE hash_demo;
```

**Compare the two index types on the same column:**

```sql
CREATE INDEX ix_hash_demo_btree ON hash_demo USING btree (long_url);
CREATE INDEX ix_hash_demo_hash  ON hash_demo USING hash  (long_url);
ANALYZE hash_demo;

-- SIZE comparison -- the headline benefit
SELECT indexrelname,
       pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes
WHERE schemaname='idxlab' AND relname='hash_demo'
ORDER BY pg_relation_size(indexrelid) DESC;
```

**Measure equality lookup with each:**

> **👁 What to look for across this pair of plans**
>
> The two runs below are the same equality query, executed once with **only** a B-tree available and once with **only** a hash index available — which is why each block drops the other index first. That isolation matters: leave both in place and the planner picks one, and you learn nothing.
>
> | In the plan | What to compare |
> |---|---|
> | Node name: **`Index Scan using ix_hash_demo_btree`** vs **`Index Scan using ix_hash_demo_hash`** | Confirms which structure served the query. Always verify — it is easy to think you dropped an index and did not. |
> | **`Index Cond: (long_url = '...'::text)`** | Identical text in both. **The plans look nearly the same; the difference is in the work behind the line.** |
> | **`Buffers: shared hit=N`** | **The comparison that matters.** The B-tree descends root → internal → leaf, comparing your ~140-character URL at each level. The hash index computes one 32-bit hash and goes almost straight to a bucket. Expect the hash path to touch the same or fewer pages. |
> | **`actual time=`** | Usually comparable, sometimes slightly better for hash. **Do not oversell the speed difference** — on this workload the real hash win is *size*, which you measured in the previous step. |
>
> **Why key length is the deciding factor:** a B-tree stores the **entire** 140-character URL in every leaf entry *and* in internal nodes. A hash index stores a **4-byte hash**. On short keys (an `int`, a short code) this advantage evaporates and B-tree wins outright on flexibility. Hash only earns its place when keys are long and the access pattern is strictly equality.

```sql
-- Capture a real value to search for
SELECT long_url FROM hash_demo WHERE id = 1234567 \gset

-- Force B-tree
DROP INDEX ix_hash_demo_hash;
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT id, hits FROM hash_demo WHERE long_url = :'long_url';

-- Force hash
CREATE INDEX ix_hash_demo_hash ON hash_demo USING hash (long_url);
DROP INDEX ix_hash_demo_btree;
ANALYZE hash_demo;

EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT id, hits FROM hash_demo WHERE long_url = :'long_url';
```

**Prove the limitation — the reason hash is not a default:**

> **👁 What to look for — you are looking for the index to be IGNORED**
>
> Both plans below use `EXPLAIN (COSTS OFF)` without `ANALYZE` — you only need to see the chosen access path, and the second query would otherwise sort millions of rows.
>
> **Query 1 — the range predicate (`long_url > '...'`):**
> - Expect **`Seq Scan`** with **`Filter: (long_url > '...')`**.
> - **Why:** a hash index stores hashes, and hashing destroys ordering by design — two adjacent strings hash to unrelated buckets. **There is no possible way to answer "greater than" from a hash structure.** This is not a planner choice or a costing decision; it is a hard structural limit.
>
> **Query 2 — `ORDER BY long_url LIMIT 10`:**
> - Expect **`Limit` → `Sort`** (with `Sort Key: long_url`) **→ `Seq Scan`**.
> - **Why:** same reason. A hash index cannot return rows in key order, so PostgreSQL must read everything and sort. Contrast this with §3 Step 5, where a B-tree eliminated the `Sort` node entirely.
>
> **Say this plainly to the room:** a B-tree serves equality, ranges, ordering, prefix matching, and uniqueness. A hash index serves **one** of those five. That is why B-tree is the default and hash is a deliberate, narrow optimization — not because hash indexes are unsafe (they have been crash-safe and replicated since PG 10).

```sql
-- Range predicate: hash index CANNOT serve this
EXPLAIN (COSTS OFF)
SELECT count(*) FROM hash_demo WHERE long_url > 'https://www.example.com/catalog/department/50';

-- ORDER BY: hash index CANNOT serve this either
EXPLAIN (COSTS OFF)
SELECT id FROM hash_demo ORDER BY long_url LIMIT 10;
```

**Verdict:** typically a meaningful size saving on long keys, with comparable or slightly better equality performance — but it serves exactly one access pattern. **Default to B-tree; choose hash deliberately.**

```sql
DROP TABLE hash_demo;
```

---

## 7. Partial indexes (Oracle's closest analogue: a function-based index on a `CASE`)

### 7.1 Concept and benefit

An index with a `WHERE` clause — it indexes **only the rows that match**.

**Benefit:** dramatically smaller index, dramatically cheaper maintenance (rows outside the predicate cost nothing on write), and often a better plan because the index is denser.

**Use case — the classic:** a queue/status table where 99.9% of rows are `COMPLETED` and every query asks for the tiny `PENDING` set. Also: "active" flags, soft-delete patterns (`WHERE deleted_at IS NULL`), and enforcing conditional uniqueness.

> Oracle does not have true partial indexes on heap tables (partial indexing there applies to partitioned tables); the usual Oracle trick is a function-based index returning `NULL` for unwanted rows, since Oracle B-trees do not store all-NULL keys. **PostgreSQL's version is explicit, readable, and more powerful.**

### 7.2 Demo — the queue table

```sql
SET search_path TO idxlab, public;

DROP TABLE IF EXISTS queue_demo;

CREATE TABLE queue_demo (
    id           bigserial PRIMARY KEY,
    status       text        NOT NULL,
    priority     int         NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    processed_at timestamptz,
    payload      text
);

-- 5,000,000 rows: 99.9% COMPLETED, ~0.1% PENDING -- a realistic queue
INSERT INTO queue_demo (status, priority, created_at, processed_at, payload)
SELECT CASE WHEN g % 1000 = 0 THEN 'PENDING' ELSE 'COMPLETED' END,
       (random() * 10)::int,
       now() - ((random() * 365) || ' days')::interval,
       CASE WHEN g % 1000 = 0 THEN NULL ELSE now() END,
       repeat('q', 50)
FROM generate_series(1, 5000000) g;

ANALYZE queue_demo;

SELECT status, count(*) FROM queue_demo GROUP BY status;
```

**Step 1 — full index (what most people build):**

> **👁 What to look for in this plan**
>
> This is the index most teams create, and it **works** — the query will be fast. The point of this step is not that it fails; it is to establish what it **costs**, so Step 2's comparison is fair.
>
> | In the plan | What to note |
> |---|---|
> | **`Index Scan using ix_queue_full`** | The index is used, and `Index Cond: (status = 'PENDING')` locates the rows. |
> | **Possible `Sort` node** | The index is ordered `(status, priority ASC, created_at)`, but the query wants `priority DESC`. Depending on version and costing, PostgreSQL may add a `Sort`, or scan backward. **Watch for `Sort` — it signals a mismatch between index order and `ORDER BY` direction.** |
> | **`actual rows=10`** at the top, with a larger count on the scan node | How many index entries were walked to produce 10 results. |
> | **`Buffers:`** | Modest — the index works. **Record it anyway**, because Step 2 will be lower still. |
>
> **The real cost is not in this plan at all.** Run the `pg_size_pretty` query that follows: this index contains an entry for **all 5,000,000 rows**, including the 4,995,000 `COMPLETED` rows nobody ever queries. You are paying storage for them, and paying index-maintenance cost on every single insert of a row you will never look up through this index. **That invisible cost is what Step 2 eliminates.**

```sql
CREATE INDEX ix_queue_full ON queue_demo (status, priority, created_at);
ANALYZE queue_demo;

EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT id, payload FROM queue_demo
WHERE status = 'PENDING'
ORDER BY priority DESC, created_at
LIMIT 10;

SELECT pg_size_pretty(pg_relation_size('ix_queue_full')) AS full_index_size;
```

**Step 2 — partial index (what you should build):**

```sql
CREATE INDEX ix_queue_partial ON queue_demo (priority DESC, created_at)
WHERE status = 'PENDING';
ANALYZE queue_demo;

DROP INDEX ix_queue_full;
```

> **👁 What to look for in the partial-index plan**
>
> | In the plan | What to confirm |
> |---|---|
> | **`Index Scan using ix_queue_partial`** | The partial index was chosen. **If you see `Seq Scan` instead, the planner could not prove your `WHERE` clause implies the index predicate** — see the warning below. |
> | **`status = 'PENDING'` is ABSENT from `Index Cond`** | **This is the signature of a partial index, and it surprises people.** The condition does not need to be checked — *every entry in the index already satisfies it by construction*. The predicate was applied once, at index-build time, not per row. |
> | **No `Sort` node** | The index is ordered `(priority DESC, created_at)`, matching the `ORDER BY` exactly. |
> | **`Buffers:`** | Should be lower than Step 1 — the whole index is a few pages, so the tree is shallower and more of it stays cached. |
> | **`actual rows=10`** | Same result, less work. |
>
> **Then compare the two `pg_size_pretty` outputs — that is the headline.** Roughly 1/1000th the size. But the storage saving is the *lesser* benefit: the real win is that **inserting a `COMPLETED` row now touches this index zero times.** On a queue processing millions of rows a day, that is a permanent reduction in write amplification, WAL volume, and vacuum pressure.
>
> **Diagnosing "my partial index isn't being used":** the planner must *prove* the query predicate implies the index predicate. A literal `WHERE status = 'PENDING'` proves it. A parameterized `WHERE status = $1` generally does not, because the value is unknown at planning time under a generic plan. Test with the exact SQL your application emits — not a hand-typed version of it.

```sql
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT id, payload FROM queue_demo
WHERE status = 'PENDING'
ORDER BY priority DESC, created_at
LIMIT 10;

SELECT pg_size_pretty(pg_relation_size('ix_queue_partial')) AS partial_index_size;
```

**Expected result:** the partial index is roughly **1/1000th the size** (kilobytes vs hundreds of megabytes) and serves the query at least as fast. The write-path saving is just as important: inserting a `COMPLETED` row touches this index **not at all**.

**Step 3 — conditional uniqueness, a genuinely useful pattern:**

```sql
-- "Only one ACTIVE subscription per customer" -- unlimited CANCELLED rows allowed
DROP TABLE IF EXISTS subs_demo;
CREATE TABLE subs_demo (
    id          bigserial PRIMARY KEY,
    customer_id int  NOT NULL,
    state       text NOT NULL
);

CREATE UNIQUE INDEX ux_subs_one_active
    ON subs_demo (customer_id)
    WHERE state = 'ACTIVE';

INSERT INTO subs_demo (customer_id, state) VALUES (1,'CANCELLED'),(1,'CANCELLED'),(1,'ACTIVE');  -- OK
INSERT INTO subs_demo (customer_id, state) VALUES (1,'ACTIVE');                                   -- ERROR
```

> ⚠️ **The predicate must be provably implied by the query.** The planner uses a partial index only when it can prove the query's `WHERE` clause implies the index predicate. `WHERE status = 'PENDING'` matches. `WHERE status = $1` with a parameter usually does **not** — a frequent production surprise. Test with the actual parameterized query shape your application sends.

---

## 8. Full-text search indexes (Oracle: Oracle Text / CONTEXT indexes)

### 8.1 Concept and benefit

PostgreSQL has full-text search built into the core: `tsvector` (parsed document) and `tsquery` (parsed query), indexed with **GIN**.

**Benefit:** ranked, stemmed, language-aware search on text — no separate search product needed for moderate volumes.

**Use case:** product descriptions, support tickets, knowledge base articles, document bodies.

### 8.2 Demo

```sql
SET search_path TO idxlab, public;

DROP TABLE IF EXISTS fts_demo;

CREATE TABLE fts_demo (
    id      bigserial PRIMARY KEY,
    title   text NOT NULL,
    body    text NOT NULL
);

INSERT INTO fts_demo (title, body)
SELECT 'Support ticket ' || g,
       (ARRAY[
         'The database connection pool is exhausted during peak hours and queries time out.',
         'Backup job failed with insufficient storage on the target volume.',
         'User reports slow performance when running monthly reconciliation reports.',
         'Migration from Oracle to PostgreSQL completed successfully with no data loss.',
         'Index bloat detected on the orders table causing degraded query performance.',
         'Replication lag exceeded threshold after the bulk load operation.'
       ])[1 + (g % 6)] || ' Reference ' || g
FROM generate_series(1, 1000000) g;

ANALYZE fts_demo;
```

**Step 1 — baseline with `LIKE` (slow and semantically poor):**

> **👁 What to look for in this plan**
>
> | In the plan | What it means |
> |---|---|
> | **`Seq Scan on fts_demo`** | Every one of the 1,000,000 rows is read. |
> | **`Filter: (body ~~ '%performance%'::text)`** | `~~` is PostgreSQL's internal operator name for `LIKE`. **The leading `%` makes this unindexable by any B-tree** — a sorted structure can find *prefixes*, never *infixes*. This is equally true in Oracle and SQL Server. |
> | **`Rows Removed by Filter:`** | Large — every non-matching row was read and discarded. |
> | **`Buffers:`** | The entire table. |
> | **`actual time=`** | Record it for comparison with Step 3. |
>
> **Beyond the performance problem, note what this query cannot do — it is the weaker half of the argument but the more important one:** `LIKE '%performance%'` matches the substring "performance" and nothing else. It will **not** match "performing", "performed", or "perform". It cannot rank results by relevance, cannot express "A and B but not C", and will happily match the middle of an unrelated word. Full-text search solves the *semantics*; the index solves the *speed*.

```sql
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT id, title FROM fts_demo WHERE body LIKE '%performance%' LIMIT 20;
```

**Step 2 — generated `tsvector` column + GIN index:**

```sql
ALTER TABLE fts_demo
    ADD COLUMN search_vec tsvector
    GENERATED ALWAYS AS (
        to_tsvector('english', coalesce(title,'') || ' ' || coalesce(body,''))
    ) STORED;

CREATE INDEX ix_fts_demo_gin ON fts_demo USING gin (search_vec);
ANALYZE fts_demo;
```

**Step 3 — measure:**

> **👁 What to look for in this plan — and why it has two index-related nodes**
>
> GIN plans look different from B-tree plans. Expect a **two-node structure**:
>
> | In the plan | What it means |
> |---|---|
> | **`Bitmap Index Scan on ix_fts_demo_gin`** (inner node) | GIN is being searched. **`Index Cond: (search_vec @@ to_tsquery(...))`** confirms the match operator `@@` is driving the lookup. GIN returns an unordered *set* of matching rows, which is why it feeds a bitmap rather than a direct scan. |
> | **`Bitmap Heap Scan on fts_demo`** (outer node) | The `ctid`s collected above are sorted into physical order, then the heap pages are visited **once each, in order**. **This is why GIN plans are almost always bitmap plans** — it converts random I/O into near-sequential I/O. |
> | **`Heap Blocks: exact=N`** | How many heap pages were actually touched. |
> | **`Recheck Cond:`** | Present on most bitmap plans. If **`Rows Removed by Index Recheck: 0`**, no false positives occurred. GIN is an *exact* index, so a nonzero value here usually means the bitmap became **lossy** (it ran out of `work_mem` and degraded to page-level granularity) — a signal to raise `work_mem` for this workload. |
> | **`Buffers:`** | Should be a small fraction of Step 1. |
>
> **Do not be alarmed that this is not an `Index Scan`.** "Bitmap" is not a downgrade here; for a multi-row match it is the optimal access pattern, and it is the same machinery §14.1 uses to replace Oracle's bitmap indexes.

```sql
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT id, title
FROM fts_demo
WHERE search_vec @@ to_tsquery('english', 'performance')
LIMIT 20;
```

**Step 4 — the capabilities `LIKE` cannot provide:**

```sql
-- Boolean logic + stemming ("degraded"/"degrade" both match "degrad")
SELECT id, title
FROM fts_demo
WHERE search_vec @@ to_tsquery('english', 'index & bloat & !replication')
LIMIT 10;

-- Phrase search (<-> = immediately followed by)
SELECT id, title
FROM fts_demo
WHERE search_vec @@ to_tsquery('english', 'connection <-> pool')
LIMIT 10;

-- Relevance ranking
SELECT id, title, ts_rank(search_vec, q) AS rank
FROM fts_demo, to_tsquery('english','database & performance') q
WHERE search_vec @@ q
ORDER BY rank DESC
LIMIT 10;
```

> **Talking point for Oracle DBAs:** this is Oracle Text without the separate index type, the `CTX_DDL` packages, or the manual index synchronization. The `GENERATED ALWAYS AS ... STORED` column keeps the vector current automatically — no sync job.

---

# PART III — Index types unique to PostgreSQL

Nothing in this part has a direct Oracle or SQL Server equivalent. These are the reasons teams choose PostgreSQL for workloads that would otherwise need a second specialized datastore.

---

## 9. GIN — Generalized Inverted Index

### 9.1 Concept and benefit

GIN indexes **composite values**: it stores each *element* inside a value, mapped to the list of rows containing it. An inverted index, in the search-engine sense.

**Benefit:** makes "does this container hold X?" fast — for arrays, JSONB, full-text, and trigrams. There is **no B-tree formulation** of these queries.

**Use case:** JSONB document filtering, tag/array membership, full-text search (§8), and **substring search with `pg_trgm`** — the `LIKE '%middle%'` problem that no B-tree can solve in any database.

### 9.2 Demo A — JSONB containment

```sql
SET search_path TO idxlab, public;

DROP TABLE IF EXISTS gin_demo;

CREATE TABLE gin_demo (
    id      bigserial PRIMARY KEY,
    doc     jsonb NOT NULL,
    tags    text[] NOT NULL
);

INSERT INTO gin_demo (doc, tags)
SELECT jsonb_build_object(
         'customer', jsonb_build_object(
             'id', (random()*10000)::int,
             'tier', (ARRAY['bronze','silver','gold','platinum'])[1+(g%4)],
             'region', (ARRAY['us-east','eu-west','apac','latam'])[1+(g%4)]),
         'order', jsonb_build_object(
             'total', (random()*5000)::numeric(10,2),
             'items', (random()*20)::int + 1,
             'status', (ARRAY['new','paid','shipped','refunded'])[1+(g%4)]),
         'flags', jsonb_build_array(
             CASE WHEN g % 7  = 0 THEN 'priority'  ELSE 'standard' END,
             CASE WHEN g % 13 = 0 THEN 'gift_wrap' ELSE 'plain'    END)),
       ARRAY[(ARRAY['electronics','books','garden','toys','apparel'])[1+(g%5)],
             (ARRAY['sale','clearance','new_arrival'])[1+(g%3)]]
FROM generate_series(1, 1000000) g;

ANALYZE gin_demo;
```

**Baseline:**

> **👁 What to look for in this plan**
>
> | In the plan | What it means |
> |---|---|
> | **`Seq Scan on gin_demo`** | All 1,000,000 JSONB documents read. |
> | **`Filter: (doc @> '{"customer": {"tier": "platinum"}}'::jsonb)`** | **The critical detail: `@>` (containment) is not just a comparison — it is a structural search *inside* each document.** For every row, PostgreSQL must parse the JSONB and walk its tree looking for a matching path. This is far more expensive per row than an integer comparison. |
> | **`Rows Removed by Filter:`** | ~750,000 — three quarters of the table examined and discarded. |
> | **`Buffers:`** | High, and made worse by JSONB rows being wide. |
> | **`actual time=`** | Note it. The per-row cost of document parsing is what makes this baseline so slow relative to a simple column filter. |
>
> **Why no B-tree could help here:** a B-tree indexes a *whole value* as a single sortable key. `doc` as a whole has no useful ordering, and the query does not ask about the whole document — it asks whether one **element** exists somewhere inside it. That is a fundamentally different question, and it needs an **inverted** index: one that maps each contained element back to the rows containing it.

**Two GIN flavors — know the difference:**

```sql
-- Default opclass: supports @>, ?, ?|, ?&, and path/value operators. Larger.
CREATE INDEX ix_gin_doc ON gin_demo USING gin (doc);

-- jsonb_path_ops: containment (@>) ONLY -- smaller and faster for that operator.
CREATE INDEX ix_gin_doc_path ON gin_demo USING gin (doc jsonb_path_ops);

ANALYZE gin_demo;

SELECT indexrelname, pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes
WHERE schemaname='idxlab' AND relname='gin_demo'
ORDER BY pg_relation_size(indexrelid) DESC;
```

> **👁 What to look for across this pair of plans — the opclass comparison**
>
> **First query (`doc @> ...`) — both indexes can serve it:**
> - Expect **`Bitmap Index Scan`** naming **`ix_gin_doc_path`** (the `jsonb_path_ops` index). **Which index name appears is the result you came for** — the planner chose the smaller, containment-specialized one over the general-purpose index. Compare against the size query you just ran.
> - **`Index Cond: (doc @> '...'::jsonb)`** — the containment operator is driving the lookup, not filtering after the fact.
> - **`Bitmap Heap Scan`** above it, with **`Recheck Cond:`**. Watch **`Rows Removed by Index Recheck`** — `jsonb_path_ops` hashes entire paths, so a small number of false positives here is normal and expected.
> - **`Buffers:`** should be a fraction of the baseline.
>
> **Second query (`doc ? 'flags'`) — only ONE index can serve it:**
> - Expect **`Bitmap Index Scan on ix_gin_doc`** — the **default** opclass index.
> - **Why the difference matters:** `jsonb_path_ops` stores a hash of each complete *path-plus-value*. It therefore cannot answer "does key `flags` exist at all?", because that question names no value. The default opclass indexes keys and values separately and can.
> - **If you had built only `jsonb_path_ops`, this query would be a `Seq Scan`.** That is the trade-off in one line: smaller and faster, but strictly containment-only.
>
> **The design decision to take away:** if every JSONB query you run uses `@>`, build `jsonb_path_ops` and enjoy the smaller index. If your application also uses `?`, `?|`, or `?&`, you need the default opclass — or both.

```sql
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT count(*) FROM gin_demo
WHERE doc @> '{"customer": {"tier": "platinum"}}';

-- Key-existence operator: served by the DEFAULT opclass, NOT by jsonb_path_ops
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT count(*) FROM gin_demo WHERE doc ? 'flags';
```

### 9.3 Demo B — array membership

> **👁 What to look for across these three plans**
>
> **Plan 1 — before the index:** `Seq Scan` with **`Filter: (tags @> '{clearance}'::text[])`**. For every row, PostgreSQL unpacks the array and scans its elements. Note the `Rows Removed by Filter` count and the buffer total.
>
> **Plan 2 — after the index, `@>` (contains):**
> - **`Bitmap Index Scan on ix_gin_tags`** with **`Index Cond: (tags @> '{clearance}')`**.
> - **What GIN did structurally:** it stored *each individual tag* as a key, mapped to the list of rows containing it. Finding `'clearance'` is now a single key lookup returning a ready-made row list — exactly like a book index entry listing page numbers.
> - `Buffers` collapses versus Plan 1.
>
> **Plan 3 — the `&&` (overlap) query, "any of these tags":**
> - Still **`Bitmap Index Scan`**, now with **`Index Cond: (tags && '{garden,toys}')`**.
> - **The point of including this one:** GIN looked up *two* keys and **unioned** their row lists internally — one index scan, not two. Watch that the plan does **not** contain a `BitmapOr` node; the union happened inside GIN itself.
> - Compare `actual rows` against Plan 2 — more rows match, yet the access cost stays proportionate.
>
> **Why this is structurally impossible for a B-tree:** a B-tree would index the array *as a single value*, sorted by its full contents. `['garden','sale']` and `['toys','garden']` sort to completely unrelated positions, so there is no contiguous range to scan for "contains garden". Inversion — indexing the elements rather than the container — is the only workable approach.

```sql
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT count(*) FROM gin_demo WHERE tags @> ARRAY['clearance'];

CREATE INDEX ix_gin_tags ON gin_demo USING gin (tags);
ANALYZE gin_demo;

EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT count(*) FROM gin_demo WHERE tags @> ARRAY['clearance'];

-- Overlap: "any of these tags"
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT count(*) FROM gin_demo WHERE tags && ARRAY['garden','toys'];
```

### 9.4 Demo C — `pg_trgm`: indexing `LIKE '%middle%'`

This is the demo that lands hardest with both Oracle and SQL Server DBAs, because **neither platform can index a leading-wildcard `LIKE` without a separate full-text product.**

```sql
-- On Azure Flexible Server, allow-list the extension first if needed:
--   Server parameter: azure.extensions -> include PG_TRGM  (then it is CREATE-able)
CREATE EXTENSION IF NOT EXISTS pg_trgm;

EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT id, email FROM btree_demo WHERE email LIKE '%250000%' LIMIT 20;
-- Seq Scan: a B-tree on email is useless here
--
-- WHAT TO LOOK FOR (before):
--   * Seq Scan on btree_demo -- despite TWO existing B-tree indexes on email
--     (the plain one from S3 and the unique one from S4.2). Neither can help.
--   * Filter: (email ~~ '%250000%'::text)  <- the leading % is the blocker
--   * Buffers: the whole table (hundreds of thousands of pages)
--   * Rows Removed by Filter: ~2,999,980
--
-- This is the exact query shape that, in Oracle or SQL Server, forces you to
-- buy/deploy a separate full-text product. Note the cost, then compare below.

CREATE INDEX ix_btree_demo_email_trgm
    ON btree_demo USING gin (email gin_trgm_ops);
ANALYZE btree_demo;

EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT id, email FROM btree_demo WHERE email LIKE '%250000%' LIMIT 20;
-- Bitmap Index Scan on the trigram index
--
-- WHAT TO LOOK FOR (after) -- this is the headline demo of the whole section:
--   * Bitmap Index Scan on ix_btree_demo_email_trgm
--       -> a LEADING-WILDCARD LIKE is now index-driven. No other mainstream
--          RDBMS can do this with a regular index.
--   * Index Cond: (email ~~ '%250000%'::text)
--       -> the LIKE moved from Filter to Index Cond. That move IS the result.
--   * Bitmap Heap Scan above it, with:
--       Recheck Cond: (email ~~ '%250000%')
--       Rows Removed by Index Recheck: <small number, EXPECTED and correct>
--       -> pg_trgm is a LOSSY index: it finds rows whose 3-character sequences
--          match, then PostgreSQL re-applies the real LIKE to discard the few
--          false positives. A nonzero recheck count here is normal, not a bug.
--   * Buffers: orders of magnitude lower than the Seq Scan above.
--
-- HOW IT WORKS: '250000' is decomposed into trigrams ('250','500','000',...).
-- GIN stores every trigram of every email, mapped to the rows containing it.
-- The search intersects those row lists, then rechecks. That is why the index
-- is large and slower to build -- the trade-off for an otherwise impossible query.
```

**Bonus — fuzzy matching for free:**

```sql
SELECT email, similarity(email, 'user250000@exampel.com') AS sim
FROM btree_demo
WHERE email % 'user250000@exampel.com'     -- note the typo in "exampel"
ORDER BY sim DESC
LIMIT 5;
```

### 9.5 GIN operational notes

```sql
-- fastupdate (default ON) buffers new entries in a pending list:
--   faster INSERTs, but searches must also scan the pending list.
ALTER INDEX ix_gin_doc SET (fastupdate = off);

-- Pending-list size cap
ALTER INDEX ix_gin_doc SET (gin_pending_list_limit = '4MB');
```

> **Trade-off to state plainly:** GIN gives outstanding read performance and is **slower to build and to update** than a B-tree. It suits read-heavy, write-moderate workloads. If writes dominate and queries are lookup-shaped, consider GiST instead (§11).

---

## 10. BRIN — Block Range INdex

### 10.1 Concept and benefit

BRIN stores, for each **range of table blocks** (default 128 pages = 1 MB), just the **min and max** of the indexed column. To answer a query it skips any block range whose min/max cannot contain matching rows.

**Benefit: astonishingly small.** A BRIN index on a billion-row table is often measured in **kilobytes** — frequently **thousands of times smaller** than the equivalent B-tree, with near-zero maintenance cost.

**Use case:** very large, **naturally ordered** tables — time-series, event logs, IoT telemetry, append-only fact tables, audit trails. Anywhere the column value correlates with physical insert order.

> ⚠️ **BRIN lives or dies on correlation.** On a naturally-ordered column it is one of the best value-for-money features in PostgreSQL. On a randomly-ordered column it is **useless** — every block range spans the whole value domain, so nothing can be skipped. Check `pg_stats.correlation` (§2.4) **before** choosing BRIN.

### 10.2 Demo — time-series log table

```sql
SET search_path TO idxlab, public;

DROP TABLE IF EXISTS brin_demo;

CREATE TABLE brin_demo (
    id          bigserial PRIMARY KEY,
    logged_at   timestamptz NOT NULL,
    device_id   int         NOT NULL,
    metric      numeric(10,3) NOT NULL,
    message     text
);

-- 10,000,000 rows inserted in CHRONOLOGICAL order -- naturally correlated
INSERT INTO brin_demo (logged_at, device_id, metric, message)
SELECT TIMESTAMPTZ '2024-01-01 00:00:00' + (g * interval '3 seconds'),
       (random() * 5000)::int + 1,
       (random() * 100)::numeric(10,3),
       'sensor reading ' || g
FROM generate_series(1, 10000000) g;

ANALYZE brin_demo;

-- Confirm correlation is near 1.0 -- the prerequisite for BRIN
SELECT attname, correlation
FROM pg_stats
WHERE schemaname='idxlab' AND tablename='brin_demo'
  AND attname IN ('logged_at','device_id');
```

**Step 1 — baseline:**

> **👁 What to look for in this plan**
>
> Ten million rows, no index, asking for a single day — roughly 28,800 rows, or **0.29% of the table**.
>
> | In the plan | What it means |
> |---|---|
> | **`Parallel Seq Scan on brin_demo`** | All 10,000,000 rows read to return ~28,800. |
> | **`Filter: ((logged_at >= ...) AND (logged_at < ...))`** | Range predicate applied per row. |
> | **`Rows Removed by Filter: ~9,971,200`** | The waste, stated numerically. |
> | **`Buffers:`** | Very large — this table is on the order of a gigabyte. |
> | **`Workers Launched:`** | PostgreSQL is throwing CPUs at a problem that indexing solves outright. |
> | **`actual time=`** | Seconds, most likely. Record it. |
>
> **Hold one thought before Step 2:** the rows you want are all *physically adjacent*, because they were inserted chronologically. The engine simply has no way to know that yet. **BRIN's entire job is to record that fact** — nothing more.

```sql
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT count(*), avg(metric)
FROM brin_demo
WHERE logged_at >= TIMESTAMPTZ '2024-06-01'
  AND logged_at <  TIMESTAMPTZ '2024-06-02';
```

**Step 2 — build BOTH index types and compare size. This is the headline.**

```sql
CREATE INDEX ix_brin_logged  ON brin_demo USING brin (logged_at);
CREATE INDEX ix_btree_logged ON brin_demo USING btree (logged_at);
ANALYZE brin_demo;

SELECT indexrelname,
       pg_size_pretty(pg_relation_size(indexrelid)) AS size,
       pg_relation_size(indexrelid) AS bytes
FROM pg_stat_user_indexes
WHERE schemaname='idxlab' AND relname='brin_demo'
ORDER BY bytes DESC;
```

Expect the B-tree at hundreds of MB and the BRIN at tens of KB.

**Step 3 — measure query performance with each:**

> **👁 What to look for across this pair of plans — the fairest comparison in the document**
>
> Same query, same data, two index types, each tested in isolation.
>
> **The BRIN plan:**
> | In the plan | What it means |
> |---|---|
> | **`Bitmap Index Scan on ix_brin_logged`** | **BRIN is *always* a bitmap scan.** It cannot point at individual rows — it can only say "these block ranges might contain matches", so it hands the planner a set of *blocks*. |
> | **`Index Cond: ((logged_at >= ...) AND (logged_at < ...))`** | The range is evaluated against each range's stored min/max. |
> | **`Bitmap Heap Scan`** with **`Heap Blocks: lossy=N`** | **This line is BRIN's signature.** `lossy` means "whole blocks flagged, not individual rows" — the opposite of the `exact=N` you saw in B-tree bitmap plans. PostgreSQL will scan every row in those blocks. |
> | **`Rows Removed by Index Recheck:`** | **Expected to be nonzero, and that is fine.** These are rows in a candidate block range that fell outside your exact window. Tuning `pages_per_range` (Step 4) is precisely the act of reducing this number. |
> | **`Buffers:`** | Dramatically below the Step 1 baseline — BRIN skipped the ~99.7% of block ranges whose min/max could not contain your day. |
>
> **The B-tree plan:**
> - Also a `Bitmap Heap Scan`, but with **`Heap Blocks: exact=N`** and **`Rows Removed by Index Recheck: 0`** — B-tree identifies rows precisely.
> - **`actual time`** will likely be *similar to or slightly better than* BRIN.
>
> **How to interpret the result honestly:** the B-tree is usually a little faster. **The BRIN index is hundreds of times smaller.** The question for the room is not "which is faster?" but **"is that marginal speed worth several hundred megabytes of storage, plus index maintenance on every insert, on a table that grows forever?"** On time-series data the answer is very often no — and that is BRIN's entire value proposition.

```sql
-- BRIN only
DROP INDEX ix_btree_logged;
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT count(*), avg(metric) FROM brin_demo
WHERE logged_at >= TIMESTAMPTZ '2024-06-01' AND logged_at < TIMESTAMPTZ '2024-06-02';

-- B-tree only
CREATE INDEX ix_btree_logged ON brin_demo USING btree (logged_at);
DROP INDEX ix_brin_logged;
ANALYZE brin_demo;

EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT count(*), avg(metric) FROM brin_demo
WHERE logged_at >= TIMESTAMPTZ '2024-06-01' AND logged_at < TIMESTAMPTZ '2024-06-02';
```

**Step 4 — tune the block range:**

> **👁 What to look for after changing `pages_per_range`**
>
> The default summarizes **128 pages (1 MB) per entry**. This rebuild uses **32**, quadrupling granularity.
>
> | Compare against Step 3's BRIN plan | Expected direction |
> |---|---|
> | **`Rows Removed by Index Recheck`** | **Should fall noticeably.** Finer ranges mean each candidate range contains fewer irrelevant rows. This is the metric you are tuning. |
> | **`Heap Blocks: lossy=N`** | Should fall — fewer blocks flagged unnecessarily. |
> | **`Buffers:`** | Should fall, following the block count. |
> | **Index size** (re-run the size query) | **Should rise** — four times as many summary entries. It will still be tiny in absolute terms. |
> | **`actual time=`** | Usually improves, with diminishing returns. |
>
> **The tuning rule:** `pages_per_range` trades index size against recheck waste. Lower it while `Rows Removed by Index Recheck` keeps dropping meaningfully; stop when the size growth stops buying you anything. **`Rows Removed by Index Recheck` is the single number that tells you whether a BRIN index is well-tuned** — there is no other signal to go on.

```sql
DROP INDEX ix_btree_logged;

-- Smaller range = finer granularity = bigger index, fewer false-positive blocks
CREATE INDEX ix_brin_logged_32 ON brin_demo
    USING brin (logged_at) WITH (pages_per_range = 32);
ANALYZE brin_demo;

EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT count(*), avg(metric) FROM brin_demo
WHERE logged_at >= TIMESTAMPTZ '2024-06-01' AND logged_at < TIMESTAMPTZ '2024-06-02';
```

**Step 5 — prove BRIN fails on uncorrelated data:**

> **👁 What to look for — this step is designed to FAIL, and the failure is the lesson**
>
> `device_id` was populated randomly, so its `correlation` is near 0 (you checked this at the start of the demo). Every 32-page range therefore contains device IDs spanning roughly the entire 1–5000 domain.
>
> | In the plan | What it reveals |
> |---|---|
> | **`Bitmap Index Scan on ix_brin_device`** | The index *is* used — **do not mistake that for success.** |
> | **`Heap Blocks: lossy=`** a number close to the **entire table's block count** | **The core finding.** Because every range's min/max spans nearly the whole value domain, **no range can be excluded**. BRIN flagged essentially everything. |
> | **`Rows Removed by Index Recheck:`** approaching **10,000,000** | You are now re-filtering the whole table, through an index, with extra steps. |
> | **`Buffers:`** | Comparable to — or *worse than* — the Step 1 sequential scan. |
> | **`actual time=`** | Likely slower than having no index at all. |
>
> **The takeaway to state explicitly:** BRIN is not a general-purpose index that is merely *less effective* on random data. On uncorrelated data it is **actively counterproductive** — it consumes storage and write cycles to deliver a scan that is worse than the sequential one it replaced.
>
> **This is why the decision rule is a hard gate, not a preference:** check `pg_stats.correlation` (§2.4) *before* creating a BRIN index. `> 0.9` → build it. `< 0.5` → use a B-tree.

```sql
-- device_id is random -- correlation near 0
CREATE INDEX ix_brin_device ON brin_demo USING brin (device_id);
ANALYZE brin_demo;

EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT count(*) FROM brin_demo WHERE device_id = 1234;
-- Every block range matches -- effectively a full scan with extra steps
```

**Step 6 — maintenance:**

```sql
-- New rows appended after index creation may sit in an unsummarized range
SELECT brin_summarize_new_values('ix_brin_logged_32');

-- Enable automatic summarization of new ranges
ALTER INDEX ix_brin_logged_32 SET (autosummarize = on);
```

**The decision rule:** `correlation > 0.9` → BRIN is a strong candidate. `correlation < 0.5` → use B-tree.

---

## 11. GiST — Generalized Search Tree

### 11.1 Concept and benefit

GiST is an **extensible framework** for balanced trees, not one algorithm. It supports queries B-trees fundamentally cannot express: overlap, containment, proximity, and nearest-neighbour.

**Benefit:** indexes **geometric, range, and multidimensional** data, and supports **exclusion constraints** — a constraint type that exists in no other mainstream RDBMS.

**Use case:** geospatial (PostGIS is built on GiST), scheduling and booking systems with time ranges, IP address ranges, and K-nearest-neighbour searches.

### 11.2 Demo A — range types and the exclusion constraint

This example alone justifies PostgreSQL for booking systems. **Preventing double-booking declaratively is impossible in Oracle and SQL Server without triggers or serialized application logic.**

```sql
SET search_path TO idxlab, public;

CREATE EXTENSION IF NOT EXISTS btree_gist;   -- lets GiST index scalar types alongside ranges

DROP TABLE IF EXISTS room_booking;

CREATE TABLE room_booking (
    id       bigserial PRIMARY KEY,
    room_id  int   NOT NULL,
    guest    text  NOT NULL,
    stay     tstzrange NOT NULL,

    -- THE POINT: same room + overlapping time = rejected by the engine
    CONSTRAINT no_double_booking
        EXCLUDE USING gist (room_id WITH =, stay WITH &&)
);

INSERT INTO room_booking (room_id, guest, stay) VALUES
 (101,'Silva',  tstzrange('2026-03-01','2026-03-05')),
 (101,'Smith',  tstzrange('2026-03-05','2026-03-09')),   -- OK: adjacent, not overlapping
 (102,'Nakamura', tstzrange('2026-03-02','2026-03-06'));

-- This MUST fail
INSERT INTO room_booking (room_id, guest, stay)
VALUES (101,'Okafor', tstzrange('2026-03-04','2026-03-07'));
-- ERROR: conflicting key value violates exclusion constraint "no_double_booking"
```

**Measure it at scale:**

```sql
INSERT INTO room_booking (room_id, guest, stay)
SELECT (g % 20000) + 1000,
       'guest_' || g,
       tstzrange(TIMESTAMPTZ '2026-01-01' + (g % 300) * interval '1 day',
                 TIMESTAMPTZ '2026-01-01' + (g % 300) * interval '1 day' + interval '2 days')
FROM generate_series(1, 500000) g
ON CONFLICT DO NOTHING;

ANALYZE room_booking;

-- "Which bookings overlap this window?" -- served by the exclusion constraint's GiST index
--
-- WHAT TO LOOK FOR IN THIS PLAN:
--  * Bitmap Index Scan (or Index Scan) on "no_double_booking"
--      -> Note the index NAME: it is the EXCLUSION CONSTRAINT. You never wrote
--         a CREATE INDEX statement. Declaring the constraint built a GiST index,
--         and that same index now accelerates your queries. One object,
--         two jobs: correctness enforcement AND read performance.
--  * Index Cond: (stay && '[2026-02-10,2026-02-12)'::tstzrange)
--      -> The overlap operator && is driving the lookup. GiST stores a bounding
--         range per subtree, so it can discard whole branches that cannot
--         possibly overlap your window. A B-tree cannot express this at all:
--         ordering ranges by start time does not group overlapping ranges
--         together, because a long early booking can overlap a late window.
--  * Recheck Cond + Rows Removed by Index Recheck
--      -> GiST is LOSSY by design. It stores approximations (bounding boxes),
--         returns candidates, and PostgreSQL re-applies the exact operator.
--         A nonzero recheck count is normal and expected.
--  * Buffers: small relative to the 500,000-row table.
--
-- THE OPERATIONAL POINT: every INSERT into this table performs this same
-- overlap search to enforce the constraint. Without the GiST index the
-- constraint would be unenforceable at any reasonable write rate -- which is
-- exactly why Oracle and SQL Server require triggers or serialized application
-- logic (and the race conditions that come with them) to achieve this.
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT count(*) FROM room_booking
WHERE stay && tstzrange('2026-02-10','2026-02-12');
```

### 11.3 Demo B — nearest-neighbour (KNN) search

```sql
DROP TABLE IF EXISTS geo_demo;

CREATE TABLE geo_demo (
    id       bigserial PRIMARY KEY,
    name     text NOT NULL,
    location point NOT NULL
);

INSERT INTO geo_demo (name, location)
SELECT 'store_' || g,
       point((random()*360)-180, (random()*180)-90)
FROM generate_series(1, 500000) g;

ANALYZE geo_demo;

> **👁 What to look for across this pair of plans — K-nearest-neighbour**
>
> **BEFORE the index:**
> | In the plan | What it means |
> |---|---|
> | **`Limit` → `Sort` → `Seq Scan`** | The classic brute-force shape. |
> | **`Sort Key: (location <-> '(0,0)'::point)`** | **PostgreSQL computed the distance from every one of 500,000 points to the origin, then sorted all 500,000 results, to return 10.** |
> | **`Sort Method:`** | Watch for `external merge  Disk:` — 500,000 computed distances may well spill out of `work_mem`. |
> | **`actual rows=500000`** on the scan feeding `rows=10` | The waste ratio in one glance. |
>
> **AFTER the index — look for one specific line:**
> | In the plan | What it means |
> |---|---|
> | **`Index Scan using ix_geo_gist`** | Not a bitmap scan — an **ordered** index scan. |
> | **`Order By: (location <-> '(0,0)'::point)`** | **This is the line that matters, and it is rare.** `Order By:` inside an index node (as opposed to a separate `Sort` node) means **the index itself is producing rows in distance order.** GiST descends the tree nearest-branch-first, emitting points in increasing distance, and stops after 10. |
> | **The `Sort` node is GONE** | No distances were computed for the other 499,990 points. |
> | **`actual rows=10`** on the index node | It genuinely read 10 rows' worth of work. |
> | **`Buffers:`** | A tiny fraction of the baseline. |
>
> **Why this cannot be done with a B-tree:** "nearest" is not a range or an equality — it is a *ranking function over two dimensions*. Sorting by X tells you nothing about combined X–Y proximity. **GiST's KNN support (the `<->` operator returning results in distance order straight from the index) has no equivalent in Oracle or SQL Server outside their dedicated spatial add-ons.** This same mechanism is what makes PostGIS — and pgvector's similarity search — possible.

```sql
-- Baseline: compute distance for every row, then sort
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT name, location <-> point(0,0) AS dist
FROM geo_demo ORDER BY location <-> point(0,0) LIMIT 10;

CREATE INDEX ix_geo_gist ON geo_demo USING gist (location);
ANALYZE geo_demo;

-- After: the index returns rows already in distance order -- no sort
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT name, location <-> point(0,0) AS dist
FROM geo_demo ORDER BY location <-> point(0,0) LIMIT 10;
```

Look for **`Index Scan using ix_geo_gist ... Order By: (location <-> ...)`** — the index itself produces the ordering. There is no B-tree equivalent of this operation.

### 11.4 GiST vs GIN — choosing between them

| | **GIN** | **GiST** |
|---|---|---|
| Lookup speed | **Faster** | Slower (lossy — requires recheck) |
| Build/update speed | Slower | **Faster** |
| Index size | Usually larger | Usually smaller |
| Exact vs lossy | Exact | Lossy (planner adds a recheck step) |
| Best for | Read-heavy full-text, JSONB, arrays | Write-heavy text search; geometry, ranges, KNN |

**Rule:** static/read-heavy → **GIN**. Frequently updated, or geometric/range/KNN data → **GiST**.

---

## 12. SP-GiST — Space-Partitioned GiST

### 12.1 Concept and benefit

GiST builds *balanced* trees. SP-GiST builds **unbalanced, space-partitioned** structures — quadtrees, k-d trees, radix/prefix trees — that partition the search space into **non-overlapping** regions.

**Benefit:** for naturally hierarchical or clustered data, the non-overlapping partitioning is far more efficient than a balanced tree would be. Prefix-structured text (URLs, file paths, phone numbers) and non-uniformly distributed points are the sweet spots.

**Use case:** IP/CIDR lookups, URL and path prefix matching, telephone number ranges, point data with heavy geographic clustering.

### 12.2 Demo — IP address range lookups

```sql
SET search_path TO idxlab, public;

DROP TABLE IF EXISTS ip_demo;

CREATE TABLE ip_demo (
    id       bigserial PRIMARY KEY,
    network  cidr NOT NULL,
    owner    text NOT NULL
);

INSERT INTO ip_demo (network, owner)
SELECT (((g % 223) + 1)::text || '.' ||
        ((g / 223) % 256)::text || '.' ||
        ((g / 57000) % 256)::text || '.0/24')::cidr,
       'org_' || (g % 5000)
FROM generate_series(1, 500000) g
ON CONFLICT DO NOTHING;

ANALYZE ip_demo;

> **👁 What to look for across this pair of plans — "which network contains this address?"**
>
> `>>=` means *contains-or-equals*. This is the lookup every firewall, CDN, geolocation service, and abuse-detection system performs constantly.
>
> **BEFORE:**
> - **`Seq Scan`** with **`Filter: (network >>= '10.20.0.55'::inet)`** — 500,000 CIDR containment tests, one per row.
> - Full-table `Buffers`.
>
> **AFTER:**
> | In the plan | What it means |
> |---|---|
> | **`Bitmap Index Scan on ix_ip_spgist`** | The space-partitioned index is used. |
> | **`Index Cond: (network >>= '10.20.0.55'::inet)`** | Containment moved into the index condition. |
> | **`Buffers:`** | Sharply reduced. |
> | **`Rows Removed by Index Recheck`** | May be nonzero — SP-GiST is lossy like GiST. |
>
> **What SP-GiST is doing differently from GiST:** GiST builds a *balanced* tree whose nodes may hold **overlapping** bounding boxes — so a search sometimes has to descend several branches. SP-GiST partitions the space into **non-overlapping** regions, so a search follows **exactly one path** at each level. IP address space is strictly hierarchical and non-overlapping by definition (10.20.0.0/16 wholly contains 10.20.0.0/24), which makes it an almost perfect fit.
>
> **The practical rule:** when your data has a *natural, non-overlapping hierarchy* — IP/CIDR, filesystem paths, phone number prefixes — test SP-GiST against GiST. When regions genuinely overlap — geometry, time ranges, bookings — use GiST.

```sql
-- Baseline
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT * FROM ip_demo WHERE network >>= inet '10.20.0.55';

CREATE INDEX ix_ip_spgist ON ip_demo USING spgist (network);
ANALYZE ip_demo;

EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT * FROM ip_demo WHERE network >>= inet '10.20.0.55';
```

### 12.3 Demo — text prefix search with the radix tree

```sql
DROP TABLE IF EXISTS path_demo;

CREATE TABLE path_demo (
    id   bigserial PRIMARY KEY,
    path text NOT NULL
);

INSERT INTO path_demo (path)
SELECT '/var/data/app' || (g % 50) || '/module' || (g % 500) || '/file_' || g || '.log'
FROM generate_series(1, 1000000) g;

ANALYZE path_demo;

-- SP-GiST text_ops uses a RADIX TREE: shared prefixes stored once
CREATE INDEX ix_path_spgist ON path_demo USING spgist (path);

-- Compare against B-tree for the same prefix query
CREATE INDEX ix_path_btree ON path_demo USING btree (path);
ANALYZE path_demo;

SELECT indexrelname, pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes
WHERE schemaname='idxlab' AND relname='path_demo'
ORDER BY pg_relation_size(indexrelid) DESC;

-- WHAT TO LOOK FOR IN THIS PLAN:
--  * WHICH index name appears -- ix_path_spgist or ix_path_btree? Both are
--    present and both CAN serve a prefix match, so the planner picks on cost.
--    Whichever it chooses, read that as the honest answer for THIS data.
--  * Index Cond: (path ~>=~ '/var/data/app7/module42/' AND path ~<~ ...)
--      -> Note that PostgreSQL rewrote your LIKE into a RANGE. A trailing-%
--         pattern is just "everything between this prefix and the next one",
--         which is why prefix matching is indexable and '%infix%' is not.
--  * Buffers: compare against the size query you just ran. SP-GiST's radix
--    tree stores the long shared prefix '/var/data/app' ONCE instead of on
--    every leaf entry, which is where its size advantage comes from.
--  * Rows Removed by Index Recheck: may be nonzero for SP-GiST (lossy),
--    and will be 0 for the B-tree (exact).
--
-- BE HONEST ABOUT THE RESULT: B-tree very often still wins on generic text.
-- SP-GiST is a specialist that pays off with long, highly repetitive prefixes.
-- Measure on YOUR data rather than accepting either as a default.
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT count(*) FROM path_demo WHERE path LIKE '/var/data/app7/module42/%';
```

> **Observation to draw out:** with long shared prefixes, SP-GiST's radix tree stores the common prefix once and is often materially smaller than the B-tree. Both handle prefix matching; measure both on *your* data — SP-GiST is a specialist, and B-tree frequently still wins on generic text.

---

## 13. Bloom indexes (extension)

### 13.1 Concept and benefit

A Bloom index stores a small **signature** (bloom filter) per row, built from several indexed columns. Queries test the signature; false positives are possible, false negatives are not — so PostgreSQL rechecks candidate rows against the heap.

**Benefit:** **one small index serves equality queries on any arbitrary subset of its columns.** The B-tree alternative is a combinatorial explosion of multicolumn indexes.

**Use case:** wide tables where users filter on unpredictable combinations of many low-cardinality columns — ad-hoc analytics, product catalogs with dozens of facets, data-warehouse dimension filtering.

> **Limitation:** equality (`=`) only. No ranges, no ordering, no uniqueness.

### 13.2 Demo

```sql
SET search_path TO idxlab, public;

-- On Azure Flexible Server: add BLOOM to the azure.extensions server parameter first
CREATE EXTENSION IF NOT EXISTS bloom;

DROP TABLE IF EXISTS bloom_demo;

CREATE TABLE bloom_demo (
    id  bigserial PRIMARY KEY,
    c1  int NOT NULL, c2 int NOT NULL, c3 int NOT NULL,
    c4  int NOT NULL, c5 int NOT NULL, c6 int NOT NULL,
    payload text
);

INSERT INTO bloom_demo (c1,c2,c3,c4,c5,c6,payload)
SELECT (random()*100)::int, (random()*100)::int, (random()*100)::int,
       (random()*100)::int, (random()*100)::int, (random()*100)::int,
       repeat('b', 40)
FROM generate_series(1, 2000000);

ANALYZE bloom_demo;
```

**Baseline — an unpredictable column combination:**

> **👁 What to look for in this plan**
>
> | In the plan | What it means |
> |---|---|
> | **`Seq Scan on bloom_demo`** | All 2,000,000 rows read. |
> | **`Filter: ((c2 = 42) AND (c5 = 17))`** | Both predicates applied per row. |
> | **`actual rows=`** roughly **200** | Each column has ~100 distinct values, so `1/100 × 1/100 × 2,000,000 ≈ 200`. **The *combination* is highly selective even though each individual column is not** — this is the defining characteristic of the workload Bloom targets. |
> | **`Rows Removed by Filter: ~1,999,800`** | The waste. |
> | **`Buffers:`** | The whole table. |
>
> **Frame the real problem before moving on.** This query filtered on `c2` and `c5`. The next user will filter on `c1` and `c4`. The one after that on `c3`, `c5`, and `c6`. With six columns there are **63 possible non-empty combinations**. You cannot build 63 indexes — the write cost and storage would dwarf the table. **That combinatorial explosion, not this one slow query, is the problem Bloom solves.**

**The B-tree approach — and why it does not scale:**

```sql
-- To cover every 2-column combination of 6 columns you need 15 indexes.
-- Every combination of any size: 63. This is the problem Bloom solves.
CREATE INDEX ix_bloom_demo_c2 ON bloom_demo (c2);
CREATE INDEX ix_bloom_demo_c5 ON bloom_demo (c5);
ANALYZE bloom_demo;

-- WHAT TO LOOK FOR IN THIS PLAN -- the BitmapAnd shape:
--  * BitmapAnd
--      |-- Bitmap Index Scan on ix_bloom_demo_c2   (Index Cond: c2 = 42)
--      +-- Bitmap Index Scan on ix_bloom_demo_c5   (Index Cond: c5 = 17)
--    -> PostgreSQL scanned BOTH single-column indexes, built a bitmap from
--       each, and INTERSECTED them before touching the heap. This is the
--       runtime equivalent of an Oracle bitmap index AND -- see S14.1.
--  * Each Bitmap Index Scan shows actual rows ~= 20,000 (1/100 of the table),
--    while the BitmapAnd above them emits only ~200. Most of the work is
--    spent finding 20,000 candidates per column to discard 39,800 of them.
--  * Buffers: much better than the Seq Scan, but note it is NOT tiny --
--    reading two whole index ranges is real work.
--
-- IT WORKS. The problem is that it only works for THIS column pair. Query
-- c1 + c4 and you are back to a Seq Scan unless you build two more indexes.
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT count(*) FROM bloom_demo WHERE c2 = 42 AND c5 = 17;

SELECT sum(pg_relation_size(indexrelid)) AS btree_bytes,
       pg_size_pretty(sum(pg_relation_size(indexrelid))) AS btree_total
FROM pg_stat_user_indexes
WHERE schemaname='idxlab' AND relname='bloom_demo'
  AND indexrelname LIKE 'ix_bloom_demo_c%';
```

**The Bloom approach — one index, all combinations:**

```sql
DROP INDEX ix_bloom_demo_c2;
DROP INDEX ix_bloom_demo_c5;

CREATE INDEX ix_bloom_demo_all ON bloom_demo
    USING bloom (c1,c2,c3,c4,c5,c6)
    WITH (length = 80, col1 = 2, col2 = 2, col3 = 2, col4 = 2, col5 = 2, col6 = 2);
ANALYZE bloom_demo;

SELECT pg_size_pretty(pg_relation_size('ix_bloom_demo_all')) AS bloom_size;

-- WHAT TO LOOK FOR ACROSS THE NEXT THREE PLANS:
--  * Bitmap Index Scan on ix_bloom_demo_all appears in ALL THREE, even though
--    each query filters on a DIFFERENT set of columns. ONE index, any subset.
--    That is the entire value proposition -- watch the index name repeat.
--  * Index Cond: shows whichever columns the query used.
--  * Rows Removed by Index Recheck: <EXPECTED TO BE LARGE>
--      -> THIS IS THE NUMBER TO STUDY. A Bloom filter can produce FALSE
--         POSITIVES (never false negatives), so PostgreSQL rechecks every
--         candidate row against the real predicate. That recheck count IS
--         your false-positive rate, made visible.
--      -> If it is uncomfortably high, raise the `length` parameter (more
--         signature bits per row) or the per-column bit counts, and rebuild.
--         Bigger signature = fewer false positives = larger index.
--  * Buffers: Bloom must scan its ENTIRE index (every row has a signature,
--    and signatures are unordered). So buffers will NOT beat a well-matched
--    B-tree on a single query. The index is small, so scanning all of it is
--    cheap -- but this is a trade, not a free win.
--
-- HOW TO JUDGE THE RESULT: do not compare Bloom against the two-B-tree plan
-- on query 1 alone -- B-tree may well win that one. Compare TOTAL INDEX SIZE
-- and TOTAL WRITE COST for covering all 63 possible column combinations.
-- That is the comparison Bloom is designed to win.

-- Same query
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT count(*) FROM bloom_demo WHERE c2 = 42 AND c5 = 17;

-- A DIFFERENT combination -- same index, no new index required
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT count(*) FROM bloom_demo WHERE c1 = 7 AND c3 = 88 AND c6 = 3;

-- And another
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT count(*) FROM bloom_demo WHERE c4 = 55;
```

**Parameters:** `length` = signature bits per row (default 80, max 4096); `colN` = bits set per column (default 2). More bits = fewer false positives = larger index. Tune by measuring **Rows Removed by Filter** in the plan — that number *is* your false-positive rate.

---

## 14. Choosing an index — decision table

| Query shape / data type | Index type | Why |
|---|---|---|
| `=`, `<`, `>`, `BETWEEN`, `ORDER BY`, uniqueness | **B-tree** | The default; the only type supporting all of these |
| `=` only, on very long values | **Hash** | Stores a small hash instead of the full key |
| Filter always includes a fixed condition | **Partial B-tree** | Tiny index, near-zero write cost |
| `WHERE func(col) = ...` | **Expression** | Makes a non-sargable predicate sargable |
| Filter + return a few extra columns | **B-tree + `INCLUDE`** | Index-only scan, no heap fetch |
| JSONB `@>`, array `@>`/`&&`, full-text `@@` | **GIN** | Inverted index over elements |
| `LIKE '%substring%'`, fuzzy match | **GIN + `pg_trgm`** | The only way to index a leading wildcard |
| Huge table, column correlates with physical order | **BRIN** | Kilobytes instead of gigabytes |
| Range overlap, geometry, KNN, exclusion constraints | **GiST** | Overlap/containment/proximity operators |
| Write-heavy text search | **GiST** | Cheaper updates than GIN |
| IP/CIDR, URL/path prefixes, clustered points | **SP-GiST** | Non-overlapping space partitioning |
| Many low-cardinality columns, unpredictable `=` combinations | **Bloom** | One index covers every subset |
| Physical reorganization for range-scan locality | **`CLUSTER`** (not an index type) | One-time reorg; decays with writes |

### 14.1 What PostgreSQL does NOT have — set expectations

| Oracle / SQL Server feature | PostgreSQL reality |
|---|---|
| **Clustered index** (SQL Server) / **IOT** (Oracle) | No equivalent. `CLUSTER` is one-time (§2). |
| **Bitmap index** (Oracle) | No bitmap **index** type. PostgreSQL builds **bitmap scans** on the fly at query time, combining multiple B-trees — often achieving the same goal without the concurrency penalty Oracle bitmap indexes carry on DML. |
| **Reverse key index** (Oracle) | No direct equivalent; hash indexes or a hashed expression index address the same contention problem. |
| **Index-organized tables** | Use `CLUSTER` periodically, or a covering index for index-only scans. |
| **Invisible indexes** (Oracle 11g+) | No per-index invisibility. Test with `SET enable_indexscan = off` at session level, or drop in a transaction and roll back. |
| **Filtered index** (SQL Server) | **Present and better** — partial indexes (§7) accept arbitrary predicates. |

**Prove the bitmap point — it answers the Oracle DBA's first objection:**

```sql
SET search_path TO idxlab, public;

CREATE INDEX ix_bitmap_c1 ON bloom_demo (c1);
CREATE INDEX ix_bitmap_c3 ON bloom_demo (c3);
ANALYZE bloom_demo;

-- WHAT TO LOOK FOR IN THIS PLAN -- the answer to "where are bitmap indexes?":
--
--   Aggregate
--     -> Bitmap Heap Scan on bloom_demo
--          Recheck Cond: ((c1 = 7) AND (c3 = 88))
--          -> BitmapAnd                          <-- THE NODE TO POINT AT
--               -> Bitmap Index Scan on ix_bitmap_c1   Index Cond: (c1 = 7)
--               -> Bitmap Index Scan on ix_bitmap_c3   Index Cond: (c3 = 88)
--
--  * BitmapAnd is PostgreSQL building a bitmap AT QUERY TIME from two ordinary
--    B-tree indexes, intersecting them, and only then visiting the heap.
--    BitmapOr does the same for OR predicates.
--  * The bitmaps are TRANSIENT -- built in work_mem, discarded after the query.
--    Nothing bitmap-shaped is stored on disk, so there is NO on-disk bitmap
--    index to lock. This is why PostgreSQL has no equivalent of Oracle's
--    bitmap-index DML concurrency problem, where a single-row update locks a
--    whole bitmap segment and blocks other writers.
--  * Heap Blocks: exact=N -- rows identified precisely (contrast BRIN's lossy=N).
--  * Watch for "lossy" appearing here: if work_mem is too small, the bitmap
--    degrades from row-level to page-level granularity and Rows Removed by
--    Index Recheck rises. That is a work_mem tuning signal.
--
-- THE TALKING POINT FOR ORACLE DBAs: you do not create bitmap indexes in
-- PostgreSQL because you do not need to. Create ordinary B-trees on the
-- columns and let the planner combine them per query -- with no DML penalty.
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT count(*) FROM bloom_demo WHERE c1 = 7 AND c3 = 88;
```

Look for **`BitmapAnd`** combining two `Bitmap Index Scan` nodes. PostgreSQL built the bitmap at runtime from two ordinary B-trees — no special index type, and no DML concurrency penalty.

---

## 15. Index maintenance and health

### 15.1 Find unused indexes

```sql
SELECT schemaname, relname AS table_name, indexrelname AS index_name,
       idx_scan AS times_used,
       pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes
WHERE idx_scan = 0
  AND indexrelid NOT IN (SELECT conindid FROM pg_constraint WHERE contype IN ('p','u','x'))
ORDER BY pg_relation_size(indexrelid) DESC;
```

> Check `pg_stat_reset` timing before acting — an index unused since the last stats reset may still serve a quarterly report. Confirm across a full business cycle.

### 15.2 Find duplicate / redundant indexes

```sql
SELECT indrelid::regclass AS table_name,
       array_agg(indexrelid::regclass) AS duplicate_indexes,
       pg_size_pretty(sum(pg_relation_size(indexrelid))) AS wasted_space
FROM pg_index
GROUP BY indrelid, indkey, indclass, indpred, indisunique
HAVING count(*) > 1;
```

Also look for indexes that are a **leftmost prefix** of another — `(a)` is redundant when `(a,b)` exists.

### 15.3 Rebuild bloated indexes

```sql
-- Online rebuild, PG 12+ (no long write lock)
REINDEX INDEX CONCURRENTLY ix_btree_demo_email;

-- Whole table
REINDEX TABLE CONCURRENTLY btree_demo;
```

### 15.4 Find INVALID indexes (failed `CONCURRENTLY` builds)

```sql
SELECT indexrelid::regclass AS invalid_index, indrelid::regclass AS on_table
FROM pg_index WHERE NOT indisvalid;
-- Remedy: DROP INDEX <name>; then recreate CONCURRENTLY.
```

### 15.5 Azure Flexible Server notes

- **Extensions must be allow-listed** before `CREATE EXTENSION` will succeed. Add `PG_TRGM`, `BLOOM`, `BTREE_GIST` (and any others) to the **`azure.extensions`** server parameter, then create them in the database.
- **Index builds are I/O-bound.** Scale up compute/IOPS for a large build, then scale back — near-zero-downtime scaling makes this cheap.
- `maintenance_work_mem` governs index build speed. Raise it for the session before a large build:
  ```sql
  SET maintenance_work_mem = '2GB';
  SET max_parallel_maintenance_workers = 4;
  CREATE INDEX CONCURRENTLY ...;
  ```
- **Query Store and Index Tuning** (Azure-specific) can recommend indexes from observed workload — a useful cross-check against your own analysis, not a replacement for it.

---

## 16. Full lab teardown

```sql
DROP SCHEMA idxlab CASCADE;
```

---

## 17. Quick reference — the six built-in index types

| Type | Operators supported | Multicolumn | `INCLUDE` | Unique | Typical size |
|---|---|---|---|---|---|
| **B-tree** | `< <= = >= > BETWEEN IN IS NULL`, `LIKE 'p%'`, sorting | Yes (32 cols) | Yes (PG 11+) | **Yes** | Moderate |
| **Hash** | `=` only | No | No | No | Small for long keys |
| **GiST** | `<< &> @> && <->` (type-dependent) | Yes | Yes (PG 12+) | No (but **exclusion constraints**) | Moderate |
| **SP-GiST** | Type-dependent: `<< >>= ~<~`, prefix | Yes (PG 14+) | Yes (PG 14+) | No | Small–moderate |
| **GIN** | `@> ? ?| ?& && @@` | Yes | No | No | Large |
| **BRIN** | `< <= = >= >` | Yes | No | No | **Tiny** |

*(Plus **Bloom** via the `bloom` contrib extension — equality on arbitrary column subsets.)*

---

## 18. Reference documentation

- PostgreSQL — Indexes: https://www.postgresql.org/docs/current/indexes.html
- Index types: https://www.postgresql.org/docs/current/indexes-types.html
- `CREATE INDEX`: https://www.postgresql.org/docs/current/sql-createindex.html
- GIN: https://www.postgresql.org/docs/current/gin.html · GiST: https://www.postgresql.org/docs/current/gist.html
- SP-GiST: https://www.postgresql.org/docs/current/spgist.html · BRIN: https://www.postgresql.org/docs/current/brin.html
- `bloom`: https://www.postgresql.org/docs/current/bloom.html · `pg_trgm`: https://www.postgresql.org/docs/current/pgtrgm.html
- Full-text search: https://www.postgresql.org/docs/current/textsearch.html
- `CLUSTER`: https://www.postgresql.org/docs/current/sql-cluster.html
- Using `EXPLAIN`: https://www.postgresql.org/docs/current/using-explain.html
- Azure Database for PostgreSQL — extensions: https://learn.microsoft.com/en-us/azure/postgresql/extensions/concepts-extensions
