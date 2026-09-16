# Pre-Migration Best Practices

## Oracle → Azure Database for PostgreSQL Flexible Server

### Tooling-led approach using the PostgreSQL extension for Visual Studio Code

**Audience:** Oracle DBAs, data architects, application owners, and the migration lead</br>
**Scope:** Everything that happens **before** the first row of production data moves</br>
**Primary tool:** PostgreSQL extension for Visual Studio Code (Microsoft, `ms-ossdata.vscode-pgsql`) — the Product Group's AI-assisted Oracle migration tooling</br>
**Companion to:** *Backup, Restore & Point-in-Time Restore — Workshop for Oracle DBAs*</br>

---

## 0. Why the pre-migration phase decides the outcome

An Oracle → PostgreSQL migration is a **heterogeneous** migration. This is not SQL Server → Azure SQL, where the engine is essentially the same on both sides. Oracle and PostgreSQL differ in SQL dialect, procedural language, data types, transaction semantics, and operational tooling.</br>

The consequence: **the work is front-loaded.** Migrations that fail rarely fail at the data-copy step — they fail because an assessment was skipped, a dependency was undiscovered, or "the application just uses standard SQL" turned out to be false.</br>

**What has changed:** the Azure Database for PostgreSQL Product Group now ships first-party, AI-assisted migration tooling directly inside the **PostgreSQL extension for Visual Studio Code**. It converts schema *and* application code, validates every converted object against a real PostgreSQL scratch database before emitting it, and produces the conversion report that becomes your assessment. This materially changes how you run the pre-migration phase — the tool now produces the authoritative gap list, not a spreadsheet estimate.</br>

> In a typical Oracle → PostgreSQL project, data movement is a small fraction of the effort. Schema conversion, PL/SQL conversion, application remediation, and testing **dominate**. The extension compresses the first two substantially — it does not remove the need for review, testing, or application ownership.

**The four pre-migration stages, in strict order:**

| Stage | Question it answers | Primary tool | Exit criteria |
|---|---|---|---|
| **1. Discover** | What do we actually have? | Pre-assessment scripts, inventory | Signed-off inventory of instances, databases, objects, and dependent applications |
| **2. Assess** | How hard is it, and what does the target look like? | **VS Code PostgreSQL extension** conversion report | Complexity rating, effort estimate, target SKU, gap list |
| **3. Convert** | Will the schema and code run on PostgreSQL? | **VS Code PostgreSQL extension** (schema pass, then application pass) | Converted schema deploys cleanly to a scratch target; review tasks triaged |
| **4. Plan & prove** | How do we cut over without losing the business? | Runbook, rehearsal, PITR drill | Approved runbook, tested rollback, validated performance baseline |

Do not let a project skip from Discover to data movement. Every stage below has a checklist; the checklists are the deliverable.

---

## 1. The Product Group tooling — PostgreSQL extension for Visual Studio Code

> **📺 Watch this first — 14 minutes, and it replaces an hour of explanation**
>
> **Azure Friday — "Migrate Oracle Workloads to PostgreSQL Using AI-Powered Tools in the VS Code PostgreSQL Extension"**
> Scott Hanselman with **Jonathon Frost**, Principal Product Manager, Azure Database for PostgreSQL
>
> - **YouTube:** https://www.youtube.com/watch?v=4X6sw5sWdqc
> - **Microsoft Learn Shows:** https://learn.microsoft.com/en-us/shows/azure-friday/migrate-oracle-workloads-to-postgresql-using-ai-powered-tools
>
> **Chapters — use these to jump straight to what your audience needs:**
>
> | Time | Topic |
> |---|---|
> | 00:00 | Introduction |
> | 00:36 | Model hyperparameter tuning, agent orchestration, and determinism |
> | 02:25 | Architectural overview of AI-enhanced schema migration |
> | 04:28 | How it's built on the VS Code extension for PostgreSQL |
> | 04:56 | Self-correction of AI-enhanced migration |
> | 05:59 | Migration demo |
> | 06:33 | Connect to Oracle database |
> | 07:23 | Connect to PostgreSQL database |
> | 07:50 | Connect to the AI endpoint |
> | 08:45 | Run migration |
> | 09:37 | Review completed migration report |
> | 11:07 | Visualize schema of PostgreSQL database |
> | 12:17 | Side-by-side file diff |
> | 13:30 | Where to get the extension and learn more |
>
> **Determinism and self-correction (00:36 and 04:56) are the two segments that answer the skeptical DBA's real question:** "why would I trust an AI to convert my PL/SQL?".

