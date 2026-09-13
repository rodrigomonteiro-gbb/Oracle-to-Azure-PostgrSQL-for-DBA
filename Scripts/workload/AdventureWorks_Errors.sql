-- Intentional PostgreSQL errors for workload 8. Use only in a test database.
-- The setup function catches each error so pgbench continues for the configured
-- duration. Its inner exception block rolls back the three test updates.

\set error_type random(1, 8)
\set delay_seconds random(1, 5)
\set personid random(1, 20777)
\set productid random(316, 999)
\set customerid random(11000, 30118)

BEGIN;

SELECT *
FROM public.demo_error_transaction(
    :error_type,
    :delay_seconds,
    :personid,
    :productid,
    :customerid
);

COMMIT;
