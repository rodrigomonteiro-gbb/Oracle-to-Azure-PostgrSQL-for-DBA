# KQL Query Pack — Azure Database for PostgreSQL Flexible Server

## Diagnostics in Log Analytics (`ArcBox-law`, Central US) — Resource-Specific tables

---

## Getting started — opening the KQL editor

There are two ways into the query editor. **They are not equivalent** — pick the right one or some queries in this pack will silently return partial results.

### Path A — Start from the workspace ✅ *use this one for this pack*

1. Go to **portal.azure.com** and sign in to the tenant that holds `ArcBox-law`.
2. In the top search bar, type **`ArcBox-law`** and select it under **Resources**.
   *(Alternatively: search **Log Analytics workspaces** and pick it from the list — confirm **Region = Central US** if you have similarly named workspaces.)*
3. In the left menu, under **General**, click **Logs**.
4. A **Queries** dialog usually opens with sample query cards — close it (**X**). You want the blank editor.
5. Confirm the **scope pill** at the top left reads **ArcBox-law**. That is your proof you are querying the right workspace.
6. Paste a query into the editor and press **Shift+Enter** (or click **▷ Run**).

**Why this path:** scoping to the workspace shows **every server** sending diagnostics to it, so the `_server = ""` parameter behaves as designed (empty = all servers), and the multi-server queries (§5.12) work.

### Path B — Start from the PostgreSQL server

1. Search for your flexible server → open it.
2. Left menu → **Monitoring** → **Logs**.
3. Same editor, but scoped to that single server.

> ⚠️ **The catch with Path B:** Azure silently injects a resource filter. Cross-server queries — including the §5.12 fleet overview — return only that one server, and you will think the query is broken. Path B is fine for single-server troubleshooting; **use Path A for everything in this pack.**

### First three things to do once you are in

**1. Confirm the tables exist.** In the left-hand pane of the editor, switch to the **Tables** tab and expand **LogManagement**. You should see `PGSQLServerLogs`, `PGSQLPgStatActivitySessions`, `AzureMetrics`, and the rest. If the PGSQL tables are absent, no data has arrived yet.

**2. Set the time picker to "Set in query".** There is a **Time range** dropdown above the editor, defaulting to *Last 24 hours*.

> ⚠️ **Every query in this pack carries its own `TimeGenerated` filter.** If the picker is also set to a range, the portal applies **the intersection of both** — which is the single most common cause of "my query returns nothing". Set the picker to **Set in query** and let the `let` block own the time window.

**3. Run the §0.3 flow check** before troubleshooting anything else. It tells you which categories are actually arriving.

### Editor mechanics worth knowing

| Action | How |
|---|---|
| Run query | **Shift+Enter**, or **▷ Run** |
| Run only part of a query | Select the lines → **Shift+Enter** |
| Multiple queries in one tab | Separate them with a **blank line**; cursor position decides which runs |
| New tab | **+** next to the tab strip — keep several queries side by side |
| Save as function | **Save** → **Save as function**, give it an alias (see §6.1) |
| Pin a chart to a dashboard | Run → **Pin to** → **Azure dashboard** |
| Export results | **Export** → CSV, or **Open in Excel** |
| Format the query | **Shift+Alt+F** |
| IntelliSense / column names | **Ctrl+Space** — the fastest way to confirm a schema |

### Suggested practice order

Each step builds on the last:

1. **§0.3** flow check — proves data is arriving and which categories are live
2. **§0.4** metric inventory — tells you immediately whether enhanced metrics are enabled
3. **§2** CPU and Memory — the simplest chart, a quick win
4. **§1.1 → §1.2** Connections vs CPU — run both so you *see* why the axis-scaling problem matters
5. **§1.3** correlation — the first genuinely analytical query

> If step 2 shows no `xact_commit` / `blks_hit` / `numbackends`, stop and set **`metrics.collector_database_activity = ON`** (server → **Settings** → **Server parameters** → search → ON → **Save**; dynamic, no restart). Wait ~5 minutes, re-run step 2. The §3 transaction queries depend on it.

> **Note on shared workspaces:** `ArcBox-law` may collect from many resource types. Every query in this pack filters on either `ResourceProvider == "MICROSOFT.DBFORPOSTGRESQL"` or a PGSQL-specific table, so you will not pick up noise from VMs or Arc agents.

---

## 0. Before you run anything — what you actually have

### 0.1 Your tables (Resource-specific mode)

Because you chose **Resource specific**, your logs land in dedicated tables — *not* in `AzureDiagnostics`. This is the better choice: typed columns, cheaper queries, no `_s` / `_d` suffixes.

| Portal log category (what you ticked) | **Table to query** | Collection frequency |
|---|---|---|
| PostgreSQL Server Logs | **`PGSQLServerLogs`** | 10 seconds |
| PostgreSQL Sessions data | **`PGSQLPgStatActivitySessions`** | **5 minutes** |
| PostgreSQL Query Store Runtime | **`PGSQLQueryStoreRuntime`** | 5 min (or `pg_qs.interval_length_minutes`) |
| PostgreSQL Query Store Wait Statistics | **`PGSQLQueryStoreWaits`** | 5 min (or `pg_qs.interval_length_minutes`) |
| PostgreSQL Query Store SQL Text | **`PGSQLQueryStoreQueryText`** | 5 min (or `pg_qs.interval_length_minutes`) |
| PostgreSQL Autovacuum and schema statistics | **`PGSQLAutovacuumStats`** | **30 minutes** |
| PostgreSQL remaining transactions | **`PGSQLDbTransactionsStats`** | **30 minutes** |
| PostgreSQL PgBouncer Logs | **`PGSQLPgBouncer`** | 10 seconds |
| **All Metrics** | **`AzureMetrics`** | 1 minute |

> ⚠️ **Three things that will bite you if nobody tells you.**
>
> **1. Metrics do NOT get a resource-specific table.** "Resource specific" applies to *logs* only. All platform metrics land in **`AzureMetrics`**, a shared, generically-shaped table. Every metric query below therefore uses `AzureMetrics` and filters on `MetricName`.
>
> **2. Sampling frequencies are wildly different.** Metrics arrive every **1 minute**; sessions every **5 minutes**; transaction and autovacuum stats every **30 minutes**. **Any join across these must bin to the *coarsest* grain involved**, or you will produce a chart full of gaps and think you have a data-loss problem. Every cross-source query below sets `_bin` accordingly and says why.
>
> **3. Many of the interesting metrics are OFF by default.** `xact_commit`, `xact_rollback`, `tps`, `numbackends`, `sessions_by_state`, `deadlocks`, `blks_hit`/`blks_read` are **enhanced metrics**. If a query below returns nothing, that is almost always the reason — not a broken query. See §0.4.

### 0.2 The standard parameter block

**Every query in this pack starts with this block.** Copy it, edit the top three lines, run. Nothing below the block needs changing.

```kusto
// ============================ PARAMETERS ============================
let _lookback   = 60m;                    // <-- EDIT: 15m, 4h, 1d, 7d ...
let _end        = now();                  // <-- EDIT for a fixed window (see below)
let _start      = _end - _lookback;
let _server     = "";                     // <-- EDIT: server name, "" = all servers
let _bin        = 5m;                     // <-- EDIT: chart granularity
// ====================================================================
```

**To query a fixed historical window instead of "the last N minutes"**, replace the first three lines:

```kusto
// Fixed window -- times are UTC. Incident review, post-mortem, change validation.
let _start = datetime(2026-09-15 13:00:00);
let _end   = datetime(2026-09-15 15:30:00);
let _server = "my-pg-prod-01";
let _bin    = 1m;
```

**Eastern Time convenience** (you are in `America/New_York`, the data is in UTC):

```kusto
// Type local times, query UTC. EDT = UTC-4, EST = UTC-5.
let _tzOffset = 4h;                                     // <-- 4h in EDT, 5h in EST
let _start = datetime(2026-09-15 09:00:00) + _tzOffset; // 9:00 AM local
let _end   = datetime(2026-09-15 17:00:00) + _tzOffset; // 5:00 PM local
```

> **Choosing `_bin`:** it must be **≥ the source's collection frequency**, or you create empty buckets.
> Metrics-only → `1m` is safe. Anything touching sessions → **`5m` minimum**. Anything touching transaction/autovacuum stats → **`30m` minimum**.
> Rule of thumb for readability: `_bin ≈ _lookback / 100`. (1h → 1m; 1d → 15m; 7d → 1h.)

### 0.3 Confirm data is flowing — run this first

**Version A — explicit table list.** Use this when you know every table exists.

