-- =====================================================================
-- 07_row_estimates.sql   *** THE MOST IMPORTANT SCRIPT IN THE SET ***
--
-- "The habit of hunting a wrong row estimate is identical."
--
--   Oracle:      E-Rows  vs  A-Rows     (DBMS_XPLAN ALLSTATS LAST)
--   PostgreSQL:  rows=N  vs  actual rows=N   (EXPLAIN ANALYZE)
--
-- Same hunt. Same root cause. Same fixes, different syntax:
--
--   Oracle                              PostgreSQL
--   ----------------------------------  ---------------------------------
--   DBMS_STATS.GATHER_TABLE_STATS       ANALYZE
--   METHOD_OPT histogram buckets        ALTER TABLE ... SET STATISTICS n
--                                       default_statistics_target
--   Extended stats / column groups      CREATE STATISTICS
--   Function-based index for stats      Expression index (gives stats too)
--   Cardinality feedback                (no equivalent - be explicit)
--
-- This script MANUFACTURES bad estimates on purpose, then fixes them.
-- Nothing here changes adventureworks data.
-- =====================================================================

-- \pset pager off
-- \timing on

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART A - The method, on one screen                            #'
-- \echo '################################################################'
-- \echo '  For every node, bottom-up:      rows=ESTIMATE   actual rows=TRUTH'
-- \echo ''
-- \echo '    ratio < 10x     usually fine'
-- \echo '    ratio 10-100x   suspicious - check this node'
-- \echo '    ratio > 100x    THIS IS YOUR BUG. Stop looking anywhere else.'
-- \echo ''
-- \echo '  Estimation error COMPOUNDS UPWARD. Always fix the LOWEST bad node'
-- \echo '  first - the ones above it are often just consequences.'
-- \echo ''

ANALYZE sales.salesorderheader;
ANALYZE sales.salesorderdetail;

EXPLAIN (ANALYZE, BUFFERS)
SELECT h.customerid, count(*) AS orders, sum(d.linetotal) AS revenue
FROM sales.salesorderheader h
JOIN sales.salesorderdetail d ON d.salesorderid = h.salesorderid
WHERE h.orderdate BETWEEN DATE '2013-01-01' AND DATE '2013-03-31'
GROUP BY h.customerid;

-- \echo ''
-- \echo '  With fresh statistics these should track closely. That is the'
-- \echo '  BASELINE. Now we break it three different ways.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# CAUSE 1 - STALE STATISTICS                                    #'
-- \echo '################################################################'
-- \echo '  The most common cause in the field, and the easiest to fix.'
-- \echo '  We simulate it by deliberately wrecking the stats target.'
-- \echo ''

ALTER TABLE sales.salesorderheader ALTER COLUMN orderdate SET STATISTICS 1;
ANALYZE sales.salesorderheader;

-- \echo '  -- With a 1-bucket histogram the planner is nearly blind:'
EXPLAIN (ANALYZE)
SELECT salesorderid, customerid, totaldue
FROM sales.salesorderheader
WHERE orderdate BETWEEN DATE '2013-06-01' AND DATE '2013-06-07';

-- \echo ''
-- \echo '      Compare rows= against actual rows=. The gap is pure ignorance'
-- \echo '      about the data distribution.'
-- \echo ''

-- \echo '  -- Restore a rich histogram (Oracle: METHOD_OPT size 254):'
ALTER TABLE sales.salesorderheader ALTER COLUMN orderdate SET STATISTICS 500;
ANALYZE sales.salesorderheader;

EXPLAIN (ANALYZE)
SELECT salesorderid, customerid, totaldue
FROM sales.salesorderheader
WHERE orderdate BETWEEN DATE '2013-06-01' AND DATE '2013-06-07';

-- \echo ''
-- \echo '      Estimate should now be much closer. No index was created, no'
-- \echo '      query was rewritten - only the planner''s KNOWLEDGE changed.'
-- \echo ''
-- \echo '      Put back the default when you are done:'
-- \echo '        ALTER TABLE sales.salesorderheader'
-- \echo '          ALTER COLUMN orderdate SET STATISTICS -1;'
-- \echo '      (99_cleanup.sql does this for you.)'
-- \echo ''

