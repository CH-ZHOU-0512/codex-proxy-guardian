[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$script:Passed = 0
$script:Failed = 0

function Invoke-Test {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        $script:Passed++
        Write-Host "PASS  $Name" -ForegroundColor Green
    }
    catch {
        $script:Failed++
        Write-Host "FAIL  $Name" -ForegroundColor Red
        Write-Host "      $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Assert-True {
    param($Value, [string]$Message = 'Expected true.')
    if (-not [bool]$Value) { throw $Message }
}

function Assert-False {
    param($Value, [string]$Message = 'Expected false.')
    if ([bool]$Value) { throw $Message }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message = '')
    if (-not [object]::Equals($Expected, $Actual)) {
        throw "Expected '$Expected', got '$Actual'. $Message"
    }
}

function Assert-Null {
    param($Value, [string]$Message = 'Expected null.')
    if ($null -ne $Value) { throw "$Message Got '$Value'." }
}

Import-Module (Join-Path $repoRoot 'src\CodexProxyGuardian.Core.psm1') -Force

Invoke-Test 'All PowerShell files parse on this runtime' {
    $errors = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $repoRoot -Recurse -File | Where-Object { $_.Extension -in @('.ps1', '.psm1') -and $_.FullName -notlike '*\artifacts\*' })) {
        $tokens = $null
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
        foreach ($parseError in @($parseErrors)) { $errors += "$($file.FullName):$($parseError.Extent.StartLineNumber): $($parseError.Message)" }
    }
    Assert-Equal 0 $errors.Count ($errors -join [Environment]::NewLine)
}

Invoke-Test 'Localized settings UI has a Windows PowerShell compatible UTF-8 BOM' {
    $bytes = [System.IO.File]::ReadAllBytes((Join-Path $repoRoot 'Settings.ps1'))
    Assert-True ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
}

Invoke-Test 'Silent VBS launchers parse and use the inbox PowerShell path' {
    $cscript = Join-Path $env:SystemRoot 'System32\cscript.exe'
    foreach ($name in @('Run-Guardian.vbs', 'Run-ManagedCodex.vbs')) {
        $output = & $cscript //nologo (Join-Path $repoRoot "src\$name") --print-command 2>&1
        Assert-Equal 0 $LASTEXITCODE "$name did not parse. Output: $($output -join ' ')"
        Assert-True (($output -join ' ') -match 'System32\\WindowsPowerShell\\v1\.0\\powershell\.exe') "$name did not resolve inbox Windows PowerShell."
    }
}

Invoke-Test 'Configuration JSON files are valid' {
    foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'config') -Filter '*.json' -File)) {
        $value = Get-Content -Raw -LiteralPath $file.FullName | ConvertFrom-Json
        Assert-True ($null -ne $value) "Could not parse $($file.Name)."
    }
}

Invoke-Test 'Default configuration is conservative' {
    $config = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'config\default-config.json') | ConvertFrom-Json
    Assert-Equal 'Safe' ([string]$config.Mode)
    Assert-True $config.AutomaticUpdates
    Assert-Equal 'Stable' ([string]$config.UpdateChannel)
    Assert-False $config.ManageExternalCodexLaunches
    Assert-True $config.SafeRepairExternalCodexLaunches
    Assert-True ([int]$config.SafeExternalLaunchGraceSeconds -ge 10)
    Assert-False $config.AllowNonLoopbackProxy
    Assert-True $config.AllowSystemNonLoopbackProxy
    Assert-True $config.EnablePACDiscovery
    Assert-True $config.EnableWPADDiscovery
    Assert-True ([int]$config.PacFetchTimeoutSeconds -le 10)
    Assert-True ([int]$config.PacExecutionTimeoutMilliseconds -le 1000)
    Assert-True ([int]$config.PacMaxBytes -le 1048576)
    Assert-True $config.UseChromiumProxyArgument
    Assert-True $config.RequireManagedLaunchForStreaming
    Assert-True $config.NotifyBeforeCodexRestart
    Assert-True ([int]$config.RestartPromptTimeoutSeconds -ge 15)
    Assert-True ([int]$config.RestartPromptSnoozeMinutes -ge 1)
    Assert-True ([int]$config.RestartCooldownSeconds -ge 10)
    Assert-True ([int]$config.RestartLimitCount -le 3)
    Assert-True ([int]$config.RecoveryLaunchRetrySeconds -ge 5)
    Assert-True ([int]$config.MinimumSuccessfulProxyTests -ge 2)
    Assert-True ([int]$config.MinimumSuccessfulProxyTests -le @($config.ProxyTestUrls).Count)
    Assert-True ('chatgpt.com' -in @($config.RequiredProxyTestHosts))
    Assert-True $config.PostUpdateStabilityEnabled
    Assert-True ([int]$config.PostUpdateStabilitySamples -ge 3)
    Assert-True ([int]$config.PostUpdateStabilitySeconds -ge 60)
    Assert-True $config.CheckForGuardianUpdateOnCodexChange
    Assert-True ([int]$config.CompatibilityUpdateRetryMinutes -ge 5)
    Assert-True ([int]$config.CodexCompatibilityConfirmationSeconds -ge 30)
    foreach ($url in @($config.ProxyTestUrls)) { Assert-True ([string]$url).StartsWith('https://', [System.StringComparison]::OrdinalIgnoreCase) }
}

Invoke-Test 'Safe external launches are repaired only after an evidence grace period' {
    $waiting = Get-CpgExternalLaunchDecision -Mode Safe -SafeRepairEnabled:$true -ProxyValid:$true -ArgumentMatches:$false -TrafficObserved:$false -PendingSeconds 19 -SafeGraceSeconds 20
    Assert-Equal 'Wait' ([string]$waiting.Action)
    Assert-Equal 'safe_evidence_grace' ([string]$waiting.Reason)

    $working = Get-CpgExternalLaunchDecision -Mode Safe -SafeRepairEnabled:$true -ProxyValid:$true -ArgumentMatches:$false -TrafficObserved:$true -PendingSeconds 30 -SafeGraceSeconds 20
    Assert-Equal 'Keep' ([string]$working.Action)
    Assert-Equal 'safe_proxy_traffic_observed' ([string]$working.Reason)

    $streamingGrace = Get-CpgExternalLaunchDecision -Mode Safe -SafeRepairEnabled:$true -ProxyValid:$true -ArgumentMatches:$false -TrafficObserved:$true -RequireManagedLaunchForStreaming:$true -PendingSeconds 19 -SafeGraceSeconds 20
    Assert-Equal 'Wait' ([string]$streamingGrace.Action)
    Assert-Equal 'safe_streaming_evidence_grace' ([string]$streamingGrace.Reason)

    $streamingRepair = Get-CpgExternalLaunchDecision -Mode Safe -SafeRepairEnabled:$true -ProxyValid:$true -ArgumentMatches:$false -TrafficObserved:$true -RequireManagedLaunchForStreaming:$true -PendingSeconds 20 -SafeGraceSeconds 20
    Assert-Equal 'Repair' ([string]$streamingRepair.Action)
    Assert-Equal 'safe_streaming_proxy_not_guaranteed' ([string]$streamingRepair.Reason)

    $repair = Get-CpgExternalLaunchDecision -Mode Safe -SafeRepairEnabled:$true -ProxyValid:$true -ArgumentMatches:$false -TrafficObserved:$false -PendingSeconds 20 -SafeGraceSeconds 20
    Assert-Equal 'Repair' ([string]$repair.Action)

    $enforced = Get-CpgExternalLaunchDecision -Mode Enforce -ProxyValid:$true -ArgumentMatches:$false -TrafficObserved:$true -PendingSeconds 15 -EnforceDebounceSeconds 15
    Assert-Equal 'Repair' ([string]$enforced.Action)
    Assert-Equal 'enforce_missing_proxy_argument' ([string]$enforced.Reason)

    $observing = Get-CpgExternalLaunchDecision -Mode Safe -SafeRepairEnabled:$true -ProxyValid:$true -ArgumentMatches:$false -TrafficObserved:$true -StabilityReady:$false -PendingSeconds 60
    Assert-Equal 'Wait' ([string]$observing.Action)
    Assert-Equal 'post_update_stability_observation' ([string]$observing.Reason)

    $upstream = Get-CpgExternalLaunchDecision -Mode Enforce -ProxyValid:$true -ArgumentMatches:$false -TrafficObserved:$true -UpstreamSuspected:$true -PendingSeconds 60
    Assert-Equal 'Hold' ([string]$upstream.Action)
    Assert-Equal 'proxy_upstream_suspected' ([string]$upstream.Reason)

    $compatibilityHold = Get-CpgExternalLaunchDecision -Mode Safe -ProxyValid:$true -ArgumentMatches:$false -TrafficObserved:$false -CompatibilityBlocked:$true -PendingSeconds 120
    Assert-Equal 'Hold' ([string]$compatibilityHold.Action)
    Assert-Equal 'codex_compatibility_review_required' ([string]$compatibilityHold.Reason)
}