### 1.1 What the tooling actually is

The PostgreSQL extension for Visual Studio Code provides an **end-to-end Oracle → PostgreSQL migration workflow**. A guided wizard connects to the Oracle source, selects schemas, configures a Microsoft Foundry model for AI-assisted DDL conversion, and chooses a PostgreSQL scratch database for validation. Once the project exists, a **dashboard tracks extraction, conversion, export, and review in a single view**.

> ⚠️ **The Oracle → PostgreSQL migration workflow is available in Visual Studio Code only.** There is no portal or CLI equivalent. Plan workstation provisioning accordingly.

### 1.2 Two passes: schema first, then application

This sequencing is the single most important thing to get right.

#### **Pass 1 — Schema conversion**

Reads the Oracle data dictionary for the schemas you select, groups extracted objects into **dependency-ordered chunks**, and converts each chunk using your Microsoft Foundry deployment. Converted objects are **compiled against the scratch database before they're written out — so the DDL you receive is verified rather than a best guess.**

A run produces four artifacts:

| Artifact | What you do with it |
|---|---|
| **Object-level PostgreSQL `.sql` files**, organized by Oracle schema and object type | Your deployment source; review file by file |
| **Conversion report** — which objects converted, which were skipped, overall success rate | **This is your assessment deliverable** |
| **Review tasks** — objects needing human judgment (fallback DDL, behavior differences) | Triage into mechanical / semantic / redesign (§4.4) |
| **Coding notes** — Oracle patterns found and how they map to PostgreSQL | Input to Pass 2, and to the application team |

#### **Pass 2 — Application conversion**

Targets the Oracle-specific code *surrounding* the database: **SQL scripts, stored procedure calls, loader control files, shell scripts, and Java files.** It consumes the **coding notes from schema conversion as input**, so converted application code lines up with the object names, types, and calling conventions schema conversion actually produced.

You can convert database-related application code inside the extension, or hand the work to the **GitHub Copilot app modernization extension** for a full modernization pass.

> ⚠️ **Sequence matters — do not invert it.** Application conversion depends on the coding notes and converted object names schema conversion generates. Converting application code before the schema settles produces code targeting objects that may still change. **If you rerun schema conversion after changing schema scope or fixing a source object, review the application code again against the updated coding notes.**

### 1.3 Prerequisites — verify before the workshop or the engagement

- [ ] **Visual Studio Code** installed
- [ ] **PostgreSQL extension** installed — publisher **Microsoft**, ID `ms-ossdata.vscode-pgsql` (several PostgreSQL extensions exist in the Marketplace; verify the publisher)
- [ ] Access to the **Oracle source** with read permissions for schema extraction
- [ ] An **Azure Database for PostgreSQL flexible server** to use as the **scratch validation database**
- [ ] A **Microsoft Foundry resource with a deployed `gpt-5.2` model** — you need the endpoint URL and either an API key or a Microsoft Entra ID account with access
- [ ] **x64 workstation** — see the platform limitation below

> ⚠️ **Scratch database constraint:** schema conversion **does not support Azure HorizonDB as the scratch database.** Use a flexible server.
>
> ⚠️ **Platform limitation: ARM64 is not supported** on Windows or Linux. Provision x64 hardware for the conversion team — this catches people out late.

**If the Migrations view doesn't appear in the sidebar:** the `pgsql.enableMigrations` setting controls the Migrations view and all migration commands. It is **enabled by default**; open VS Code settings (`Ctrl+,` / `Cmd+,`) and confirm it is `true`.

### 1.4 Creating a migration project — the four-step wizard

1. **Project setup** — open the **Migrations** view in the sidebar. Start a project via **+ Create Migration Project**, the **+** toolbar button, or by right-clicking a workspace folder in Explorer → **Open Migration Project**. Name the project, then **Next: Oracle Connection**.
2. **Connect to Oracle** — source credentials; load the schemas to convert.
3. **Connect to PostgreSQL** — the flexible server hosting the scratch schemas.
4. **Configure the AI endpoint** — the Microsoft Foundry endpoint and key.

The wizard collects source, target, and AI configuration before creating the project workspace; from there the dashboard drives extraction → conversion → export → review.

### 1.5 How this reshapes the pre-migration phase

