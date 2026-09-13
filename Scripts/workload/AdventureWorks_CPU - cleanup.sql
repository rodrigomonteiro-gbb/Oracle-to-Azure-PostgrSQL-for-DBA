/* 
	PostgreSQL Cleanup Script for AdventureWorks CPU Workload
	
	This script removes all objects created by AdventureWorks_CPU - setup_pgbench.sql
	including functions, permissions, and the test schema.
	
	Run this script to clean up the database after testing.
	
	This Sample Code is provided for the purpose of illustration only and is not intended
	to be used in a production environment. THIS SAMPLE CODE AND ANY RELATED INFORMATION ARE
	PROVIDED "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER EXPRESSED OR IMPLIED, INCLUDING BUT
	NOT LIMITED TO THE IMPLIED WARRANTIES OF MERCHANTABILITY AND/OR FITNESS FOR A PARTICULAR
	PURPOSE.
*/

-- Revoke execute permissions (if functions exist)
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid 
               WHERE n.nspname = 'test' AND p.proname = 'employeebylastname') THEN
        REVOKE EXECUTE ON FUNCTION test.employeebylastname(VARCHAR) FROM PUBLIC;
        RAISE NOTICE 'Revoked permissions on test.employeebylastname';
    END IF;
    
    IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid 
               WHERE n.nspname = 'test' AND p.proname = 'employeebyfirstname') THEN
        REVOKE EXECUTE ON FUNCTION test.employeebyfirstname(VARCHAR) FROM PUBLIC;
        RAISE NOTICE 'Revoked permissions on test.employeebyfirstname';
    END IF;
    
    IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid 
               WHERE n.nspname = 'test' AND p.proname = 'employeedepartmenthistorybylastname') THEN
        REVOKE EXECUTE ON FUNCTION test.employeedepartmenthistorybylastname(VARCHAR) FROM PUBLIC;
        RAISE NOTICE 'Revoked permissions on test.employeedepartmenthistorybylastname';
    END IF;
    
    IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid 
               WHERE n.nspname = 'test' AND p.proname = 'employeedepartmenthistorybyfirstname') THEN
        REVOKE EXECUTE ON FUNCTION test.employeedepartmenthistorybyfirstname(VARCHAR) FROM PUBLIC;
        RAISE NOTICE 'Revoked permissions on test.employeedepartmenthistorybyfirstname';
    END IF;
END $$;

-- Drop functions
DROP FUNCTION IF EXISTS test.employeebylastname(VARCHAR);
DROP FUNCTION IF EXISTS test.employeebyfirstname(VARCHAR);
DROP FUNCTION IF EXISTS test.employeedepartmenthistorybylastname(VARCHAR);
DROP FUNCTION IF EXISTS test.employeedepartmenthistorybyfirstname(VARCHAR);
-- DROP FUNCTION IF EXISTS test.productanddescriptionbykeyword(VARCHAR); -- This was never created

-- Drop the test schema (CASCADE will drop any remaining objects)
DROP SCHEMA IF EXISTS test CASCADE;


-- Validation queries to verify cleanup
-- Check if test schema was dropped
SELECT 
    CASE 
        WHEN EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = 'test')
        THEN 'STILL EXISTS - CLEANUP FAILED' 
        ELSE 'DROPPED SUCCESSFULLY' 
    END AS test_schema_status;

-- Check for any remaining functions in test schema
SELECT 
    CASE 
        WHEN EXISTS (
            SELECT 1 
            FROM pg_catalog.pg_proc p
            JOIN pg_catalog.pg_namespace n ON p.pronamespace = n.oid
            WHERE n.nspname = 'test'
        )
        THEN 'FUNCTIONS STILL EXIST - CLEANUP FAILED'
        ELSE 'ALL FUNCTIONS DROPPED SUCCESSFULLY'
    END AS functions_status;

-- List any remaining objects in test schema (should return nothing)
SELECT 
    n.nspname AS schema_name,
    p.proname AS function_name,
    'Function still exists!' AS status
FROM pg_catalog.pg_proc p
JOIN pg_catalog.pg_namespace n ON p.pronamespace = n.oid
WHERE n.nspname = 'test';

-- Verify specific functions are gone
SELECT 
    CASE 
        WHEN EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid 
                     WHERE n.nspname = 'test' AND p.proname = 'employeebylastname')
        THEN 'EXISTS' ELSE 'DROPPED' 
    END AS employeebylastname_status,
    CASE 
        WHEN EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid 
                     WHERE n.nspname = 'test' AND p.proname = 'employeebyfirstname')
        THEN 'EXISTS' ELSE 'DROPPED' 
    END AS employeebyfirstname_status,
    CASE 
        WHEN EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid 
                     WHERE n.nspname = 'test' AND p.proname = 'employeedepartmenthistorybylastname')
        THEN 'EXISTS' ELSE 'DROPPED' 
    END AS employeedepthistorylastname_status,
    CASE 
        WHEN EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid 
                     WHERE n.nspname = 'test' AND p.proname = 'employeedepartmenthistorybyfirstname')
        THEN 'EXISTS' ELSE 'DROPPED' 
    END AS employeedepthistoryfirstname_status;
