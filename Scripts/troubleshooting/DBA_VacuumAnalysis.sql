/*
    DBA analysis and optimization advisor for VACUUM and autovacuum

    Purpose
    -------
    Use this script to identify tables that need vacuuming, transaction ID
    wraparound risk, ineffective autovacuum settings, blocked or slow workers,
    long-running transactions that prevent cleanup, and tables whose maintenance
    thresholds should be reviewed.

    Safety
    ------
    This script does not run VACUUM or change configuration. Sections 13 and 14
    generate commands for DBA review. Test proposed settings against workload and
    storage capacity before applying them. VACUUM FULL requires an ACCESS EXCLUSIVE
    lock and is intentionally not recommended automatically.

    Scope and requirements
    ----------------------
    - Run in each database that needs analysis; table statistics are per database.
    - pg_monitor or pg_read_all_stats provides the most complete visibility.
    - Statistics are cumulative since stats_reset and estimates can lag briefly.
    - n_dead_tup is an estimate, not an exact bloat measurement.
    - Regular VACUUM reclaims space for reuse inside a relation; it usually does
      not return space to the operating system.

    Suggested workflow
    ------------------
    - Run sections 1 through 4 for configuration and maintenance priorities.
    - Run sections 5 through 8 while autovacuum or manual VACUUM is active.
    - Resolve old transactions, prepared transactions, or replication horizons
      found in sections 9 through 11 before increasing vacuum aggressiveness.
    - Review generated commands in sections 13 and 14; execute only those that
      match the workload, maintenance window, and measured resource capacity.
*/

\pset pager off
\timing on

-- 1. Verify server identity, monitoring privileges, and statistics age.
SELECT current_database() AS database_name,
       current_user AS monitoring_role,
       current_setting('server_version') AS server_version,
       pg_has_role(current_user, 'pg_monitor', 'MEMBER') AS is_pg_monitor,
       pg_has_role(current_user, 'pg_read_all_stats', 'MEMBER')
           AS can_read_all_stats,
       database_stats.stats_reset,
       pg_postmaster_start_time() AS server_started_at,
       clock_timestamp() AS observed_at
FROM pg_stat_database AS database_stats
WHERE database_stats.datname = current_database();

-- 2. Review the settings that control autovacuum frequency, concurrency, cost,
-- freezing, and logging. source identifies whether a value is default, server,
-- database, or role configuration. pending_restart highlights unapplied changes.
SELECT name,
       setting,
       unit,
       context,
       source,
       pending_restart
FROM pg_settings
WHERE name IN (
    'autovacuum',
    'track_counts',
    'autovacuum_max_workers',
    'autovacuum_naptime',
    'autovacuum_vacuum_threshold',
    'autovacuum_vacuum_scale_factor',
    'autovacuum_vacuum_insert_threshold',
    'autovacuum_vacuum_insert_scale_factor',
    'autovacuum_analyze_threshold',
    'autovacuum_analyze_scale_factor',
    'autovacuum_vacuum_cost_delay',
    'autovacuum_vacuum_cost_limit',
    'vacuum_cost_delay',
    'vacuum_cost_limit',
    'vacuum_cost_page_hit',
    'vacuum_cost_page_miss',
    'vacuum_cost_page_dirty',
    'autovacuum_freeze_max_age',
    'autovacuum_multixact_freeze_max_age',
    'vacuum_freeze_min_age',
    'vacuum_freeze_table_age',
    'vacuum_multixact_freeze_min_age',
    'vacuum_multixact_freeze_table_age',
    'maintenance_work_mem',
    'autovacuum_work_mem',
    'log_autovacuum_min_duration'
)
ORDER BY name;

-- 3. Check database transaction ID and multixact wraparound risk. Values nearing
-- 100 percent require urgent investigation. Autovacuum may run even when disabled
-- for a table when PostgreSQL must prevent wraparound.
WITH limits AS (
    SELECT current_setting('autovacuum_freeze_max_age')::numeric AS xid_limit,
           current_setting('autovacuum_multixact_freeze_max_age')::numeric
               AS mxid_limit
)
SELECT database_name.datname,
       age(database_name.datfrozenxid) AS xid_age,
       round(100.0 * age(database_name.datfrozenxid) / limits.xid_limit, 2)
           AS xid_limit_pct,
       mxid_age(database_name.datminmxid) AS multixact_age,
       round(
           100.0 * mxid_age(database_name.datminmxid) / limits.mxid_limit,
           2
       ) AS multixact_limit_pct,
       CASE
           WHEN age(database_name.datfrozenxid) >= limits.xid_limit * 0.90
             OR mxid_age(database_name.datminmxid) >= limits.mxid_limit * 0.90
           THEN 'CRITICAL'
           WHEN age(database_name.datfrozenxid) >= limits.xid_limit * 0.75
             OR mxid_age(database_name.datminmxid) >= limits.mxid_limit * 0.75
           THEN 'WARNING'
           ELSE 'OK'
       END AS risk_level
