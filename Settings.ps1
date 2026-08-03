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
foreach ($requiredPath in @($markerPath, $configPath, $coreModule)) {
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
$updateChannel = [string](Get-CpgConfigValue $config 'UpdateChannel' 'Prerelease')
$version = [string]$marker.version

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Codex Proxy Guardian 设置'
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.MinimizeBox = $false
$form.ClientSize = New-Object System.Drawing.Size(560, 455)
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
$automaticDescription.Text = '先观察 Codex 是否已经通过当前代理通信；能用就保持不动，确有必要时才受控修复。'
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
[void]$channelCombo.Items.Add('预发布版本（Alpha）')
[void]$channelCombo.Items.Add('仅稳定版本')
$channelCombo.SelectedIndex = if ($updateChannel -eq 'Stable') { 1 } else { 0 }
$updateGroup.Controls.Add($channelCombo)

$checkButton = New-Object System.Windows.Forms.Button
$checkButton.Text = '立即检查更新'
$checkButton.Location = New-Object System.Drawing.Point(345, 57)
$checkButton.Size = New-Object System.Drawing.Size(135, 30)
$updateGroup.Controls.Add($checkButton)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = "当前：$profile；自动更新：$(if ($automaticUpdates) { '开启' } else { '关闭' })"
$statusLabel.Location = New-Object System.Drawing.Point(22, 374)
$statusLabel.Size = New-Object System.Drawing.Size(340, 25)
$form.Controls.Add($statusLabel)

$applyButton = New-Object System.Windows.Forms.Button
$applyButton.Text = '应用'
$applyButton.Location = New-Object System.Drawing.Point(365, 405)
$applyButton.Size = New-Object System.Drawing.Size(82, 32)
$applyButton.DialogResult = [System.Windows.Forms.DialogResult]::None
$form.Controls.Add($applyButton)

$closeButton = New-Object System.Windows.Forms.Button
$closeButton.Text = '关闭'
$closeButton.Location = New-Object System.Drawing.Point(458, 405)
$closeButton.Size = New-Object System.Drawing.Size(82, 32)
$closeButton.Add_Click({ $form.Close() })
$form.Controls.Add($closeButton)

$controlPath = Join-Path $resolvedRoot 'Control.ps1'
$updatePath = Join-Path $resolvedRoot 'Update.ps1'

$checkButton.Add_Click({
    try {
        $form.UseWaitCursor = $true
        $checkButton.Enabled = $false
        [System.Windows.Forms.Application]::DoEvents()
        $result = & $updatePath -InstallRoot $resolvedRoot -CheckOnly
        if ([bool]$result.UpdateAvailable) {
            $choice = [System.Windows.Forms.MessageBox]::Show("发现新版本 $($result.TargetVersion)。是否立即校验并安装？", '发现更新', 'YesNo', 'Question')
            if ($choice -eq [System.Windows.Forms.DialogResult]::Yes) {
                $installed = & $updatePath -InstallRoot $resolvedRoot -Install
                [void][System.Windows.Forms.MessageBox]::Show("已升级到 $($installed.InstalledVersion)。设置窗口将关闭。", '更新完成', 'OK', 'Information')
                $form.Close()
            }
        }
        else {
            [void][System.Windows.Forms.MessageBox]::Show('当前更新通道已经是最新版。', '检查完成', 'OK', 'Information')
        }
    }
    catch {
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '检查更新失败', 'OK', 'Error')
    }
    finally {
        $checkButton.Enabled = $true
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
        $requestedChannel = if ($channelCombo.SelectedIndex -eq 1) { 'Stable' } else { 'Prerelease' }
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
        ModeProfile = $profile
        AutomaticUpdates = $automaticUpdates
        UpdateChannel = $updateChannel
        ControlExists = (Test-Path -LiteralPath $controlPath)
        UpdaterExists = (Test-Path -LiteralPath $updatePath)
    }
    $form.Dispose()
    return
}
[void]$form.ShowDialog()
