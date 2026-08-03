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
    Assert-True $config.UseChromiumProxyArgument
    Assert-True ([int]$config.RestartCooldownSeconds -ge 10)
    Assert-True ([int]$config.RestartLimitCount -le 3)
    Assert-True ([int]$config.RecoveryLaunchRetrySeconds -ge 5)
    Assert-True ([int]$config.MinimumSuccessfulProxyTests -ge 2)
    Assert-True ([int]$config.MinimumSuccessfulProxyTests -le @($config.ProxyTestUrls).Count)
    foreach ($url in @($config.ProxyTestUrls)) { Assert-True ([string]$url).StartsWith('https://', [System.StringComparison]::OrdinalIgnoreCase) }
}

Invoke-Test 'Safe external launches are repaired only after an evidence grace period' {
    $waiting = Get-CpgExternalLaunchDecision -Mode Safe -SafeRepairEnabled:$true -ProxyValid:$true -ArgumentMatches:$false -TrafficObserved:$false -PendingSeconds 19 -SafeGraceSeconds 20
    Assert-Equal 'Wait' ([string]$waiting.Action)
    Assert-Equal 'safe_evidence_grace' ([string]$waiting.Reason)

    $working = Get-CpgExternalLaunchDecision -Mode Safe -SafeRepairEnabled:$true -ProxyValid:$true -ArgumentMatches:$false -TrafficObserved:$true -PendingSeconds 30 -SafeGraceSeconds 20
    Assert-Equal 'Keep' ([string]$working.Action)
    Assert-Equal 'safe_proxy_traffic_observed' ([string]$working.Reason)

    $repair = Get-CpgExternalLaunchDecision -Mode Safe -SafeRepairEnabled:$true -ProxyValid:$true -ArgumentMatches:$false -TrafficObserved:$false -PendingSeconds 20 -SafeGraceSeconds 20
    Assert-Equal 'Repair' ([string]$repair.Action)

    $enforced = Get-CpgExternalLaunchDecision -Mode Enforce -ProxyValid:$true -ArgumentMatches:$false -TrafficObserved:$true -PendingSeconds 15 -EnforceDebounceSeconds 15
    Assert-Equal 'Repair' ([string]$enforced.Action)
    Assert-Equal 'enforce_missing_proxy_argument' ([string]$enforced.Reason)
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
}

Invoke-Test 'Release checksum parser accepts only a leading SHA-256 digest' {
    $hash = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
    Assert-Equal $hash (Get-CpgDeclaredSha256 "$hash  CodexProxyGuardian.zip")
    Assert-Null (Get-CpgDeclaredSha256 'sha256: invalid')
    Assert-Null (Get-CpgDeclaredSha256 "prefix $hash")
}

Invoke-Test 'Configuration migration adds defaults without replacing user choices' {
    $config = [pscustomobject]@{ Mode = 'Enforce'; PollSeconds = 12; UpdateChannel = 'Prerelease' }
    $defaults = [pscustomobject]@{ Mode = 'Safe'; PollSeconds = 5; CircuitBreakerMinutes = 15; UpdateChannel = 'Stable' }
    $merged = Update-CpgConfigDefaults -Config $config -Defaults $defaults
    Assert-Equal 'Enforce' ([string]$merged.Mode)
    Assert-Equal 12 ([int]$merged.PollSeconds)
    Assert-Equal 15 ([int]$merged.CircuitBreakerMinutes)
    Assert-Equal 'Prerelease' ([string]$merged.UpdateChannel)
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

Invoke-Test 'Proxy scheme and explicit port are required' {
    Assert-Null (ConvertTo-CpgHttpProxyUri -Address 'socks5://127.0.0.1:1080')
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
    Assert-Equal 2 $items.Count
    Assert-Equal 'https' ([string]$items[0].Label)
    Assert-Equal 'http://127.0.0.1:9000' ([string]$items[0].Uri)
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

Invoke-Test 'Watcher publishes explicit lifecycle states' {
    $watcher = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'src\Watch-CodexProxy.ps1')
    foreach ($state in @('WaitingForProxy', 'Stabilizing', 'Ready', 'EvaluatingCodexLaunch', 'CodexNeedsManagedLaunch', 'CodexResolutionUnavailable', 'RecoveringCodex', 'RecoveryBlockedByCodex', 'RestartCircuitOpen')) {
        Assert-True ($watcher.Contains("'$state'")) "Missing guardian lifecycle state: $state"
    }
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
    foreach ($file in @(Get-ChildItem -LiteralPath $repoRoot -Recurse -File | Where-Object { $_.FullName -notlike '*\.git\*' -and $_.FullName -notlike '*\artifacts\*' -and $_.FullName -notlike '*\tests\*' })) {
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
    Assert-Equal 3 ([int]$report.reportSchema)
    Assert-False (($reportText -join '') -match [regex]::Escape($env:USERPROFILE)) 'The diagnostic report exposed the user profile path.'
    Assert-False (($reportText -join '') -match '(?i)"(?:activeProxy|systemProxy|proxyUri|proxyServer)"\s*:') 'The diagnostic report exposed a raw proxy field.'
}

Write-Host "`n$script:Passed passed, $script:Failed failed."
if ($script:Failed -gt 0) { throw "$script:Failed test(s) failed." }