| Traditional approach | With the VS Code extension |
|---|---|
| Ora2Pg `SHOW_REPORT` estimate, manual interpretation | Per-object conversion report with measured success rate |
| Converted DDL is a best guess until you try to deploy it | Objects **compiled against a scratch database before output** |
| Unconvertible objects discovered at deploy time | Flagged up front as **review tasks** |
| Application remediation scoped by guesswork | **Coding notes** enumerate the Oracle patterns actually present |
| Schema and application converted by separate teams, out of sync | Application pass consumes schema-pass output by design |

**Where Ora2Pg still earns its place:** as a fast, zero-setup **first-pass sizing signal** before you stand up Foundry and a scratch server — particularly for portfolio-level triage across many schemas. Use it to rank and scope; use the extension to produce the authoritative gap list. **Do not blend effort estimates from both tools into one number.**

### 1.6 Extension resources

- **Learn docs (migration tooling):** https://aka.ms/pg-migration-tooling
- **VS Code Marketplace page:** https://aka.ms/pgsql-vscode
- **Oracle migration blog:** https://aka.ms/pg-blog-orcl
- **Oracle to PostgreSQL migration (full workflow doc):** https://learn.microsoft.com/en-us/azure/postgresql/development/vs-code-extension/oracle-migration
- **Related session — Java apps:** *Migrate Java Apps from Oracle to Postgres with the VS Code PostgreSQL Extension* (Microsoft for Java Developers)
- **Deeper technical session:** *AI-assisted migration: The path to powerful performance on PostgreSQL* — BRK123, Microsoft Ignite

---

## 2. Stage 1 — Discovery

**Goal:** an accurate, current inventory. You cannot scope what you have not counted.

### 2.1 What to inventory

- Every Oracle instance: host, version, edition (SE2 / EE), patch level, options in use (Partitioning, Advanced Security, Spatial, RAC, Active Data Guard, In-Memory).
- Every database/schema, with object counts by type and status (including **INVALID** objects).
- Raw data size per schema and per table.
- **Lines of PL/SQL code** per package, procedure, function, trigger — the best early predictor of effort.
- Every dependent application, batch job, ETL feed, report, and integration.
- Licensing position and renewal dates (often the business driver and the deadline).

### 2.2 Tooling

- **Microsoft pre-assessment scripts for Oracle** — query Oracle metadata and produce a database inventory (object counts by schema/type/status), rough raw-data estimates per schema, table sizes, and lines of code per program unit. Available from the Microsoft DataMigrationTeam GitHub repository.
- **Ora2Pg** in report mode for first-pass triage (§3.3).
- **VS Code PostgreSQL extension** — its extraction phase catalogs objects and dependencies, which doubles as discovery validation once you reach Stage 2.

### 2.3 Gather statistics first

Assessment and export accuracy depend on current Oracle statistics. Run before any assessment:

```sql
BEGIN
  DBMS_STATS.GATHER_SCHEMA_STATS('APP_SCHEMA');
  DBMS_STATS.GATHER_DATABASE_STATS;
  DBMS_STATS.GATHER_DICTIONARY_STATS;
END;
/
```

### 2.4 The dependency question nobody asks early enough

Inventory what connects **to** the database, not just the database. The extension's application-conversion pass covers SQL scripts, stored procedure calls, loader control files, shell scripts, and Java — so this inventory directly scopes Pass 2:

- [ ] Application code — which frameworks, which drivers (OCI, JDBC thin, ODP.NET)?
- [ ] Embedded SQL with Oracle-specific syntax (`CONNECT BY`, `DECODE`, `NVL`, `ROWNUM`, `(+)` joins, `MERGE`, hints)
- [ ] SQL*Loader control files and shell wrappers
- [ ] Database links to/from other Oracle systems
- [ ] Oracle Forms / APEX / Reports
- [ ] Scheduled jobs (`DBMS_SCHEDULER`, cron calling `sqlplus`)
- [ ] ETL and BI tools with Oracle-native connectors
- [ ] Monitoring, backup, and audit tooling bound to Oracle
- [ ] Downstream replication consumers (GoldenGate targets, CDC feeds)

> **Field observation:** the most common schedule-killer is not PL/SQL — it is an undiscovered downstream consumer that surfaces two weeks before cutover.

### Discovery exit checklist

- [ ] Instance and database inventory complete and dated
- [ ] Object counts by type and status, per schema
- [ ] PL/SQL line counts per program unit
- [ ] Data sizes per schema and largest-table list
- [ ] Application/integration dependency map with a named owner per item
- [ ] Oracle statistics refreshed
- [ ] Migration scope agreed: which schemas are **in**, which are explicitly **out**
- [ ] Extension prerequisites provisioned (x64 workstation, scratch flexible server, Foundry `gpt-5.2` deployment)

