-- =====================================================================
-- 01_reading_plans.sql   How to read a PostgreSQL plan
--
-- THE ORACLE MAPPING - say this out loud early, it lands every time:
--
--   Oracle                              PostgreSQL
--   ----------------------------------  ----------------------------------
--   EXPLAIN PLAN + DBMS_XPLAN.DISPLAY   EXPLAIN
--   /*+ GATHER_PLAN_STATISTICS */ +     EXPLAIN (ANALYZE, BUFFERS)
--     DISPLAY_CURSOR('ALLSTATS LAST')
--   TABLE ACCESS FULL                   Seq Scan
--   INDEX RANGE SCAN                    Index Scan
--   INDEX FAST FULL SCAN                Index Only Scan
--   TABLE ACCESS BY INDEX ROWID         (the heap fetch inside Index Scan)
--   HASH JOIN                           Hash Join
--   NESTED LOOPS                        Nested Loop
--   SORT MERGE JOIN                     Merge Join
--   SORT ORDER BY                       Sort
--   HASH GROUP BY                       HashAggregate
--   SORT GROUP BY                       GroupAggregate
--   PX / parallel slaves                Gather + Parallel <op>
--   E-Rows vs A-Rows                    rows=N  vs  actual rows=N
--   buffer gets                         Buffers: shared hit/read
--
--   The single habit that transfers 1:1: HUNT THE WRONG ROW ESTIMATE.
--   In both engines, a bad cardinality estimate high in the tree is the
--   root cause of most bad plans. Everything else is downstream.
-- =====================================================================

-- \pset pager off
-- \timing on

-- \echo ''
-- \echo '########################################################'
-- \echo '# A. EXPLAIN alone - ESTIMATES ONLY, query does NOT run #'
-- \echo '########################################################'
-- \echo '  Oracle: EXPLAIN PLAN FOR ... ; SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY);'
-- \echo ''

EXPLAIN
SELECT customerid, count(*) AS orders, sum(totaldue) AS revenue
FROM sales.salesorderheader
WHERE orderdate >= DATE '2013-01-01'
GROUP BY customerid;

-- \echo ''
-- \echo '  READ IT INSIDE-OUT / BOTTOM-UP. Each line shows:'
-- \echo '    cost=STARTUP..TOTAL   rows=ESTIMATED   width=AVG BYTES PER ROW'
-- \echo ''
-- \echo '  cost is in arbitrary planner units, NOT milliseconds. It is only'
-- \echo '  meaningful when COMPARED against another plan for the same query.'
-- \echo '  That comparison is exactly what script 02 does.'
-- \echo ''

-- \echo ''
-- \echo '####################################################'
-- \echo '# B. EXPLAIN (ANALYZE) - actually EXECUTES the query #'
-- \echo '####################################################'
-- \echo '  Oracle: DBMS_XPLAN.DISPLAY_CURSOR(FORMAT => ''ALLSTATS LAST'')'
-- \echo '  WARNING: ANALYZE runs the statement. On INSERT/UPDATE/DELETE,'
-- \echo '           wrap it in BEGIN; ... ROLLBACK;  (script 10 shows this).'
-- \echo ''

EXPLAIN (ANALYZE)
SELECT customerid, count(*) AS orders, sum(totaldue) AS revenue
FROM sales.salesorderheader
WHERE orderdate >= DATE '2013-01-01'
GROUP BY customerid;

-- \echo ''
-- \echo '  NOW you get "actual time=... rows=... loops=..." beside the estimate.'
-- \echo ''
-- \echo '  *** THE MOST IMPORTANT NUMBER ON THE SCREEN ***'
-- \echo '  Compare   rows=<estimate>   against   actual rows=<truth>'
-- \echo '  An order-of-magnitude gap is your root cause. Same hunt as Oracle''s'
-- \echo '  E-Rows vs A-Rows. Script 07 is entirely devoted to this.'
-- \echo ''
-- \echo '  Watch for loops=N: actual time is PER LOOP, so true cost is'
-- \echo '  (actual time x loops). This is the #1 plan-reading mistake.'
-- \echo ''

-- \echo ''
-- \echo '#############################################################'
-- \echo '# C. EXPLAIN (ANALYZE, BUFFERS) - THE ONE YOU SHOULD ALWAYS USE #'
-- \echo '#############################################################'
-- \echo '  Oracle equivalent: buffer gets / physical reads in ALLSTATS.'
-- \echo ''

EXPLAIN (ANALYZE, BUFFERS)
SELECT customerid, count(*) AS orders, sum(totaldue) AS revenue
FROM sales.salesorderheader
WHERE orderdate >= DATE '2013-01-01'
GROUP BY customerid;

-- \echo ''
-- \echo '  Buffers: shared hit=N    pages found in cache        (Oracle: buffer gets)'
-- \echo '           shared read=N   pages read from disk/OS     (Oracle: physical reads)'
-- \echo '           shared dirtied  pages modified'
-- \echo '           temp read/written  SPILL TO DISK - work_mem was too small'
-- \echo ''
-- \echo '  Buffers is the honest currency. Timings vary with cache state;'
-- \echo '  buffer counts barely move. Tune on buffers, verify with time.'
-- \echo ''

-- \echo ''
-- \echo '###########################################################'
-- \echo '# D. The full-diagnostic form - use when something is odd  #'
-- \echo '###########################################################'

EXPLAIN (ANALYZE, BUFFERS, VERBOSE, SETTINGS, WAL, COSTS, TIMING, FORMAT TEXT)
SELECT customerid, count(*) AS orders, sum(totaldue) AS revenue
FROM sales.salesorderheader
WHERE orderdate >= DATE '2013-01-01'
GROUP BY customerid;

-- \echo ''
-- \echo '  VERBOSE   output column list + schema-qualified names'
-- \echo '  SETTINGS  any non-default planner setting in play - catches the'
-- \echo '            "it is fast on my laptop" class of mystery instantly'
-- \echo '  WAL       WAL generated (write statements)'
-- \echo '  FORMAT JSON|YAML|XML  machine-readable, and what plan visualisers eat'
-- \echo ''

-- \echo ''
-- \echo '###############################################'
-- \echo '# E. Same plan as JSON - for plan visualisers  #'
-- \echo '###############################################'
-- \echo '  Paste the output into explain.dalibo.com or pgMustard for a'
-- \echo '  graphical tree. Very effective on a projector.'
-- \echo ''

EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)
SELECT customerid, count(*) AS orders
FROM sales.salesorderheader
WHERE orderdate >= DATE '2013-01-01'
GROUP BY customerid;

-- \echo ''
-- \echo '=== CHECKLIST to put on a slide ==========================='
-- \echo '  1. Is any actual rows wildly different from rows=?   <- start here'
-- \echo '  2. Which node owns the most actual time (x loops)?'
-- \echo '  3. Seq Scan on a big table with a selective filter?  <- index candidate'
-- \echo '  4. Rows Removed by Filter huge?                      <- reading then throwing away'
-- \echo '  5. temp read/written present?                        <- work_mem too small'
-- \echo '  6. shared read >> shared hit?                        <- cold cache or too big'
-- \echo '==========================================================='
-- \echo ''
