/*
    Enable or disable execution-plan workload tracking

    Usage with psql
    ---------------
    Enable (default):
      psql -d adventureworks -f DBA_EnableTracking.SQL
      psql -d adventureworks -v enable_tracking=on -f DBA_EnableTracking.SQL

    Disable:
      psql -d adventureworks -v enable_tracking=off -f DBA_EnableTracking.SQL

    Settings controlled
    -------------------
    Enabled values:
      track_io_timing = on
      pg_stat_statements.track = all
      pg_stat_statements.track_planning = on

    Disabled values:
      track_io_timing = off
      pg_stat_statements.track = none
      pg_stat_statements.track_planning = off

    Scope and permissions
    ---------------------
    ALTER SYSTEM makes these settings persistent for the PostgreSQL server.
    The settings are reloadable and normally do not require a restart. Existing
    sessions may retain prior values, so start pgbench only after this script
    completes and reconnect monitoring sessions before validating their settings.

    These are superuser-context parameters. Run as a sufficiently privileged DBA.
    On managed services such as Azure Database for PostgreSQL, ALTER SYSTEM can be
    restricted. If it is rejected, configure the same three parameter names and
    values through the Azure portal, Azure CLI, ARM/Bicep, or Terraform, then use
    the verification query at the end of this script in a new database session.

    Caution
    -------
    These changes affect workloads beyond AdventureWorks. track_io_timing adds
    timing overhead, track_planning adds planning instrumentation overhead, and
    pg_stat_statements.track = all also captures nested statements. Disabling
    tracking does not erase existing pg_stat_statements data; reset it separately
    when appropriate.
*/

\set ON_ERROR_STOP on
\pset pager off

-- Default to ON when the caller does not provide -v enable_tracking=on|off.
\if :{?enable_tracking}
\else
    \set enable_tracking on
\endif

-- Accept common Boolean spellings but reject ambiguous values before changing
-- server configuration.
SELECT lower(:'enable_tracking') IN
       ('on', 'off', 'true', 'false', 'yes', 'no', '1', '0')
       AS tracking_switch_valid,
       lower(:'enable_tracking') IN ('on', 'true', 'yes', '1')
       AS tracking_switch_on
\gset

\if :tracking_switch_valid
\else
    \echo 'ERROR: enable_tracking must be on or off.'
    \quit 2
\endif

-- Confirm pg_stat_statements is installed in the current database before changing
-- its collection settings. Install/load the extension separately if this fails.
SELECT EXISTS (
           SELECT 1
           FROM pg_extension
           WHERE extname = 'pg_stat_statements'
       ) AS pg_stat_statements_installed
\gset

\if :pg_stat_statements_installed
\else
    \echo 'ERROR: pg_stat_statements is not installed in the current database.'
    \quit 3
\endif

-- Avoid ALTER SYSTEM when the requested values are already effective. Otherwise,
-- verify that the current role can set every superuser-context parameter first.
SELECT bool_and(
       setting = CASE name
         WHEN 'pg_stat_statements.track' THEN
           CASE WHEN :'tracking_switch_on'::boolean THEN 'all' ELSE 'none' END
         ELSE
           CASE WHEN :'tracking_switch_on'::boolean THEN 'on' ELSE 'off' END
       END
     ) AS tracking_already_configured,
     bool_and(has_parameter_privilege(current_user, name, 'SET'))
       AS can_configure_tracking
FROM pg_settings
WHERE name IN ('track_io_timing',
         'pg_stat_statements.track',
         'pg_stat_statements.track_planning')
\gset

\if :tracking_already_configured
  \echo 'Tracking settings already match the requested mode; no server change is needed.'
\else
  \if :can_configure_tracking
    \if :tracking_switch_on
      \echo 'Enabling execution-plan workload tracking...'

      ALTER SYSTEM SET track_io_timing = 'on';
      ALTER SYSTEM SET pg_stat_statements.track = 'all';
      ALTER SYSTEM SET pg_stat_statements.track_planning = 'on';
    \else
      \echo 'Disabling execution-plan workload tracking...'

      ALTER SYSTEM SET track_io_timing = 'off';
      ALTER SYSTEM SET pg_stat_statements.track = 'none';
      ALTER SYSTEM SET pg_stat_statements.track_planning = 'off';
    \endif

    -- These parameters are reloadable and do not require a server restart.
    SELECT pg_reload_conf() AS configuration_reload_requested;
  \else
    \echo 'ERROR: The current role cannot change all tracking parameters.'
    \echo 'On Azure Database for PostgreSQL, set them under Server parameters.'
    \echo 'Requested and current values:'

    SELECT name,
         setting AS current_value,
         CASE name
           WHEN 'pg_stat_statements.track' THEN
             CASE WHEN :'tracking_switch_on'::boolean THEN 'all' ELSE 'none' END
           ELSE
             CASE WHEN :'tracking_switch_on'::boolean THEN 'on' ELSE 'off' END
         END AS requested_value,
         has_parameter_privilege(current_user, name, 'SET') AS can_set
    FROM pg_settings
    WHERE name IN ('track_io_timing',
             'pg_stat_statements.track',
             'pg_stat_statements.track_planning')
    ORDER BY name;

    \quit 4
  \endif
\endif

-- Verify configured and effective values. setting is the value visible to this
-- session; sourcefile/sourceline identify the winning configuration entry.
-- Reconnect and rerun this SELECT if the current session still shows old values.
SELECT name,
       setting AS effective_value,
       reset_val AS configured_reset_value,
       source,
       sourcefile,
       sourceline,
       pending_restart
FROM pg_settings
WHERE name IN ('track_io_timing',
               'pg_stat_statements.track',
               'pg_stat_statements.track_planning')
ORDER BY name;
