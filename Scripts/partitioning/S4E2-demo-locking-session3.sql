SELECT pg_backend_pid() AS session_3_pid;  -- must differ from Sessions 1 and 2

SET lock_timeout = '30s';  -- prevents an accidental indefinite wait
SELECT count(*) FROM partlab.sod_part_2024_q1;
-- Waits, then reports SQLSTATE 55P03 if Session 1 still holds the lock.
