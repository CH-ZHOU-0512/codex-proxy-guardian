[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$script:Passed = 0
$script:Failed = 0

function Invoke-Test {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        $script:Passed++
        Write-Host "PASS  $Name" -ForegroundColor Green
    }
    catch {
        $script:Failed++
        Write-Host "FAIL  $Name" -ForegroundColor Red
        Write-Host "      $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Assert-True {
    param($Value, [string]$Message = 'Expected true.')
    if (-not [bool]$Value) { throw $Message }
}

function Assert-False {
    param($Value, [string]$Message = 'Expected false.')
    if ([bool]$Value) { throw $Message }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message = '')
    if (-not [object]::Equals($Expected, $Actual)) {
        throw "Expected '$Expected', got '$Actual'. $Message"
    }
}

function Assert-Null {
    param($Value, [string]$Message = 'Expected null.')
    if ($null -ne $Value) { throw "$Message Got '$Value'." }
}

Import-Module (Join-Path $repoRoot 'src\CodexProxyGuardian.Core.psm1') -Force

Invoke-Test 'All PowerShell files parse on this runtime' {
    $errors = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $repoRoot -Recurse -File | Where-Object { $_.Extension -in @('.ps1', '.psm1') -and $_.FullName -notlike '*\artifacts\*' })) {
        $tokens = $null
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
        foreach ($parseError in @($parseErrors)) { $errors += "$($file.FullName):$($parseError.Extent.StartLineNumber): $($parseError.Message)" }
    }
    Assert-Equal 0 $errors.Count ($errors -join [Environment]::NewLine)
}

Invoke-Test 'Silent VBS launchers parse and use the inbox PowerShell path' {
    $cscript = Join-Path $env:SystemRoot 'System32\cscript.exe'
    foreach ($name in @('Run-Guardian.vbs', 'Run-ManagedCodex.vbs')) {
        $output = & $cscript //nologo (Join-Path $repoRoot "src\$name") --print-command 2>&1
        Assert-Equal 0 $LASTEXITCODE "$name did not parse. Output: $($output -join ' ')"
        Assert-True (($output -join ' ') -match 'System32\\WindowsPowerShell\\v1\.0\\powershell\.exe') "$name did not resolve inbox Windows PowerShell."
    }
}

Invoke-Test 'Configuration JSON files are valid' {
    foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'config') -Filter '*.json' -File)) {
        $value = Get-Content -Raw -LiteralPath $file.FullName | ConvertFrom-Json
        Assert-True ($null -ne $value) "Could not parse $($file.Name)."
    }
}

Invoke-Test 'Default configuration is conservative' {
    $config = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'config\default-config.json') | ConvertFrom-Json
    Assert-Equal 'Safe' ([string]$config.Mode)
    Assert-False $config.ManageExternalCodexLaunches
    Assert-False $config.AllowNonLoopbackProxy
    Assert-True $config.UseChromiumProxyArgument
    Assert-True ([int]$config.RestartCooldownSeconds -ge 10)
}

Invoke-Test 'Loopback proxy without a scheme is normalized' {
    Assert-Equal 'http://127.0.0.1:8080' (ConvertTo-CpgHttpProxyUri -Address '127.0.0.1:8080')
    Assert-Equal 'http://localhost:80' (ConvertTo-CpgHttpProxyUri -Address 'http://localhost:80')
}

Invoke-Test 'IPv6 loopback proxy is accepted' {
    Assert-Equal 'http://[::1]:8080' (ConvertTo-CpgHttpProxyUri -Address '[::1]:8080')
}

Invoke-Test 'Proxy scheme and explicit port are required' {
    Assert-Null (ConvertTo-CpgHttpProxyUri -Address 'socks5://127.0.0.1:1080')
    Assert-Null (ConvertTo-CpgHttpProxyUri -Address 'http://127.0.0.1')
}

Invoke-Test 'Proxy endpoints cannot contain paths, queries, or fragments' {
    Assert-Null (ConvertTo-CpgHttpProxyUri -Address 'http://127.0.0.1:8080/path')
    Assert-Null (ConvertTo-CpgHttpProxyUri -Address 'http://127.0.0.1:8080?token=value')
    Assert-Null (ConvertTo-CpgHttpProxyUri -Address 'http://127.0.0.1:8080/#fragment')
}

Invoke-Test 'Remote proxies require an explicit opt-in' {
    Assert-Null (ConvertTo-CpgHttpProxyUri -Address 'http://192.0.2.10:8080')
    Assert-Equal 'http://192.0.2.10:8080' (ConvertTo-CpgHttpProxyUri -Address 'http://192.0.2.10:8080' -AllowNonLoopback)
}

