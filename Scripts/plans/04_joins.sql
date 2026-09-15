-- =====================================================================
-- 04_joins.sql   The three join operators
--
--   Nested Loop  (Oracle: NESTED LOOPS)
--   Hash Join    (Oracle: HASH JOIN)
--   Merge Join   (Oracle: SORT MERGE JOIN)
--
-- PostgreSQL has exactly these three. The mapping is 1:1, which makes this
-- the easiest part of the migration conversation.
--
-- Also demonstrates: the join-order and join-method decision, and how a
-- missing index on the inner side turns a good Nested Loop into a disaster.
-- =====================================================================

-- \pset pager off
-- \timing on

ANALYZE sales.salesorderheader;
ANALYZE sales.salesorderdetail;
ANALYZE person.person;
ANALYZE sales.customer;

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART A - HASH JOIN: big set meets big set                     #'
-- \echo '################################################################'
-- \echo '  Oracle: HASH JOIN. Identical concept.'
-- \echo '  Builds an in-memory hash table from the SMALLER side, then probes'
-- \echo '  it with the larger side. One pass over each. No ordering required.'
-- \echo ''

EXPLAIN (ANALYZE, BUFFERS)
SELECT h.salesorderid, h.orderdate, d.productid, d.orderqty
FROM sales.salesorderheader h
JOIN sales.salesorderdetail d ON d.salesorderid = h.salesorderid;

-- \echo ''
-- \echo '  >>> READ THESE LINES:'
-- \echo '    "Hash Cond: (d.salesorderid = h.salesorderid)"  the join predicate'
-- \echo '    "->  Hash"          the BUILD side (smaller input)'
-- \echo '    "Buckets: N  Batches: M  Memory Usage: NkB"'
-- \echo ''
-- \echo '    *** Batches: 1  = the hash table fit in work_mem. GOOD.'
-- \echo '    *** Batches: >1 = IT SPILLED TO DISK. The join was split into'
-- \echo '        multiple passes. This is the single most common cause of a'
-- \echo '        slow hash join, and it is a work_mem problem, not an'
-- \echo '        index problem. Oracle folks: this is the multi-pass /'
-- \echo '        one-pass distinction from PGA workarea stats.'
-- \echo ''

-- \echo '  -- Force a spill so they can see it (session-scoped, harmless):'
SET work_mem = '64kB';
EXPLAIN (ANALYZE, BUFFERS)
SELECT h.salesorderid, h.orderdate, d.productid, d.orderqty
FROM sales.salesorderheader h
JOIN sales.salesorderdetail d ON d.salesorderid = h.salesorderid;
RESET work_mem;

-- \echo ''
-- \echo '  Batches jumped, and "temp read/written" appeared in Buffers.'
-- \echo '  That is disk IO caused purely by a memory setting. Powerful moment:'
-- \echo '  the same query, the same data, the same indexes - only work_mem'
-- \echo '  changed.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART B - NESTED LOOP: small driver, indexed inner side         #'
-- \echo '################################################################'
-- \echo '  Oracle: NESTED LOOPS. For each row of the outer input, probe the'
-- \echo '  inner input. Only sane when the inner probe is cheap - i.e. INDEXED.'
-- \echo ''

DROP INDEX IF EXISTS sales.ix_demo_sod_salesorderid;
CREATE INDEX ix_demo_sod_salesorderid ON sales.salesorderdetail (salesorderid);
ANALYZE sales.salesorderdetail;

EXPLAIN (ANALYZE, BUFFERS)
SELECT h.salesorderid, h.orderdate, d.productid, d.orderqty
FROM sales.salesorderheader h
JOIN sales.salesorderdetail d ON d.salesorderid = h.salesorderid
WHERE h.salesorderid BETWEEN 43659 AND 43700;

-- \echo ''
-- \echo '  >>> THE MOST MISREAD LINE IN ANY PLAN:'
-- \echo '        "actual time=0.015..0.021 rows=3 loops=42"'
-- \echo '      actual time and rows are PER LOOP AVERAGES.'
-- \echo '      Real total time  = 0.021 x 42'
-- \echo '      Real total rows  = 3 x 42 = 126'
-- \echo ''
-- \echo '      Oracle DBAs already know this from Starts x A-Rows in ALLSTATS.'
-- \echo '      Identical trap, identical fix: always multiply by loops.'
-- \echo ''
-- \echo '      A Nested Loop with loops in the MILLIONS and a Seq Scan inside'
-- \echo '      it is the classic catastrophic plan. That is what the next part'
-- \echo '      shows.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART C - The disaster: Nested Loop with an UNINDEXED inner     #'
-- \echo '################################################################'
-- \echo '  Same shape, but we remove the inner index first.'
-- \echo ''

