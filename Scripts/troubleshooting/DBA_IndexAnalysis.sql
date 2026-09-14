/*
    DBA index usage and health analysis

    This script is read-only and uses core PostgreSQL catalog/statistics views.
    No extension is required for Sections 1 through 12. Optional extensions:
      pg_stat_statements - correlate workload cost with index opportunities
      pgstattuple        - exact/estimated index density and bloat inspection
      pg_buffercache     - current shared-buffer residency
      hypopg             - test hypothetical indexes without creating them

    Run in each database to be analyzed. Statistics are cumulative since reset.
    pg_monitor or pg_read_all_stats provides the most complete visibility.
*/

-- 1. Verify server identity, privileges, statistics age, and optional extensions.
SELECT current_database() AS database_name,
       current_user AS monitoring_role,
       current_setting('server_version') AS server_version,
       database_stats.stats_reset,
       pg_has_role(current_user, 'pg_monitor', 'MEMBER') AS is_pg_monitor,
       pg_has_role(current_user, 'pg_read_all_stats', 'MEMBER')
           AS can_read_all_stats,
       EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements')
           AS pg_stat_statements_installed,
       EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pgstattuple')
           AS pgstattuple_installed,
       EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_buffercache')
           AS pg_buffercache_installed,
       EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'hypopg')
           AS hypopg_installed,
       clock_timestamp() AS observed_at
FROM pg_stat_database AS database_stats
WHERE database_stats.datname = current_database();

-- 2. Inventory all user indexes, their definitions, validity, uniqueness, size,
-- and cumulative use. Constraint-backed indexes are identified separately.
SELECT namespace.nspname AS schemaname,
       table_class.relname AS table_name,
       index_class.relname AS index_name,
       pg_size_pretty(pg_relation_size(index_class.oid)) AS index_size,
       pg_relation_size(index_class.oid) AS index_bytes,
       index_definition.indisprimary AS is_primary,
       index_definition.indisunique AS is_unique,
       index_definition.indisvalid AS is_valid,
       index_definition.indisready AS is_ready,
       index_definition.indislive AS is_live,
       constraint_definition.contype AS constraint_type,
       index_stats.idx_scan,
       index_stats.idx_tup_read,
       index_stats.idx_tup_fetch,
       pg_get_indexdef(index_class.oid) AS index_definition
FROM pg_index AS index_definition
JOIN pg_class AS index_class
  ON index_class.oid = index_definition.indexrelid
JOIN pg_class AS table_class
  ON table_class.oid = index_definition.indrelid
JOIN pg_namespace AS namespace
  ON namespace.oid = table_class.relnamespace
LEFT JOIN pg_stat_user_indexes AS index_stats
  ON index_stats.indexrelid = index_class.oid
LEFT JOIN pg_constraint AS constraint_definition
  ON constraint_definition.conindid = index_class.oid
WHERE table_class.relkind IN ('r', 'm', 'p')
  AND namespace.nspname NOT IN ('pg_catalog', 'information_schema')
ORDER BY pg_relation_size(index_class.oid) DESC,
         namespace.nspname,
         table_class.relname,
         index_class.relname;

-- 3. Rank indexes by use. idx_scan counts scans, not rows or business value.
SELECT stats.schemaname,
       stats.relname AS table_name,
       stats.indexrelname AS index_name,
       stats.idx_scan,
       stats.idx_tup_read,
       stats.idx_tup_fetch,
       round(stats.idx_tup_read::numeric / NULLIF(stats.idx_scan, 0), 2)
           AS tuples_read_per_scan,
       round(stats.idx_tup_fetch::numeric / NULLIF(stats.idx_scan, 0), 2)
           AS heap_tuples_fetched_per_scan,
       pg_size_pretty(pg_relation_size(stats.indexrelid)) AS index_size,
       pg_get_indexdef(stats.indexrelid) AS index_definition
FROM pg_stat_user_indexes AS stats
ORDER BY stats.idx_scan DESC,
         pg_relation_size(stats.indexrelid) DESC;

