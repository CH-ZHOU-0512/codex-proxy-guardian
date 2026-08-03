[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'CodexProxyGuardian'),
    [switch]$KeepLogs
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$resolvedRoot = [System.IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
$markerPath = Join-Path $resolvedRoot '.cpg-install.json'
if (-not (Test-Path -LiteralPath $resolvedRoot)) {
    return [pscustomobject]@{ Uninstalled = $true; AlreadyAbsent = $true; RemovedPath = $resolvedRoot; SystemProxyModified = $false }
}
if (-not (Test-Path -LiteralPath $markerPath)) {
    throw "Refusing to remove an unmarked directory: $resolvedRoot"
}

try { $marker = Get-Content -Raw -LiteralPath $markerPath | ConvertFrom-Json }
catch { throw "Refusing to remove a directory with an invalid installation marker: $markerPath" }

if ([string]$marker.productId -ne 'CodexProxyGuardian') { throw "Unexpected product marker in: $markerPath" }
$markedRoot = [System.IO.Path]::GetFullPath([string]$marker.installRoot).TrimEnd('\')
if (-not [string]::Equals($markedRoot, $resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Installation marker path mismatch. Requested '$resolvedRoot', marker says '$markedRoot'."
}

$taskName = [string]$marker.taskName
$runValueName = [string]$marker.runValueName
$shortcutPath = [string]$marker.shortcutPath
$settingsShortcutProperty = $marker.PSObject.Properties['settingsShortcutPath']
$settingsShortcutPath = if ($null -eq $settingsShortcutProperty) { '' } else { [string]$settingsShortcutProperty.Value }
$updateTaskProperty = $marker.PSObject.Properties['updateTaskName']
$updateTaskName = if ($null -eq $updateTaskProperty) { '' } else { [string]$updateTaskProperty.Value }
$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($null -ne $task) {
    $expectedWatcher = Join-Path $resolvedRoot 'Watch-CodexProxy.ps1'
    $ownedAction = @($task.Actions | Where-Object {
        ([string]$_.Arguments).IndexOf($expectedWatcher, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
    }).Count -gt 0
    if (-not $ownedAction) { throw "Refusing to unregister scheduled task '$taskName' because its action is not owned by '$resolvedRoot'." }
}

$updateTask = if ([string]::IsNullOrWhiteSpace($updateTaskName)) { $null } else { Get-ScheduledTask -TaskName $updateTaskName -ErrorAction SilentlyContinue }
if ($null -ne $updateTask) {
    $expectedUpdater = Join-Path $resolvedRoot 'Update.ps1'
    $ownedUpdateAction = @($updateTask.Actions | Where-Object {
        ([string]$_.Arguments).IndexOf($expectedUpdater, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
    }).Count -gt 0
    if (-not $ownedUpdateAction) { throw "Refusing to unregister scheduled task '$updateTaskName' because it is not owned by '$resolvedRoot'." }
}

if (-not $PSCmdlet.ShouldProcess($resolvedRoot, 'Uninstall Codex Proxy Guardian and remove its files')) { return }

$statusPath = Join-Path $resolvedRoot 'status.json'
$guardianPid = 0
if (Test-Path -LiteralPath $statusPath) {
    try { $guardianPid = [int](Get-Content -Raw -LiteralPath $statusPath | ConvertFrom-Json).guardianPid } catch { $guardianPid = 0 }
}
New-Item -ItemType File -Path (Join-Path $resolvedRoot 'stop.request') -Force | Out-Null

if ($null -ne $task) {
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}
if ($null -ne $updateTask) {
    Stop-ScheduledTask -TaskName $updateTaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $updateTaskName -Confirm:$false
}

$deadline = (Get-Date).AddSeconds(20)
while ($guardianPid -gt 0 -and $null -ne (Get-Process -Id $guardianPid -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 250
}

$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
if (-not [string]::IsNullOrWhiteSpace($runValueName)) {
    $runItem = Get-ItemProperty -LiteralPath $runKey -ErrorAction SilentlyContinue
    $runProperty = if ($null -eq $runItem) { $null } else { $runItem.PSObject.Properties[$runValueName] }
    $runValue = if ($null -eq $runProperty) { $null } else { [string]$runProperty.Value }
    $expectedRunScript = Join-Path $resolvedRoot 'Run-Guardian.vbs'
    if ($null -ne $runValue -and ([string]$runValue).IndexOf($expectedRunScript, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
        Remove-ItemProperty -LiteralPath $runKey -Name $runValueName -ErrorAction SilentlyContinue
    }
}

if (-not [string]::IsNullOrWhiteSpace($shortcutPath) -and (Test-Path -LiteralPath $shortcutPath)) {
    $shortcutOwned = $false
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $expectedShortcutScript = Join-Path $resolvedRoot 'Run-ManagedCodex.vbs'
        $shortcutOwned = (([string]$shortcut.Arguments).IndexOf($expectedShortcutScript, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
    }
    catch { $shortcutOwned = $false }
    if ($shortcutOwned) { Remove-Item -LiteralPath $shortcutPath -Force }
    else { Write-Warning "The recorded shortcut was not removed because it no longer points to this installation: $shortcutPath" }
}

if (-not [string]::IsNullOrWhiteSpace($settingsShortcutPath) -and (Test-Path -LiteralPath $settingsShortcutPath)) {
    $settingsShortcutOwned = $false
    try {
        $shell = New-Object -ComObject WScript.Shell
        $settingsShortcut = $shell.CreateShortcut($settingsShortcutPath)
        $expectedSettingsScript = Join-Path $resolvedRoot 'Settings.ps1'
        $settingsShortcutOwned = (([string]$settingsShortcut.Arguments).IndexOf($expectedSettingsScript, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
    }
    catch { $settingsShortcutOwned = $false }
    if ($settingsShortcutOwned) { Remove-Item -LiteralPath $settingsShortcutPath -Force }
    else { Write-Warning "The recorded settings shortcut was not removed because it no longer points to this installation: $settingsShortcutPath" }
}

$keptLogsPath = $null
if ($KeepLogs -and (Test-Path -LiteralPath (Join-Path $resolvedRoot 'logs'))) {
    $keptLogsPath = Join-Path $env:LOCALAPPDATA ("CodexProxyGuardian-logs-{0}-{1}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'), [Guid]::NewGuid().ToString('N').Substring(0, 8))
    Move-Item -LiteralPath (Join-Path $resolvedRoot 'logs') -Destination $keptLogsPath
}

$currentLocationPath = [System.IO.Path]::GetFullPath((Get-Location).Path).TrimEnd('\')
$locationIsInsideInstall = [string]::Equals($currentLocationPath, $resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase) -or `
    $currentLocationPath.StartsWith($resolvedRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)
if ($locationIsInsideInstall) { Set-Location -LiteralPath $env:TEMP }
Remove-Item -LiteralPath $resolvedRoot -Recurse -Force

[pscustomobject]@{
    Uninstalled = $true
    AlreadyAbsent = $false
    RemovedPath = $resolvedRoot
    RemovedTask = if ($null -eq $task) { $null } else { $taskName }
    RemovedUpdateTask = if ($null -eq $updateTask) { $null } else { $updateTaskName }
    RemovedShortcut = if ([string]::IsNullOrWhiteSpace($shortcutPath)) { $null } else { $shortcutPath }
    RemovedSettingsShortcut = if ([string]::IsNullOrWhiteSpace($settingsShortcutPath)) { $null } else { $settingsShortcutPath }
    KeptLogsPath = $keptLogsPath
    SystemProxyModified = $false
}
