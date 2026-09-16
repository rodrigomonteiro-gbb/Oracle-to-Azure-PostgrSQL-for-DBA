# Backup, Restore & Point-in-Time Restore
## Azure Database for PostgreSQL – Flexible Server
### Workshop for Oracle DBAs moving to Azure PostgreSQL

**Audience:** Experienced Oracle DBAs (RMAN, Data Guard, Flashback, ARCHIVELOG)
**Goal:** Be able to explain, configure, test and defend a backup/recovery strategy on Azure Database for PostgreSQL – Flexible Server on day one.
**Format:** ~90 minutes — concepts (30 min), demos/labs (45 min), Q&A + checklist (15 min)

---

## 0. The one-slide mental model

> In Oracle you **own** the backup. In Azure PostgreSQL Flexible Server the platform **owns** the backup — you own the **retention policy, the redundancy choice, and the recovery drill.**

| What you did in Oracle | What happens here |
|---|---|
| Configure ARCHIVELOG mode, FRA sizing | Always on. WAL archiving is managed by the service. |
| Write and schedule RMAN full/incremental scripts | Automatic daily snapshot (first = full, subsequent = differential). Nothing to schedule. |
| RMAN `RESTORE DATABASE` + `RECOVER UNTIL TIME` | **Point-in-Time Restore (PITR)** — one portal/CLI action that deploys a **new server**. |
| `FLASHBACK DATABASE TO TIMESTAMP` (in place) | **No in-place rewind.** Restore creates a *new* server; you cut over or copy data back. |
| RMAN catalog, backup pieces on disk/tape you manage | Backups are opaque, encrypted (AES-256), and **not exportable**. Use `pg_dump`/`pg_restore` if you need a portable file. |
| Tape / long-term retention scripts | **Vaulted backups (LTR)** via Azure Backup vault — up to 10 years. |
| Data Guard standby | Read replicas / HA (zone-redundant or same-zone) — *availability*, not backup. |

**The single biggest culture shift to land early:** a restore does **not** overwrite the source server. Every restore is a **new server with a new name and new connection string**.

---

## 1. How operational backup actually works

### 1.1 What is captured
- **Snapshot backups of the data files** — storage-level snapshots, not a logical dump.
- **Transaction log (WAL) backups** — a WAL file is archived when it is filled and ready.
- Together these give you **any point in time** inside the retention window.

### 1.2 Frequency
| Item | Behavior |
|---|---|
| First snapshot | Immediately after server creation (full backup) |
| Subsequent snapshots | Once daily, differential |
| Idle server | Snapshots temporarily suspended if no database changed; a new snapshot is taken as soon as a change occurs |
| WAL backup | Variable — driven by workload and WAL fill rate |
| **Effective RPO** | **Up to ~5 minutes** |

> **Oracle analogy:** think "daily RMAN level-0/level-1 to an unmanaged FRA + continuous archive log shipping", with the archiver never falling behind because the platform owns it.

### 1.3 Retention
- **Default: 7 days. Configurable 7 → 35 days.**
- Changeable **after** creation (Settings → Compute + storage → Backup).
- Beyond 35 days requires **vaulted backups / LTR** (Section 5).

#### Current backup retention

![Current Backup Retention](images/backup-01-Settings.png)

#### Changing backup retention

![Changing Backup Retention](images/backup-02-CurrentRetention.png)

#### Modifying and Saving backup retention

![Changed Backup Retention](images/backup-03-ChangedRetention-Save.png)



### 1.4 Redundancy options
| Option | What it does | When it is chosen |
|---|---|---|
| **Zone-redundant** | 3 copies in the server's AZ + replication to another AZ; ~12 nines durability | Default in regions with availability zones |
| **Locally redundant (LRS)** | Multiple copies in the same datacenter; ~11 nines | Default in regions without AZs, and default for same-zone HA / no-HA servers |
| **Geo-redundant (GRS)** | Also replicated to the Azure paired region; ~16 nines; enables cross-region restore | **Opt-in at server creation only** |

> ⚠️ **Teaching point / common regret:** **Geo-redundant backup can only be selected when the server is created and cannot be changed afterwards.** If cross-region recoverability is a requirement, it must be decided at provisioning time. (Retention days *can* be changed later; redundancy cannot.)

