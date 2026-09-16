# PostgreSQL Table Partitioning

## Concepts · implementation · creation · maintenance · locking · query plans

---

## 0. The 60-second summary

| Question | Answer |
|---|---|
| **What is a partitioned table in PostgreSQL?** | A **logical parent that holds no data**, plus a set of **real child tables** that hold all of it |
| **Which methods?** | **RANGE**, **LIST**, **HASH** — and they can be nested (sub-partitioning) |
| **Are partitions separate tables?** | ✅ **Yes** — each has its own files, own indexes, own statistics, own vacuum cycle |
| **Global indexes (Oracle-style)?** | ❌ **Do not exist.** Every index is local to one partition |
| **Can a unique key exclude the partition key?** | ❌ **No.** Every unique/PK constraint **must include** the partition key |
| **Can I index one partition only?** | ✅ **Yes** — and this is a genuine advantage |
| **Does it make queries faster?** | Only if the planner can **prune**. Without pruning, partitioning usually makes things *slower* |
| **The #1 reason to partition** | **Maintenance and data lifecycle** — dropping a partition is instant; `DELETE` of the same rows is not |

> ⚠️ Partitioning is a **data-management** feature that sometimes helps performance — not a performance feature that sometimes helps management. Teams that partition purely "to make it faster" are usually disappointed.

---

# PART I — Concepts

## 1. What partitioning is

**Partitioning splits one logical table into multiple physical tables**, divided by the value of a **partition key**. The parent is a shell — an empty definition with routing rules. Every row lives in exactly one child.

```
                 sales_order_detail          <-- PARENT (no data, no storage)
                   PARTITION BY RANGE (order_date)
                           |
     +---------------------+---------------------+
     |                     |                     |
 sod_2024_q1          sod_2024_q2          sod_2024_q3     <-- real tables
 (own files,          (own files,          (own files,
  own indexes,         own indexes,         own indexes,
  own statistics)      own statistics)      own statistics)
```

### 1.1 The three methods

| Method | Splits by | Classic use |
|---|---|---|
| **RANGE** | A continuous range of values | Dates, timestamps, sequential IDs — **by far the most common** |
| **LIST** | An explicit set of discrete values | Region, country, tenant, status |
| **HASH** | A hash of the key, modulo N | Even distribution when there is no natural range or list |

### 1.2 How PostgreSQL implements it

**Declarative partitioning** (PostgreSQL 10+) is the modern, supported mechanism. You declare the scheme and PostgreSQL handles routing, pruning, and metadata.

> ⚠️ **The old way still exists, and you will meet it.** Before PG 10, partitioning was done with **table inheritance plus CHECK constraints plus routing triggers**. It works, it is still supported, and it is **worse in every respect**: manual routing, `constraint_exclusion` instead of true pruning, no `ATTACH`/`DETACH`, no partition-wise joins.
>
> **If you inherit an inheritance-based scheme, migrating it to declarative partitioning is almost always worth the effort.** Detect it with:
> ```sql
> SELECT inhrelid::regclass AS child, inhparent::regclass AS parent
> FROM pg_inherits
> WHERE inhparent NOT IN (SELECT oid FROM pg_class WHERE relkind = 'p');
> ```

</br>
> Rows here are **legacy inheritance** children, not declarative partitions.

## 2. Benefits — the honest list

### ✅ 2.1 Instant data lifecycle management *(the real reason)*

```sql
-- Deleting a year of data from a 5-billion-row table:
DELETE FROM sales WHERE order_date < '2020-01-01';
-- Hours. Massive WAL. Enormous bloat. Vacuum for days afterwards.

-- The same operation on a partitioned table:
ALTER TABLE sales DETACH PARTITION sales_2019;
DROP TABLE sales_2019;
-- Milliseconds. Trivial WAL. Zero bloat. No vacuum needed.
```

> **This alone justifies partitioning for most time-series workloads.** Everything else is a bonus.

### ✅ 2.2 Partition pruning

The planner skips partitions that cannot contain matching rows. A query for one day against five years of monthly partitions touches **1 partition out of 60**.

### ✅ 2.3 Smaller, faster maintenance units

| Operation | Unpartitioned 2 TB table | Partitioned into 24 × 85 GB |
|---|---|---|
| `VACUUM` | One enormous job | 24 independent jobs, parallelizable, each finishing |
| `REINDEX` | Hours, huge temp space | Per-partition, schedulable |
| `ANALYZE` | Samples 2 TB | Samples per partition — **better statistics** |
| Index rebuild | 2 TB of I/O | 85 GB at a time |

### ✅ 2.4 Per-partition physical strategy

Old partitions can be indexed differently, compressed differently, or moved to different tablespaces from hot ones. See §9.

### ✅ 2.5 Partition-wise joins and aggregates

When two tables share a partitioning scheme, PostgreSQL can join them **partition by partition** — smaller hash tables, better parallelism. **Off by default** (§12.4).

---

## 3. Drawbacks — read these before committing

### ❌ 3.1 No global indexes

**This is the single biggest difference from Oracle.**

```sql
-- Oracle: a global unique index on a non-partition-key column -- fine.
-- PostgreSQL: IMPOSSIBLE.
```

Every index is **local** to one partition. Consequences:

- **A unique constraint must include the partition key.** You cannot enforce "email is unique across the whole table" unless `email` is the partition key.
- A query filtering **only** on a non-partition-key column must scan **every partition's** index.

```sql
-- This fails:
CREATE TABLE t (id bigint, tenant int, PRIMARY KEY (id))
PARTITION BY RANGE (tenant);
-- ERROR: unique constraint on partitioned table must include all partitioning columns

-- This works -- the partition key is in the key:
CREATE TABLE t (id bigint, tenant int, PRIMARY KEY (id, tenant))
PARTITION BY RANGE (tenant);
```

> **Design consequence:** if your natural primary key cannot include the partition key, **partitioning may be the wrong choice** — or you need a different partition key. Decide this before you build.

### ❌ 3.2 Planning overhead grows with partition count

Every partition is a relation the planner must consider and lock. Hundreds are fine; **thousands hurt**, especially for short OLTP queries where planning time rivals execution time.

| Partition count | Practical assessment |
|---|---|
| **< 100** | Comfortable |
| **100–1,000** | Fine with good pruning; watch planning time |
| **1,000–10,000** | Possible; expect measurable planning overhead |
| **> 10,000** | Expect problems. Reconsider the granularity |

> **The most common design error is over-partitioning.** Daily partitions for 10 years is 3,650 partitions. Monthly is 120 and almost always better.

### ❌ 3.3 Queries without the partition key get slower

A query that cannot prune scans **every** partition — with per-partition overhead on top. **This is slower than the unpartitioned table would have been.**

### ❌ 3.4 Other limitations

- ❌ You **cannot** add a partition that overlaps an existing range
- ❌ You cannot `ALTER` the partition key after creation — it is a rebuild
- ❌ `ON CONFLICT` has restrictions across partitions
- ❌ Row movement between partitions on `UPDATE` requires PG 11+ and is a delete+insert internally
- ❌ **No automatic partition creation** — you script it, or use `pg_partman`
- ⚠️ **Parent-level statistics are not maintained by autovacuum** (§11.3)

