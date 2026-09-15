# Session 1H: Extension Management [LAB]

## Lab Goal

Understand PostgreSQL extensions and apply the Azure Flexible Server sequence: allow the extension, preload it when required, restart when required, and create it in the target database.

## What Is an Extension?

An extension packages SQL objects and, where supported by the service, native functionality as one managed unit. Extensions can add data types, functions, index operator classes, monitoring collectors, schedulers, and complete feature sets.

On Azure Database for PostgreSQL Flexible Server, administrators select from a curated list. They do not install arbitrary operating-system packages on the managed server.

## Why Some Extensions Need To Be Enabled First

On self-managed PostgreSQL, a DBA may be used to installing extension packages directly on the host and then running `CREATE EXTENSION`. On Azure Database for PostgreSQL Flexible Server, the operating system and extension binaries are managed by Azure, so the DBA uses supported control-plane settings instead.

There are three separate ideas:

| Step | Why it exists | Workshop example |
| --- | --- | --- |
| Allow-list in `azure.extensions` | Azure must expose the extension as supported for that server before a database can create it. This is a managed-service supportability and safety boundary. | `pg_stat_statements`, `pg_trgm`, `uuid-ossp`, `pgcrypto`, `pgstattuple` |
| Preload in `shared_preload_libraries` | Some extensions hook into server startup, shared memory, or statement execution. They must be loaded when PostgreSQL starts, not after a session connects. | `pg_stat_statements` |
| `CREATE EXTENSION` in the database | The extension's SQL objects are created inside one database. Extensions are database-scoped, not automatically installed everywhere on the server. | Create in `adventureworks` |

That is why the safe sequence is:

> allow-list at the Azure server level -> preload and restart if required -> connect to the target database -> `CREATE EXTENSION`

If an extension only adds SQL functions, data types, or index operator classes, it usually does **not** need preload. If it collects server-wide execution statistics or hooks into query execution, it usually **does** need preload.

## The Azure Extension Workflow

### Step 1: Discover Available Extensions

Show the Azure allow-list setting:

```sql
SHOW azure.extensions;
```

Inspect PostgreSQL's extension catalog:

```sql
SELECT name, default_version, installed_version, comment
FROM pg_available_extensions
ORDER BY name;
```

List extensions installed in the current database:

```sql
SELECT extname, extversion
FROM pg_extension
ORDER BY extname;
```

Extensions are installed per database. Creating an extension in `postgres` does not automatically create it in `adventureworks`.

### Step 2: Allow the Extension

In the Azure portal:

1. Open the Flexible Server.
2. Select **Server parameters**.
3. Search for `azure.extensions`.
4. Select the required extension.
5. Save the parameter.

An extension absent from the allow-list cannot be created even if PostgreSQL knows its package name.

CLI equivalent, PowerShell:

```powershell
az postgres flexible-server parameter set `
  --resource-group <resource-group> `
  --server-name <server-name> `
  --name azure.extensions `
  --value "pg_stat_statements,pg_trgm,uuid-ossp,pgcrypto,pgstattuple"
```

CLI equivalent, Bash:

```bash
az postgres flexible-server parameter set \
  --resource-group <resource-group> \
  --server-name <server-name> \
  --name azure.extensions \
  --value "pg_stat_statements,pg_trgm,uuid-ossp,pgcrypto,pgstattuple"
```

Important: setting `azure.extensions` replaces the parameter value. Include every workshop extension that must remain allowed, not only the one you are adding.

Verify the allow-list from `psql`:

```sql
SHOW azure.extensions;
```

### Step 3: Preload When Required

Some extensions must initialize during server startup. Add those extensions to `shared_preload_libraries`, save the setting, and restart the server when prompted.

The workshop extension that requires preload is:

- `pg_stat_statements`

Extensions such as `pg_trgm`, `uuid-ossp`, `pgcrypto`, and `pgstattuple` do not require preload.

### Step 4: Create the Extension

Connect to the intended database:

```powershell
psql -h <postgresql-fqdn> -U <pgadmin> -d adventureworks
```

Then create it:

```sql
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
```

Verify:

```sql
SELECT extname, extversion
FROM pg_extension
WHERE extname = 'pg_stat_statements';
```

## The Two Classic Errors

### Error 1: Extension Is Not Allowed

Typical cause: the extension was not selected in `azure.extensions`.

Resolution:

1. Add the extension to `azure.extensions`.
2. Save the server parameter.
3. Retry `CREATE EXTENSION` in the target database.

### Error 2: Extension Must Be Preloaded

Typical cause: the extension requires `shared_preload_libraries` but was created before preload and restart.

Resolution:

1. Add it to `shared_preload_libraries`.
2. Save and restart the Flexible Server.
3. Reconnect to the target database.
4. Run `CREATE EXTENSION` again.

The complete sequence is:

> Allow-list -> preload if required -> restart if required -> `CREATE EXTENSION` in each target database

## pg_stat_statements

This extension collects normalized, cumulative execution statistics.

```sql
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

SELECT calls,
ROUND(total_exec_time::numeric, 2) AS total_ms,
ROUND(mean_exec_time::numeric, 2) AS mean_ms,
LEFT(query, 120) AS query
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 10;
```

Azure setup also requires:

- `pg_stat_statements` selected in `azure.extensions`
- `pg_stat_statements` included in `shared_preload_libraries`
- `pg_stat_statements.track = all` so statements are collected; if this is `none`, `pg_stat_statements` can be installed and preloaded but still return zero rows

Important: `shared_preload_libraries` is a comma-separated server parameter. Do not remove existing Azure-managed entries when adding `pg_stat_statements`; append it to the current value if it is missing.

CLI setup, PowerShell:

```powershell
az postgres flexible-server parameter set `
  --resource-group <resource-group> `
  --server-name <server-name> `
  --name azure.extensions `
  --value "pg_stat_statements,pg_trgm,uuid-ossp,pgcrypto,pgstattuple"

az postgres flexible-server parameter set `
  --resource-group <resource-group> `
  --server-name <server-name> `
  --name shared_preload_libraries `
  --value "pg_cron,pg_stat_statements,azure,pg_qs,pgaadauth,pgms_stats,pgms_wait_sampling,pg_availability"

az postgres flexible-server parameter set `
  --resource-group <resource-group> `
  --server-name <server-name> `
  --name pg_stat_statements.track `
  --value "all"
```

CLI setup, Bash:

```bash
az postgres flexible-server parameter set \
  --resource-group <resource-group> \
  --server-name <server-name> \
  --name azure.extensions \
  --value "pg_stat_statements,pg_trgm,uuid-ossp,pgcrypto,pgstattuple"

az postgres flexible-server parameter set \
  --resource-group <resource-group> \
  --server-name <server-name> \
  --name shared_preload_libraries \
  --value "pg_cron,pg_stat_statements,azure,pg_qs,pgaadauth,pgms_stats,pgms_wait_sampling,pg_availability"

az postgres flexible-server parameter set \
  --resource-group <resource-group> \
  --server-name <server-name> \
  --name pg_stat_statements.track \
  --value "all"
```

Restart the Flexible Server if the portal or CLI reports that `shared_preload_libraries` requires it. Then reconnect to `adventureworks` and run `CREATE EXTENSION`.

If validation shows `pg_stat_statements.track = none`, fix that parameter first; no pgbench workload will appear while tracking is disabled.

### Generate pg_stat_statements Activity with pgbench

After `pg_stat_statements` is enabled and created in `adventureworks`, use `pgbench` with a short inline AdventureWorks workload to generate repeatable query activity.

Important: `pgbench` is not a SQL command. Run it from PowerShell or Bash, not from inside `psql`. The order is:

1. In `psql`, optionally reset `pg_stat_statements`.
2. Exit `psql` with `\q`.
3. In PowerShell or Bash, create the temporary `pgbench` script and run `pgbench`.
4. Reconnect with `psql` and inspect `pg_stat_statements`.