---

## 3. Stage 2 — Assessment

**Goal:** turn the inventory into a complexity rating, an effort estimate, a target design, and a gap list.

### 3.1 Four assessments, not one

Run all four. Skipping any one is where estimates go wrong.

| Assessment | What it produces | Source |
|---|---|---|
| **Schema/code complexity** | Conversion effort, difficulty rating | Extension conversion report (authoritative); Ora2Pg for triage |
| **Data size and scale** | Time to move data; migration method choice | Inventory + test load |
| **Target resource sizing** | Compute, memory, IOPS, storage, network | Oracle AWR/Statspack |
| **Client application scope** | Application code that must change, and who owns it | Dependency map + **coding notes** |

> ⚠️ **Do not mix outputs from different assessment tools into one estimate.** Each tool has its own cost model and units; interpolating between them produces numbers you cannot defend.

### 3.2 Run the extension's conversion as your assessment

The most accurate assessment is a **real conversion run against a scratch database**. Because the extension compiles converted objects before writing them out, the report tells you what genuinely works — not what a heuristic predicts.

Read the conversion report for:

1. **Overall success rate** — the headline number for the steering committee.
2. **Objects skipped** — scope questions and out-of-scope confirmations.
3. **Review tasks** — your real backlog; triage per §4.4.
4. **Coding notes** — the Oracle patterns present in *this* schema, which scope application remediation.

**The per-object report from your own conversion run is authoritative for your schema.** Generic complexity tables are a starting point; an individual object can still need attention when it uses a construct that does not convert — a function calling a Java routine, for example.

### 3.3 Ora2Pg — first-pass triage

Still useful before Foundry and a scratch server exist, especially across a large portfolio:

```ini
# ora2pg.conf (assessment)
ORACLE_DSN       dbi:Oracle:host=oracle-host;sid=ORCL;port=1521
ORACLE_USER      migration_user
ORACLE_PWD       ********
SCHEMA           APP_SCHEMA
TYPE             SHOW_REPORT
PG_VERSION       16
OUTPUT_DIR       /migration/ora2pg_output
COST_UNIT_VALUE  5
```

```bash
ora2pg -c ora2pg.conf -t SHOW_REPORT --estimate_cost
```

Objects are rated roughly **A (trivial) → B (moderate) → C (complex)**; most Oracle → PostgreSQL migrations land in **B–C** because of PL/SQL volume. Treat the estimated hours as a *relative* sizing signal across schemas, not a project plan.

### 3.4 Known conversion gaps to flag during assessment

Surface these so they become planned work, not cutover surprises:

| Oracle construct | Behavior on conversion | Plan for it |
|---|---|---|
| **Packages / package bodies** | PostgreSQL has no packages. Package state maps to session variables — state persisting across calls does **not** behave like an Oracle package instance. | Decompose into schema-scoped functions; test shared-state behavior explicitly. |
| **`PRAGMA AUTONOMOUS_TRANSACTION`** | Routed through **dblink** — commits independently of the caller and is **not** rolled back if the caller fails. Largest single cause of placeholder output. | **Install `dblink` on the target before converting.** Review each routine; bodies that are not a simple INSERT+COMMIT, or that contain exception handlers or `MERGE`, need manual review. |
| **Wrapped PL/SQL** | Body cannot be read — always produces a placeholder. | Supply the original unwrapped source and convert again. |
| **Java in the database** (Java source/class/stored procedure) | Not extracted. Azure PostgreSQL flexible server cannot run Java in the database. | Rewrite in PL/pgSQL or move to the application layer. |
| **External C libraries (`CREATE LIBRARY`)** | Not extracted. | Rewrite in PL/pgSQL or move to the application layer. |
| **Type bodies** | Not extracted. | Reimplement object-type methods as PostgreSQL functions. |
| **System-event triggers** | Only `LOGON`/`LOGOFF` are recognized. `STARTUP`, `SHUTDOWN`, `SERVERERROR` can pass through and produce non-working output. | Reimplement that logic outside the database. |
| **Cross-edition triggers / EBR** | Edition-based redefinition is not detected; converts to an ordinary trigger that fires for **every** session. | Convert a single edition; handle rollout in the release process. |
| **Transaction control (`ROLLBACK TO SAVEPOINT`)** | Does not always convert cleanly. | Review and rework. |
| **Oracle system schemas** (`SYS`, `SYSTEM`, `XDB`, `MDSYS`, `CTXSYS`, `WMSYS`) | Not extracted or converted. | Out of scope by design — confirm nothing application-critical lives there. |

