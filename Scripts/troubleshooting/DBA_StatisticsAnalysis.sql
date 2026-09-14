/*
    DBA planner statistics analysis

    Purpose
    -------
    Review the statistics PostgreSQL uses for row-count estimates and plan
    selection. This includes table freshness, column distributions, statistics
    targets, index-key coverage, extended statistics, partitioned tables, and
    active ANALYZE operations.

    Safety and scope
    ----------------
    - This script is read-only. Generated ANALYZE and ALTER commands are text.
    - Run it in each database to be analyzed; planner statistics are per database.
    - No extension is required for Sections 1 through 11.
    - Section 12 requires pg_stat_statements and should be run separately only
      when Section 1 reports that the extension is installed.
    - pg_monitor or pg_read_all_stats provides the most complete visibility.

    Monitoring roles
    ----------------
    pg_read_all_stats and pg_monitor are predefined PostgreSQL roles, not
    extensions. They do not need to be created.

    - pg_read_all_stats allows a member to read all pg_stat_* views and use
      statistics-related functions and extensions that may otherwise hide data.
    - pg_monitor is broader. It includes pg_read_all_stats,
      pg_read_all_settings, and pg_stat_scan_tables. Granting pg_monitor already
      provides the pg_read_all_stats privileges, so do not grant both.

    Use the narrower role when complete statistics visibility is sufficient:

      SELECT current_user;
      GRANT pg_read_all_stats TO your_username;

    Use the broader role only when the user also needs general server-monitoring
    settings and functions:

      GRANT pg_monitor TO your_username;

    Replace your_username with the value returned by SELECT current_user. Run
    GRANT as the server administrator, a superuser, or a role holding ADMIN
    OPTION for the predefined role. Do not put the username in single quotes.
    Double-quote any name that is not a valid unquoted identifier, including
    names with uppercase letters, special characters, a leading digit, or a
    reserved keyword:

      GRANT pg_read_all_stats TO "MonitoringUser";

    Verify effective inherited privileges. USAGE accounts for role inheritance;
    MEMBER checks membership only and can differ for a NOINHERIT login role:

      SELECT current_user,
         pg_has_role(current_user, 'pg_read_all_stats', 'USAGE')
                 AS can_read_all_stats,
         pg_has_role(current_user, 'pg_monitor', 'USAGE') AS is_pg_monitor;

    Reconnect if the client does not immediately reflect the new membership.
    Remove access when it is no longer required:

      REVOKE pg_read_all_stats FROM your_username;
      REVOKE pg_monitor FROM your_username;

    On Azure Database for PostgreSQL Flexible Server, the configured server
    administrator is a member of the restricted azure_pg_admin pseudo-superuser
    role, not a true PostgreSQL superuser. Execute the grant as that server
    administrator; whether it can grant a particular predefined role depends on
    Azure's managed-role restrictions. Neither monitoring role grants true
    superuser access or unrestricted access to server files.
*/

-- 1. Environment, planner statistics settings, and extension availability.
SELECT current_database() AS database_name,
       current_user AS monitoring_role,
       current_setting('server_version') AS server_version,
       database_stats.stats_reset,
       pg_has_role(current_user, 'pg_monitor', 'MEMBER') AS is_pg_monitor,
       pg_has_role(current_user, 'pg_read_all_stats', 'MEMBER')
           AS can_read_all_stats,
       current_setting('track_counts') AS track_counts,
       current_setting('default_statistics_target')::integer
           AS default_statistics_target,
       current_setting('autovacuum') AS autovacuum,
       current_setting('autovacuum_analyze_threshold')::integer
           AS autovacuum_analyze_threshold,
       current_setting('autovacuum_analyze_scale_factor')::numeric
           AS autovacuum_analyze_scale_factor,
       EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements')
           AS pg_stat_statements_installed,
       clock_timestamp() AS observed_at
FROM pg_stat_database AS database_stats
WHERE database_stats.datname = current_database();

