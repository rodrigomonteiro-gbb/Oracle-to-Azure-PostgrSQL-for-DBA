/* Prepare an independent, correctly indexed table for the FIXED scenario. */

DROP TABLE IF EXISTS public.productdescription_sarg_fixed;

CREATE TABLE public.productdescription_sarg_fixed AS
SELECT productdescriptionid,
       description,
       rowguid,
       make_date(
           2009 + (productdescriptionid % 5),
           1 + (productdescriptionid % 12),
           1 + (productdescriptionid % 27)
       )::timestamp AS modifieddate
FROM production.productdescription;

ALTER TABLE public.productdescription_sarg_fixed
    ADD CONSTRAINT productdescription_sarg_fixed_pk
    PRIMARY KEY (productdescriptionid);

-- text_pattern_ops supports prefix LIKE with a B-tree index in any locale.
CREATE INDEX productdescription_sarg_fixed_description_pattern_idx
    ON public.productdescription_sarg_fixed (description text_pattern_ops);

CREATE INDEX productdescription_sarg_fixed_modifieddate_idx
    ON public.productdescription_sarg_fixed (modifieddate);

ANALYZE public.productdescription_sarg_fixed;