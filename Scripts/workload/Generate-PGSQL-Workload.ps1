### for Azure-SQL-MI 
### connection string is: azuresql-mi-gp-001.public.d6aea0eaad39.database.windows.net,3342
### connection string is: sqlsrvhyperscale-001.database.windows.net

### PAY ATTENTION TO THE .PUBLIC. 

## executables
$PsqlExe = "C:\Program Files\pgAdmin 4\runtime\psql.exe"
$PgBenchExe = "pgbench.exe"
$env:PGSSLMODE = "require"

# Set to $true to capture pgbench stdout, stderr, command details, and exit status.
$CapturePGBenchDiagnostics = $false

#srv-workshop-pto-pgsql.postgres.database.azure.com
#postgres
#P0stgr3sTcpcep.0123456

$scriptDir = $PSScriptRoot
$ResultsRoot = Join-Path $scriptDir 'Results'
add-Type -AssemblyName System.Windows.Forms

# UI form control and properties
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Generate PostGreSQL Workload'
$form.Size = New-Object System.Drawing.Size(1050,940) ##1050,1150
$form.StartPosition = 'Manual' #'CenterScreen'
    <#
        CenterParent	        4	The form is centered within the bounds of its parent form.
        CenterScreen	        1	The form is centered on the current display, and has the dimensions specified in the form's size.
        Manual       	        0	The position of the form is determined by the Location property.
        WindowsDefaultBounds	3	The form is positioned at the Windows default location and has the bounds determined by Windows default.
        WindowsDefaultLocation	2	The form is positioned at the Windows default location and has the dimensions specified in the form's size.
        #>

$labelInstance = New-Object System.Windows.Forms.Label
$labelInstance.top = 10
$labelInstance.left = 30
$labelInstance.width = 240
$labelInstance.height = 30
$labelInstance.Text = 'hostname:'
$labelInstance.Font = New-Object System.Drawing.Font("Lucida Console",12,[System.Drawing.FontStyle]::Regular)
$form.Controls.Add($labelInstance) 

$textBoxInstance = New-Object System.Windows.Forms.TextBox
$textBoxInstance.top= 10
$textBoxInstance.left = 290
$textBoxInstance.width = 720
$textBoxInstance.height = 60
$textBoxInstance.Font = New-Object System.Drawing.Font("Lucida Console",18,[System.Drawing.FontStyle]::Regular)
$form.Controls.Add($textBoxInstance)

$labelPort = New-Object System.Windows.Forms.Label
$labelPort.top = 50
$labelPort.left = 30
$labelPort.width = 240
$labelPort.height = 30
$labelPort.Text = 'port:'
$labelPort.Font = New-Object System.Drawing.Font("Lucida Console",12,[System.Drawing.FontStyle]::Regular)
$form.Controls.Add($labelPort)

$textBoxPort = New-Object System.Windows.Forms.TextBox
$textBoxPort.top = 50
$textBoxPort.left = 290
$textBoxPort.width = 75
$textBoxPort.height = 60
$textBoxPort.text = "5432"
$textBoxPort.Font = New-Object System.Drawing.Font("Lucida Console",18,[System.Drawing.FontStyle]::Regular)
$textBoxPort.enabled = $true
$form.Controls.Add($textBoxPort)

$labelDatabase = New-Object System.Windows.Forms.Label
$labelDatabase.top = 90
$labelDatabase.left = 30
$labelDatabase.width = 240
$labelDatabase.height = 30
$labelDatabase.Text = 'Database:'
$labelDatabase.Font = New-Object System.Drawing.Font("Lucida Console",12,[System.Drawing.FontStyle]::Regular)
$form.Controls.Add($labelDatabase)

$textBoxDatabase = New-Object System.Windows.Forms.TextBox
$textBoxDatabase.top= 90
$textBoxDatabase.left = 290
$textBoxDatabase.width = 600
$textBoxDatabase.height = 60
$textBoxDatabase.Font = New-Object System.Drawing.Font("Lucida Console",18,[System.Drawing.FontStyle]::Regular)
$form.Controls.Add($textBoxDatabase)

## add radio button to gather security: SQL Authentication | Windows Integrated Security
# Create a group that will contain your radio buttons
$SecurityGroupBox = New-Object System.Windows.Forms.GroupBox
$SecurityGroupBox.top = 130
$SecurityGroupBox.left = 290
$SecurityGroupBox.width = 600
$SecurityGroupBox.height = 60
$SecurityGroupBox.text = "Authentication"
$SecurityGroupBox.Font = New-Object System.Drawing.Font("Lucida Console",12,[System.Drawing.FontStyle]::Regular)

# Create the collection of radio buttons
$SQLAuthRadioButton = New-Object System.Windows.Forms.RadioButton
$SQLAuthRadioButton.Top = 20
$SQLAuthRadioButton.Left = 20
$SQLAuthRadioButton.Width = 240
$SQLAuthRadioButton.height = 30
$SQLAuthRadioButton.Checked = $true 
$SQLAuthRadioButton.Text = "PGSQL" ## PGSQL Authentication
$SQLAuthRadioButton.Font = New-Object System.Drawing.Font("Lucida Console",12,[System.Drawing.FontStyle]::Regular)

$WindowsRadioButton = New-Object System.Windows.Forms.RadioButton
$WindowsRadioButton.top = 20
$WindowsRadioButton.left = 300
$WindowsRadioButton.width = 240
$WindowsRadioButton.height = 30
$WindowsRadioButton.Checked = $false
$WindowsRadioButton.Text = "ENTRA" ## Windows Integrated
$WindowsRadioButton.enabled = $false
$WindowsRadioButton.Font = New-Object System.Drawing.Font("Lucida Console",12,[System.Drawing.FontStyle]::Regular)

# Add all the GroupBox controls on one line
$SecurityGroupBox.Controls.AddRange(@($SQLAuthRadioButton,$WindowsRadioButton))
$form.Controls.Add($SecurityGroupBox)

$labelUsername = New-Object System.Windows.Forms.Label
$labelUsername.top = 200 
$labelUsername.left = 30
$labelUsername.width = 240
$labelUsername.height = 30
$labelUsername.Text = 'Username:'
$labelUsername.Font = New-Object System.Drawing.Font("Lucida Console",12,[System.Drawing.FontStyle]::Regular)
$form.Controls.Add($labelUsername)

$textBoxUsername = New-Object System.Windows.Forms.TextBox
$textBoxUsername.top= 200 
$textBoxUsername.left = 290
$textBoxUsername.width = 600
$textBoxUsername.height = 60
$textBoxUsername.Font = New-Object System.Drawing.Font("Lucida Console",18,[System.Drawing.FontStyle]::Regular)
$form.Controls.Add($textBoxUsername)

$labelPassword = New-Object System.Windows.Forms.Label
$labelPassword.top = 240
$labelPassword.left = 30
$labelPassword.width = 240
$labelPassword.height = 30
$labelPassword.Text = 'Password:'
$labelPassword.Font = New-Object System.Drawing.Font("Lucida Console",12,[System.Drawing.FontStyle]::Regular)
$form.Controls.Add($labelPassword)

$textboxpassword = New-Object Windows.Forms.MaskedTextBox
$textboxpassword.PasswordChar = '*'
$textboxpassword.Top  = 240 
$textboxpassword.Left = 290
$textboxpassword.Width  = 600
$textboxpassword.Height = 30
$textboxpassword.text = "P0stgr3sTcpcep.0123456"
$textboxpassword.Font = New-Object System.Drawing.Font("Lucida Console",18,[System.Drawing.FontStyle]::Regular)
$form.Controls.Add($textboxpassword)

$labelWorkload = New-Object System.Windows.Forms.Label
$labelWorkload.top = 280 
$labelWorkload.left = 30
$labelWorkload.width = 240
$labelWorkload.height = 30
$labelWorkload.Text = 'Workload:'
$labelWorkload.Font = New-Object System.Drawing.Font("Lucida Console",12,[System.Drawing.FontStyle]::Regular)
$form.Controls.Add($labelWorkload)

$listBox = New-Object System.Windows.Forms.ListBox
$listBox.top= 280 
$listBox.left = 290
$listBox.width = 600
$listBox.Height = 270 ##330
[void] $listBox.Items.Add('0 Connection Test')
[void] $listBox.Items.Add('1 Compile Workload')
[void] $listBox.Items.Add('2 CPU')
[void] $listBox.Items.Add('3 SQL CPU')
[void] $listBox.Items.Add('4 Blockers')
[void] $listBox.Items.Add('5 Sargability queries')
[void] $listBox.Items.Add('6 Execution Plan')
[void] $listBox.Items.Add('7 Cursors')
[void] $listBox.Items.Add('8 Errors')
[void] $listBox.Items.Add('9 TempDB')
#[void] $listBox.Items.Add('A CPU Runner')
#[void] $listBox.Items.Add('B Heavy Queries')
#[void] $listBox.Items.Add('C Dynamic Workload')
#[void] $listBox.Items.Add('D Memory Grant')
#[void] $listBox.Items.Add('E Keyset cursors')
#[void] $listBox.Items.Add('F Update cursors')
#[void] $listBox.Items.Add('G read only cursors')
#[void] $listBox.Items.Add('H for Insert rows')
#[void] $listBox.Items.Add('I light workload')
#[void] $listBox.Items.Add('J TempDB small/med/large #tables')
#[void] $listBox.Items.Add('K WriteLog med/large tables')
#[void] $listBox.Items.Add('L Deadlocks')
#[void] $listBox.Items.Add('M Attentions')
#[void] $listBox.Items.Add('N Warehousing via Stored Procedure')
#[void] $listBox.Items.Add('O Warehousing via Adhoc Queries')
$ListBox.Font = New-Object System.Drawing.Font("Lucida Console",18,[System.Drawing.FontStyle]::Regular)
$form.Controls.Add($listBox)

$labelClients = New-Object System.Windows.Forms.Label
$labelClients.top = 560
$labelClients.left = 30
$labelClients.width = 240
$labelClients.height = 30
$labelClients.Text = 'Clients:'
$labelClients.Font = New-Object System.Drawing.Font("Lucida Console",12,[System.Drawing.FontStyle]::Regular)
$form.Controls.Add($labelClients)

$textboxClients = New-Object Windows.Forms.TextBox
$textboxClients.Top  = 560 
$textboxClients.left = 290
$textboxClients.Width  = 60
$textboxClients.Height = 900
$textboxClients.Font = New-Object System.Drawing.Font("Lucida Console",18,[System.Drawing.FontStyle]::Regular)
$form.Controls.Add($textboxClients)

# threads
$labelThreads = New-Object System.Windows.Forms.Label
$labelThreads.top = 600 
$labelThreads.left = 30
$labelThreads.width = 240
$labelThreads.height = 60
$labelThreads.Text = 'Threads:'
$labelThreads.Font = New-Object System.Drawing.Font("Lucida Console",12,[System.Drawing.FontStyle]::Regular)
$form.Controls.Add($labelThreads)

$textboxThreads = New-Object Windows.Forms.TextBox
$textboxThreads.Top  = 600 
$textboxThreads.left = 290
$textboxThreads.Width  = 60
$textboxThreads.Height = 30
$textboxThreads.Font = New-Object System.Drawing.Font("Lucida Console",18,[System.Drawing.FontStyle]::Regular)
$form.Controls.Add($textboxThreads)

