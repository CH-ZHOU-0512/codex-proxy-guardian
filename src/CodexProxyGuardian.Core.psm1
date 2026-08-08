Set-StrictMode -Version 2.0

function Get-CpgConfigValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$Name,
        $Default
    )

    $property = $Config.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return $Default
    }
    return $property.Value
}

function Update-CpgConfigDefaults {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)]$Defaults
    )

    foreach ($property in $Defaults.PSObject.Properties) {
        if ($null -eq $Config.PSObject.Properties[$property.Name]) {
            $Config | Add-Member -MemberType NoteProperty -Name $property.Name -Value $property.Value
        }
    }
    return $Config
}

function Set-CpgModeProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][ValidateSet('Auto', 'Safe', 'Strict', 'Enforce')][string]$Profile
    )

    $strict = $Profile -in @('Strict', 'Enforce')
    foreach ($entry in ([ordered]@{
        Mode = if ($strict) { 'Enforce' } else { 'Safe' }
        ManageExternalCodexLaunches = $strict
        SafeRepairExternalCodexLaunches = $true
    }).GetEnumerator()) {
        $Config | Add-Member -MemberType NoteProperty -Name $entry.Key -Value $entry.Value -Force
    }
    return $Config
}

function Get-CpgModeProfile {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Config)

    $mode = [string](Get-CpgConfigValue -Config $Config -Name 'Mode' -Default 'Safe')
    $managed = [bool](Get-CpgConfigValue -Config $Config -Name 'ManageExternalCodexLaunches' -Default $false)
    if ($mode -eq 'Enforce' -or $managed) { return 'Strict' }
    return 'Automatic'
}

function Compare-CpgSemanticVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Left,
        [Parameter(Mandatory = $true)][string]$Right
    )

    $pattern = '^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?$'
    $leftMatch = [regex]::Match($Left.Trim(), $pattern)
    $rightMatch = [regex]::Match($Right.Trim(), $pattern)
    if (-not $leftMatch.Success -or -not $rightMatch.Success) { throw "Invalid semantic version comparison: '$Left' and '$Right'." }

    for ($index = 1; $index -le 3; $index++) {
        $leftNumber = [int64]$leftMatch.Groups[$index].Value
        $rightNumber = [int64]$rightMatch.Groups[$index].Value
        if ($leftNumber -lt $rightNumber) { return -1 }
        if ($leftNumber -gt $rightNumber) { return 1 }
    }

    $leftPre = [string]$leftMatch.Groups[4].Value
    $rightPre = [string]$rightMatch.Groups[4].Value
    if ([string]::IsNullOrWhiteSpace($leftPre) -and [string]::IsNullOrWhiteSpace($rightPre)) { return 0 }
    if ([string]::IsNullOrWhiteSpace($leftPre)) { return 1 }
    if ([string]::IsNullOrWhiteSpace($rightPre)) { return -1 }

    $leftParts = @($leftPre -split '\.')
    $rightParts = @($rightPre -split '\.')
    $count = [Math]::Max($leftParts.Count, $rightParts.Count)
    for ($index = 0; $index -lt $count; $index++) {
        if ($index -ge $leftParts.Count) { return -1 }
        if ($index -ge $rightParts.Count) { return 1 }
        $leftNumeric = $leftParts[$index] -match '^\d+$'
        $rightNumeric = $rightParts[$index] -match '^\d+$'
        if ($leftNumeric -and $rightNumeric) {
            $leftNumber = [int64]$leftParts[$index]
            $rightNumber = [int64]$rightParts[$index]
            if ($leftNumber -lt $rightNumber) { return -1 }
            if ($leftNumber -gt $rightNumber) { return 1 }
        }
        elseif ($leftNumeric) { return -1 }
        elseif ($rightNumeric) { return 1 }
        else {
            $comparison = [string]::Compare($leftParts[$index], $rightParts[$index], [System.StringComparison]::Ordinal)
            if ($comparison -lt 0) { return -1 }
            if ($comparison -gt 0) { return 1 }
        }
    }
    return 0
}

