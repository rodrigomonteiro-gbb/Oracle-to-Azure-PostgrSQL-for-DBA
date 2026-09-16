# Advanced PostgreSQL Backup & Restore

## `pg_dump` / `pg_restore` to Azure Storage — including multi-terabyte databases

**Platform:** Azure Database for PostgreSQL Flexible Server
**Companion to:** *Backup, Restore & Point-in-Time Restore — Workshop for Oracle DBAs*
**Scope:** logical backup to Azure Storage, from a 10 GB demo database to an 8 TB production estate

---

## 0. Read this before you write any code

### 0.1 Can `pg_dump` write directly to a storage account?

**Not natively.** `pg_dump` has no Azure Blob driver — it writes to a local file, a directory, or stdout. There are two practical ways to land the output in a storage account:

| Approach | How | Verdict |
|---|---|---|
| **A — Dump local, then upload** | `pg_dump -f` → `azcopy` | ✅ Reliable. Needs local disk for the full dump |
| **B — Mount a file share, dump into it** | SMB/NFS mount, `pg_dump -f Z:\...` | ✅ **True "direct to storage."** No staging disk; supports parallel `-Fd -j` |
| **C — Pipe stdout to blob** | `pg_dump \| azcopy` | ⚠️ Fragile — PowerShell mangles binary pipes. Avoid |

### 0.2 ⚠️ The size question — answer this before anything else

> **At 5–8 TB, `pg_dump` is the wrong tool for *backup*.** It is single-threaded per table, has no PITR, no incremental capability, no resumability, and a restore measured in **days**. Using it as your recovery strategy at that scale is a business risk, not a technical choice.

**Use this table to decide what you are actually doing:**

| Database size | Backup strategy | Is `pg_dump` appropriate? |
|---|---|---|
| **< 100 GB** | Platform PITR + optional `pg_dump` | ✅ Yes, for export/portability |
| **100 GB – 1 TB** | Platform PITR + vaulted LTR | ⚠️ Only for migration or object-level work |
| **1 – 5 TB** | Platform PITR + vaulted LTR | ⚠️ Migration only, and plan it as a project |
| **5 TB+** | **Platform PITR + vaulted LTR — full stop** | 🔴 **Not as a backup.** Migration only, with the architecture in Part IV |

**Why the platform backup wins at scale — and it is not close:**

| | Platform snapshot backup | `pg_dump` at 8 TB |
|---|---|---|
| Backup duration | **Near-constant** — storage snapshot | 10–30+ hours |
| Impact on the source | Minimal | Sustained heavy read load |
| RPO | **~5 minutes** (WAL archiving) | Since the last dump — hours or days |
| Restore duration | Hours, driven by size + WAL replay | **Days** — index rebuilds dominate |
| PITR to an arbitrary second | ✅ | ❌ |
| Resumable if it fails at 90% | ✅ N/A | ❌ **Start over** |
| Consistency across databases | ✅ | ❌ Per-database only |

### 0.3 So when IS `pg_dump` the right answer at scale?

| Use case | Why the platform backup cannot do it |
|---|---|
| **Migrate out of Azure**, or to another cloud | Platform backups are encrypted and non-exportable |
| **Cross-major-version** move (PG 13 → 16) | Snapshots cannot restore to a different major version |
| Hand a dataset to a partner, auditor, or dev team | No Azure access required for the recipient |
| **Single-table or single-schema** recovery | Platform PITR restores an entire server |
| Pre-release safety net for one schema | Minutes to take, minutes to restore, no new server |

**Everything in Part IV assumes you have answered "yes" to one of these.** If you are here for routine backup of a multi-TB database, stop and use §1.

---

## 1. The correct multi-TB backup strategy (for reference)

Before the `pg_dump` material, the thing you should actually be doing:

```powershell
$RG  = 'rg-pg-workshop'
$SRC = 'pg-prod-01'

# 1. Operational backup: 7-35 days, snapshot-based, ~5 min RPO
Update-AzPostgreSqlFlexibleServer -ResourceGroupName $RG -Name $SRC -BackupRetentionDay 35

# 2. Confirm redundancy (GRS is CREATE-TIME ONLY -- cannot be added later)
(Get-AzPostgreSqlFlexibleServer -ResourceGroupName $RG -Name $SRC).BackupGeoRedundantBackup

# 3. Long-term retention beyond 35 days: Backup vault (portal: Settings -> LTR)
#    Up to 10 years, stored OUTSIDE your tenant -- ransomware isolation
```

> **For a multi-TB server, vaulted LTR + PITR is the strategy.** `pg_dump` is a supplementary tool for the five use cases in §0.3 — never the primary.

---

# PART I — Create the storage account

```powershell
# ============================ VARIABLES ============================
$RG      = 'rg-pg-workshop'
$LOC     = 'eastus2'
$SRC     = 'pg-prod-01'
$ADMIN   = 'pgadmin'
$SrcFqdn = "$SRC.postgres.database.azure.com"

# Storage account names: 3-24 chars, lowercase letters+digits only, GLOBALLY unique
$STG       = 'stpgbackup' + (Get-Random -Minimum 10000 -Maximum 99999)
$CONTAINER = 'pgdumps'      # blob container  (Option A)
$SHARE     = 'pgdumps'      # file share      (Option B)
# ===================================================================

$sa = New-AzStorageAccount `
        -ResourceGroupName $RG `
        -Name $STG `
        -Location $LOC `
        -SkuName Standard_LRS `          # Standard_GRS for geo-redundant copies
        -Kind StorageV2 `
        -AccessTier Cool `               # dumps are written once, read rarely
        -MinimumTlsVersion TLS1_2 `
        -AllowBlobPublicAccess $false `
        -EnableHttpsTrafficOnly $true

$ctx = $sa.Context

New-AzStorageContainer -Name $CONTAINER -Context $ctx -Permission Off
New-AzStorageShare     -Name $SHARE     -Context $ctx
Set-AzStorageShareQuota -ShareName $SHARE -Quota 5120 -Context $ctx   # 5 TiB

