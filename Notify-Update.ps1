[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'CodexProxyGuardian'),
    [ValidatePattern('^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$')][string]$InstalledVersion,
    [ValidatePattern('^(?:|\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?)$')][string]$PreviousVersion = '',
    [switch]$SelfTest
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$title = "已更新到 v$InstalledVersion"
$message = if ([string]::IsNullOrWhiteSpace($PreviousVersion)) {
    "Codex Proxy Guardian 已自动更新完成。Codex 无需重启，可以继续使用。"
}
else {
    "已从 v$PreviousVersion 自动更新到 v$InstalledVersion。Codex 无需重启，可以继续使用。"
}

if ($SelfTest) {
    [pscustomobject]@{
        Ready = $true
        Title = $title
        Message = $message
        AutoCloses = $true
        CodexRestartRequired = $false
    }
    return
}

$resolvedRoot = [System.IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
$logsPath = Join-Path $resolvedRoot 'logs'
function Write-CpgUpdateNotificationLog {
    param([string]$Level, [string]$Event, [string]$Method, [string]$ErrorMessage = '')
    try {
        New-Item -ItemType Directory -Path $logsPath -Force | Out-Null
        $entry = [ordered]@{
            time = (Get-Date).ToUniversalTime().ToString('o')
            level = $Level
            event = $Event
            previous_version = $PreviousVersion
            installed_version = $InstalledVersion
            method = $Method
        }
        if (-not [string]::IsNullOrWhiteSpace($ErrorMessage)) { $entry.error = $ErrorMessage }
        Add-Content -LiteralPath (Join-Path $logsPath ("update-{0}.jsonl" -f (Get-Date -Format 'yyyyMMdd'))) `
            -Value ($entry | ConvertTo-Json -Compress -Depth 4) -Encoding UTF8
    }
    catch { }
}

$notifyIcon = $null
try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $notifyIcon = New-Object System.Windows.Forms.NotifyIcon
    $notifyIcon.Text = 'Codex Proxy Guardian'
    $notifyIcon.Icon = [System.Drawing.SystemIcons]::Information
    $notifyIcon.Visible = $true
    $notifyIcon.ShowBalloonTip(10000, $title, $message, [System.Windows.Forms.ToolTipIcon]::Info)

    $deadline = (Get-Date).AddSeconds(8)
    while ((Get-Date) -lt $deadline) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 100
    }
    Write-CpgUpdateNotificationLog 'INFO' 'automatic_update_notification_shown' 'NotifyIcon'
}
catch {
    $notifyError = $_.Exception.Message
    $shell = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        [void]$shell.Popup($message, 15, ("更新完成 · $title"), 64)
        Write-CpgUpdateNotificationLog 'INFO' 'automatic_update_notification_shown' 'WScriptPopup'
    }
    catch {
        Write-CpgUpdateNotificationLog 'WARN' 'automatic_update_notification_failed' 'Unavailable' ("$notifyError; $($_.Exception.Message)")
    }
    finally {
        if ($null -ne $shell) {
            try { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) } catch { }
        }
    }
}
finally {
    if ($null -ne $notifyIcon) {
        $notifyIcon.Visible = $false
        $notifyIcon.Dispose()
    }
}