```kusto
let _lookback = 24h;
let _end      = now();
let _start    = _end - _lookback;
union withsource=SourceTable
    PGSQLServerLogs, PGSQLPgStatActivitySessions, PGSQLQueryStoreRuntime,
    PGSQLQueryStoreWaits, PGSQLQueryStoreQueryText, PGSQLAutovacuumStats,
    PGSQLDbTransactionsStats, PGSQLPgBouncer, AzureMetrics
| where TimeGenerated between (_start .. _end)
| summarize Records      = count(),
            FirstSeen    = min(TimeGenerated),
            LastSeen     = max(TimeGenerated),
            MinutesStale = datetime_diff('minute', now(), max(TimeGenerated))
        by SourceTable
| extend Status = case(MinutesStale <= 10,  "✅ Current",
                       MinutesStale <= 60,  "⚠️ Lagging",
                                            "❌ Stale / not flowing")
| order by Records desc
```

> ⚠️ **Do NOT name the source column `TableName`.** `union withsource=X` creates a new column called `X`, and it **must not collide with a column that already exists in any unioned table**. `PGSQLServerLogs` has a real `TableName` column (the PostgreSQL table involved in an error), so `withsource=TableName` fails with:
> ```
> union: column named 'TableName' already exists
> ```
> `SourceTable`, `SrcTable`, or `_Origin` are all safe.

**Version B — wildcard.** Use this when a category may not have arrived yet.

```kusto
let _lookback = 24h;
let _end      = now();
let _start    = _end - _lookback;
union withsource=SourceTable PGSQL*, AzureMetrics
| where TimeGenerated between (_start .. _end)
| summarize Records      = count(),
            FirstSeen    = min(TimeGenerated),
            LastSeen     = max(TimeGenerated),
            MinutesStale = datetime_diff('minute', now(), max(TimeGenerated))
        by SourceTable
| extend Status = case(MinutesStale <= 10,  "✅ Current",
                       MinutesStale <= 60,  "⚠️ Lagging",
                                            "❌ Stale / not flowing")
| order by Records desc
```

**Why two versions:** Version A names each table explicitly, so it **fails outright if any one of them does not yet exist** in the workspace — which is useful when you *want* to be told a category is missing. Version B unions whatever `PGSQL*` tables are present, so it always runs; the missing category simply does not appear as a row. Version B costs marginally more (wildcard resolution) but is the safer first run on a new workspace.

> **One caveat on Version B:** `AzureMetrics` is workspace-wide. On a shared workspace like `ArcBox-law` its row count includes VMs, Arc agents, and every other resource type. To see only PostgreSQL metrics, scope it separately:
> ```kusto
> AzureMetrics
> | where TimeGenerated > ago(24h)
> | where ResourceProvider == "MICROSOFT.DBFORPOSTGRESQL"
> | summarize Records = count(), Last = max(TimeGenerated) by Resource
> ```

**How to read the result:** every table you ticked should appear. A missing table means that category is not arriving — check the diagnostic setting, or the extra server parameters that category requires (§0.4). `PGSQLAutovacuumStats` and `PGSQLDbTransactionsStats` legitimately show up to 30 minutes stale.

### 0.4 Enable the data these queries need

Several queries need server parameters that are **off by default**. Set them once, on the server, under **Settings → Server parameters** (all are dynamic — no restart):

| Parameter | Set to | Unlocks |
|---|---|---|
| `metrics.collector_database_activity` | `ON` | `xact_commit`, `xact_rollback`, `tps`, `numbackends`, `deadlocks`, `blks_hit`, `blks_read`, `tup_*`, `sessions_by_state`, `sessions_by_wait_event_type`, `temp_files`, `temp_bytes` |
| `metrics.autovacuum_diagnostics` | `ON` | `bloat_percent`, `n_dead_tup_user_tables`, autovacuum counters |
| `metrics.pgbouncer_diagnostics` | `ON` | All PgBouncer metrics (also needs `pgbouncer.enabled = on`) |
| `pg_qs.query_capture_mode` | `top` or `all` | Query Store runtime + wait data |
| `pgms_wait_sampling.query_capture_mode` | `on` | Query Store wait statistics |
| `pg_qs.emit_query_text` | `on` | Query Store SQL text |
| `track_io_timing` | `on` | `BlkReadTime` / `BlkWriteTime` in Query Store (small overhead) |

**See which metrics are actually arriving:**

```kusto
AzureMetrics
| where TimeGenerated > ago(24h)
| where ResourceProvider == "MICROSOFT.DBFORPOSTGRESQL"
| summarize Samples = count(), Last = max(TimeGenerated) by MetricName, UnitName
| order by MetricName asc
```

> **The `AzureMetrics` shape, once — then every query below makes sense:**
> `MetricName` (e.g. `cpu_percent`), `Average` / `Maximum` / `Minimum` / `Total` / `Count` (pre-aggregated per `TimeGrain`), `TimeGrain` (usually `PT1M`), `UnitName`, `Resource` (server name, **uppercase**), `_ResourceId`.
> **Pick the aggregate deliberately:** `Average` for utilization (`cpu_percent`), `Maximum` for peaks and alert thresholds, **`Total` for counters** (`xact_commit`, `connections_failed` — these are per-interval counts, and averaging them is meaningless).
>
> ⚠️ **Dimensions are not preserved in `AzureMetrics`.** Metrics split by `DatabaseName` or `State` arrive **pre-aggregated across all dimension values**. For per-database or per-state breakdowns, use the **log tables** (`PGSQLPgStatActivitySessions`), not `AzureMetrics`.

---

## 1. Connections vs CPU

**The question:** is CPU being driven by connection volume, or by something else? This is the first chart to open when a server "feels slow".

### 1.1 The chart

```kusto
// ============================ PARAMETERS ============================
let _lookback   = 60m;
let _end        = now();
let _start      = _end - _lookback;
let _server     = "";
let _bin        = 1m;
// ====================================================================
AzureMetrics
| where TimeGenerated between (_start .. _end)
| where ResourceProvider == "MICROSOFT.DBFORPOSTGRESQL"
| where isempty(_server) or Resource =~ _server
| where MetricName in ("cpu_percent", "active_connections")
| summarize Value = avg(Average) by MetricName, bin(TimeGenerated, _bin)
| project TimeGenerated,
          Series = case(MetricName == "cpu_percent",        "CPU %",
                        MetricName == "active_connections", "Active connections",
                                                            MetricName),
          Value
| render timechart
    with (title="Connections vs CPU", ytitle="CPU % / Connection count", xtitle="Time (UTC)")
```

> ⚠️ **Different units on one axis.** CPU tops out at 100; connections may be in the hundreds or thousands, which flattens the CPU line into the floor. Use §1.2 when the scales diverge.

### 1.2 Normalized to 0–100 — both lines readable

```kusto
let _lookback = 60m;
let _end      = now();
let _start    = _end - _lookback;
let _server   = "";
let _bin      = 1m;
let _maxConnections = 200.0;   // <-- EDIT: your max_connections, for % scaling
AzureMetrics
| where TimeGenerated between (_start .. _end)
| where ResourceProvider == "MICROSOFT.DBFORPOSTGRESQL"
| where isempty(_server) or Resource =~ _server
| where MetricName in ("cpu_percent", "active_connections")
| summarize Value = avg(Average) by MetricName, bin(TimeGenerated, _bin)
| extend Pct = iff(MetricName == "active_connections", Value / _maxConnections * 100.0, Value)
| project TimeGenerated,
          Series = iff(MetricName == "cpu_percent", "CPU %", "Connections (% of max)"),
          Pct
| render timechart
    with (title="CPU % vs Connection utilization %", ytitle="Percent", ymin=0, ymax=100)
```

### 1.3 Are they actually correlated? — scatter + coefficient

A time chart shows two lines moving. **This tells you whether they move *together*.**

```kusto
let _lookback = 4h;
let _end      = now();
let _start    = _end - _lookback;
let _server   = "";
let _bin      = 1m;
AzureMetrics
| where TimeGenerated between (_start .. _end)
| where ResourceProvider == "MICROSOFT.DBFORPOSTGRESQL"
| where isempty(_server) or Resource =~ _server
| where MetricName in ("cpu_percent", "active_connections")
| summarize Value = avg(Average) by MetricName, bin(TimeGenerated, _bin)
| evaluate pivot(MetricName, any(Value))
| where isnotnull(cpu_percent) and isnotnull(active_connections)
| project Connections = active_connections, CPU = cpu_percent
| render scatterchart
    with (title="CPU % vs Active connections — tight diagonal = connection-driven CPU")
```

```kusto
// The number behind the picture: Pearson correlation, -1 .. +1
let _lookback = 4h;
let _end      = now();
let _start    = _end - _lookback;
let _server   = "";
let _bin      = 1m;
AzureMetrics
| where TimeGenerated between (_start .. _end)
| where ResourceProvider == "MICROSOFT.DBFORPOSTGRESQL"
| where isempty(_server) or Resource =~ _server
| where MetricName in ("cpu_percent", "active_connections")
| summarize Value = avg(Average) by MetricName, bin(TimeGenerated, _bin)
| evaluate pivot(MetricName, any(Value))
| where isnotnull(cpu_percent) and isnotnull(active_connections)
| summarize Samples   = count(),
            AvgCPU    = round(avg(cpu_percent), 1),
            AvgConns  = round(avg(active_connections), 1),
            Covariance = round(
                avg(cpu_percent * active_connections) - avg(cpu_percent) * avg(active_connections), 2),
            StdCPU     = round(stdev(cpu_percent), 3),
            StdConns   = round(stdev(active_connections), 3)
| extend Correlation = round(Covariance / (StdCPU * StdConns), 3)
| extend Interpretation = case(
      Correlation >  0.7, "Strong — CPU is connection-driven. Look at pooling / app connection behavior.",
      Correlation >  0.4, "Moderate — connections are a contributing factor, not the whole story.",
      Correlation > -0.4, "Weak — CPU is driven by something else. Check Query Store (§6).",
                          "Inverse — CPU rises as connections fall. Suspect blocking or long single queries.")
| project Samples, AvgCPU, AvgConns, Correlation, Interpretation
```

