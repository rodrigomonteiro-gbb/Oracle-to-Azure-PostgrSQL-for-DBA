-- =====================================================================
-- 02_index_types.sql    B-tree / BRIN / GIN / GiST / Hash
--
-- Oracle has B-tree, bitmap, and function-based. PostgreSQL ships SIX
-- index access methods, several with no Oracle equivalent at all.
-- This is one of the strongest "PostgreSQL is not a lesser database"
-- moments in the whole deck.
--
-- The headline demo is BRIN: same column, 1/100th the storage.
--
-- NOTE: GIN/pg_trgm sections need extensions. On Azure Flexible Server
-- they must be in azure.extensions first. Each section checks and skips
-- cleanly if unavailable - it will not error out mid-demo.
-- =====================================================================

-- \pset pager off
-- \timing on

ANALYZE sales.salesorderheader;
ANALYZE production.product;
ANALYZE person.person;

-- \echo ''
-- \echo '################################################################'
-- \echo '# The six access methods available on this server               #'
-- \echo '################################################################'

SELECT amname AS access_method,
       CASE amname
         WHEN 'btree'  THEN 'default; =, <, >, BETWEEN, IN, ORDER BY, IS NULL'
         WHEN 'hash'   THEN 'equality only; crash-safe since PG10'
         WHEN 'gin'    THEN 'MANY keys per row: jsonb, arrays, full-text, trigram'
         WHEN 'gist'   THEN 'geometric, ranges, nearest-neighbour'
         WHEN 'spgist' THEN 'space-partitioned: quadtrees, radix trees'
         WHEN 'brin'   THEN 'BLOCK RANGE: tiny index for naturally-ordered data'
       END AS best_for
FROM pg_am WHERE amtype = 'i' ORDER BY amname;

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART A - BRIN: the size demo that stops the room              #'
-- \echo '################################################################'
-- \echo '  BRIN stores min/max per BLOCK RANGE (default 128 pages), not per'
-- \echo '  row. Microscopic index. Works brilliantly when the column'
-- \echo '  CORRELATES with physical row order - append-only time-series,'
-- \echo '  order dates, log tables, IoT.'
-- \echo ''
-- \echo '  No Oracle equivalent. Lead with it.'
-- \echo ''

-- \echo '  -- First: is orderdate correlated with physical order?'
SELECT attname, correlation,
       CASE WHEN abs(correlation) > 0.9 THEN 'EXCELLENT for BRIN'
            WHEN abs(correlation) > 0.5 THEN 'workable'
            ELSE 'POOR - BRIN will not help' END AS brin_verdict
FROM pg_stats
WHERE schemaname='sales' AND tablename='salesorderheader'
  AND attname IN ('orderdate','salesorderid','customerid','totaldue')
ORDER BY abs(correlation) DESC NULLS LAST;

-- \echo ''
-- \echo '   correlation near 1.0 = rows are physically stored in that order.'
-- \echo '   THIS COLUMN IS THE ONLY THING THAT DECIDES IF BRIN WORKS.'
-- \echo ''

DROP INDEX IF EXISTS sales.ix_lab_brin_orderdate;
DROP INDEX IF EXISTS sales.ix_lab_btree_orderdate;

CREATE INDEX ix_lab_btree_orderdate ON sales.salesorderheader (orderdate);
CREATE INDEX ix_lab_brin_orderdate  ON sales.salesorderheader
    USING brin (orderdate) WITH (pages_per_range = 32);
ANALYZE sales.salesorderheader;

-- \echo '  *** THE SIZE COMPARISON ***'
SELECT indexrelid::regclass                          AS index_name,
       CASE WHEN indexrelid::regclass::text LIKE '%brin%' THEN 'BRIN' ELSE 'B-tree' END AS type,
       pg_size_pretty(pg_relation_size(indexrelid))  AS size,
       pg_relation_size(indexrelid)                  AS bytes