FROM pg_database AS database_name
CROSS JOIN limits
WHERE database_name.datallowconn
ORDER BY GREATEST(
             age(database_name.datfrozenxid) / limits.xid_limit,
             mxid_age(database_name.datminmxid) / limits.mxid_limit
         ) DESC;

-- 4. Rank user tables by maintenance urgency. threshold_exceeded approximates the
-- global autovacuum trigger. Per-table reloptions can override these global values,
-- so review table_options before relying on that indicator.
WITH vacuum_settings AS (
    SELECT current_setting('autovacuum_vacuum_threshold')::numeric
               AS vacuum_threshold,
           current_setting('autovacuum_vacuum_scale_factor')::numeric
               AS vacuum_scale_factor,
           current_setting('autovacuum_analyze_threshold')::numeric
               AS analyze_threshold,
           current_setting('autovacuum_analyze_scale_factor')::numeric
               AS analyze_scale_factor
)
SELECT stats.schemaname,
       stats.relname,
       pg_size_pretty(pg_total_relation_size(stats.relid)) AS total_size,
       stats.n_live_tup,
       stats.n_dead_tup,
       round(
           100.0 * stats.n_dead_tup /
           NULLIF(stats.n_live_tup + stats.n_dead_tup, 0),
           2
       ) AS dead_tuple_pct,
       stats.n_ins_since_vacuum,
       stats.n_mod_since_analyze,
       ceil(settings.vacuum_threshold
            + settings.vacuum_scale_factor * stats.n_live_tup)
           AS estimated_vacuum_trigger,
       stats.n_dead_tup >= ceil(
           settings.vacuum_threshold
           + settings.vacuum_scale_factor * stats.n_live_tup
       ) AS vacuum_threshold_exceeded,
       stats.n_mod_since_analyze >= ceil(
           settings.analyze_threshold
           + settings.analyze_scale_factor * stats.n_live_tup
       ) AS analyze_threshold_exceeded,
       stats.last_vacuum,
       stats.last_autovacuum,
       stats.vacuum_count,
       stats.autovacuum_count,
       stats.last_analyze,
       stats.last_autoanalyze,
       relation.reloptions AS table_options
FROM pg_stat_user_tables AS stats
JOIN pg_class AS relation
  ON relation.oid = stats.relid
CROSS JOIN vacuum_settings AS settings
ORDER BY (stats.n_dead_tup >= ceil(
             settings.vacuum_threshold
             + settings.vacuum_scale_factor * stats.n_live_tup
         )) DESC,
         stats.n_dead_tup DESC,
         pg_total_relation_size(stats.relid) DESC;

-- 5. Find tables with autovacuum disabled explicitly. This can be intentional for
-- controlled bulk loads, but permanent use increases dead-tuple and wraparound risk.
SELECT namespace.nspname AS schemaname,
       relation.relname,
       pg_size_pretty(pg_total_relation_size(relation.oid)) AS total_size,
       relation.reloptions AS table_options,
       age(relation.relfrozenxid) AS xid_age,
       mxid_age(relation.relminmxid) AS multixact_age
FROM pg_class AS relation
JOIN pg_namespace AS namespace
  ON namespace.oid = relation.relnamespace
WHERE relation.relkind IN ('r', 'm')
  AND namespace.nspname NOT IN ('pg_catalog', 'information_schema')
  AND EXISTS (
      SELECT 1
      FROM unnest(COALESCE(relation.reloptions, ARRAY[]::text[])) AS option_value
      WHERE option_value = 'autovacuum_enabled=false'
  )
ORDER BY age(relation.relfrozenxid) DESC;

-- 6. Monitor VACUUM progress. heap_blks_scanned_pct shows scan progress, while
-- indexes_processed_pct applies during index cleanup. vacuuming indexes can repeat
-- in multiple cycles when maintenance memory cannot hold all dead tuple identifiers.
SELECT progress.pid,
       activity.backend_type,
       activity.usename,
       activity.application_name,
       progress.relid::regclass AS relation_name,
       progress.phase,
       progress.heap_blks_total,
       progress.heap_blks_scanned,
       round(
           100.0 * progress.heap_blks_scanned /
           NULLIF(progress.heap_blks_total, 0),
           2
       ) AS heap_blks_scanned_pct,
       progress.heap_blks_vacuumed,
       progress.index_vacuum_count,
       progress.max_dead_tuples,
       progress.num_dead_tuples,
       activity.wait_event_type,
       activity.wait_event,
       clock_timestamp() - activity.query_start AS elapsed,
       left(activity.query, 500) AS vacuum_command
