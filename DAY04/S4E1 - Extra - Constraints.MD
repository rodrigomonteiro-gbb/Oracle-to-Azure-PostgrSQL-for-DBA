# PostgreSQL Constraints — and What They Do to Your Indexes

## Primary Key, Unique, Foreign Key, Check, Exclusion and the rest

**Audience:** DBAs coming from Oracle and SQL Server
**Companion to:** *PostgreSQL Index Types — Complete Guide with Hands-On Demos*
**Platform:** Azure Database for PostgreSQL Flexible Server (PG 14+; PG 16 assumed)
**All demos are runnable SQL.**

---

## 0. The short answer to the question

> **Do PK / UNIQUE / FK constraints create indexes in PostgreSQL?**

| Constraint | Index created automatically? | What kind | Why |
|---|---|---|---|
| **PRIMARY KEY** | ✅ **YES** | **Unique B-tree** | It is the only way to enforce uniqueness efficiently |
| **UNIQUE** | ✅ **YES** | **Unique B-tree** | Same reason |
| **EXCLUDE** | ✅ **YES** | **GiST** (usually) | Overlap checks need a GiST search |
| **FOREIGN KEY** | ❌ **NO** — on the child side | *(none)* | Enforced by **triggers**, not by an index |
| **CHECK** | ❌ NO | *(none)* | A row-level boolean test; nothing to search |
| **NOT NULL** | ❌ NO | *(none)* | A column attribute, not even a table constraint |

**The three sentences that matter:**

1. **`PRIMARY KEY` and `UNIQUE` are, mechanically, a unique B-tree index plus a catalog entry.** The index *is* the enforcement mechanism — it is not a side effect.
2. **`FOREIGN KEY` creates NO index on the referencing (child) column.** This is the single biggest performance trap for Oracle and SQL Server DBAs alike — the same trap exists in all three products, but PostgreSQL punishes it harder because of MVCC.
3. **A `FOREIGN KEY` *requires* a unique index on the referenced (parent) side** — you cannot reference a column that is not `PRIMARY KEY` or `UNIQUE`.

Everything below proves and expands these.

---

## 1. Constraints vs indexes — two different things that overlap

PostgreSQL keeps constraints and indexes in **two separate catalogs**:

| Catalog | Holds | Key columns |
|---|---|---|
| **`pg_constraint`** | Constraint definitions | `conname`, `contype`, `conrelid`, `conindid` |
| **`pg_index`** | Index definitions | `indexrelid`, `indrelid`, `indisunique`, `indisprimary` |

The link between them is **`pg_constraint.conindid`** — the index that *backs* the constraint. For a `CHECK` or `FOREIGN KEY` constraint, that column is `0`: no backing index.

### 1.1 The `contype` codes — memorize these five

```
'p' = PRIMARY KEY
'u' = UNIQUE
'f' = FOREIGN KEY
'c' = CHECK
'x' = EXCLUDE
't' = CONSTRAINT TRIGGER
'n' = NOT NULL   (PG 17+; earlier versions store it as a column attribute only)
```

### 1.2 The query you will use constantly

```sql
-- What constraints exist, and which ones have an index behind them?
SELECT
    c.conname                                   AS constraint_name,
    CASE c.contype
        WHEN 'p' THEN 'PRIMARY KEY'
        WHEN 'u' THEN 'UNIQUE'
        WHEN 'f' THEN 'FOREIGN KEY'
        WHEN 'c' THEN 'CHECK'
        WHEN 'x' THEN 'EXCLUDE'
        WHEN 't' THEN 'TRIGGER'
        ELSE c.contype::text
    END                                         AS constraint_type,
    c.conrelid::regclass                        AS on_table,
    CASE WHEN c.conindid = 0
         THEN '-- none --'
         ELSE c.conindid::regclass::text
    END                                         AS backing_index,
    CASE WHEN c.conindid = 0
         THEN NULL
         ELSE pg_size_pretty(pg_relation_size(c.conindid))
    END                                         AS index_size,
    pg_get_constraintdef(c.oid)                 AS definition
FROM pg_constraint c
JOIN pg_namespace n ON n.oid = c.connamespace
WHERE n.nspname = current_schema()
ORDER BY c.conrelid::regclass::text, c.contype;
```

> **Read the `backing_index` column.** Every `p`, `u`, and `x` row has one. Every `f` and `c` row says `-- none --`. That single output answers the original question definitively, on your own database.

---

## 2. PRIMARY KEY

### 2.1 What it actually is

A `PRIMARY KEY` is **four things bundled together**:

1. A **`NOT NULL`** constraint on every column in the key
2. A **`UNIQUE`** constraint
3. A **unique B-tree index** that enforces #2
4. A catalog flag (`pg_index.indisprimary = true`) marking it as *the* primary key

> ⚠️ **It is NOT a clustered index.** This is the key difference from SQL Server. A PostgreSQL table is always a **heap** (index guide §1), and the primary key index is an ordinary secondary B-tree whose leaves point at `ctid`s. There is **no** physical row ordering. **Oracle DBAs:** it is closest to a non-IOT primary key — index and table are separate objects.

### 2.2 Demo — prove the index is created

```sql
CREATE SCHEMA IF NOT EXISTS conlab;
SET search_path TO conlab, public;

DROP TABLE IF EXISTS pk_demo CASCADE;

CREATE TABLE pk_demo (
    id         bigint PRIMARY KEY,          -- watch what this creates
    email      text,
    created_at timestamptz DEFAULT now()
);
```

PostgreSQL announces it:

```
NOTICE:  CREATE TABLE / PRIMARY KEY will create implicit index "pk_demo_pkey" for table "pk_demo"
```

Confirm in the catalogs:

```sql
-- The index exists, is unique, and is flagged as the primary key
SELECT i.indexrelid::regclass         AS index_name,
       i.indisunique                  AS is_unique,
       i.indisprimary                 AS is_primary,
       am.amname                      AS index_method,
       pg_get_indexdef(i.indexrelid)  AS definition
FROM pg_index i
JOIN pg_class ci ON ci.oid = i.indexrelid
JOIN pg_am    am ON am.oid = ci.relam
WHERE i.indrelid = 'pk_demo'::regclass;
```

Expect **one** row: `pk_demo_pkey`, `is_unique = t`, `is_primary = t`, **`index_method = btree`**.