Invoke-Test 'Post-update stability requires fresh consecutive critical validations' {
    $first = Get-CpgProxyStabilityDecision -ObservationActive:$true -ValidationFresh:$true -EndpointReachable:$true -ValidationPassed:$true -CriticalTargetsPassed:$true -SuccessfulSamples 0 -RequiredSamples 3 -ElapsedSeconds 10 -MinimumObservationSeconds 60
    Assert-Equal 'ObservingAfterCodexUpdate' ([string]$first.State)
    Assert-Equal 1 ([int]$first.SuccessfulSamples)
    Assert-False $first.StabilityReady

    $cached = Get-CpgProxyStabilityDecision -ObservationActive:$true -ValidationFresh:$false -EndpointReachable:$true -ValidationPassed:$true -CriticalTargetsPassed:$true -SuccessfulSamples $first.SuccessfulSamples -RequiredSamples 3 -ElapsedSeconds 40 -MinimumObservationSeconds 60
    Assert-Equal 1 ([int]$cached.SuccessfulSamples)
    Assert-False $cached.StabilityReady

    $failed = Get-CpgProxyStabilityDecision -ObservationActive:$true -ValidationFresh:$true -EndpointReachable:$true -ValidationPassed:$false -CriticalTargetsPassed:$false -SuccessfulSamples 2 -RequiredSamples 3 -ElapsedSeconds 61 -MinimumObservationSeconds 60
    Assert-Equal 'UpstreamSuspected' ([string]$failed.State)
    Assert-Equal 0 ([int]$failed.SuccessfulSamples)
    Assert-True $failed.UpstreamSuspected
    Assert-False $failed.StabilityReady

    $recovered = Get-CpgProxyStabilityDecision -ObservationActive:$true -ValidationFresh:$true -EndpointReachable:$true -ValidationPassed:$true -CriticalTargetsPassed:$true -SuccessfulSamples 2 -RequiredSamples 3 -ElapsedSeconds 90 -MinimumObservationSeconds 60 -UpstreamSuspected:$true
    Assert-Equal 'StableAfterCodexUpdate' ([string]$recovered.State)
    Assert-True $recovered.ObservationComplete
    Assert-True $recovered.StabilityReady

    $listenerDown = Get-CpgProxyStabilityDecision -ObservationActive:$false -ValidationFresh:$true -EndpointReachable:$false -ValidationPassed:$false -CriticalTargetsPassed:$false
    Assert-Equal 'IndirectEvidenceOnly' ([string]$listenerDown.State)
    Assert-False $listenerDown.UpstreamSuspected
}

Invoke-Test 'Codex compatibility audit fails safe after an unconfirmed managed launch' {
    $auditing = Get-CpgCodexCompatibilityDecision -ObservationActive:$true
    Assert-Equal 'Auditing' ([string]$auditing.State)
    Assert-False $auditing.ReviewRequired

    $traffic = Get-CpgCodexCompatibilityDecision -ObservationPassed:$true -TrafficObserved:$true
    Assert-Equal 'Compatible' ([string]$traffic.State)
    Assert-Equal 'ProxyTrafficObserved' ([string]$traffic.Evidence)

    $httpOnlyTraffic = Get-CpgCodexCompatibilityDecision -ObservationPassed:$true -TrafficObserved:$true -RequireManagedLaunchForStreaming:$true
    Assert-Equal 'NeedsManagedLaunch' ([string]$httpOnlyTraffic.State)
    Assert-Equal 'SystemProxyHttpTrafficOnly' ([string]$httpOnlyTraffic.Evidence)
    Assert-False $httpOnlyTraffic.ReviewRequired

    $managedPending = Get-CpgCodexCompatibilityDecision -ObservationPassed:$true -LaunchConfigured:$true -RequireManagedLaunchForStreaming:$true -RecoveryPending:$true -CodexRunning:$true -SecondsSinceManagedLaunch 44 -ConfirmationSeconds 45
    Assert-Equal 'AwaitingEvidence' ([string]$managedPending.State)
    Assert-Equal 'ManagedStreamingTrafficPending' ([string]$managedPending.Evidence)

    $managedConfirmed = Get-CpgCodexCompatibilityDecision -ObservationPassed:$true -LaunchConfigured:$true -TrafficObserved:$true -RequireManagedLaunchForStreaming:$true
    Assert-Equal 'Compatible' ([string]$managedConfirmed.State)
    Assert-Equal 'ManagedLaunchAndTrafficObserved' ([string]$managedConfirmed.Evidence)

    $managedUnconfirmed = Get-CpgCodexCompatibilityDecision -ObservationPassed:$true -LaunchConfigured:$true -RequireManagedLaunchForStreaming:$true -RecoveryPending:$true -CodexRunning:$true -SecondsSinceManagedLaunch 45 -ConfirmationSeconds 45
    Assert-Equal 'ReviewRequired' ([string]$managedUnconfirmed.State)
    Assert-Equal 'ManagedStreamingTrafficNotConfirmed' ([string]$managedUnconfirmed.Evidence)

    $waiting = Get-CpgCodexCompatibilityDecision -ObservationPassed:$true -RecoveryPending:$true -CodexRunning:$true -SecondsSinceManagedLaunch 44 -ConfirmationSeconds 45
    Assert-Equal 'AwaitingEvidence' ([string]$waiting.State)

    $blocked = Get-CpgCodexCompatibilityDecision -ObservationPassed:$true -RecoveryPending:$true -CodexRunning:$true -SecondsSinceManagedLaunch 45 -ConfirmationSeconds 45
    Assert-Equal 'ReviewRequired' ([string]$blocked.State)
    Assert-True $blocked.ReviewRequired

    $recovered = Get-CpgCodexCompatibilityDecision -ObservationPassed:$true -LaunchConfigured:$true -CompatibilityBlocked:$true
    Assert-Equal 'Compatible' ([string]$recovered.State)
    Assert-False $recovered.ReviewRequired
}

