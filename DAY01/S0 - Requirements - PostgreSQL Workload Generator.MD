# PostGreSQL Workload Generator

</br>
</br>

## Tool Definition

</br>

PostGreSQL_Workload_Generator is a **Powershell 7**  script that uses a GUI to allow the user to issue queries targetting a PostgreSQL Server. It uses a combination of resources to generate workload against an AdventureWorks database. The resources are:</br>
</br>

 A series of **SQL scripts**, each one used to target a specific area of PostGreSQL Server. All the necessary demo scripts are in the \SQL folder.</li></br>

 **PSQL** is part of the [PGADMIN4 utilities](https://www.enterprisedb.com/downloads/postgres-postgresql-downloads) is used to connect to SQL Server and execute one SQL script.</li></br>
 To install **PGBench** follow instructions on [](Tools_PGBench_Installation.MD)

 **PGBENCH** is available at https://www.enterprisedb.com/downloads/postgres-postgresql-downloads. It is used to connect to PostGreSQL Server and execute the SQL scripts with multiple sessions in parallel. </li>
</ul>

</br>

### to verify you have PowerShell 7

</br>

### 1. Check your current version</br>

1.1 execute: $PSVersionTable.PSVersion</br>
1.2 if you see 5.1.x you are running windows powershell 5.1</br>

### 2. Install PowerShell 7</br>

2.1. In an elevated PowerShell or Command Prompt window: </br>
winget install Microsoft.PowerShell</br>
2.2. or </br>
winget install --id Microsoft.PowerShell -e</br>

### 3. Start PowerShell 7 </br>

After installation, close and reopen your terminal, then run: </br>
pwsh </br>
PowerShell 7 installs side-by-side with Windows PowerShell 5.1 and is launched using pwsh.exe. </br>

### 4. Verify </br>

4.1. $PSVersionTable.PSVersion</br>
4.2. You should now see a version beginning with 7.x.</br>

### 5. (Recommended) Make PowerShell 7 the default in Windows Terminal</br>

Open Windows Terminal Settings (Ctrl+,)</br>
Go to Startup</br>
Change Default profile from Windows PowerShell to PowerShell (the PowerShell 7 profile)</br>
Save and restart Windows Terminal.</br>
Upgrade an existing PowerShell 7 installation</br>
If you already have PowerShell 7 and want the latest release:</br>
winget upgrade Microsoft.PowerShell
</br>
</br>

## GUI Description

</br>
The Graphical User Interface is shown below.</br>
You need to propulate the following fields to allow a connection to PostgreSQL:</br>
<ul>
<li>1 - Hostname: enter the complete server name.</li>
<li>2 - port. Usually **5432**. When using PGBouncer change it to **6432**</li>
<li>3 - Database Name: The name given to the AdventureWorks database.</li>
<li>4 - Username: a valid login to the database, with read/write permissions.</li>
<li>5 - Password: the corresponding password to the username entered above.</li>
<li>6 - <a href="S0%20-%20Requirements%20-%20WorkloadDefinitions.MD">Workload</a>: a list of existing workload simulations.</li>
<li>7 - Clients: the number of clientes PGBENCH will execute in parallel with the selected workload.</li>
<li>8 - Threads: the number of Threads PGBENCH will lauch.</li>
<li>9 - Limit execution to
<ul>
<li>a) nothing. PGBench will execute until the user closes the execution screen</li>
<li>b) Transactions/Client. Number of transactions per client that PGBench will execute. it will close the execution screen after it</li>
<li>c) Time (ss). Number of seconds PGBench will stay executing the query. it will close the execution screen after it</li>
</ul>
<li>PGBench Options:</li>
<li>10- Show PGBench Progress every xx seconds:</li>
<li>11- Capture PGBench log</li>
<li>12- Reset PGStats before executing the query</li>
<li>13- Confirm the execution by clicking OK, or end the script by clicking CANCEL</li>
</ul>
</br>
> :Memo: **Tip:** The value for the password is masked.
</br>

![GUI Image](images/workload-generator-01-screen-layout.png)

>The .SQL scripts used to generate workload are based on the **AdventureWorks** sample database. Please read the [pre-requisites](prerequisites.md) to find how to download the sample.
</br>
</br>
</br>

## Executing the tool

The image below illustrates a connection to an Azure Database for PostgreSQL Flexible Server, using default Port 5432, and pointing to the  AdventureWorks database.</br>
</br>
For this simmulation, we will validate the tool can connect to that instance, thus the selected workload is "**0 Connection Test**"</br>
</br>
</br>

![Connection Test](images/workload-generator-02-connection_test.png)
</br>
Notice the input used for this sample execution:</br>
<ul>
<li>Hostname: an Azure Database for PostgreSQL servername was provided.</li>
<li>port: 5432</li>
<li>Workload: **Connection Test is selected**.</li>
<li>Clients: 20.</li>
<li>Limit execution to 60 seconds</li>
<li>PGBench Options:</li>
<li>Show PGBench Progress every 10 seconds:</li>
<li>Capture PGBench log</li>
<li>Reset PGStats before executing the query</li>
</ul>
</br>

* the following screenshots contain the PGBENCH execution at launch, 10 seconds, 20 seconds, and 60 seconds.

![PGBench at launch](images/workload-execution-pgbench-00-seconds.png)
</br>
</br>
![PGBench at 10 seconds](images/workload-execution-pgbench-10-seconds.png)
</br>
</br>
![PGBench at 20 seconds](images//workload-execution-pgbench-20-seconds.png)
</br>
</br>
![PGBench at 60 seconds](images//workload-execution-pgbench-60-seconds.png)
</br>
</br>
now we used PGADMIN to connect to the same server, and visualized the activity. The screenshots below show:</br>

* Activity Dashboard
* State Dashboard
* System View query execution

![Activity Dashboard](images/workload-analysis-pgadmin-dashboard-activity.png)
</br>
</br>
![State Dashboard](images/workload-analysis-pgadmin-dashboard-state.png)
</br>
</br>
![System View query](images/workload-analysis-pgadmin-DBA_Query.png)
</br>
</br>
