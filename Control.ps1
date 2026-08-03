[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Start', 'Stop', 'Restart', 'Status', 'Doctor', 'SetMode', 'ToggleMode', 'Configure', 'CheckUpdate', 'Update')][string]$Action = 'Status',
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'CodexProxyGuardian'),
    [ValidateSet('Auto', 'Safe', 'Strict', 'Enforce')][string]$Mode,
    [ValidateSet('Keep', 'On', 'Off')][string]$AutomaticUpdates = 'Keep',
    [ValidateSet('Keep', 'Stable', 'Prerelease')][string]$UpdateChannel = 'Keep',
    [switch]$Json,
    [switch]$Online
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$resolvedRoot = [System.IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
$markerPath = Join-Path $resolvedRoot '.cpg-install.json'
if (-not (Test-Path -LiteralPath $markerPath)) { throw "No marked Codex Proxy Guardian installation was found at: $resolvedRoot" }
$marker = Get-Content -Raw -LiteralPath $markerPath | ConvertFrom-Json
if ([string]$marker.productId -ne 'CodexProxyGuardian' -or -not [string]::Equals([System.IO.Path]::GetFullPath([string]$marker.installRoot).TrimEnd('\'), $resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'The installation marker does not match the requested path.'
}
$coreModule = Join-Path $resolvedRoot 'CodexProxyGuardian.Core.psm1'
if (-not (Test-Path -LiteralPath $coreModule)) { throw "The installed core module is missing: $coreModule" }
Import-Module $coreModule -Force

function Get-OwnedScheduledTask {
    $task = Get-ScheduledTask -TaskName ([string]$marker.taskName) -ErrorAction Stop
    $expectedWatcher = Join-Path $resolvedRoot 'Watch-CodexProxy.ps1'
    if (@($task.Actions | Where-Object { ([string]$_.Arguments).IndexOf($expectedWatcher, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 }).Count -eq 0) {
        throw 'The scheduled task action no longer belongs to this installation.'
    }
    return $task
}

function Stop-Guardian {
    if (-not $PSCmdlet.ShouldProcess($resolvedRoot, 'Stop the guardian process')) { return }
    $statusPath = Join-Path $resolvedRoot 'status.json'
    $expectedWatcher = Join-Path $resolvedRoot 'Watch-CodexProxy.ps1'
    New-Item -ItemType File -Path (Join-Path $resolvedRoot 'stop.request') -Force | Out-Null
    if ([string]$marker.startupMode -eq 'ScheduledTask') {
        [void](Get-OwnedScheduledTask)
        Stop-ScheduledTask -TaskName ([string]$marker.taskName) -ErrorAction SilentlyContinue
    }
    $deadline = (Get-Date).AddSeconds(20)
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
    Remove-Item -LiteralPath $statusPath -Force -ErrorAction SilentlyContinue
}

function Start-Guardian {
    if (-not $PSCmdlet.ShouldProcess($resolvedRoot, 'Start the guardian process')) { return }
    Remove-Item -LiteralPath (Join-Path $resolvedRoot 'stop.request') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $resolvedRoot 'status.json') -Force -ErrorAction SilentlyContinue
    if ([string]$marker.startupMode -eq 'ScheduledTask') {
        [void](Get-OwnedScheduledTask)
        Start-ScheduledTask -TaskName ([string]$marker.taskName)
    }
    else {
        $wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
        Start-Process -FilePath $wscript -ArgumentList ('"{0}"' -f (Join-Path $resolvedRoot 'Run-Guardian.vbs')) -WindowStyle Hidden
    }
    $statusPath = Join-Path $resolvedRoot 'status.json'
    $deadline = (Get-Date).AddSeconds(40)
    $status = $null
    do {
        if (Test-Path -LiteralPath $statusPath) {
            try { $status = Get-Content -Raw -LiteralPath $statusPath | ConvertFrom-Json } catch { $status = $null }
            if ($null -ne $status -and [string]$status.guardianState -ne 'Stabilizing') { break }
        }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    if ($null -eq $status) { throw 'The guardian did not publish status within 40 seconds.' }
    return [pscustomobject]@{
        Started = $true
        GuardianPid = [int]$status.guardianPid
        GuardianState = [string]$status.guardianState
        ModeProfile = if ([string]$status.mode -eq 'Enforce') { 'Strict' } else { 'Automatic' }
        ActiveProxyValid = [bool]$status.activeProxyValid
        EffectivenessEvidence = [string]$status.effectivenessEvidence
    }
}

function Write-ConfigurationAtomically {
    param($Config)

    $configPath = Join-Path $resolvedRoot 'config.json'
    $temporaryPath = Join-Path $resolvedRoot ("config.{0}.tmp" -f [Guid]::NewGuid().ToString('N'))
    $replacementBackupPath = Join-Path $resolvedRoot ("config.{0}.bak" -f [Guid]::NewGuid().ToString('N'))
    try {
        $Config | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
        [void](Get-Content -Raw -LiteralPath $temporaryPath | ConvertFrom-Json)
        if (Test-Path -LiteralPath $configPath) {
            [System.IO.File]::Replace($temporaryPath, $configPath, $replacementBackupPath, $true)
        }
        else {
            Move-Item -LiteralPath $temporaryPath -Destination $configPath
        }
    }
    finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $replacementBackupPath -Force -ErrorAction SilentlyContinue
    }
}

function Set-GuardianConfiguration {
    param(
        [string]$RequestedMode = '',
        [string]$RequestedAutomaticUpdates = 'Keep',
        [string]$RequestedUpdateChannel = 'Keep'
    )

    $configPath = Join-Path $resolvedRoot 'config.json'
    if (-not (Test-Path -LiteralPath $configPath)) { throw "The installed configuration is missing: $configPath" }
    $config = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
    $beforeProfile = Get-CpgModeProfile -Config $config
    $beforeMode = [string](Get-CpgConfigValue $config 'Mode' 'Safe')
    $beforeManageExternal = [bool](Get-CpgConfigValue $config 'ManageExternalCodexLaunches' $false)
    $beforeSafeRepair = [bool](Get-CpgConfigValue $config 'SafeRepairExternalCodexLaunches' $true)
    $beforeUpdates = [bool](Get-CpgConfigValue $config 'AutomaticUpdates' $true)
    $beforeChannel = [string](Get-CpgConfigValue $config 'UpdateChannel' 'Stable')

    if (-not [string]::IsNullOrWhiteSpace($RequestedMode)) {
        $config = Set-CpgModeProfile -Config $config -Profile $RequestedMode
    }
    if ($RequestedAutomaticUpdates -ne 'Keep') {
        $config | Add-Member -MemberType NoteProperty -Name AutomaticUpdates -Value ($RequestedAutomaticUpdates -eq 'On') -Force
    }
    if ($RequestedUpdateChannel -ne 'Keep') {
        $config | Add-Member -MemberType NoteProperty -Name UpdateChannel -Value $RequestedUpdateChannel -Force
    }

    $afterProfile = Get-CpgModeProfile -Config $config
    $afterMode = [string](Get-CpgConfigValue $config 'Mode' 'Safe')
    $afterManageExternal = [bool](Get-CpgConfigValue $config 'ManageExternalCodexLaunches' $false)
    $afterSafeRepair = [bool](Get-CpgConfigValue $config 'SafeRepairExternalCodexLaunches' $true)
    $afterUpdates = [bool](Get-CpgConfigValue $config 'AutomaticUpdates' $true)
    $afterChannel = [string](Get-CpgConfigValue $config 'UpdateChannel' 'Stable')
    $modeChanged = $beforeMode -ne $afterMode -or $beforeManageExternal -ne $afterManageExternal -or $beforeSafeRepair -ne $afterSafeRepair
    $changed = $modeChanged -or $beforeUpdates -ne $afterUpdates -or $beforeChannel -ne $afterChannel
    $applied = $false
    $guardianRestarted = $false
    $guardianReloadRequested = $false
    if ($changed -and $PSCmdlet.ShouldProcess((Join-Path $resolvedRoot 'config.json'), "Set mode to $afterProfile, automatic updates to $afterUpdates, and channel to $afterChannel")) {
        Write-ConfigurationAtomically -Config $config
        $applied = $true
        if ($modeChanged) {
            New-Item -ItemType File -Path (Join-Path $resolvedRoot 'config.reload.request') -Force | Out-Null
            $guardianReloadRequested = $true
        }
    }

    $currentStatus = $null
    $currentStatusPath = Join-Path $resolvedRoot 'status.json'
    if (Test-Path -LiteralPath $currentStatusPath) {
        try { $currentStatus = Get-Content -Raw -LiteralPath $currentStatusPath | ConvertFrom-Json } catch { $currentStatus = $null }
    }

    return [pscustomobject]@{
        Changed = $changed
        Applied = $applied
        ModeProfile = $afterProfile
        InternalMode = [string]$config.Mode
        AutomaticUpdates = $afterUpdates
        UpdateChannel = $afterChannel
        GuardianRestarted = $guardianRestarted
        GuardianReloadRequested = $guardianReloadRequested
        GuardianState = if ($null -eq $currentStatus) { $null } else { [string]$currentStatus.guardianState }
    }
}

switch ($Action) {
    'Start' { Start-Guardian }
    'Stop' { Stop-Guardian }
    'Restart' { Stop-Guardian; Start-Guardian }
    'Status' { & (Join-Path $resolvedRoot 'Status.ps1') -InstallRoot $resolvedRoot -Json:$Json }
    'Doctor' { & (Join-Path $resolvedRoot 'Doctor.ps1') -InstallRoot $resolvedRoot -Json:$Json -Online:$Online }
    'SetMode' {
        if ([string]::IsNullOrWhiteSpace($Mode)) { throw '-Mode Auto or -Mode Strict is required for SetMode.' }
        Set-GuardianConfiguration -RequestedMode $Mode
    }
    'ToggleMode' {
        $config = Get-Content -Raw -LiteralPath (Join-Path $resolvedRoot 'config.json') | ConvertFrom-Json
        $target = if ((Get-CpgModeProfile $config) -eq 'Strict') { 'Auto' } else { 'Strict' }
        Set-GuardianConfiguration -RequestedMode $target
    }
    'Configure' { Set-GuardianConfiguration -RequestedMode $Mode -RequestedAutomaticUpdates $AutomaticUpdates -RequestedUpdateChannel $UpdateChannel }
    'CheckUpdate' { & (Join-Path $resolvedRoot 'Update.ps1') -InstallRoot $resolvedRoot -CheckOnly -Json:$Json }
    'Update' { & (Join-Path $resolvedRoot 'Update.ps1') -InstallRoot $resolvedRoot -Install -Json:$Json }
}
