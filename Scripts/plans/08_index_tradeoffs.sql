-- =====================================================================
-- 08_index_tradeoffs.sql   The honest half of the index conversation
--
-- Anyone can show "add an index, query gets faster". The credible version
-- shows what it COSTS: storage, write amplification, and indexes that
-- silently do nothing.
--
-- Also: partial indexes, expression indexes, index bloat, and the
-- unused-index audit query you should leave with the customer.
--
-- All writes happen inside BEGIN/ROLLBACK - adventureworks data is
-- returned to its exact original state.
-- =====================================================================

-- \pset pager off
-- \timing on

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART A - What the indexes already cost you                    #'
-- \echo '################################################################'

SELECT schemaname || '.' || relname                  AS table_name,
       pg_size_pretty(pg_relation_size(relid))       AS heap,
       pg_size_pretty(pg_indexes_size(relid))        AS indexes,
       round(100.0 * pg_indexes_size(relid) /
             NULLIF(pg_relation_size(relid), 0), 1)  AS index_pct_of_heap
FROM pg_stat_user_tables
WHERE schemaname IN ('sales','person','production')
ORDER BY pg_indexes_size(relid) DESC
LIMIT 12;

-- \echo ''
-- \echo '      index_pct_of_heap above ~100% means you are storing more index'
-- \echo '      than data. Sometimes justified. Always worth a conversation.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART B - Write amplification, measured                        #'
-- \echo '################################################################'
-- \echo '  EXPLAIN (ANALYZE, BUFFERS, WAL) on an INSERT, with and without'
-- \echo '  extra indexes. Everything is rolled back.'
-- \echo ''

DROP INDEX IF EXISTS sales.ix_demo_wa_1;
DROP INDEX IF EXISTS sales.ix_demo_wa_2;
DROP INDEX IF EXISTS sales.ix_demo_wa_3;

-- \echo '  -- B1. Baseline UPDATE cost (rolled back):'
BEGIN;
EXPLAIN (ANALYZE, BUFFERS, WAL)
UPDATE sales.salesorderheader
SET    totaldue = totaldue
WHERE  salesorderid BETWEEN 43659 AND 44659;
ROLLBACK;

-- \echo ''
-- \echo '      Note "WAL: records=N  bytes=N" - that is the write cost.'
-- \echo ''

-- \echo '  -- B2. Add three indexes on columns the UPDATE touches:'
CREATE INDEX ix_demo_wa_1 ON sales.salesorderheader (totaldue);
CREATE INDEX ix_demo_wa_2 ON sales.salesorderheader (totaldue, orderdate);
CREATE INDEX ix_demo_wa_3 ON sales.salesorderheader (totaldue, customerid, status);
ANALYZE sales.salesorderheader;

-- \echo '  -- B3. Identical UPDATE, identical rows:'
BEGIN;
EXPLAIN (ANALYZE, BUFFERS, WAL)
UPDATE sales.salesorderheader
SET    totaldue = totaldue
WHERE  salesorderid BETWEEN 43659 AND 44659;
ROLLBACK;

-- \echo ''
-- \echo '  >>> COMPARE WAL bytes and shared dirtied between B1 and B3.'
-- \echo ''
-- \echo '      Every index on an updated column must ALSO be updated.'
-- \echo '      Say: "An index is a permanent tax on every write, paid to make'
-- \echo '       certain reads faster. Worth it when you collect - expensive'
-- \echo '       when the index is never used. So let us go find the ones'
-- \echo '       nobody is using."'
-- \echo ''
-- \echo '      PostgreSQL nuance worth mentioning: HOT (Heap-Only Tuple)'
-- \echo '      updates can skip index maintenance entirely - but ONLY when no'
-- \echo '      indexed column changed AND the page has free space (fillfactor).'
-- \echo '      More indexes = fewer HOT updates = more write amplification.'
-- \echo ''

DROP INDEX IF EXISTS sales.ix_demo_wa_1;
DROP INDEX IF EXISTS sales.ix_demo_wa_2;
DROP INDEX IF EXISTS sales.ix_demo_wa_3;

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART C - THE UNUSED INDEX AUDIT - leave this with the customer #'
-- \echo '################################################################'

SELECT s.schemaname || '.' || s.relname            AS table_name,
       s.indexrelname                              AS index_name,
       s.idx_scan                                  AS times_used,
       pg_size_pretty(pg_relation_size(s.indexrelid)) AS size,
       CASE WHEN i.indisprimary THEN 'PRIMARY KEY - keep'
            WHEN i.indisunique  THEN 'UNIQUE constraint - keep'
            WHEN s.idx_scan = 0 THEN 'NEVER USED - drop candidate'
            WHEN s.idx_scan < 50 THEN 'rarely used - review'
            ELSE 'in use'
       END                                         AS verdict
FROM pg_stat_user_indexes s
JOIN pg_index i ON i.indexrelid = s.indexrelid
WHERE s.schemaname IN ('sales','person','production','humanresources','purchasing')
ORDER BY s.idx_scan ASC, pg_relation_size(s.indexrelid) DESC
LIMIT 25;

-- \echo ''
-- \echo '      CAVEAT TO STATE OUT LOUD: idx_scan counts since the last'
-- \echo '      statistics reset. Check the age before you trust a zero -'
-- \echo '      a quarter-end report index may look unused in July:'
SELECT stats_reset FROM pg_stat_database WHERE datname = current_database();