-- 2. Table statistics freshness and effective autoanalyze thresholds. Per-table
-- reloptions override server settings when present.
WITH settings AS (
    SELECT current_setting('autovacuum_analyze_threshold')::numeric
               AS default_threshold,
           current_setting('autovacuum_analyze_scale_factor')::numeric
               AS default_scale_factor
), table_context AS (
    SELECT stats.relid,
           stats.schemaname,
           stats.relname,
           stats.n_live_tup,
           stats.n_dead_tup,
           stats.n_mod_since_analyze,
           stats.last_analyze,
           stats.last_autoanalyze,
           stats.analyze_count,
           stats.autoanalyze_count,
           table_class.reltuples::bigint AS planner_row_estimate,
           COALESCE(
               (SELECT option_value::numeric
                FROM pg_options_to_table(table_class.reloptions)
                WHERE option_name = 'autovacuum_analyze_threshold'),
               settings.default_threshold
           ) AS analyze_threshold,
           COALESCE(
               (SELECT option_value::numeric
                FROM pg_options_to_table(table_class.reloptions)
                WHERE option_name = 'autovacuum_analyze_scale_factor'),
               settings.default_scale_factor
           ) AS analyze_scale_factor
    FROM pg_stat_user_tables AS stats
    JOIN pg_class AS table_class
      ON table_class.oid = stats.relid
    CROSS JOIN settings
)
SELECT schemaname,
       relname AS table_name,
       n_live_tup,
       planner_row_estimate,
       n_dead_tup,
       n_mod_since_analyze,
       ceil(analyze_threshold + analyze_scale_factor * n_live_tup)::bigint
           AS estimated_autoanalyze_trigger,
         n_mod_since_analyze >= ceil(
           analyze_threshold + analyze_scale_factor * n_live_tup
         ) AS estimated_analyze_threshold_exceeded,
       round(
           100.0 * n_mod_since_analyze /
           NULLIF(ceil(analyze_threshold + analyze_scale_factor * n_live_tup), 0),
           2
       ) AS trigger_progress_pct,
       last_analyze,
       last_autoanalyze,
       analyze_count,
       autoanalyze_count
FROM table_context
ORDER BY estimated_analyze_threshold_exceeded DESC,
         trigger_progress_pct DESC NULLS LAST,
         n_mod_since_analyze DESC;

-- 3. Tables with missing or potentially stale statistics. A threshold crossing
-- is a scheduling signal, not proof that current plans are wrong.
WITH settings AS (
  SELECT current_setting('autovacuum_analyze_threshold')::numeric
         AS default_threshold,
       current_setting('autovacuum_analyze_scale_factor')::numeric
         AS default_scale_factor
), table_context AS (
  SELECT stats.*,
       COALESCE(
         (SELECT option_value::numeric
        FROM pg_options_to_table(table_class.reloptions)
        WHERE option_name = 'autovacuum_analyze_threshold'),
         settings.default_threshold
       ) AS analyze_threshold,
       COALESCE(
         (SELECT option_value::numeric
        FROM pg_options_to_table(table_class.reloptions)
        WHERE option_name = 'autovacuum_analyze_scale_factor'),
         settings.default_scale_factor
       ) AS analyze_scale_factor
  FROM pg_stat_user_tables AS stats
  JOIN pg_class AS table_class
    ON table_class.oid = stats.relid
  CROSS JOIN settings
)
SELECT stats.schemaname,
       stats.relname AS table_name,
       stats.n_live_tup,
       stats.n_mod_since_analyze,
       stats.last_analyze,
       stats.last_autoanalyze,
       CASE
           WHEN stats.last_analyze IS NULL AND stats.last_autoanalyze IS NULL
               THEN 'Never analyzed since statistics reset/startup'
           WHEN stats.n_mod_since_analyze >= ceil(
                stats.analyze_threshold
                + stats.analyze_scale_factor * stats.n_live_tup
                )
               THEN 'Estimated autoanalyze threshold reached'
           ELSE 'Large modification count; review workload and table overrides'
       END AS review_reason,
       format('ANALYZE VERBOSE %I.%I;', stats.schemaname, stats.relname)
           AS proposed_analyze_command
