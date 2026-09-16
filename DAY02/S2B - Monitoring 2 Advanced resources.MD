# Advanced Azure Dashboarding — Parameterized Filters

## Time range · Resource Group · Instance pickers, and KQL that responds to them

**Companion to:** *KQL Query Pack — Azure Database for PostgreSQL Flexible Server* and *Building an Azure Dashboard from KQL Queries*
**Outcome:** an interactive monitoring surface with header filters that drive every tile

---

## 0. ⚠️ Read this first — the routing decision

> **Azure Dashboards cannot do what you are asking for.**
>
> An Azure portal dashboard has exactly **one** control: the global time picker. It has **no custom parameters, no dropdowns, no cascading pickers**, and no way to pass a user selection into a tile's KQL. Every tile is a frozen query.
>
> **Everything in this document is built with Azure Workbooks.** Workbooks are in the same portal, query the same `ArcBox-law` workspace, and run the same KQL — they simply add the parameter layer that dashboards lack.

| Requirement | Azure Dashboard | **Azure Workbook** | Managed Grafana |
|---|---|---|---|
| Global time picker | ✅ (one, limited) | ✅ Fully configurable | ✅ |
| **Custom dropdown filters** | ❌ | ✅ | ✅ (template variables) |
| **Cascading filters** (RG → instance) | ❌ | ✅ | ✅ |
| **Parameters inside KQL** | ❌ | ✅ `{ParamName}` | ✅ `$variable` |
| Conditional tile visibility | ❌ | ✅ | ⚠️ Limited |
| Tabs / sections | ❌ | ✅ | ✅ |
| Drill-through | ❌ | ✅ | ✅ |
| Pin to a dashboard | — | ✅ **individual parts** | ❌ |
| Cost | Free | **Free** | Paid service |

> 💡 **You do not have to abandon your dashboard.** §11 covers the hybrid: build the workbook, then **pin individual workbook parts onto the existing dashboard**. You get the parameterized experience in the workbook and the at-a-glance tiles on the dashboard.

---

## 1. Create the workbook

1. Portal → open **`ArcBox-law`**.
2. Left menu → **Monitoring** → **Workbooks**.
3. **+ New**.
4. Top toolbar → **</> Advanced Editor** to paste JSON, or **+ Add** to build visually.
5. **Save** — give it a name, subscription, resource group, and location (**Central US**).

> ⚠️ **Save the workbook in a resource group your audience can read.** Like dashboards, workbook access and *data* access are separate grants — viewers still need **Log Analytics Reader** on `ArcBox-law` or every tile will be empty.

> 📸 **SCREENSHOT 1** — new empty workbook with the Add menu open.
>
> ![New empty workbook](images/adv-01-new-workbook.png)

### 1.1 The editing model in 30 seconds

A workbook is an ordered list of **items**. Each item is one of:

| Item type | Purpose |
|---|---|
| **Parameters** | The filter controls — this is what you came for |
| **Query** | A KQL query plus a visualization |
| **Metric** | A platform-metrics chart (no KQL) |
| **Text** | Markdown headings and explanation |
| **Group** | A container — used for conditional visibility and layout |
| **Links/tabs** | Navigation between sections |

**Add a parameters item first**, at the very top. Everything below it can reference those parameters.

---

# PART I — The three filters you asked for

## 2. Filter A — Time interval dropdown

You want: **5m / 10m / 15m / 30m / 1h / 2h / 4h / 8h / 1d / 1w**.

### 2.1 The built-in way — Time Range Picker

1. **+ Add** → **Add parameters** → **+ Add Parameter**.
2. Configure:
   - **Parameter name:** `TimeRange` *(no spaces — this is the token you use in KQL)*
   - **Display name:** `Time range`
   - **Parameter type:** **Time range picker**
   - **Required:** ✅
3. Under **Available time ranges**, tick exactly the ones you want:
   - Last 5 minutes, Last 10 minutes *(if offered)*, Last 15 minutes, Last 30 minutes
   - Last hour, Last 2 hours *(if offered)*, Last 4 hours, Last 8 hours *(if offered)*
   - Last 24 hours, Last 7 days
   - ✅ **Allow custom time range selection** — lets users pick an absolute window for incident review
4. **Save**.

> ⚠️ **The built-in list is fixed** — Azure offers a standard set (5m, 15m, 30m, 1h, 4h, 12h, 1d, 3d, 7d, 30d …) and you choose which to expose. **If 10 minutes, 2 hours, or 8 hours are not in the list, use §2.2 instead.**

### 2.2 The exact-control way — custom JSON dropdown

Gives you precisely the ten options you specified, and doubles as a value you can compute with.

1. **+ Add Parameter**
   - **Parameter name:** `Lookback`
   - **Display name:** `Time interval`
   - **Parameter type:** **Drop down**
   - **Get data from:** **JSON**
