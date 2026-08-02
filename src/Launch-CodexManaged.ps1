[CmdletBinding()]
param([string]$InstallRoot = (Split-Path -Parent $MyInvocation.MyCommand.Path))

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $InstallRoot)) {
    throw "Codex Proxy Guardian is not installed at: $InstallRoot"
}
$resolvedRoot = [System.IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
$markerPath = Join-Path $resolvedRoot '.cpg-install.json'
$corePath = Join-Path $resolvedRoot 'CodexProxyGuardian.Core.psm1'
if (-not (Test-Path -LiteralPath $markerPath) -or -not (Test-Path -LiteralPath $corePath)) {
    throw "The Codex Proxy Guardian installation marker or core module is missing: $resolvedRoot"
}
Import-Module $corePath -Force
$marker = Get-Content -Raw -LiteralPath $markerPath | ConvertFrom-Json
if (-not (Test-CpgInstallMarker -InstallRoot $resolvedRoot -Marker $marker)) {
    throw 'The installation marker does not match the managed launch path.'
}
$InstallRoot = $resolvedRoot

$statusPath = Join-Path $InstallRoot 'status.json'
$launchRequestPath = Join-Path $InstallRoot 'launch.request'
$status = $null
if (Test-Path -LiteralPath $statusPath) {
    try { $status = Get-Content -Raw -LiteralPath $statusPath | ConvertFrom-Json } catch { $status = $null }
}

$guardianAlive = $false
if ($null -ne $status -and [bool]$status.running -and [int]$status.guardianPid -gt 0) {
    $guardianProcess = Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f [int]$status.guardianPid) -ErrorAction SilentlyContinue
    $expectedWatcher = Join-Path $InstallRoot 'Watch-CodexProxy.ps1'
    $guardianAlive = $null -ne $guardianProcess -and ([string]$guardianProcess.CommandLine).IndexOf($expectedWatcher, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
}

if (-not $guardianAlive) {
    $wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
    Start-Process -FilePath $wscript -ArgumentList ('"{0}"' -f (Join-Path $InstallRoot 'Run-Guardian.vbs')) -WindowStyle Hidden
}

New-Item -ItemType File -Path $launchRequestPath -Force | Out-Null