FROM table_context AS stats
WHERE (stats.last_analyze IS NULL AND stats.last_autoanalyze IS NULL)
   OR stats.n_mod_since_analyze >= ceil(
      stats.analyze_threshold
      + stats.analyze_scale_factor * stats.n_live_tup
      )
   OR stats.n_mod_since_analyze >= 100000
ORDER BY stats.n_mod_since_analyze DESC,
         stats.schemaname,
         stats.relname;

-- 3A. Run the proposed ANALYZE VERBOSE command from Section 3 separately.
-- A successful ANALYZE has already refreshed the table's ordinary column
-- statistics. Dead rows reported by VERBOSE require VACUUM, not another
-- ANALYZE, if they need to be reclaimed.

ANALYZE VERBOSE humanresources.employee;
ANALYZE VERBOSE humanresources.employeedepartmenthistory;
ANALYZE VERBOSE humanresources.employeepayhistory;


ANALYZE VERBOSE humanresources.jobcandidate;
VACUUM (VERBOSE, ANALYZE) humanresources.jobcandidate;
ANALYZE VERBOSE humanresources.jobcandidate;

ANALYZE VERBOSE humanresources.shift;
ANALYZE VERBOSE person.address;


/*
    3B. Update or create planner statistics (run selected commands separately)
    --------------------------------------------------------------------------

    Refresh ordinary statistics for every eligible column in one table:

      ANALYZE VERBOSE humanresources.department;

    Refresh ordinary statistics for selected columns only:

      ANALYZE VERBOSE humanresources.department (departmentid, name);

    Vacuum dead tuples and refresh ordinary statistics in one operation:

      VACUUM (VERBOSE, ANALYZE) humanresources.department;

    Refresh ordinary statistics for every table in the current database:

      ANALYZE VERBOSE;

    Increase the detail collected for a skewed column, then recollect it.
    SET STATISTICS changes the target; ANALYZE creates the new statistics data:

      ALTER TABLE humanresources.department
          ALTER COLUMN name SET STATISTICS 500;

      ANALYZE VERBOSE humanresources.department (name);

    Restore that column to default_statistics_target, then recollect it:

      ALTER TABLE humanresources.department
          ALTER COLUMN name SET STATISTICS -1;

      ANALYZE VERBOSE humanresources.department (name);

    Create an extended-statistics object when a demonstrated estimate error
    involves related columns. CREATE STATISTICS defines the object; ANALYZE
    populates it. Use a schema-qualified, unique statistics-object name:

      CREATE STATISTICS humanresources.st_department_group_name
          (dependencies, ndistinct, mcv)
          ON groupname, name
          FROM humanresources.department;

      ANALYZE VERBOSE humanresources.department;

    Remove the example extended-statistics object when it is no longer needed:

      DROP STATISTICS IF EXISTS humanresources.st_department_group_name;

    PostgreSQL automatically maintains ordinary per-column statistics; there
    is no SQL Server-style CREATE STATISTICS command for a single ordinary
    column. CREATE STATISTICS is for extended column/expression relationships.
*/

-- 4. Column statistics targets. -1 means use default_statistics_target; 0
-- disables collection for that column; positive values are explicit targets.
SELECT namespace.nspname AS schemaname,
       table_class.relname AS table_name,
       attribute.attname AS column_name,
       format_type(attribute.atttypid, attribute.atttypmod) AS data_type,
       attribute.attstattarget AS configured_statistics_target,
       CASE
           WHEN attribute.attstattarget = -1
               THEN current_setting('default_statistics_target')::integer
           ELSE attribute.attstattarget
       END AS effective_statistics_target,
       attribute.attnotnull AS is_not_null,
       attribute.attgenerated <> '' AS is_generated,
       column_stats.attname IS NOT NULL AS has_pg_stats_row