2. Paste this into the JSON box:

```json
[
  { "value": "5m",  "label": "Last 5 minutes"  },
  { "value": "10m", "label": "Last 10 minutes" },
  { "value": "15m", "label": "Last 15 minutes" },
  { "value": "30m", "label": "Last 30 minutes" },
  { "value": "1h",  "label": "Last 1 hour", "selected": true },
  { "value": "2h",  "label": "Last 2 hours"   },
  { "value": "4h",  "label": "Last 4 hours"   },
  { "value": "8h",  "label": "Last 8 hours"   },
  { "value": "1d",  "label": "Last 24 hours"  },
  { "value": "7d",  "label": "Last 7 days"    }
]
```

3. **Save**.

**Use it in KQL** — the token is replaced with the literal text before execution:

```kusto
AzureMetrics
| where TimeGenerated > ago({Lookback})
| where ResourceProvider == "MICROSOFT.DBFORPOSTGRESQL"
| summarize avg(Average) by MetricName, bin(TimeGenerated, 1m)
```

> **Which approach should you use?**
>
> | | Time Range Picker | Custom JSON dropdown |
> |---|---|---|
> | Absolute ("from X to Y") windows | ✅ | ❌ |
> | Exact control of the option list | ⚠️ Fixed set | ✅ |
> | Works with `{TimeRange:start/end}` | ✅ | ❌ |
> | Feels native to Azure users | ✅ | ⚠️ |
>
> **Recommendation:** use the **Time Range Picker** as your primary control — absolute windows matter for incident review — and add the custom dropdown only if a specific interval you need is genuinely missing.

### 2.3 ⭐ Add a separate Granularity parameter

This is the advanced move most workbooks miss. **Window size and bin size are different decisions**, and letting a user pick a 7-day window at 1-minute bins produces 10,080 points and a tile that times out.

```json
[
  { "value": "auto", "label": "Auto (recommended)", "selected": true },
  { "value": "1m",   "label": "1 minute"  },
  { "value": "5m",   "label": "5 minutes" },
  { "value": "15m",  "label": "15 minutes" },
  { "value": "30m",  "label": "30 minutes" },
  { "value": "1h",   "label": "1 hour"    },
  { "value": "1d",   "label": "1 day"     }
]
```

Name it `Grain`, then in KQL:

```kusto
// 'auto' derives ~100 buckets from the selected window; anything else is literal
let _grain = iff("{Grain}" == "auto",
                 totimespan({TimeRange:seconds} / 100 * 1s),
                 totimespan("{Grain}"));
AzureMetrics
| where TimeGenerated between ({TimeRange:start} .. {TimeRange:end})
| where ResourceProvider == "MICROSOFT.DBFORPOSTGRESQL"
| where MetricName == "cpu_percent"
| summarize CPU = avg(Average) by bin(TimeGenerated, _grain)
| render timechart
```

> **`{TimeRange:seconds}` is the key to auto-granularity** — it gives you the selected window length as a number, so the bin scales automatically. This single pattern eliminates the most common workbook failure mode: charts that work at 1 hour and time out at 30 days.

> 📸 **SCREENSHOT 2** — the parameters row showing Time range and Granularity.
>
> ![Time range and granularity parameters](images/adv-02-time-params.png)

---

## 3. Filter B — Resource Group dropdown

Requirement: **distinct RGs the user can access that actually contain a PostgreSQL flexible server**, plus an **All** option.

### 3.1 Build it with Azure Resource Graph

**Azure Resource Graph (ARG) is the right data source here, not Log Analytics.** ARG queries live Azure inventory and is **automatically scoped to what the signed-in user has RBAC on** — which is exactly your "resource groups this user has access to" requirement, enforced by the platform rather than by your query.

1. **+ Add Parameter**
   - **Parameter name:** `ResourceGroups`
   - **Display name:** `Resource group`
   - **Parameter type:** **Drop down**
   - **Get data from:** **Azure Resource Graph**
   - **Subscriptions:** *Use default subscriptions* (or bind to a Subscription parameter — §4.1)
2. Query:

```kusto
resources
| where type =~ 'microsoft.dbforpostgresql/flexibleservers'
| distinct resourceGroup
| order by resourceGroup asc
```

3. Under **Parameter settings**:
   - ✅ **Allow multiple selections**
   - **Delimiter:** `,`
   - **Quote with:** `'`
   - **Select all value:** `*`   ← *this creates your "All Resource groups" option*
4. **Save**.

> **Why ARG rather than a Log Analytics query:** a Log Analytics query only shows resource groups that have **already sent telemetry**. ARG shows every PostgreSQL server that **exists**, including a newly created one that has not logged anything yet — and it respects the user's RBAC automatically.

### 3.2 A richer version with server counts

