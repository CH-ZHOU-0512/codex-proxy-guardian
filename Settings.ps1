[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'CodexProxyGuardian'),
    [switch]$SelfTest
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$resolvedRoot = [System.IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
$markerPath = Join-Path $resolvedRoot '.cpg-install.json'
$configPath = Join-Path $resolvedRoot 'config.json'
$coreModule = Join-Path $resolvedRoot 'CodexProxyGuardian.Core.psm1'
$versionPath = Join-Path $resolvedRoot 'VERSION'
foreach ($requiredPath in @($markerPath, $configPath, $coreModule, $versionPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) { throw "Codex Proxy Guardian is not fully installed: $requiredPath" }
}

$marker = Get-Content -Raw -LiteralPath $markerPath | ConvertFrom-Json
if ([string]$marker.productId -ne 'CodexProxyGuardian') { throw 'The installation marker is not owned by Codex Proxy Guardian.' }
Import-Module $coreModule -Force

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$config = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
$profile = Get-CpgModeProfile -Config $config
$automaticUpdates = [bool](Get-CpgConfigValue $config 'AutomaticUpdates' $true)
$updateChannel = [string](Get-CpgConfigValue $config 'UpdateChannel' 'Stable')
$version = (Get-Content -Raw -LiteralPath $versionPath).Trim()
$statusPath = Join-Path $resolvedRoot 'status.json'
$status = try { if (Test-Path -LiteralPath $statusPath) { Get-Content -Raw -LiteralPath $statusPath | ConvertFrom-Json } else { $null } } catch { $null }
function Get-SettingsStatusValue {
    param($Object, [string]$Name, $Default)
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}
$proxyReachability = [string](Get-SettingsStatusValue $status 'proxyReachability' 'Unknown')
$streamStability = [string](Get-SettingsStatusValue $status 'streamStability' 'Unknown')
$compatibilityState = [string](Get-SettingsStatusValue $status 'codexCompatibilityState' 'Unknown')
$compatibilityUpdateState = [string](Get-SettingsStatusValue $status 'compatibilityUpdateCheckState' 'NotNeeded')
$streamingProxyGuaranteed = [bool](Get-SettingsStatusValue $status 'streamingProxyGuaranteed' $false)
$streamingRepairRequired = [bool](Get-SettingsStatusValue $status 'streamingRepairRequired' $false)
$postUpdateSamples = '{0}/{1}' -f [int](Get-SettingsStatusValue $status 'postUpdateSuccessfulSamples' 0), [int](Get-SettingsStatusValue $status 'postUpdateRequiredSamples' 0)
$reachabilityText = switch ($proxyReachability) {
    'CriticalTargetsPassed' { '关键入口已通过' }
    'CriticalTargetsFailed' { '关键入口失败' }
    'ListenerUnavailable' { '本地端口不可达' }
    default { '尚无结论' }
}
$stabilityText = switch ($streamStability) {
    'ObservingAfterCodexUpdate' { "Codex 更新后观察中（$postUpdateSamples）" }
    'UpstreamSuspected' { '疑似代理上游异常；请保持 Codex 打开并尝试换节点' }
    'IndirectEvidenceOnly' { '仅有间接证据；无法从外部证明登录态长连接绝对稳定' }
    default { '尚无结论' }
}
$compatibilityText = switch ($compatibilityState) {
    'Auditing' { '新版能力自动审计中' }
    'Compatible' { '当前 Codex 已取得兼容证据' }
    'NeedsManagedLaunch' { 'HTTP 已走代理，但流式代理尚未保障' }
    'AwaitingEvidence' { '新版入口已自动解析，等待真实使用证据' }
    'ReviewRequired' { '适配未确认：已暂停自动重启并请求受信更新' }
    default { '使用通用 MSIX 清单适配' }
}
$updateAuditText = switch ($compatibilityUpdateState) {
    'Requested' { '已触发 Guardian 兼容更新检查' }
    'RetryDeferred' { '更新检查稍后自动重试' }
    'Failed' { '即时检查失败，保留每日自动检查' }
    'Disabled' { '兼容更新检查已关闭' }
    default { '兼容更新按需检查' }
}
$streamingGuaranteeText = if ($streamingProxyGuaranteed) { '流式代理已由受管启动保障' } elseif ($streamingRepairRequired) { '普通启动仅确认 HTTP；等待你批准受管修复' } else { '流式代理等待 Codex 启动后确认' }

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Codex Proxy Guardian 设置'
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.MinimizeBox = $false
$form.ClientSize = New-Object System.Drawing.Size(560, 630)
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

$title = New-Object System.Windows.Forms.Label
$title.Text = "Codex Proxy Guardian  $version"
$title.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 13, [System.Drawing.FontStyle]::Bold)
$title.AutoSize = $true
$title.Location = New-Object System.Drawing.Point(22, 18)
$form.Controls.Add($title)

