[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'CodexProxyGuardian'),
    [switch]$CheckOnly,
    [switch]$Install,
    [switch]$Silent,
    [switch]$Json
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ($CheckOnly -and $Install) { throw 'Use either -CheckOnly or -Install, not both.' }
if (-not $CheckOnly -and -not $Install) { $CheckOnly = $true }

$resolvedRoot = [System.IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
$markerPath = Join-Path $resolvedRoot '.cpg-install.json'
$configPath = Join-Path $resolvedRoot 'config.json'
$versionPath = Join-Path $resolvedRoot 'VERSION'
$coreModule = Join-Path $resolvedRoot 'CodexProxyGuardian.Core.psm1'
foreach ($requiredPath in @($markerPath, $configPath, $versionPath, $coreModule)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) { throw "The installed update prerequisite is missing: $requiredPath" }
}

$marker = Get-Content -Raw -LiteralPath $markerPath | ConvertFrom-Json
if ([string]$marker.productId -ne 'CodexProxyGuardian' -or -not [string]::Equals([System.IO.Path]::GetFullPath([string]$marker.installRoot).TrimEnd('\'), $resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'The installation marker does not match the update path.'
}
Import-Module $coreModule -Force

$config = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
$currentVersion = (Get-Content -Raw -LiteralPath $versionPath).Trim()
$automaticUpdates = [bool](Get-CpgConfigValue $config 'AutomaticUpdates' $true)
$channel = [string](Get-CpgConfigValue $config 'UpdateChannel' 'Stable')
if ($channel -notin @('Stable', 'Prerelease')) { throw "Unsupported update channel: $channel" }

$logsPath = Join-Path $resolvedRoot 'logs'
New-Item -ItemType Directory -Path $logsPath -Force | Out-Null
$updateLogPath = Join-Path $logsPath ("update-{0}.jsonl" -f (Get-Date -Format 'yyyyMMdd'))
$updateStatusPath = Join-Path $resolvedRoot 'update-status.json'
function Write-UpdateLog {
    param([string]$Level, [string]$Event, [string]$Message, [hashtable]$Data = @{})
    $entry = [ordered]@{
        time = (Get-Date).ToUniversalTime().ToString('o')
        level = $Level
        event = $Event
        message = $Message
    }
    foreach ($key in $Data.Keys) { $entry[$key] = $Data[$key] }
    Add-Content -LiteralPath $updateLogPath -Value ($entry | ConvertTo-Json -Compress -Depth 5) -Encoding UTF8
    $statusTemporaryPath = Join-Path $resolvedRoot ("update-status.{0}.tmp" -f [Guid]::NewGuid().ToString('N'))
    $statusBackupPath = Join-Path $resolvedRoot ("update-status.{0}.bak" -f [Guid]::NewGuid().ToString('N'))
    try {
        $entry | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $statusTemporaryPath -Encoding UTF8
        if (Test-Path -LiteralPath $updateStatusPath) {
            [System.IO.File]::Replace($statusTemporaryPath, $updateStatusPath, $statusBackupPath, $true)
        }
        else {
            Move-Item -LiteralPath $statusTemporaryPath -Destination $updateStatusPath
        }
    }
    finally {
        Remove-Item -LiteralPath $statusTemporaryPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $statusBackupPath -Force -ErrorAction SilentlyContinue
    }
}

function Write-UpdateResult {
    param($Result)
    if ($Json) { $Result | ConvertTo-Json -Depth 6 }
    elseif (-not $Silent) { $Result }
}

$mutex = New-Object System.Threading.Mutex($false, 'Local\CodexProxyGuardianUpdater')
$mutexAcquired = $false
$temporaryRoot = $null
$backupRoot = $null
$installationStarted = $false
$guardianWasRunning = $false

function Stop-OwnedGuardianForRollback {
    $watcherPath = Join-Path $resolvedRoot 'Watch-CodexProxy.ps1'
    New-Item -ItemType File -Path (Join-Path $resolvedRoot 'stop.request') -Force | Out-Null
    if ([string]$marker.startupMode -eq 'ScheduledTask') {
        Stop-ScheduledTask -TaskName ([string]$marker.taskName) -ErrorAction SilentlyContinue
    }
    $deadline = (Get-Date).AddSeconds(20)
    do {
        $ownedProcesses = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
            Test-CpgGuardianProcessIdentity -Process $_ -WatcherPath $watcherPath
        })
        if ($ownedProcesses.Count -eq 0 -or (Get-Date) -ge $deadline) { break }
        Start-Sleep -Milliseconds 250
    } while ($true)
    foreach ($ownedProcess in $ownedProcesses) {
        if (Test-CpgGuardianProcessIdentity -Process $ownedProcess -WatcherPath $watcherPath) {
            Stop-Process -Id ([int]$ownedProcess.ProcessId) -Force -ErrorAction SilentlyContinue
        }
    }
}

