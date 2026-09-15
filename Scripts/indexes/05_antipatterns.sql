-- =====================================================================
-- 05_antipatterns.sql    Indexes that do NOTHING
--
-- Every one of these is real, common, and invisible until you look at
-- a plan. Demo them deliberately so nobody meets them in production.
--
-- Most of these are engine-independent - they bite in Oracle too - which
-- makes them a good confidence-builder for a migrating audience.
-- =====================================================================

-- \pset pager off
-- \timing on

ANALYZE person.person;
ANALYZE sales.salesorderheader;
ANALYZE production.product;

-- \echo ''
-- \echo '################################################################'
-- \echo '# 1. LEADING WILDCARD                                           #'
-- \echo '################################################################'

DROP INDEX IF EXISTS person.ix_lab_ap_lastname;
CREATE INDEX ix_lab_ap_lastname ON person.person (lastname);
ANALYZE person.person;

-- \echo '  -- Trailing wildcard -> INDEX USED'
EXPLAIN (ANALYZE) SELECT count(*) FROM person.person WHERE lastname LIKE 'Sm%';

-- \echo ''
-- \echo '  -- Leading wildcard -> SEQ SCAN'
EXPLAIN (ANALYZE) SELECT count(*) FROM person.person WHERE lastname LIKE '%mith';

-- \echo ''
-- \echo '   A B-tree is sorted by the WHOLE value. No leading prefix means'
-- \echo '   no way to seek. Identical in Oracle.'
-- \echo '   FIX: pg_trgm GIN index (script 02 part C), or a reversed-string'
-- \echo '        expression index if the wildcard is always leading.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# 2. FUNCTION APPLIED TO THE COLUMN                             #'
-- \echo '################################################################'

-- \echo '  -- Bare column -> INDEX USED'
EXPLAIN (ANALYZE) SELECT count(*) FROM person.person WHERE lastname = 'Smith';

-- \echo ''
-- \echo '  -- Function on the column -> SEQ SCAN'
EXPLAIN (ANALYZE) SELECT count(*) FROM person.person WHERE upper(lastname) = 'SMITH';

-- \echo ''
-- \echo '   FIX: index the expression, or rewrite so the column is bare.'
-- \echo '   The rewrite is better when you control the SQL - one plain'
-- \echo '   index then serves every predicate on that column.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# 3. IMPLICIT TYPE CAST - the silent one                        #'
-- \echo '################################################################'

-- \echo '  -- Matching types -> INDEX USED'
EXPLAIN (ANALYZE) SELECT salesorderid FROM sales.salesorderheader
WHERE salesorderid = 43659;

-- \echo ''
-- \echo '  -- Column cast to text -> INDEX DEAD'
EXPLAIN (ANALYZE) SELECT salesorderid FROM sales.salesorderheader
WHERE salesorderid::text = '43659';

-- \echo ''
-- \echo '   Casting the COLUMN kills the index. Casting the LITERAL is free.'
-- \echo '   This hides in ORMs and in schemas where an id is text on one'
-- \echo '   table and integer on another - then the JOIN silently degrades.'
-- \echo ''
-- \echo '   Hunt for mismatched join-key types:'
SELECT c.relname AS table_name, a.attname AS column_name,
       format_type(a.atttypid, a.atttypmod) AS data_type
FROM pg_attribute a
JOIN pg_class c ON c.oid = a.attrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname IN ('sales','person','production')
  AND a.attname IN ('customerid','productid','salesorderid','businessentityid')
  AND a.attnum > 0 AND NOT a.attisdropped
ORDER BY a.attname, c.relname;

-- \echo ''
-- \echo '   Same column name with DIFFERENT types across tables is a bug'
-- \echo '   waiting to surface as a slow join.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# 4. LOW-CARDINALITY COLUMN, indexed alone                      #'
-- \echo '################################################################'

SELECT makeflag, count(*) AS rows,
       round(100.0*count(*)/sum(count(*)) OVER (),1) AS pct
FROM production.product GROUP BY makeflag;

DROP INDEX IF EXISTS production.ix_lab_ap_makeflag;
CREATE INDEX ix_lab_ap_makeflag ON production.product (makeflag);
ANALYZE production.product;

EXPLAIN (ANALYZE) SELECT count(*) FROM production.product WHERE makeflag = true;

-- \echo ''
-- \echo '   A boolean splits the table roughly in half, so the index is'
-- \echo '   ignored - correctly. The index costs storage and write time'
-- \echo '   and returns nothing.'
-- \echo ''
-- \echo '   BUT - and this is the nuance that makes you useful:'
-- \echo '   a low-cardinality column is EXCELLENT as a PARTIAL INDEX'
-- \echo '   PREDICATE, or as a SECOND column in a composite.'
-- \echo ''
-- \echo '     BAD :  CREATE INDEX ON orders (status);'
-- \echo '     GOOD:  CREATE INDEX ON orders (created_at) WHERE status=''open'';'
-- \echo ''
-- \echo '   Oracle DBAs will reach for a BITMAP index here. PostgreSQL has'
-- \echo '   no persistent bitmap index - it builds bitmaps on the fly'
-- \echo '   (Bitmap Heap Scan). Partial indexes are the idiomatic answer.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# 5. REDUNDANT INDEXES - paying twice                           #'
-- \echo '################################################################'

