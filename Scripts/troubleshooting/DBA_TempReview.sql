/*
	PostgreSQL temporary file and spill troubleshooting queries.

	Temporary file statistics are cumulative since the last statistics reset.

	Reset before a controlled test when appropriate:
		SELECT pg_stat_reset();
*/

-- 1. Temporary file statistics for the current database.
SELECT datname,
       temp_files,
       pg_size_pretty(temp_bytes) AS temp_bytes_pretty
FROM pg_stat_database
WHERE datname = current_database();

/* output :
 datname  | temp_files | temp_bytes_pretty
----------+------------+-----------------
 mydb     | 10         | 1 MB

temp_files:	Number of temp files created since last stats reset.
        	Any value > 0 means queries spilled sorts or hashes to disk because they exceeded work_mem
temp_bytes:	Total bytes written to temp files	
            Large values (hundreds of MB+) indicate heavy sort/hash operations. Queries 3, 4, and 6 are the likely culprits
*/
