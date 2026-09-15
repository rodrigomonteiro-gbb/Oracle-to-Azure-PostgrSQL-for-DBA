# Execution Plan Demos — AdventureWorks on PostgreSQL

Built for an audience of Oracle (or SQL Server) DBAs. Every script carries the
translation inline, because the message of the session is:

> **The vocabulary changed. The expertise did not.**
> `EXPLAIN (ANALYZE, BUFFERS)` replaces `DBMS_XPLAN`.
> `Seq Scan` / `Index Scan` / `Hash Join` replace `TABLE ACCESS FULL` /
> `INDEX RANGE SCAN` / `HASH JOIN`.
> **The habit of hunting a wrong row estimate is identical.**

---

## Run them

```powershell
cd "<folder with the scripts>"
$env:PGPASSWORD = "<admin password>"

.\03_plans.ps1 -Script list          # all scripts + suggested running order
.\03_plans.ps1 -Script discovery     # ALWAYS run this first
.\03_plans.ps1 -Script seqscan -Capture
.\03_plans.ps1 -Interactive          # live psql, step through with \i
.\03_plans.ps1 -Script cleanup       # when finished
```

Or straight from psql:
```
\i plans/02_seqscan_vs_index.sql
```

---

## The scripts

| # | File | Covers |
|---|---|---|
| 00 | `00_discovery.sql` | Read-only inventory: tables, **existing indexes**, stats, memory settings |
| 01 | `01_reading_plans.sql` | `EXPLAIN` vs `ANALYZE` vs `BUFFERS`; full Oracle mapping table |
| 02 | `02_seqscan_vs_index.sql` | **Flagship.** Seq Scan → create index → Index Scan, cost compared |
| 03 | `03_index_only_and_bitmap.sql` | Index Only Scan, `Heap Fetches`, Bitmap Heap Scan, `BitmapAnd` |
| 04 | `04_joins.sql` | Nested Loop / Hash Join / Merge Join, and the `loops=` trap |
| 05 | `05_sorts_and_aggregates.sql` | Sort spill, HashAggregate vs GroupAggregate, deleting a Sort with an index |
| 06 | `06_parallel_and_cte.sql` | Gather, Memoize, CTE inlining (PG12 change), SubPlan vs InitPlan |
| 07 | `07_row_estimates.sql` | **The core message.** Three causes of bad estimates, and the fix for each |
| 08 | `08_index_tradeoffs.sql` | Write amplification (WAL measured), partial/expression indexes, unused-index audit |
| 09 | `09_full_scenario.sql` | **Finale.** One query, five tuning rounds, costs recorded each round |
| 99 | `99_cleanup.sql` | Drops every `ix_demo_*` / `stx_demo_*`, resets stats targets |

---

## Safety

- Every index is named `ix_demo_*`, every extended-stats object `stx_demo_*` —
  `99_cleanup.sql` finds and drops them by pattern.
- All `SET` commands (`work_mem`, `enable_seqscan`, `enable_hashjoin`,
  `max_parallel_workers_per_gather`) are **session-scoped**. Closing psql clears
  them; the server is never reconfigured.
- The only writes are in `08_index_tradeoffs.sql`, wrapped in
  `BEGIN; … ROLLBACK;`.
- **No AdventureWorks row or original index is ever modified.**

Verify anything is left behind:
```sql
SELECT * FROM pg_indexes WHERE indexname LIKE 'ix\_demo\_%';
```

---

## Before you present — two things that will bite you

**1. Check which indexes already exist.** AdventureWorks ports differ. Some
create only PK/FK constraints; others include the SQL Server secondary indexes.
If `orderdate` is already indexed, script 02 shows an Index Scan from the start
and the before/after evaporates.

```powershell
.\03_plans.ps1 -Script discovery
```

Each script names an alternate column where one exists. If the port is heavily
indexed, the safest untouched columns are usually `totaldue`, `duedate`, and
`status` on `salesorderheader`.

**2. Table size sets expectations.** `salesorderheader` is ~31k rows and
`salesorderdetail` ~121k. On a modern server these fit in cache, so *elapsed
times are small* — which is why the scripts teach you to compare **cost and
buffers**, not milliseconds. Say so up front and the small numbers stop being a
distraction:

