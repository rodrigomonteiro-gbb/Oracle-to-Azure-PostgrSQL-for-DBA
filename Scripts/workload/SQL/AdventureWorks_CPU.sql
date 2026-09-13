/* 
	PostgreSQL Note: AdventureWorks CPU Workload - Cannot be directly converted to pgbench
	
	REASON FOR SPECIAL HANDLING:
	This script cannot be directly converted to pgbench format because:
	
	1. Uses WHILE loop with procedural logic
	   - pgbench executes simple SQL statements, not procedural code blocks
	
	2. Calls stored procedures multiple times in a loop
	   - test.EmployeeByLastName
	   - test.EmployeeByFirstName
	   - test.EmployeeDepartmentHistoryByFirstName
	   - test.EmployeeDepartmentHistoryByLastName
	   - test.ProductAndDescriptionByKeyword
	
	3. Iterates through alphabet (a-z) for search parameters
	
	POSTGRESQL EQUIVALENT APPROACH:
	
	SETUP REQUIRED:
	Run AdventureWorks_CPU - setup_pgbench.sql first to create the functions.
	
	Option 1: Call functions directly with random letters (RECOMMENDED for pgbench):
	
	----- File: AdventureWorks_CPU_pgbench.sql -----
	-- Generate random letter for search
	\set random_letter random(0, 25)
	
	-- Call the test functions with random single letter
	SELECT * FROM test.employeebylastname(chr(97 + :random_letter));
	SELECT * FROM test.employeebyfirstname(chr(97 + :random_letter));
	SELECT * FROM test.employeedepartmenthistorybyfirstname(chr(97 + :random_letter));
	SELECT * FROM test.employeedepartmenthistorybylastname(chr(97 + :random_letter));
	SELECT * FROM test.productanddescriptionbykeyword(chr(97 + :random_letter));
	----- End of File -----
	
	Option 2: Create a PL/pgSQL function that replicates the WHILE loop:
	
	CREATE OR REPLACE FUNCTION test.cpu_workload(loops INTEGER)
	RETURNS VOID AS $$
	DECLARE
	    i INTEGER;
	    j INTEGER;
	    search CHAR(1);
	BEGIN
	    FOR i IN 1..loops LOOP
	        FOR j IN 0..25 LOOP
	            search := chr(97 + j);  -- 'a' to 'z'
	            PERFORM * FROM test.employeebylastname(search);
	            PERFORM * FROM test.employeebyfirstname(search);
	            PERFORM * FROM test.employeedepartmenthistorybyfirstname(search);
	            PERFORM * FROM test.employeedepartmenthistorybylastname(search);
	            PERFORM * FROM test.productanddescriptionbykeyword(search);
	        END LOOP;
	    END LOOP;
	END;
	$$ LANGUAGE plpgsql;
	
	-- Call it:
	SELECT test.cpu_workload(100);
	
	This Sample Code is provided for the purpose of illustration only and is not intended
	to be used in a production environment. THIS SAMPLE CODE AND ANY RELATED INFORMATION ARE
	PROVIDED "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER EXPRESSED OR IMPLIED, INCLUDING BUT
	NOT LIMITED TO THE IMPLIED WARRANTIES OF MERCHANTABILITY AND/OR FITNESS FOR A PARTICULAR
	PURPOSE.
*/

-- pgbench-compatible version (calls functions with random letters):
\set random_letter random(0, 25)

SELECT * FROM test.employeebylastname(chr(97 + :random_letter));
SELECT * FROM test.employeebyfirstname(chr(97 + :random_letter));
SELECT * FROM test.employeedepartmenthistorybyfirstname(chr(97 + :random_letter));
SELECT * FROM test.employeedepartmenthistorybylastname(chr(97 + :random_letter));
--SELECT * FROM test.productanddescriptionbykeyword(chr(97 + :random_letter));