### 1.4 Connection health — succeeded vs failed

```kusto
let _lookback = 60m;
let _end      = now();
let _start    = _end - _lookback;
let _server   = "";
let _bin      = 1m;
AzureMetrics
| where TimeGenerated between (_start .. _end)
| where ResourceProvider == "MICROSOFT.DBFORPOSTGRESQL"
| where isempty(_server) or Resource =~ _server
| where MetricName in ("connections_succeeded", "connections_failed", "active_connections")
| summarize Gauge = avg(Average), Counter = sum(Total)
        by MetricName, bin(TimeGenerated, _bin)
// active_connections is a GAUGE (average it); succeeded/failed are COUNTERS (sum them).
| extend Value = iff(MetricName == "active_connections", Gauge, Counter)
| project TimeGenerated,
          Series = case(MetricName == "connections_succeeded", "Connections succeeded",
                        MetricName == "connections_failed",    "Connections failed",
                        MetricName == "active_connections",    "Active connections",
                                                               MetricName),
          Value
| render timechart with (title="Connection churn and failures", ytitle="Count per bin")
```

> ⚠️ **KQL rule this query exists to teach.** You **cannot reference a `by` (group-by) column inside a `summarize` aggregation expression**, even though it is one of the grouping keys. This fails:
> ```kusto
> | summarize Value = iff(MetricName == "active_connections", avg(Average), sum(Total))
>         by MetricName, bin(TimeGenerated, _bin)
> ```
> ```
> Reference to a column 'MetricName' in the aggregation context
> may not appear outside of an aggregate function
> ```
> **The fix pattern:** compute *both* aggregates in the `summarize`, then choose between them in a following `extend`, where `MetricName` is an ordinary column again. The legal in-`summarize` alternative is `sumif(Total, <condition>)` — but that only helps when the condition is on a **non-key** column, so the two-aggregate-then-`extend` form is the right tool here. **The same fix applies to §3.1.**

**Read it as:** a rising `connections_failed` line alongside `active_connections` plateauing near `max_connections` is connection exhaustion — the case for PgBouncer. High `connections_succeeded` churn with low `active_connections` means the application is opening and closing connections per request, which is expensive in PostgreSQL and also solved by pooling.

---

## 2. CPU and Memory

```kusto
let _lookback = 60m;
let _end      = now();
let _start    = _end - _lookback;
let _server   = "";
let _bin      = 1m;
AzureMetrics
| where TimeGenerated between (_start .. _end)
| where ResourceProvider == "MICROSOFT.DBFORPOSTGRESQL"
| where isempty(_server) or Resource =~ _server
| where MetricName in ("cpu_percent", "memory_percent")
| summarize Avg = avg(Average), Max = max(Maximum) by MetricName, bin(TimeGenerated, _bin)
| project TimeGenerated,
          Series = strcat(iff(MetricName == "cpu_percent", "CPU", "Memory"), " avg %"),
          Avg
| render timechart
    with (title="CPU and Memory utilization", ytitle="Percent", ymin=0, ymax=100)
```

**Average *and* peak together** — averages hide short spikes that cause user-visible stalls:

```kusto
let _lookback = 4h;
let _end      = now();
let _start    = _end - _lookback;
let _server   = "";
let _bin      = 5m;
AzureMetrics
| where TimeGenerated between (_start .. _end)
| where ResourceProvider == "MICROSOFT.DBFORPOSTGRESQL"
| where isempty(_server) or Resource =~ _server
| where MetricName in ("cpu_percent", "memory_percent")
| summarize AvgVal = avg(Average), MaxVal = max(Maximum)
        by MetricName, bin(TimeGenerated, _bin)
| project TimeGenerated,
          ["CPU avg"]    = iff(MetricName == "cpu_percent",    AvgVal, real(null)),
          ["CPU peak"]   = iff(MetricName == "cpu_percent",    MaxVal, real(null)),
          ["Mem avg"]    = iff(MetricName == "memory_percent", AvgVal, real(null)),
          ["Mem peak"]   = iff(MetricName == "memory_percent", MaxVal, real(null))
| render timechart with (title="CPU & Memory — average vs peak", ytitle="Percent", ymin=0, ymax=100)
```

**Saturation summary with percentiles** — the table to paste into a capacity review:

```kusto
let _lookback = 24h;
let _end      = now();
let _start    = _end - _lookback;
let _server   = "";
AzureMetrics
| where TimeGenerated between (_start .. _end)
| where ResourceProvider == "MICROSOFT.DBFORPOSTGRESQL"
| where isempty(_server) or Resource =~ _server
| where MetricName in ("cpu_percent", "memory_percent", "storage_percent",
                       "disk_iops_consumed_percentage", "disk_bandwidth_consumed_percentage")
| summarize Avg = round(avg(Average), 1),
            P50 = round(percentile(Average, 50), 1),
            P95 = round(percentile(Average, 95), 1),
            P99 = round(percentile(Average, 99), 1),
            Peak = round(max(Maximum), 1)
        by MetricName, Server = Resource
| extend Assessment = case(P95 >= 90, "🔴 Saturated — scale up",
                           P95 >= 75, "🟠 Pressured — plan headroom",
                           P95 >= 50, "🟡 Healthy with margin",
                                      "🟢 Plenty of headroom")
| order by P95 desc
```

**CPU anomaly detection** — find spikes you were not watching for:

```kusto
let _lookback = 24h;
let _end      = now();
let _start    = _end - _lookback;
let _server   = "";
let _bin      = 5m;
let _sensitivity = 2.0;   // lower = more sensitive (1.5 noisy, 3.0 conservative)
AzureMetrics
| where TimeGenerated between (_start .. _end)
| where ResourceProvider == "MICROSOFT.DBFORPOSTGRESQL"
| where isempty(_server) or Resource =~ _server
| where MetricName == "cpu_percent"
| make-series CPU = avg(Average) default=0 on TimeGenerated from _start to _end step _bin
| extend (Anomalies, AnomalyScore, ExpectedCPU) =
        series_decompose_anomalies(CPU, _sensitivity, -1, 'linefit')
// Expand the four parallel arrays back into rows so the Logs blade can chart them
| mv-expand TimeGenerated to typeof(datetime),
            CPU          to typeof(double),
            ExpectedCPU  to typeof(double),
            Anomalies    to typeof(int),
            AnomalyScore to typeof(double)
| project TimeGenerated,
          ["CPU actual"]   = CPU,
          ["CPU expected"] = ExpectedCPU,
          ["Anomaly"]      = iff(Anomalies != 0, CPU, real(null))
| render timechart
    with (title="CPU vs expected baseline — anomaly points plotted as a third series")
```

> ⚠️ **`render anomalychart` does NOT work in the Log Analytics Logs blade.** It is an Azure Data Explorer / Kusto Explorer renderer, and the portal returns:
> ```
> Failed to create visualization
> We currently don't support 'anomalychart' visualization type.
> ```
> The analysis itself is unaffected — `mv-expand` the series arrays back into rows and render a normal `timechart`, as above.

**How to read the chart:** *CPU actual* and *CPU expected* should track closely. Where they diverge, the **Anomaly** series plots a point at the actual value, so anomalies appear as isolated markers off the baseline. `Anomalies` returns `1` for an upward spike, `-1` for a dip, `0` for normal.

**Variant — anomalies as a table.** More useful than a chart when writing up an incident, because each row gives you a timestamp to feed straight into the §5.10 incident view.

```kusto
let _lookback = 24h;
let _end      = now();
let _start    = _end - _lookback;
let _server   = "";
let _bin      = 5m;
AzureMetrics
| where TimeGenerated between (_start .. _end)
| where ResourceProvider == "MICROSOFT.DBFORPOSTGRESQL"
| where isempty(_server) or Resource =~ _server
| where MetricName == "cpu_percent"
| make-series CPU = avg(Average) default=0 on TimeGenerated from _start to _end step _bin
| extend (Anomalies, AnomalyScore, ExpectedCPU) =
        series_decompose_anomalies(CPU, 2.0, -1, 'linefit')
| mv-expand TimeGenerated to typeof(datetime),
            CPU          to typeof(double),
            ExpectedCPU  to typeof(double),
            Anomalies    to typeof(int),
            AnomalyScore to typeof(double)
| where Anomalies != 0
| project TimeGenerated,
          ActualCPU   = round(CPU, 1),
          ExpectedCPU = round(ExpectedCPU, 1),
          Deviation   = round(CPU - ExpectedCPU, 1),
          Score       = round(AnomalyScore, 2),
          Direction   = iff(Anomalies == 1, "🔺 Spike", "🔻 Dip")
| order by abs(Score) desc
```