```sql
-- And the constraint side, linked to that same index
SELECT conname, contype, conindid::regclass AS backing_index
FROM pg_constraint
WHERE conrelid = 'pk_demo'::regclass;
```

### 2.3 The index is not decoration — it does real work

```sql
INSERT INTO pk_demo (id, email)
SELECT g, 'user' || g || '@example.com'
FROM generate_series(1, 2000000) g;

ANALYZE pk_demo;
```

> **👁 What to look for in this plan**
>
> | In the plan | What it means |
> |---|---|
> | **`Index Scan using pk_demo_pkey`** | The **constraint's** index is serving an ordinary query. You never wrote `CREATE INDEX` — the `PRIMARY KEY` declaration built it. |
> | **`Index Cond: (id = 1234567)`** | Located, not filtered. |
> | **`Buffers: shared hit=3..4`** | Root → internal → leaf descent, plus one heap page. |
> | **`actual rows=1`** | The planner knows a unique index returns **at most one row**. That guarantee produces better join plans elsewhere and is worth as much as the lookup speed. |

```sql
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT email FROM pk_demo WHERE id = 1234567;
```

### 2.4 Prove the enforcement

```sql
-- Uniqueness
INSERT INTO pk_demo (id, email) VALUES (1, 'dup@example.com');
-- ERROR:  duplicate key value violates unique constraint "pk_demo_pkey"
-- DETAIL: Key (id)=(1) already exists.

-- NOT NULL, which came free with the PRIMARY KEY
INSERT INTO pk_demo (id, email) VALUES (NULL, 'null@example.com');
-- ERROR:  null value in column "id" of relation "pk_demo" violates not-null constraint
```

> **Note the error names the INDEX (`pk_demo_pkey`), not the constraint.** That is PostgreSQL telling you plainly which mechanism rejected the row.

### 2.5 You cannot drop the index without dropping the constraint

```sql
DROP INDEX pk_demo_pkey;
-- ERROR:  cannot drop index pk_demo_pkey because constraint pk_demo_pkey on table pk_demo requires it
-- HINT:  You can drop constraint pk_demo_pkey on table pk_demo instead.
```

The index is **owned** by the constraint. Dropping the constraint drops the index with it:

```sql
ALTER TABLE pk_demo DROP CONSTRAINT pk_demo_pkey;

-- Verify the index went too
SELECT count(*) AS indexes_remaining
FROM pg_index WHERE indrelid = 'pk_demo'::regclass;   -- 0
```

### 2.6 Composite primary keys and column order

```sql
DROP TABLE IF EXISTS pk_composite CASCADE;

CREATE TABLE pk_composite (
    tenant_id  int,
    order_id   bigint,
    placed_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, order_id)          -- order matters, see below
);
```

The backing index is `(tenant_id, order_id)`, so the **leftmost-prefix rule applies exactly as in the index guide (§4.1)**:

| Query | Uses `pk_composite_pkey`? |
|---|---|
| `WHERE tenant_id = 5` | ✅ Yes — leading column |
| `WHERE tenant_id = 5 AND order_id = 99` | ✅ Yes — full key |
| `WHERE order_id = 99` | ❌ No — non-leading column |

> 💡 **Design point most teams miss:** your primary key is also a free index, so **choose the column order to match your dominant access pattern** — not alphabetically, and not by "importance". In a multi-tenant schema `(tenant_id, order_id)` is almost always right, because every query filters by tenant.

### 2.7 Adding a primary key without locking the table

A plain `ALTER TABLE ... ADD PRIMARY KEY` takes an **`ACCESS EXCLUSIVE`** lock and builds the index inline — the table is unavailable throughout. On a large production table, split it:

```sql
-- Step 1: build the unique index WITHOUT blocking writes
CREATE UNIQUE INDEX CONCURRENTLY pk_demo_id_idx ON pk_demo (id);

-- Step 2: the column must be NOT NULL first
ALTER TABLE pk_demo ALTER COLUMN id SET NOT NULL;

-- Step 3: promote the existing index into a primary key constraint.
--         Nearly instant -- no rebuild, it adopts the index.
ALTER TABLE pk_demo ADD CONSTRAINT pk_demo_pkey PRIMARY KEY USING INDEX pk_demo_id_idx;
```

> **`USING INDEX` is the most useful constraint feature nobody knows about.** It lets you do the expensive part (`CREATE INDEX CONCURRENTLY`) without blocking, then attach the constraint in a metadata-only operation. The index is renamed to the constraint name automatically.
>
> ⚠️ **Caveat:** `USING INDEX` requires a **unique, non-partial, non-expression** B-tree index on plain columns. A partial or expression index cannot back a constraint (§3.5).

---

## 3. UNIQUE constraints and unique indexes

### 3.1 Two ways to spell almost the same thing

```sql
DROP TABLE IF EXISTS uk_demo CASCADE;

CREATE TABLE uk_demo (
    id       bigserial PRIMARY KEY,
    email    text NOT NULL,
    username text NOT NULL,
    tax_id   text
);

-- Way 1: a UNIQUE CONSTRAINT (creates an index behind the scenes)
ALTER TABLE uk_demo ADD CONSTRAINT uk_demo_email_key UNIQUE (email);

-- Way 2: a UNIQUE INDEX directly (no constraint catalog entry)
CREATE UNIQUE INDEX uk_demo_username_idx ON uk_demo (username);
```

Both enforce uniqueness identically. The difference is in the catalog:

```sql
SELECT c.conname, c.contype, c.conindid::regclass AS backing_index
FROM pg_constraint c
WHERE c.conrelid = 'uk_demo'::regclass AND c.contype = 'u';
-- returns uk_demo_email_key ONLY -- the bare unique index has no constraint row

SELECT i.indexrelid::regclass AS index_name, i.indisunique
FROM pg_index i WHERE i.indrelid = 'uk_demo'::regclass;
-- returns the PK, uk_demo_email_key AND uk_demo_username_idx
```

### 3.2 So which should you use?

| | **UNIQUE constraint** | **UNIQUE index** |
|---|---|---|
| Appears in `pg_constraint` | ✅ | ❌ |
| Can be referenced by a **FOREIGN KEY** | ✅ | ✅ *(a unique index is sufficient)* |
| Supports **`DEFERRABLE`** | ✅ | ❌ |
| Can be **partial** (`WHERE ...`) | ❌ | ✅ |
| Can be on an **expression** | ❌ | ✅ |
| Can specify **opclass / collation / `DESC`** | ❌ | ✅ |
| Can be built **`CONCURRENTLY`** | ❌ *(but see `USING INDEX`)* | ✅ |
| Visible to ORM / tool schema introspection | Usually ✅ | Sometimes ❌ |