FROM pg_stat_progress_vacuum AS progress
JOIN pg_stat_activity AS activity
  ON activity.pid = progress.pid
ORDER BY activity.query_start;

-- 7. Summarize autovacuum workers and their current waits. Lock waits can prevent
-- progress; IO waits can indicate storage pressure; no wait generally means CPU or
-- runnable work. A high worker count at the configured maximum may indicate backlog.
SELECT activity.pid,
       activity.datname,
       activity.state,
       activity.wait_event_type,
       activity.wait_event,
       clock_timestamp() - activity.query_start AS elapsed,
       pg_blocking_pids(activity.pid) AS blocking_pids,
       left(activity.query, 500) AS current_query
FROM pg_stat_activity AS activity
WHERE activity.backend_type = 'autovacuum worker'
   OR activity.query ~* '^\s*(autovacuum:|vacuum\s)'
ORDER BY activity.query_start;

-- 8. Show blockers of active VACUUM operations. Resolve the owning transaction
-- rather than terminating a backend without understanding its business impact.
SELECT vacuum_activity.pid AS vacuum_pid,
       vacuum_activity.query_start AS vacuum_started_at,
       clock_timestamp() - vacuum_activity.query_start AS vacuum_elapsed,
       vacuum_activity.wait_event_type,
       vacuum_activity.wait_event,
       blocker.pid AS blocker_pid,
       blocker.usename AS blocker_user,
       blocker.application_name AS blocker_application,
       blocker.state AS blocker_state,
       clock_timestamp() - blocker.xact_start AS blocker_transaction_age,
       left(vacuum_activity.query, 500) AS vacuum_query,
       left(blocker.query, 500) AS blocker_query
FROM pg_stat_activity AS vacuum_activity
CROSS JOIN LATERAL
     unnest(pg_blocking_pids(vacuum_activity.pid)) AS blockers(blocker_pid)
JOIN pg_stat_activity AS blocker
  ON blocker.pid = blockers.blocker_pid
WHERE vacuum_activity.backend_type = 'autovacuum worker'
   OR vacuum_activity.query ~* '^\s*(autovacuum:|vacuum\s)'
ORDER BY vacuum_elapsed DESC;

-- 9. Find old transactions and xmin horizons that can prevent VACUUM from removing
-- dead rows. Pay special attention to idle-in-transaction sessions.
SELECT pid,
       usename,
       application_name,
       client_addr,
       state,
       backend_xid,
       backend_xmin,
       age(backend_xmin) AS xmin_age,
       clock_timestamp() - backend_start AS backend_age,
       clock_timestamp() - xact_start AS transaction_age,
       clock_timestamp() - state_change AS state_age,
       wait_event_type,
       wait_event,
       left(query, 1000) AS current_or_last_query
FROM pg_stat_activity
WHERE datname = current_database()
  AND backend_type = 'client backend'
  AND pid <> pg_backend_pid()
  AND (xact_start IS NOT NULL OR backend_xmin IS NOT NULL)
ORDER BY backend_xmin NULLS LAST,
         xact_start NULLS LAST;

-- 10. Prepared transactions remain open independently of their original session
-- and can hold back cleanup until committed or rolled back.
SELECT transaction,
       gid,
       prepared,
       clock_timestamp() - prepared AS prepared_age,
       owner,
       database
FROM pg_prepared_xacts
ORDER BY prepared;

-- 11. Replication slots can retain row versions or catalog tuples. Investigate old
-- xmin/catalog_xmin values and inactive slots before dropping anything; slots may
-- be required by replicas, CDC, or logical replication consumers.
SELECT slot_name,
       slot_type,
       database,
       active,
       active_pid,
       xmin,
       age(xmin) AS xmin_age,
       catalog_xmin,
       age(catalog_xmin) AS catalog_xmin_age,
       restart_lsn,
       confirmed_flush_lsn,
       wal_status
FROM pg_replication_slots
ORDER BY GREATEST(
             COALESCE(age(xmin), 0),
             COALESCE(age(catalog_xmin), 0)
         ) DESC;

