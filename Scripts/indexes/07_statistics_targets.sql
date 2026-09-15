-- =====================================================================
-- 07_statistics_targets.sql    Resolution: how much does the planner see?
--
-- default_statistics_target and per-column SET STATISTICS.
-- Oracle: DBMS_STATS METHOD_OPT ... FOR COLUMNS SIZE n
--
-- Headline demo: take one query from a badly wrong estimate to an
-- accurate one WITHOUT creating an index or changing the SQL.
--
-- Changes here are per-column and fully reverted by 99_cleanup.sql.
-- =====================================================================

-- \pset pager off
-- \timing on

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART A - What the target controls                             #'
-- \echo '################################################################'

SHOW default_statistics_target;

-- \echo ''
-- \echo '   The target controls TWO things at once:'
-- \echo '     1. SAMPLE SIZE      ~ 300 x target rows are read'
-- \echo '     2. RESOLUTION       up to  target  MCV entries and'
-- \echo '                                target  histogram buckets'
-- \echo ''
-- \echo '   Default 100 -> ~30,000 rows sampled, 100 buckets.'
-- \echo '   Range 1 .. 10000.'
-- \echo ''
-- \echo '   Oracle analogue: METHOD_OPT ''FOR COLUMNS SIZE 254''.'
-- \echo '   PostgreSQL goes further (10000) and is per-column, same as'
-- \echo '   Oracle per-column histograms.'
-- \echo ''

SELECT a.attname                        AS column_name,
       CASE WHEN a.attstattarget = -1 THEN 'default (' || current_setting('default_statistics_target') || ')'
            ELSE a.attstattarget::text END AS statistics_target
FROM pg_attribute a
WHERE a.attrelid = 'sales.salesorderheader'::regclass
  AND a.attnum > 0 AND NOT a.attisdropped
ORDER BY a.attname;

-- \echo ''
-- \echo '   -1 means "inherit default_statistics_target".'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART B - THE HEADLINE DEMO                                    #'
-- \echo '# Fix a bad estimate with statistics ALONE. No index. No rewrite.#'
-- \echo '################################################################'

-- \echo '  -- B1. Cripple the resolution to 1 bucket:'
ALTER TABLE sales.salesorderheader ALTER COLUMN orderdate SET STATISTICS 1;
ANALYZE sales.salesorderheader;

SELECT attname,
       array_length(most_common_vals,1)  AS mcv_entries,
       array_length(histogram_bounds,1)  AS histogram_buckets
FROM pg_stats
WHERE schemaname='sales' AND tablename='salesorderheader' AND attname='orderdate';

EXPLAIN (ANALYZE)
SELECT count(*) FROM sales.salesorderheader
WHERE orderdate BETWEEN DATE '2013-06-01' AND DATE '2013-06-07';

-- \echo ''
-- \echo '      >>> RECORD:  rows=______   actual rows=______'
-- \echo ''

-- \echo '  -- B2. Default resolution:'
ALTER TABLE sales.salesorderheader ALTER COLUMN orderdate SET STATISTICS 100;
ANALYZE sales.salesorderheader;

EXPLAIN (ANALYZE)
SELECT count(*) FROM sales.salesorderheader
WHERE orderdate BETWEEN DATE '2013-06-01' AND DATE '2013-06-07';

-- \echo ''
-- \echo '  -- B3. High resolution:'
ALTER TABLE sales.salesorderheader ALTER COLUMN orderdate SET STATISTICS 1000;
ANALYZE sales.salesorderheader;

SELECT attname,
       array_length(most_common_vals,1)  AS mcv_entries,
       array_length(histogram_bounds,1)  AS histogram_buckets
FROM pg_stats
WHERE schemaname='sales' AND tablename='salesorderheader' AND attname='orderdate';

EXPLAIN (ANALYZE)
SELECT count(*) FROM sales.salesorderheader
WHERE orderdate BETWEEN DATE '2013-06-01' AND DATE '2013-06-07';

-- \echo ''
-- \echo '  >>> THREE PLANS. Same query. Same data. No index created.'
-- \echo '      No SQL changed. Only the planner''s KNOWLEDGE changed.'
-- \echo ''
-- \echo '      Say: "Before you add an index, check whether the planner'
-- \echo '       simply cannot SEE your data clearly. Statistics are free.'
-- \echo '       Indexes are a permanent tax on every write."'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART C - Where a HIGH target actually pays off: SKEW          #'
-- \echo '################################################################'
-- \echo '  Uniform data does not need many buckets. Skewed data does.'
-- \echo ''

-- \echo '  -- How skewed is customerid?'
WITH freq AS (
  SELECT customerid, count(*) AS c
  FROM sales.salesorderheader GROUP BY customerid
)
SELECT count(*)                        AS distinct_customers,
       min(c)                          AS fewest_orders,
       max(c)                          AS most_orders,
       round(avg(c),2)                 AS avg_orders,
       round(stddev(c),2)              AS stddev,
       round(max(c)::numeric/NULLIF(avg(c),0),1) AS max_vs_avg_ratio
FROM freq;