> **Practical rule:** use a **`UNIQUE` constraint** for plain business keys — it documents intent and tools understand it. Use a **`UNIQUE` index** when you need a partial, expression-based, or concurrently-built rule that a constraint cannot express.

### 3.3 The NULL behavior — a real difference from SQL Server

```sql
-- PostgreSQL treats NULLs as DISTINCT from one another by default
INSERT INTO uk_demo (email, username, tax_id) VALUES ('a@x.com','ua', NULL);
INSERT INTO uk_demo (email, username, tax_id) VALUES ('b@x.com','ub', NULL);

CREATE UNIQUE INDEX uk_demo_tax_idx ON uk_demo (tax_id);
-- Succeeds. Two NULLs do not collide.

INSERT INTO uk_demo (email, username, tax_id) VALUES ('c@x.com','uc', NULL);
-- Also succeeds -- unlimited NULLs allowed
```

| Platform | Multiple NULLs in a unique key? |
|---|---|
| **PostgreSQL** (default) | ✅ Allowed — unlimited |
| **Oracle** | ✅ Allowed (single-column keys) |
| **SQL Server** | ❌ **Only one NULL** |

**To get the SQL Server behavior (PostgreSQL 15+):**

```sql
DROP INDEX uk_demo_tax_idx;
CREATE UNIQUE INDEX uk_demo_tax_idx ON uk_demo (tax_id) NULLS NOT DISTINCT;

INSERT INTO uk_demo (email, username, tax_id) VALUES ('d@x.com','ud', NULL);
-- ERROR: duplicate key value violates unique constraint "uk_demo_tax_idx"
```

Also available on the constraint form:

```sql
ALTER TABLE uk_demo ADD CONSTRAINT uk_tax UNIQUE NULLS NOT DISTINCT (tax_id);
```

> ⚠️ **This is a genuine migration hazard.** A SQL Server schema relying on the one-NULL rule behaves differently in PostgreSQL — silently, with no error. Add it to the pre-migration semantics checklist.

### 3.4 Case-insensitive uniqueness — the expression index case

A `UNIQUE` **constraint** cannot do this. A `UNIQUE` **index** can:

```sql
-- Prevent 'Sam@x.com' and 'sam@x.com' both existing
CREATE UNIQUE INDEX uk_demo_email_ci ON uk_demo (lower(email));

INSERT INTO uk_demo (email, username) VALUES ('A@X.COM', 'ue');
INSERT INTO uk_demo (email, username) VALUES ('a@x.com', 'uf');
-- ERROR: duplicate key value violates unique constraint "uk_demo_email_ci"
```

> **Oracle equivalent:** a function-based unique index — same concept, same shape. **SQL Server has no direct equivalent** (it needs a persisted computed column plus a unique index on it), so this is a genuine PostgreSQL advantage worth calling out in a migration.

### 3.5 Conditional uniqueness — the partial unique index

The single most useful thing a constraint **cannot** do:

```sql
DROP TABLE IF EXISTS subscriptions CASCADE;

CREATE TABLE subscriptions (
    id          bigserial PRIMARY KEY,
    customer_id int  NOT NULL,
    plan        text NOT NULL,
    state       text NOT NULL CHECK (state IN ('ACTIVE','CANCELLED','EXPIRED'))
);

-- "At most ONE active subscription per customer" -- unlimited cancelled ones
CREATE UNIQUE INDEX ux_one_active_sub
    ON subscriptions (customer_id)
    WHERE state = 'ACTIVE';

INSERT INTO subscriptions (customer_id, plan, state) VALUES
    (1, 'basic',   'CANCELLED'),
    (1, 'pro',     'CANCELLED'),
    (1, 'premium', 'ACTIVE');      -- OK

INSERT INTO subscriptions (customer_id, plan, state) VALUES (1, 'gold', 'ACTIVE');
-- ERROR: duplicate key value violates unique constraint "ux_one_active_sub"
```

> **Soft-delete variant** — the same pattern, and probably the most common real use:
> ```sql
> CREATE UNIQUE INDEX ux_active_email
>     ON users (email) WHERE deleted_at IS NULL;
> ```
> Emails are unique among live rows; deleted rows may hold duplicates.

⚠️ **A partial unique index cannot back a `FOREIGN KEY`.** If another table must reference these rows, you need a full unique constraint.

---

## 4. FOREIGN KEY — the one that does NOT create an index

### 4.1 How PostgreSQL actually enforces a foreign key

There is no index on the child side. Instead, PostgreSQL creates **internal constraint triggers** — `AFTER INSERT` / `AFTER UPDATE` on the child, and `AFTER UPDATE` / `AFTER DELETE` on the parent.

```sql
DROP TABLE IF EXISTS orders CASCADE;
DROP TABLE IF EXISTS customers CASCADE;

CREATE TABLE customers (
    customer_id bigserial PRIMARY KEY,       -- creates customers_pkey (unique btree)
    name        text NOT NULL,
    region      text
);

CREATE TABLE orders (
    order_id    bigserial PRIMARY KEY,
    customer_id bigint NOT NULL REFERENCES customers(customer_id),  -- FK, NO index
    amount      numeric(12,2) NOT NULL,
    placed_at   timestamptz NOT NULL DEFAULT now()
);
```

**Prove no index was created on `orders.customer_id`:**

```sql
SELECT i.indexrelid::regclass         AS index_name,
       pg_get_indexdef(i.indexrelid)  AS definition
FROM pg_index i
WHERE i.indrelid = 'orders'::regclass;
```

You get **only `orders_pkey`** (on `order_id`). Nothing on `customer_id`.

**See the hidden triggers doing the work:**

```sql
SELECT tgname            AS trigger_name,
       tgrelid::regclass AS on_table,
       tgisinternal      AS internal,
       pg_get_triggerdef(oid) AS definition
FROM pg_trigger
WHERE tgrelid IN ('orders'::regclass, 'customers'::regclass)
  AND tgisinternal
ORDER BY tgrelid::regclass::text;
```

You will see `RI_ConstraintTrigger_*` entries on **both** tables. That is the enforcement mechanism — not an index.

