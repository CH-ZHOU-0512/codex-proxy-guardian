[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-CpgFreePort {
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try { return [int]([System.Net.IPEndPoint]$listener.LocalEndpoint).Port }
    finally { $listener.Stop() }
}

$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('cpg-relay-test-' + [Guid]::NewGuid().ToString('N'))
$targetJob = $null
$relayProcess = $null
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    $targetPort = Get-CpgFreePort
    $relayPort = Get-CpgFreePort
    $targetJob = Start-Job -ArgumentList $targetPort -ScriptBlock {
        param($Port)
        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
        $listener.Start()
        try {
            $client = $listener.AcceptTcpClient()
            try {
                $stream = $client.GetStream()
                $buffer = New-Object byte[] 4
                $read = $stream.Read($buffer, 0, $buffer.Length)
                $stream.Write($buffer, 0, $read)
                $stream.Flush()
            }
            finally { $client.Close() }
        }
        finally { $listener.Stop() }
    }

    $readyPath = Join-Path $testRoot 'ready'
    $stopPath = Join-Path $testRoot 'stop'
    $relayPath = Join-Path $repoRoot 'src\ProxyRelay.ps1'
    $powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $relayPath),
        '-ListenHost', '127.0.0.1', '-ListenPort', [string]$relayPort,
        '-TargetHost', '127.0.0.1', '-TargetPort', [string]$targetPort,
        '-InstanceToken', [Guid]::NewGuid().ToString('N'),
        '-ReadyPath', ('"{0}"' -f $readyPath), '-StopPath', ('"{0}"' -f $stopPath)
    )
    $relayProcess = Start-Process -FilePath $powershellPath -ArgumentList $arguments -WindowStyle Hidden -PassThru
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath $readyPath)) {
        if ($relayProcess.HasExited) { throw "Relay exited with code $($relayProcess.ExitCode)." }
        Start-Sleep -Milliseconds 100
    }
    if (-not (Test-Path -LiteralPath $readyPath)) { throw 'Relay readiness timeout.' }

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $client.Connect('127.0.0.1', $relayPort)
        $stream = $client.GetStream()
        $sent = [Text.Encoding]::ASCII.GetBytes('ping')
        $stream.Write($sent, 0, $sent.Length)
        $stream.Flush()
        $received = New-Object byte[] 4
        $read = $stream.Read($received, 0, $received.Length)
        $reply = [Text.Encoding]::ASCII.GetString($received, 0, $read)
        if ($reply -ne 'ping') { throw "Unexpected relay reply: $reply" }
    }
    finally { $client.Close() }

    New-Item -ItemType File -Path $stopPath | Out-Null
    [void]$relayProcess.WaitForExit(5000)
    if (-not $relayProcess.HasExited) { throw 'Relay did not stop after its stop file was created.' }
    Receive-Job $targetJob -Wait | Out-Null
    Write-Output 'PASS  In-place proxy relay forwards a live TCP stream'
}
finally {
    if ($null -ne $relayProcess -and -not $relayProcess.HasExited) {
        Stop-Process -Id $relayProcess.Id -Force -ErrorAction SilentlyContinue
    }
    if ($null -ne $targetJob) {
        Stop-Job $targetJob -ErrorAction SilentlyContinue
        Remove-Job $targetJob -Force -ErrorAction SilentlyContinue
    }
    $resolvedTestRoot = [System.IO.Path]::GetFullPath($testRoot).TrimEnd('\')
    $resolvedTempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\')
    if ($resolvedTestRoot.StartsWith($resolvedTempRoot + '\cpg-relay-test-', [System.StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