## 4. Should you partition? — the decision test

| Signal | Partition? |
|---|---|
| Table > ~100 GB **and** growing | ✅ Strong candidate |
| You regularly delete/archive old data in bulk | ✅ **Best reason there is** |
| Almost every query filters on one natural key (date, tenant) | ✅ Yes — that is the partition key |
| Vacuum/reindex windows no longer fit | ✅ Yes |
| Table is < 10 GB | ❌ No — indexes are enough |
| Queries filter on many different columns unpredictably | ❌ No — you will not prune |
| You need a unique constraint that excludes the partition key | ❌ **Blocked** — rethink |
| "To make it faster" with no other reason | ❌ Index it properly first |

---

# PART II — Creating partitions

## 5. Lab setup

```sql
CREATE SCHEMA IF NOT EXISTS partlab;
SET search_path TO partlab, public;
\timing on
```

## 6. Partitioning an empty table — the easy path

### 6.1 RANGE partitioning

```sql
DROP TABLE IF EXISTS sales CASCADE;

-- The PARENT. Note: no storage, and the PK must include the partition key.
CREATE TABLE sales (
    sale_id     bigint      GENERATED ALWAYS AS IDENTITY,
    order_date  date        NOT NULL,
    customer_id int         NOT NULL,
    amount      numeric(12,2) NOT NULL,
    region      text        NOT NULL,
    PRIMARY KEY (sale_id, order_date)        -- partition key REQUIRED in the PK
) PARTITION BY RANGE (order_date);
```

```sql
-- Children. Bounds are [inclusive, exclusive).
CREATE TABLE sales_2024_q1 PARTITION OF sales
    FOR VALUES FROM ('2024-01-01') TO ('2024-04-01');
CREATE TABLE sales_2024_q2 PARTITION OF sales
    FOR VALUES FROM ('2024-04-01') TO ('2024-07-01');
CREATE TABLE sales_2024_q3 PARTITION OF sales
    FOR VALUES FROM ('2024-07-01') TO ('2024-10-01');
CREATE TABLE sales_2024_q4 PARTITION OF sales
    FOR VALUES FROM ('2024-10-01') TO ('2025-01-01');

-- A DEFAULT partition catches anything outside every defined range
CREATE TABLE sales_default PARTITION OF sales DEFAULT;
```

> ⚠️ **The DEFAULT partition is a double-edged tool.** It prevents insert failures, but **once it contains a row, adding a new partition whose range overlaps that row requires scanning the default partition** (and fails if a conflicting row exists). On a busy system, a default partition that has silently collected rows is a future outage. **Either monitor it and keep it empty, or omit it and let bad inserts fail loudly.**

```sql
-- Verify the structure
SELECT c.relname AS partition_name,
       pg_get_expr(c.relpartbound, c.oid) AS bounds,
       pg_size_pretty(pg_relation_size(c.oid)) AS size
FROM pg_class c
JOIN pg_inherits i ON i.inhrelid = c.oid
WHERE i.inhparent = 'sales'::regclass
ORDER BY c.relname;
```

### 6.2 Routing happens automatically

```sql
INSERT INTO sales (order_date, customer_id, amount, region) VALUES
  ('2024-02-15', 101,  250.00, 'US'),
  ('2024-05-20', 102, 1200.50, 'EU'),
  ('2024-08-03', 103,  875.25, 'APAC'),
  ('2024-11-11', 104, 3400.00, 'US');

-- tableoid reveals WHICH partition each row landed in
SELECT tableoid::regclass AS lives_in, sale_id, order_date, amount
FROM sales ORDER BY order_date;
```

> 💡 **`tableoid::regclass` is the single most useful trick in partitioned-table work.** It is a system column on every row telling you its physical table. Use it constantly.

### 6.3 LIST partitioning

```sql
DROP TABLE IF EXISTS events CASCADE;

CREATE TABLE events (
    event_id  bigint GENERATED ALWAYS AS IDENTITY,
    region    text NOT NULL,
    payload   jsonb,
    logged_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (event_id, region)
) PARTITION BY LIST (region);

CREATE TABLE events_us   PARTITION OF events FOR VALUES IN ('US','CA','MX');
CREATE TABLE events_eu   PARTITION OF events FOR VALUES IN ('UK','DE','FR','ES','IT');
CREATE TABLE events_apac PARTITION OF events FOR VALUES IN ('JP','AU','SG','IN');
CREATE TABLE events_other PARTITION OF events DEFAULT;
```

### 6.4 HASH partitioning

```sql
DROP TABLE IF EXISTS accounts CASCADE;

CREATE TABLE accounts (
    account_id bigint NOT NULL,
    owner_name text   NOT NULL,
    balance    numeric(14,2) NOT NULL DEFAULT 0,
    PRIMARY KEY (account_id)
) PARTITION BY HASH (account_id);

CREATE TABLE accounts_p0 PARTITION OF accounts FOR VALUES WITH (MODULUS 4, REMAINDER 0);
CREATE TABLE accounts_p1 PARTITION OF accounts FOR VALUES WITH (MODULUS 4, REMAINDER 1);
CREATE TABLE accounts_p2 PARTITION OF accounts FOR VALUES WITH (MODULUS 4, REMAINDER 2);
CREATE TABLE accounts_p3 PARTITION OF accounts FOR VALUES WITH (MODULUS 4, REMAINDER 3);
```

> **HASH gives even distribution but no range pruning.** `WHERE account_id = 12345` prunes to one partition; `WHERE account_id BETWEEN 1 AND 1000` prunes **nothing**. Use HASH for contention spreading and parallel maintenance, not for range queries.

### 6.5 Sub-partitioning

```sql
DROP TABLE IF EXISTS metrics CASCADE;

CREATE TABLE metrics (
    ts       timestamptz NOT NULL,
    region   text        NOT NULL,
    device   int         NOT NULL,
    reading  numeric(10,3)
) PARTITION BY RANGE (ts);

-- This partition is ITSELF partitioned
CREATE TABLE metrics_2024_10 PARTITION OF metrics
    FOR VALUES FROM ('2024-10-01') TO ('2024-11-01')
    PARTITION BY LIST (region);

CREATE TABLE metrics_2024_10_us PARTITION OF metrics_2024_10 FOR VALUES IN ('US');
CREATE TABLE metrics_2024_10_eu PARTITION OF metrics_2024_10 FOR VALUES IN ('EU');
CREATE TABLE metrics_2024_10_def PARTITION OF metrics_2024_10 DEFAULT;
```

> ⚠️ **Sub-partitioning multiplies partition count fast.** 24 months × 5 regions = 120 tables. It is rarely worth it — **partition by the dimension you prune on, and index the other one.**

---

## 7. Partitioning a table that already has data

This is the hard case, and the one that matters in a migration.

### 7.1 Build the demo table — a large `salesorderdetail`

Shaped like AdventureWorks `Sales.SalesOrderDetail`, enlarged to be worth partitioning.