### 4.2 The parent side DOES require a unique index

```sql
DROP TABLE IF EXISTS bad_child CASCADE;
DROP TABLE IF EXISTS bad_parent CASCADE;

CREATE TABLE bad_parent (id int, label text);     -- no PK, no UNIQUE

CREATE TABLE bad_child (
    id     int PRIMARY KEY,
    ref_id int REFERENCES bad_parent(id)
);
-- ERROR:  there is no unique constraint matching given keys for referenced table "bad_parent"
```

> **Why:** a foreign key asks *"does exactly one matching parent row exist?"* Without a uniqueness guarantee that question is ambiguous, and without an index it would mean a sequential scan of the parent on **every child insert**. A unique index provides both the guarantee and the speed.
>
> **A unique *index* is sufficient** — it need not be a declared constraint:
> ```sql
> CREATE UNIQUE INDEX ON bad_parent (id);   -- now the FK above will work
> ```

### 4.3 ⚠️ The unindexed-FK performance trap — measured

This is the most important demo in the document.

```sql
INSERT INTO customers (name, region)
SELECT 'customer_' || g, (ARRAY['us','eu','apac'])[1 + (g % 3)]
FROM generate_series(1, 200000) g;

INSERT INTO orders (customer_id, amount, placed_at)
SELECT (random() * 199999)::int + 1,
       (random() * 1000)::numeric(12,2),
       now() - ((random() * 365) || ' days')::interval
FROM generate_series(1, 3000000);

ANALYZE customers;
ANALYZE orders;
```

#### Trap 1 — the child-side lookup

> **👁 What to look for in this plan**
>
> This is the most common query shape in any relational application: *"give me this parent's children."*
>
> | In the plan | What it means |
> |---|---|
> | **`Seq Scan on orders`** | All 3,000,000 rows read to find ~15. **The foreign key did not help at all** — it is not an access path. |
> | **`Filter: (customer_id = 12345)`** | Read and discarded, not located. |
> | **`Rows Removed by Filter: ~2,999,985`** | The waste, stated numerically. |
> | **`Buffers:`** | The whole table. |
>
> **Say this out loud:** the FK guarantees the value is *valid*. It does nothing to make it *findable*.

```sql
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT order_id, amount FROM orders WHERE customer_id = 12345;
```

#### Trap 2 — the parent-side DELETE (the expensive one)

> **👁 What to look for in this plan**
>
> Deleting **one** parent row forces PostgreSQL to verify no orphans remain.
>
> | In the plan | What it means |
> |---|---|
> | **`Delete on customers`** above a tiny `Index Scan` | The delete itself is trivial — one row. |
> | **`Trigger for constraint orders_customer_id_fkey: time=NNNN.NNN calls=1`** | ⚠️ **THE LINE THAT MATTERS.** It appears *below* the plan tree. This is the RI trigger scanning `orders` for referencing rows. |
> | **Trigger time dwarfs the delete time** | Often by three or four orders of magnitude — a 0.05 ms delete with a 900 ms trigger. |
>
> **`EXPLAIN ANALYZE` reports trigger time separately from the plan tree.** Read only the tree and you will conclude the delete was instant, and be completely wrong.

```sql
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
DELETE FROM customers WHERE customer_id = 199999;
```

#### The fix — index the child column yourself

```sql
CREATE INDEX ix_orders_customer_id ON orders (customer_id);
ANALYZE orders;
```

> **👁 Re-run both plans and compare**
>
> **Child lookup:** `Seq Scan` → **`Bitmap Index Scan on ix_orders_customer_id`** (or `Index Scan`); `Filter` → **`Index Cond`**; buffers collapse from hundreds of thousands to single digits.
>
> **Parent delete:** the **`Trigger for constraint ...: time=`** line drops from hundreds of milliseconds to a fraction of one. **Same statement, same data, one index.**

```sql
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT order_id, amount FROM orders WHERE customer_id = 12345;

EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
DELETE FROM customers WHERE customer_id = 199998;
```

### 4.4 Find every unindexed foreign key in your database

**Run this on any database you inherit.** It is the highest-value single query in this document.

```sql
SELECT c.conrelid::regclass                         AS child_table,
       c.conname                                    AS fk_name,
       a.attname                                    AS fk_column,
       c.confrelid::regclass                        AS parent_table,
       pg_size_pretty(pg_relation_size(c.conrelid)) AS child_size,
       'CREATE INDEX CONCURRENTLY ix_'
         || replace(c.conrelid::regclass::text, '.', '_')
         || '_' || a.attname
         || ' ON ' || c.conrelid::regclass || ' (' || quote_ident(a.attname) || ');'
                                                    AS suggested_fix
FROM pg_constraint c
JOIN LATERAL unnest(c.conkey) WITH ORDINALITY AS k(attnum, ord) ON true
JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
WHERE c.contype = 'f'
  AND k.ord = 1                                    -- leading FK column
  AND NOT EXISTS (
        SELECT 1 FROM pg_index i
        WHERE i.indrelid = c.conrelid
          AND i.indisvalid
          AND i.indkey[0] = k.attnum               -- indexed as the LEADING column
  )
ORDER BY pg_relation_size(c.conrelid) DESC;
```

> **Why `indkey[0]`:** an index on `(order_date, customer_id)` does **not** help the FK — the leftmost-prefix rule applies. Only an index whose **first** column is the FK column serves the RI check.

### 4.5 Referential actions — and their index implications

```sql
DROP TABLE IF EXISTS order_items CASCADE;

CREATE TABLE order_items (
    item_id  bigserial PRIMARY KEY,
    order_id bigint NOT NULL
        REFERENCES orders(order_id)
        ON DELETE CASCADE                  -- delete children with the parent
        ON UPDATE CASCADE,                 -- follow parent key changes
    sku      text   NOT NULL,
    qty      int    NOT NULL CHECK (qty > 0)
);

CREATE INDEX ix_order_items_order_id ON order_items (order_id);   -- ALWAYS do this
```

| Action | Behavior on parent delete/update | Index urgency on the child |
|---|---|---|
| **`NO ACTION`** *(default)* | Error if children exist; check **deferred to end of statement** | **High** — RI scan on every parent delete |
| **`RESTRICT`** | Error if children exist; check is **immediate**, cannot be deferred | **High** |
| **`CASCADE`** | Deletes/updates the children too | **Critical** — without an index, a cascade is a seq scan *per parent row* |
| **`SET NULL`** | Sets the child FK column to `NULL` | **Critical** — same reason |
| **`SET DEFAULT`** | Sets the child FK column to its default | **Critical**; the default value must itself exist in the parent |