-- \echo '  -- What the planner actually knows - show them pg_stats:'
SELECT attname,
       n_distinct,
       null_frac,
       array_length(most_common_vals, 1)  AS mcv_count,
       array_length(histogram_bounds, 1)  AS histogram_buckets,
       correlation
FROM pg_stats
WHERE schemaname = 'sales' AND tablename = 'salesorderheader'
  AND attname IN ('orderdate','customerid','totaldue','territoryid')
ORDER BY attname;

-- \echo ''
-- \echo '      n_distinct    distinct values (negative = ratio of table size)'
-- \echo '      MCV list      most common values - Oracle frequency histogram'
-- \echo '      histogram     range distribution - Oracle height-balanced'
-- \echo '      correlation   physical/logical ordering match, -1..1.'
-- \echo '                    NEAR 1 MAKES INDEX SCANS MUCH CHEAPER because'
-- \echo '                    heap access becomes near-sequential. This one'
-- \echo '                    column explains many "why did it pick that plan"'
-- \echo '                    mysteries.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# CAUSE 2 - CORRELATED COLUMNS (the classic)                    #'
-- \echo '################################################################'
-- \echo '  PostgreSQL assumes predicates are INDEPENDENT and multiplies their'
-- \echo '  selectivities. When columns are correlated, the estimate collapses'
-- \echo '  by orders of magnitude.'
-- \echo '  Oracle solves this with extended stats / column groups.'
-- \echo '  PostgreSQL: CREATE STATISTICS. Same idea, different syntax.'
-- \echo ''

DROP STATISTICS IF EXISTS sales.stx_demo_soh_corr;

-- \echo '  -- BEFORE: two correlated predicates, independence assumed'
EXPLAIN (ANALYZE)
SELECT salesorderid, orderdate, duedate, shipdate
FROM sales.salesorderheader
WHERE orderdate BETWEEN DATE '2013-01-01' AND DATE '2013-06-30'
  AND duedate   BETWEEN DATE '2013-01-01' AND DATE '2013-07-30';

-- \echo ''
-- \echo '      duedate is almost always orderdate + 12 days - they are HEAVILY'
-- \echo '      correlated. The planner does not know that, so it multiplies'
-- \echo '      two selectivities and badly UNDER-estimates.'
-- \echo ''

-- \echo '  -- Teach it the relationship:'
CREATE STATISTICS sales.stx_demo_soh_corr (dependencies, ndistinct, mcv)
    ON orderdate, duedate FROM sales.salesorderheader;
ANALYZE sales.salesorderheader;

-- \echo '  -- AFTER: same query'
EXPLAIN (ANALYZE)
SELECT salesorderid, orderdate, duedate, shipdate
FROM sales.salesorderheader
WHERE orderdate BETWEEN DATE '2013-01-01' AND DATE '2013-06-30'
  AND duedate   BETWEEN DATE '2013-01-01' AND DATE '2013-07-30';

-- \echo ''
-- \echo '      The estimate should move sharply toward the actual.'
-- \echo ''
-- \echo '  -- What it learned:'
SELECT statistics_name, attnames, kinds
FROM pg_stats_ext
WHERE statistics_schema = 'sales' AND statistics_name = 'stx_demo_soh_corr';

-- \echo ''
-- \echo '      "dependencies" = functional dependency degree between columns.'
-- \echo '      Close to 1.0 means one column effectively determines the other.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# CAUSE 3 - EXPRESSIONS HIDE THE COLUMN                          #'
-- \echo '################################################################'
-- \echo '  Wrap a column in a function and its statistics become unreachable.'
-- \echo '  PostgreSQL falls back to a hardcoded guess. Oracle behaves the same'
-- \echo '  way without a function-based index.'
-- \echo ''

DROP INDEX IF EXISTS sales.ix_demo_soh_year;

-- \echo '  -- BEFORE: expression on the column - stats are blind'
EXPLAIN (ANALYZE)
SELECT salesorderid, orderdate
FROM sales.salesorderheader
WHERE EXTRACT(YEAR FROM orderdate) = 2013;

-- \echo ''
-- \echo '      Note the estimate, and note the Seq Scan. Also note the filter'
-- \echo '      is NOT sargable - no plain index on orderdate can help it.'
-- \echo ''

-- \echo '  -- FIX 1 (BEST): rewrite as a sargable range predicate'
EXPLAIN (ANALYZE)
SELECT salesorderid, orderdate
FROM sales.salesorderheader
WHERE orderdate >= DATE '2013-01-01'
  AND orderdate <  DATE '2014-01-01';

