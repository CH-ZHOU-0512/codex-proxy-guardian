[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'CodexProxyGuardian'),
    [switch]$Online,
    [switch]$Json,
    [string]$ExportPath = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'SilentlyContinue'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$resolvedRoot = [System.IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
$installedCore = Join-Path $resolvedRoot 'CodexProxyGuardian.Core.psm1'
$repoCore = Join-Path $scriptRoot 'src\CodexProxyGuardian.Core.psm1'
$corePath = if (Test-Path -LiteralPath $repoCore) { $repoCore } else { $installedCore }
if (-not (Test-Path -LiteralPath $corePath)) { throw 'CodexProxyGuardian.Core.psm1 could not be found.' }
Import-Module $corePath -Force

function Get-SafeProperty {
    param($Object, [string]$Name, $Default)
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

$defaultConfigPath = if (Test-Path -LiteralPath (Join-Path $resolvedRoot 'config.default.json')) {
    Join-Path $resolvedRoot 'config.default.json'
} else {
    Join-Path $scriptRoot 'config\default-config.json'
}
$configPath = Join-Path $resolvedRoot 'config.json'
$config = if (Test-Path -LiteralPath $configPath) {
    Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
} elseif (Test-Path -LiteralPath $defaultConfigPath) {
    Get-Content -Raw -LiteralPath $defaultConfigPath | ConvertFrom-Json
} else { $null }
if ($null -ne $config -and (Test-Path -LiteralPath $defaultConfigPath)) {
    $defaults = Get-Content -Raw -LiteralPath $defaultConfigPath | ConvertFrom-Json
    $config = Update-CpgConfigDefaults -Config $config -Defaults $defaults
}

$markerPath = Join-Path $resolvedRoot '.cpg-install.json'
$marker = if (Test-Path -LiteralPath $markerPath) { Get-Content -Raw -LiteralPath $markerPath | ConvertFrom-Json } else { $null }
$markerValid = $false
if ($null -ne $marker) {
    try { $markerValid = Test-CpgInstallMarker -InstallRoot $resolvedRoot -Marker $marker } catch { $markerValid = $false }
}
$statusPath = Join-Path $resolvedRoot 'status.json'
$status = if (Test-Path -LiteralPath $statusPath) { Get-Content -Raw -LiteralPath $statusPath | ConvertFrom-Json } else { $null }
$updateStatusPath = Join-Path $resolvedRoot 'update-status.json'
$updateStatus = if (Test-Path -LiteralPath $updateStatusPath) { Get-Content -Raw -LiteralPath $updateStatusPath | ConvertFrom-Json } else { $null }
$task = if ($markerValid) { Get-ScheduledTask -TaskName ([string]$marker.taskName) -ErrorAction SilentlyContinue } else { $null }
$updateTaskProperty = if (-not $markerValid) { $null } else { $marker.PSObject.Properties['updateTaskName'] }
$updateTaskName = if ($null -eq $updateTaskProperty) { 'Codex Proxy Guardian Update' } else { [string]$updateTaskProperty.Value }
$updateTask = if ($markerValid) { Get-ScheduledTask -TaskName $updateTaskName -ErrorAction SilentlyContinue } else { $null }
$updateTaskInfo = if ($null -eq $updateTask) { $null } else { Get-ScheduledTaskInfo -TaskName $updateTaskName -ErrorAction SilentlyContinue }
$updateTaskHasRun = $null -ne $updateTaskInfo -and $updateTaskInfo.LastRunTime.Year -ge 2001

$os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
$computer = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
$codexApp = if ($null -eq $config) { $null } else { Get-CpgCodexApp -Config $config }
$internetSettings = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
$proxyEnabled = [int](Get-SafeProperty $internetSettings 'ProxyEnable' 0) -eq 1
$rawProxy = [string](Get-SafeProperty $internetSettings 'ProxyServer' '')
$manualEndpoints = @(if ($null -eq $config) { @() } else {
    @(ConvertFrom-CpgProxyServer -ProxyServer $rawProxy -AllowNonLoopback:([bool](Get-CpgConfigValue $config 'AllowNonLoopbackProxy' $false)))
})
$pacUrlPresent = -not [string]::IsNullOrWhiteSpace([string](Get-SafeProperty $internetSettings 'AutoConfigURL' ''))

$environmentProxyNames = @()
foreach ($name in @('HTTPS_PROXY', 'https_proxy', 'HTTP_PROXY', 'http_proxy', 'ALL_PROXY', 'all_proxy')) {
    if (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name, 'Process'))) { $environmentProxyNames += $name }
}

