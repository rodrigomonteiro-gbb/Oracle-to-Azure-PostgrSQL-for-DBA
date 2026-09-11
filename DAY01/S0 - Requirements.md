# Azure PostgreSQL Workshop Prerequisites</br>

</br>
</br>
</br>

## 1. Azure Subscription</br>

</br>

An active Azure subscription is required.

---
</br>

## 2. Azure Resource Group</br>

</br>
Create or use an existing Azure Resource Group to host all workshop resources.
</br>
</br>

### 2.1 go to portal.azure.com</br>

</br>
</br>

:::image type="content" source="images/Azure-Portal-Home-screen.png" alt-text="Azure Portal home screen":::
</br>
</br>

### 2.2 Search: Resource Group

</br>
</br>
Click on Resource-Group at the toolbar, or search for "resource group" at the search bar
</br>
</br>

:::image type="content" source="images/find-and-open-resourcegroups.png" alt-text="click on Resource Group":::
</br>
</br>

If you don't find the resource group for your activities, create a new one.
</br>
</br>

:::image type="content" source="images/create-new-resource-group.png" alt-text="Create New Resource Group":::
</br>
</br>

If you don't find the resource group for your activities, create a new one - provide:

- Resouce Group name
- Region

</br>
</br>

:::image type="content" source="images/new-resource-group-details.png" alt-text="input Resource Group details":::
</br>
</br>

scroll down to click **CREATE**

</br>
</br>

:::image type="content" source="images/review-create-resourcegroup.png" alt-text="CREATE Resource Group":::
</br>
</br>

Once the Resrouce Group is created you'll get a notification at top right

</br>
</br>

:::image type="content" source="images/notification-resourcegroup-created.png" alt-text="notification: Resource Group created":::
</br>
</br>

click on **Go to resource group** then close the notification panel

</br>
</br>

## 3. Azure Database for PostgreSQL Flexible Server

</br>
Create now an Azure Database for PostGreSQL Flexible Server using the following configuration

| Setting | Value |
| ---------- | -------- |
| Service Tier | General Purpose |
| Compute SKU | D4ads_v5 |
| vCPUs | 4 |
| Memory | 16 GiB RAM |
| Storage | 128 GiB |
| Disk Performance | P10 (500 IOPS) |
| Zonal Resiliency | Disabled |
| Authentication | PostgreSQL and Microsoft Entra authentication |
| **admin account** | **postgres** |

</br>
</br>

### 3.1 Create new Azure PostGreSQL Flexible Server in the resource group

</br>
</br>

Click on **+ CREATE** at the toolbar
</br>
</br>

:::image type="content" source="images/create-new-resource.png" alt-text="click on + CREATE":::
</br>
</br>

Type **Flexible Server** at the textbox
</br>
</br>

:::image type="content" source="images/search-for-flexible-server.png" alt-text="Type Flexible Server":::
</br>
</br>
select the option **Azure Database for PostgreSQL Flexible Server**
</br>
</br>

### 3.2 Azure Database for PostGreSQL Flexible Server tile

</br>
</br>

#### 3.2.1 Click on **Azure Database for PostGreSQL Flexible Server** tile to start the creation process via wizard
</br>
</br>

:::image type="content" source="images/create-new-flexserver-tile.png" alt-text="click on tile":::
</br>
</br>

#### 3.2.2 Click on **Create**

</br>
</br>

:::image type="content" source="images/create-new-flexserver-button.png" alt-text="click on Create button":::
</br>
</br>
the following sections will drive your navigation to create a new PostgreSQL Flexible server
</br>
</br>

##### 3.2.2.A **Basic Tab**

</br>
</br>
1 - select the Resource Group where Azure PostgreSQL Flexible server will be placed</br>
2 - enter servername</br>
3 - select the region for the server. Note: it does not need to be on same region as the Resource Group</br>
4 - select PostgreSQL version</br>
5 - workload. For this training you can select DEV/TEST as it cost less. for Production always use PRODUCTION</br>
6 - verify the compute selected for this instance of PostgreSQL Flexible server. Click on **configure server** to modify it</br>
7 - Zone Resiliency. We will demonstrate failover/failback during this class, leave it as Enabled</br>
8 - Authentication Mode.</br>
9 - Set Admin with Entra -> only available if authentication is selected with ENTRA</br>
10 - Administrator loging. A valid username. Recommended to be 'postgres' </br>
11 - Password</br>
</br>
Before going to the next section, we will do:</br>

&emsp;**configure server** to review or set the service tier and hardware for this instance of PostgreSQL Flexible.</br>
&emsp;&emsp;Click on [CONFIGURE SERVER](S0%20-%20Requirements%20-%20Compute%20Storage.MD). this will take you to 3.2.2.B</br>
&emsp;**set admin** in case you are using ENTRA. Click on [Set Admin](S0%20-%20Requirements%20-%20set%20ENTRA.MD), this will take you to 3.2.2.C</br>
</br>
</br>