```sql
SET search_path TO partlab, public;

DROP TABLE IF EXISTS salesorderdetail CASCADE;

CREATE TABLE salesorderdetail (
    salesorderid           int           NOT NULL,
    salesorderdetailid     bigint        GENERATED ALWAYS AS IDENTITY,
    carriertrackingnumber  varchar(25),
    orderqty               smallint      NOT NULL,
    productid              int           NOT NULL,
    specialofferid         int           NOT NULL,
    unitprice              numeric(19,4) NOT NULL,
    unitpricediscount      numeric(19,4) NOT NULL DEFAULT 0,
    linetotal              numeric(38,6) NOT NULL,
    rowguid                uuid          NOT NULL DEFAULT gen_random_uuid(),
    modifieddate           timestamp     NOT NULL DEFAULT now(),
    orderdate              date          NOT NULL          -- our partition key
);
```

**Option A — generate synthetic data (works anywhere):**

```sql
INSERT INTO salesorderdetail
    (salesorderid, carriertrackingnumber, orderqty, productid, specialofferid,
     unitprice, unitpricediscount, linetotal, orderdate, modifieddate)
SELECT (g / 4) + 43659,
       upper(substr(md5(random()::text), 1, 4)) || '-' ||
       upper(substr(md5(random()::text), 1, 4)) || '-' ||
       upper(substr(md5(random()::text), 1, 2)),
       (random() * 10)::smallint + 1,
       (random() * 500)::int + 707,
       (random() * 15)::int + 1,
       round((random() * 2000 + 5)::numeric, 4),
       round((random() * 0.2)::numeric, 4),
       round((random() * 3000 + 10)::numeric, 6),
       d.order_date,
       d.order_date + (random() * interval '12 hours')
FROM generate_series(1, 12000000) g
CROSS JOIN LATERAL (
    SELECT (DATE '2022-01-01' + ((g * 7) % 1095) * interval '1 day')::date AS order_date
) d;

ANALYZE salesorderdetail;

SELECT count(*) AS rows,
       pg_size_pretty(pg_total_relation_size('salesorderdetail')) AS total_size,
       min(orderdate) AS from_date, max(orderdate) AS to_date
FROM salesorderdetail;
```

**Option B — enlarge a real `sales.salesorderdetail` if you have AdventureWorks loaded:**

```sql
-- Multiply the real table 200x, spreading dates across 3 years
INSERT INTO partlab.salesorderdetail
    (salesorderid, carriertrackingnumber, orderqty, productid, specialofferid,
     unitprice, unitpricediscount, linetotal, orderdate, modifieddate)
SELECT d.salesorderid + (m.n * 100000),
       d.carriertrackingnumber,
       d.orderqty,
       d.productid,
       d.specialofferid,
       d.unitprice,
       d.unitpricediscount,
       d.linetotal,
       (DATE '2022-01-01' + ((m.n * 5 + d.salesorderdetailid) % 1095) * interval '1 day')::date,
       now()
FROM sales.salesorderdetail d
CROSS JOIN generate_series(1, 200) AS m(n);

ANALYZE partlab.salesorderdetail;
```

```sql
-- Index it the way an unpartitioned table would be
CREATE INDEX ix_sod_orderdate ON salesorderdetail (orderdate);
CREATE INDEX ix_sod_productid ON salesorderdetail (productid);
ANALYZE salesorderdetail;
```

### 7.2 ⚠️ The impact of partitioning existing data

**You cannot convert a table in place.** `ALTER TABLE ... PARTITION BY` does not exist. Your options:

| Method | Downtime | Disk needed | Complexity |
|---|---|---|---|
| **A — Create new + copy + rename** | Minutes to hours (write outage) | **2× table size** | Low |
| **B — Create new + `ATTACH` the old table as one partition** | **Seconds** | Minimal | Medium |
| **C — Online with logical replication / `pg_partman`** | Near-zero | 2× | High |

> **The cost everyone underestimates is disk.** Methods A and C need a full second copy of the table *plus its indexes* simultaneously. On a 2 TB table that is 4 TB of free space. **Verify before you start** — running out of space mid-copy leaves you with a mess.

### 7.3 Method A — copy into a new partitioned table

```sql
-- 1. Build the partitioned shell
DROP TABLE IF EXISTS sod_part CASCADE;

CREATE TABLE sod_part (LIKE salesorderdetail INCLUDING DEFAULTS INCLUDING CONSTRAINTS)
PARTITION BY RANGE (orderdate);

-- 2. Create partitions covering the full data range (quarterly here)
DO $$
DECLARE
    d date := DATE '2022-01-01';
BEGIN
    WHILE d < DATE '2025-01-01' LOOP
        EXECUTE format(
            'CREATE TABLE %I PARTITION OF sod_part FOR VALUES FROM (%L) TO (%L)',
            'sod_part_' || to_char(d, 'YYYY') || '_q' || to_char(d, 'Q'),
            d, d + interval '3 months');
        d := (d + interval '3 months')::date;
    END LOOP;
END $$;

-- 3. Copy. THIS is the expensive step.
INSERT INTO sod_part SELECT * FROM salesorderdetail;

-- 4. Index AFTER loading -- far faster than loading into indexed partitions
CREATE INDEX ix_sodpart_orderdate ON sod_part (orderdate);
CREATE INDEX ix_sodpart_productid ON sod_part (productid);

ANALYZE sod_part;

-- 5. Swap (inside a transaction -- brief ACCESS EXCLUSIVE)
BEGIN;
  ALTER TABLE salesorderdetail RENAME TO salesorderdetail_old;
  ALTER TABLE sod_part         RENAME TO salesorderdetail;
COMMIT;
```

> **Sequence of operations matters enormously.** Load first, index second. Loading 12 million rows into a table that already has two indexes is several times slower than loading then indexing, because every insert maintains both index trees.

### 7.4 Method B — attach the existing table as a partition *(minimal downtime)*

The trick for large tables: keep the historical data exactly where it is.

```sql
DROP TABLE IF EXISTS sod_live CASCADE;

-- 1. New partitioned parent
CREATE TABLE sod_live (LIKE salesorderdetail_old INCLUDING DEFAULTS)
PARTITION BY RANGE (orderdate);

-- 2. CRITICAL: add a CHECK constraint matching the future partition bound.
--    Without it, ATTACH must scan the whole table to prove every row fits.
--    With it, PostgreSQL trusts the constraint and ATTACH is nearly instant.
ALTER TABLE salesorderdetail_old
    ADD CONSTRAINT ck_sod_hist
    CHECK (orderdate >= DATE '2022-01-01' AND orderdate < DATE '2025-01-01')
    NOT VALID;

ALTER TABLE salesorderdetail_old VALIDATE CONSTRAINT ck_sod_hist;  -- weak lock

-- 3. Attach. Fast, because the CHECK already proves the bound.
ALTER TABLE sod_live ATTACH PARTITION salesorderdetail_old
    FOR VALUES FROM ('2022-01-01') TO ('2025-01-01');

-- 4. Add forward partitions for new data
CREATE TABLE sod_live_2025_q1 PARTITION OF sod_live
    FOR VALUES FROM ('2025-01-01') TO ('2025-04-01');

-- 5. The redundant CHECK can now be dropped
ALTER TABLE salesorderdetail_old DROP CONSTRAINT ck_sod_hist;
```