function Select-CpgLatestRelease {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Releases,
        [ValidateSet('Stable', 'Prerelease')][string]$Channel = 'Stable'
    )

    # Windows PowerShell 5.1 can emit a top-level JSON array from
    # Invoke-RestMethod as one pipeline object. Flatten that shape here so the
    # updater does not mistake the complete release array for one release.
    $pending = New-Object System.Collections.Queue
    $pending.Enqueue($Releases)
    $selected = $null
    while ($pending.Count -gt 0) {
        $release = $pending.Dequeue()
        if ($release -is [System.Array]) {
            foreach ($item in $release) { $pending.Enqueue($item) }
            continue
        }
        if ($null -eq $release -or [bool](Get-CpgConfigValue $release 'draft' $false)) { continue }
        if ($Channel -eq 'Stable' -and [bool](Get-CpgConfigValue $release 'prerelease' $false)) { continue }
        $tag = [string](Get-CpgConfigValue $release 'tag_name' '')
        if ($tag -notmatch '^v?\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$') { continue }
        $candidateVersion = $tag.TrimStart('v')
        $selectedVersion = if ($null -eq $selected) { '' } else { ([string]$selected.tag_name).TrimStart('v') }
        if ($null -eq $selected -or (Compare-CpgSemanticVersion $candidateVersion $selectedVersion) -gt 0) {
            $selected = $release
        }
    }
    return $selected
}

function Select-CpgUpdateRelease {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Releases,
        [Parameter(Mandatory = $true)][string]$CurrentVersion,
        [ValidateSet('Stable', 'Prerelease')][string]$Channel = 'Stable'
    )

    $latest = Select-CpgLatestRelease -Releases $Releases -Channel $Channel
    if ($null -eq $latest) { return $null }
    $latestVersion = ([string]$latest.tag_name).TrimStart('v')
    if ((Compare-CpgSemanticVersion $latestVersion $CurrentVersion) -le 0) { return $null }
    return $latest
}

function Get-CpgDeclaredSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ChecksumText)

    $match = [regex]::Match($ChecksumText.Trim(), '(?i)^([a-f0-9]{64})(?:\s|$)')
    if (-not $match.Success) { return $null }
    return $match.Groups[1].Value.ToLowerInvariant()
}

function Get-CpgExternalLaunchDecision {
    [CmdletBinding()]
    param(
        [ValidateSet('Safe', 'Enforce')][string]$Mode = 'Safe',
        [bool]$SafeRepairEnabled = $true,
        [bool]$ProxyValid = $false,
        [bool]$ArgumentMatches = $false,
        [bool]$TrafficObserved = $false,
        [bool]$StabilityReady = $true,
        [bool]$UpstreamSuspected = $false,
        [bool]$CompatibilityBlocked = $false,
        [double]$PendingSeconds = 0,
        [int]$SafeGraceSeconds = 20,
        [int]$EnforceDebounceSeconds = 15
    )

    if (-not $ProxyValid) {
        return [pscustomobject]@{ Action = 'None'; Reason = 'proxy_not_valid' }
    }
    if ($ArgumentMatches) {
        return [pscustomobject]@{ Action = 'None'; Reason = 'proxy_argument_matches' }
    }
    if ($UpstreamSuspected) {
        return [pscustomobject]@{ Action = 'Hold'; Reason = 'proxy_upstream_suspected' }
    }
    if ($CompatibilityBlocked) {
        return [pscustomobject]@{ Action = 'Hold'; Reason = 'codex_compatibility_review_required' }
    }
    if (-not $StabilityReady) {
        return [pscustomobject]@{ Action = 'Wait'; Reason = 'post_update_stability_observation' }
    }

    if ($Mode -eq 'Enforce') {
        if ($PendingSeconds -lt [Math]::Max(0, $EnforceDebounceSeconds)) {
            return [pscustomobject]@{ Action = 'Wait'; Reason = 'enforce_debounce' }
        }
        return [pscustomobject]@{ Action = 'Repair'; Reason = 'enforce_missing_proxy_argument' }
    }

    if (-not $SafeRepairEnabled) {
        return [pscustomobject]@{ Action = 'ManagedShortcut'; Reason = 'safe_repair_disabled' }
    }
    if ($TrafficObserved) {
        return [pscustomobject]@{ Action = 'Keep'; Reason = 'safe_proxy_traffic_observed' }
    }
    if ($PendingSeconds -lt [Math]::Max(0, $SafeGraceSeconds)) {
        return [pscustomobject]@{ Action = 'Wait'; Reason = 'safe_evidence_grace' }
    }
    return [pscustomobject]@{ Action = 'Repair'; Reason = 'safe_missing_argument_without_proxy_traffic' }
}

