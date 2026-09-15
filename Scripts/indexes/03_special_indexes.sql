-- =====================================================================
-- 03_special_indexes.sql
--
--   PARTIAL     index only the rows you query        (no Oracle equivalent)
--   EXPRESSION  index a computed value               (Oracle: function-based)
--   COVERING    INCLUDE payload -> Index Only Scan   (Oracle: covering index)
--   UNIQUE      constraint + index, incl. partial-unique
--   MULTICOLUMN unique across columns
--
-- Every section is a BEFORE/AFTER with cost and size comparison.
-- =====================================================================

-- \pset pager off
-- \timing on

ANALYZE sales.salesorderheader;
ANALYZE person.person;
ANALYZE production.product;

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART A - PARTIAL INDEXES: the PostgreSQL superpower           #'
-- \echo '################################################################'
-- \echo '  Index only the rows matching a WHERE clause. Smaller index,'
-- \echo '  hotter in cache, and NO write cost for excluded rows.'
-- \echo '  Oracle needs a function-based index trick to approximate this.'
-- \echo ''

-- \echo '  -- How skewed is status? Skew is what makes partial indexes win.'
SELECT status, count(*) AS rows,
       round(100.0 * count(*) / sum(count(*)) OVER (), 2) AS pct
FROM sales.salesorderheader GROUP BY status ORDER BY 2 DESC;

DROP INDEX IF EXISTS sales.ix_lab_status_full;
DROP INDEX IF EXISTS sales.ix_lab_status_partial;

-- \echo ''
-- \echo '  -- A1. Full index on every row:'
CREATE INDEX ix_lab_status_full ON sales.salesorderheader (orderdate);

-- \echo '  -- A2. Partial index on the interesting rows only:'
CREATE INDEX ix_lab_status_partial ON sales.salesorderheader (orderdate)
    WHERE status <> 5;

ANALYZE sales.salesorderheader;

-- \echo ''
-- \echo '  *** SIZE COMPARISON ***'
SELECT indexrelid::regclass AS index_name,
       pg_size_pretty(pg_relation_size(indexrelid)) AS size,
       pg_relation_size(indexrelid) AS bytes
FROM pg_index
WHERE indexrelid IN ('sales.ix_lab_status_full'::regclass,
                     'sales.ix_lab_status_partial'::regclass)
ORDER BY bytes DESC;

-- \echo ''
-- \echo '  -- A3. Query matching the partial predicate -> index usable:'
EXPLAIN (ANALYZE, BUFFERS)
SELECT salesorderid, orderdate FROM sales.salesorderheader
WHERE status <> 5 AND orderdate >= DATE '2013-01-01';

-- \echo ''
-- \echo '  -- A4. THE GOTCHA: no status predicate -> partial index IGNORED'
EXPLAIN (ANALYZE)
SELECT salesorderid, orderdate FROM sales.salesorderheader
WHERE orderdate >= DATE '2013-01-01';

-- \echo ''
-- \echo '  >>> The planner must PROVE the query predicate implies the index'
-- \echo '      predicate. It cannot, so the index is silently unusable.'
-- \echo '      Surprising the first time you meet it - demo it deliberately'
-- \echo '      so nobody discovers it in production.'
-- \echo ''
-- \echo '      REAL-WORLD PATTERNS worth naming:'
-- \echo '        WHERE deleted_at IS NULL     soft-delete tables'
-- \echo '        WHERE status = ''pending''     job queues - index 1% of rows'
-- \echo '        WHERE active = true          user tables'
-- \echo '        WHERE amount > 10000         exception reporting'
-- \echo ''
-- \echo '      Pitch: "On a 500-million-row orders table where 2% are open,'
-- \echo '       a partial index is 2% of the size, 2% of the write cost,'
-- \echo '       and stays entirely in memory. That is not a tuning tweak,'
-- \echo '       that is an architectural difference."'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART B - EXPRESSION INDEXES (Oracle: function-based)          #'
-- \echo '################################################################'
-- \echo '  Wrapping a column in a function makes the predicate'
-- \echo '  non-sargable AND hides the column statistics. An expression'
-- \echo '  index fixes BOTH - and the statistics half is often the'
-- \echo '  bigger win.'
-- \echo ''

DROP INDEX IF EXISTS person.ix_lab_upper_lastname;
DROP INDEX IF EXISTS person.ix_lab_lastname_plain;
CREATE INDEX ix_lab_lastname_plain ON person.person (lastname);
ANALYZE person.person;

-- \echo '  -- B1. BEFORE: function on the column, plain index unusable'
EXPLAIN (ANALYZE, BUFFERS)
SELECT businessentityid, lastname FROM person.person
WHERE upper(lastname) = 'SMITH';

-- \echo ''
-- \echo '  -- B2. AFTER: index the expression itself'
CREATE INDEX ix_lab_upper_lastname ON person.person (upper(lastname));
ANALYZE person.person;

