[CmdletBinding()]
param(
    [switch]$SelfTest,
    [switch]$RunOnce,
    [string]$ProxyOverride = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $script:Root 'CodexProxyGuardian.Core.psm1') -Force

$script:ConfigPath = Join-Path $script:Root 'config.json'
$script:LogsPath = Join-Path $script:Root 'logs'
$script:StatusPath = Join-Path $script:Root 'status.json'
$script:StatePath = Join-Path $script:Root 'state.json'
$script:StopRequestPath = Join-Path $script:Root 'stop.request'
$script:LaunchRequestPath = Join-Path $script:Root 'launch.request'
$script:AdoptRequestPath = Join-Path $script:Root 'adopt-current-once.request'
$script:ValidationCache = @{}

function Read-GuardianConfig {
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) {
        throw "Missing configuration file: $script:ConfigPath"
    }
    return (Get-Content -Raw -LiteralPath $script:ConfigPath | ConvertFrom-Json)
}

function Initialize-Logging {
    param($Config)

    if (-not (Test-Path -LiteralPath $script:LogsPath)) {
        New-Item -ItemType Directory -Path $script:LogsPath -Force | Out-Null
    }

    $retentionDays = [int](Get-CpgConfigValue $Config 'LogRetentionDays' 14)
    $maxFiles = [int](Get-CpgConfigValue $Config 'MaxLogFiles' 20)
    $maxBytes = [int64](Get-CpgConfigValue $Config 'MaxLogFileMB' 5) * 1MB
    $script:LogPath = Join-Path $script:LogsPath ("guardian-{0}.jsonl" -f (Get-Date -Format 'yyyyMMdd'))

    if ((Test-Path -LiteralPath $script:LogPath) -and (Get-Item -LiteralPath $script:LogPath).Length -ge $maxBytes) {
        $archive = Join-Path $script:LogsPath ("guardian-{0}.jsonl" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
        Move-Item -LiteralPath $script:LogPath -Destination $archive -Force
    }

    $cutoff = (Get-Date).AddDays(-$retentionDays)
    Get-ChildItem -LiteralPath $script:LogsPath -Filter 'guardian-*.jsonl' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        Remove-Item -Force -ErrorAction SilentlyContinue

    $files = @(Get-ChildItem -LiteralPath $script:LogsPath -Filter 'guardian-*.jsonl' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending)
    if ($files.Count -gt $maxFiles) {
        $files | Select-Object -Skip $maxFiles | Remove-Item -Force -ErrorAction SilentlyContinue
    }
}

function Write-GuardianLog {
    param(
        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')][string]$Level,
        [string]$Event,
        [string]$Message,
        [hashtable]$Data
    )

    if ($SelfTest) { return }
    $entry = [ordered]@{
        time = (Get-Date).ToUniversalTime().ToString('o')
        level = $Level
        event = $Event
        message = $Message
    }
    if ($null -ne $Data) {
        foreach ($key in $Data.Keys) { $entry[$key] = $Data[$key] }
    }
    Add-Content -LiteralPath $script:LogPath -Value ($entry | ConvertTo-Json -Compress -Depth 6) -Encoding UTF8
}

function Write-JsonAtomically {
    param([string]$Path, $Value)

    $temporaryPath = "$Path.tmp"
    $Value | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
}

function New-ProxyCandidate {
    param([string]$Uri, [string]$Source, [int]$Score)

    if ([string]::IsNullOrWhiteSpace($Uri)) { return $null }
    $parsed = [Uri]$Uri
    return [pscustomobject]@{
        Uri = $Uri
        Host = $parsed.Host
        Port = $parsed.Port
        Source = $Source
        Score = $Score
    }
}

function Get-SystemProxyCandidates {
    param($Config)

    $allowRemote = [bool](Get-CpgConfigValue $Config 'AllowNonLoopbackProxy' $false)
    $result = @()
    $explicitProxy = [string](Get-CpgConfigValue $Config 'ExplicitProxy' '')
    if (-not [string]::IsNullOrWhiteSpace($explicitProxy)) {
        $uri = ConvertTo-CpgHttpProxyUri -Address $explicitProxy -AllowNonLoopback:$allowRemote
        if ($null -ne $uri) { $result += New-ProxyCandidate $uri 'config:ExplicitProxy' 300 }
    }

    $settings = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
    if ($null -eq $settings -or [int](Get-CpgConfigValue $settings 'ProxyEnable' 0) -ne 1) { return $result }

    foreach ($item in @(ConvertFrom-CpgProxyServer -ProxyServer ([string](Get-CpgConfigValue $settings 'ProxyServer' '')) -AllowNonLoopback:$allowRemote)) {
        $result += New-ProxyCandidate ([string]$item.Uri) ("system:{0}" -f $item.Label) 200
    }
    $maximum = [Math]::Max(1, [int](Get-CpgConfigValue $Config 'MaxProcessProxyCandidates' 6))
    return @($result | Sort-Object -Property @{ Expression = 'Score'; Descending = $true }, @{ Expression = 'Port'; Ascending = $true } | Select-Object -First $maximum)
}

function Test-PreferredProxyProcess {
    param([string]$ProcessName, $Config)

    foreach ($pattern in @(Get-CpgConfigValue $Config 'PreferredProxyProcesses' @())) {
        if ($ProcessName -like [string]$pattern) { return $true }
    }
    return $false
}

function Get-ProcessProxyCandidates {
    param($Config)

    $result = @()
    $seen = @{}
    $preferredPorts = @((Get-CpgConfigValue $Config 'PreferredProxyPorts' @()) | ForEach-Object { [int]$_ })
    foreach ($connection in @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue)) {
        $process = Get-Process -Id $connection.OwningProcess -ErrorAction SilentlyContinue
        if ($null -eq $process -or -not (Test-PreferredProxyProcess $process.ProcessName $Config)) { continue }

        $hostName = [string]$connection.LocalAddress
        if ($hostName -eq '0.0.0.0') { $hostName = '127.0.0.1' }
        if ($hostName -eq '::') { $hostName = '::1' }
        if (-not (Test-CpgLoopbackHost -HostName $hostName)) { continue }

        $address = if ($hostName.Contains(':')) { "[$hostName]:$($connection.LocalPort)" } else { "$hostName`:$($connection.LocalPort)" }
        $uri = ConvertTo-CpgHttpProxyUri -Address $address
        if ($null -eq $uri -or $seen.ContainsKey($uri)) { continue }
        $seen[$uri] = $true

        $score = 100
        if ([int]$connection.LocalPort -in $preferredPorts) { $score += 20 }
        $result += New-ProxyCandidate $uri ("process:{0}" -f $process.ProcessName) $score
    }
    return $result
}

