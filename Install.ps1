[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'CodexProxyGuardian'),
    [ValidateSet('Safe', 'Enforce')][string]$Mode = 'Safe',
    [ValidateNotNullOrEmpty()][string]$TaskName = 'Codex Proxy Guardian',
    [ValidateNotNullOrEmpty()][string]$RunValueName = 'CodexProxyGuardian',
    [ValidateNotNullOrEmpty()][string]$ShortcutName = 'Codex (Managed Proxy).lnk',
    [ValidateNotNullOrEmpty()][string]$SettingsShortcutName = 'Codex Proxy Guardian Settings.lnk',
    [ValidateNotNullOrEmpty()][string]$UpdateTaskName = 'Codex Proxy Guardian Update',
    [switch]$AllowMissingCodex,
    [switch]$RequireConnectivity,
    [switch]$SkipConnectivityCheck,
    [switch]$NoShortcut,
    [switch]$NoStart,
    [switch]$PreserveUpdateTask,
    [switch]$AutomaticUpdate,
    [switch]$PreflightOnly,
    [switch]$ProgressProtocol
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$sourceRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$coreModule = Join-Path $sourceRoot 'src\CodexProxyGuardian.Core.psm1'
$defaultConfigPath = Join-Path $sourceRoot 'config\default-config.json'
$version = (Get-Content -Raw -LiteralPath (Join-Path $sourceRoot 'VERSION')).Trim()
$markerName = '.cpg-install.json'
$resolvedRoot = [System.IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
$powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$wscriptPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

function Read-ExistingMarker {
    param([string]$Root)
    $path = Join-Path $Root $markerName
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { return Get-Content -Raw -LiteralPath $path | ConvertFrom-Json }
    catch { throw "The installation marker is invalid: $path" }
}

function Test-MarkerMatchesRoot {
    param($Marker, [string]$Root)
    if ($null -eq $Marker -or [string]$Marker.productId -ne 'CodexProxyGuardian') { return $false }
    $markedRoot = [System.IO.Path]::GetFullPath([string]$Marker.installRoot).TrimEnd('\')
    return [string]::Equals($markedRoot, $Root, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-RunValue {
    param([string]$Name)
    $item = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $null }
    $property = $item.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return [string]$property.Value
}

function Write-CpgInstallProgress {
    param(
        [ValidateRange(0, 100)][int]$Percent,
        [ValidateNotNullOrEmpty()][string]$Message
    )
    if (-not $ProgressProtocol) { return }
    $safeMessage = ($Message -replace '[\r\n|]', ' ').Trim()
    [Console]::Out.WriteLine(('CPG_PROGRESS|{0}|{1}' -f $Percent, $safeMessage))
}

function Test-CpgAutomaticUpdateParent {
    try {
        $currentProcess = Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f $PID) -ErrorAction Stop
        if ($null -eq $currentProcess -or [int]$currentProcess.ParentProcessId -le 0) { return $false }
        $parentProcess = Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f [int]$currentProcess.ParentProcessId) -ErrorAction Stop
        if ($null -eq $parentProcess) { return $false }
        $parentCommandLine = [string]$parentProcess.CommandLine
        return $parentCommandLine.IndexOf('Update.ps1', [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -and `
            $parentCommandLine -match '(?i)(?:^|\s)-Silent(?:\s|$)'
    }
    catch { return $false }
}

function Test-CpgInstalledGuardianAlive {
    param($Status, [ValidateNotNullOrEmpty()][string]$WatcherPath)
    if ($null -eq $Status) { return $false }
    $pidProperty = $Status.PSObject.Properties['guardianPid']
    if ($null -eq $pidProperty -or [int]$pidProperty.Value -le 0) { return $false }
    $guardianProcess = Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f [int]$pidProperty.Value) -ErrorAction SilentlyContinue
    return ($null -ne $guardianProcess -and (Test-CpgGuardianProcessIdentity -Process $guardianProcess -WatcherPath $WatcherPath))
}

if ($ProgressProtocol) {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
}
Write-CpgInstallProgress 30 'CheckingWindowsEnvironment'

if ($env:OS -ne 'Windows_NT') { throw 'Codex Proxy Guardian supports Windows only.' }
if ($PSVersionTable.PSVersion -lt [Version]'5.1') { throw 'Windows PowerShell 5.1 or later is required.' }
if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    throw "PowerShell FullLanguage mode is required. Current mode: $($ExecutionContext.SessionState.LanguageMode)."
}
foreach ($requiredPath in @($coreModule, $defaultConfigPath, $powershellPath, $wscriptPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) { throw "Missing required file: $requiredPath" }
}
Unblock-File -LiteralPath $coreModule -ErrorAction SilentlyContinue
foreach ($commandName in @('Get-AppxPackage', 'Get-AppxPackageManifest', 'Register-ScheduledTask', 'Get-CimInstance', 'Get-NetTCPConnection')) {
    if ($null -eq (Get-Command $commandName -ErrorAction SilentlyContinue)) { throw "Missing required Windows command: $commandName" }
}
Write-CpgInstallProgress 34 'CheckingCodexAndComponents'

$policyList = @(Get-ExecutionPolicy -List)
$groupPolicy = $policyList | Where-Object { $_.Scope -in @('MachinePolicy', 'UserPolicy') -and $_.ExecutionPolicy -notin @('Undefined', 'Bypass', 'Unrestricted', 'RemoteSigned') } | Select-Object -First 1
if ($null -ne $groupPolicy) {
    throw "PowerShell Group Policy '$($groupPolicy.ExecutionPolicy)' at scope '$($groupPolicy.Scope)' can block the unsigned guardian scripts. Ask your administrator to approve/sign the project before installing."
}

$driveRoot = [System.IO.Path]::GetPathRoot($resolvedRoot).TrimEnd('\')
if ([string]::Equals($driveRoot, $resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'The installation root cannot be a drive root.'
}

$existingMarker = $null
if (Test-Path -LiteralPath $resolvedRoot) {
    $existingMarker = Read-ExistingMarker $resolvedRoot
    $existingItems = @(Get-ChildItem -LiteralPath $resolvedRoot -Force -ErrorAction SilentlyContinue)
    if ($existingItems.Count -gt 0 -and -not (Test-MarkerMatchesRoot $existingMarker $resolvedRoot)) {
        throw "Refusing to install over a non-empty directory that is not marked as Codex Proxy Guardian: $resolvedRoot"
    }
}

$previousInstalledVersion = ''
if (Test-MarkerMatchesRoot $existingMarker $resolvedRoot) {
    $existingVersionProperty = $existingMarker.PSObject.Properties['version']
    if ($null -ne $existingVersionProperty) { $previousInstalledVersion = ([string]$existingVersionProperty.Value).Trim() }
    if ([string]::IsNullOrWhiteSpace($previousInstalledVersion)) {
        $existingVersionPath = Join-Path $resolvedRoot 'VERSION'
        if (Test-Path -LiteralPath $existingVersionPath) {
            try { $previousInstalledVersion = (Get-Content -Raw -LiteralPath $existingVersionPath).Trim() } catch { $previousInstalledVersion = '' }
        }
    }
}
$versionChanged = -not [string]::IsNullOrWhiteSpace($previousInstalledVersion) -and $previousInstalledVersion -ne $version
$automaticUpdateInvocation = [bool]$AutomaticUpdate -or (Test-CpgAutomaticUpdateParent)

Import-Module $coreModule -Force
$defaultConfig = Get-Content -Raw -LiteralPath $defaultConfigPath | ConvertFrom-Json
$codexApp = Get-CpgCodexApp -Config $defaultConfig
if ($null -eq $codexApp -and -not $AllowMissingCodex) {
    throw 'The Store/MSIX Codex desktop app was not found for the current user. Install Codex first, or use -AllowMissingCodex for staging.'
}

$installedConfigPath = Join-Path $resolvedRoot 'config.json'
$prospectiveConfig = $defaultConfig | ConvertTo-Json -Depth 8 | ConvertFrom-Json
if ((Test-MarkerMatchesRoot $existingMarker $resolvedRoot) -and (Test-Path -LiteralPath $installedConfigPath)) {
    try { $prospectiveConfig = Get-Content -Raw -LiteralPath $installedConfigPath | ConvertFrom-Json }
    catch { throw "The installed configuration is invalid and was left untouched: $installedConfigPath" }
    $prospectiveConfig = Update-CpgConfigDefaults -Config $prospectiveConfig -Defaults $defaultConfig
    if ($PSBoundParameters.ContainsKey('Mode')) {
        $prospectiveConfig.Mode = $Mode
        $prospectiveConfig.ManageExternalCodexLaunches = ($Mode -eq 'Enforce')
    }
}
else {
    $prospectiveConfig.Mode = $Mode
    $prospectiveConfig.ManageExternalCodexLaunches = ($Mode -eq 'Enforce')
}

$existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($null -ne $existingTask -and -not (Test-MarkerMatchesRoot $existingMarker $resolvedRoot)) {
    throw "A scheduled task named '$TaskName' already exists and is not owned by this installation. Choose another -TaskName."
}
if ($null -ne $existingTask -and (Test-MarkerMatchesRoot $existingMarker $resolvedRoot)) {
    $expectedWatcher = Join-Path $resolvedRoot 'Watch-CodexProxy.ps1'
    $ownedAction = @($existingTask.Actions | Where-Object {
        ([string]$_.Arguments).IndexOf($expectedWatcher, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
    }).Count -gt 0
    if (-not $ownedAction) {
        throw "The existing scheduled task '$TaskName' no longer points to this installation. Refusing to overwrite it."
    }
}

$programs = [Environment]::GetFolderPath('Programs')
$shortcutPath = Join-Path $programs $ShortcutName
$settingsShortcutPath = Join-Path $programs $SettingsShortcutName
if ([System.IO.Path]::GetFileName($ShortcutName) -ne $ShortcutName -or -not $ShortcutName.EndsWith('.lnk', [System.StringComparison]::OrdinalIgnoreCase)) {
    throw '-ShortcutName must be a .lnk file name without directory components.'
}
if ([System.IO.Path]::GetFileName($SettingsShortcutName) -ne $SettingsShortcutName -or -not $SettingsShortcutName.EndsWith('.lnk', [System.StringComparison]::OrdinalIgnoreCase)) {
    throw '-SettingsShortcutName must be a .lnk file name without directory components.'
}
if (-not $NoShortcut -and (Test-Path -LiteralPath $shortcutPath) -and -not (Test-MarkerMatchesRoot $existingMarker $resolvedRoot)) {
    throw "A shortcut already exists and is not owned by this installation: $shortcutPath"
}
if (-not $NoShortcut -and (Test-Path -LiteralPath $settingsShortcutPath) -and -not (Test-MarkerMatchesRoot $existingMarker $resolvedRoot)) {
    throw "A settings shortcut already exists and is not owned by this installation: $settingsShortcutPath"
}

$existingUpdateTask = Get-ScheduledTask -TaskName $UpdateTaskName -ErrorAction SilentlyContinue
if ($null -ne $existingUpdateTask) {
    $expectedUpdater = Join-Path $resolvedRoot 'Update.ps1'
    $ownedUpdateAction = @($existingUpdateTask.Actions | Where-Object {
        ([string]$_.Arguments).IndexOf($expectedUpdater, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
    }).Count -gt 0
    if (-not (Test-MarkerMatchesRoot $existingMarker $resolvedRoot) -or -not $ownedUpdateAction) {
        throw "A scheduled task named '$UpdateTaskName' exists and is not owned by this installation."
    }
}
Write-CpgInstallProgress 38 'PreflightPassed'

$preflight = [pscustomobject]@{
    Ready = $true
    Version = $version
    InstallRoot = $resolvedRoot
    PowerShell = [string]$PSVersionTable.PSVersion
    LanguageMode = [string]$ExecutionContext.SessionState.LanguageMode
    CodexFound = ($null -ne $codexApp)
    CodexPackage = if ($null -eq $codexApp) { $null } else { $codexApp.PackageName }
    CodexVersion = if ($null -eq $codexApp) { $null } else { $codexApp.Version }
    ExistingInstall = (Test-MarkerMatchesRoot $existingMarker $resolvedRoot)
    SystemProxyWillBeModified = $false
}
if ($PreflightOnly) {
    Write-CpgInstallProgress 100 'PreflightComplete'
    return $preflight
}

if (-not $PSCmdlet.ShouldProcess($resolvedRoot, "Install Codex Proxy Guardian $version in $Mode mode")) { return }

$connectivityState = 'Skipped'
if (-not $SkipConnectivityCheck) {
    Write-CpgInstallProgress 40 'CheckingConnectivity'
    $stagingRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('CodexProxyGuardian-preflight-' + [Guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $sourceRoot 'src\CodexProxyGuardian.Core.psm1') -Destination (Join-Path $stagingRoot 'CodexProxyGuardian.Core.psm1')
        Copy-Item -LiteralPath (Join-Path $sourceRoot 'src\Watch-CodexProxy.ps1') -Destination (Join-Path $stagingRoot 'Watch-CodexProxy.ps1')
        Copy-Item -LiteralPath $defaultConfigPath -Destination (Join-Path $stagingRoot 'config.default.json')
        $prospectiveConfig | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $stagingRoot 'config.json') -Encoding UTF8
        $selfTestOutput = @(& $powershellPath -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $stagingRoot 'Watch-CodexProxy.ps1') -SelfTest 2>&1)
        $selfTestExit = $LASTEXITCODE
    }
    finally {
        if (Test-Path -LiteralPath $stagingRoot) { Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
    if ($selfTestExit -eq 0) { $connectivityState = 'Passed' }
    else {
        $connectivityState = "Warning (exit $selfTestExit)"
        $message = "Connectivity self-test did not pass. Installation can continue because proxies may be offline temporarily. Output: $($selfTestOutput -join ' ')"
        if ($RequireConnectivity) { throw $message }
        Write-Warning $message
    }
}
Write-CpgInstallProgress 48 'ConnectivityComplete'

Write-CpgInstallProgress 50 'PreparingUpgrade'
if (Test-MarkerMatchesRoot $existingMarker $resolvedRoot) {
    $oldStatusPath = Join-Path $resolvedRoot 'status.json'
    $expectedWatcher = Join-Path $resolvedRoot 'Watch-CodexProxy.ps1'
    $oldPid = 0
    if (Test-Path -LiteralPath $oldStatusPath) {
        try { $oldPid = [int](Get-Content -Raw -LiteralPath $oldStatusPath | ConvertFrom-Json).guardianPid } catch { $oldPid = 0 }
    }
    if ($oldPid -gt 0) {
        $statusProcess = Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f $oldPid) -ErrorAction SilentlyContinue
        if ($null -ne $statusProcess -and -not (Test-CpgGuardianProcessIdentity -Process $statusProcess -WatcherPath $expectedWatcher)) {
            Write-Warning "The previous guardian PID $oldPid has been reused by another process. The stale status will be replaced without terminating that process."
        }
    }
    New-Item -ItemType File -Path (Join-Path $resolvedRoot 'stop.request') -Force | Out-Null
    Start-Sleep -Seconds 1
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    $deadline = (Get-Date).AddSeconds(19)
    $ownedGuardianProcesses = @()
    do {
        $ownedGuardianProcesses = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
            Test-CpgGuardianProcessIdentity -Process $_ -WatcherPath $expectedWatcher
        })
        if ($ownedGuardianProcesses.Count -eq 0 -or (Get-Date) -ge $deadline) { break }
        Start-Sleep -Milliseconds 250
    } while ($true)
    foreach ($ownedProcess in $ownedGuardianProcesses) {
        if (Test-CpgGuardianProcessIdentity -Process $ownedProcess -WatcherPath $expectedWatcher) {
            Stop-Process -Id ([int]$ownedProcess.ProcessId) -Force -ErrorAction SilentlyContinue
        }
    }
    Remove-Item -LiteralPath (Join-Path $resolvedRoot 'stop.request') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $oldStatusPath -Force -ErrorAction SilentlyContinue
}
Write-CpgInstallProgress 56 'UpgradeReady'

Write-CpgInstallProgress 58 'CreatingInstallDirectory'
New-Item -ItemType Directory -Path $resolvedRoot -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $resolvedRoot 'logs') -Force | Out-Null

$marker = [ordered]@{
    productId = 'CodexProxyGuardian'
    markerSchema = 2
    version = $version
    installRoot = $resolvedRoot
    taskName = $TaskName
    runValueName = $RunValueName
    shortcutPath = if ($NoShortcut) { $null } else { $shortcutPath }
    settingsShortcutPath = if ($NoShortcut) { $null } else { $settingsShortcutPath }
    updateTaskName = $UpdateTaskName
    startupMode = $null
    startupError = $null
    updateTaskError = $null
    installedUtc = (Get-Date).ToUniversalTime().ToString('o')
    systemProxyModified = $false
    winHttpModified = $false
    userProxyEnvironmentModified = $false
}
$marker | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $resolvedRoot $markerName) -Encoding UTF8

$payload = [ordered]@{
    (Join-Path $sourceRoot 'src\CodexProxyGuardian.Core.psm1') = 'CodexProxyGuardian.Core.psm1'
    (Join-Path $sourceRoot 'src\Watch-CodexProxy.ps1') = 'Watch-CodexProxy.ps1'
    (Join-Path $sourceRoot 'src\Launch-CodexManaged.ps1') = 'Launch-CodexManaged.ps1'
    (Join-Path $sourceRoot 'src\Run-Guardian.vbs') = 'Run-Guardian.vbs'
    (Join-Path $sourceRoot 'src\Run-ManagedCodex.vbs') = 'Run-ManagedCodex.vbs'
    (Join-Path $sourceRoot 'Uninstall.ps1') = 'Uninstall.ps1'
    (Join-Path $sourceRoot 'Status.ps1') = 'Status.ps1'
    (Join-Path $sourceRoot 'Doctor.ps1') = 'Doctor.ps1'
    (Join-Path $sourceRoot 'Control.ps1') = 'Control.ps1'
    (Join-Path $sourceRoot 'Settings.ps1') = 'Settings.ps1'
    (Join-Path $sourceRoot 'Notify-Update.ps1') = 'Notify-Update.ps1'
    (Join-Path $sourceRoot 'Update.ps1') = 'Update.ps1'
    (Join-Path $sourceRoot 'LICENSE') = 'LICENSE'
    (Join-Path $sourceRoot 'VERSION') = 'VERSION'
    (Join-Path $sourceRoot 'config\config.schema.json') = 'config.schema.json'
}
$payloadIndex = 0
$payloadCount = [Math]::Max(1, $payload.Count)
foreach ($entry in $payload.GetEnumerator()) {
    if (-not (Test-Path -LiteralPath $entry.Key)) { throw "Missing installation payload: $($entry.Key)" }
    Copy-Item -LiteralPath $entry.Key -Destination (Join-Path $resolvedRoot $entry.Value) -Force
    $payloadIndex++
    $copyPercent = 60 + [int][Math]::Floor(($payloadIndex * 12.0) / $payloadCount)
    Write-CpgInstallProgress $copyPercent 'CopyingFiles'
}
Get-ChildItem -LiteralPath $resolvedRoot -File | Unblock-File -ErrorAction SilentlyContinue

$prospectiveConfig | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $installedConfigPath -Encoding UTF8
Copy-Item -LiteralPath $defaultConfigPath -Destination (Join-Path $resolvedRoot 'config.default.json') -Force
Write-CpgInstallProgress 74 'UpdatingConfiguration'

$startupMode = 'ScheduledTask'
$startupError = $null

Write-CpgInstallProgress 76 'RegisteringStartup'
try {
    $taskAction = New-ScheduledTaskAction -Execute $powershellPath -Argument ('-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f (Join-Path $resolvedRoot 'Watch-CodexProxy.ps1')) -WorkingDirectory $resolvedRoot
    $taskTrigger = New-ScheduledTaskTrigger -AtLogOn -User $identity
    $taskPrincipal = New-ScheduledTaskPrincipal -UserId $identity -LogonType Interactive -RunLevel Limited
    $taskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -RestartCount 50 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName $TaskName -Action $taskAction -Trigger $taskTrigger -Principal $taskPrincipal -Settings $taskSettings -Description 'Validates the active proxy and relaunches Codex after a stable endpoint change. Does not modify Windows proxy settings.' -Force | Out-Null

    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $existingRun = Get-RunValue $RunValueName
    $expectedRunScript = Join-Path $resolvedRoot 'Run-Guardian.vbs'
    if ($null -ne $existingRun -and ([string]$existingRun).IndexOf($expectedRunScript, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
        Remove-ItemProperty -LiteralPath $runKey -Name $RunValueName -ErrorAction SilentlyContinue
    }
}
catch {
    $startupMode = 'HKCU-Run-Fallback'
    $startupError = $_.Exception.Message
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $existingRun = Get-RunValue $RunValueName
    $expectedRunScript = Join-Path $resolvedRoot 'Run-Guardian.vbs'
    if ($null -ne $existingRun -and ([string]$existingRun).IndexOf($expectedRunScript, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw "Scheduled Task registration failed, and HKCU Run value '$RunValueName' belongs to another program. Original error: $startupError"
    }
    $runCommand = '"{0}" "{1}"' -f $wscriptPath, (Join-Path $resolvedRoot 'Run-Guardian.vbs')
    New-ItemProperty -LiteralPath $runKey -Name $RunValueName -PropertyType String -Value $runCommand -Force | Out-Null
}
Write-CpgInstallProgress 80 'StartupRegistered'

$updateTaskError = $null
Write-CpgInstallProgress 82 'RegisteringUpdates'
try {
    if (-not ($PreserveUpdateTask -and $null -ne $existingUpdateTask)) {
        $updateAction = New-ScheduledTaskAction -Execute $powershellPath -Argument ('-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Install -Silent' -f (Join-Path $resolvedRoot 'Update.ps1')) -WorkingDirectory $resolvedRoot
        $updateTrigger = New-ScheduledTaskTrigger -Daily -At '12:00'
        $updatePrincipal = New-ScheduledTaskPrincipal -UserId $identity -LogonType Interactive -RunLevel Limited
        $updateSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 2)
        Register-ScheduledTask -TaskName $UpdateTaskName -Action $updateAction -Trigger $updateTrigger -Principal $updatePrincipal -Settings $updateSettings -Description 'Checks the project GitHub Releases, verifies the release SHA-256, and safely updates Codex Proxy Guardian.' -Force | Out-Null
    }
}
catch {
    $updateTaskError = $_.Exception.Message
    Write-Warning "Automatic update task registration failed. Manual updates remain available through Control.ps1. Error: $updateTaskError"
}
Write-CpgInstallProgress 85 'UpdatesRegistered'

Write-CpgInstallProgress 87 'CreatingShortcuts'
if (-not $NoShortcut) {
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $wscriptPath
    $shortcut.Arguments = '"{0}"' -f (Join-Path $resolvedRoot 'Run-ManagedCodex.vbs')
    $shortcut.WorkingDirectory = $resolvedRoot
    if ($null -ne $codexApp) { $shortcut.IconLocation = "$($codexApp.ExecutablePath),0" }
    $shortcut.Description = 'Launch Codex through Codex Proxy Guardian'
    $shortcut.Save()

    $settingsShortcut = $shell.CreateShortcut($settingsShortcutPath)
    $settingsShortcut.TargetPath = $powershellPath
    $settingsShortcut.Arguments = '-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f (Join-Path $resolvedRoot 'Settings.ps1')
    $settingsShortcut.WorkingDirectory = $resolvedRoot
    if ($null -ne $codexApp) { $settingsShortcut.IconLocation = "$($codexApp.ExecutablePath),0" }
    $settingsShortcut.Description = 'Configure Codex Proxy Guardian mode and automatic updates'
    $settingsShortcut.Save()
}
Write-CpgInstallProgress 90 'ShortcutsReady'

$marker.startupMode = $startupMode
$marker.startupError = $startupError
$marker.updateTaskError = $updateTaskError
$marker | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $resolvedRoot $markerName) -Encoding UTF8
Write-CpgInstallProgress 92 'WritingInstallConfiguration'

$runtimeStatus = $null
if (-not $NoStart) {
    Write-CpgInstallProgress 94 'StartingGuardian'
    $statusPath = Join-Path $resolvedRoot 'status.json'
    $installedWatcherPath = Join-Path $resolvedRoot 'Watch-CodexProxy.ps1'
    $codexWasRunning = $false
    Remove-Item -LiteralPath $statusPath -Force -ErrorAction SilentlyContinue
    if ($null -ne $codexApp) {
        $roots = @(Get-CimInstance Win32_Process -Filter ("Name='{0}'" -f $codexApp.ProcessName.Replace("'", "''")) -ErrorAction SilentlyContinue |
            Where-Object { Test-CpgCodexRootProcess -Process $_ -CodexApp $codexApp })
        $codexWasRunning = $roots.Count -gt 0
        if ($codexWasRunning) { New-Item -ItemType File -Path (Join-Path $resolvedRoot 'adopt-current-once.request') -Force | Out-Null }
    }

    for ($guardianStartAttempt = 1; $guardianStartAttempt -le 2; $guardianStartAttempt++) {
        if ($guardianStartAttempt -gt 1) {
            Write-CpgInstallProgress 98 'RetryingGuardian'
            Write-Warning 'Guardian exited during installation health verification. Retrying startup once.'
            if ($startupMode -eq 'ScheduledTask') {
                Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
            }
            $staleGuardianProcesses = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
                Test-CpgGuardianProcessIdentity -Process $_ -WatcherPath $installedWatcherPath
            })
            foreach ($staleGuardianProcess in $staleGuardianProcesses) {
                if (Test-CpgGuardianProcessIdentity -Process $staleGuardianProcess -WatcherPath $installedWatcherPath) {
                    Stop-Process -Id ([int]$staleGuardianProcess.ProcessId) -Force -ErrorAction SilentlyContinue
                }
            }
            Remove-Item -LiteralPath (Join-Path $resolvedRoot 'stop.request') -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $statusPath -Force -ErrorAction SilentlyContinue
            if ($codexWasRunning) { New-Item -ItemType File -Path (Join-Path $resolvedRoot 'adopt-current-once.request') -Force | Out-Null }
        }

        $runtimeStatus = $null
        if ($startupMode -eq 'ScheduledTask') { Start-ScheduledTask -TaskName $TaskName }
        else { Start-Process -FilePath $wscriptPath -ArgumentList ('"{0}"' -f (Join-Path $resolvedRoot 'Run-Guardian.vbs')) -WindowStyle Hidden }

        $deadline = (Get-Date).AddSeconds(40)
        $statusWaitStarted = Get-Date
        $lastRuntimeProgress = if ($guardianStartAttempt -gt 1) { 98 } else { 94 }
        do {
            if (Test-Path -LiteralPath $statusPath) {
                try { $runtimeStatus = Get-Content -Raw -LiteralPath $statusPath | ConvertFrom-Json } catch { $runtimeStatus = $null }
                if ($null -ne $runtimeStatus) {
                    $runtimeAlive = Test-CpgInstalledGuardianAlive -Status $runtimeStatus -WatcherPath $installedWatcherPath
                    if (-not $runtimeAlive -or [string]$runtimeStatus.guardianState -ne 'Stabilizing') { break }
                }
            }
            if ($guardianStartAttempt -eq 1) {
                $elapsedSeconds = ((Get-Date) - $statusWaitStarted).TotalSeconds
                $runtimeProgress = 94 + [int][Math]::Min(4, [Math]::Floor($elapsedSeconds / 10))
                if ($runtimeProgress -gt $lastRuntimeProgress) {
                    $lastRuntimeProgress = $runtimeProgress
                    Write-CpgInstallProgress $runtimeProgress 'WaitingForGuardian'
                }
            }
            Start-Sleep -Milliseconds 500
        } while ((Get-Date) -lt $deadline)

        if (Test-CpgInstalledGuardianAlive -Status $runtimeStatus -WatcherPath $installedWatcherPath) {
            break
        }
    }

    if (-not (Test-CpgInstalledGuardianAlive -Status $runtimeStatus -WatcherPath $installedWatcherPath)) {
        throw "Guardian did not remain running after two start attempts. Check: $resolvedRoot\logs"
    }
    if ([string]$runtimeStatus.guardianState -eq 'Stabilizing') {
        $statusMessage = "Guardian is running but did not finish stabilization within 40 seconds. Check: $resolvedRoot\logs"
        if ($RequireConnectivity) { throw $statusMessage }
        Write-Warning $statusMessage
    }
}
Write-CpgInstallProgress 99 'Finalizing'

$updateNotificationRequested = $false
if ($automaticUpdateInvocation -and $versionChanged -and [bool](Get-CpgConfigValue $prospectiveConfig 'NotifyAfterAutomaticUpdate' $true)) {
    $notifierPath = Join-Path $resolvedRoot 'Notify-Update.ps1'
    if (Test-Path -LiteralPath $notifierPath) {
        try {
            $safePreviousVersion = if ($previousInstalledVersion -match '^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$') { $previousInstalledVersion } else { '' }
            $notifierArguments = '-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -InstallRoot "{1}" -PreviousVersion "{2}" -InstalledVersion "{3}"' -f `
                $notifierPath, $resolvedRoot, $safePreviousVersion, $version
            Start-Process -FilePath $powershellPath -ArgumentList $notifierArguments -WindowStyle Hidden
            $updateNotificationRequested = $true
        }
        catch {
            Write-Warning "Guardian was updated, but the completion notification could not be started: $($_.Exception.Message)"
        }
    }
}

$effectiveConfig = Get-Content -Raw -LiteralPath $installedConfigPath | ConvertFrom-Json
$managedLaunchRecommended = $null -ne $runtimeStatus -and [bool]$runtimeStatus.codexRunning -and [bool]$runtimeStatus.activeProxyValid -and -not [bool]$runtimeStatus.codexProxyArgumentMatch
$effectiveMode = [string](Get-CpgConfigValue $effectiveConfig 'Mode' 'Safe')
$externalLaunchPolicy = if ($effectiveMode -eq 'Enforce' -or [bool](Get-CpgConfigValue $effectiveConfig 'ManageExternalCodexLaunches' $false)) {
    'Enforce'
} elseif ([bool](Get-CpgConfigValue $effectiveConfig 'SafeRepairExternalCodexLaunches' $true)) {
    if ([bool](Get-CpgConfigValue $effectiveConfig 'RequireManagedLaunchForStreaming' $true)) { 'SafeStreamingRepair' } else { 'SafeEvidenceRepair' }
} else {
    'ManagedShortcutOnly'
}
$nextStep = $null
if ($managedLaunchRecommended) {
    if ($externalLaunchPolicy -eq 'SafeStreamingRepair') {
        $nextStep = 'Safe mode found an ordinary Codex launch. HTTP traffic alone does not prove WebSocket proxy inheritance; finish the active task, then approve the guarded managed relaunch, or open "Codex (Managed Proxy)" when ready.'
    }
    elseif ($externalLaunchPolicy -eq 'SafeEvidenceRepair') {
        $nextStep = 'Safe mode is evaluating the current Codex launch. Leave the guardian running, or open "Codex (Managed Proxy)" to apply the validated proxy immediately.'
    }
    elseif ($externalLaunchPolicy -eq 'Enforce') {
        $nextStep = 'Enforce mode is waiting for its debounce and restart budget before correcting the current Codex launch.'
    }
    else {
        $nextStep = 'Open the Start Menu shortcut "Codex (Managed Proxy)" to apply the validated proxy to the current Codex session.'
    }
}
[pscustomobject]@{
    Installed = $true
    Version = $version
    InstallRoot = $resolvedRoot
    Mode = [string]$effectiveConfig.Mode
    StartupMode = $startupMode
    TaskName = if ($startupMode -eq 'ScheduledTask') { $TaskName } else { $null }
    UpdateTaskName = if ($null -eq $updateTaskError) { $UpdateTaskName } else { $null }
    ManagedShortcut = if ($NoShortcut) { $null } else { $shortcutPath }
    SettingsShortcut = if ($NoShortcut) { $null } else { $settingsShortcutPath }
    AutomaticUpdates = [bool](Get-CpgConfigValue $effectiveConfig 'AutomaticUpdates' $true)
    UpdateChannel = [string](Get-CpgConfigValue $effectiveConfig 'UpdateChannel' 'Stable')
    UpdateTaskPreserved = ($PreserveUpdateTask -and $null -ne $existingUpdateTask)
    ConnectivityCheck = $connectivityState
    GuardianState = if ($null -eq $runtimeStatus) { $null } else { [string]$runtimeStatus.guardianState }
    ActiveProxyValid = if ($null -eq $runtimeStatus) { $null } else { [bool]$runtimeStatus.activeProxyValid }
    EffectivenessEvidence = if ($null -eq $runtimeStatus) { $null } else { [string]$runtimeStatus.effectivenessEvidence }
    ExternalLaunchPolicy = $externalLaunchPolicy
    ManagedLaunchRecommended = $managedLaunchRecommended
    NextStep = $nextStep
    SystemProxyModified = $false
    UpdateNotificationRequested = $updateNotificationRequested
}