Write-Host "Storage account created: $STG" -ForegroundColor Green
```

**Protect the backups — this is the point of an off-server copy:**

```powershell
# Soft delete: recover blobs deleted accidentally or maliciously
Enable-AzStorageBlobDeleteRetentionPolicy -ResourceGroupName $RG `
    -StorageAccountName $STG -RetentionDays 30

# Versioning: every overwrite keeps the prior version
Update-AzStorageBlobServiceProperty -ResourceGroupName $RG `
    -StorageAccountName $STG -IsVersioningEnabled $true
```

> 💡 **Add an immutability / legal-hold policy** if these dumps are your ransomware insurance. Without it, anyone holding the storage key can delete them — which defeats the entire purpose.

---

# PART II — Small and medium databases (< 500 GB)

## 2. Option A — dump locally, then upload

```powershell
$env:PGPASSWORD = (Read-Host -Prompt 'Postgres admin password' -AsSecureString |
                   ConvertFrom-SecureString -AsPlainText)

$WorkDir = 'D:\pgdumps'
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null

$stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
$DB    = 'salesdb'

# Whole database, custom format (parallel-restorable)  -- like expdp
$full = Join-Path $WorkDir "$DB-full-$stamp.dump"
pg_dump -h $SrcFqdn -U $ADMIN -d $DB -Fc -Z 6 -v -f $full
if ($LASTEXITCODE -ne 0) { throw "pg_dump FAILED (exit $LASTEXITCODE)" }

# Single table only
$tbl = Join-Path $WorkDir "orders-$stamp.dump"
pg_dump -h $SrcFqdn -U $ADMIN -d $DB -Fc -t public.orders -f $tbl

# Schema only / data only
pg_dump -h $SrcFqdn -U $ADMIN -d $DB -Fc --schema-only -f "$WorkDir\$DB-schema-$stamp.dump"
pg_dump -h $SrcFqdn -U $ADMIN -d $DB -Fc --data-only   -f "$WorkDir\$DB-data-$stamp.dump"
```

**Upload with AzCopy:**

```powershell
$sas = New-AzStorageContainerSASToken -Name $CONTAINER `
         -Permission racwdl -ExpiryTime (Get-Date).AddHours(8) -Context $ctx

$dest   = "https://$STG.blob.core.windows.net/$CONTAINER"
$prefix = (Get-Date).ToUniversalTime().ToString('yyyy/MM/dd')

Get-ChildItem $WorkDir -Filter "*$stamp*" | ForEach-Object {
    azcopy copy "$($_.FullName)" "$dest/$prefix/$($_.Name)$sas" --block-size-mb 64
    if ($LASTEXITCODE -ne 0) { Write-Warning "Upload FAILED: $($_.Name)" }
}
```

**Or pure Az PowerShell** (simpler, slower — fine under a few GB):

```powershell
Set-AzStorageBlobContent -File $full -Container $CONTAINER `
    -Blob "$prefix/$(Split-Path $full -Leaf)" -Context $ctx `
    -StandardBlobTier Cool -Force
```

## 3. Option B — mount a file share, dump straight into it

```powershell
# Port 445 outbound must be open (many ISPs and corp networks block it)
Test-NetConnection -ComputerName "$STG.file.core.windows.net" -Port 445
```

```powershell
$key = (Get-AzStorageAccountKey -ResourceGroupName $RG -Name $STG)[0].Value

cmd /c "cmdkey /add:`"$STG.file.core.windows.net`" /user:`"localhost\$STG`" /pass:`"$key`""

New-PSDrive -Name Z -PSProvider FileSystem `
    -Root "\\$STG.file.core.windows.net\$SHARE" -Persist

Get-PSDrive Z | Format-List Name, Root, Used, Free
```

```powershell
$stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
$dir   = "Z:\$($stamp.Substring(0,8))"
New-Item -ItemType Directory -Path $dir -Force | Out-Null

# pg_dump writes DIRECTLY to the storage account
pg_dump -h $SrcFqdn -U $ADMIN -d salesdb -Fc -Z 6 -v -f "$dir\salesdb-full-$stamp.dump"

# DIRECTORY format with PARALLEL dump -- needs a real filesystem, so only works here
pg_dump -h $SrcFqdn -U $ADMIN -d salesdb -Fd -j 4 -Z 6 -f "$dir\salesdb-pardump"
if ($LASTEXITCODE -ne 0) { throw "Parallel pg_dump FAILED (exit $LASTEXITCODE)" }
```

> ⚠️ **SMB over the internet is latency-sensitive.** Run from a VM **in the same region** as both the storage account and the database. From a laptop over VPN this will be slow and prone to timeouts mid-dump.

## 4. Restore

```powershell
$TGT5    = 'pg-restore-05'
$TgtFqdn = "$TGT5.postgres.database.azure.com"
$DB      = 'salesdb'

$env:PGPASSWORD = (Read-Host -Prompt 'Target admin password' -AsSecureString |
                   ConvertFrom-SecureString -AsPlainText)

# Inspect a dump without restoring it  -- like impdp SQLFILE=
pg_restore --list "Z:\20260916\salesdb-full-20260916-143000.dump" | Select-Object -First 40

# pg_restore will NOT create the database for you
psql -h $TgtFqdn -U $ADMIN -d postgres -c "CREATE DATABASE $DB;"

# Restore with 4 parallel jobs  -- like impdp
pg_restore -h $TgtFqdn -U $ADMIN -d $DB -j 4 -v --no-owner --no-privileges `
    "Z:\20260916\salesdb-full-20260916-143000.dump"
```

**Selective restore — the pattern Oracle DBAs expect:**

```powershell
# Single table into an existing database
pg_restore -h $TgtFqdn -U $ADMIN -d $DB -t orders -v "Z:\20260916\orders-20260916-143000.dump"

# Schema first, then data -- lets you fix DDL between the two steps
pg_restore -h $TgtFqdn -U $ADMIN -d $DB "Z:\...\salesdb-schema-...dump"
pg_restore -h $TgtFqdn -U $ADMIN -d $DB -j 4 "Z:\...\salesdb-data-...dump"

# Generate SQL instead of executing it -- review before applying
pg_restore -f "D:\review.sql" "Z:\...\salesdb-full-...dump"
```

> **`--no-owner --no-privileges` is almost always right on Azure.** Source roles rarely exist on the target and there is no superuser to create them. Without these flags you get a wall of *role does not exist* errors.

---

# PART III — Sizing the job before you start

