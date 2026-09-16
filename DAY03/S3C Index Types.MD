# PostgreSQL Index Types — Complete Guide with Hands-On Demos

## For DBAs coming from SQL Server and Oracle

**Target platform:** Azure Database for PostgreSQL Flexible Server (PostgreSQL 14+; PG 16 assumed)
**Format:** every section = concept → benefit → use case → runnable SQL demo → how to measure the gain
**All demos are pure SQL.** They are self-contained: each creates its own table, populates it, measures before/after, and cleans up.

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

> **Teaching point:** this is why `SELECT` without `ORDER BY` has **no** ordering guarantee in PostgreSQL — stronger than in Oracle or SQL Server, because MVCC actively relocates rows. There is no "it usually comes back in clustered-index order" fallback, because there is no clustered index.

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

### 2.4 Demo — measure clustering, then fix it

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

```sql
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT sum(amount)
FROM cluster_demo
WHERE customer_id BETWEEN 100 AND 200;
```

Record `Buffers: shared read` + `hit`. Every matching row is probably on its own page.

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

EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT sum(amount)
FROM cluster_demo
WHERE customer_id BETWEEN 100 AND 200;
```

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

```sql
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT id, last_name FROM btree_demo WHERE email = 'user1234567@example.com';
```

Expect `Parallel Seq Scan`, hundreds of thousands of buffers, hundreds of ms.

**Step 2 — create the index**

```sql
-- Production form:
-- CREATE INDEX CONCURRENTLY ix_btree_demo_email ON btree_demo (email);
CREATE INDEX ix_btree_demo_email ON btree_demo (email);
ANALYZE btree_demo;
```

**Step 3 — re-measure**

```sql
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT id, last_name FROM btree_demo WHERE email = 'user1234567@example.com';
```

Expect `Index Scan`, ~4–6 buffers, sub-millisecond. **This is typically a 10,000×+ reduction in pages touched.**

**Step 4 — price the index**

```sql
SELECT pg_size_pretty(pg_relation_size('ix_btree_demo_email')) AS index_size,
       pg_size_pretty(pg_relation_size('btree_demo'))          AS heap_size;
```

**Step 5 — sort avoidance, the benefit people forget**

```sql
-- Without a matching index: Seq Scan + Sort (possibly spilling to disk)
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT id, signup_date FROM btree_demo ORDER BY signup_date DESC LIMIT 20;

CREATE INDEX ix_btree_demo_signup ON btree_demo (signup_date DESC);
ANALYZE btree_demo;

-- Now: walk 20 entries off the end of the index. No sort at all.
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT id, signup_date FROM btree_demo ORDER BY signup_date DESC LIMIT 20;
```

**Step 6 — the write cost, so the trade-off is honest**

```sql
-- Time an update WITHOUT touching an indexed column (HOT-eligible)
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

```sql
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT id, created_at
FROM composite_demo
WHERE tenant_id = 42 AND status = 'SHIPPED'
ORDER BY created_at DESC
LIMIT 50;
```

**Column order matters — build both and compare:**

```sql
-- Good: equality columns first, then the ORDER BY column
CREATE INDEX ix_comp_good ON composite_demo (tenant_id, status, created_at DESC);
ANALYZE composite_demo;

EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT id, created_at FROM composite_demo
WHERE tenant_id = 42 AND status = 'SHIPPED'
ORDER BY created_at DESC LIMIT 50;

-- Poor: leading with the low-selectivity column, ORDER BY column stranded
CREATE INDEX ix_comp_poor ON composite_demo (status, created_at DESC, tenant_id);
ANALYZE composite_demo;

-- Force a comparison
SET enable_indexscan = on;
DROP INDEX ix_comp_good;

EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
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

-- Covering index: key = country, payload = lifetime_val
CREATE INDEX ix_btree_demo_cover
    ON btree_demo (country) INCLUDE (lifetime_val);
ANALYZE btree_demo;

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

-- Expression index
CREATE INDEX ix_btree_demo_lower_email ON btree_demo (lower(email));
ANALYZE btree_demo;

EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT id FROM btree_demo WHERE lower(email) = 'user2500000@example.com';
```

**Date truncation — the reporting workhorse:**

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

```sql
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT count(*) FROM gin_demo
WHERE doc @> '{"customer": {"tier": "platinum"}}';
```

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

```sql
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT count(*) FROM gin_demo
WHERE doc @> '{"customer": {"tier": "platinum"}}';

-- Key-existence operator: served by the DEFAULT opclass, NOT by jsonb_path_ops
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT count(*) FROM gin_demo WHERE doc ? 'flags';
```

### 9.3 Demo B — array membership

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

CREATE INDEX ix_btree_demo_email_trgm
    ON btree_demo USING gin (email gin_trgm_ops);
ANALYZE btree_demo;

EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT id, email FROM btree_demo WHERE email LIKE '%250000%' LIMIT 20;
-- Bitmap Index Scan on the trigram index
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

```sql
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT count(*) FROM bloom_demo WHERE c2 = 42 AND c5 = 17;
```

**The B-tree approach — and why it does not scale:**

```sql
-- To cover every 2-column combination of 6 columns you need 15 indexes.
-- Every combination of any size: 63. This is the problem Bloom solves.
CREATE INDEX ix_bloom_demo_c2 ON bloom_demo (c2);
CREATE INDEX ix_bloom_demo_c5 ON bloom_demo (c5);
ANALYZE bloom_demo;

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
