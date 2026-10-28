Set-StrictMode -Version 2.0

# Do not force-reload Core from a nested Windows PowerShell 5.1 module scope.
# Doing so removes the caller's exported Core commands from the global session.
Import-Module (Join-Path $PSScriptRoot 'CodexProxyGuardian.Core.psm1') -ErrorAction Stop

function ConvertTo-CpgLoopbackProxyParts {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ProxyUri)

    $uri = $null
    if (-not [Uri]::TryCreate($ProxyUri, [UriKind]::Absolute, [ref]$uri)) { return $null }
    if (-not (Test-CpgLoopbackHost -HostName $uri.Host) -or $uri.Port -le 0) { return $null }
    return [pscustomobject]@{
        Scheme = $uri.Scheme.ToLowerInvariant()
        Host = $uri.Host.Trim('[', ']')
        Port = [int]$uri.Port
    }
}

function Test-CpgProxyRelayCompatibility {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SourceProxyUri,
        [Parameter(Mandatory = $true)][string]$TargetProxyUri
    )

    $source = ConvertTo-CpgLoopbackProxyParts $SourceProxyUri
    $target = ConvertTo-CpgLoopbackProxyParts $TargetProxyUri
    if ($null -eq $source -or $null -eq $target) { return $false }
    if ($source.Port -eq $target.Port -and
        [string]::Equals($source.Host, $target.Host, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }
    $sourceFamily = if ($source.Scheme -in @('socks5', 'socks5h')) { 'socks5' } elseif ($source.Scheme -in @('http', 'https')) { 'http' } else { '' }
    $targetFamily = if ($target.Scheme -in @('socks5', 'socks5h')) { 'socks5' } elseif ($target.Scheme -in @('http', 'https')) { 'http' } else { '' }
    return -not [string]::IsNullOrWhiteSpace($sourceFamily) -and $sourceFamily -eq $targetFamily
}

function Stop-CpgProxyRelayProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)][string]$ReadyPath,
        [Parameter(Mandatory = $true)][string]$StopPath
    )

    Remove-Item -LiteralPath $StopPath -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $StatePath) {
        try {
            $state = Get-Content -Raw -LiteralPath $StatePath | ConvertFrom-Json
            $relayPid = [int](Get-CpgConfigValue $state 'pid' 0)
            if ($relayPid -gt 0) {
                $token = [string](Get-CpgConfigValue $state 'instanceToken' '')
                $processRecord = Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f $relayPid) -ErrorAction SilentlyContinue
                $owned = -not [string]::IsNullOrWhiteSpace($token) -and $null -ne $processRecord -and
                    ([string]$processRecord.CommandLine).Contains($token)
                if ($owned) {
                    New-Item -ItemType File -Path $StopPath -Force | Out-Null
                    $deadline = (Get-Date).AddSeconds(3)
                    while ((Get-Date) -lt $deadline -and $null -ne (Get-Process -Id $relayPid -ErrorAction SilentlyContinue)) {
                        Start-Sleep -Milliseconds 100
                    }
                    if ($null -ne (Get-Process -Id $relayPid -ErrorAction SilentlyContinue)) {
                        Stop-Process -Id $relayPid -Force -ErrorAction SilentlyContinue
                    }
                }
            }
        }
        catch { }
    }
    Remove-Item -LiteralPath $StopPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $ReadyPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $StatePath -Force -ErrorAction SilentlyContinue
}