-- 4. Potentially unused indexes. This excludes primary, unique, constraint-backed,
-- invalid, and not-ready indexes. Review a representative statistics interval,
-- replicas, seasonal jobs, and emergency queries before considering removal.
SELECT stats.schemaname,
       stats.relname AS table_name,
       stats.indexrelname AS index_name,
       stats.idx_scan,
       pg_size_pretty(pg_relation_size(stats.indexrelid)) AS index_size,
       pg_relation_size(stats.indexrelid) AS index_bytes,
       table_stats.n_tup_ins,
       table_stats.n_tup_upd,
       table_stats.n_tup_del,
       pg_get_indexdef(stats.indexrelid) AS index_definition
FROM pg_stat_user_indexes AS stats
JOIN pg_index AS index_definition
  ON index_definition.indexrelid = stats.indexrelid
JOIN pg_stat_user_tables AS table_stats
  ON table_stats.relid = stats.relid
LEFT JOIN pg_constraint AS constraint_definition
  ON constraint_definition.conindid = stats.indexrelid
WHERE stats.idx_scan = 0
  AND NOT index_definition.indisprimary
  AND NOT index_definition.indisunique
  AND index_definition.indisvalid
  AND index_definition.indisready
  AND constraint_definition.oid IS NULL
ORDER BY pg_relation_size(stats.indexrelid) DESC;

-- 5. Index cache and physical-read behavior. These counters are cumulative.
SELECT stats.schemaname,
       stats.relname AS table_name,
       stats.indexrelname AS index_name,
       stats.idx_blks_read,
       stats.idx_blks_hit,
       round(
           100.0 * stats.idx_blks_hit /
           NULLIF(stats.idx_blks_hit + stats.idx_blks_read, 0),
           2
       ) AS index_cache_hit_pct,
       pg_size_pretty(pg_relation_size(stats.indexrelid)) AS index_size
FROM pg_statio_user_indexes AS stats
ORDER BY stats.idx_blks_read DESC,
         pg_relation_size(stats.indexrelid) DESC;

-- 6. Table scan balance. High sequential scans are not automatically bad; small
-- tables and queries reading much of a table often favor sequential scans.
SELECT stats.schemaname,
       stats.relname AS table_name,
       stats.seq_scan,
       stats.seq_tup_read,
       stats.idx_scan,
       stats.idx_tup_fetch,
       round(
           100.0 * stats.idx_scan /
           NULLIF(stats.seq_scan + stats.idx_scan, 0),
           2
       ) AS index_scan_pct,
       stats.n_live_tup,
       stats.n_dead_tup,
       pg_size_pretty(pg_total_relation_size(stats.relid)) AS total_size,
       stats.last_analyze,
       stats.last_autoanalyze
FROM pg_stat_user_tables AS stats
ORDER BY stats.seq_tup_read DESC,
         pg_total_relation_size(stats.relid) DESC;

-- 7. Invalid or incomplete indexes. Invalid indexes may be left by failed CREATE
-- INDEX CONCURRENTLY operations and require investigation before rebuilding/removal.
SELECT namespace.nspname AS schemaname,
       table_class.relname AS table_name,
       index_class.relname AS index_name,
       index_definition.indisvalid AS is_valid,
       index_definition.indisready AS is_ready,
       index_definition.indislive AS is_live,
       pg_size_pretty(pg_relation_size(index_class.oid)) AS index_size,
       pg_get_indexdef(index_class.oid) AS index_definition
FROM pg_index AS index_definition
JOIN pg_class AS index_class
  ON index_class.oid = index_definition.indexrelid
JOIN pg_class AS table_class
  ON table_class.oid = index_definition.indrelid
JOIN pg_namespace AS namespace
  ON namespace.oid = table_class.relnamespace
WHERE NOT index_definition.indisvalid
   OR NOT index_definition.indisready
   OR NOT index_definition.indislive
ORDER BY pg_relation_size(index_class.oid) DESC;

