# PGBench Explained

</br>

**pgbench**  is a benchmark tool first and a query runner second. By design, it suppresses most query result sets and focuses on TPS, latency, and transaction metrics. The PostgreSQL documentation explicitly describes pgbench as a transaction benchmark tool that repeatedly executes SQL and reports throughput and latency statistics. [postgresql.org]

</br>

## 1. The best reference

Official PostgreSQL pgbench documentation:
PostgreSQL pgbench Documentation [postgresql.org]
</br>
</br>

``` powershell
pgbench --help
```

</br>

and</br>

</br>
``` powershell
pgbench --version
```

</br>

## 2. Why you don't see query results

Consider this script:</br>
</br>

```sql
SELECT count(*)
FROM  sales.salesorderheader;
```

</br>If executed through:

```powershell
pgbench -f myscript.sql -c 1 -j 1 -T 10 adventureworks
```

You will not see the SELECT results.</br>
pgbench executes the query but discards the result set.</br>
Instead you'll get something like:</br>


```code
transaction type: myscript.sql
number of clients: 1
number of threads: 1
duration: 10 s
latency average = 12.3 ms
tps = 81.5
```

</br>

![PGBench doesn't show results](images/PGBench_01_NoResults.png)
</br>


</br>

## 3. Enable Transaction Logging

A very useful option is for PGBench to generate a session log file using the -l option:</br>
</br>

```PowerShell
pgbench -f workload.sql `
-c 50 `
-j 10 `
-T 300 `
-l `
adventureworks
```

</br>

The **-l** option generates .log files in the folder where PGBench is executed:</br>

</br>

![PGBench Log output](images/PGBench_02_SessionLogOutput.png)
</br>


Session Log contents are as follows:

| Column | Meaning |
|---|---|
|Client ID | Which client executed the transaction |
| Timestamp	| When transaction completed |
| Latency | Transaction duration |
| Status | Success/failure |
The exact format varies slightly by PostgreSQL version.

</br>

![PGBench output example](images/PGBench_03_SessionLogOutput.png)
</br>


## 4. PGBench Detailed Report

</br>

The **-r** option reports average latency per statement. This is one of the most useful options when tuning a workload. The official documentation describes custom script execution and reporting capabilities. [postgresql.org]</br>
</br>

```powershell
pgbench -f workload.sql `
-c 100 `
-j 20 `
-T 300 `
-r `
adventureworks`
```

</br>
</br>

![PGBench detailed report](images/PGBench_04_DetailedReport.png)
</br>

</br>
</br>

## 5. PGBench Verbose Mode

</br>
with Verbose mode you'll get Connection and Execution progress messages
</br>
</br>


```powershell
pgbench -v
or
pgbench --verbose
```

</br>
```Powershell
pgbench **-v** -f workload.sql -c 1 -T 10 adventureworks`
```

</br></br>

![PGBench verbose mode](images/PGBench_05_VerboseMode.png)
</br>
</br>
</br>

