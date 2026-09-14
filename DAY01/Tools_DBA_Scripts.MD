# DBA Scripts

</br>



| scriptname | Use when |
| --- | --- |
| [DBA_ActivityReview](../Scripts/troubleshooting/DBA_ActivityReview.sql) |  Reviews current PostgreSQL sessions, active queries, wait events, transaction age, query duration, and blocking PIDs. Useful for general real-time workload monitoring. |
| [DBA_BlockingReview](../Scripts/troubleshooting/DBA_BlockingReview.sql) | Diagnoses lock contention by identifying blocked sessions, blocking sessions, lock types, affected objects, blocking duration, and blocker query details. |
| [DBA_ConnectionAnalysis](../Scripts/troubleshooting/DBA_ConnectionAnalysis.SQL) | Analyzes connection utilization, backend processes, session states, waits, connection capacity, and relevant memory settings. Designed primarily for the connection-test workload. |
| [DBA_CursorsReview](../Scripts/troubleshooting/DBA_CursorsReview.SQL) | Monitors cursor workloads through session activity, waits, locks, function statistics, statement performance, table access, index usage, and update-related table health. |
| [DBA_EnableTrackin](../Scripts/troubleshooting/DBA_EnableTracking.SQL) | Enables or disables PostgreSQL performance tracking settings, including I/O timing, nested statement tracking, and planning statistics. Requires elevated privileges or managed-service parameter configuration. |
| [DBA_ErrorsReview](../Scripts/troubleshooting/DBA_ErrorsReview.sql) | Reviews the intentional-error workload, including active sessions, unhealthy transaction states, rollback statistics, SQLSTATE distributions, and individual events recorded in pgbench_error_log. |
| [DBA_ExecutionPlan_Analysis](../Scripts/troubleshooting/DBA_ExecutionPlan_Analysis.sql) | Provides detailed performance analysis for the execution-plan workload, covering statement latency, planning time, I/O, cache efficiency, temporary spills, JIT, parallelism, WAL, waits, and object access. |
| [DBA_NonOptimal_Queries](../Scripts/troubleshooting/DBA_NonOptimal_Queries.sql) | Compares non-sargable and optimized queries using live activity, pg_stat_statements, table scan statistics, and index usage. Primarily supports the SARGability workload. |
| [DBA_TempDBReview](../Scripts/troubleshooting/DBA_TempDBReview.sql) | Analyzes PostgreSQL temporary processing, including temporary tables, executor spills, session activity, blocking, source-table access, database temporary-file totals, and PostgreSQL 16+ I/O statistics. |