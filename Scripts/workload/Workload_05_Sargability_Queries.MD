# Workload 5: Sargability Queries

This workload compares intentionally non-SARGable predicates with indexed, SARGable forms. It runs a BAD phase first, waits for confirmation, and then optionally runs a FIXED phase.

## Prerequisites

The connected role must be allowed to create and drop tables and indexes in the `public` schema. The launcher prepares isolated comparison tables, so do not store unrelated data in:

- `public.productdescription_sarg`
- `public.productdescription_sarg_fixed`

## Run the Workload

Start `Generate-PGSQL-Workload.ps1` and select:

```text
Workload: 5 Sargability queries
Port: 5432
Clients: 10
Threads: 4
Limit: Time
Duration: 60 seconds
```

The launcher performs this sequence:

1. Runs `SQL/AdventureWorks_Sargability_BAD_Setup.sql`.
2. Runs `SQL/AdventureWorks_Sargability_BAD.sql` and waits for it to finish.
3. Prompts whether to continue with the FIXED workload.
4. If **Yes** is selected, runs `SQL/AdventureWorks_Sargability_FIXED_Setup.sql`.
5. Starts `SQL/AdventureWorks_Sargability_FIXED.sql`.

The phases use these identities:

| Phase | Application name | Result folder |
| --- | --- | --- |
| BAD | `PGBench_Sargability_BAD` | `Results/PGBench_Sargability_BAD/<timestamp>` |
| FIXED | `PGBench_Sargability_FIXED` | `Results/PGBench_Sargability_FIXED/<timestamp>` |

Select **Reset PGSTATS before run** only when resetting shared statistics is acceptable. For a clean BAD-versus-FIXED comparison, capture BAD results before starting FIXED because the launcher resets statistics only once, before the full workflow.

## Monitor the Workload

During each phase and after completion, execute:

```text
SQL/DBA/DBA_NonOptimal_Queries.sql
```

Focus on:

- Active BAD or FIXED sessions
- Total and mean execution time
- Calls and rows per call
- Shared block hits and reads
- Temporary block reads and writes
- Sequential scans versus index scans
- Index usage for both comparison tables

The BAD script deliberately disables index, index-only, and bitmap scans inside its non-SARGable transactions. The FIXED script leaves planner choices enabled and uses predicates that match its indexes. Compare runs with identical clients, threads, duration, database, server tier, and cache conditions.