function Get-CpgProxyStabilityDecision {
    [CmdletBinding()]
    param(
        [bool]$ObservationActive = $false,
        [bool]$ValidationFresh = $false,
        [bool]$EndpointReachable = $false,
        [bool]$ValidationPassed = $false,
        [bool]$CriticalTargetsPassed = $false,
        [int]$SuccessfulSamples = 0,
        [int]$RequiredSamples = 3,
        [double]$ElapsedSeconds = 0,
        [int]$MinimumObservationSeconds = 60,
        [bool]$UpstreamSuspected = $false
    )

    $required = [Math]::Max(1, $RequiredSamples)
    $minimumSeconds = [Math]::Max(0, $MinimumObservationSeconds)
    $nextSamples = [Math]::Max(0, $SuccessfulSamples)
    $suspected = $UpstreamSuspected

    if ($ValidationFresh) {
        if ($EndpointReachable -and (-not $ValidationPassed -or -not $CriticalTargetsPassed)) {
            $suspected = $true
            $nextSamples = 0
        }
        elseif ($ValidationPassed -and $CriticalTargetsPassed) {
            $suspected = $false
            if ($ObservationActive) { $nextSamples++ }
        }
        elseif ($ObservationActive) {
            $nextSamples = 0
        }
    }

    $observationComplete = $ObservationActive -and -not $suspected -and
        $nextSamples -ge $required -and $ElapsedSeconds -ge $minimumSeconds
    $stabilityReady = -not $suspected -and (-not $ObservationActive -or $observationComplete)
    $state = if ($suspected) {
        'UpstreamSuspected'
    }
    elseif ($ObservationActive -and -not $observationComplete) {
        'ObservingAfterCodexUpdate'
    }
    elseif ($observationComplete) {
        'StableAfterCodexUpdate'
    }
    else {
        'IndirectEvidenceOnly'
    }

    return [pscustomobject]@{
        State = $state
        StabilityReady = $stabilityReady
        ObservationComplete = $observationComplete
        SuccessfulSamples = $nextSamples
        UpstreamSuspected = $suspected
    }
}

function Get-CpgCodexCompatibilityDecision {
    [CmdletBinding()]
    param(
        [bool]$ObservationActive = $false,
        [bool]$ObservationPassed = $false,
        [bool]$LaunchConfigured = $false,
        [bool]$TrafficObserved = $false,
        [bool]$RecoveryPending = $false,
        [bool]$CodexRunning = $false,
        [double]$SecondsSinceManagedLaunch = 0,
        [int]$ConfirmationSeconds = 45,
        [bool]$CompatibilityBlocked = $false
    )

    if ($ObservationActive) {
        return [pscustomobject]@{ State = 'Auditing'; Evidence = 'PostUpdateObservation'; ReviewRequired = $false }
    }
    if ($LaunchConfigured) {
        return [pscustomobject]@{ State = 'Compatible'; Evidence = 'LaunchArgumentMatched'; ReviewRequired = $false }
    }
    if ($TrafficObserved) {
        return [pscustomobject]@{ State = 'Compatible'; Evidence = 'ProxyTrafficObserved'; ReviewRequired = $false }
    }
    if ($CompatibilityBlocked) {
        return [pscustomobject]@{ State = 'ReviewRequired'; Evidence = 'PreviousManagedVerificationFailed'; ReviewRequired = $true }
    }

    $timeout = [Math]::Max(15, $ConfirmationSeconds)
    if ($ObservationPassed -and $RecoveryPending -and $CodexRunning -and $SecondsSinceManagedLaunch -ge $timeout) {
        return [pscustomobject]@{ State = 'ReviewRequired'; Evidence = 'ManagedLaunchNotConfirmed'; ReviewRequired = $true }
    }
    if ($ObservationPassed) {
        return [pscustomobject]@{ State = 'AwaitingEvidence'; Evidence = 'PackageResolvedAndTargetsPassed'; ReviewRequired = $false }
    }
    return [pscustomobject]@{ State = 'Baseline'; Evidence = 'PackageManifestResolved'; ReviewRequired = $false }
}

function Test-CpgGuardianProcessIdentity {
    [CmdletBinding()]
    param(
        $Process,
        [Parameter(Mandatory = $true)][string]$WatcherPath
    )

    if ($null -eq $Process -or [string]::IsNullOrWhiteSpace($WatcherPath)) { return $false }
    $commandLine = [string](Get-CpgConfigValue -Config $Process -Name 'CommandLine' -Default '')
    if ([string]::IsNullOrWhiteSpace($commandLine)) { return $false }
    $watcherToken = '(?i)(?:^|\s|")' + [regex]::Escape($WatcherPath) + '(?:"|\s|$)'
    return $commandLine -match $watcherToken
}