-- 8. Exact duplicate index definitions by table, access method, keys, included
-- columns, predicates, and expressions. Constraint ownership must still be checked.
WITH index_signatures AS (
    SELECT index_definition.indrelid,
           index_class.oid AS index_oid,
           namespace.nspname AS schemaname,
           table_class.relname AS table_name,
           index_class.relname AS index_name,
           index_class.relam,
           index_definition.indkey,
           index_definition.indcollation,
           index_definition.indclass,
           index_definition.indoption,
           index_definition.indnkeyatts,
           index_definition.indnatts,
           index_definition.indisunique,
           index_definition.indisexclusion,
           pg_get_expr(index_definition.indpred, index_definition.indrelid)
               AS predicate,
           pg_get_expr(index_definition.indexprs, index_definition.indrelid)
               AS expressions,
           pg_relation_size(index_class.oid) AS index_bytes
    FROM pg_index AS index_definition
    JOIN pg_class AS index_class
      ON index_class.oid = index_definition.indexrelid
    JOIN pg_class AS table_class
      ON table_class.oid = index_definition.indrelid
    JOIN pg_namespace AS namespace
      ON namespace.oid = table_class.relnamespace
    WHERE index_definition.indisvalid
      AND namespace.nspname NOT IN ('pg_catalog', 'information_schema')
)
SELECT first_index.schemaname,
       first_index.table_name,
       first_index.index_name AS first_index,
       second_index.index_name AS duplicate_index,
       pg_size_pretty(first_index.index_bytes) AS first_index_size,
       pg_size_pretty(second_index.index_bytes) AS duplicate_index_size,
       pg_get_indexdef(first_index.index_oid) AS first_definition,
       pg_get_indexdef(second_index.index_oid) AS duplicate_definition
FROM index_signatures AS first_index
JOIN index_signatures AS second_index
  ON second_index.indrelid = first_index.indrelid
 AND second_index.index_oid > first_index.index_oid
 AND second_index.relam = first_index.relam
 AND second_index.indkey = first_index.indkey
 AND second_index.indcollation = first_index.indcollation
 AND second_index.indclass = first_index.indclass
 AND second_index.indoption = first_index.indoption
 AND second_index.indnkeyatts = first_index.indnkeyatts
 AND second_index.indnatts = first_index.indnatts
 AND second_index.indisunique = first_index.indisunique
 AND second_index.indisexclusion = first_index.indisexclusion
 AND second_index.predicate IS NOT DISTINCT FROM first_index.predicate
 AND second_index.expressions IS NOT DISTINCT FROM first_index.expressions
ORDER BY first_index.index_bytes + second_index.index_bytes DESC;

-- 9. Foreign keys without a supporting index whose leading columns exactly match
-- the foreign-key columns. Such indexes can improve parent DELETE/UPDATE checks and
-- common joins, but workload evidence must justify creating them.
SELECT child_namespace.nspname AS child_schema,
       child_table.relname AS child_table,
       constraint_definition.conname AS foreign_key,
       string_agg(child_column.attname, ', ' ORDER BY key_column.ordinality)
           AS foreign_key_columns,
       pg_size_pretty(pg_total_relation_size(child_table.oid)) AS child_table_size,
       format(
           'CREATE INDEX ON %I.%I (%s);',
           child_namespace.nspname,
           child_table.relname,
           string_agg(quote_ident(child_column.attname), ', '
                      ORDER BY key_column.ordinality)
       ) AS proposed_index_command
FROM pg_constraint AS constraint_definition
JOIN pg_class AS child_table
  ON child_table.oid = constraint_definition.conrelid
JOIN pg_namespace AS child_namespace
  ON child_namespace.oid = child_table.relnamespace
CROSS JOIN LATERAL
     unnest(constraint_definition.conkey) WITH ORDINALITY
     AS key_column(attnum, ordinality)
JOIN pg_attribute AS child_column
  ON child_column.attrelid = child_table.oid
 AND child_column.attnum = key_column.attnum
WHERE constraint_definition.contype = 'f'
  AND NOT EXISTS (
      SELECT 1
      FROM pg_index AS supporting_index
      WHERE supporting_index.indrelid = constraint_definition.conrelid
        AND supporting_index.indisvalid
        AND supporting_index.indisready
        AND supporting_index.indpred IS NULL
        AND supporting_index.indexprs IS NULL
        AND supporting_index.indnkeyatts >= cardinality(constraint_definition.conkey)
        AND ARRAY(
            SELECT index_key.attnum
            FROM unnest(supporting_index.indkey::smallint[])
               WITH ORDINALITY AS index_key(attnum, position)
            WHERE index_key.position <= cardinality(constraint_definition.conkey)
            ORDER BY index_key.position
          ) = ARRAY(
            SELECT foreign_key.attnum
            FROM unnest(constraint_definition.conkey)
               WITH ORDINALITY AS foreign_key(attnum, position)
            ORDER BY foreign_key.position
          )
  )
GROUP BY child_namespace.nspname,
         child_table.oid,
         child_table.relname,
         constraint_definition.oid,
         constraint_definition.conname
