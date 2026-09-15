-- =====================================================================
-- 01_btree_and_column_order.sql
--
-- The leading-column rule, composite ordering, sort order, and NULLs.
-- Oracle DBAs already know all of this - the point is to show that it
-- transfers unchanged, which builds confidence fast.
--
-- All objects are named ix_lab_* and dropped by 99_cleanup.sql.
-- =====================================================================

-- \pset pager off
-- \timing on

ANALYZE sales.salesorderheader;

DROP INDEX IF EXISTS sales.ix_lab_cust_date;
DROP INDEX IF EXISTS sales.ix_lab_date_cust;

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART A - THE LEADING COLUMN RULE                              #'
-- \echo '################################################################'
-- \echo '  One composite index: (customerid, orderdate).'
-- \echo '  Watch which queries it can serve and which it cannot.'
-- \echo ''

CREATE INDEX ix_lab_cust_date
    ON sales.salesorderheader (customerid, orderdate);
ANALYZE sales.salesorderheader;

-- \echo '  -- A1. Leading column alone -> INDEX USED'
EXPLAIN (ANALYZE, BUFFERS)
SELECT salesorderid, orderdate FROM sales.salesorderheader
WHERE customerid = 29825;

-- \echo ''
-- \echo '  -- A2. BOTH columns -> INDEX USED, both as Index Cond'
EXPLAIN (ANALYZE, BUFFERS)
SELECT salesorderid, orderdate FROM sales.salesorderheader
WHERE customerid = 29825
  AND orderdate >= DATE '2013-01-01';

-- \echo ''
-- \echo '  -- A3. SECOND column alone -> index is (almost) useless'
EXPLAIN (ANALYZE, BUFFERS)
SELECT salesorderid, customerid FROM sales.salesorderheader
WHERE orderdate BETWEEN DATE '2013-06-01' AND DATE '2013-06-07';

-- \echo ''
-- \echo '  >>> A3 falls back to a Seq Scan - or, on a wide enough table,'
-- \echo '      PostgreSQL may do an INDEX ONLY SCAN reading the WHOLE index'
-- \echo '      (a "full index scan"). Either way it is not a targeted seek.'
-- \echo ''
-- \echo '      THE RULE, identical to Oracle:'
-- \echo '      A composite index on (a, b) serves'
-- \echo '          WHERE a = ?              YES'
-- \echo '          WHERE a = ? AND b = ?    YES'
-- \echo '          WHERE b = ?              NO (no usable leading prefix)'
-- \echo ''
-- \echo '      Think of a phone book sorted by (lastname, firstname).'
-- \echo '      Finding "Smith" is easy. Finding everyone named "John"'
-- \echo '      means reading the entire book.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART B - COLUMN ORDER CHANGES EVERYTHING                      #'
-- \echo '################################################################'
-- \echo '  Same two columns, reversed. Same storage cost. Different index.'
-- \echo ''

CREATE INDEX ix_lab_date_cust
    ON sales.salesorderheader (orderdate, customerid);
ANALYZE sales.salesorderheader;

-- \echo '  -- B1. The date-range query the FIRST index could not serve:'
EXPLAIN (ANALYZE, BUFFERS)
SELECT salesorderid, customerid FROM sales.salesorderheader
WHERE orderdate BETWEEN DATE '2013-06-01' AND DATE '2013-06-07';

-- \echo ''
-- \echo '  -- B2. Which index does the planner pick when BOTH exist?'
EXPLAIN (ANALYZE, BUFFERS)
SELECT salesorderid FROM sales.salesorderheader
WHERE customerid = 29825
  AND orderdate BETWEEN DATE '2013-01-01' AND DATE '2013-12-31';

-- \echo ''
-- \echo '  >>> ORDERING GUIDANCE - put columns in this order:'
-- \echo '        1. EQUALITY predicates first   (customerid = ?)'
-- \echo '        2. RANGE predicates last       (orderdate BETWEEN ? AND ?)'
-- \echo ''
-- \echo '      Why: a B-tree can seek precisely on equality, then scan a'
-- \echo '      contiguous range. Reverse them and the equality column is'
-- \echo '      scattered across the whole range - you read far more entries.'
-- \echo ''
-- \echo '      Secondary tie-breaker: higher selectivity first.'
-- \echo '      Same guidance you already apply in Oracle.'
-- \echo ''

SELECT indexrelid::regclass AS index_name,
       pg_size_pretty(pg_relation_size(indexrelid)) AS size,
       idx_scan AS times_used_so_far
FROM pg_stat_user_indexes
WHERE indexrelid IN ('sales.ix_lab_cust_date'::regclass,
                     'sales.ix_lab_date_cust'::regclass);

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART C - SORT ORDER: ASC, DESC, and why it matters            #'
-- \echo '################################################################'
-- \echo '  A B-tree can be read forwards OR backwards, so a plain ASC index'
-- \echo '  already serves ORDER BY x DESC. Direction only matters for'
-- \echo '  MIXED ordering.'
-- \echo ''

