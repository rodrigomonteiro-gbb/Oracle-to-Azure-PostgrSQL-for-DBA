/* Prepare the isolated table for the SARGability BAD scenario. */

DROP TABLE IF EXISTS public.productdescription_sarg;

CREATE TABLE public.productdescription_sarg AS
SELECT productdescriptionid,
       description,
       rowguid,
       make_date(
           2009 + (productdescriptionid % 5),
           1 + (productdescriptionid % 12),
           1 + (productdescriptionid % 27)
       )::timestamp AS modifieddate
FROM production.productdescription;

ALTER TABLE public.productdescription_sarg
    ADD CONSTRAINT productdescription_sarg_pk
    PRIMARY KEY (productdescriptionid);

CREATE INDEX productdescription_sarg_description_pattern_idx
    ON public.productdescription_sarg (description text_pattern_ops);

CREATE INDEX productdescription_sarg_modifieddate_idx
    ON public.productdescription_sarg (modifieddate);

ANALYZE public.productdescription_sarg;