-- \echo ''
-- \echo '      Never drop a unique or PK index - it enforces a constraint.'
-- \echo '      Oracle equivalent of this audit: V$OBJECT_USAGE / index'
-- \echo '      monitoring. Same conversation, better ergonomics.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART D - PARTIAL INDEX: index only the rows that matter        #'
-- \echo '################################################################'
-- \echo '  No Oracle equivalent (Oracle needs a function-based index trick).'
-- \echo '  Genuinely a PostgreSQL advantage - lead with it.'
-- \echo ''

DROP INDEX IF EXISTS sales.ix_demo_soh_status_full;
DROP INDEX IF EXISTS sales.ix_demo_soh_status_partial;

-- \echo '  -- D1. Full index on status:'
CREATE INDEX ix_demo_soh_status_full ON sales.salesorderheader (status);
ANALYZE sales.salesorderheader;

-- \echo '  -- D2. Partial index - only the rare, interesting rows:'
CREATE INDEX ix_demo_soh_status_partial
    ON sales.salesorderheader (orderdate)
    WHERE status <> 5;
ANALYZE sales.salesorderheader;

SELECT indexrelid::regclass AS index_name,
       pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_index
WHERE indexrelid IN ('sales.ix_demo_soh_status_full'::regclass,
                     'sales.ix_demo_soh_status_partial'::regclass);

-- \echo ''
-- \echo '      Compare the sizes. The partial index covers only the rows you'
-- \echo '      actually query, so it is smaller, stays hotter in cache, and'
-- \echo '      costs less on every write to the excluded rows.'
-- \echo ''

EXPLAIN (ANALYZE, BUFFERS)
SELECT salesorderid, orderdate, status
FROM sales.salesorderheader
WHERE status <> 5
  AND orderdate >= DATE '2013-01-01';

-- \echo ''
-- \echo '      The planner must PROVE the query predicate implies the index'
-- \echo '      predicate. If the WHERE clause does not match, the partial'
-- \echo '      index is silently ignored - a common gotcha worth demonstrating:'

EXPLAIN (ANALYZE)
SELECT salesorderid, orderdate, status
FROM sales.salesorderheader
WHERE orderdate >= DATE '2013-01-01';

-- \echo ''
-- \echo '      No status predicate -> partial index unusable. Correct, but'
-- \echo '      surprising the first time you meet it.'
-- \echo ''
-- \echo '      Classic production use: WHERE deleted_at IS NULL,'
-- \echo '      WHERE status = ''pending'' - index 2% of a huge table.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART E - Indexes that silently do NOTHING                      #'
-- \echo '################################################################'

DROP INDEX IF EXISTS person.ix_demo_person_lastname;
CREATE INDEX ix_demo_person_lastname ON person.person (lastname);
ANALYZE person.person;

-- \echo '  -- E1. Leading wildcard - B-tree cannot help:'
EXPLAIN (ANALYZE)
SELECT businessentityid, lastname FROM person.person WHERE lastname LIKE '%son';

-- \echo ''
-- \echo '  -- E2. Function on the column - index on the raw column unusable:'
EXPLAIN (ANALYZE)
SELECT businessentityid, lastname FROM person.person WHERE upper(lastname) = 'SMITH';

-- \echo ''
-- \echo '  -- E3. Fix E2 with an expression index (Oracle: function-based index):'
DROP INDEX IF EXISTS person.ix_demo_person_upper_lastname;
CREATE INDEX ix_demo_person_upper_lastname ON person.person (upper(lastname));
ANALYZE person.person;

EXPLAIN (ANALYZE)
SELECT businessentityid, lastname FROM person.person WHERE upper(lastname) = 'SMITH';

-- \echo ''
-- \echo '  -- E4. Fix E1 with a trigram index (needs pg_trgm):'
-- \echo '        CREATE EXTENSION IF NOT EXISTS pg_trgm;'
-- \echo '        CREATE INDEX ix_demo_person_lastname_trgm'
-- \echo '          ON person.person USING gin (lastname gin_trgm_ops);'
-- \echo '        -> now LIKE ''%son'' CAN use an index.'
-- \echo '        On Azure, pg_trgm must be in azure.extensions first.'
-- \echo ''
-- \echo '  -- E5. Type mismatch - a silent plan killer:'
EXPLAIN (ANALYZE)
SELECT salesorderid FROM sales.salesorderheader WHERE salesorderid::text = '43659';

-- \echo ''
-- \echo '      Casting the COLUMN defeats the index. Casting the LITERAL is'
-- \echo '      free. This one hides in ORMs constantly.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART F - Index bloat and REINDEX CONCURRENTLY                  #'
-- \echo '################################################################'

SELECT s.indexrelname AS index_name,
       pg_size_pretty(pg_relation_size(s.indexrelid)) AS size,
       s.idx_scan AS times_used
FROM pg_stat_user_indexes s
WHERE s.schemaname = 'sales'
ORDER BY pg_relation_size(s.indexrelid) DESC
LIMIT 10;

-- \echo ''
-- \echo '      PostgreSQL B-trees fragment under heavy update/delete. Rebuild'
-- \echo '      WITHOUT blocking writes:'
-- \echo '        REINDEX INDEX CONCURRENTLY sales.<index_name>;'
-- \echo '      (PG 12+. Slower, uses more space, but does not take the lock'
-- \echo '       that plain REINDEX does. Always CONCURRENTLY in production.)'
-- \echo ''
-- \echo '      Same for creating an index on a live system:'
-- \echo '        CREATE INDEX CONCURRENTLY ...'
-- \echo '      It cannot run inside a transaction block, and it can leave an'
-- \echo '      INVALID index behind if it fails - check pg_index.indisvalid'
-- \echo '      afterwards and drop any invalid leftovers.'
-- \echo ''

-- \echo ''
-- \echo '>>> NEXT: 09_full_scenario.sql   - the end-to-end tuning story'
-- \echo ''