# Create a group to contain your radio buttons for Execution Control
$ExecutionGroupBox = New-Object System.Windows.Forms.GroupBox
$ExecutionGroupBox.top = 660
$ExecutionGroupBox.left = 30
$ExecutionGroupBox.width = 340
$ExecutionGroupBox.height = 120
$ExecutionGroupBox.text = "Limit Execution to:"
$ExecutionGroupBox.Font = New-Object System.Drawing.Font("Lucida Console",12,[System.Drawing.FontStyle]::Regular)

# Create the collection of radio buttons
$ExecNothingRadioButton = New-Object System.Windows.Forms.RadioButton
$ExecNothingRadioButton.Top = 20
$ExecNothingRadioButton.Left = 20
$ExecNothingRadioButton.Width = 100
$ExecNothingRadioButton.height = 30
$ExecNothingRadioButton.Checked = $false
$ExecNothingRadioButton.Text = "Nothing" 
$ExecNothingRadioButton.Font = New-Object System.Drawing.Font("Lucida Console",12,[System.Drawing.FontStyle]::Regular)
$ExecutionGroupBox.Controls.Add($ExecNothingRadioButton)

$ExecTransactionsRadioButton = New-Object System.Windows.Forms.RadioButton
$ExecTransactionsRadioButton.Top = 50
$ExecTransactionsRadioButton.Left = 20
$ExecTransactionsRadioButton.Width = 220
$ExecTransactionsRadioButton.height = 30
$ExecTransactionsRadioButton.Checked = $true 
$ExecTransactionsRadioButton.Text = "Transactions/Client" 
$ExecTransactionsRadioButton.Font = New-Object System.Drawing.Font("Lucida Console",12,[System.Drawing.FontStyle]::Regular)
$ExecutionGroupBox.Controls.Add($ExecTransactionsRadioButton)

$textBoxExecTransactions = New-Object System.Windows.Forms.TextBox
$textBoxExecTransactions.top = 50
$textBoxExecTransactions.left = 250
$textBoxExecTransactions.width = 75
$textBoxExecTransactions.height = 60
$textBoxExecTransactions.Font = New-Object System.Drawing.Font("Lucida Console",18,[System.Drawing.FontStyle]::Regular)
$textBoxExecTransactions.enabled = $true
$ExecutionGroupBox.Controls.Add($textBoxExecTransactions)

$ExecTimeRadioButton = New-Object System.Windows.Forms.RadioButton
$ExecTimeRadioButton.Top = 80
$ExecTimeRadioButton.Left = 20
$ExecTimeRadioButton.Width = 150
$ExecTimeRadioButton.height = 30
$ExecTimeRadioButton.Checked = $false 
$ExecTimeRadioButton.Text = "Time (ss)" ## 
$ExecTimeRadioButton.Font = New-Object System.Drawing.Font("Lucida Console",12,[System.Drawing.FontStyle]::Regular)
$ExecutionGroupBox.Controls.Add($ExecTimeRadioButton)

$textBoxExecExecTime = New-Object System.Windows.Forms.TextBox
$textBoxExecExecTime.top = 80
$textBoxExecExecTime.left = 250
$textBoxExecExecTime.width = 75
$textBoxExecExecTime.height = 60
$textBoxExecExecTime.Font = New-Object System.Drawing.Font("Lucida Console",18,[System.Drawing.FontStyle]::Regular)
$textBoxExecExecTime.enabled = $true
$ExecutionGroupBox.Controls.Add($textBoxExecExecTime)

# Add event handlers for radio buttons to control textbox states
$ExecNothingRadioButton.Add_CheckedChanged({
    if ($ExecNothingRadioButton.Checked) {
        $textBoxExecTransactions.enabled = $false
        $textBoxExecExecTime.enabled = $false
    }
})

$ExecTransactionsRadioButton.Add_CheckedChanged({
    if ($ExecTransactionsRadioButton.Checked) {
        $textBoxExecTransactions.enabled = $true
        $textBoxExecExecTime.enabled = $false
    }
})

$ExecTimeRadioButton.Add_CheckedChanged({
    if ($ExecTimeRadioButton.Checked) {
        $textBoxExecTransactions.enabled = $false
        $textBoxExecExecTime.enabled = $true
    }
})

# Set initial state based on default selection
if ($ExecTransactionsRadioButton.Checked) {
    $textBoxExecTransactions.enabled = $true
    $textBoxExecExecTime.enabled = $false
}

$form.Controls.Add($ExecutionGroupBox)

# Create a group to contain your radio buttons for Execution Control
$PGBenchOptionsGroupBox = New-Object System.Windows.Forms.GroupBox
$PGBenchOptionsGroupBox.top = 560 
$PGBenchOptionsGroupBox.left = 470
$PGBenchOptionsGroupBox.width = 420
$PGBenchOptionsGroupBox.height = 205
$PGBenchOptionsGroupBox.text = "PGBench options"
$PGBenchOptionsGroupBox.Font = New-Object System.Drawing.Font("Lucida Console",12,[System.Drawing.FontStyle]::Regular)

$chkbox_ShowPGBenchProgress = New-Object System.Windows.Forms.CheckBox
$chkbox_ShowPGBenchProgress.text = "Show PGBench progress (ss):"
$chkbox_ShowPGBenchProgress.Top  = 20 
$chkbox_ShowPGBenchProgress.Left = 20 
$chkbox_ShowPGBenchProgress.Width  = 300
$chkbox_ShowPGBenchProgress.Height = 40
$chkbox_ShowPGBenchProgress.checked = $true
$chkbox_ShowPGBenchProgress.Font = New-Object System.Drawing.Font("Lucida Console",12,[System.Drawing.FontStyle]::Regular)
$PGBenchOptionsGroupBox.Controls.Add($chkbox_ShowPGBenchProgress)

$textboxPGBenchProgress = New-Object System.Windows.Forms.TextBox
$textboxPGBenchProgress.Top  = 30 
$textboxPGBenchProgress.left = 320
$textboxPGBenchProgress.Width  = 45
$textboxPGBenchProgress.Height = 40
$textboxPGBenchProgress.text = "10"
$textboxPGBenchProgress.Font = New-Object System.Drawing.Font("Lucida Console",18,[System.Drawing.FontStyle]::Regular)
$textboxPGBenchProgress.enabled = $true
$PGBenchOptionsGroupBox.Controls.Add($textboxPGBenchProgress)

$chkbox_CapturePGBenchLog = New-Object System.Windows.Forms.CheckBox
$chkbox_CapturePGBenchLog.text = "Capture PGBench Log"
$chkbox_CapturePGBenchLog.Top  = 60
$chkbox_CapturePGBenchLog.Left = 20
$chkbox_CapturePGBenchLog.Width  = 300
$chkbox_CapturePGBenchLog.Height = 40
$chkbox_CapturePGBenchLog.checked = -1
$chkbox_CapturePGBenchLog.Font = New-Object System.Drawing.Font("Lucida Console",12,[System.Drawing.FontStyle]::Regular)
$PGBenchOptionsGroupBox.Controls.Add($chkbox_CapturePGBenchLog)

## PG STATS checkboxes
$chkbox_Reset_PG_Stats_beforeRun = New-Object System.Windows.Forms.CheckBox
$chkbox_Reset_PG_Stats_beforeRun.text = "Reset PGSTATS before run"
$chkbox_Reset_PG_Stats_beforeRun.Top  = 100
$chkbox_Reset_PG_Stats_beforeRun.Left = 20
$chkbox_Reset_PG_Stats_beforeRun.Width  = 270
$chkbox_Reset_PG_Stats_beforeRun.Height = 40
$chkbox_Reset_PG_Stats_beforeRun.checked = 0
$chkbox_Reset_PG_Stats_beforeRun.Font = New-Object System.Drawing.Font("Lucida Console",12,[System.Drawing.FontStyle]::Regular)
$PGBenchOptionsGroupBox.Controls.Add($chkbox_Reset_PG_Stats_beforeRun)

$chkbox_Show_PG_Stats_AfterRun = New-Object System.Windows.Forms.CheckBox
$chkbox_Show_PG_Stats_AfterRun.text = "Show PGSTATS after run"
$chkbox_Show_PG_Stats_AfterRun.Top  = 140
$chkbox_Show_PG_Stats_AfterRun.Left = 20
$chkbox_Show_PG_Stats_AfterRun.Width  = 270
$chkbox_Show_PG_Stats_AfterRun.Height = 60
$chkbox_Show_PG_Stats_AfterRun.checked = 0
$chkbox_Show_PG_Stats_AfterRun.Font = New-Object System.Drawing.Font("Lucida Console",12,[System.Drawing.FontStyle]::Regular)
$chkbox_Show_PG_Stats_AfterRun.Visible  = 0

$labelTracking = New-Object System.Windows.Forms.Label
$labelTracking.Text = "Tracking:"
$labelTracking.Top = 155
$labelTracking.Left = 20
$labelTracking.Width = 120
$labelTracking.Height = 30
$labelTracking.Enabled = $false
$labelTracking.Font = New-Object System.Drawing.Font("Lucida Console",12,[System.Drawing.FontStyle]::Regular)
$PGBenchOptionsGroupBox.Controls.Add($labelTracking)

$EnableTrackingRadioButton = New-Object System.Windows.Forms.RadioButton
$EnableTrackingRadioButton.Text = "Enable"
$EnableTrackingRadioButton.Top = 150
$EnableTrackingRadioButton.Left = 145
$EnableTrackingRadioButton.Width = 115
$EnableTrackingRadioButton.Height = 40
$EnableTrackingRadioButton.Checked = $true
$EnableTrackingRadioButton.Enabled = $false
$EnableTrackingRadioButton.Font = New-Object System.Drawing.Font("Lucida Console",12,[System.Drawing.FontStyle]::Regular)
$PGBenchOptionsGroupBox.Controls.Add($EnableTrackingRadioButton)

$DisableTrackingRadioButton = New-Object System.Windows.Forms.RadioButton
$DisableTrackingRadioButton.Text = "Disable"
$DisableTrackingRadioButton.Top = 150
$DisableTrackingRadioButton.Left = 270
$DisableTrackingRadioButton.Width = 125
$DisableTrackingRadioButton.Height = 40
$DisableTrackingRadioButton.Checked = $false
$DisableTrackingRadioButton.Enabled = $false
$DisableTrackingRadioButton.Font = New-Object System.Drawing.Font("Lucida Console",12,[System.Drawing.FontStyle]::Regular)
$PGBenchOptionsGroupBox.Controls.Add($DisableTrackingRadioButton)

# Add all the GroupBox controls on one line
$form.Controls.Add($PGBenchOptionsGroupBox)
$form.Font = New-Object System.Drawing.Font("Lucida Console",14,[System.Drawing.FontStyle]::Regular)

$okButton = New-Object System.Windows.Forms.Button
$okButton.Top= 810
$okButton.Left= 470
$okButton.Width= 210
$okButton.Height= 60
$okButton.Text = 'OK'
$okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
$okButton.Font = New-Object System.Drawing.Font("Lucida Console",18,[System.Drawing.FontStyle]::Regular)
$form.AcceptButton = $okButton
$form.Controls.Add($okButton)

$cancelButton = New-Object System.Windows.Forms.Button
$cancelButton.Top= 810
$cancelButton.Left= 680
$cancelButton.Width= 210
$cancelButton.Height= 60
$cancelButton.Text = 'Cancel'
$cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
$cancelButton.Font = New-Object System.Drawing.Font("Lucida Console",18,[System.Drawing.FontStyle]::Regular)
$form.CancelButton = $cancelButton
$form.Controls.Add($cancelButton)