$modeGroup = New-Object System.Windows.Forms.GroupBox
$modeGroup.Text = '运行模式'
$modeGroup.Location = New-Object System.Drawing.Point(20, 58)
$modeGroup.Size = New-Object System.Drawing.Size(520, 175)
$form.Controls.Add($modeGroup)

$automaticRadio = New-Object System.Windows.Forms.RadioButton
$automaticRadio.Text = '自动（推荐 / Safe）'
$automaticRadio.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
$automaticRadio.AutoSize = $true
$automaticRadio.Location = New-Object System.Drawing.Point(18, 28)
$automaticRadio.Checked = $profile -ne 'Strict'
$modeGroup.Controls.Add($automaticRadio)

$automaticDescription = New-Object System.Windows.Forms.Label
$automaticDescription.Text = '自动验证 HTTP 与流式代理。普通启动只证明 HTTP 时会弹窗询问；只有点击“是”才受控修复。'
$automaticDescription.Location = New-Object System.Drawing.Point(38, 55)
$automaticDescription.Size = New-Object System.Drawing.Size(460, 38)
$modeGroup.Controls.Add($automaticDescription)

$strictRadio = New-Object System.Windows.Forms.RadioButton
$strictRadio.Text = '严格（Enforce）'
$strictRadio.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
$strictRadio.AutoSize = $true
$strictRadio.Location = New-Object System.Drawing.Point(18, 100)
$strictRadio.Checked = $profile -eq 'Strict'
$modeGroup.Controls.Add($strictRadio)

$strictDescription = New-Object System.Windows.Forms.Label
$strictDescription.Text = '只要 Codex 缺少当前代理参数，就在防抖和重启保护允许时进行校正。'
$strictDescription.Location = New-Object System.Drawing.Point(38, 127)
$strictDescription.Size = New-Object System.Drawing.Size(460, 35)
$modeGroup.Controls.Add($strictDescription)

$updateGroup = New-Object System.Windows.Forms.GroupBox
$updateGroup.Text = '更新'
$updateGroup.Location = New-Object System.Drawing.Point(20, 245)
$updateGroup.Size = New-Object System.Drawing.Size(520, 115)
$form.Controls.Add($updateGroup)

$updateCheck = New-Object System.Windows.Forms.CheckBox
$updateCheck.Text = '自动安装经过 SHA-256 校验的 GitHub Release'
$updateCheck.AutoSize = $true
$updateCheck.Location = New-Object System.Drawing.Point(18, 26)
$updateCheck.Checked = $automaticUpdates
$updateGroup.Controls.Add($updateCheck)

$channelLabel = New-Object System.Windows.Forms.Label
$channelLabel.Text = '更新通道：'
$channelLabel.AutoSize = $true
$channelLabel.Location = New-Object System.Drawing.Point(18, 63)
$updateGroup.Controls.Add($channelLabel)

$channelCombo = New-Object System.Windows.Forms.ComboBox
$channelCombo.DropDownStyle = 'DropDownList'
$channelCombo.Location = New-Object System.Drawing.Point(95, 59)
$channelCombo.Size = New-Object System.Drawing.Size(205, 26)
[void]$channelCombo.Items.Add('稳定版本（推荐）')
[void]$channelCombo.Items.Add('预发布版本（Alpha / Beta）')
$channelCombo.SelectedIndex = if ($updateChannel -eq 'Prerelease') { 1 } else { 0 }
$updateGroup.Controls.Add($channelCombo)