-- \echo ''
-- \echo '      Same rows, real statistics, and an index can now be used.'
-- \echo '      ALWAYS PREFER THE REWRITE.'
-- \echo ''

-- \echo '  -- FIX 2: when you cannot change the SQL, index the EXPRESSION'
-- \echo '           (Oracle: function-based index). This also creates'
-- \echo '           statistics ON THE EXPRESSION - often the bigger win.'
CREATE INDEX ix_demo_soh_year
    ON sales.salesorderheader ((EXTRACT(YEAR FROM orderdate)));
ANALYZE sales.salesorderheader;

EXPLAIN (ANALYZE)
SELECT salesorderid, orderdate
FROM sales.salesorderheader
WHERE EXTRACT(YEAR FROM orderdate) = 2013;

-- \echo ''
-- \echo '      The original, unchanged query now has both an index AND a real'
-- \echo '      estimate. This is the pattern for vendor applications you'
-- \echo '      cannot modify.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART D - Watch a bad estimate WRECK a join                     #'
-- \echo '################################################################'
-- \echo '  This is why estimates matter: they change the OPERATOR choice.'
-- \echo ''

ALTER TABLE sales.salesorderheader ALTER COLUMN orderdate SET STATISTICS 1;
ANALYZE sales.salesorderheader;

-- \echo '  -- Bad estimate feeding a join:'
EXPLAIN (ANALYZE, BUFFERS)
SELECT h.customerid, count(*) AS lines
FROM sales.salesorderheader h
JOIN sales.salesorderdetail d ON d.salesorderid = h.salesorderid
WHERE h.orderdate BETWEEN DATE '2013-06-01' AND DATE '2013-06-07'
GROUP BY h.customerid;

ALTER TABLE sales.salesorderheader ALTER COLUMN orderdate SET STATISTICS 500;
ANALYZE sales.salesorderheader;

-- \echo '  -- Good estimate, identical query:'
EXPLAIN (ANALYZE, BUFFERS)
SELECT h.customerid, count(*) AS lines
FROM sales.salesorderheader h
JOIN sales.salesorderdetail d ON d.salesorderid = h.salesorderid
WHERE h.orderdate BETWEEN DATE '2013-06-01' AND DATE '2013-06-07'
GROUP BY h.customerid;

-- \echo ''
-- \echo '  >>> THE PUNCHLINE, AND THE LINE TO END THE SESSION ON:'
-- \echo ''
-- \echo '      The join METHOD and/or the join ORDER may have changed between'
-- \echo '      those two plans. Nobody touched the SQL. Nobody added an index.'
-- \echo '      Only the planner''s estimate of how many rows would survive the'
-- \echo '      filter changed.'
-- \echo ''
-- \echo '      "This is why we hunt the row estimate FIRST. In Oracle you'
-- \echo '       compared E-Rows to A-Rows. Here you compare rows= to actual'
-- \echo '       rows=. The syntax changed. The instinct did not - and your'
-- \echo '       instinct is the part that took years to build."'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART E - Fix reference card                                    #'
-- \echo '################################################################'

SELECT 'Stale statistics'      AS symptom,
       'ANALYZE <table>'       AS postgresql_fix,
       'DBMS_STATS.GATHER_TABLE_STATS' AS oracle_equivalent
UNION ALL SELECT 'Skewed data, poor histogram',
       'ALTER TABLE .. ALTER COLUMN .. SET STATISTICS 500; ANALYZE',
       'METHOD_OPT FOR COLUMNS SIZE 254'
UNION ALL SELECT 'Correlated columns',
       'CREATE STATISTICS (dependencies, ndistinct, mcv) ON a,b FROM t',
       'DBMS_STATS.CREATE_EXTENDED_STATS (column group)'
UNION ALL SELECT 'Expression hides the column',
       'rewrite sargable, or CREATE INDEX ON t ((expr))',
       'function-based index + extended stats'
UNION ALL SELECT 'Estimates fine but plan still bad',
       'check random_page_cost / effective_cache_size / work_mem',
       'optimizer_index_cost_adj / pga_aggregate_target';

-- \echo ''
-- \echo '>>> NEXT: 08_index_tradeoffs.sql'
-- \echo ''
