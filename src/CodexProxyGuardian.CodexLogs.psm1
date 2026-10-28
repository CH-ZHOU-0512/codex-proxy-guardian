Set-StrictMode -Version 2.0

function Get-CpgCodexSqliteWalPath {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$ConfiguredPath = '')

    $path = [Environment]::ExpandEnvironmentVariables($ConfiguredPath)
    if ([string]::IsNullOrWhiteSpace($path)) {
        $profileRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
        if ([string]::IsNullOrWhiteSpace($profileRoot)) { $profileRoot = [string]$env:USERPROFILE }
        $path = Join-Path $profileRoot '.codex\logs_2.sqlite-wal'
    }
    elseif ($path.EndsWith('.sqlite', [System.StringComparison]::OrdinalIgnoreCase)) {
        $path = "$path-wal"
    }
    return [System.IO.Path]::GetFullPath($path)
}

function New-CpgCodexSqliteTailState {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$ConfiguredPath = '')

    $path = Get-CpgCodexSqliteWalPath -ConfiguredPath $ConfiguredPath
    $length = if (Test-Path -LiteralPath $path -PathType Leaf) {
        [int64](Get-Item -LiteralPath $path -ErrorAction Stop).Length
    }
    else { [int64]0 }
    $state = @{}
    $state[$path] = [pscustomobject]@{ Offset = $length; Carry = '' }
    return $state
}

function Read-CpgCodexSqliteTail {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$State,
        [AllowEmptyString()][string]$ConfiguredPath = '',
        [int]$MaxReadBytes = 262144
    )

    $path = Get-CpgCodexSqliteWalPath -ConfiguredPath $ConfiguredPath
    if (-not $State.ContainsKey($path)) {
        $State[$path] = [pscustomobject]@{ Offset = [int64]0; Carry = '' }
    }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @() }

    $tail = $State[$path]
    $limit = [Math]::Max(65536, [Math]::Min(4194304, $MaxReadBytes))
    $encoding = New-Object System.Text.UTF8Encoding($false, $false)
    $result = New-Object System.Collections.ArrayList
    $stream = $null
    try {
        $stream = New-Object System.IO.FileStream($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
        if ([int64]$tail.Offset -gt $stream.Length) {
            # SQLite checkpoints can replace or truncate the WAL. Reading from
            # zero is safe because reconnect fingerprints are deduplicated.
            $tail.Offset = [int64]0
            $tail.Carry = ''
        }
        $remaining = $stream.Length - [int64]$tail.Offset
        if ($remaining -le 0) { return @() }

        $readLength = [int][Math]::Min([int64]$limit, $remaining)
        $buffer = New-Object byte[] $readLength
        [void]$stream.Seek([int64]$tail.Offset, [System.IO.SeekOrigin]::Begin)
        $read = $stream.Read($buffer, 0, $readLength)
        if ($read -le 0) { return @() }
        $tail.Offset = [int64]$tail.Offset + $read

        $text = [string]$tail.Carry + $encoding.GetString($buffer, 0, $read)
        $relevant = '(?i)(?:failed to (?:connect to )?app-server remote control websocket|required remote control server token refresh failed|stream disconnected\s*-\s*retrying sampling request|app_server_connection\.state_changed|AppServerConnection|error sending request for url|response stream)'
        foreach ($fragment in @([regex]::Split($text, '[\x00-\x08\x0B\x0C\x0E-\x1F]+'))) {
            if ($fragment -match $relevant) { [void]$result.Add($fragment.Trim()) }
        }

        $carryLength = [Math]::Min(8192, $text.Length)
        $tail.Carry = if ($carryLength -gt 0) { $text.Substring($text.Length - $carryLength) } else { '' }
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
    return @($result)
}

Export-ModuleMember -Function @(
    'Get-CpgCodexSqliteWalPath',
    'New-CpgCodexSqliteTailState',
    'Read-CpgCodexSqliteTail'
)
