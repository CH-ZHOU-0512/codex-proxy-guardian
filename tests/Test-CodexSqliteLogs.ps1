[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\CodexProxyGuardian.CodexLogs.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\src\CodexProxyGuardian.Core.psm1') -Force
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class CpgTestLogWriter {
    [DllImport("winsqlite3.dll", CallingConvention=CallingConvention.Cdecl)]
    static extern int sqlite3_open(byte[] path, out IntPtr db);
    [DllImport("winsqlite3.dll", CallingConvention=CallingConvention.Cdecl)]
    static extern int sqlite3_exec(IntPtr db, byte[] sql, IntPtr callback, IntPtr arg, IntPtr error);
    [DllImport("winsqlite3.dll", CallingConvention=CallingConvention.Cdecl)]
    static extern int sqlite3_close(IntPtr db);
    static byte[] U(string s) { return Encoding.UTF8.GetBytes(s + "\0"); }
    public static IntPtr Open(string path) {
        IntPtr db; if(sqlite3_open(U(path), out db)!=0) throw new Exception("open failed"); return db;
    }
    public static void Exec(IntPtr db,string sql) {
        if(sqlite3_exec(db,U(sql),IntPtr.Zero,IntPtr.Zero,IntPtr.Zero)!=0) throw new Exception("write failed");
    }
    public static void Close(IntPtr db) { sqlite3_close(db); }
}
'@
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('cpg-native-log-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$db = [IntPtr]::Zero
try {
    $path = Join-Path $testRoot 'logs_2.sqlite'
    $db = [CpgTestLogWriter]::Open($path)
    [CpgTestLogWriter]::Exec($db, 'PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE logs(id INTEGER PRIMARY KEY AUTOINCREMENT,ts INTEGER,target TEXT,feedback_log_body TEXT);')
    $state = New-CpgCodexSqliteTailState -ConfiguredPath $path
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $body = 'stream disconnected - retrying sampling request (4/5 in 1.2s) sampling_error=request timed out'
    [CpgTestLogWriter]::Exec($db, "INSERT INTO logs(ts,target,feedback_log_body) VALUES($now,'codex_core::responses_retry','$body');")
    $records = @(Read-CpgCodexSqliteTail -State $state -ConfiguredPath $path)
    if ($records.Count -ne 1) { throw "Expected one committed event, got $($records.Count)" }
    $signal = Get-CpgReconnectLogSignal $records[0]
    if (-not $signal.IsSignal -or $signal.Attempt -ne 4) { throw 'Real SQLite row was not classified' }
    if (@(Read-CpgCodexSqliteTail -State $state -ConfiguredPath $path).Count -ne 0) { throw 'Repeated query replayed old events' }
    [CpgTestLogWriter]::Exec($db, 'PRAGMA wal_checkpoint(RESTART);')
    [CpgTestLogWriter]::Exec($db, "INSERT INTO logs(ts,target,feedback_log_body) VALUES($now,'codex_core::responses_retry','$body');")
    if (@(Read-CpgCodexSqliteTail -State $state -ConfiguredPath $path).Count -ne 1) { throw 'Reused WAL lost an event' }
    [CpgTestLogWriter]::Exec($db, "INSERT INTO logs(ts,target,feedback_log_body) VALUES($now,'feedback_tags','$body');")
    if (@(Read-CpgCodexSqliteTail -State $state -ConfiguredPath $path).Count -ne 0) { throw 'Tool/prompt echo was treated as telemetry' }
    [CpgTestLogWriter]::Exec($db, "BEGIN; INSERT INTO logs(ts,target,feedback_log_body) VALUES($now,'codex_core::responses_retry','$body');")
    if (@(Read-CpgCodexSqliteTail -State $state -ConfiguredPath $path).Count -ne 0) { throw 'Uncommitted event was read' }
    [CpgTestLogWriter]::Exec($db, 'COMMIT;')
    if (@(Read-CpgCodexSqliteTail -State $state -ConfiguredPath $path).Count -ne 1) { throw 'Committed event was lost' }
    'PASS SQLite transactions, WAL reuse, deduplication, and telemetry filtering'
} finally {
    if ($db -ne [IntPtr]::Zero) { [CpgTestLogWriter]::Close($db) }
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
