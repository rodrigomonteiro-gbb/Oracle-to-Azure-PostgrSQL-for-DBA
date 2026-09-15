-- =====================================================================
-- 10_full_scenario.sql    THE FINALE - one slow query, six rounds
--
-- A realistic reporting query tuned live. Each round changes exactly ONE
-- thing and re-measures, so the audience sees cause and effect.
--
-- The point of the ORDER is the lesson: we fix KNOWLEDGE before we fix
-- ACCESS PATH. Statistics are free; indexes are a permanent tax.
--
-- Keep a whiteboard open. Each round, record:
--     round | estimate | actual | total cost | buffers | time
-- The trend line IS the demo.
-- =====================================================================

-- \pset pager off
-- \timing on

-- Clean slate so the script is repeatable
DROP INDEX IF EXISTS sales.ix_lab_fs_date;
DROP INDEX IF EXISTS sales.ix_lab_fs_cover;
DROP INDEX IF EXISTS sales.ix_lab_fs_partial;
DROP STATISTICS IF EXISTS sales.stx_lab_fs;
ALTER TABLE sales.salesorderheader ALTER COLUMN orderdate SET STATISTICS -1;
ALTER TABLE sales.salesorderheader ALTER COLUMN duedate   SET STATISTICS -1;

ANALYZE sales.salesorderheader;
ANALYZE sales.salesorderdetail;
ANALYZE sales.customer;
ANALYZE person.person;

-- \echo ''
-- \echo '################################################################'
-- \echo '# THE BUSINESS QUESTION                                         #'
-- \echo '################################################################'
-- \echo '  "For orders placed in H1 2013 that were DUE in the same window'
-- \echo '   and are not yet closed, show me the top 25 customers by'
-- \echo '   revenue."'
-- \echo ''
-- \echo '  Two correlated date predicates, a low-cardinality status filter,'
-- \echo '  four tables, an aggregate and a Top-N. Everything from scripts'
-- \echo '  01-09 shows up in this one plan.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# ROUND 1 - BASELINE                                            #'
-- \echo '################################################################'

EXPLAIN (ANALYZE, BUFFERS)
SELECT p.lastname, p.firstname,
       count(DISTINCT h.salesorderid) AS orders,
       sum(d.linetotal)               AS revenue
FROM sales.salesorderheader   h
JOIN sales.salesorderdetail   d ON d.salesorderid     = h.salesorderid
JOIN sales.customer           c ON c.customerid       = h.customerid
JOIN person.person            p ON p.businessentityid = c.personid
WHERE h.orderdate BETWEEN DATE '2013-01-01' AND DATE '2013-06-30'
  AND h.duedate   BETWEEN DATE '2013-01-13' AND DATE '2013-07-12'
  AND h.status <> 5
GROUP BY p.lastname, p.firstname
ORDER BY revenue DESC
LIMIT 25;

-- \echo ''
-- \echo '  >>> RECORD: est=____ actual=____ cost=____ buffers=____ time=____'
-- \echo ''
-- \echo '  >>> WALK THE TREE BOTTOM-UP AND ASK THE ROOM:'
-- \echo '      1. Which node reads rows only to throw them away?'
-- \echo '         (look for "Rows Removed by Filter")'
-- \echo '      2. Where is rows= furthest from actual rows=?'
-- \echo '      3. Is anything spilling? (Batches>1, temp read/written)'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# ROUND 2 - FIX THE KNOWLEDGE: extended statistics               #'
-- \echo '################################################################'
-- \echo '  orderdate and duedate are correlated. The planner multiplies'
-- \echo '  their selectivities and under-estimates badly.'
-- \echo '  NO INDEX. NO SQL CHANGE. Just the truth about the data.'
-- \echo ''

CREATE STATISTICS sales.stx_lab_fs (dependencies, ndistinct, mcv)
    ON orderdate, duedate, status FROM sales.salesorderheader;
ANALYZE sales.salesorderheader;

EXPLAIN (ANALYZE, BUFFERS)
SELECT p.lastname, p.firstname,
       count(DISTINCT h.salesorderid) AS orders,
       sum(d.linetotal)               AS revenue
FROM sales.salesorderheader   h
JOIN sales.salesorderdetail   d ON d.salesorderid     = h.salesorderid
JOIN sales.customer           c ON c.customerid       = h.customerid
JOIN person.person            p ON p.businessentityid = c.personid
WHERE h.orderdate BETWEEN DATE '2013-01-01' AND DATE '2013-06-30'
  AND h.duedate   BETWEEN DATE '2013-01-13' AND DATE '2013-07-12'
  AND h.status <> 5
