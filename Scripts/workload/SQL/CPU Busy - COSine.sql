/*
	PostgreSQL/pgbench version of CPU Busy - COSine
	
	Performs repeated cosine calculations to generate CPU load.
	Uses pg_sleep to control duration within pgbench iteration.
	
	Usage with pgbench:
	  pgbench -c <num_clients> -j <num_threads> -T <duration_seconds> -f "CPU Busy - COSine_pgbench.sql" -r adventureworks
	
	Example:
	  pgbench -c 5 -j 2 -T 60 -f "CPU Busy - COSine_pgbench.sql" -r adventureworks
	
	Note: Each iteration runs calculations for approximately 5 seconds.
	Adjust the loop count or use pgbench's duration parameter to control total runtime.
	
	This Sample Code is provided for the purpose of illustration only and is not intended
	to be used in a production environment. THIS SAMPLE CODE AND ANY RELATED INFORMATION ARE
	PROVIDED "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER EXPRESSED OR IMPLIED, INCLUDING BUT
	NOT LIMITED TO THE IMPLIED WARRANTIES OF MERCHANTABILITY AND/OR FITNESS FOR A PARTICULAR
	PURPOSE.
*/

-- PostgreSQL version: Perform cosine calculations in a loop
-- Using generate_series to create iterations
DO $$
DECLARE
    result DOUBLE PRECISION;
    i INTEGER;
BEGIN
    -- Perform 1 million cosine calculations
    -- Adjust the loop count to control CPU usage duration
    FOR i IN 1..1000000 LOOP
        result := cos(2.5);
    END LOOP;
END $$;