## 5. The arithmetic that decides your architecture

**Do this calculation before provisioning anything.** It is the difference between a planned 12-hour window and a failed 30-hour attempt.

```powershell
# Actual logical size on the source
$env:PGPASSWORD = (Read-Host -Prompt 'Postgres admin password' -AsSecureString |
                   ConvertFrom-SecureString -AsPlainText)

psql -h $SrcFqdn -U $ADMIN -d salesdb -c @"
SELECT pg_size_pretty(pg_database_size(current_database())) AS database_size;

SELECT schemaname,
       relname                                              AS table_name,
       pg_size_pretty(pg_total_relation_size(relid))        AS total,
       pg_size_pretty(pg_relation_size(relid))              AS heap,
       pg_size_pretty(pg_indexes_size(relid))               AS indexes,
       pg_total_relation_size(relid)                        AS bytes
FROM pg_catalog.pg_statio_user_tables
ORDER BY pg_total_relation_size(relid) DESC
LIMIT 25;
"@
```

> **💡 The number that matters is `heap`, not `total`.** `pg_dump` exports **data only** — indexes are *recreated* on restore, not copied. An 8 TB database with 3 TB of indexes dumps 5 TB of heap, and then spends most of the restore window rebuilding those 3 TB of indexes.

### 5.1 Estimating duration

| Input | How to get it |
|---|---|
| **Heap size** | The query above, summed |
| **Compression ratio** | Typically **3–5×** on mixed data; test on your largest table |
| **Sustained read throughput** | Limited by the *lowest* of: source IOPS, VM network, destination write speed |

```
Dump duration    ≈ heap_size / sustained_throughput
Dump output size ≈ heap_size / compression_ratio
Restore duration ≈ 2× to 4× the dump duration   (index rebuilds dominate)
```

**Worked example — 8 TB database, 5 TB heap:**

| Sustained throughput | Dump time | Restore time (est.) | Total window |
|---|---|---|---|
| 100 MB/s | ~14 hours | 28–56 h | 🔴 **2–3 days** |
| 250 MB/s | ~5.5 hours | 11–22 h | 🟠 ~1 day |
| 500 MB/s | ~3 hours | 6–12 h | 🟡 Feasible weekend |
| 1 GB/s | ~1.5 hours | 3–6 h | 🟢 Overnight |

> ⚠️ **Treat these as planning estimates, not commitments.** The only number you can defend is one you measured — **dump your largest single table first and extrapolate.** §7.1 shows how.

### 5.2 Where the bottleneck actually is

```
  SOURCE SERVER            NETWORK              WORKER VM           DESTINATION
  ┌──────────────┐       ┌─────────┐         ┌───────────┐        ┌────────────┐
  │ Storage IOPS │──────▶│ VNet /  │────────▶│ pg_dump   │───────▶│ Azure Files│
  │ + CPU        │       │ Private │         │ + compress│        │  or Blob   │
  │              │       │ Endpoint│         │ (CPU!)    │        │            │
  └──────────────┘       └─────────┘         └───────────┘        └────────────┘
        │                     │                    │                     │
   read_iops /           VM NIC Gbps          vCPU count for       provisioned
   disk_bandwidth_       (E32 ≈ 16 Gbps)      -j workers and       throughput
   consumed_pct                               compression          (scales with size)
```

**The four limits, and how to check each:**

| Limit | Check it with |
|---|---|
| **Source storage** | `disk_iops_consumed_percentage` metric. At 100% you are capped — scale up IOPS |
| **Source CPU** | `cpu_percent`. Compression happens on the *client*, but the server still reads |
| **VM network** | Compare observed MB/s against the VM SKU's documented bandwidth |
| **Destination write** | Azure Files throughput scales with provisioned size — **under-provisioning here is the most common mistake** |

---

# PART IV — Multi-terabyte architecture (5–8 TB)

## 6. Architecture: no local staging, no laptop, no small VM

```
                 ┌──────────────────────────────────────────┐
                 │  Azure VNet  (same region, private only) │
                 │                                          │
 ┌───────────────┴──┐    ┌──────────────────┐    ┌──────────┴────────────┐
 │ PostgreSQL Flex  │    │  WORKER VM       │    │ Azure Files PREMIUM   │
 │ pg-prod-01       │───▶│  E32ds_v5+       │───▶│  or Azure NetApp Files│
 │ (scaled UP for   │    │  32+ vCPU        │    │  (NFS / SMB mount)    │
 │  the operation)  │    │  Private EP      │    │  provisioned for      │
 └──────────────────┘    │  NO staging disk │    │  THROUGHPUT           │
                         └──────────────────┘    └───────────┬───────────┘
                                                             │
                                                             ▼
                                              ┌──────────────────────────┐
                                              │ Blob (Cool/Archive) for  │
                                              │ long-term retention      │
                                              └──────────────────────────┘
```

**The three design decisions:**

1. **Never stage 5 TB on a local disk.** Mount premium file storage and write directly into it. You avoid buying a 6 TB disk *and* the second copy operation.
2. **Everything in one region, over a private endpoint.** Public-endpoint traffic adds latency and, on some paths, egress charges.
3. **Scale the source up for the operation, then back down.** Near-zero-downtime compute and IOPS scaling makes this cheap, and IOPS is usually the binding constraint.

## 7. Provision the environment

### 7.1 Measure before you commit — the 30-minute pilot

> 🔴 **Do this first.** Dump your single largest table and extrapolate. Thirty minutes here saves a failed 30-hour window.

```powershell
$env:PGPASSWORD = (Read-Host -Prompt 'Postgres admin password' -AsSecureString |
                   ConvertFrom-SecureString -AsPlainText)

$probeTable = 'public.salesorderdetail'    # <-- your largest table
$probeOut   = 'D:\probe.dump'

$sw = [System.Diagnostics.Stopwatch]::StartNew()
pg_dump -h $SrcFqdn -U $ADMIN -d salesdb -Fc -Z 6 -t $probeTable -f $probeOut
$sw.Stop()

$sizeGB = (Get-Item $probeOut).Length / 1GB
[pscustomobject]@{
    Table            = $probeTable
    DumpMinutes      = [math]::Round($sw.Elapsed.TotalMinutes, 1)
    DumpFileGB       = [math]::Round($sizeGB, 2)
    ThroughputMBps   = [math]::Round(($sizeGB * 1024) / $sw.Elapsed.TotalSeconds, 1)
} | Format-List
```