$recognizedListeners = @()
if ($null -ne $config) {
    foreach ($connection in @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue)) {
        $process = Get-Process -Id $connection.OwningProcess -ErrorAction SilentlyContinue
        if ($null -eq $process) { continue }
        $matched = $false
        foreach ($pattern in @(Get-CpgConfigValue $config 'PreferredProxyProcesses' @())) {
            if ($process.ProcessName -like [string]$pattern) { $matched = $true; break }
        }
        if (-not $matched) { continue }
        $address = [string]$connection.LocalAddress
        if ($address -in @('0.0.0.0', '::') -or (Test-CpgLoopbackHost -HostName $address)) {
            $recognizedListeners += [pscustomobject]@{ Process = $process.ProcessName; Port = [int]$connection.LocalPort }
        }
    }
}
$recognizedListeners = @($recognizedListeners | Sort-Object Process, Port -Unique)

$tunnelAdapters = @(Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue | Where-Object {
    ([string]$_.Name + ' ' + [string]$_.InterfaceDescription) -match '(?i)\b(tun|tap|wintun|wireguard|mihomo|clash|sing-box|hiddify)\b'
})

$onlineResult = $null
if ($Online) {
    $watcherPath = Join-Path $resolvedRoot 'Watch-CodexProxy.ps1'
    if (Test-Path -LiteralPath $watcherPath) {
        $powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $output = @(& $powershellPath -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $watcherPath -SelfTest 2>&1)
        $exitCode = $LASTEXITCODE
        try { $parsed = ($output -join [Environment]::NewLine) | ConvertFrom-Json } catch { $parsed = $null }
        $onlineResult = [ordered]@{
            exitCode = $exitCode
            proxyValid = [bool](Get-SafeProperty $parsed 'ProxyValid' $false)
            proxySource = [string](Get-SafeProperty $parsed 'ProxySource' '')
            successCount = [int](Get-SafeProperty $parsed 'ProxyTestSuccessCount' 0)
            requiredCount = [int](Get-SafeProperty $parsed 'ProxyTestRequiredCount' 0)
            targetCount = [int](Get-SafeProperty $parsed 'ProxyTestTargetCount' 0)
            attemptedCount = [int](Get-SafeProperty $parsed 'ProxyTestAttemptedCount' 0)
            codexInstalled = [bool](Get-SafeProperty $parsed 'CodexInstalled' $false)
        }
    }
    else { $onlineResult = [ordered]@{ exitCode = $null; error = 'Install the guardian before running online diagnostics.' } }
}

$guardianAlive = $false
$guardianPid = [int](Get-SafeProperty $status 'guardianPid' 0)
if ($guardianPid -gt 0) {
    $guardianProcess = Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f $guardianPid) -ErrorAction SilentlyContinue
    $expectedWatcher = Join-Path $resolvedRoot 'Watch-CodexProxy.ps1'
    $guardianAlive = $null -ne $guardianProcess -and ([string]$guardianProcess.CommandLine).IndexOf($expectedWatcher, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
}