function Test-CpgLoopbackHost {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$HostName)

    if ($HostName -in @('localhost', '127.0.0.1', '::1')) {
        return $true
    }

    $address = $null
    if ([System.Net.IPAddress]::TryParse($HostName, [ref]$address)) {
        return [System.Net.IPAddress]::IsLoopback($address)
    }
    return $false
}

function ConvertTo-CpgProxyUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Address,
        [switch]$AllowNonLoopback
    )

    if ([string]::IsNullOrWhiteSpace($Address)) {
        return $null
    }

    $value = $Address.Trim().Trim('"').Trim("'")
    if ($value -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
        $value = "http://$value"
    }

    $authorityText = (($value -replace '^[a-zA-Z][a-zA-Z0-9+.-]*://', '') -split '[/?#]', 2)[0]
    if ($authorityText -notmatch ':\d+$') {
        return $null
    }

    $uri = $null
    if (-not [Uri]::TryCreate($value, [UriKind]::Absolute, [ref]$uri)) {
        return $null
    }
    $scheme = $uri.Scheme.ToLowerInvariant()
    if ($scheme -in @('socks', 'socks5')) { $scheme = 'socks5h' }
    if ($scheme -notin @('http', 'https', 'socks5h')) {
        return $null
    }
    if ([string]::IsNullOrWhiteSpace($uri.Host) -or $uri.Port -le 0 -or $uri.Port -gt 65535) {
        return $null
    }
    if (($uri.AbsolutePath -ne '/' -and -not [string]::IsNullOrEmpty($uri.AbsolutePath)) -or
        -not [string]::IsNullOrEmpty($uri.Query) -or
        -not [string]::IsNullOrEmpty($uri.Fragment)) {
        return $null
    }
    if (-not [string]::IsNullOrEmpty($uri.UserInfo)) {
        return $null
    }
    if (-not $AllowNonLoopback -and -not (Test-CpgLoopbackHost -HostName $uri.Host)) {
        return $null
    }

    $normalizedHost = $uri.Host.Trim('[', ']')
    if ($normalizedHost.Contains(':')) {
        $ipAddress = $null
        if ([System.Net.IPAddress]::TryParse($normalizedHost, [ref]$ipAddress)) {
            $normalizedHost = $ipAddress.ToString()
        }
        $normalizedHost = "[$normalizedHost]"
    }
    return ("{0}://{1}:{2}" -f $scheme, $normalizedHost.ToLowerInvariant(), $uri.Port)
}

function ConvertTo-CpgHttpProxyUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Address,
        [switch]$AllowNonLoopback
    )

    return ConvertTo-CpgProxyUri -Address $Address -AllowNonLoopback:$AllowNonLoopback
}

function ConvertTo-CpgChromiumProxyUri {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ProxyUri)

    if ($ProxyUri.StartsWith('socks5h://', [System.StringComparison]::OrdinalIgnoreCase)) {
        return 'socks5://' + $ProxyUri.Substring('socks5h://'.Length)
    }
    return $ProxyUri
}

function ConvertFrom-CpgProxyServer {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$ProxyServer,
        [switch]$AllowNonLoopback
    )

    if ([string]::IsNullOrWhiteSpace($ProxyServer)) {
        return @()
    }

    $items = @()
    $raw = $ProxyServer.Trim()
    if ($raw.Contains('=')) {
        $map = @{}
        foreach ($part in ($raw -split ';')) {
            $pair = $part -split '=', 2
            if ($pair.Count -eq 2) {
                $map[$pair[0].Trim().ToLowerInvariant()] = $pair[1].Trim()
            }
        }
        foreach ($scheme in @('https', 'http', 'socks')) {
            if ($map.ContainsKey($scheme)) {
                $address = $map[$scheme]
                if ($scheme -eq 'socks' -and $address -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
                    $address = 'socks5h://' + $address
                }
                $items += [pscustomobject]@{ Address = $address; Label = $scheme }
            }
        }
    }
    else {
        $items += [pscustomobject]@{ Address = $raw; Label = 'all' }
    }

    $result = @()
    $seen = @{}
    foreach ($item in $items) {
        $uri = ConvertTo-CpgProxyUri -Address ([string]$item.Address) -AllowNonLoopback:$AllowNonLoopback
        if ($null -ne $uri -and -not $seen.ContainsKey($uri)) {
            $seen[$uri] = $true
            $result += [pscustomobject]@{ Uri = $uri; Label = $item.Label }
        }
    }
    return $result
}