function Test-TcpEndpoint {
    param([string]$HostName, [int]$Port, [int]$TimeoutMilliseconds)

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMilliseconds, $false)) { return $false }
        $client.EndConnect($async)
        return $client.Connected
    }
    catch { return $false }
    finally { $client.Close() }
}

function Test-HttpProxy {
    param([string]$ProxyUri, [string[]]$TestUrls, [int]$TimeoutSeconds)

    Add-Type -AssemblyName System.Net.Http
    foreach ($testUrl in $TestUrls) {
        $handler = New-Object System.Net.Http.HttpClientHandler
        $client = $null
        $request = $null
        $response = $null
        try {
            $handler.UseProxy = $true
            $handler.Proxy = New-Object System.Net.WebProxy($ProxyUri, $false)
            $handler.UseDefaultCredentials = $false
            $client = New-Object System.Net.Http.HttpClient($handler)
            $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
            $request = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Head, $testUrl)
            $response = $client.SendAsync($request).GetAwaiter().GetResult()
            $statusCode = [int]$response.StatusCode
            if ($statusCode -ge 200 -and $statusCode -lt 500 -and $statusCode -ne 407) { return $true }
        }
        catch { }
        finally {
            if ($null -ne $response) { $response.Dispose() }
            if ($null -ne $request) { $request.Dispose() }
            if ($null -ne $client) { $client.Dispose() } else { $handler.Dispose() }
        }
    }
    return $false
}

