Set-StrictMode -Version 2.0

function Get-CpgSystemProxyConfigEdit {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    $featureTable = [regex]::Match($Text, '(?ms)^\[features\][ \t]*\r?\n(?<body>.*?)(?=^\[|\z)')
    if ($featureTable.Success -and $featureTable.Groups['body'].Value -match '(?m)^\s*respect_system_proxy\s*=\s*(true|false)\b') {
        return [pscustomobject]@{ Changed = $false; Text = $Text; State = if ($matches[1] -eq 'true') { 'Enabled' } else { 'UserDisabled' } }
    }
    # Preserve unusual/inline or quoted TOML declarations for manual review.
    if ($Text -match '(?m)^\s*(?:features\s*=|\[\s*["'']features|respect_system_proxy\s*=)' -or
        $Text -match '(?m)^\s*features\.respect_system_proxy\s*=') {
        return [pscustomobject]@{ Changed = $false; Text = $Text; State = 'ManualConfigReview' }
    }
    $nl = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $block = '# Codex Proxy Guardian: begin system proxy routing' + $nl +
        'respect_system_proxy = true' + $nl + '# Codex Proxy Guardian: end system proxy routing' + $nl
    if ($featureTable.Success) {
        $offset = $featureTable.Index + $featureTable.Length
        $updated = $Text.Insert($offset, $nl + $block)
    } else {
        $firstTable = [regex]::Match($Text, '(?m)^\[')
        $offset = if ($firstTable.Success) { $firstTable.Index } else { $Text.Length }
        $updated = $Text.Insert($offset, $nl + '[features]' + $nl + $block + $nl)
    }
    return [pscustomobject]@{ Changed = $true; Text = $updated; State = 'EnabledForNewSessions' }
}

function Enable-CpgCodexSystemProxy {
    param([Parameter(Mandatory = $true)][string]$CliPath, [Parameter(Mandatory = $true)][string]$ConfigPath)
    if (-not (Test-Path -LiteralPath $CliPath -PathType Leaf)) { return 'CliUnavailable' }
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $CliPath
    $startInfo.Arguments = 'features list'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        [void]$process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(10000)) {
            # This is only our short-lived capability probe, never the desktop/app-server.
            $process.Kill()
            return 'CapabilityProbeTimedOut'
        }
        $output = $stdoutTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0 -or $output -notmatch '(?m)^respect_system_proxy\s+(?!removed\b).+\s+(true|false)\s*$') { return 'Unsupported' }
    } finally { $process.Dispose() }

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { return 'ConfigUnavailable' }
    $before = [IO.File]::ReadAllText($ConfigPath)
    $edit = Get-CpgSystemProxyConfigEdit -Text $before
    if (-not $edit.Changed) { return [string]$edit.State }
    $backupPath = $ConfigPath + '.bak-guardian-' + [guid]::NewGuid().ToString('N')
    Copy-Item -LiteralPath $ConfigPath -Destination $backupPath -ErrorAction Stop
    $tempPath = $ConfigPath + '.guardian-' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($tempPath, [string]$edit.Text, (New-Object Text.UTF8Encoding($false)))
        if ([IO.File]::ReadAllText($ConfigPath) -cne $before) { return 'ConfigChangedConcurrently' }
        Move-Item -LiteralPath $tempPath -Destination $ConfigPath -Force
    } finally {
        if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force }
    }
    return [string]$edit.State
}

function Disable-CpgOwnedSystemProxyConfig {
    param([Parameter(Mandatory = $true)][string]$ConfigPath)
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { return }
    $text = [IO.File]::ReadAllText($ConfigPath)
    $pattern = '(?m)^# Codex Proxy Guardian: begin system proxy routing\r?\nrespect_system_proxy = true\r?\n# Codex Proxy Guardian: end system proxy routing\r?\n?'
    $updated = [regex]::Replace($text, $pattern, '')
    if ($updated -cne $text) {
        [IO.File]::WriteAllText($ConfigPath, $updated, (New-Object Text.UTF8Encoding($false)))
    }
}

Export-ModuleMember -Function @('Get-CpgSystemProxyConfigEdit','Enable-CpgCodexSystemProxy','Disable-CpgOwnedSystemProxyConfig')