> **Tuning the two arguments that matter:**
> - **`_sensitivity`** is the threshold in standard deviations. Start at `2.0`; raise toward `3.0` on a spiky workload to cut false positives, lower toward `1.5` to catch subtler drift.
> - **`'linefit'`** is the baseline model, and is right for a window of a day or less. For multi-day windows with a daily rhythm, switch to **`'seasonal'`** so a normal 9am ramp is not flagged as an anomaly every morning.

---

## 3. Sessions and transactions — committed and rolled back

> **Two sources, deliberately.** `xact_commit` / `xact_rollback` are **enhanced metrics** (need `metrics.collector_database_activity = ON`). Session *state* detail comes from the **log** table, because `AzureMetrics` drops the `State` dimension.

### 3.1 Transactions committed vs rolled back, with sessions

```kusto
let _lookback = 60m;
let _end      = now();
let _start    = _end - _lookback;
let _server   = "";
let _bin      = 5m;   // 5m: the smallest bin that also suits session data
AzureMetrics
| where TimeGenerated between (_start .. _end)
| where ResourceProvider == "MICROSOFT.DBFORPOSTGRESQL"
| where isempty(_server) or Resource =~ _server
| where MetricName in ("xact_commit", "xact_rollback", "xact_total",
                       "active_connections", "numbackends", "tps")
| summarize Gauge = avg(Average), Counter = sum(Total)
        by MetricName, bin(TimeGenerated, _bin)
| extend Value = iff(MetricName in ("active_connections", "numbackends", "tps"),
                     Gauge,      // gauges -> average
                     Counter)    // counters -> sum
| project TimeGenerated,
          Series = case(MetricName == "xact_commit",        "Transactions committed",
                        MetricName == "xact_rollback",      "Transactions rolled back",
                        MetricName == "xact_total",         "Transactions total",
                        MetricName == "active_connections", "Active connections",
                        MetricName == "numbackends",        "Backends",
                        MetricName == "tps",                "TPS",
                                                            MetricName),
          Value
| render timechart with (title="Sessions and transactions (commit / rollback)", ytitle="Count per bin")
```

> ⚠️ **Same KQL rule as §1.4** — the conditional aggregate must live in an `extend` *after* the `summarize`, never inside it. See the callout under §1.4 for the full explanation.
>
> **If this runs but returns only `Active connections`**, that is not a query bug — it is the enhanced-metrics gate. Verify with:
> ```kusto
> AzureMetrics
> | where TimeGenerated > ago(24h)
> | where ResourceProvider == "MICROSOFT.DBFORPOSTGRESQL"
> | where MetricName in ("xact_commit","xact_rollback","xact_total","numbackends","tps")
> | summarize Samples = count(), Last = max(TimeGenerated) by MetricName
> ```
> An empty result means `metrics.collector_database_activity` is still `OFF` (§0.4). Set it, wait ~5 minutes, re-run.

### 3.2 Rollback ratio — the health signal that matters

A steady low rollback rate is normal. A **rising ratio** means the application is erroring, deadlocking, or timing out.

```kusto
let _lookback = 4h;
let _end      = now();
let _start    = _end - _lookback;
let _server   = "";
let _bin      = 5m;
let _warnPct  = 5.0;    // <-- EDIT: your alerting threshold
AzureMetrics
| where TimeGenerated between (_start .. _end)
| where ResourceProvider == "MICROSOFT.DBFORPOSTGRESQL"
| where isempty(_server) or Resource =~ _server
| where MetricName in ("xact_commit", "xact_rollback")
| summarize Value = sum(Total) by MetricName, bin(TimeGenerated, _bin)
| evaluate pivot(MetricName, any(Value))
| extend Committed  = coalesce(xact_commit, 0.0),
         RolledBack = coalesce(xact_rollback, 0.0)
| extend Total = Committed + RolledBack
| where Total > 0
| extend ["Rollback %"] = round(RolledBack / Total * 100.0, 2),
         ["Threshold %"] = _warnPct
| project TimeGenerated, ["Rollback %"], ["Threshold %"]
| render timechart with (title="Rollback ratio vs threshold", ytitle="Percent of transactions")
```

**Correlate the rollback spike with the actual errors** (this is the query that finds root cause):

```kusto
let _lookback = 4h;
let _end      = now();
let _start    = _end - _lookback;
let _server   = "";
let _bin      = 5m;
let rollbacks =
    AzureMetrics
    | where TimeGenerated between (_start .. _end)
    | where ResourceProvider == "MICROSOFT.DBFORPOSTGRESQL"
    | where isempty(_server) or Resource =~ _server
    | where MetricName == "xact_rollback"
    | summarize Rollbacks = sum(Total) by bin(TimeGenerated, _bin);
let errors =
    PGSQLServerLogs
    | where TimeGenerated between (_start .. _end)
    | where isempty(_server) or LogicalServerName =~ _server
    | where ErrorLevel in ("ERROR", "FATAL", "PANIC")
    | summarize Errors = count() by bin(TimeGenerated, _bin);
rollbacks
| join kind=fullouter errors on TimeGenerated
| project TimeGenerated = coalesce(TimeGenerated, TimeGenerated1),
          Rollbacks = coalesce(Rollbacks, 0.0),
          ["Server errors"] = coalesce(todouble(Errors), 0.0)
| order by TimeGenerated asc
| render timechart with (title="Rollbacks vs server errors — lines that move together share a cause")
```

### 3.3 Sessions by state — from the log table, where the detail survives

```kusto
let _lookback = 4h;
let _end      = now();
let _start    = _end - _lookback;
let _server   = "";
let _bin      = 5m;   // sessions are sampled every 5 minutes -- do not go below this
PGSQLPgStatActivitySessions
| where TimeGenerated between (_start .. _end)
| where isempty(_server) or LogicalServerName =~ _server
| where BackendType == "client backend"          // exclude autovacuum, walwriter, etc.
| summarize Sessions = dcount(ProcessId) by State, bin(TimeGenerated, _bin)
| render timechart with (title="Client sessions by state", ytitle="Sessions")
```

> **What each state means, and when to worry:**
> - **`active`** — running a query right now. Sustained high = real work or slow queries.
> - **`idle`** — connected, doing nothing. High counts are just pooling; harmless but consumes a connection slot.
> - **`idle in transaction`** — ⚠️ **the dangerous one.** Holds locks and blocks vacuum from cleaning dead tuples. A rising count here causes bloat and wraparound risk. Usually an application that forgot to commit.
> - **`idle in transaction (aborted)`** — a failed transaction never rolled back. Same damage as above.

**Catch long-running `idle in transaction` sessions specifically:**

```kusto
let _lookback = 24h;
let _end      = now();
let _start    = _end - _lookback;
let _server   = "";
let _minMinutes = 5;   // <-- EDIT: how long is "too long"
PGSQLPgStatActivitySessions
| where TimeGenerated between (_start .. _end)
| where isempty(_server) or LogicalServerName =~ _server
| where State startswith "idle in transaction"
| where isnotnull(TransactionStartTime)
| extend TxnAgeMinutes = datetime_diff('minute', CollectionTime, TransactionStartTime)
| where TxnAgeMinutes >= _minMinutes
| project TimeGenerated, DatabaseName, ApplicationName, ClientIpAddress,
          ProcessId, State, TxnAgeMinutes, WaitEventType, WaitEvent, OldestTransactionId
| order by TxnAgeMinutes desc
| take 100
```

### 3.4 Transaction wraparound risk (30-minute data)

```kusto
let _lookback = 7d;
let _end      = now();
let _start    = _end - _lookback;
let _server   = "";
let _bin      = 30m;   // this table is collected every 30 minutes -- do not go below
PGSQLDbTransactionsStats
| where TimeGenerated between (_start .. _end)
| where isempty(_server) or LogicalServerName =~ _server
| summarize RemainingXIDs = min(RemainingTransactionIdsTillWraparound)
        by DatabaseName, bin(TimeGenerated, _bin)
| render timechart with (title="Transaction IDs remaining until wraparound (lower = worse)")
```