# read entries from last-execution if file exists
$lastexecpath = Join-Path $scriptDir 'exec_PGBENCH.TXT'
if (Test-Path -LiteralPath $lastexecpath) {
    $content = Get-Content -Path $lastexecpath
    $textBoxInstance.text = $content[0]
    $textBoxDatabase.text = $content[1]
    $textBoxUsername.text = $content[2]
    #
    # password is not saved in file
    #$textBoxPassword.text = $content[3]
    #
    $textboxClients.text = $content[3]
    $textboxThreads.text = $content[4]
}

function Get-Argument_PGBench
    {
        $param_list = $args[0]
            $p_server = $param_list[0]
            $p_port = $param_list[1]
            $p_user = $param_list[2]
            $p_database = $param_list[3]
            $p_script = $param_list[4]
            $p_clients = $param_list[5]
            $p_Threads = $param_list[6]
            $p_limit_Type = $param_list[7]
            $p_limit_Amount = $param_list[8]
            $p_output_folder = $param_list[9]
            $p_ShowPGBenchProgress = $param_list[10]
            $p_ShowPGBenchProgressInterval = $param_list[11]
            $p_CapturePGBenchLog = $param_list[12]
    
        $value=''
        $value+=' --no-vacuum '
        $value+=' --host="' + $p_server + '" '
        $value+=' --port=' + $p_port 
        $value+=' --username="' + $p_user + '" '
        $value+=' --dbname="' + $p_database + '" '
        $value+=' --file="' + $p_script + '" '
        $value+=' --client=' + $p_clients 
        $value+=' --jobs=' + $p_Threads
        if ($p_limit_Type -eq " ") {
            $value+='' 
        } else {
            $value+= ' --' + $p_limit_Type + '=' + $p_limit_Amount
        }
        if ($p_ShowPGBenchProgress -eq "Y") {
            $value+= ' --progress=' + $p_ShowPGBenchProgressInterval
        }
        if ($p_CapturePGBenchLog -eq "Y") {
            $value+= ' --log '
            $value+= ' --log-prefix="' + 'pgbench_log" '
        }
        $value+=' --report-per-command '
    return $value
}


function Get-Argument_PSQL
    {
        $param_list = $args[0]
            $p_server = $param_list[0]
            $p_port = $param_list[1]
            $p_user = $param_list[2]
            $p_database = $param_list[3]

        return @(
            '-h', $p_server,
            '-p', $p_port,
            '-U', $p_user,
            '-d', $p_database,
            '--no-password'
        )
}


function New-PgPassFile
    {

        $param_list = $args[0]
            $p_server = $param_list[0]
            $p_port = $param_list[1]
            $p_database = $param_list[2]
            $p_user = $param_list[3]
            $p_pass = $param_list[4]

        # https://www.postgresql.org/docs/current/libpq-pgpass.html
        $pgConfigFolder = Join-Path $env:APPDATA 'postgresql'
        $pgPassPath = Join-Path $pgConfigFolder 'pgpass.conf'
        $pgPassContent = $p_server + ':' + $p_port + ':' + $p_database + ':' + $p_user + ':' + $p_pass

        New-Item -ItemType Directory -Path $pgConfigFolder -Force | Out-Null
        Set-Content -Path $pgPassPath -Value $pgPassContent -Force

    return $pgPassPath
}


function Get-ResultsFolder
    {
        $param_list = $args[0]
            $p_Results_folder = $param_list[0]
            $p_Timestamp = $param_list[1]

        # ----------------------------------------------------
        # Output Folder
        # ----------------------------------------------------
        $WorkloadResultsFolder = Join-Path $ResultsRoot $p_Results_folder
        if ($p_Timestamp -eq "Y") {
            $RunId = Get-Date -Format "yyyyMMdd_HHmmss"
            $OutputFolder = Join-Path $WorkloadResultsFolder $RunId
        } else {
            $RunId = ""
            $OutputFolder = $WorkloadResultsFolder
        }
   
        New-Item -ItemType Directory `
        -Path $OutputFolder `
        -Force | Out-Null
 
    return $OutputFolder
} 