function Test-ProxyCandidate {
    param($Candidate, $Config)

    $tcpTimeout = [int](Get-CpgConfigValue $Config 'TcpTimeoutMilliseconds' 1500)
    if (-not (Test-TcpEndpoint $Candidate.Host $Candidate.Port $tcpTimeout)) {
        $script:ValidationCache.Remove($Candidate.Uri)
        return $false
    }

    $interval = [int](Get-CpgConfigValue $Config 'HttpValidationIntervalSeconds' 30)
    if ($script:ValidationCache.ContainsKey($Candidate.Uri)) {
        $cached = $script:ValidationCache[$Candidate.Uri]
        if ($cached.Valid -and ((Get-Date) - $cached.CheckedAt).TotalSeconds -lt $interval) { return $true }
    }

    $urls = @((Get-CpgConfigValue $Config 'ProxyTestUrls' @('https://api.openai.com/v1/models')) | ForEach-Object {
        $testUri = $null
        if ([Uri]::TryCreate([string]$_, [UriKind]::Absolute, [ref]$testUri) -and $testUri.Scheme -eq 'https') { [string]$_ }
    } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($urls.Count -eq 0) { throw 'ProxyTestUrls must contain at least one absolute HTTPS URL.' }
    $valid = Test-HttpProxy $Candidate.Uri $urls ([int](Get-CpgConfigValue $Config 'HttpTimeoutSeconds' 8))
    $script:ValidationCache[$Candidate.Uri] = [pscustomobject]@{ Valid = $valid; CheckedAt = Get-Date }
    return $valid
}

function Find-EffectiveProxy {
    param($Config)

    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($ProxyOverride)) {
        $allowRemote = [bool](Get-CpgConfigValue $Config 'AllowNonLoopbackProxy' $false)
        $uri = ConvertTo-CpgHttpProxyUri -Address $ProxyOverride -AllowNonLoopback:$allowRemote
        if ($null -ne $uri) { $candidates += New-ProxyCandidate $uri 'parameter:ProxyOverride' 400 }
    }
    $candidates += @(Get-SystemProxyCandidates $Config)
    $candidates += @(Get-ProcessProxyCandidates $Config)

    $seen = @{}
    foreach ($candidate in @($candidates | Sort-Object Score -Descending)) {
        if ($null -eq $candidate -or $seen.ContainsKey($candidate.Uri)) { continue }
        $seen[$candidate.Uri] = $true
        if (Test-ProxyCandidate $candidate $Config) { return $candidate }
    }
    return $null
}

function Get-CodexRootProcesses {
    param($CodexApp)

    if ($null -eq $CodexApp) { return @() }
    $name = [string]$CodexApp.ProcessName
    $escapedName = $name.Replace("'", "''")
    $result = @()
    foreach ($process in @(Get-CimInstance Win32_Process -Filter ("Name='{0}'" -f $escapedName) -ErrorAction SilentlyContinue)) {
        if (Test-CpgCodexRootProcess -Process $process -CodexApp $CodexApp) { $result += $process }
    }
    return $result
}

function Set-ScopedProxyEnvironment {
    param([string]$ProxyUri, $Config)

    $noProxy = [string](Get-CpgConfigValue $Config 'NoProxy' 'localhost,127.0.0.1,::1')
    foreach ($name in @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy')) {
        [Environment]::SetEnvironmentVariable($name, $ProxyUri, 'Process')
    }
    foreach ($name in @('NO_PROXY', 'no_proxy')) {
        [Environment]::SetEnvironmentVariable($name, $noProxy, 'Process')
    }
}

