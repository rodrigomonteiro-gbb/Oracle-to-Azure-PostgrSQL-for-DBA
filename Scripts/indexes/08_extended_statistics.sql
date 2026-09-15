-- =====================================================================
-- 08_extended_statistics.sql    CREATE STATISTICS
--
-- *** THE BEST-KEPT SECRET IN POSTGRESQL TUNING ***
--
-- PostgreSQL assumes predicates are INDEPENDENT and multiplies their
-- selectivities. When columns are correlated that assumption collapses
-- the estimate by orders of magnitude - and no index can fix it,
-- because the problem is knowledge, not access path.
--
-- Oracle solved this with extended statistics / column groups.
-- PostgreSQL has CREATE STATISTICS. Almost nobody on a migrated
-- database has ever created one.
--
-- Four kinds:
--   dependencies   functional dependency  a -> b
--   ndistinct      distinct COMBINATIONS of columns (fixes GROUP BY)
--   mcv            multivariate most-common-value list
--   expressions    statistics on an expression, NO INDEX NEEDED (PG14+)
-- =====================================================================

-- \pset pager off
-- \timing on

ANALYZE sales.salesorderheader;
ANALYZE person.person;

DROP STATISTICS IF EXISTS sales.stx_lab_dates;
DROP STATISTICS IF EXISTS sales.stx_lab_cust_terr;
DROP STATISTICS IF EXISTS sales.stx_lab_expr;

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART A - Prove the columns are correlated                     #'
-- \echo '################################################################'
-- \echo '  In AdventureWorks, duedate is almost always orderdate + 12 days'
-- \echo '  and shipdate is orderdate + 7. Textbook functional dependency.'
-- \echo ''

SELECT count(*)                                              AS total_rows,
       count(*) FILTER (WHERE duedate = orderdate + 12)      AS duedate_is_order_plus_12,
       round(100.0 * count(*) FILTER (WHERE duedate = orderdate + 12)
             / count(*), 1)                                  AS pct
FROM sales.salesorderheader;

-- \echo ''
-- \echo '   If that percentage is high, the columns carry almost NO'
-- \echo '   independent information - yet the planner will treat them as'
-- \echo '   two independent filters and multiply their selectivities.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART B - dependencies: the headline fix                       #'
-- \echo '################################################################'

-- \echo '  -- B1. BEFORE - independence assumed:'
EXPLAIN (ANALYZE)
SELECT count(*) FROM sales.salesorderheader
WHERE orderdate BETWEEN DATE '2013-01-01' AND DATE '2013-06-30'
  AND duedate   BETWEEN DATE '2013-01-13' AND DATE '2013-07-12';

-- \echo ''
-- \echo '      >>> RECORD:  rows=______   actual rows=______'
-- \echo '      The estimate should be badly LOW: the planner multiplied'
-- \echo '      two ~50% selectivities and got ~25%, when the truth is'
-- \echo '      nearly 50% because the two filters select the same rows.'
-- \echo ''

-- \echo '  -- B2. Teach it the relationship:'
CREATE STATISTICS sales.stx_lab_dates (dependencies, ndistinct, mcv)
    ON orderdate, duedate FROM sales.salesorderheader;
ANALYZE sales.salesorderheader;

-- \echo '  -- B3. AFTER - identical query:'
EXPLAIN (ANALYZE)
SELECT count(*) FROM sales.salesorderheader
WHERE orderdate BETWEEN DATE '2013-01-01' AND DATE '2013-06-30'
  AND duedate   BETWEEN DATE '2013-01-13' AND DATE '2013-07-12';

-- \echo ''
-- \echo '  >>> The estimate should move sharply toward the actual.'
-- \echo ''
-- \echo '      NO INDEX WAS CREATED. NO SQL WAS CHANGED.'
-- \echo '      We only told the planner something true about the data.'
-- \echo ''

-- \echo '  -- What it learned:'
SELECT statistics_name, attnames, kinds
FROM pg_stats_ext WHERE statistics_name = 'stx_lab_dates';

SELECT dependencies
FROM pg_stats_ext WHERE statistics_name = 'stx_lab_dates';

-- \echo ''
-- \echo '      Read the dependency degrees: "1 => 2: 0.98" means column 1'
-- \echo '      determines column 2 with 98% confidence. Near 1.0 is a'
-- \echo '      strong functional dependency.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART C - ndistinct: fixes GROUP BY estimates                  #'
-- \echo '################################################################'
-- \echo '  For GROUP BY a, b the planner multiplies n_distinct(a) by'
-- \echo '  n_distinct(b). When the columns are related that product is'
-- \echo '  wildly too high - and a too-high group estimate is what makes'
-- \echo '  a HashAggregate spill to disk.'
-- \echo ''

-- \echo '  -- C1. The truth vs the naive product:'
SELECT (SELECT count(DISTINCT customerid)  FROM sales.salesorderheader) AS distinct_customers,
       (SELECT count(DISTINCT territoryid) FROM sales.salesorderheader) AS distinct_territories,
       (SELECT count(DISTINCT customerid)  FROM sales.salesorderheader)
         * (SELECT count(DISTINCT territoryid) FROM sales.salesorderheader) AS naive_product,
       (SELECT count(*) FROM (
          SELECT DISTINCT customerid, territoryid FROM sales.salesorderheader) s)
                                                                        AS actual_combinations;

-- \echo ''
-- \echo '   naive_product vs actual_combinations - that gap IS the error.'
-- \echo '   Each customer belongs to one territory, so the combinations'
-- \echo '   barely exceed the customer count.'
-- \echo ''

-- \echo '  -- C2. BEFORE:'
EXPLAIN (ANALYZE)
SELECT customerid, territoryid, count(*)
FROM sales.salesorderheader GROUP BY customerid, territoryid;