function Start-PgBenchWorkload
    {
        param(
            [Parameter(Mandatory = $true)]
            [string]$ArgumentList,

            [Parameter(Mandatory = $true)]
            [string]$WorkingDirectory,

            [Parameter(Mandatory = $true)]
            [string]$ApplicationName,

            [switch]$Wait
        )

        $ResolvedOutputFolder = [System.IO.Path]::GetFullPath($WorkingDirectory)

        if (-not $CapturePGBenchDiagnostics) {
            $StartProcessParameters = @{
                FilePath = $PgBenchExe
                WorkingDirectory = $ResolvedOutputFolder
                WindowStyle = $PGBench_WindowsStyle
                ArgumentList = $ArgumentList
                PassThru = $true
            }

            if ($Wait) {
                $StartProcessParameters.Wait = $true
            }

            return Start-Process @StartProcessParameters
        }

        $ConsoleLogPath = Join-Path $ResolvedOutputFolder 'pgbench_console.log'
        $ErrorLogPath = Join-Path $ResolvedOutputFolder 'pgbench_error.log'
        $StatusLogPath = Join-Path $ResolvedOutputFolder 'pgbench_status.txt'
        $CommandLogPath = Join-Path $ResolvedOutputFolder 'pgbench_command.txt'
        $StartedAt = Get-Date

        @(
            "StartedAt=$($StartedAt.ToString('o'))"
            "ApplicationName=$ApplicationName"
            "Executable=$PgBenchExe"
            "Arguments=$ArgumentList"
            "WorkingDirectory=$ResolvedOutputFolder"
        ) | Set-Content -LiteralPath $CommandLogPath

        Write-Host "PGBench diagnostics: $ResolvedOutputFolder"

        try {
            $Process = Start-Process `
                -FilePath $PgBenchExe `
                -WorkingDirectory $ResolvedOutputFolder `
                -WindowStyle $PGBench_WindowsStyle `
                -ArgumentList $ArgumentList `
                -RedirectStandardOutput $ConsoleLogPath `
                -RedirectStandardError $ErrorLogPath `
                -PassThru
        } catch {
            @(
                "StartedAt=$($StartedAt.ToString('o'))"
                "CompletedAt=$((Get-Date).ToString('o'))"
                'ExitCode=START_FAILED'
                "Error=$($_.Exception.Message)"
            ) | Set-Content -LiteralPath $StatusLogPath
            throw
        }

        if ($Wait) {
            $Process.WaitForExit()
            @(
                "StartedAt=$($StartedAt.ToString('o'))"
                "CompletedAt=$((Get-Date).ToString('o'))"
                "ProcessId=$($Process.Id)"
                "ExitCode=$($Process.ExitCode)"
            ) | Set-Content -LiteralPath $StatusLogPath
        } else {
            $Process.EnableRaisingEvents = $true
            $EventData = @{
                StartedAt = $StartedAt
                StatusLogPath = $StatusLogPath
            }
            $null = Register-ObjectEvent `
                -InputObject $Process `
                -EventName Exited `
                -MessageData $EventData `
                -Action {
                    @(
                        "StartedAt=$($Event.MessageData.StartedAt.ToString('o'))"
                        "CompletedAt=$((Get-Date).ToString('o'))"
                        "ProcessId=$($Event.Sender.Id)"
                        "ExitCode=$($Event.Sender.ExitCode)"
                    ) | Set-Content -LiteralPath $Event.MessageData.StatusLogPath
                    Unregister-Event -SourceIdentifier $Event.SourceIdentifier
                }
        }

        return $Process
}


#
# create Results folder if not exists
#
if (-not (Test-Path -LiteralPath $ResultsRoot)) {
    New-Item -ItemType Directory `
    -Path $ResultsRoot `
    -Force | Out-Null
}

$form.Topmost = $true
#
# display form on a loop
#
while ($true) {

    $form.Add_Shown({$textBoxInstance.Select()})

    $result = $form.ShowDialog()

    [string]$srv=''
    [string]$database=''
    [string]$user=''
    [string]$Pass=''
    [string]$clients=''
    [string]$Threads=''
    [string]$LimitType=''
    [string]$LimitAmount=''
    [string]$ShowPGBenchProgress=''
    [string]$ShowPGBenchProgressInterval=''
    [string]$CapturePGBenchLog=''
    [string]$arguments=''

    if ($result -ne [System.Windows.Forms.DialogResult]::OK){
        BREAK
    }

    if ($result -eq [System.Windows.Forms.DialogResult]::OK)
    {
        $srv = $textBoxInstance.Text
        $port = $textboxPort.Text
        $database = $textBoxDatabase.Text
        if ($database -eq "")
            {
                $database = "master"
            }
        $user = $textBoxUsername.text
        $pass = $textboxpassword.text 
        
        $clients = $textboxClients.Text
        if ($clients -eq "")
            {
                $clients = "1"
            }
        $Threads = $textboxThreads.Text
        if ($Threads -eq "")
            {
                $Threads = "10"
            }

        if ($ExecNothingRadioButton.Checked) {
            $LimitType=' ' ## for NOTHING
            $LimitAmount=''
        } elseif ($ExecTransactionsRadioButton.Checked) {
            $LimitType='transactions'
            $LimitAmount=$textBoxExecTransactions.text
        } elseif ($ExecTimeRadioButton.Checked) {
            $LimitType='time' 
            $LimitAmount=$textBoxExecExecTime.text 
        }

        $PGBench_WindowsStyle = "Normal" ## "Hidden"
        if ($chkbox_showPGBench.checked) {
            $PGBench_WindowsStyle = "Minimized"
        }

        if ($chkbox_showPGBenchProgress.checked) {
            $ShowPGBenchProgress='Y'
            $ShowPGBenchProgressInterval=$textboxPGBenchProgress.text
        } else {
            $ShowPGBenchProgress='N'
            $ShowPGBenchProgressInterval=''
        }

        if ($chkbox_CapturePGBenchLog.checked) {
            $CapturePGBenchLog='Y'
        } else {
            $CapturePGBenchLog='N'
        }


    }


    ## lisbox selection
    if ($result -eq [System.Windows.Forms.DialogResult]::OK)
    {

        # check: save/overwrite exec_PGBENCH.TXT file?
        ##
        ## UPDATE INFO ON exec_PGBENCH.TXT
        ##
        $lastexecpath = Join-Path $scriptDir 'exec_PGBENCH.TXT'
        #if 1 -eq 1 {
            #if (Test-Path -LiteralPath $lastexecpath) {
            #    Remove-Item -LiteralPath $path -Verbose 
            #}
            $textBoxInstance.text | Out-File $lastexecpath
            $textBoxDatabase.text | Out-File -FilePath $lastexecpath -Append
            $textBoxUsername.text | Out-File -FilePath $lastexecpath -Append
            #
            # do not save password:
            #$textBoxPassword.text | Out-File -FilePath $lastexecpath -Append
            #
            $textboxClients.text | Out-File -FilePath $lastexecpath -Append
            $textboxThreads.text | Out-File -FilePath $lastexecpath -Append
        #}


        if ($listBox.SelectedIndex -eq -1) {
            $listBox.SelectedIndex = 0
        }
        $Workload = $listBox.SelectedItem
        $selection = $Workload.Substring(0,1) 


        # check to reset PGSTATS before run
        if ($chkbox_Reset_PG_Stats_beforeRun.checked) {
            $ArgsPsqlExe = Get-Argument_PSQL @($srv, $port, $user, $database)
            $env:PGPASSWORD = $pass
            $ResetStatsSql = @"
SELECT pg_stat_reset();
SELECT pg_stat_reset_shared('io');
SELECT pg_stat_statements_reset();
SELECT pg_stat_clear_snapshot();
"@
            & $PsqlExe @ArgsPsqlExe --set=ON_ERROR_STOP=1 -c $ResetStatsSql
            if ($LASTEXITCODE -ne 0) {
                throw "PostgreSQL statistics reset failed. psql exit code: $LASTEXITCODE"
            }
        }   

          <# Tracking configuration is disabled because managed PostgreSQL settings
              must be changed through the provider's server-parameter controls.
        $TrackingMode = if ($EnableTrackingRadioButton.Checked) { "on" } else { "off" }
        $ArgsPsqlExe = Get-Argument_PSQL @($srv, $port, $user, $database)
        $env:PGPASSWORD = $pass
        [string[]]$TrackingOutput = @(& $PsqlExe @ArgsPsqlExe --set=ON_ERROR_STOP=1 --variable="enable_tracking=$TrackingMode" -f "$scriptDir\SQL\DBA\DBA_EnableTracking.SQL" 2>&1)
        $TrackingExitCode = $LASTEXITCODE
        $TrackingOutput | ForEach-Object { Write-Host $_ }
        if ($TrackingExitCode -ne 0) {
            $TrackingError = [string]::Join([Environment]::NewLine, $TrackingOutput).Trim()
            throw "PostgreSQL tracking configuration failed. psql exit code: $TrackingExitCode`n$TrackingError"
        }
        #>


        switch ($selection)
        {
        '0' {    
                $paths = 'PGBench_TestConnection'
                $OutputFolder = Get-ResultsFolder @($paths, "Y")
                
                $arguments = Get-Argument_PGBench($srv, $port, $user, $database , "$scriptDir\SQL\Connection_test.sql" , $clients , $Threads ,$LimitType , $LimitAmount, $paths ,$ShowPGBenchProgress, $ShowPGBenchProgressInterval, $CapturePGBenchLog)
                $env:PGPASSWORD = $pass; $env:PGAPPNAME=$paths; $null = Start-PgBenchWorkload -ArgumentList $arguments -WorkingDirectory $OutputFolder -ApplicationName $paths
            }

        '1' {    
                $paths = 'PGBench_CompileWorkload'
                $OutputFolder = Get-ResultsFolder @($paths, "Y")

                $arguments = Get-Argument_PGBench($srv, $port, $user, $database , "$scriptDir\SQL\AdventureWorks_Compile_Workload.sql" , $clients , $Threads ,$LimitType , $LimitAmount, $paths ,$ShowPGBenchProgress, $ShowPGBenchProgressInterval, $CapturePGBenchLog)
                $env:PGPASSWORD = $pass; $env:PGAPPNAME=$paths; $null = Start-PgBenchWorkload -ArgumentList $arguments -WorkingDirectory $OutputFolder -ApplicationName $paths
            }         

        '2' {
                
                # # # # script for setup
                $ArgsPsqlExe = Get-Argument_PSQL @($srv, $port, $user, $database)
                $env:PGPASSWORD = $pass; 
                $PgPassPath = New-PgPassFile @($srv, $port, $database, $user, $pass)
                
                & $PsqlExe @ArgsPsqlExe --set=ON_ERROR_STOP=1 -f "$scriptDir\SQL\AdventureWorks_CPU - setup.sql"
                if ($LASTEXITCODE -ne 0) {
                    throw "AdventureWorks CPU setup failed. psql exit code: $LASTEXITCODE"
                }
                
                # after executing psql destroy the pgpass.conf file
                if (Test-Path -LiteralPath $PgPassPath) {
                    Remove-Item -LiteralPath $PgPassPath -Verbose 
                }

                # workload 
                $paths = 'PGBench_CPU_Stress' 
                $OutputFolder = Get-ResultsFolder @($paths, "Y")
                $arguments = Get-Argument_PGBench($srv, $port, $user, $database , "$scriptDir\SQL\AdventureWorks_CPU.sql" , $clients , $Threads ,$LimitType , $LimitAmount,  $paths, $ShowPGBenchProgress, $ShowPGBenchProgressInterval, $CapturePGBenchLog)
                $env:PGPASSWORD = $pass; $env:PGAPPNAME=$paths
                $PgBenchProcess = Start-PgBenchWorkload -ArgumentList $arguments -WorkingDirectory $OutputFolder -ApplicationName $paths -Wait

                & $PsqlExe @ArgsPsqlExe --set=ON_ERROR_STOP=1 -f "$scriptDir\SQL\AdventureWorks_CPU - cleanup.sql"
                $CleanupExitCode = $LASTEXITCODE

                if ($CleanupExitCode -ne 0) {
                    throw "AdventureWorks CPU cleanup failed. psql exit code: $CleanupExitCode"
                }

                if ($PgBenchProcess.ExitCode -ne 0) {
                    throw "AdventureWorks CPU workload failed. pgbench exit code: $($PgBenchProcess.ExitCode)"
                }
            }         

        '3' 
            {    
                # workload 
                $paths = 'PGBench_SQLCPUPower'
                $OutputFolder = Get-ResultsFolder @($paths, "Y")
                $arguments = Get-Argument_PGBench($srv, $port, $user, $database , "$scriptDir\SQL\CPU Busy - Power.sql" , $clients , $Threads ,$LimitType , $LimitAmount,  $paths ,$ShowPGBenchProgress, $ShowPGBenchProgressInterval, $CapturePGBenchLog)
                $env:PGPASSWORD = $pass; $env:PGAPPNAME=$paths; $null = Start-PgBenchWorkload -ArgumentList $arguments -WorkingDirectory $OutputFolder -ApplicationName $paths

                # workload 
                $paths = 'PGBench_SQLCPUCosine'
                $OutputFolder = Get-ResultsFolder @($paths, "Y")
                $arguments = Get-Argument_PGBench($srv, $port, $user, $database , "$scriptDir\SQL\CPU Busy - COSine.sql" , $clients , $Threads ,$LimitType , $LimitAmount,  $paths ,$ShowPGBenchProgress, $ShowPGBenchProgressInterval, $CapturePGBenchLog)
                $env:PGPASSWORD = $pass; $env:PGAPPNAME=$paths; $null = Start-PgBenchWorkload -ArgumentList $arguments -WorkingDirectory $OutputFolder -ApplicationName $paths

                # workload 
                $paths = 'PGBench_SQLCPUNumbers' 
                $OutputFolder = Get-ResultsFolder @($paths, "Y")
                $arguments = Get-Argument_PGBench($srv, $port, $user, $database , "$scriptDir\SQL\CPU Busy - Numbers Table.sql" , $clients , $Threads ,$LimitType , $LimitAmount,  $paths ,$ShowPGBenchProgress, $ShowPGBenchProgressInterval, $CapturePGBenchLog)
                $env:PGPASSWORD = $pass; $env:PGAPPNAME=$paths; $null = Start-PgBenchWorkload -ArgumentList $arguments -WorkingDirectory $OutputFolder -ApplicationName $paths

            }
        '4' 
            {    
                $paths = 'PGBench_blockers_2A'
                $OutputFolder = Get-ResultsFolder @($paths, "Y")
                # workload 
                $arguments = Get-Argument_PGBench($srv, $port, $user, $database , "$scriptDir\SQL\AdventureWorks_blockers_2A.sql" , $clients , $Threads ,$LimitType , $LimitAmount,  $paths,$ShowPGBenchProgress, $ShowPGBenchProgressInterval, $CapturePGBenchLog)
                $env:PGPASSWORD = $pass; $env:PGAPPNAME=$paths; $null = Start-PgBenchWorkload -ArgumentList $arguments -WorkingDirectory $OutputFolder -ApplicationName $paths

                $paths = 'PGBench_blocked_2A'
                $OutputFolder = Get-ResultsFolder @($paths, "Y")
                # workload 
                $arguments = Get-Argument_PGBench($srv, $port, $user, $database , "$scriptDir\SQL\AdventureWorks_blocked_2A.sql" , $clients , $Threads ,$LimitType , $LimitAmount,  $paths,$ShowPGBenchProgress, $ShowPGBenchProgressInterval, $CapturePGBenchLog)
                $env:PGPASSWORD = $pass; $env:PGAPPNAME=$paths; $null = Start-PgBenchWorkload -ArgumentList $arguments -WorkingDirectory $OutputFolder -ApplicationName $paths

            } 
        '5' 
            {
                $ArgsPsqlExe = Get-Argument_PSQL @($srv, $port, $user, $database)
                $env:PGPASSWORD = $pass
                $PgPassPath = New-PgPassFile @($srv, $port, $database, $user, $pass)

                & $PsqlExe @ArgsPsqlExe --set=ON_ERROR_STOP=1 -f "$scriptDir\SQL\AdventureWorks_Sargability_BAD_Setup.sql"
                if ($LASTEXITCODE -ne 0) {
                    throw "AdventureWorks SARGability BAD setup failed. psql exit code: $LASTEXITCODE"
                }

                $paths = 'PGBench_Sargability_BAD'
                $OutputFolder = Get-ResultsFolder @($paths, "Y")
                $arguments = Get-Argument_PGBench($srv, $port, $user, $database , "$scriptDir\SQL\AdventureWorks_Sargability_BAD.sql" , $clients , $Threads ,$LimitType , $LimitAmount,  $paths,$ShowPGBenchProgress, $ShowPGBenchProgressInterval, $CapturePGBenchLog)
                $env:PGPASSWORD = $pass; $env:PGAPPNAME=$paths; $null = Start-PgBenchWorkload -ArgumentList $arguments -WorkingDirectory $OutputFolder -ApplicationName $paths -Wait

                $continueFixed = [System.Windows.Forms.MessageBox]::Show(
                    "The BAD SARGability workload has completed.`n`nContinue with the FIXED workload?",
                    "SARGability workload",
                    [System.Windows.Forms.MessageBoxButtons]::YesNo,
                    [System.Windows.Forms.MessageBoxIcon]::Information,
                    [System.Windows.Forms.MessageBoxDefaultButton]::Button2
                )

                if ($continueFixed -eq [System.Windows.Forms.DialogResult]::Yes) {
                    & $PsqlExe @ArgsPsqlExe --set=ON_ERROR_STOP=1 -f "$scriptDir\SQL\AdventureWorks_Sargability_FIXED_Setup.sql"
                    if ($LASTEXITCODE -ne 0) {
                        throw "AdventureWorks SARGability FIXED setup failed. psql exit code: $LASTEXITCODE"
                    }

                    $paths = 'PGBench_Sargability_FIXED'
                    $OutputFolder = Get-ResultsFolder @($paths, "Y")
                    $arguments = Get-Argument_PGBench($srv, $port, $user, $database , "$scriptDir\SQL\AdventureWorks_Sargability_FIXED.sql" , $clients , $Threads ,$LimitType , $LimitAmount,  $paths,$ShowPGBenchProgress, $ShowPGBenchProgressInterval, $CapturePGBenchLog)
                    $env:PGPASSWORD = $pass; $env:PGAPPNAME=$paths; $null = Start-PgBenchWorkload -ArgumentList $arguments -WorkingDirectory $OutputFolder -ApplicationName $paths
                }

                if (Test-Path -LiteralPath $PgPassPath) {
                    Remove-Item -LiteralPath $PgPassPath -Verbose
                }
            } 

        '6' {    
                $paths = 'PGBench_ExecutionPlan'
                $OutputFolder = Get-ResultsFolder @($paths, "Y")
                # workload 
                $arguments = Get-Argument_PGBench($srv, $port, $user, $database , "$scriptDir\SQL\AdventureWorks_ExecutionPlan.sql" , $clients , $Threads ,$LimitType , $LimitAmount,  $paths,$ShowPGBenchProgress, $ShowPGBenchProgressInterval, $CapturePGBenchLog)
                $env:PGPASSWORD = $pass; $env:PGAPPNAME=$paths; $null = Start-PgBenchWorkload -ArgumentList $arguments -WorkingDirectory $OutputFolder -ApplicationName $paths
            }

        '7' {
                $ArgsPsqlExe = Get-Argument_PSQL @($srv, $port, $user, $database)
                $env:PGPASSWORD = $pass

                & $PsqlExe @ArgsPsqlExe --set=ON_ERROR_STOP=1 -f "$scriptDir\SQL\AdventureWorks_Cursors_Setup.sql"
                if ($LASTEXITCODE -ne 0) {
                    throw "AdventureWorks cursor setup failed. psql exit code: $LASTEXITCODE"
                }

                # workload 
                $paths = 'PGBench_Cursors_PersonAddress'
                $OutputFolder = Get-ResultsFolder @($paths, "Y")
                $arguments = Get-Argument_PGBench($srv, $port, $user, $database , "$scriptDir\SQL\AdventureWorks_Cursors_PersonAddress.sql" , $clients , $Threads ,$LimitType , $LimitAmount,  $paths,$ShowPGBenchProgress, $ShowPGBenchProgressInterval, $CapturePGBenchLog)
                $env:PGPASSWORD = $pass; $env:PGAPPNAME=$paths; $null = Start-PgBenchWorkload -ArgumentList $arguments -WorkingDirectory $OutputFolder -ApplicationName $paths

                $paths = 'PGBench_Cursors_SalesOrderHeader'
                $OutputFolder = Get-ResultsFolder @($paths, "Y")
                $arguments = Get-Argument_PGBench($srv, $port, $user, $database , "$scriptDir\SQL\AdventureWorks_Cursors_SalesOrderHeader.sql" , $clients , $Threads ,$LimitType , $LimitAmount,  $paths,$ShowPGBenchProgress, $ShowPGBenchProgressInterval, $CapturePGBenchLog)
                $env:PGPASSWORD = $pass; $env:PGAPPNAME=$paths; $null = Start-PgBenchWorkload -ArgumentList $arguments -WorkingDirectory $OutputFolder -ApplicationName $paths

                $paths = 'PGBench_Cursors_UpdateSalesOrderHeader'
                $OutputFolder = Get-ResultsFolder @($paths, "Y")
                $arguments = Get-Argument_PGBench($srv, $port, $user, $database , "$scriptDir\SQL\AdventureWorks_Cursors_UpdateSalesOrderHeader.sql" , $clients , $Threads ,$LimitType , $LimitAmount,  $paths,$ShowPGBenchProgress, $ShowPGBenchProgressInterval, $CapturePGBenchLog)
                $env:PGPASSWORD = $pass; $env:PGAPPNAME=$paths; $null = Start-PgBenchWorkload -ArgumentList $arguments -WorkingDirectory $OutputFolder -ApplicationName $paths
            } 

        '8' {
            $ArgsPsqlExe = Get-Argument_PSQL @($srv, $port, $user, $database)
            $env:PGPASSWORD = $pass

            & $PsqlExe @ArgsPsqlExe --set=ON_ERROR_STOP=1 -f "$scriptDir\SQL\AdventureWorks_Errors_Setup.sql"
            if ($LASTEXITCODE -ne 0) {
                throw "AdventureWorks errors setup failed. psql exit code: $LASTEXITCODE"
            }

                $paths = 'PGBench_Errors'
                $OutputFolder = Get-ResultsFolder @($paths, "Y")
                # workload 
                $arguments = Get-Argument_PGBench($srv, $port, $user, $database , "$scriptDir\SQL\AdventureWorks_Errors.sql" , $clients , $Threads ,$LimitType , $LimitAmount,  $paths,$ShowPGBenchProgress, $ShowPGBenchProgressInterval, $CapturePGBenchLog)
                $env:PGPASSWORD = $pass; $env:PGAPPNAME=$paths; $null = Start-PgBenchWorkload -ArgumentList $arguments -WorkingDirectory $OutputFolder -ApplicationName $paths
            } 

        '9' {    
                $paths = 'PGBench_TempDBResults'
                $OutputFolder = Get-ResultsFolder @($paths, "Y")
                # workload 
                $arguments = Get-Argument_PGBench($srv, $port, $user, $database , "$scriptDir\SQL\Stress_TempDB.sql" , $clients , $Threads ,$LimitType , $LimitAmount,  $paths,$ShowPGBenchProgress, $ShowPGBenchProgressInterval, $CapturePGBenchLog)
                $env:PGPASSWORD = $pass; $env:PGAPPNAME=$paths; $null = Start-PgBenchWorkload -ArgumentList $arguments -WorkingDirectory $OutputFolder -ApplicationName $paths
            }

        'A' {    
                $paths = 'PGBench_CPURunner'
                $OutputFolder = Get-ResultsFolder @($paths, "Y")
                # workload 
                $arguments = Get-Argument_PGBench($srv, $port, $user, $database , "$scriptDir\SQL\AdventureWorks_CPURunner.sql" , $clients , $Threads ,$LimitType , $LimitAmount,  $paths,$ShowPGBenchProgress, $ShowPGBenchProgressInterval, $CapturePGBenchLog)
                $env:PGPASSWORD = $pass; $env:PGAPPNAME=$paths; Start-Process -FilePath $PgBenchExe -WorkingDirectory $OutputFolder -WindowStyle $PGBench_WindowsStyle -ArgumentList $arguments
            } 

        'B' {    
                $paths = 'PGBench_HeavyQuery'
                $OutputFolder = Get-ResultsFolder @($paths, "Y")
                # workload 
                $arguments = Get-Argument_PGBench($srv, $port, $user, $database , "$scriptDir\SQL\AdventureWorks_HeavyQuery.sql" , $clients , $Threads ,$LimitType , $LimitAmount,  $paths,$ShowPGBenchProgress, $ShowPGBenchProgressInterval, $CapturePGBenchLog)
                $env:PGPASSWORD = $pass; $env:PGAPPNAME=$paths; Start-Process -FilePath $PgBenchExe -WorkingDirectory $OutputFolder -WindowStyle $PGBench_WindowsStyle -ArgumentList $arguments
            } 

        'C' {

                $paths = 'PGBench_Dynamic_Workload'
                $OutputFolder = Get-ResultsFolder @($paths, "Y")
                # workload 
                $arguments = Get-Argument_PGBench($srv, $port, $user, $database , "$scriptDir\SQL\AdventureWorks_Dynamic_Workload.sql" , $clients , $Threads ,$LimitType , $LimitAmount,  $paths,$ShowPGBenchProgress, $ShowPGBenchProgressInterval, $CapturePGBenchLog)
                $env:PGPASSWORD = $pass; $env:PGAPPNAME=$paths; Start-Process -FilePath $PgBenchExe -WorkingDirectory $OutputFolder -WindowStyle $PGBench_WindowsStyle -ArgumentList $arguments
            }

        'D' {    
                $paths = 'PGBench_MemoryGrant'
                $OutputFolder = Get-ResultsFolder @($paths, "Y")
                # workload 
                $arguments = Get-Argument_PGBench($srv, $port, $user, $database , "$scriptDir\SQL\AdventureWorks_MemoryGrant.sql" , $clients , $Threads ,$LimitType , $LimitAmount,  $paths,$ShowPGBenchProgress, $ShowPGBenchProgressInterval, $CapturePGBenchLog)
                $env:PGPASSWORD = $pass; $env:PGAPPNAME=$paths; Start-Process -FilePath $PgBenchExe -WorkingDirectory $OutputFolder -WindowStyle $PGBench_WindowsStyle -ArgumentList $arguments
            } 

        'E' {
                # remove previous execution:
                $paths = 'PGBench_KeysetCursor'
                $OutputFolder = Get-ResultsFolder @($paths, "Y")
                # workload 
                $arguments = Get-Argument_PGBench($srv, $port, $user, $database , "$scriptDir\SQL\STRESS 103 - KEYSET CURSOR for UPDATE Person.sql" , $clients , $Threads ,$LimitType , $LimitAmount,  $paths,$ShowPGBenchProgress, $ShowPGBenchProgressInterval, $CapturePGBenchLog)
                $env:PGPASSWORD = $pass; $env:PGAPPNAME=$paths; Start-Process -FilePath $PgBenchExe -WorkingDirectory $OutputFolder -WindowStyle $PGBench_WindowsStyle -ArgumentList $arguments
            } 

        'F' {
                $paths = 'PGBench_UPDATECursor'
                $OutputFolder = Get-ResultsFolder @($paths, "Y")
                # workload 
                $arguments = Get-Argument_PGBench($srv, $port, $user, $database , "$scriptDir\SQL\STRESS 101 - UPDATE Person Cursor.sql" , $clients , $Threads ,$LimitType , $LimitAmount,  $paths,$ShowPGBenchProgress, $ShowPGBenchProgressInterval, $CapturePGBenchLog)
                $env:PGPASSWORD = $pass; $env:PGAPPNAME=$paths; Start-Process -FilePath $PgBenchExe -WorkingDirectory $OutputFolder -WindowStyle $PGBench_WindowsStyle -ArgumentList $arguments
            }

        'G' {
                $paths = 'PGBench_READONLYCursor'
                $OutputFolder = Get-ResultsFolder @($paths, "Y")
                # workload 
                $arguments = Get-Argument_PGBench($srv, $port, $user, $database , "$scriptDir\SQL\STRESS 102 - READONLY Cursor Person.sql" , $clients , $Threads ,$LimitType , $LimitAmount,  $paths,$ShowPGBenchProgress, $ShowPGBenchProgressInterval, $CapturePGBenchLog)
                $env:PGPASSWORD = $pass; $env:PGAPPNAME=$paths; Start-Process -FilePath $PgBenchExe -WorkingDirectory $OutputFolder -WindowStyle $PGBench_WindowsStyle -ArgumentList $arguments
            } 

        'H' {
                # setup
                $ArgsPsqlExe = Get-Argument_PSQL @($srv, $port, $user, $database)
                $PgPassPath = New-PgPassFile @($srv, $port, $database, $user, $pass)
                & $PsqlExe @ArgsPsqlExe --set=ON_ERROR_STOP=1 -f "$scriptDir\SQL\AdventureWorks_EnlargeSalesTables_Setup.sql"
                # after executing psql destroy pgpass.conf file
                if (Test-Path -LiteralPath $PgPassPath) {
                    Remove-Item -LiteralPath $PgPassPath -Verbose 
                }

                # workload 
                $paths = 'PGBench_InsertEnlargedSales' 
                $OutputFolder = Get-ResultsFolder @($paths, "Y")
                $arguments = Get-Argument_PGBench($srv, $port, $user, $database , "$scriptDir\SQL\AdventureWorks_EnlargeSalesTables.sql" , $clients , $Threads ,$LimitType , $LimitAmount,  $paths,$ShowPGBenchProgress, $ShowPGBenchProgressInterval, $CapturePGBenchLog)
                $env:PGPASSWORD = $pass; $env:PGAPPNAME=$paths; Start-Process -FilePath $PgBenchExe -WorkingDirectory $OutputFolder -WindowStyle $PGBench_WindowsStyle -ArgumentList $arguments
            } 

        'I' {
                
                # setup
                $ArgsPsqlExe = Get-Argument_PSQL @($srv, $port, $user, $database)
                $PgPassPath = New-PgPassFile @($srv, $port, $database, $user, $pass)
                & $PsqlExe @ArgsPsqlExe --set=ON_ERROR_STOP=1 -f "$scriptDir\SQL\AdventureWorks_ParamSniffing - setup.sql"
                # after executing psql destroy pgpass.conf file
                if (Test-Path -LiteralPath $PgPassPath) {
                    Remove-Item -LiteralPath $PgPassPath -Verbose 
                }

                # workload 
                $paths = 'PGBench_ParamSniffing'
                $OutputFolder = Get-ResultsFolder @($paths, "Y")
                $arguments = Get-Argument_PGBench($srv, $port, $user, $database , "$scriptDir\SQL\AdventureWorks_ParamSniffing.sql" , $clients , $Threads ,$LimitType , $LimitAmount,  $paths,$ShowPGBenchProgress, $ShowPGBenchProgressInterval, $CapturePGBenchLog)
                $env:PGPASSWORD = $pass; $env:PGAPPNAME=$paths; Start-Process -FilePath $PgBenchExe -WorkingDirectory $OutputFolder -WindowStyle $PGBench_WindowsStyle -ArgumentList $arguments
                # workload 
                $paths =  'PGBench_Hash'
                $OutputFolder = Get-ResultsFolder @($paths, "Y")
                $arguments = Get-Argument_PGBench($srv, $port, $user, $database , "$scriptDir\SQL\AdventureWorks_Hash.sql" , $clients , $Threads ,$LimitType , $LimitAmount,  $paths,$ShowPGBenchProgress, $ShowPGBenchProgressInterval, $CapturePGBenchLog)
                $env:PGPASSWORD = $pass; $env:PGAPPNAME=$paths; Start-Process -FilePath $PgBenchExe -WorkingDirectory $OutputFolder -WindowStyle $PGBench_WindowsStyle -ArgumentList $arguments
                # workload 
                $paths =  'PGBench_PARAMETERIZATION'
                $OutputFolder = Get-ResultsFolder @($paths, "Y")
                $arguments = Get-Argument_PGBench($srv, $port, $user, $database , "$scriptDir\SQL\AdventureWorks_PARAMETERIZATION.sql" , $clients , $Threads ,$LimitType , $LimitAmount,  $paths,$ShowPGBenchProgress, $ShowPGBenchProgressInterval, $CapturePGBenchLog)
                $env:PGPASSWORD = $pass; $env:PGAPPNAME=$paths; Start-Process -FilePath $PgBenchExe -WorkingDirectory $OutputFolder -WindowStyle $PGBench_WindowsStyle -ArgumentList $arguments
                # workload 
                $paths =  'PGBench_Recompile'
                $OutputFolder = Get-ResultsFolder @($paths, "Y")
                $arguments = Get-Argument_PGBench($srv, $port, $user, $database , "$scriptDir\SQL\AdventureWorks_Recompile.sql" , $clients , $Threads ,$LimitType , $LimitAmount,  $paths,$ShowPGBenchProgress, $ShowPGBenchProgressInterval, $CapturePGBenchLog)
                $env:PGPASSWORD = $pass; $env:PGAPPNAME=$paths; Start-Process -FilePath $PgBenchExe -WorkingDirectory $OutputFolder -WindowStyle $PGBench_WindowsStyle -ArgumentList $arguments
                # workload 
                $paths =  'PGBench_High_CPU'
                $OutputFolder = Get-ResultsFolder @($paths, "Y")
                $arguments = Get-Argument_PGBench($srv, $port, $user, $database , "$scriptDir\SQL\AdventureWorks_HighCPU.sql" , $clients , $Threads ,$LimitType , $LimitAmount,  $paths,$ShowPGBenchProgress, $ShowPGBenchProgressInterval, $CapturePGBenchLog)
                $env:PGPASSWORD = $pass; $env:PGAPPNAME=$paths; Start-Process -FilePath $PgBenchExe -WorkingDirectory $OutputFolder -WindowStyle $PGBench_WindowsStyle -ArgumentList $arguments

            }


        'J' { # J for TempDB small/med/large #tables
                # setup
                $ArgsPsqlExe = Get-Argument_PSQL @($srv, $port, $user, $database)
                $PgPassPath = New-PgPassFile @($srv, $port, $database, $user, $pass)
                & $PsqlExe @ArgsPsqlExe --set=ON_ERROR_STOP=1 -f "$scriptDir\SQL\tempstress_ddl.sql"
                # after executing psql destroy pgpass.conf file
                if (Test-Path -LiteralPath $PgPassPath) {
                    Remove-Item -LiteralPath $PgPassPath -Verbose 
                }

                # workload 
                $paths = 'PGBench_TempDB_Objects_small' 
                $OutputFolder = Get-ResultsFolder @($paths, "Y")
                $arguments = Get-Argument_PGBench($srv, $port, $user, $database , "$scriptDir\SQL\gen_tempstress_small.sql" , $clients , $Threads ,$LimitType , $LimitAmount,  $paths,$ShowPGBenchProgress, $ShowPGBenchProgressInterval, $CapturePGBenchLog)
                $env:PGPASSWORD = $pass; $env:PGAPPNAME=$paths; Start-Process -FilePath $PgBenchExe -WorkingDirectory $OutputFolder -WindowStyle $PGBench_WindowsStyle -ArgumentList $arguments
                # workload 
                $paths = 'PGBench_TempDB_medsize'
                $OutputFolder = Get-ResultsFolder @($paths, "Y")
                $arguments = Get-Argument_PGBench($srv, $port, $user, $database , "$scriptDir\SQL\gen_tempstress_medsize.sql" , $clients , $Threads ,$LimitType , $LimitAmount,  $paths,$ShowPGBenchProgress, $ShowPGBenchProgressInterval, $CapturePGBenchLog)
                $env:PGPASSWORD = $pass; $env:PGAPPNAME=$paths; Start-Process -FilePath $PgBenchExe -WorkingDirectory $OutputFolder -WindowStyle $PGBench_WindowsStyle -ArgumentList $arguments
                # workload 
                $paths = 'PGBench_TempDB_Objects_large'
                $OutputFolder = Get-ResultsFolder @($paths, "Y")
                $arguments = Get-Argument_PGBench($srv, $port, $user, $database , "$scriptDir\SQL\gen_tempstress_large.sql" , $clients , $Threads ,$LimitType , $LimitAmount,  $paths,$ShowPGBenchProgress, $ShowPGBenchProgressInterval, $CapturePGBenchLog)
                $env:PGPASSWORD = $pass; $env:PGAPPNAME=$paths; Start-Process -FilePath $PgBenchExe -WorkingDirectory $OutputFolder -WindowStyle $PGBench_WindowsStyle -ArgumentList $arguments
            }

            'K' { # K for WriteLog med/large tables
                # setup
                $ArgsPsqlExe = Get-Argument_PSQL @($srv, $port, $user, $database)
                $PgPassPath = New-PgPassFile @($srv, $port, $database, $user, $pass)
                & $PsqlExe @ArgsPsqlExe --set=ON_ERROR_STOP=1 -f "$scriptDir\SQL\WriteLog_ddl.sql"
                # after executing psql destroy pgpass.conf file
                if (Test-Path -LiteralPath $PgPassPath) {
                    Remove-Item -LiteralPath $PgPassPath -Verbose 
                }

                # workload 
                $paths = 'PGBench_WriteLog_Objects_small'
                $OutputFolder = Get-ResultsFolder @($paths, "Y")
                $arguments = Get-Argument_PGBench($srv, $port, $user, $database , "$scriptDir\SQL\gen_WriteLog_small.sql" , $clients , $Threads ,$LimitType , $LimitAmount,  $paths,$ShowPGBenchProgress, $ShowPGBenchProgressInterval, $CapturePGBenchLog)
                $env:PGPASSWORD = $pass; $env:PGAPPNAME=$paths; Start-Process -FilePath $PgBenchExe -WorkingDirectory $OutputFolder -WindowStyle $PGBench_WindowsStyle -ArgumentList $arguments
                # workload 
                $paths = 'PGBench_WriteLog_Objects_medsize'
                $OutputFolder = Get-ResultsFolder @($paths, "Y")
                $arguments = Get-Argument_PGBench($srv, $port, $user, $database , "$scriptDir\SQL\gen_WriteLog_medsize.sql" , $clients , $Threads ,$LimitType , $LimitAmount,  $paths ,$ShowPGBenchProgress, $ShowPGBenchProgressInterval, $CapturePGBenchLog)
                $env:PGPASSWORD = $pass; $env:PGAPPNAME=$paths; Start-Process -FilePath $PgBenchExe -WorkingDirectory $OutputFolder -WindowStyle $PGBench_WindowsStyle -ArgumentList $arguments
                # workload 
                $paths = 'PGBench_WriteLog_Objects_large'
                $OutputFolder = Get-ResultsFolder @($paths, "Y")
                $arguments = Get-Argument_PGBench($srv, $port, $user, $database , "$scriptDir\SQL\gen_WriteLog_large.sql" , $clients , $Threads ,$LimitType , $LimitAmount,  $paths,$ShowPGBenchProgress, $ShowPGBenchProgressInterval, $CapturePGBenchLog)
                $env:PGPASSWORD = $pass; $env:PGAPPNAME=$paths; Start-Process -FilePath $PgBenchExe -WorkingDirectory $OutputFolder -WindowStyle $PGBench_WindowsStyle -ArgumentList $arguments
            }

        'L' { # 'L for Deadlocks'
                # setup
                $ArgsPsqlExe = Get-Argument_PSQL @($srv, $port, $user, $database)
                $PgPassPath = New-PgPassFile @($srv, $port, $database, $user, $pass)
                & $PsqlExe @ArgsPsqlExe --set=ON_ERROR_STOP=1 -f "$scriptDir\SQL\AdventureWorks_Deadlock_Setup.sql"
                # after executing psql destroy pgpass.conf file
                if (Test-Path -LiteralPath $PgPassPath) {
                    Remove-Item -LiteralPath $PgPassPath -Verbose 
                }

                # workload 
                $paths = 'PGBench_deadlock_session_1'
                $OutputFolder = Get-ResultsFolder @($paths, "Y")
                $arguments = Get-Argument_PGBench($srv, $port, $user, $database , "$scriptDir\SQL\AdventureWorks_Deadlock_Session_1.sql" , $clients , $Threads ,$LimitType , $LimitAmount,  $paths,$ShowPGBenchProgress, $ShowPGBenchProgressInterval, $CapturePGBenchLog)
                $env:PGPASSWORD = $pass; $env:PGAPPNAME=$paths; Start-Process -FilePath $PgBenchExe -WorkingDirectory $OutputFolder -WindowStyle $PGBench_WindowsStyle -ArgumentList $arguments
                # workload 
                $paths = 'PGBench_deadlock_session_2'
                $OutputFolder = Get-ResultsFolder @($paths, "Y")
                $arguments = Get-Argument_PGBench($srv, $port, $user, $database , "$scriptDir\SQL\AdventureWorks_Deadlock_Session_2.sql" , $clients , $Threads ,$LimitType , $LimitAmount,  $paths,$ShowPGBenchProgress, $ShowPGBenchProgressInterval, $CapturePGBenchLog)
                $env:PGPASSWORD = $pass; $env:PGAPPNAME=$paths; Start-Process -FilePath $PgBenchExe -WorkingDirectory $OutputFolder -WindowStyle $PGBench_WindowsStyle -ArgumentList $arguments
            }

        'M' { # 'M for Attentions'
                # setup
                $ArgsPsqlExe = Get-Argument_PSQL @($srv, $port, $user, $database)
                $PgPassPath = New-PgPassFile @($srv, $port, $database, $user, $pass)
                & $PsqlExe @ArgsPsqlExe --set=ON_ERROR_STOP=1 -f "$scriptDir\SQL\AdventureWorks_LockEscalation_Setup.sql"
                # after executing psql destroy pgpass.conf file
                if (Test-Path -LiteralPath $PgPassPath) {
                    Remove-Item -LiteralPath $PgPassPath -Verbose 
                }

                # lock-escalation-workload
                $paths = 'PGBench_attentions_LockEscalation'
                $OutputFolder = Get-ResultsFolder @($paths, "Y")
                $arguments = Get-Argument_PGBench($srv, $port, $user, $database , "$scriptDir\SQL\AdventureWorks_LockEscalation_Workload.sql" , $clients , $Threads ,$LimitType , $LimitAmount,  $paths,$ShowPGBenchProgress, $ShowPGBenchProgressInterval, $CapturePGBenchLog)
                $env:PGPASSWORD = $pass; $env:PGAPPNAME=$paths; Start-Process -FilePath $PgBenchExe -WorkingDirectory $OutputFolder -WindowStyle $PGBench_WindowsStyle -ArgumentList $arguments

                # jopin-predicate-workload
                $paths = 'PGBench_attentions_JoinPredicate' 
                $OutputFolder = Get-ResultsFolder @($paths, "Y")
                $arguments = Get-Argument_PGBench($srv, $port, $user, $database , "$scriptDir\SQL\AdventureWorks_attentions_JoinPredicate.sql" , $clients , $Threads ,$LimitType , $LimitAmount,  $paths,$ShowPGBenchProgress, $ShowPGBenchProgressInterval, $CapturePGBenchLog)
                $env:PGPASSWORD = $pass; $env:PGAPPNAME=$paths; Start-Process -FilePath $PgBenchExe -WorkingDirectory $OutputFolder -WindowStyle $PGBench_WindowsStyle -ArgumentList $arguments

                # join-predicate-workload
                $paths = 'PGBench_attentions_SortWarnings'
                $OutputFolder = Get-ResultsFolder @($paths, "Y")
                $arguments = Get-Argument_PGBench($srv, $port, $user, $database , "$scriptDir\SQL\AdventureWorks_attentions_SortWarning.sql" , $clients , $Threads ,$LimitType , $LimitAmount,  $paths,$ShowPGBenchProgress, $ShowPGBenchProgressInterval, $CapturePGBenchLog)
                $env:PGPASSWORD = $pass; $env:PGAPPNAME=$paths; Start-Process -FilePath $PgBenchExe -WorkingDirectory $OutputFolder -WindowStyle $PGBench_WindowsStyle -ArgumentList $arguments

                #$paths = 'PGBench_attentions_HashWarnings'
            }

        'N' { # 'N for Warehousing via Stored Procedure'
                # setup
                # add 'R' for receive operations, add 'T' for transfer operations, add 'S' for shipping operations, add 'I' for inventory operations, add 'C' for capacity operations
                $ArgsPsqlExe = Get-Argument_PSQL @($srv, $port, $user, $database)
                #$env:PGPASSWORD = $pass; 
                $PgPassPath = New-PgPassFile @($srv, $port, $database, $user, $pass)
                
                #$PsqlExe @ArgsPsqlExe -f "$scriptDir\SQL\AdventureWorks_CPU - setup.sql"
                & $PsqlExe @ArgsPsqlExe --set=ON_ERROR_STOP=1 -f "$scriptDir\SQL\warehousing_setup.sql"
                
                # alter / create SPs 
                #$PsqlExe @ArgsPsqlExe -f "$scriptDir\SQL\AdventureWorks_CPU - setup.sql"
                & $PsqlExe @ArgsPsqlExe --set=ON_ERROR_STOP=1 -f "$scriptDir\SQL\warehousing_stored_procedures_setup.sql"
                
                # after executing psql destroy the pgpass.conf file
                if (Test-Path -LiteralPath $PgPassPath) {
                    Remove-Item -LiteralPath $PgPassPath -Verbose 
                }
                
                # usp_InventoryLookup
                $paths = 'PGBench_Warehousing_InventoryLookup'
                $OutputFolder = Get-ResultsFolder @($paths, "Y")
                $arguments = Get-Argument_PGBench($srv, $port, $user, $database , "$scriptDir\SQL\Warehousing_SP_InventoryLookup.sql" , $clients , $Threads ,$LimitType , $LimitAmount,  $paths,$ShowPGBenchProgress, $ShowPGBenchProgressInterval, $CapturePGBenchLog)
                $env:PGPASSWORD = $pass; $env:PGAPPNAME=$paths; Start-Process -FilePath $PgBenchExe -WorkingDirectory $OutputFolder -WindowStyle $PGBench_WindowsStyle -ArgumentList $arguments
                # usp_StockReplenishment
                $paths = 'PGBench_Warehousing_StockReplenishment'
                $OutputFolder = Get-ResultsFolder @($paths, "Y")
                $arguments = Get-Argument_PGBench($srv, $port, $user, $database , "$scriptDir\SQL\Warehousing_SP_StockReplenishment.sql" , $clients , $Threads ,$LimitType , $LimitAmount,  $paths,$ShowPGBenchProgress, $ShowPGBenchProgressInterval, $CapturePGBenchLog)
                $env:PGPASSWORD = $pass; $env:PGAPPNAME=$paths; Start-Process -FilePath $PgBenchExe -WorkingDirectory $OutputFolder -WindowStyle $PGBench_WindowsStyle -ArgumentList $arguments
                # usp_ProductMovementLog
                $paths = 'PGBench_Warehousing_ProductMovementLog'
                $OutputFolder = Get-ResultsFolder @($paths, "Y")
                $arguments = Get-Argument_PGBench($srv, $port, $user, $database , "$scriptDir\SQL\Warehousing_SP_ProductMovementLog.sql" , $clients , $Threads ,$LimitType , $LimitAmount,  $paths,$ShowPGBenchProgress, $ShowPGBenchProgressInterval, $CapturePGBenchLog)
                $env:PGPASSWORD = $pass; $env:PGAPPNAME=$paths; Start-Process -FilePath $PgBenchExe -WorkingDirectory $OutputFolder -WindowStyle $PGBench_WindowsStyle -ArgumentList $arguments
                # usp_LowStockAlert
                $paths = 'PGBench_Warehousing_LowStockAlert'
                $OutputFolder = Get-ResultsFolder @($paths, "Y")
                $arguments = Get-Argument_PGBench($srv, $port, $user, $database , "$scriptDir\SQL\Warehousing_SP_LowStockAlert.sql" , $clients , $Threads ,$LimitType , $LimitAmount,  $paths,$ShowPGBenchProgress, $ShowPGBenchProgressInterval, $CapturePGBenchLog)
                $env:PGPASSWORD = $pass; $env:PGAPPNAME=$paths; Start-Process -FilePath $PgBenchExe -WorkingDirectory $OutputFolder -WindowStyle $PGBench_WindowsStyle -ArgumentList $arguments
                # usp_WarehouseCapacityCheck
                $paths = 'PGBench_Warehousing_WarehouseCapacityCheck'
                $OutputFolder = Get-ResultsFolder @($paths, "Y")
                $arguments = Get-Argument_PGBench($srv, $port, $user, $database , "$scriptDir\SQL\Warehousing_SP_WarehouseCapacityCheck.sql" , $clients , $Threads ,$LimitType , $LimitAmount,  $paths,$ShowPGBenchProgress, $ShowPGBenchProgressInterval, $CapturePGBenchLog)
                $env:PGPASSWORD = $pass; $env:PGAPPNAME=$paths; Start-Process -FilePath $PgBenchExe -WorkingDirectory $OutputFolder -WindowStyle $PGBench_WindowsStyle -ArgumentList $arguments
                # usp_ProductLocationLookup
                $paths = 'PGBench_Warehousing_ProductLocationLookup'
                $OutputFolder = Get-ResultsFolder @($paths, "Y")
                $arguments = Get-Argument_PGBench($srv, $port, $user, $database , "$scriptDir\SQL\Warehousing_SP_ProductLocationLookup.sql" , $clients , $Threads ,$LimitType , $LimitAmount,  $paths,$ShowPGBenchProgress, $ShowPGBenchProgressInterval, $CapturePGBenchLog)
                $env:PGPASSWORD = $pass; $env:PGAPPNAME=$paths; Start-Process -FilePath $PgBenchExe -WorkingDirectory $OutputFolder -WindowStyle $PGBench_WindowsStyle -ArgumentList $arguments
                # usp_InventoryAgingReport
                $paths = 'PGBench_Warehousing_InventoryAgingReport'
                $OutputFolder = Get-ResultsFolder @($paths, "Y")
                $arguments = Get-Argument_PGBench($srv, $port, $user, $database , "$scriptDir\SQL\Warehousing_SP_InventoryAgingReport.sql" , $clients , $Threads ,$LimitType , $LimitAmount,  $paths,$ShowPGBenchProgress, $ShowPGBenchProgressInterval, $CapturePGBenchLog)
                $env:PGPASSWORD = $pass; $env:PGAPPNAME=$paths; Start-Process -FilePath $PgBenchExe -WorkingDirectory $OutputFolder -WindowStyle $PGBench_WindowsStyle -ArgumentList $arguments
                # usp_CycleCountAudit
                $paths = 'PGBench_Warehousing_CycleCountAudit'
                $OutputFolder = Get-ResultsFolder @($paths, "Y")
                $arguments = Get-Argument_PGBench($srv, $port, $user, $database , "$scriptDir\SQL\Warehousing_SP_CycleCountAudit.sql" , $clients , $Threads ,$LimitType , $LimitAmount,  $paths,$ShowPGBenchProgress, $ShowPGBenchProgressInterval, $CapturePGBenchLog)
                $env:PGPASSWORD = $pass; $env:PGAPPNAME=$paths; Start-Process -FilePath $PgBenchExe -WorkingDirectory $OutputFolder -WindowStyle $PGBench_WindowsStyle -ArgumentList $arguments
                # usp_ReceivingLog
                $paths = 'PGBench_Warehousing_ReceivingLog'
                $OutputFolder = Get-ResultsFolder @($paths, "Y")
                $arguments = Get-Argument_PGBench($srv, $port, $user, $database , "$scriptDir\SQL\Warehousing_SP_ReceivingLog.sql" , $clients , $Threads ,$LimitType , $LimitAmount,  $paths,$ShowPGBenchProgress, $ShowPGBenchProgressInterval, $CapturePGBenchLog)
                $env:PGPASSWORD = $pass; $env:PGAPPNAME=$paths; Start-Process -FilePath $PgBenchExe -WorkingDirectory $OutputFolder -WindowStyle $PGBench_WindowsStyle -ArgumentList $arguments
                # usp_ShippingLog
                $paths = 'PGBench_Warehousing_ShippingLog'
                $OutputFolder = Get-ResultsFolder @($paths, "Y")
                $arguments = Get-Argument_PGBench($srv, $port, $user, $database , "$scriptDir\SQL\Warehousing_SP_ShippingLog.sql" , $clients , $Threads ,$LimitType , $LimitAmount,  $paths,$ShowPGBenchProgress, $ShowPGBenchProgressInterval, $CapturePGBenchLog)
                $env:PGPASSWORD = $pass; $env:PGAPPNAME=$paths; Start-Process -FilePath $PgBenchExe -WorkingDirectory $OutputFolder -WindowStyle $PGBench_WindowsStyle -ArgumentList $arguments
            }

        'O' { # 'O for Warehousing via Adhoc Queries'
                # setup
                # add 'R' for receive operations, add 'T' for transfer operations, add 'S' for shipping operations, add 'I' for inventory operations, add 'C' for capacity operations
                $ArgsPsqlExe = Get-Argument_PSQL @($srv, $port, $user, $database)
                #$env:PGPASSWORD = $pass; 
                $PgPassPath = New-PgPassFile @($srv, $port, $database, $user, $pass)
                
                #$PsqlExe @ArgsPsqlExe -f "$scriptDir\SQL\AdventureWorks_CPU - setup.sql"
                & $PsqlExe @ArgsPsqlExe --set=ON_ERROR_STOP=1 -f "$scriptDir\SQL\warehousing_setup.sql"
                
                # after executing psql destroy the pgpass.conf file
                if (Test-Path -LiteralPath $PgPassPath) {
                    Remove-Item -LiteralPath $PgPassPath -Verbose 
                }


                # warehousing_adhoc_inventory_lookup
                $paths = 'PGBench_Warehousing_Adhoc_InventoryLookup'
                $OutputFolder = Get-ResultsFolder @($paths, "Y")
                $arguments = Get-Argument_PGBench($srv, $port, $user, $database , "$scriptDir\SQL\warehousing_adhoc_inventory_lookup.sql" , $clients , $Threads ,$LimitType , $LimitAmount,  $paths,$ShowPGBenchProgress, $ShowPGBenchProgressInterval, $CapturePGBenchLog)
                $env:PGPASSWORD = $pass; $env:PGAPPNAME=$paths; Start-Process -FilePath $PgBenchExe -WorkingDirectory $OutputFolder -WindowStyle $PGBench_WindowsStyle -ArgumentList $arguments

                # warehousing_adhoc_stock_replenishment
                $paths = 'PGBench_Warehousing_Adhoc_StockReplenishment'
                $OutputFolder = Get-ResultsFolder @($paths, "Y")
                $arguments = Get-Argument_PGBench($srv, $port, $user, $database , "$scriptDir\SQL\warehousing_adhoc_stock_replenishment.sql" , $clients , $Threads ,$LimitType , $LimitAmount,  $paths,$ShowPGBenchProgress, $ShowPGBenchProgressInterval, $CapturePGBenchLog)
                $env:PGPASSWORD = $pass; $env:PGAPPNAME=$paths; Start-Process -FilePath $PgBenchExe -WorkingDirectory $OutputFolder -WindowStyle $PGBench_WindowsStyle -ArgumentList $arguments

                # warehousing_adhoc_product_movement_log
                $paths = 'PGBench_Warehousing_Adhoc_ProductMovementLog'
                $OutputFolder = Get-ResultsFolder @($paths, "Y")
                $arguments = Get-Argument_PGBench($srv, $port, $user, $database , "$scriptDir\SQL\warehousing_adhoc_product_movement_log.sql" , $clients , $Threads ,$LimitType , $LimitAmount,  $paths,$ShowPGBenchProgress, $ShowPGBenchProgressInterval, $CapturePGBenchLog)
                $env:PGPASSWORD = $pass; $env:PGAPPNAME=$paths; Start-Process -FilePath $PgBenchExe -WorkingDirectory $OutputFolder -WindowStyle $PGBench_WindowsStyle -ArgumentList $arguments

                # warehousing_adhoc_low_stock_alert
                $paths = 'PGBench_Warehousing_Adhoc_LowStockAlert'
                $OutputFolder = Get-ResultsFolder @($paths, "Y")
                $arguments = Get-Argument_PGBench($srv, $port, $user, $database , "$scriptDir\SQL\warehousing_adhoc_low_stock_alert.sql" , $clients , $Threads ,$LimitType , $LimitAmount,  $paths,$ShowPGBenchProgress, $ShowPGBenchProgressInterval, $CapturePGBenchLog)
                $env:PGPASSWORD = $pass; $env:PGAPPNAME=$paths; Start-Process -FilePath $PgBenchExe -WorkingDirectory $OutputFolder -WindowStyle $PGBench_WindowsStyle -ArgumentList $arguments

                # warehousing_adhoc_warehouse_capacity_check
                $paths = 'PGBench_Warehousing_Adhoc_WarehouseCapacityCheck'
                $OutputFolder = Get-ResultsFolder @($paths, "Y")
                $arguments = Get-Argument_PGBench($srv, $port, $user, $database , "$scriptDir\SQL\warehousing_adhoc_warehouse_capacity_check.sql" , $clients , $Threads ,$LimitType , $LimitAmount,  $paths,$ShowPGBenchProgress, $ShowPGBenchProgressInterval, $CapturePGBenchLog)
                $env:PGPASSWORD = $pass; $env:PGAPPNAME=$paths; Start-Process -FilePath $PgBenchExe -WorkingDirectory $OutputFolder -WindowStyle $PGBench_WindowsStyle -ArgumentList $arguments

                # warehousing_adhoc_product_location_lookup
                $paths = 'PGBench_Warehousing_Adhoc_ProductLocationLookup'
                $OutputFolder = Get-ResultsFolder @($paths, "Y")
                $arguments = Get-Argument_PGBench($srv, $port, $user, $database , "$scriptDir\SQL\warehousing_adhoc_product_location_lookup.sql" , $clients , $Threads ,$LimitType , $LimitAmount,  $paths,$ShowPGBenchProgress, $ShowPGBenchProgressInterval, $CapturePGBenchLog)
                $env:PGPASSWORD = $pass; $env:PGAPPNAME=$paths; Start-Process -FilePath $PgBenchExe -WorkingDirectory $OutputFolder -WindowStyle $PGBench_WindowsStyle -ArgumentList $arguments

                # warehousing_adhoc_inventory_aging_report
                $paths = 'PGBench_Warehousing_Adhoc_InventoryAgingReport'
                $OutputFolder = Get-ResultsFolder @($paths, "Y")
                $arguments = Get-Argument_PGBench($srv, $port, $user, $database , "$scriptDir\SQL\warehousing_adhoc_inventory_aging_report.sql" , $clients , $Threads ,$LimitType , $LimitAmount,  $paths,$ShowPGBenchProgress, $ShowPGBenchProgressInterval, $CapturePGBenchLog)
                $env:PGPASSWORD = $pass; $env:PGAPPNAME=$paths; Start-Process -FilePath $PgBenchExe -WorkingDirectory $OutputFolder -WindowStyle $PGBench_WindowsStyle -ArgumentList $arguments

                # warehousing_adhoc_cycle_count_audit
                $paths = 'PGBench_Warehousing_Adhoc_CycleCountAudit'
                $OutputFolder = Get-ResultsFolder @($paths, "Y")
                $arguments = Get-Argument_PGBench($srv, $port, $user, $database , "$scriptDir\SQL\warehousing_adhoc_cycle_count_audit.sql" , $clients , $Threads ,$LimitType , $LimitAmount,  $paths,$ShowPGBenchProgress, $ShowPGBenchProgressInterval, $CapturePGBenchLog)
                $env:PGPASSWORD = $pass; $env:PGAPPNAME=$paths; Start-Process -FilePath $PgBenchExe -WorkingDirectory $OutputFolder -WindowStyle $PGBench_WindowsStyle -ArgumentList $arguments

                # warehousing_adhoc_receiving_log
                $paths = 'PGBench_Warehousing_Adhoc_ReceivingLog'
                $OutputFolder = Get-ResultsFolder @($paths, "Y")
                $arguments = Get-Argument_PGBench($srv, $port, $user, $database , "$scriptDir\SQL\warehousing_adhoc_receiving_log.sql" , $clients , $Threads ,$LimitType , $LimitAmount,  $paths,$ShowPGBenchProgress, $ShowPGBenchProgressInterval, $CapturePGBenchLog)
                $env:PGPASSWORD = $pass; $env:PGAPPNAME=$paths; Start-Process -FilePath $PgBenchExe -WorkingDirectory $OutputFolder -WindowStyle $PGBench_WindowsStyle -ArgumentList $arguments

                # warehousing_adhoc_shipping_log
                $paths = 'PGBench_Warehousing_Adhoc_ShippingLog'
                $OutputFolder = Get-ResultsFolder @($paths, "Y")
                $arguments = Get-Argument_PGBench($srv, $port, $user, $database , "$scriptDir\SQL\warehousing_adhoc_shipping_log.sql" , $clients , $Threads ,$LimitType , $LimitAmount,  $paths,$ShowPGBenchProgress, $ShowPGBenchProgressInterval, $CapturePGBenchLog)
                $env:PGPASSWORD = $pass; $env:PGAPPNAME=$paths; Start-Process -FilePath $PgBenchExe -WorkingDirectory $OutputFolder -WindowStyle $PGBench_WindowsStyle -ArgumentList $arguments
            }
        }

       # check to show LOG
        if ($chkbox_CapturePGBenchLog.checked) {
            # pgbench log filename patterns:
            #   thread 0: pgbench_log.<numeric>
            #   thread N: pgbench_log.<threadIndex>.<numeric>
            $pgbenchLogFiles = Get-ChildItem -Path $OutputFolder -File |
                Where-Object {
                    $_.Name -match '^pgbench_log\.\d+$' -or
                    $_.Name -match '^pgbench_log\.\d+\.\d+$'
                } |
                Sort-Object Name

            if (Test-Path -LiteralPath "$OutputFolder\pgbench_console.log") {
                Start-Process notepad.exe -ArgumentList "`"$OutputFolder\pgbench_console.log`""
            }

            if (Test-Path -LiteralPath "$OutputFolder\pgbench_error.log") {
                Start-Process notepad.exe -ArgumentList "`"$OutputFolder\pgbench_error.log`""
            }

            $firstLogFile = $pgbenchLogFiles | Select-Object -First 1
            if ($firstLogFile) {
                Start-Process notepad.exe -ArgumentList "`"$($firstLogFile.FullName)`""
            }
        }

        # check to show PGSTATS after  run
        if ($chkbox_Show_PG_Stats_AfterRun.checked) {
            # ----------------------------------------------------
            # show PG_STATS after execution
            # ----------------------------------------------------
            
            $ArgsPsqlExe = @(
            "-h", $srv,
            "-p", $port,
            "-U", $user,
            "-d", $database
            )
            & $PsqlExe @ArgsPsqlExe `
                -c "
                SELECT
                calls,
                total_exec_time,
                mean_exec_time,
                max_exec_time,
                query
                FROM pg_stat_statements
                ORDER BY total_exec_time DESC
                LIMIT 50;
                " |
                Out-File "$OutputFolder\pg_stat_statements.txt"
                # open pg_stat_statements
                NOTEPAD "$OutputFolder\pg_stat_statements.txt"

 
            # # # # --------------------------------------------------------------------------------------------------------
            # # # # show PG_ACTIVITIES after execution
            # # # # --------------------------------------------------------------------------------------------------------
            # # # # this query is only good while the workload is running, otherwise it will return nothing
            # # # # --------------------------------------------------------------------------------------------------------
            $ArgsPsqlExe = @(
            "-h", $srv,
            "-p", $port,
            "-U", $user,
            "-d", $database
            )
            & $PsqlExe @ArgsPsqlExe `
                -c "
                SELECT
                    pid,
                    usename,
                    application_name,
                    client_addr,
                    client_port,
                    backend_start,
                    state,
                    query
                FROM pg_stat_activity
                WHERE application_name = '" + '%PGBench%' + "'
                ORDER BY backend_start DESC;
                " |
                Out-File "$OutputFolder\pg_stat_activities.txt"
                # open pg_stat_activities
                NOTEPAD "$OutputFolder\pg_stat_activities.txt"


        }   
    }
}