Better UX — users see how many servers each RG holds:

```kusto
resources
| where type =~ 'microsoft.dbforpostgresql/flexibleservers'
| summarize ServerCount = count() by resourceGroup
| project value = resourceGroup,
          label = strcat(resourceGroup, '  (', ServerCount, ' server', iff(ServerCount > 1, 's', ''), ')')
| order by label asc
```

> **The `value` / `label` column convention is the core of workbook dropdowns.** `label` is what the user sees; `value` is what gets substituted into your KQL. Two other optional columns: `selected` (boolean, sets the default) and `group` (creates option groups).

> 📸 **SCREENSHOT 3** — the Resource group dropdown open, showing server counts and the All option.
>
> ![Resource group dropdown](images/adv-03-rg-dropdown.png)

---

## 4. Filter C — Instance dropdown, cascading from the Resource Group

Requirement: **one instance from the selected RG**, plus **All Instances**.

### 4.1 The cascade

**A parameter can reference any parameter defined *above* it.** That is how cascading works — order matters.

1. **+ Add Parameter**
   - **Parameter name:** `Instances`
   - **Display name:** `Instance`
   - **Parameter type:** **Drop down**
   - **Get data from:** **Azure Resource Graph**
2. Query — note it filters on `{ResourceGroups}`:

```kusto
resources
| where type =~ 'microsoft.dbforpostgresql/flexibleservers'
| where '*' in ({ResourceGroups}) or resourceGroup in ({ResourceGroups})
| project value = name,
          label = strcat(name, '  —  ', resourceGroup, '  (', location, ')'),
          group = resourceGroup
| order by label asc
```

3. **Parameter settings:**
   - ✅ **Allow multiple selections**
   - **Delimiter:** `,`  ·  **Quote with:** `'`
   - **Select all value:** `*`
4. **Save**.

> **The line that makes "All" work:**
> ```kusto
> | where '*' in ({ResourceGroups}) or resourceGroup in ({ResourceGroups})
> ```
> When the user picks **All**, `{ResourceGroups}` expands to `'*'`, the first condition is true, and nothing is filtered. When they pick specific groups it expands to `'rg-a','rg-b'`, the first condition is false, and the second filters normally. **This one-line idiom is used in every query for the rest of this document.**

> ⚠️ **Cascading resets.** Changing the Resource Group re-runs the Instance query and clears the previous instance selection. That is correct behavior — but tell your users, because it surprises people mid-investigation.

### 4.2 A richer instance picker

```kusto
resources
| where type =~ 'microsoft.dbforpostgresql/flexibleservers'
| where '*' in ({ResourceGroups}) or resourceGroup in ({ResourceGroups})
| extend tier    = tostring(sku.tier),
         skuName = tostring(sku.name),
         version = tostring(properties.version),
         state   = tostring(properties.state),
         haMode  = tostring(properties.highAvailability.mode)
| project value = name,
          label = strcat(name, '  ·  PG', version, '  ·  ', tier, '  ·  ', haMode),
          group = resourceGroup,
          state
| order by label asc
```

> 💡 **Surface HA mode and version in the label.** When someone asks "why is this server behaving differently?", half the time the answer is visible right there in the picker.

> 📸 **SCREENSHOT 4** — the cascading Instance dropdown grouped by resource group.
>
> ![Cascading instance dropdown](images/adv-04-instance-dropdown.png)

---

# PART II — Making the tiles respond

## 5. Parameter syntax reference

| Token | Returns | Example use |
|---|---|---|
| `{ParamName}` | The **value** (or a quoted, delimited list for multi-select) | `where Resource in ({Instances})` |
| `{ParamName:label}` | The display label | Chart titles |
| `{ParamName:value}` | Explicit value form | Same as `{ParamName}` |
| **`{TimeRange:start}`** | Window start as a datetime | `where TimeGenerated >= {TimeRange:start}` |
| **`{TimeRange:end}`** | Window end as a datetime | `where TimeGenerated <= {TimeRange:end}` |
| **`{TimeRange:seconds}`** | Window length in seconds | Auto-granularity (§2.3) |
| `{TimeRange:grain}` | Suggested bin size | `bin(TimeGenerated, {TimeRange:grain})` |
| `{TimeRange:label}` | e.g. "Last 4 hours" | Chart subtitles |
| `{Resources}` | Selected resource IDs | `where _ResourceId in ({Resources})` |

> ⚠️ **Parameters are text substitution, not bound variables.** `{Instances}` is literally replaced with `'srv-a','srv-b'` *before* the query is sent. Three consequences:
> 1. **Quoting must be configured on the parameter**, or you get unquoted tokens and a syntax error.
> 2. An **empty** multi-select expands to nothing and breaks the query — always mark such parameters **Required**, or give them a **Select all value**.
> 3. Use the **</> Advanced Editor** on any query item to see the **fully expanded** KQL. **This is the single most useful debugging tool in workbooks.**