-- \echo ''
-- \echo '   A high max_vs_avg_ratio = skew = the MCV list matters.'
-- \echo ''

-- \echo '  -- C1. Low target on a skewed column:'
ALTER TABLE sales.salesorderheader ALTER COLUMN customerid SET STATISTICS 10;
ANALYZE sales.salesorderheader;

SELECT array_length(most_common_vals,1) AS mcv_entries
FROM pg_stats WHERE schemaname='sales' AND tablename='salesorderheader'
  AND attname='customerid';

EXPLAIN (ANALYZE) SELECT count(*) FROM sales.salesorderheader WHERE customerid = 29825;

-- \echo ''
-- \echo '  -- C2. High target - the frequent values now get exact entries:'
ALTER TABLE sales.salesorderheader ALTER COLUMN customerid SET STATISTICS 1000;
ANALYZE sales.salesorderheader;

SELECT array_length(most_common_vals,1) AS mcv_entries
FROM pg_stats WHERE schemaname='sales' AND tablename='salesorderheader'
  AND attname='customerid';

EXPLAIN (ANALYZE) SELECT count(*) FROM sales.salesorderheader WHERE customerid = 29825;

-- \echo ''
-- \echo '   With more MCV slots, frequent values are stored EXACTLY rather'
-- \echo '   than averaged into a histogram bucket. On skewed data this is'
-- \echo '   the difference between a Nested Loop and a Hash Join.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART D - The COST of a high target                            #'
-- \echo '################################################################'
-- \echo '  Nothing is free. Raising the target costs ANALYZE time,'
-- \echo '  catalogue space, and a little PLANNING time on every query'
-- \echo '  (the planner scans the MCV list).'
-- \echo ''

-- \echo '  -- Time ANALYZE at three targets. Watch the elapsed time.'
ALTER TABLE sales.salesorderheader ALTER COLUMN orderdate SET STATISTICS 10;
-- \echo '     target 10:'
ANALYZE sales.salesorderheader;

ALTER TABLE sales.salesorderheader ALTER COLUMN orderdate SET STATISTICS 100;
-- \echo '     target 100:'
ANALYZE sales.salesorderheader;

ALTER TABLE sales.salesorderheader ALTER COLUMN orderdate SET STATISTICS 5000;
-- \echo '     target 5000:'
ANALYZE sales.salesorderheader;

-- \echo ''
-- \echo '   On a 31k-row table the difference is invisible. On a'
-- \echo '   500-million-row table, a target of 5000 means sampling 1.5'
-- \echo '   million rows per column - and autoanalyze has to do that too,'
-- \echo '   repeatedly, in production.'
-- \echo ''
-- \echo '   PRACTICAL GUIDANCE:'
-- \echo '     - do NOT raise default_statistics_target globally by reflex'
-- \echo '     - DO raise it per-column on skewed columns that appear in'
-- \echo '       WHERE clauses and join keys'
-- \echo '     - 100 (default) is right for most columns'
-- \echo '     - 250-1000 for skewed, heavily-filtered columns'
-- \echo '     - above 1000 only with evidence'
-- \echo ''

-- \echo '  -- Restore the default and verify:'
ALTER TABLE sales.salesorderheader ALTER COLUMN orderdate  SET STATISTICS -1;
ALTER TABLE sales.salesorderheader ALTER COLUMN customerid SET STATISTICS -1;
ANALYZE sales.salesorderheader;

SELECT a.attname, a.attstattarget AS target_minus1_means_default
FROM pg_attribute a
WHERE a.attrelid='sales.salesorderheader'::regclass
  AND a.attname IN ('orderdate','customerid');

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART E - ANALYZE mechanics                                    #'
-- \echo '################################################################'
-- \echo '  ANALYZE SAMPLES - it does not read the whole table. That is why'
-- \echo '  it is fast, and why estimates are estimates.'
-- \echo ''

ANALYZE VERBOSE sales.salesorderheader;

-- \echo ''
-- \echo '   Read the VERBOSE output: "scanned N of M pages, containing X'
-- \echo '   live rows ... estimated Y total rows".'
-- \echo '   On a big table N will be far smaller than M.'
-- \echo ''
-- \echo '   VARIANTS:'
-- \echo '     ANALYZE;                       every table in the database'
-- \echo '     ANALYZE tbl;                   one table'
-- \echo '     ANALYZE tbl (col1, col2);      specific columns only -'
-- \echo '                                    much cheaper on a wide table'
-- \echo '     ANALYZE VERBOSE tbl;           show the sampling'
-- \echo '     VACUUM ANALYZE tbl;            reclaim space AND resample'
-- \echo ''
-- \echo '   Locking: ANALYZE takes only SHARE UPDATE EXCLUSIVE. Reads and'
-- \echo '   writes continue normally. Safe to run on a live system.'
-- \echo ''
-- \echo '   Progress monitoring (PG13+), from a second session:'
-- \echo '     SELECT * FROM pg_stat_progress_analyze;'
-- \echo ''

SELECT * FROM pg_stat_progress_analyze;

-- \echo ''
-- \echo '>>> NEXT: 08_extended_statistics.sql   - the feature nobody uses'
-- \echo ''