$issues = @()
$recommendations = @()
if ($env:OS -ne 'Windows_NT') { $issues += 'unsupported_os' }
if ($PSVersionTable.PSVersion -lt [Version]'5.1') { $issues += 'powershell_too_old' }
if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') { $issues += 'constrained_language_mode' }
if ($null -eq $codexApp) { $issues += 'codex_msix_not_found'; $recommendations += 'Install the Store/MSIX Codex app for the current user.' }
if ($pacUrlPresent) { $issues += 'pac_detected'; $recommendations += 'PAC/WPAD is detected but not converted to a static endpoint; use an HTTP/mixed ExplicitProxy when Codex needs one.' }
if ($proxyEnabled -and @($manualEndpoints).Count -eq 0) { $issues += 'manual_proxy_not_usable' }
if ($markerValid -and -not $guardianAlive) {
    $issues += 'guardian_not_running'
    $recommendations += 'Start the guardian with Control.ps1 -Action Start, then run Doctor again.'
}
if ($markerValid -and [string]$marker.startupMode -eq 'ScheduledTask' -and $null -eq $task) {
    $issues += 'scheduled_task_missing'
    $recommendations += 'Re-run Install.ps1 against the same marked installation directory to repair startup registration.'
}
if ($markerValid -and $null -ne $config -and [bool](Get-CpgConfigValue $config 'AutomaticUpdates' $true) -and $null -eq $updateTask) {
    $issues += 'automatic_update_task_missing'
    $recommendations += 'Re-run Install.ps1 to restore the daily verified-release update task, or disable AutomaticUpdates in Settings.'
}
if (-not $proxyEnabled -and @($environmentProxyNames).Count -eq 0 -and @($recognizedListeners).Count -eq 0 -and @($tunnelAdapters).Count -gt 0) {
    $issues += 'tun_only_likely'
    $recommendations += 'A tunnel adapter is present without a discoverable HTTP endpoint. Codex may already be transparently routed; use a mixed/HTTP inbound for explicit verification.'
}
if ([bool](Get-SafeProperty $status 'restartCircuitOpen' $false)) {
    $issues += 'restart_circuit_open'
    $recommendations += 'Keep Safe mode enabled and inspect candidate changes before closing the restart circuit.'
}
$guardianLifecycle = [string](Get-SafeProperty $status 'guardianState' '')
if ($guardianAlive -and $guardianLifecycle -eq 'WaitingForProxy') {
    $issues += 'guardian_waiting_for_proxy'
    $recommendations += 'No proxy has met the validation quorum. Run Doctor.ps1 -Online and verify an HTTP/mixed endpoint is available.'
}
if ($guardianLifecycle -eq 'RecoveryBlockedByCodex') {
    $issues += 'codex_relaunch_recovery_blocked'
    $recommendations += 'A Codex root without the current proxy argument is blocking recovery. Use the managed shortcut, or enable SafeRepairExternalCodexLaunches/Enforce mode.'
}
elseif ([bool](Get-SafeProperty $status 'recoveryLaunchRequired' $false)) {
    $issues += 'codex_relaunch_recovery_pending'
    $recommendations += 'The last managed relaunch has not been confirmed. Leave the guardian running; it will retry within the restart-rate limit.'
}
$externalLaunchState = [string](Get-SafeProperty $status 'externalLaunchState' '')
if ($externalLaunchState -eq 'ManagedShortcutRequired') {
    $issues += 'codex_managed_launch_required'
    $recommendations += 'Open "Codex (Managed Proxy)", or enable SafeRepairExternalCodexLaunches after checking the restart safeguards.'
}
elseif ($externalLaunchState -eq 'CodexResolutionUnavailable') {
    $issues += 'codex_replacement_resolution_unavailable'
    $recommendations += 'Codex was left running because a replacement MSIX executable could not be resolved. Finish any Store update, then restart the guardian.'
}
if ($Online -and $null -ne $onlineResult -and -not [bool](Get-SafeProperty ([pscustomobject]$onlineResult) 'proxyValid' $false)) {
    $issues += 'online_proxy_validation_failed'
    $recommendations += 'Set ExplicitProxy to a working HTTP/mixed endpoint, then run Doctor.ps1 -Online again.'
}

$health = 'Ready'
if (@($issues).Count -gt 0) { $health = 'NeedsAttention' }
if ($issues -contains 'unsupported_os' -or $issues -contains 'powershell_too_old' -or $issues -contains 'constrained_language_mode' -or $issues -contains 'codex_msix_not_found') { $health = 'Blocked' }

