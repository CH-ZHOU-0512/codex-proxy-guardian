[CmdletBinding()]
param([string]$OutputDirectory = '')

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-CpgCSharpCompiler {
    $frameworkRoots = @(
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'),
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319')
    )
    foreach ($frameworkRoot in $frameworkRoots) {
        $compiler = Join-Path $frameworkRoot 'csc.exe'
        if (Test-Path -LiteralPath $compiler) {
            return [pscustomobject]@{ Compiler = $compiler; FrameworkRoot = $frameworkRoot }
        }
    }
    throw 'The Windows .NET Framework C# compiler was not found. Windows 11 normally includes .NET Framework 4.8.'
}

function New-CpgSetupIcon {
    param([Parameter(Mandatory = $true)][string]$Path)

    Add-Type -AssemblyName System.Drawing
    $bitmap = New-Object System.Drawing.Bitmap 256, 256
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $darkBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(17, 21, 16))
    $lightBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(243, 241, 232))
    $font = New-Object System.Drawing.Font 'Segoe UI', 118, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
    $format = New-Object System.Drawing.StringFormat
    $memory = New-Object System.IO.MemoryStream
    try {
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.Clear([System.Drawing.Color]::Transparent)
        $graphics.FillEllipse($darkBrush, 8, 8, 240, 240)
        $format.Alignment = [System.Drawing.StringAlignment]::Center
        $format.LineAlignment = [System.Drawing.StringAlignment]::Center
        $graphics.DrawString('C', $font, $lightBrush, (New-Object System.Drawing.RectangleF 0, 0, 256, 248), $format)
        $bitmap.Save($memory, [System.Drawing.Imaging.ImageFormat]::Png)
        $pngBytes = $memory.ToArray()

        $iconStream = New-Object System.IO.MemoryStream
        $writer = New-Object System.IO.BinaryWriter $iconStream
        try {
            $writer.Write([UInt16]0)
            $writer.Write([UInt16]1)
            $writer.Write([UInt16]1)
            $writer.Write([Byte]0)
            $writer.Write([Byte]0)
            $writer.Write([Byte]0)
            $writer.Write([Byte]0)
            $writer.Write([UInt16]1)
            $writer.Write([UInt16]32)
            $writer.Write([UInt32]$pngBytes.Length)
            $writer.Write([UInt32]22)
            $writer.Write($pngBytes)
            $writer.Flush()
            [System.IO.File]::WriteAllBytes($Path, $iconStream.ToArray())
        }
        finally {
            $writer.Dispose()
            $iconStream.Dispose()
        }
    }
    finally {
        $memory.Dispose()
        $format.Dispose()
        $font.Dispose()
        $lightBrush.Dispose()
        $darkBrush.Dispose()
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$version = (Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'VERSION')).Trim()
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = Join-Path $repoRoot 'artifacts' }
$outputRoot = [System.IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null

& (Join-Path $repoRoot 'tests\Run-Tests.ps1')

$stageRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("CodexProxyGuardian-package-{0}" -f [Guid]::NewGuid().ToString('N'))
$stageProject = Join-Path $stageRoot 'CodexProxyGuardian'
New-Item -ItemType Directory -Path $stageProject -Force | Out-Null
try {
    $releaseItems = @(
        'assets', 'CHANGELOG.md', 'CODE_OF_CONDUCT.md', 'CONTRIBUTING.md', 'Control.ps1',
        'DISCLAIMER.md', 'Doctor.ps1', 'Install.ps1', 'LICENSE', 'README.md',
        'Notify-Update.ps1', 'SECURITY.md', 'Settings.ps1', 'Status.ps1', 'Uninstall.ps1', 'Update.ps1', 'VERSION',
        'cmd', 'config', 'docs', 'go.mod', 'internal', 'platform', 'setup', 'src', 'tests', 'tools'
    )
    foreach ($name in $releaseItems) {
        $sourcePath = Join-Path $repoRoot $name
        if (-not (Test-Path -LiteralPath $sourcePath)) { throw "Missing release item: $sourcePath" }
        Copy-Item -LiteralPath $sourcePath -Destination $stageProject -Recurse -Force
    }

    $zipPath = Join-Path $outputRoot ("CodexProxyGuardian-{0}.zip" -f $version)
    $checksumPath = "$zipPath.sha256"
    $installerPath = Join-Path $outputRoot ("CodexProxyGuardian-Setup-{0}.exe" -f $version)
    $installerChecksumPath = "$installerPath.sha256"
    Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $checksumPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $installerPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $installerChecksumPath -Force -ErrorAction SilentlyContinue
    Compress-Archive -LiteralPath $stageProject -DestinationPath $zipPath -CompressionLevel Optimal
    $hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $([System.IO.Path]::GetFileName($zipPath))" | Set-Content -LiteralPath $checksumPath -Encoding ASCII

    if ($version -notmatch '^(\d+)\.(\d+)\.(\d+)') {
        throw "VERSION '$version' cannot be converted into a Windows file version."
    }
    $assemblyVersion = '{0}.{1}.{2}.0' -f $Matches[1], $Matches[2], $Matches[3]
    $assemblyInfoPath = Join-Path $stageRoot 'AssemblyInfo.cs'
    $iconPath = Join-Path $stageRoot 'CodexProxyGuardian.ico'
    $assemblyInfo = @"
using System.Reflection;
[assembly: AssemblyTitle("Codex Proxy Guardian Setup")]
[assembly: AssemblyDescription("One-click current-user installer for Codex Proxy Guardian")]
[assembly: AssemblyCompany("CH-ZHOU-0512")]
[assembly: AssemblyProduct("Codex Proxy Guardian")]
[assembly: AssemblyCopyright("Copyright (c) 2026 CH-ZHOU-0512")]
[assembly: AssemblyVersion("$assemblyVersion")]
[assembly: AssemblyFileVersion("$assemblyVersion")]
[assembly: AssemblyInformationalVersion("$version")]
"@
    Set-Content -LiteralPath $assemblyInfoPath -Value $assemblyInfo -Encoding UTF8
    New-CpgSetupIcon -Path $iconPath

    $compilerInfo = Get-CpgCSharpCompiler
    $referenceNames = @(
        'System.dll', 'System.Core.dll', 'System.Drawing.dll', 'System.Windows.Forms.dll',
        'System.IO.Compression.dll', 'System.IO.Compression.FileSystem.dll'
    )
    $compilerArguments = @(
        '/nologo', '/target:winexe', '/optimize+', '/platform:anycpu', '/codepage:65001',
        "/out:$installerPath", "/win32icon:$iconPath", "/resource:$zipPath,CodexProxyGuardian.Payload.zip"
    )
    foreach ($referenceName in $referenceNames) {
        $referencePath = Join-Path $compilerInfo.FrameworkRoot $referenceName
        if (-not (Test-Path -LiteralPath $referencePath)) { throw "Missing compiler reference: $referencePath" }
        $compilerArguments += "/reference:$referencePath"
    }
    $compilerArguments += (Join-Path $repoRoot 'setup\Program.cs')
    $compilerArguments += $assemblyInfoPath
    & $compilerInfo.Compiler @compilerArguments
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $installerPath)) {
        throw "The one-click installer compiler exited with code $LASTEXITCODE."
    }

    & $installerPath --verify
    if ($LASTEXITCODE -ne 0) { throw "The one-click installer self-check exited with code $LASTEXITCODE." }
    $installerHash = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash.ToLowerInvariant()
    "$installerHash  $([System.IO.Path]::GetFileName($installerPath))" | Set-Content -LiteralPath $installerChecksumPath -Encoding ASCII

    & go run (Join-Path $repoRoot 'tools\package-posix.go') -root $repoRoot -out $outputRoot -version $version
    if ($LASTEXITCODE -ne 0) { throw "The macOS/Linux packager exited with code $LASTEXITCODE." }

    [pscustomobject]@{
        Version = $version
        Archive = $zipPath
        Sha256 = $hash
        ChecksumFile = $checksumPath
        Installer = $installerPath
        InstallerSha256 = $installerHash
        InstallerChecksumFile = $installerChecksumPath
        PosixArchives = @(Get-ChildItem -LiteralPath $outputRoot -Filter "CodexProxyGuardian-$version-*.tar.gz" -File | Select-Object -ExpandProperty FullName)
    }
}
finally {
    $tempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\')
    $resolvedStage = [System.IO.Path]::GetFullPath($stageRoot).TrimEnd('\')
    if ($resolvedStage.StartsWith($tempBase + '\CodexProxyGuardian-package-', [System.StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedStage -Recurse -Force -ErrorAction SilentlyContinue
    }
}
