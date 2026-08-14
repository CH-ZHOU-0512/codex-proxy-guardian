[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'CodexProxyGuardian'),
    [switch]$CheckOnly,
    [switch]$Install,
    [switch]$Silent,
    [switch]$Json,
    [string]$ChannelOverride = ''
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
$configuredChannel = [string](Get-CpgConfigValue $config 'UpdateChannel' 'Stable')
$channel = if ([string]::IsNullOrWhiteSpace($ChannelOverride)) { $configuredChannel } else { $ChannelOverride.Trim() }
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

$guardianStatusPath = Join-Path $resolvedRoot 'status.json'
$guardianStatus = try {
    if (Test-Path -LiteralPath $guardianStatusPath) { Get-Content -Raw -LiteralPath $guardianStatusPath | ConvertFrom-Json } else { $null }
}
catch { $null }
$preferredUpdateRoute = Get-CpgUpdateProxyDecision -Status $guardianStatus -Config $config
$script:LastUpdateNetworkRoute = [string]$preferredUpdateRoute.Source

function Get-UpdateRequestAttempts {
    $attempts = @()
    if ([bool]$preferredUpdateRoute.UseProxy) {
        $attempts += $preferredUpdateRoute
        $attempts += $preferredUpdateRoute
        $attempts += [pscustomobject]@{ UseProxy = $false; ProxyUri = $null; Source = 'WindowsDefaultRoute'; Transport = 'PowerShell' }
    }
    else {
        1..3 | ForEach-Object {
            $attempts += [pscustomobject]@{ UseProxy = $false; ProxyUri = $null; Source = 'WindowsDefaultRoute'; Transport = 'PowerShell' }
        }
    }
    return @($attempts)
}

function Protect-UpdateRequestError {
    param([string]$Message)
    $safeMessage = $Message
    if ([bool]$preferredUpdateRoute.UseProxy -and -not [string]::IsNullOrWhiteSpace([string]$preferredUpdateRoute.ProxyUri)) {
        $safeMessage = $safeMessage.Replace([string]$preferredUpdateRoute.ProxyUri, (Protect-CpgProxyUri ([string]$preferredUpdateRoute.ProxyUri)))
    }
    if ($safeMessage.Length -gt 1000) { return $safeMessage.Substring(0, 1000) + '...' }
    return $safeMessage
}

function Invoke-UpdateCurlDownload {
    param(
        [string]$Uri,
        [hashtable]$Headers,
        [string]$OutFile,
        [int]$TimeoutSeconds,
        [string]$ProxyUri
    )

    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($null -eq $curl) { throw 'curl.exe is required to update through a SOCKS proxy on Windows 11, but it was not found.' }
    $arguments = @('--fail', '--silent', '--show-error', '--location', '--connect-timeout', '15', '--max-time', [string]$TimeoutSeconds)
    foreach ($headerName in $Headers.Keys) {
        $arguments += @('--header', ('{0}: {1}' -f $headerName, [string]$Headers[$headerName]))
    }
    if (-not [string]::IsNullOrWhiteSpace($ProxyUri)) { $arguments += @('--proxy', $ProxyUri) }
    $arguments += @('--output', $OutFile, $Uri)
    & ([string]$curl.Source) @arguments
    if ($LASTEXITCODE -ne 0) { throw "curl.exe failed with exit code $LASTEXITCODE." }
}

function Invoke-UpdateJsonRequest {
    param([string]$Uri, [hashtable]$Headers, [int]$TimeoutSeconds = 30)

    $attemptNumber = 0
    $attempts = @(Get-UpdateRequestAttempts)
    foreach ($route in $attempts) {
        $attemptNumber++
        $temporaryJson = $null
        try {
            if ([bool]$route.UseProxy -and [string]$route.Transport -eq 'Curl') {
                $temporaryJson = Join-Path ([System.IO.Path]::GetTempPath()) ("CodexProxyGuardian-update-json-{0}.tmp" -f [Guid]::NewGuid().ToString('N'))
                Invoke-UpdateCurlDownload -Uri $Uri -Headers $Headers -OutFile $temporaryJson -TimeoutSeconds $TimeoutSeconds -ProxyUri ([string]$route.ProxyUri)
                $jsonText = [System.IO.File]::ReadAllText($temporaryJson, (New-Object System.Text.UTF8Encoding($false, $true)))
                $result = $jsonText | ConvertFrom-Json
            }
            else {
                $parameters = @{
                    Uri = $Uri
                    Headers = $Headers
                    Method = 'Get'
                    TimeoutSec = $TimeoutSeconds
                }
                if ([bool]$route.UseProxy) { $parameters.Proxy = [string]$route.ProxyUri }
                $result = Invoke-RestMethod @parameters
            }
            $script:LastUpdateNetworkRoute = [string]$route.Source
            return $result
        }
        catch {
            $safeError = Protect-UpdateRequestError $_.Exception.Message
            if ($attemptNumber -ge $attempts.Count) { throw $safeError }
            Write-UpdateLog 'WARN' 'update_request_retry' 'A GitHub update request failed and will be retried through a safe fallback route.' @{
                attempt = $attemptNumber
                route = [string]$route.Source
                error = $safeError
            }
            Start-Sleep -Seconds ([Math]::Min(4, $attemptNumber))
        }
        finally {
            if ($null -ne $temporaryJson) { Remove-Item -LiteralPath $temporaryJson -Force -ErrorAction SilentlyContinue }
        }
    }
}