> ⚠️ **`ON DELETE CASCADE` without a child index is the classic production outage.** Deleting 1,000 parent rows triggers 1,000 sequential scans of a multi-million-row child table. It works fine in dev with 500 rows and falls over at scale.

**PG 15+ can restrict the cascade to specific columns:**

```sql
-- Null out only this one column, not the whole FK
... REFERENCES parent(a, b) ON UPDATE SET NULL (b)
```

### 4.6 Deferrable constraints — check at COMMIT, not per statement

```sql
DROP TABLE IF EXISTS node CASCADE;

CREATE TABLE node (
    id        int PRIMARY KEY,
    parent_id int REFERENCES node(id) DEFERRABLE INITIALLY DEFERRED,
    label     text
);

-- Insert a cycle that is only valid once BOTH rows exist
BEGIN;
  INSERT INTO node (id, parent_id, label) VALUES (1, 2, 'a');   -- 2 doesn't exist yet
  INSERT INTO node (id, parent_id, label) VALUES (2, 1, 'b');
COMMIT;   -- both checks run here, and both pass
```

```sql
-- Defer on demand within a transaction
BEGIN;
  SET CONSTRAINTS ALL DEFERRED;
  -- ... bulk load in arbitrary order ...
COMMIT;
```

| Constraint type | Can be `DEFERRABLE`? |
|---|---|
| `PRIMARY KEY` | ✅ |
| `UNIQUE` | ✅ (constraint form only, not a bare unique index) |
| `FOREIGN KEY` | ✅ |
| `EXCLUDE` | ✅ |
| **`CHECK`** | ❌ **No** — always immediate |
| `NOT NULL` | ❌ No |

> ⚠️ **`DEFERRABLE INITIALLY DEFERRED` has a cost:** PostgreSQL queues every pending check until commit, consuming memory proportional to the number of affected rows. On a huge bulk load that is significant. Prefer `DEFERRABLE INITIALLY IMMEDIATE` and defer explicitly with `SET CONSTRAINTS` only where you need it.

### 4.7 `MATCH FULL` vs `MATCH SIMPLE` — composite FK NULL handling

```sql
-- MATCH SIMPLE (the default): if ANY column is NULL, the check is SKIPPED
-- MATCH FULL: either ALL columns are NULL, or none are

CREATE TABLE fk_match_demo (
    a int, b int,
    FOREIGN KEY (a, b) REFERENCES pk_composite (tenant_id, order_id) MATCH FULL
);
-- (a=1, b=NULL) is now REJECTED; under MATCH SIMPLE it would be silently allowed
```

> **Migration note:** Oracle's default composite-FK behavior matches `MATCH SIMPLE`, so the PostgreSQL default is safe — but `MATCH FULL` is usually what the data model actually meant.

---

## 5. CHECK constraints

### 5.1 What they are — and what they are not

A `CHECK` is a boolean expression evaluated **per row, on insert and update**. It creates **no index** and provides **no access path**.

```sql
DROP TABLE IF EXISTS products CASCADE;

CREATE TABLE products (
    product_id  bigserial PRIMARY KEY,
    sku         text          NOT NULL,
    price       numeric(12,2) NOT NULL CHECK (price > 0),
    discount    numeric(5,2)  CHECK (discount >= 0 AND discount <= 100),
    status      text          NOT NULL,
    launch_date date,
    end_date    date,

    -- Named table-level checks -- ALWAYS name them; auto-generated names are unreadable
    CONSTRAINT ck_products_status
        CHECK (status IN ('DRAFT','ACTIVE','DISCONTINUED')),
    CONSTRAINT ck_products_dates
        CHECK (end_date IS NULL OR launch_date IS NULL OR end_date >= launch_date),
    CONSTRAINT ck_products_sku_format
        CHECK (sku ~ '^[A-Z]{3}-[0-9]{6}$')
);
```

```sql
INSERT INTO products (sku, price, status) VALUES ('ABC-123456', -5, 'ACTIVE');
-- ERROR: new row for relation "products" violates check constraint "products_price_check"

INSERT INTO products (sku, price, status) VALUES ('bad-sku', 10, 'ACTIVE');
-- ERROR: ... violates check constraint "ck_products_sku_format"
```

**Confirm there is no index:**

```sql
SELECT conname, contype, conindid AS backing_index_oid
FROM pg_constraint
WHERE conrelid = 'products'::regclass AND contype = 'c';
-- backing_index_oid = 0 for every row
```

### 5.2 ⚠️ The NULL trap in CHECK constraints

**A `CHECK` passes when the expression evaluates to `NULL`** — only an explicit `FALSE` rejects the row.

```sql
INSERT INTO products (sku, price, status, discount)
VALUES ('XYZ-999999', 10, 'ACTIVE', NULL);
-- SUCCEEDS. NULL >= 0 is NULL, not FALSE, so the CHECK does not reject it.
```

If the value must be present, say so explicitly:

```sql
ALTER TABLE products
    ADD CONSTRAINT ck_products_discount_required
    CHECK (discount IS NOT NULL AND discount BETWEEN 0 AND 100);
```

> **This behavior is identical in Oracle and SQL Server**, but it catches people on every platform. Worth stating explicitly in a schema review.

### 5.3 CHECK constraints and the planner — a hidden benefit

The planner **can** use a `CHECK` to prove a query returns nothing — *constraint exclusion*:

```sql
EXPLAIN (COSTS OFF)
SELECT * FROM products WHERE price < 0;
```

> **👁 What to look for**
>
> Look for a **`One-Time Filter: false`** node, or a `Result` node with no scan beneath it. **PostgreSQL proved from `CHECK (price > 0)` that no row can satisfy `price < 0`, and skipped the table entirely.** It read zero pages.
>
> This is the same machinery behind **partition pruning** — each partition carries an implicit `CHECK` on its bounds, and the planner uses it to skip partitions. **A `CHECK` constraint is therefore not purely a data-quality tool; it is also planner metadata.**

### 5.4 Adding a CHECK to a large table without a long lock

`ALTER TABLE ... ADD CHECK` scans the whole table to validate, holding a lock throughout. Split it:

```sql
-- Step 1: add it WITHOUT validating existing rows. Fast, metadata-only.
--         New and updated rows are enforced immediately.
ALTER TABLE products
    ADD CONSTRAINT ck_products_price_sane CHECK (price < 1000000) NOT VALID;

-- Step 2: validate existing rows later, under a much weaker lock
--         (SHARE UPDATE EXCLUSIVE -- concurrent reads AND writes continue)
ALTER TABLE products VALIDATE CONSTRAINT ck_products_price_sane;
```

```sql
-- Find constraints still sitting in NOT VALID state
SELECT conrelid::regclass AS table_name, conname, contype, convalidated
FROM pg_constraint
WHERE NOT convalidated;
```

> **`NOT VALID` works for `CHECK` and `FOREIGN KEY`**, and it is the standard technique for adding constraints to large live tables.
>
> ⚠️ **But note:** a `NOT VALID` constraint is **not used for constraint exclusion** (§5.3) until validated — the planner will not trust an unproven claim.

---

## 6. EXCLUSION constraints — the one with no Oracle or SQL Server equivalent

### 6.1 What it does

`EXCLUDE` generalizes `UNIQUE`. Where `UNIQUE` says *"no two rows may have equal values"*, `EXCLUDE` says *"no two rows may satisfy **this operator**"* — which can be `=`, but can also be `&&` (overlaps), `~=` (same shape), or any operator with the right properties.

**It creates an index — a GiST index by default.**

### 6.2 Demo — declarative double-booking prevention

```sql
CREATE EXTENSION IF NOT EXISTS btree_gist;   -- lets GiST index scalar types too

DROP TABLE IF EXISTS room_booking CASCADE;

CREATE TABLE room_booking (
    id      bigserial PRIMARY KEY,
    room_id int   NOT NULL,
    guest   text  NOT NULL,
    stay    tstzrange NOT NULL,

    CONSTRAINT no_double_booking
        EXCLUDE USING gist (room_id WITH =, stay WITH &&)
);
```

```sql
INSERT INTO room_booking (room_id, guest, stay) VALUES
 (101, 'Silva',    tstzrange('2026-03-01','2026-03-05')),
 (101, 'Smith',    tstzrange('2026-03-05','2026-03-09')),   -- adjacent, OK
 (102, 'Nakamura', tstzrange('2026-03-02','2026-03-06'));

INSERT INTO room_booking (room_id, guest, stay)
VALUES (101, 'Okafor', tstzrange('2026-03-04','2026-03-07'));
-- ERROR:  conflicting key value violates exclusion constraint "no_double_booking"
```

**Confirm the index:**

```sql
SELECT c.conname, c.contype,
       c.conindid::regclass        AS backing_index,
       am.amname                   AS index_method,
       pg_get_constraintdef(c.oid) AS definition
FROM pg_constraint c
JOIN pg_class ci ON ci.oid = c.conindid
JOIN pg_am    am ON am.oid = ci.relam
WHERE c.conrelid = 'room_booking'::regclass AND c.contype = 'x';
```

`index_method` = **`gist`**.

### 6.3 The constraint's index also serves your queries

> **👁 What to look for in this plan**
>
> | In the plan | What it means |
> |---|---|
> | **`Index Scan` / `Bitmap Index Scan` on `no_double_booking`** | **Note the index name is the constraint name.** You never wrote `CREATE INDEX`. One object does correctness enforcement *and* read acceleration. |
> | **`Index Cond: (stay && '[...]'::tstzrange)`** | The overlap operator drives the lookup. GiST stores a bounding range per subtree and discards branches that cannot overlap. |
> | **`Recheck Cond`** + **`Rows Removed by Index Recheck`** | GiST is **lossy** — it returns candidates from approximations, then PostgreSQL applies the exact operator. A nonzero recheck count is normal. |
>
> **The operational point:** every `INSERT` runs this same overlap search to enforce the constraint. Without the GiST index the constraint would be unenforceable at any real write rate — which is exactly why Oracle and SQL Server need triggers or serialized application logic here, with all the race conditions that implies.

```sql
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT count(*) FROM room_booking
WHERE stay && tstzrange('2026-03-03','2026-03-06');
```

### 6.4 Other exclusion patterns worth knowing

```sql
-- No two overlapping assignments for the same employee
CREATE TABLE assignment (
    emp_id     int NOT NULL,
    project_id int NOT NULL,
    period     daterange NOT NULL,
    EXCLUDE USING gist (emp_id WITH =, period WITH &&)
);

-- No overlapping IP ranges
CREATE TABLE ip_allocation (
    id      bigserial PRIMARY KEY,
    network inet NOT NULL,
    EXCLUDE USING gist (network inet_ops WITH &&)
);

-- EXCLUDE can also emulate UNIQUE -- useful when you want a deferrable btree
CREATE TABLE uniq_via_exclude (
    code text,
    EXCLUDE USING btree (code WITH =) DEFERRABLE INITIALLY DEFERRED
);
```

---

## 7. NOT NULL, DEFAULT, IDENTITY and GENERATED

### 7.1 NOT NULL

**Not a table constraint in the traditional sense** — it is a column attribute (`pg_attribute.attnotnull`). No index, and no `pg_constraint` row in PG 16 and earlier.

```sql
ALTER TABLE products ALTER COLUMN sku SET NOT NULL;
ALTER TABLE products ALTER COLUMN sku DROP NOT NULL;

-- Find nullable columns that probably should not be
SELECT table_name, column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_schema = 'conlab' AND is_nullable = 'YES'
ORDER BY table_name, ordinal_position;
```

> **PG 11+ optimization worth knowing:** adding a `NOT NULL` column **with a default** no longer rewrites the table — the default is stored in the catalog and applied on read. Before PG 11 this rewrote every row and was a notorious outage cause on large tables.

### 7.2 IDENTITY vs `serial` — use IDENTITY

```sql
DROP TABLE IF EXISTS id_demo CASCADE;

CREATE TABLE id_demo (
    -- SQL-standard, and what you should use in new schemas
    id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name text NOT NULL
);

-- GENERATED BY DEFAULT AS IDENTITY allows explicit inserts; ALWAYS does not
INSERT INTO id_demo (id, name) VALUES (1, 'x');
-- ERROR: cannot insert a non-DEFAULT value into column "id"
-- (override with OVERRIDING SYSTEM VALUE if you must)
```

