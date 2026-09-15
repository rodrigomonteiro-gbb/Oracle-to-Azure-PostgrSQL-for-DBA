-- =====================================================================
-- 02_seqscan_vs_index.sql   *** THE FLAGSHIP DEMO ***
--
--   Seq Scan  (Oracle: TABLE ACCESS FULL)
--      -> CREATE INDEX ->
--   Index Scan (Oracle: INDEX RANGE SCAN + TABLE ACCESS BY INDEX ROWID)
--
-- Run it top to bottom. It prints BEFORE cost, creates ONE index, prints
-- AFTER cost, and you read the two numbers side by side.
--
-- Every index created here is named ix_demo_*  and dropped by 99_cleanup.sql.
-- NO adventureworks data is modified.
-- =====================================================================

-- \pset pager off
-- \timing on

-- Make estimates trustworthy before measuring anything.
ANALYZE sales.salesorderheader;

-- Start from a known state (safe to re-run this script)
DROP INDEX IF EXISTS sales.ix_demo_soh_orderdate;

-- \echo ''
-- \echo '################################################################'
-- \echo '# STEP 1 - BEFORE. No index on orderdate.                      #'
-- \echo '################################################################'
-- \echo '  A narrow date range: we want a handful of rows out of ~31,000.'
-- \echo ''

EXPLAIN (ANALYZE, BUFFERS)
SELECT salesorderid, customerid, orderdate, totaldue
FROM sales.salesorderheader
WHERE orderdate BETWEEN DATE '2013-06-01' AND DATE '2013-06-07';

-- \echo ''
-- \echo '  >>> POINT AT THESE THREE THINGS:'
-- \echo ''
-- \echo '  1. "Seq Scan on salesorderheader"'
-- \echo '        = Oracle TABLE ACCESS FULL. Every page, every row.'
-- \echo ''
-- \echo '  2. "cost=0.00..NNN.NN"  <-- WRITE THE TOTAL COST ON THE WHITEBOARD.'
-- \echo '        Startup cost 0.00 is the signature of a Seq Scan: it can'
-- \echo '        return the first row immediately, it just has to read'
-- \echo '        everything to find them all.'
-- \echo ''
-- \echo '  3. "Rows Removed by Filter: NNNNN"  <-- THE SMOKING GUN.'
-- \echo '        We read ~31,000 rows and threw away almost all of them.'
-- \echo '        That ratio - rows kept vs rows removed - is the single best'
-- \echo '        "this needs an index" signal in the whole plan.'
-- \echo ''
-- \echo '  4. "Buffers: shared hit=NNN"'
-- \echo '        = Oracle buffer gets. Remember this number too.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# STEP 2 - Prove the planner is not being lazy                 #'
-- \echo '################################################################'
-- \echo '  Ask: "Could it have done better?" Force the issue - if no index'
-- \echo '  exists, disabling Seq Scan changes nothing. There IS no alternative.'
-- \echo ''

SET enable_seqscan = off;

EXPLAIN (ANALYZE, BUFFERS)
SELECT salesorderid, customerid, orderdate, totaldue
FROM sales.salesorderheader
WHERE orderdate BETWEEN DATE '2013-06-01' AND DATE '2013-06-07';

RESET enable_seqscan;

-- \echo ''
-- \echo '  Still a Seq Scan (possibly with an inflated cost). enable_seqscan=off'
-- \echo '  is a DISCOURAGEMENT, not a prohibition - PostgreSQL will still do it'
-- \echo '  when there is no other way. Oracle folks: this is the rough equivalent'
-- \echo '  of testing a hypothesis with a hint before committing to an index.'
-- \echo '  It is a DIAGNOSTIC TOOL, never a production setting.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# STEP 3 - Create the index                                    #'
-- \echo '################################################################'

CREATE INDEX ix_demo_soh_orderdate
    ON sales.salesorderheader (orderdate);

ANALYZE sales.salesorderheader;

-- \echo ''
SELECT indexrelid::regclass                              AS index_name,
       pg_size_pretty(pg_relation_size(indexrelid))      AS index_size
FROM pg_index
WHERE indexrelid = 'sales.ix_demo_soh_orderdate'::regclass;