FROM pg_attribute AS attribute
JOIN pg_class AS table_class
  ON table_class.oid = attribute.attrelid
JOIN pg_namespace AS namespace
  ON namespace.oid = table_class.relnamespace
LEFT JOIN pg_stats AS column_stats
  ON column_stats.schemaname = namespace.nspname
 AND column_stats.tablename = table_class.relname
 AND column_stats.attname = attribute.attname
 AND NOT column_stats.inherited
WHERE table_class.relkind IN ('r', 'm', 'p')
  AND attribute.attnum > 0
  AND NOT attribute.attisdropped
  AND namespace.nspname NOT IN ('pg_catalog', 'information_schema')
ORDER BY namespace.nspname,
         table_class.relname,
         attribute.attnum;

-- 5. Planner column distributions from pg_stats. Array values are summarized to
-- keep the report readable; inspect a selected pg_stats row for full values.
SELECT stats.schemaname,
       stats.tablename AS table_name,
       stats.attname AS column_name,
       stats.inherited,
       stats.null_frac,
       stats.avg_width,
       stats.n_distinct,
       CASE
           WHEN stats.n_distinct < 0
               THEN round(abs(stats.n_distinct) * table_class.reltuples)::bigint
           ELSE stats.n_distinct::bigint
       END AS estimated_distinct_values,
       stats.correlation,
       cardinality(stats.most_common_freqs) AS most_common_value_count,
       cardinality(stats.histogram_bounds) AS histogram_boundary_count
FROM pg_stats AS stats
JOIN pg_namespace AS namespace
  ON namespace.nspname = stats.schemaname
JOIN pg_class AS table_class
  ON table_class.relnamespace = namespace.oid
 AND table_class.relname = stats.tablename
WHERE stats.schemaname NOT IN ('pg_catalog', 'information_schema')
ORDER BY stats.schemaname,
         stats.tablename,
         stats.attname,
         stats.inherited;

-- 6. Statistics coverage for ordinary index key columns. Expression keys have
-- attnum = 0 and require expression-level plan review rather than a column row.
SELECT namespace.nspname AS schemaname,
       table_class.relname AS table_name,
       index_class.relname AS index_name,
       key_column.position AS key_position,
       CASE
           WHEN key_column.attnum = 0 THEN '<expression>'
           ELSE attribute.attname
       END AS key_column,
       attribute.attstattarget AS configured_statistics_target,
       column_stats.attname IS NOT NULL AS has_pg_stats_row,
       column_stats.null_frac,
       column_stats.n_distinct,
       column_stats.correlation,
       pg_get_indexdef(index_class.oid) AS index_definition
FROM pg_index AS index_definition
JOIN pg_class AS index_class
  ON index_class.oid = index_definition.indexrelid
JOIN pg_class AS table_class
  ON table_class.oid = index_definition.indrelid
JOIN pg_namespace AS namespace
  ON namespace.oid = table_class.relnamespace
CROSS JOIN LATERAL
     unnest(index_definition.indkey::smallint[]) WITH ORDINALITY
     AS key_column(attnum, position)
LEFT JOIN pg_attribute AS attribute
  ON attribute.attrelid = table_class.oid
 AND attribute.attnum = key_column.attnum
LEFT JOIN pg_stats AS column_stats
  ON column_stats.schemaname = namespace.nspname
 AND column_stats.tablename = table_class.relname
 AND column_stats.attname = attribute.attname
 AND NOT column_stats.inherited
WHERE key_column.position <= index_definition.indnkeyatts
  AND namespace.nspname NOT IN ('pg_catalog', 'information_schema')
ORDER BY namespace.nspname,
         table_class.relname,
         index_class.relname,
         key_column.position;