Invoke-Test 'Embedded credentials are rejected and redacted' {
    Assert-Null (ConvertTo-CpgHttpProxyUri -Address 'http://alice:supersecret@127.0.0.1:8080')
    $safe = Protect-CpgProxyUri 'http://alice:supersecret@127.0.0.1:8080'
    Assert-False ($safe -match 'alice|supersecret')
    Assert-Equal 'http://127.0.0.1:8080' $safe
}

Invoke-Test 'Windows protocol proxy map prefers HTTPS and deduplicates' {
    $items = @(ConvertFrom-CpgProxyServer -ProxyServer 'http=127.0.0.1:8000;https=127.0.0.1:9000;socks=127.0.0.1:1080')
    Assert-Equal 2 $items.Count
    Assert-Equal 'https' ([string]$items[0].Label)
    Assert-Equal 'http://127.0.0.1:9000' ([string]$items[0].Uri)
}

Invoke-Test 'Managed-root matching survives PID handoff' {
    $old = [pscustomobject]@{ ProcessId = 10; CommandLine = 'ChatGPT.exe --proxy-server=http://127.0.0.1:8080' }
    $new = [pscustomobject]@{ ProcessId = 99; CommandLine = 'ChatGPT.exe --proxy-server=http://127.0.0.1:8080' }
    Assert-True (Test-CpgRootUsesProxy -RootProcess $old -ProxyUri 'http://127.0.0.1:8080')
    Assert-True (Test-CpgRootUsesProxy -RootProcess $new -ProxyUri 'http://127.0.0.1:8080')
    Assert-False (Test-CpgRootUsesProxy -RootProcess $new -ProxyUri 'http://127.0.0.1:8081')
}

Invoke-Test 'Proxy argument must be a complete token' {
    $root = [pscustomobject]@{ CommandLine = 'ChatGPT.exe --proxy-server=http://127.0.0.1:80800' }
    Assert-False (Test-CpgRootUsesProxy -RootProcess $root -ProxyUri 'http://127.0.0.1:8080')
}

Invoke-Test 'Codex root process requires an exact resolved path and no child type' {
    $app = [pscustomobject]@{ ExecutablePath = 'C:\Program Files\WindowsApps\Example\app.exe' }
    $root = [pscustomobject]@{ ExecutablePath = 'C:\Program Files\WindowsApps\Example\app.exe'; CommandLine = 'app.exe' }
    $child = [pscustomobject]@{ ExecutablePath = 'C:\Program Files\WindowsApps\Example\app.exe'; CommandLine = 'app.exe --type=renderer' }
    Assert-True (Test-CpgCodexRootProcess -Process $root -CodexApp $app)
    Assert-False (Test-CpgCodexRootProcess -Process $child -CodexApp $app)
}

Invoke-Test 'Install marker is bound to its canonical root' {
    $root = Join-Path $env:TEMP 'cpg-marker-test'
    $marker = [pscustomobject]@{ productId = 'CodexProxyGuardian'; installRoot = $root }
    Assert-True (Test-CpgInstallMarker -InstallRoot $root -Marker $marker)
    Assert-False (Test-CpgInstallMarker -InstallRoot (Join-Path $env:TEMP 'different-root') -Marker $marker)
    $marker.productId = 'SomethingElse'
    Assert-False (Test-CpgInstallMarker -InstallRoot $root -Marker $marker)
}

Invoke-Test 'Source contains no original-machine fingerprints' {
    $forbidden = @('Gzhou', 'POTATO', 'C:\VPN', '26.727.6591.0')
    $hits = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $repoRoot -Recurse -File | Where-Object { $_.FullName -notlike '*\.git\*' -and $_.FullName -notlike '*\artifacts\*' -and $_.FullName -notlike '*\tests\*' })) {
        $content = Get-Content -Raw -LiteralPath $file.FullName -ErrorAction SilentlyContinue
        foreach ($pattern in $forbidden) {
            if ($content -like "*$pattern*") { $hits += "$($file.FullName): $pattern" }
        }
    }
    Assert-Equal 0 $hits.Count ($hits -join [Environment]::NewLine)
}

Invoke-Test 'Public scripts do not mutate network configuration' {
    $forbiddenCommands = @('netsh winhttp set proxy', 'ProxyEnable\s*=', 'SetEnvironmentVariable\([^\r\n]+["''](?:User|Machine)["'']')
    $hits = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $repoRoot -Recurse -File | Where-Object { $_.Extension -in @('.ps1', '.psm1', '.vbs') -and $_.FullName -notlike '*\tests\*' })) {
        $content = Get-Content -Raw -LiteralPath $file.FullName
        foreach ($pattern in $forbiddenCommands) {
            if ($content -match $pattern) { $hits += "$($file.FullName): $pattern" }
        }
    }
    Assert-Equal 0 $hits.Count ($hits -join [Environment]::NewLine)
}

Write-Host "`n$script:Passed passed, $script:Failed failed."
if ($script:Failed -gt 0) { throw "$script:Failed test(s) failed." }