**Extrapolate:** `total_heap_GB / (ThroughputMBps × 3.6)` ≈ hours for a single-threaded dump. Divide by your intended `-j` worker count for the parallel estimate — **but expect sub-linear scaling**, because you will hit a shared bottleneck (§5.2) before workers do.

### 7.2 Premium file storage sized for throughput, not capacity

```powershell
$STGPREM = 'stpgprem' + (Get-Random -Minimum 10000 -Maximum 99999)

# Premium FileStorage: SSD-backed, provisioned model.
# THROUGHPUT SCALES WITH PROVISIONED SIZE -- provision well above your data size.
$saPrem = New-AzStorageAccount `
    -ResourceGroupName $RG `
    -Name $STGPREM `
    -Location $LOC `
    -SkuName Premium_LRS `
    -Kind FileStorage `
    -MinimumTlsVersion TLS1_2 `
    -EnableHttpsTrafficOnly $false      # required for NFS shares

$ctxPrem = $saPrem.Context

# Provision 10 TiB for a ~2 TB dump footprint -- you are buying THROUGHPUT
New-AzRmStorageShare -ResourceGroupName $RG -StorageAccountName $STGPREM `
    -Name 'pgdump-prem' -QuotaGiB 10240 -EnabledProtocol SMB
```

> ⚠️ **This is the mistake that ruins multi-TB dumps.** Provisioning a 2 TiB share for 2 TB of output gives you 2 TiB worth of throughput — and the dump crawls. **Provision 3–5× your expected output size.** You pay for provisioned capacity, but only for the hours the operation runs; delete the share afterwards.
>
> 💡 **For the largest jobs, evaluate Azure NetApp Files** (Premium or Ultra tier). Throughput scales per TiB of provisioned capacity and is substantially higher than Azure Files Premium at the top end. It is more expensive per GiB, but for a one-off migration the *window* usually costs more than the storage.

### 7.3 Worker VM

```powershell
$VMNAME = 'vm-pgdump-worker'
$VNET   = 'vnet-pg-workshop'
$SUBNET = 'snet-workers'

# Example sizing -- verify current SKU specs for your region before deploying.
#   E32ds_v5 : 32 vCPU / 256 GB RAM / high network bandwidth
#   E64ds_v5 : 64 vCPU / 512 GB RAM  -- for -j 16 and above
$cred = Get-Credential -Message 'Local admin for the worker VM'

New-AzVm `
    -ResourceGroupName $RG `
    -Name $VMNAME `
    -Location $LOC `
    -VirtualNetworkName $VNET `
    -SubnetName $SUBNET `
    -SecurityGroupName 'nsg-workers' `
    -PublicIpAddressName $null `          # no public IP -- private only
    -Size 'Standard_E32ds_v5' `
    -Image 'Win2022Datacenter' `
    -Credential $cred `
    -OpenPorts @()
```

**On the VM, install the PostgreSQL client tools and AzCopy:**

```powershell
# Client tools MUST be the same major version as the TARGET, or newer.
# A PG 16 pg_dump can read a PG 13 server; a PG 13 pg_restore cannot read a PG 16 dump.
winget install --id PostgreSQL.PostgreSQL.16 --silent
winget install --id Microsoft.Azure.AZCopy.10 --silent

$env:Path += ';C:\Program Files\PostgreSQL\16\bin'
pg_dump --version
```

### 7.4 Scale the source up for the operation

```powershell
# Record the current configuration so you can scale back
$before = Get-AzPostgreSqlFlexibleServer -ResourceGroupName $RG -Name $SRC
$before | Select-Object Name, SkuName, SkuTier, StorageSizeGb | Format-List

# Scale up -- IOPS is usually the binding constraint, not vCPU
Update-AzPostgreSqlFlexibleServer -ResourceGroupName $RG -Name $SRC `
    -Sku 'Standard_E16ds_v5' -SkuTier MemoryOptimized
```

> 💡 **Scale the *source* for the dump and the *target* for the restore.** Both are temporary. On a multi-day operation the compute cost is trivial next to the cost of the outage window.

### 7.5 Mount the premium share

```powershell
$keyPrem = (Get-AzStorageAccountKey -ResourceGroupName $RG -Name $STGPREM)[0].Value

cmd /c "cmdkey /add:`"$STGPREM.file.core.windows.net`" /user:`"localhost\$STGPREM`" /pass:`"$keyPrem`""

New-PSDrive -Name D -PSProvider FileSystem `
    -Root "\\$STGPREM.file.core.windows.net\pgdump-prem" -Persist

# Sanity-check write throughput BEFORE the real run
$testFile = 'D:\throughput-test.bin'
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$buffer = New-Object byte[] (256MB)
[System.IO.File]::WriteAllBytes($testFile, $buffer)
$sw.Stop()
"Write throughput: {0:N0} MB/s" -f (256 / $sw.Elapsed.TotalSeconds)
Remove-Item $testFile
```

> **If that number is below ~200 MB/s, stop and fix it** before starting an 8 TB dump. Check: share provisioned size, VM SKU network limits, and that you are in the same region.

## 8. The parallel dump

### 8.1 Directory format — the only viable format at this scale

```powershell
$env:PGPASSWORD = (Read-Host -Prompt 'Postgres admin password' -AsSecureString |
                   ConvertFrom-SecureString -AsPlainText)

$stamp   = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
$dumpDir = "D:\salesdb-$stamp"
$DB      = 'salesdb'
$JOBS    = 16     # start at vCPU/2; raise while throughput still improves

$sw = [System.Diagnostics.Stopwatch]::StartNew()

pg_dump `
    -h $SrcFqdn -U $ADMIN -d $DB `
    --format=directory `
    --jobs=$JOBS `
    --compress=6 `
    --no-owner --no-privileges `
    --verbose `
    --file=$dumpDir 2>&1 | Tee-Object -FilePath "D:\pgdump-$stamp.log"

$sw.Stop()

if ($LASTEXITCODE -ne 0) { throw "pg_dump FAILED (exit $LASTEXITCODE) -- see the log" }

"Dump completed in {0:N1} hours" -f $sw.Elapsed.TotalHours
```

