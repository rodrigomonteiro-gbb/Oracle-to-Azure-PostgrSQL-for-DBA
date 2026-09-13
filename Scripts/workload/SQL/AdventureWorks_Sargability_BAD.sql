/*
    PostgreSQL/pgbench SARGability BAD scenario.

    The intentionally non-SARGable queries disable index access methods in
    their local transactions. The comparison statements retain normal planner
    behavior.
*/

-- Query 1: Non-SARGable - Leading wildcard
BEGIN;
	SET LOCAL enable_indexscan = off;
	SET LOCAL enable_indexonlyscan = off;
	SET LOCAL enable_bitmapscan = off;

	SELECT *
	FROM   public.productdescription_sarg AS pd
	WHERE  pd.description LIKE '%replacement%';

COMMIT;

-- Query 2: SARGable comparison
SELECT *
FROM   public.productdescription_sarg AS pd
WHERE  pd.description LIKE 'replacement%';

-- Query 3: Non-SARGable - Function on column
BEGIN;
	SET LOCAL enable_indexscan = off;
	SET LOCAL enable_indexonlyscan = off;
	SET LOCAL enable_bitmapscan = off;

	SELECT *
	FROM   public.productdescription_sarg AS pd
	WHERE  SUBSTRING(pd.description, 1, 11) = 'replacement';

COMMIT;

-- Query 4: SARGable comparison
SELECT *
FROM   public.productdescription_sarg AS pd
WHERE  pd.description LIKE 'replacement%';

-- Query 5: Non-SARGable - Function on date column
BEGIN;
	SET LOCAL enable_indexscan = off;
	SET LOCAL enable_indexonlyscan = off;
	SET LOCAL enable_bitmapscan = off;

	SELECT pd.description,
		pd.modifieddate
	FROM   public.productdescription_sarg AS pd
	WHERE  EXTRACT(YEAR FROM pd.modifieddate) = 2009;

COMMIT;

-- Query 6: SARGable comparison
SELECT pd.description,
       pd.modifieddate
FROM   public.productdescription_sarg AS pd
WHERE  pd.modifieddate >= DATE '2009-01-01'
	AND pd.modifieddate < DATE '2010-01-01';