-- \echo ''
-- \echo '  -- C3. Teach it:'
CREATE STATISTICS sales.stx_lab_cust_terr (ndistinct)
    ON customerid, territoryid FROM sales.salesorderheader;
ANALYZE sales.salesorderheader;

SELECT statistics_name, n_distinct FROM pg_stats_ext
WHERE statistics_name = 'stx_lab_cust_terr';

-- \echo ''
-- \echo '  -- C4. AFTER:'
EXPLAIN (ANALYZE)
SELECT customerid, territoryid, count(*)
FROM sales.salesorderheader GROUP BY customerid, territoryid;

-- \echo ''
-- \echo '   A better group-count estimate means better MEMORY sizing for'
-- \echo '   the HashAggregate - which is how you stop a GROUP BY from'
-- \echo '   silently spilling to disk. Tie this back to "Batches: >1".'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART D - mcv: multivariate most-common values                 #'
-- \echo '################################################################'
-- \echo '  dependencies and ndistinct help with RANGES and GROUP BY.'
-- \echo '  For specific VALUE COMBINATIONS you want the MCV kind.'
-- \echo ''

DROP STATISTICS IF EXISTS person.stx_lab_persontype;
CREATE STATISTICS person.stx_lab_persontype (mcv, dependencies)
    ON persontype, emailpromotion FROM person.person;
ANALYZE person.person;

EXPLAIN (ANALYZE)
SELECT count(*) FROM person.person
WHERE persontype = 'IN' AND emailpromotion = 0;

-- \echo ''
SELECT statistics_name, attnames, kinds FROM pg_stats_ext
WHERE statistics_name = 'stx_lab_persontype';

-- \echo ''
-- \echo '   The MCV kind stores frequencies for VALUE PAIRS, so the'
-- \echo '   planner no longer multiplies two independent frequencies for'
-- \echo '   combinations it has actually observed.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART E - expressions (PG14+): stats without an index          #'
-- \echo '################################################################'
-- \echo '  Before PG14 the ONLY way to get statistics on an expression was'
-- \echo '  to build an expression INDEX - paying index storage and write'
-- \echo '  cost just to buy the planner some knowledge.'
-- \echo '  Now you can have the statistics alone.'
-- \echo ''

-- \echo '  -- E1. BEFORE - expression is opaque, estimate is a guess:'
EXPLAIN (ANALYZE)
SELECT count(*) FROM sales.salesorderheader
WHERE EXTRACT(YEAR FROM orderdate) = 2013;

-- \echo ''
-- \echo '  -- E2. Statistics on the expression, NO INDEX:'
DO $$
BEGIN
  EXECUTE 'CREATE STATISTICS sales.stx_lab_expr
             ON (EXTRACT(YEAR FROM orderdate)) FROM sales.salesorderheader';
  EXECUTE 'ANALYZE sales.salesorderheader';
  RAISE NOTICE 'expression statistics created';
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'expression statistics need PG14+: %', SQLERRM;
END $$;

-- \echo '  -- E3. AFTER:'
EXPLAIN (ANALYZE)
SELECT count(*) FROM sales.salesorderheader
WHERE EXTRACT(YEAR FROM orderdate) = 2013;

-- \echo ''
-- \echo '  >>> The estimate improves. The plan may still be a Seq Scan -'
-- \echo '      AND THAT IS THE POINT. We fixed the KNOWLEDGE problem'
-- \echo '      without paying for an index. If you also need the ACCESS'
-- \echo '      path, then build the expression index; often you do not.'
-- \echo ''
-- \echo '      Separating "the planner is wrong" from "the access path is'
-- \echo '      wrong" is the single most useful diagnostic distinction in'
-- \echo '      this whole session.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART F - Everything we created                                #'
-- \echo '################################################################'

SELECT statistics_schema || '.' || statistics_name AS stats_object,
       tablename, attnames, exprs, kinds
FROM pg_stats_ext
WHERE statistics_name LIKE 'stx\_lab\_%'
ORDER BY 1;

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART G - When to reach for each kind                          #'
-- \echo '################################################################'

SELECT 'dependencies' AS kind,
       'columns where one implies the other'                    AS use_when,
       'WHERE city=? AND state=?  /  orderdate + duedate'       AS example,
       'extended stats (column group)'                          AS oracle_equivalent
UNION ALL SELECT 'ndistinct',
       'GROUP BY on several related columns',
       'GROUP BY customerid, territoryid',
       'extended stats (column group)'
UNION ALL SELECT 'mcv',
       'specific VALUE COMBINATIONS are common',
       'WHERE status=? AND type=?',
       'extended stats with histograms'
UNION ALL SELECT 'expressions',
       'a function wraps a column and you cannot change the SQL',
       'WHERE date_trunc(''month'', ts) = ?',
       'extended stats on an expression';

-- \echo ''
-- \echo '   HOW TO FIND CANDIDATES IN A CUSTOMER DATABASE:'
-- \echo '     1. Find plans where rows= is far from actual rows='
-- \echo '     2. Look at the WHERE clause: two or more predicates on the'
-- \echo '        SAME table?'
-- \echo '     3. Ask whether those columns are logically related'
-- \echo '        (city/state, order/due date, category/subcategory,'
-- \echo '         make/model, country/currency)'
-- \echo '     4. CREATE STATISTICS, ANALYZE, re-run EXPLAIN'
-- \echo ''
-- \echo '   Cost: a little ANALYZE time and a few KB. There is almost no'
-- \echo '   downside, and most migrated databases have ZERO of these.'
-- \echo '   This is the cheapest tuning win you can hand a customer.'
-- \echo ''
-- \echo '>>> NEXT: 09_stats_lifecycle.sql'
-- \echo ''
