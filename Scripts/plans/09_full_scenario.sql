-- =====================================================================
-- 09_full_scenario.sql   THE CLOSING DEMO - one query, five rounds
--
-- A realistic reporting query, tuned live from a Seq-Scan-everything plan
-- to an indexed plan, measuring cost and buffers at every round.
--
-- Run this as the finale. It ties together every operator from scripts
-- 02-08 and ends on the row-estimate message from 07.
--
-- Keep a whiteboard or a text file open and write down, each round:
--     round | total cost | actual time | shared buffers
-- The trend line IS the demo.
-- =====================================================================

-- \pset pager off
-- \timing on

-- Clean slate so the script is repeatable
DROP INDEX IF EXISTS sales.ix_demo_fs_orderdate;
DROP INDEX IF EXISTS sales.ix_demo_fs_sod_orderid;
DROP INDEX IF EXISTS sales.ix_demo_fs_covering;
DROP STATISTICS IF EXISTS sales.stx_demo_fs;

ANALYZE sales.salesorderheader;
ANALYZE sales.salesorderdetail;
ANALYZE sales.customer;
ANALYZE person.person;

-- \echo ''
-- \echo '################################################################'
-- \echo '# THE BUSINESS QUESTION                                         #'
-- \echo '################################################################'
-- \echo '  "Top 25 customers by revenue for orders placed in June 2013,'
-- \echo '   with their name and order count."'
-- \echo ''
-- \echo '  Four tables, a date filter, a join, an aggregate, a sort, a limit.'
-- \echo '  Every operator we have covered appears in this one plan.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# ROUND 1 - BASELINE. No helpful indexes.                       #'
-- \echo '################################################################'

EXPLAIN (ANALYZE, BUFFERS)
SELECT p.lastname, p.firstname,
       count(DISTINCT h.salesorderid) AS orders,
       sum(d.linetotal)               AS revenue
FROM sales.salesorderheader  h
JOIN sales.salesorderdetail  d ON d.salesorderid    = h.salesorderid
JOIN sales.customer          c ON c.customerid      = h.customerid
JOIN person.person           p ON p.businessentityid = c.personid
WHERE h.orderdate >= DATE '2013-06-01'
  AND h.orderdate <  DATE '2013-07-01'
GROUP BY p.lastname, p.firstname
ORDER BY revenue DESC
LIMIT 25;

-- \echo ''
-- \echo '  >>> RECORD:  total cost = ______   time = ______ ms   buffers = ______'
-- \echo ''
-- \echo '  >>> WALK THE TREE BOTTOM-UP AND NARRATE:'
-- \echo '      - Seq Scan on salesorderheader   (Oracle: TABLE ACCESS FULL)'
-- \echo '        with "Rows Removed by Filter" in the thousands'
-- \echo '      - Hash Join                      (Oracle: HASH JOIN)'
-- \echo '      - HashAggregate                  (Oracle: HASH GROUP BY)'
-- \echo '      - Sort                           (Oracle: SORT ORDER BY)'
-- \echo '      - Limit'
-- \echo ''
-- \echo '      Then ask the room the diagnostic question:'
-- \echo '      "Which node is reading rows only to throw them away?"'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# ROUND 2 - Index the filter column                             #'
-- \echo '################################################################'
-- \echo '  The date predicate is the most selective thing in the query.'
-- \echo '  Attack that first.'
-- \echo ''

CREATE INDEX ix_demo_fs_orderdate ON sales.salesorderheader (orderdate);
ANALYZE sales.salesorderheader;

EXPLAIN (ANALYZE, BUFFERS)
SELECT p.lastname, p.firstname,
       count(DISTINCT h.salesorderid) AS orders,
       sum(d.linetotal)               AS revenue
FROM sales.salesorderheader  h
JOIN sales.salesorderdetail  d ON d.salesorderid    = h.salesorderid
JOIN sales.customer          c ON c.customerid      = h.customerid
JOIN person.person           p ON p.businessentityid = c.personid
WHERE h.orderdate >= DATE '2013-06-01'
  AND h.orderdate <  DATE '2013-07-01'
GROUP BY p.lastname, p.firstname
ORDER BY revenue DESC
LIMIT 25;

-- \echo ''
-- \echo '  >>> RECORD:  total cost = ______   time = ______ ms   buffers = ______'
-- \echo ''
-- \echo '      The Seq Scan on salesorderheader should be gone, replaced by'
-- \echo '      an Index Scan or Bitmap Heap Scan. "Rows Removed by Filter"'
-- \echo '      should have collapsed.'
-- \echo ''
-- \echo '      IMPORTANT HONESTY: the JOIN METHOD may also have changed.'
-- \echo '      Fewer driving rows can make a Nested Loop beat a Hash Join.'
-- \echo '      One index changed the shape of the whole plan - exactly the'
-- \echo '      cascade effect from script 07.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# ROUND 3 - Index the join key on the large child table          #'
-- \echo '################################################################'
-- \echo '  salesorderdetail is the biggest table here. If the planner wants a'
-- \echo '  Nested Loop, the inner side MUST be indexed (script 04 part C).'
-- \echo ''

CREATE INDEX ix_demo_fs_sod_orderid ON sales.salesorderdetail (salesorderid);
ANALYZE sales.salesorderdetail;

EXPLAIN (ANALYZE, BUFFERS)
SELECT p.lastname, p.firstname,
       count(DISTINCT h.salesorderid) AS orders,
       sum(d.linetotal)               AS revenue
