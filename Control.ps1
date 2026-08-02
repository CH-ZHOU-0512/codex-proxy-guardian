[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Start', 'Stop', 'Restart', 'Status', 'Doctor')][string]$Action = 'Status',
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'CodexProxyGuardian'),
    [switch]$Json,
    [switch]$Online
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$resolvedRoot = [System.IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
$markerPath = Join-Path $resolvedRoot '.cpg-install.json'
if (-not (Test-Path -LiteralPath $markerPath)) { throw "No marked Codex Proxy Guardian installation was found at: $resolvedRoot" }
$marker = Get-Content -Raw -LiteralPath $markerPath | ConvertFrom-Json
if ([string]$marker.productId -ne 'CodexProxyGuardian' -or -not [string]::Equals([System.IO.Path]::GetFullPath([string]$marker.installRoot).TrimEnd('\'), $resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'The installation marker does not match the requested path.'
}

function Get-OwnedScheduledTask {
    $task = Get-ScheduledTask -TaskName ([string]$marker.taskName) -ErrorAction Stop
    $expectedWatcher = Join-Path $resolvedRoot 'Watch-CodexProxy.ps1'
    if (@($task.Actions | Where-Object { ([string]$_.Arguments).IndexOf($expectedWatcher, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 }).Count -eq 0) {
        throw 'The scheduled task action no longer belongs to this installation.'
    }
    return $task
}

function Stop-Guardian {
    if (-not $PSCmdlet.ShouldProcess($resolvedRoot, 'Stop the guardian process')) { return }
    $statusPath = Join-Path $resolvedRoot 'status.json'
    $guardianPid = 0
    if (Test-Path -LiteralPath $statusPath) {
        try { $guardianPid = [int](Get-Content -Raw -LiteralPath $statusPath | ConvertFrom-Json).guardianPid } catch { $guardianPid = 0 }
    }
    New-Item -ItemType File -Path (Join-Path $resolvedRoot 'stop.request') -Force | Out-Null
    if ([string]$marker.startupMode -eq 'ScheduledTask') {
        [void](Get-OwnedScheduledTask)
        Stop-ScheduledTask -TaskName ([string]$marker.taskName) -ErrorAction SilentlyContinue
    }
    $deadline = (Get-Date).AddSeconds(20)
    while ($guardianPid -gt 0 -and $null -ne (Get-Process -Id $guardianPid -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 250 }
    if ($guardianPid -gt 0 -and $null -ne (Get-Process -Id $guardianPid -ErrorAction SilentlyContinue)) {
        $guardianProcess = Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f $guardianPid) -ErrorAction SilentlyContinue
        $expectedWatcher = Join-Path $resolvedRoot 'Watch-CodexProxy.ps1'
        if ($null -eq $guardianProcess -or ([string]$guardianProcess.CommandLine).IndexOf($expectedWatcher, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
            throw 'The guardian did not stop and the remaining process identity could not be verified.'
        }
        Stop-Process -Id $guardianPid -Force
    }
    Remove-Item -LiteralPath $statusPath -Force -ErrorAction SilentlyContinue
}

function Start-Guardian {
    if (-not $PSCmdlet.ShouldProcess($resolvedRoot, 'Start the guardian process')) { return }
    Remove-Item -LiteralPath (Join-Path $resolvedRoot 'stop.request') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $resolvedRoot 'status.json') -Force -ErrorAction SilentlyContinue
    if ([string]$marker.startupMode -eq 'ScheduledTask') {
        [void](Get-OwnedScheduledTask)
        Start-ScheduledTask -TaskName ([string]$marker.taskName)
    }
    else {
        $wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
        Start-Process -FilePath $wscript -ArgumentList ('"{0}"' -f (Join-Path $resolvedRoot 'Run-Guardian.vbs')) -WindowStyle Hidden
    }
    $statusPath = Join-Path $resolvedRoot 'status.json'
    $deadline = (Get-Date).AddSeconds(40)
    $status = $null
    do {
        if (Test-Path -LiteralPath $statusPath) {
            try { $status = Get-Content -Raw -LiteralPath $statusPath | ConvertFrom-Json } catch { $status = $null }
            if ($null -ne $status -and [string]$status.guardianState -ne 'Stabilizing') { break }
        }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    if ($null -eq $status) { throw 'The guardian did not publish status within 40 seconds.' }
    return [pscustomobject]@{
        Started = $true
        GuardianPid = [int]$status.guardianPid
        GuardianState = [string]$status.guardianState
        ActiveProxyValid = [bool]$status.activeProxyValid
        EffectivenessEvidence = [string]$status.effectivenessEvidence
    }
}

switch ($Action) {
    'Start' { Start-Guardian }
    'Stop' { Stop-Guardian }
    'Restart' { Stop-Guardian; Start-Guardian }
    'Status' { & (Join-Path $resolvedRoot 'Status.ps1') -InstallRoot $resolvedRoot -Json:$Json }
    'Doctor' { & (Join-Path $resolvedRoot 'Doctor.ps1') -InstallRoot $resolvedRoot -Json:$Json -Online:$Online }
}