> **Why directory format is mandatory here:**
>
> | | Custom `-Fc` | **Directory `-Fd`** |
> |---|---|---|
> | Parallel dump (`-j`) | ❌ **Not supported** | ✅ |
> | Parallel restore (`-j`) | ✅ | ✅ |
> | Output | One large file | One file **per table** |
> | Per-table retry after failure | ❌ | ✅ (with orchestration — §8.3) |
> | Can write to a pipe | ✅ | ❌ Needs a filesystem |
>
> **At 5 TB, `-Fc` is a non-starter** — a single-threaded dump of that volume takes days, and a single 1.5 TB file is unwieldy to move and impossible to partially retry.

### 8.2 Compression choice matters at this scale

```powershell
# PostgreSQL 16+ supports multiple algorithms. zstd is dramatically faster
# than gzip at a comparable ratio -- and compression runs on the CLIENT,
# so at high -j it competes with your dump workers for CPU.
pg_dump -h $SrcFqdn -U $ADMIN -d $DB -Fd -j 16 --compress=zstd:3 -f $dumpDir

# If the VM is CPU-bound (check Task Manager during the pilot), drop the level
pg_dump -h $SrcFqdn -U $ADMIN -d $DB -Fd -j 16 --compress=zstd:1 -f $dumpDir

# If the network/storage is the bottleneck and CPU is idle, compress harder
pg_dump -h $SrcFqdn -U $ADMIN -d $DB -Fd -j 16 --compress=zstd:9 -f $dumpDir
```

| Setting | Use when |
|---|---|
| `--compress=zstd:1` | VM is CPU-saturated — trade size for speed |
| **`--compress=zstd:3`** | **Best default on PG 16+** |
| `--compress=6` (gzip) | PG 15 and earlier, or client tools without zstd |
| `--compress=0` | Storage and network are abundant, CPU is the constraint |

> **Watch VM CPU during the pilot run.** If all cores are pinned, compression is your bottleneck — lower the level rather than lowering `-j`.

### 8.3 ⭐ Shard by table for resumability

**`pg_dump` has no resume capability.** A failure at hour 11 of 14 means starting over. At multi-TB scale that is unacceptable — so drive it yourself, one table at a time, with a manifest.

```powershell
# ---------------------------------------------------------------
# Build a work list: every table, largest first
# ---------------------------------------------------------------
$listSql = @"
SELECT quote_ident(schemaname) || '.' || quote_ident(relname) AS fq,
       pg_total_relation_size(relid)                          AS bytes
FROM pg_catalog.pg_statio_user_tables
ORDER BY pg_total_relation_size(relid) DESC;
"@

$tables = psql -h $SrcFqdn -U $ADMIN -d $DB -t -A -F '|' -c $listSql |
          Where-Object { $_ -match '\|' } |
          ForEach-Object {
              $p = $_ -split '\|'
              [pscustomobject]@{ Table = $p[0]; Bytes = [int64]$p[1] }
          }

"Found $($tables.Count) tables, total $([math]::Round(($tables.Bytes | Measure-Object -Sum).Sum / 1TB, 2)) TB"
```

```powershell
# ---------------------------------------------------------------
# Dump each table separately, tracking state in a manifest.
# Re-running the script SKIPS tables already completed.
# ---------------------------------------------------------------
$root     = "D:\salesdb-sharded"
$manifest = "$root\manifest.csv"
New-Item -ItemType Directory -Path $root -Force | Out-Null

$done = @{}
if (Test-Path $manifest) {
    Import-Csv $manifest | Where-Object Status -eq 'OK' |
        ForEach-Object { $done[$_.Table] = $true }
    Write-Host "Resuming -- $($done.Count) tables already complete" -ForegroundColor Cyan
}

# First run only: schema without data
if (-not (Test-Path "$root\_schema.dump")) {
    pg_dump -h $SrcFqdn -U $ADMIN -d $DB -Fc --schema-only --no-owner --no-privileges `
        -f "$root\_schema.dump"
}

