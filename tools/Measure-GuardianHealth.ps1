[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'CodexProxyGuardian'),
    [ValidateRange(1, 1440)][int]$DurationMinutes = 60,
    [ValidateRange(2, 60)][int]$SampleIntervalSeconds = 5,
    [switch]$Json,
    [string]$ExportPath = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$resolvedRoot = [System.IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
$markerPath = Join-Path $resolvedRoot '.cpg-install.json'
if (-not (Test-Path -LiteralPath $markerPath)) { throw "No marked installation was found at: $resolvedRoot" }
$marker = Get-Content -Raw -LiteralPath $markerPath | ConvertFrom-Json
if ([string]$marker.productId -ne 'CodexProxyGuardian') { throw 'The installation marker belongs to another product.' }

function Get-Value {
    param($Object, [string]$Name, $Default)
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

function Get-EndpointFingerprint {
    param([string]$Endpoint)
    if ([string]::IsNullOrWhiteSpace($Endpoint)) { return '' }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Endpoint)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').Substring(0, 12).ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

$started = Get-Date
$deadline = $started.AddMinutes($DurationMinutes)
$sampleCount = 0
$missingStatusSamples = 0
$invalidProxySamples = 0
$circuitOpenSamples = 0
$trafficEvidenceSamples = 0
$launchEvidenceSamples = 0
$endpointFingerprints = @()
$lastCodexPids = ''
$codexPidChanges = 0

while ((Get-Date) -lt $deadline) {
    $statusPath = Join-Path $resolvedRoot 'status.json'
    $status = $null
    if (Test-Path -LiteralPath $statusPath) {
        try { $status = Get-Content -Raw -LiteralPath $statusPath | ConvertFrom-Json } catch { $status = $null }
    }
    $sampleCount++
    if ($null -eq $status) { $missingStatusSamples++ }
    else {
        if (-not [bool](Get-Value $status 'activeProxyValid' $false)) { $invalidProxySamples++ }
        if ([bool](Get-Value $status 'restartCircuitOpen' $false)) { $circuitOpenSamples++ }
        $evidence = [string](Get-Value $status 'effectivenessEvidence' '')
        if ($evidence -eq 'TrafficObserved') { $trafficEvidenceSamples++ }
        if ($evidence -in @('LaunchConfigured', 'TrafficObserved')) { $launchEvidenceSamples++ }
        $fingerprint = Get-EndpointFingerprint ([string](Get-Value $status 'activeProxy' ''))
        if (-not [string]::IsNullOrWhiteSpace($fingerprint)) { $endpointFingerprints += $fingerprint }
        $codexPids = @((Get-Value $status 'codexRootPids' @()) | ForEach-Object { [int]$_ } | Sort-Object) -join ','
        if (-not [string]::IsNullOrWhiteSpace($lastCodexPids) -and -not [string]::IsNullOrWhiteSpace($codexPids) -and $codexPids -ne $lastCodexPids) { $codexPidChanges++ }
        if (-not [string]::IsNullOrWhiteSpace($codexPids)) { $lastCodexPids = $codexPids }
    }
    $remaining = ($deadline - (Get-Date)).TotalSeconds
    if ($remaining -gt 0) { Start-Sleep -Seconds ([Math]::Min($SampleIntervalSeconds, [Math]::Ceiling($remaining))) }
}

$uniqueEndpoints = @($endpointFingerprints | Sort-Object -Unique)
$report = [ordered]@{
    reportSchema = 1
    safeForSharing = $true
    version = [string]$marker.version
    startedUtc = $started.ToUniversalTime().ToString('o')
    completedUtc = (Get-Date).ToUniversalTime().ToString('o')
    durationMinutes = $DurationMinutes
    sampleCount = $sampleCount
    missingStatusSamples = $missingStatusSamples
    invalidProxySamples = $invalidProxySamples
    launchEvidenceSamples = $launchEvidenceSamples
    trafficEvidenceSamples = $trafficEvidenceSamples
    circuitOpenSamples = $circuitOpenSamples
    uniqueEndpointCount = $uniqueEndpoints.Count
    endpointFingerprints = $uniqueEndpoints
    codexPidChanges = $codexPidChanges
    healthy = ($missingStatusSamples -eq 0 -and $invalidProxySamples -eq 0 -and $circuitOpenSamples -eq 0 -and $uniqueEndpoints.Count -le 1)
}
$reportJson = [pscustomobject]$report | ConvertTo-Json -Depth 5
if (-not [string]::IsNullOrWhiteSpace($ExportPath)) { $reportJson | Set-Content -LiteralPath ([System.IO.Path]::GetFullPath($ExportPath)) -Encoding UTF8 }
if ($Json) { $reportJson; return }
[pscustomobject]$report | Format-List