**Placeholder output — understand this behavior:** when an object cannot be converted, the tool emits **best-effort or placeholder DDL** preserving the original name and signature so dependent objects still convert and deploy. A placeholder is **not functional**, is flagged as a review task, and objects depending on it may be held back from the generated deployment script. **One unconverted routine can therefore affect several other objects** — triage placeholders early, not at the end.

### 3.5 Data type mapping — the quiet data-loss risk

Numeric, date/time, and text types are where data is silently lost, truncated, or mangled. Decide mappings deliberately and document them — and verify the converted DDL against this table rather than assuming:

| Oracle | Common PostgreSQL choice | Watch out for |
|---|---|---|
| `NUMBER` (no precision) | `numeric` | Unbounded `numeric` is slow. Where scale is known, map to `integer`/`bigint`/`numeric(p,s)` — a large win for performance and storage. |
| `NUMBER(p,0)` | `smallint` / `integer` / `bigint` by range | Pick the smallest type that fits the real domain. |
| `VARCHAR2(n)` | `varchar(n)` or `text` | Oracle byte vs. char semantics (`NLS_LENGTH_SEMANTICS`) — a multibyte `VARCHAR2(10 BYTE)` is not `varchar(10)`. |
| `DATE` | `timestamp` (not `date`) | **Oracle `DATE` carries a time component; PostgreSQL `date` does not.** Mapping to `date` silently drops the time. |
| `TIMESTAMP WITH LOCAL TIME ZONE` | `timestamptz` | Semantics differ — validate with real data. |
| `CLOB` / `BLOB` | `text` / `bytea` | Size limits and driver streaming behavior differ. |
| `RAW` / `LONG RAW` | `bytea` | `LONG` types should be remediated on the Oracle side first where possible. |
| `ROWID` / `UROWID` | `ctid` is **not** an equivalent | Any application logic depending on ROWID must be redesigned. |
| Empty string | `''` ≠ `NULL` in PostgreSQL | **Oracle treats `''` as `NULL`; PostgreSQL does not.** This changes query results and constraint behavior. Test explicitly — one of the highest-impact semantic differences. |

### 3.6 Semantic and behavioral differences to test for

Conversion tooling handles syntax. **These are behavior**, and behavior is validated by tests, not by a compiler:

- **Empty string vs NULL** (above) — highest-impact difference in practice.
- **Case folding:** unquoted identifiers fold to **upper** in Oracle, **lower** in PostgreSQL. Quoted mixed-case identifiers create permanent friction — avoid them.
- **Default sort order:** collation differences change `ORDER BY` results and index behavior.
- **Sequences and identity:** `NEXTVAL` semantics, caching, and gap behavior differ.
- **Hierarchical queries:** `CONNECT BY` → recursive CTE (`WITH RECURSIVE`).
- **Built-ins:** `DECODE` → `CASE`, `NVL` → `COALESCE`, `ROWNUM` → `LIMIT`/window functions, `SYSDATE` → `now()`/`clock_timestamp()`.
- **Outer joins:** `(+)` syntax → ANSI `LEFT JOIN`.
- **Transaction semantics:** no native autonomous transactions; different default isolation behavior; PostgreSQL DDL is transactional (a genuine advantage — use it).
- **MVCC and vacuum:** no rollback segments. `autovacuum` and bloat management replace them — a new operational discipline for the DBA team.
- **Optimizer hints:** PostgreSQL has no Oracle-style hints. Plan stability comes from statistics, indexing, and configuration.

### 3.7 Target sizing and platform decisions

Size the flexible server from measured Oracle workload data (AWR/Statspack), not from the existing Oracle host spec — you are not buying the same hardware.

- [ ] Compute tier and vCores from actual CPU utilization, not provisioned
- [ ] Storage size **and IOPS** — IOPS is frequently the real constraint
- [ ] PostgreSQL major version (confirm before converting; you **cannot** migrate to an earlier version later)
- [ ] Region, and **paired region** if DR is required
- [ ] **HA model: zone-redundant vs same-zone** — decide now, it drives backup redundancy defaults
- [ ] **Backup redundancy: LRS / ZRS / geo-redundant — GRS is a create-time-only decision and cannot be added later**
- [ ] Backup retention (7–35 days) and whether vaulted LTR is required for compliance
- [ ] Networking: private access (VNet) vs public with firewall; private DNS zone
- [ ] Required **extensions** — verify each is on the Azure supported-extensions list **before** designing around it
- [ ] Connection pooling (PgBouncer) — Oracle apps often open far more connections than PostgreSQL likes
- [ ] Read replicas for reporting workloads that used Active Data Guard
- [ ] **A separate scratch flexible server for conversion validation** (not the production target; not HorizonDB)

