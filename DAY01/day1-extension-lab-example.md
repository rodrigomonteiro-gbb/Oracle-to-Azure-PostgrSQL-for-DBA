# Day 1 Lab Example - Extension Management for Oracle DBAs

## Lab theme

**Question:** Before I say yes to an extension in production, what do I need to know?

This lab is designed for Oracle DBAs moving to Azure Database for PostgreSQL Flexible Server. It teaches extension management as an **operational decision**, not just a feature demo.

---

## What attendees should leave with

By the end of this lab, attendees should be able to:

- classify an extension as **installed**, **available**, **restart-required**, or **unavailable**
- explain what Oracle-style operational question an extension answers
- identify whether enabling it requires only database DDL or also a server restart
- identify who can enable it in production
- describe rollback, upgrade, and supportability implications
- decide whether a missing extension is a workaround, a redesign, or a migration blocker

---

## Suggested lab duration

- **Core lab:** 20-25 minutes
- **Optional discussion / advanced variation:** 10-15 minutes

---

## Lab structure

1. Inventory and classify extensions
2. Enable one practical extension end to end
3. Assess operational impact
4. Decide whether the extension is a migration dependency
5. Capture the result in a reusable worksheet

---

## Lab prerequisites

Attendees should already have:

- an Azure Database for PostgreSQL Flexible Server environment
- access to `psql`
- a role with enough privilege to inspect extensions
- a user with `azure_pg_admin` membership for enable/disable steps
- the `orders_demo` database from earlier labs

---

## Part 1 - Inventory and classify

### Objective

Separate four states clearly:

- installed in this database
- available for this server version
- requires preload/restart
- unavailable on this platform

### Commands

```sql
-- Installed in the current database
\dx
```

```sql
-- Everything available for this PostgreSQL version on this server
SELECT name, default_version, installed_version, comment
FROM pg_available_extensions
ORDER BY name;
```

```sql
-- Installed extensions only, with versions
SELECT extname, extversion
FROM pg_extension
ORDER BY extname;
```

### Discussion prompts

Ask attendees to answer out loud (Think Out loud always):

- Which extensions are already installed here?
- Which are available but not yet enabled?
- Which business need would require checking the allow-list before promising anything?
- Is there anything here they expected to see but do not?

---

## Part 2 - Enable one practical extension end to end

### Suggested first example: `pg_stat_statements`

Why this is the right first example:

- Oracle DBAs instantly recognize the **top SQL / expensive SQL** question
- it bridges Day 1 into diagnostics and Day 2 into tuning
- it introduces the preload/restart concept clearly

### Step 1 - Check whether preload is already configured

```sql
SHOW shared_preload_libraries;
```

If `pg_stat_statements` is not already enabled at the server level, the administrator enables it with the Azure parameter path.

### Azure CLI example

```bash
az postgres flexible-server parameter set \
  --resource-group <resource-group> \
  --server-name <server-name> \
  --name azure.extensions \
  --value PG_STAT_STATEMENTS
```

### Restart note

Some environments may require a restart after changing preload-related configuration. That must be treated as a **change event**, not as a free action.

### Step 2 - Create the extension in the target database

```sql
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
```

### Step 3 - Confirm it exists

```sql
\dx
```

```sql
SELECT extname, extversion
FROM pg_extension
WHERE extname = 'pg_stat_statements';
```

### Step 4 - Use it to answer a real DBA question

```sql
SELECT query,
       calls,
       total_exec_time,
       mean_exec_time,
       rows
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 10;
```

### Discussion prompts

Ask attendees:

- What Oracle operational question does this answer?
- Did this require only database DDL, or also server-level change?
- Who should be allowed to enable this in production?
- Would you enable this by default on a production server? Why?

---

## Part 3 - Assess operational impact like a production DBA

### Objective

Move beyond syntax. Treat extension enablement as a production decision.

### Questions to answer

For the extension just enabled, attendees should record:

- What operational problem does it solve?
- Does it require restart?
- Does it introduce overhead?
- Does it change upgrade planning?
- Does it change backup / restore assumptions?
- Can an application team self-manage it?
- What would rollback mean?

### Example prompt text

