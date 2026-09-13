/* 
	PostgreSQL Setup Script for AdventureWorks CPU Workload
	
	This script creates stored procedures (functions in PostgreSQL) that are used 
	by the AdventureWorks_CPU.sql workload script.
	
	Note: This is a setup script, not a pgbench workload file.
	Run this once before executing the CPU workload.
	
	PostgreSQL Differences:
	- Stored procedures are created as FUNCTIONS
	- Schema creation uses CREATE SCHEMA IF NOT EXISTS
	- Views must exist: humanresources.vemployee and vemployeedepartmenthistory
	- production.vproductanddescription view must exist
	
	This Sample Code is provided for the purpose of illustration only and is not intended
	to be used in a production environment. THIS SAMPLE CODE AND ANY RELATED INFORMATION ARE
	PROVIDED "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER EXPRESSED OR IMPLIED, INCLUDING BUT
	NOT LIMITED TO THE IMPLIED WARRANTIES OF MERCHANTABILITY AND/OR FITNESS FOR A PARTICULAR
	PURPOSE.
*/

-- Create the test schema
CREATE SCHEMA IF NOT EXISTS test;

-- Check if required views exist before creating functions
DO $$
BEGIN
    -- Check for humanresources.vemployee
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.views 
        WHERE table_schema = 'humanresources' AND table_name = 'vemployee'
    ) THEN
        RAISE NOTICE 'WARNING: View humanresources.vemployee does not exist';
    END IF;
    
    -- Check for humanresources.vemployeedepartmenthistory
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.views 
        WHERE table_schema = 'humanresources' AND table_name = 'vemployeedepartmenthistory'
    ) THEN
        RAISE NOTICE 'WARNING: View humanresources.vemployeedepartmenthistory does not exist';
    END IF;
    
    -- Check for production.vproductanddescription
    -- IF NOT EXISTS (
    --     SELECT 1 FROM information_schema.views 
    --     WHERE table_schema = 'production' AND table_name = 'vproductanddescription'
    -- ) THEN
    --     RAISE NOTICE 'WARNING: View production.vproductanddescription does not exist';
    -- END IF;
END $$;

-- Function: EmployeeByLastName
CREATE OR REPLACE FUNCTION test.employeebylastname(lname VARCHAR)
RETURNS TABLE (
    businessentityid INTEGER,
    title VARCHAR,
    firstname VARCHAR,
    lastname VARCHAR,
    jobtitle VARCHAR
) AS $$
BEGIN
    RETURN QUERY
    SELECT e.businessentityid,
           e.title::VARCHAR,
           e.firstname::VARCHAR,
           e.lastname::VARCHAR,
           e.jobtitle::VARCHAR
    FROM   humanresources.vemployee AS e
    WHERE  e.lastname::VARCHAR LIKE '%' || lname || '%';
END;
$$ LANGUAGE plpgsql;

-- Function: EmployeeByFirstName
CREATE OR REPLACE FUNCTION test.employeebyfirstname(fname VARCHAR)
RETURNS TABLE (
    businessentityid INTEGER,
    title VARCHAR,
    firstname VARCHAR,
    lastname VARCHAR,
    jobtitle VARCHAR
) AS $$
BEGIN
    RETURN QUERY
    SELECT e.businessentityid,
           e.title::VARCHAR,
           e.firstname::VARCHAR,
           e.lastname::VARCHAR,
           e.jobtitle::VARCHAR
    FROM   humanresources.vemployee AS e
    WHERE  e.firstname::VARCHAR LIKE '%' || fname || '%';
END;
$$ LANGUAGE plpgsql;

-- Function: EmployeeDepartmentHistoryByLastName
CREATE OR REPLACE FUNCTION test.employeedepartmenthistorybylastname(lname VARCHAR)
RETURNS TABLE (
    businessentityid INTEGER,
    firstname VARCHAR,
    lastname VARCHAR,
    department VARCHAR
) AS $$
BEGIN
    RETURN QUERY
    SELECT e.businessentityid,
           e.firstname::VARCHAR,
           e.lastname::VARCHAR,
           e.department::VARCHAR
    FROM   humanresources.vemployeedepartmenthistory AS e
    WHERE  e.lastname::VARCHAR LIKE '%' || lname || '%';
END;
$$ LANGUAGE plpgsql;

-- Function: EmployeeDepartmentHistoryByFirstName
CREATE OR REPLACE FUNCTION test.employeedepartmenthistorybyfirstname(fname VARCHAR)
RETURNS TABLE (
    businessentityid INTEGER,
    firstname VARCHAR,
    lastname VARCHAR,
    department VARCHAR
) AS $$
BEGIN
    RETURN QUERY
    SELECT e.businessentityid,
           e.firstname::VARCHAR,
           e.lastname::VARCHAR,
           e.department::VARCHAR
    FROM   humanresources.vemployeedepartmenthistory AS e
    WHERE  e.firstname::VARCHAR LIKE '%' || fname || '%';