-- 7. Extended statistics definitions. Kinds: d = multivariate distinct counts,
-- f = functional dependencies, m = multivariate most-common-value lists.
SELECT namespace.nspname AS schemaname,
       table_class.relname AS table_name,
       stats_object.stxname AS statistics_name,
       stats_namespace.nspname AS statistics_schema,
       stats_object.stxkind AS statistics_kinds,
       stats_object.stxstattarget AS statistics_target,
       pg_get_statisticsobjdef(stats_object.oid) AS statistics_definition
FROM pg_statistic_ext AS stats_object
JOIN pg_class AS table_class
  ON table_class.oid = stats_object.stxrelid
JOIN pg_namespace AS namespace
  ON namespace.oid = table_class.relnamespace
JOIN pg_namespace AS stats_namespace
  ON stats_namespace.oid = stats_object.stxnamespace
WHERE namespace.nspname NOT IN ('pg_catalog', 'information_schema')
ORDER BY namespace.nspname,
         table_class.relname,
         stats_object.stxname;

-- 8. Collected extended statistics. Definitions can exist before ANALYZE has
-- populated data, in which case the data columns can be NULL.
SELECT stats.schemaname,
       stats.tablename AS table_name,
       stats.statistics_schemaname,
       stats.statistics_name,
       stats.attnames AS columns,
       stats.exprs AS expressions,
       stats.kinds,
       stats.inherited,
       stats.n_distinct AS multivariate_distinct_counts,
       stats.dependencies AS functional_dependencies,
       cardinality(stats.most_common_freqs) AS multivariate_mcv_count
FROM pg_stats_ext AS stats
WHERE stats.schemaname NOT IN ('pg_catalog', 'information_schema')
ORDER BY stats.schemaname,
         stats.tablename,
         stats.statistics_name,
         stats.inherited;

-- 9. Partitioned-table statistics coverage. Autovacuum does not analyze a
-- partitioned parent. Analyze the parent manually for inherited statistics and
-- analyze individual partitions according to their own modification activity.
SELECT parent_namespace.nspname AS parent_schema,
       parent_class.relname AS parent_table,
       count(*) FILTER (WHERE partition_tree.isleaf) AS leaf_partition_count,
       parent_class.reltuples::bigint AS parent_planner_row_estimate,
       parent_stats.last_analyze,
       parent_stats.last_autoanalyze,
       count(parent_column_stats.attname) FILTER (
           WHERE parent_column_stats.inherited
       ) AS inherited_column_statistics_rows,
       format('ANALYZE VERBOSE %I.%I;',
              parent_namespace.nspname,
              parent_class.relname) AS proposed_parent_analyze_command
FROM pg_class AS parent_class
JOIN pg_namespace AS parent_namespace
  ON parent_namespace.oid = parent_class.relnamespace
CROSS JOIN LATERAL pg_partition_tree(parent_class.oid) AS partition_tree
LEFT JOIN pg_stat_user_tables AS parent_stats
  ON parent_stats.relid = parent_class.oid
LEFT JOIN pg_stats AS parent_column_stats
  ON parent_column_stats.schemaname = parent_namespace.nspname
 AND parent_column_stats.tablename = parent_class.relname
WHERE parent_class.relkind = 'p'
  AND parent_namespace.nspname NOT IN ('pg_catalog', 'information_schema')
GROUP BY parent_class.oid,
         parent_namespace.nspname,
         parent_class.relname,
         parent_class.reltuples,
         parent_stats.last_analyze,
         parent_stats.last_autoanalyze
ORDER BY leaf_partition_count DESC,
         parent_namespace.nspname,
         parent_class.relname;

-- 10. Active ANALYZE operations. Available in PostgreSQL 13 and later.
SELECT progress.pid,
       progress.datname AS database_name,
       progress.relid::regclass AS table_name,
       progress.phase,
       progress.sample_blks_total,
       progress.sample_blks_scanned,
       round(
           100.0 * progress.sample_blks_scanned /
           NULLIF(progress.sample_blks_total, 0),
           2
       ) AS sample_blocks_done_pct,
       progress.ext_stats_total,
       progress.ext_stats_computed,
       progress.child_tables_total,
       progress.child_tables_done,
       progress.current_child_table_relid::regclass AS current_child_table,
       activity.wait_event_type,
       activity.wait_event,
       clock_timestamp() - activity.query_start AS elapsed