Invoke-Test 'Stale guardian PIDs cannot identify unrelated processes' {
    $watcher = 'C:\Users\Example\AppData\Local\CodexProxyGuardian\Watch-CodexProxy.ps1'
    $guardian = [pscustomobject]@{ CommandLine = "powershell.exe -File `"$watcher`"" }
    $reusedPidProcess = [pscustomobject]@{ CommandLine = 'python.exe markitdown-mcp.exe' }
    $lookalike = [pscustomobject]@{ CommandLine = "powershell.exe -File `"$watcher.backup`"" }
    Assert-True (Test-CpgGuardianProcessIdentity -Process $guardian -WatcherPath $watcher)
    Assert-False (Test-CpgGuardianProcessIdentity -Process $reusedPidProcess -WatcherPath $watcher)
    Assert-False (Test-CpgGuardianProcessIdentity -Process $lookalike -WatcherPath $watcher)
    Assert-False (Test-CpgGuardianProcessIdentity -Process $null -WatcherPath $watcher)
}

Invoke-Test 'User mode profiles map to safe automatic and strict enforcement settings' {
    $config = [pscustomobject]@{ Mode = 'Enforce'; ManageExternalCodexLaunches = $true; SafeRepairExternalCodexLaunches = $false }
    $automatic = Set-CpgModeProfile -Config $config -Profile Auto
    Assert-Equal 'Safe' ([string]$automatic.Mode)
    Assert-False $automatic.ManageExternalCodexLaunches
    Assert-True $automatic.SafeRepairExternalCodexLaunches
    Assert-Equal 'Automatic' (Get-CpgModeProfile $automatic)

    $strict = Set-CpgModeProfile -Config $automatic -Profile Strict
    Assert-Equal 'Enforce' ([string]$strict.Mode)
    Assert-True $strict.ManageExternalCodexLaunches
    Assert-Equal 'Strict' (Get-CpgModeProfile $strict)
}

Invoke-Test 'Mode changes use background reload without restarting Guardian' {
    $control = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'Control.ps1')
    $watcher = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'src\Watch-CodexProxy.ps1')
    Assert-True $control.Contains("'config.reload.request'") 'Control does not request a background mode reload.'
    Assert-True $watcher.Contains("'mode_reloaded'") 'Watcher does not apply a requested mode reload.'
    $configurationStart = $control.IndexOf('function Set-GuardianConfiguration', [System.StringComparison]::Ordinal)
    $switchStart = $control.IndexOf('switch ($Action)', [System.StringComparison]::Ordinal)
    Assert-True ($configurationStart -ge 0 -and $switchStart -gt $configurationStart) 'Could not isolate mode configuration control flow.'
    $configurationFlow = $control.Substring($configurationStart, $switchStart - $configurationStart)
    Assert-False $configurationFlow.Contains('Stop-Guardian') 'A settings-only mode change still stops Guardian.'
    Assert-False $configurationFlow.Contains('Start-Guardian') 'A settings-only mode change still starts Guardian.'
}

Invoke-Test 'Semantic update selection respects version order and release channel' {
    Assert-True ((Compare-CpgSemanticVersion '0.4.0-alpha' '0.3.1-alpha') -gt 0)
    Assert-True ((Compare-CpgSemanticVersion '1.0.0' '1.0.0-rc.1') -gt 0)
    Assert-True ((Compare-CpgSemanticVersion '1.0.0-alpha.2' '1.0.0-alpha.10') -lt 0)
    Assert-Equal 0 (Compare-CpgSemanticVersion 'v1.2.3' '1.2.3')

    $releases = @(
        [pscustomobject]@{ tag_name = 'v0.4.0-alpha'; draft = $false; prerelease = $true },
        [pscustomobject]@{ tag_name = 'v0.3.2'; draft = $false; prerelease = $false },
        [pscustomobject]@{ tag_name = 'not-a-version'; draft = $false; prerelease = $false }
    )
    Assert-Equal 'v0.4.0-alpha' ([string](Select-CpgUpdateRelease $releases '0.3.1-alpha' Prerelease).tag_name)
    Assert-Equal 'v0.3.2' ([string](Select-CpgUpdateRelease $releases '0.3.1-alpha' Stable).tag_name)
    Assert-Null (Select-CpgUpdateRelease $releases '0.4.0-alpha' Prerelease)
    Assert-Equal 'v0.4.0-alpha' ([string](Select-CpgLatestRelease $releases Prerelease).tag_name)
    Assert-Equal 'v0.3.2' ([string](Select-CpgLatestRelease $releases Stable).tag_name)

    $wrappedReleases = New-Object 'object[]' 1
    $wrappedReleases[0] = $releases
    Assert-Equal 'v0.4.0-alpha' ([string](Select-CpgUpdateRelease $wrappedReleases '0.3.1-alpha' Prerelease).tag_name)
}

Invoke-Test 'Windows updater expands REST release arrays and reuses the validated proxy' {
    $updateSource = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'Update.ps1')
    Assert-True ($updateSource.Contains('$releaseResponse = Invoke-UpdateJsonRequest'))
    Assert-True ($updateSource.Contains('$releases = @($releaseResponse)'))
    Assert-False ($updateSource.Contains('$releases = @(Invoke-RestMethod'))
    Assert-True ($updateSource.Contains("'Cache-Control' = 'no-cache'"))
    Assert-True ($updateSource.Contains('LatestVersion = $latestVersion'))
    Assert-True ($updateSource.Contains("CheckStatus = 'Busy'"))
    Assert-True ($updateSource.Contains('ChannelOverride'))
    Assert-True ($updateSource.Contains('Get-CpgUpdateProxyDecision'))
    Assert-True ($updateSource.Contains("'update_request_retry'"))
    Assert-True ($updateSource.Contains('Invoke-UpdateCurlDownload'))
    Assert-True ($updateSource.Contains('New-Object System.Text.UTF8Encoding($false, $true)'))
    Assert-True ($updateSource.Contains('NetworkRoute = $script:LastUpdateNetworkRoute'))
}

Invoke-Test 'Update routing prefers validated HTTP and supports validated SOCKS' {
    $config = [pscustomobject]@{ ExplicitProxy = ''; AllowNonLoopbackProxy = $false }
    $validated = [pscustomobject]@{ activeProxyValid = $true; activeProxy = 'http://127.0.0.1:7897' }
    $httpDecision = Get-CpgUpdateProxyDecision -Status $validated -Config $config
    Assert-True $httpDecision.UseProxy
    Assert-Equal 'http://127.0.0.1:7897' ([string]$httpDecision.ProxyUri)
    Assert-Equal 'PowerShell' ([string]$httpDecision.Transport)
    Assert-Equal 'GuardianValidatedProxy' ([string]$httpDecision.Source)

    $socks = [pscustomobject]@{ activeProxyValid = $true; activeProxy = 'socks5h://127.0.0.1:1080' }
    $socksDecision = Get-CpgUpdateProxyDecision -Status $socks -Config $config
    Assert-True $socksDecision.UseProxy
    Assert-Equal 'Curl' ([string]$socksDecision.Transport)

    $unvalidated = [pscustomobject]@{ activeProxyValid = $false; activeProxy = 'http://127.0.0.1:7897' }
    $directDecision = Get-CpgUpdateProxyDecision -Status $unvalidated -Config $config
    Assert-False $directDecision.UseProxy
    Assert-Equal 'WindowsDefaultRoute' ([string]$directDecision.Source)
}

Invoke-Test 'Compatibility updates track terminal results and retry the same Codex version' {
    $now = [datetime]'2026-08-14T10:00:00Z'
    $first = Get-CpgCompatibilityUpdateDecision -CodexVersion '26.900.1.0' -Now $now
    Assert-Equal 'Start' ([string]$first.Action)
    Assert-Equal 'Pending' ([string]$first.State)

    $running = Get-CpgCompatibilityUpdateDecision -CodexVersion '26.900.1.0' -RequestedVersion '26.900.1.0' -LastAttempt $now -TaskRunning:$true -Now $now
    Assert-Equal 'Running' ([string]$running.State)

    $currentStatus = [pscustomobject]@{ event = 'update_not_available'; time = $now.AddMinutes(1).ToString('o') }
    $current = Get-CpgCompatibilityUpdateDecision -CodexVersion '26.900.1.0' -RequestedVersion '26.900.1.0' -LastAttempt $now -UpdateStatus $currentStatus -Now $now.AddMinutes(2)
    Assert-Equal 'None' ([string]$current.Action)
    Assert-Equal 'Current' ([string]$current.State)

    $failedStatus = [pscustomobject]@{ event = 'update_failed'; time = $now.AddMinutes(1).ToString('o') }
    $deferred = Get-CpgCompatibilityUpdateDecision -CodexVersion '26.900.1.0' -RequestedVersion '26.900.1.0' -LastAttempt $now -UpdateStatus $failedStatus -Now $now.AddMinutes(5) -RetryMinutes 15
    Assert-Equal 'FailedRetryScheduled' ([string]$deferred.State)
    Assert-Equal 'None' ([string]$deferred.Action)
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$deferred.RetryAfterUtc))

    $retry = Get-CpgCompatibilityUpdateDecision -CodexVersion '26.900.1.0' -RequestedVersion '26.900.1.0' -LastAttempt $now -UpdateStatus $failedStatus -Now $now.AddMinutes(15) -RetryMinutes 15
    Assert-Equal 'Retrying' ([string]$retry.State)
    Assert-Equal 'Start' ([string]$retry.Action)

    $staleSuccess = [pscustomobject]@{ event = 'update_not_available'; time = $now.AddMinutes(-5).ToString('o') }
    $notFooled = Get-CpgCompatibilityUpdateDecision -CodexVersion '26.900.1.0' -RequestedVersion '26.900.1.0' -LastAttempt $now -UpdateStatus $staleSuccess -Now $now.AddMinutes(15) -RetryMinutes 15
    Assert-Equal 'Start' ([string]$notFooled.Action)
}