## 6. Converting your existing queries

### 6.1 The conversion pattern

**Before** — from the query pack, with hardcoded `let` values:

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
| where MetricName in ("cpu_percent", "active_connections")
| summarize Value = avg(Average) by MetricName, bin(TimeGenerated, _bin)
| render timechart
```

**After** — parameterized:

```kusto
let _grain = iff("{Grain}" == "auto",
                 totimespan({TimeRange:seconds} / 100 * 1s),
                 totimespan("{Grain}"));
AzureMetrics
| where TimeGenerated between ({TimeRange:start} .. {TimeRange:end})
| where ResourceProvider == "MICROSOFT.DBFORPOSTGRESQL"
| where '*' in ({ResourceGroups}) or ResourceGroup in ({ResourceGroups})
| where '*' in ({Instances})      or Resource      in ({Instances})
| where MetricName in ("cpu_percent", "active_connections")
| summarize Value = avg(Average) by MetricName, bin(TimeGenerated, _grain)
| project TimeGenerated,
          Series = case(MetricName == "cpu_percent",        "CPU %",
                        MetricName == "active_connections", "Active connections",
                                                            MetricName),
          Value
| render timechart
```

**The four mechanical substitutions:**

| Replace this | With this |
|---|---|
| `let _start/_end/_lookback` | `{TimeRange:start}` / `{TimeRange:end}` |
| `let _bin = 1m` | The `_grain` expression |
| `where isempty(_server) or Resource =~ _server` | Two lines: RG filter **and** instance filter |
| Nothing | `where '*' in (...)` guard on **every** filter |

### 6.2 ⚠️ Filtering resource-specific log tables

`AzureMetrics` has a **`ResourceGroup`** column. The PostgreSQL log tables (`PGSQLServerLogs`, `PGSQLPgStatActivitySessions`, etc.) **do not** — you must parse `_ResourceId`.

```kusto
// _ResourceId format:
// /subscriptions/{sub}/resourcegroups/{rg}/providers/microsoft.dbforpostgresql/flexibleservers/{name}
// split by '/':   [2]=sub   [4]=resourceGroup   [8]=serverName

PGSQLServerLogs
| where TimeGenerated between ({TimeRange:start} .. {TimeRange:end})
| extend ResourceGroupName = tostring(split(_ResourceId, '/')[4])
| where '*' in ({ResourceGroups}) or ResourceGroupName in~ ({ResourceGroups})
| where '*' in ({Instances})      or LogicalServerName in~ ({Instances})
| where ErrorLevel in ("ERROR", "FATAL", "PANIC")
| summarize Events = count() by ErrorLevel, bin(TimeGenerated, 15m)
| render timechart
```

> 💡 **Use `in~` (case-insensitive) for names.** `AzureMetrics.Resource` is typically **uppercase**, while ARG returns the name as created. `in~` avoids a whole class of silent empty-result bugs.

### 6.3 A reusable header block

Paste this at the top of every query item — then the body never changes:

```kusto
// ===================== WORKBOOK FILTER HEADER =====================
let _grain = iff("{Grain}" == "auto",
                 totimespan({TimeRange:seconds} / 100 * 1s),
                 totimespan("{Grain}"));
let _rgAll  = '*' in ({ResourceGroups});
let _svrAll = '*' in ({Instances});
// ==================================================================
AzureMetrics
| where TimeGenerated between ({TimeRange:start} .. {TimeRange:end})
| where ResourceProvider == "MICROSOFT.DBFORPOSTGRESQL"
| where _rgAll  or ResourceGroup in~ ({ResourceGroups})
| where _svrAll or Resource      in~ ({Instances})
// ---- query body from here ----
| where MetricName == "cpu_percent"
| summarize CPU = avg(Average) by bin(TimeGenerated, _grain)
| render timechart
```

### 6.4 Three converted tiles, ready to paste

**Connections vs CPU** *(query pack §1.2)*

```kusto
let _grain = iff("{Grain}" == "auto",
                 totimespan({TimeRange:seconds} / 100 * 1s), totimespan("{Grain}"));
AzureMetrics
| where TimeGenerated between ({TimeRange:start} .. {TimeRange:end})
| where ResourceProvider == "MICROSOFT.DBFORPOSTGRESQL"
| where '*' in ({ResourceGroups}) or ResourceGroup in~ ({ResourceGroups})
| where '*' in ({Instances})      or Resource      in~ ({Instances})
| where MetricName in ("cpu_percent", "active_connections")
| summarize Value = avg(Average) by MetricName, bin(TimeGenerated, _grain)
| extend Pct = iff(MetricName == "active_connections", Value / {MaxConnections} * 100.0, Value)
| project TimeGenerated,
          Series = iff(MetricName == "cpu_percent", "CPU %", "Connections (% of max)"),
          Pct
