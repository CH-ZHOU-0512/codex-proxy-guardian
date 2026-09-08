[CmdletBinding()]
param(
    [switch]$SelfTest,
    [switch]$RunOnce,
    [switch]$ObserveOnly,
    [switch]$PreviewRestartPrompt,
    [string]$PreviewScreenshotPath = '',
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
$script:UpdateStatusPath = Join-Path $script:Root 'update-status.json'
$script:ValidationCache = @{}
$script:ProxyAddressCache = @{}
$script:PACDiscoveryCache = $null
$script:CodexLogOffsets = @{}
$script:ReconnectSignalFingerprints = @{}
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

function Get-CpgRecentCodexLogFiles {
    param($Config)

    $configuredRoot = [string](Get-CpgConfigValue $Config 'CodexLogRoot' '')
    $logRoot = if ([string]::IsNullOrWhiteSpace($configuredRoot)) {
        Join-Path $env:LOCALAPPDATA 'Codex\Logs'
    }
    else {
        [Environment]::ExpandEnvironmentVariables($configuredRoot)
    }
    if (-not (Test-Path -LiteralPath $logRoot)) { return @() }

    $files = @()
    foreach ($date in @((Get-Date), (Get-Date).AddDays(-1))) {
        $datePath = Join-Path (Join-Path (Join-Path $logRoot $date.ToString('yyyy')) $date.ToString('MM')) $date.ToString('dd')
        if (-not (Test-Path -LiteralPath $datePath)) { continue }
        $files += @(Get-ChildItem -LiteralPath $datePath -Filter 'codex-desktop-*.log' -File -ErrorAction SilentlyContinue)
    }
    return @($files | Sort-Object LastWriteTime -Descending | Select-Object -First 20)
}

function Initialize-CpgCodexLogTail {
    param($Config)

    $script:CodexLogOffsets = @{}
    foreach ($file in @(Get-CpgRecentCodexLogFiles $Config)) {
        $script:CodexLogOffsets[$file.FullName] = [pscustomobject]@{ Offset = [int64]$file.Length; Carry = '' }
    }
}

function Read-CpgNewCodexLogLines {
    param($Config)

    $result = @()
    $maxReadBytes = [Math]::Max(65536, [int](Get-CpgConfigValue $Config 'ReconnectLogMaxReadBytes' 262144))
    $encoding = New-Object System.Text.UTF8Encoding($false, $false)
    foreach ($file in @(Get-CpgRecentCodexLogFiles $Config)) {
        if (-not $script:CodexLogOffsets.ContainsKey($file.FullName)) {
            $script:CodexLogOffsets[$file.FullName] = [pscustomobject]@{ Offset = [int64]0; Carry = '' }
        }
        $tail = $script:CodexLogOffsets[$file.FullName]
        try {
            $stream = New-Object System.IO.FileStream($file.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
            try {
                if ([int64]$tail.Offset -gt $stream.Length) {
                    $tail.Offset = [int64]0
                    $tail.Carry = ''
                }
                $remaining = $stream.Length - [int64]$tail.Offset
                if ($remaining -le 0) { continue }
                $readLength = [int][Math]::Min([int64]$maxReadBytes, $remaining)
                $buffer = New-Object byte[] $readLength
                [void]$stream.Seek([int64]$tail.Offset, [System.IO.SeekOrigin]::Begin)
                $read = $stream.Read($buffer, 0, $readLength)
                if ($read -le 0) { continue }
                $tail.Offset = [int64]$tail.Offset + $read
                $text = [string]$tail.Carry + $encoding.GetString($buffer, 0, $read)
                $parts = @($text -split "`n", -1)
                if ($parts.Count -gt 1) {
                    for ($index = 0; $index -lt ($parts.Count - 1); $index++) {
                        $line = $parts[$index].TrimEnd("`r")
                        if (-not [string]::IsNullOrWhiteSpace($line)) { $result += $line }
                    }
                    $tail.Carry = $parts[-1]
                }
                else {
                    $tail.Carry = $text
                }
                if ([string]$tail.Carry.Length -gt 131072) { $tail.Carry = ([string]$tail.Carry).Substring(([string]$tail.Carry).Length - 131072) }
            }
            finally { $stream.Dispose() }
        }
        catch {
            Write-GuardianLog 'DEBUG' 'codex_log_tail_retry' 'A Codex log could not be tailed yet; the listener will retry.' @{ error = $_.Exception.GetType().Name }
        }
    }
    return @($result)
}

function Receive-CpgReconnectSignals {
    param($Config)

    $now = Get-Date
    $dedupeMinutes = [Math]::Max(1, [int](Get-CpgConfigValue $Config 'ReconnectSignalDedupeMinutes' 10))
    $burstSeconds = [Math]::Max(10, [int](Get-CpgConfigValue $Config 'ReconnectSignalWindowSeconds' 120))
    foreach ($key in @($script:ReconnectSignalFingerprints.Keys)) {
        if (($now - [datetime]$script:ReconnectSignalFingerprints[$key]).TotalMinutes -ge $dedupeMinutes) {
            $script:ReconnectSignalFingerprints.Remove($key)
        }
    }

    $signals = @()
    foreach ($line in @(Read-CpgNewCodexLogLines $Config)) {
        $signal = Get-CpgReconnectLogSignal $line
        if (-not [bool]$signal.IsSignal -or $script:ReconnectSignalFingerprints.ContainsKey([string]$signal.SignalId)) { continue }
        $script:ReconnectSignalFingerprints[[string]$signal.SignalId] = $now
        $signals += $signal
        $script:ReconnectSignalHistory = @($script:ReconnectSignalHistory) + @($now)
        $script:ReconnectSignalCount++
        $script:LastReconnectSignalAt = $now
        $script:LastReconnectCategory = [string]$signal.Category
        $script:LastReconnectErrorClass = [string]$signal.ErrorClass
        Write-GuardianLog 'WARN' 'codex_reconnect_signal_detected' 'Codex reported a real streaming or WebSocket connection failure; cached proxy evidence will be discarded and revalidated immediately.' @{
            category = [string]$signal.Category
            error_class = [string]$signal.ErrorClass
            endpoint = [string]$signal.Endpoint
            reconnect_attempt = [int]$signal.Attempt
            codex_restart_requested = $false
            system_proxy_modified = $false
        }
    }
    $cutoff = $now.AddSeconds(-$burstSeconds)
    $script:ReconnectSignalHistory = @($script:ReconnectSignalHistory | Where-Object { $_ -ge $cutoff -and $_ -le $now })
    $script:ReconnectBurstCount = @($script:ReconnectSignalHistory).Count
    if ($signals.Count -gt 0) {
        $script:ValidationCache.Clear()
        $script:ProxyAddressCache.Clear()
        $script:PACDiscoveryCache = $null
        $script:ReconnectListenerAction = 'ImmediateProxyRevalidation'
    }
    return @($signals)
}

function Initialize-CpgEventListener {
    param($Config)

    $sourcePrefix = "CodexProxyGuardian.$PID"
    $subscriptions = New-Object System.Collections.ArrayList
    $sourceIdentifiers = New-Object System.Collections.ArrayList
    $watchers = New-Object System.Collections.ArrayList
    $components = New-Object System.Collections.ArrayList

    try {
        $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
        if ([string]::IsNullOrWhiteSpace($localAppData)) { $localAppData = [string]$env:LOCALAPPDATA }
        $codexRoot = Join-Path $localAppData 'Codex'
        $codexLogRoot = Join-Path $codexRoot 'Logs'
        $watchPath = $null
        $watchFilter = '*.log'
        $watchIncludeSubdirectories = $true
        if (Test-Path -LiteralPath $codexLogRoot -PathType Container) {
            $watchPath = $codexLogRoot
            $watchIncludeSubdirectories = $true
        }
        elseif (Test-Path -LiteralPath $codexRoot -PathType Container) {
            $watchPath = $codexRoot
            $watchIncludeSubdirectories = $true
        }
        else {
            $watchPath = Split-Path -Parent $codexRoot
            $watchFilter = 'Codex'
            $watchIncludeSubdirectories = $false
        }
        if (Test-Path -LiteralPath $watchPath -PathType Container) {
            $watcher = New-Object System.IO.FileSystemWatcher($watchPath, $watchFilter)
            $watcher.IncludeSubdirectories = $watchIncludeSubdirectories
            $watcher.NotifyFilter = [System.IO.NotifyFilters]'FileName, LastWrite, Size'
            foreach ($eventName in @('Changed', 'Created', 'Renamed')) {
                $sourceIdentifier = "$sourcePrefix.CodexLog.$eventName"
                $subscription = Register-ObjectEvent -InputObject $watcher -EventName $eventName -SourceIdentifier $sourceIdentifier
                [void]$subscriptions.Add($subscription)
                [void]$sourceIdentifiers.Add($sourceIdentifier)
            }
            $watcher.EnableRaisingEvents = $true
            [void]$watchers.Add($watcher)
            [void]$components.Add('CodexLog')
        }
        else {
            Write-GuardianLog 'WARN' 'event_listener_codex_log_unavailable' 'The Codex log parent directory is unavailable; periodic checks remain active.' @{ path = $watchPath }
        }
    }
    catch {
        Write-GuardianLog 'WARN' 'event_listener_codex_log_unavailable' 'Codex log events are unavailable; periodic checks remain active.' @{ error = $_.Exception.GetType().Name }
    }

    try {
        $watcher = New-Object System.IO.FileSystemWatcher($script:Root, 'update-status.json')
        $watcher.NotifyFilter = [System.IO.NotifyFilters]'FileName, LastWrite, Size'
        foreach ($eventName in @('Changed', 'Created', 'Renamed')) {
            $sourceIdentifier = "$sourcePrefix.UpdateStatus.$eventName"
            $subscription = Register-ObjectEvent -InputObject $watcher -EventName $eventName -SourceIdentifier $sourceIdentifier
            [void]$subscriptions.Add($subscription)
            [void]$sourceIdentifiers.Add($sourceIdentifier)
        }
        $watcher.EnableRaisingEvents = $true
        [void]$watchers.Add($watcher)
        [void]$components.Add('UpdateStatus')
    }
    catch {
        Write-GuardianLog 'WARN' 'event_listener_update_status_unavailable' 'Update-result events are unavailable; periodic checks remain active.' @{ error = $_.Exception.GetType().Name }
    }

    try {
        $query = New-Object System.Management.WqlEventQuery("SELECT * FROM Win32_ProcessStartTrace WHERE ProcessName = 'ChatGPT.exe' OR ProcessName = 'Codex.exe'")
        $processWatcher = New-Object System.Management.ManagementEventWatcher($query)
        $sourceIdentifier = "$sourcePrefix.CodexProcess.Started"
        $subscription = Register-ObjectEvent -InputObject $processWatcher -EventName EventArrived -SourceIdentifier $sourceIdentifier
        [void]$subscriptions.Add($subscription)
        [void]$sourceIdentifiers.Add($sourceIdentifier)
        $processWatcher.Start()
        [void]$watchers.Add($processWatcher)
        [void]$components.Add('CodexProcess')
    }
    catch {
        Write-GuardianLog 'WARN' 'event_listener_codex_process_unavailable' 'Codex process events are unavailable; periodic checks remain active.' @{ error = $_.Exception.GetType().Name }
    }

    return [pscustomobject]@{
        # Register-ObjectEvent returns no pipeline object in Windows PowerShell 5.1,
        # even though the subscription is registered. Track source identifiers
        # explicitly so the listener is enabled and can be cleaned up reliably.
        Enabled = $components.Count -gt 0
        SourcePrefix = $sourcePrefix
        Subscriptions = @($subscriptions)
        SourceIdentifiers = @($sourceIdentifiers)
        Watchers = @($watchers)
        Components = @($components)
    }
}

function Wait-CpgEventListener {
    param($Listener, [int]$TimeoutSeconds, [int]$DebounceMilliseconds)

    if ($null -eq $Listener -or -not [bool]$Listener.Enabled) {
        Start-Sleep -Seconds $TimeoutSeconds
        return @()
    }
    $firstEvent = Wait-Event -Timeout $TimeoutSeconds
    if ($null -eq $firstEvent) { return @() }
    if ($DebounceMilliseconds -gt 0) { Start-Sleep -Milliseconds $DebounceMilliseconds }

    $reasons = @()
    foreach ($eventRecord in @(Get-Event -ErrorAction SilentlyContinue | Where-Object { [string]$_.SourceIdentifier -like "$($Listener.SourcePrefix).*" })) {
        $source = [string]$eventRecord.SourceIdentifier
        if ($source -like '*.CodexLog.*') { $reasons += 'CodexLog' }
        elseif ($source -like '*.UpdateStatus.*') { $reasons += 'UpdateStatus' }
        elseif ($source -like '*.CodexProcess.*') { $reasons += 'CodexProcess' }
        Remove-Event -EventIdentifier $eventRecord.EventIdentifier -ErrorAction SilentlyContinue
    }
    if ($reasons.Count -eq 0) { $reasons += 'Other' }
    return @($reasons | Select-Object -Unique)
}

function Stop-CpgEventListener {
    param($Listener)
    if ($null -eq $Listener) { return }
    foreach ($sourceIdentifier in @($Listener.SourceIdentifiers)) {
        Unregister-Event -SourceIdentifier ([string]$sourceIdentifier) -ErrorAction SilentlyContinue
        Get-Job -Name ([string]$sourceIdentifier) -ErrorAction SilentlyContinue | Remove-Job -Force -ErrorAction SilentlyContinue
    }
    foreach ($subscription in @($Listener.Subscriptions)) {
        Unregister-Event -SourceIdentifier ([string]$subscription.Name) -ErrorAction SilentlyContinue
        Remove-Job -Id ([int]$subscription.Id) -Force -ErrorAction SilentlyContinue
    }
    foreach ($watcher in @($Listener.Watchers)) {
        try { if ($watcher -is [System.Management.ManagementEventWatcher]) { $watcher.Stop() } } catch { }
        try { $watcher.Dispose() } catch { }
    }
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
    param([string]$ProxyUri, [string[]]$TestUrls, [int]$TimeoutSeconds, [int]$MinimumSuccessCount, [string[]]$RequiredHosts = @())

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
        $decision = Get-CpgProxyValidationDecision -Results $results -MinimumSuccessCount $required -RequiredHosts $RequiredHosts
        if ($decision.Passed -or @($decision.CriticalFailures).Count -gt 0) { break }
        if (($successCount + ($TestUrls.Count - $attemptedCount)) -lt $required) { break }
    }
    $decision = Get-CpgProxyValidationDecision -Results $results -MinimumSuccessCount $required -RequiredHosts $RequiredHosts
    return [pscustomobject]@{
        Passed = [bool]$decision.Passed
        SuccessCount = [int]$decision.SuccessCount
        RequiredCount = $required
        TargetCount = $TestUrls.Count
        AttemptedCount = $attemptedCount
        CriticalTargetsPassed = [bool]$decision.CriticalTargetsPassed
        CriticalFailures = @($decision.CriticalFailures)
        CriticalMissing = @($decision.CriticalMissing)
        Results = $results
    }
}

function Test-Socks5Proxy {
    param([string]$ProxyUri, [string[]]$TestUrls, [int]$TimeoutSeconds, [int]$MinimumSuccessCount, [string[]]$RequiredHosts = @())

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
        $decision = Get-CpgProxyValidationDecision -Results $results -MinimumSuccessCount $required -RequiredHosts $RequiredHosts
        if ($decision.Passed -or @($decision.CriticalFailures).Count -gt 0) { break }
        if (($successCount + ($TestUrls.Count - $attemptedCount)) -lt $required) { break }
    }
    $decision = Get-CpgProxyValidationDecision -Results $results -MinimumSuccessCount $required -RequiredHosts $RequiredHosts
    return [pscustomobject]@{
        Passed = [bool]$decision.Passed
        SuccessCount = [int]$decision.SuccessCount
        RequiredCount = $required
        TargetCount = $TestUrls.Count
        AttemptedCount = $attemptedCount
        CriticalTargetsPassed = [bool]$decision.CriticalTargetsPassed
        CriticalFailures = @($decision.CriticalFailures)
        CriticalMissing = @($decision.CriticalMissing)
        Results = $results
    }
}