Invoke-Test 'Settings never reports a skipped update check as current' {
    $settingsSource = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'Settings.ps1')
    Assert-True ($settingsSource.Contains('-ChannelOverride $requestedChannel'))
    Assert-True ($settingsSource.Contains('-not [bool]$result.UpdateChecked'))
    Assert-True ($settingsSource.Contains('$result.CurrentVersion'))
    Assert-True ($settingsSource.Contains('$result.LatestVersion'))
    Assert-True ($settingsSource.Contains('$result.CheckedAtUtc'))
    Assert-True ($settingsSource.Contains('Version = $version'))
    Assert-True ($settingsSource.Contains('ReconnectGuidanceVisible'))
    Assert-True ($settingsSource.Contains('StreamStabilityVisible'))
    Assert-True ($settingsSource.Contains('codex_restart / proxy_changed'))
}

Invoke-Test 'Public diagnostics explain how to attribute reconnects' {
    $statusSource = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'Status.ps1')
    $doctorSource = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'Doctor.ps1')
    $issueTemplate = Get-Content -Raw -LiteralPath (Join-Path $repoRoot '.github\ISSUE_TEMPLATE\bug_report.yml')
    foreach ($required in @('CodexStreamRetryNotProofOfGuardianRestart', 'codex_restart', 'proxy_changed', 'WebSocket reset', 'ProviderNodeManagedByGuardian')) {
        Assert-True ($statusSource.Contains($required)) "Status is missing reconnect attribution: $required"
        Assert-True ($doctorSource.Contains($required) -or ($required -eq 'ProviderNodeManagedByGuardian' -and $doctorSource.Contains('providerNodeManagedByGuardian'))) "Doctor is missing reconnect attribution: $required"
    }
    Assert-True ($issueTemplate.Contains('reconnect_attribution'))
    Assert-True ($issueTemplate.Contains('codex_restart'))
    Assert-True ($statusSource.Contains('PostUpdateObservationState'))
    Assert-True ($statusSource.Contains('UpstreamSuspected'))
    Assert-True ($statusSource.Contains('StreamingProxyGuaranteed'))
    Assert-True ($issueTemplate.Contains('proxy_changed'))
}

Invoke-Test 'Guardian serializes an empty critical failure list as a JSON array' {
    $watcherSource = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'src\Watch-CodexProxy.ps1')
    Assert-True ($watcherSource.Contains("proxyCriticalFailures = @(if (`$null -eq `$currentValidation)"))

    $sample = [pscustomobject]@{ failures = @(if ($false) { @('chatgpt.com') } else { @() }) }
    Assert-Equal '{"failures":[]}' ($sample | ConvertTo-Json -Compress)
}

Invoke-Test 'Release checksum parser accepts only a leading SHA-256 digest' {
    $hash = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
    Assert-Equal $hash (Get-CpgDeclaredSha256 "$hash  CodexProxyGuardian.zip")
    Assert-Null (Get-CpgDeclaredSha256 'sha256: invalid')
    Assert-Null (Get-CpgDeclaredSha256 "prefix $hash")
}

Invoke-Test 'Configuration migration adds defaults without replacing user choices' {
    $config = [pscustomobject]@{ Mode = 'Enforce'; PollSeconds = 12; UpdateChannel = 'Prerelease' }
    $defaults = [pscustomobject]@{
        Mode = 'Safe'; PollSeconds = 5; CircuitBreakerMinutes = 15; UpdateChannel = 'Stable'
        EnablePACDiscovery = $true; PacExecutionTimeoutMilliseconds = 500; AllowSystemNonLoopbackProxy = $true
    }
    $merged = Update-CpgConfigDefaults -Config $config -Defaults $defaults
    Assert-Equal 'Enforce' ([string]$merged.Mode)
    Assert-Equal 12 ([int]$merged.PollSeconds)
    Assert-Equal 15 ([int]$merged.CircuitBreakerMinutes)
    Assert-Equal 'Prerelease' ([string]$merged.UpdateChannel)
    Assert-True $merged.EnablePACDiscovery
    Assert-Equal 500 ([int]$merged.PacExecutionTimeoutMilliseconds)
    Assert-True $merged.AllowSystemNonLoopbackProxy
}

Invoke-Test 'First stable release upgrades the alpha series on the Stable channel' {
    $releases = @([pscustomobject]@{ tag_name = 'v1.0.0'; draft = $false; prerelease = $false })
    Assert-Equal 'v1.0.0' ([string](Select-CpgUpdateRelease $releases '0.4.0-alpha' Stable).tag_name)
}

Invoke-Test 'Loopback proxy without a scheme is normalized' {
    Assert-Equal 'http://127.0.0.1:8080' (ConvertTo-CpgHttpProxyUri -Address '127.0.0.1:8080')
    Assert-Equal 'http://localhost:80' (ConvertTo-CpgHttpProxyUri -Address 'http://localhost:80')
}

Invoke-Test 'IPv6 loopback proxy is accepted' {
    Assert-Equal 'http://[::1]:8080' (ConvertTo-CpgHttpProxyUri -Address '[::1]:8080')
}

Invoke-Test 'HTTP and SOCKS5 proxy schemes require an explicit port' {
    Assert-Equal 'socks5h://127.0.0.1:1080' (ConvertTo-CpgProxyUri -Address 'socks5://127.0.0.1:1080')
    Assert-Equal 'socks5h://127.0.0.1:1080' (ConvertTo-CpgProxyUri -Address 'socks://127.0.0.1:1080')
    Assert-Null (ConvertTo-CpgProxyUri -Address 'socks4://127.0.0.1:1080')
    Assert-Null (ConvertTo-CpgHttpProxyUri -Address 'http://127.0.0.1')
}

Invoke-Test 'Proxy endpoints cannot contain paths, queries, or fragments' {
    Assert-Null (ConvertTo-CpgHttpProxyUri -Address 'http://127.0.0.1:8080/path')
    Assert-Null (ConvertTo-CpgHttpProxyUri -Address 'http://127.0.0.1:8080?token=value')
    Assert-Null (ConvertTo-CpgHttpProxyUri -Address 'http://127.0.0.1:8080/#fragment')
}

Invoke-Test 'Remote proxies require an explicit opt-in' {
    Assert-Null (ConvertTo-CpgHttpProxyUri -Address 'http://192.0.2.10:8080')
    Assert-Equal 'http://192.0.2.10:8080' (ConvertTo-CpgHttpProxyUri -Address 'http://192.0.2.10:8080' -AllowNonLoopback)
}

Invoke-Test 'Embedded credentials are rejected and redacted' {
    Assert-Null (ConvertTo-CpgHttpProxyUri -Address 'http://alice:supersecret@127.0.0.1:8080')
    $safe = Protect-CpgProxyUri 'http://alice:supersecret@127.0.0.1:8080'
    Assert-False ($safe -match 'alice|supersecret')
    Assert-Equal 'http://127.0.0.1:8080' $safe
}