| render timechart
```

*(`MaxConnections` is a Text parameter — see §7.6.)*

**Sessions by state** *(query pack §3.3, a log table)*

```kusto
PGSQLPgStatActivitySessions
| where TimeGenerated between ({TimeRange:start} .. {TimeRange:end})
| extend ResourceGroupName = tostring(split(_ResourceId, '/')[4])
| where '*' in ({ResourceGroups}) or ResourceGroupName in~ ({ResourceGroups})
| where '*' in ({Instances})      or LogicalServerName in~ ({Instances})
| where BackendType == "client backend"
| summarize Sessions = dcount(ProcessId) by State, bin(TimeGenerated, 5m)
| render timechart
```

**Fleet status table** *(query pack §5.12)*

```kusto
AzureMetrics
| where TimeGenerated between ({TimeRange:start} .. {TimeRange:end})
| where ResourceProvider == "MICROSOFT.DBFORPOSTGRESQL"
| where '*' in ({ResourceGroups}) or ResourceGroup in~ ({ResourceGroups})
| where '*' in ({Instances})      or Resource      in~ ({Instances})
| where MetricName in ("cpu_percent","memory_percent","storage_percent","active_connections")
| summarize Value = avg(Average) by Server = Resource, ResourceGroup, MetricName
| evaluate pivot(MetricName, any(Value))
| project Server, ResourceGroup,
          ["CPU %"]       = round(cpu_percent, 1),
          ["Memory %"]    = round(memory_percent, 1),
          ["Storage %"]   = round(storage_percent, 1),
          ["Connections"] = round(active_connections, 0)
| extend Status = case(["CPU %"] > 85 or ["Memory %"] > 90 or ["Storage %"] > 90, "Attention",
                       ["CPU %"] > 70 or ["Memory %"] > 75 or ["Storage %"] > 80, "Watch",
                                                                                  "Healthy")
| order by ["CPU %"] desc
```

> 💡 On a table visualization, use **Column settings → Status → Renderer: Thresholds** to colour the Status column red/amber/green natively — better than emoji, and it sorts correctly.

> 📸 **SCREENSHOT 5** — a tile responding to a filter change.
>
> ![Tile responding to filter selection](images/adv-05-tile-filtered.png)

---

# PART III — More filter ideas

## 7. Additional parameters worth adding

### 7.1 Subscription picker *(add above Resource Group)*

- **Type:** Subscription picker · **Name:** `Subscriptions`
- Then make the RG query subscription-scoped. **Add this first if you manage more than one subscription** — it makes every downstream cascade correct.

### 7.2 Region / location

```kusto
resources
| where type =~ 'microsoft.dbforpostgresql/flexibleservers'
| summarize Count = count() by location
| project value = location, label = strcat(location, ' (', Count, ')')
| order by label asc
```

### 7.3 Environment — from tags

**The most valuable filter in a real estate**, if your tagging is disciplined:

```kusto
resources
| where type =~ 'microsoft.dbforpostgresql/flexibleservers'
| extend env = tostring(tags['Environment'])
| where isnotempty(env)
| distinct env
| order by env asc
```

Then filter instances by it:

```kusto
resources
| where type =~ 'microsoft.dbforpostgresql/flexibleservers'
| extend env = tostring(tags['Environment'])
| where '*' in ({Environment}) or env in ({Environment})
| where '*' in ({ResourceGroups}) or resourceGroup in ({ResourceGroups})
| project value = name, label = strcat(name, ' · ', env), group = resourceGroup
```

### 7.4 SKU tier / compute size

```kusto
resources
| where type =~ 'microsoft.dbforpostgresql/flexibleservers'
| extend tier = tostring(sku.tier), skuName = tostring(sku.name)
| summarize Count = count() by tier
| project value = tier, label = strcat(tier, ' (', Count, ')')
```

> **Useful for capacity reviews:** filter to Burstable only and you immediately see which servers are CPU-credit constrained.

### 7.5 PostgreSQL major version

```kusto
resources
| where type =~ 'microsoft.dbforpostgresql/flexibleservers'
| extend version = tostring(properties.version)
| summarize Count = count() by version
| project value = version, label = strcat('PostgreSQL ', version, ' (', Count, ')')
| order by label desc
```

> 💡 **Ties directly to your index-maintenance material:** filter to PG 13 and earlier to find servers that lack bottom-up index deletion and will bloat faster.

### 7.6 Threshold parameters — Text type

Let the viewer tune the analysis rather than hardcoding your assumptions.

| Name | Type | Default | Used for |
|---|---|---|---|
| `MaxConnections` | Text | `200` | Normalizing connections to a percentage |
| `CpuThreshold` | Text | `80` | Threshold line on CPU charts |
| `RollbackPct` | Text | `5` | Rollback-ratio alert line |
| `SlowQueryMs` | Text | `1000` | Query Store filtering |
| `TopN` | Drop down (JSON) | `10` | Rows in "top queries" tiles |

```kusto
// Threshold line rendered as a second series
| extend ["Threshold"] = todouble("{CpuThreshold}")
```

> ⚠️ **Text parameters are unvalidated free text.** A user typing `abc` breaks the query. Prefer a **Drop down** with fixed numeric options wherever the set is known.

### 7.7 Database name — from log data

Cannot come from ARG (Azure has no visibility inside the server), so query Log Analytics:

```kusto
PGSQLPgStatActivitySessions
| where TimeGenerated > ago(7d)
| where isnotempty(DatabaseName)
| distinct DatabaseName
| order by DatabaseName asc
```

### 7.8 Replica role — primary vs standby

Most log tables carry `ReplicaRole`:

```json
[
  { "value": "*",         "label": "All roles", "selected": true },
  { "value": "Primary",   "label": "Primary only" },
  { "value": "Secondary", "label": "Replicas only" }
]
```

```kusto
| where "{ReplicaRole}" == "*" or ReplicaRole == "{ReplicaRole}"
```

> **Genuinely useful:** replica CPU and read IOPS behave very differently from the primary. Mixing them in one average hides both.

### 7.9 Severity / error level

```json
[
  { "value": "FATAL,PANIC",                       "label": "Critical only" },
  { "value": "ERROR,FATAL,PANIC",                 "label": "Errors and above", "selected": true },
  { "value": "WARNING,ERROR,FATAL,PANIC",         "label": "Warnings and above" },
  { "value": "LOG,WARNING,ERROR,FATAL,PANIC",     "label": "Everything" }
]
```

```kusto
| where ErrorLevel in (split("{Severity}", ","))
```

### 7.10 Comparison period — day-over-day

```json
[
  { "value": "0",  "label": "No comparison", "selected": true },
  { "value": "1",  "label": "vs yesterday" },
  { "value": "7",  "label": "vs last week" },
  { "value": "30", "label": "vs last month" }
]
```

```kusto
let _offset = totimespan({ComparePeriod}d);
let _cur = AzureMetrics
    | where TimeGenerated between ({TimeRange:start} .. {TimeRange:end})
    | where MetricName == "cpu_percent"
    | summarize V = avg(Average) by bin(TimeGenerated, 15m)
    | extend Period = "Current";
