[CmdletBinding()]
param(
    [switch]$SelfTest,
    [switch]$RunOnce,
    [switch]$ObserveOnly,
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
$script:ConfigReloadRequestPath = Join-Path $script:Root 'config.reload.request'
$script:ValidationCache = @{}
$script:ProxyAddressCache = @{}
$script:PACDiscoveryCache = $null
$script:InheritedProxyEnvironment = @{}
foreach ($proxyVariableName in @('HTTPS_PROXY', 'https_proxy', 'HTTP_PROXY', 'http_proxy', 'ALL_PROXY', 'all_proxy')) {
    $script:InheritedProxyEnvironment[$proxyVariableName] = [Environment]::GetEnvironmentVariable($proxyVariableName, 'Process')
}

function Read-GuardianConfig {
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) {
        throw "Missing configuration file: $script:ConfigPath"
    }
    $config = Get-Content -Raw -LiteralPath $script:ConfigPath | ConvertFrom-Json
    $defaultsPath = Join-Path $script:Root 'config.default.json'
    if (Test-Path -LiteralPath $defaultsPath) {
        $defaults = Get-Content -Raw -LiteralPath $defaultsPath | ConvertFrom-Json
        $config = Update-CpgConfigDefaults -Config $config -Defaults $defaults
    }
    return $config
}

