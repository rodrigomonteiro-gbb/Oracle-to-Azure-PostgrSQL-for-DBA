-- =====================================================================
-- 05_sorts_and_aggregates.sql
--
--   Sort            (Oracle: SORT ORDER BY)
--   HashAggregate   (Oracle: HASH GROUP BY)
--   GroupAggregate  (Oracle: SORT GROUP BY)
--   Incremental Sort, Limit, Unique, WindowAgg
--
-- Headline demo: an ORDER BY that spills to disk, then the SAME query
-- with an index that removes the sort entirely. Cost comparison included.
-- =====================================================================

-- \pset pager off
-- \timing on

ANALYZE sales.salesorderheader;
ANALYZE sales.salesorderdetail;

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART A - Sort: quicksort in memory vs external merge on disk  #'
-- \echo '################################################################'
-- \echo '  Oracle: SORT ORDER BY, and the same one-pass/multi-pass distinction.'
-- \echo ''

-- \echo '  -- A1. Comfortable memory:'
RESET work_mem;
EXPLAIN (ANALYZE, BUFFERS)
SELECT salesorderid, customerid, totaldue
FROM sales.salesorderheader
ORDER BY totaldue DESC;

-- \echo ''
-- \echo '      "Sort Method: quicksort  Memory: NNNkB"   <- all in RAM. Good.'
-- \echo ''

-- \echo '  -- A2. Starve it (session-scoped only - server default untouched):'
SET work_mem = '64kB';
EXPLAIN (ANALYZE, BUFFERS)
SELECT salesorderid, customerid, totaldue
FROM sales.salesorderheader
ORDER BY totaldue DESC;
RESET work_mem;

-- \echo ''
-- \echo '      "Sort Method: external merge  Disk: NNNNkB"  <- SPILLED.'
-- \echo '      "Buffers: ... temp read=N written=N"         <- real disk IO.'
-- \echo ''
-- \echo '      Two plans, identical query, identical data. The ONLY difference'
-- \echo '      is one memory setting. Before you go index-hunting, check'
-- \echo '      whether you are simply sorting on disk.'
-- \echo ''
-- \echo '      work_mem is PER SORT NODE PER CONNECTION - not per query and'
-- \echo '      not per server. A 100-connection workload with 3 sorts each can'
-- \echo '      allocate 300 x work_mem. That is how people OOM a PostgreSQL box.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART B - Deleting the Sort entirely with an index              #'
-- \echo '################################################################'
-- \echo '  A B-tree IS a sorted structure. If the index order matches the'
-- \echo '  ORDER BY, the sort node disappears. This is the best cost'
-- \echo '  before/after in the whole deck after script 02.'
-- \echo ''

DROP INDEX IF EXISTS sales.ix_demo_soh_totaldue;

-- \echo '  -- B1. BEFORE - no index. Note the Sort node and the total cost:'
EXPLAIN (ANALYZE, BUFFERS)
SELECT salesorderid, customerid, totaldue
FROM sales.salesorderheader
ORDER BY totaldue DESC
LIMIT 20;

-- \echo ''
-- \echo '      Even with LIMIT 20, look at the node BELOW the Limit: the whole'
-- \echo '      table is read and sorted, then 20 rows are kept. "Top-N'
-- \echo '      heapsort" is better than a full sort, but it still reads'
-- \echo '      everything.'
-- \echo ''

-- \echo '  -- B2. Create a DESC index matching the ORDER BY exactly:'
CREATE INDEX ix_demo_soh_totaldue
    ON sales.salesorderheader (totaldue DESC);
ANALYZE sales.salesorderheader;

-- \echo '  -- B3. AFTER - identical query:'
EXPLAIN (ANALYZE, BUFFERS)
SELECT salesorderid, customerid, totaldue
FROM sales.salesorderheader
ORDER BY totaldue DESC
LIMIT 20;

