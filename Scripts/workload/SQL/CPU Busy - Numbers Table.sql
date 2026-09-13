/*
	PostgreSQL/pgbench version of CPU Busy - Numbers Table
	
	Generates a large numbers table using CTEs to create CPU load.
	This is a CPU-intensive operation that generates a result set of numbers.
	
	Usage with pgbench:
	  pgbench -c <num_clients> -j <num_threads> -T <duration_seconds> -f "CPU Busy - Numbers Table_pgbench.sql" -r adventureworks
	
	Example (use moderate concurrency for CPU-intensive queries):
	  pgbench -c 5 -j 2 -T 60 -f "CPU Busy - Numbers Table_pgbench.sql" -r adventureworks
	
	Note: This query generates 4 million rows which is very CPU intensive.
	Consider reducing the limit for lighter load testing.
	
	Original reference:
	http://sqlblog.com/blogs/linchi_shea/archive/2011/07/22/performance-impact-stored-procedures-sql-batches-and-cpu-usage.aspx
	
	This Sample Code is provided for the purpose of illustration only and is not intended
	to be used in a production environment. THIS SAMPLE CODE AND ANY RELATED INFORMATION ARE
	PROVIDED "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER EXPRESSED OR IMPLIED, INCLUDING BUT
	NOT LIMITED TO THE IMPLIED WARRANTIES OF MERCHANTABILITY AND/OR FITNESS FOR A PARTICULAR
	PURPOSE.
*/

-- Generate a numbers table using CTEs
-- This creates exponential growth through cross joins

--\set maxrows random(1, 10);  -- Randomly choose a limit between 100k and 4 million for testing

WITH 
	E00(N) AS (SELECT 1 UNION ALL SELECT 1),
	E02(N) AS (SELECT 1 FROM E00 a, E00 b),
	E04(N) AS (SELECT 1 FROM E02 a, E02 b),
	E08(N) AS (SELECT 1 FROM E04 a, E04 b),
	E16(N) AS (SELECT 1 FROM E08 a, E08 b),
	E32(N) AS (SELECT 1 FROM E16 a, E16 b),
cteTally(N) AS (SELECT ROW_NUMBER() OVER (ORDER BY N) FROM E32)
SELECT *
FROM cteTally
WHERE N <= (5 * 500000)

-- For lighter testing, use a smaller limit:
-- WHERE N <= 1000000;  -- 1 million rows
-- WHERE N <= 500000;   -- 500k rows
-- WHERE N <= 100000;   -- 100k rows