> ⚠️ **Sizing for migration vs. sizing for steady state are different.** Migrate onto a **higher SKU** to shorten the copy and index-rebuild window, then scale down — near-zero-downtime compute and IOPS scaling makes this cheap. Avoid Burstable SKUs for the migration itself.

### 3.8 Platform constraints to design around

Confirm against current documentation for your target version, and reflect in the design:

- **No superuser.** Anything requiring superuser privileges must be redesigned.
- **No custom tablespaces** — data lands in the default tablespace. Any Oracle tablespace-based storage strategy must be replaced (partitioning, separate servers, or storage tiering).
- **Unsupported extensions cannot be moved** — check the supported-extensions list early.
- **User-defined collations** are not migratable.
- **Migration service caveats:** one active migration or validation per flexible server; user databases only; **no object-level (single table or schema) migration**; requires `sslmode` of `preferred` or `required`; no downgrade to an earlier PostgreSQL version. **Verify data and objects on the target manually after migration** — the service reports tables copied, not correctness.

### Assessment exit checklist

- [ ] Extension conversion run completed against a scratch database
- [ ] Conversion report reviewed: success rate, skipped objects, review tasks, coding notes
- [ ] All four assessments complete, from a consistent toolset
- [ ] Complexity rating and effort estimate per schema
- [ ] Gap list: unsupported objects, placeholders, manual-rework items — each with an owner
- [ ] Data type mapping document reviewed and signed off against the converted DDL
- [ ] Target design: SKU, storage, IOPS, version, HA, **backup redundancy**, networking, extensions
- [ ] Application remediation scope agreed with application owners, informed by coding notes
- [ ] Migration method chosen: **offline** (planned downtime) vs **online/CDC** (near-zero downtime)

---

## 4. Stage 3 — Convert (and prove it deploys)

**Goal:** converted schema and code that deploys cleanly to a real Azure PostgreSQL flexible server — before any production data moves.

### 4.1 Prepare the target before converting

- [ ] **Install `dblink` on the target before conversion** if any routine uses `PRAGMA AUTONOMOUS_TRANSACTION` — otherwise those routines fall back to placeholder output. *(This is the highest-value pre-conversion action on this list.)*
- [ ] Stand up the **scratch flexible server** the extension validates against
- [ ] Confirm all required extensions are installed and allow-listed
- [ ] Establish the role/privilege model (no superuser) before deploying objects
- [ ] Confirm the Foundry `gpt-5.2` deployment is reachable from the workstation

### 4.2 Run the two passes in order

1. **Schema conversion** → object-level `.sql` files, conversion report, review tasks, coding notes.
2. Resolve review tasks; redeploy to scratch; **rerun until the report is clean or every exception is formally accepted**.
3. **Application conversion** → using the *final* coding notes, not an earlier run's.
4. Optionally hand broader modernization to the **GitHub Copilot app modernization extension**.

> If schema scope changes or a source object is fixed after Pass 2 has run, **re-review the application code against the updated coding notes.** Treat this as a formal gate, not a judgment call.

**Review everything the tool emits.** Automated conversion — AI-assisted and scratch-validated included — is a verified starting point, not a signed-off result. Use the side-by-side file diff (demoed at 12:17 in the Azure Friday session) as the review mechanism.

### 4.3 Load order and performance practices

- Export data with **`COPY`, not `INSERT`**.
- **Do not export tables together with their foreign keys, constraints, and indexes** — these slow the import dramatically. Load data first, then create indexes and constraints.
- Create **materialized views with the `NO DATA` clause**, refresh later. Use **unique indexes** on materialized views so `REFRESH MATERIALIZED VIEW CONCURRENTLY` is available.
- Run `ANALYZE` after load, before any performance measurement.

### 4.4 Triage review tasks

Sort flagged objects into three buckets and assign owners:

1. **Mechanical** — syntax-level fixes; batch them.
2. **Semantic** — behavior differs (package state, autonomous transactions, empty-string/NULL). Requires a decision and a test, not just an edit.
3. **Redesign** — Java, external libraries, type bodies, EBR, ROWID logic. These belong in the application backlog, and they drive the schedule.

### Convert exit checklist