function ConvertFrom-CpgPacResult {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$Result,
        [switch]$AllowNonLoopback
    )

    if ([string]::IsNullOrWhiteSpace($Result)) { return @() }
    if ($Result.Contains('=')) {
        return @(ConvertFrom-CpgProxyServer -ProxyServer $Result -AllowNonLoopback:$AllowNonLoopback)
    }

    $items = @()
    $seen = @{}
    foreach ($part in ($Result -split ';')) {
        $token = $part.Trim()
        if ([string]::IsNullOrWhiteSpace($token) -or $token -match '^(?i)DIRECT$') { continue }
        $address = $token
        $label = 'proxy'
        if ($token -match '^(?i)(PROXY|HTTP|HTTPS|SOCKS|SOCKS5)\s+(.+)$') {
            $kind = $matches[1].ToUpperInvariant()
            $address = $matches[2].Trim()
            $label = $kind.ToLowerInvariant()
            $scheme = switch ($kind) {
                'HTTPS' { 'https' }
                { $_ -in @('SOCKS', 'SOCKS5') } { 'socks5h' }
                default { 'http' }
            }
            $address = "$scheme`://$address"
        }
        $uri = ConvertTo-CpgProxyUri -Address $address -AllowNonLoopback:$AllowNonLoopback
        if ($null -ne $uri -and -not $seen.ContainsKey($uri)) {
            $seen[$uri] = $true
            $items += [pscustomobject]@{ Uri = $uri; Label = $label }
        }
    }
    return $items
}

function Protect-CpgProxyUri {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$ProxyUri)

    if ([string]::IsNullOrWhiteSpace($ProxyUri)) {
        return $ProxyUri
    }

    $value = $ProxyUri.Trim()
    if ($value -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
        $value = "http://$value"
    }
    $uri = $null
    if (-not [Uri]::TryCreate($value, [UriKind]::Absolute, [ref]$uri)) {
        return '<invalid-proxy-uri>'
    }
    if ([string]::IsNullOrWhiteSpace($uri.Host)) {
        return '<invalid-proxy-uri>'
    }
    return $uri.GetLeftPart([UriPartial]::Authority).Replace($uri.UserInfo + '@', '')
}

function Get-CpgProxyEndpointKey {
    param([AllowNull()][AllowEmptyString()][string]$ProxyUri)

    if ([string]::IsNullOrWhiteSpace($ProxyUri)) { return '' }
    $uri = $null
    if (-not [Uri]::TryCreate($ProxyUri, [UriKind]::Absolute, [ref]$uri) -or
        [string]::IsNullOrWhiteSpace($uri.Host) -or $uri.Port -le 0) {
        return ''
    }

    $hostName = $uri.Host.Trim('[', ']').ToLowerInvariant()
    return "{0}|{1}" -f $hostName, $uri.Port
}

function Test-CpgSameProxyEndpoint {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$FirstProxyUri,
        [AllowNull()][AllowEmptyString()][string]$SecondProxyUri
    )

    $firstKey = Get-CpgProxyEndpointKey -ProxyUri $FirstProxyUri
    $secondKey = Get-CpgProxyEndpointKey -ProxyUri $SecondProxyUri
    return -not [string]::IsNullOrWhiteSpace($firstKey) -and $firstKey -eq $secondKey
}

function Resolve-CpgProxyLifecycleUri {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$PreferredProxyUri,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$ValidatedProxyUri,
        [switch]$ExplicitSelection
    )

    if ($ExplicitSelection) { return $ValidatedProxyUri }
    if (Test-CpgSameProxyEndpoint -FirstProxyUri $PreferredProxyUri -SecondProxyUri $ValidatedProxyUri) {
        return $PreferredProxyUri
    }
    return $ValidatedProxyUri
}