$report = [ordered]@{
    reportSchema = 3
    generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    safeForSharing = $true
    health = $health
    issues = $issues
    recommendations = $recommendations
    platform = [ordered]@{
        caption = [string](Get-SafeProperty $os 'Caption' 'Windows')
        version = [string](Get-SafeProperty $os 'Version' '')
        build = [string](Get-SafeProperty $os 'BuildNumber' '')
        architecture = [string](Get-SafeProperty $os 'OSArchitecture' $env:PROCESSOR_ARCHITECTURE)
        systemType = [string](Get-SafeProperty $computer 'SystemType' '')
        powerShell = [string]$PSVersionTable.PSVersion
        languageMode = [string]$ExecutionContext.SessionState.LanguageMode
        executionPolicies = @(Get-ExecutionPolicy -List | ForEach-Object { [ordered]@{ scope = [string]$_.Scope; policy = [string]$_.ExecutionPolicy } })
    }
    codex = [ordered]@{
        found = ($null -ne $codexApp)
        package = if ($null -eq $codexApp) { $null } else { $codexApp.PackageName }
        version = if ($null -eq $codexApp) { $null } else { $codexApp.Version }
        packageArchitecture = if ($null -eq $codexApp) { $null } else { $codexApp.PackageArchitecture }
        applicationId = if ($null -eq $codexApp) { $null } else { $codexApp.ApplicationId }
        executableName = if ($null -eq $codexApp) { $null } else { $codexApp.ProcessName }
        resolutionMethod = if ($null -eq $codexApp) { $null } else { $codexApp.ResolutionMethod }
        processRunning = [bool](Get-SafeProperty $status 'codexRunning' $false)
        launchProxyMatch = Get-SafeProperty $status 'codexProxyArgumentMatch' $null
        proxyTrafficObservedRecently = Get-SafeProperty $status 'codexProxyConnectionObservedRecently' $null
    }
    proxyDiscovery = [ordered]@{
        systemManualProxyEnabled = $proxyEnabled
        usableManualEndpointCount = @($manualEndpoints).Count
        pacConfigured = $pacUrlPresent
        inheritedProxyVariableNames = @($environmentProxyNames | Sort-Object -Unique)
        recognizedListenerCount = @($recognizedListeners).Count
        recognizedListeners = $recognizedListeners
        tunnelAdapterCount = @($tunnelAdapters).Count
    }
    guardian = [ordered]@{
        installed = $markerValid
        version = if ($markerValid) { $marker.version } else { $null }
        startupMode = if ($markerValid) { $marker.startupMode } else { $null }
        taskState = if ($null -eq $task) { $null } else { [string]$task.State }
        alive = $guardianAlive
        state = Get-SafeProperty $status 'guardianState' $null
        mode = Get-SafeProperty $status 'mode' $null
        modeProfile = if ($null -eq $config) { $null } else { Get-CpgModeProfile $config }
        externalLaunchPolicy = Get-SafeProperty $status 'externalLaunchPolicy' $null
        externalLaunchState = Get-SafeProperty $status 'externalLaunchState' $null
        activeProxyValid = [bool](Get-SafeProperty $status 'activeProxyValid' $false)
        effectivenessEvidence = Get-SafeProperty $status 'effectivenessEvidence' $null
        proxyTestSuccessCount = [int](Get-SafeProperty $status 'proxyTestSuccessCount' 0)
        proxyTestRequiredCount = [int](Get-SafeProperty $status 'proxyTestRequiredCount' 0)
        restartCircuitOpen = [bool](Get-SafeProperty $status 'restartCircuitOpen' $false)
        recentRestartCount = [int](Get-SafeProperty $status 'recentRestartCount' 0)
        restartApprovalRequired = [bool](Get-SafeProperty $status 'restartApprovalRequired' $false)
        restartNotificationEnabled = [bool](Get-SafeProperty $status 'restartNotificationEnabled' $true)
        restartDeferredUntilUtc = Get-SafeProperty $status 'restartDeferredUntilUtc' $null
        recoveryLaunchRequired = [bool](Get-SafeProperty $status 'recoveryLaunchRequired' $false)
    }
    updates = [ordered]@{
        automatic = if ($null -eq $config) { $null } else { [bool](Get-CpgConfigValue $config 'AutomaticUpdates' $true) }
        channel = if ($null -eq $config) { $null } else { [string](Get-CpgConfigValue $config 'UpdateChannel' 'Stable') }
        taskPresent = ($null -ne $updateTask)
        taskState = if ($null -eq $updateTask) { $null } else { [string]$updateTask.State }
        lastCheckUtc = if ($null -eq $updateStatus) { $null } else { [string](Get-SafeProperty $updateStatus 'time' '') }
        lastEvent = if ($null -eq $updateStatus) { $null } else { [string](Get-SafeProperty $updateStatus 'event' '') }
        lastRunTime = if ($updateTaskHasRun) { $updateTaskInfo.LastRunTime.ToUniversalTime().ToString('o') } else { $null }
        lastResult = if ($updateTaskHasRun) { $updateTaskInfo.LastTaskResult } else { $null }
    }
    onlineTest = $onlineResult
}

$reportJson = [pscustomobject]$report | ConvertTo-Json -Depth 10
if (-not [string]::IsNullOrWhiteSpace($ExportPath)) {
    $resolvedExport = [System.IO.Path]::GetFullPath($ExportPath)
    $reportJson | Set-Content -LiteralPath $resolvedExport -Encoding UTF8
}
if ($Json) { $reportJson; return }

[pscustomobject]@{
    Health = $health
    CodexFound = ($null -ne $codexApp)
    GuardianInstalled = $markerValid
    GuardianAlive = $guardianAlive
    GuardianState = Get-SafeProperty $status 'guardianState' $null
    EffectivenessEvidence = Get-SafeProperty $status 'effectivenessEvidence' $null
    ProxyTests = ('{0}/{1}' -f [int](Get-SafeProperty $status 'proxyTestSuccessCount' 0), [int](Get-SafeProperty $status 'proxyTestRequiredCount' 0))
    ProxyCriticalTargetsPassed = [bool](Get-SafeProperty $status 'proxyCriticalTargetsPassed' $false)
    ProxyCriticalFailures = @((Get-SafeProperty $status 'proxyCriticalFailures' @()))
    LaunchProxyMatch = Get-SafeProperty $status 'codexProxyArgumentMatch' $null
    ProxyTrafficObservedRecently = Get-SafeProperty $status 'codexProxyConnectionObservedRecently' $null
    RestartApprovalRequired = [bool](Get-SafeProperty $status 'restartApprovalRequired' $false)
    RestartDeferredUntilUtc = Get-SafeProperty $status 'restartDeferredUntilUtc' $null
    RestartCircuitOpen = [bool](Get-SafeProperty $status 'restartCircuitOpen' $false)
    SafeToShareJson = (-not [string]::IsNullOrWhiteSpace($ExportPath))
} | Format-List
if (@($issues).Count -gt 0) { "Issues: $($issues -join ', ')" }
foreach ($recommendation in $recommendations) { "- $recommendation" }
