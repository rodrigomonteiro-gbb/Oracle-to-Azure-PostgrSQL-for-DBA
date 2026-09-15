-- =====================================================================
-- 06_parallel_and_cte.sql
--
--   Gather / Gather Merge / Parallel Seq Scan   (Oracle: PX / parallel slaves)
--   Materialize, Memoize, CTE Scan, SubPlan, InitPlan, Append
--
-- Also: the PG12 CTE change that surprises every Oracle DBA.
-- =====================================================================

-- \pset pager off
-- \timing on

ANALYZE sales.salesorderdetail;
ANALYZE sales.salesorderheader;

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART A - Parallel query                                       #'
-- \echo '################################################################'
-- \echo '  Oracle: PARALLEL hint / PX COORDINATOR / PX BLOCK ITERATOR.'
-- \echo '  PostgreSQL: Gather (coordinator) + Parallel <operator> (workers).'
-- \echo ''

SELECT name, setting FROM pg_settings
WHERE name IN ('max_parallel_workers_per_gather','max_parallel_workers',
               'max_worker_processes','parallel_setup_cost',
               'parallel_tuple_cost','min_parallel_table_scan_size');

-- \echo ''
-- \echo '  -- A1. Serial baseline:'
SET max_parallel_workers_per_gather = 0;
EXPLAIN (ANALYZE, BUFFERS)
SELECT productid, count(*) AS lines, sum(linetotal) AS revenue
FROM sales.salesorderdetail
GROUP BY productid;

-- \echo ''
-- \echo '  -- A2. Allow workers:'
SET max_parallel_workers_per_gather = 4;
EXPLAIN (ANALYZE, BUFFERS)
SELECT productid, count(*) AS lines, sum(linetotal) AS revenue
FROM sales.salesorderdetail
GROUP BY productid;
RESET max_parallel_workers_per_gather;

-- \echo ''
-- \echo '  >>> READ THE PARALLEL PLAN:'
-- \echo '      "Gather"                      the coordinator collecting results'
-- \echo '      "Workers Planned: N"          what the planner asked for'
-- \echo '      "Workers Launched: N"         WHAT IT ACTUALLY GOT'
-- \echo ''
-- \echo '      *** Planned 4 / Launched 0 or 1 is a REAL production incident'
-- \echo '          pattern: the worker pool was exhausted by other queries.'
-- \echo '          Same class of problem as Oracle downgrading a PX plan to'
-- \echo '          serial. Always check this line before blaming the query.'
-- \echo ''
-- \echo '      "Parallel Seq Scan"           each worker takes a block range'
-- \echo '      "Partial HashAggregate"       per-worker partial results'
-- \echo '      "Finalize GroupAggregate"     coordinator merges them'
-- \echo ''
-- \echo '      Partial -> Finalize is the PostgreSQL two-phase aggregation.'
-- \echo '      If the table is small the planner will refuse to parallelise -'
-- \echo '      parallel_setup_cost is real, and correctly accounted for.'
-- \echo ''

-- \echo '  -- A3. Gather Merge - workers each return SORTED output'
SET max_parallel_workers_per_gather = 4;
EXPLAIN (ANALYZE, BUFFERS)
SELECT salesorderid, productid, linetotal
FROM sales.salesorderdetail
ORDER BY linetotal DESC
LIMIT 100;
RESET max_parallel_workers_per_gather;

-- \echo ''
-- \echo '      "Gather Merge" preserves ordering while merging worker streams,'
-- \echo '      so no re-sort is needed on the coordinator.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART B - CTEs: the change that surprises Oracle DBAs           #'
-- \echo '################################################################'
-- \echo '  BEFORE PostgreSQL 12: a CTE was ALWAYS an optimisation fence -'
-- \echo '  materialised, never pushed into. Oracle-style /*+ MATERIALIZE */'
-- \echo '  behaviour, but mandatory.'
-- \echo '  POSTGRESQL 12+: CTEs are INLINED by default when referenced once.'
-- \echo ''
-- \echo '  Migrated code written against the old behaviour can change plans.'
-- \echo '  Usually for the better - but you must know to look.'
-- \echo ''

-- \echo '  -- B1. Default: inlined, predicate pushed down into the CTE'
EXPLAIN (ANALYZE, BUFFERS)
WITH recent AS (
    SELECT salesorderid, customerid, orderdate, totaldue
    FROM sales.salesorderheader
    WHERE orderdate >= DATE '2013-01-01'
)
SELECT * FROM recent WHERE customerid = 29825;

-- \echo ''
-- \echo '      No "CTE Scan" node - the CTE vanished into the outer query and'
-- \echo '      both predicates were applied together.'
-- \echo ''