Invoke-Test 'Windows protocol proxy map prefers HTTPS and deduplicates' {
    $items = @(ConvertFrom-CpgProxyServer -ProxyServer 'http=127.0.0.1:8000;https=127.0.0.1:9000;socks=127.0.0.1:1080')
    Assert-Equal 3 $items.Count
    Assert-Equal 'https' ([string]$items[0].Label)
    Assert-Equal 'http://127.0.0.1:9000' ([string]$items[0].Uri)
    Assert-Equal 'socks5h://127.0.0.1:1080' ([string]$items[2].Uri)
}

Invoke-Test 'PAC results preserve supported fallback order' {
    $items = @(ConvertFrom-CpgPacResult -Result 'PROXY 127.0.0.1:8080; SOCKS5 127.0.0.1:1080; SOCKS4 127.0.0.1:1081; DIRECT')
    Assert-Equal 2 $items.Count
    Assert-Equal 'http://127.0.0.1:8080' ([string]$items[0].Uri)
    Assert-Equal 'socks5h://127.0.0.1:1080' ([string]$items[1].Uri)
}

Invoke-Test 'Chromium receives its supported SOCKS5 spelling' {
    Assert-Equal 'socks5://127.0.0.1:1080' (ConvertTo-CpgChromiumProxyUri -ProxyUri 'socks5h://127.0.0.1:1080')
    $root = [pscustomobject]@{ CommandLine = 'ChatGPT.exe --proxy-server=socks5://127.0.0.1:1080' }
    Assert-True (Test-CpgRootUsesProxy -RootProcess $root -ProxyUri 'socks5h://127.0.0.1:1080')
    Assert-True (Test-CpgRootUsesProxy -RootProcess $root -ProxyUri 'http://127.0.0.1:1080')
    Assert-False (Test-CpgRootUsesProxy -RootProcess $root -ProxyUri 'http://127.0.0.1:1081')
}

Invoke-Test 'Candidate ordering is deterministic and sticky only within a score tier' {
    $candidates = @(
        [pscustomobject]@{ Uri = 'http://127.0.0.1:9000'; Source = 'process:z'; Score = 100 },
        [pscustomobject]@{ Uri = 'http://127.0.0.1:8000'; Source = 'process:a'; Score = 100 },
        [pscustomobject]@{ Uri = 'http://127.0.0.1:7000'; Source = 'system:all'; Score = 200 }
    )
    $ordered = @(Select-CpgProxyCandidates -Candidates $candidates -PreferredUri 'http://127.0.0.1:9000')
    Assert-Equal 'http://127.0.0.1:7000' ([string]$ordered[0].Uri)
    Assert-Equal 'http://127.0.0.1:9000' ([string]$ordered[1].Uri)
    Assert-Equal 'http://127.0.0.1:8000' ([string]$ordered[2].Uri)
}

Invoke-Test 'Candidate ordering prefers the higher-confidence protocol on the same endpoint' {
    $candidates = @(
        [pscustomobject]@{ Uri = 'http://127.0.0.1:7897'; Source = 'system:all'; Score = 210 },
        [pscustomobject]@{ Uri = 'http://127.0.0.1:7897'; Source = 'process:verge-mihomo'; Score = 120 },
        [pscustomobject]@{ Uri = 'socks5h://127.0.0.1:7897'; Source = 'process:verge-mihomo:socks5'; Score = 115 }
    )

    $ordered = @(Select-CpgProxyCandidates -Candidates $candidates -PreferredUri 'socks5h://127.0.0.1:7897')
    Assert-Equal 'http://127.0.0.1:7897' ([string]$ordered[0].Uri)
    Assert-Equal 'http://127.0.0.1:7897' ([string]$ordered[1].Uri)
    Assert-Equal 'socks5h://127.0.0.1:7897' ([string]$ordered[2].Uri)
}

Invoke-Test 'Candidate ordering still changes to a higher-priority different endpoint' {
    $candidates = @(
        [pscustomobject]@{ Uri = 'http://127.0.0.1:7898'; Source = 'system:all'; Score = 210 },
        [pscustomobject]@{ Uri = 'socks5h://127.0.0.1:7897'; Source = 'process:verge-mihomo:socks5'; Score = 115 }
    )

    $ordered = @(Select-CpgProxyCandidates -Candidates $candidates -PreferredUri 'socks5h://127.0.0.1:7897')
    Assert-Equal 'http://127.0.0.1:7898' ([string]$ordered[0].Uri)
}

Invoke-Test 'Explicit proxy selection overrides same-endpoint scheme stickiness' {
    $candidates = @(
        [pscustomobject]@{ Uri = 'http://127.0.0.1:7897'; Source = 'config:ExplicitProxy'; Score = 300 },
        [pscustomobject]@{ Uri = 'socks5h://127.0.0.1:7897'; Source = 'process:verge-mihomo:socks5'; Score = 115 }
    )

    $ordered = @(Select-CpgProxyCandidates -Candidates $candidates -PreferredUri 'socks5h://127.0.0.1:7897')
    Assert-Equal 'http://127.0.0.1:7897' ([string]$ordered[0].Uri)
}

Invoke-Test 'Lifecycle identity ignores protocol changes on the same host and port' {
    Assert-True (Test-CpgSameProxyEndpoint -FirstProxyUri 'http://127.0.0.1:7897' -SecondProxyUri 'socks5h://127.0.0.1:7897')
    Assert-False (Test-CpgSameProxyEndpoint -FirstProxyUri 'http://127.0.0.1:7897' -SecondProxyUri 'http://127.0.0.1:7898')
    Assert-Equal 'socks5h://127.0.0.1:7897' (Resolve-CpgProxyLifecycleUri -PreferredProxyUri 'socks5h://127.0.0.1:7897' -ValidatedProxyUri 'http://127.0.0.1:7897')
    Assert-Equal 'http://127.0.0.1:7898' (Resolve-CpgProxyLifecycleUri -PreferredProxyUri 'socks5h://127.0.0.1:7897' -ValidatedProxyUri 'http://127.0.0.1:7898')
    Assert-Equal 'http://127.0.0.1:7897' (Resolve-CpgProxyLifecycleUri -PreferredProxyUri 'socks5h://127.0.0.1:7897' -ValidatedProxyUri 'http://127.0.0.1:7897' -ExplicitSelection)

    $protocolUpdate = Get-CpgProxyChangeDecision -CurrentProxyUri 'socks5h://127.0.0.1:7897' -ValidatedProxyUri 'http://127.0.0.1:7897'
    Assert-Equal 'ProtocolUpdate' ([string]$protocolUpdate.Kind)
    Assert-False $protocolUpdate.RestartRequired

    $endpointChange = Get-CpgProxyChangeDecision -CurrentProxyUri 'http://127.0.0.1:7897' -ValidatedProxyUri 'http://127.0.0.1:7898'
    Assert-Equal 'EndpointChange' ([string]$endpointChange.Kind)
    Assert-True $endpointChange.RestartRequired
}

Invoke-Test 'Critical ChatGPT validation cannot be hidden by two unrelated successes' {
    $results = @(
        [pscustomobject]@{ Host = 'api.openai.com'; Passed = $true },
        [pscustomobject]@{ Host = 'chatgpt.com'; Passed = $false },
        [pscustomobject]@{ Host = 'auth.openai.com'; Passed = $true }
    )
    $decision = Get-CpgProxyValidationDecision -Results $results -MinimumSuccessCount 2 -RequiredHosts @('chatgpt.com')
    Assert-False $decision.Passed
    Assert-False $decision.CriticalTargetsPassed
    Assert-Equal 'chatgpt.com' ([string]$decision.CriticalFailures[0])

    $results[1].Passed = $true
    $healthy = Get-CpgProxyValidationDecision -Results $results -MinimumSuccessCount 2 -RequiredHosts @('chatgpt.com')
    Assert-True $healthy.Passed
    Assert-True $healthy.CriticalTargetsPassed
}

