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