let _prev = AzureMetrics
    | where TimeGenerated between (({TimeRange:start} - _offset) .. ({TimeRange:end} - _offset))
    | where MetricName == "cpu_percent"
    | summarize V = avg(Average) by bin(TimeGenerated, 15m)
    | extend TimeGenerated = TimeGenerated + _offset, Period = "Baseline";
union _cur, _prev
| where {ComparePeriod} > 0 or Period == "Current"
| render timechart
```

### 7.11 Metric picker — one tile, any metric

```kusto
AzureMetrics
| where TimeGenerated > ago(7d)
| where ResourceProvider == "MICROSOFT.DBFORPOSTGRESQL"
| distinct MetricName
| project value = MetricName, label = MetricName
| order by label asc
```

> **One tile then replaces twenty.** Pair it with a multi-select so users can overlay any combination.

### 7.12 Summary — recommended parameter order

Order determines cascade direction. **This sequence works:**

```
1. Subscriptions      (Subscription picker)
2. Environment        (tag-based, ARG)
3. ResourceGroups     (ARG, cascades from 1 + 2)
4. Instances          (ARG, cascades from 3)
5. TimeRange          (Time range picker)
6. Grain              (JSON dropdown)
7. Thresholds         (Text / dropdown — MaxConnections, CpuThreshold …)
```

---

# PART IV — Advanced techniques

## 8. Conditional visibility

Show a tile **only** when it is relevant.

1. Put related items inside a **Group** (**+ Add** → **Add group**).
2. Group → **Advanced Settings** → **Make this item conditionally visible**.
3. Condition: *parameter* `Instances` · *comparison* `is not equal to` · *value* `*`

**Practical uses:**

| Show when | Tile |
|---|---|
| A single instance is selected | Per-server deep-dive: Query Store, wait events, sessions |
| **All** instances selected | Fleet comparison table, ranked lists |
| Environment = Production | SLA and compliance tiles |
| Comparison period ≠ 0 | The baseline-overlay chart |

> 💡 **This is how you avoid the 30-tile wall of noise.** Show fleet tiles at fleet scope, detail tiles at instance scope — the workbook reshapes itself around the question being asked.

## 9. Tabs

**+ Add** → **Add links** → style **Tabs**, each tab revealing a group:

```
[ Overview ] [ Performance ] [ Sessions ] [ Queries ] [ Storage ] [ Errors ]
```

Parameters defined **above** the tab control apply to every tab — so the filters stay put while the content changes.

## 10. Drill-through

Grid → **Column Settings** → column → **Renderer: Link** → **Link type:**

| Link type | Behavior |
|---|---|
| **Cell details** | Popup with the full row — best default |
| **Workbook (template)** | Open another workbook, passing the value as a parameter |
| **Resource overview** | Jump to the resource blade in the portal |
| **Generic details** | Custom content |

**The classic pattern:** fleet table → click a server name → a detail workbook opens filtered to that server. **This is the capability that makes workbooks worth the extra build effort over dashboards.**

## 11. The hybrid — pin workbook parts to your dashboard

You keep the dashboard *and* get the interactivity.

1. Open the workbook in **edit** mode.
2. On any item → **⋯** → **Pin to dashboard**.
3. Choose your existing dashboard.

> ⚠️ **A pinned part keeps the parameter values that were selected when you pinned it** — it becomes a snapshot of that configuration, not a live control. **Pin the "All instances, last 4 hours" view for the dashboard, and keep the workbook link for interactive work.** Add a Markdown tile on the dashboard linking to the workbook.

> 📸 **SCREENSHOT 6** — a pinned workbook part on the dashboard.
>
> ![Workbook part pinned to dashboard](images/adv-06-pinned-part.png)

## 12. Deploy as code

**Advanced Editor** (`</>`) → the full workbook is JSON (an ARM template).

- **Export:** copy the JSON → commit to Git
- **Import:** new workbook → Advanced Editor → paste → **Apply**
- **Deploy:** `Microsoft.Insights/workbooks` resource in an ARM/Bicep template

```powershell
az deployment group create `
  --resource-group "rg-monitoring" `
  --template-file "./postgresql-workbook.bicep"