> **👁 What to observe — time both variants**
>
> Run `ATTACH PARTITION` with and without the pre-created `CHECK` constraint on a copy.
>
> - **Without `CHECK`:** `ATTACH` performs a **full sequential scan** of the table to validate every row against the bound. On 12 million rows this is seconds; on 2 billion it is many minutes — **holding a lock the whole time**.
> - **With a validated `CHECK`:** PostgreSQL reads the catalog, sees the constraint implies the bound, and **skips the scan entirely**. Near-instant.
>
> **This is the single most valuable technique in this document for migrating a large live table.**

### 7.5 `pg_partman` — automated partition lifecycle

Manual `DO` blocks do not scale operationally. `pg_partman` creates partitions ahead of time and retires old ones on a schedule.

```sql
-- On Azure Flexible Server: add PG_PARTMAN (and PG_CRON for scheduling) to the
-- azure.extensions server parameter first, then create them here.
CREATE EXTENSION IF NOT EXISTS pg_partman;

SELECT partman.create_parent(
    p_parent_table => 'partlab.sod_live',
    p_control      => 'orderdate',
    p_interval     => '1 month',
    p_premake      => 4                -- keep 4 future partitions ready
);

-- Retention: drop partitions older than 24 months
UPDATE partman.part_config
SET retention = '24 months',
    retention_keep_table = false
WHERE parent_table = 'partlab.sod_live';

-- Run maintenance (schedule with pg_cron)
SELECT partman.run_maintenance();
```

---

# PART III — Indexes on partitioned tables

## 8. How indexes work across partitions

### 8.1 Creating on the parent cascades to every child

```sql
SET search_path TO partlab, public;

-- ONE statement, but it creates an index on EVERY partition
CREATE INDEX ix_sales_customer ON sales (customer_id);
```

```sql
-- The parent index is a "partitioned index" -- metadata only, zero bytes.
-- The real indexes are the per-partition children.
SELECT c.relname                                AS index_name,
       c.relkind,                               -- 'I' = partitioned, 'i' = real
       CASE c.relkind WHEN 'I' THEN 'partitioned (metadata only)'
                      WHEN 'i' THEN 'physical index' END AS kind,
       pg_size_pretty(pg_relation_size(c.oid))  AS size,
       i.inhparent::regclass                    AS parent_index
FROM pg_class c
LEFT JOIN pg_inherits i ON i.inhrelid = c.oid
WHERE c.relname LIKE 'ix_sales_customer%' OR c.relname LIKE 'sales%customer%'
ORDER BY c.relkind DESC, c.relname;
```

> **Key insight:** the parent index is a **catalog entry with no storage** (`relkind = 'I'`). Only the per-partition indexes hold data. **New partitions automatically inherit every parent index** — that is the main reason to define indexes on the parent.

### 8.2 ✅ Yes — you can index a single partition

This is a real capability and a genuine advantage over a monolithic table.

```sql
-- Index that exists ONLY on the current quarter
CREATE INDEX ix_sales_q4_region ON sales_2024_q4 (region);

-- Verify it is local
SELECT tablename, indexname
FROM pg_indexes
WHERE schemaname = 'partlab' AND tablename LIKE 'sales_2024%'
ORDER BY tablename, indexname;
```

**Why you would do this:**

| Scenario | Strategy |
|---|---|
| Hot current partition, cold history | Rich indexing on current; minimal on archive |
| Different query patterns by era | Index each partition for how it is actually queried |
| Reduce storage on archive data | Drop non-essential indexes from old partitions |
| Load a new partition fast | Load unindexed, index afterwards, then attach |

```sql
-- Reclaim space by dropping indexes from cold partitions
DROP INDEX IF EXISTS sales_2024_q1_customer_id_idx;
```

> ⚠️ **The trade-off:** a query without partition pruning that relies on that index will be fast on some partitions and slow on others. **Asymmetric indexing demands that pruning works.**

### 8.3 Building parent indexes without a long lock

`CREATE INDEX` on the parent locks **every** partition for the whole build. For a large table, do it partition by partition:

```sql
-- 1. Create the parent index as metadata ONLY -- instant, no build
CREATE INDEX ix_sales_amount ON ONLY sales (amount);
-- The parent index is marked INVALID until every partition has one attached

-- 2. Build each partition's index CONCURRENTLY -- no write blocking
CREATE INDEX CONCURRENTLY ix_sales_q1_amount ON sales_2024_q1 (amount);
CREATE INDEX CONCURRENTLY ix_sales_q2_amount ON sales_2024_q2 (amount);
CREATE INDEX CONCURRENTLY ix_sales_q3_amount ON sales_2024_q3 (amount);
CREATE INDEX CONCURRENTLY ix_sales_q4_amount ON sales_2024_q4 (amount);
CREATE INDEX CONCURRENTLY ix_sales_def_amount ON sales_default (amount);

-- 3. Attach each one to the parent
ALTER INDEX ix_sales_amount ATTACH PARTITION ix_sales_q1_amount;
ALTER INDEX ix_sales_amount ATTACH PARTITION ix_sales_q2_amount;
ALTER INDEX ix_sales_amount ATTACH PARTITION ix_sales_q3_amount;
ALTER INDEX ix_sales_amount ATTACH PARTITION ix_sales_q4_amount;
ALTER INDEX ix_sales_amount ATTACH PARTITION ix_sales_def_amount;

-- 4. Once ALL partitions are attached, the parent index becomes valid
SELECT indexrelid::regclass AS index_name, indisvalid
FROM pg_index WHERE indexrelid = 'ix_sales_amount'::regclass;
```

> ⚠️ **`CREATE INDEX CONCURRENTLY` is not supported directly on a partitioned parent.** The `ON ONLY` + per-partition + `ATTACH` sequence above is the supported workaround, and it is the standard production technique.

### 8.4 Unique constraints — the hard limitation

```sql
-- Fails: partition key not in the unique key
ALTER TABLE sales ADD CONSTRAINT uq_sales_customer UNIQUE (customer_id);
-- ERROR: unique constraint on partitioned table must include all partitioning columns

-- Works:
ALTER TABLE sales ADD CONSTRAINT uq_sales_cust_date UNIQUE (customer_id, order_date);
```

> **This enforces uniqueness only within the combination** — the same `customer_id` can appear on many dates, across many partitions. **There is no way to enforce global uniqueness on a non-partition-key column.** If the data model requires it, either make that column the partition key, or do not partition.

---

# PART IV — Querying partitioned tables

## 9. Partition pruning — the whole point

### 9.1 Plan-time pruning

> **👁 What to look for in the plan — and in a graphical plan viewer**
>
> **In the text plan (`EXPLAIN ANALYZE`):**
>
> | What to look for | Meaning |
> |---|---|
> | **`Append`** node | The partition dispatcher. Its **children are the partitions actually scanned.** |
> | **Count the child nodes** | 1 child out of 12 partitions = pruning worked. 12 children = **no pruning — investigate.** |
> | **Child node names** | They are the **partition names** (`sod_part_2023_q2`). Read them to confirm the *right* ones were chosen. |
> | **`Subplans Removed: N`** | **Run-time pruning** happened (§9.2). Absent in a pure plan-time prune. |
> | **`never executed`** on a child | That partition was pruned at execution time. |
> | **`Buffers:`** on the `Append` | Total pages across all scanned partitions — compare against the unpartitioned table. |
> | **`Planning Time:`** | **Watch this on wide scans.** With many partitions it can exceed execution time. |
>
> **In a graphical plan (pgAdmin / VS Code PostgreSQL extension / explain.dalibo.com):**
>
> | What to look at | Meaning |
> |---|---|
> | **Number of boxes feeding the `Append` node** | The visual partition count — the fastest possible pruning check |
> | **Arrow thickness** into `Append` | Row volume per partition; one thick arrow and many hairlines = good skew-aware pruning |
> | **Node colour/heat** | Most tools shade the most expensive node — if a partition scan is the hotspot, that partition needs an index |
> | **`Append` with a single child** | The visual signature of perfect pruning |
> | **Total node count** | A plan that visually explodes into dozens of boxes is a pruning failure, even before you read any numbers |