EXPLAIN (ANALYZE, BUFFERS)
SELECT businessentityid, lastname FROM person.person
WHERE upper(lastname) = 'SMITH';

-- \echo ''
-- \echo '  >>> The expression must match the query EXACTLY.'
-- \echo '      Index on upper(lastname) does NOT serve lower(lastname).'
-- \echo ''

-- \echo '  -- B3. Statistics on the EXPRESSION - the hidden benefit:'
SELECT tablename, attname, n_distinct, null_frac
FROM pg_stats
WHERE schemaname='person' AND tablename LIKE 'ix_lab_upper%';

-- \echo ''
-- \echo '      PostgreSQL gathers statistics for expression indexes, so the'
-- \echo '      planner now has a real estimate for upper(lastname) instead'
-- \echo '      of a hardcoded guess. Same trick Oracle uses.'
-- \echo ''

-- \echo '  -- B4. Date-truncation: the most common real-world case'
DROP INDEX IF EXISTS sales.ix_lab_order_month;
CREATE INDEX ix_lab_order_month
    ON sales.salesorderheader (date_trunc('month', orderdate));
ANALYZE sales.salesorderheader;

EXPLAIN (ANALYZE, BUFFERS)
SELECT date_trunc('month', orderdate) AS mth, count(*), sum(totaldue)
FROM sales.salesorderheader
WHERE date_trunc('month', orderdate) = DATE '2013-06-01'
GROUP BY 1;

-- \echo ''
-- \echo '      BUT STILL SAY THIS: the sargable rewrite is better when you'
-- \echo '      control the SQL -'
-- \echo '        WHERE orderdate >= ''2013-06-01'' AND orderdate < ''2013-07-01'''
-- \echo '      - because a plain index on orderdate then serves ALL date'
-- \echo '      ranges, not just month boundaries. Expression indexes are'
-- \echo '      for SQL you cannot change.'
-- \echo ''

-- \echo '  -- B5. Case-insensitive uniqueness, a classic migration need:'
DROP INDEX IF EXISTS production.ix_lab_product_name_ci;
CREATE UNIQUE INDEX ix_lab_product_name_ci
    ON production.product (lower(name));
ANALYZE production.product;

EXPLAIN (ANALYZE)
SELECT productid, name FROM production.product
WHERE lower(name) = 'mountain-100 black, 38';

-- \echo ''
-- \echo '      A UNIQUE expression index enforces case-insensitive'
-- \echo '      uniqueness - something an ordinary constraint cannot do.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART C - COVERING INDEXES (INCLUDE) -> Index Only Scan        #'
-- \echo '################################################################'
-- \echo '  Two ways to cover a query:'
-- \echo '    (a) composite  (a, b, c)          searchable AND returnable'
-- \echo '    (b) INCLUDE    (a) INCLUDE (b, c) payload only, smaller'
-- \echo ''

DROP INDEX IF EXISTS sales.ix_lab_cover_none;
DROP INDEX IF EXISTS sales.ix_lab_cover_composite;
DROP INDEX IF EXISTS sales.ix_lab_cover_include;

-- \echo '  -- C1. Plain index: index seek + HEAP FETCH for the payload'
CREATE INDEX ix_lab_cover_none ON sales.salesorderheader (customerid);
ANALYZE sales.salesorderheader;

EXPLAIN (ANALYZE, BUFFERS)
SELECT customerid, orderdate, totaldue FROM sales.salesorderheader
WHERE customerid BETWEEN 11000 AND 11500;

-- \echo ''
-- \echo '      Note the buffer count - most of it is the heap fetch.'
-- \echo ''

-- \echo '  -- C2. INCLUDE: payload lives in the index leaf'
DROP INDEX sales.ix_lab_cover_none;
CREATE INDEX ix_lab_cover_include
    ON sales.salesorderheader (customerid) INCLUDE (orderdate, totaldue);
VACUUM (ANALYZE) sales.salesorderheader;

EXPLAIN (ANALYZE, BUFFERS)
SELECT customerid, orderdate, totaldue FROM sales.salesorderheader
WHERE customerid BETWEEN 11000 AND 11500;

-- \echo ''
-- \echo '  >>> "Index Only Scan" + "Heap Fetches: 0". Buffers should drop'
-- \echo '      sharply.'
-- \echo ''
-- \echo '      *** THE VACUUM ABOVE IS NOT DECORATION. ***'
-- \echo '      PostgreSQL stores row VISIBILITY in the heap, not the index.'
-- \echo '      An Index Only Scan is only truly index-only when the'
-- \echo '      visibility map marks those pages all-visible - and VACUUM is'
-- \echo '      what maintains that map.'
-- \echo ''
-- \echo '      So in PostgreSQL, VACUUM is not just space reclamation:'
-- \echo '      IT IS WHAT KEEPS YOUR INDEX ONLY SCANS INDEX-ONLY.'
-- \echo '      A genuine operational difference from Oracle - name it.'
-- \echo ''