| | `serial` | `GENERATED ... AS IDENTITY` |
|---|---|---|
| Standard SQL | ❌ PostgreSQL-specific | ✅ |
| Sequence ownership | Loosely coupled | Properly owned; dropped with the column |
| Can block manual inserts | ❌ | ✅ (`ALWAYS`) |
| Recommended for new work | ❌ | ✅ |

> **Oracle mapping:** `GENERATED ALWAYS AS IDENTITY` is the direct equivalent of Oracle 12c+ identity columns. Pre-12c sequence + trigger patterns should convert to **this**, not to `serial`.

### 7.3 Generated (computed) columns

```sql
DROP TABLE IF EXISTS gen_demo CASCADE;

CREATE TABLE gen_demo (
    id     bigserial PRIMARY KEY,
    first  text NOT NULL,
    last   text NOT NULL,
    -- STORED is the only option in current PostgreSQL
    full_name text GENERATED ALWAYS AS (first || ' ' || last) STORED
);

-- Generated columns CAN be indexed
CREATE INDEX ix_gen_demo_full ON gen_demo (full_name);

-- And they can carry constraints
ALTER TABLE gen_demo ADD CONSTRAINT ck_full_len CHECK (length(full_name) < 200);
```

> **Compare with an expression index** (index guide §5): a generated column **materializes** the value (storage cost, available to `SELECT`); an expression index computes it **only inside the index** (no table storage, not selectable). For a value you both query *and* display, use a generated column; for one you only filter on, use an expression index.

---

## 8. DOMAIN constraints — reusable rules

A `DOMAIN` is a named type with constraints attached. Define once, apply everywhere.

```sql
CREATE DOMAIN email_address AS text
    CHECK (VALUE ~ '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$');

CREATE DOMAIN positive_money AS numeric(14,2)
    CHECK (VALUE > 0);

CREATE DOMAIN iso_country AS char(2)
    CHECK (VALUE ~ '^[A-Z]{2}$');

DROP TABLE IF EXISTS domain_demo CASCADE;

CREATE TABLE domain_demo (
    id      bigserial PRIMARY KEY,
    email   email_address  NOT NULL,
    price   positive_money NOT NULL,
    country iso_country    NOT NULL
);

INSERT INTO domain_demo (email, price, country) VALUES ('not-an-email', 10, 'US');
-- ERROR: value for domain email_address violates check constraint "email_address_check"
```

> **Why this beats repeating `CHECK`:** the rule lives in one place. Change the domain and every column using it inherits the change. **Oracle DBAs:** conceptually similar to a user-defined type with a constraint, but far lighter weight and directly usable as a column type.

**Domains create no index.** They are validation only.

---

## 9. Constraint reference tables

### 9.1 Index behavior at a glance

| Constraint | Index? | Method | Enforcement mechanism | Deferrable |
|---|---|---|---|---|
| `PRIMARY KEY` | ✅ | unique B-tree | The index itself | ✅ |
| `UNIQUE` (constraint) | ✅ | unique B-tree | The index itself | ✅ |
| `UNIQUE INDEX` | ✅ | unique B-tree | The index itself | ❌ |
| `EXCLUDE` | ✅ | **GiST** (or B-tree / SP-GiST / hash) | Index search per write | ✅ |
| `FOREIGN KEY` | ❌ **child side** | — | **Internal RI triggers** | ✅ |
| `CHECK` | ❌ | — | Per-row expression | ❌ |
| `NOT NULL` | ❌ | — | Column attribute | ❌ |
| `DOMAIN ... CHECK` | ❌ | — | Type-level expression | ❌ |

### 9.2 Cross-platform comparison

| Behavior | **PostgreSQL** | **Oracle** | **SQL Server** |
|---|---|---|---|
| PK creates an index | ✅ Unique B-tree (non-clustered) | ✅ Unique index | ✅ **Clustered** by default |
| PK physically orders the table | ❌ Never | ❌ (unless IOT) | ✅ (clustered) |
| UNIQUE creates an index | ✅ | ✅ | ✅ |
| Multiple NULLs in a unique key | ✅ Unlimited *(default)* | ✅ Single-column only | ❌ One only |
| FK auto-indexes the child column | ❌ | ❌ | ❌ |
| FK requires a unique parent key | ✅ | ✅ | ✅ |
| Partial / filtered unique | ✅ Partial index | ⚠️ Function-based workaround | ✅ Filtered index |
| Case-insensitive unique | ✅ Expression index | ✅ Function-based index | ⚠️ Computed column required |
| **Exclusion constraint** | ✅ **Unique to PostgreSQL** | ❌ | ❌ |
| Deferrable constraints | ✅ PK/UK/FK/EXCLUDE | ✅ | ⚠️ Very limited |
| `CHECK` used for planner pruning | ✅ | ✅ | ✅ |
| Add constraint without a full scan | ✅ `NOT VALID` | ✅ `ENABLE NOVALIDATE` | ✅ `WITH NOCHECK` |
| Disable a constraint temporarily | ❌ **Not supported** | ✅ `DISABLE CONSTRAINT` | ✅ `NOCHECK CONSTRAINT` |

> ⚠️ **PostgreSQL has no `DISABLE CONSTRAINT`.** To bulk-load past a constraint you must **drop and recreate** it, or use `SET CONSTRAINTS ALL DEFERRED` if it is deferrable. Oracle migration scripts that disable constraints for a load need rewriting — this belongs on the pre-migration gap list.

---

## 10. Operational recipes

### 10.1 Full constraint and index inventory for a table

```sql
\d+ orders
```

Or in pure SQL:

```sql
SELECT 'CONSTRAINT' AS object_kind,
       c.conname    AS name,
       CASE c.contype WHEN 'p' THEN 'PRIMARY KEY' WHEN 'u' THEN 'UNIQUE'
                      WHEN 'f' THEN 'FOREIGN KEY' WHEN 'c' THEN 'CHECK'
                      WHEN 'x' THEN 'EXCLUDE' ELSE c.contype::text END AS kind,
       pg_get_constraintdef(c.oid) AS definition,
       CASE WHEN c.conindid = 0 THEN NULL
            ELSE pg_size_pretty(pg_relation_size(c.conindid)) END AS size
FROM pg_constraint c
WHERE c.conrelid = 'orders'::regclass
UNION ALL
SELECT 'INDEX',
       i.indexrelid::regclass::text,
       CASE WHEN i.indisprimary THEN 'PK index'
            WHEN i.indisunique  THEN 'Unique index'
            ELSE 'Index' END,
       pg_get_indexdef(i.indexrelid),
       pg_size_pretty(pg_relation_size(i.indexrelid))
FROM pg_index i
WHERE i.indrelid = 'orders'::regclass
ORDER BY object_kind, name;
```