```sql
SET search_path TO partlab, public;

-- ✅ GOOD: filters on the partition key -- prunes to one partition
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT count(*), sum(linetotal)
FROM sod_part
WHERE orderdate >= DATE '2023-04-01' AND orderdate < DATE '2023-07-01';
```

```sql
-- ❌ BAD: no partition key predicate -- scans EVERY partition
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT count(*) FROM sod_part WHERE productid = 870;
```

> **👁 Compare these two plans side by side — this is the core demonstration**
>
> The first shows an `Append` with **one** child. The second shows an `Append` with **twelve**, each with its own scan, each contributing buffers. Same table, same data. **The only difference is whether the WHERE clause names the partition key.**

```sql
-- ⚠️ The subtle trap: a function on the partition key defeats plan-time pruning
EXPLAIN (COSTS OFF)
SELECT count(*) FROM sod_part WHERE extract(year FROM orderdate) = 2023;
-- Scans everything.

-- The rewrite that prunes:
EXPLAIN (COSTS OFF)
SELECT count(*) FROM sod_part
WHERE orderdate >= DATE '2023-01-01' AND orderdate < DATE '2024-01-01';
```

### 9.2 Run-time pruning

When the value is not known at plan time — a parameter, or a join key — PostgreSQL prunes during execution (PG 11+).

```sql
PREPARE q(date, date) AS
SELECT count(*) FROM sod_part WHERE orderdate >= $1 AND orderdate < $2;

EXPLAIN (ANALYZE, COSTS OFF)
EXECUTE q(DATE '2023-04-01', DATE '2023-07-01');
```

> **👁 What to look for**
>
> - **`Subplans Removed: N`** — the explicit run-time pruning counter. **This line only appears for run-time pruning**; its presence is the proof.
> - Child nodes marked **`(never executed)`** — planned but skipped.
> - The plan lists **all** partitions (the planner could not know which), yet only some have `actual time` values.
>
> **In a graphical plan:** the pruned nodes render greyed out or with zero rows. Many viewers show them at zero width — visually obvious once you know to look.

### 9.3 Querying one partition directly

```sql
-- Partitions are real tables -- query them by name
SELECT count(*) FROM sod_part_2023_q2;

-- ONLY restricts to the parent alone (which holds no rows)
SELECT count(*) FROM ONLY sod_part;      -- always 0
```

```sql
-- Which partition does each row live in?
SELECT tableoid::regclass AS partition, count(*)
FROM sod_part
GROUP BY 1
ORDER BY 1;
```

```sql
-- Filter by partition using tableoid
SELECT * FROM sod_part
WHERE tableoid = 'sod_part_2023_q2'::regclass
LIMIT 10;
```

> ⚠️ **Querying a partition by name bypasses the parent and is marginally faster** — no `Append`, no pruning logic. But it **hard-codes physical layout into application SQL.** Use it for maintenance and ad-hoc investigation; **never in application code**, which should always address the parent.

### 9.4 Row counts and sizes per partition

```sql
SELECT c.relname                                   AS partition,
       pg_get_expr(c.relpartbound, c.oid)          AS bounds,
       c.reltuples::bigint                         AS est_rows,
       pg_size_pretty(pg_relation_size(c.oid))     AS heap_size,
       pg_size_pretty(pg_indexes_size(c.oid))      AS index_size,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS total
FROM pg_class c
JOIN pg_inherits i ON i.inhrelid = c.oid
WHERE i.inhparent = 'sod_part'::regclass
ORDER BY c.relname;
```

### 9.5 Partition-wise joins and aggregates — off by default

```sql
SHOW enable_partitionwise_join;       -- off
SHOW enable_partitionwise_aggregate;  -- off

SET enable_partitionwise_join = on;
SET enable_partitionwise_aggregate = on;
```

> **👁 What changes in the plan**
>
> **Without:** `Append` all partitions → then one big `Hash Join` / `HashAggregate` at the top.
> **With:** the `Hash Join` / `HashAggregate` appears **inside each `Append` child** — the join runs per partition pair, on much smaller inputs.
>
> **Why it is off by default:** it increases planning time and memory, and only pays off when both tables share an identical partitioning scheme. **Enable it per-session or per-workload after measuring — not globally as a default.**

---

# PART V — Maintenance

## 10. VACUUM and partitioned tables

### 10.1 The fundamental rule

**Each partition is an independent table for vacuum purposes.** The parent holds no rows and needs no heap vacuum.

```sql
-- Vacuums EVERY partition (the parent itself has nothing to vacuum)
VACUUM (VERBOSE, ANALYZE) sod_part;

-- Vacuum one partition only -- the normal maintenance unit
VACUUM (VERBOSE, ANALYZE) sod_part_2023_q2;
```

> **👁 What to look for in the `VERBOSE` output**
>
> Vacuuming the parent produces a **separate block of output per partition**:
> ```
> INFO:  vacuuming "partlab.sod_part_2022_q1"
> INFO:  scanned index "sod_part_2022_q1_orderdate_idx" to remove N row versions
> ...
> INFO:  vacuuming "partlab.sod_part_2022_q2"
> ...
> ```
> **Each partition is vacuumed serially, with its own index phase.** This is exactly why partitioning helps maintenance: you can vacuum one 85 GB partition in a window instead of one 2 TB table, and you can run several in parallel from separate sessions.

### 10.2 Autovacuum treats partitions individually

```sql
-- Per-partition vacuum health
SELECT relname,
       n_live_tup, n_dead_tup,
       round(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 1) AS dead_pct,
       last_vacuum, last_autovacuum, last_analyze, last_autoanalyze
FROM pg_stat_user_tables
WHERE schemaname = 'partlab' AND relname LIKE 'sod_part%'
ORDER BY relname;
```

> **The operational benefit:** autovacuum thresholds are evaluated **per partition**. On a 2 TB unpartitioned table, `autovacuum_vacuum_scale_factor = 0.2` means waiting for 400 GB of dead rows. **Partitioned, the same setting triggers at 20% of an 85 GB partition** — far sooner, and the resulting vacuum is far smaller. Partitioning fixes the large-table autovacuum problem almost for free.

**Per-partition tuning — aggressive on hot, relaxed on cold:**

```sql
-- Current partition: heavy writes, vacuum eagerly
ALTER TABLE sod_part_2024_q4 SET (
    autovacuum_vacuum_scale_factor  = 0.02,
    autovacuum_analyze_scale_factor = 0.01,
    autovacuum_vacuum_cost_limit    = 2000
);

-- Archive partition: read-only, almost never needs vacuum
ALTER TABLE sod_part_2022_q1 SET (
    autovacuum_vacuum_scale_factor  = 0.4,
    autovacuum_enabled              = true    -- keep ON for wraparound freezing
);
```