GROUP BY p.lastname, p.firstname
ORDER BY revenue DESC
LIMIT 25;

-- \echo ''
-- \echo '  >>> RECORD: est=____ actual=____ cost=____ buffers=____ time=____'
-- \echo ''
-- \echo '      The ESTIMATE should improve sharply. The plan may or may'
-- \echo '      not change yet - and either outcome teaches something:'
-- \echo '      we have separated "the planner is wrong" from "the access'
-- \echo '      path is wrong".'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# ROUND 3 - Raise resolution on the filter column                #'
-- \echo '################################################################'

ALTER TABLE sales.salesorderheader ALTER COLUMN orderdate SET STATISTICS 1000;
ALTER TABLE sales.salesorderheader ALTER COLUMN duedate   SET STATISTICS 1000;
ANALYZE sales.salesorderheader;

EXPLAIN (ANALYZE, BUFFERS)
SELECT p.lastname, p.firstname,
       count(DISTINCT h.salesorderid) AS orders,
       sum(d.linetotal)               AS revenue
FROM sales.salesorderheader   h
JOIN sales.salesorderdetail   d ON d.salesorderid     = h.salesorderid
JOIN sales.customer           c ON c.customerid       = h.customerid
JOIN person.person            p ON p.businessentityid = c.personid
WHERE h.orderdate BETWEEN DATE '2013-01-01' AND DATE '2013-06-30'
  AND h.duedate   BETWEEN DATE '2013-01-13' AND DATE '2013-07-12'
  AND h.status <> 5
GROUP BY p.lastname, p.firstname
ORDER BY revenue DESC
LIMIT 25;

-- \echo ''
-- \echo '  >>> RECORD: est=____ actual=____ cost=____ buffers=____ time=____'
-- \echo ''
-- \echo '      Two rounds in, zero indexes created, zero SQL changed.'
-- \echo '      Everything so far was FREE and reversible.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# ROUND 4 - NOW fix the access path: index the filter            #'
-- \echo '################################################################'

CREATE INDEX ix_lab_fs_date ON sales.salesorderheader (orderdate);
ANALYZE sales.salesorderheader;

EXPLAIN (ANALYZE, BUFFERS)
SELECT p.lastname, p.firstname,
       count(DISTINCT h.salesorderid) AS orders,
       sum(d.linetotal)               AS revenue
FROM sales.salesorderheader   h
JOIN sales.salesorderdetail   d ON d.salesorderid     = h.salesorderid
JOIN sales.customer           c ON c.customerid       = h.customerid
JOIN person.person            p ON p.businessentityid = c.personid
WHERE h.orderdate BETWEEN DATE '2013-01-01' AND DATE '2013-06-30'
  AND h.duedate   BETWEEN DATE '2013-01-13' AND DATE '2013-07-12'
  AND h.status <> 5
GROUP BY p.lastname, p.firstname
ORDER BY revenue DESC
LIMIT 25;

-- \echo ''
-- \echo '  >>> RECORD: est=____ actual=____ cost=____ buffers=____ time=____'
-- \echo ''
-- \echo '      "Rows Removed by Filter" on salesorderheader should collapse.'
-- \echo '      The JOIN METHOD may also have changed - one index can'
-- \echo '      reshape the entire plan.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# ROUND 5 - PARTIAL + COVERING: the precision instrument         #'
-- \echo '################################################################'
-- \echo '  Combine three ideas at once: index only the rows the query'
-- \echo '  wants (partial), and carry the payload so no heap fetch is'
-- \echo '  needed (INCLUDE).'
-- \echo ''

DROP INDEX sales.ix_lab_fs_date;
CREATE INDEX ix_lab_fs_partial
    ON sales.salesorderheader (orderdate)
    INCLUDE (customerid, salesorderid, duedate)
    WHERE status <> 5;
VACUUM (ANALYZE) sales.salesorderheader;

SELECT indexrelid::regclass AS index_name,
       pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_index WHERE indexrelid = 'sales.ix_lab_fs_partial'::regclass;

EXPLAIN (ANALYZE, BUFFERS)
SELECT p.lastname, p.firstname,
       count(DISTINCT h.salesorderid) AS orders,
       sum(d.linetotal)               AS revenue
FROM sales.salesorderheader   h
JOIN sales.salesorderdetail   d ON d.salesorderid     = h.salesorderid
JOIN sales.customer           c ON c.customerid       = h.customerid
JOIN person.person            p ON p.businessentityid = c.personid
WHERE h.orderdate BETWEEN DATE '2013-01-01' AND DATE '2013-06-30'
  AND h.duedate   BETWEEN DATE '2013-01-13' AND DATE '2013-07-12'
  AND h.status <> 5