FROM pg_index
WHERE indexrelid IN ('sales.ix_lab_btree_orderdate'::regclass,
                     'sales.ix_lab_brin_orderdate'::regclass)
ORDER BY bytes DESC;

-- \echo ''
-- \echo '   On a 31k-row table BRIN is a fraction of the B-tree. On a'
-- \echo '   500-million-row time-series table the ratio is routinely'
-- \echo '   100:1 or better - gigabytes versus megabytes.'
-- \echo ''

-- \echo '  -- Force each index in turn and compare the plans:'
SET enable_seqscan = off;

-- \echo '     BRIN only:'
DROP INDEX sales.ix_lab_btree_orderdate;
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*), sum(totaldue) FROM sales.salesorderheader
WHERE orderdate BETWEEN DATE '2013-06-01' AND DATE '2013-06-30';

-- \echo ''
-- \echo '     B-tree only:'
CREATE INDEX ix_lab_btree_orderdate ON sales.salesorderheader (orderdate);
DROP INDEX sales.ix_lab_brin_orderdate;
ANALYZE sales.salesorderheader;
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*), sum(totaldue) FROM sales.salesorderheader
WHERE orderdate BETWEEN DATE '2013-06-01' AND DATE '2013-06-30';

RESET enable_seqscan;
CREATE INDEX ix_lab_brin_orderdate ON sales.salesorderheader
    USING brin (orderdate) WITH (pages_per_range = 32);
ANALYZE sales.salesorderheader;

-- \echo ''
-- \echo '  >>> THE TRADE-OFF, stated honestly:'
-- \echo '      BRIN reads MORE heap blocks (it only knows a range MIGHT'
-- \echo '      contain matches, so it rechecks) but the INDEX itself is'
-- \echo '      almost free to store, to scan, and to MAINTAIN ON WRITE.'
-- \echo ''
-- \echo '      Pitch: "On an append-only 2 TB audit table, a B-tree on the'
-- \echo '       timestamp might be 60 GB and slow every insert. BRIN is'
-- \echo '       maybe 600 MB and costs almost nothing to maintain. If your'
-- \echo '       queries are date ranges over naturally-ordered data, this'
-- \echo '       is free money."'
-- \echo ''
-- \echo '      Critical caveat: if rows are NOT inserted in column order,'
-- \echo '      correlation collapses and BRIN becomes useless. Check'
-- \echo '      pg_stats.correlation BEFORE you propose it.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART B - HASH: equality only                                  #'
-- \echo '################################################################'
-- \echo '  Crash-safe and WAL-logged since PG10 (before that they were'
-- \echo '  genuinely dangerous - which is why older DBAs avoid them).'
-- \echo '  Smaller than B-tree for long keys, but supports ONLY equality:'
-- \echo '  no ranges, no ORDER BY, no uniqueness, no multicolumn.'
-- \echo ''

DROP INDEX IF EXISTS production.ix_lab_hash_productnumber;
DROP INDEX IF EXISTS production.ix_lab_btree_productnumber;

CREATE INDEX ix_lab_hash_productnumber
    ON production.product USING hash (productnumber);
CREATE INDEX ix_lab_btree_productnumber
    ON production.product (productnumber);
ANALYZE production.product;

SELECT indexrelid::regclass AS index_name,
       pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_index
WHERE indexrelid IN ('production.ix_lab_hash_productnumber'::regclass,
                     'production.ix_lab_btree_productnumber'::regclass);

-- \echo ''
-- \echo '  -- Equality: hash CAN serve this'
SET enable_seqscan = off;
EXPLAIN (ANALYZE) SELECT productid, name FROM production.product
WHERE productnumber = 'BK-M18B-40';

-- \echo ''
-- \echo '  -- Range: hash CANNOT. Only the B-tree is eligible.'
EXPLAIN (ANALYZE) SELECT productid, name FROM production.product
WHERE productnumber BETWEEN 'BK-M18B-40' AND 'BK-M68S-42';
RESET enable_seqscan;

