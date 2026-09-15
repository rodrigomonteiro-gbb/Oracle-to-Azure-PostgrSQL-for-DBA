-- =====================================================================
-- 06_statistics_anatomy.sql    What the planner actually knows
--
-- Everything in pg_stats, what each field means, and - most importantly -
-- how to RECOMPUTE THE PLANNER'S ESTIMATE BY HAND and show it matches.
-- Once the room sees that, the optimiser stops being a black box.
--
-- Oracle mapping:
--   DBA_TAB_COL_STATISTICS       -> pg_stats
--   NUM_DISTINCT                 -> n_distinct
--   frequency histogram          -> most_common_vals / most_common_freqs
--   height-balanced histogram    -> histogram_bounds
--   CLUSTERING_FACTOR            -> correlation  (inverted sense)
--   DENSITY                      -> 1 / n_distinct
--
-- 100% READ-ONLY except for ANALYZE. Safe on any server.
-- =====================================================================

-- \pset pager off
-- \timing on

ANALYZE sales.salesorderheader;
ANALYZE person.person;
ANALYZE production.product;

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART A - The table-level numbers                              #'
-- \echo '################################################################'

SELECT c.relname                       AS table_name,
       c.reltuples::bigint             AS estimated_rows,
       c.relpages                      AS pages,
       pg_size_pretty(pg_relation_size(c.oid)) AS size,
       CASE WHEN c.relpages > 0
            THEN round(c.reltuples / c.relpages, 1) END AS rows_per_page
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'sales' AND c.relkind = 'r'
ORDER BY c.reltuples DESC LIMIT 10;

-- \echo ''
-- \echo '   reltuples and relpages are the FOUNDATION of every cost'
-- \echo '   estimate. They are refreshed by ANALYZE and by VACUUM.'
-- \echo '   If they are wrong, every plan above them is built on sand.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART B - pg_stats, column by column                           #'
-- \echo '################################################################'

SELECT attname                                  AS column_name,
       null_frac                                AS pct_null,
       n_distinct,
       avg_width                                AS avg_bytes,
       correlation,
       array_length(most_common_vals,1)         AS mcv_entries,
       array_length(histogram_bounds,1)         AS histogram_buckets
FROM pg_stats
WHERE schemaname='sales' AND tablename='salesorderheader'
ORDER BY attname;

-- \echo ''
-- \echo '   FIELD BY FIELD:'
-- \echo ''
-- \echo '   null_frac    fraction of NULLs. Drives IS NULL estimates.'
-- \echo ''
-- \echo '   n_distinct   POSITIVE = an absolute count of distinct values'
-- \echo '                NEGATIVE = a RATIO of the table size'
-- \echo '                  -1    every value unique (a key)'
-- \echo '                  -0.5  each value appears about twice'
-- \echo '                PostgreSQL uses the negative form when distinct'
-- \echo '                count appears to scale WITH the table, so the'
-- \echo '                estimate stays correct as the table grows.'
-- \echo '                Oracle stores an absolute NUM_DISTINCT and has to'
-- \echo '                re-gather. This is a small, real PostgreSQL win.'
-- \echo ''
-- \echo '   avg_width    average bytes - drives the width= in EXPLAIN and'
-- \echo '                therefore memory and sort-spill estimates.'
-- \echo ''
-- \echo '   correlation  -1..1, how well physical order matches logical'
-- \echo '                order. NEAR 1 MAKES INDEX SCANS MUCH CHEAPER'
-- \echo '                because the heap fetches become near-sequential.'
-- \echo '                This is the inverse of Oracle CLUSTERING_FACTOR,'
-- \echo '                and it is the single most under-appreciated'
-- \echo '                number in the whole catalogue.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART C - The MCV list (Oracle: frequency histogram)           #'
-- \echo '################################################################'
-- \echo '  The planner stores the most common values AND their frequencies'
-- \echo '  exactly. For those values the estimate is essentially perfect.'
-- \echo ''

SELECT unnest(most_common_vals::text::text[])       AS common_value,
       round((unnest(most_common_freqs) * 100)::numeric, 3) AS pct_of_table
FROM pg_stats
WHERE schemaname='person' AND tablename='person' AND attname='persontype'
LIMIT 10;

-- \echo ''
-- \echo '  -- PROVE IT. Predicted vs actual for an MCV:'
WITH s AS (
  SELECT most_common_vals::text::text[] AS vals,
         most_common_freqs              AS freqs
  FROM pg_stats
  WHERE schemaname='person' AND tablename='person' AND attname='persontype'
),
t AS (SELECT reltuples AS total FROM pg_class WHERE oid='person.person'::regclass)
SELECT s.vals[1]                                        AS value_tested,
       round((s.freqs[1] * t.total)::numeric, 0)        AS planner_predicts,
       (SELECT count(*) FROM person.person p
         WHERE p.persontype = s.vals[1])                AS actual_rows
FROM s, t;

-- \echo ''
-- \echo '  >>> Those two numbers should be very close. Then run the plan'
-- \echo '      and watch EXPLAIN print the same prediction:'

EXPLAIN (ANALYZE)
SELECT count(*) FROM person.person WHERE persontype = 'IN';