$checkButton = New-Object System.Windows.Forms.Button
$checkButton.Text = '立即检查更新'
$checkButton.Location = New-Object System.Drawing.Point(345, 57)
$checkButton.Size = New-Object System.Drawing.Size(135, 30)
$updateGroup.Controls.Add($checkButton)

$reconnectGroup = New-Object System.Windows.Forms.GroupBox
$reconnectGroup.Text = '关于“正在重新连接”'
$reconnectGroup.Location = New-Object System.Drawing.Point(20, 372)
$reconnectGroup.Size = New-Object System.Drawing.Size(520, 165)
$form.Controls.Add($reconnectGroup)

$reconnectDescription = New-Object System.Windows.Forms.Label
$reconnectDescription.Text = '这表示 Codex 的流式连接正在重试，不等于 Guardian 重启。普通启动时 HTTP 能走系统代理，也不代表 WebSocket 已继承显式代理；受管启动会同时注入 HTTP/HTTPS/WS/WSS。若日志没有 codex_restart / proxy_changed，再检查代理节点。'
$reconnectDescription.Location = New-Object System.Drawing.Point(18, 25)
$reconnectDescription.Size = New-Object System.Drawing.Size(480, 70)
$reconnectGroup.Controls.Add($reconnectDescription)

$connectionStatusLabel = New-Object System.Windows.Forms.Label
$connectionStatusLabel.Text = "连接判定：$reachabilityText；$stabilityText`r`n流式保障：$streamingGuaranteeText`r`n兼容机制：$compatibilityText；$updateAuditText"
$connectionStatusLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
$connectionStatusLabel.Location = New-Object System.Drawing.Point(18, 99)
$connectionStatusLabel.Size = New-Object System.Drawing.Size(480, 64)
$reconnectGroup.Controls.Add($connectionStatusLabel)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = "当前：$profile；自动更新：$(if ($automaticUpdates) { '开启' } else { '关闭' })"
$statusLabel.Location = New-Object System.Drawing.Point(22, 550)
$statusLabel.Size = New-Object System.Drawing.Size(340, 25)
$form.Controls.Add($statusLabel)

$applyButton = New-Object System.Windows.Forms.Button
$applyButton.Text = '应用'
$applyButton.Location = New-Object System.Drawing.Point(365, 583)
$applyButton.Size = New-Object System.Drawing.Size(82, 32)
$applyButton.DialogResult = [System.Windows.Forms.DialogResult]::None
$form.Controls.Add($applyButton)

$closeButton = New-Object System.Windows.Forms.Button
$closeButton.Text = '关闭'
$closeButton.Location = New-Object System.Drawing.Point(458, 583)
$closeButton.Size = New-Object System.Drawing.Size(82, 32)
$closeButton.Add_Click({ $form.Close() })
$form.Controls.Add($closeButton)

$controlPath = Join-Path $resolvedRoot 'Control.ps1'
$updatePath = Join-Path $resolvedRoot 'Update.ps1'

