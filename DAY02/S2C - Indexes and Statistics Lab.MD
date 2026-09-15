# S2C - Indexes and Statistics Lab

## Purpose

In this lab, you will run a series of PostgreSQL scripts that demonstrate:

- B-tree indexes and column order
- Partial, expression, and covering indexes
- Index maintenance, write cost, and bloat
- Common indexing antipatterns
- PostgreSQL statistics and row estimates
- Extended statistics and statistics lifecycle
- A complete tuning scenario

The scripts use the AdventureWorks database and are located in the `indexes` folder.

## Important: How to Run These Scripts

Although you are working in VS Code and may already have a PostgreSQL connection in the database extension, run these files from the **VS Code integrated terminal using `psql`**.

The scripts contain `psql` commands such as `\echo`, `\timing`, and `\pset`. A standard SQL query editor may report syntax errors for these commands.

## Prerequisites

Before starting, confirm that you have:

- VS Code open at the workshop repository folder
- Access to the PostgreSQL server
- The AdventureWorks database installed
- A PostgreSQL account that can create and drop schemas, indexes, and statistics
- The PostgreSQL command-line client (`psql`) installed
- Your PostgreSQL host name, user name, database name, and password


The relevant scripts detect unavailable extensions and skip those optional sections.

## 1. Open the VS Code Terminal

In VS Code, select **Terminal > New Terminal**. Confirm that the terminal is PowerShell and that you are in the repository root, which contains `04_indexes.ps1` and the `indexes` folder.

```powershell
Get-Location
Get-ChildItem
```

Confirm that `psql` is available:

```powershell
psql --version
```

## 2. Connect to PostgreSQL

### Option A: Use the Workshop Launcher

Use this option when the instructor has already run `00_setup.ps1` and a `state.json` file exists in the repository root.

Set your password for the current terminal session:

```powershell
$env:PGPASSWORD = "<your PostgreSQL password>"
```

List the available lab scripts:

```powershell
.\04_indexes.ps1 -Script list
```

Open an interactive `psql` session:

```powershell
.\04_indexes.ps1 -Interactive
```

At the `psql` prompt, verify the connection:

```sql
SELECT current_database(), current_user, version();
```

### Option B: Connect Directly with `psql`

Use this option if `state.json` is not available. In the VS Code terminal, run:

```powershell
$env:PGPASSWORD = "<your PostgreSQL password>"
$env:PGSSLMODE = "require"
psql --host="<server-name>" --port=5432 --username="<user-name>" --dbname="adventureworks" --no-password
```

When the `psql` prompt appears, verify the connection:

```sql
SELECT current_database(), current_user, version();
```

## 3. Run the Lab Scripts

Run the scripts in numerical order. From the interactive `psql` prompt, use `\i`:

```text
\i indexes/00_index_inventory.sql
```

After each script finishes, read its output and discussion prompts before continuing.

| Step | Script | Topic |
| ---: | --- | --- |
| 1 | `00_index_inventory.sql` | Read-only inventory of indexes, usage, size, redundancy, and statistics health |
| 2 | `01_btree_and_column_order.sql` | B-tree leading-column rule, sort order, and indexed `NULL` values |
| 3 | `02_index_types.sql` | BRIN, hash, GIN with trigram search, full-text search, and JSONB |
| 4 | `03_special_indexes.sql` | Partial, expression, covering, and partial-unique indexes |
| 5 | `04_maintenance_and_bloat.sql` | WAL write cost, HOT updates, bloat, and `REINDEX` |
| 6 | `05_antipatterns.sql` | Common reasons an index is not used |
| 7 | `06_statistics_anatomy.sql` | Understanding `pg_stats` and planner estimates |
| 8 | `07_statistics_targets.sql` | Statistics resolution and per-column targets |
| 9 | `08_extended_statistics.sql` | Dependencies, distinct values, MCVs, and expression statistics |
| 10 | `09_stats_lifecycle.sql` | Autoanalyze thresholds and statistics after bulk loads |
| 11 | `10_full_scenario.sql` | Complete six-round query tuning scenario |
| 12 | `99_cleanup.sql` | Remove all objects created by the lab |

Run the full sequence with these commands:

```text
\i indexes/00_index_inventory.sql
\i indexes/01_btree_and_column_order.sql
\i indexes/02_index_types.sql
\i indexes/03_special_indexes.sql
\i indexes/04_maintenance_and_bloat.sql
\i indexes/05_antipatterns.sql
\i indexes/06_statistics_anatomy.sql
\i indexes/07_statistics_targets.sql
\i indexes/08_extended_statistics.sql
\i indexes/09_stats_lifecycle.sql
\i indexes/10_full_scenario.sql
```

You can also run one script directly from the VS Code terminal without opening an interactive session:

```powershell
.\04_indexes.ps1 -Script inventory
.\04_indexes.ps1 -Script btree
.\04_indexes.ps1 -Script types
```

To capture a script's output in a timestamped text file:

```powershell
.\04_indexes.ps1 -Script types -Capture
```

## 4. What to Record

For each `EXPLAIN (ANALYZE, BUFFERS)` result, identify and record:

- The scan type: Sequential, Index, Index Only, or Bitmap
- Estimated rows (`rows`)
- Actual rows (`actual rows`)
- Rows removed by a filter
- Planning and execution time
- Buffer activity
- Heap fetches for an Index Only Scan
- Whether the new index changed the plan

For `10_full_scenario.sql`, record the following after each round:

| Round | Change | Estimated Rows | Actual Rows | Total Cost | Buffers | Execution Time |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 1 | Baseline | | | | | |
| 2 | Extended statistics | | | | | |
| 3 | Higher statistics targets | | | | | |
| 4 | Filter index | | | | | |
| 5 | Partial covering index | | | | | |
| 6 | Covered join key | | | | | |

Focus on plan shape, estimates, cost, and buffers. The AdventureWorks tables may fit in memory, so small execution-time differences are normal.

## 5. Clean Up

Always run the cleanup script when the lab is complete:

```text
\i indexes/99_cleanup.sql
```

Or, from the VS Code PowerShell terminal:

```powershell
.\04_indexes.ps1 -Script cleanup
```

Cleanup removes only the lab objects:

- Indexes named `ix_lab_*`
- Extended statistics named `stx_lab_*`
- The `idx_lab` schema and its demonstration tables
- Per-column statistics targets and per-table autovacuum overrides changed by the lab

It does not remove AdventureWorks data, original indexes, primary keys, foreign keys, or unique constraints. Optional extensions are left installed.

Verify that cleanup succeeded. Each count should be `0`:

```sql
SELECT count(*) AS indexes_remaining
FROM pg_indexes
WHERE indexname LIKE 'ix\_lab\_%';

SELECT count(*) AS statistics_remaining
FROM pg_stats_ext
WHERE statistics_name LIKE 'stx\_lab\_%';

SELECT count(*) AS schemas_remaining
FROM pg_namespace
WHERE nspname = 'idx_lab';
```

Exit `psql`:

```text
\q
```

Clear the password from the PowerShell session:

```powershell
Remove-Item Env:PGPASSWORD
```