function Get-CpgProxyChangeDecision {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$CurrentProxyUri,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$ValidatedProxyUri
    )

    if ([string]::IsNullOrWhiteSpace($CurrentProxyUri)) {
        return [pscustomobject]@{ Kind = 'InitialAdoption'; RestartRequired = $false; SameEndpoint = $false }
    }
    if ([string]::Equals($CurrentProxyUri, $ValidatedProxyUri, [System.StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ Kind = 'Unchanged'; RestartRequired = $false; SameEndpoint = $true }
    }
    if (Test-CpgSameProxyEndpoint -FirstProxyUri $CurrentProxyUri -SecondProxyUri $ValidatedProxyUri) {
        return [pscustomobject]@{ Kind = 'ProtocolUpdate'; RestartRequired = $false; SameEndpoint = $true }
    }
    return [pscustomobject]@{ Kind = 'EndpointChange'; RestartRequired = $true; SameEndpoint = $false }
}

function Get-CpgRestartPromptDecision {
    [CmdletBinding()]
    param([int]$PopupResult)

    switch ($PopupResult) {
        6 { return [pscustomobject]@{ Approved = $true; Reason = 'approved' } }
        7 { return [pscustomobject]@{ Approved = $false; Reason = 'declined' } }
        -1 { return [pscustomobject]@{ Approved = $false; Reason = 'timeout' } }
        default { return [pscustomobject]@{ Approved = $false; Reason = 'prompt_unavailable' } }
    }
}

function Select-CpgProxyCandidates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()]$Candidates,
        [AllowEmptyString()][string]$PreferredUri = ''
    )

    $ordered = @($Candidates | Sort-Object -Property `
        @{ Expression = { [int]$_.Score }; Descending = $true }, `
        @{ Expression = { if ([string]$_.Uri -eq $PreferredUri) { 1 } else { 0 } }; Descending = $true }, `
        @{ Expression = { [string]$_.Source }; Ascending = $true }, `
        @{ Expression = { [string]$_.Uri }; Ascending = $true })

    return $ordered
}

function Get-CpgRestartDecision {
    [CmdletBinding()]
    param(
        [datetime[]]$RestartHistory = @(),
        [datetime]$Now = (Get-Date),
        [ValidateRange(1, 100)][int]$LimitCount = 3,
        [ValidateRange(1, 1440)][int]$WindowMinutes = 10,
        [ValidateRange(1, 1440)][int]$CircuitBreakerMinutes = 15,
        [datetime]$CircuitBreakerUntil = [datetime]::MinValue
    )

    $cutoff = $Now.AddMinutes(-$WindowMinutes)
    $recent = @($RestartHistory | Where-Object { $_ -ge $cutoff -and $_ -le $Now })
    if ($CircuitBreakerUntil -gt $Now) {
        return [pscustomobject]@{
            Allowed = $false
            Reason = 'circuit_open'
            RecentRestarts = $recent
            CircuitBreakerUntil = $CircuitBreakerUntil
        }
    }
    if ($recent.Count -ge $LimitCount) {
        return [pscustomobject]@{
            Allowed = $false
            Reason = 'restart_limit_reached'
            RecentRestarts = $recent
            CircuitBreakerUntil = $Now.AddMinutes($CircuitBreakerMinutes)
        }
    }
    return [pscustomobject]@{
        Allowed = $true
        Reason = 'allowed'
        RecentRestarts = $recent
        CircuitBreakerUntil = [datetime]::MinValue
    }
}

function Test-CpgProxyResponseStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][int]$StatusCode)

    return ($StatusCode -ge 200 -and $StatusCode -lt 500 -and $StatusCode -ne 407)
}

function Get-CpgProxyValidationDecision {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]$Results = @(),
        [ValidateRange(1, 100)][int]$MinimumSuccessCount = 1,
        [AllowEmptyCollection()][string[]]$RequiredHosts = @()
    )

    $items = @($Results | Where-Object { $null -ne $_ })
    $successCount = @($items | Where-Object { [bool](Get-CpgConfigValue $_ 'Passed' $false) }).Count
    $requiredCount = [Math]::Max(1, $MinimumSuccessCount)
    $normalizedRequiredHosts = @($RequiredHosts | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    $criticalFailures = @()
    $criticalMissing = @()
    foreach ($requiredHost in $normalizedRequiredHosts) {
        $hostResults = @($items | Where-Object { [string]::Equals(([string](Get-CpgConfigValue $_ 'Host' '')).Trim(), $requiredHost, [System.StringComparison]::OrdinalIgnoreCase) })
        if ($hostResults.Count -eq 0) {
            $criticalMissing += $requiredHost
            continue
        }
        if (@($hostResults | Where-Object { [bool](Get-CpgConfigValue $_ 'Passed' $false) }).Count -eq 0) {
            $criticalFailures += $requiredHost
        }
    }

    $criticalTargetsPassed = $criticalFailures.Count -eq 0 -and $criticalMissing.Count -eq 0
    return [pscustomobject]@{
        Passed = ($successCount -ge $requiredCount -and $criticalTargetsPassed)
        SuccessCount = $successCount
        RequiredCount = $requiredCount
        CriticalTargetsPassed = $criticalTargetsPassed
        CriticalFailures = @($criticalFailures)
        CriticalMissing = @($criticalMissing)
    }
}