Optional reset before the `pgbench` run:

```sql
SELECT pg_stat_statements_reset();
```

If your prompt starts with `adventureworks=>` or `AdventureWorks=>`, exit `psql` before running `pgbench`:

```sql
\q
```

PowerShell:

```powershell
$PgBenchScript = Join-Path $env:TEMP "pgbench_adventureworks_pg_stat_statements.sql"

@'
\set status random(1, 5)
\set min_total random(100, 5000)
\set product_id random(700, 999)
\set territory_id random(1, 10)

SELECT h.salesorderid,
       h.customerid,
       h.orderdate,
       h.status,
       h.totaldue
FROM sales.salesorderheader h
WHERE h.status = :status
  AND h.totaldue >= :min_total
ORDER BY h.orderdate DESC
LIMIT 25;

SELECT d.productid,
       count(*) AS line_count,
       sum(d.linetotal) AS product_revenue
FROM sales.salesorderdetail d
JOIN sales.salesorderheader h
  ON h.salesorderid = d.salesorderid
WHERE d.productid = :product_id
GROUP BY d.productid;

SELECT c.territoryid,
       count(DISTINCT h.salesorderid) AS orders,
       sum(h.totaldue) AS revenue
FROM sales.customer c
JOIN sales.salesorderheader h
  ON h.customerid = c.customerid
WHERE c.territoryid = :territory_id
GROUP BY c.territoryid;

SELECT h.customerid,
       count(*) AS order_count,
       sum(h.totaldue) AS lifetime_value
FROM sales.salesorderheader h
GROUP BY h.customerid
ORDER BY lifetime_value DESC
LIMIT 50;
'@ | Set-Content -Path $PgBenchScript -Encoding ascii

pgbench -h <postgresql-fqdn> -U <pgadmin> -d adventureworks -c 4 -j 2 -T 60 -f $PgBenchScript
```

PowerShell example:

```powershell
$PgBenchScript = Join-Path $env:TEMP "pgbench_adventureworks_pg_stat_statements.sql"
pgbench -h rodpgsqldemo01.postgres.database.azure.com -U rodadmin -d AdventureWorks -c 4 -j 2 -T 60 -f $PgBenchScript
```

Bash:

```bash
cat > /tmp/pgbench_adventureworks_pg_stat_statements.sql <<'SQL'
\set status random(1, 5)
\set min_total random(100, 5000)
\set product_id random(700, 999)
\set territory_id random(1, 10)

SELECT h.salesorderid,
       h.customerid,
       h.orderdate,
       h.status,
       h.totaldue
FROM sales.salesorderheader h
WHERE h.status = :status
  AND h.totaldue >= :min_total
ORDER BY h.orderdate DESC
LIMIT 25;

SELECT d.productid,
       count(*) AS line_count,
       sum(d.linetotal) AS product_revenue
FROM sales.salesorderdetail d
JOIN sales.salesorderheader h
  ON h.salesorderid = d.salesorderid
WHERE d.productid = :product_id
GROUP BY d.productid;

SELECT c.territoryid,
       count(DISTINCT h.salesorderid) AS orders,
       sum(h.totaldue) AS revenue
FROM sales.customer c
JOIN sales.salesorderheader h
  ON h.customerid = c.customerid
WHERE c.territoryid = :territory_id
GROUP BY c.territoryid;

SELECT h.customerid,
       count(*) AS order_count,
       sum(h.totaldue) AS lifetime_value
FROM sales.salesorderheader h
GROUP BY h.customerid
ORDER BY lifetime_value DESC
LIMIT 50;
SQL

pgbench -h <postgresql-fqdn> -U <pgadmin> -d adventureworks -c 4 -j 2 -T 60 -f /tmp/pgbench_adventureworks_pg_stat_statements.sql
```

Bash example:

```bash
pgbench -h rodpgsqldemo01.postgres.database.azure.com -U rodadmin -d AdventureWorks -c 4 -j 2 -T 60 -f /tmp/pgbench_adventureworks_pg_stat_statements.sql
```