12 - click **Next** to go to the next tab: networking</br>
</br>
</br>

#### 3.2.2.B. **Networking Tab**

</br>
settings:</br>

1 - Connectivity Method: select whether the connectivity will be available to **PUBLIC ACCESS** or **PRIVATE ACCESS**</br>. For this workshop select **Public Access**
2 - Public Access: check the checkbox for  **Allow Public access to this resource**</br>
3 - Firewall Rules: check the checkbox for  **Allow public access from any Azure Service within azure to this server**</br>
3.1 add client IP for the jumpbox:</br>
&emsp;Add current client IP address (x.x.x.x)</br>
&emsp;or</br>
&emsp;**Add current client IP range (example 0.0.0.0 to)**</br>
</br>
</br>

4 - click **Next** to go to the next tab: Security</br>
</br>
:::image type="content" source="images/new-flexserver-2-Networking-Tab.png" alt-text="Networking Tab":::
</br>
</br>

#### 3.2.2.C. **Security Tab**

</br>
settings:</br>

1 - Data Encryption Key: leave as **Service-managed key**</br>
2 - click **Next** to go to the next tab: Tags</br>
</br>

:::image type="content" source="images/new-flexserver-3-Security-Tab.png" alt-text="Security Tab":::
</br>
</br>

#### 3.2.2.D. **Tags Tab**
>
</br>
Settings:</br>
for the sake of this workshop you can leave as is</br>
for an actual production environment, we recommend that you use tags to make management and finding resources, or billing easier to manage. For instance you can use tags to:</br>

- Cost Center</br>
- Application Name</br>
- Location/Building</br>
- Manager/Responsible</br>

</br>
</br>

1 - click **Next** to go to the next tab: **Review+Create**</br>
</br>

:::image type="content" source="images/new-flexserver-4-Tags-Tab.png" alt-text="Tags Tab":::
</br>
</br>

#### 3.2.2.E. **Review + Create**

</br>
</br>

This tab shows the summary of the new Azure Database for PostgreSQL flexible server that will be created.</br>
Review all settings before clicking on **Create**.</br>
Click on **Create** to go to the deployment process.</br>
</br>
</br>

:::image type="content" source="images/new-flexserver-5-Review-Create.png" alt-text="Review":::
</br>
</br>

### 3.2.3. Deployment in progress

</br>
</br>
When Azure receives the request to create the resource, it displays a dialog showing the creation progress as per the image below.</br>

:::image type="content" source="images/new-flexserver-6-Deployment.png" alt-text="Deployment":::
</br>
</br>

### 3.2.4. Deployment Complete

</br>
</br>

When the deployment is done, the screen shows the new status with **Your deployment is complete**</br>
1 - Click on **Go to Resource** so Azure will navigate to the newly created **Azure Database for PostgreSQL Flexible Server**</br>

:::image type="content" source="images/new-flexserver-7-Deployment-Complete.png" alt-text="Deployment Complete":::
</br>
</br>

**3.3. Post Deployment**
</br>
</br>

:::image type="content" source="images/new-flexserver-8-post-Deployment.png" alt-text="post Deployment":::
</br>
</br>


## 4. Azure Virtual Machine

</br>
Provision a Windows VM that will be used to access the PostgreSQL database and run the workshop training and labs.

</br>

### 4.1 VM Requirements

</br>

| Setting | Value |
| ---------- | -------- |
| Operating System | Windows Server or Windows 11 |
| VM Size | Standard_D4ads_v7 |
| vCPUs | 4 |
| Memory | 16 GB |

### 4.2 Required Software

</br>

#### 4.2.1. PostgreSQL Workload Generator

</br>
Download the PostgreSQL Workload Generator:</br>
</br>

- [PostGreSQL Workload Generator - based on psql & pgbench][https://github.com/sammesel/PostGreSQL_Workload_Generator]</br>


- Click [here](S0%20-%20Requirements%20-%20PostgreSQL%20Workload%20Generator.MD) to learn about the PostgreSQL Workload Generator tool
</br>
</br>

#### 4.2.2. Development Tools

Install the following tools on the VM:</br>
</br>
&nbsp; - PGAdmin4, psql, pgbench, pgrestore</br>
&nbsp; - Visual Studio Code (VS Code)</br>
&nbsp; - PostGreSQL Extension for VSCode</br>
&nbsp; - MarkDown Extension for VSCode</br>
&nbsp; - DBeaver</br>
&nbsp; - Toad</br>
&nbsp; - Any other PostgreSQL-compatible client tool for database administration and querying</br>
</br>
</br>
