/*
	PostgreSQL/pgbench version of CPU Busy - Power
	
	Performs repeated power calculations to generate CPU load.
	
	Usage with pgbench:
	  pgbench -c <num_clients> -j <num_threads> -T <duration_seconds> -f "CPU Busy - Power_pgbench.sql" -r adventureworks
	
	Example:
	  pgbench -c 5 -j 2 -T 60 -f "CPU Busy - Power_pgbench.sql" -r adventureworks
	
	Note: Each iteration runs calculations for approximately 5 seconds.
	Use pgbench's duration (-T) parameter to control total runtime.
	
	Original reference:
	http://blog.sqlauthority.com/2013/02/22/sql-server-t-sql-script-to-keep-cpu-busy/
	
	This Sample Code is provided for the purpose of illustration only and is not intended
	to be used in a production environment. THIS SAMPLE CODE AND ANY RELATED INFORMATION ARE
	PROVIDED "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER EXPRESSED OR IMPLIED, INCLUDING BUT
	NOT LIMITED TO THE IMPLIED WARRANTIES OF MERCHANTABILITY AND/OR FITNESS FOR A PARTICULAR
	PURPOSE.
*/

-- PostgreSQL version: Perform power calculations in a loop
-- Using PL/pgSQL anonymous block
-- \set maxpower random(1, 32)

DO $$
DECLARE
    result BIGINT;
    i INTEGER;
BEGIN
    -- Perform 1 million power calculations
    -- Adjust the loop count to control CPU usage duration
    FOR i IN 1..1000000 LOOP
        result := POWER(2, 32)::BIGINT;
    END LOOP;
END $$;