$checkButton.Add_Click({
    try {
        $form.UseWaitCursor = $true
        $checkButton.Enabled = $false
        $checkButton.Text = '正在检查...'
        [System.Windows.Forms.Application]::DoEvents()
        $requestedChannel = if ($channelCombo.SelectedIndex -eq 1) { 'Prerelease' } else { 'Stable' }
        $channelText = if ($requestedChannel -eq 'Prerelease') { '预发布' } else { '稳定版' }
        $result = & $updatePath -InstallRoot $resolvedRoot -CheckOnly -ChannelOverride $requestedChannel
        if ($null -eq $result -or -not [bool]$result.UpdateChecked) {
            $busyMessage = "本次尚未完成更新检查。`r`n`r`n本机版本：$version`r`n检查通道：$channelText`r`n原因：另一个更新任务正在运行。`r`n`r`n这不代表当前已经是最新版，请稍后再试。"
            [void][System.Windows.Forms.MessageBox]::Show($busyMessage, '检查尚未完成', 'OK', 'Warning')
            return
        }

        $checkedAt = try { ([datetime]::Parse([string]$result.CheckedAtUtc)).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss') } catch { '刚刚' }
        if ([bool]$result.UpdateAvailable) {
            $choice = [System.Windows.Forms.MessageBox]::Show("发现新版本。`r`n`r`n本机版本：$($result.CurrentVersion)`r`n远端版本：$($result.TargetVersion)`r`n检查通道：$channelText`r`n检查时间：$checkedAt`r`n来源：GitHub Releases`r`n`r`n是否立即校验并安装？", '发现更新', 'YesNo', 'Question')
            if ($choice -eq [System.Windows.Forms.DialogResult]::Yes) {
                $installed = & $updatePath -InstallRoot $resolvedRoot -Install -ChannelOverride $requestedChannel
                [void][System.Windows.Forms.MessageBox]::Show("已升级到 $($installed.InstalledVersion)。设置窗口将关闭。", '更新完成', 'OK', 'Information')
                $form.Close()
            }
        }
        elseif ([string]$result.CheckStatus -eq 'NoEligibleRelease') {
            [void][System.Windows.Forms.MessageBox]::Show("检查已完成，但 GitHub 没有返回此通道可验证的 Release。`r`n`r`n本机版本：$($result.CurrentVersion)`r`n检查通道：$channelText`r`n检查时间：$checkedAt`r`n`r`n这不能证明当前已经是最新版，请检查网络或稍后重试。", '未找到可验证版本', 'OK', 'Warning')
        }
        else {
            [void][System.Windows.Forms.MessageBox]::Show("检查已完成。`r`n`r`n本机版本：$($result.CurrentVersion)`r`n远端版本：$($result.LatestVersion)`r`n检查通道：$channelText`r`n检查时间：$checkedAt`r`n来源：GitHub Releases`r`n`r`n没有发现更高版本。", '检查完成', 'OK', 'Information')
        }
    }
    catch {
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '检查更新失败', 'OK', 'Error')
    }
    finally {
        $checkButton.Enabled = $true
        $checkButton.Text = '立即检查更新'
        $form.UseWaitCursor = $false
    }
})

$applyButton.Add_Click({
    try {
        $form.UseWaitCursor = $true
        $applyButton.Enabled = $false
        [System.Windows.Forms.Application]::DoEvents()
        $requestedMode = if ($strictRadio.Checked) { 'Strict' } else { 'Auto' }
        $requestedUpdates = if ($updateCheck.Checked) { 'On' } else { 'Off' }
        $requestedChannel = if ($channelCombo.SelectedIndex -eq 1) { 'Prerelease' } else { 'Stable' }
        $result = & $controlPath -Action Configure -InstallRoot $resolvedRoot -Mode $requestedMode -AutomaticUpdates $requestedUpdates -UpdateChannel $requestedChannel
        $statusLabel.Text = "当前：$($result.ModeProfile)；自动更新：$(if ($result.AutomaticUpdates) { '开启' } else { '关闭' })"
        $message = if ($result.Changed) { '设置已经应用。模式会由 Guardian 自动重新加载，不会重启当前 Codex。' } else { '设置没有变化。' }
        [void][System.Windows.Forms.MessageBox]::Show($message, 'Codex Proxy Guardian', 'OK', 'Information')
    }
    catch {
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '应用设置失败', 'OK', 'Error')
    }
    finally {
        $applyButton.Enabled = $true
        $form.UseWaitCursor = $false
    }
})

$form.AcceptButton = $applyButton
$form.CancelButton = $closeButton
if ($SelfTest) {
    [pscustomobject]@{
        Ready = $true
        Version = $version
        ModeProfile = $profile
        AutomaticUpdates = $automaticUpdates
        UpdateChannel = $updateChannel
        ReconnectGuidanceVisible = ($reconnectDescription.Text -like '*不等于 Guardian 重启*')
        StreamStabilityVisible = ($connectionStatusLabel.Text -like '*连接判定*')
        CompatibilityAutomationVisible = ($connectionStatusLabel.Text -like '*兼容机制*')
        StreamingProxyGuaranteeVisible = ($connectionStatusLabel.Text -like '*流式保障*')
        ControlExists = (Test-Path -LiteralPath $controlPath)
        UpdaterExists = (Test-Path -LiteralPath $updatePath)
    }
    $form.Dispose()
    return
}
[void]$form.ShowDialog()