function Start-CodexManaged {
    param([string]$ProxyUri, $Config, $CodexApp)

    if ($null -eq $CodexApp -or -not (Test-Path -LiteralPath $CodexApp.ExecutablePath)) {
        throw 'The configured Codex MSIX application could not be resolved.'
    }

    Set-ScopedProxyEnvironment $ProxyUri $Config
    $arguments = @()
    if ([bool](Get-CpgConfigValue $Config 'UseChromiumProxyArgument' $true)) {
        $arguments += "--proxy-server=$ProxyUri"
        $arguments += '--proxy-bypass-list=localhost;127.0.0.1;[::1]'
    }

    $parameters = @{
        FilePath = [string]$CodexApp.ExecutablePath
        WorkingDirectory = Split-Path -Parent ([string]$CodexApp.ExecutablePath)
        PassThru = $true
    }
    if ($arguments.Count -gt 0) { $parameters.ArgumentList = $arguments }
    $process = Start-Process @parameters
    Write-GuardianLog 'INFO' 'codex_started' 'Codex was launched with the validated proxy.' @{
        pid = $process.Id
        proxy = Protect-CpgProxyUri $ProxyUri
        package = [string]$CodexApp.PackageName
    }
    return $process.Id
}

function Get-ProcessTreeIds {
    param([int[]]$RootIds)

    $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    $depthById = @{}
    $queue = New-Object System.Collections.Queue
    foreach ($rootId in $RootIds) { $depthById[$rootId] = 0; $queue.Enqueue($rootId) }
    while ($queue.Count -gt 0) {
        $parentId = [int]$queue.Dequeue()
        foreach ($child in @($all | Where-Object { $_.ParentProcessId -eq $parentId })) {
            if (-not $depthById.ContainsKey([int]$child.ProcessId)) {
                $depthById[[int]$child.ProcessId] = [int]$depthById[$parentId] + 1
                $queue.Enqueue([int]$child.ProcessId)
            }
        }
    }
    return @($depthById.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { [int]$_.Key })
}

function Stop-CodexDesktop {
    param([int[]]$RootIds, $Config)

    foreach ($rootId in $RootIds) {
        $process = Get-Process -Id $rootId -ErrorAction SilentlyContinue
        if ($null -ne $process) { [void]$process.CloseMainWindow() }
    }

    $deadline = (Get-Date).AddSeconds([int](Get-CpgConfigValue $Config 'GracefulCloseSeconds' 10))
    do {
        $remaining = @($RootIds | Where-Object { $null -ne (Get-Process -Id $_ -ErrorAction SilentlyContinue) })
        if ($remaining.Count -eq 0) { return }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)

    foreach ($processId in @(Get-ProcessTreeIds $RootIds)) {
        Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
    }
}

function Restart-CodexManaged {
    param($Roots, [string]$ProxyUri, $Config, $CodexApp)

    $rootIds = @($Roots | ForEach-Object { [int]$_.ProcessId })
    Write-GuardianLog 'INFO' 'codex_restart' 'Restarting Codex after a stable proxy change.' @{
        old_pids = $rootIds
        proxy = Protect-CpgProxyUri $ProxyUri
    }
    Stop-CodexDesktop $rootIds $Config
    Start-Sleep -Milliseconds 750
    return Start-CodexManaged $ProxyUri $Config $CodexApp
}

function Save-PersistentState {
    param([string]$ActiveProxy, [string]$ActiveSource, [datetime]$LastRestart)

    $restartText = $null
    if ($LastRestart -ne [datetime]::MinValue) { $restartText = $LastRestart.ToUniversalTime().ToString('o') }
    Write-JsonAtomically $script:StatePath ([ordered]@{
        activeProxy = $ActiveProxy
        activeSource = $ActiveSource
        lastRestartUtc = $restartText
        updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    })
}