```

> **When moving between environments, search the JSON for:** hardcoded workspace resource IDs, subscription GUIDs, and any default parameter values naming a specific server.

---

## 13. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| **Tile empty after adding filters** | Case mismatch — `AzureMetrics.Resource` is uppercase | Use **`in~`** not `in` |
| `SyntaxError` near a parameter | Quoting not configured on a multi-select | Parameter settings → **Quote with:** `'` |
| **All** option returns nothing | Missing `'*' in (...)` guard | Add the guard to every filter line |
| Instance dropdown empty | Cascade broken, or no RG selected | Confirm `{ResourceGroups}` is referenced and Required |
| Parameter shows no options | ARG query wrong, or no RBAC | Run the ARG query standalone in **Resource Graph Explorer** |
| Tile times out on wide ranges | Bin too small for the window | Use the auto-granularity pattern (§2.3) |
| Values reset on every refresh | Parameters not marked Required / no default | Set `"selected": true` in the JSON |
| **Cannot see the generated KQL** | — | Query item → **</> Advanced Editor** shows the **expanded** query |

## 14. Checklist

**Parameters**
- [ ] Defined in cascade order (§7.12)
- [ ] Every multi-select has a **Select all value** of `*`
- [ ] Quoting and delimiter configured on every multi-select
- [ ] Required flags set so no parameter can be empty
- [ ] Defaults chosen so the workbook is useful on first open

**Queries**
- [ ] Every tile uses `{TimeRange:start}` / `{TimeRange:end}`
- [ ] Every tile carries **both** RG and instance filters with `'*' in (...)` guards
- [ ] `in~` used for all name comparisons
- [ ] Log tables parse `_ResourceId` for resource group (§6.2)
- [ ] Auto-granularity applied to every timechart
- [ ] Expanded KQL reviewed in the Advanced Editor at least once per tile

**Experience**
- [ ] Conditional visibility separates fleet view from instance view
- [ ] Tabs group related content
- [ ] Drill-through from the fleet table to instance detail
- [ ] Chart titles include `{TimeRange:label}` so screenshots are self-documenting

**Governance**
- [ ] Saved to a resource group the audience can read
- [ ] Viewers have **Log Analytics Reader** on `ArcBox-law`
- [ ] JSON exported to source control
- [ ] Key views pinned to the dashboard, with a link back to the workbook

---

## Appendix A — Screenshot checklist

| # | Filename | Shows | Done |
|---|---|---|---|
| 1 | `adv-01-new-workbook.png` | New empty workbook, Add menu | ☐ |
| 2 | `adv-02-time-params.png` | Time range + granularity parameters | ☐ |
| 3 | `adv-03-rg-dropdown.png` | Resource group dropdown with counts | ☐ |
| 4 | `adv-04-instance-dropdown.png` | Cascading instance dropdown | ☐ |
| 5 | `adv-05-tile-filtered.png` | Tile responding to a filter change | ☐ |
| 6 | `adv-06-pinned-part.png` | Workbook part pinned to dashboard | ☐ |
| 7 | `adv-07-conditional.png` | Conditional visibility in action | ☐ |
| 8 | `adv-08-drillthrough.png` | Drill-through from fleet table | ☐ |
| 9 | `adv-09-complete.png` | **Finished workbook (hero shot)** | ☐ |

