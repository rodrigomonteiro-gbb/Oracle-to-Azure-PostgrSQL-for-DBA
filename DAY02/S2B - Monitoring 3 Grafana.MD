# Monitoring with Grafana

## A build-it-yourself guide to a PostgreSQL monitoring dashboard

---

> ### ⚠ Notes
>
> 1. **Part 6** builds the PostgreSQL monitoring dashboard from **native SQL**
>    against `pg_stat_*` — the correct approach when Grafana talks to PostgreSQL
>    directly
> 2. **Part 7** is a **KQL → Grafana translation guide** covering the standard
>    Azure Monitor / Log Analytics patterns for PostgreSQL Flexible Server, plus
>    the mechanical translation rules. Paste your original KQL into a reply and it
>    can be converted line by line.
>
> **Which one you need depends on your target:** monitoring a PostgreSQL server
> *directly*</br>
> → Part 6. Monitoring **Azure Database for PostgreSQL** through Azure Monitor</br>
> → Part 7. Many real deployments use both.</br>

---

## Table of contents

1. [What Grafana is — and what it is not](#part-1)
2. [The vocabulary](#part-2)
3. [Installing and first login](#part-3)
4. [Connecting PostgreSQL as a data source](#part-4)
5. [Your first panel, built from nothing](#part-5)
6. [The full PostgreSQL monitoring dashboard](#part-6)
7. [KQL → Grafana: translating Azure Monitor queries](#part-7)
8. [Variables — one dashboard, many servers](#part-8)
9. [Alerting](#part-9)
10. [Provisioning as code](#part-10)
11. [Troubleshooting](#part-11)
12. [Where to go next](#part-12)

---

<a name="part-1"></a>

## Part 1 — What Grafana is, and what it is not

Grafana is a **visualization and alerting layer**. It stores no metrics of its
own. Every number on a Grafana screen was fetched, live, from somewhere else at
the moment you looked at it.

That single fact explains most of Grafana's design, and most of the confusion
newcomers have:

- **It has no database of metrics.** Point it at PostgreSQL, Prometheus, Azure
  Monitor, or all three. Grafana queries them on demand.
- **It does not collect anything.** If nobody is recording the data, Grafana
  cannot show you history. This matters enormously for PostgreSQL — see the
  cumulative-counter warning in Part 6.
- **It is read-only by design.** Grafana renders and alerts. It does not fix.

**The mental model:**

```
  Data sources                Grafana                  You
  ┌──────────────┐         ┌──────────────┐        ┌────────┐
  │ PostgreSQL   │◄────────│              │        │        │
  │ Prometheus   │◄────────│  queries →   │───────►│ panels │
  │ Azure Monitor│◄────────│  transforms  │        │ alerts │
  └──────────────┘         └──────────────┘        └────────┘
        ▲                                                │
        └────────── you must ensure data lands here ─────┘
```

### **Grafana vs. things it is often confused with**

| Tool | What it actually does | Relationship to Grafana |
|---|---|---|
| **Prometheus** | Stores and scrapes time-series metrics | A *data source*. Very common pairing. |
| **postgres_exporter** | Translates `pg_stat_*` into Prometheus metrics | Feeds Prometheus, which feeds Grafana |
| **Azure Monitor** | Stores Azure platform metrics and logs | A *data source*, queried with KQL |
| **pgAdmin** | Administers PostgreSQL | Unrelated. Different job. |
| **Power BI** | Business analytics over warehoused data | Overlaps visually; different operational focus |

---

<a name="part-2"></a>

## Part 2 — The vocabulary

Learn these fourteen terms and Grafana stops being mysterious. They are the
whole language.

### Structural terms

| Term | What it means |
|---|---|
| **Data source** | A configured connection to a system that holds data. Has a name, a type, and credentials. Everything starts here. |
| **Dashboard** | A saved collection of panels plus their layout, variables, and time settings. Stored as JSON. |
| **Panel** | One visualization. A graph, a number, a table, a gauge. The atomic unit of a dashboard. |
| **Row** | A collapsible horizontal group of panels. Good for sectioning a long dashboard. |
| **Folder** | Organizes dashboards. Also the unit that permissions attach to. |
| **Library panel** | A panel defined once and reused across dashboards. Edit in one place, updates everywhere. |

### Query terms

| Term | What it means |
|---|---|
| **Query** | The request sent to a data source. SQL for PostgreSQL, PromQL for Prometheus, KQL for Azure Monitor. Each panel can hold several. |
| **Query editor** | The data-source-specific UI for writing that query. Looks completely different per source — this is normal. |
| **Format as** | Tells Grafana how to interpret the result: **Time series** or **Table**. Getting this wrong is the #1 beginner error. |
| **Transformation** | Post-query reshaping *inside* Grafana — join, filter, rename, compute. Runs after the data arrives, before rendering. |
| **Refresh interval** | How often Grafana re-runs every query on the dashboard. |

### Display terms

| Term | What it means |
|---|---|
| **Time range** | The window every query runs against. Set once, top-right, applies dashboard-wide. |
| **Variable** | A named placeholder, `$server`, that turns into a dropdown. One dashboard, many targets. |
| **Field / Unit** | A column in the result, and how it should be rendered — bytes, ms, percent. Set the unit; it is the difference between amateur and professional. |
| **Threshold** | A value that changes a panel's colour. Green under, red over. |
| **Legend** | The series labels. In SQL, controlled by your column aliases. |
| **Annotation** | A vertical marker on a time axis — a deployment, an incident, a maintenance window. |

### The three terms that cause the most trouble

### **1. Time series vs. Table format**

Grafana's *Time series* format demands a specific shape:

| Column | Requirement |
|---|---|
| A time column | Must be `timestamp`/`timestamptz`, and **must be named `time`** |
| One or more numeric columns | The values plotted |
| Optional text columns | Become series labels |

Return a result without a valid `time` column and set *Format as: Time series*,
and you get **"Data is missing a time field"**. That single error accounts for
most first-hour frustration. Fix: either supply a proper `time` column, or switch
the panel to *Table*.

**2. `$__timeFilter()` — the macro that makes zooming work**

Grafana macros are expanded *before* the query is sent:

```sql
SELECT ts AS time, value FROM metrics WHERE $__timeFilter(ts)
```

becomes

```sql
SELECT ts AS time, value FROM metrics
WHERE ts BETWEEN '2026-09-17T14:00:00Z' AND '2026-09-17T18:00:00Z'
```

**Omit this macro and your panel ignores the time picker entirely** — zooming
does nothing, and the panel returns the whole table every refresh. If a panel
seems to ignore the time range, this is why.

Essential PostgreSQL macros:

| Macro | Expands to |
|---|---|
| `$__timeFilter(col)` | `col BETWEEN <from> AND <to>` |
| `$__timeFrom()` / `$__timeTo()` | The range boundaries as literals |
| `$__timeGroup(col, '5m')` | Buckets `col` into 5-minute intervals |
| `$__timeGroupAlias(col, '5m')` | Same, and names the output `time` — use this one |
| `$__interval` | Grafana's suggested bucket width for the current zoom |
| `$__unixEpochFilter(col)` | For epoch-integer columns |

### **3. Instant vs. range queries**

A *range* query returns a series over time (a graph). An *instant* query returns
the value right now (a Stat panel). In SQL data sources the distinction is
implicit — whether you return a `time` column or a single row.

---

<a name="part-3"></a>

## Part 3 — Installing and first login

### Fastest path: Docker

```bash
docker run -d \
  --name grafana \
  -p 3000:3000 \
  -v grafana-storage:/var/lib/grafana \
  grafana/grafana-oss:latest
```

Browse to `http://localhost:3000` — default credentials `admin` / `admin`, and
it will force a change on first login.

> The named volume matters. Without `-v`, every dashboard you build dies with
> the container.

### With a PostgreSQL to monitor — full lab stack

```yaml
# docker-compose.yml
version: '3.8'
services:
  postgres:
    image: postgres:16
    environment:
      POSTGRES_PASSWORD: labpassword
      POSTGRES_DB: labdb
    ports: ["5432:5432"]
    command: >
      postgres
      -c shared_preload_libraries=pg_stat_statements
      -c pg_stat_statements.track=all
      -c track_io_timing=on

  grafana:
    image: grafana/grafana-oss:latest
    ports: ["3000:3000"]
    volumes:
      - grafana-storage:/var/lib/grafana
    depends_on: [postgres]

volumes:
  grafana-storage:
```

```bash
docker compose up -d
```

> Note the `shared_preload_libraries` and `track_io_timing` flags — Part 6 needs
> both, and both require a server restart if added later. Setting them at
> container creation avoids that.

### Grafana Cloud

A free tier exists and removes the hosting question entirely. The dashboard
work in this guide is identical either way; only the data source networking
differs (your database must be reachable from Grafana's cloud).

### Azure Managed Grafana

If your PostgreSQL is Azure Database for PostgreSQL, Azure Managed Grafana is
worth knowing about: it ships with the Azure Monitor data source pre-wired and
uses Entra ID for auth, which removes the credential management in Part 4.
Relevant to Part 7.

---

<a name="part-4"></a>

## Part 4 — Connecting PostgreSQL as a data source

### Create a read-only monitoring role first

**Never point Grafana at a superuser account.** Grafana executes whatever SQL a
panel contains; anyone who can edit a panel can run that SQL. Create a
least-privilege role:

```sql
CREATE ROLE grafana_ro WITH LOGIN PASSWORD 'use-a-real-secret';

GRANT CONNECT ON DATABASE labdb TO grafana_ro;
GRANT USAGE ON SCHEMA public TO grafana_ro;

-- PG10+ : read the statistics views without full superuser
GRANT pg_monitor TO grafana_ro;

-- Optional: if panels need to read application tables too
GRANT SELECT ON ALL TABLES IN SCHEMA public TO grafana_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO grafana_ro;
```

> **`pg_monitor` is the key grant.** It is a built-in role bundling
> `pg_read_all_settings`, `pg_read_all_stats`, and `pg_stat_scan_tables`. Without
> it, non-superusers see **NULL** in the `query` column of `pg_stat_activity` for
> other users' sessions, and `pg_stat_statements` returns `<insufficient
> privilege>` instead of query text. The panels will render — they will just be
> mysteriously empty. This is a very common silent failure.

### Configure in Grafana

### **Connections → Data sources → Add new data source → PostgreSQL**

| Field | Value | Notes |
|---|---|---|
| Name | `PostgreSQL-Lab` | You will reference this by name |
| Host URL | `postgres:5432` | Container name inside Compose; `localhost:5432` otherwise |
| Database | `labdb` | |
| User | `grafana_ro` | |
| Password | *your secret* | |
| TLS/SSL Mode | `disable` for local lab, **`require`** or stricter in production | Azure PostgreSQL enforces SSL |
| Version | Match your server | Affects which SQL features Grafana generates |
| Min time interval | `1m` | Floor for `$__interval`; prevents absurd bucket sizes |
| **TimescaleDB** | Off unless you actually run it | |

Click **Save & test** → *"Database Connection OK"*.

> **Connection limits.** Each Grafana data source keeps its own pool. A dashboard
> with 15 panels refreshing every 5 seconds is a real workload. Set *Max open
> connections* (default 100) to something sane — 10 is plenty for a lab — and
> never refresh faster than your queries take to run.

---

<a name="part-5"></a>

## Part 5 — Your first panel, built from nothing

Build this one by hand. The muscle memory is worth more than a copied dashboard.

**1. New dashboard** → **Add visualization** → select `PostgreSQL-Lab`.

**2. Switch the query editor from Builder to Code.** The visual builder cannot
express the queries in Part 6.

**3. Type this:**

```sql
SELECT
    now()                              AS time,
    count(*)                           AS "active connections"
FROM pg_stat_activity
WHERE state = 'active';
```

**4. Set *Format as* to `Table`, and choose the `Stat` visualization.** You now
have a number on screen. That is a working panel.

**5. Now make it a real time series.** The query above returns "now" — one point.
To get history you need data recorded over time, which `pg_stat_activity` does
not provide. This is the central PostgreSQL-on-Grafana problem, and Part 6
solves it properly. For the moment, see the shape work:

```sql
SELECT
    $__timeGroupAlias(ts, $__interval),
    avg(active_count) AS "active"
FROM monitor.connection_history
WHERE $__timeFilter(ts)
GROUP BY 1
ORDER BY 1;
```

Note the three elements that make this a valid Grafana time-series query:
`$__timeGroupAlias` (produces a column named `time`), `$__timeFilter` (respects
the time picker), and `ORDER BY 1` (Grafana requires ascending time).

**6. Set the unit.** Right panel → *Standard options* → *Unit*. For bytes pick
`bytes(IEC)`; for durations `milliseconds`; for ratios `percent (0-100)`. An
unlabelled axis is the mark of an unfinished dashboard.

**7. Add a threshold.** *Thresholds* → add `80` red. The Stat panel turns red
above 80.

**8. Save** with a name and folder.

### The five habits that separate good panels from bad

1. **Always alias to a readable legend.** `AS "Cache hit %"`, not `AS col1`.
2. **Always set the unit.** Grafana cannot infer it.
3. **Always include `$__timeFilter`** in time-series panels.
4. **Always `ORDER BY time`.** Unordered results render as scribble.
5. **Write a panel description.** The little `i` icon. Future-you will not
   remember what `n_tup_hot_upd` meant.

---

<a name="part-6"></a>

## Part 6 — The full PostgreSQL monitoring dashboard

### ⚠ First, the thing that breaks every PostgreSQL dashboard

**Almost everything in `pg_stat_*` is a cumulative counter, not a gauge.**

`pg_stat_database.xact_commit` is *total commits since the stats were last
reset*. Graph it raw and you get a line going up and to the right forever. It
tells you nothing about now.

What you want is the **rate**: commits *per second*, right now. Three ways to get
there, in increasing order of quality:

| Approach | How | Verdict |
|---|---|---|
| **A. Snapshot table** | A table + a scheduled job storing samples; query deltas with window functions | **Best for a self-contained lab.** No extra infrastructure. Used below. |
| **B. postgres_exporter + Prometheus** | Exporter scrapes, Prometheus stores, `rate()` does the math | **Best for production.** The standard stack. |
| **C. Live-only panels** | Query current state, accept no history | Fine for `pg_stat_activity`, useless for counters |

This guide uses **A**, with **B** noted where relevant.

### 6.1 — Build the snapshot infrastructure

```sql
CREATE SCHEMA IF NOT EXISTS monitor;

CREATE TABLE IF NOT EXISTS monitor.db_stats_history (
    ts               timestamptz NOT NULL DEFAULT now(),
    datname          text        NOT NULL,
    numbackends      int,
    xact_commit      bigint,
    xact_rollback    bigint,
    blks_read        bigint,
    blks_hit         bigint,
    tup_returned     bigint,
    tup_fetched      bigint,
    tup_inserted     bigint,
    tup_updated      bigint,
    tup_deleted      bigint,
    conflicts        bigint,
    temp_files       bigint,
    temp_bytes       bigint,
    deadlocks        bigint,
    blk_read_time    double precision,
    blk_write_time   double precision,
    PRIMARY KEY (ts, datname)
);

CREATE INDEX IF NOT EXISTS ix_db_stats_history_ts
    ON monitor.db_stats_history (ts DESC);

CREATE TABLE IF NOT EXISTS monitor.activity_history (
    ts             timestamptz NOT NULL DEFAULT now(),
    datname        text,
    state          text,
    backend_count  int,
    max_duration_s double precision,
    PRIMARY KEY (ts, datname, state)
);

CREATE INDEX IF NOT EXISTS ix_activity_history_ts
    ON monitor.activity_history (ts DESC);
```

```sql
CREATE OR REPLACE FUNCTION monitor.take_snapshot()
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO monitor.db_stats_history (
        datname, numbackends, xact_commit, xact_rollback,
        blks_read, blks_hit, tup_returned, tup_fetched,
        tup_inserted, tup_updated, tup_deleted, conflicts,
        temp_files, temp_bytes, deadlocks, blk_read_time, blk_write_time)
    SELECT datname, numbackends, xact_commit, xact_rollback,
           blks_read, blks_hit, tup_returned, tup_fetched,
           tup_inserted, tup_updated, tup_deleted, conflicts,
           temp_files, temp_bytes, deadlocks, blk_read_time, blk_write_time
    FROM   pg_stat_database
    WHERE  datname IS NOT NULL
      AND  datname NOT IN ('template0','template1');

    INSERT INTO monitor.activity_history (datname, state, backend_count, max_duration_s)
    SELECT datname,
           COALESCE(state, 'unknown'),
           count(*),
           COALESCE(max(EXTRACT(epoch FROM (now() - state_change))), 0)
    FROM   pg_stat_activity
    WHERE  backend_type = 'client backend'
      AND  datname IS NOT NULL
    GROUP  BY datname, COALESCE(state, 'unknown');

    -- Retention: keep 7 days
    DELETE FROM monitor.db_stats_history  WHERE ts < now() - interval '7 days';
    DELETE FROM monitor.activity_history  WHERE ts < now() - interval '7 days';
END
$$;
```

**Schedule it.** With `pg_cron`:

```sql
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('pg-monitor-snapshot', '* * * * *', 'SELECT monitor.take_snapshot()');
```

Without `pg_cron`, a system cron entry works equally well:

```bash
* * * * * psql -d labdb -c "SELECT monitor.take_snapshot()" >/dev/null 2>&1
```

> **Sampling interval sets your resolution ceiling.** One minute is a sensible
> default. Every 10 seconds gives sharper graphs and 6× the storage. Do not
> sample faster than you will ever look.

Seed a few samples before building panels, or every graph will be empty:

```sql
SELECT monitor.take_snapshot(); SELECT pg_sleep(2);
SELECT monitor.take_snapshot(); SELECT pg_sleep(2);
SELECT monitor.take_snapshot();
```

### 6.2 — Row 1: Service health (Stat panels)

### **Panel 1.1 — Uptime**

```sql
SELECT EXTRACT(epoch FROM (now() - pg_postmaster_start_time())) AS "uptime";
```
*Format:* Table · *Viz:* Stat · *Unit:* `seconds(s)` · Thresholds: red below `300`
(a low value means a recent restart — worth noticing).

### **Panel 1.2 — Connections used vs. max**

```sql
SELECT
    (SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'client backend')::float
    / NULLIF(current_setting('max_connections')::float, 0) * 100 AS "connections used";
```

*Viz:* Gauge · *Unit:* `percent (0-100)` · Min 0, Max 100 · Thresholds: yellow `70`, red `85`.

> Connection exhaustion is one of the most common production PostgreSQL
> incidents, and it fails hard — new connections are simply refused. This gauge
> is arguably the single most valuable panel on the dashboard.

### **Panel 1.3 — Cache hit ratio**

```sql
SELECT
    sum(blks_hit)::float / NULLIF(sum(blks_hit) + sum(blks_read), 0) * 100
        AS "cache hit ratio"
FROM pg_stat_database
WHERE datname NOT IN ('template0','template1');
```

*Viz:* Stat · *Unit:* `percent (0-100)` · Thresholds: red below `90`, green above `99`.

> **Read this one with care.** A high ratio is not automatically good — it only
> means reads were served from shared buffers rather than going to the OS. It
> says nothing about whether the queries should have run at all. A missing index
> can show 99.9% cache hits while burning enormous CPU. Pair it with the query
> panels in 6.5; never treat it as a standalone health score.

### **Panel 1.4 — Database size**

```sql
SELECT pg_database_size(current_database()) AS "database size";
```

*Viz:* Stat · *Unit:* `bytes(IEC)` · Graph mode: Area.

### **Panel 1.5 — Oldest transaction age**

```sql
SELECT COALESCE(EXTRACT(epoch FROM max(now() - xact_start)), 0) AS "oldest transaction"
FROM pg_stat_activity
WHERE state <> 'idle' AND xact_start IS NOT NULL;
```
*Viz:* Stat · *Unit:* `seconds(s)` · Thresholds: yellow `300`, red `1800`.

> Long-running transactions hold back the vacuum horizon, causing table bloat and
> — in the extreme — transaction ID wraparound. This panel catches the cause
> before the symptoms appear.

### 6.3 — Row 2: Throughput (rates from snapshots)

### **Panel 2.1 — Transactions per second**

```sql
SELECT
    $__timeGroupAlias(ts, $__interval),
    datname AS metric,
    GREATEST(
      (max(xact_commit) - min(xact_commit))
      / NULLIF(EXTRACT(epoch FROM (max(ts) - min(ts))), 0), 0
    ) AS "commits/s"
FROM   monitor.db_stats_history
WHERE  $__timeFilter(ts)
GROUP  BY 1, 2
ORDER  BY 1;
```
*Format:* Time series · *Viz:* Time series · *Unit:* `ops/sec`.

> **The `GREATEST(..., 0)` is not decoration.** `pg_stat_reset()`, a server
> restart, or a stats-file reset sends the counter back to zero, producing a
> large negative spike that wrecks the axis scale. Clamping at zero makes the
> dashboard survive a restart. Every rate panel below does the same.

### **Panel 2.2 — Rollback ratio**

```sql
SELECT
    $__timeGroupAlias(ts, $__interval),
    100.0 * GREATEST(max(xact_rollback) - min(xact_rollback), 0)
      / NULLIF(GREATEST(max(xact_commit) - min(xact_commit), 0)
             + GREATEST(max(xact_rollback) - min(xact_rollback), 0), 0)
      AS "rollback %"
FROM   monitor.db_stats_history
WHERE  $__timeFilter(ts)
GROUP  BY 1
ORDER  BY 1;
```
*Unit:* `percent (0-100)`. A rising rollback ratio usually means application
errors or deadlocks — a leading indicator worth alerting on.

### **Panel 2.3 — Tuple operations**

```sql
SELECT
    $__timeGroupAlias(ts, $__interval),
    GREATEST((max(tup_inserted) - min(tup_inserted))
      / NULLIF(EXTRACT(epoch FROM (max(ts) - min(ts))), 0), 0) AS "inserted/s",
    GREATEST((max(tup_updated)  - min(tup_updated))
      / NULLIF(EXTRACT(epoch FROM (max(ts) - min(ts))), 0), 0) AS "updated/s",
    GREATEST((max(tup_deleted)  - min(tup_deleted))
      / NULLIF(EXTRACT(epoch FROM (max(ts) - min(ts))), 0), 0) AS "deleted/s",
    GREATEST((max(tup_fetched)  - min(tup_fetched))
      / NULLIF(EXTRACT(epoch FROM (max(ts) - min(ts))), 0), 0) AS "fetched/s"
FROM   monitor.db_stats_history
WHERE  $__timeFilter(ts)
GROUP  BY 1
ORDER  BY 1;
```
*Unit:* `rows/sec`. Multiple numeric columns become multiple series automatically
— no `metric` column needed.

### **Panel 2.4 — Block I/O rate**

```sql
SELECT
    $__timeGroupAlias(ts, $__interval),
    GREATEST((max(blks_read) - min(blks_read))
      / NULLIF(EXTRACT(epoch FROM (max(ts) - min(ts))), 0), 0) * 8192 AS "disk read",
    GREATEST((max(blks_hit)  - min(blks_hit))
      / NULLIF(EXTRACT(epoch FROM (max(ts) - min(ts))), 0), 0) * 8192 AS "cache read"
FROM   monitor.db_stats_history
WHERE  $__timeFilter(ts)
GROUP  BY 1
ORDER  BY 1;
```
*Unit:* `bytes/sec(IEC)`. The `* 8192` converts blocks to bytes — correct for the
default 8 kB block size; adjust if yours differs.

### **Panel 2.5 — Deadlocks and temp files**

```sql
SELECT
    $__timeGroupAlias(ts, $__interval),
    GREATEST(max(deadlocks)  - min(deadlocks), 0)  AS "deadlocks",
    GREATEST(max(temp_files) - min(temp_files), 0) AS "temp files"
FROM   monitor.db_stats_history
WHERE  $__timeFilter(ts)
GROUP  BY 1
ORDER  BY 1;
```
*Viz:* Bars. Both should normally be zero. Temp files mean sorts spilling out of
`work_mem` — the same mechanism demonstrated in the indexing module's sort-avoidance
step. Deadlocks always warrant investigation.

### 6.4 — Row 3: Sessions and contention

### **Panel 3.1 — Connections by state over time**

```sql
SELECT
    $__timeGroupAlias(ts, $__interval),
    state AS metric,
    avg(backend_count) AS "backends"
FROM   monitor.activity_history
WHERE  $__timeFilter(ts)
GROUP  BY 1, 2
ORDER  BY 1;
```
*Viz:* Time series, Stacked. Watch `idle in transaction` specifically — it is the
state that blocks vacuum and holds locks.

### **Panel 3.2 — Current activity (live table)**

```sql
SELECT
    pid,
    usename          AS "user",
    application_name AS "application",
    client_addr      AS "client",
    state,
    round(EXTRACT(epoch FROM (now() - query_start))::numeric, 1) AS "duration_s",
    wait_event_type  AS "wait type",
    wait_event       AS "wait event",
    left(regexp_replace(query, '\s+', ' ', 'g'), 120) AS "query"
FROM   pg_stat_activity
WHERE  backend_type = 'client backend'
  AND  pid <> pg_backend_pid()
  AND  state <> 'idle'
ORDER  BY query_start NULLS LAST;
```
*Format:* Table · *Viz:* Table. Add a cell colour threshold on `duration_s`.

> This is a **live** panel — no `$__timeFilter`, because `pg_stat_activity` has no
> history. It shows the present moment only, and that is correct.

### **Panel 3.3 — Blocked sessions**

```sql
SELECT
    blocked.pid              AS "blocked pid",
    blocked.usename          AS "blocked user",
    left(blocked.query, 80)  AS "blocked query",
    blocking.pid             AS "blocking pid",
    blocking.usename         AS "blocking user",
    left(blocking.query, 80) AS "blocking query",
    round(EXTRACT(epoch FROM (now() - blocked.query_start))::numeric, 1) AS "blocked_s"
FROM pg_stat_activity blocked
JOIN LATERAL unnest(pg_blocking_pids(blocked.pid)) AS blocking_pid ON true
JOIN pg_stat_activity blocking ON blocking.pid = blocking_pid
WHERE cardinality(pg_blocking_pids(blocked.pid)) > 0;
```
*Format:* Table. Empty is healthy. When it is not empty, it names both sides of
the problem — one of the highest-value panels you can build.

### **Panel 3.4 — Wait events**

```sql
SELECT
    COALESCE(wait_event_type, 'CPU / running') AS "wait type",
    count(*)                                   AS "sessions"
FROM   pg_stat_activity
WHERE  backend_type = 'client backend' AND state = 'active'
GROUP  BY 1
ORDER  BY 2 DESC;
```

*Viz:* Pie chart or Bar gauge. The fastest way to answer "what is the server
waiting on?"

### 6.5 — Row 4: Query performance (`pg_stat_statements`)

> Requires `shared_preload_libraries = 'pg_stat_statements'` and a restart.
> ```sql
> CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
> ```
> Column naming changed in PG13: `total_time` → `total_exec_time`, `mean_time` →
> `mean_exec_time`. Queries below use PG13+ names.

### **Panel 4.1 — Top queries by total time**

```sql
SELECT
    round(total_exec_time::numeric, 1)          AS "total ms",
    calls,
    round(mean_exec_time::numeric, 3)           AS "mean ms",
    round(max_exec_time::numeric, 1)            AS "max ms",
    rows,
    round(100.0 * shared_blks_hit
          / NULLIF(shared_blks_hit + shared_blks_read, 0), 1) AS "cache %",
    left(regexp_replace(query, '\s+', ' ', 'g'), 150) AS "query"
FROM   pg_stat_statements
WHERE  query NOT ILIKE '%pg_stat_statements%'
  AND  query NOT ILIKE 'EXPLAIN%'
ORDER  BY total_exec_time DESC
LIMIT  20;
```

> **The two exclusion lines are deliberate.** `pg_stat_statements` records
> `EXPLAIN` as a *separate* utility statement from the query it explains —
> `track_utility` defaults to on — so without the filter you get duplicate
> entries with inflated timings. Same mechanism documented in the indexing
> module's appendix.

### **Panel 4.2 — Top queries by mean time**

```sql
SELECT
    round(mean_exec_time::numeric, 3) AS "mean ms",
    calls,
    round(total_exec_time::numeric, 1) AS "total ms",
    left(regexp_replace(query, '\s+', ' ', 'g'), 150) AS "query"
FROM   pg_stat_statements
WHERE  calls > 10
  AND  query NOT ILIKE '%pg_stat_statements%'
  AND  query NOT ILIKE 'EXPLAIN%'
ORDER  BY mean_exec_time DESC
LIMIT  20;
```

> Panels 4.1 and 4.2 answer different questions, and both matter. 4.1 finds
> **aggregate load** — a 2 ms query called ten million times. 4.2 finds
> **individual slowness** — a 40-second report. Optimising the wrong one is
> wasted effort. The `calls > 10` filter keeps one-off outliers out of 4.2.

### **Panel 4.3 — Queries causing temp file I/O**

```sql
SELECT
    round((temp_blks_written * 8192)::numeric, 0) AS "temp bytes written",
    calls,
    round(mean_exec_time::numeric, 2) AS "mean ms",
    left(regexp_replace(query, '\s+', ' ', 'g'), 150) AS "query"
FROM   pg_stat_statements
WHERE  temp_blks_written > 0
ORDER  BY temp_blks_written DESC
LIMIT  10;
```

*Unit* on the first column: `bytes(IEC)`. These are your `work_mem` candidates.

### 6.6 — Row 5: Table and index health

### **Panel 5.1 — Index usage efficiency**

```sql
SELECT
    schemaname || '.' || relname AS "table",
    seq_scan                     AS "seq scans",
    COALESCE(idx_scan, 0)        AS "index scans",
    round(100.0 * COALESCE(idx_scan, 0)
          / NULLIF(seq_scan + COALESCE(idx_scan, 0), 0), 1) AS "index use %",
    n_live_tup                   AS "live rows",
    pg_size_pretty(pg_total_relation_size(relid)) AS "total size"
FROM   pg_stat_user_tables
WHERE  seq_scan + COALESCE(idx_scan, 0) > 0
ORDER  BY seq_scan DESC
LIMIT  25;
```

> Sort by `seq_scan` descending and the top rows are your missing-index
> candidates — large tables being repeatedly scanned. But **read it with
> judgement**: a small lookup table *should* be seq-scanned, because scanning 3
> pages beats descending a B-tree. Cross-reference against `total size` before
> concluding anything.

### **Panel 5.2 — Unused indexes**

```sql
SELECT
    schemaname || '.' || relname   AS "table",
    indexrelname                   AS "index",
    idx_scan                       AS "times used",
    pg_relation_size(indexrelid)   AS "size"
FROM   pg_stat_user_indexes
WHERE  idx_scan < 50
  AND  NOT EXISTS (
        SELECT 1 FROM pg_constraint c
        WHERE c.conindid = pg_stat_user_indexes.indexrelid)
ORDER  BY pg_relation_size(indexrelid) DESC
LIMIT  25;
```

*Unit* on `size`: `bytes(IEC)`.

> Every index here costs storage, slows every write, and adds vacuum work while
> returning nothing. **Two cautions before dropping any of them:** counters are
> cumulative since the last `pg_stat_reset()` — an index unused since a restart
> five minutes ago proves nothing, so check `pg_postmaster_start_time()` first.
> And an index serving a quarterly report will look unused for 89 days. The
> `NOT EXISTS` clause already excludes constraint-backing indexes, which must
> never be dropped.

### **Panel 5.3 — Dead tuples / bloat indicator**

```sql
SELECT
    schemaname || '.' || relname AS "table",
    n_live_tup                   AS "live",
    n_dead_tup                   AS "dead",
    round(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 1) AS "dead %",
    last_autovacuum,
    last_autoanalyze
FROM   pg_stat_user_tables
WHERE  n_dead_tup > 1000
ORDER  BY n_dead_tup DESC
LIMIT  25;
```

> High dead-tuple percentage plus an old or NULL `last_autovacuum` means
> autovacuum is not keeping up. That is a tuning conversation, not a one-off
> `VACUUM`.

### **Panel 5.4 — HOT update ratio**

```sql
SELECT
    $__timeGroupAlias(ts, $__interval),
    100.0 * GREATEST(max(hot) - min(hot), 0)
      / NULLIF(GREATEST(max(upd) - min(upd), 0), 0) AS "HOT %"
FROM (
    SELECT ts, tup_updated AS upd, tup_updated AS hot
    FROM   monitor.db_stats_history
) s
WHERE  $__timeFilter(ts)
GROUP  BY 1
ORDER  BY 1;
```

> **To make this panel meaningful**, add `n_tup_upd` and `n_tup_hot_upd` from
> `pg_stat_user_tables` to the snapshot function — `pg_stat_database` does not
> expose HOT counts. Worth the effort: a falling HOT ratio is the clearest early
> signal that someone added an index to a frequently-updated column, which is
> exactly the trade-off the indexing module's write-cost step demonstrates. This
> panel turns that lesson into ongoing production telemetry.

### **Panel 5.5 — Transaction ID wraparound headroom**

```sql
SELECT
    datname AS "database",
    age(datfrozenxid) AS "xid age",
    round(100.0 * age(datfrozenxid)
          / current_setting('autovacuum_freeze_max_age')::float, 1) AS "% to freeze"
FROM   pg_database
WHERE  datname NOT IN ('template0','template1')
ORDER  BY age(datfrozenxid) DESC;
```

> Obscure until the day it takes production down. If this climbs toward 100%,
> autovacuum is losing the race and the server will eventually refuse writes to
> protect itself. Alert on it.

### 6.7 — Assembling the dashboard

1. Create a folder: **PostgreSQL**.
2. New dashboard → add panels in the order above.
3. Group into rows: `Service Health`, `Throughput`, `Sessions`, `Query
   Performance`, `Table & Index Health`.
4. Dashboard settings → time options → default range `Last 6 hours`, refresh
   `1m`.
5. **Match the refresh to the snapshot interval.** Refreshing every 5 s when you
   sample every 60 s just hammers the database for identical data.
6. Save. Then **export the JSON** (Share → Export → Save to file) and commit it
   to source control — see Part 10.

---

<a name="part-7"></a>

## Part 7 — KQL → Grafana: translating Azure Monitor queries

For **Azure Database for PostgreSQL – Flexible Server**, platform metrics and
logs live in Azure Monitor and are queried with **KQL**, not SQL. Grafana speaks
to this through the **Azure Monitor data source**.

> The KQL below covers the standard Azure Monitor patterns for PostgreSQL. It is
> written from the documented `AzureMetrics` / `AzureDiagnostics` schema — **not**
> reconstructed from your originals, which are not available in this session.
> Verify table and metric names against your workspace, and paste your own
> queries in for a line-by-line conversion.

### 7.1 — Configuring the Azure Monitor data source

#### **Connections → Add data source → Azure Monitor**

| Field | Value |
|---|---|
| Authentication | App Registration, or **Managed Identity** (preferred on Azure Managed Grafana) |
| Directory (tenant) ID | Your Entra tenant |
| Application (client) ID | The app registration |
| Client secret | Or use managed identity and skip |
| Default subscription | Your subscription |

**Required RBAC:** the identity needs **Monitoring Reader** on the subscription
or resource group, and **Log Analytics Reader** on the workspace for KQL log
queries.

The data source exposes three query types — and picking the wrong one is the
usual first mistake:

| Query type | Queries | Language |
|---|---|---|
| **Metrics** | Azure Monitor platform metrics | No query language — dropdowns |
| **Logs** | Log Analytics workspace | **KQL** |
| **Azure Resource Graph** | Resource inventory | KQL subset |

### 7.2 — The translation rules

KQL and Grafana-flavoured SQL differ in five specific ways. Learn these and any
query converts mechanically.

| Concept | KQL | Grafana SQL equivalent |
|---|---|---|
| **Time filtering** | `where TimeGenerated > ago(1h)` | `WHERE $__timeFilter(ts)` |
| **Grafana time macro (KQL)** | `where $__timeFilter(TimeGenerated)` | same macro, KQL syntax |
| **Bucketing** | `summarize by bin(TimeGenerated, 5m)` | `$__timeGroupAlias(ts, '5m')` |
| **Dynamic bucket** | `bin(TimeGenerated, $__timeInterval)` | `$__timeGroup(ts, $__interval)` |
| **Aggregation** | `summarize avg(X) by Y` | `SELECT avg(x) ... GROUP BY y` |
| **Projection / alias** | `project time=TimeGenerated, v=Value` | `SELECT ts AS time, val AS v` |
| **Series naming** | last text column, or `by` key | column aliased `metric` |
| **Ordering** | `order by TimeGenerated asc` | `ORDER BY 1` |
| **Row limit** | `take 20` / `top 20 by X` | `LIMIT 20` / `ORDER BY x DESC LIMIT 20` |
| **Filtering rows** | `where X > 5` | `WHERE x > 5` |
| **Renaming** | `extend pct = A * 100.0 / B` | `SELECT a * 100.0 / b AS pct` |

**Three Grafana-specific KQL rules that are non-negotiable:**

1. **Alias the time column `TimeGenerated` or explicitly `time`.** The Azure
   Monitor plugin looks for it exactly as the PostgreSQL plugin does.
2. **Always use `$__timeFilter(TimeGenerated)`** rather than `ago(1h)`. Hardcoding
   `ago()` breaks the time picker in precisely the same way omitting
   `$__timeFilter` does in SQL.
3. **The last string column becomes the series name.** In KQL, `summarize ... by
   Resource` produces one series per resource automatically.

### 7.3 — Worked conversions

### **A — CPU utilisation over time**

```kusto
AzureMetrics
| where $__timeFilter(TimeGenerated)
| where ResourceProvider == "MICROSOFT.DBFORPOSTGRESQL"
| where MetricName == "cpu_percent"
| summarize CPU = avg(Average) by bin(TimeGenerated, $__timeInterval), Resource
| project TimeGenerated, CPU, Resource
| order by TimeGenerated asc
```

*Panel:* Time series · *Unit:* `percent (0-100)` · Thresholds: yellow 70, red 85.

The native equivalent — same panel, different source — would be Part 6's
throughput row. **On Azure, prefer the platform metric**: it measures the host,
including work `pg_stat_*` cannot see.

### **B — Storage used percentage**

```kusto
AzureMetrics
| where $__timeFilter(TimeGenerated)
| where MetricName == "storage_percent"
| summarize Storage = avg(Average) by bin(TimeGenerated, $__timeInterval), Resource
| order by TimeGenerated asc
```

### **C — Active connections vs. limit**

```kusto
AzureMetrics
| where $__timeFilter(TimeGenerated)
| where MetricName in ("active_connections", "connections_failed")
| summarize Value = avg(Average) by bin(TimeGenerated, $__timeInterval), MetricName
| order by TimeGenerated asc
```

Maps directly onto Panel 1.2. `connections_failed` is the one to alert on — it
means clients were actively refused.

### **D — Slow query log (Log Analytics)**

```kusto
AzureDiagnostics
| where $__timeFilter(TimeGenerated)
| where Category == "PostgreSQLLogs"
| where Message contains "duration:"
| extend DurationMs = todouble(extract(@"duration: ([\d.]+) ms", 1, Message))
| where DurationMs > 1000
| project TimeGenerated, DurationMs, Message, Resource
| order by DurationMs desc
| take 50
```

*Panel:* Table. The native counterpart is Panel 4.2 — but this one requires
`log_min_duration_statement` to be set and the diagnostic setting to be routing
`PostgreSQLLogs` to the workspace. Both are off by default.

### **E — Query Store: top queries by mean duration**

```kusto
AzureDiagnostics
| where $__timeFilter(TimeGenerated)
| where Category == "PostgreSQLFlexQueryStoreRuntime"
| summarize MeanMs = avg(todouble(mean_time_s)) * 1000,
            Calls  = sum(toint(calls_s))
          by query_id_s
| order by MeanMs desc
| take 20
```

The Azure-native equivalent of Panel 4.2. Azure's Query Store persists this
across restarts, which raw `pg_stat_statements` does not.

### **F — Failed connections and deadlocks**

```kusto
AzureMetrics
| where $__timeFilter(TimeGenerated)
| where MetricName in ("connections_failed", "deadlocks")
| summarize Total = sum(Total) by bin(TimeGenerated, $__timeInterval), MetricName
| order by TimeGenerated asc
```

*Panel:* Bars. Maps to Panel 2.5.

### 7.4 — Which source for which metric

Neither source is complete. Use both:

| Metric | Best source | Why |
|---|---|---|
| CPU, memory, IOPS | **Azure Monitor** | Host-level; invisible to `pg_stat_*` |
| Storage percent | **Azure Monitor** | Platform-managed |
| Connections | Either | Azure Monitor also captures *failures* |
| Query text and plans | **PostgreSQL native** | Far more detail in `pg_stat_statements` |
| Index usage, bloat, HOT | **PostgreSQL native** | Not exposed as Azure metrics at all |
| Blocking chains | **PostgreSQL native** | Requires live `pg_stat_activity` |
| Long-term history | **Azure Monitor** | Retention without building Part 6.1 |

A mature dashboard mixes data sources panel by panel. Grafana supports this
natively — set the data source per panel, not per dashboard.

---

<a name="part-8"></a>

## Part 8 — Variables: one dashboard, many servers

Hardcoding a database name into 25 panels is a mistake you make exactly once.

**Dashboard settings → Variables → New variable**

**A query variable** — populate a dropdown from the database itself:

| Field | Value |
|---|---|
| Name | `datname` |
| Type | Query |
| Data source | `PostgreSQL-Lab` |
| Query | `SELECT datname FROM pg_database WHERE datname NOT IN ('template0','template1') ORDER BY 1` |
| Multi-value | On |
| Include All option | On |

Then use it in panels:

```sql
WHERE datname IN ($datname)     -- multi-value, quoted automatically
WHERE datname = '$datname'      -- single-value
```

> **Quoting is the classic trap.** For multi-value variables use
> `IN ($datname)` with no quotes — Grafana expands to `'a','b','c'`. For a single
> value use `'$datname'` with quotes. Mixing them up produces a syntax error that
> looks like a Grafana bug and is not.

**A data source variable** — one dashboard pointed at dev, staging, or production:

| Field | Value |
|---|---|
| Name | `pgserver` |
| Type | Data source |
| Type filter | PostgreSQL |

Set each panel's data source to `${pgserver}`. Now a dropdown switches every
panel to another server at once. This is the single highest-leverage Grafana
feature for anyone running more than one database.

**An interval variable** — user-selectable resolution:

| Name | `bucket` · Type: Interval · Values: `1m,5m,15m,1h,6h` |

Then `$__timeGroupAlias(ts, $bucket)` instead of `$__interval`.

**Useful built-ins:** `$__from` / `$__to` (epoch ms), `$__interval`,
`$__interval_ms`, `$__name`, `$__dashboard`, `$__user.login`.

---

<a name="part-9"></a>

## Part 9 — Alerting

Grafana's unified alerting has four moving parts, and understanding the split is
most of the learning curve:

| Component | Role |
|---|---|
| **Alert rule** | A query plus a condition, evaluated on a schedule |
| **Contact point** | Where a notification goes — email, Teams, PagerDuty, webhook |
| **Notification policy** | Routing tree: which alerts reach which contact point |
| **Silence** | Temporary suppression, e.g. during maintenance |

### Building an alert: connection saturation

### **Alerting → Alert rules → New alert rule**

**1. Query section (A):**

```sql
SELECT
    now() AS time,
    (SELECT count(*) FROM pg_stat_activity WHERE backend_type='client backend')::float
    / NULLIF(current_setting('max_connections')::float, 0) * 100 AS value;
```

### **2. Expression (B):** Reduce → Last → of A

### **3. Expression (C):** Threshold → `IS ABOVE 85` → **set as alert condition**

### **4. Evaluation:**

- Folder: `PostgreSQL` · Evaluation group: `pg-1m` · Interval: `1m`
- **Pending period: `5m`** ← the anti-noise setting. The condition must hold
  continuously for 5 minutes before firing. Without it, a momentary spike pages
  someone at 03:00.

### **5. Labels and annotations:**

```
Summary:     Connection pool {{ $values.B.Value | printf "%.0f" }}% utilised
Description: Above 85% of max_connections for 5 minutes. Check for connection
             leaks or a pooler misconfiguration.
Severity:    warning
```

> Write annotations for whoever gets woken up. "Connections high" is useless at
> 03:00. Name the likely cause and the first thing to check.

### Alerts worth having on a PostgreSQL server

| Alert | Condition | Pending | Severity |
|---|---|---|---|
| Connection saturation | > 85% of max | 5m | warning |
| Connection exhaustion | > 95% of max | 1m | critical |
| Replication lag | > 60 s | 5m | critical |
| Longest transaction | > 30 min | 5m | warning |
| Deadlock rate | > 0 in 5m | 0m | warning |
| Cache hit ratio | < 90% | 15m | info |
| Disk space | > 85% used | 5m | critical |
| XID wraparound | > 80% to freeze | 30m | critical |
| Blocked sessions | any > 60 s | 2m | warning |
| Autovacuum stalled | dead tuples > 20% and no vacuum in 24h | 1h | warning |

### Contact point: Microsoft Teams

**Alerting → Contact points → Add** → integration **Microsoft Teams** → paste an
incoming webhook URL from the target channel.

> **Design alerts for action, not awareness.** Every alert that fires without a
> clear response trains people to ignore alerts. If nobody would do anything at
> 03:00, it belongs on a dashboard, not in a pager.

---

<a name="part-10"></a>

## Part 10 — Provisioning as code

Click-built dashboards are fine to learn on and a liability to operate. Grafana
reads YAML at startup so data sources, dashboards, and alerts can live in git.

**Data source** — `/etc/grafana/provisioning/datasources/postgres.yaml`:

```yaml
apiVersion: 1
datasources:
  - name: PostgreSQL-Lab
    type: postgres
    access: proxy
    url: postgres:5432
    database: labdb
    user: grafana_ro
    jsonData:
      sslmode: disable
      maxOpenConns: 10
      maxIdleConns: 2
      connMaxLifetime: 14400
      postgresVersion: 1600
      timescaledb: false
    secureJsonData:
      password: ${POSTGRES_GRAFANA_PASSWORD}   # from environment, never literal
```

**Dashboard loader** — `/etc/grafana/provisioning/dashboards/default.yaml`:

```yaml
apiVersion: 1
providers:
  - name: 'PostgreSQL dashboards'
    orgId: 1
    folder: 'PostgreSQL'
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    allowUiUpdates: true
    options:
      path: /var/lib/grafana/dashboards
```

Drop exported dashboard JSON into that path.

**Wire into Compose:**

```yaml
  grafana:
    image: grafana/grafana-oss:latest
    environment:
      - POSTGRES_GRAFANA_PASSWORD=${POSTGRES_GRAFANA_PASSWORD}
    volumes:
      - ./provisioning:/etc/grafana/provisioning
      - ./dashboards:/var/lib/grafana/dashboards
      - grafana-storage:/var/lib/grafana
```

> **Never commit a password to the repository.** `secureJsonData` with `${VAR}`
> reads from the environment; supply it from your secret store or a
> gitignored `.env`.

### Community dashboards — use them as a starting point

Grafana's dashboard library has well-maintained PostgreSQL dashboards. Import via
**Dashboards → New → Import** and paste an ID.

Two caveats: most assume **Prometheus + postgres_exporter**, not a direct SQL data
source, so panels will be empty if you have not deployed that stack. And an
imported dashboard teaches you nothing. Build Part 6 by hand first, then import
for comparison — you will find panels you did not think of, and understand why
they are there.

---

<a name="part-11"></a>

## Part 11 — Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| **"Data is missing a time field"** | *Format as: Time series* with no valid `time` column | Alias a timestamp column `AS time`, or switch to *Table* |
| **Panel ignores the time picker** | No `$__timeFilter()` | Add it to the `WHERE` clause |
| **Graph is a flat rising line** | Graphing a cumulative counter raw | Compute a delta/rate — Part 6.3 |
| **Sudden huge negative spike** | `pg_stat_reset()` or a restart | Wrap deltas in `GREATEST(..., 0)` |
| **Empty panel, no error** | No data in range, or the snapshot job is not running | `SELECT count(*), max(ts) FROM monitor.db_stats_history` |
| **`query` column is NULL in pg_stat_activity** | Missing `pg_monitor` | `GRANT pg_monitor TO grafana_ro` |
| **`<insufficient privilege>` in query text** | Same | Same |
| **`pg_stat_statements does not exist`** | Not in `shared_preload_libraries` | Add it, restart the server |
| **`column "total_time" does not exist`** | PG13 renamed it | Use `total_exec_time` / `mean_exec_time` |
| **Series all named "value"** | No text column and no alias | Alias the column, or add a `metric` column |
| **Jagged, aliased graph** | `$__interval` smaller than the snapshot interval | Set *Min time interval* on the data source |
| **Variable produces a syntax error** | Quoting mismatch | `IN ($var)` for multi, `'$var'` for single |
| **Grafana slows the database** | Refresh too fast, or expensive panels | Increase refresh; check `pg_stat_statements` for Grafana's own queries |
| **Everything lost after restart** | No volume mount | Add `-v grafana-storage:/var/lib/grafana` |
| **Azure Monitor returns nothing** | Missing RBAC, or diagnostics not enabled | Grant Monitoring Reader; enable the diagnostic setting |

**The general debugging move:** in the panel editor, open **Query inspector →
Query** to see the fully expanded SQL with every macro and variable substituted.
Copy that into psql and run it. Nine times out of ten the problem is visible
immediately, and it is usually not Grafana.

---

<a name="part-12"></a>

## Part 12 — Where to go next

### **Deepen the current dashboard**

- Add **annotations** from a deployments table so releases appear as vertical
  lines — correlating a latency change with a deploy is the fastest root-cause
  tool there is.
- Build a second dashboard scoped to a single table, driven by a variable.
- Add **exemplars** or panel links that drill from a slow query straight into a
  detail view.

### **Graduate to the production stack**

- Deploy **postgres_exporter** + **Prometheus**, and rebuild Part 6.3 using
  `rate()`. You will appreciate what the snapshot table was doing manually.
- Add **node_exporter** for host CPU, memory, and disk alongside database
  metrics — most "database problems" are host problems.
- Explore **Loki** for PostgreSQL log aggregation, so log lines sit next to
  metrics on the same time axis.

### **Skills that transfer**

- **PromQL**, if you go the Prometheus route. Different language, identical
  concepts.
- **Transformations** — Grafana's in-panel joins and calculations, which often
  remove the need for complex SQL.
- **Dashboard JSON** — read it once and every UI option becomes obvious.

### **Reference**

- Grafana documentation: `grafana.com/docs`
- PostgreSQL monitoring chapter: `postgresql.org/docs/current/monitoring.html`
- Dashboard library: `grafana.com/grafana/dashboards`

---

## Appendix A — Quick reference card

### **PostgreSQL macros**

```
$__timeFilter(col)              WHERE clause for the time picker
$__timeGroupAlias(col, '5m')    bucket + alias as "time"   ← use this
$__timeGroup(col, $__interval)  bucket with dynamic width
$__timeFrom() / $__timeTo()     range boundaries
$__unixEpochFilter(col)         for epoch-integer columns
$__interval                     suggested bucket width
```

### **Time-series query skeleton**

```sql
SELECT
    $__timeGroupAlias(ts, $__interval),
    some_label AS metric,
    avg(value)  AS "Readable Name"
FROM   table
WHERE  $__timeFilter(ts)
GROUP  BY 1, 2
ORDER  BY 1;
```

### **Counter-to-rate skeleton**

```sql
GREATEST(max(counter) - min(counter), 0)
  / NULLIF(EXTRACT(epoch FROM (max(ts) - min(ts))), 0) AS "per second"
```

### **Panel checklist**

```
[ ] Format as (Time series vs Table) correct
[ ] $__timeFilter present on historical panels
[ ] ORDER BY time ascending
[ ] Columns aliased to readable legends
[ ] Unit set
[ ] Thresholds where a number has a meaning
[ ] Description written
[ ] Verified against the real query in Query inspector
```
