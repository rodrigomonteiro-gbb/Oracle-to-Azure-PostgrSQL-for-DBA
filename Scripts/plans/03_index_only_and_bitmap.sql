-- =====================================================================
-- 03_index_only_and_bitmap.sql
--
--   Index Scan       (Oracle: INDEX RANGE SCAN + TABLE ACCESS BY INDEX ROWID)
--   Index Only Scan  (Oracle: INDEX FAST FULL SCAN / covering index)
--   Bitmap Heap Scan (no clean Oracle equivalent - explain it fresh)
--
-- Teaches the three-way trade-off, and why VACUUM matters for Index Only.
-- Requires 02_seqscan_vs_index.sql to have run (uses ix_demo_soh_orderdate).
-- =====================================================================

-- \pset pager off
-- \timing on

ANALYZE sales.salesorderheader;
ANALYZE sales.salesorderdetail;

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART A - Index Scan: the heap fetch you are paying for        #'
-- \echo '################################################################'

DROP INDEX IF EXISTS sales.ix_demo_soh_orderdate;
CREATE INDEX ix_demo_soh_orderdate ON sales.salesorderheader (orderdate);
ANALYZE sales.salesorderheader;

EXPLAIN (ANALYZE, BUFFERS)
SELECT orderdate, totaldue, customerid
FROM sales.salesorderheader
WHERE orderdate BETWEEN DATE '2013-06-01' AND DATE '2013-06-07';

-- \echo ''
-- \echo '  This is a two-step operation, exactly like Oracle:'
-- \echo '    1. descend the B-tree to find matching entries   (INDEX RANGE SCAN)'
-- \echo '    2. fetch each row from the heap for totaldue/customerid'
-- \echo '                                                     (TABLE ACCESS BY INDEX ROWID)'
-- \echo '  Step 2 is RANDOM IO and it is where the cost lives.'
-- \echo '  Note the buffer count.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART B - Index Only Scan: eliminate the heap fetch entirely   #'
-- \echo '################################################################'
-- \echo '  Put the payload columns IN the index. Two ways:'
-- \echo '    (a) composite index      - columns are searchable AND returnable'
-- \echo '    (b) INCLUDE clause       - payload only, smaller, not searchable'
-- \echo '  Oracle people know (a) as a covering index. (b) is PG 11+.'
-- \echo ''

DROP INDEX IF EXISTS sales.ix_demo_soh_covering;
CREATE INDEX ix_demo_soh_covering
    ON sales.salesorderheader (orderdate) INCLUDE (totaldue, customerid);
ANALYZE sales.salesorderheader;

EXPLAIN (ANALYZE, BUFFERS)
SELECT orderdate, totaldue, customerid
FROM sales.salesorderheader
WHERE orderdate BETWEEN DATE '2013-06-01' AND DATE '2013-06-07';

-- \echo ''
-- \echo '  >>> "Index Only Scan using ix_demo_soh_covering"'
-- \echo '      The heap is never touched. Buffers should drop noticeably'
-- \echo '      against Part A.'
-- \echo ''
-- \echo '  >>> "Heap Fetches: N"  <-- THE LINE EVERYONE MISSES.'
-- \echo '      Heap Fetches: 0     perfect - fully index-only'
-- \echo '      Heap Fetches: >0    the visibility map is stale, so PostgreSQL'
-- \echo '                          must check the heap for row visibility anyway'
-- \echo ''
-- \echo '      WHY: PostgreSQL keeps row visibility in the HEAP, not the index.'
-- \echo '      An Index Only Scan is only truly "only" when the visibility map'
-- \echo '      marks those pages all-visible - which VACUUM maintains.'
-- \echo ''
-- \echo '      This is a genuine difference from Oracle and worth calling out:'
-- \echo '      on PostgreSQL, VACUUM is not just space reclamation, it is what'
-- \echo '      KEEPS YOUR INDEX ONLY SCANS index-only.'
-- \echo ''

-- \echo '  Watch it improve after a vacuum:'
VACUUM (ANALYZE) sales.salesorderheader;

EXPLAIN (ANALYZE, BUFFERS)
SELECT orderdate, totaldue, customerid
FROM sales.salesorderheader
WHERE orderdate BETWEEN DATE '2013-06-01' AND DATE '2013-06-07';