> "These tables are small enough to sit in memory, so I'm going to read cost and
> buffer counts rather than milliseconds. On your 400 GB table the same plan
> shapes produce the same decisions — the ratios hold, the absolute numbers don't."

Want bigger numbers? Run the CPU/write workloads from `01_workloads.ps1` in
another window first so the cache is contended.

---

## Oracle → PostgreSQL reference

| Oracle | PostgreSQL |
|---|---|
| `EXPLAIN PLAN` + `DBMS_XPLAN.DISPLAY` | `EXPLAIN` |
| `GATHER_PLAN_STATISTICS` + `DISPLAY_CURSOR('ALLSTATS LAST')` | `EXPLAIN (ANALYZE, BUFFERS)` |
| `TABLE ACCESS FULL` | `Seq Scan` |
| `INDEX RANGE SCAN` | `Index Scan` |
| `INDEX FAST FULL SCAN` | `Index Only Scan` |
| `TABLE ACCESS BY INDEX ROWID` | the heap fetch inside `Index Scan` |
| `HASH JOIN` | `Hash Join` |
| `NESTED LOOPS` | `Nested Loop` |
| `SORT MERGE JOIN` | `Merge Join` |
| `SORT ORDER BY` | `Sort` |
| `HASH GROUP BY` | `HashAggregate` |
| `SORT GROUP BY` | `GroupAggregate` |
| PX slaves | `Gather` + `Parallel <op>` |
| `E-Rows` vs `A-Rows` | `rows=` vs `actual rows=` |
| `Starts` × `A-Rows` | `loops=` × `actual rows=` |
| buffer gets / physical reads | `Buffers: shared hit` / `shared read` |
| `DBMS_STATS.GATHER_TABLE_STATS` | `ANALYZE` |
| `METHOD_OPT … SIZE 254` | `ALTER TABLE … SET STATISTICS 500` |
| extended stats / column groups | `CREATE STATISTICS` |
| function-based index | expression index — `CREATE INDEX ON t ((expr))` |

No Oracle equivalent — lead with these: **Bitmap Heap Scan**, **partial
indexes**, **Memoize**, **Incremental Sort**.

---

## The plan-reading checklist (put this on a slide)

1. Is any `actual rows` wildly different from `rows=`? ← **always start here**
2. Which node owns the most `actual time` × `loops`?
3. `Seq Scan` on a big table with a selective filter? → index candidate
4. `Rows Removed by Filter` huge? → reading rows only to discard them
5. `temp read/written` present? → `work_mem` too small
6. `Batches: >1` on a Hash node? → the hash spilled to disk
7. `Heap Fetches: >0` on an Index Only Scan? → needs `VACUUM`
8. `Workers Planned` > `Workers Launched`? → worker pool exhausted

---

## Talking points that land

**On cost:** "Cost is in arbitrary planner units, not milliseconds. It's only
meaningful compared against another plan for the same query — which is exactly
what we're about to do."

**On the planner ignoring an index (script 02, step 5):** "An index isn't a
performance setting you switch on. It's a bet on selectivity, and the planner
re-evaluates that bet for every query. When someone tells me the database is
ignoring their index, this is usually why — and the planner is usually right."

**On `random_page_cost`:** "The default of 4.0 is a spinning-disk assumption. On
Azure Premium SSD it should be 1.1–2.0. Leaving it at 4.0 systematically biases
the planner away from your indexes." Highest-value, lowest-risk tuning change on
most migrated workloads.

**On `VACUUM`:** "In PostgreSQL, visibility lives in the heap, not the index. So
`VACUUM` isn't just space reclamation — it's what keeps your Index Only Scans
index-only." A genuine operational difference from Oracle.

**The close (script 09):** "Everything you just watched is the loop you already
run in Oracle. Read the plan bottom-up. Find the node reading rows it's going to
throw away. Check whether the estimate matches reality. Change one thing. Measure
again. The vocabulary is new. The expertise is not — and the expertise is the
expensive part."