> ⚠️ **Never set `autovacuum_enabled = false` on an archive partition.** It stops anti-wraparound freezing, and a never-frozen archive partition eventually forces an emergency vacuum — or a shutdown. **Relax the thresholds; do not disable the mechanism.**

### 10.3 VACUUM options with partitions

```sql
-- Parallel index vacuuming WITHIN one partition
VACUUM (PARALLEL 4) sod_part_2023_q2;

-- Freeze an archive partition once, then it needs almost nothing forever
VACUUM (FREEZE, ANALYZE) sod_part_2022_q1;

-- Skip index cleanup -- emergency only
VACUUM (INDEX_CLEANUP OFF) sod_part_2024_q4;

-- VACUUM FULL rebuilds ONE partition -- lock is scoped to that partition
VACUUM FULL sod_part_2022_q1;
```

> 💡 **`VACUUM FULL` on a single partition is dramatically more practical than on a monolithic table.** It takes `ACCESS EXCLUSIVE` on **that partition only** — queries touching other partitions continue. Combined with `VACUUM (FREEZE)` on archives, this is the standard pattern: freeze cold partitions once, and they largely stop needing maintenance.

> ⚠️ **`VACUUM FULL` on the *parent* rewrites every partition, holding locks across all of them.** Almost never what you want. **Always name the specific partition.**

### 10.4 Monitoring

```sql
SELECT p.pid, a.query, p.relid::regclass AS current_partition,
       p.phase, p.heap_blks_total, p.heap_blks_scanned, p.index_vacuum_count
FROM pg_stat_progress_vacuum p
JOIN pg_stat_activity a USING (pid);
```

> **`relid::regclass` shows which partition vacuum is currently on.** When vacuuming a parent, you watch it walk through the children one at a time.

## 11. Statistics on partitioned tables

### 11.1 Two levels of statistics

| Level | Used for | Maintained by autovacuum? |
|---|---|---|
| **Per-partition** | Estimating within a partition after pruning | ✅ **Yes** |
| **Parent (inheritance) statistics** | Estimating across partitions, join planning, `GROUP BY` | ❌ **NO** |

### 11.2 Demo — see both levels

```sql
ANALYZE sod_part;   -- gathers BOTH parent-level and per-partition statistics
```

```sql
-- Parent-level: inherited = true
SELECT tablename, attname, n_distinct, correlation, inherited
FROM pg_stats
WHERE schemaname = 'partlab' AND tablename = 'sod_part'
  AND attname IN ('orderdate','productid')
ORDER BY attname, inherited;

-- Per-partition
SELECT tablename, attname, n_distinct, correlation
FROM pg_stats
WHERE schemaname = 'partlab' AND tablename = 'sod_part_2023_q2'
  AND attname IN ('orderdate','productid')
ORDER BY attname;
```

### 11.3 ⚠️ The parent-statistics gap — the one that bites people

**Autovacuum analyzes each partition. It does NOT analyze the parent partitioned table.**

```sql
-- Proof: the parent never shows an autoanalyze timestamp
SELECT relname, last_analyze, last_autoanalyze, n_mod_since_analyze
FROM pg_stat_user_tables
WHERE schemaname = 'partlab' AND relname LIKE 'sod_part%'
ORDER BY relname;
```

> **Consequences of stale parent statistics:**
> - Bad row estimates for queries spanning partitions
> - Poor join order when the partitioned table joins to others
> - Wrong `GROUP BY` and aggregate strategies
>
> **And the estimate error is invisible in the usual places** — each partition's own statistics are perfectly fresh, so nothing looks wrong until you compare `rows=` against `actual rows=` on the `Append` node.

**The fix — schedule it explicitly:**

```sql
-- Add to your maintenance job. This is NOT optional on a partitioned schema.
ANALYZE sod_part;
```

```sql
-- Find partitioned parents that have never been analyzed
SELECT c.relname AS partitioned_table,
       s.last_analyze, s.last_autoanalyze,
       CASE WHEN s.last_analyze IS NULL AND s.last_autoanalyze IS NULL
            THEN '🔴 NEVER ANALYZED - parent stats missing'
            WHEN COALESCE(s.last_analyze, s.last_autoanalyze) < now() - interval '7 days'
            THEN '🟠 Stale'
            ELSE '🟢 Current' END AS status,
       'ANALYZE ' || c.relname::regclass || ';' AS fix
FROM pg_class c
LEFT JOIN pg_stat_user_tables s ON s.relid = c.oid
WHERE c.relkind = 'p'
ORDER BY c.relname;
```

> **👁 The diagnostic signature of missing parent statistics**
>
> In `EXPLAIN ANALYZE`, look at the **`Append` node**: estimated `rows=` far off `actual rows=`, while each **individual child scan** has accurate estimates. **Children accurate, parent wrong** = run `ANALYZE <parent>`.

### 11.4 Statistics targets and extended statistics

```sql
-- Per-partition target
ALTER TABLE sod_part_2023_q2 ALTER COLUMN productid SET STATISTICS 500;
ANALYZE sod_part_2023_q2;

-- On the parent -- inherited by future partitions
ALTER TABLE sod_part ALTER COLUMN productid SET STATISTICS 500;
ANALYZE sod_part;
```

> ⚠️ **Extended statistics (`CREATE STATISTICS`) must be created per partition.** They are **not** inherited from the parent. If correlated columns matter, script their creation into your partition-creation routine.

## 12. Partition lifecycle operations

### 12.1 Adding a partition

```sql
CREATE TABLE sod_part_2025_q1 PARTITION OF sod_part
    FOR VALUES FROM ('2025-01-01') TO ('2025-04-01');
-- Inherits every parent index automatically
```

**Fast pattern for a large pre-built partition — load detached, then attach:**

```sql
-- 1. Build standalone (no partition overhead during load)
CREATE TABLE sod_part_2025_q2_new (LIKE sod_part INCLUDING DEFAULTS);

-- 2. Load and index it offline
--    INSERT / COPY ...
CREATE INDEX ON sod_part_2025_q2_new (orderdate);
CREATE INDEX ON sod_part_2025_q2_new (productid);
ANALYZE sod_part_2025_q2_new;

-- 3. CHECK constraint so ATTACH skips the validation scan
ALTER TABLE sod_part_2025_q2_new
    ADD CONSTRAINT ck_bound
    CHECK (orderdate >= DATE '2025-04-01' AND orderdate < DATE '2025-07-01');

-- 4. Attach -- fast
ALTER TABLE sod_part ATTACH PARTITION sod_part_2025_q2_new
    FOR VALUES FROM ('2025-04-01') TO ('2025-07-01');

ALTER TABLE sod_part_2025_q2_new DROP CONSTRAINT ck_bound;
```

### 12.2 Removing a partition

```sql
-- Detach and keep the data as a standalone table (archival)
ALTER TABLE sod_part DETACH PARTITION sod_part_2022_q1;

-- PG 14+: detach without a long lock
ALTER TABLE sod_part DETACH PARTITION sod_part_2022_q2 CONCURRENTLY;

-- Or drop outright -- instant, regardless of size
DROP TABLE sod_part_2022_q3;
```

