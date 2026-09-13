# Workload Definitions

</br>
</br>
these are the workloads available for this workshop, with their definition, and scripts/explanation how to monitor/troubleshoot them:

| workload | Definition | DBA Script filename |
|---|---|---|
| [0 Connection Test](Workload_00_Connection_Test.MD) | Creates concurrent sessions running a simple query to analyze connection capacity, backend processes, waits, and PgBouncer behavior. | [DBA_ConnectionAnalysis](../../scripts/troubleshooting/DBA_ConnectionAnalysis.SQL) |
| [1 Compile Workload](Workload_01_CompileWorkload.MD) | Runs randomized AdventureWorks queries to demonstrate planning overhead, statement diversity, latency, and database activity. | [DBA_ActivityReview](../../scripts/troubleshooting/DBA_ActivityReview.sql) |
| [2 CPU](Workload_02_CPU.MD) | Calls AdventureWorks search functions with randomized values to generate database CPU load. | [DBA_ActivityReview](../../scripts/troubleshooting/DBA_ActivityReview.sql) |
| [3 SQL CPU](Workload_03_SQL_CPU.MD) | Runs three concurrent calculation workloads using power, cosine, and number-table operations. | [DBA_ActivityReview](../../scripts/troubleshooting/DBA_ActivityReview.sql) |
| [4 Blockers](Workload_04_Blockers.MD) | Creates intentional blocker and blocked sessions to demonstrate lock waits and blocking chains. | [DBA_BlockingReview](../../scripts/troubleshooting/DBA_BlockingReview.sql) |
| [5 Sargability Queries](Workload_05_Sargability_Queries.MD) | Compares non-SARGable queries against indexed, SARGable equivalents. | [DBA_NonOptimal_Queries](../../scripts/troubleshooting/DBA_NonOptimal_Queries.sql) |
| [6 Execution Plan](Workload_06_Execution_Plan.MD) | Runs randomized query patterns to analyze execution cost, planning, I/O, scans, parallelism, JIT, and temporary spills. | [DBA_ExecutionPlan_Analysis](../../scripts/troubleshooting/DBA_ExecutionPlan_Analysis.sql) |
| [7 Cursors](Workload_07_Cursos.MD) | Runs read and update cursor workloads to demonstrate row-by-row processing, locking, WAL, and dead tuples. | [DBA_CursorsReview](../../scripts/troubleshooting/DBA_CursorsReview.SQL) |
| [8 Errors](Workload_08_Errors.MD) | Generates and catches intentional PostgreSQL errors while recording their SQLSTATE and context. | [DBA_ErrorsReview](../../scripts/troubleshooting/DBA_ErrorsReview.sql) |
| [9 TempDB](Workload_09_TempDB.MD) | Repeatedly creates, populates, queries, and drops session-local temporary tables to measure temporary processing. | [DBA_TempDBReview](../../scripts/troubleshooting/DBA_TempDBReview.sql) |

</br>

</br>
Go back to Requirements 

[Azure PostgreSQL Workshop Prerequisites](S0%20-%20Requirements.md)