END;
$$ LANGUAGE plpgsql;

-- Function: ProductAndDescriptionByKeyword
-- COMMENTED OUT: production.vproductanddescription view does not exist
/*
CREATE OR REPLACE FUNCTION test.productanddescriptionbykeyword(keyword VARCHAR)
RETURNS TABLE (
    productid INTEGER,
    name VARCHAR,
    productmodel VARCHAR,
    description TEXT
) AS $$
BEGIN
    RETURN QUERY
    SELECT p.productid,
           p.name::VARCHAR,
           p.productmodel::VARCHAR,
           p.description
    FROM   production.vproductanddescription AS p
    WHERE  p.name::VARCHAR LIKE '%' || keyword || '%'
           OR p.productmodel::VARCHAR LIKE '%' || keyword || '%'
           OR p.description::TEXT LIKE '%' || keyword || '%';
END;
$$ LANGUAGE plpgsql;
*/

-- Grant execute permissions
GRANT EXECUTE ON FUNCTION test.employeebylastname(VARCHAR) TO PUBLIC;
GRANT EXECUTE ON FUNCTION test.employeebyfirstname(VARCHAR) TO PUBLIC;
GRANT EXECUTE ON FUNCTION test.employeedepartmenthistorybylastname(VARCHAR) TO PUBLIC;
GRANT EXECUTE ON FUNCTION test.employeedepartmenthistorybyfirstname(VARCHAR) TO PUBLIC;
-- GRANT EXECUTE ON FUNCTION test.productanddescriptionbykeyword(VARCHAR) TO PUBLIC; -- View does not exist

/*
    -- Validation queries to verify the setup
    -- Check if test schema exists
    SELECT schema_name 
    FROM information_schema.schemata 
    WHERE schema_name = 'test';

    -- Check if required views exist
    SELECT 
        CASE 
            WHEN EXISTS (SELECT 1 FROM information_schema.views WHERE table_schema = 'humanresources' AND table_name = 'vemployee')
            THEN 'EXISTS' ELSE 'MISSING' 
        END AS vemployee_status,
        CASE 
            WHEN EXISTS (SELECT 1 FROM information_schema.views WHERE table_schema = 'humanresources' AND table_name = 'vemployeedepartmenthistory')
            THEN 'EXISTS' ELSE 'MISSING' 
        END AS vemployeedepartmenthistory_status,
        CASE 
            WHEN EXISTS (SELECT 1 FROM information_schema.views WHERE table_schema = 'production' AND table_name = 'vproductanddescription')
            THEN 'EXISTS' ELSE 'MISSING' 
        END AS vproductanddescription_status;

    -- List all views in humanresources schema
    SELECT table_name 
    FROM information_schema.views 
    WHERE table_schema = 'humanresources'
    ORDER BY table_name;

    -- List all views in production schema
    SELECT table_name 
    FROM information_schema.views 
    WHERE table_schema = 'production'
    ORDER BY table_name;

    -- Verify all functions are created in the test schema
    -- Using pg_proc directly for better results
    SELECT 
        n.nspname AS schema_name,
        p.proname AS function_name,
        pg_catalog.pg_get_function_arguments(p.oid) AS arguments,
        CASE p.prokind 
            WHEN 'f' THEN 'function'
            WHEN 'p' THEN 'procedure'
            ELSE p.prokind::text 
        END AS routine_type
    FROM pg_catalog.pg_proc p
    JOIN pg_catalog.pg_namespace n ON p.pronamespace = n.oid
    WHERE n.nspname = 'test'
    ORDER BY p.proname;

    -- Count functions in test schema (should be 4)
    SELECT COUNT(*) AS function_count
    FROM pg_catalog.pg_proc p
    JOIN pg_catalog.pg_namespace n ON p.pronamespace = n.oid
    WHERE n.nspname = 'test';

    -- If functions exist, test them with sample data
    -- Note: These will only return results if the underlying views have data
    SELECT 'Testing employeebylastname' AS test_description;
    SELECT * FROM test.employeebylastname('a') LIMIT 5;

    SELECT 'Testing employeebyfirstname' AS test_description;
    SELECT * FROM test.employeebyfirstname('a') LIMIT 5;

    SELECT 'Testing employeedepartmenthistorybylastname' AS test_description;
    SELECT * FROM test.employeedepartmenthistorybylastname('a') LIMIT 5;

    SELECT 'Testing employeedepartmenthistorybyfirstname' AS test_description;
    SELECT * FROM test.employeedepartmenthistorybyfirstname('a') LIMIT 5;

    -- COMMENTED OUT: production.vproductanddescription view does not exist
    /*
    SELECT 'Testing productanddescriptionbykeyword' AS test_description;
    SELECT * FROM test.productanddescriptionbykeyword('bike') LIMIT 5;
    */

*/