### 1.5 Cost model
- Backup storage **up to the provisioned storage size is included**; consumption beyond that is billed.
- Long retention + high change rate (heavy `UPDATE`/`DELETE`/index maintenance) inflates WAL and differential volume — the same physics as an oversized Oracle FRA.
- Monitor with the **Backup Storage Used** metric (server → Monitoring → Metrics).

---

## 2. Restore types — the decision table

| Restore type | Use it for | Oracle equivalent | Result |
|---|---|---|---|
| **Latest restore point (Now)** | Server-level logical corruption just discovered; fastest "current" copy | `RESTORE DATABASE; RECOVER DATABASE;` | New server, current as of ~now |
| **Custom restore point (PITR)** | "Someone ran DELETE without WHERE at 14:32" | `RECOVER DATABASE UNTIL TIME '...'` | New server as of the timestamp you pick |
| **Fast restore point (full backup only)** | Need a copy *quickly*, exact second doesn't matter | Restore to a backup set, no log apply | New server at the snapshot time — skips WAL replay, so it is the **fastest** option |
| **Geo-restore** | Regional outage / DR drill | Restore from off-site tape to another site | New server in the **paired region** (requires GRS chosen at creation) |
| **Vaulted / LTR restore** | Compliance, audit, ransomware, "give me March 2024" | Long-term tape retrieval | Restore **as files** to a storage container, then load into a server |
| **`pg_dump` / `pg_restore`** | Single table/schema, move across clouds/versions | Data Pump (`expdp`/`impdp`) | Logical, portable, object-level |

### 2.1 Critical constraints to state out loud
1. **Restore always creates a NEW server.** There is no in-place restore and no "restore over the top". Plan the **cutover**: DNS/app connection string, firewall/VNet rules, parameters, roles/logins, extensions, PgBouncer setting, monitoring, HA re-enable.
2. **PITR is same-region**, except geo-restore, which targets the paired region.
3. **You cannot restore a single table with PITR.** Table-level recovery = restore a server to the timestamp, then `pg_dump -t` the table out and load it into production. (This is the equivalent of Oracle table-level RMAN recovery via an auxiliary instance — same pattern, fewer moving parts.)
4. **Earliest restore point** is bounded by the retention window; older backups are deleted automatically.
5. **Restores are not free and not instant** — restore time scales with data size and the amount of WAL to replay. This is exactly why the **Fast restore point** option exists.
6. Some settings are **not inherited** by the restored server the way you may expect — verify HA, redundancy, firewall rules, and parameters after the restore.

---

## 3. Hands-on: the core commands

Set variables once:

```bash
RG=rg-pg-workshop
SRC=pg-prod-01
TGT=pg-restore-01
LOC=eastus2
```

### 3.1 Inspect current backup configuration
```bash
az postgres flexible-server show \
  --resource-group $RG --name $SRC \
  --query "{retention:backup.backupRetentionDays, geo:backup.geoRedundantBackup, earliest:backup.earliestRestoreDate}" -o table
```

### 3.2 Change retention (7–35 days)
```bash
az postgres flexible-server update \
  --resource-group $RG --name $SRC \
  --backup-retention 35
```

### 3.3 Point-in-time restore to a timestamp
```bash
az postgres flexible-server restore \
  --resource-group $RG \
  --name $TGT \
  --source-server $SRC \
  --restore-time "2026-09-15T14:30:00Z"
```
> Use **UTC**. Teach the team to record incident timestamps in UTC — mixing local time and UTC is the #1 cause of a "restored to the wrong minute" do-over.

### 3.4 Restore to latest restore point
```bash
az postgres flexible-server restore \
  --resource-group $RG --name $TGT --source-server $SRC
```

### 3.5 Geo-restore to the paired region (GRS servers only)
```bash
az postgres flexible-server geo-restore \
  --resource-group $RG \
  --name pg-dr-01 \
  --source-server $SRC \
  --location westus2
```

### 3.6 Logical backup — the tool they already understand
```bash
# Whole database, custom format (parallel-restorable) — like expdp
pg_dump -h $SRC.postgres.database.azure.com -U pgadmin -d salesdb -Fc -f salesdb.dump

# Single table only
pg_dump -h $SRC.postgres.database.azure.com -U pgadmin -d salesdb -Fc -t public.orders -f orders.dump

# Restore into a target, 4 parallel jobs — like impdp
pg_restore -h $TGT.postgres.database.azure.com -U pgadmin -d salesdb -j 4 orders.dump
```
> **Say this clearly:** `pg_dump` is **not** your DR strategy — it has no PITR, no consistency across databases, and long runtimes at scale. It is your **object-level and portability** tool. Platform backup is your DR strategy.