function Read-PersistentState {
    if (-not (Test-Path -LiteralPath $script:StatePath)) { return $null }
    try { return Get-Content -Raw -LiteralPath $script:StatePath | ConvertFrom-Json } catch { return $null }
}

function Get-MutexName {
    $bytes = [Text.Encoding]::UTF8.GetBytes(([System.IO.Path]::GetFullPath($script:Root)).ToLowerInvariant())
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').Substring(0, 16) }
    finally { $sha.Dispose() }
    return "Local\CodexProxyGuardian_$hash"
}

$config = Read-GuardianConfig
$codexApp = Get-CpgCodexApp -Config $config

if ($SelfTest) {
    $candidate = Find-EffectiveProxy $config
    [pscustomobject]@{
        ProxyValid = ($null -ne $candidate)
        Proxy = if ($null -eq $candidate) { $null } else { Protect-CpgProxyUri $candidate.Uri }
        ProxySource = if ($null -eq $candidate) { $null } else { $candidate.Source }
        CodexInstalled = ($null -ne $codexApp)
        CodexPackage = if ($null -eq $codexApp) { $null } else { $codexApp.PackageName }
        SystemProxyModified = $false
    } | ConvertTo-Json -Depth 4
    if ($null -eq $candidate) { exit 2 }
    if ($null -eq $codexApp) { exit 3 }
    exit 0
}

Initialize-Logging $config
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, (Get-MutexName), [ref]$createdNew)
if (-not $createdNew) {
    Write-GuardianLog 'INFO' 'duplicate_instance' 'Another guardian instance already owns this installation.' @{}
    $mutex.Dispose()
    exit 0
}

$pollSeconds = [Math]::Max(2, [int](Get-CpgConfigValue $config 'PollSeconds' 5))
$stableSamples = [Math]::Max(1, [int](Get-CpgConfigValue $config 'StableSamples' 3))
$debounceSeconds = [Math]::Max(0, [int](Get-CpgConfigValue $config 'DebounceSeconds' 10))
$externalDebounceSeconds = [Math]::Max(0, [int](Get-CpgConfigValue $config 'ExternalLaunchDebounceSeconds' 15))
$restartCooldownSeconds = [Math]::Max(10, [int](Get-CpgConfigValue $config 'RestartCooldownSeconds' 45))
$unavailableLogSeconds = [Math]::Max(30, [int](Get-CpgConfigValue $config 'UnavailableLogIntervalSeconds' 300))
$manageExternalLaunches = [bool](Get-CpgConfigValue $config 'ManageExternalCodexLaunches' $false)

$persistentState = Read-PersistentState
$previousActiveProxy = ''
if ($null -ne $persistentState) { $previousActiveProxy = [string](Get-CpgConfigValue $persistentState 'activeProxy' '') }
$activeProxy = $null
$activeSource = $null
$pendingProxy = $null
$pendingSince = [datetime]::MinValue
$pendingSamples = 0
$managedRootPid = 0
$pendingExternalPid = 0
$pendingExternalSince = [datetime]::MinValue
$lastRestart = [datetime]::MinValue
if ($null -ne $persistentState) {
    $lastRestartText = [string](Get-CpgConfigValue $persistentState 'lastRestartUtc' '')
    if (-not [string]::IsNullOrWhiteSpace($lastRestartText)) {
        try { $lastRestart = ([datetime]::Parse($lastRestartText)).ToLocalTime() } catch { $lastRestart = [datetime]::MinValue }
    }
}
$restartRequired = $false
$consecutiveErrors = 0
$lastUnavailableLog = [datetime]::MinValue

if (Test-Path -LiteralPath $script:AdoptRequestPath) {
    Remove-Item -LiteralPath $script:AdoptRequestPath -Force -ErrorAction SilentlyContinue
    $existing = @(Get-CodexRootProcesses $codexApp)
    if ($existing.Count -gt 0) {
        $managedRootPid = [int]$existing[0].ProcessId
        Write-GuardianLog 'INFO' 'initial_adoption' 'The existing Codex session was adopted without restart.' @{ pid = $managedRootPid }
    }
}