-- \echo ''
-- \echo '   THIS IS THE MOMENT THE OPTIMISER STOPS BEING MAGIC.'
-- \echo '   Say: "The planner is not guessing. It is doing arithmetic on'
-- \echo '    numbers we can read, and we just did the same arithmetic by'
-- \echo '    hand. When the plan is wrong, one of these numbers is wrong -'
-- \echo '    and now you know exactly where to look."'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART D - The histogram (Oracle: height-balanced)              #'
-- \echo '################################################################'
-- \echo '  Values NOT in the MCV list are estimated from equal-frequency'
-- \echo '  histogram buckets. Each bucket holds roughly the same NUMBER OF'
-- \echo '  ROWS, so bucket WIDTH varies with density.'
-- \echo ''

SELECT attname,
       array_length(histogram_bounds,1) AS buckets,
       (histogram_bounds::text::text[])[1]                                  AS min_bound,
       (histogram_bounds::text::text[])[array_length(histogram_bounds,1)/2] AS median_bound,
       (histogram_bounds::text::text[])[array_length(histogram_bounds,1)]   AS max_bound
FROM pg_stats
WHERE schemaname='sales' AND tablename='salesorderheader'
  AND attname IN ('orderdate','totaldue','customerid')
  AND histogram_bounds IS NOT NULL;

-- \echo ''
-- \echo '  -- Derive a range estimate from the histogram, then check it:'
EXPLAIN (ANALYZE)
SELECT count(*) FROM sales.salesorderheader
WHERE orderdate BETWEEN DATE '2013-06-01' AND DATE '2013-06-30';

-- \echo ''
-- \echo '   The planner interpolates across the buckets the range spans.'
-- \echo '   More buckets = finer resolution = better estimates on skewed'
-- \echo '   data. That is exactly the knob script 07 turns.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART E - CORRELATION, and why it changes plans                #'
-- \echo '################################################################'

SELECT attname, correlation,
       CASE WHEN correlation IS NULL           THEN 'n/a'
            WHEN abs(correlation) > 0.9        THEN 'EXCELLENT - index scans cheap, BRIN viable'
            WHEN abs(correlation) > 0.5        THEN 'moderate'
            ELSE 'POOR - heap fetches will be random IO'
       END AS meaning
FROM pg_stats
WHERE schemaname='sales' AND tablename='salesorderheader'
  AND attname IN ('salesorderid','orderdate','customerid','totaldue','status')
ORDER BY abs(correlation) DESC NULLS LAST;

-- \echo ''
-- \echo '   Two columns, same selectivity, different correlation -> the'
-- \echo '   planner may use the index for one and not the other, because'
-- \echo '   the HEAP ACCESS PATTERN differs. High correlation means the'
-- \echo '   matching rows are physically adjacent.'
-- \echo ''
-- \echo '   Levers:'
-- \echo '     CLUSTER tbl USING idx;   physically reorder (one-off,'
-- \echo '                              ACCESS EXCLUSIVE lock, not'
-- \echo '                              maintained afterwards)'
-- \echo '     BRIN                     only viable at high correlation'
-- \echo ''
-- \echo '   Oracle DBAs: this is CLUSTERING_FACTOR wearing a different hat.'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART F - Where statistics run out                             #'
-- \echo '################################################################'
-- \echo '  When PostgreSQL has nothing useful it falls back to hardcoded'
-- \echo '  constants. Knowing the defaults tells you instantly that you'
-- \echo '  are looking at a GUESS, not an estimate.'
-- \echo ''
-- \echo '    equality on an unknown column   0.5%   of rows'
-- \echo '    inequality (< >)                33%'
-- \echo '    range BETWEEN                   ~0.5%  fallback'
-- \echo '    pattern match LIKE              varies, often very wrong'
-- \echo ''

-- \echo '  -- A function the planner cannot see inside:'
EXPLAIN
SELECT * FROM sales.salesorderheader
WHERE md5(salesorderid::text) LIKE 'a%';

-- \echo ''
-- \echo '   That estimate is a GUESS. Recognising the tell-tale round'
-- \echo '   numbers is a skill worth teaching explicitly.'
-- \echo ''

-- \echo '  -- Same class of problem: a function with no statistics'
EXPLAIN
SELECT * FROM sales.salesorderheader
WHERE totaldue > (random() * 1000);

-- \echo ''
-- \echo '   FIXES:'
-- \echo '     - an expression index (creates statistics on the expression)'
-- \echo '     - CREATE STATISTICS on an expression (PG14+, no index needed)'
-- \echo '     - rewrite so the planner can see a plain column'
-- \echo ''

-- \echo ''
-- \echo '################################################################'
-- \echo '# PART G - How much does the planner store?                     #'
-- \echo '################################################################'

SELECT count(*)                                   AS columns_with_stats,
       count(*) FILTER (WHERE most_common_vals IS NOT NULL) AS with_mcv,
       count(*) FILTER (WHERE histogram_bounds IS NOT NULL) AS with_histogram
FROM pg_stats
WHERE schemaname IN ('sales','person','production');

SELECT pg_size_pretty(pg_total_relation_size('pg_statistic')) AS pg_statistic_size;

-- \echo ''
-- \echo '   Tiny. Statistics are almost free to store and enormously'
-- \echo '   valuable - which is why raising the statistics target on your'
-- \echo '   important columns is nearly always the right trade.'
-- \echo ''
-- \echo '>>> NEXT: 07_statistics_targets.sql'
-- \echo ''