---

## 4. Lab exercises

### Lab 1 — Prove the RPO (20 min)
1. Create a table and insert rows with `now()` timestamps in a loop for 5 minutes.
2. Note a timestamp **T** mid-loop (UTC). Keep inserting for 5 more minutes.
3. Simulate the disaster: `DROP TABLE` (or `DELETE` with no `WHERE`).
4. Restore with `--restore-time T`.
5. Connect to the new server and confirm the table contains rows **up to T and nothing after**.
6. Record: wall-clock restore duration vs. database size. *This becomes your RTO evidence.*

### Lab 2 — Table-level recovery (15 min)
1. Using the server restored in Lab 1, `pg_dump -t` the recovered table.
2. `pg_restore` it into the production server under a staging schema.
3. Reconcile and merge. **Discussion:** when is this preferable to cutting over to the restored server?

### Lab 3 — Fast restore point vs. PITR (10 min)
Run both on the same source and time them. **Discussion:** what data loss are you accepting in exchange for the speed?

### Lab 4 — Post-restore checklist drill (10 min)
Restore a server and identify everything NOT automatically carried over. Produce a cutover runbook (template in Section 7).

---

## 5. Long-term retention (vaulted backups)

For retention beyond 35 days — regulatory, audit, ransomware protection.

**What it gives you**
- Retention up to **10 years**.
- Backups copied to an **isolated storage environment outside your tenant and subscription** → protection against ransomware and against deletion of the source subscription.
- Zero-infrastructure: Azure Backup handles scheduling and retention lifecycle.
- Central monitoring of jobs across estates.

**How to set it up (portal path)**
1. Create a **Backup vault** **in the same region** as the server.
2. Create a **backup policy** — datasource type *Azure Database for PostgreSQL flexible servers*; set frequency (weekly/monthly/yearly) and retention rules.
3. On the server: **Settings → LTR (Vaulted Backups) → Configure protection**, pick the vault + policy.
4. Grant the vault's **managed identity** the required roles — the wizard offers **Assign missing roles**:
   - *PostgreSQL Flexible Server Long Term Retention Backup Role* on the server
   - *Reader* on the server's resource group
   - *Storage Blob Data Contributor* on the target storage account (for restore)

**Restoring from the vault is a two-step process**
1. Restore the backup from the vault **to a storage container** (restore-as-files).
2. Load those files into a **new or existing** flexible server.

> ⚠️ **Original Location Recovery (OLR) is not supported for PaaS databases** — use **Alternate Location Recovery (ALR)**: restore into the same or another flexible server as a new database, keeping both source and restored copies.
> ⚠️ Target storage account needs `AllowCrossTenantReplication = true`, permitted copy scope "from any storage account", and network access permitting the Backup vault (or the trusted-Microsoft-services exception).

**Cost:** protected-instance fee (per 250 GB units of database size) + backup storage fee (GB stored × vault redundancy).

---

## 6. Oracle → PostgreSQL translation glossary

| Oracle | Azure PostgreSQL Flexible Server |
|---|---|
| ARCHIVELOG mode | WAL archiving — always on, platform-managed |
| Archived redo log | WAL segment |
| SCN | LSN (Log Sequence Number) |
| Control file | `pg_control` + platform metadata (not user-managed) |
| Fast Recovery Area (FRA) | Managed backup storage (size it via retention, not a quota) |
| RMAN backupset / image copy | Platform snapshot (opaque, not exportable) |
| RMAN `RECOVER UNTIL TIME` | PITR with custom restore point |
| `FLASHBACK DATABASE` | *No equivalent* — restore to a new server |
| Flashback Query / `AS OF TIMESTAMP` | *No equivalent* — restore then query the copy |
| Flashback Drop / recycle bin | *No equivalent* — DDL is not recoverable in place; PITR is the answer |
| Data Pump `expdp`/`impdp` | `pg_dump` / `pg_restore` |
| RMAN catalog / `LIST BACKUP` | Portal *Backup and restore* blade; earliest restore point; Backup vault jobs |
| Data Guard | HA (zone-redundant/same-zone) + read replicas |
| Tablespace point-in-time recovery | Restore server → `pg_dump -t` → load |
| `V$RMAN_STATUS` | Backup Storage Used metric; Backup center jobs |

---