GROUP BY p.lastname, p.firstname
ORDER BY revenue DESC
LIMIT 25;

-- \echo ''
-- \echo '  >>> RECORD: est=____ actual=____ cost=____ buffers=____ time=____'
-- \echo ''
-- \echo '      Look for "Index Only Scan" and "Heap Fetches: 0".'
-- \echo '      The VACUUM above is what makes Heap Fetches zero - call it'
-- \echo '      out, it is the PostgreSQL-specific operational habit.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# ROUND 6 - Index the join key on the big child table            #'
-- \echo '################################################################'

DROP INDEX IF EXISTS sales.ix_lab_fs_cover;
CREATE INDEX ix_lab_fs_cover
    ON sales.salesorderdetail (salesorderid) INCLUDE (linetotal);
VACUUM (ANALYZE) sales.salesorderdetail;

EXPLAIN (ANALYZE, BUFFERS)
SELECT p.lastname, p.firstname,
       count(DISTINCT h.salesorderid) AS orders,
       sum(d.linetotal)               AS revenue
FROM sales.salesorderheader   h
JOIN sales.salesorderdetail   d ON d.salesorderid     = h.salesorderid
JOIN sales.customer           c ON c.customerid       = h.customerid
JOIN person.person            p ON p.businessentityid = c.personid
WHERE h.orderdate BETWEEN DATE '2013-01-01' AND DATE '2013-06-30'
  AND h.duedate   BETWEEN DATE '2013-01-13' AND DATE '2013-07-12'
  AND h.status <> 5
GROUP BY p.lastname, p.firstname
ORDER BY revenue DESC
LIMIT 25;

-- \echo ''
-- \echo '  >>> RECORD: est=____ actual=____ cost=____ buffers=____ time=____'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# THE BILL - what did those indexes cost?                       #'
-- \echo '################################################################'
-- \echo '  Always close an index demo with the price tag. It is what makes'
-- \echo '  the rest of your advice credible.'
-- \echo ''

SELECT indexrelid::regclass AS index_name,
       pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_index
WHERE indexrelid::regclass::text LIKE '%ix_lab_fs%';

-- \echo ''
-- \echo '  -- Write cost, measured (rolled back):'
BEGIN;
EXPLAIN (ANALYZE, BUFFERS, WAL)
UPDATE sales.salesorderheader SET totaldue = totaldue
WHERE salesorderid BETWEEN 43659 AND 45659;
ROLLBACK;

-- \echo ''
-- \echo '################################################################'
-- \echo '# THE SUMMARY SLIDE                                             #'
-- \echo '################################################################'

SELECT 1 AS round, 'Baseline'                        AS change,
       'none'                                        AS cost,
       'bad estimate, Seq Scan, filter throwing rows away' AS result
UNION ALL SELECT 2, 'CREATE STATISTICS (correlated dates)',
       'a few KB',   'estimate corrected - NO index, NO SQL change'
UNION ALL SELECT 3, 'SET STATISTICS 1000 on the date columns',
       'ANALYZE time', 'finer histogram, better range estimate'
UNION ALL SELECT 4, 'Index the filter column',
       'storage + write tax', 'Rows Removed by Filter collapses'
UNION ALL SELECT 5, 'Partial + covering index',
       'smaller than round 4', 'Index Only Scan, Heap Fetches 0'
UNION ALL SELECT 6, 'Cover the join key on the child table',
       'storage + write tax', 'join served from the index'
ORDER BY 1;

-- \echo ''
-- \echo '  >>> CLOSE ON THIS - IT IS THE WHOLE SESSION IN FOUR SENTENCES:'
-- \echo ''
-- \echo '      "Notice the ORDER we worked in. Rounds 2 and 3 cost nothing'
-- \echo '       but a little ANALYZE time and they are instantly'
-- \echo '       reversible. Rounds 4, 5 and 6 buy speed with storage and'
-- \echo '       a permanent tax on every single write to that table."'
-- \echo ''
-- \echo '      "So fix what the planner KNOWS before you change how it'
-- \echo '       READS. Most teams do it backwards - they add indexes to'
-- \echo '       compensate for statistics that were never gathered,'
-- \echo '       and then pay for those indexes forever."'
-- \echo ''
-- \echo '>>> FINALLY: run 99_cleanup.sql to remove every ix_lab_* object.'
-- \echo ''