-- \echo ''
-- \echo '  >>> Honest verdict: B-tree is almost always the better default.'
-- \echo '      Hash is a niche win for very long keys under pure equality'
-- \echo '      lookup. Mention it, do not recommend it by reflex.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART C - GIN + pg_trgm: making LIKE %text% indexable          #'
-- \echo '################################################################'
-- \echo '  A B-tree CANNOT help "WHERE col LIKE ''%son''" - no usable'
-- \echo '  leading prefix. A trigram GIN index CAN. No Oracle equivalent'
-- \echo '  short of Oracle Text.'
-- \echo ''

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_trgm') THEN
    CREATE EXTENSION IF NOT EXISTS pg_trgm;
    RAISE NOTICE 'pg_trgm ready';
  ELSE
    RAISE NOTICE 'pg_trgm NOT AVAILABLE - add PG_TRGM to azure.extensions, then re-run';
  END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'Could not create pg_trgm: %. Add PG_TRGM to azure.extensions.', SQLERRM;
END $$;

DROP INDEX IF EXISTS person.ix_lab_lastname_btree;
CREATE INDEX ix_lab_lastname_btree ON person.person (lastname);
ANALYZE person.person;

-- \echo '  -- C1. BEFORE: leading wildcard, B-tree useless -> Seq Scan'
EXPLAIN (ANALYZE, BUFFERS)
SELECT businessentityid, lastname FROM person.person
WHERE lastname LIKE '%son%';

-- \echo ''
-- \echo '  -- C2. Add a trigram GIN index:'
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname='pg_trgm') THEN
    EXECUTE 'DROP INDEX IF EXISTS person.ix_lab_lastname_trgm';
    EXECUTE 'CREATE INDEX ix_lab_lastname_trgm ON person.person
             USING gin (lastname gin_trgm_ops)';
    EXECUTE 'ANALYZE person.person';
    RAISE NOTICE 'trigram index created';
  ELSE
    RAISE NOTICE 'skipped - pg_trgm not installed';
  END IF;
END $$;

-- \echo '  -- C3. AFTER: identical query'
EXPLAIN (ANALYZE, BUFFERS)
SELECT businessentityid, lastname FROM person.person
WHERE lastname LIKE '%son%';

-- \echo ''
-- \echo '  >>> If pg_trgm installed, you now get a Bitmap Index Scan on the'
-- \echo '      GIN index instead of a Seq Scan. Compare buffers.'
-- \echo ''
-- \echo '      Bonus - FUZZY matching, which no B-tree can ever do:'
SELECT businessentityid, lastname,
       round(similarity(lastname, 'Jonson')::numeric, 3) AS score
FROM person.person
WHERE lastname % 'Jonson'
ORDER BY score DESC LIMIT 10;

-- \echo ''
-- \echo '      That is a typo-tolerant search served by an index. Very'
-- \echo '      strong demo for anyone building a customer-lookup screen.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART D - GIN for full-text search                             #'
-- \echo '################################################################'
-- \echo '  tsvector + GIN = built-in full-text search. Oracle needs Oracle'
-- \echo '  Text, a separately licensed and separately managed component.'
-- \echo ''

DROP INDEX IF EXISTS production.ix_lab_product_fts;
CREATE INDEX ix_lab_product_fts ON production.product
    USING gin (to_tsvector('english', name));
ANALYZE production.product;

EXPLAIN (ANALYZE, BUFFERS)
SELECT productid, name FROM production.product
WHERE to_tsvector('english', name) @@ to_tsquery('english', 'mountain & bike');

-- \echo ''
SELECT productid, name,
       ts_rank(to_tsvector('english', name),
               to_tsquery('english','mountain | road')) AS rank
FROM production.product
WHERE to_tsvector('english', name) @@ to_tsquery('english','mountain | road')
ORDER BY rank DESC LIMIT 10;