### 10.2 Find duplicate protection — constraint AND index on the same columns

Creating a `UNIQUE` constraint when a unique index already exists leaves you with **two** indexes doing the same job.

```sql
SELECT i.indrelid::regclass AS table_name,
       array_agg(i.indexrelid::regclass) AS redundant_indexes,
       pg_size_pretty(sum(pg_relation_size(i.indexrelid))) AS total_size
FROM pg_index i
GROUP BY i.indrelid, i.indkey, i.indclass, i.indpred, i.indisunique
HAVING count(*) > 1;
```

### 10.3 Validate all constraints after a bulk load or migration

```sql
-- Anything still NOT VALID?
SELECT conrelid::regclass AS table_name, conname,
       CASE contype WHEN 'c' THEN 'CHECK' WHEN 'f' THEN 'FOREIGN KEY' END AS kind,
       'ALTER TABLE ' || conrelid::regclass || ' VALIDATE CONSTRAINT '
         || quote_ident(conname) || ';' AS fix
FROM pg_constraint
WHERE NOT convalidated
ORDER BY conrelid::regclass::text;
```

### 10.4 Find orphaned rows before adding a foreign key

```sql
-- Child rows whose parent does not exist -- ADD CONSTRAINT will fail on these
SELECT o.customer_id, count(*) AS orphan_rows
FROM orders o
LEFT JOIN customers c ON c.customer_id = o.customer_id
WHERE c.customer_id IS NULL
GROUP BY o.customer_id
ORDER BY orphan_rows DESC
LIMIT 20;
```

### 10.5 Bulk-load pattern — constraints last

```sql
BEGIN;

-- 1. Drop FK constraints on the target (keep the PK if you can)
ALTER TABLE orders DROP CONSTRAINT orders_customer_id_fkey;

-- 2. Drop non-essential indexes
DROP INDEX IF EXISTS ix_orders_customer_id;

-- 3. Load with COPY, not INSERT
--    COPY orders FROM '/path/orders.csv' WITH (FORMAT csv, HEADER);

-- 4. Rebuild indexes
CREATE INDEX ix_orders_customer_id ON orders (customer_id);

-- 5. Re-add the FK as NOT VALID (instant)
ALTER TABLE orders ADD CONSTRAINT orders_customer_id_fkey
    FOREIGN KEY (customer_id) REFERENCES customers(customer_id) NOT VALID;

COMMIT;

-- 6. Validate outside the transaction, under a weak lock
ALTER TABLE orders VALIDATE CONSTRAINT orders_customer_id_fkey;
ANALYZE orders;
```

---

## 11. Checklist — constraints and indexes review

Run through this on any schema you inherit or migrate.

**Primary keys**
- [ ] Every table has a primary key (or a documented reason it does not)
- [ ] Composite PK column order matches the dominant query pattern
- [ ] New schemas use `GENERATED ALWAYS AS IDENTITY`, not `serial`
- [ ] No PK on a wide or volatile natural key where a surrogate would serve better

**Unique constraints**
- [ ] Business keys have `UNIQUE` constraints, not just application-level checks
- [ ] NULL semantics reviewed — `NULLS NOT DISTINCT` where the source platform assumed it
- [ ] Case sensitivity of text keys is deliberate (expression index where needed)
- [ ] Soft-delete / status-scoped uniqueness uses **partial unique indexes**

**Foreign keys** ⚠️ *the section that matters most*
- [ ] **Every FK child column has an index with that column LEADING** (run §4.4)
- [ ] `ON DELETE CASCADE` / `SET NULL` columns are indexed — **non-negotiable**
- [ ] Referential actions are deliberate, not accidental defaults
- [ ] `MATCH FULL` used where composite FKs must be all-or-nothing
- [ ] No `NOT VALID` FKs left unvalidated after a migration

**Check constraints**
- [ ] All named explicitly — no `products_price_check1` auto-names
- [ ] NULL behavior considered (`IS NOT NULL AND ...` where required)
- [ ] Large-table additions used `NOT VALID` + `VALIDATE`
- [ ] No `CHECK` doing work a `DOMAIN` or a proper data type should do

**Exclusion constraints**
- [ ] Used wherever "no overlap" is a business rule (booking, scheduling, versioning)
- [ ] `btree_gist` installed where scalar equality is mixed with range overlap
- [ ] Replaced any trigger-based overlap logic inherited from Oracle/SQL Server

**General**
- [ ] No redundant constraint + index pair on the same columns (§10.2)
- [ ] Index sizes reviewed — constraint-backed indexes count toward your storage
- [ ] Bulk-load procedures rewritten — **PostgreSQL cannot disable constraints**

---

## 12. Lab teardown

```sql
DROP SCHEMA conlab CASCADE;
DROP DOMAIN IF EXISTS email_address, positive_money, iso_country;
```

---

## Reference

- Constraints — https://www.postgresql.org/docs/current/ddl-constraints.html
- `CREATE TABLE` (constraint syntax) — https://www.postgresql.org/docs/current/sql-createtable.html
- `ALTER TABLE` — https://www.postgresql.org/docs/current/sql-altertable.html
- Unique indexes — https://www.postgresql.org/docs/current/indexes-unique.html
- Exclusion constraints — https://www.postgresql.org/docs/current/ddl-constraints.html#DDL-CONSTRAINTS-EXCLUSION
- `pg_constraint` catalog — https://www.postgresql.org/docs/current/catalog-pg-constraint.html
- `pg_index` catalog — https://www.postgresql.org/docs/current/catalog-pg-index.html
- Range types — https://www.postgresql.org/docs/current/rangetypes.html
- `btree_gist` — https://www.postgresql.org/docs/current/btree-gist.html
- Domains — https://www.postgresql.org/docs/current/sql-createdomain.html
- Identity columns — https://www.postgresql.org/docs/current/sql-createtable.html#SQL-CREATETABLE-PARMS-GENERATED-IDENTITY