-- \echo ''
-- \echo '  Heap Fetches should now be 0 or much lower. Same query, same index,'
-- \echo '  better result - purely from maintenance. Strong story for the'
-- \echo '  "PostgreSQL needs different operational habits" conversation.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART C - Bitmap Heap Scan: the middle ground                  #'
-- \echo '################################################################'
-- \echo '  Medium selectivity: too many rows for row-at-a-time index lookups,'
-- \echo '  too few to justify reading the whole table.'
-- \echo ''
-- \echo '  PostgreSQL builds a BITMAP of matching tuple ids, sorts it into'
-- \echo '  PHYSICAL PAGE ORDER, then reads the heap sequentially.'
-- \echo '  Random IO becomes near-sequential IO. Oracle has no clean'
-- \echo '  equivalent - introduce it as a distinct PostgreSQL capability.'
-- \echo ''

DROP INDEX IF EXISTS sales.ix_demo_sod_productid;
CREATE INDEX ix_demo_sod_productid ON sales.salesorderdetail (productid);
ANALYZE sales.salesorderdetail;

-- \echo '  -- Narrow: one product -> Index Scan'
EXPLAIN (ANALYZE, BUFFERS)
SELECT salesorderid, orderqty, unitprice
FROM sales.salesorderdetail
WHERE productid = 707;

-- \echo ''
-- \echo '  -- Wider: a range of products -> Bitmap Heap Scan'
EXPLAIN (ANALYZE, BUFFERS)
SELECT salesorderid, orderqty, unitprice
FROM sales.salesorderdetail
WHERE productid BETWEEN 707 AND 760;

-- \echo ''
-- \echo '  >>> Read the bitmap plan bottom-up:'
-- \echo '      "Bitmap Index Scan"  builds the tid bitmap from the index'
-- \echo '      "Bitmap Heap Scan"   reads the heap in page order'
-- \echo '      "Recheck Cond"       re-applies the predicate'
-- \echo '      "Heap Blocks: exact=N lossy=N"'
-- \echo '            exact = bitmap tracked individual rows'
-- \echo '            lossy = bitmap overflowed work_mem and degraded to'
-- \echo '                    whole-page granularity, so every row on those'
-- \echo '                    pages must be rechecked.'
-- \echo '            LOSSY BLOCKS ARE A work_mem SIGNAL.'
-- \echo ''

-- \echo '  -- Widest: most of the table -> back to Seq Scan'
EXPLAIN (ANALYZE, BUFFERS)
SELECT salesorderid, orderqty, unitprice
FROM sales.salesorderdetail
WHERE productid > 700;

-- \echo ''
-- \echo '  Three plans, one index, one table. The ONLY variable is how many'
-- \echo '  rows the predicate is expected to return.'
-- \echo ''
-- \echo '    selectivity        chosen operator'
-- \echo '    very selective     Index Scan'
-- \echo '    medium             Bitmap Heap Scan'
-- \echo '    not selective      Seq Scan'
-- \echo ''
-- \echo '  This is the whole cost-based optimiser story in one screen.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART D - Combining two bitmaps with BitmapAnd                 #'
-- \echo '################################################################'
-- \echo '  Two separate single-column indexes can be intersected. Useful'
-- \echo '  answer to "should I create a composite index or two singles?"'
-- \echo ''

DROP INDEX IF EXISTS sales.ix_demo_soh_customerid;
CREATE INDEX ix_demo_soh_customerid ON sales.salesorderheader (customerid);
ANALYZE sales.salesorderheader;

EXPLAIN (ANALYZE, BUFFERS)
SELECT salesorderid, customerid, orderdate
FROM sales.salesorderheader
WHERE customerid BETWEEN 11000 AND 11200
  AND orderdate  BETWEEN DATE '2013-01-01' AND DATE '2013-12-31';

-- \echo ''
-- \echo '  If you see BitmapAnd, two indexes were intersected. That is often'
-- \echo '  GOOD ENOUGH and more flexible than a composite - each index still'
-- \echo '  serves its own single-column queries.'
-- \echo ''
-- \echo '  Now compare against one purpose-built composite:'

DROP INDEX IF EXISTS sales.ix_demo_soh_cust_date;
CREATE INDEX ix_demo_soh_cust_date
    ON sales.salesorderheader (customerid, orderdate);
ANALYZE sales.salesorderheader;

EXPLAIN (ANALYZE, BUFFERS)
SELECT salesorderid, customerid, orderdate
FROM sales.salesorderheader
WHERE customerid BETWEEN 11000 AND 11200
  AND orderdate  BETWEEN DATE '2013-01-01' AND DATE '2013-12-31';

-- \echo ''
-- \echo '  The composite usually wins on cost - but it is a narrower bet.'
-- \echo '  COLUMN ORDER MATTERS: (customerid, orderdate) serves a customerid'
-- \echo '  predicate alone; it serves an orderdate predicate alone poorly.'
-- \echo '  Same leading-column rule Oracle DBAs already live by.'
-- \echo ''
-- \echo '>>> NEXT: 04_joins.sql'
-- \echo ''