-- 12. Review per-table freezing age and maintenance history. High xid_age or
-- multixact_age can be urgent even when dead_tuple_pct is low.
SELECT stats.schemaname,
       stats.relname,
       pg_size_pretty(pg_total_relation_size(stats.relid)) AS total_size,
       age(relation.relfrozenxid) AS xid_age,
       mxid_age(relation.relminmxid) AS multixact_age,
       stats.n_live_tup,
       stats.n_dead_tup,
       stats.last_vacuum,
       stats.last_autovacuum,
       stats.vacuum_count,
       stats.autovacuum_count,
       relation.reloptions AS table_options
FROM pg_stat_user_tables AS stats
JOIN pg_class AS relation
  ON relation.oid = stats.relid
ORDER BY age(relation.relfrozenxid) DESC,
         mxid_age(relation.relminmxid) DESC;

-- 13. Generate targeted maintenance commands for tables currently beyond the
-- approximate global vacuum or analyze trigger. Review locking and I/O capacity,
-- then run selected commands individually. VERBOSE output helps diagnose behavior.
WITH settings AS (
    SELECT current_setting('autovacuum_vacuum_threshold')::numeric
               AS vacuum_threshold,
           current_setting('autovacuum_vacuum_scale_factor')::numeric
               AS vacuum_scale_factor,
           current_setting('autovacuum_analyze_threshold')::numeric
               AS analyze_threshold,
           current_setting('autovacuum_analyze_scale_factor')::numeric
               AS analyze_scale_factor
)
SELECT stats.schemaname,
       stats.relname,
       stats.n_dead_tup,
       stats.n_mod_since_analyze,
       CASE
           WHEN stats.n_dead_tup >= ceil(
                    settings.vacuum_threshold
                    + settings.vacuum_scale_factor * stats.n_live_tup
                )
           THEN format(
                    'VACUUM (VERBOSE, ANALYZE) %I.%I;',
                    stats.schemaname,
                    stats.relname
                )
           WHEN stats.n_mod_since_analyze >= ceil(
                    settings.analyze_threshold
                    + settings.analyze_scale_factor * stats.n_live_tup
                )
           THEN format(
                    'ANALYZE VERBOSE %I.%I;',
                    stats.schemaname,
                    stats.relname
                )
       END AS proposed_maintenance_command
FROM pg_stat_user_tables AS stats
CROSS JOIN settings
WHERE stats.n_dead_tup >= ceil(
          settings.vacuum_threshold
          + settings.vacuum_scale_factor * stats.n_live_tup
      )
   OR stats.n_mod_since_analyze >= ceil(
          settings.analyze_threshold
          + settings.analyze_scale_factor * stats.n_live_tup
      )
ORDER BY stats.n_dead_tup DESC,
         stats.n_mod_since_analyze DESC;

-- 14. Generate conservative per-table autovacuum examples for large, frequently
-- changing tables still using global settings. These are candidates, not automatic
-- prescriptions. Lower scale factors run maintenance sooner and can increase I/O.
-- Existing table-level options are excluded to avoid overwriting intentional tuning.
SELECT stats.schemaname,
       stats.relname,
       pg_size_pretty(pg_total_relation_size(stats.relid)) AS total_size,
       stats.n_live_tup,
       stats.n_dead_tup,
       stats.n_mod_since_analyze,
       format(
           'ALTER TABLE %I.%I SET (autovacuum_vacuum_scale_factor = 0.02, '
           'autovacuum_analyze_scale_factor = 0.01);',
           stats.schemaname,
           stats.relname
       ) AS proposed_tuning_command,
       format(
           'ALTER TABLE %I.%I RESET (autovacuum_vacuum_scale_factor, '
           'autovacuum_analyze_scale_factor);',
           stats.schemaname,
           stats.relname
       ) AS rollback_command
FROM pg_stat_user_tables AS stats
JOIN pg_class AS relation
  ON relation.oid = stats.relid
WHERE pg_total_relation_size(stats.relid) >= 1024::bigint * 1024 * 1024
  AND relation.reloptions IS NULL
  AND (stats.n_dead_tup > 0 OR stats.n_mod_since_analyze > 0)
ORDER BY pg_total_relation_size(stats.relid) DESC;

-- 15. Review database-level outcomes. Rising deadlocks or temporary activity is not
-- caused by VACUUM alone, but provides context when correlating maintenance windows.
SELECT datname,
       stats_reset,
       xact_commit,
       xact_rollback,
       blks_read,
       blks_hit,
       round(
           100.0 * blks_hit / NULLIF(blks_hit + blks_read, 0),
           2
       ) AS cache_hit_pct,
       temp_files,
       pg_size_pretty(temp_bytes) AS temp_size,
       deadlocks,
       round(blk_read_time::numeric, 2) AS block_read_ms,
       round(blk_write_time::numeric, 2) AS block_write_ms
FROM pg_stat_database
WHERE datname = current_database();