FROM pg_stat_progress_analyze AS progress
LEFT JOIN pg_stat_activity AS activity
  ON activity.pid = progress.pid
ORDER BY activity.query_start NULLS LAST;

-- 11. Tables where scan volume and modification volume justify checking plans
-- and statistics quality. Sequential scans are not inherently problematic.
SELECT stats.schemaname,
       stats.relname AS table_name,
       stats.seq_scan,
       stats.seq_tup_read,
       stats.idx_scan,
       stats.idx_tup_fetch,
       stats.n_live_tup,
       stats.n_mod_since_analyze,
       stats.last_analyze,
       stats.last_autoanalyze,
       pg_size_pretty(pg_total_relation_size(stats.relid)) AS total_size
FROM pg_stat_user_tables AS stats
WHERE stats.seq_tup_read > 0
   OR stats.n_mod_since_analyze > 0
ORDER BY stats.seq_tup_read DESC,
         stats.n_mod_since_analyze DESC,
         pg_total_relation_size(stats.relid) DESC;

-- 11A. Inspect freshness and column distributions for one table returned by
-- Section 11. Change the two target values, then run this section separately.
WITH target AS (
  SELECT 'humanresources'::name AS schemaname,
         'department'::name AS table_name
)
SELECT target.schemaname,
       target.table_name,
       column_stats.attname AS column_name,
       column_stats.null_frac,
       column_stats.n_distinct,
       column_stats.correlation,
       cardinality(column_stats.most_common_vals) AS most_common_value_count,
       cardinality(column_stats.histogram_bounds) AS histogram_boundary_count,
       table_stats.n_live_tup,
       table_stats.n_mod_since_analyze,
       table_stats.last_analyze,
       table_stats.last_autoanalyze
FROM target
JOIN pg_stat_user_tables AS table_stats
  ON table_stats.schemaname = target.schemaname
 AND table_stats.relname = target.table_name
LEFT JOIN pg_stats AS column_stats
  ON column_stats.schemaname = target.schemaname
 AND column_stats.tablename = target.table_name
 AND NOT column_stats.inherited
ORDER BY column_stats.attname;

/*
    11B. Find candidate statements that reference the selected table
    -----------------------------------------------------------------
    Requires pg_stat_statements. Text matching is only a candidate search: it
    can miss dynamically generated or unqualified references and can include
    unrelated text. Replace both search strings before running separately.

      SELECT statements.calls,
             round(statements.total_exec_time::numeric, 2) AS total_exec_ms,
             round(statements.mean_exec_time::numeric, 2) AS mean_exec_ms,
             statements.rows,
             left(statements.query, 2000) AS query_text
      FROM pg_stat_statements AS statements
      WHERE statements.dbid = (SELECT oid
                                FROM pg_database
                                WHERE datname = current_database())
        AND statements.query ILIKE '%department%'
        AND (statements.query ILIKE '%humanresources%'
             OR statements.query ILIKE '%department%')
      ORDER BY statements.total_exec_time DESC
      LIMIT 50;

    11C. Capture the actual plan for a representative statement
    -------------------------------------------------------------
    Substitute a representative SELECT and realistic parameter values.
    EXPLAIN ANALYZE executes the statement; use BEGIN/ROLLBACK around DML.

      EXPLAIN (ANALYZE, BUFFERS, WAL, SETTINGS, VERBOSE, SUMMARY)
      SELECT ...
      FROM humanresources.department
      WHERE ...;

    Compare each important node's estimated "rows" with "actual rows". A
    sequential scan can be optimal for a small table or a large result set.

    11D. Refresh ordinary statistics for the selected table
    --------------------------------------------------------
    ANALYZE refreshes planner statistics. It does not remove dead tuples.

      ANALYZE VERBOSE humanresources.department;

    If dead tuples also require cleanup, combine VACUUM and ANALYZE:

      VACUUM (VERBOSE, ANALYZE) humanresources.department;

    Rerun 11A and the same 11C plan after maintenance. Stop when estimates and
    performance are acceptable; do not tune statistics solely to remove a
    sequential scan.

    11E. Apply a targeted statistics fix only for a proven estimate error
    ---------------------------------------------------------------------
    For skew on one predicate or join column, raise its target and recollect:

      ALTER TABLE humanresources.department
          ALTER COLUMN name SET STATISTICS 500;
      ANALYZE VERBOSE humanresources.department (name);

    For correlated columns used together, create and populate extended stats:

      CREATE STATISTICS humanresources.st_department_group_name
          (dependencies, ndistinct, mcv)
          ON groupname, name
          FROM humanresources.department;
      ANALYZE VERBOSE humanresources.department;

    Rerun the identical 11C plan and compare estimates, execution time,
    buffers, and planning time. Section 3B contains restore and cleanup forms.
    If estimates are accurate but the query remains expensive, investigate
    indexing, query shape, memory, I/O, locking, and returned-row volume; that
    is not a statistics-refresh problem.
*/