-- \echo '  -- C3. INCLUDE vs composite: size and capability'
CREATE INDEX ix_lab_cover_composite
    ON sales.salesorderheader (customerid, orderdate, totaldue);
ANALYZE sales.salesorderheader;

SELECT indexrelid::regclass AS index_name,
       pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_index
WHERE indexrelid IN ('sales.ix_lab_cover_include'::regclass,
                     'sales.ix_lab_cover_composite'::regclass);

-- \echo ''
-- \echo '      Composite:  columns are SEARCHABLE and sortable, bigger,'
-- \echo '                  and can serve ORDER BY customerid, orderdate'
-- \echo '      INCLUDE:    payload is NOT searchable, smaller leaf entries,'
-- \echo '                  and INCLUDE columns may be types with no'
-- \echo '                  B-tree operator class at all'
-- \echo ''
-- \echo '      Rule of thumb: if you FILTER or SORT on it, put it in the key.'
-- \echo '      If you only SELECT it, put it in INCLUDE.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART D - UNIQUE, and the partial-unique trick                 #'
-- \echo '################################################################'

DROP INDEX IF EXISTS idx_lab.ix_lab_uniq_active_email;
CREATE SCHEMA IF NOT EXISTS idx_lab;

DROP TABLE IF EXISTS idx_lab.account;
CREATE TABLE idx_lab.account (
  account_id  bigserial PRIMARY KEY,
  email       text NOT NULL,
  deleted_at  timestamptz
);

-- \echo '  -- Requirement: email unique among ACTIVE accounts only.'
-- \echo '     Soft-deleted rows may reuse the address. A plain UNIQUE'
-- \echo '     constraint cannot express this. A PARTIAL UNIQUE INDEX can.'

CREATE UNIQUE INDEX ix_lab_uniq_active_email
    ON idx_lab.account (email) WHERE deleted_at IS NULL;

INSERT INTO idx_lab.account (email, deleted_at)
VALUES ('sam@contoso.com', NULL);

-- \echo '  -- Soft-delete it, then reuse the address - ALLOWED:'
UPDATE idx_lab.account SET deleted_at = now() WHERE email = 'sam@contoso.com';
INSERT INTO idx_lab.account (email, deleted_at) VALUES ('sam@contoso.com', NULL);

SELECT account_id, email,
       CASE WHEN deleted_at IS NULL THEN 'active' ELSE 'deleted' END AS state
FROM idx_lab.account ORDER BY account_id;

-- \echo ''
-- \echo '  -- A second ACTIVE duplicate - must FAIL:'
DO $$
BEGIN
  INSERT INTO idx_lab.account (email, deleted_at) VALUES ('sam@contoso.com', NULL);
  RAISE NOTICE 'UNEXPECTED: the duplicate was accepted';
EXCEPTION WHEN unique_violation THEN
  RAISE NOTICE 'CORRECT: blocked by the partial unique index - %', SQLERRM;
END $$;

-- \echo ''
-- \echo '   Every soft-delete schema in the world needs this and most'
-- \echo '   people do not know it exists. Reliably gets a reaction.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART E - NULLS NOT DISTINCT (PG 15+)                          #'
-- \echo '################################################################'
-- \echo '  By default every NULL is distinct, so a UNIQUE index permits'
-- \echo '  unlimited NULLs. PG15 lets you change that.'
-- \echo ''

DROP TABLE IF EXISTS idx_lab.nulltest;
CREATE TABLE idx_lab.nulltest (id serial PRIMARY KEY, code text);
CREATE UNIQUE INDEX ix_lab_nulltest_default ON idx_lab.nulltest (code);

INSERT INTO idx_lab.nulltest (code) VALUES (NULL), (NULL), (NULL);
SELECT count(*) AS null_rows_allowed_by_default FROM idx_lab.nulltest;

-- \echo ''
-- \echo '   Three NULLs in a UNIQUE column. Standard SQL, matches Oracle,'
-- \echo '   and surprises everyone anyway.'
-- \echo ''
-- \echo '   PG15+ alternative:'
-- \echo '     CREATE UNIQUE INDEX ... ON t (code) NULLS NOT DISTINCT;'
-- \echo '   -> only ONE NULL permitted.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART F - Everything built so far                              #'
-- \echo '################################################################'

SELECT schemaname || '.' || tablename AS table_name,
       indexname,
       pg_size_pretty(pg_relation_size((schemaname||'.'||indexname)::regclass)) AS size
FROM pg_indexes
WHERE indexname LIKE 'ix\_lab\_%'
ORDER BY 1, 2;

-- \echo ''
-- \echo '>>> NEXT: 04_maintenance_and_bloat.sql'
-- \echo ''