function Start-CpgProxyRelayProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SourceProxyUri,
        [Parameter(Mandatory = $true)][string]$TargetProxyUri,
        [Parameter(Mandatory = $true)][string]$RelayScriptPath,
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)][string]$ReadyPath,
        [Parameter(Mandatory = $true)][string]$StopPath
    )

    if (-not (Test-Path -LiteralPath $RelayScriptPath) -or
        -not (Test-CpgProxyRelayCompatibility -SourceProxyUri $SourceProxyUri -TargetProxyUri $TargetProxyUri)) {
        return [pscustomobject]@{ Active = $false; Started = $false; Reason = 'IncompatibleOrMissing'; Pid = 0 }
    }

    if (Test-Path -LiteralPath $StatePath) {
        try {
            $existing = Get-Content -Raw -LiteralPath $StatePath | ConvertFrom-Json
            $existingPid = [int](Get-CpgConfigValue $existing 'pid' 0)
            $existingToken = [string](Get-CpgConfigValue $existing 'instanceToken' '')
            $existingProcess = Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f $existingPid) -ErrorAction SilentlyContinue
            $existingOwned = -not [string]::IsNullOrWhiteSpace($existingToken) -and $null -ne $existingProcess -and
                ([string]$existingProcess.CommandLine).Contains($existingToken)
            if ([string]::Equals([string](Get-CpgConfigValue $existing 'source' ''), $SourceProxyUri, [System.StringComparison]::OrdinalIgnoreCase) -and
                [string]::Equals([string](Get-CpgConfigValue $existing 'target' ''), $TargetProxyUri, [System.StringComparison]::OrdinalIgnoreCase) -and
                $existingOwned) {
                return [pscustomobject]@{ Active = $true; Started = $false; Reason = 'AlreadyRunning'; Pid = $existingPid }
            }
        }
        catch { }
    }

    Stop-CpgProxyRelayProcess -StatePath $StatePath -ReadyPath $ReadyPath -StopPath $StopPath
    $source = ConvertTo-CpgLoopbackProxyParts $SourceProxyUri
    $target = ConvertTo-CpgLoopbackProxyParts $TargetProxyUri
    try {
        $powershellPath = (Get-Command powershell.exe -ErrorAction Stop).Source
        $instanceToken = [Guid]::NewGuid().ToString('N')
        $arguments = @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
            '-File', ('"{0}"' -f $RelayScriptPath.Replace('"', '""')),
            '-ListenHost', $source.Host, '-ListenPort', [string]$source.Port,
            '-TargetHost', $target.Host, '-TargetPort', [string]$target.Port,
            '-InstanceToken', $instanceToken,
            '-ReadyPath', ('"{0}"' -f $ReadyPath.Replace('"', '""')),
            '-StopPath', ('"{0}"' -f $StopPath.Replace('"', '""'))
        )
        $process = Start-Process -FilePath $powershellPath -ArgumentList $arguments -WindowStyle Hidden -PassThru
        $deadline = (Get-Date).AddSeconds(3)
        while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath $ReadyPath)) {
            if ($process.HasExited) { break }
            Start-Sleep -Milliseconds 100
        }
        if (-not (Test-Path -LiteralPath $ReadyPath) -or $process.HasExited) {
            if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
            return [pscustomobject]@{
                Active = $false
                Started = $false
                Reason = 'BindFailed'
                Pid = [int]$process.Id
                ExitCode = if ($process.HasExited) { $process.ExitCode } else { $null }
            }
        }

        $state = [ordered]@{
            pid = [int]$process.Id
            source = $SourceProxyUri
            target = $TargetProxyUri
            instanceToken = $instanceToken
            protocolFamily = if ($source.Scheme -in @('socks5', 'socks5h')) { 'socks5' } else { 'http' }
            startedUtc = (Get-Date).ToUniversalTime().ToString('o')
        }
        $temporaryPath = "$StatePath.tmp"
        $state | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
        Move-Item -LiteralPath $temporaryPath -Destination $StatePath -Force
        return [pscustomobject]@{ Active = $true; Started = $true; Reason = 'Started'; Pid = [int]$process.Id }
    }
    catch {
        return [pscustomobject]@{ Active = $false; Started = $false; Reason = $_.Exception.GetType().Name; Pid = 0; Error = $_.Exception.Message }
    }
}

function Get-CpgRootProxyUriFromCommandLine {
    [CmdletBinding()]
    param($RootProcess)

    if ($null -eq $RootProcess) { return '' }
    $commandLine = [string](Get-CpgConfigValue $RootProcess 'CommandLine' '')
    $match = [regex]::Match($commandLine, '(?i)(?:^|\s)--proxy-server=(?:"(?<quoted>[^"]+)"|(?<plain>\S+))')
    if (-not $match.Success) { return '' }
    $value = if ($match.Groups['quoted'].Success) { $match.Groups['quoted'].Value } else { $match.Groups['plain'].Value }
    $converted = ConvertTo-CpgProxyUri -Address $value -AllowNonLoopback
    if ($null -eq $converted) { return '' }
    return [string]$converted
}

Export-ModuleMember -Function @(
    'ConvertTo-CpgLoopbackProxyParts',
    'Test-CpgProxyRelayCompatibility',
    'Start-CpgProxyRelayProcess',
    'Stop-CpgProxyRelayProcess',
    'Get-CpgRootProxyUriFromCommandLine'
)