DROP INDEX IF EXISTS sales.ix_lab_ap_a;
DROP INDEX IF EXISTS sales.ix_lab_ap_ab;
DROP INDEX IF EXISTS sales.ix_lab_ap_abc;

CREATE INDEX ix_lab_ap_a   ON sales.salesorderheader (customerid);
CREATE INDEX ix_lab_ap_ab  ON sales.salesorderheader (customerid, orderdate);
CREATE INDEX ix_lab_ap_abc ON sales.salesorderheader (customerid, orderdate, status);
ANALYZE sales.salesorderheader;

SELECT indexrelid::regclass AS index_name,
       pg_size_pretty(pg_relation_size(indexrelid)) AS size,
       idx_scan AS times_used
FROM pg_stat_user_indexes
WHERE indexrelid::regclass::text LIKE '%ix_lab_ap_a%'
ORDER BY 1;

-- \echo ''
-- \echo '   (customerid) is fully covered by (customerid, orderdate), which'
-- \echo '   is fully covered by (customerid, orderdate, status).'
-- \echo '   Two of these three are pure cost: storage, write amplification,'
-- \echo '   cache pressure, longer backups, slower restores.'
-- \echo ''
-- \echo '   CAVEAT worth stating: the narrower index IS smaller, so it can'
-- \echo '   be marginally faster for its own query. That is almost never'
-- \echo '   worth the write cost - but "almost never" is not "never", so'
-- \echo '   measure rather than assert.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# 6. OR - the predicate that splits the plan                    #'
-- \echo '################################################################'

DROP INDEX IF EXISTS sales.ix_lab_ap_cust;
DROP INDEX IF EXISTS sales.ix_lab_ap_date;
CREATE INDEX ix_lab_ap_cust ON sales.salesorderheader (customerid);
CREATE INDEX ix_lab_ap_date ON sales.salesorderheader (orderdate);
ANALYZE sales.salesorderheader;

-- \echo '  -- 6a. OR across two columns:'
EXPLAIN (ANALYZE, BUFFERS)
SELECT salesorderid FROM sales.salesorderheader
WHERE customerid = 29825 OR orderdate = DATE '2013-06-01';

-- \echo ''
-- \echo '      Look for BitmapOr - PostgreSQL can union two bitmaps. That'
-- \echo '      is often fine. When it is not, UNION ALL of two indexed'
-- \echo '      branches is the classic rewrite:'
-- \echo ''

EXPLAIN (ANALYZE, BUFFERS)
SELECT salesorderid FROM sales.salesorderheader WHERE customerid = 29825
UNION
SELECT salesorderid FROM sales.salesorderheader WHERE orderdate = DATE '2013-06-01';

-- \echo ''
-- \echo '  -- 6b. NOT / <> is rarely selective:'
EXPLAIN (ANALYZE)
SELECT count(*) FROM sales.salesorderheader WHERE customerid <> 29825;

-- \echo ''
-- \echo '      "Everything except one value" is not selective, so the'
-- \echo '      index is correctly ignored.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# 7. INDEXING A TINY TABLE                                      #'
-- \echo '################################################################'

SELECT relname, n_live_tup,
       pg_size_pretty(pg_relation_size(relid)) AS size
FROM pg_stat_user_tables
WHERE schemaname IN ('sales','person','production')
ORDER BY n_live_tup ASC LIMIT 5;

-- \echo ''
-- \echo '   Under a few thousand rows the whole table is 1-2 pages. A Seq'
-- \echo '   Scan reads it in one IO; an Index Scan reads the index root,'
-- \echo '   a leaf, THEN the heap page. The index is slower.'
-- \echo ''
-- \echo '   When a customer says "the database is ignoring my index", this'
-- \echo '   and high selectivity are the two most common explanations -'
-- \echo '   and in both cases the planner is right.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# 8. THE SUMMARY TABLE                                          #'
-- \echo '################################################################'

SELECT 1 AS n, 'LIKE ''%text''' AS antipattern,
       'no usable leading prefix in a B-tree' AS why,
       'pg_trgm GIN index' AS fix
UNION ALL SELECT 2, 'upper(col) = ?',
       'function hides the column and its statistics',
       'expression index, or rewrite so the column is bare'
UNION ALL SELECT 3, 'col::text = ?',
       'casting the COLUMN defeats the index',
       'cast the LITERAL instead; fix mismatched column types'
UNION ALL SELECT 4, 'index on a boolean / low-cardinality column',
       'not selective enough to beat a Seq Scan',
       'partial index, or use it as a trailing composite column'
UNION ALL SELECT 5, 'indexes on (a), (a,b) and (a,b,c)',
       'leading-column rule makes the narrow ones redundant',
       'keep the widest; drop the covered ones'
UNION ALL SELECT 6, 'OR across columns',
       'may force a scan or a BitmapOr',
       'UNION of indexed branches when BitmapOr underperforms'
UNION ALL SELECT 7, 'index on a tiny table',
       'a Seq Scan is one IO',
       'do not index small lookup tables'
UNION ALL SELECT 8, 'index that is never scanned',
       'pure write and storage cost',
       'idx_scan = 0 audit, then drop'
ORDER BY 1;

-- \echo ''
-- \echo '   Items 1, 2, 3, 4 and 7 behave the SAME WAY IN ORACLE.'
-- \echo '   Say that out loud - it is the reassurance the room needs.'
-- \echo ''
-- \echo '>>> NEXT: 06_statistics_anatomy.sql   (the statistics half begins)'
-- \echo ''