function Test-ProxyCandidate {
    param($Candidate, $Config)

    $requiredHosts = @((Get-CpgConfigValue $Config 'RequiredProxyTestHosts' @()) | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $tcpTimeout = [int](Get-CpgConfigValue $Config 'TcpTimeoutMilliseconds' 1500)
    if (-not (Test-TcpEndpoint $Candidate.Host $Candidate.Port $tcpTimeout)) {
        $script:ValidationCache.Remove($Candidate.Uri)
        $checkedAt = Get-Date
        $Candidate | Add-Member -MemberType NoteProperty -Name ValidationResult -Value ([pscustomobject]@{
            Passed = $false
            SuccessCount = 0
            RequiredCount = [Math]::Max(1, [int](Get-CpgConfigValue $Config 'MinimumSuccessfulProxyTests' 1))
            TargetCount = @((Get-CpgConfigValue $Config 'ProxyTestUrls' @())).Count
            AttemptedCount = 0
            EndpointReachable = $false
            CriticalTargetsPassed = $false
            CriticalFailures = @()
            CriticalMissing = @($requiredHosts)
            Results = @()
        }) -Force
        $Candidate | Add-Member -MemberType NoteProperty -Name ValidationCheckedAt -Value $checkedAt -Force
        $Candidate | Add-Member -MemberType NoteProperty -Name ValidationFresh -Value $true -Force
        $Candidate | Add-Member -MemberType NoteProperty -Name EndpointReachable -Value $false -Force
        return $false
    }

    $interval = [int](Get-CpgConfigValue $Config 'HttpValidationIntervalSeconds' 30)
    if ($script:ValidationCache.ContainsKey($Candidate.Uri)) {
        $cached = $script:ValidationCache[$Candidate.Uri]
        if (((Get-Date) - $cached.CheckedAt).TotalSeconds -lt $interval) {
            $Candidate | Add-Member -MemberType NoteProperty -Name ValidationResult -Value $cached.Result -Force
            $Candidate | Add-Member -MemberType NoteProperty -Name ValidationCheckedAt -Value $cached.CheckedAt -Force
            $Candidate | Add-Member -MemberType NoteProperty -Name ValidationFresh -Value $false -Force
            $Candidate | Add-Member -MemberType NoteProperty -Name EndpointReachable -Value $true -Force
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
        Test-Socks5Proxy $Candidate.Uri $urls ([int](Get-CpgConfigValue $Config 'HttpTimeoutSeconds' 8)) $minimum $requiredHosts
    }
    else {
        Test-HttpProxy $Candidate.Uri $urls ([int](Get-CpgConfigValue $Config 'HttpTimeoutSeconds' 8)) $minimum $requiredHosts
    }
    $validation | Add-Member -MemberType NoteProperty -Name EndpointReachable -Value $true -Force
    $checkedAt = Get-Date
    $Candidate | Add-Member -MemberType NoteProperty -Name ValidationResult -Value $validation -Force
    $Candidate | Add-Member -MemberType NoteProperty -Name ValidationCheckedAt -Value $checkedAt -Force
    $Candidate | Add-Member -MemberType NoteProperty -Name ValidationFresh -Value $true -Force
    $Candidate | Add-Member -MemberType NoteProperty -Name EndpointReachable -Value $true -Force
    $script:ValidationCache[$Candidate.Uri] = [pscustomobject]@{ Valid = [bool]$validation.Passed; CheckedAt = $checkedAt; Result = $validation }
    return [bool]$validation.Passed
}

function Find-EffectiveProxy {
    param($Config, [string]$PreferredUri = '')

    $script:LastProxyValidationAttempts = @()
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
        $valid = Test-ProxyCandidate $candidate $Config
        $script:LastProxyValidationAttempts += $candidate
        if ($valid) { return $candidate }
        if (-not [string]::IsNullOrWhiteSpace($PreferredUri) -and
            [bool](Get-CpgConfigValue $candidate 'EndpointReachable' $false) -and
            (Test-CpgSameProxyEndpoint -FirstProxyUri $PreferredUri -SecondProxyUri ([string]$candidate.Uri))) {
            return $null
        }
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

    # Traffic observed before this launch cannot prove that the new process inherited the proxy.
    $script:LastProxyConnection = [datetime]::MinValue
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

function Set-CpgRoundedRegion {
    param(
        $Control,
        [ValidateRange(2, 40)][int]$Radius
    )

    $diameter = $Radius * 2
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    try {
        $path.AddArc(0, 0, $diameter, $diameter, 180, 90)
        $path.AddArc($Control.Width - $diameter, 0, $diameter, $diameter, 270, 90)
        $path.AddArc($Control.Width - $diameter, $Control.Height - $diameter, $diameter, $diameter, 0, 90)
        $path.AddArc(0, $Control.Height - $diameter, $diameter, $diameter, 90, 90)
        $path.CloseFigure()
        $Control.Region = New-Object System.Drawing.Region($path)
    }
    finally { $path.Dispose() }
}

function Show-CpgRestartApprovalFallback {
    param(
        [string]$ReasonText,
        [string]$Endpoint,
        [int]$TimeoutSeconds,
        [int]$SnoozeMinutes
    )

    $message = @(
        '检测到更合适的连接。',
        '重启Codex后，连接通常会更稳定。',
        $ReasonText,
        ('代理：{0}' -f $Endpoint),
        '',
        '要重启Codex吗？',
        '选择“是”：重启Codex，正在进行的任务会中断。',
        ('选择“否”或关闭窗口：不做任何改动，{0}分钟后再提醒我。' -f $SnoozeMinutes)
    ) -join [Environment]::NewLine

    $shell = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        # Yes/No, information icon, default No, foreground. Deliberately not system-modal.
        return [int]$shell.Popup($message, $TimeoutSeconds, '连接优化建议 · Codex Proxy Guardian', 65860)
    }
    catch { return 0 }
    finally {
        if ($null -ne $shell) {
            try { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) } catch { }
        }
    }
}

function Enable-CpgPromptDpiAwareness {
    if (-not ('CpgPromptDpi' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class CpgPromptDpi
{
    [DllImport("user32.dll")]
    private static extern IntPtr SetThreadDpiAwarenessContext(IntPtr dpiContext);

    [DllImport("user32.dll")]
    private static extern bool SetProcessDPIAware();

    public static void Enable()
    {
        try { SetThreadDpiAwarenessContext(new IntPtr(-4)); }
        catch
        {
            try { SetProcessDPIAware(); }
            catch { }
        }
    }
}
'@
    }
    [CpgPromptDpi]::Enable()
}

function Show-CpgRestartApprovalDialog {
    param(
        [ValidateNotNullOrEmpty()][string]$ReasonText,
        [ValidateNotNullOrEmpty()][string]$Endpoint,
        [ValidateRange(15, 300)][int]$TimeoutSeconds,
        [ValidateRange(1, 1440)][int]$SnoozeMinutes,
        [switch]$StreamingRepair,
        [string]$ScreenshotPath = ''
    )

    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        Enable-CpgPromptDpiAwareness
        [System.Windows.Forms.Application]::EnableVisualStyles()

        $paper = [System.Drawing.ColorTranslator]::FromHtml('#F4F2EA')
        $paperDeep = [System.Drawing.ColorTranslator]::FromHtml('#E9E7DD')
        $ink = [System.Drawing.ColorTranslator]::FromHtml('#111510')
        $muted = [System.Drawing.ColorTranslator]::FromHtml('#62685F')
        $green = [System.Drawing.ColorTranslator]::FromHtml('#2F6B50')
        $greenDark = [System.Drawing.ColorTranslator]::FromHtml('#214B39')
        $greenSoft = [System.Drawing.ColorTranslator]::FromHtml('#DCE8DF')
        $line = [System.Drawing.ColorTranslator]::FromHtml('#CDD0C6')
        $dark = [System.Drawing.ColorTranslator]::FromHtml('#142219')
        $acid = [System.Drawing.ColorTranslator]::FromHtml('#D7F06B')
        $white = [System.Drawing.Color]::White

        $form = New-Object System.Windows.Forms.Form
        $form.Text = 'Codex Proxy Guardian'
        $form.ClientSize = New-Object System.Drawing.Size(640, 470)
        $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
        $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
        $form.MaximizeBox = $false
        $form.MinimizeBox = $true
        $form.ShowInTaskbar = $true
        $form.TopMost = $true
        $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
        $form.BackColor = $paper
        $form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

        $header = New-Object System.Windows.Forms.Panel
        $header.Location = New-Object System.Drawing.Point(0, 0)
        $header.Size = New-Object System.Drawing.Size(640, 92)
        $header.BackColor = $dark
        $form.Controls.Add($header)

        $brandMark = New-Object System.Windows.Forms.Label
        $brandMark.Text = 'C'
        $brandMark.Location = New-Object System.Drawing.Point(26, 24)
        $brandMark.Size = New-Object System.Drawing.Size(44, 44)
        $brandMark.BackColor = $acid
        $brandMark.ForeColor = $dark
        $brandMark.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
        $brandMark.Font = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
        $header.Controls.Add($brandMark)
        Set-CpgRoundedRegion -Control $brandMark -Radius 12

        $brandTitle = New-Object System.Windows.Forms.Label
        $brandTitle.Text = '连接优化建议'
        $brandTitle.Location = New-Object System.Drawing.Point(84, 22)
        $brandTitle.Size = New-Object System.Drawing.Size(300, 28)
        $brandTitle.AutoSize = $true
        $brandTitle.ForeColor = $white
        $brandTitle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 13, [System.Drawing.FontStyle]::Bold)
        $header.Controls.Add($brandTitle)

        $brandSubtitle = New-Object System.Windows.Forms.Label
        $brandSubtitle.Text = 'CODEX PROXY GUARDIAN'
        $brandSubtitle.Location = New-Object System.Drawing.Point(86, 52)
        $brandSubtitle.Size = New-Object System.Drawing.Size(300, 18)
        $brandSubtitle.AutoSize = $true
        $brandSubtitle.ForeColor = $greenSoft
        $brandSubtitle.Font = New-Object System.Drawing.Font('Segoe UI', 8, [System.Drawing.FontStyle]::Bold)
        $header.Controls.Add($brandSubtitle)

        $accentLine = New-Object System.Windows.Forms.Panel
        $accentLine.Location = New-Object System.Drawing.Point(0, 88)
        $accentLine.Size = New-Object System.Drawing.Size(640, 4)
        $accentLine.BackColor = $acid
        $header.Controls.Add($accentLine)

        $heading = New-Object System.Windows.Forms.Label
        $heading.Text = '检测到更合适的连接'
        $heading.Location = New-Object System.Drawing.Point(28, 118)
        $heading.Size = New-Object System.Drawing.Size(588, 34)
        $heading.AutoSize = $true
        $heading.ForeColor = $ink
        $heading.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 16, [System.Drawing.FontStyle]::Bold)
        $form.Controls.Add($heading)

        $reassurance = New-Object System.Windows.Forms.Label
        $reassurance.Text = '重启Codex后，连接通常会更稳定。'
        $reassurance.Location = New-Object System.Drawing.Point(30, 160)
        $reassurance.Size = New-Object System.Drawing.Size(580, 25)
        $reassurance.AutoSize = $true
        $reassurance.ForeColor = $muted
        $reassurance.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
        $form.Controls.Add($reassurance)

        $card = New-Object System.Windows.Forms.Panel
        $card.Location = New-Object System.Drawing.Point(28, 204)
        $card.Size = New-Object System.Drawing.Size(576, 108)
        $card.BackColor = $white
        $form.Controls.Add($card)
        Set-CpgRoundedRegion -Control $card -Radius 16

        $cardAccent = New-Object System.Windows.Forms.Panel
        $cardAccent.Location = New-Object System.Drawing.Point(0, 0)
        $cardAccent.Size = New-Object System.Drawing.Size(7, 108)
        $cardAccent.BackColor = $green
        $card.Controls.Add($cardAccent)

        $cardEyebrow = New-Object System.Windows.Forms.Label
        $cardEyebrow.Text = '已找到可用代理'
        $cardEyebrow.Location = New-Object System.Drawing.Point(26, 17)
        $cardEyebrow.Size = New-Object System.Drawing.Size(520, 20)
        $cardEyebrow.AutoSize = $true
        $cardEyebrow.ForeColor = $greenDark
        $cardEyebrow.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
        $card.Controls.Add($cardEyebrow)

        $reasonLabel = New-Object System.Windows.Forms.Label
        $reasonLabel.Text = $ReasonText
        $reasonLabel.Location = New-Object System.Drawing.Point(26, 75)
        $reasonLabel.AutoSize = $true
        $reasonLabel.MaximumSize = New-Object System.Drawing.Size(530, 0)
        $reasonLabel.ForeColor = $muted
        $reasonLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
        $card.Controls.Add($reasonLabel)

        $endpointLabel = New-Object System.Windows.Forms.Label
        $endpointLabel.Text = $Endpoint
        $endpointLabel.Location = New-Object System.Drawing.Point(26, 43)
        $endpointLabel.Size = New-Object System.Drawing.Size(530, 22)
        $endpointLabel.AutoSize = $true
        $endpointLabel.ForeColor = $ink
        $endpointLabel.Font = New-Object System.Drawing.Font('Consolas', 10, [System.Drawing.FontStyle]::Bold)
        $card.Controls.Add($endpointLabel)

        $guidance = New-Object System.Windows.Forms.Label
        $guidance.Text = '重启会中断正在进行的任务，请在方便时操作。'
        $guidance.Location = New-Object System.Drawing.Point(30, 340)
        $guidance.Size = New-Object System.Drawing.Size(580, 25)
        $guidance.AutoSize = $true
        $guidance.ForeColor = $ink
        $guidance.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
        $form.Controls.Add($guidance)

        $countdownLabel = New-Object System.Windows.Forms.Label
        $countdownLabel.Location = New-Object System.Drawing.Point(30, 378)
        $countdownLabel.Size = New-Object System.Drawing.Size(230, 22)
        $countdownLabel.AutoSize = $true
        $countdownLabel.ForeColor = $muted
        $form.Controls.Add($countdownLabel)

        $secondaryButton = New-Object System.Windows.Forms.Button
        $secondaryButton.Text = ('{0}分钟后再提醒我' -f $SnoozeMinutes)
        $secondaryButton.Location = New-Object System.Drawing.Point(246, 407)
        $secondaryButton.Size = New-Object System.Drawing.Size(190, 40)
        $secondaryButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $secondaryButton.FlatAppearance.BorderColor = $line
        $secondaryButton.FlatAppearance.BorderSize = 1
        $secondaryButton.BackColor = $white
        $secondaryButton.ForeColor = $ink
        $secondaryButton.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
        $form.Controls.Add($secondaryButton)
        Set-CpgRoundedRegion -Control $secondaryButton -Radius 10

        $primaryButton = New-Object System.Windows.Forms.Button
        $primaryButton.Text = '重启Codex'
        $primaryButton.Location = New-Object System.Drawing.Point(448, 407)
        $primaryButton.Size = New-Object System.Drawing.Size(160, 40)
        $primaryButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $primaryButton.FlatAppearance.BorderSize = 0
        $primaryButton.BackColor = $green
        $primaryButton.ForeColor = $white
        $primaryButton.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
        $form.Controls.Add($primaryButton)
        Set-CpgRoundedRegion -Control $primaryButton -Radius 10

        $promptState = [pscustomobject]@{ Outcome = 'pending'; RemainingSeconds = $TimeoutSeconds }
        $countdownLabel.Text = ('倒计时 {0} 秒 · 自动稍后提醒' -f $promptState.RemainingSeconds)

        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = 1000
        $timer.Add_Tick({
            $promptState.RemainingSeconds--
            if ($promptState.RemainingSeconds -le 0) {
                $promptState.Outcome = 'timeout'
                $form.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
                $form.Close()
                return
            }
            $countdownLabel.Text = ('倒计时 {0} 秒 · 自动稍后提醒' -f $promptState.RemainingSeconds)
        })
        $secondaryButton.Add_Click({
            $promptState.Outcome = 'declined'
            $form.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
            $form.Close()
        })
        $primaryButton.Add_Click({
            $promptState.Outcome = 'approved'
            $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $form.Close()
        })
        $form.Add_FormClosing({
            if ($promptState.Outcome -eq 'pending') { $promptState.Outcome = 'declined' }
            $timer.Stop()
        })
        $form.Add_Shown({
            [void]$secondaryButton.Focus()
            $timer.Start()
        })
        $form.CancelButton = $secondaryButton

        if (-not [string]::IsNullOrWhiteSpace($ScreenshotPath)) {
            $resolvedScreenshotPath = [System.IO.Path]::GetFullPath($ScreenshotPath)
            $screenshotDirectory = Split-Path -Parent $resolvedScreenshotPath
            if (-not (Test-Path -LiteralPath $screenshotDirectory)) {
                New-Item -ItemType Directory -Path $screenshotDirectory -Force | Out-Null
            }
            $form.Show()
            [System.Windows.Forms.Application]::DoEvents()
            $bitmap = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
            try {
                $form.DrawToBitmap($bitmap, (New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
                $bitmap.Save($resolvedScreenshotPath, [System.Drawing.Imaging.ImageFormat]::Png)
            }
            finally { $bitmap.Dispose() }
            $form.Close()
            $timer.Dispose()
            $form.Dispose()
            return 7
        }

        try { [void]$form.ShowDialog() }
        finally {
            $timer.Dispose()
            $form.Dispose()
        }

        switch ($promptState.Outcome) {
            'approved' { return 6 }
            'timeout' { return -1 }
            default { return 7 }
        }
    }
    catch {
        if (Test-Path variable:script:LogPath) {
            Write-GuardianLog 'WARN' 'restart_prompt_fallback' 'The branded restart prompt could not be displayed; the calm system fallback will be used.' @{
                error = $_.Exception.Message
            }
        }
        return Show-CpgRestartApprovalFallback -ReasonText $ReasonText -Endpoint $Endpoint `
            -TimeoutSeconds $TimeoutSeconds -SnoozeMinutes $SnoozeMinutes
    }
}

function Request-CodexRestartApproval {
    param([string]$Reason, [string]$ProxyUri, $Config)

    if (-not [bool](Get-CpgConfigValue $Config 'NotifyBeforeCodexRestart' $true)) {
        Write-GuardianLog 'WARN' 'restart_warning_disabled' 'Codex restart warning is disabled by explicit configuration.' @{
            reason = $Reason
        }
        return $true
    }

    $now = Get-Date
    if ($script:RestartDeferredUntil -gt $now) { return $false }

    $timeoutSeconds = [Math]::Max(15, [Math]::Min(300, [int](Get-CpgConfigValue $Config 'RestartPromptTimeoutSeconds' 45)))
    $configuredSnoozeMinutes = [Math]::Max(1, [Math]::Min(1440, [int](Get-CpgConfigValue $Config 'RestartPromptSnoozeMinutes' 10)))
    $endpoint = Protect-CpgProxyUri $ProxyUri
    $streamingRepair = $Reason -eq 'safe_streaming_proxy_not_guaranteed'
    $snoozeMinutes = if ($streamingRepair) { [Math]::Max(60, $configuredSnoozeMinutes) } else { $configuredSnoozeMinutes }
    $reasonText = switch ($Reason) {
        'safe_streaming_proxy_not_guaranteed' { '当前 Codex 还没有完整使用这条代理。' }
        'proxy_endpoint_changed' { '代理地址已经变化，当前 Codex 仍在使用旧地址。' }
        'managed_shortcut_takeover' { '你刚刚选择了受管启动。' }
        default { '当前 Codex 的连接设置需要更新。' }
    }

    $popupResult = Show-CpgRestartApprovalDialog -ReasonText $reasonText -Endpoint $endpoint `
        -TimeoutSeconds $timeoutSeconds -SnoozeMinutes $snoozeMinutes -StreamingRepair:$streamingRepair

    $decision = Get-CpgRestartPromptDecision -PopupResult $popupResult
    if ($decision.Approved) {
        $script:RestartDeferredUntil = [datetime]::MinValue
        Write-GuardianLog 'INFO' 'restart_approved' 'The user approved the pending Codex restart.' @{
            reason = $Reason
            proxy = $endpoint
        }
        return $true
    }

    $script:RestartDeferredUntil = (Get-Date).AddMinutes($snoozeMinutes)
    Write-GuardianLog 'WARN' 'restart_deferred' 'Codex was left running because the restart was declined, timed out, or could not be prompted.' @{
        reason = $Reason
        decision = [string]$decision.Reason
        retry_after_utc = $script:RestartDeferredUntil.ToUniversalTime().ToString('o')
    }
    Save-PersistentState $activeProxy $activeSource $lastRestart
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
    param($Roots, [string]$ProxyUri, $Config, $CodexApp, [switch]$ApprovalGranted)

    if (-not $ApprovalGranted) {
        throw 'Refusing to close Codex without an explicit restart approval result.'
    }

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
        restartDeferredUntilUtc = if ($script:RestartDeferredUntil -gt (Get-Date)) { $script:RestartDeferredUntil.ToUniversalTime().ToString('o') } else { $null }
        lastCodexPackageVersion = $script:LastCodexPackageVersion
        pendingCodexPackageVersion = $script:PendingCodexPackageVersion
        postUpdateObservationVersion = $script:PostUpdateObservationVersion
        postUpdateObservationStartedUtc = if ($script:PostUpdateObservationStarted -gt [datetime]::MinValue) { $script:PostUpdateObservationStarted.ToUniversalTime().ToString('o') } else { $null }
        postUpdateSuccessfulSamples = $script:PostUpdateSuccessfulSamples
        postUpdateLastValidationUtc = if ($script:PostUpdateLastValidation -gt [datetime]::MinValue) { $script:PostUpdateLastValidation.ToUniversalTime().ToString('o') } else { $null }
        postUpdateObservationPassedVersion = $script:PostUpdateObservationPassedVersion
        upstreamSuspected = $script:UpstreamSuspected
        upstreamSuspectedSinceUtc = if ($script:UpstreamSuspectedSince -gt [datetime]::MinValue) { $script:UpstreamSuspectedSince.ToUniversalTime().ToString('o') } else { $null }
        compatibilityUpdateRequestedVersion = $script:CompatibilityUpdateRequestedVersion
        compatibilityUpdateLastAttemptUtc = if ($script:CompatibilityUpdateLastAttempt -gt [datetime]::MinValue) { $script:CompatibilityUpdateLastAttempt.ToUniversalTime().ToString('o') } else { $null }
        compatibilityHold = $script:CompatibilityHold
        compatibilityHoldCodexVersion = $script:CompatibilityHoldCodexVersion
        compatibilityHoldGuardianVersion = $script:CompatibilityHoldGuardianVersion
        lastCompatibleCodexFingerprint = $script:LastCompatibleCodexFingerprint
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

if ($PreviewRestartPrompt) {
    $previewEndpoint = if ([string]::IsNullOrWhiteSpace($ProxyOverride)) { 'http://127.0.0.1:7897' } else { Protect-CpgProxyUri $ProxyOverride }
    $previewResult = Show-CpgRestartApprovalDialog `
        -ReasonText '当前 Codex 还没有完整使用这条代理。' `
        -Endpoint $previewEndpoint -TimeoutSeconds 300 -SnoozeMinutes 60 -StreamingRepair `
        -ScreenshotPath $PreviewScreenshotPath
    [pscustomobject]@{
        Preview = $true
        Approved = ($previewResult -eq 6)
        Result = $previewResult
    }
    exit 0
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
        ProxyCriticalTargetsPassed = if ($null -eq $validation) { $false } else { [bool](Get-CpgConfigValue $validation 'CriticalTargetsPassed' $true) }
        ProxyCriticalFailures = @(if ($null -eq $validation) { @() } else { @((Get-CpgConfigValue $validation 'CriticalFailures' @())) })
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
$requireManagedLaunchForStreaming = [bool](Get-CpgConfigValue $config 'RequireManagedLaunchForStreaming' $true)
$restartCooldownSeconds = [Math]::Max(10, [int](Get-CpgConfigValue $config 'RestartCooldownSeconds' 45))
$restartLimitCount = [Math]::Max(1, [int](Get-CpgConfigValue $config 'RestartLimitCount' 3))
$restartLimitWindowMinutes = [Math]::Max(1, [int](Get-CpgConfigValue $config 'RestartLimitWindowMinutes' 10))
$circuitBreakerMinutes = [Math]::Max(1, [int](Get-CpgConfigValue $config 'CircuitBreakerMinutes' 15))
$recoveryLaunchRetrySeconds = [Math]::Max(5, [int](Get-CpgConfigValue $config 'RecoveryLaunchRetrySeconds' 10))
$codexResolveIntervalSeconds = [Math]::Max(10, [int](Get-CpgConfigValue $config 'CodexResolveIntervalSeconds' 60))
$listenerDebounceMilliseconds = [Math]::Max(250, [int](Get-CpgConfigValue $config 'EventListenerDebounceMilliseconds' 1000))
$updateHeartbeatEvaluationSeconds = [Math]::Max(15, [int](Get-CpgConfigValue $config 'UpdateHeartbeatEvaluationSeconds' 30))
$trafficEvidenceWindowSeconds = [Math]::Max(30, [int](Get-CpgConfigValue $config 'ProxyConnectionEvidenceWindowSeconds' 300))
$listenerDebounceMilliseconds = [Math]::Max(250, [int](Get-CpgConfigValue $config 'EventListenerDebounceMilliseconds' 1000))
$updateHeartbeatEvaluationSeconds = [Math]::Max(15, [int](Get-CpgConfigValue $config 'UpdateHeartbeatEvaluationSeconds' 30))
$reconnectBurstThreshold = [Math]::Max(1, [int](Get-CpgConfigValue $config 'ReconnectSignalBurstThreshold' 2))
$postUpdateStabilityEnabled = [bool](Get-CpgConfigValue $config 'PostUpdateStabilityEnabled' $true)
$postUpdateStabilitySamples = [Math]::Max(1, [int](Get-CpgConfigValue $config 'PostUpdateStabilitySamples' 3))
$postUpdateStabilitySeconds = [Math]::Max(0, [int](Get-CpgConfigValue $config 'PostUpdateStabilitySeconds' 60))
$compatibilityConfirmationSeconds = [Math]::Max(15, [int](Get-CpgConfigValue $config 'CodexCompatibilityConfirmationSeconds' 45))
$unavailableLogSeconds = [Math]::Max(30, [int](Get-CpgConfigValue $config 'UnavailableLogIntervalSeconds' 300))
$guardianMode = [string](Get-CpgConfigValue $config 'Mode' 'Safe')
$manageExternalLaunches = ($guardianMode -eq 'Enforce' -or [bool](Get-CpgConfigValue $config 'ManageExternalCodexLaunches' $false)) -and -not $ObserveOnly
$safeRepairExternalLaunches = $guardianMode -eq 'Safe' -and [bool](Get-CpgConfigValue $config 'SafeRepairExternalCodexLaunches' $true) -and -not $ObserveOnly
$externalLaunchPolicy = if ($ObserveOnly) { 'ObserveOnly' } elseif ($manageExternalLaunches) { 'Enforce' } elseif ($safeRepairExternalLaunches -and $requireManagedLaunchForStreaming) { 'SafeStreamingRepair' } elseif ($safeRepairExternalLaunches) { 'SafeEvidenceRepair' } else { 'ManagedShortcutOnly' }
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
$script:RestartDeferredUntil = [datetime]::MinValue
$script:LastCodexPackageVersion = if ($null -eq $codexApp) { '' } else { [string]$codexApp.Version }
$script:PendingCodexPackageVersion = ''
$script:PostUpdateObservationVersion = ''
$script:PostUpdateObservationStarted = [datetime]::MinValue
$script:PostUpdateSuccessfulSamples = 0
$script:PostUpdateLastValidation = [datetime]::MinValue
$script:PostUpdateObservationPassedVersion = ''
$script:UpstreamSuspected = $false
$script:UpstreamSuspectedSince = [datetime]::MinValue
$script:CompatibilityUpdateRequestedVersion = ''
$script:CompatibilityUpdateLastAttempt = [datetime]::MinValue
$script:CompatibilityUpdateResultEvent = ''
$script:CompatibilityUpdateRetryAfterUtc = ''
$script:CompatibilityHold = $false
$script:CompatibilityHoldCodexVersion = ''
$script:CompatibilityHoldGuardianVersion = ''
$script:LastCompatibleCodexFingerprint = ''
$script:FallbackUpdateProcess = $null
$script:UpdateHeartbeatLastAttempt = [datetime]::MinValue
$script:UpdateHeartbeatResultEvent = ''
$script:UpdateHeartbeatRetryAfterUtc = ''
$script:ReconnectSignalHistory = @()
$script:ReconnectSignalCount = 0
$script:ReconnectBurstCount = 0
$script:LastReconnectSignalAt = [datetime]::MinValue
$script:LastReconnectCategory = ''
$script:LastReconnectErrorClass = ''
$script:ReconnectListenerAction = 'Monitoring'
$script:PendingListenerWakeReasons = @()
$script:LastListenerWakeAt = [datetime]::MinValue
$script:LastListenerWakeReason = ''
$script:EventListener = $null
$hadStoredCodexPackageVersion = $false
$lastEquivalentValidationUri = ''
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
    $deferredText = [string](Get-CpgConfigValue $persistentState 'restartDeferredUntilUtc' '')
    if (-not [string]::IsNullOrWhiteSpace($deferredText)) {
        try { $script:RestartDeferredUntil = ([datetime]::Parse($deferredText)).ToLocalTime() } catch { $script:RestartDeferredUntil = [datetime]::MinValue }
    }
    $storedCodexVersion = [string](Get-CpgConfigValue $persistentState 'lastCodexPackageVersion' '')
    if (-not [string]::IsNullOrWhiteSpace($storedCodexVersion)) {
        $hadStoredCodexPackageVersion = $true
        $script:LastCodexPackageVersion = $storedCodexVersion
    }
    $script:PendingCodexPackageVersion = [string](Get-CpgConfigValue $persistentState 'pendingCodexPackageVersion' '')
    $script:PostUpdateObservationVersion = [string](Get-CpgConfigValue $persistentState 'postUpdateObservationVersion' '')
    $observationText = [string](Get-CpgConfigValue $persistentState 'postUpdateObservationStartedUtc' '')
    if (-not [string]::IsNullOrWhiteSpace($observationText)) {
        try { $script:PostUpdateObservationStarted = ([datetime]::Parse($observationText)).ToLocalTime() } catch { $script:PostUpdateObservationStarted = [datetime]::MinValue }
    }
    $script:PostUpdateSuccessfulSamples = [Math]::Max(0, [int](Get-CpgConfigValue $persistentState 'postUpdateSuccessfulSamples' 0))
    $observationValidationText = [string](Get-CpgConfigValue $persistentState 'postUpdateLastValidationUtc' '')
    if (-not [string]::IsNullOrWhiteSpace($observationValidationText)) {
        try { $script:PostUpdateLastValidation = ([datetime]::Parse($observationValidationText)).ToLocalTime() } catch { $script:PostUpdateLastValidation = [datetime]::MinValue }
    }
    $script:PostUpdateObservationPassedVersion = [string](Get-CpgConfigValue $persistentState 'postUpdateObservationPassedVersion' '')
    $script:UpstreamSuspected = [bool](Get-CpgConfigValue $persistentState 'upstreamSuspected' $false)
    $upstreamText = [string](Get-CpgConfigValue $persistentState 'upstreamSuspectedSinceUtc' '')
    if (-not [string]::IsNullOrWhiteSpace($upstreamText)) {
        try { $script:UpstreamSuspectedSince = ([datetime]::Parse($upstreamText)).ToLocalTime() } catch { $script:UpstreamSuspectedSince = [datetime]::MinValue }
    }
    $script:CompatibilityUpdateRequestedVersion = [string](Get-CpgConfigValue $persistentState 'compatibilityUpdateRequestedVersion' '')
    $compatibilityAttemptText = [string](Get-CpgConfigValue $persistentState 'compatibilityUpdateLastAttemptUtc' '')
    if (-not [string]::IsNullOrWhiteSpace($compatibilityAttemptText)) {
        try { $script:CompatibilityUpdateLastAttempt = ([datetime]::Parse($compatibilityAttemptText)).ToLocalTime() } catch { $script:CompatibilityUpdateLastAttempt = [datetime]::MinValue }
    }
    $script:CompatibilityHold = [bool](Get-CpgConfigValue $persistentState 'compatibilityHold' $false)
    $script:CompatibilityHoldCodexVersion = [string](Get-CpgConfigValue $persistentState 'compatibilityHoldCodexVersion' '')
    $script:CompatibilityHoldGuardianVersion = [string](Get-CpgConfigValue $persistentState 'compatibilityHoldGuardianVersion' '')
    $script:LastCompatibleCodexFingerprint = [string](Get-CpgConfigValue $persistentState 'lastCompatibleCodexFingerprint' '')
}

function Get-CpgOwnedUpdateContext {
    $markerPath = Join-Path $script:Root '.cpg-install.json'
    if (-not (Test-Path -LiteralPath $markerPath)) { throw 'The install marker is unavailable.' }
    $marker = Get-Content -Raw -LiteralPath $markerPath | ConvertFrom-Json
    if (-not (Test-CpgInstallMarker -InstallRoot $script:Root -Marker $marker)) { throw 'The install marker does not own this directory.' }

    $updaterPath = Join-Path $script:Root 'Update.ps1'
    if (-not (Test-Path -LiteralPath $updaterPath)) { throw 'The installed updater is unavailable.' }
    $updateTaskName = [string](Get-CpgConfigValue $marker 'updateTaskName' 'Codex Proxy Guardian Update')
    $task = Get-ScheduledTask -TaskName $updateTaskName -ErrorAction SilentlyContinue
    $taskOwned = $false
    if ($null -ne $task) {
        $expectedFileArgument = '-File "{0}"' -f $updaterPath
        $taskOwned = @($task.Actions | Where-Object {
            ([string]$_.Execute).EndsWith('powershell.exe', [System.StringComparison]::OrdinalIgnoreCase) -and
            ([string]$_.Arguments).IndexOf($expectedFileArgument, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
        }).Count -gt 0
    }
    $fallbackRunning = $null -ne $script:FallbackUpdateProcess -and -not $script:FallbackUpdateProcess.HasExited
    return [pscustomobject]@{
        TaskName = $updateTaskName
        Task = $task
        TaskOwned = $taskOwned
        Running = ($fallbackRunning -or ($taskOwned -and [string]$task.State -eq 'Running'))
        UpdaterPath = $updaterPath
    }
}

function Start-CpgOwnedUpdateCheck {
    param($Context)
    if ($null -eq $Context) { $Context = Get-CpgOwnedUpdateContext }

    if ([bool]$Context.TaskOwned) {
        Start-ScheduledTask -TaskName ([string]$Context.TaskName)
        return 'ScheduledTask'
    }

    $powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -InstallRoot "{1}" -Install -Silent' -f ([string]$Context.UpdaterPath), $script:Root
    [void]($script:FallbackUpdateProcess = Start-Process -FilePath $powershellPath -ArgumentList $arguments -WindowStyle Hidden -PassThru)
    return 'DirectOwnedFallback'
}

function Read-CpgUpdateStatus {
    try {
        if (Test-Path -LiteralPath $script:UpdateStatusPath) { return Get-Content -Raw -LiteralPath $script:UpdateStatusPath | ConvertFrom-Json }
    }
    catch { }
    return $null
}

function Request-GuardianUpdateHeartbeat {
    param($Config)

    $intervalMinutes = [Math]::Max(15, [int](Get-CpgConfigValue $Config 'GuardianUpdateCheckIntervalMinutes' 60))
    $retryMinutes = [Math]::Max(5, [int](Get-CpgConfigValue $Config 'CompatibilityUpdateRetryMinutes' 15))
    try {
        $context = Get-CpgOwnedUpdateContext
        $updateStatus = Read-CpgUpdateStatus
        $decision = Get-CpgUpdateHeartbeatDecision `
            -AutomaticUpdates:([bool](Get-CpgConfigValue $Config 'AutomaticUpdates' $true)) `
            -UpdateStatus $updateStatus -UpdaterRunning:([bool]$context.Running) `
            -LastAttempt $script:UpdateHeartbeatLastAttempt -Now (Get-Date) `
            -IntervalMinutes $intervalMinutes -RetryMinutes $retryMinutes
        $script:UpdateHeartbeatResultEvent = [string]$decision.ResultEvent
        $script:UpdateHeartbeatRetryAfterUtc = [string]$decision.RetryAfterUtc
        if ([string]$decision.Action -ne 'Start') { return [string]$decision.State }

        $script:UpdateHeartbeatLastAttempt = Get-Date
        $source = Start-CpgOwnedUpdateCheck $context
        Write-GuardianLog 'INFO' 'guardian_update_heartbeat_started' 'The update listener started a verified release check.' @{
            guardian_version = $guardianVersion
            source = $source
            interval_minutes = $intervalMinutes
        }
        return 'Running'
    }
    catch {
        $script:UpdateHeartbeatLastAttempt = Get-Date
        $script:UpdateHeartbeatResultEvent = 'update_request_failed'
        $script:UpdateHeartbeatRetryAfterUtc = $script:UpdateHeartbeatLastAttempt.AddMinutes($retryMinutes).ToUniversalTime().ToString('o')
        Write-GuardianLog 'WARN' 'guardian_update_heartbeat_failed' 'The update listener could not start a release check and will retry.' @{
            error = $_.Exception.Message
            retry_minutes = $retryMinutes
        }
        return 'FailedRetryScheduled'
    }
}

function Request-CompatibilityUpdateCheck {
    param([string]$CodexVersion, $Config)

    if ([string]::IsNullOrWhiteSpace($CodexVersion)) { return 'NotNeeded' }
    if (-not [bool](Get-CpgConfigValue $Config 'AutomaticUpdates' $true) -or
        -not [bool](Get-CpgConfigValue $Config 'CheckForGuardianUpdateOnCodexChange' $true)) {
        return 'Disabled'
    }
    $now = Get-Date
    $retryMinutes = [Math]::Max(5, [int](Get-CpgConfigValue $Config 'CompatibilityUpdateRetryMinutes' 15))

    try {
        $updateContext = Get-CpgOwnedUpdateContext
        $updateTaskName = [string]$updateContext.TaskName
        $updateStatus = Read-CpgUpdateStatus
        $decision = Get-CpgCompatibilityUpdateDecision -CodexVersion $CodexVersion `
            -RequestedVersion $script:CompatibilityUpdateRequestedVersion `
            -LastAttempt $script:CompatibilityUpdateLastAttempt -UpdateStatus $updateStatus `
            -TaskRunning:([bool]$updateContext.Running) -Now $now -RetryMinutes $retryMinutes
        $script:CompatibilityUpdateResultEvent = [string]$decision.ResultEvent
        $script:CompatibilityUpdateRetryAfterUtc = [string]$decision.RetryAfterUtc

        if ([string]$decision.State -eq 'Running' -and
            -not [string]::Equals($script:CompatibilityUpdateRequestedVersion, $CodexVersion, [System.StringComparison]::OrdinalIgnoreCase)) {
            $script:CompatibilityUpdateRequestedVersion = $CodexVersion
            $script:CompatibilityUpdateLastAttempt = $now
            Write-GuardianLog 'INFO' 'codex_compatibility_update_joined' 'A running verified Guardian update task was associated with the new Codex package version.' @{
                codex_version = $CodexVersion
                guardian_version = $guardianVersion
                update_task = $updateTaskName
            }
        }
        if ([string]$decision.Action -ne 'Start') { return [string]$decision.State }

        $script:CompatibilityUpdateRequestedVersion = $CodexVersion
        $script:CompatibilityUpdateLastAttempt = $now
        $updateSource = Start-CpgOwnedUpdateCheck $updateContext
        $script:CompatibilityUpdateResultEvent = 'update_check_started'
        $script:CompatibilityUpdateRetryAfterUtc = $now.AddMinutes($retryMinutes).ToUniversalTime().ToString('o')
        $requestEvent = if ([string]$decision.State -eq 'Retrying') { 'codex_compatibility_update_retried' } else { 'codex_compatibility_update_requested' }
        Write-GuardianLog 'INFO' $requestEvent 'A Codex package change started the verified Guardian update task; completion is tracked and failures are retried automatically.' @{
            codex_version = $CodexVersion
            guardian_version = $guardianVersion
            update_task = $updateTaskName
            update_source = $updateSource
            retry_minutes = $retryMinutes
        }
        return 'Running'
    }
    catch {
        $script:CompatibilityUpdateRequestedVersion = $CodexVersion
        $script:CompatibilityUpdateLastAttempt = $now
        $script:CompatibilityUpdateResultEvent = 'update_request_failed'
        $script:CompatibilityUpdateRetryAfterUtc = $now.AddMinutes($retryMinutes).ToUniversalTime().ToString('o')
        Write-GuardianLog 'WARN' 'codex_compatibility_update_request_failed' 'The compatibility update check could not be completed or started. Guardian will retry for this same Codex version; the daily updater also remains available.' @{
            codex_version = $CodexVersion
            error = $_.Exception.Message
            retry_minutes = $retryMinutes
        }
        return 'FailedRetryScheduled'
    }
}

function Get-CodexCompatibilityFingerprint {
    param($CodexApp, [bool]$UseProxyArgument, [bool]$RequireManagedStreaming)
    if ($null -eq $CodexApp) { return $null }
    $text = @(
        [string]$CodexApp.PackageName,
        [string]$CodexApp.Version,
        [string]$CodexApp.ApplicationId,
        [string]$CodexApp.ProcessName,
        [string]$CodexApp.ResolutionMethod,
        [string]$UseProxyArgument,
        [string]$RequireManagedStreaming,
        'managed-streaming-contract-v3'
    ) -join '|'
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}
if ($postUpdateStabilityEnabled -and $null -ne $codexApp) {
    if (-not $hadStoredCodexPackageVersion -or
        (-not [string]::IsNullOrWhiteSpace($script:LastCodexPackageVersion) -and
        -not [string]::Equals($script:LastCodexPackageVersion, [string]$codexApp.Version, [System.StringComparison]::OrdinalIgnoreCase))) {
        $script:PendingCodexPackageVersion = [string]$codexApp.Version
        $script:LastCodexPackageVersion = [string]$codexApp.Version
    }
}
if ($script:CompatibilityHold -and (
    -not [string]::Equals($script:CompatibilityHoldGuardianVersion, $guardianVersion, [System.StringComparison]::OrdinalIgnoreCase) -or
    $null -eq $codexApp -or
    -not [string]::Equals($script:CompatibilityHoldCodexVersion, [string]$codexApp.Version, [System.StringComparison]::OrdinalIgnoreCase))) {
    $script:CompatibilityHold = $false
    $script:CompatibilityHoldCodexVersion = ''
    $script:CompatibilityHoldGuardianVersion = ''
}
$compatibilityUpdateCheckState = if ($null -eq $codexApp) {
    'NotNeeded'
}
elseif (-not [string]::Equals($script:CompatibilityUpdateRequestedVersion, [string]$codexApp.Version, [System.StringComparison]::OrdinalIgnoreCase)) {
    'Pending'
}
else {
    'Pending'
}
$lastCompatibilityUpdateEvaluation = [datetime]::MinValue
$updateHeartbeatState = 'Pending'
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

Initialize-CpgCodexLogTail $config
$script:EventListener = Initialize-CpgEventListener $config
$lastUpdateHeartbeatEvaluation = [datetime]::MinValue

Write-GuardianLog 'INFO' 'guardian_started' 'Codex Proxy Guardian started.' @{
    version = $guardianVersion
    pid = $PID
    mode = if ($ObserveOnly) { 'ObserveOnly' } else { $guardianMode }
    external_launch_policy = $externalLaunchPolicy
    package_found = ($null -ne $codexApp)
    event_listener_enabled = [bool]$script:EventListener.Enabled
    event_listener_components = @($script:EventListener.Components)
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
                $updatedRequireManagedStreaming = [bool](Get-CpgConfigValue $updatedConfig 'RequireManagedLaunchForStreaming' $true)
                $updatedPolicy = if ($ObserveOnly) { 'ObserveOnly' } elseif ($updatedManageExternal) { 'Enforce' } elseif ($updatedSafeRepair -and $updatedRequireManagedStreaming) { 'SafeStreamingRepair' } elseif ($updatedSafeRepair) { 'SafeEvidenceRepair' } else { 'ManagedShortcutOnly' }
                $config.Mode = $updatedMode
                $config.ManageExternalCodexLaunches = [bool](Get-CpgConfigValue $updatedConfig 'ManageExternalCodexLaunches' $false)
                $config.SafeRepairExternalCodexLaunches = [bool](Get-CpgConfigValue $updatedConfig 'SafeRepairExternalCodexLaunches' $true)
                $config | Add-Member -MemberType NoteProperty -Name RequireManagedLaunchForStreaming -Value $updatedRequireManagedStreaming -Force
                $guardianMode = $updatedMode
                $manageExternalLaunches = $updatedManageExternal
                $safeRepairExternalLaunches = $updatedSafeRepair
                $requireManagedLaunchForStreaming = $updatedRequireManagedStreaming
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

            $listenerWakeReasons = @($script:PendingListenerWakeReasons)
            $script:PendingListenerWakeReasons = @()
            if ($listenerWakeReasons.Count -gt 0) {
                $script:LastListenerWakeAt = Get-Date
                $script:LastListenerWakeReason = ($listenerWakeReasons -join ',')
                if ('CodexProcess' -in $listenerWakeReasons) {
                    $lastCodexResolve = [datetime]::MinValue
                    $lastCompatibilityUpdateEvaluation = [datetime]::MinValue
                }
                if ('UpdateStatus' -in $listenerWakeReasons) {
                    $lastCompatibilityUpdateEvaluation = [datetime]::MinValue
                    $lastUpdateHeartbeatEvaluation = [datetime]::MinValue
                }
            }

            $newReconnectSignals = @(Receive-CpgReconnectSignals $config)

            if ($null -eq $codexApp -or -not (Test-Path -LiteralPath ([string]$codexApp.ExecutablePath)) -or ((Get-Date) - $lastCodexResolve).TotalSeconds -ge $codexResolveIntervalSeconds) {
                $resolvedApp = Get-CpgCodexApp -Config $config
                $lastCodexResolve = Get-Date
                if ($null -ne $resolvedApp) {
                    $appChanged = $null -eq $codexApp -or -not [string]::Equals([string]$codexApp.ExecutablePath, [string]$resolvedApp.ExecutablePath, [System.StringComparison]::OrdinalIgnoreCase)
                    $versionChanged = -not [string]::IsNullOrWhiteSpace($script:LastCodexPackageVersion) -and
                        -not [string]::Equals($script:LastCodexPackageVersion, [string]$resolvedApp.Version, [System.StringComparison]::OrdinalIgnoreCase)
                    if ($postUpdateStabilityEnabled -and $versionChanged) {
                        $script:PendingCodexPackageVersion = [string]$resolvedApp.Version
                    }
                    if ($versionChanged) {
                        $script:CompatibilityHold = $false
                        $script:CompatibilityHoldCodexVersion = ''
                        $script:CompatibilityHoldGuardianVersion = ''
                        $compatibilityUpdateCheckState = 'Pending'
                    }
                    $script:LastCodexPackageVersion = [string]$resolvedApp.Version
                    $codexApp = $resolvedApp
                    if (@($codexApps | Where-Object { [string]::Equals([string]$_.ExecutablePath, [string]$resolvedApp.ExecutablePath, [System.StringComparison]::OrdinalIgnoreCase) }).Count -eq 0) {
                        $codexApps = @($codexApps) + @($resolvedApp)
                        $codexApps = @($codexApps | Select-Object -Last 3)
                    }
                    if ($appChanged -or $versionChanged) {
                        Write-GuardianLog 'INFO' 'codex_package_refreshed' 'The current Codex MSIX executable was refreshed from its package manifest.' @{
                            package = [string]$resolvedApp.PackageName
                            version = [string]$resolvedApp.Version
                            stability_observation_pending = (-not [string]::IsNullOrWhiteSpace($script:PendingCodexPackageVersion))
                        }
                    }
                }
                elseif ($null -ne $codexApp -and -not (Test-Path -LiteralPath ([string]$codexApp.ExecutablePath))) { $codexApp = $null }
            }

            if (((Get-Date) - $lastUpdateHeartbeatEvaluation).TotalSeconds -ge $updateHeartbeatEvaluationSeconds) {
                $lastUpdateHeartbeatEvaluation = Get-Date
                $updateHeartbeatState = Request-GuardianUpdateHeartbeat -Config $config
            }

            if ($null -ne $codexApp -and ((Get-Date) - $lastCompatibilityUpdateEvaluation).TotalSeconds -ge 30) {
                $lastCompatibilityUpdateEvaluation = Get-Date
                $previousCompatibilityRequestedVersion = $script:CompatibilityUpdateRequestedVersion
                $previousCompatibilityAttempt = $script:CompatibilityUpdateLastAttempt
                $compatibilityUpdateCheckState = Request-CompatibilityUpdateCheck -CodexVersion ([string]$codexApp.Version) -Config $config
                if ($previousCompatibilityRequestedVersion -ne $script:CompatibilityUpdateRequestedVersion -or
                    $previousCompatibilityAttempt -ne $script:CompatibilityUpdateLastAttempt) {
                    $proxyToPersist = if ([string]::IsNullOrWhiteSpace($activeProxy)) { $previousActiveProxy } else { $activeProxy }
                    Save-PersistentState $proxyToPersist $activeSource $lastRestart
                }
            }

            $preferredProxy = if (-not [string]::IsNullOrWhiteSpace($activeProxy)) { $activeProxy } else { $previousActiveProxy }
            $candidate = Find-EffectiveProxy $config $preferredProxy
            if ($null -ne $candidate -and
                -not [string]::IsNullOrWhiteSpace($preferredProxy) -and
                [string]$candidate.Uri -ne $preferredProxy -and
                (Test-CpgSameProxyEndpoint -FirstProxyUri $preferredProxy -SecondProxyUri ([string]$candidate.Uri))) {
                $validatedUri = [string]$candidate.Uri
                if ($lastEquivalentValidationUri -ne $validatedUri) {
                    Write-GuardianLog 'INFO' 'proxy_protocol_candidate' 'A higher-priority protocol validated on the same host and port; it will be adopted without restarting the current Codex session.' @{
                        active_proxy = Protect-CpgProxyUri $preferredProxy
                        validated_alternate = Protect-CpgProxyUri $validatedUri
                    }
                    $lastEquivalentValidationUri = $validatedUri
                }
            }
            elseif ($null -ne $candidate -and [string]$candidate.Uri -eq $preferredProxy) {
                $lastEquivalentValidationUri = ''
            }
            $validationCandidate = $candidate
            if ($null -eq $validationCandidate -and @($script:LastProxyValidationAttempts).Count -gt 0) {
                if (-not [string]::IsNullOrWhiteSpace($preferredProxy)) {
                    $validationCandidate = @($script:LastProxyValidationAttempts | Where-Object {
                        Test-CpgSameProxyEndpoint -FirstProxyUri $preferredProxy -SecondProxyUri ([string]$_.Uri)
                    } | Select-Object -First 1)[0]
                }
                if ($null -eq $validationCandidate) { $validationCandidate = @($script:LastProxyValidationAttempts)[0] }
            }
            $currentValidation = if ($null -eq $validationCandidate) { $null } else { $validationCandidate.ValidationResult }
            $currentValidationFresh = if ($null -eq $validationCandidate) { $false } else { [bool](Get-CpgConfigValue $validationCandidate 'ValidationFresh' $false) }
            $currentValidationCheckedAt = if ($null -eq $validationCandidate) { [datetime]::MinValue } else { [datetime](Get-CpgConfigValue $validationCandidate 'ValidationCheckedAt' ([datetime]::MinValue)) }
            $currentEndpointReachable = if ($null -eq $validationCandidate) { $false } else { [bool](Get-CpgConfigValue $validationCandidate 'EndpointReachable' $false) }
            $currentValidationPassed = if ($null -eq $currentValidation) { $false } else { [bool](Get-CpgConfigValue $currentValidation 'Passed' $false) }
            $currentCriticalTargetsPassed = if ($null -eq $currentValidation) { $false } else { [bool](Get-CpgConfigValue $currentValidation 'CriticalTargetsPassed' $false) }
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
                            $changeDecision = Get-CpgProxyChangeDecision -CurrentProxyUri $oldProxy -ValidatedProxyUri $activeProxy
                            if ([string]$changeDecision.Kind -eq 'ProtocolUpdate') {
                                Write-GuardianLog 'INFO' 'proxy_protocol_updated' 'The preferred protocol for the same proxy endpoint was updated for future launches; the current Codex session was not restarted.' @{
                                    old_proxy = Protect-CpgProxyUri $oldProxy
                                    new_proxy = Protect-CpgProxyUri $activeProxy
                                    source = $activeSource
                                }
                            }
                            else {
                                $script:LastProxyConnection = [datetime]::MinValue
                                $restartRequired = [bool]$changeDecision.RestartRequired
                                Write-GuardianLog 'INFO' 'proxy_changed' 'The validated proxy endpoint changed after debounce.' @{
                                    old_proxy = Protect-CpgProxyUri $oldProxy
                                    new_proxy = Protect-CpgProxyUri $activeProxy
                                    source = $activeSource
                                }
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
            $currentPackageRoots = @()
            if ($null -ne $codexApp) {
                $currentPackageRoots = @($roots | Where-Object {
                    -not [string]::IsNullOrWhiteSpace([string]$_.ExecutablePath) -and
                    [string]::Equals([string]$_.ExecutablePath, [string]$codexApp.ExecutablePath, [System.StringComparison]::OrdinalIgnoreCase)
                })
            }

            $stateChanged = $false
            if ($postUpdateStabilityEnabled -and -not [string]::IsNullOrWhiteSpace($script:PendingCodexPackageVersion) -and $currentPackageRoots.Count -gt 0) {
                $script:PostUpdateObservationVersion = $script:PendingCodexPackageVersion
                $script:PendingCodexPackageVersion = ''
                $script:PostUpdateObservationStarted = Get-Date
                $script:PostUpdateSuccessfulSamples = 0
                $script:PostUpdateLastValidation = [datetime]::MinValue
                $script:LastProxyConnection = [datetime]::MinValue
                $pendingExternalTrafficObserved = $false
                $stateChanged = $true
                Write-GuardianLog 'INFO' 'codex_update_observation_started' 'A newly updated Codex process was detected. Guardian will require consecutive fresh critical-target validations before accepting indirect traffic evidence.' @{
                    version = $script:PostUpdateObservationVersion
                    required_samples = $postUpdateStabilitySamples
                    minimum_seconds = $postUpdateStabilitySeconds
                    codex_pids = @($currentPackageRoots | ForEach-Object { [int]$_.ProcessId })
                }
            }

            $observationActive = $postUpdateStabilityEnabled -and
                -not [string]::IsNullOrWhiteSpace($script:PostUpdateObservationVersion) -and
                $script:PostUpdateObservationStarted -gt [datetime]::MinValue
            $freshForStability = $currentValidationFresh -and
                $currentValidationCheckedAt -gt $script:PostUpdateLastValidation
            $elapsedObservationSeconds = if ($observationActive) { ((Get-Date) - $script:PostUpdateObservationStarted).TotalSeconds } else { 0 }
            $previousUpstreamSuspected = $script:UpstreamSuspected
            $stabilityDecision = Get-CpgProxyStabilityDecision -ObservationActive:$observationActive `
                -ValidationFresh:$freshForStability -EndpointReachable:$currentEndpointReachable `
                -ValidationPassed:$currentValidationPassed -CriticalTargetsPassed:$currentCriticalTargetsPassed `
                -SuccessfulSamples $script:PostUpdateSuccessfulSamples -RequiredSamples $postUpdateStabilitySamples `
                -ElapsedSeconds $elapsedObservationSeconds -MinimumObservationSeconds $postUpdateStabilitySeconds `
                -UpstreamSuspected:$script:UpstreamSuspected
            $script:PostUpdateSuccessfulSamples = [int]$stabilityDecision.SuccessfulSamples
            $script:UpstreamSuspected = [bool]$stabilityDecision.UpstreamSuspected
            if ($freshForStability) { $script:PostUpdateLastValidation = $currentValidationCheckedAt; $stateChanged = $true }
            if ($script:UpstreamSuspected -and -not $previousUpstreamSuspected) {
                $script:UpstreamSuspectedSince = Get-Date
                $stateChanged = $true
                Write-GuardianLog 'WARN' 'proxy_upstream_suspected' 'The local proxy listener is reachable, but a critical external validation failed. Codex was left running; change the provider node if reconnects continue.' @{
                    proxy = if ([string]::IsNullOrWhiteSpace($activeProxy)) { $null } else { Protect-CpgProxyUri $activeProxy }
                    critical_failures = @(Get-CpgConfigValue $currentValidation 'CriticalFailures' @())
                    critical_missing = @(Get-CpgConfigValue $currentValidation 'CriticalMissing' @())
                    codex_restart_requested = $false
                    system_proxy_modified = $false
                }
            }
            elseif (-not $script:UpstreamSuspected -and $previousUpstreamSuspected -and $freshForStability) {
                $script:UpstreamSuspectedSince = [datetime]::MinValue
                $stateChanged = $true
                Write-GuardianLog 'INFO' 'proxy_upstream_recovered' 'Fresh critical-target validation passed again; the suspected upstream incident is cleared.' @{}
            }
            if ($stabilityDecision.ObservationComplete) {
                $completedVersion = $script:PostUpdateObservationVersion
                $script:PostUpdateObservationPassedVersion = $completedVersion
                $script:PostUpdateObservationVersion = ''
                $script:PostUpdateObservationStarted = [datetime]::MinValue
                $stateChanged = $true
                $observationActive = $false
                Write-GuardianLog 'INFO' 'codex_update_observation_passed' 'Post-update critical-target observation passed. Indirect proxy traffic evidence may now be accepted for this Codex version.' @{
                    version = $completedVersion
                    successful_samples = $script:PostUpdateSuccessfulSamples
                    observed_seconds = [Math]::Round($elapsedObservationSeconds, 1)
                }
            }
            $stabilityReady = -not $observationActive -and -not $script:UpstreamSuspected
            if ($stateChanged) {
                $proxyToPersist = if ([string]::IsNullOrWhiteSpace($activeProxy)) { $previousActiveProxy } else { $activeProxy }
                Save-PersistentState $proxyToPersist $activeSource $lastRestart
            }
            $matchingRoots = @()
            if ($proxyIsValid) {
                $useArgument = [bool](Get-CpgConfigValue $config 'UseChromiumProxyArgument' $true)
                $matchingRoots = @($roots | Where-Object { Test-CpgRootUsesProxy $_ $activeProxy $useArgument })
            }
            if ($matchingRoots.Count -gt 0) {
                $managedRootPid = [int]$matchingRoots[0].ProcessId
                $pendingExternalPid = 0
                if ($restartRequired) {
                    $restartRequired = $false
                    $script:RestartDeferredUntil = [datetime]::MinValue
                    Write-GuardianLog 'INFO' 'restart_no_longer_required' 'The running Codex process already matches the active proxy; the pending restart was cancelled.' @{
                        pid = $managedRootPid
                    }
                }
                if ($script:RecoveryLaunchRequired) {
                    $script:RecoveryLaunchRequired = $false
                    Save-PersistentState $activeProxy $activeSource $lastRestart
                    Write-GuardianLog 'INFO' 'codex_restart_confirmed' 'The relaunched Codex root was observed with the current proxy argument.' @{ pid = $managedRootPid }
                }
            }
            elseif ($managedRootPid -ne 0 -and $managedRootPid -notin $rootIds) { $managedRootPid = 0 }

            if ($script:LastReconnectSignalAt -gt [datetime]::MinValue) {
                $previousReconnectAction = $script:ReconnectListenerAction
                if ($script:UpstreamSuspected) {
                    $script:ReconnectListenerAction = 'UpstreamSuspected'
                }
                elseif (-not $proxyIsValid) {
                    $script:ReconnectListenerAction = 'ProxyRevalidationFailed'
                }
                elseif ($roots.Count -gt 0 -and $matchingRoots.Count -eq 0 -and $requireManagedLaunchForStreaming) {
                    $script:ReconnectListenerAction = 'ManagedRepairRecommended'
                }
                else {
                    $script:ReconnectListenerAction = 'ValidatedAfterSignal'
                }
                if ($newReconnectSignals.Count -gt 0 -or $previousReconnectAction -ne $script:ReconnectListenerAction) {
                    Write-GuardianLog 'INFO' 'codex_reconnect_signal_assessed' 'The reconnect listener completed an immediate proxy assessment without restarting Codex.' @{
                        action = $script:ReconnectListenerAction
                        proxy_valid = $proxyIsValid
                        streaming_proxy_guaranteed = ($matchingRoots.Count -gt 0)
                        upstream_suspected = $script:UpstreamSuspected
                        codex_restart_requested = $false
                    }
                }
            }

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

            $postUpdateObservationPassed = $null -ne $codexApp -and
                [string]::Equals($script:PostUpdateObservationPassedVersion, [string]$codexApp.Version, [System.StringComparison]::OrdinalIgnoreCase)
            $secondsSinceManagedLaunch = if ($lastRestart -gt [datetime]::MinValue) { ((Get-Date) - $lastRestart).TotalSeconds } else { 0 }
            $compatibilityFingerprint = Get-CodexCompatibilityFingerprint -CodexApp $codexApp `
                -UseProxyArgument:([bool](Get-CpgConfigValue $config 'UseChromiumProxyArgument' $true)) `
                -RequireManagedStreaming:$requireManagedLaunchForStreaming
            $compatibilityDecision = Get-CpgCodexCompatibilityDecision -ObservationActive:$observationActive `
                -ObservationPassed:$postUpdateObservationPassed -LaunchConfigured:($matchingRoots.Count -gt 0) `
                -TrafficObserved:$trafficObservedRecently -RequireManagedLaunchForStreaming:$requireManagedLaunchForStreaming `
                -RecoveryPending:$script:RecoveryLaunchRequired `
                -CodexRunning:($roots.Count -gt 0) -SecondsSinceManagedLaunch $secondsSinceManagedLaunch `
                -ConfirmationSeconds $compatibilityConfirmationSeconds -CompatibilityBlocked:$script:CompatibilityHold
            if ([string]$compatibilityDecision.State -eq 'Compatible') {
                $compatibilityRecovered = $script:CompatibilityHold
                $script:CompatibilityHold = $false
                $script:CompatibilityHoldCodexVersion = ''
                $script:CompatibilityHoldGuardianVersion = ''
                if (-not [string]::IsNullOrWhiteSpace($compatibilityFingerprint) -and $script:LastCompatibleCodexFingerprint -ne $compatibilityFingerprint) {
                    $script:LastCompatibleCodexFingerprint = $compatibilityFingerprint
                    $stateChanged = $true
                }
                if ($compatibilityRecovered) {
                    $stateChanged = $true
                    Write-GuardianLog 'INFO' 'codex_compatibility_recovered' 'The current Codex version now has verified launch or traffic evidence; the compatibility safety hold is cleared.' @{
                        codex_version = if ($null -eq $codexApp) { $null } else { [string]$codexApp.Version }
                        evidence = [string]$compatibilityDecision.Evidence
                    }
                }
            }
            elseif ($compatibilityDecision.ReviewRequired -and -not $script:CompatibilityHold) {
                $script:CompatibilityHold = $true
                $script:CompatibilityHoldCodexVersion = if ($null -eq $codexApp) { '' } else { [string]$codexApp.Version }
                $script:CompatibilityHoldGuardianVersion = $guardianVersion
                $script:RecoveryLaunchRequired = $false
                $restartRequired = $false
                $stateChanged = $true
                Write-GuardianLog 'ERROR' 'codex_compatibility_review_required' 'A managed launch on this Codex version could not be confirmed. Guardian entered a fail-safe hold and will not restart Codex again; verified Guardian updates are checked automatically.' @{
                    codex_version = $script:CompatibilityHoldCodexVersion
                    guardian_version = $guardianVersion
                    evidence = [string]$compatibilityDecision.Evidence
                    codex_pids = $rootIds
                    codex_restart_requested = $false
                }
                $compatibilityDecision = Get-CpgCodexCompatibilityDecision -ObservationPassed:$postUpdateObservationPassed -CompatibilityBlocked:$true
            }
            if ($stateChanged) {
                $proxyToPersist = if ([string]::IsNullOrWhiteSpace($activeProxy)) { $previousActiveProxy } else { $activeProxy }
                Save-PersistentState $proxyToPersist $activeSource $lastRestart
            }

            if (-not $ObserveOnly -and -not $script:CompatibilityHold -and $script:RecoveryLaunchRequired -and $proxyIsValid -and $roots.Count -eq 0 -and $null -ne $codexApp) {
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

            if (-not $ObserveOnly -and -not $script:CompatibilityHold -and $restartRequired -and $proxyIsValid -and $stabilityReady -and $roots.Count -gt 0 -and $null -ne $codexApp) {
                if (((Get-Date) - $lastRestart).TotalSeconds -ge $restartCooldownSeconds -and (Test-GuardianRestartBudget)) {
                    if (Request-CodexRestartApproval -Reason 'proxy_endpoint_changed' -ProxyUri $activeProxy -Config $config) {
                        $lastRestart = Get-Date
                        Register-GuardianRestart $lastRestart
                        $script:RecoveryLaunchRequired = $true
                        Save-PersistentState $activeProxy $activeSource $lastRestart
                        $managedRootPid = Restart-CodexManaged $roots $activeProxy $config $codexApp -ApprovalGranted
                        $restartRequired = $false
                        $pendingExternalPid = 0
                        Save-PersistentState $activeProxy $activeSource $lastRestart
                    }
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
                    -RequireManagedLaunchForStreaming:$requireManagedLaunchForStreaming `
                    -StabilityReady:$stabilityReady -UpstreamSuspected:$script:UpstreamSuspected `
                    -CompatibilityBlocked:$script:CompatibilityHold `
                    -PendingSeconds ((Get-Date) - $pendingExternalSince).TotalSeconds `
                    -SafeGraceSeconds $safeExternalGraceSeconds -EnforceDebounceSeconds $externalDebounceSeconds

                switch ([string]$externalDecision.Action) {
                    'Wait' {
                        $externalLaunchState = if ([string]$externalDecision.Reason -eq 'post_update_stability_observation') {
                            'PostUpdateStabilityObservation'
                        }
                        elseif ([string]$externalDecision.Reason -eq 'safe_streaming_evidence_grace') {
                            'StreamingGuaranteeGrace'
                        }
                        elseif ($decisionMode -eq 'Enforce') {
                            'EnforceDebounce'
                        }
                        else {
                            'SafeEvidenceGrace'
                        }
                    }
                    'Hold' { $externalLaunchState = if ([string]$externalDecision.Reason -eq 'codex_compatibility_review_required') { 'CodexCompatibilityReviewRequired' } else { 'UpstreamSuspected' } }
                    'Keep' { $externalLaunchState = 'ProxyTrafficObserved' }
                    'ManagedShortcut' { $externalLaunchState = 'ManagedShortcutRequired' }
                    'Repair' {
                        $externalLaunchState = 'WaitingForRestartBudget'
                        if (((Get-Date) - $lastRestart).TotalSeconds -ge $restartCooldownSeconds -and (Test-GuardianRestartBudget)) {
                            if (Request-CodexRestartApproval -Reason ([string]$externalDecision.Reason) -ProxyUri $activeProxy -Config $config) {
                                $lastRestart = Get-Date
                                Register-GuardianRestart $lastRestart
                                $script:RecoveryLaunchRequired = $true
                                Save-PersistentState $activeProxy $activeSource $lastRestart
                                Write-GuardianLog 'INFO' 'external_codex_repair' 'The external Codex launch is being replaced with a validated managed launch.' @{
                                    pid = $externalPid
                                    policy = $externalLaunchPolicy
                                    reason = [string]$externalDecision.Reason
                                }
                                $managedRootPid = Restart-CodexManaged $roots $activeProxy $config $codexApp -ApprovalGranted
                                $pendingExternalPid = 0
                                $pendingExternalTrafficObserved = $false
                                $externalLaunchState = 'Repairing'
                                Save-PersistentState $activeProxy $activeSource $lastRestart
                            }
                            else { $externalLaunchState = 'RestartDeferred' }
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

            if (-not $ObserveOnly -and -not $script:CompatibilityHold -and (Test-Path -LiteralPath $script:LaunchRequestPath)) {
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
                    if (Request-CodexRestartApproval -Reason 'managed_shortcut_takeover' -ProxyUri $activeProxy -Config $config) {
                        Remove-Item -LiteralPath $script:LaunchRequestPath -Force -ErrorAction SilentlyContinue
                        $lastRestart = Get-Date
                        Register-GuardianRestart $lastRestart
                        $script:RecoveryLaunchRequired = $true
                        Save-PersistentState $activeProxy $activeSource $lastRestart
                        Write-GuardianLog 'INFO' 'managed_launch_takeover' 'The managed shortcut requested replacement of a Codex root missing the current proxy argument.' @{ old_pids = $rootIds }
                        $managedRootPid = Restart-CodexManaged $roots $activeProxy $config $codexApp -ApprovalGranted
                        $pendingExternalPid = 0
                    }
                }
            }

            $historyCutoff = (Get-Date).AddMinutes(-$restartLimitWindowMinutes)
            $script:RestartHistory = @($script:RestartHistory | Where-Object { $_ -ge $historyCutoff -and $_ -le (Get-Date) })

            $effectiveness = 'NoValidatedProxy'
            if ($proxyIsValid) { $effectiveness = 'ValidatedProxy' }
            if ($proxyIsValid -and $matchingRoots.Count -gt 0) { $effectiveness = 'LaunchConfigured' }
            if ($proxyIsValid -and $matchingRoots.Count -gt 0 -and $trafficObservedRecently -and $stabilityReady) { $effectiveness = 'ManagedTrafficObserved' }
            elseif ($proxyIsValid -and $roots.Count -gt 0 -and $trafficObservedRecently -and $stabilityReady -and $requireManagedLaunchForStreaming) { $effectiveness = 'SystemProxyHttpTrafficOnly' }
            elseif ($proxyIsValid -and $roots.Count -gt 0 -and $trafficObservedRecently -and $stabilityReady) { $effectiveness = 'TrafficObserved' }
            if ($observationActive) { $effectiveness = 'PostUpdateObservation' }
            if ($script:UpstreamSuspected) { $effectiveness = 'EndpointReachableOnly' }

            $proxyReachability = if ($null -eq $currentValidation) {
                'Unknown'
            }
            elseif (-not $currentEndpointReachable) {
                'ListenerUnavailable'
            }
            elseif ($currentValidationPassed -and $currentCriticalTargetsPassed) {
                'CriticalTargetsPassed'
            }
            else {
                'CriticalTargetsFailed'
            }
            $streamStability = if ($script:UpstreamSuspected) { 'UpstreamSuspected' } elseif ($observationActive) { 'ObservingAfterCodexUpdate' } else { 'IndirectEvidenceOnly' }
            $postUpdateObservationState = if ($observationActive) {
                'Observing'
            }
            elseif (-not [string]::IsNullOrWhiteSpace($script:PendingCodexPackageVersion)) {
                'WaitingForUpdatedCodexLaunch'
            }
            elseif ($null -ne $codexApp -and [string]::Equals($script:PostUpdateObservationPassedVersion, [string]$codexApp.Version, [System.StringComparison]::OrdinalIgnoreCase)) {
                'Passed'
            }
            else {
                'NotRequired'
            }
            $displayPostUpdateSuccessfulSamples = if ($postUpdateObservationState -eq 'Passed') {
                [Math]::Max($script:PostUpdateSuccessfulSamples, $postUpdateStabilitySamples)
            }
            else {
                $script:PostUpdateSuccessfulSamples
            }

            $guardianState = 'WaitingForProxy'
            if (-not $proxyIsValid -and -not [string]::IsNullOrWhiteSpace([string]$pendingProxy)) { $guardianState = 'Stabilizing' }
            if ($proxyIsValid) { $guardianState = 'Ready' }
            if ($proxyIsValid -and $externalLaunchState -in @('SafeEvidenceGrace', 'StreamingGuaranteeGrace', 'EnforceDebounce', 'WaitingForRestartBudget')) { $guardianState = 'EvaluatingCodexLaunch' }
            if ($observationActive) { $guardianState = 'ObservingAfterCodexUpdate' }
            if ($script:UpstreamSuspected) { $guardianState = 'UpstreamSuspected' }
            if ($proxyIsValid -and $externalLaunchState -eq 'ManagedShortcutRequired') { $guardianState = 'CodexNeedsManagedLaunch' }
            if ($externalLaunchState -eq 'CodexResolutionUnavailable') { $guardianState = 'CodexResolutionUnavailable' }
            if ($script:RecoveryLaunchRequired) { $guardianState = 'RecoveringCodex' }
            if ($script:RecoveryLaunchRequired -and $roots.Count -gt 0 -and $matchingRoots.Count -eq 0 -and -not $manageExternalLaunches -and -not $safeRepairExternalLaunches) { $guardianState = 'RecoveryBlockedByCodex' }
            if ([string]$compatibilityDecision.State -eq 'ReviewRequired') { $guardianState = 'CodexCompatibilityReviewRequired' }
            $restartApprovalRequired = $restartRequired -or $externalLaunchState -eq 'RestartDeferred'
            if ($restartApprovalRequired) {
                $guardianState = if ($script:RestartDeferredUntil -gt (Get-Date)) { 'RestartDeferred' } else { 'RestartApprovalRequired' }
            }
            if ($script:CircuitBreakerUntil -gt (Get-Date)) { $guardianState = 'RestartCircuitOpen' }

            Write-JsonAtomically $script:StatusPath ([ordered]@{
                running = $true
                guardianPid = $PID
                version = $guardianVersion
                updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
                guardianState = $guardianState
                mode = if ($ObserveOnly) { 'ObserveOnly' } else { $guardianMode }
                eventListenerEnabled = [bool]$script:EventListener.Enabled
                eventListenerComponents = @($script:EventListener.Components)
                eventListenerState = if ([bool]$script:EventListener.Enabled) { 'Ready' } else { 'PeriodicFallback' }
                lastListenerWakeUtc = if ($script:LastListenerWakeAt -gt [datetime]::MinValue) { $script:LastListenerWakeAt.ToUniversalTime().ToString('o') } else { $null }
                lastListenerWakeReason = if ([string]::IsNullOrWhiteSpace($script:LastListenerWakeReason)) { $null } else { $script:LastListenerWakeReason }
                externalLaunchPolicy = $externalLaunchPolicy
                externalLaunchState = $externalLaunchState
                safeRepairExternalLaunches = $safeRepairExternalLaunches
                streamingProxyGuaranteeRequired = $requireManagedLaunchForStreaming
                streamingProxyGuaranteed = ($matchingRoots.Count -gt 0)
                streamingProxyEvidence = if ($matchingRoots.Count -gt 0) { 'ManagedLaunchEnvironmentAndChromiumArgument' } elseif ($trafficObservedRecently) { 'SystemProxyHttpTrafficOnly' } else { 'NoManagedStreamingEvidence' }
                streamingRepairRequired = ($requireManagedLaunchForStreaming -and $roots.Count -gt 0 -and $matchingRoots.Count -eq 0)
                pendingExternalCodexPid = if ($pendingExternalPid -eq 0) { $null } else { $pendingExternalPid }
                pendingExternalProxyTrafficObserved = $pendingExternalTrafficObserved
                activeProxy = $activeProxy
                activeSource = $activeSource
                activeProxyValid = $proxyIsValid
                effectivenessEvidence = $effectiveness
                proxyReachability = $proxyReachability
                proxyEndpointReachable = $currentEndpointReachable
                streamStability = $streamStability
                streamStabilityLimitation = 'Critical HTTPS probes and local traffic are indirect evidence; authenticated long-lived Codex streams cannot be proven externally.'
                reconnectSignalsDetected = $script:ReconnectSignalCount
                reconnectBurstCount = $script:ReconnectBurstCount
                lastReconnectSignalUtc = if ($script:LastReconnectSignalAt -gt [datetime]::MinValue) { $script:LastReconnectSignalAt.ToUniversalTime().ToString('o') } else { $null }
                lastReconnectCategory = if ([string]::IsNullOrWhiteSpace($script:LastReconnectCategory)) { $null } else { $script:LastReconnectCategory }
                lastReconnectErrorClass = if ([string]::IsNullOrWhiteSpace($script:LastReconnectErrorClass)) { $null } else { $script:LastReconnectErrorClass }
                reconnectListenerAction = $script:ReconnectListenerAction
                upstreamSuspected = $script:UpstreamSuspected
                upstreamSuspectedSinceUtc = if ($script:UpstreamSuspectedSince -gt [datetime]::MinValue) { $script:UpstreamSuspectedSince.ToUniversalTime().ToString('o') } else { $null }
                upstreamRecommendedAction = if ($script:UpstreamSuspected) { 'Keep Codex open and change the provider node in the proxy application if reconnects continue.' } else { $null }
                safeTrafficEvidenceAccepted = ($trafficObservedRecently -and $stabilityReady -and (-not $requireManagedLaunchForStreaming -or $matchingRoots.Count -gt 0))
                postUpdateObservationState = $postUpdateObservationState
                postUpdateObservationActive = $observationActive
                postUpdateVersion = if ($observationActive) { $script:PostUpdateObservationVersion } elseif (-not [string]::IsNullOrWhiteSpace($script:PendingCodexPackageVersion)) { $script:PendingCodexPackageVersion } else { $script:PostUpdateObservationPassedVersion }
                postUpdateSuccessfulSamples = $displayPostUpdateSuccessfulSamples
                postUpdateRequiredSamples = $postUpdateStabilitySamples
                postUpdateObservationStartedUtc = if ($script:PostUpdateObservationStarted -gt [datetime]::MinValue) { $script:PostUpdateObservationStarted.ToUniversalTime().ToString('o') } else { $null }
                postUpdateMinimumSeconds = $postUpdateStabilitySeconds
                codexCompatibilityState = [string]$compatibilityDecision.State
                codexCompatibilityEvidence = [string]$compatibilityDecision.Evidence
                codexCompatibilityFingerprint = $compatibilityFingerprint
                lastCompatibleCodexFingerprint = $script:LastCompatibleCodexFingerprint
                codexCompatibilitySafeHold = $script:CompatibilityHold
                compatibilityUpdateCheckState = $compatibilityUpdateCheckState
                compatibilityUpdateRequestedVersion = $script:CompatibilityUpdateRequestedVersion
                compatibilityUpdateLastAttemptUtc = if ($script:CompatibilityUpdateLastAttempt -gt [datetime]::MinValue) { $script:CompatibilityUpdateLastAttempt.ToUniversalTime().ToString('o') } else { $null }
                compatibilityUpdateResultEvent = if ([string]::IsNullOrWhiteSpace($script:CompatibilityUpdateResultEvent)) { $null } else { $script:CompatibilityUpdateResultEvent }
                compatibilityUpdateRetryAfterUtc = if ([string]::IsNullOrWhiteSpace($script:CompatibilityUpdateRetryAfterUtc)) { $null } else { $script:CompatibilityUpdateRetryAfterUtc }
                guardianUpdateHeartbeatState = $updateHeartbeatState
                guardianUpdateCheckIntervalMinutes = [Math]::Max(15, [int](Get-CpgConfigValue $config 'GuardianUpdateCheckIntervalMinutes' 60))
                guardianUpdateLastAttemptUtc = if ($script:UpdateHeartbeatLastAttempt -gt [datetime]::MinValue) { $script:UpdateHeartbeatLastAttempt.ToUniversalTime().ToString('o') } else { $null }
                guardianUpdateResultEvent = if ([string]::IsNullOrWhiteSpace($script:UpdateHeartbeatResultEvent)) { $null } else { $script:UpdateHeartbeatResultEvent }
                guardianUpdateRetryAfterUtc = if ([string]::IsNullOrWhiteSpace($script:UpdateHeartbeatRetryAfterUtc)) { $null } else { $script:UpdateHeartbeatRetryAfterUtc }
                compatibilityAutomation = @{
                    contractVersion = 3
                    behaviorBasedEvidence = $true
                    codexVersionInvalidatesPreviousEvidence = $true
                    managedLaunchAndFreshTrafficRequired = $requireManagedLaunchForStreaming
                    manifestReresolution = $true
                    postUpdateCapabilityAudit = $postUpdateStabilityEnabled
                    immediateVerifiedGuardianUpdateCheck = [bool](Get-CpgConfigValue $config 'CheckForGuardianUpdateOnCodexChange' $true)
                    dailyVerifiedGuardianUpdateFallback = [bool](Get-CpgConfigValue $config 'AutomaticUpdates' $true)
                    eventDrivenUpdateHeartbeat = [bool](Get-CpgConfigValue $config 'AutomaticUpdates' $true)
                    reconnectSignalForcesFreshValidation = $true
                    failSafeNoRestartOnUnconfirmedAdapter = $true
                }
                proxyTestSuccessCount = if ($null -eq $currentValidation) { 0 } else { $currentValidation.SuccessCount }
                proxyTestRequiredCount = if ($null -eq $currentValidation) { [int](Get-CpgConfigValue $config 'MinimumSuccessfulProxyTests' 1) } else { $currentValidation.RequiredCount }
                proxyTestTargetCount = if ($null -eq $currentValidation) { @((Get-CpgConfigValue $config 'ProxyTestUrls' @())).Count } else { $currentValidation.TargetCount }
                proxyTestAttemptedCount = if ($null -eq $currentValidation) { 0 } else { $currentValidation.AttemptedCount }
                proxyCriticalTargetsPassed = if ($null -eq $currentValidation) { $false } else { [bool](Get-CpgConfigValue $currentValidation 'CriticalTargetsPassed' $true) }
                proxyCriticalFailures = @(if ($null -eq $currentValidation) { @() } else { @((Get-CpgConfigValue $currentValidation 'CriticalFailures' @())) })
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
                restartApprovalRequired = $restartApprovalRequired
                restartNotificationEnabled = [bool](Get-CpgConfigValue $config 'NotifyBeforeCodexRestart' $true)
                restartDeferredUntilUtc = if ($script:RestartDeferredUntil -gt (Get-Date)) { $script:RestartDeferredUntil.ToUniversalTime().ToString('o') } else { $null }
                recoveryLaunchRequired = $script:RecoveryLaunchRequired
                recentRestartCount = @($script:RestartHistory).Count
                restartCircuitOpen = ($script:CircuitBreakerUntil -gt (Get-Date))
                circuitBreakerUntilUtc = if ($script:CircuitBreakerUntil -gt (Get-Date)) { $script:CircuitBreakerUntil.ToUniversalTime().ToString('o') } else { $null }
                systemProxyModified = $false
            })

            $consecutiveErrors = 0
            if ($RunOnce) { break }
            $wakeReasons = @(Wait-CpgEventListener -Listener $script:EventListener -TimeoutSeconds $pollSeconds -DebounceMilliseconds $listenerDebounceMilliseconds)
            if ($wakeReasons.Count -gt 0) {
                $script:PendingListenerWakeReasons = @($wakeReasons | Select-Object -Unique)
            }
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
    Stop-CpgEventListener $script:EventListener
    Write-GuardianLog 'INFO' 'guardian_stopped' 'Codex Proxy Guardian stopped.' @{}
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