```kusto
// Current risk ranking -- run this weekly, on every production server
let _server = "";
PGSQLDbTransactionsStats
| where TimeGenerated > ago(2h)
| where isempty(_server) or LogicalServerName =~ _server
| summarize arg_max(TimeGenerated, *) by LogicalServerName, DatabaseName
| extend PctConsumed = round(100.0 - (RemainingTransactionIdsTillWraparound / 2147483648.0 * 100.0), 2)
| project LogicalServerName, DatabaseName, TimeGenerated,
          TransactionIdFrozenAge,
          RemainingTransactionIdsTillEmergencyAV,
          RemainingTransactionIdsTillWraparound,
          RemainingMultixactIdsTillWraparound,
          AutovacuumFreezeMaxAge
| extend Risk = case(RemainingTransactionIdsTillWraparound  < 50000000,  "🔴 CRITICAL — act now",
                     RemainingTransactionIdsTillEmergencyAV < 100000000, "🟠 Emergency autovacuum approaching",
                     RemainingTransactionIdsTillWraparound  < 500000000, "🟡 Monitor",
                                                                         "🟢 Healthy")
| order by RemainingTransactionIdsTillWraparound asc
```

> **Why this matters to an Oracle DBA:** there is no Oracle equivalent. PostgreSQL transaction IDs are 32-bit and wrap around; if freezing falls behind, the database **shuts down to protect itself**. Long `idle in transaction` sessions (§3.3) are the usual cause of falling behind.

---

## 4. Sessions and IOPS (read / write)

### 4.1 Sessions with read and write IOPS

```kusto
let _lookback = 60m;
let _end      = now();
let _start    = _end - _lookback;
let _server   = "";
let _bin      = 5m;   // read_iops/write_iops are batched in 5-minute groups anyway
AzureMetrics
| where TimeGenerated between (_start .. _end)
| where ResourceProvider == "MICROSOFT.DBFORPOSTGRESQL"
| where isempty(_server) or Resource =~ _server
| where MetricName in ("read_iops", "write_iops", "iops", "active_connections")
| summarize Value = avg(Average) by MetricName, bin(TimeGenerated, _bin)
| project TimeGenerated,
          Series = case(MetricName == "read_iops",          "Read IOPS",
                        MetricName == "write_iops",         "Write IOPS",
                        MetricName == "iops",               "Total IOPS",
                        MetricName == "active_connections", "Active connections",
                                                            MetricName),
          Value
| render timechart with (title="Sessions vs Read/Write IOPS", ytitle="IOPS / Connections")
```

> ⚠️ **`read_iops`, `write_iops`, `disk_queue_depth`, `read_throughput`, `write_throughput` and the two saturation percentages are emitted every minute but *processed in five-minute batches*** — up to a **5-minute visibility delay**. Do not chase "missing" recent data at `_bin = 1m`, and account for the lag when alerting.

### 4.2 IOPS per connection — the efficiency metric

Rising IOPS with flat connections means each session is doing more I/O — a query regression, a lost index, or a plan change.

```kusto
let _lookback = 4h;
let _end      = now();
let _start    = _end - _lookback;
let _server   = "";
let _bin      = 5m;
AzureMetrics
| where TimeGenerated between (_start .. _end)
| where ResourceProvider == "MICROSOFT.DBFORPOSTGRESQL"
| where isempty(_server) or Resource =~ _server
| where MetricName in ("iops", "active_connections")
| summarize Value = avg(Average) by MetricName, bin(TimeGenerated, _bin)
| evaluate pivot(MetricName, any(Value))
| where isnotnull(iops) and active_connections > 0
| project TimeGenerated,
          ["IOPS per connection"] = round(iops / active_connections, 2),
          ["Total IOPS"]          = iops,
          ["Connections"]         = active_connections
| render timechart with (title="I/O efficiency — IOPS per active connection")
```

### 4.3 Storage saturation — are you hitting the IOPS ceiling?

```kusto
let _lookback = 24h;
let _end      = now();
let _start    = _end - _lookback;
let _server   = "";
let _bin      = 5m;
AzureMetrics
| where TimeGenerated between (_start .. _end)
| where ResourceProvider == "MICROSOFT.DBFORPOSTGRESQL"
| where isempty(_server) or Resource =~ _server
| where MetricName in ("disk_iops_consumed_percentage", "disk_bandwidth_consumed_percentage",
                       "disk_queue_depth", "storage_percent")
| summarize Value = avg(Average) by MetricName, bin(TimeGenerated, _bin)
| render timechart with (title="Storage saturation — IOPS %, bandwidth %, queue depth, storage %")
```

**Read/write mix** — tells you whether to tune for reads (indexes, cache, replicas) or writes (WAL, checkpoints, autovacuum):

```kusto
let _lookback = 24h;
let _end      = now();
let _start    = _end - _lookback;
let _server   = "";
let _bin      = 15m;
AzureMetrics
| where TimeGenerated between (_start .. _end)
| where ResourceProvider == "MICROSOFT.DBFORPOSTGRESQL"
| where isempty(_server) or Resource =~ _server
| where MetricName in ("read_iops", "write_iops")
| summarize Value = avg(Average) by MetricName, bin(TimeGenerated, _bin)
| evaluate pivot(MetricName, any(Value))
| extend R = coalesce(read_iops, 0.0), W = coalesce(write_iops, 0.0)
| where (R + W) > 0
| project TimeGenerated,
          ["Read %"]  = round(R / (R + W) * 100.0, 1),
          ["Write %"] = round(W / (R + W) * 100.0, 1)
| render areachart with (title="Read/Write IOPS mix", ytitle="Percent of total IOPS", ymin=0, ymax=100)
```

---

## 5. Combinations worth having — the ones that answer real questions

### 5.1 One-screen server health

Six normalized signals on one chart. **This is the query to pin to a dashboard.**

```kusto
let _lookback = 4h;
let _end      = now();
let _start    = _end - _lookback;
let _server   = "";
let _bin      = 5m;
let _maxConnections = 200.0;   // <-- EDIT
AzureMetrics
| where TimeGenerated between (_start .. _end)
| where ResourceProvider == "MICROSOFT.DBFORPOSTGRESQL"
| where isempty(_server) or Resource =~ _server
| where MetricName in ("cpu_percent", "memory_percent", "storage_percent",
                       "disk_iops_consumed_percentage", "active_connections",
                       "disk_bandwidth_consumed_percentage")
| summarize Value = avg(Average) by MetricName, bin(TimeGenerated, _bin)
| extend Normalized = iff(MetricName == "active_connections",
                          Value / _maxConnections * 100.0, Value)
| project TimeGenerated,
          Series = case(MetricName == "cpu_percent",                        "CPU %",
                        MetricName == "memory_percent",                     "Memory %",
                        MetricName == "storage_percent",                    "Storage %",
                        MetricName == "disk_iops_consumed_percentage",      "Disk IOPS %",
                        MetricName == "disk_bandwidth_consumed_percentage", "Disk BW %",
                        MetricName == "active_connections",                 "Connections % of max",
                                                                            MetricName),
          Normalized
| render timechart with (title="Server health — all signals normalized to %", ymin=0, ymax=100)
```

### 5.2 Cache hit ratio — the classic tuning signal

PostgreSQL's equivalent of Oracle's buffer cache hit ratio. **Below ~95% on an OLTP workload means memory pressure or missing indexes.**

```kusto
let _lookback = 4h;
let _end      = now();
let _start    = _end - _lookback;
let _server   = "";
let _bin      = 5m;
AzureMetrics
| where TimeGenerated between (_start .. _end)
| where ResourceProvider == "MICROSOFT.DBFORPOSTGRESQL"
| where isempty(_server) or Resource =~ _server
| where MetricName in ("blks_hit", "blks_read")
| summarize Value = sum(Total) by MetricName, bin(TimeGenerated, _bin)
| evaluate pivot(MetricName, any(Value))
| extend Hit = coalesce(blks_hit, 0.0), Read = coalesce(blks_read, 0.0)
| where (Hit + Read) > 0
| project TimeGenerated,
          ["Cache hit %"] = round(Hit / (Hit + Read) * 100.0, 2),
          ["Target 95%"]  = 95.0
| render timechart with (title="Buffer cache hit ratio", ytitle="Percent", ymin=80, ymax=100)
```

### 5.3 Workload profile — throughput, tuples, temp files

Temp files are the giveaway for under-sized `work_mem`: sorts and hashes spilling to disk.

```kusto
let _lookback = 4h;
let _end      = now();
let _start    = _end - _lookback;
let _server   = "";
let _bin      = 5m;
AzureMetrics
| where TimeGenerated between (_start .. _end)
| where ResourceProvider == "MICROSOFT.DBFORPOSTGRESQL"
| where isempty(_server) or Resource =~ _server
| where MetricName in ("tup_fetched", "tup_returned", "tup_inserted",
                       "tup_updated", "tup_deleted", "temp_files", "deadlocks")
| summarize Value = sum(Total) by MetricName, bin(TimeGenerated, _bin)
| render timechart with (title="Workload profile — tuples, temp files, deadlocks", ytitle="Count per bin")
```

### 5.4 Top queries by total time — where the CPU actually goes

When §1.3 says CPU is *not* connection-driven, this is the next query.

