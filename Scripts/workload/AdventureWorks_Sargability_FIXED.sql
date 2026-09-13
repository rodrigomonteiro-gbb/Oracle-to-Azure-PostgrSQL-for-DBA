/*
    PostgreSQL/pgbench SARGability FIXED scenario.

    These predicates match the indexes created by
    AdventureWorks_Sargability_FIXED_Setup.sql. Planner choices remain enabled
    so PostgreSQL can choose an index when its estimated cost is lower.
*/

-- Fixed text search: anchored prefix can use text_pattern_ops.
SELECT *
FROM public.productdescription_sarg_fixed AS pd
WHERE pd.description LIKE 'replacement%';

-- Fixed function predicate: compare the indexed column directly.
SELECT *
FROM public.productdescription_sarg_fixed AS pd
WHERE pd.description LIKE 'replacement%';

-- Fixed date predicate: half-open range can use the modifieddate index.
SELECT pd.description,
       pd.modifieddate
FROM public.productdescription_sarg_fixed AS pd
WHERE pd.modifieddate >= DATE '2009-01-01'
  AND pd.modifieddate < DATE '2010-01-01';