-- \echo '  -- B2. Force the old fence behaviour:'
EXPLAIN (ANALYZE, BUFFERS)
WITH recent AS MATERIALIZED (
    SELECT salesorderid, customerid, orderdate, totaldue
    FROM sales.salesorderheader
    WHERE orderdate >= DATE '2013-01-01'
)
SELECT * FROM recent WHERE customerid = 29825;

-- \echo ''
-- \echo '      NOW you see "CTE Scan on recent" and a "CTE recent" subtree.'
-- \echo '      The full CTE result is built first, THEN filtered. Note the'
-- \echo '      difference in rows processed - that gap is the cost of a fence.'
-- \echo ''
-- \echo '      MATERIALIZED is still the right choice when the CTE is expensive'
-- \echo '      and referenced MANY times: compute once, reuse. Same judgement'
-- \echo '      call as Oracle MATERIALIZE vs INLINE hints.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART C - Materialize and Memoize                               #'
-- \echo '################################################################'
-- \echo '  Materialize: buffer a subtree so it is not recomputed per loop.'
-- \echo '  Memoize (PG 14+): CACHE inner results per distinct key in a'
-- \echo '  Nested Loop. Oracle has no direct equivalent - excellent'
-- \echo '  "PostgreSQL has its own tricks" moment.'
-- \echo ''

SET enable_hashjoin  = off;
SET enable_mergejoin = off;

EXPLAIN (ANALYZE, BUFFERS)
SELECT d.salesorderid, d.productid, p.name, p.listprice
FROM sales.salesorderdetail d
JOIN production.product p ON p.productid = d.productid
WHERE d.salesorderid BETWEEN 43659 AND 43800;

RESET enable_hashjoin;
RESET enable_mergejoin;

-- \echo ''
-- \echo '      If you see "Memoize", read:'
-- \echo '        "Hits: N  Misses: M  Evictions: E  Memory Usage: NkB"'
-- \echo '      A high hit ratio means the repeated inner lookups were served'
-- \echo '      from cache instead of re-probing the index. Few products, many'
-- \echo '      order lines - a textbook Memoize win.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART D - SubPlan and InitPlan                                  #'
-- \echo '################################################################'
-- \echo '  InitPlan = evaluated ONCE (uncorrelated subquery)'
-- \echo '  SubPlan  = evaluated PER ROW (correlated subquery)  <- the expensive one'
-- \echo ''

-- \echo '  -- D1. InitPlan: scalar subquery, runs once'
EXPLAIN (ANALYZE, BUFFERS)
SELECT salesorderid, totaldue
FROM sales.salesorderheader
WHERE totaldue > (SELECT avg(totaldue) FROM sales.salesorderheader);

-- \echo ''
-- \echo '  -- D2. SubPlan: correlated - watch it run per outer row'
EXPLAIN (ANALYZE, BUFFERS)
SELECT h.salesorderid, h.totaldue
FROM sales.salesorderheader h
WHERE h.totaldue > (
    SELECT avg(h2.totaldue)
    FROM sales.salesorderheader h2
    WHERE h2.customerid = h.customerid
)
AND h.orderdate >= DATE '2013-06-01';

-- \echo ''
-- \echo '      Check "loops=" on the SubPlan. That is how many times the'
-- \echo '      correlated subquery executed. The classic rewrite is a window'
-- \echo '      function or a derived table joined once:'
-- \echo ''

EXPLAIN (ANALYZE, BUFFERS)
SELECT salesorderid, totaldue
FROM (
    SELECT salesorderid, totaldue, orderdate,
           avg(totaldue) OVER (PARTITION BY customerid) AS cust_avg
    FROM sales.salesorderheader
) s
WHERE totaldue > cust_avg
  AND orderdate >= DATE '2013-06-01';

-- \echo ''
-- \echo '      Same answer, one pass. Compare total cost and buffers against D2.'
-- \echo '      This is the highest-value rewrite pattern you can teach a'
-- \echo '      migrating application team.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART E - Append / UNION ALL                                    #'
-- \echo '################################################################'

EXPLAIN (ANALYZE, BUFFERS)
SELECT salesorderid, totaldue FROM sales.salesorderheader WHERE totaldue > 10000
UNION ALL
SELECT salesorderid, totaldue FROM sales.salesorderheader WHERE totaldue < 10;

-- \echo ''
-- \echo '      "Append" concatenates. UNION (without ALL) adds a HashAggregate'
-- \echo '      or Unique node to deduplicate - measurable extra cost. If the'
-- \echo '      branches cannot overlap, UNION ALL is free money.'
-- \echo '      Append is also what you see over PARTITIONS; with partition'
-- \echo '      pruning, unscanned partitions never appear in the plan at all.'
-- \echo ''
-- \echo '>>> NEXT: 07_row_estimates.sql   <- the most important script'
-- \echo ''