-- 12. Statistics maintenance captured by pg_stat_statements.
-- Run separately only when Section 1 reports pg_stat_statements_installed = true.
-- The extension view must also be visible through the current search_path and
-- the monitoring role must have permission to read it.
SELECT statements.calls,
       round(statements.total_exec_time::numeric, 2) AS total_exec_ms,
       round(statements.mean_exec_time::numeric, 2) AS mean_exec_ms,
       statements.rows,
       left(statements.query, 500) AS query_text
FROM pg_stat_statements AS statements
WHERE statements.dbid = (SELECT database_definition.oid
                          FROM pg_database AS database_definition
                          WHERE database_definition.datname = current_database())
  AND statements.query ~*
      '^\s*analyze([[:space:](]|$)|^\s*vacuum[[:space:](].*analyze'
ORDER BY statements.total_exec_time DESC
LIMIT 50;

/*
    Optional review commands (generated or run separately)
    ------------------------------------------------------

    PostgreSQL equivalent of SQL Server UPDATE STATISTICS. PostgreSQL does not
    use an UPDATE STATISTICS statement; ANALYZE recollects and replaces the
    table's ordinary planner statistics:

      ANALYZE VERBOSE sales.salesorderheader;

    Update statistics for selected columns only:

      ANALYZE VERBOSE sales.salesorderheader (customerid, territoryid);

    When dead tuples also need cleanup, vacuum and update statistics together:

      VACUUM (VERBOSE, ANALYZE) sales.salesorderheader;

    Inspect full values for one AdventureWorks column:

      SELECT *
      FROM pg_stats
      WHERE schemaname = 'sales'
        AND tablename = 'salesorderheader'
        AND attname = 'customerid';

    Increase detail for a skewed column, then recollect statistics. Higher
    targets increase ANALYZE time, catalog storage, and planning work.

      ALTER TABLE sales.salesorderheader
          ALTER COLUMN customerid SET STATISTICS 500;
      ANALYZE VERBOSE sales.salesorderheader (customerid);

    Restore the column to the database default target:

      ALTER TABLE sales.salesorderheader
          ALTER COLUMN customerid SET STATISTICS -1;

    Test multicolumn extended statistics for correlated predicates. CREATE
    STATISTICS creates metadata; ANALYZE populates the statistics data.

      CREATE STATISTICS sales.st_salesorderheader_customer_territory
          (dependencies, ndistinct, mcv)
          ON customerid, territoryid
          FROM sales.salesorderheader;

      ANALYZE VERBOSE sales.salesorderheader;

    Remove the demonstration statistics object when testing is complete:

      DROP STATISTICS IF EXISTS
          sales.st_salesorderheader_customer_territory;
*/