```kusto
let _lookback = 4h;
let _end      = now();
let _start    = _end - _lookback;
let _server   = "";
let _topN     = 15;
PGSQLQueryStoreRuntime
| where TimeGenerated between (_start .. _end)
| where isempty(_server) or LogicalServerName =~ _server
| where IsSystemQuery == false
| summarize TotalDurationMs = sum(TotalExecDurationMs),
            Calls           = sum(Calls),
            MeanMs          = round(avg(MeanExecDurationMs), 2),
            MaxMs           = round(max(MaxExecDurationMs), 2),
            Rows            = sum(Rows),
            SharedRead      = sum(SharedBlksRead),
            SharedHit       = sum(SharedBlksHit),
            TempWritten     = sum(TempBlksWritten)
        by QueryId, QueryType
| extend ["Cache hit %"] = iff(SharedHit + SharedRead > 0,
                               round(todouble(SharedHit) / (SharedHit + SharedRead) * 100.0, 1),
                               real(null))
| extend ["Avg rows/call"] = iff(Calls > 0, round(todouble(Rows) / Calls, 1), real(null))
| order by TotalDurationMs desc
| take _topN
// Attach the SQL text (requires pg_qs.emit_query_text = on)
| join kind=leftouter (
    PGSQLQueryStoreQueryText
    | where TimeGenerated between (_start .. _end)
    | summarize arg_max(TimeGenerated, QueryText) by QueryId
    | project QueryId, QueryText
  ) on QueryId
| project QueryId, QueryType, Calls,
          TotalSeconds = round(TotalDurationMs / 1000.0, 1),
          MeanMs, MaxMs, ["Avg rows/call"], ["Cache hit %"], TempWritten,
          SQL = substring(QueryText, 0, 300)
```

**Chart the same thing:**

```kusto
let _lookback = 4h;
let _end      = now();
let _start    = _end - _lookback;
let _server   = "";
PGSQLQueryStoreRuntime
| where TimeGenerated between (_start .. _end)
| where isempty(_server) or LogicalServerName =~ _server
| where IsSystemQuery == false
| summarize TotalSeconds = round(sum(TotalExecDurationMs) / 1000.0, 1) by QueryId
| order by TotalSeconds desc
| take 15
| render barchart with (title="Top 15 queries by total execution time (seconds)")
```

### 5.5 Query load over time vs CPU — proving which queries caused the spike

```kusto
let _lookback = 4h;
let _end      = now();
let _start    = _end - _lookback;
let _server   = "";
let _bin      = 5m;
let cpu =
    AzureMetrics
    | where TimeGenerated between (_start .. _end)
    | where ResourceProvider == "MICROSOFT.DBFORPOSTGRESQL"
    | where isempty(_server) or Resource =~ _server
    | where MetricName == "cpu_percent"
    | summarize CPU = avg(Average) by bin(TimeGenerated, _bin);
let qs =
    PGSQLQueryStoreRuntime
    | where TimeGenerated between (_start .. _end)
    | where isempty(_server) or LogicalServerName =~ _server
    | where IsSystemQuery == false
    | summarize QuerySeconds = sum(TotalExecDurationMs) / 1000.0,
                Calls        = sum(Calls)
            by bin(TimeGenerated, _bin);
cpu
| join kind=fullouter qs on TimeGenerated
| project TimeGenerated   = coalesce(TimeGenerated, TimeGenerated1),
          ["CPU %"]       = coalesce(CPU, 0.0),
          ["Query seconds"] = coalesce(QuerySeconds, 0.0),
          ["Calls (÷100)"]  = coalesce(todouble(Calls), 0.0) / 100.0
| order by TimeGenerated asc
| render timechart with (title="CPU vs Query Store execution time — do the peaks line up?")
```

### 5.6 Wait statistics — what the server is waiting ON

```kusto
let _lookback = 4h;
let _end      = now();
let _start    = _end - _lookback;
let _server   = "";
let _bin      = 5m;
PGSQLQueryStoreWaits
| where TimeGenerated between (_start .. _end)
| where isempty(_server) or LogicalServerName =~ _server
| summarize Samples = sum(Calls) by EventType, bin(TimeGenerated, _bin)
| render areachart with (title="Wait event types over time", ytitle="Sampled wait events")
```

> ⚠️ **The column is `Calls`, not `TotalEventCount`.** In `PGSQLQueryStoreWaits`, `Calls` is documented as *"number of the same event captured for this entry"* — entries are aggregated into time buckets, so `sum(Calls)` is the sampled wait count. `EventType` and `Event` are the correct names for the bucket and the specific event.

**Ranked wait events — Version A, subquery for the total:**

```kusto
let _lookback = 4h;
let _end      = now();
let _start    = _end - _lookback;
let _server   = "";
PGSQLQueryStoreWaits
| where TimeGenerated between (_start .. _end)
| where isempty(_server) or LogicalServerName =~ _server
| summarize Samples = sum(Calls) by EventType, Event
| extend Share = round(todouble(Samples) * 100.0 / toscalar(
        PGSQLQueryStoreWaits
        | where TimeGenerated between (_start .. _end)
        | where isempty(_server) or LogicalServerName =~ _server
        | summarize sum(Calls)), 2)
| order by Samples desc
| take 20
```

**Ranked wait events — Version B, single pass with `as`:**

```kusto
let _lookback = 4h;
let _end      = now();
let _start    = _end - _lookback;
let _server   = "";
PGSQLQueryStoreWaits
| where TimeGenerated between (_start .. _end)
| where isempty(_server) or LogicalServerName =~ _server
| summarize Samples = sum(Calls) by EventType, Event
| as Waits
| extend Share = round(todouble(Samples) * 100.0 / toscalar(Waits | summarize sum(Samples)), 2)
| order by Samples desc
| take 20
```

**Why two versions:** Version A re-reads the raw table to compute the denominator — correct, but it scans `PGSQLQueryStoreWaits` **twice**, which matters on a wide window. Version B names the already-aggregated result with `as Waits` and totals **that** instead, so the source table is read once. **Prefer Version B**; Version A is kept because the subquery pattern is worth recognizing and is easier to adapt when the denominator needs a *different* filter than the numerator.

**🎁 BONUS — waits attributed to the queries causing them.** Wait analysis only pays off when you can name the query, and this is where the `QueryId` in the waits table earns its keep.

```kusto
let _lookback = 4h;
let _end      = now();
let _start    = _end - _lookback;
let _server   = "";
PGSQLQueryStoreWaits
| where TimeGenerated between (_start .. _end)
| where isempty(_server) or LogicalServerName =~ _server
| where QueryId != "0"                       // 0 = background worker or system call
| summarize Waits = sum(Calls), WaitTypes = make_set(EventType, 5) by QueryId
| order by Waits desc
| take 15
| join kind=leftouter (
    PGSQLQueryStoreQueryText
    | where TimeGenerated between (_start .. _end)
    | summarize arg_max(TimeGenerated, QueryText) by QueryId
  ) on QueryId
| project QueryId, Waits, WaitTypes, SQL = substring(QueryText, 0, 250)
```

> Cross-reference the `QueryId` values here against §5.4. A query that is **top by total duration AND top by waits** is blocked or I/O-bound; a query that is top by duration but **not** by waits is genuinely CPU-bound — two very different remediations.

> **Interpreting wait types:** `IO` → storage-bound, look at §4. `Lock` → contention, look for `idle in transaction` (§3.3). `LWLock` → internal contention, often heavy concurrency. `Client` → the server is waiting on the *application*, not the other way round. `IPC` / `BufferPin` → usually parallel query coordination.

**Sessions by wait event, from the session snapshots:**

```kusto
let _lookback = 4h;
let _end      = now();
let _start    = _end - _lookback;
let _server   = "";
let _bin      = 5m;
PGSQLPgStatActivitySessions
| where TimeGenerated between (_start .. _end)
| where isempty(_server) or LogicalServerName =~ _server
| where BackendType == "client backend"
| where isnotempty(WaitEventType)
| summarize Sessions = count() by WaitEventType, bin(TimeGenerated, _bin)
| render columnchart with (title="Client sessions waiting, by wait event type", kind=stacked)
```

### 5.7 Errors and server log health

```kusto
let _lookback = 24h;
let _end      = now();
let _start    = _end - _lookback;
let _server   = "";
let _bin      = 15m;
PGSQLServerLogs
| where TimeGenerated between (_start .. _end)
| where isempty(_server) or LogicalServerName =~ _server
| where ErrorLevel in ("ERROR", "FATAL", "PANIC", "WARNING")
| summarize Events = count() by ErrorLevel, bin(TimeGenerated, _bin)
| render timechart with (title="Server log events by severity", ytitle="Events per bin")
```

```kusto
// Most frequent errors, normalized so variable values collapse into one pattern
let _lookback = 24h;
let _end      = now();
let _start    = _end - _lookback;
let _server   = "";
PGSQLServerLogs
| where TimeGenerated between (_start .. _end)
| where isempty(_server) or LogicalServerName =~ _server
| where ErrorLevel in ("ERROR", "FATAL", "PANIC")
| extend Pattern = replace_regex(Message, @'\d+', 'N')      // strip numbers
| extend Pattern = replace_regex(Pattern, @'"[^"]*"', '"X"') // strip quoted literals
| summarize Occurrences = count(),
            FirstSeen   = min(TimeGenerated),
            LastSeen    = max(TimeGenerated),
            SampleCode  = any(SqlErrorCode),
            Databases   = make_set(SchemaName, 5)
        by Pattern, ErrorLevel
| order by Occurrences desc
| take 25
```