> **This is the headline benefit.** `DROP TABLE` on a 200 GB partition is a catalog operation and a file unlink — **effectively instant, minimal WAL, zero bloat.** A `DELETE` of the same 200 GB would run for hours, generate 200 GB+ of WAL, and leave a table that needs vacuuming for days.

### 12.3 Archiving — detach, compress, retain

```sql
BEGIN;
  ALTER TABLE sod_part DETACH PARTITION sod_part_2022_q1;
  ALTER TABLE sod_part_2022_q1 RENAME TO archive_sod_2022_q1;
COMMIT;

-- Now an ordinary table: export it, move it, or drop indexes to reclaim space
DROP INDEX IF EXISTS archive_sod_2022_q1_productid_idx;
VACUUM (FULL, FREEZE, ANALYZE) archive_sod_2022_q1;
```

### 12.4 Merging and splitting

PostgreSQL 16 and earlier have **no `MERGE PARTITION` or `SPLIT PARTITION`**. Do it manually:

```sql
-- Merge two quarters into a half-year partition
BEGIN;
  ALTER TABLE sod_part DETACH PARTITION sod_part_2022_q1;
  ALTER TABLE sod_part DETACH PARTITION sod_part_2022_q2;

  CREATE TABLE sod_part_2022_h1 (LIKE sod_part INCLUDING DEFAULTS);
  INSERT INTO sod_part_2022_h1 SELECT * FROM sod_part_2022_q1;
  INSERT INTO sod_part_2022_h1 SELECT * FROM sod_part_2022_q2;

  ALTER TABLE sod_part ATTACH PARTITION sod_part_2022_h1
      FOR VALUES FROM ('2022-01-01') TO ('2022-07-01');

  DROP TABLE sod_part_2022_q1, sod_part_2022_q2;
COMMIT;
```

> **Oracle and SQL Server both have native `MERGE`/`SPLIT`.** This is a genuine gap — factor the manual effort into any migration estimate. (`SPLIT`/`MERGE PARTITION` arrived in PostgreSQL 17; confirm your Azure version before relying on it.)

---

# PART VI — Locking

## 13. How partition locking differs from table locking

**This is one of partitioning's strongest operational advantages**, and it is poorly understood.

### 13.1 The core principle

> **DDL on one partition takes a lock on that partition only.** Queries touching *other* partitions are unaffected. On a monolithic table, the same DDL blocks everything.

### 13.2 Lock levels by operation

| Operation | Lock on **parent** | Lock on **partition** | Blocks other partitions? |
|---|---|---|---|
| `SELECT` (pruned) | `ACCESS SHARE` | `ACCESS SHARE` on surviving partitions | ❌ No |
| `INSERT`/`UPDATE`/`DELETE` | `ROW EXCLUSIVE` | `ROW EXCLUSIVE` on target | ❌ No |
| `CREATE TABLE ... PARTITION OF` | `SHARE UPDATE EXCLUSIVE` | — | ❌ No |
| **`ATTACH PARTITION`** | `SHARE UPDATE EXCLUSIVE` *(PG 12+)* | `ACCESS EXCLUSIVE` on the table being attached | ❌ No |
| **`DETACH PARTITION`** | `ACCESS EXCLUSIVE` | `ACCESS EXCLUSIVE` | ⚠️ **Yes, briefly** |
| **`DETACH ... CONCURRENTLY`** *(PG 14+)* | `SHARE UPDATE EXCLUSIVE` | — | ❌ No |
| `DROP TABLE <partition>` | `ACCESS EXCLUSIVE` on parent | — | ⚠️ Yes, briefly |
| `VACUUM <partition>` | — | `SHARE UPDATE EXCLUSIVE` | ❌ No |
| **`VACUUM FULL <partition>`** | — | `ACCESS EXCLUSIVE` on **that partition** | ❌ **No — the key win** |
| `REINDEX <partition index>` | — | Blocks writes on that partition | ❌ No |
| `CREATE INDEX` on **parent** | `SHARE` | `SHARE` on **all** | ⚠️ **Yes — blocks writes everywhere** |
| `CREATE INDEX` on one partition | — | `SHARE` on that partition | ❌ No |
| `ALTER TABLE` on parent (add column) | `ACCESS EXCLUSIVE` | Cascades to all | ⚠️ **Yes** |

### 13.3 Demo — prove partition-scoped locking

**Session 1:**

```sql
BEGIN;
VACUUM FULL sod_part_2022_q1;   -- ACCESS EXCLUSIVE on this partition only
-- leave it running
```

**Session 2 — runs normally, unblocked:**

```sql
SELECT count(*) FROM sod_part
WHERE orderdate >= DATE '2024-01-01' AND orderdate < DATE '2024-04-01';
-- Completes immediately: pruning means it never touches sod_part_2022_q1
```

**Session 3 — this one blocks:**

```sql
SELECT count(*) FROM sod_part_2022_q1;   -- waits
```

**Inspect the locks:**

```sql
SELECT l.pid,
       l.locktype,
       l.relation::regclass AS locked_object,
       l.mode,
       l.granted,
       left(a.query, 60)    AS query
FROM pg_locks l
JOIN pg_stat_activity a USING (pid)
WHERE l.relation::regclass::text LIKE 'sod_part%'
ORDER BY l.granted, l.pid;
```

> **👁 What to observe**
>
> - `granted = false` rows are **waiting** — that is your blocked session.
> - **The `locked_object` column names the specific partition**, not the parent. That is the entire point: the blast radius of the lock is one partition.
> - On a monolithic table, `VACUUM FULL` would have blocked **every** query in sessions 2 *and* 3.

### 13.4 Finding blocking chains

```sql
SELECT blocked.pid            AS blocked_pid,
       blocked.relation::regclass AS blocked_on,
       blocked.mode           AS wants,
       blocking.pid           AS blocking_pid,
       blocking.mode          AS holds,
       left(ba.query, 80)     AS blocking_query,
       now() - ba.query_start AS blocking_duration
FROM pg_locks blocked
JOIN pg_locks blocking
  ON blocking.relation = blocked.relation
 AND blocking.granted AND NOT blocked.granted
 AND blocking.pid <> blocked.pid
JOIN pg_stat_activity ba ON ba.pid = blocking.pid
ORDER BY blocking_duration DESC;
```

### 13.5 ⚠️ Lock traps specific to partitioning

1. **`ALTER TABLE` on the parent cascades.** Adding a column takes `ACCESS EXCLUSIVE` on the parent **and every partition** — with 200 partitions that is 201 exclusive locks acquired together. **Schedule it like a full-table DDL, because that is what it is.**

2. **`DETACH PARTITION` (non-concurrent) needs `ACCESS EXCLUSIVE` on the parent** — briefly blocking *all* queries against the table. **Use `DETACH ... CONCURRENTLY` on PG 14+.**

3. **Lock queues cascade.** One long query holding `ACCESS SHARE` on the parent delays a waiting `ACCESS EXCLUSIVE`, which in turn queues every subsequent query behind it. Always set a timeout for maintenance DDL:
   ```sql
   SET lock_timeout = '5s';
   ALTER TABLE sod_part DETACH PARTITION sod_part_2022_q1;
   ```