function Test-CpgRootUsesProxy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$RootProcess,
        [Parameter(Mandatory = $true)][string]$ProxyUri,
        [bool]$UseChromiumProxyArgument = $true
    )

    if (-not $UseChromiumProxyArgument) {
        return $true
    }
    if ([string]::IsNullOrWhiteSpace($ProxyUri)) {
        return $false
    }

    $commandLine = [string]$RootProcess.CommandLine
    $argumentMatch = [regex]::Match($commandLine, '(?i)(?:^|\s)--proxy-server=(?:"(?<quoted>[^"]+)"|(?<plain>\S+))')
    if (-not $argumentMatch.Success) { return $false }
    $actualText = if ($argumentMatch.Groups['quoted'].Success) { $argumentMatch.Groups['quoted'].Value } else { $argumentMatch.Groups['plain'].Value }
    $actualProxy = ConvertTo-CpgProxyUri -Address $actualText -AllowNonLoopback
    $expectedProxy = ConvertTo-CpgProxyUri -Address $ProxyUri -AllowNonLoopback
    if ([string]::IsNullOrWhiteSpace($actualProxy) -or [string]::IsNullOrWhiteSpace($expectedProxy)) { return $false }
    return Test-CpgSameProxyEndpoint -FirstProxyUri $actualProxy -SecondProxyUri $expectedProxy
}