function Get-GuardianVersion {
    foreach ($versionPath in @(
        (Join-Path $script:Root 'VERSION'),
        (Join-Path (Split-Path -Parent $script:Root) 'VERSION')
    )) {
        if (Test-Path -LiteralPath $versionPath) {
            $value = (Get-Content -Raw -LiteralPath $versionPath).Trim()
            if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
        }
    }

    $markerPath = Join-Path $script:Root '.cpg-install.json'
    if (Test-Path -LiteralPath $markerPath) {
        try {
            $value = [string](Get-Content -Raw -LiteralPath $markerPath | ConvertFrom-Json).version
            if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
        }
        catch { }
    }
    return 'development'
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

function Initialize-CpgWinHttpAutoProxy {
    if ($null -ne ('CodexProxyGuardian.WinHttpAutoProxy' -as [type])) { return }

    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace CodexProxyGuardian {
    public static class WinHttpAutoProxy {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct CurrentUserProxyConfig {
            [MarshalAs(UnmanagedType.Bool)] public bool AutoDetect;
            public IntPtr AutoConfigUrl;
            public IntPtr Proxy;
            public IntPtr ProxyBypass;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct AutoProxyOptions {
            public uint Flags;
            public uint AutoDetectFlags;
            public IntPtr AutoConfigUrl;
            public IntPtr Reserved;
            public uint ReservedFlags;
            [MarshalAs(UnmanagedType.Bool)] public bool AutoLogonIfChallenged;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct ProxyInfo {
            public uint AccessType;
            public IntPtr Proxy;
            public IntPtr ProxyBypass;
        }

        [DllImport("winhttp.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern IntPtr WinHttpOpen(string userAgent, uint accessType, string proxyName, string proxyBypass, uint flags);
        [DllImport("winhttp.dll", SetLastError = true)]
        private static extern bool WinHttpCloseHandle(IntPtr handle);
        [DllImport("winhttp.dll", SetLastError = true)]
        private static extern bool WinHttpSetTimeouts(IntPtr handle, int resolve, int connect, int send, int receive);
        [DllImport("winhttp.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern bool WinHttpGetIEProxyConfigForCurrentUser(out CurrentUserProxyConfig config);
        [DllImport("winhttp.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern bool WinHttpGetProxyForUrl(IntPtr session, string url, ref AutoProxyOptions options, out ProxyInfo info);
        [DllImport("kernel32.dll")]
        private static extern IntPtr GlobalFree(IntPtr memory);

        private static void Free(IntPtr memory) {
            if (memory != IntPtr.Zero) GlobalFree(memory);
        }

        public static string Resolve(string targetUrl, string explicitPac, bool allowWpad, int timeoutMilliseconds) {
            CurrentUserProxyConfig current = new CurrentUserProxyConfig();
            bool haveCurrent = WinHttpGetIEProxyConfigForCurrentUser(out current);
            string systemPac = haveCurrent && current.AutoConfigUrl != IntPtr.Zero ? Marshal.PtrToStringUni(current.AutoConfigUrl) : null;
            bool autoDetect = haveCurrent && current.AutoDetect && allowWpad;
            if (haveCurrent) {
                Free(current.AutoConfigUrl);
                Free(current.Proxy);
                Free(current.ProxyBypass);
            }
            string pac = String.IsNullOrWhiteSpace(explicitPac) ? systemPac : explicitPac;
            if (String.IsNullOrWhiteSpace(pac) && !autoDetect) return null;

            IntPtr session = WinHttpOpen("CodexProxyGuardian", 1, null, null, 0);
            if (session == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            IntPtr pacPointer = IntPtr.Zero;
            ProxyInfo info = new ProxyInfo();
            try {
                WinHttpSetTimeouts(session, timeoutMilliseconds, timeoutMilliseconds, timeoutMilliseconds, timeoutMilliseconds);
                AutoProxyOptions options = new AutoProxyOptions();
                if (!String.IsNullOrWhiteSpace(pac)) {
                    options.Flags |= 0x2;
                    pacPointer = Marshal.StringToHGlobalUni(pac);
                    options.AutoConfigUrl = pacPointer;
                }
                if (autoDetect) {
                    options.Flags |= 0x1;
                    options.AutoDetectFlags = 0x3;
                }
                options.AutoLogonIfChallenged = true;
                if (!WinHttpGetProxyForUrl(session, targetUrl, ref options, out info)) return null;
                return info.Proxy == IntPtr.Zero ? null : Marshal.PtrToStringUni(info.Proxy);
            }
            finally {
                if (pacPointer != IntPtr.Zero) Marshal.FreeHGlobal(pacPointer);
                Free(info.Proxy);
                Free(info.ProxyBypass);
                WinHttpCloseHandle(session);
            }
        }
    }
}
'@
}

function Get-PacProxyCandidates {
    param($Config)

    if (-not [bool](Get-CpgConfigValue $Config 'EnablePACDiscovery' $true)) { return @() }
    Initialize-CpgWinHttpAutoProxy
    $explicitPac = [string](Get-CpgConfigValue $Config 'ExplicitPAC' '')
    $allowWpad = [bool](Get-CpgConfigValue $Config 'EnableWPADDiscovery' $true)
    $allowRemote = if ([string]::IsNullOrWhiteSpace($explicitPac)) {
        [bool](Get-CpgConfigValue $Config 'AllowSystemNonLoopbackProxy' $true)
    }
    else { [bool](Get-CpgConfigValue $Config 'AllowNonLoopbackProxy' $false) }
    $timeout = [int](Get-CpgConfigValue $Config 'PacFetchTimeoutSeconds' 5) * 1000
    $cacheMinutes = [Math]::Max(1, [int](Get-CpgConfigValue $Config 'PacCacheMinutes' 5))
    $internetSettings = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
    $systemPacMarker = if ($null -eq $internetSettings) { '' } else { [string](Get-CpgConfigValue $internetSettings 'AutoConfigURL' '') }
    $cacheKey = "{0}|{1}|{2}|{3}|{4}" -f $explicitPac, $systemPacMarker, $allowWpad, $allowRemote, (@(Get-CpgConfigValue $Config 'ProxyTestUrls' @()) -join ',')
    if ($null -ne $script:PACDiscoveryCache -and $script:PACDiscoveryCache.Key -eq $cacheKey -and
        ((Get-Date) - $script:PACDiscoveryCache.CheckedAt).TotalMinutes -lt $cacheMinutes) {
        return @($script:PACDiscoveryCache.Candidates)
    }
    $result = @()
    $seen = @{}
    $targetIndex = 0
    foreach ($target in @(Get-CpgConfigValue $Config 'ProxyTestUrls' @())) {
        $targetIndex++
        $targetUri = $null
        if (-not [Uri]::TryCreate([string]$target, [UriKind]::Absolute, [ref]$targetUri) -or $targetUri.Scheme -ne 'https') { continue }
        $resolved = $null
        try { $resolved = [CodexProxyGuardian.WinHttpAutoProxy]::Resolve([string]$target, $explicitPac, $allowWpad, $timeout) }
        catch { continue }
        foreach ($item in @(ConvertFrom-CpgPacResult -Result ([string]$resolved) -AllowNonLoopback:$allowRemote)) {
            if ($seen.ContainsKey([string]$item.Uri)) { continue }
            $seen[[string]$item.Uri] = $true
            $source = if ([string]::IsNullOrWhiteSpace($explicitPac)) { 'system:pac-wpad' } else { 'config:ExplicitPAC' }
            $result += New-ProxyCandidate ([string]$item.Uri) ("{0}:target-{1}" -f $source, $targetIndex) (280 - $targetIndex)
        }
    }
    $script:PACDiscoveryCache = [pscustomobject]@{ Key = $cacheKey; CheckedAt = Get-Date; Candidates = @($result) }
    return $result
}

function Get-SystemProxyCandidates {
    param($Config)

    $allowRemote = [bool](Get-CpgConfigValue $Config 'AllowNonLoopbackProxy' $false)
    $allowSystemRemote = [bool](Get-CpgConfigValue $Config 'AllowSystemNonLoopbackProxy' $true)
    $result = @()
    $explicitProxy = [string](Get-CpgConfigValue $Config 'ExplicitProxy' '')
    if (-not [string]::IsNullOrWhiteSpace($explicitProxy)) {
        $uri = ConvertTo-CpgProxyUri -Address $explicitProxy -AllowNonLoopback:$allowRemote
        if ($null -ne $uri) { $result += New-ProxyCandidate $uri 'config:ExplicitProxy' 300 }
    }

    $result += @(Get-PacProxyCandidates $Config)

    $settings = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
    if ($null -eq $settings -or [int](Get-CpgConfigValue $settings 'ProxyEnable' 0) -ne 1) { return $result }

    foreach ($item in @(ConvertFrom-CpgProxyServer -ProxyServer ([string](Get-CpgConfigValue $settings 'ProxyServer' '')) -AllowNonLoopback:$allowSystemRemote)) {
        $score = switch ([string]$item.Label) {
            'https' { 220 }
            'http' { 210 }
            default { 200 }
        }
        $result += New-ProxyCandidate ([string]$item.Uri) ("system:{0}" -f $item.Label) $score
    }
    return $result
}

function Get-EnvironmentProxyCandidates {
    param($Config)

    if (-not [bool](Get-CpgConfigValue $Config 'EnableEnvironmentProxyDiscovery' $true)) { return @() }
    $allowRemote = [bool](Get-CpgConfigValue $Config 'AllowNonLoopbackProxy' $false)
    $result = @()
    $score = 190
    foreach ($name in @('HTTPS_PROXY', 'https_proxy', 'HTTP_PROXY', 'http_proxy', 'ALL_PROXY', 'all_proxy')) {
        $value = $script:InheritedProxyEnvironment[$name]
        $uri = ConvertTo-CpgProxyUri -Address ([string]$value) -AllowNonLoopback:$allowRemote
        if ($null -ne $uri) { $result += New-ProxyCandidate $uri ("environment:{0}" -f $name) $score }
        $score--
    }
    return $result
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
        $score = 100
        if ([int]$connection.LocalPort -in $preferredPorts) { $score += 20 }
        foreach ($proxyAddress in @($address, "socks5h://$address")) {
            $uri = ConvertTo-CpgProxyUri -Address $proxyAddress
            if ($null -eq $uri -or $seen.ContainsKey($uri)) { continue }
            $seen[$uri] = $true
            $schemePenalty = if ($uri.StartsWith('socks5h://', [System.StringComparison]::OrdinalIgnoreCase)) { 5 } else { 0 }
            $sourceSuffix = if ($schemePenalty -gt 0) { ':socks5' } else { '' }
            $result += New-ProxyCandidate $uri ("process:{0}{1}" -f $process.ProcessName, $sourceSuffix) ($score - $schemePenalty)
        }
    }
    $maximum = [Math]::Max(1, [int](Get-CpgConfigValue $Config 'MaxProcessProxyCandidates' 6)) * 2
    return @($result | Sort-Object -Property @{ Expression = 'Score'; Descending = $true }, @{ Expression = 'Port'; Ascending = $true }, @{ Expression = 'Uri'; Ascending = $true } | Select-Object -First $maximum)
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
    param([string]$ProxyUri, [string[]]$TestUrls, [int]$TimeoutSeconds, [int]$MinimumSuccessCount)

    Add-Type -AssemblyName System.Net.Http
    $results = @()
    $successCount = 0
    $required = [Math]::Min($TestUrls.Count, [Math]::Max(1, $MinimumSuccessCount))
    $attemptedCount = 0
    foreach ($testUrl in $TestUrls) {
        $attemptedCount++
        $handler = New-Object System.Net.Http.HttpClientHandler
        $client = $null
        $request = $null
        $response = $null
        $statusCode = $null
        $passed = $false
        $failureType = $null
        try {
            $handler.UseProxy = $true
            $handler.Proxy = New-Object System.Net.WebProxy($ProxyUri, $false)
            $handler.UseDefaultCredentials = $false
            $client = New-Object System.Net.Http.HttpClient($handler)
            $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
            $request = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Head, $testUrl)
            $response = $client.SendAsync($request).GetAwaiter().GetResult()
            $statusCode = [int]$response.StatusCode
            $passed = Test-CpgProxyResponseStatus -StatusCode $statusCode
        }
        catch { $failureType = $_.Exception.GetType().Name }
        finally {
            if ($null -ne $response) { $response.Dispose() }
            if ($null -ne $request) { $request.Dispose() }
            if ($null -ne $client) { $client.Dispose() } else { $handler.Dispose() }
        }
        if ($passed) { $successCount++ }
        $results += [pscustomobject]@{
            Host = ([Uri]$testUrl).Host
            Passed = $passed
            StatusCode = $statusCode
            FailureType = $failureType
        }
        if ($successCount -ge $required) { break }
        if (($successCount + ($TestUrls.Count - $attemptedCount)) -lt $required) { break }
    }
    return [pscustomobject]@{
        Passed = ($successCount -ge $required)
        SuccessCount = $successCount
        RequiredCount = $required
        TargetCount = $TestUrls.Count
        AttemptedCount = $attemptedCount
        Results = $results
    }
}

function Test-Socks5Proxy {
    param([string]$ProxyUri, [string[]]$TestUrls, [int]$TimeoutSeconds, [int]$MinimumSuccessCount)

    $results = @()
    $successCount = 0
    $required = [Math]::Min($TestUrls.Count, [Math]::Max(1, $MinimumSuccessCount))
    $attemptedCount = 0
    $curlPath = Join-Path $env:SystemRoot 'System32\curl.exe'
    foreach ($testUrl in $TestUrls) {
        $attemptedCount++
        $statusCode = $null
        $passed = $false
        $failureType = $null
        if (-not (Test-Path -LiteralPath $curlPath -PathType Leaf)) {
            $failureType = 'CurlUnavailable'
        }
        else {
            try {
                $output = & $curlPath '--silent' '--show-error' '--output=NUL' '--write-out=%{http_code}' '--noproxy=' ("--proxy=$ProxyUri") ("--connect-timeout=$TimeoutSeconds") ("--max-time=$TimeoutSeconds") ("--url=$testUrl") 2>$null
                [int]$parsedStatusCode = 0
                if ($LASTEXITCODE -eq 0 -and [int]::TryParse(([string]$output).Trim(), [ref]$parsedStatusCode)) {
                    $statusCode = $parsedStatusCode
                    $passed = Test-CpgProxyResponseStatus -StatusCode $statusCode
                }
                else { $failureType = 'CurlProxyRequestFailed' }
            }
            catch { $failureType = $_.Exception.GetType().Name }
        }
        if ($passed) { $successCount++ }
        $results += [pscustomobject]@{ Host = ([Uri]$testUrl).Host; Passed = $passed; StatusCode = $statusCode; FailureType = $failureType }
        if ($successCount -ge $required) { break }
        if (($successCount + ($TestUrls.Count - $attemptedCount)) -lt $required) { break }
    }
    return [pscustomobject]@{
        Passed = ($successCount -ge $required)
        SuccessCount = $successCount
        RequiredCount = $required
        TargetCount = $TestUrls.Count
        AttemptedCount = $attemptedCount
        Results = $results
    }
}

function Test-ProxyCandidate {
    param($Candidate, $Config)

    $tcpTimeout = [int](Get-CpgConfigValue $Config 'TcpTimeoutMilliseconds' 1500)
    if (-not (Test-TcpEndpoint $Candidate.Host $Candidate.Port $tcpTimeout)) {
        $script:ValidationCache.Remove($Candidate.Uri)
        $Candidate | Add-Member -MemberType NoteProperty -Name ValidationResult -Value ([pscustomobject]@{ Passed = $false; SuccessCount = 0; RequiredCount = 1; TargetCount = 0; AttemptedCount = 0; Results = @() }) -Force
        return $false
    }

    $interval = [int](Get-CpgConfigValue $Config 'HttpValidationIntervalSeconds' 30)
    if ($script:ValidationCache.ContainsKey($Candidate.Uri)) {
        $cached = $script:ValidationCache[$Candidate.Uri]
        if (((Get-Date) - $cached.CheckedAt).TotalSeconds -lt $interval) {
            $Candidate | Add-Member -MemberType NoteProperty -Name ValidationResult -Value $cached.Result -Force
            return [bool]$cached.Valid
        }
    }

    $urls = @((Get-CpgConfigValue $Config 'ProxyTestUrls' @('https://api.openai.com/v1/models')) | ForEach-Object {
        $testUri = $null
        if ([Uri]::TryCreate([string]$_, [UriKind]::Absolute, [ref]$testUri) -and $testUri.Scheme -eq 'https') { [string]$_ }
    } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($urls.Count -eq 0) { throw 'ProxyTestUrls must contain at least one absolute HTTPS URL.' }
    $minimum = [int](Get-CpgConfigValue $Config 'MinimumSuccessfulProxyTests' 1)
    $proxyScheme = ([Uri]$Candidate.Uri).Scheme.ToLowerInvariant()
    $validation = if ($proxyScheme -in @('socks5', 'socks5h')) {
        Test-Socks5Proxy $Candidate.Uri $urls ([int](Get-CpgConfigValue $Config 'HttpTimeoutSeconds' 8)) $minimum
    }
    else {
        Test-HttpProxy $Candidate.Uri $urls ([int](Get-CpgConfigValue $Config 'HttpTimeoutSeconds' 8)) $minimum
    }
    $Candidate | Add-Member -MemberType NoteProperty -Name ValidationResult -Value $validation -Force
    $script:ValidationCache[$Candidate.Uri] = [pscustomobject]@{ Valid = [bool]$validation.Passed; CheckedAt = Get-Date; Result = $validation }
    return [bool]$validation.Passed
}

function Find-EffectiveProxy {
    param($Config, [string]$PreferredUri = '')

    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($ProxyOverride)) {
        $allowRemote = [bool](Get-CpgConfigValue $Config 'AllowNonLoopbackProxy' $false)
        $uri = ConvertTo-CpgProxyUri -Address $ProxyOverride -AllowNonLoopback:$allowRemote
        if ($null -ne $uri) { $candidates += New-ProxyCandidate $uri 'parameter:ProxyOverride' 400 }
    }
    $candidates += @(Get-SystemProxyCandidates $Config)
    $candidates += @(Get-EnvironmentProxyCandidates $Config)
    $candidates += @(Get-ProcessProxyCandidates $Config)

    $seen = @{}
    foreach ($candidate in @(Select-CpgProxyCandidates -Candidates $candidates -PreferredUri $PreferredUri)) {
        if ($null -eq $candidate -or $seen.ContainsKey($candidate.Uri)) { continue }
        $seen[$candidate.Uri] = $true
        if (Test-ProxyCandidate $candidate $Config) { return $candidate }
    }
    return $null
}

function Get-CodexRootProcesses {
    param($CodexApps)

    $apps = @($CodexApps | Where-Object { $null -ne $_ })
    if ($apps.Count -eq 0) { return @() }
    $result = @()
    $seen = @{}
    foreach ($name in @($apps | ForEach-Object { [string]$_.ProcessName } | Sort-Object -Unique)) {
        $escapedName = $name.Replace("'", "''")
        foreach ($process in @(Get-CimInstance Win32_Process -Filter ("Name='{0}'" -f $escapedName) -ErrorAction SilentlyContinue)) {
            if ($seen.ContainsKey([int]$process.ProcessId)) { continue }
            foreach ($app in $apps) {
                if (Test-CpgCodexRootProcess -Process $process -CodexApp $app) {
                    $seen[[int]$process.ProcessId] = $true
                    $result += $process
                    break
                }
            }
        }
    }
    return $result
}

function Set-ScopedProxyEnvironment {
    param([string]$ProxyUri, $Config)

    $noProxy = [string](Get-CpgConfigValue $Config 'NoProxy' 'localhost,127.0.0.1,::1')
    foreach ($name in @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'WS_PROXY', 'WSS_PROXY', 'http_proxy', 'https_proxy', 'all_proxy', 'ws_proxy', 'wss_proxy')) {
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
        $arguments += "--proxy-server=$(ConvertTo-CpgChromiumProxyUri -ProxyUri $ProxyUri)"
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

function Test-CodexProxyTraffic {
    param([int[]]$RootIds, [string]$ProxyUri)

    if ($RootIds.Count -eq 0 -or [string]::IsNullOrWhiteSpace($ProxyUri)) { return $false }
    $uri = [Uri]$ProxyUri
    $proxyHost = $uri.Host.Trim('[', ']')
    $proxyAddresses = @()
    $proxyAddress = $null
    if ([System.Net.IPAddress]::TryParse($proxyHost, [ref]$proxyAddress)) { $proxyAddresses = @($proxyAddress) }
    elseif (Test-CpgLoopbackHost -HostName $proxyHost) { $proxyAddresses = @([System.Net.IPAddress]::Loopback, [System.Net.IPAddress]::IPv6Loopback) }
    else {
        $cacheKey = $proxyHost.ToLowerInvariant()
        $cachedAddresses = if ($script:ProxyAddressCache.ContainsKey($cacheKey)) { $script:ProxyAddressCache[$cacheKey] } else { $null }
        if ($null -eq $cachedAddresses -or ((Get-Date) - $cachedAddresses.CheckedAt).TotalMinutes -ge 5) {
            $resolvedAddresses = @()
            try {
                $resolutionTask = [System.Net.Dns]::GetHostAddressesAsync($proxyHost)
                if ($resolutionTask.Wait(1500)) { $resolvedAddresses = @($resolutionTask.Result) }
            }
            catch { $resolvedAddresses = @() }
            $cachedAddresses = [pscustomobject]@{ CheckedAt = Get-Date; Addresses = $resolvedAddresses }
            $script:ProxyAddressCache[$cacheKey] = $cachedAddresses
        }
        $proxyAddresses = @($cachedAddresses.Addresses)
    }
    if ($proxyAddresses.Count -eq 0) { return $false }

    $processIds = @(Get-ProcessTreeIds $RootIds)
    foreach ($connection in @(Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue | Where-Object {
        [int]$_.OwningProcess -in $processIds -and [int]$_.RemotePort -eq $uri.Port
    })) {
        $remote = $null
        if (-not [System.Net.IPAddress]::TryParse([string]$connection.RemoteAddress, [ref]$remote)) { continue }
        if ((Test-CpgLoopbackHost -HostName $proxyHost) -and [System.Net.IPAddress]::IsLoopback($remote)) { return $true }
        foreach ($expectedAddress in $proxyAddresses) {
            if ($remote.Equals($expectedAddress) -or $remote.MapToIPv6().Equals($expectedAddress.MapToIPv6())) { return $true }
        }
    }
    return $false
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

    if ($null -eq $CodexApp -or -not (Test-Path -LiteralPath ([string]$CodexApp.ExecutablePath))) {
        throw 'Codex was left running because a replacement MSIX executable could not be resolved.'
    }

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
    $circuitText = $null
    if ($script:CircuitBreakerUntil -gt [datetime]::MinValue) { $circuitText = $script:CircuitBreakerUntil.ToUniversalTime().ToString('o') }
    $trafficText = $null
    if ($script:LastProxyConnection -gt [datetime]::MinValue) { $trafficText = $script:LastProxyConnection.ToUniversalTime().ToString('o') }
    Write-JsonAtomically $script:StatePath ([ordered]@{
        activeProxy = $ActiveProxy
        activeSource = $ActiveSource
        lastRestartUtc = $restartText
        restartHistoryUtc = @($script:RestartHistory | ForEach-Object { $_.ToUniversalTime().ToString('o') })
        circuitBreakerUntilUtc = $circuitText
        lastProxyConnectionUtc = $trafficText
        recoveryLaunchRequired = $script:RecoveryLaunchRequired
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
$codexApps = @($codexApp | Where-Object { $null -ne $_ })
$lastCodexResolve = Get-Date

if ($SelfTest) {
    $candidate = Find-EffectiveProxy $config
    $validation = if ($null -eq $candidate) { $null } else { $candidate.ValidationResult }
    [pscustomobject]@{
        ProxyValid = ($null -ne $candidate)
        Proxy = if ($null -eq $candidate) { $null } else { Protect-CpgProxyUri $candidate.Uri }
        ProxySource = if ($null -eq $candidate) { $null } else { $candidate.Source }
        ProxyTestSuccessCount = if ($null -eq $validation) { 0 } else { $validation.SuccessCount }
        ProxyTestRequiredCount = if ($null -eq $validation) { [int](Get-CpgConfigValue $config 'MinimumSuccessfulProxyTests' 1) } else { $validation.RequiredCount }
        ProxyTestTargetCount = if ($null -eq $validation) { @((Get-CpgConfigValue $config 'ProxyTestUrls' @())).Count } else { $validation.TargetCount }
        ProxyTestAttemptedCount = if ($null -eq $validation) { 0 } else { $validation.AttemptedCount }
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
if ($RunOnce) { $stableSamples = 1; $debounceSeconds = 0 }
$externalDebounceSeconds = [Math]::Max(0, [int](Get-CpgConfigValue $config 'ExternalLaunchDebounceSeconds' 15))
$safeExternalGraceSeconds = [Math]::Max(10, [int](Get-CpgConfigValue $config 'SafeExternalLaunchGraceSeconds' 20))
$restartCooldownSeconds = [Math]::Max(10, [int](Get-CpgConfigValue $config 'RestartCooldownSeconds' 45))
$restartLimitCount = [Math]::Max(1, [int](Get-CpgConfigValue $config 'RestartLimitCount' 3))
$restartLimitWindowMinutes = [Math]::Max(1, [int](Get-CpgConfigValue $config 'RestartLimitWindowMinutes' 10))
$circuitBreakerMinutes = [Math]::Max(1, [int](Get-CpgConfigValue $config 'CircuitBreakerMinutes' 15))
$recoveryLaunchRetrySeconds = [Math]::Max(5, [int](Get-CpgConfigValue $config 'RecoveryLaunchRetrySeconds' 10))
$codexResolveIntervalSeconds = [Math]::Max(10, [int](Get-CpgConfigValue $config 'CodexResolveIntervalSeconds' 60))
$trafficEvidenceWindowSeconds = [Math]::Max(30, [int](Get-CpgConfigValue $config 'ProxyConnectionEvidenceWindowSeconds' 300))
$unavailableLogSeconds = [Math]::Max(30, [int](Get-CpgConfigValue $config 'UnavailableLogIntervalSeconds' 300))
$guardianMode = [string](Get-CpgConfigValue $config 'Mode' 'Safe')
$manageExternalLaunches = ($guardianMode -eq 'Enforce' -or [bool](Get-CpgConfigValue $config 'ManageExternalCodexLaunches' $false)) -and -not $ObserveOnly
$safeRepairExternalLaunches = $guardianMode -eq 'Safe' -and [bool](Get-CpgConfigValue $config 'SafeRepairExternalCodexLaunches' $true) -and -not $ObserveOnly
$externalLaunchPolicy = if ($ObserveOnly) { 'ObserveOnly' } elseif ($manageExternalLaunches) { 'Enforce' } elseif ($safeRepairExternalLaunches) { 'SafeEvidenceRepair' } else { 'ManagedShortcutOnly' }
$guardianVersion = Get-GuardianVersion

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
$pendingExternalTrafficObserved = $false
$externalLaunchState = 'NoCodex'
$lastRestart = [datetime]::MinValue
$script:RestartHistory = @()
$script:CircuitBreakerUntil = [datetime]::MinValue
$script:LastProxyConnection = [datetime]::MinValue
$script:RecoveryLaunchRequired = $false
if ($null -ne $persistentState) {
    $lastRestartText = [string](Get-CpgConfigValue $persistentState 'lastRestartUtc' '')
    if (-not [string]::IsNullOrWhiteSpace($lastRestartText)) {
        try { $lastRestart = ([datetime]::Parse($lastRestartText)).ToLocalTime() } catch { $lastRestart = [datetime]::MinValue }
    }
    foreach ($historyText in @(Get-CpgConfigValue $persistentState 'restartHistoryUtc' @())) {
        try { $script:RestartHistory += ([datetime]::Parse([string]$historyText)).ToLocalTime() } catch { }
    }
    $circuitText = [string](Get-CpgConfigValue $persistentState 'circuitBreakerUntilUtc' '')
    if (-not [string]::IsNullOrWhiteSpace($circuitText)) {
        try { $script:CircuitBreakerUntil = ([datetime]::Parse($circuitText)).ToLocalTime() } catch { $script:CircuitBreakerUntil = [datetime]::MinValue }
    }
    $trafficText = [string](Get-CpgConfigValue $persistentState 'lastProxyConnectionUtc' '')
    if (-not [string]::IsNullOrWhiteSpace($trafficText)) {
        try { $script:LastProxyConnection = ([datetime]::Parse($trafficText)).ToLocalTime() } catch { $script:LastProxyConnection = [datetime]::MinValue }
    }
    $script:RecoveryLaunchRequired = [bool](Get-CpgConfigValue $persistentState 'recoveryLaunchRequired' $false)
}
$restartRequired = $false
$consecutiveErrors = 0
$lastUnavailableLog = [datetime]::MinValue

function Test-GuardianRestartBudget {
    $decision = Get-CpgRestartDecision -RestartHistory $script:RestartHistory -Now (Get-Date) `
        -LimitCount $restartLimitCount -WindowMinutes $restartLimitWindowMinutes `
        -CircuitBreakerMinutes $circuitBreakerMinutes -CircuitBreakerUntil $script:CircuitBreakerUntil
    $script:RestartHistory = @($decision.RecentRestarts)
    if ($decision.Allowed) {
        $script:CircuitBreakerUntil = [datetime]::MinValue
        return $true
    }

    if ($decision.CircuitBreakerUntil -ne $script:CircuitBreakerUntil) {
        $script:CircuitBreakerUntil = $decision.CircuitBreakerUntil
        Write-GuardianLog 'ERROR' 'restart_circuit_opened' 'The restart-rate limit was reached. No further Codex lifecycle action will occur until the circuit breaker expires.' @{
            recent_restarts = @($decision.RecentRestarts).Count
            retry_after_utc = $script:CircuitBreakerUntil.ToUniversalTime().ToString('o')
        }
        Save-PersistentState $activeProxy $activeSource $lastRestart
    }
    return $false
}

function Register-GuardianRestart {
    param([datetime]$When)
    $cutoff = $When.AddMinutes(-$restartLimitWindowMinutes)
    $script:RestartHistory = @($script:RestartHistory | Where-Object { $_ -ge $cutoff }) + @($When)
    $script:CircuitBreakerUntil = [datetime]::MinValue
}

if (Test-Path -LiteralPath $script:AdoptRequestPath) {
    Remove-Item -LiteralPath $script:AdoptRequestPath -Force -ErrorAction SilentlyContinue
    $existing = @(Get-CodexRootProcesses $codexApps)
    if ($existing.Count -gt 0) {
        $managedRootPid = [int]$existing[0].ProcessId
        Write-GuardianLog 'INFO' 'initial_adoption' 'The existing Codex session was adopted without restart.' @{ pid = $managedRootPid }
    }
}

Write-GuardianLog 'INFO' 'guardian_started' 'Codex Proxy Guardian started.' @{
    version = $guardianVersion
    pid = $PID
    mode = if ($ObserveOnly) { 'ObserveOnly' } else { $guardianMode }
    external_launch_policy = $externalLaunchPolicy
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

            if (Test-Path -LiteralPath $script:ConfigReloadRequestPath) {
                $updatedConfig = Read-GuardianConfig
                $updatedMode = [string](Get-CpgConfigValue $updatedConfig 'Mode' 'Safe')
                $updatedManageExternal = ($updatedMode -eq 'Enforce' -or [bool](Get-CpgConfigValue $updatedConfig 'ManageExternalCodexLaunches' $false)) -and -not $ObserveOnly
                $updatedSafeRepair = $updatedMode -eq 'Safe' -and [bool](Get-CpgConfigValue $updatedConfig 'SafeRepairExternalCodexLaunches' $true) -and -not $ObserveOnly
                $updatedPolicy = if ($ObserveOnly) { 'ObserveOnly' } elseif ($updatedManageExternal) { 'Enforce' } elseif ($updatedSafeRepair) { 'SafeEvidenceRepair' } else { 'ManagedShortcutOnly' }
                $config.Mode = $updatedMode
                $config.ManageExternalCodexLaunches = [bool](Get-CpgConfigValue $updatedConfig 'ManageExternalCodexLaunches' $false)
                $config.SafeRepairExternalCodexLaunches = [bool](Get-CpgConfigValue $updatedConfig 'SafeRepairExternalCodexLaunches' $true)
                $guardianMode = $updatedMode
                $manageExternalLaunches = $updatedManageExternal
                $safeRepairExternalLaunches = $updatedSafeRepair
                $externalLaunchPolicy = $updatedPolicy
                $pendingExternalPid = 0
                $pendingExternalSince = [datetime]::MinValue
                $pendingExternalTrafficObserved = $false
                Remove-Item -LiteralPath $script:ConfigReloadRequestPath -Force -ErrorAction SilentlyContinue
                Write-GuardianLog 'INFO' 'mode_reloaded' 'The selected user mode was reloaded without restarting Guardian or Codex.' @{
                    mode = $guardianMode
                    external_launch_policy = $externalLaunchPolicy
                }
            }

            if ($null -eq $codexApp -or -not (Test-Path -LiteralPath ([string]$codexApp.ExecutablePath)) -or ((Get-Date) - $lastCodexResolve).TotalSeconds -ge $codexResolveIntervalSeconds) {
                $resolvedApp = Get-CpgCodexApp -Config $config
                $lastCodexResolve = Get-Date
                if ($null -ne $resolvedApp) {
                    $appChanged = $null -eq $codexApp -or -not [string]::Equals([string]$codexApp.ExecutablePath, [string]$resolvedApp.ExecutablePath, [System.StringComparison]::OrdinalIgnoreCase)
                    $codexApp = $resolvedApp
                    if (@($codexApps | Where-Object { [string]::Equals([string]$_.ExecutablePath, [string]$resolvedApp.ExecutablePath, [System.StringComparison]::OrdinalIgnoreCase) }).Count -eq 0) {
                        $codexApps = @($codexApps) + @($resolvedApp)
                        $codexApps = @($codexApps | Select-Object -Last 3)
                    }
                    if ($appChanged) {
                        Write-GuardianLog 'INFO' 'codex_package_refreshed' 'The current Codex MSIX executable was refreshed from its package manifest.' @{
                            package = [string]$resolvedApp.PackageName
                            version = [string]$resolvedApp.Version
                        }
                    }
                }
                elseif ($null -ne $codexApp -and -not (Test-Path -LiteralPath ([string]$codexApp.ExecutablePath))) { $codexApp = $null }
            }

            $preferredProxy = if (-not [string]::IsNullOrWhiteSpace($activeProxy)) { $activeProxy } else { $previousActiveProxy }
            $candidate = Find-EffectiveProxy $config $preferredProxy
            $currentValidation = if ($null -eq $candidate) { $null } else { $candidate.ValidationResult }
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
                            $script:LastProxyConnection = [datetime]::MinValue
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

            $roots = @(Get-CodexRootProcesses $codexApps)
            $rootIds = @($roots | ForEach-Object { [int]$_.ProcessId })
            $matchingRoots = @()
            if ($proxyIsValid) {
                $useArgument = [bool](Get-CpgConfigValue $config 'UseChromiumProxyArgument' $true)
                $matchingRoots = @($roots | Where-Object { Test-CpgRootUsesProxy $_ $activeProxy $useArgument })
            }
            if ($matchingRoots.Count -gt 0) {
                $managedRootPid = [int]$matchingRoots[0].ProcessId
                $pendingExternalPid = 0
                if ($script:RecoveryLaunchRequired) {
                    $script:RecoveryLaunchRequired = $false
                    Save-PersistentState $activeProxy $activeSource $lastRestart
                    Write-GuardianLog 'INFO' 'codex_restart_confirmed' 'The relaunched Codex root was observed with the current proxy argument.' @{ pid = $managedRootPid }
                }
            }
            elseif ($managedRootPid -ne 0 -and $managedRootPid -notin $rootIds) { $managedRootPid = 0 }

            $trafficObservedNow = $false
            if ($proxyIsValid -and $roots.Count -gt 0) {
                $trafficObservedNow = Test-CodexProxyTraffic -RootIds $rootIds -ProxyUri $activeProxy
                if ($trafficObservedNow) {
                    $previousTrafficObservation = $script:LastProxyConnection
                    $script:LastProxyConnection = Get-Date
                    if ($previousTrafficObservation -eq [datetime]::MinValue -or ($script:LastProxyConnection - $previousTrafficObservation).TotalSeconds -ge 60) {
                        Save-PersistentState $activeProxy $activeSource $lastRestart
                    }
                }
            }
            $trafficObservedRecently = $script:LastProxyConnection -gt [datetime]::MinValue -and ((Get-Date) - $script:LastProxyConnection).TotalSeconds -le $trafficEvidenceWindowSeconds

            if (-not $ObserveOnly -and $script:RecoveryLaunchRequired -and $proxyIsValid -and $roots.Count -eq 0 -and $null -ne $codexApp) {
                if (((Get-Date) - $lastRestart).TotalSeconds -ge $recoveryLaunchRetrySeconds -and (Test-GuardianRestartBudget)) {
                    $lastRestart = Get-Date
                    Register-GuardianRestart $lastRestart
                    Save-PersistentState $activeProxy $activeSource $lastRestart
                    Write-GuardianLog 'WARN' 'codex_recovery_retry' 'Retrying a managed Codex launch after the previous relaunch was not confirmed.' @{
                        proxy = Protect-CpgProxyUri $activeProxy
                        attempt_count = @($script:RestartHistory).Count
                    }
                    $managedRootPid = Start-CodexManaged $activeProxy $config $codexApp
                    $restartRequired = $false
                }
            }

            if (-not $ObserveOnly -and $restartRequired -and $proxyIsValid -and $roots.Count -gt 0 -and $null -ne $codexApp) {
                if (((Get-Date) - $lastRestart).TotalSeconds -ge $restartCooldownSeconds -and (Test-GuardianRestartBudget)) {
                    $lastRestart = Get-Date
                    Register-GuardianRestart $lastRestart
                    $script:RecoveryLaunchRequired = $true
                    Save-PersistentState $activeProxy $activeSource $lastRestart
                    $managedRootPid = Restart-CodexManaged $roots $activeProxy $config $codexApp
                    $restartRequired = $false
                    $pendingExternalPid = 0
                    Save-PersistentState $activeProxy $activeSource $lastRestart
                }
            }

            $externalMismatch = $proxyIsValid -and $roots.Count -gt 0 -and $matchingRoots.Count -eq 0 -and -not $restartRequired
            if (-not $ObserveOnly -and $externalMismatch -and $null -ne $codexApp) {
                $externalPid = [int]$roots[0].ProcessId
                if ($pendingExternalPid -ne $externalPid) {
                    $pendingExternalPid = $externalPid
                    $pendingExternalSince = Get-Date
                    $pendingExternalTrafficObserved = $trafficObservedNow
                    Write-GuardianLog 'INFO' 'unmanaged_codex' 'A Codex root missing the current proxy argument is being evaluated by the external-launch policy.' @{
                        pid = $externalPid
                        policy = $externalLaunchPolicy
                    }
                }
                elseif ($trafficObservedNow) { $pendingExternalTrafficObserved = $true }

                $decisionMode = if ($manageExternalLaunches) { 'Enforce' } else { 'Safe' }
                $externalDecision = Get-CpgExternalLaunchDecision -Mode $decisionMode `
                    -SafeRepairEnabled:$safeRepairExternalLaunches -ProxyValid:$proxyIsValid `
                    -ArgumentMatches:$false -TrafficObserved:$pendingExternalTrafficObserved `
                    -PendingSeconds ((Get-Date) - $pendingExternalSince).TotalSeconds `
                    -SafeGraceSeconds $safeExternalGraceSeconds -EnforceDebounceSeconds $externalDebounceSeconds

                switch ([string]$externalDecision.Action) {
                    'Wait' {
                        $externalLaunchState = if ($decisionMode -eq 'Enforce') { 'EnforceDebounce' } else { 'SafeEvidenceGrace' }
                    }
                    'Keep' { $externalLaunchState = 'ProxyTrafficObserved' }
                    'ManagedShortcut' { $externalLaunchState = 'ManagedShortcutRequired' }
                    'Repair' {
                        $externalLaunchState = 'WaitingForRestartBudget'
                        if (((Get-Date) - $lastRestart).TotalSeconds -ge $restartCooldownSeconds -and (Test-GuardianRestartBudget)) {
                            $lastRestart = Get-Date
                            Register-GuardianRestart $lastRestart
                            $script:RecoveryLaunchRequired = $true
                            Save-PersistentState $activeProxy $activeSource $lastRestart
                            Write-GuardianLog 'INFO' 'external_codex_repair' 'The external Codex launch is being replaced with a validated managed launch.' @{
                                pid = $externalPid
                                policy = $externalLaunchPolicy
                                reason = [string]$externalDecision.Reason
                            }
                            $managedRootPid = Restart-CodexManaged $roots $activeProxy $config $codexApp
                            $pendingExternalPid = 0
                            $pendingExternalTrafficObserved = $false
                            $externalLaunchState = 'Repairing'
                            Save-PersistentState $activeProxy $activeSource $lastRestart
                        }
                    }
                }
            }
            else {
                $pendingExternalPid = 0
                $pendingExternalTrafficObserved = $false
                if ($roots.Count -eq 0) { $externalLaunchState = 'NoCodex' }
                elseif ($matchingRoots.Count -gt 0) { $externalLaunchState = 'Managed' }
                elseif ($ObserveOnly) { $externalLaunchState = 'ObservedUnmanaged' }
                elseif ($externalMismatch -and $null -eq $codexApp) { $externalLaunchState = 'CodexResolutionUnavailable' }
                else { $externalLaunchState = 'WaitingForValidatedProxy' }
            }

            if (-not $ObserveOnly -and (Test-Path -LiteralPath $script:LaunchRequestPath)) {
                if ($proxyIsValid -and $matchingRoots.Count -gt 0) {
                    Remove-Item -LiteralPath $script:LaunchRequestPath -Force -ErrorAction SilentlyContinue
                }
                elseif ($proxyIsValid -and $roots.Count -eq 0 -and $null -ne $codexApp -and (Test-GuardianRestartBudget)) {
                    Remove-Item -LiteralPath $script:LaunchRequestPath -Force -ErrorAction SilentlyContinue
                    $lastRestart = Get-Date
                    Register-GuardianRestart $lastRestart
                    $script:RecoveryLaunchRequired = $true
                    Save-PersistentState $activeProxy $activeSource $lastRestart
                    $managedRootPid = Start-CodexManaged $activeProxy $config $codexApp
                }
                elseif ($proxyIsValid -and $roots.Count -gt 0 -and $null -ne $codexApp -and ((Get-Date) - $lastRestart).TotalSeconds -ge $restartCooldownSeconds -and (Test-GuardianRestartBudget)) {
                    Remove-Item -LiteralPath $script:LaunchRequestPath -Force -ErrorAction SilentlyContinue
                    $lastRestart = Get-Date
                    Register-GuardianRestart $lastRestart
                    $script:RecoveryLaunchRequired = $true
                    Save-PersistentState $activeProxy $activeSource $lastRestart
                    Write-GuardianLog 'INFO' 'managed_launch_takeover' 'The managed shortcut requested replacement of a Codex root missing the current proxy argument.' @{ old_pids = $rootIds }
                    $managedRootPid = Restart-CodexManaged $roots $activeProxy $config $codexApp
                    $pendingExternalPid = 0
                }
            }

            $historyCutoff = (Get-Date).AddMinutes(-$restartLimitWindowMinutes)
            $script:RestartHistory = @($script:RestartHistory | Where-Object { $_ -ge $historyCutoff -and $_ -le (Get-Date) })

            $effectiveness = 'NoValidatedProxy'
            if ($proxyIsValid) { $effectiveness = 'ValidatedProxy' }
            if ($proxyIsValid -and $matchingRoots.Count -gt 0) { $effectiveness = 'LaunchConfigured' }
            if ($proxyIsValid -and $roots.Count -gt 0 -and $trafficObservedRecently) { $effectiveness = 'TrafficObserved' }

            $guardianState = 'WaitingForProxy'
            if (-not $proxyIsValid -and -not [string]::IsNullOrWhiteSpace([string]$pendingProxy)) { $guardianState = 'Stabilizing' }
            if ($proxyIsValid) { $guardianState = 'Ready' }
            if ($proxyIsValid -and $externalLaunchState -in @('SafeEvidenceGrace', 'EnforceDebounce', 'WaitingForRestartBudget')) { $guardianState = 'EvaluatingCodexLaunch' }
            if ($proxyIsValid -and $externalLaunchState -eq 'ManagedShortcutRequired') { $guardianState = 'CodexNeedsManagedLaunch' }
            if ($externalLaunchState -eq 'CodexResolutionUnavailable') { $guardianState = 'CodexResolutionUnavailable' }
            if ($script:RecoveryLaunchRequired) { $guardianState = 'RecoveringCodex' }
            if ($script:RecoveryLaunchRequired -and $roots.Count -gt 0 -and $matchingRoots.Count -eq 0 -and -not $manageExternalLaunches -and -not $safeRepairExternalLaunches) { $guardianState = 'RecoveryBlockedByCodex' }
            if ($script:CircuitBreakerUntil -gt (Get-Date)) { $guardianState = 'RestartCircuitOpen' }

            Write-JsonAtomically $script:StatusPath ([ordered]@{
                running = $true
                guardianPid = $PID
                updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
                guardianState = $guardianState
                mode = if ($ObserveOnly) { 'ObserveOnly' } else { $guardianMode }
                externalLaunchPolicy = $externalLaunchPolicy
                externalLaunchState = $externalLaunchState
                safeRepairExternalLaunches = $safeRepairExternalLaunches
                pendingExternalCodexPid = if ($pendingExternalPid -eq 0) { $null } else { $pendingExternalPid }
                pendingExternalProxyTrafficObserved = $pendingExternalTrafficObserved
                activeProxy = $activeProxy
                activeSource = $activeSource
                activeProxyValid = $proxyIsValid
                effectivenessEvidence = $effectiveness
                proxyTestSuccessCount = if ($null -eq $currentValidation) { 0 } else { $currentValidation.SuccessCount }
                proxyTestRequiredCount = if ($null -eq $currentValidation) { [int](Get-CpgConfigValue $config 'MinimumSuccessfulProxyTests' 1) } else { $currentValidation.RequiredCount }
                proxyTestTargetCount = if ($null -eq $currentValidation) { @((Get-CpgConfigValue $config 'ProxyTestUrls' @())).Count } else { $currentValidation.TargetCount }
                proxyTestAttemptedCount = if ($null -eq $currentValidation) { 0 } else { $currentValidation.AttemptedCount }
                proxyTestResults = if ($null -eq $currentValidation) { @() } else { @($currentValidation.Results) }
                pendingProxy = $pendingProxy
                pendingSamples = $pendingSamples
                codexInstalled = ($null -ne $codexApp)
                codexPackageVersion = if ($null -eq $codexApp) { $null } else { $codexApp.Version }
                codexPackageArchitecture = if ($null -eq $codexApp) { $null } else { $codexApp.PackageArchitecture }
                codexApplicationId = if ($null -eq $codexApp) { $null } else { $codexApp.ApplicationId }
                codexExecutableName = if ($null -eq $codexApp) { $null } else { $codexApp.ProcessName }
                codexResolutionMethod = if ($null -eq $codexApp) { $null } else { $codexApp.ResolutionMethod }
                codexRunning = ($roots.Count -gt 0)
                codexRootPids = $rootIds
                managedCodexRootPid = if ($managedRootPid -eq 0) { $null } else { $managedRootPid }
                codexProxyArgumentMatch = ($matchingRoots.Count -gt 0)
                codexProxyConnectionObservedNow = $trafficObservedNow
                codexProxyConnectionObservedRecently = $trafficObservedRecently
                lastProxyConnectionUtc = if ($script:LastProxyConnection -eq [datetime]::MinValue) { $null } else { $script:LastProxyConnection.ToUniversalTime().ToString('o') }
                restartRequired = $restartRequired
                recoveryLaunchRequired = $script:RecoveryLaunchRequired
                recentRestartCount = @($script:RestartHistory).Count
                restartCircuitOpen = ($script:CircuitBreakerUntil -gt (Get-Date))
                circuitBreakerUntilUtc = if ($script:CircuitBreakerUntil -gt (Get-Date)) { $script:CircuitBreakerUntil.ToUniversalTime().ToString('o') } else { $null }
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