-- \echo ''
-- \echo '   Stemming, ranking, boolean operators - all in the core engine,'
-- \echo '   all covered by one GIN index, no extra licence.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART E - GIN on jsonb                                         #'
-- \echo '################################################################'
-- \echo '  Indexing INSIDE a document. GIN stores one entry per key/value,'
-- \echo '  so one index serves queries on any key.'
-- \echo ''

CREATE SCHEMA IF NOT EXISTS idx_lab;

DROP TABLE IF EXISTS idx_lab.product_doc;
CREATE TABLE idx_lab.product_doc AS
SELECT productid,
       jsonb_build_object(
         'name',      name,
         'number',    productnumber,
         'color',     COALESCE(color,'n/a'),
         'listprice', listprice,
         'flags',     jsonb_build_object('make', makeflag, 'finished', finishedgoodsflag)
       ) AS doc
FROM production.product;

ANALYZE idx_lab.product_doc;

-- \echo '  -- E1. BEFORE: no index on the jsonb column'
EXPLAIN (ANALYZE, BUFFERS)
SELECT productid, doc->>'name' FROM idx_lab.product_doc
WHERE doc @> '{"color":"Black"}';

-- \echo ''
-- \echo '  -- E2. AFTER: one GIN index serves ANY key in the document'
CREATE INDEX ix_lab_productdoc_gin ON idx_lab.product_doc USING gin (doc);
ANALYZE idx_lab.product_doc;

SET enable_seqscan = off;
EXPLAIN (ANALYZE, BUFFERS)
SELECT productid, doc->>'name' FROM idx_lab.product_doc
WHERE doc @> '{"color":"Black"}';

-- \echo ''
-- \echo '  -- E3. Same index, a DIFFERENT key - no new index needed:'
EXPLAIN (ANALYZE, BUFFERS)
SELECT productid, doc->>'name' FROM idx_lab.product_doc
WHERE doc @> '{"flags":{"make":true}}';
RESET enable_seqscan;

-- \echo ''
-- \echo '   ONE index, ANY key, ANY nesting depth. That flexibility is why'
-- \echo '   GIN is bigger and slower to update than a B-tree - a real'
-- \echo '   trade-off, worth stating rather than glossing over.'
-- \echo ''
-- \echo '   For a KNOWN single key, a B-tree on the EXPRESSION is smaller'
-- \echo '   and faster:'
CREATE INDEX ix_lab_productdoc_color
    ON idx_lab.product_doc ((doc->>'color'));
ANALYZE idx_lab.product_doc;

EXPLAIN (ANALYZE, BUFFERS)
SELECT productid FROM idx_lab.product_doc WHERE doc->>'color' = 'Black';

-- \echo ''
-- \echo '   jsonb_path_ops is a smaller GIN variant when you only ever use'
-- \echo '   the @> containment operator:'
-- \echo '     CREATE INDEX ... USING gin (doc jsonb_path_ops);'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART F - Decision table for the slide                         #'
-- \echo '################################################################'

SELECT 'B-tree' AS index_type, 'the default - 95% of cases' AS use_when,
       '=, <, >, BETWEEN, IN, LIKE ''x%'', ORDER BY, IS NULL' AS supports,
       'B-tree / function-based' AS oracle_equivalent
UNION ALL SELECT 'BRIN','huge table, column correlates with physical order',
       'range predicates only','(none)'
UNION ALL SELECT 'GIN','many keys per row: jsonb, arrays, text search, trigram',
       '@>, @@, LIKE ''%x%'' via pg_trgm','(Oracle Text, separately licensed)'
UNION ALL SELECT 'GiST','geometry, ranges, nearest-neighbour',
       '&&, <->, range overlap','Oracle Spatial'
UNION ALL SELECT 'Hash','very long keys, pure equality lookup',
       '= only','(none - Oracle hash is for clusters)'
UNION ALL SELECT 'SP-GiST','non-balanced structures: quadtree, radix, IP prefix',
       'specialised operator classes','(none)';

-- \echo ''
-- \echo '>>> NEXT: 03_special_indexes.sql'
-- \echo ''