4. **`max_locks_per_transaction`.** A query touching hundreds of partitions acquires hundreds of locks. Wide scans across many partitions can exhaust the lock table — the error is `out of shared memory` with a hint about this parameter. **Another reason not to over-partition.**

---

# PART VII — Reference

## 14. Cross-platform comparison

| Feature | **PostgreSQL** | **Oracle** | **SQL Server** |
|---|---|---|---|
| Declarative partitioning | ✅ PG 10+ | ✅ | ✅ (partition function/scheme) |
| RANGE / LIST / HASH | ✅ All three | ✅ + composite, reference, interval | ✅ RANGE only |
| **Automatic partition creation** | ❌ `pg_partman` or scripts | ✅ **INTERVAL partitioning** | ❌ |
| **Global indexes** | ❌ **Not supported** | ✅ | ⚠️ Non-aligned indexes |
| Local indexes | ✅ (the only kind) | ✅ | ✅ (aligned) |
| Unique key excluding partition key | ❌ | ✅ (global index) | ⚠️ Non-aligned only |
| Partition pruning | ✅ Plan-time + run-time | ✅ | ✅ |
| Partition-wise join | ✅ *(off by default)* | ✅ | ✅ |
| `SPLIT` / `MERGE` partition | ⚠️ PG 17+ only | ✅ | ✅ |
| Attach/detach ("switch") | ✅ `ATTACH`/`DETACH` | ✅ `EXCHANGE PARTITION` | ✅ `SWITCH` |
| Online detach | ✅ PG 14+ `CONCURRENTLY` | ✅ | ✅ |
| Per-partition statistics | ✅ | ✅ | ✅ |
| **Parent stats auto-maintained** | ❌ **Manual `ANALYZE`** | ✅ | ✅ |

> **The two lines to highlight for an Oracle DBA:**
> 1. **No global indexes.** Any Oracle design relying on a global unique index on a non-partition-key column **cannot be ported directly.** This is a schema-redesign item, not a syntax translation.
> 2. **No INTERVAL partitioning.** Oracle creates the next partition automatically; PostgreSQL does not. Budget for `pg_partman` or a scheduled job — and make sure it is monitored, because a missing future partition means failed inserts.

## 15. Health-check query pack

```sql
-- 1. Every partitioned table and its partition count
SELECT c.relname                        AS partitioned_table,
       count(i.inhrelid)                AS partitions,
       pg_size_pretty(sum(pg_total_relation_size(i.inhrelid))) AS total_size
FROM pg_class c
JOIN pg_inherits i ON i.inhparent = c.oid
WHERE c.relkind = 'p'
GROUP BY c.relname
ORDER BY sum(pg_total_relation_size(i.inhrelid)) DESC;
```

```sql
-- 2. Default partitions that have collected rows -- a future ATTACH failure
SELECT c.relname AS default_partition, c.reltuples::bigint AS est_rows
FROM pg_class c
JOIN pg_inherits i ON i.inhrelid = c.oid
WHERE pg_get_expr(c.relpartbound, c.oid) = 'DEFAULT'
  AND c.reltuples > 0;
```

```sql
-- 3. Skew -- are partitions wildly uneven?
SELECT i.inhparent::regclass AS parent,
       c.relname             AS partition,
       c.reltuples::bigint   AS est_rows,
       round(100.0 * c.reltuples /
             NULLIF(sum(c.reltuples) OVER (PARTITION BY i.inhparent), 0), 1) AS pct_of_total
FROM pg_class c
JOIN pg_inherits i ON i.inhrelid = c.oid
WHERE c.relkind = 'r'
ORDER BY i.inhparent::regclass::text, c.reltuples DESC;
```

```sql
-- 4. Partitions missing an index the parent has
SELECT p.relname AS partition, pi.relname AS missing_index_from_parent
FROM pg_class parent
JOIN pg_inherits ti ON ti.inhparent = parent.oid
JOIN pg_class p ON p.oid = ti.inhrelid
JOIN pg_index parent_idx ON parent_idx.indrelid = parent.oid
JOIN pg_class pi ON pi.oid = parent_idx.indexrelid
WHERE parent.relkind = 'p'
  AND NOT EXISTS (
      SELECT 1 FROM pg_inherits ii
      JOIN pg_index ci ON ci.indexrelid = ii.inhrelid
      WHERE ii.inhparent = parent_idx.indexrelid AND ci.indrelid = p.oid);
```

## 16. Checklist

**Design**
- [ ] Partition key appears in **almost every** query's `WHERE` clause
- [ ] Partition key is in the primary key and every unique constraint
- [ ] No requirement for a unique constraint excluding the partition key
- [ ] Partition count will stay under ~1,000 for the data's lifetime
- [ ] Granularity chosen for retention (drop whole partitions), not just for queries
- [ ] DEFAULT partition decision made deliberately — and monitored if present

**Creation**
- [ ] For existing data, method chosen (copy vs `ATTACH`) with **disk space verified**
- [ ] `ATTACH` preceded by a validated `CHECK` constraint to skip the scan
- [ ] Data loaded **before** indexes, not after
- [ ] Parent indexes built with `ON ONLY` + per-partition `CONCURRENTLY` + `ATTACH`

**Maintenance**
- [ ] Future partitions created ahead of need (`pg_partman` or a monitored job)
- [ ] ⚠️ **`ANALYZE <parent>` scheduled explicitly** — autovacuum will not do it
- [ ] Per-partition autovacuum tuning: aggressive on hot, relaxed on cold
- [ ] `autovacuum_enabled` never set to `false` on any partition
- [ ] Archive partitions `VACUUM (FREEZE)`'d once
- [ ] `VACUUM FULL` targeted at partitions, never the parent
- [ ] Extended statistics recreated per partition where needed

**Operations**
- [ ] `DETACH ... CONCURRENTLY` used on PG 14+
- [ ] `lock_timeout` set for all maintenance DDL
- [ ] Parent `ALTER TABLE` scheduled as a full-table outage
- [ ] `max_locks_per_transaction` reviewed if partition counts are high
- [ ] Application SQL addresses the **parent**, never partition names

## 17. Teardown

```sql
DROP SCHEMA partlab CASCADE;
```

---

## Reference

- Table partitioning — https://www.postgresql.org/docs/current/ddl-partitioning.html
- `CREATE TABLE ... PARTITION` — https://www.postgresql.org/docs/current/sql-createtable.html
- `ALTER TABLE ... ATTACH/DETACH PARTITION` — https://www.postgresql.org/docs/current/sql-altertable.html
- Partition pruning — https://www.postgresql.org/docs/current/ddl-partitioning.html#DDL-PARTITION-PRUNING
- Explicit locking — https://www.postgresql.org/docs/current/explicit-locking.html
- Routine vacuuming — https://www.postgresql.org/docs/current/routine-vacuuming.html
- Planner statistics — https://www.postgresql.org/docs/current/planner-stats.html
- `pg_partman` — https://github.com/pgpartman/pg_partman
- Azure — extensions — https://learn.microsoft.com/en-us/azure/postgresql/extensions/concepts-extensions
