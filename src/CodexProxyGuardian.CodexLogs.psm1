Set-StrictMode -Version 2.0

function Initialize-CpgSqliteReader {
    if ('CpgSqliteLogReader' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class CpgSqliteLogReader {
    [DllImport("winsqlite3.dll", CallingConvention=CallingConvention.Cdecl)]
    static extern int sqlite3_open_v2(byte[] path, out IntPtr db, int flags, IntPtr vfs);
    [DllImport("winsqlite3.dll", CallingConvention=CallingConvention.Cdecl)]
    static extern int sqlite3_close(IntPtr db);
    [DllImport("winsqlite3.dll", CallingConvention=CallingConvention.Cdecl)]
    static extern int sqlite3_busy_timeout(IntPtr db, int ms);
    [DllImport("winsqlite3.dll", CallingConvention=CallingConvention.Cdecl)]
    static extern int sqlite3_prepare_v2(IntPtr db, byte[] sql, int size, out IntPtr stmt, IntPtr tail);
    [DllImport("winsqlite3.dll", CallingConvention=CallingConvention.Cdecl)]
    static extern int sqlite3_step(IntPtr stmt);
    [DllImport("winsqlite3.dll", CallingConvention=CallingConvention.Cdecl)]
    static extern int sqlite3_finalize(IntPtr stmt);
    [DllImport("winsqlite3.dll", CallingConvention=CallingConvention.Cdecl)]
    static extern long sqlite3_column_int64(IntPtr stmt, int column);
    [DllImport("winsqlite3.dll", CallingConvention=CallingConvention.Cdecl)]
    static extern IntPtr sqlite3_column_text(IntPtr stmt, int column);
    [DllImport("winsqlite3.dll", CallingConvention=CallingConvention.Cdecl)]
    static extern int sqlite3_column_bytes(IntPtr stmt, int column);
    static byte[] Utf8(string value) { return Encoding.UTF8.GetBytes(value + "\0"); }
    public static string[][] Query(string path, string sql) {
        IntPtr db = IntPtr.Zero, stmt = IntPtr.Zero;
        try {
            // SQLITE_OPEN_READONLY respects committed WAL frames and checkpoints.
            int rc = sqlite3_open_v2(Utf8(path), out db, 1, IntPtr.Zero);
            if (rc != 0) throw new InvalidOperationException("SQLite read-only open failed: " + rc);
            sqlite3_busy_timeout(db, 250);
            rc = sqlite3_prepare_v2(db, Utf8(sql), -1, out stmt, IntPtr.Zero);
            if (rc != 0) throw new InvalidOperationException("SQLite log schema unavailable: " + rc);
            var rows = new List<string[]>();
            while ((rc = sqlite3_step(stmt)) == 100) {
                var values = new string[3];
                values[0] = sqlite3_column_int64(stmt, 0).ToString(System.Globalization.CultureInfo.InvariantCulture);
                values[1] = sqlite3_column_int64(stmt, 1).ToString(System.Globalization.CultureInfo.InvariantCulture);
                int size = sqlite3_column_bytes(stmt, 2);
                IntPtr pointer = sqlite3_column_text(stmt, 2);
                if (pointer != IntPtr.Zero && size > 0) {
                    byte[] bytes = new byte[size]; Marshal.Copy(pointer, bytes, 0, size);
                    values[2] = Encoding.UTF8.GetString(bytes);
                } else { values[2] = ""; }
                rows.Add(values);
            }
            if (rc != 101) throw new InvalidOperationException("SQLite log read failed: " + rc);
            return rows.ToArray();
        } finally {
            if (stmt != IntPtr.Zero) sqlite3_finalize(stmt);
            if (db != IntPtr.Zero) sqlite3_close(db);
        }
    }
}
'@
}

function Get-CpgCodexSqliteWalPath {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$ConfiguredPath = '')
    $path = [Environment]::ExpandEnvironmentVariables($ConfiguredPath)
    if ([string]::IsNullOrWhiteSpace($path)) {
        $profileRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
        if ([string]::IsNullOrWhiteSpace($profileRoot)) { $profileRoot = [string]$env:USERPROFILE }
        $path = Join-Path $profileRoot '.codex\logs_2.sqlite-wal'
    }
    elseif ($path.EndsWith('.sqlite', [System.StringComparison]::OrdinalIgnoreCase)) { $path = "$path-wal" }
    return [System.IO.Path]::GetFullPath($path)
}

function New-CpgCodexSqliteTailState {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$ConfiguredPath = '')
    # Include recent failures when Guardian attaches after a failed first request.
    return @{ LastId = [int64]0; SinceUnix = [int64]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 120) }
}

function Read-CpgCodexSqliteTail {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$State,
        [AllowEmptyString()][string]$ConfiguredPath = '',
        [int]$MaxReadBytes = 262144
    )
    $walPath = Get-CpgCodexSqliteWalPath -ConfiguredPath $ConfiguredPath
    $dbPath = $walPath.Substring(0, $walPath.Length - 4)
    if (-not (Test-Path -LiteralPath $dbPath -PathType Leaf)) { return @() }
    Initialize-CpgSqliteReader
    $lastId = [int64]$State.LastId
    $since = [int64]$State.SinceUnix
    # Only telemetry producers: never classify tool output or prompt echoes.
    $sql = "SELECT id,ts,substr(feedback_log_body,-8192) FROM logs WHERE id > $lastId AND ts >= $since AND target IN ('codex_core::responses_retry','codex_api::endpoint::responses_websocket','codex_app_server_transport::transport::remote_control::websocket','codex_core::client') ORDER BY id LIMIT 256"
    $rows = [CpgSqliteLogReader]::Query($dbPath, $sql)
    $lines = New-Object System.Collections.ArrayList
    foreach ($row in $rows) {
        $State.LastId = [int64]$row[0]
        $timestamp = [DateTimeOffset]::FromUnixTimeSeconds([int64]$row[1]).UtcDateTime.ToString('o')
        [void]$lines.Add("$timestamp sqlite_log_id=$($row[0]) $($row[2])")
    }
    return @($lines)
}

Export-ModuleMember -Function @('Get-CpgCodexSqliteWalPath','New-CpgCodexSqliteTailState','Read-CpgCodexSqliteTail')
