[CmdletBinding()]
param([string]$InstallRoot = (Split-Path -Parent $MyInvocation.MyCommand.Path))

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $InstallRoot)) {
    throw "Codex Proxy Guardian is not installed at: $InstallRoot"
}

$statusPath = Join-Path $InstallRoot 'status.json'
$launchRequestPath = Join-Path $InstallRoot 'launch.request'
$status = $null
if (Test-Path -LiteralPath $statusPath) {
    try { $status = Get-Content -Raw -LiteralPath $statusPath | ConvertFrom-Json } catch { $status = $null }
}

if ($null -eq $status -or -not [bool]$status.running) {
    $wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
    Start-Process -FilePath $wscript -ArgumentList ('"{0}"' -f (Join-Path $InstallRoot 'Run-Guardian.vbs')) -WindowStyle Hidden
}

New-Item -ItemType File -Path $launchRequestPath -Force | Out-Null