foreach ($t in $tables) {
    if ($done.ContainsKey($t.Table)) { continue }

    $safe = $t.Table -replace '[^A-Za-z0-9]', '_'
    $out  = "$root\$safe.dump"
    $sw   = [System.Diagnostics.Stopwatch]::StartNew()

    Write-Host ("Dumping {0} ({1:N2} GB)..." -f $t.Table, ($t.Bytes / 1GB))

    pg_dump -h $SrcFqdn -U $ADMIN -d $DB -Fc --compress=zstd:3 `
            --no-owner --no-privileges -t $t.Table -f $out
    $exit = $LASTEXITCODE
    $sw.Stop()

    [pscustomobject]@{
        Table       = $t.Table
        SourceBytes = $t.Bytes
        DumpBytes   = if (Test-Path $out) { (Get-Item $out).Length } else { 0 }
        Minutes     = [math]::Round($sw.Elapsed.TotalMinutes, 2)
        Status      = if ($exit -eq 0) { 'OK' } else { "FAILED($exit)" }
        CompletedAt = (Get-Date).ToUniversalTime().ToString('o')
    } | Export-Csv $manifest -NoTypeInformation -Append

    if ($exit -ne 0) { Write-Warning "FAILED: $($t.Table) -- re-run the script to retry" }
}

Import-Csv $manifest | Group-Object Status | Select-Object Name, Count
```

> **Why this is worth the extra code at 5 TB+:**
> - ✅ **Resumable** — re-run and it picks up where it stopped
> - ✅ **Per-table retry** — one bad table does not cost you the other 4.9 TB
> - ✅ **Observable** — the manifest tells you exactly where you are and how fast
> - ✅ **Splittable across windows** — run 2 TB tonight, 3 TB tomorrow
> - ⚠️ **Trade-off:** tables are **not mutually consistent** unless you add a snapshot (§8.4)

### 8.4 Consistency across a sharded dump

Independent `pg_dump` invocations each take their own snapshot — so a sharded dump is **not** a point-in-time-consistent copy. Fix it with an exported snapshot:

```sql
-- SESSION 1: hold a repeatable-read snapshot open for the whole dump
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ;
SELECT pg_export_snapshot();     -- returns e.g. '00000003-0000001B-1'
-- LEAVE THIS SESSION OPEN until every shard has finished
```

```powershell
$SNAPSHOT = '00000003-0000001B-1'   # <-- from the query above

pg_dump -h $SrcFqdn -U $ADMIN -d $DB -Fc --snapshot=$SNAPSHOT `
        -t $t.Table -f $out
```

> ⚠️ **Holding a snapshot open for hours blocks `VACUUM` from cleaning any dead tuple newer than it — across the entire database.** On a busy 8 TB server a 14-hour snapshot can cause serious bloat and, in the worst case, push you toward transaction-ID wraparound.
>
> **Decide deliberately:**
> - **Migration with a maintenance window** (source read-only) → skip the snapshot; nothing is changing
> - **Online export from a live system** → use the snapshot, accept the bloat, and schedule an aggressive `VACUUM` afterwards

### 8.5 Monitor the dump while it runs

```powershell
# From another session -- watch it progress
while ($true) {
    $files = Get-ChildItem $dumpDir -Recurse -File -ErrorAction SilentlyContinue
    $gb    = [math]::Round((($files | Measure-Object Length -Sum).Sum) / 1GB, 2)
    Write-Host ("{0:HH:mm:ss}  files={1}  written={2} GB" -f (Get-Date), $files.Count, $gb)
    Start-Sleep -Seconds 60
}
```

```sql
-- On the source: what are the dump workers actually doing?
SELECT pid, state, wait_event_type, wait_event,
       now() - query_start AS running_for,
       left(query, 80) AS query
FROM pg_stat_activity
WHERE application_name LIKE 'pg_dump%'
ORDER BY query_start;
```

```powershell
# Source-side saturation -- is the server the bottleneck?
# (KQL for ArcBox-law; see the monitoring query pack)
```

```kusto
AzureMetrics
| where TimeGenerated > ago(4h)
| where ResourceProvider == "MICROSOFT.DBFORPOSTGRESQL"
| where MetricName in ("cpu_percent","read_iops","disk_iops_consumed_percentage",
                       "network_bytes_egress","active_connections")
| summarize Value = avg(Average) by MetricName, bin(TimeGenerated, 1m)
| render timechart with (title="Source server load during pg_dump")
```

> **👁 What to look for:** `disk_iops_consumed_percentage` pinned at 100% means the **source storage** is the bottleneck — scale IOPS up, not `-j`. Adding workers against a saturated disk makes it *slower*.

## 9. Move the dump to long-term storage

```powershell
# Premium file share -> Cool blob for retention. AzCopy handles directories natively.
$sasPrem = New-AzStorageContainerSASToken -Name $CONTAINER `
             -Permission racwdl -ExpiryTime (Get-Date).AddHours(24) -Context $ctx

$prefix = (Get-Date).ToUniversalTime().ToString('yyyy/MM/dd')

azcopy copy "D:\salesdb-$stamp" `
    "https://$STG.blob.core.windows.net/$CONTAINER/$prefix/$sasPrem" `
    --recursive `
    --block-size-mb 100 `
    --cap-mbps 0 `
    --log-level INFO

if ($LASTEXITCODE -ne 0) { throw "AzCopy FAILED (exit $LASTEXITCODE)" }
```

```powershell
# Verify the transfer -- count and total size must match
$local = Get-ChildItem "D:\salesdb-$stamp" -Recurse -File
$blobs = Get-AzStorageBlob -Container $CONTAINER -Context $ctx -Prefix "$prefix/salesdb-$stamp"

[pscustomobject]@{
    LocalFiles = $local.Count
    LocalGB    = [math]::Round((($local | Measure-Object Length -Sum).Sum)/1GB, 2)
    BlobFiles  = $blobs.Count
    BlobGB     = [math]::Round((($blobs | Measure-Object Length -Sum).Sum)/1GB, 2)
} | Format-List
```

```powershell
# Once verified, release the expensive premium share
Remove-PSDrive -Name D -Force
Remove-AzRmStorageShare -ResourceGroupName $RG -StorageAccountName $STGPREM `
    -Name 'pgdump-prem' -Force
```

---

# PART V — Restoring at multi-terabyte scale

## 10. Prepare the target — this is where the window is won or lost

> **Index and constraint rebuilds dominate a large restore**, typically consuming more time than the data load itself. Tuning the target beforehand is not optional.

```powershell
$TGT     = 'pg-restore-05'
$TgtFqdn = "$TGT.postgres.database.azure.com"

# Restore onto a LARGER SKU than steady state, then scale down afterwards
Update-AzPostgreSqlFlexibleServer -ResourceGroupName $RG -Name $TGT `
    -Sku 'Standard_E32ds_v5' -SkuTier MemoryOptimized
```

**Server parameters for the restore window** (portal → Settings → Server parameters, or CLI):

| Parameter | Restore value | Why | Revert after? |
|---|---|---|---|
| `maintenance_work_mem` | **2 GB** | Index builds — the single biggest win | ✅ Yes |
| `max_wal_size` | **32 GB** | Far fewer checkpoints during bulk load | ✅ Yes |
| `checkpoint_timeout` | **30 min** | Same | ✅ Yes |
| `max_parallel_maintenance_workers` | **4–8** | Parallel index builds | ✅ Yes |
| `autovacuum` | **off** | Stop it competing during the load | ✅ **Critical to revert** |
| `synchronous_commit` | **off** | Removes an fsync per commit | ✅ Yes |
| `wal_compression` | **on** | Less WAL, less I/O | Can stay on |
| `shared_buffers` | 25% of RAM | Standard | Leave |

```powershell
az postgres flexible-server parameter set -g $RG -s $TGT -n maintenance_work_mem --value 2097151
az postgres flexible-server parameter set -g $RG -s $TGT -n max_wal_size --value 32768
az postgres flexible-server parameter set -g $RG -s $TGT -n autovacuum --value off
az postgres flexible-server parameter set -g $RG -s $TGT -n synchronous_commit --value off
```

> ⚠️ **Set a calendar reminder to revert `autovacuum`.** A multi-TB database running with autovacuum off will bloat catastrophically and march toward transaction-ID wraparound. **More production incidents come from forgetting this than from the restore itself.**

## 11. The parallel restore

```powershell
$env:PGPASSWORD = (Read-Host -Prompt 'Target admin password' -AsSecureString |
                   ConvertFrom-SecureString -AsPlainText)

$DB      = 'salesdb'
$dumpDir = "D:\salesdb-20260916-143000"
$JOBS    = 16

psql -h $TgtFqdn -U $ADMIN -d postgres -c "CREATE DATABASE $DB;"

$sw = [System.Diagnostics.Stopwatch]::StartNew()

pg_restore `
    -h $TgtFqdn -U $ADMIN -d $DB `
    --jobs=$JOBS `
    --no-owner --no-privileges `
    --verbose `
    --exit-on-error `
    $dumpDir 2>&1 | Tee-Object -FilePath "D:\pgrestore-$(Get-Date -f yyyyMMdd-HHmmss).log"

$sw.Stop()
"Restore completed in {0:N1} hours" -f $sw.Elapsed.TotalHours
```

### 11.1 Three-phase restore — maximum control

For the largest jobs, split it. You get better parallelism on the data load and can fix problems between phases.

```powershell
# Phase 1: schema only, WITHOUT indexes and constraints
pg_restore -h $TgtFqdn -U $ADMIN -d $DB --section=pre-data `
           --no-owner --no-privileges -v $dumpDir

# Phase 2: data only -- maximum parallelism, no index maintenance overhead
pg_restore -h $TgtFqdn -U $ADMIN -d $DB --section=data `
           --jobs=$JOBS --no-owner --no-privileges -v $dumpDir

# Phase 3: indexes, constraints, triggers -- the long pole
pg_restore -h $TgtFqdn -U $ADMIN -d $DB --section=post-data `
           --jobs=$JOBS --no-owner --no-privileges -v $dumpDir
```

> **Why this beats a single `pg_restore` at scale:** in phase 2 there are no indexes to maintain, so the data loads at raw `COPY` speed. Phase 3 then builds every index **in parallel** on a fully-populated table — which is far faster than maintaining them incrementally during the load.

### 11.2 Restoring a sharded dump

```powershell
$root     = "D:\salesdb-sharded"
$manifest = "$root\manifest.csv"
$restored = "$root\restore-manifest.csv"

# Schema first
pg_restore -h $TgtFqdn -U $ADMIN -d $DB --no-owner --no-privileges "$root\_schema.dump"

$alreadyDone = @{}
if (Test-Path $restored) {
    Import-Csv $restored | Where-Object Status -eq 'OK' |
        ForEach-Object { $alreadyDone[$_.Table] = $true }
}

Import-Csv $manifest | Where-Object Status -eq 'OK' | ForEach-Object {
    if ($alreadyDone.ContainsKey($_.Table)) { return }

    $safe = $_.Table -replace '[^A-Za-z0-9]', '_'
    $file = "$root\$safe.dump"
    $sw   = [System.Diagnostics.Stopwatch]::StartNew()

    pg_restore -h $TgtFqdn -U $ADMIN -d $DB -j 4 `
               --no-owner --no-privileges --data-only $file
    $exit = $LASTEXITCODE
    $sw.Stop()

    [pscustomobject]@{
        Table   = $_.Table
        Minutes = [math]::Round($sw.Elapsed.TotalMinutes, 2)
        Status  = if ($exit -eq 0) { 'OK' } else { "FAILED($exit)" }
    } | Export-Csv $restored -NoTypeInformation -Append
}
```

## 12. Post-restore — mandatory steps

```powershell
# 1. REVERT the parameters -- especially autovacuum
az postgres flexible-server parameter set -g $RG -s $TGT -n autovacuum --value on
az postgres flexible-server parameter set -g $RG -s $TGT -n synchronous_commit --value on
az postgres flexible-server parameter set -g $RG -s $TGT -n maintenance_work_mem --value 524288
az postgres flexible-server parameter set -g $RG -s $TGT -n max_wal_size --value 2048