ORDER BY pg_total_relation_size(child_table.oid) DESC;

-- 10. Index maintenance cost context. Every INSERT and many UPDATE/DELETE operations
-- must maintain indexes even when those indexes are rarely scanned.
SELECT table_stats.schemaname,
       table_stats.relname AS table_name,
       count(index_definition.indexrelid) AS index_count,
       pg_size_pretty(COALESCE(sum(pg_relation_size(index_definition.indexrelid)), 0))
           AS total_index_size,
       table_stats.n_tup_ins,
       table_stats.n_tup_upd,
       table_stats.n_tup_hot_upd,
       round(
           100.0 * table_stats.n_tup_hot_upd /
           NULLIF(table_stats.n_tup_upd, 0),
           2
       ) AS hot_update_pct,
       table_stats.n_tup_del,
       table_stats.n_dead_tup
FROM pg_stat_user_tables AS table_stats
LEFT JOIN pg_index AS index_definition
  ON index_definition.indrelid = table_stats.relid
GROUP BY table_stats.relid,
         table_stats.schemaname,
         table_stats.relname,
         table_stats.n_tup_ins,
         table_stats.n_tup_upd,
         table_stats.n_tup_hot_upd,
         table_stats.n_tup_del,
         table_stats.n_dead_tup
ORDER BY count(index_definition.indexrelid) DESC,
         COALESCE(sum(pg_relation_size(index_definition.indexrelid)), 0) DESC;

-- 11. Active index builds and rebuilds. Available in PostgreSQL 12 and later.
SELECT progress.pid,
       progress.command,
       progress.relid::regclass AS table_name,
       progress.index_relid::regclass AS index_name,
       progress.phase,
       progress.lockers_total,
       progress.lockers_done,
       progress.blocks_total,
       progress.blocks_done,
       round(100.0 * progress.blocks_done / NULLIF(progress.blocks_total, 0), 2)
           AS blocks_done_pct,
       progress.tuples_total,
       progress.tuples_done,
       round(100.0 * progress.tuples_done / NULLIF(progress.tuples_total, 0), 2)
           AS tuples_done_pct,
       activity.wait_event_type,
       activity.wait_event,
       clock_timestamp() - activity.query_start AS elapsed
FROM pg_stat_progress_create_index AS progress
JOIN pg_stat_activity AS activity
  ON activity.pid = progress.pid
ORDER BY activity.query_start;

-- 12. Index-related statements captured by pg_stat_statements.
-- Run this section only when Section 1 reports pg_stat_statements_installed = true.
SELECT statements.calls,
     round(statements.total_exec_time::numeric, 2) AS total_exec_ms,
     left(statements.query, 500) AS query_text
FROM pg_stat_statements AS statements
WHERE statements.dbid = (SELECT database_definition.oid
              FROM pg_database AS database_definition
              WHERE database_definition.datname = current_database())
  AND statements.query ~*
    '^\s*(create|alter|drop|reindex)\s+(unique\s+)?index|^\s*vacuum'
ORDER BY statements.total_exec_time DESC
LIMIT 20;