```kusto
// Connection-related failures specifically -- auth, limits, terminations
let _lookback = 24h;
let _end      = now();
let _start    = _end - _lookback;
let _server   = "";
PGSQLServerLogs
| where TimeGenerated between (_start .. _end)
| where isempty(_server) or LogicalServerName =~ _server
| where Message has_any ("too many clients", "authentication failed", "connection limit",
                         "terminating connection", "could not connect", "remaining connection slots",
                         "SSL", "password")
| summarize Count = count(), Sample = any(Message), LastSeen = max(TimeGenerated)
        by ErrorLevel, SqlErrorCode
| order by Count desc
```

### 5.8 PgBouncer — pooling effectiveness

```kusto
let _lookback = 4h;
let _end      = now();
let _start    = _end - _lookback;
let _server   = "";
let _bin      = 5m;
AzureMetrics
| where TimeGenerated between (_start .. _end)
| where ResourceProvider == "MICROSOFT.DBFORPOSTGRESQL"
| where isempty(_server) or Resource =~ _server
| where MetricName in ("client_connections_active", "client_connections_waiting",
                       "server_connections_active", "server_connections_idle",
                       "total_pooled_connections", "num_pools")
| summarize Value = avg(Average) by MetricName, bin(TimeGenerated, _bin)
| render timechart with (title="PgBouncer pool state", ytitle="Connections")
```

> **`client_connections_waiting` above zero is the signal that matters** — clients are queued waiting for a backend. Either the pool is too small or queries are holding backends too long.

```kusto
// Pooling ratio: how many client connections each real backend serves
let _lookback = 4h;
let _end      = now();
let _start    = _end - _lookback;
let _server   = "";
let _bin      = 5m;
AzureMetrics
| where TimeGenerated between (_start .. _end)
| where ResourceProvider == "MICROSOFT.DBFORPOSTGRESQL"
| where isempty(_server) or Resource =~ _server
| where MetricName in ("client_connections_active", "server_connections_active")
| summarize Value = avg(Average) by MetricName, bin(TimeGenerated, _bin)
| evaluate pivot(MetricName, any(Value))
| where server_connections_active > 0
| project TimeGenerated,
          ["Clients per backend"] = round(client_connections_active / server_connections_active, 2)
| render timechart with (title="Pooling efficiency — clients served per server connection")
```

### 5.9 Autovacuum, dead tuples and bloat (30-minute data)

```kusto
let _lookback = 7d;
let _end      = now();
let _start    = _end - _lookback;
let _server   = "";
let _bin      = 30m;   // this table is collected every 30 minutes
PGSQLAutovacuumStats
| where TimeGenerated between (_start .. _end)
| where isempty(_server) or LogicalServerName =~ _server
| summarize DeadRows = sum(DeadRowsCount),
            LiveRows = sum(LiveRowsCount)
        by DatabaseName, bin(TimeGenerated, _bin)
| extend ["Dead row %"] = iff(LiveRows + DeadRows > 0,
                              round(todouble(DeadRows) / (LiveRows + DeadRows) * 100.0, 2),
                              real(null))
| project TimeGenerated, DatabaseName, ["Dead row %"]
| render timechart with (title="Dead row percentage by database — rising = autovacuum falling behind")
```

> ⚠️ **Two schema facts that will trip you up in this table.**
>
> **1. The columns are `DeadRowsCount` / `LiveRowsCount`** — not `DeadTuples` / `LiveTuples`.
>
> **2. Two column names are genuinely misspelled in the shipped schema** — **`SeqentialScansCount`** and **`RowsFromSeqentialScansCount`** (missing the "u" in *Sequential*). You must type the typo. This is not a documentation error; it is the actual column name.
>
> Also note this table aggregates **per schema**, not per table — `SchemaName` is a grouping column, and `TablesCount` tells you how many tables each row covers.
>
> **Whenever a column fails to resolve, `<TableName> | take 10` settles it in seconds.** That is faster than any documentation lookup.

**Current bloat ranking by schema — the actionable version:**

```kusto
let _server = "";
PGSQLAutovacuumStats
| where TimeGenerated > ago(2h)
| where isempty(_server) or LogicalServerName =~ _server
| summarize arg_max(TimeGenerated, *) by LogicalServerName, DatabaseName, SchemaName
| extend DeadPct = iff(LiveRowsCount + DeadRowsCount > 0,
                       round(todouble(DeadRowsCount) / (LiveRowsCount + DeadRowsCount) * 100.0, 2),
                       real(null))
| project LogicalServerName, DatabaseName, SchemaName, TimeGenerated,
          TablesCount, LiveRowsCount, DeadRowsCount, DeadPct,
          AutovacuumCount, AutoanalyzeCount,
          ModificationsSinceAnalyzeCount
| extend Assessment = case(DeadPct > 30, "🔴 Heavy bloat — investigate autovacuum settings",
                           DeadPct > 20, "🟠 Elevated — monitor",
                           DeadPct > 10, "🟡 Normal for a write-heavy schema",
                                         "🟢 Healthy")
| order by DeadPct desc
```

**Why both:** the timechart shows the **trend** — whether autovacuum is keeping up or steadily losing ground. The ranking table shows the **current state per schema**, with `ModificationsSinceAnalyzeCount` to tell you whether statistics are also going stale. Use the chart to decide *if* there is a problem, the table to decide *where*.

**🎁 BONUS 1 — HOT update ratio.** This is the write-amplification cost of indexing, measured in production.

```kusto
let _lookback = 24h;
let _end      = now();
let _start    = _end - _lookback;
let _server   = "";
PGSQLAutovacuumStats
| where TimeGenerated between (_start .. _end)
| where isempty(_server) or LogicalServerName =~ _server
| summarize Updated = sum(RowsUpdatedCount), HotUpdated = sum(RowsHotUpdatedCount)
        by DatabaseName, SchemaName
| where Updated > 0
| extend ["HOT %"] = round(todouble(HotUpdated) / Updated * 100.0, 1)
| project DatabaseName, SchemaName, Updated, HotUpdated, ["HOT %"]
| extend Assessment = case(["HOT %"] > 80, "🟢 Excellent — indexes aren't taxing updates",
                           ["HOT %"] > 50, "🟡 Moderate",
                                           "🔴 Low — indexed columns are being updated often")
| order by Updated desc
```

> **Why this matters:** a **HOT (Heap-Only Tuple)** update writes the new row version on the same page and skips index maintenance entirely — but only when **no indexed column changed**. A low HOT percentage on a high-update schema means you have indexed a frequently-updated column, HOT is disabled, and every update now maintains every index on the table. This is the production measurement of the trade-off demonstrated in the index guide (§3, Step 6).

**🎁 BONUS 2 — sequential vs index scan ratio.** Finds schemas with missing indexes.

```kusto
let _lookback = 24h;
let _end      = now();
let _start    = _end - _lookback;
let _server   = "";
PGSQLAutovacuumStats
| where TimeGenerated between (_start .. _end)
| where isempty(_server) or LogicalServerName =~ _server
| summarize SeqScans   = sum(SeqentialScansCount),          // NOTE: schema typo is real
            IndexScans = sum(IndexScansCount),
            SeqRows    = sum(RowsFromSeqentialScansCount),  // NOTE: schema typo is real
            IdxRows    = sum(RowsFromIndexScansCount)
        by DatabaseName, SchemaName
| where SeqScans + IndexScans > 0
| extend ["Index scan %"]      = round(todouble(IndexScans) / (SeqScans + IndexScans) * 100.0, 1),
         ["Rows per seq scan"] = iff(SeqScans > 0, round(todouble(SeqRows) / SeqScans, 0), real(null))
| project DatabaseName, SchemaName, SeqScans, IndexScans, ["Index scan %"], ["Rows per seq scan"]
| order by SeqScans desc
```

> **`Rows per seq scan` is the number to read, not the raw scan count.** A high sequential-scan count returning **few rows each time** means large tables scanned for small result sets — the classic missing-index signature. High sequential-scan counts on **small** tables are entirely normal (a seq scan of a 50-row lookup table is faster than any index) and should be ignored.

### 5.10 Cross-signal incident view — everything at once, around a spike

Point `_incident` at the moment things went wrong and get every signal in one table.