Then reconnect with `psql` to the same database name used by `pgbench` and inspect the normalized statements. For this environment, if `pgbench` used `-d AdventureWorks`, query `pg_stat_statements` from `AdventureWorks` too.

```sql
SELECT calls,
       round(total_exec_time::numeric, 2) AS total_ms,
       round(mean_exec_time::numeric, 2) AS mean_ms,
       rows,
       left(query, 160) AS query
FROM pg_stat_statements
WHERE query NOT ILIKE '%pg_stat_statements%'
ORDER BY total_exec_time DESC
LIMIT 10;
```

Teaching point: `pgbench` is only creating a monitoring signal here. The goal is not a benchmark score; it is to show how repeated application-style SQL becomes ranked evidence in `pg_stat_statements`.

If the result is empty, check these in order:

```sql
-- 1. Confirm you are querying the same database that pgbench used.
SELECT current_database();

-- 2. Confirm the extension exists in this database.
SELECT extname, extversion
FROM pg_extension
WHERE extname = 'pg_stat_statements';

-- 3. Confirm the library was preloaded. If this does not include pg_stat_statements,
-- add it to shared_preload_libraries and restart the Flexible Server.
SHOW shared_preload_libraries;

-- 4. Confirm tracking is enabled.
SHOW pg_stat_statements.track;

-- 5. Remove the filter and check whether anything is being tracked at all.
SELECT count(*) AS tracked_statement_count
FROM pg_stat_statements;

-- 6. Generate one simple statement from this same psql session.
SELECT count(*)
FROM sales.salesorderheader;

SELECT calls,
       round(total_exec_time::numeric, 2) AS total_ms,
       round(mean_exec_time::numeric, 2) AS mean_ms,
       rows,
       left(query, 160) AS query
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 10;
```

Common causes:

1. `pgbench` connected to a different database name than the `psql` session. Use one database name consistently, normally `adventureworks`.
2. `pg_stat_statements` was created, but `shared_preload_libraries` was not set or the server was not restarted afterward.
3. `pg_stat_statements.track` is set to `none`, which disables statement collection even when the extension is installed and preloaded.
4. `SELECT pg_stat_statements_reset();` was run after `pgbench`, clearing the evidence.
5. `pgbench` started but did not execute transactions. Check that the PowerShell command prints transaction counts and not connection or script errors.

If `SELECT count(*) FROM sales.salesorderheader;` returns rows but `pg_stat_statements` is still empty, prove whether tracking is active with a minimal same-session test:

```sql
SHOW shared_preload_libraries;
SHOW pg_stat_statements.track;
SHOW pg_stat_statements.track_utility;
SHOW compute_query_id;

SELECT pg_stat_statements_reset();
SELECT 1 AS pgss_smoke_test;

SELECT calls,
       rows,
       left(query, 160) AS query
FROM pg_stat_statements
ORDER BY calls DESC
LIMIT 10;
```

Expected result: the `SELECT $1 AS pgss_smoke_test` or similar normalized statement appears. If it does not, `pg_stat_statements` is not actively tracking statements yet; fix `shared_preload_libraries`, restart the server, confirm `pg_stat_statements.track` is not `none`, reconnect, and test again before running `pgbench`.

## pg_trgm

`pg_trgm` provides trigram similarity and index support for fuzzy matching and wildcard text searches.

```sql
CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE INDEX idx_aw_emailaddress_trgm
ON person.emailaddress USING gin (emailaddress gin_trgm_ops);

SELECT p.businessentityid,
       p.firstname,
       p.lastname,
       e.emailaddress
FROM person.person p
JOIN person.emailaddress e
  ON e.businessentityid = p.businessentityid
WHERE e.emailaddress LIKE '%adventure-works%';
```

Similarity search:

```sql
SELECT businessentityid,
       firstname,
       lastname,
       similarity(lastname, 'Smith') AS similarity_score
FROM person.person
WHERE lastname % 'Smith'
ORDER BY similarity_score DESC
LIMIT 10;
```

Clean up the demonstration index:

```sql
DROP INDEX IF EXISTS idx_aw_emailaddress_trgm;
```

## UUID Generation

PostgreSQL 18 provides `gen_random_uuid()` without requiring an extension:

```sql
SELECT gen_random_uuid();
```

Install `uuid-ossp` for additional UUID algorithms:

```sql
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
SELECT uuid_generate_v4();
SELECT uuid_generate_v1();
```

## pgcrypto

`pgcrypto` provides hashing, encryption functions, and secure random bytes:

```sql
CREATE EXTENSION IF NOT EXISTS pgcrypto;

SELECT crypt('my_password', gen_salt('bf', 10)) AS password_hash;
SELECT encode(gen_random_bytes(32), 'hex') AS random_token;
```

Hash workshop email addresses for an anonymized export:

```sql
SELECT businessentityid,
       encode(digest(emailaddress, 'sha256'), 'hex') AS email_hash
FROM person.emailaddress
LIMIT 5;
```

## pgstattuple

`pgstattuple` is used in Day 2 to measure dead tuples and bloat on the AdventureWorks MVCC lab table.

Allow-list it before Day 2:

PowerShell:

```powershell
az postgres flexible-server parameter set `
  --resource-group <resource-group> `
  --server-name <server-name> `
  --name azure.extensions `
  --value "pg_stat_statements,pg_trgm,uuid-ossp,pgcrypto,pgstattuple"
```

Bash:

```bash
az postgres flexible-server parameter set \
  --resource-group <resource-group> \
  --server-name <server-name> \
  --name azure.extensions \
  --value "pg_stat_statements,pg_trgm,uuid-ossp,pgcrypto,pgstattuple"
```

Create it in `adventureworks`:

```sql
CREATE EXTENSION IF NOT EXISTS pgstattuple;
```

## Workshop Extension Reference

| Extension | Why we enable it | Allow-list required | Preload required | Create in database |
| --- | --- | --- | --- | --- |
| `pg_stat_statements` | Needed for top-SQL evidence, Query Store comparison, and Day 2 runbook cases. It tracks normalized statement execution statistics. | Yes | Yes | Yes, in `adventureworks` |
| `pg_trgm` | Used to demonstrate PostgreSQL operator-class extensions, fuzzy text search, and GIN indexing on AdventureWorks email/name data. | Yes | No | Yes, in `adventureworks` |
| `uuid-ossp` | AdventureWorks uses UUID values and this extension demonstrates compatibility with older UUID-generation patterns. | Yes | No | Yes, in `adventureworks` if not already restored |
| `pgcrypto` | Used for hashing/anonymizing sample email data and demonstrating secure random/hash functions. | Yes | No | Yes, in `adventureworks` |
| `pgstattuple` | Needed for the Day 2 MVCC/bloat lab to quantify dead tuples and table bloat beyond the approximate `pg_stat_user_tables` counters. | Yes | No | Yes, in `adventureworks` |

Do not introduce extra extensions during this lab. The point is to teach the managed-service extension workflow using extensions the workshop actually uses.

## Remove Optional Lab Extensions

```sql
DROP EXTENSION IF EXISTS pg_trgm;
DROP EXTENSION IF EXISTS pgcrypto;
```

Keep `pg_stat_statements`, `pgstattuple`, and `uuid-ossp`; later workshop sessions or AdventureWorks objects can depend on them.

## Lab Completion Checklist

- Available and installed extensions can be listed.
- The Azure allow-list step is understood.
- Extensions requiring preload can be identified.
- `pg_stat_statements` is installed in `adventureworks`.
- The workshop allow-list includes `pg_stat_statements`, `pg_trgm`, `uuid-ossp`, `pgcrypto`, and `pgstattuple`.
- The two common failure modes can be diagnosed.
- Optional extensions and demonstration objects are removed when no longer needed.