function Restore-PreviousInstallation {
    if ($null -eq $backupRoot -or -not (Test-Path -LiteralPath $backupRoot)) { return }
    Stop-OwnedGuardianForRollback
    foreach ($backupFile in @(Get-ChildItem -LiteralPath $backupRoot -File -Force)) {
        Copy-Item -LiteralPath $backupFile.FullName -Destination (Join-Path $resolvedRoot $backupFile.Name) -Force
    }
    Remove-Item -LiteralPath (Join-Path $resolvedRoot 'stop.request') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $resolvedRoot 'status.json') -Force -ErrorAction SilentlyContinue
    if ($guardianWasRunning) {
        if ([string]$marker.startupMode -eq 'ScheduledTask') {
            Start-ScheduledTask -TaskName ([string]$marker.taskName) -ErrorAction Stop
        }
        else {
            $wscriptPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
            Start-Process -FilePath $wscriptPath -ArgumentList ('"{0}"' -f (Join-Path $resolvedRoot 'Run-Guardian.vbs')) -WindowStyle Hidden
        }
    }
}
try {
    $mutexAcquired = $mutex.WaitOne(0, $false)
    if (-not $mutexAcquired) {
        $result = [pscustomobject]@{ UpdateChecked = $false; AlreadyRunning = $true; CurrentVersion = $currentVersion }
        Write-UpdateResult $result
        return
    }
    if ($Silent -and $Install -and -not $automaticUpdates) {
        Write-UpdateLog 'INFO' 'automatic_update_disabled' 'The scheduled update check was skipped because automatic updates are disabled.'
        Write-UpdateResult ([pscustomobject]@{ UpdateChecked = $false; AutomaticUpdates = $false; CurrentVersion = $currentVersion })
        return
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $repository = 'CH-ZHOU-0512/codex-proxy-guardian'
    $headers = @{
        Accept = 'application/vnd.github+json'
        'User-Agent' = "CodexProxyGuardian/$currentVersion"
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    Write-UpdateLog 'INFO' 'update_check_started' 'Checking the configured GitHub Release channel.' @{ current_version = $currentVersion; channel = $channel }
    $releases = @(Invoke-RestMethod -Uri "https://api.github.com/repos/$repository/releases?per_page=20" -Headers $headers -Method Get -TimeoutSec 30)
    $release = Select-CpgUpdateRelease -Releases $releases -CurrentVersion $currentVersion -Channel $channel
    if ($null -eq $release) {
        Write-UpdateLog 'INFO' 'update_not_available' 'The installed version is current for the configured channel.' @{ current_version = $currentVersion; channel = $channel }
        Write-UpdateResult ([pscustomobject]@{
            UpdateChecked = $true
            UpdateAvailable = $false
            CurrentVersion = $currentVersion
            Channel = $channel
        })
        return
    }

    $targetVersion = ([string]$release.tag_name).TrimStart('v')
    $archiveName = "CodexProxyGuardian-$targetVersion.zip"
    $checksumName = "$archiveName.sha256"
    $archiveAsset = @($release.assets | Where-Object { [string]$_.name -eq $archiveName }) | Select-Object -First 1
    $checksumAsset = @($release.assets | Where-Object { [string]$_.name -eq $checksumName }) | Select-Object -First 1
    if ($null -eq $archiveAsset -or $null -eq $checksumAsset) { throw "Release $($release.tag_name) does not contain the expected archive and checksum assets." }

    $releasePrefix = "https://github.com/$repository/releases/download/"
    foreach ($asset in @($archiveAsset, $checksumAsset)) {
        if (-not ([string]$asset.browser_download_url).StartsWith($releasePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Release asset URL is outside the trusted repository: $($asset.name)"
        }
    }

    $availableResult = [pscustomobject]@{
        UpdateChecked = $true
        UpdateAvailable = $true
        CurrentVersion = $currentVersion
        TargetVersion = $targetVersion
        Channel = $channel
        ReleaseUrl = [string]$release.html_url
    }
    Write-UpdateLog 'INFO' 'update_available' 'A newer verified-channel release is available.' @{ current_version = $currentVersion; target_version = $targetVersion }
    if ($CheckOnly) {
        Write-UpdateResult $availableResult
        return
    }
    if (-not $PSCmdlet.ShouldProcess($targetVersion, "Download, verify, and install Codex Proxy Guardian $targetVersion")) {
        Write-UpdateResult $availableResult
        return
    }

    $temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("CodexProxyGuardian-update-{0}" -f [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
    $archivePath = Join-Path $temporaryRoot $archiveName
    $checksumPath = Join-Path $temporaryRoot $checksumName
    Invoke-WebRequest -Uri ([string]$archiveAsset.browser_download_url) -Headers $headers -UseBasicParsing -OutFile $archivePath -TimeoutSec 120
    Invoke-WebRequest -Uri ([string]$checksumAsset.browser_download_url) -Headers $headers -UseBasicParsing -OutFile $checksumPath -TimeoutSec 30
    $archiveInfo = Get-Item -LiteralPath $archivePath
    if ($archiveInfo.Length -le 0 -or $archiveInfo.Length -gt 100MB) { throw "Downloaded archive size is invalid: $($archiveInfo.Length) bytes." }
    $checksumInfo = Get-Item -LiteralPath $checksumPath
    if ($checksumInfo.Length -le 0 -or $checksumInfo.Length -gt 1MB) { throw "Downloaded checksum size is invalid: $($checksumInfo.Length) bytes." }
    $declaredHash = Get-CpgDeclaredSha256 -ChecksumText (Get-Content -Raw -LiteralPath $checksumPath)
    if ([string]::IsNullOrWhiteSpace($declaredHash)) { throw 'The release checksum file is malformed.' }
    $actualHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $declaredHash) { throw "Release archive SHA-256 mismatch. Expected $declaredHash, got $actualHash." }

    $assetDigestProperty = $archiveAsset.PSObject.Properties['digest']
    if ($null -ne $assetDigestProperty -and -not [string]::IsNullOrWhiteSpace([string]$assetDigestProperty.Value)) {
        $assetDigest = ([string]$assetDigestProperty.Value).Trim().ToLowerInvariant()
        if ($assetDigest -notmatch '^sha256:[0-9a-f]{64}$' -or $assetDigest -ne "sha256:$actualHash") {
            throw "The GitHub asset digest does not match the downloaded release archive: $assetDigest."
        }
    }

    $extractRoot = Join-Path $temporaryRoot 'extracted'
    New-Item -ItemType Directory -Path $extractRoot | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($archivePath)
    try {
        $entryCount = 0
        $expandedBytes = [long]0
        $resolvedExtractRoot = [System.IO.Path]::GetFullPath($extractRoot).TrimEnd('\')
        foreach ($entry in $archive.Entries) {
            $entryCount++
            $expandedBytes += [long]$entry.Length
            if ($entryCount -gt 5000 -or $expandedBytes -gt 200MB) { throw 'The release archive exceeds the safe extraction limits.' }
            $entryPath = [string]$entry.FullName
            $resolvedEntryPath = [System.IO.Path]::GetFullPath((Join-Path $resolvedExtractRoot ($entryPath.Replace('/', '\'))))
            if (-not $resolvedEntryPath.StartsWith($resolvedExtractRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "The release archive contains an unsafe path: $entryPath"
            }
        }
    }
    finally {
        $archive.Dispose()
    }
    Expand-Archive -LiteralPath $archivePath -DestinationPath $extractRoot
    $stagedRoot = Join-Path $extractRoot 'CodexProxyGuardian'
    $stagedInstaller = Join-Path $stagedRoot 'Install.ps1'
    $stagedVersionPath = Join-Path $stagedRoot 'VERSION'
    if (-not (Test-Path -LiteralPath $stagedInstaller) -or -not (Test-Path -LiteralPath $stagedVersionPath)) { throw 'The verified release archive does not contain the expected project root.' }
    $stagedVersion = (Get-Content -Raw -LiteralPath $stagedVersionPath).Trim()
    if ($stagedVersion -ne $targetVersion) { throw "Release tag, asset name, and staged VERSION do not match: $targetVersion vs $stagedVersion." }

    Write-UpdateLog 'INFO' 'update_install_started' 'The verified release is being installed.' @{ target_version = $targetVersion; sha256 = $actualHash }
    $backupRoot = Join-Path $temporaryRoot 'previous-installation'
    New-Item -ItemType Directory -Path $backupRoot | Out-Null
    foreach ($installedFile in @(Get-ChildItem -LiteralPath $resolvedRoot -File -Force | Where-Object {
        $_.Name -notin @('status.json', 'state.json', 'stop.request') -and
        $_.Name -notlike 'status.stale-pid-*.json' -and
        $_.Name -notlike 'stop.stale-pid-*.request'
    })) {
        Copy-Item -LiteralPath $installedFile.FullName -Destination (Join-Path $backupRoot $installedFile.Name) -Force
    }
    $watcherPath = Join-Path $resolvedRoot 'Watch-CodexProxy.ps1'
    $guardianWasRunning = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        Test-CpgGuardianProcessIdentity -Process $_ -WatcherPath $watcherPath
    }).Count -gt 0
    $powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $installArguments = @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $stagedInstaller,
        '-InstallRoot', $resolvedRoot,
        '-TaskName', [string]$marker.taskName,
        '-RunValueName', [string]$marker.runValueName,
        '-PreserveUpdateTask'
    )
    $updateTaskProperty = $marker.PSObject.Properties['updateTaskName']
    if ($null -ne $updateTaskProperty -and -not [string]::IsNullOrWhiteSpace([string]$updateTaskProperty.Value)) {
        $installArguments += @('-UpdateTaskName', [string]$updateTaskProperty.Value)
    }
    $managedShortcutProperty = $marker.PSObject.Properties['shortcutPath']
    $managedShortcutPath = if ($null -eq $managedShortcutProperty) { '' } else { [string]$managedShortcutProperty.Value }
    if ([string]::IsNullOrWhiteSpace($managedShortcutPath)) {
        $installArguments += '-NoShortcut'
    }
    else {
        $installArguments += @('-ShortcutName', [System.IO.Path]::GetFileName($managedShortcutPath))
        $settingsShortcutProperty = $marker.PSObject.Properties['settingsShortcutPath']
        if ($null -ne $settingsShortcutProperty -and -not [string]::IsNullOrWhiteSpace([string]$settingsShortcutProperty.Value)) {
            $installArguments += @('-SettingsShortcutName', [System.IO.Path]::GetFileName([string]$settingsShortcutProperty.Value))
        }
    }
    $installationStarted = $true
    $installOutput = @(& $powershellPath @installArguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "The verified update installer failed with exit code $LASTEXITCODE. Output: $($installOutput -join ' ')" }
    $installedVersion = (Get-Content -Raw -LiteralPath (Join-Path $resolvedRoot 'VERSION')).Trim()
    if ($installedVersion -ne $targetVersion) { throw "The updater completed but installed VERSION is '$installedVersion' instead of '$targetVersion'." }
    Write-UpdateLog 'INFO' 'update_installed' 'The verified release was installed successfully.' @{ previous_version = $currentVersion; installed_version = $installedVersion; sha256 = $actualHash }
    Write-UpdateResult ([pscustomobject]@{
        UpdateChecked = $true
        UpdateAvailable = $true
        Updated = $true
        PreviousVersion = $currentVersion
        InstalledVersion = $installedVersion
        Channel = $channel
        Sha256 = $actualHash
    })
}
catch {
    $originalError = $_.Exception.Message
    $rollbackError = $null
    if ($installationStarted) {
        try {
            Restore-PreviousInstallation
            Write-UpdateLog 'WARN' 'update_rolled_back' 'The failed update was rolled back to the previous installation.' @{ error = $originalError; previous_version = $currentVersion }
        }
        catch {
            $rollbackError = $_.Exception.Message
        }
    }
    Write-UpdateLog 'ERROR' 'update_failed' 'The update check or installation failed.' @{ error = $originalError; rollback_error = $rollbackError; rollback_attempted = $installationStarted }
    if ($null -ne $rollbackError) { throw "Update failed: $originalError Rollback also failed: $rollbackError" }
    throw $originalError
}
finally {
    if ($null -ne $temporaryRoot -and (Test-Path -LiteralPath $temporaryRoot)) {
        $tempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\')
        $resolvedTemporaryRoot = [System.IO.Path]::GetFullPath($temporaryRoot).TrimEnd('\')
        if ($resolvedTemporaryRoot.StartsWith($tempBase + '\CodexProxyGuardian-update-', [System.StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $resolvedTemporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    if ($mutexAcquired) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