```kusto
let _incident = datetime(2026-09-15 14:30:00);   // <-- EDIT: UTC time of the problem
let _window   = 30m;                             // <-- EDIT: minutes either side
let _start    = _incident - _window;
let _end      = _incident + _window;
let _server   = "";
let _bin      = 1m;
let metrics =
    AzureMetrics
    | where TimeGenerated between (_start .. _end)
    | where ResourceProvider == "MICROSOFT.DBFORPOSTGRESQL"
    | where isempty(_server) or Resource =~ _server
    | where MetricName in ("cpu_percent","memory_percent","active_connections",
                           "read_iops","write_iops","disk_queue_depth")
    | summarize Value = avg(Average) by MetricName, bin(TimeGenerated, _bin)
    | evaluate pivot(MetricName, any(Value));
let errs =
    PGSQLServerLogs
    | where TimeGenerated between (_start .. _end)
    | where isempty(_server) or LogicalServerName =~ _server
    | where ErrorLevel in ("ERROR","FATAL","PANIC")
    | summarize ErrorCount = count() by bin(TimeGenerated, _bin);
metrics
| join kind=leftouter errs on TimeGenerated
| project TimeGenerated,
          CPU     = round(cpu_percent, 1),
          Memory  = round(memory_percent, 1),
          Conns   = round(active_connections, 0),
          ReadIO  = round(read_iops, 0),
          WriteIO = round(write_iops, 0),
          Queue   = round(disk_queue_depth, 1),
          Errors  = coalesce(ErrorCount, 0)
| order by TimeGenerated asc
```

### 5.11 Day-over-day comparison — "is today different?"

```kusto
let _bin      = 15m;
let _server   = "";
let _metric   = "cpu_percent";   // <-- EDIT: any metric name
let _daysBack = 7;               // <-- EDIT: compare against N days ago
AzureMetrics
| where TimeGenerated > ago(1d) or TimeGenerated between (ago(_daysBack * 1d + 1d) .. ago(_daysBack * 1d))
| where ResourceProvider == "MICROSOFT.DBFORPOSTGRESQL"
| where isempty(_server) or Resource =~ _server
| where MetricName == _metric
| extend Period = iff(TimeGenerated > ago(1d), "Today", strcat(_daysBack, " days ago"))
| extend TimeOfDay = TimeGenerated - iff(Period == "Today", 0d, _daysBack * 1d)
| summarize Value = avg(Average) by Period, bin(TimeOfDay, _bin)
| render timechart with (title="Today vs baseline — same clock time, different day")
```

### 5.12 Multi-server fleet overview

```kusto
let _lookback = 1h;
let _end      = now();
let _start    = _end - _lookback;
AzureMetrics
| where TimeGenerated between (_start .. _end)
| where ResourceProvider == "MICROSOFT.DBFORPOSTGRESQL"
| where MetricName in ("cpu_percent","memory_percent","storage_percent","active_connections")
| summarize Value = avg(Average) by Server = Resource, MetricName
| evaluate pivot(MetricName, any(Value))
| project Server,
          ["CPU %"]       = round(cpu_percent, 1),
          ["Memory %"]    = round(memory_percent, 1),
          ["Storage %"]   = round(storage_percent, 1),
          ["Connections"] = round(active_connections, 0)
| extend Health = case(["CPU %"] > 85 or ["Memory %"] > 90 or ["Storage %"] > 90, "🔴 Attention",
                       ["CPU %"] > 70 or ["Memory %"] > 75 or ["Storage %"] > 80, "🟠 Watch",
                                                                                  "🟢 Healthy")
| order by ["CPU %"] desc
```

---

## 6. Practical notes

### 6.1 Save these as reusable functions

In the workspace: **Logs → run the query → Save → Save as function**. Then call it like a table:

```kusto
// After saving the health query as "PgHealth"
PgHealth
| where Series == "CPU %"
| where Normalized > 80
```

Functions cannot take parameters in the free editor — so **keep the `let` block inside the function with sensible defaults**, and override by wrapping the call.

### 6.2 Chart types used here, and when each fits

| `render` | Use it for |
|---|---|
| `timechart` | Anything over time — the default |
| `areachart` / `barchart with (kind=stacked)` | Composition: read/write mix, wait types, session states |
| `columnchart` | Discrete buckets, categorical comparisons |
| `scatterchart` | Correlation between two metrics (§1.3) |
| `piechart` | Share-of-total for a single window |
| *(no render)* | Tables you will read, export, or paste into a report |

> ⚠️ **`anomalychart` is NOT supported in the Log Analytics Logs blade** — it exists only in Azure Data Explorer / Kusto Explorer. For anomaly output, `mv-expand` the series back into rows and use `timechart` (§2). Other ADX-only renderers to avoid here: `ladderchart`, `pivotchart`, `timepivot`.

### 6.3 Cost control

- **Filter on `TimeGenerated` first, always** — it is the partition key and the cheapest filter you can apply.
- Prefer `summarize` over returning raw rows; you almost never need the rows.
- `PGSQLServerLogs` and `PGSQLPgBouncer` run at **10-second frequency** and are by far your highest-volume tables. Filter `ErrorLevel` early.
- All of these tables support the **Basic / Auxiliary** log plans — worth considering for high-volume, rarely-queried categories.
- **Query Store SQL text is only worth ingesting if you use it.** If §5.4 is not part of your routine, that category is pure cost.

### 6.4 Turning any query into an alert

1. Run the query and confirm it returns rows **only when the condition is true**.
2. **+ New alert rule** from the Logs blade.
3. Measure = `Table rows`, Operator = `Greater than`, Threshold = `0`.
4. Set evaluation frequency **≥ the source collection frequency** — 5 min for session data, **30 min** for autovacuum/transaction data, 5 min for the batched IOPS metrics.

**Alert-shaped example — sustained CPU:**

```kusto
let _threshold = 85.0;      // <-- EDIT
let _minutes   = 10;        // <-- EDIT: must be high for this long
AzureMetrics
| where TimeGenerated > ago(_minutes * 1m)
| where ResourceProvider == "MICROSOFT.DBFORPOSTGRESQL"
| where MetricName == "cpu_percent"
| summarize AvgCPU = avg(Average), Samples = count() by Server = Resource
| where AvgCPU > _threshold and Samples >= _minutes
```

### 6.5 If a query returns nothing — work down this list

1. **Is the time window right?** The data is **UTC**. `now()` is UTC. Your `datetime()` literals are UTC.
2. **Is `_server` correct?** `Resource` in `AzureMetrics` is typically **uppercase**; `=~` is case-insensitive, which is why every query above uses it. Confirm with `AzureMetrics | distinct Resource`.
3. **Is the metric enabled?** Enhanced, autovacuum, and PgBouncer metrics are **off by default** (§0.4).
4. **Is the collection interval longer than your bin?** Sessions = 5 min; autovacuum and transactions = 30 min.
5. **Is it the batching delay?** `read_iops`, `write_iops`, `disk_queue_depth`, throughput, and the saturation percentages lag up to **5 minutes**.
6. **Is the column name different from what you expected?** `<TableName> | take 10` settles it in seconds. Verified gotchas in these tables:
   - `PGSQLQueryStoreWaits` → the count column is **`Calls`** (not `TotalEventCount`).
   - `PGSQLAutovacuumStats` → **`DeadRowsCount` / `LiveRowsCount`**, and **`SeqentialScansCount` / `RowsFromSeqentialScansCount` are misspelled in the actual schema** — type the typo.
   - `PGSQLServerLogs` has its own **`TableName`** column, which collides with `union withsource=TableName` (§0.3).

### 6.6 Errors you will hit, and what they mean

| Error message | Cause | Fix |
|---|---|---|
| `union: column named 'X' already exists` | `withsource=X` collides with a real column in one of the unioned tables | Rename the alias — `SourceTable` (§0.3) |
| `Reference to a column 'X' in the aggregation context may not appear outside of an aggregate function` | A `by` key referenced inside a `summarize` aggregation expression | Compute both aggregates, choose in a following `extend` (§1.4) |
| `We currently don't support 'anomalychart' visualization type` | ADX-only renderer used in the Logs blade | `mv-expand` + `timechart` (§2) |
| `Failed to resolve scalar expression named 'X'` | Column does not exist in that table | `<TableName> \| take 10` and use the real name |
| Query runs, returns nothing | Usually a disabled metric, not a bug | Work down the list in §6.5 |

---

## 7. Reference

- Monitor with metrics and logs — https://learn.microsoft.com/en-us/azure/postgresql/monitor/concepts-monitoring
- Configure and access logs — https://learn.microsoft.com/en-us/azure/postgresql/monitor/how-to-configure-and-access-logs
- Supported log categories (flexible servers) — https://learn.microsoft.com/en-us/azure/azure-monitor/reference/supported-logs/microsoft-dbforpostgresql-flexibleservers-logs
- `PGSQLServerLogs` — https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/pgsqlserverlogs
- `PGSQLPgStatActivitySessions` — https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/pgsqlpgstatactivitysessions
- `PGSQLQueryStoreRuntime` — https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/pgsqlquerystoreruntime
- `PGSQLDbTransactionsStats` — https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/pgsqldbtransactionsstats
- KQL quick reference — https://learn.microsoft.com/en-us/azure/data-explorer/kql-quick-reference
- `render` operator — https://learn.microsoft.com/en-us/azure/data-explorer/kusto/query/renderoperator