Invoke-Test 'Restart prompt requires an explicit Yes response' {
    $approved = Get-CpgRestartPromptDecision -PopupResult 6
    Assert-True $approved.Approved
    Assert-Equal 'approved' ([string]$approved.Reason)

    foreach ($result in @(7, -1, 0, 2)) {
        $decision = Get-CpgRestartPromptDecision -PopupResult $result
        Assert-False $decision.Approved
    }
    Assert-Equal 'declined' ([string](Get-CpgRestartPromptDecision -PopupResult 7).Reason)
    Assert-Equal 'timeout' ([string](Get-CpgRestartPromptDecision -PopupResult -1).Reason)
    Assert-Equal 'prompt_unavailable' ([string](Get-CpgRestartPromptDecision -PopupResult 0).Reason)
}

Invoke-Test 'Restart circuit breaker opens, remains open, and later recovers' {
    $now = [datetime]'2026-08-02T10:00:00Z'
    $history = @($now.AddMinutes(-8), $now.AddMinutes(-4), $now.AddMinutes(-1))
    $opened = Get-CpgRestartDecision -RestartHistory $history -Now $now -LimitCount 3 -WindowMinutes 10 -CircuitBreakerMinutes 15
    Assert-False $opened.Allowed
    Assert-Equal 'restart_limit_reached' ([string]$opened.Reason)
    Assert-True ($opened.CircuitBreakerUntil -eq $now.AddMinutes(15))

    $stillOpen = Get-CpgRestartDecision -RestartHistory $history -Now $now.AddMinutes(2) -LimitCount 3 -WindowMinutes 10 -CircuitBreakerMinutes 15 -CircuitBreakerUntil $opened.CircuitBreakerUntil
    Assert-False $stillOpen.Allowed
    Assert-Equal 'circuit_open' ([string]$stillOpen.Reason)

    $recovered = Get-CpgRestartDecision -RestartHistory $history -Now $now.AddMinutes(16) -LimitCount 3 -WindowMinutes 10 -CircuitBreakerMinutes 15 -CircuitBreakerUntil $opened.CircuitBreakerUntil
    Assert-True $recovered.Allowed
    Assert-Equal 0 @($recovered.RecentRestarts).Count
}

Invoke-Test 'HTTPS target responses require a usable non-server-error response' {
    Assert-True (Test-CpgProxyResponseStatus -StatusCode 200)
    Assert-True (Test-CpgProxyResponseStatus -StatusCode 401)
    Assert-True (Test-CpgProxyResponseStatus -StatusCode 403)
    Assert-False (Test-CpgProxyResponseStatus -StatusCode 500)
    Assert-False (Test-CpgProxyResponseStatus -StatusCode 407)
    Assert-False (Test-CpgProxyResponseStatus -StatusCode 0)
}

Invoke-Test 'Managed-root matching survives PID handoff' {
    $old = [pscustomobject]@{ ProcessId = 10; CommandLine = 'ChatGPT.exe --proxy-server=http://127.0.0.1:8080' }
    $new = [pscustomobject]@{ ProcessId = 99; CommandLine = 'ChatGPT.exe --proxy-server=http://127.0.0.1:8080' }
    Assert-True (Test-CpgRootUsesProxy -RootProcess $old -ProxyUri 'http://127.0.0.1:8080')
    Assert-True (Test-CpgRootUsesProxy -RootProcess $new -ProxyUri 'http://127.0.0.1:8080')
    Assert-False (Test-CpgRootUsesProxy -RootProcess $new -ProxyUri 'http://127.0.0.1:8081')
}

Invoke-Test 'Codex manifest selection prefers a configured app and known executable names' {
    $applications = @(
        [pscustomobject]@{ Id = 'Updater'; Executable = 'tools\Updater.exe'; EntryPoint = 'Windows.FullTrustApplication' },
        [pscustomobject]@{ Id = 'App'; Executable = 'app\ChatGPT.exe'; EntryPoint = 'Windows.FullTrustApplication' },
        [pscustomobject]@{ Id = 'Preview'; Executable = 'app\Preview.exe'; EntryPoint = 'Windows.FullTrustApplication' }
    )
    $ranked = @(Get-CpgCodexApplicationCandidates -Applications $applications)
    Assert-Equal 'App' ([string]$ranked[0].ApplicationId)
    Assert-Equal 'preferred_executable_name' ([string]$ranked[0].ResolutionMethod)

    $configured = @(Get-CpgCodexApplicationCandidates -Applications $applications -PreferredApplicationId 'Preview')
    Assert-Equal 'Preview' ([string]$configured[0].ApplicationId)
    Assert-Equal 'configured_application_id' ([string]$configured[0].ResolutionMethod)
}

Invoke-Test 'Proxy argument must be a complete token' {
    $root = [pscustomobject]@{ CommandLine = 'ChatGPT.exe --proxy-server=http://127.0.0.1:80800' }
    Assert-False (Test-CpgRootUsesProxy -RootProcess $root -ProxyUri 'http://127.0.0.1:8080')
}

Invoke-Test 'Codex root process requires an exact resolved path and no child type' {
    $app = [pscustomobject]@{ ExecutablePath = 'C:\Program Files\WindowsApps\Example\app.exe' }
    $root = [pscustomobject]@{ ExecutablePath = 'C:\Program Files\WindowsApps\Example\app.exe'; CommandLine = 'app.exe' }
    $child = [pscustomobject]@{ ExecutablePath = 'C:\Program Files\WindowsApps\Example\app.exe'; CommandLine = 'app.exe --type=renderer' }
    Assert-True (Test-CpgCodexRootProcess -Process $root -CodexApp $app)
    Assert-False (Test-CpgCodexRootProcess -Process $child -CodexApp $app)
}

Invoke-Test 'Install marker is bound to its canonical root' {
    $root = Join-Path $env:TEMP 'cpg-marker-test'
    $marker = [pscustomobject]@{ productId = 'CodexProxyGuardian'; installRoot = $root }
    Assert-True (Test-CpgInstallMarker -InstallRoot $root -Marker $marker)
    Assert-False (Test-CpgInstallMarker -InstallRoot (Join-Path $env:TEMP 'different-root') -Marker $marker)
    $marker.productId = 'SomethingElse'
    Assert-False (Test-CpgInstallMarker -InstallRoot $root -Marker $marker)
}

Invoke-Test 'Mandatory connectivity is staged before an existing guardian is stopped' {
    $installer = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'Install.ps1')
    $stagingIndex = $installer.IndexOf('CodexProxyGuardian-preflight-', [System.StringComparison]::Ordinal)
    $stopIndex = $installer.IndexOf("'stop.request'", [System.StringComparison]::Ordinal)
    Assert-True ($stagingIndex -ge 0) 'The staged connectivity gate is missing.'
    Assert-True ($stopIndex -gt $stagingIndex) 'The installer can stop an existing guardian before staged connectivity is checked.'
}

Invoke-Test 'Installer provisions settings and a verified-release update task' {
    $installer = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'Install.ps1')
    foreach ($required in @('Settings.ps1', 'Update.ps1', 'settingsShortcutPath', 'Codex Proxy Guardian Update', '-Install -Silent')) {
        Assert-True $installer.Contains($required) "Installer is missing update/settings payload: $required"
    }
    $updater = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'Update.ps1')
    Assert-True $updater.Contains('Get-FileHash') 'Updater does not calculate the downloaded archive hash.'
    Assert-True $updater.Contains('Get-CpgDeclaredSha256') 'Updater does not parse the published checksum.'
    Assert-True $updater.Contains('https://api.github.com/repos/$repository/releases') 'Updater is not bound to the expected GitHub Releases API.'
    Assert-True $updater.Contains('$repository = ''CH-ZHOU-0512/codex-proxy-guardian''') 'Updater repository identity is not fixed.'
    Assert-True $updater.Contains('previous-installation') 'Updater does not snapshot the current installation before replacement.'
    Assert-True $updater.Contains('Restore-PreviousInstallation') 'Updater does not expose a failed-install rollback path.'
    Assert-True $updater.Contains('The release archive exceeds the safe extraction limits.') 'Updater does not cap expanded release archives.'
    Assert-True $updater.Contains('The release archive contains an unsafe path:') 'Updater does not reject unsafe archive paths.'
    Assert-True $updater.Contains("'-PreserveUpdateTask'") 'Updater can replace its own running scheduled task during installation.'
    Assert-False $updater.Contains('::Replace($statusTemporaryPath, $updateStatusPath, $null') 'Windows PowerShell cannot bind an empty File.Replace backup path safely.'
    $control = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'Control.ps1')
    Assert-False $control.Contains('::Replace($temporaryPath, $configPath, $null') 'Mode changes use an invalid File.Replace backup path.'
}