# 2. ANALYZE -- statistics are NOT in the dump. Skip this and every plan is wrong.
psql -h $TgtFqdn -U $ADMIN -d $DB -c "ANALYZE VERBOSE;"

# 3. Scale back to steady state
Update-AzPostgreSqlFlexibleServer -ResourceGroupName $RG -Name $TGT `
    -Sku 'Standard_D4ds_v5' -SkuTier GeneralPurpose
```

```sql
-- 4. Reconcile row counts against the source
SELECT schemaname, relname, n_live_tup
FROM pg_stat_user_tables
ORDER BY n_live_tup DESC
LIMIT 30;

-- 5. Confirm every index and constraint arrived
SELECT count(*) FILTER (WHERE indisvalid)     AS valid_indexes,
       count(*) FILTER (WHERE NOT indisvalid) AS INVALID_INDEXES
FROM pg_index i
JOIN pg_class c ON c.oid = i.indrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname NOT IN ('pg_catalog','information_schema');

-- 6. Sequences -- a classic post-restore bug
SELECT schemaname, sequencename, last_value
FROM pg_sequences
WHERE last_value IS NULL OR last_value < 2;
```

> ⚠️ **Statistics are not included in a dump.** Until you `ANALYZE`, the planner has nothing and will produce terrible plans on a freshly restored database. Users will report "the migration made everything slow" and they will be right — for about twenty minutes.

## 13. Verification checklist

```powershell
# Compare object counts between source and target
$verify = @"
SELECT 'tables'    AS object, count(*) FROM pg_stat_user_tables
UNION ALL SELECT 'indexes',   count(*) FROM pg_stat_user_indexes
UNION ALL SELECT 'sequences', count(*) FROM pg_sequences
UNION ALL SELECT 'views',     count(*) FROM pg_views    WHERE schemaname NOT LIKE 'pg\_%'
UNION ALL SELECT 'functions', count(*) FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
          WHERE n.nspname NOT IN ('pg_catalog','information_schema');
"@

"--- SOURCE ---"; psql -h $SrcFqdn -U $ADMIN -d $DB -c $verify
"--- TARGET ---"; psql -h $TgtFqdn -U $ADMIN -d $DB -c $verify
```

```sql
-- Row-count reconciliation for the largest tables (exact, not estimated)
SELECT 'public.salesorderdetail' AS t, count(*) FROM public.salesorderdetail
UNION ALL
SELECT 'public.orders', count(*) FROM public.orders;
```