FROM sales.salesorderheader  h
JOIN sales.salesorderdetail  d ON d.salesorderid    = h.salesorderid
JOIN sales.customer          c ON c.customerid      = h.customerid
JOIN person.person           p ON p.businessentityid = c.personid
WHERE h.orderdate >= DATE '2013-06-01'
  AND h.orderdate <  DATE '2013-07-01'
GROUP BY p.lastname, p.firstname
ORDER BY revenue DESC
LIMIT 25;

-- \echo ''
-- \echo '  >>> RECORD:  total cost = ______   time = ______ ms   buffers = ______'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# ROUND 4 - Cover the query: eliminate heap fetches              #'
-- \echo '################################################################'
-- \echo '  Put the payload columns in the index so the join can be answered'
-- \echo '  from the index alone (script 03 part B).'
-- \echo ''

CREATE INDEX ix_demo_fs_covering
    ON sales.salesorderdetail (salesorderid) INCLUDE (linetotal);
VACUUM (ANALYZE) sales.salesorderdetail;

EXPLAIN (ANALYZE, BUFFERS)
SELECT p.lastname, p.firstname,
       count(DISTINCT h.salesorderid) AS orders,
       sum(d.linetotal)               AS revenue
FROM sales.salesorderheader  h
JOIN sales.salesorderdetail  d ON d.salesorderid    = h.salesorderid
JOIN sales.customer          c ON c.customerid      = h.customerid
JOIN person.person           p ON p.businessentityid = c.personid
WHERE h.orderdate >= DATE '2013-06-01'
  AND h.orderdate <  DATE '2013-07-01'
GROUP BY p.lastname, p.firstname
ORDER BY revenue DESC
LIMIT 25;

-- \echo ''
-- \echo '  >>> RECORD:  total cost = ______   time = ______ ms   buffers = ______'
-- \echo ''
-- \echo '      Look for "Index Only Scan" and "Heap Fetches: 0".'
-- \echo '      The VACUUM before this run is what makes Heap Fetches zero -'
-- \echo '      call that out, it is the PostgreSQL-specific operational habit.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# ROUND 5 - Memory: is anything still spilling?                  #'
-- \echo '################################################################'
-- \echo '  Indexes fixed the ACCESS path. Now check the MEMORY path.'
-- \echo ''

SHOW work_mem;

SET work_mem = '64MB';
EXPLAIN (ANALYZE, BUFFERS)
SELECT p.lastname, p.firstname,
       count(DISTINCT h.salesorderid) AS orders,
       sum(d.linetotal)               AS revenue
FROM sales.salesorderheader  h
JOIN sales.salesorderdetail  d ON d.salesorderid    = h.salesorderid
JOIN sales.customer          c ON c.customerid      = h.customerid
JOIN person.person           p ON p.businessentityid = c.personid
WHERE h.orderdate >= DATE '2013-06-01'
  AND h.orderdate <  DATE '2013-07-01'
GROUP BY p.lastname, p.firstname
ORDER BY revenue DESC
LIMIT 25;
RESET work_mem;

-- \echo ''
-- \echo '  >>> RECORD:  total cost = ______   time = ______ ms   buffers = ______'
-- \echo ''
-- \echo '      If "Batches: 1" everywhere and no "temp read/written", memory'
-- \echo '      was never the constraint - say so plainly. Not every knob helps,'
-- \echo '      and showing one that does not is what makes the rest credible.'
-- \echo ''
-- \echo '      Remember work_mem is per sort/hash node PER CONNECTION. Raise'
-- \echo '      it for the SESSION or the ROLE that runs reports, not globally.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# THE SUMMARY SLIDE                                             #'
-- \echo '################################################################'

SELECT 1 AS round, 'Baseline - no indexes'          AS change,
       'Seq Scan + Hash Join + HashAggregate + Sort' AS plan_shape
UNION ALL SELECT 2, 'Index the date filter',
       'Index/Bitmap Scan; Rows Removed by Filter collapses'
UNION ALL SELECT 3, 'Index the join key',
       'inner side of the join becomes cheap'
UNION ALL SELECT 4, 'Covering index + VACUUM',
       'Index Only Scan, Heap Fetches 0'
UNION ALL SELECT 5, 'work_mem',
       'no spill - or proof memory was never the problem'
ORDER BY 1;

-- \echo ''
-- \echo '  Indexes created by this scenario:'
SELECT indexrelid::regclass                          AS index_name,
       pg_size_pretty(pg_relation_size(indexrelid))  AS size
FROM pg_index
WHERE indexrelid::regclass::text LIKE '%ix_demo_fs%';

-- \echo ''
-- \echo '  >>> CLOSE ON THIS:'
-- \echo ''
-- \echo '      "Everything you just watched is the loop you already run in'
-- \echo '       Oracle. Read the plan bottom-up. Find the node reading rows'
-- \echo '       it is going to throw away. Check whether the estimate matches'
-- \echo '       reality. Change ONE thing. Measure again."'
-- \echo ''
-- \echo '      "EXPLAIN (ANALYZE, BUFFERS) replaced DBMS_XPLAN. Seq Scan,'
-- \echo '       Index Scan and Hash Join replaced TABLE ACCESS FULL, INDEX'
-- \echo '       RANGE SCAN and HASH JOIN. The vocabulary is new. The'
-- \echo '       expertise is not - and the expertise is the expensive part."'
-- \echo ''
-- \echo '>>> FINALLY: run 99_cleanup.sql to remove every ix_demo_* object.'
-- \echo ''