- [ ] Schema pass complete; converted schema deploys to a clean flexible server with **zero errors**
- [ ] Every placeholder resolved or formally accepted with a documented workaround
- [ ] Objects held back due to placeholder dependencies identified and re-deployed
- [ ] Application pass run against the **final** coding notes
- [ ] Row counts, constraints, indexes, sequences verified against source
- [ ] Sequence current values reconciled
- [ ] Unit tests for converted PL/pgSQL pass
- [ ] Application connects and runs a smoke test against the converted schema

---

## 5. Stage 4 — Plan, prove, and prepare to cut over

### 5.1 Choose the migration method deliberately

| Method | Downtime | Use when |
|---|---|---|
| **Offline** | Planned outage, mark source read-only, copy, cut over | Downtime window is acceptable; simplest and most predictable |
| **Online / CDC** | Near-zero | 24×7 workload; requires a CDC/replication tool supporting Oracle → PostgreSQL, plus additional cost and complexity |

Pick based on the business's real tolerance, not aspiration. Offline is dramatically simpler; many workloads can absorb a weekend window.

### 5.2 Establish a performance baseline **before** you migrate

You cannot prove the target is acceptable without a measured "before". Capture from Oracle:

- Top N queries by elapsed time, executions, and logical reads (AWR/Statspack)
- Peak and average CPU, memory, IOPS, and concurrent sessions
- Batch window durations
- Business-critical transaction response times with agreed SLA thresholds

Define acceptance criteria in advance: *"These 20 transactions must complete within X ms at Y concurrency."* Without this, "is it fast enough?" becomes an unwinnable argument at cutover.

### 5.3 Set up the target's operational posture before go-live

The migration is not done when the data lands. Have these configured and **tested** first:

- [ ] Backup retention set (7–35 days) and **redundancy chosen at creation**
- [ ] Vaulted / long-term retention configured if compliance requires > 35 days
- [ ] **A point-in-time restore rehearsed and the RTO measured and documented** *(see the Backup/Restore/PITR workshop — Lab 1)*
- [ ] HA enabled and failover tested
- [ ] Read replicas created if required
- [ ] Monitoring, alerting, diagnostic settings, Defender for Cloud
- [ ] `autovacuum` tuning reviewed for the largest/hottest tables
- [ ] Connection pooling configured and load-tested
- [ ] Maintenance window chosen deliberately
- [ ] Runbooks rewritten for PostgreSQL — the Oracle ones do not transfer

### 5.4 Rollback plan

Every cutover needs a defined, tested way back:

- [ ] Explicit **rollback trigger criteria** agreed in advance (not decided under pressure at 3am)
- [ ] Oracle source retained read-only for a defined period — do not decommission on cutover day
- [ ] Reverse-sync strategy if writes have already landed in PostgreSQL
- [ ] Rollback decision owner named, with authority to call it
- [ ] Communication plan for the business

### 5.5 Rehearse

Run at least one **full dress rehearsal** on production-sized data before the real cutover. Measure each step and build the actual runbook timings from that rehearsal. A rehearsal never done at full scale is an estimate, not a plan.

---

## 6. Pre-migration master checklist

**Tooling readiness**
- [ ] VS Code + PostgreSQL extension (publisher Microsoft, `ms-ossdata.vscode-pgsql`) installed
- [ ] **x64** workstation confirmed (ARM64 unsupported)
- [ ] Oracle source read access for schema extraction
- [ ] Scratch **flexible server** provisioned (not HorizonDB)
- [ ] Microsoft Foundry resource with deployed **`gpt-5.2`** model; endpoint + key or Entra ID access
- [ ] `pgsql.enableMigrations` confirmed `true`; Migrations view visible
- [ ] Team has watched the Azure Friday session (§1)

**Discovery**
- [ ] Instance/database inventory complete and dated
- [ ] Object counts by type and status; invalid objects identified
- [ ] PL/SQL line counts per program unit
- [ ] Data sizes per schema; largest tables listed
- [ ] Oracle statistics gathered
- [ ] Full application/integration dependency map with named owners
- [ ] Scope agreed: in / out

**Assessment**
- [ ] Extension conversion run completed; report reviewed end to end
- [ ] Review tasks triaged into mechanical / semantic / redesign with owners
- [ ] Coding notes used to scope application remediation
- [ ] Ora2Pg `SHOW_REPORT` (optional first-pass triage) — **not blended** into the extension's estimate
- [ ] Data type mapping document signed off against converted DDL
- [ ] Unsupported-object list with disposition per item
- [ ] Target SKU, storage, IOPS, version, HA, **backup redundancy** decided
- [ ] Extension compatibility verified
- [ ] Offline vs online method chosen