/*
    Optional extension examples (run separately after installing the extension)
    ---------------------------------------------------------------------------

    pgstattuple: inspect the primary B-tree index for several AdventureWorks
    tables. Catalog lookup avoids depending on the imported index names.

      SELECT 'sales.salesorderheader' AS table_name,
             index_class.oid::regclass AS index_name,
             index_stats.*
      FROM pg_index AS index_definition
      JOIN pg_class AS index_class
        ON index_class.oid = index_definition.indexrelid
      CROSS JOIN LATERAL pgstatindex(index_class.oid) AS index_stats
      WHERE index_definition.indrelid = 'sales.salesorderheader'::regclass
        AND index_definition.indisprimary;

      SELECT 'sales.salesorderdetail' AS table_name,
             index_class.oid::regclass AS index_name,
             index_stats.*
      FROM pg_index AS index_definition
      JOIN pg_class AS index_class
        ON index_class.oid = index_definition.indexrelid
      CROSS JOIN LATERAL pgstatindex(index_class.oid) AS index_stats
      WHERE index_definition.indrelid = 'sales.salesorderdetail'::regclass
        AND index_definition.indisprimary;

      SELECT 'production.product' AS table_name,
             index_class.oid::regclass AS index_name,
             index_stats.*
      FROM pg_index AS index_definition
      JOIN pg_class AS index_class
        ON index_class.oid = index_definition.indexrelid
      CROSS JOIN LATERAL pgstatindex(index_class.oid) AS index_stats
      WHERE index_definition.indrelid = 'production.product'::regclass
        AND index_definition.indisprimary;

    Ranked B-tree fragmentation report for AdventureWorks user schemas.
    pgstatindex reads every qualifying index, so run this selectively and
    avoid peak periods on large databases.

      SELECT table_namespace.nspname AS schemaname,
             table_class.relname AS table_name,
             index_class.relname AS index_name,
             pg_size_pretty(index_stats.index_size) AS index_size,
             index_stats.tree_level,
             index_stats.leaf_pages,
             index_stats.empty_pages,
             index_stats.deleted_pages,
             round(index_stats.avg_leaf_density::numeric, 2)
                 AS avg_leaf_density_pct,
             round(index_stats.leaf_fragmentation::numeric, 2)
                 AS leaf_fragmentation_pct
      FROM pg_index AS index_definition
      JOIN pg_class AS table_class
        ON table_class.oid = index_definition.indrelid
      JOIN pg_namespace AS table_namespace
        ON table_namespace.oid = table_class.relnamespace
      JOIN pg_class AS index_class
        ON index_class.oid = index_definition.indexrelid
      JOIN pg_am AS access_method
        ON access_method.oid = index_class.relam
      CROSS JOIN LATERAL pgstatindex(index_class.oid) AS index_stats
      WHERE table_namespace.nspname IN
            ('humanresources', 'person', 'production', 'purchasing', 'sales')
        AND access_method.amname = 'btree'
        AND index_class.relkind = 'i'
        AND index_definition.indisvalid
        AND index_definition.indisready
      ORDER BY index_stats.leaf_fragmentation DESC,
               index_stats.index_size DESC;

    pg_buffercache, current index residency:
      SELECT c.oid::regclass AS index_name,
             count(*) AS cached_buffers,
             pg_size_pretty(count(*) * current_setting('block_size')::bigint)
                 AS cached_size
      FROM pg_buffercache AS b
       JOIN pg_class AS c
         ON c.relfilenode = b.relfilenode
        AND b.reltablespace = COALESCE(
          NULLIF(c.reltablespace, 0),
          (SELECT d.dattablespace
           FROM pg_database AS d
           WHERE d.datname = current_database())
         )
      JOIN pg_index AS i ON i.indexrelid = c.oid
      WHERE b.reldatabase IN (0, (SELECT oid FROM pg_database
                                 WHERE datname = current_database()))
      GROUP BY c.oid
      ORDER BY count(*) DESC;

    hypopg: compare baseline and hypothetical plans in the same session.

      SELECT *
      FROM hypopg_list_indexes;

      EXPLAIN
      SELECT customerid, orderdate, subtotal, totaldue
      FROM sales.salesorderheader
      WHERE customerid = 11000
      ORDER BY orderdate;

      SELECT * FROM hypopg_create_index(
          'CREATE INDEX ON sales.salesorderheader (customerid, orderdate)'
      );

      SELECT *
      FROM hypopg_list_indexes;

      EXPLAIN
      SELECT customerid, orderdate, subtotal, totaldue
      FROM sales.salesorderheader
      WHERE customerid = 11000
      ORDER BY orderdate;

      SELECT * FROM hypopg_create_index(
          'CREATE INDEX ON sales.salesorderheader (salespersonid, orderdate)'
      );

      SELECT *
      FROM hypopg_list_indexes;

      EXPLAIN
      SELECT salespersonid, customerid, orderdate, subtotal, totaldue
      FROM sales.salesorderheader
      WHERE salespersonid = 35
      ORDER BY orderdate;

      SELECT * FROM hypopg_create_index(
          'CREATE INDEX ON production.product '
          '(productline, daystomanufacture, name)'
      );

      SELECT *
      FROM hypopg_list_indexes;

      EXPLAIN
      SELECT name, productnumber, listprice
      FROM production.product
      WHERE productline = 'R'
        AND daystomanufacture < 4
      ORDER BY name;

      -- List hypothetical indexes in this session. This is a view, not a function.
      SELECT * FROM hypopg_list_indexes;

      -- Remove every hypothetical index created in this session.
      SELECT hypopg_reset();
*/