## Appendix B — Starter parameter JSON

Paste into **Advanced Editor** as the first item, then adjust.

```json
{
  "type": 9,
  "content": {
    "version": "KqlParameterItem/1.0",
    "parameters": [
      {
        "id": "rg-param",
        "version": "KqlParameterItem/1.0",
        "name": "ResourceGroups",
        "label": "Resource group",
        "type": 2,
        "isRequired": true,
        "multiSelect": true,
        "quote": "'",
        "delimiter": ",",
        "typeSettings": { "additionalResourceOptions": [], "showDefault": false },
        "queryType": 1,
        "query": "resources | where type =~ 'microsoft.dbforpostgresql/flexibleservers' | summarize c=count() by resourceGroup | project value=resourceGroup, label=strcat(resourceGroup,'  (',c,')') | order by label asc",
        "value": ["*"]
      },
      {
        "id": "inst-param",
        "version": "KqlParameterItem/1.0",
        "name": "Instances",
        "label": "Instance",
        "type": 2,
        "isRequired": true,
        "multiSelect": true,
        "quote": "'",
        "delimiter": ",",
        "queryType": 1,
        "query": "resources | where type =~ 'microsoft.dbforpostgresql/flexibleservers' | where '*' in ({ResourceGroups}) or resourceGroup in ({ResourceGroups}) | project value=name, label=strcat(name,'  —  ',resourceGroup), group=resourceGroup | order by label asc",
        "value": ["*"]
      },
      {
        "id": "time-param",
        "version": "KqlParameterItem/1.0",
        "name": "TimeRange",
        "label": "Time range",
        "type": 4,
        "isRequired": true,
        "typeSettings": {
          "selectableValues": [
            { "durationMs": 300000 },
            { "durationMs": 900000 },
            { "durationMs": 1800000 },
            { "durationMs": 3600000 },
            { "durationMs": 14400000 },
            { "durationMs": 43200000 },
            { "durationMs": 86400000 },
            { "durationMs": 604800000 }
          ],
          "allowCustom": true
        },
        "value": { "durationMs": 3600000 }
      },
      {
        "id": "grain-param",
        "version": "KqlParameterItem/1.0",
        "name": "Grain",
        "label": "Granularity",
        "type": 2,
        "isRequired": true,
        "jsonData": "[{\"value\":\"auto\",\"label\":\"Auto (recommended)\",\"selected\":true},{\"value\":\"1m\",\"label\":\"1 minute\"},{\"value\":\"5m\",\"label\":\"5 minutes\"},{\"value\":\"15m\",\"label\":\"15 minutes\"},{\"value\":\"1h\",\"label\":\"1 hour\"},{\"value\":\"1d\",\"label\":\"1 day\"}]",
        "value": "auto"
      },
      {
        "id": "maxconn-param",
        "version": "KqlParameterItem/1.0",
        "name": "MaxConnections",
        "label": "max_connections",
        "type": 1,
        "value": "200"
      }
    ],
    "style": "pills",
    "queryType": 1
  },
  "name": "filter-parameters"
}
```

> ⚠️ **Treat this as a starting skeleton, not a finished artifact.** Workbook JSON schema evolves; paste it, click **Apply**, and fix anything the editor rejects. Building the first parameter through the UI and then reading its JSON is the fastest way to learn the current shape.

---

## Reference

- Workbooks overview — https://learn.microsoft.com/en-us/azure/azure-monitor/visualize/workbooks-overview
- Workbook parameters — https://learn.microsoft.com/en-us/azure/azure-monitor/visualize/workbooks-parameters
- Dropdown parameters — https://learn.microsoft.com/en-us/azure/azure-monitor/visualize/workbooks-dropdowns
- Time parameters — https://learn.microsoft.com/en-us/azure/azure-monitor/visualize/workbooks-time
- Resource parameters — https://learn.microsoft.com/en-us/azure/azure-monitor/visualize/workbooks-resources
- Conditional visibility — https://learn.microsoft.com/en-us/azure/azure-monitor/visualize/workbooks-grid-visualizations
- Azure Resource Graph query language — https://learn.microsoft.com/en-us/azure/governance/resource-graph/concepts/query-language
- Resource Graph sample queries — https://learn.microsoft.com/en-us/azure/governance/resource-graph/samples/starter
- Deploy workbooks with ARM — https://learn.microsoft.com/en-us/azure/azure-monitor/visualize/workbooks-automate