## 7. Post-restore cutover runbook (hand out as a template)

After **every** restore, before declaring recovery complete:

- [ ] Server name and FQDN are new → update **application connection strings / DNS / key vault secrets**
- [ ] **Networking**: VNet integration, private endpoint, firewall rules
- [ ] **Server parameters** — verify against the source baseline
- [ ] **Roles, users, passwords** and `pg_hba`-equivalent access rules
- [ ] **Extensions** (`shared_preload_libraries`, `CREATE EXTENSION`) present and correct
- [ ] **High availability** re-enabled if required (restores land without HA unless configured)
- [ ] **Backup retention & redundancy** reconfigured on the new server (GRS is create-time only — decide now)
- [ ] **Read replicas** recreated
- [ ] **Monitoring, alerts, diagnostic settings, Defender** re-attached
- [ ] **Maintenance window** and tags reapplied
- [ ] `ANALYZE` the restored database before opening to the workload
- [ ] Validate row counts / application smoke test **before** cutting traffic over
- [ ] Decide fate of the source server (retain for forensics, then delete to stop charges)

---

## 8. Design decisions to make before go-live

| Decision | Options | Guidance |
|---|---|---|
| Backup retention | 7–35 days | Set to the longest incident-detection window you realistically have. 7 days is rarely enough for slow-burn logical corruption. |
| Backup redundancy | LRS / ZRS / **GRS** | **Decide at creation.** If there is any DR/regional requirement, choose geo-redundant — it cannot be added later. |
| Long-term retention | None / vaulted LTR | Any regulatory retention > 35 days, or ransomware-isolation requirement → vaulted backups. |
| Restore target sizing | Same / larger SKU | Restore to a larger compute tier to shorten replay and validation, then scale down. |
| Recovery drill cadence | Quarterly minimum | An untested restore is a hypothesis. Measure RTO and publish it. |
| Logical export | Optional | Keep periodic `pg_dump` of small critical schemas for fast object-level fixes. |

---

## 9. FAQ — the questions Oracle DBAs always ask

**"Can I restore over the existing server?"** No. Every restore produces a new server; cutover is your responsibility. Plan for it.

**"Can I get one table back without a full restore?"** Not directly. Restore the server to the timestamp, then `pg_dump -t` that table and load it into production.

**"Can I download the backup files?"** No — platform backups are encrypted and not exportable, and cannot be used to build a server outside the service. Use `pg_dump`/`pg_restore` for portable copies.

**"Can I take a manual backup before a release?"** Yes — trigger an on-demand backup from the portal (**Backup and restore → Backup now**, with a descriptive name such as `pre-release-v2-1-0`). This is the equivalent of your pre-change RMAN full.

**"Do I need to manage archive log deletion?"** No. WAL retention is governed by your backup retention setting; the platform manages the lifecycle.

**"What's my RPO and RTO?"** RPO: up to ~5 minutes (WAL archive cadence). RTO: not a fixed number — it depends on data size and WAL replay volume. **Measure it in a drill and document your own number.**

**"Is HA a backup?"** No. HA and read replicas protect against infrastructure failure; they faithfully replicate a `DELETE` with no `WHERE`. Only backups protect against logical corruption.

**"What if the region is down?"** Geo-restore into the paired region — **only if geo-redundant backup was enabled at server creation.**

---

## 10. Key takeaways (closing slide)

1. Backups are automatic — **your job is retention, redundancy, and drills.**
2. **Restore = new server.** Rehearse the cutover, not just the restore.
3. **Geo-redundancy is a create-time decision.** There is no retrofit.
4. **35 days is the operational ceiling.** Compliance retention lives in a Backup vault, up to 10 years.
5. There is **no Flashback**. PITR + `pg_dump` cover the same ground with different ergonomics.
6. **Measure your RTO** in a lab, publish it, and re-test quarterly.

---

## Reference documentation

- Backup and restore concepts — https://learn.microsoft.com/en-us/azure/postgresql/backup-restore/concepts-backup-restore
- Restore to latest restore point — https://learn.microsoft.com/en-us/azure/postgresql/backup-restore/how-to-restore-latest-restore-point
- Azure Backup for PostgreSQL Flexible Server (LTR) overview — https://learn.microsoft.com/en-us/azure/backup/backup-azure-database-postgresql-flex-overview
- Configure vaulted backup — https://learn.microsoft.com/en-us/azure/backup/backup-azure-database-postgresql-flex