> `pg_stat_statements` is not just a feature. It changes what evidence is available to the DBA team and may require platform-level enablement. That makes it both an observability decision and an operations decision.

---

## Part 4 - Decide whether the extension is a migration dependency

### Objective

Teach attendees to classify dependency risk early.

### Example capability mapping exercise

Ask attendees where each requirement lands:

| Requirement | Likely answer |
|---|---|
| Top SQL history | `pg_stat_statements` and Query Store |
| Scheduler-like behavior | `pg_cron` if supported, otherwise Azure-native scheduling |
| Spatial support | `PostGIS` if supported |
| Text similarity / trigram search | `pg_trgm` |
| Custom package logic | schema-scoped functions / PL/pgSQL |
| Custom host-level component | likely redesign or unsupported in managed service |

### Discussion prompts

For each item, ask:

- Is this core PostgreSQL, an extension, an Azure service, or a redesign?
- If it is missing, is that a workaround, a migration blocker, or a design-change item?
- At what phase should this be discovered?

---

## Part 5 - Rollback, versioning, and lifecycle

### Objective

Teach the questions Oracle DBAs ask after the feature demo.

### Rollback example

```sql
DROP EXTENSION IF EXISTS pg_stat_statements;
```

### Important discussion point

Dropping an extension is **not always the same as undoing everything**:

- dependent objects may be removed
- preload configuration may still remain
- support or monitoring expectations may already have changed

### Version check

```sql
SELECT extname, extversion
FROM pg_extension
ORDER BY extname;
```

### Discussion prompts

Ask attendees:

- Is extension versioning the same thing as PostgreSQL major version? No.
- Could an extension delay or complicate a future upgrade? Yes.
- Should extension inventory be part of migration assessment? Absolutely.

---

## Reusable extension decision worksheet

Attendees can copy this table into their runbook or migration backlog.

| Extension / capability | Installed now | Available here | Needs restart | Required privilege | Operational purpose | Support / upgrade risk | Migration blocker if missing |
|---|---|---|---|---|---|---|---|
| pg_stat_statements |  |  |  |  |  |  |  |
| pg_cron |  |  |  |  |  |  |  |
| postgis |  |  |  |  |  |  |  |
| pg_trgm |  |  |  |  |  |  |  |
| custom requirement |  |  |  |  |  |  |  |

---

## Instructor prompts

These questions usually create the best Oracle DBA discussion:

1. Is this more like an Oracle option, a package, or a plugin?
2. Is it already installed, only available, or unavailable here?
3. Does enabling it require restart?
4. Who can enable it in production?
5. What changes operationally if we enable it?
6. What does rollback actually mean?
7. Does it create upgrade or supportability risk?
8. If it is missing, is that a workaround, a redesign, or a migration blocker?

---

## Suggested “what good looks like” criteria

Attendees should be able to:

- name one extension that answers a real DBA question
- distinguish **installed** from **available**
- identify whether an extension requires restart
- state who owns the enablement decision
- explain why unsupported extensions must be caught before cutover
- fill in the decision worksheet for at least three capabilities

---

## Optional advanced variation

If time allows, add a second extension and compare it with `pg_stat_statements`:

- `pg_trgm` for text-search or similarity use cases
- `pg_cron` for scheduler-style discussion
- `postgis` for spatial workloads if relevant to the audience

Ask the room to compare:

- observability value
- privilege requirements
- restart requirement
- migration criticality
- operational risk

---

## What this lab answers - and what comes next

This lab is designed to answer the **first production questions** a DBA should ask before saying yes to an extension:

- is it supported here?
- is it already installed, only available, or unavailable?
- does it require restart?
- who can enable it?
- what changes operationally if we enable it?
- is it a migration blocker if missing?

It is **not** meant to exhaust every deep extension engineering question on Day 1. Senior DBA follow-up questions usually include:

- how extension compatibility affects major version upgrades
- which extensions should be safe production defaults
- what the supportability difference is between common and niche extensions
- when an extension requirement should become application redesign or Azure-service design
- how extension lifecycle should be governed in production

## Suggested closing line

**An extension is never just a feature choice. On a managed PostgreSQL service, it is also a support, upgrade, and migration decision.**
