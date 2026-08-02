[CmdletBinding()]
param([string]$OutputDirectory = '')

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

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
        'CHANGELOG.md', 'CODE_OF_CONDUCT.md', 'CONTRIBUTING.md', 'Control.ps1',
        'DISCLAIMER.md', 'Doctor.ps1', 'Install.ps1', 'LICENSE', 'README.md',
        'SECURITY.md', 'Status.ps1', 'Uninstall.ps1', 'VERSION',
        'config', 'docs', 'src', 'tests', 'tools'
    )
    foreach ($name in $releaseItems) {
        $sourcePath = Join-Path $repoRoot $name
        if (-not (Test-Path -LiteralPath $sourcePath)) { throw "Missing release item: $sourcePath" }
        Copy-Item -LiteralPath $sourcePath -Destination $stageProject -Recurse -Force
    }

    $zipPath = Join-Path $outputRoot ("CodexProxyGuardian-{0}.zip" -f $version)
    $checksumPath = "$zipPath.sha256"
    Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $checksumPath -Force -ErrorAction SilentlyContinue
    Compress-Archive -LiteralPath $stageProject -DestinationPath $zipPath -CompressionLevel Optimal
    $hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $([System.IO.Path]::GetFileName($zipPath))" | Set-Content -LiteralPath $checksumPath -Encoding ASCII

    [pscustomobject]@{
        Version = $version
        Archive = $zipPath
        Sha256 = $hash
        ChecksumFile = $checksumPath
    }
}
finally {
    $tempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\')
    $resolvedStage = [System.IO.Path]::GetFullPath($stageRoot).TrimEnd('\')
    if ($resolvedStage.StartsWith($tempBase + '\CodexProxyGuardian-package-', [System.StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedStage -Recurse -Force -ErrorAction SilentlyContinue
    }
}