DROP INDEX IF EXISTS sales.ix_lab_mixed_wrong;
DROP INDEX IF EXISTS sales.ix_lab_mixed_right;

-- \echo '  -- C1. Mixed ORDER BY with a same-direction index:'
CREATE INDEX ix_lab_mixed_wrong
    ON sales.salesorderheader (customerid, totaldue);
ANALYZE sales.salesorderheader;

EXPLAIN (ANALYZE, BUFFERS)
SELECT customerid, totaldue FROM sales.salesorderheader
ORDER BY customerid ASC, totaldue DESC
LIMIT 50;

-- \echo ''
-- \echo '      A Sort or Incremental Sort node appears - the index order'
-- \echo '      does not match what the query asked for.'
-- \echo ''

-- \echo '  -- C2. Index whose direction matches EXACTLY:'
CREATE INDEX ix_lab_mixed_right
    ON sales.salesorderheader (customerid ASC, totaldue DESC);
ANALYZE sales.salesorderheader;

EXPLAIN (ANALYZE, BUFFERS)
SELECT customerid, totaldue FROM sales.salesorderheader
ORDER BY customerid ASC, totaldue DESC
LIMIT 50;

-- \echo ''
-- \echo '  >>> The Sort node should be GONE. Compare startup cost: the'
-- \echo '      matching index returns its first row almost immediately,'
-- \echo '      because the data already arrives in the requested order.'
-- \echo ''
-- \echo '      Rule: direction only matters when the ORDER BY MIXES'
-- \echo '      directions. ORDER BY a DESC alone is served fine by an'
-- \echo '      ASC index read backwards.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART D - NULLS FIRST / NULLS LAST                             #'
-- \echo '################################################################'
-- \echo '  PostgreSQL default: ASC -> NULLS LAST, DESC -> NULLS FIRST.'
-- \echo '  Oracle default is the same. If your ORDER BY overrides it, the'
-- \echo '  index must match or you get a Sort.'
-- \echo ''

DROP INDEX IF EXISTS person.ix_lab_middlename;
CREATE INDEX ix_lab_middlename ON person.person (middlename);
ANALYZE person.person;

-- \echo '  -- D1. Default NULL ordering - index usable:'
EXPLAIN (ANALYZE)
SELECT businessentityid, middlename FROM person.person
ORDER BY middlename LIMIT 20;

-- \echo ''
-- \echo '  -- D2. Overridden NULL ordering - index no longer matches:'
EXPLAIN (ANALYZE)
SELECT businessentityid, middlename FROM person.person
ORDER BY middlename NULLS FIRST LIMIT 20;

-- \echo ''
-- \echo '  -- D3. NULLs ARE indexed in PostgreSQL B-trees (unlike Oracle!):'
EXPLAIN (ANALYZE)
SELECT count(*) FROM person.person WHERE middlename IS NULL;

-- \echo ''
-- \echo '  >>> *** A REAL DIFFERENCE FROM ORACLE - CALL THIS OUT. ***'
-- \echo '      Oracle B-tree indexes do NOT store entirely-NULL keys, so'
-- \echo '      "WHERE col IS NULL" cannot use a single-column index.'
-- \echo '      PostgreSQL B-trees DO index NULLs, so IS NULL is indexable.'
-- \echo ''
-- \echo '      This surprises migrating DBAs, and it is a genuine'
-- \echo '      PostgreSQL advantage worth naming.'
-- \echo ''

SELECT count(*) FILTER (WHERE middlename IS NULL)     AS null_middlenames,
       count(*) FILTER (WHERE middlename IS NOT NULL) AS non_null,
       count(*)                                        AS total
FROM person.person;

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART E - How big is a B-tree, and how deep?                   #'
-- \echo '################################################################'

SELECT i.indexrelid::regclass                          AS index_name,
       pg_size_pretty(pg_relation_size(i.indexrelid))  AS size,
       c.reltuples::bigint                             AS entries,
       c.relpages                                      AS pages
FROM pg_index i
JOIN pg_class c ON c.oid = i.indexrelid
WHERE i.indexrelid::regclass::text LIKE '%ix_lab_%'
ORDER BY pg_relation_size(i.indexrelid) DESC;

-- \echo ''
-- \echo '   B-trees are shallow: 3-4 levels covers hundreds of millions of'
-- \echo '   rows. That is why an index lookup is a handful of page reads'
-- \echo '   regardless of table size - and why the Index Scan cost barely'
-- \echo '   grows as your table does.'
-- \echo ''
-- \echo '   If pageinspect is available you can show the actual depth:'
-- \echo '     CREATE EXTENSION IF NOT EXISTS pageinspect;'
-- \echo '     SELECT level, type FROM bt_page_stats(''sales.ix_lab_cust_date'', 1);'
-- \echo ''
-- \echo '>>> NEXT: 02_index_types.sql'
-- \echo ''