Write-GuardianLog 'INFO' 'guardian_started' 'Codex Proxy Guardian started.' @{
    version = '0.1.0-alpha'
    pid = $PID
    mode = [string](Get-CpgConfigValue $config 'Mode' 'Safe')
    package_found = ($null -ne $codexApp)
}

try {
    while ($true) {
        try {
            if (Test-Path -LiteralPath $script:StopRequestPath) {
                Remove-Item -LiteralPath $script:StopRequestPath -Force -ErrorAction SilentlyContinue
                Write-GuardianLog 'INFO' 'guardian_stop' 'Stop request received.' @{}
                break
            }

            if ($null -eq $codexApp) { $codexApp = Get-CpgCodexApp -Config $config }
            $candidate = Find-EffectiveProxy $config
            $proxyIsValid = $false
            if ($null -ne $candidate) {
                if ($pendingProxy -eq $candidate.Uri) { $pendingSamples++ }
                else {
                    $pendingProxy = $candidate.Uri
                    $pendingSince = Get-Date
                    $pendingSamples = 1
                    Write-GuardianLog 'INFO' 'proxy_candidate' 'A valid proxy candidate is being debounced.' @{
                        proxy = Protect-CpgProxyUri $candidate.Uri
                        source = $candidate.Source
                    }
                }

                if ($pendingSamples -ge $stableSamples -and ((Get-Date) - $pendingSince).TotalSeconds -ge $debounceSeconds) {
                    if ($activeProxy -ne $candidate.Uri) {
                        $oldProxy = $null
                        if ($null -ne $activeProxy) { $oldProxy = $activeProxy }
                        elseif (-not [string]::IsNullOrWhiteSpace($previousActiveProxy)) { $oldProxy = $previousActiveProxy }

                        $activeProxy = $candidate.Uri
                        $activeSource = $candidate.Source
                        if ($null -ne $oldProxy -and $oldProxy -ne $activeProxy) {
                            $restartRequired = $true
                            Write-GuardianLog 'INFO' 'proxy_changed' 'The validated proxy endpoint changed after debounce.' @{
                                old_proxy = Protect-CpgProxyUri $oldProxy
                                new_proxy = Protect-CpgProxyUri $activeProxy
                                source = $activeSource
                            }
                        }
                        else {
                            Write-GuardianLog 'INFO' 'proxy_active' 'The validated proxy endpoint became active.' @{
                                proxy = Protect-CpgProxyUri $activeProxy
                                source = $activeSource
                            }
                        }
                        $previousActiveProxy = $activeProxy
                        Save-PersistentState $activeProxy $activeSource $lastRestart
                    }
                    else { $activeSource = $candidate.Source }
                }
                $proxyIsValid = ($activeProxy -eq $candidate.Uri)
            }
            else {
                $pendingProxy = $null
                $pendingSamples = 0
                if (((Get-Date) - $lastUnavailableLog).TotalSeconds -ge $unavailableLogSeconds) {
                    Write-GuardianLog 'WARN' 'proxy_unavailable' 'No candidate passed listener and HTTPS validation; Codex was left untouched.' @{}
                    $lastUnavailableLog = Get-Date
                }
            }

            $roots = @(Get-CodexRootProcesses $codexApp)
            $rootIds = @($roots | ForEach-Object { [int]$_.ProcessId })
            $matchingRoots = @()
            if ($proxyIsValid) {
                $useArgument = [bool](Get-CpgConfigValue $config 'UseChromiumProxyArgument' $true)
                $matchingRoots = @($roots | Where-Object { Test-CpgRootUsesProxy $_ $activeProxy $useArgument })
            }
            if ($matchingRoots.Count -gt 0) {
                $managedRootPid = [int]$matchingRoots[0].ProcessId
                $pendingExternalPid = 0
            }
            elseif ($managedRootPid -ne 0 -and $managedRootPid -notin $rootIds) { $managedRootPid = 0 }

            if ($restartRequired -and $proxyIsValid -and $roots.Count -gt 0 -and $null -ne $codexApp) {
                if (((Get-Date) - $lastRestart).TotalSeconds -ge $restartCooldownSeconds) {
                    $managedRootPid = Restart-CodexManaged $roots $activeProxy $config $codexApp
                    $lastRestart = Get-Date
                    $restartRequired = $false
                    $pendingExternalPid = 0
                    Save-PersistentState $activeProxy $activeSource $lastRestart
                }
            }

            if ($manageExternalLaunches -and $proxyIsValid -and $roots.Count -gt 0 -and $matchingRoots.Count -eq 0 -and -not $restartRequired) {
                $externalPid = [int]$roots[0].ProcessId
                if ($pendingExternalPid -ne $externalPid) {
                    $pendingExternalPid = $externalPid
                    $pendingExternalSince = Get-Date
                    Write-GuardianLog 'INFO' 'unmanaged_codex' 'A Codex root missing the current proxy argument is being debounced.' @{ pid = $externalPid }
                }
                elseif (((Get-Date) - $pendingExternalSince).TotalSeconds -ge $externalDebounceSeconds -and ((Get-Date) - $lastRestart).TotalSeconds -ge $restartCooldownSeconds) {
                    $managedRootPid = Restart-CodexManaged $roots $activeProxy $config $codexApp
                    $lastRestart = Get-Date
                    $pendingExternalPid = 0
                    Save-PersistentState $activeProxy $activeSource $lastRestart
                }
            }
            elseif ($roots.Count -eq 0 -or $matchingRoots.Count -gt 0) { $pendingExternalPid = 0 }

            if (Test-Path -LiteralPath $script:LaunchRequestPath) {
                if ($roots.Count -gt 0) { Remove-Item -LiteralPath $script:LaunchRequestPath -Force -ErrorAction SilentlyContinue }
                elseif ($proxyIsValid -and $null -ne $codexApp) {
                    Remove-Item -LiteralPath $script:LaunchRequestPath -Force -ErrorAction SilentlyContinue
                    $managedRootPid = Start-CodexManaged $activeProxy $config $codexApp
                }
            }

            Write-JsonAtomically $script:StatusPath ([ordered]@{
                running = $true
                guardianPid = $PID
                updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
                mode = [string](Get-CpgConfigValue $config 'Mode' 'Safe')
                activeProxy = $activeProxy
                activeSource = $activeSource
                activeProxyValid = $proxyIsValid
                pendingProxy = $pendingProxy
                pendingSamples = $pendingSamples
                codexInstalled = ($null -ne $codexApp)
                codexPackageVersion = if ($null -eq $codexApp) { $null } else { $codexApp.Version }
                codexRunning = ($roots.Count -gt 0)
                codexRootPids = $rootIds
                managedCodexRootPid = if ($managedRootPid -eq 0) { $null } else { $managedRootPid }
                codexProxyArgumentMatch = ($matchingRoots.Count -gt 0)
                restartRequired = $restartRequired
                systemProxyModified = $false
            })

            $consecutiveErrors = 0
            if ($RunOnce) { break }
            Start-Sleep -Seconds $pollSeconds
        }
        catch {
            $consecutiveErrors++
            $delay = [Math]::Min(60, [Math]::Max($pollSeconds, [Math]::Pow(2, [Math]::Min($consecutiveErrors, 5))))
            Write-GuardianLog 'ERROR' 'loop_error' $_.Exception.Message @{ retry_seconds = $delay; consecutive_errors = $consecutiveErrors }
            if ($RunOnce) { throw }
            Start-Sleep -Seconds ([int]$delay)
        }
    }
}
finally {
    Write-GuardianLog 'INFO' 'guardian_stopped' 'Codex Proxy Guardian stopped.' @{}
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