Invoke-Test 'Codex package changes trigger owned verified updates and fail safe' {
    $watcher = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'src\Watch-CodexProxy.ps1')
    foreach ($required in @(
        'Request-CompatibilityUpdateCheck',
        'Test-CpgInstallMarker -InstallRoot $script:Root',
        'Start-ScheduledTask -TaskName $updateTaskName',
        "'codex_compatibility_update_requested'",
        "'codex_compatibility_review_required'",
        'failSafeNoRestartOnUnconfirmedAdapter',
        'codexCompatibilityFingerprint',
        'managed-streaming-contract-v2',
        'codexVersionInvalidatesPreviousEvidence',
        'managedLaunchAndFreshTrafficRequired'
    )) {
        Assert-True $watcher.Contains($required) "Watcher is missing compatibility automation: $required"
    }
    Assert-True $watcher.Contains('-not $script:CompatibilityHold -and $restartRequired') 'A compatibility hold does not block endpoint-change restarts.'
    Assert-True $watcher.Contains('-CompatibilityBlocked:$script:CompatibilityHold') 'External-launch decisions ignore the compatibility hold.'
}

Invoke-Test 'One-click installer embeds and safely verifies the exact release payload' {
    $bootstrapper = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'setup\Program.cs')
    foreach ($required in @(
        'CodexProxyGuardian.Payload.zip', '--verify', 'MaximumEntries', 'MaximumExpandedBytes',
        'MaximumEntryBytes', 'FileMode.CreateNew', 'GetManifestResourceStream',
        'The embedded payload VERSION does not match the installer.',
        'WindowsPowerShell\v1.0\powershell.exe', 'ExecutionPolicy Bypass',
        'ProgressBarStyle.Continuous', 'WorkerReportsProgress = true', 'TryParseProgress',
        'CPG_PROGRESS|', '-ProgressProtocol', 'RetryingGuardian'
    )) {
        Assert-True $bootstrapper.Contains($required) "One-click installer is missing safety behavior: $required"
    }
    Assert-False $bootstrapper.Contains('ProgressBarStyle.Marquee') 'One-click installer still uses an indeterminate spinner.'
    Assert-True $bootstrapper.Contains('targetPath.StartsWith(rootPrefix, StringComparison.OrdinalIgnoreCase)') 'One-click installer does not reject paths outside its temporary root.'
    Assert-True $bootstrapper.Contains('process.WaitForExit(10 * 60 * 1000)') 'One-click installer has no bounded wait for Install.ps1.'
    Assert-False ($bootstrapper -match '(?i)SetEnvironmentVariable|ProxyEnable|netsh\s+winhttp') 'One-click installer directly mutates network or persistent environment configuration.'

    $packager = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'tools\Package-Release.ps1')
    Assert-True $packager.Contains('CodexProxyGuardian-Setup-{0}.exe') 'Release packaging does not create the one-click installer.'
    Assert-True $packager.Contains('/resource:$zipPath,CodexProxyGuardian.Payload.zip') 'Release ZIP is not embedded as the installer payload.'
    Assert-True $packager.Contains('& $installerPath --verify') 'Packaged installer is not self-checked.'
	Assert-True $packager.Contains('package-posix.go') 'Release packaging does not create macOS/Linux archives.'

    $releaseWorkflow = Get-Content -Raw -LiteralPath (Join-Path $repoRoot '.github\workflows\release.yml')
	Assert-True $releaseWorkflow.Contains('Get-ChildItem -LiteralPath .\artifacts -File') 'GitHub Release does not publish all generated assets.'
	Assert-True $releaseWorkflow.Contains('Expected at least 12 release assets') 'GitHub Release does not enforce the complete cross-platform asset set.'
    Assert-True $releaseWorkflow.Contains("`$ErrorActionPreference = 'SilentlyContinue'") 'A missing first-time Release can terminate Windows PowerShell before the create branch.'
    Assert-True $releaseWorkflow.Contains('$releaseViewExitCode = $LASTEXITCODE') 'Release creation does not preserve the probe exit code.'
    Assert-True $releaseWorkflow.Contains('if ($releaseViewExitCode -eq 0)') 'Release creation still branches on a stale native exit code.'
}

Invoke-Test 'Installer progress protocol reports determinate stages' {
    $installer = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'Install.ps1')
    foreach ($required in @('[switch]$ProgressProtocol', 'Write-CpgInstallProgress', 'CPG_PROGRESS|{0}|{1}', "Write-CpgInstallProgress 100 '")) {
        Assert-True $installer.Contains($required) "Installer progress protocol is missing: $required"
    }

    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $testId = [Guid]::NewGuid().ToString('N')
    $testRoot = Join-Path $env:TEMP ('cpg-progress-preflight-' + $testId)
    $output = @(& $windowsPowerShell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'Install.ps1') -InstallRoot $testRoot -TaskName "CPG Test $testId" -RunValueName "CPGTest-$testId" -ShortcutName "CPG Test $testId.lnk" -SettingsShortcutName "CPG Settings Test $testId.lnk" -UpdateTaskName "CPG Update Test $testId" -AllowMissingCodex -PreflightOnly -ProgressProtocol 2>&1)
    $exitCode = $LASTEXITCODE
    Assert-Equal 0 $exitCode 'Installer progress preflight failed.'

    $progressLines = @($output | ForEach-Object { [string]$_ } | Where-Object { $_ -match '^CPG_PROGRESS\|\d+\|' })
    Assert-True ($progressLines.Count -ge 3) 'Installer did not emit enough progress stages.'
    foreach ($percent in @(30, 38, 100)) {
        Assert-Equal 1 @($progressLines | Where-Object { $_ -like "CPG_PROGRESS|$percent|*" }).Count "Installer did not emit progress stage $percent."
    }
    $progressPercents = @($progressLines | ForEach-Object { [int](($_ -split '\|', 3)[1]) })
    Assert-Equal '30,34,38,100' ($progressPercents -join ',') 'Installer preflight progress is incomplete or not monotonic.'

    $plainOutput = @(& $windowsPowerShell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'Install.ps1') -InstallRoot $testRoot -TaskName "CPG Test $testId" -RunValueName "CPGTest-$testId" -ShortcutName "CPG Test $testId.lnk" -SettingsShortcutName "CPG Settings Test $testId.lnk" -UpdateTaskName "CPG Update Test $testId" -AllowMissingCodex -PreflightOnly 2>&1)
    Assert-Equal 0 $LASTEXITCODE 'Plain installer preflight failed.'
    Assert-False (($plainOutput -join [Environment]::NewLine).Contains('CPG_PROGRESS|')) 'Manual script execution exposed the private installer progress protocol.'
}

Invoke-Test 'Installer verifies the started guardian and retries one unexpected exit' {
    $installer = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'Install.ps1')
    foreach ($required in @(
        'Test-CpgInstalledGuardianAlive',
        'for ($guardianStartAttempt = 1; $guardianStartAttempt -le 2; $guardianStartAttempt++)',
        "Write-CpgInstallProgress 98 'RetryingGuardian'",
        'Guardian did not remain running after two start attempts.'
    )) {
        Assert-True $installer.Contains($required) "Installer health retry is missing: $required"
    }
}