-- \echo ''
-- \echo '  Note the index SIZE. An index is not free - it costs storage and it'
-- \echo '  costs every INSERT/UPDATE/DELETE. Script 08 covers write amplification.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# STEP 4 - AFTER. Identical query.                             #'
-- \echo '################################################################'

EXPLAIN (ANALYZE, BUFFERS)
SELECT salesorderid, customerid, orderdate, totaldue
FROM sales.salesorderheader
WHERE orderdate BETWEEN DATE '2013-06-01' AND DATE '2013-06-07';

-- \echo ''
-- \echo '  >>> NOW COMPARE, SIDE BY SIDE:'
-- \echo ''
-- \echo '                          BEFORE              AFTER'
-- \echo '  Operator                Seq Scan            Index Scan'
-- \echo '  Oracle name             TABLE ACCESS FULL   INDEX RANGE SCAN'
-- \echo '  Total cost              (whiteboard)        (much lower)'
-- \echo '  Startup cost            0.00                >0  (must descend the B-tree)'
-- \echo '  Rows Removed by Filter  thousands           0   <-- THE WHOLE POINT'
-- \echo '  Buffers: shared hit     hundreds            a handful'
-- \echo ''
-- \echo '  "Rows Removed by Filter: 0" is the money line. We stopped reading'
-- \echo '  rows in order to throw them away. We now go straight to them.'
-- \echo ''
-- \echo '  The Index Cond line is the predicate the INDEX evaluated.'
-- \echo '  A Filter line, by contrast, is evaluated AFTER the rows are fetched.'
-- \echo '  Index Cond = good. Filter on a large row count = still doing work.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# STEP 5 - The nuance that makes you credible                  #'
-- \echo '################################################################'
-- \echo '  Widen the range. Same index, same table - watch the planner ABANDON'
-- \echo '  the index on purpose.'
-- \echo ''

EXPLAIN (ANALYZE, BUFFERS)
SELECT salesorderid, customerid, orderdate, totaldue
FROM sales.salesorderheader
WHERE orderdate >= DATE '2012-01-01';

-- \echo ''
-- \echo '  Back to a Seq Scan - and that is CORRECT. When a query touches a'
-- \echo '  large fraction of the table, random-access index lookups cost MORE'
-- \echo '  than reading it sequentially. Same logic as Oracle choosing a full'
-- \echo '  table scan over an index range scan at high selectivity.'
-- \echo ''
-- \echo '  Say this: "An index is not a performance setting you switch on.'
-- \echo '   It is a bet on selectivity. The planner re-evaluates that bet for'
-- \echo '   every query, using the statistics. When someone tells me the'
-- \echo '   database is ignoring their index, this is usually why - and the'
-- \echo '   planner is usually right."'
-- \echo ''
-- \echo '  The cost model driving that decision:'
SELECT name, setting FROM pg_settings
WHERE name IN ('seq_page_cost','random_page_cost','effective_cache_size');
-- \echo ''
-- \echo '  random_page_cost 4.0 is a SPINNING DISK default. On Azure Premium SSD'
-- \echo '  it should be 1.1-2.0. Leaving it at 4.0 systematically biases the'
-- \echo '  planner AWAY from your indexes. This is one of the highest-value,'
-- \echo '  lowest-risk tuning changes on a migrated workload.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# STEP 6 - Cost breakdown table for the slide                  #'
-- \echo '################################################################'

SELECT 'Seq Scan'   AS operator, 'TABLE ACCESS FULL'  AS oracle_equivalent,
       'reads every page; startup cost 0.00'          AS characteristic,
       'wins when you need most of the table'         AS best_when
UNION ALL SELECT 'Index Scan', 'INDEX RANGE SCAN',
       'B-tree descent, then heap fetch per row',
       'selective predicate, few rows returned'
UNION ALL SELECT 'Index Only Scan', 'INDEX FAST FULL SCAN',
       'answered from the index alone, no heap fetch',
       'all needed columns are in the index'
UNION ALL SELECT 'Bitmap Heap Scan', '(no direct equivalent)',
       'collects tids, sorts them, reads heap in page order',
       'medium selectivity - too many for index, too few for seq';

-- \echo ''
-- \echo '>>> NEXT: 03_index_only_and_bitmap.sql'
-- \echo '>>> The index stays in place for that script. 99_cleanup.sql drops it.'
-- \echo ''