**Convert**
- [ ] `dblink` installed on target **before** conversion (if autonomous transactions exist)
- [ ] Schema pass clean against scratch database
- [ ] Placeholders resolved or formally accepted
- [ ] Application pass run against final coding notes
- [ ] Load strategy set: `COPY`, constraints/indexes after data, matviews `NO DATA`
- [ ] Converted schema deploys error-free to the target

**Plan & prove**
- [ ] Performance baseline captured from Oracle
- [ ] Acceptance criteria defined and agreed
- [ ] Target operational posture configured (backup, HA, monitoring, pooling, autovacuum)
- [ ] **PITR rehearsed; RTO measured and published**
- [ ] Rollback plan documented, owned, and tested
- [ ] Full-scale dress rehearsal completed; runbook timings derived from it
- [ ] Cutover runbook approved with named owners per step

---

## 7. Top 10 pre-migration mistakes

1. **Estimating from data volume instead of code volume.** PL/SQL lines, not gigabytes, drive the schedule.
2. **Running application conversion before schema conversion settles.** The coding notes are the contract between the two passes — invert the order and you convert against object names that still change.
3. **Skipping the application assessment entirely.** The database can be perfect and the project still fails.
4. **Mixing estimates from different assessment tools.** The numbers are not interchangeable.
5. **Mapping Oracle `DATE` to PostgreSQL `date`.** Silently drops the time component.
6. **Mapping every `NUMBER` to unbounded `numeric`.** Correct but slow; a major, avoidable performance regression.
7. **Not testing empty-string vs NULL.** Oracle treats `''` as NULL; PostgreSQL does not. Query results change — and no compiler catches it.
8. **Not installing `dblink` before conversion.** Turns every autonomous-transaction routine into a placeholder and inflates the review backlog for no reason.
9. **Not deciding geo-redundant backup at server creation.** It cannot be added later — a permanent, irreversible design decision.
10. **No rehearsed rollback.** An untested rollback is a hypothesis, exactly like an untested backup.

---

## 8. Reference documentation

**Product Group tooling**
- Azure Friday — *Migrate Oracle Workloads to PostgreSQL Using AI-Powered Tools in the VS Code PostgreSQL Extension* (Scott Hanselman with Jonathon Frost): https://www.youtube.com/watch?v=4X6sw5sWdqc · https://learn.microsoft.com/en-us/shows/azure-friday/migrate-oracle-workloads-to-postgresql-using-ai-powered-tools
- Oracle to PostgreSQL migration — VS Code extension workflow: https://learn.microsoft.com/en-us/azure/postgresql/development/vs-code-extension/oracle-migration
- Migration tooling docs: https://aka.ms/pg-migration-tooling
- VS Code Marketplace page: https://aka.ms/pgsql-vscode
- Oracle migration blog: https://aka.ms/pg-blog-orcl
- Schema conversion overview: https://learn.microsoft.com/en-us/azure/postgresql/migrate/oracle-conversions-schema/schema-conversions-overview
- Schema conversion limitations: https://learn.microsoft.com/en-us/azure/postgresql/migrate/oracle-conversions-schema/schema-conversions-limitations

**Migration guidance**
- Migrating Oracle to Azure Database for PostgreSQL flexible server: https://learn.microsoft.com/en-us/azure/postgresql/migrate/oracle-migration/concepts-oracle-migration
- Oracle migration stages: https://learn.microsoft.com/en-us/azure/postgresql/migrate/oracle-migration/concepts-oracle-migration-stages
- Ora2Pg migration guide: https://learn.microsoft.com/en-us/azure/postgresql/migrate/how-to-migrate-oracle-ora2pg
- Migration service known issues and limitations: https://learn.microsoft.com/en-us/azure/postgresql/migrate/migration-service/concepts-known-issues-migration-service
- Oracle to Azure PostgreSQL Migration Playbook (PDF): https://download.microsoft.com/download/8/f/c/8fc4fe39-7cb1-484a-aaa0-418704b90c0e/Oracle%20to%20Azure%20Postgres%20Migration%20Playbook.pdf
- Oracle to Azure PostgreSQL Migration Cookbook (PDF): https://raw.githubusercontent.com/microsoft/DataMigrationTeam/master/Whitepapers/Oracle%20to%20Azure%20PostgreSQL%20Migration%20Cookbook.pdf

**Operations**
- Backup and restore concepts: https://learn.microsoft.com/en-us/azure/postgresql/backup-restore/concepts-backup-restore