Invoke-Test 'Installer and health sampling understand streaming-safe evidence' {
    $installer = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'Install.ps1')
    Assert-True $installer.Contains("'SafeStreamingRepair'") 'Installer does not report the streaming-safe launch policy.'
    Assert-True $installer.Contains('HTTP traffic alone does not prove WebSocket proxy inheritance') 'Installer does not explain the guarded managed relaunch.'

    $healthSampler = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'tools\Measure-GuardianHealth.ps1')
    Assert-True $healthSampler.Contains("'ManagedTrafficObserved'") 'Health sampling ignores managed streaming traffic evidence.'
}

Invoke-Test 'Watcher publishes explicit lifecycle states' {
    $watcher = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'src\Watch-CodexProxy.ps1')
    foreach ($state in @('WaitingForProxy', 'Stabilizing', 'Ready', 'EvaluatingCodexLaunch', 'StreamingGuaranteeGrace', 'CodexNeedsManagedLaunch', 'CodexResolutionUnavailable', 'RecoveringCodex', 'RecoveryBlockedByCodex', 'RestartApprovalRequired', 'RestartDeferred', 'RestartCircuitOpen')) {
        Assert-True ($watcher.Contains("'$state'")) "Missing guardian lifecycle state: $state"
    }
    Assert-True $watcher.Contains('Show-CpgRestartApprovalDialog') 'Watcher does not contain the branded restart prompt.'
    Assert-True $watcher.Contains("'#F4F2EA'") 'Restart prompt does not use the Guardian paper background.'
    Assert-True $watcher.Contains("'#2F6B50'") 'Restart prompt does not use the Guardian green accent.'
    Assert-True $watcher.Contains("'#D7F06B'") 'Restart prompt does not use the Guardian highlight color.'
    $restartActionLabel = ('{0}{1}Codex' -f [char]0x91CD, [char]0x542F)
    $reminderActionLabel = ('{0}{1}{2}{3}{4}{5}{6}' -f [char]0x5206, [char]0x949F, [char]0x540E, [char]0x518D, [char]0x63D0, [char]0x9192, [char]0x6211)
    Assert-True ($watcher.Contains(("'" + $restartActionLabel + "'"))) 'Restart prompt does not use the direct restart action label.'
    Assert-True ($watcher.Contains($reminderActionLabel)) 'Restart prompt does not offer the explicit reminder action.'
    Assert-True $watcher.Contains('$form.CancelButton = $secondaryButton') 'Closing or cancelling the restart prompt is not fail-safe.'
    Assert-True $watcher.Contains('$form.MinimizeBox = $true') 'Restart prompt cannot be minimized.'
    Assert-True $watcher.Contains('SetThreadDpiAwarenessContext') 'Restart prompt does not opt into crisp per-monitor DPI rendering.'
    Assert-True $watcher.Contains('65860') 'System fallback is not an informational, default-No prompt.'
    Assert-False $watcher.Contains('69940') 'Legacy warning/system-modal prompt flags are still present.'
    Assert-True $watcher.Contains('Get-CpgRestartPromptDecision') 'Watcher does not require an explicit prompt decision.'
    Assert-True $watcher.Contains('safe_streaming_proxy_not_guaranteed') 'Watcher does not distinguish HTTP fallback from guaranteed streaming proxy injection.'
    Assert-True $watcher.Contains('[Math]::Max(60, $configuredSnoozeMinutes)') 'A declined streaming repair can prompt too frequently.'
    Assert-True $watcher.Contains('$script:LastProxyConnection = [datetime]::MinValue') 'A managed launch can reuse stale traffic evidence.'
    $restartCalls = @([regex]::Matches($watcher, '(?m)^\s*\$managedRootPid\s*=\s*Restart-CodexManaged\b[^\r\n]*'))
    Assert-True ($restartCalls.Count -ge 3) 'Expected all managed restart call paths to be present.'
    foreach ($restartCall in $restartCalls) {
        Assert-True $restartCall.Value.Contains('-ApprovalGranted') "A managed restart call bypasses approval: $($restartCall.Value.Trim())"
    }
    $stopCalls = @([regex]::Matches($watcher, '(?m)^\s*Stop-CodexDesktop\b[^\r\n]*'))
    Assert-Equal 1 $stopCalls.Count 'Codex shutdown must remain centralized behind the approval-guarded restart function.'
}

Invoke-Test 'Injected Codex proxy variables cannot feed back into discovery' {
    $watcher = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'src\Watch-CodexProxy.ps1')
    $start = $watcher.IndexOf('function Get-EnvironmentProxyCandidates', [System.StringComparison]::Ordinal)
    $end = $watcher.IndexOf('function Test-PreferredProxyProcess', [System.StringComparison]::Ordinal)
    Assert-True ($start -ge 0 -and $end -gt $start) 'Could not isolate environment discovery.'
    $environmentDiscovery = $watcher.Substring($start, $end - $start)
    Assert-True ($environmentDiscovery.Contains('$script:InheritedProxyEnvironment')) 'Environment discovery is not using its startup snapshot.'
    Assert-False ($environmentDiscovery.Contains('GetEnvironmentVariable')) 'Environment discovery can read proxy variables injected later for Codex.'
}

Invoke-Test 'Source contains no original-machine fingerprints' {
    $forbidden = @('Gzhou', 'POTATO', 'C:\VPN', '26.727.6591.0')
    $hits = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $repoRoot -Recurse -File | Where-Object { $_.Extension -ne '.exe' -and $_.FullName -notlike '*\.git\*' -and $_.FullName -notlike '*\artifacts\*' -and $_.FullName -notlike '*\tests\*' })) {
        $content = Get-Content -Raw -LiteralPath $file.FullName -ErrorAction SilentlyContinue
        foreach ($pattern in $forbidden) {
            if ($content -like "*$pattern*") { $hits += "$($file.FullName): $pattern" }
        }
    }
    Assert-Equal 0 $hits.Count ($hits -join [Environment]::NewLine)
}

Invoke-Test 'Public scripts do not mutate network configuration' {
    $forbiddenCommands = @('netsh winhttp set proxy', 'ProxyEnable\s*=', 'SetEnvironmentVariable\([^\r\n]+["''](?:User|Machine)["'']')
    $hits = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $repoRoot -Recurse -File | Where-Object { $_.Extension -in @('.ps1', '.psm1', '.vbs') -and $_.FullName -notlike '*\tests\*' })) {
        $content = Get-Content -Raw -LiteralPath $file.FullName
        foreach ($pattern in $forbiddenCommands) {
            if ($content -match $pattern) { $hits += "$($file.FullName): $pattern" }
        }
    }
    Assert-Equal 0 $hits.Count ($hits -join [Environment]::NewLine)
}

Invoke-Test 'Doctor emits a redacted, share-safe JSON report' {
    $diagnosticRoot = Join-Path $env:TEMP 'CodexProxyGuardian-Nonexistent-Diagnostics'
    $reportText = & (Join-Path $repoRoot 'Doctor.ps1') -InstallRoot $diagnosticRoot -Json
    $report = $reportText | ConvertFrom-Json
    Assert-True $report.safeForSharing
    Assert-Equal 8 ([int]$report.reportSchema)
    Assert-Equal 'CodexStreamRetryNotProofOfGuardianRestartOrEndpointFailure' ([string]$report.reconnectAttribution.meaning)
    Assert-False ([bool]$report.reconnectAttribution.providerNodeManagedByGuardian)
    Assert-False (($reportText -join '') -match [regex]::Escape($env:USERPROFILE)) 'The diagnostic report exposed the user profile path.'
    Assert-False (($reportText -join '') -match '(?i)"(?:activeProxy|systemProxy|proxyUri|proxyServer)"\s*:') 'The diagnostic report exposed a raw proxy field.'
}

Write-Host "`n$script:Passed passed, $script:Failed failed."
if ($script:Failed -gt 0) { throw "$script:Failed test(s) failed." }