-- \echo ''
-- \echo '  >>> COMPARE:'
-- \echo '        BEFORE   Limit <- Sort <- Seq Scan      (read all, sort all)'
-- \echo '        AFTER    Limit <- Index Scan            (read 20 and stop)'
-- \echo ''
-- \echo '      The Sort node is GONE. Total cost collapses, and notice the'
-- \echo '      STARTUP cost in particular - the AFTER plan returns its first'
-- \echo '      row almost immediately because the data already arrives ordered.'
-- \echo ''
-- \echo '      Top-N + matching index is the single highest-value index pattern'
-- \echo '      in reporting and paging workloads. Every "latest N records"'
-- \echo '      screen in the application is this query.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART C - HashAggregate vs GroupAggregate                       #'
-- \echo '################################################################'
-- \echo '  HashAggregate  = Oracle HASH GROUP BY   (hash table of groups)'
-- \echo '  GroupAggregate = Oracle SORT GROUP BY   (needs sorted input)'
-- \echo ''

-- \echo '  -- C1. Typical: HashAggregate'
EXPLAIN (ANALYZE, BUFFERS)
SELECT customerid, count(*) AS orders, sum(totaldue) AS revenue
FROM sales.salesorderheader
GROUP BY customerid;

-- \echo ''
-- \echo '      "HashAggregate ... Batches: 1  Memory Usage: NkB"'
-- \echo '      Batches > 1 means the GROUP BY spilled - same work_mem story.'
-- \echo ''

-- \echo '  -- C2. Force the sorted variant to contrast them:'
SET enable_hashagg = off;
EXPLAIN (ANALYZE, BUFFERS)
SELECT customerid, count(*) AS orders, sum(totaldue) AS revenue
FROM sales.salesorderheader
GROUP BY customerid;
RESET enable_hashagg;

-- \echo ''
-- \echo '      GroupAggregate needs a Sort beneath it. Usually worse - UNLESS'
-- \echo '      an index already supplies the order, which is exactly C3.'
-- \echo ''

-- \echo '  -- C3. Index supplies the grouping order: sort-free GroupAggregate'
DROP INDEX IF EXISTS sales.ix_demo_soh_cust_total;
CREATE INDEX ix_demo_soh_cust_total
    ON sales.salesorderheader (customerid, totaldue);
ANALYZE sales.salesorderheader;

EXPLAIN (ANALYZE, BUFFERS)
SELECT customerid, count(*) AS orders, sum(totaldue) AS revenue
FROM sales.salesorderheader
GROUP BY customerid;

-- \echo ''
-- \echo '      Depending on row counts you may now see GroupAggregate over an'
-- \echo '      Index Only Scan with NO Sort node - or the planner may still'
-- \echo '      prefer HashAggregate. Either outcome is a teaching moment:'
-- \echo '      the planner is COMPARING COSTS, not following rules.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART D - Incremental Sort (PG 13+)                             #'
-- \echo '################################################################'
-- \echo '  Index gives you the first sort key; PostgreSQL sorts only within'
-- \echo '  each group for the remaining keys. No Oracle equivalent - a good'
-- \echo '  "PostgreSQL has moved on" talking point.'
-- \echo ''

EXPLAIN (ANALYZE, BUFFERS)
SELECT customerid, orderdate, totaldue
FROM sales.salesorderheader
ORDER BY customerid, totaldue DESC
LIMIT 100;

-- \echo ''
-- \echo '      Look for "Incremental Sort" and "Full-sort Groups / Pre-sorted'
-- \echo '      Groups". Memory stays tiny because it never sorts the whole set.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART E - WindowAgg and DISTINCT                                #'
-- \echo '################################################################'

EXPLAIN (ANALYZE, BUFFERS)
SELECT customerid, orderdate, totaldue,
       rank() OVER (PARTITION BY customerid ORDER BY totaldue DESC) AS rnk
FROM sales.salesorderheader
WHERE orderdate >= DATE '2013-01-01';

-- \echo ''
-- \echo '      WindowAgg always needs its input ordered by PARTITION BY then'
-- \echo '      ORDER BY. An index on (customerid, totaldue DESC) can remove'
-- \echo '      that Sort - the same trick as Part B, applied to window functions.'
-- \echo ''

-- \echo '  -- DISTINCT: Unique-over-Sort vs HashAggregate'
EXPLAIN (ANALYZE, BUFFERS)
SELECT DISTINCT customerid FROM sales.salesorderheader;

-- \echo ''
-- \echo '      DISTINCT is just a GROUP BY with no aggregate, and the planner'
-- \echo '      treats it that way - HashAggregate or Unique-over-Sort.'
-- \echo ''
-- \echo '>>> NEXT: 06_aggregate_pushdown_and_parallel.sql'
-- \echo ''