DROP INDEX IF EXISTS sales.ix_demo_sod_salesorderid;
ANALYZE sales.salesorderdetail;

-- \echo '  Force the nested loop so the audience sees the failure mode:'
SET enable_hashjoin  = off;
SET enable_mergejoin = off;

EXPLAIN (ANALYZE, BUFFERS)
SELECT h.salesorderid, h.orderdate, d.productid, d.orderqty
FROM sales.salesorderheader h
JOIN sales.salesorderdetail d ON d.salesorderid = h.salesorderid
WHERE h.salesorderid BETWEEN 43659 AND 43700;

RESET enable_hashjoin;
RESET enable_mergejoin;

-- \echo ''
-- \echo '  A Seq Scan (or Materialize) sits inside the loop and runs once per'
-- \echo '  outer row. Look at loops= and multiply. This is the plan behind'
-- \echo '  most "it worked in test, it died in production" incidents:'
-- \echo '  the outer row count grew, and the loop count grew with it.'
-- \echo ''
-- \echo '  Put the index back and let the planner choose freely again:'

CREATE INDEX ix_demo_sod_salesorderid ON sales.salesorderdetail (salesorderid);
ANALYZE sales.salesorderdetail;

EXPLAIN (ANALYZE, BUFFERS)
SELECT h.salesorderid, h.orderdate, d.productid, d.orderqty
FROM sales.salesorderheader h
JOIN sales.salesorderdetail d ON d.salesorderid = h.salesorderid
WHERE h.salesorderid BETWEEN 43659 AND 43700;

-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART D - MERGE JOIN: both inputs already sorted                #'
-- \echo '################################################################'
-- \echo '  Oracle: SORT MERGE JOIN. Walks two sorted inputs in lockstep.'
-- \echo '  Wins when the inputs arrive pre-sorted (from an index) or when the'
-- \echo '  result must be ordered anyway.'
-- \echo ''

SET enable_hashjoin = off;
SET enable_nestloop = off;

EXPLAIN (ANALYZE, BUFFERS)
SELECT h.salesorderid, h.orderdate, d.productid
FROM sales.salesorderheader h
JOIN sales.salesorderdetail d ON d.salesorderid = h.salesorderid
ORDER BY h.salesorderid;

RESET enable_hashjoin;
RESET enable_nestloop;

-- \echo ''
-- \echo '  "Merge Cond:" is the join predicate. If a Sort node feeds it, the'
-- \echo '  sort is the real cost. If an Index Scan feeds it directly, the'
-- \echo '  sort was FREE - the index already provided the order.'
-- \echo '  That is the argument for indexing your join keys.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART E - A realistic multi-table join                          #'
-- \echo '################################################################'
-- \echo '  Four tables. The planner now chooses BOTH the join order and the'
-- \echo '  join method for each step - same combinatorial problem Oracle solves.'
-- \echo ''

EXPLAIN (ANALYZE, BUFFERS)
SELECT p.firstname, p.lastname, h.orderdate, h.totaldue, d.orderqty
FROM sales.salesorderheader h
JOIN sales.customer        c ON c.customerid = h.customerid
JOIN person.person         p ON p.businessentityid = c.personid
JOIN sales.salesorderdetail d ON d.salesorderid = h.salesorderid
WHERE h.orderdate BETWEEN DATE '2013-06-01' AND DATE '2013-06-30'
ORDER BY h.totaldue DESC
LIMIT 50;

-- \echo ''
-- \echo '  >>> WORK THE TREE BOTTOM-UP AND ASK, AT EVERY NODE:'
-- \echo '        does rows= match actual rows= ?'
-- \echo ''
-- \echo '      Estimation error COMPOUNDS upward. A 10x error at the bottom'
-- \echo '      becomes a 1000x error three joins later, and THAT is what makes'
-- \echo '      the planner pick a Nested Loop where it needed a Hash Join.'
-- \echo ''
-- \echo '      This is the identical diagnostic habit as Oracle. The operator'
-- \echo '      names changed; the method did not. Script 07 drills it.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART F - Cheat sheet                                          #'
-- \echo '################################################################'

SELECT 'Nested Loop' AS pg_operator, 'NESTED LOOPS' AS oracle,
       'small outer + INDEXED inner'          AS wins_when,
       'loops x inner cost; dies as outer grows' AS watch_for
UNION ALL SELECT 'Hash Join', 'HASH JOIN',
       'two large unsorted inputs, equality join',
       'Batches>1 means it spilled - raise work_mem'
UNION ALL SELECT 'Merge Join', 'SORT MERGE JOIN',
       'inputs pre-sorted, or output must be ordered',
       'a Sort feeding it is the real cost';

-- \echo ''
-- \echo '>>> NEXT: 05_sorts_and_aggregates.sql'
-- \echo ''
