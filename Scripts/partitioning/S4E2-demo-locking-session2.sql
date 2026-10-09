-- Session 2 — runs normally, unblocked:**

SELECT pg_backend_pid() AS session_2_pid;  -- must differ from Session 1

SELECT count(*) FROM partlab.salesorderdetail
WHERE orderdate >= DATE '2024-04-01' AND orderdate < DATE '2024-07-01';

SELECT l.pid,
       l.locktype,
       l.relation::regclass AS locked_object,
       l.mode,
       l.granted,
       left(a.query, 60)    AS query
FROM pg_locks l
JOIN pg_stat_activity a USING (pid)
JOIN pg_class c ON c.oid = l.relation
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'partlab'
  AND (c.relname = 'salesorderdetail' OR c.relname LIKE 'sod_part_%')
ORDER BY l.granted, l.pid;