---

# PART VI — Alternatives for very large migrations

## 14. When `pg_dump` is still the wrong tool

| Tool | What it does | Use when |
|---|---|---|
| **Azure migration service** | Managed PG → Flexible Server migration, online or offline | **First choice** for PostgreSQL → Azure PostgreSQL |
| **`pgcopydb`** | Parallel clone with index-build parallelism, resumable | Large PG → PG, more parallel than `pg_dump` |
| **Logical replication** | Continuous CDC; cut over with near-zero downtime | 24×7 workloads that cannot take an outage |
| **Read replica + promote** | Replica in the target region, promoted at cutover | Region moves within Azure |
| **Platform PITR / geo-restore** | Snapshot-based | **Any routine recovery scenario** |

```powershell
# pgcopydb -- purpose-built for exactly this problem (Linux worker VM)
# pgcopydb clone \
#   --source "postgres://pgadmin@pg-prod-01.postgres.database.azure.com/salesdb" \
#   --target "postgres://pgadmin@pg-restore-05.postgres.database.azure.com/salesdb" \
#   --table-jobs 8 --index-jobs 8 --split-tables-larger-than 10GB \
#   --resume --not-consistent
```

> **`pgcopydb` is materially better than `pg_dump | pg_restore` for PG→PG at scale**: it streams directly (no intermediate files at all), parallelizes index builds independently of table loads, splits single large tables across workers, and is **resumable**. If your job is a PG→PG migration of several TB, evaluate it before writing the orchestration in §8.3.

---

## 15. Cost considerations

| Component | Driver | Control it by |
|---|---|---|
| **Premium file share** | Provisioned GiB × hours | Provision large, **delete immediately after** |
| **Worker VM** | SKU × hours | Deallocate the moment the job finishes |
| **Blob storage** | GB-month, by tier | Cool for 30 days → Archive → delete |
| **Source scale-up** | vCPU-hours | Scale back the same day |
| **Egress** | Cross-region / internet | **Keep everything in one region** |

```powershell
# Lifecycle: Cool -> Archive at 30 days, delete at 365
$rule = New-AzStorageAccountManagementPolicyRule -Name 'pgdump-lifecycle' `
    -Action (New-AzStorageAccountManagementPolicyAction `
                -BaseBlobAction TierToArchive -daysAfterModificationGreaterThan 30 |
             Add-AzStorageAccountManagementPolicyAction `
                -BaseBlobAction Delete -daysAfterModificationGreaterThan 365) `
    -Filter (New-AzStorageAccountManagementPolicyFilter -PrefixMatch $CONTAINER -BlobType blockBlob)

Set-AzStorageAccountManagementPolicy -ResourceGroupName $RG -StorageAccountName $STG -Rule $rule
```

```powershell
# Always tear down the expensive parts
Stop-AzVM -ResourceGroupName $RG -Name $VMNAME -Force          # stop billing compute
Remove-PSDrive -Name D -Force -ErrorAction SilentlyContinue
Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue
cmd /c "cmdkey /delete:$STGPREM.file.core.windows.net"
```

---

## 16. Multi-terabyte runbook checklist

**Before you start**
- [ ] Confirmed `pg_dump` is the right tool (§0.3) — not routine backup
- [ ] Heap size measured separately from index size (§5)
- [ ] **Pilot dump of the largest table completed**; throughput extrapolated (§7.1)
- [ ] Window estimated, including a 2–4× restore multiplier
- [ ] Client tools are the **target's major version or newer**
- [ ] Everything in one region; private endpoints in place
- [ ] Premium file share provisioned at **3–5× expected output**
- [ ] Write-throughput test passed (> ~200 MB/s)
- [ ] Source scaled up; IOPS headroom confirmed

**During the dump**
- [ ] Directory format `-Fd` with `-j` tuned to observed throughput
- [ ] Compression level matched to the actual bottleneck (§8.2)
- [ ] Sharded orchestration + manifest if resumability is required (§8.3)
- [ ] Snapshot consistency decision made deliberately (§8.4)
- [ ] Source metrics watched — IOPS saturation means stop adding workers
- [ ] Output redirected to a log file

**Before the restore**
- [ ] Target scaled **up** for the operation
- [ ] `maintenance_work_mem`, `max_wal_size`, `autovacuum=off`, `synchronous_commit=off`
- [ ] Target database created
- [ ] Three-phase approach chosen for the largest jobs (§11.1)

**After the restore** 🔴 *none of these are optional*
- [ ] **`autovacuum` reverted to `on`**
- [ ] `synchronous_commit` and memory parameters reverted
- [ ] **`ANALYZE` run across the whole database**
- [ ] Row counts reconciled against the source
- [ ] No invalid indexes; sequences correct
- [ ] Application smoke test passed
- [ ] Target scaled back to steady state
- [ ] Worker VM deallocated; premium share deleted
- [ ] Dumps moved to Cool/Archive; lifecycle policy active

---

## 17. Reference

- `pg_dump` — https://www.postgresql.org/docs/current/app-pgdump.html
- `pg_restore` — https://www.postgresql.org/docs/current/app-pgrestore.html
- Backup and restore concepts (Azure) — https://learn.microsoft.com/en-us/azure/postgresql/backup-restore/concepts-backup-restore
- Azure Backup for PostgreSQL Flexible Server (LTR) — https://learn.microsoft.com/en-us/azure/backup/backup-azure-database-postgresql-flex-overview
- Migration service — https://learn.microsoft.com/en-us/azure/postgresql/migrate/migration-service/concepts-migration-service-postgresql
- Azure Files Premium — https://learn.microsoft.com/en-us/azure/storage/files/understanding-billing
- Azure NetApp Files performance — https://learn.microsoft.com/en-us/azure/azure-netapp-files/azure-netapp-files-performance-considerations
- AzCopy — https://learn.microsoft.com/en-us/azure/storage/common/storage-use-azcopy-v10
- Mount Azure Files on Windows — https://learn.microsoft.com/en-us/azure/storage/files/storage-how-to-use-files-windows
- `pgcopydb` — https://github.com/dimitri/pgcopydb
- Server parameters (Azure) — https://learn.microsoft.com/en-us/azure/postgresql/flexible-server/concepts-server-parameters