function Invoke-UpdateAssetDownload {
    param([string]$Uri, [hashtable]$Headers, [string]$OutFile, [int]$TimeoutSeconds)

    $attemptNumber = 0
    $attempts = @(Get-UpdateRequestAttempts)
    foreach ($route in $attempts) {
        $attemptNumber++
        try {
            Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
            if ([bool]$route.UseProxy -and [string]$route.Transport -eq 'Curl') {
                Invoke-UpdateCurlDownload -Uri $Uri -Headers $Headers -OutFile $OutFile -TimeoutSeconds $TimeoutSeconds -ProxyUri ([string]$route.ProxyUri)
            }
            else {
                $parameters = @{
                    Uri = $Uri
                    Headers = $Headers
                    UseBasicParsing = $true
                    OutFile = $OutFile
                    TimeoutSec = $TimeoutSeconds
                }
                if ([bool]$route.UseProxy) { $parameters.Proxy = [string]$route.ProxyUri }
                [void](Invoke-WebRequest @parameters)
            }
            if (-not (Test-Path -LiteralPath $OutFile)) { throw 'The update request completed without creating the expected file.' }
            $script:LastUpdateNetworkRoute = [string]$route.Source
            return
        }
        catch {
            $safeError = Protect-UpdateRequestError $_.Exception.Message
            if ($attemptNumber -ge $attempts.Count) { throw $safeError }
            Write-UpdateLog 'WARN' 'update_request_retry' 'A GitHub asset download failed and will be retried through a safe fallback route.' @{
                attempt = $attemptNumber
                route = [string]$route.Source
                error = $safeError
            }
            Start-Sleep -Seconds ([Math]::Min(4, $attemptNumber))
        }
    }
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
        $result = [pscustomobject]@{
            UpdateChecked = $false
            UpdateAvailable = $null
            AlreadyRunning = $true
            CheckStatus = 'Busy'
            CurrentVersion = $currentVersion
            Channel = $channel
        }
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
        'Cache-Control' = 'no-cache'
        Pragma = 'no-cache'
    }
    Write-UpdateLog 'INFO' 'update_check_started' 'Checking the configured GitHub Release channel.' @{ current_version = $currentVersion; channel = $channel; preferred_route = [string]$preferredUpdateRoute.Source }
    # Assign first, then enumerate. Windows PowerShell 5.1 otherwise preserves
    # the top-level JSON array as one pipeline object inside @(...).
    $releaseResponse = Invoke-UpdateJsonRequest -Uri "https://api.github.com/repos/$repository/releases?per_page=20" -Headers $headers -TimeoutSeconds 30
    $releases = @($releaseResponse)
    $checkedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    $latestRelease = Select-CpgLatestRelease -Releases $releases -Channel $channel
    $latestVersion = if ($null -eq $latestRelease) { $null } else { ([string]$latestRelease.tag_name).TrimStart('v') }
    $release = Select-CpgUpdateRelease -Releases $releases -CurrentVersion $currentVersion -Channel $channel
    if ($null -eq $release) {
        $checkStatus = if ($null -eq $latestRelease) { 'NoEligibleRelease' } else { 'Current' }
        Write-UpdateLog 'INFO' 'update_not_available' 'No newer release is available for the requested channel.' @{ current_version = $currentVersion; latest_version = $latestVersion; channel = $channel; check_status = $checkStatus; network_route = $script:LastUpdateNetworkRoute }
        Write-UpdateResult ([pscustomobject]@{
            UpdateChecked = $true
            UpdateAvailable = $false
            AlreadyRunning = $false
            CheckStatus = $checkStatus
            CurrentVersion = $currentVersion
            LatestVersion = $latestVersion
            Channel = $channel
            CheckedAtUtc = $checkedAtUtc
            NetworkRoute = $script:LastUpdateNetworkRoute
            ReleaseUrl = if ($null -eq $latestRelease) { $null } else { [string]$latestRelease.html_url }
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
        AlreadyRunning = $false
        CheckStatus = 'Available'
        CurrentVersion = $currentVersion
        TargetVersion = $targetVersion
        LatestVersion = $latestVersion
        Channel = $channel
        CheckedAtUtc = $checkedAtUtc
        NetworkRoute = $script:LastUpdateNetworkRoute
        ReleaseUrl = [string]$release.html_url
    }
    Write-UpdateLog 'INFO' 'update_available' 'A newer verified-channel release is available.' @{ current_version = $currentVersion; target_version = $targetVersion; network_route = $script:LastUpdateNetworkRoute }
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
    Invoke-UpdateAssetDownload -Uri ([string]$archiveAsset.browser_download_url) -Headers $headers -OutFile $archivePath -TimeoutSeconds 120
    Invoke-UpdateAssetDownload -Uri ([string]$checksumAsset.browser_download_url) -Headers $headers -OutFile $checksumPath -TimeoutSeconds 30
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
    if ($Silent) { $installArguments += '-AutomaticUpdate' }
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
    Write-UpdateLog 'INFO' 'update_installed' 'The verified release was installed successfully.' @{ previous_version = $currentVersion; installed_version = $installedVersion; sha256 = $actualHash; network_route = $script:LastUpdateNetworkRoute }
    Write-UpdateResult ([pscustomobject]@{
        UpdateChecked = $true
        UpdateAvailable = $true
        Updated = $true
        PreviousVersion = $currentVersion
        InstalledVersion = $installedVersion
        Channel = $channel
        NetworkRoute = $script:LastUpdateNetworkRoute
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
    Write-UpdateLog 'ERROR' 'update_failed' 'The update check or installation failed.' @{ error = $originalError; rollback_error = $rollbackError; rollback_attempted = $installationStarted; network_route = $script:LastUpdateNetworkRoute }
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