function Get-CpgCodexApplicationCandidates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Applications,
        [string]$PreferredApplicationId = '',
        [string[]]$PreferredExecutableNames = @('ChatGPT.exe', 'Codex.exe')
    )

    $ranked = @()
    foreach ($application in @($Applications)) {
        if ($null -eq $application) { continue }
        $id = [string](Get-CpgConfigValue -Config $application -Name 'Id' -Default '')
        $executable = [string](Get-CpgConfigValue -Config $application -Name 'Executable' -Default '')
        $entryPoint = [string](Get-CpgConfigValue -Config $application -Name 'EntryPoint' -Default '')
        if ([string]::IsNullOrWhiteSpace($executable)) { continue }

        $fileName = [System.IO.Path]::GetFileName($executable.Replace('/', '\'))
        $score = 100
        $reason = 'manifest_executable'
        if (-not [string]::IsNullOrWhiteSpace($PreferredApplicationId) -and [string]::Equals($id, $PreferredApplicationId, [System.StringComparison]::OrdinalIgnoreCase)) {
            $score = 10000
            $reason = 'configured_application_id'
        }
        else {
            for ($index = 0; $index -lt @($PreferredExecutableNames).Count; $index++) {
                if ([string]::Equals($fileName, [string]$PreferredExecutableNames[$index], [System.StringComparison]::OrdinalIgnoreCase)) {
                    $score = 5000 - $index
                    $reason = 'preferred_executable_name'
                    break
                }
            }
            if ($score -eq 100 -and ($id -match '(?i)(codex|chatgpt)' -or $fileName -match '(?i)(codex|chatgpt)')) {
                $score = 4000
                $reason = 'codex_identity_match'
            }
            elseif ($score -eq 100 -and $entryPoint -match '(?i)FullTrustApplication') {
                $score = 1000
                $reason = 'full_trust_application'
            }
        }

        $ranked += [pscustomobject]@{
            Application = $application
            ApplicationId = $id
            Executable = $executable
            Score = $score
            ResolutionMethod = $reason
        }
    }

    return @($ranked | Sort-Object @{ Expression = 'Score'; Descending = $true }, ApplicationId, Executable)
}

function Get-CpgCodexApp {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Config)

    $packageNames = @(Get-CpgConfigValue -Config $Config -Name 'CodexPackageNames' -Default @('OpenAI.Codex'))
    $preferredAppId = [string](Get-CpgConfigValue -Config $Config -Name 'CodexApplicationId' -Default '')
    $preferredExecutableNames = @(Get-CpgConfigValue -Config $Config -Name 'PreferredCodexExecutables' -Default @('ChatGPT.exe', 'Codex.exe'))
    foreach ($packageName in $packageNames) {
        $package = Get-AppxPackage -Name ([string]$packageName) -ErrorAction SilentlyContinue |
            Sort-Object Version -Descending |
            Select-Object -First 1
        if ($null -eq $package) {
            continue
        }

        try {
            $manifest = Get-AppxPackageManifest -Package $package -ErrorAction Stop
            $applications = @($manifest.Package.Applications.Application)
            foreach ($candidate in @(Get-CpgCodexApplicationCandidates -Applications $applications -PreferredApplicationId $preferredAppId -PreferredExecutableNames $preferredExecutableNames)) {
                $application = $candidate.Application
                $relativeExecutable = ([string]$candidate.Executable).Replace('/', '\')
                $executablePath = Join-Path ([string]$package.InstallLocation) $relativeExecutable
                if (-not (Test-Path -LiteralPath $executablePath)) { continue }

                return [pscustomobject]@{
                    PackageName       = [string]$package.Name
                    PackageFamilyName = [string]$package.PackageFamilyName
                    PackageArchitecture = [string]$package.Architecture
                    Version           = [string]$package.Version
                    ApplicationId     = [string]$candidate.ApplicationId
                    InstallLocation   = [string]$package.InstallLocation
                    ExecutablePath    = $executablePath
                    ProcessName       = [System.IO.Path]::GetFileName($executablePath)
                    ResolutionMethod  = [string]$candidate.ResolutionMethod
                }
            }
        }
        catch {
            continue
        }
    }
    return $null
}

function Test-CpgCodexRootProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Process,
        [Parameter(Mandatory = $true)]$CodexApp
    )

    $path = [string]$Process.ExecutablePath
    $commandLine = [string]$Process.CommandLine
    if ([string]::IsNullOrWhiteSpace($path) -or [string]::IsNullOrWhiteSpace([string]$CodexApp.ExecutablePath)) {
        return $false
    }
    $pathMatches = [string]::Equals(
        [System.IO.Path]::GetFullPath($path),
        [System.IO.Path]::GetFullPath([string]$CodexApp.ExecutablePath),
        [System.StringComparison]::OrdinalIgnoreCase
    )
    return ($pathMatches -and $commandLine -notmatch '(?:^|\s)--type=')
}

function Test-CpgInstallMarker {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)]$Marker
    )

    if ([string]$Marker.productId -ne 'CodexProxyGuardian') {
        return $false
    }
    $expected = [System.IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
    $actual = [System.IO.Path]::GetFullPath([string]$Marker.installRoot).TrimEnd('\')
    return [string]::Equals($expected, $actual, [System.StringComparison]::OrdinalIgnoreCase)
}

Export-ModuleMember -Function @(
    'Get-CpgConfigValue',
    'Update-CpgConfigDefaults',
    'Set-CpgModeProfile',
    'Get-CpgModeProfile',
    'Compare-CpgSemanticVersion',
    'Select-CpgLatestRelease',
    'Select-CpgUpdateRelease',
    'Get-CpgDeclaredSha256',
    'Get-CpgExternalLaunchDecision',
    'Get-CpgProxyStabilityDecision',
    'Get-CpgCodexCompatibilityDecision',
    'Test-CpgGuardianProcessIdentity',
    'Test-CpgLoopbackHost',
    'ConvertTo-CpgProxyUri',
    'ConvertTo-CpgHttpProxyUri',
    'ConvertTo-CpgChromiumProxyUri',
    'ConvertFrom-CpgProxyServer',
    'ConvertFrom-CpgPacResult',
    'Protect-CpgProxyUri',
    'Test-CpgSameProxyEndpoint',
    'Resolve-CpgProxyLifecycleUri',
    'Get-CpgProxyChangeDecision',
    'Get-CpgRestartPromptDecision',
    'Select-CpgProxyCandidates',
    'Get-CpgRestartDecision',
    'Test-CpgProxyResponseStatus',
    'Get-CpgProxyValidationDecision',
    'Test-CpgRootUsesProxy',
    'Get-CpgCodexApplicationCandidates',
    'Get-CpgCodexApp',
    'Test-CpgCodexRootProcess',
    'Test-CpgInstallMarker'
)
