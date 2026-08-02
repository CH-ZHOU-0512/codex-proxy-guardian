Set-StrictMode -Version 2.0

function Get-CpgConfigValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$Name,
        $Default
    )

    $property = $Config.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return $Default
    }
    return $property.Value
}

function Test-CpgLoopbackHost {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$HostName)

    if ($HostName -in @('localhost', '127.0.0.1', '::1')) {
        return $true
    }

    $address = $null
    if ([System.Net.IPAddress]::TryParse($HostName, [ref]$address)) {
        return [System.Net.IPAddress]::IsLoopback($address)
    }
    return $false
}

function ConvertTo-CpgHttpProxyUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Address,
        [switch]$AllowNonLoopback
    )

    if ([string]::IsNullOrWhiteSpace($Address)) {
        return $null
    }

    $value = $Address.Trim().Trim('"').Trim("'")
    if ($value -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
        $value = "http://$value"
    }

    $authorityText = (($value -replace '^[a-zA-Z][a-zA-Z0-9+.-]*://', '') -split '[/?#]', 2)[0]
    if ($authorityText -notmatch ':\d+$') {
        return $null
    }

    $uri = $null
    if (-not [Uri]::TryCreate($value, [UriKind]::Absolute, [ref]$uri)) {
        return $null
    }
    if ($uri.Scheme -notin @('http', 'https')) {
        return $null
    }
    if ([string]::IsNullOrWhiteSpace($uri.Host) -or $uri.Port -le 0 -or $uri.Port -gt 65535) {
        return $null
    }
    if (($uri.AbsolutePath -ne '/' -and -not [string]::IsNullOrEmpty($uri.AbsolutePath)) -or
        -not [string]::IsNullOrEmpty($uri.Query) -or
        -not [string]::IsNullOrEmpty($uri.Fragment)) {
        return $null
    }
    if (-not [string]::IsNullOrEmpty($uri.UserInfo)) {
        return $null
    }
    if (-not $AllowNonLoopback -and -not (Test-CpgLoopbackHost -HostName $uri.Host)) {
        return $null
    }

    $normalizedHost = $uri.Host.Trim('[', ']')
    if ($normalizedHost.Contains(':')) {
        $ipAddress = $null
        if ([System.Net.IPAddress]::TryParse($normalizedHost, [ref]$ipAddress)) {
            $normalizedHost = $ipAddress.ToString()
        }
        $normalizedHost = "[$normalizedHost]"
    }
    return ("{0}://{1}:{2}" -f $uri.Scheme.ToLowerInvariant(), $normalizedHost.ToLowerInvariant(), $uri.Port)
}

function ConvertFrom-CpgProxyServer {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$ProxyServer,
        [switch]$AllowNonLoopback
    )

    if ([string]::IsNullOrWhiteSpace($ProxyServer)) {
        return @()
    }

    $items = @()
    $raw = $ProxyServer.Trim()
    if ($raw.Contains('=')) {
        $map = @{}
        foreach ($part in ($raw -split ';')) {
            $pair = $part -split '=', 2
            if ($pair.Count -eq 2) {
                $map[$pair[0].Trim().ToLowerInvariant()] = $pair[1].Trim()
            }
        }
        foreach ($scheme in @('https', 'http')) {
            if ($map.ContainsKey($scheme)) {
                $items += [pscustomobject]@{ Address = $map[$scheme]; Label = $scheme }
            }
        }
    }
    else {
        $items += [pscustomobject]@{ Address = $raw; Label = 'all' }
    }

    $result = @()
    $seen = @{}
    foreach ($item in $items) {
        $uri = ConvertTo-CpgHttpProxyUri -Address ([string]$item.Address) -AllowNonLoopback:$AllowNonLoopback
        if ($null -ne $uri -and -not $seen.ContainsKey($uri)) {
            $seen[$uri] = $true
            $result += [pscustomobject]@{ Uri = $uri; Label = $item.Label }
        }
    }
    return $result
}

function Protect-CpgProxyUri {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$ProxyUri)

    if ([string]::IsNullOrWhiteSpace($ProxyUri)) {
        return $ProxyUri
    }

    $value = $ProxyUri.Trim()
    if ($value -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
        $value = "http://$value"
    }
    $uri = $null
    if (-not [Uri]::TryCreate($value, [UriKind]::Absolute, [ref]$uri)) {
        return '<invalid-proxy-uri>'
    }
    if ([string]::IsNullOrWhiteSpace($uri.Host)) {
        return '<invalid-proxy-uri>'
    }
    return $uri.GetLeftPart([UriPartial]::Authority).Replace($uri.UserInfo + '@', '')
}

function Test-CpgRootUsesProxy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$RootProcess,
        [Parameter(Mandatory = $true)][string]$ProxyUri,
        [bool]$UseChromiumProxyArgument = $true
    )

    if (-not $UseChromiumProxyArgument) {
        return $true
    }
    if ([string]::IsNullOrWhiteSpace($ProxyUri)) {
        return $false
    }

    $expected = '--proxy-server=' + $ProxyUri.TrimEnd('/')
    $commandLine = [string]$RootProcess.CommandLine
    return ($commandLine -match ('(?i)(?:^|\s)' + [regex]::Escape($expected) + '(?:\s|$)'))
}

function Get-CpgCodexApp {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Config)

    $packageNames = @(Get-CpgConfigValue -Config $Config -Name 'CodexPackageNames' -Default @('OpenAI.Codex'))
    $preferredAppId = [string](Get-CpgConfigValue -Config $Config -Name 'CodexApplicationId' -Default '')
    foreach ($packageName in $packageNames) {
        $package = Get-AppxPackage -Name ([string]$packageName) -ErrorAction SilentlyContinue |
            Sort-Object Version -Descending |
            Select-Object -First 1
        if ($null -eq $package) {
            continue
        }

        try {
            $manifest = Get-AppxPackageManifest -Package $package -ErrorAction Stop
            $applications = @($manifest.Package.Applications.Application)
            $application = $null
            if (-not [string]::IsNullOrWhiteSpace($preferredAppId)) {
                $application = $applications | Where-Object { [string]$_.Id -eq $preferredAppId } | Select-Object -First 1
            }
            if ($null -eq $application) {
                $application = $applications | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Executable) } | Select-Object -First 1
            }
            if ($null -eq $application) {
                continue
            }

            $relativeExecutable = ([string]$application.Executable).Replace('/', '\')
            $executablePath = Join-Path ([string]$package.InstallLocation) $relativeExecutable
            if (-not (Test-Path -LiteralPath $executablePath)) {
                continue
            }

            return [pscustomobject]@{
                PackageName       = [string]$package.Name
                PackageFamilyName = [string]$package.PackageFamilyName
                Version           = [string]$package.Version
                ApplicationId     = [string]$application.Id
                InstallLocation   = [string]$package.InstallLocation
                ExecutablePath    = $executablePath
                ProcessName       = [System.IO.Path]::GetFileName($executablePath)
            }
        }
        catch {
            continue
        }
    }
    return $null
}

function Test-CpgCodexRootProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Process,
        [Parameter(Mandatory = $true)]$CodexApp
    )

    $path = [string]$Process.ExecutablePath
    $commandLine = [string]$Process.CommandLine
    if ([string]::IsNullOrWhiteSpace($path) -or [string]::IsNullOrWhiteSpace([string]$CodexApp.ExecutablePath)) {
        return $false
    }
    $pathMatches = [string]::Equals(
        [System.IO.Path]::GetFullPath($path),
        [System.IO.Path]::GetFullPath([string]$CodexApp.ExecutablePath),
        [System.StringComparison]::OrdinalIgnoreCase
    )
    return ($pathMatches -and $commandLine -notmatch '(?:^|\s)--type=')
}

function Test-CpgInstallMarker {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)]$Marker
    )

    if ([string]$Marker.productId -ne 'CodexProxyGuardian') {
        return $false
    }
    $expected = [System.IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
    $actual = [System.IO.Path]::GetFullPath([string]$Marker.installRoot).TrimEnd('\')
    return [string]::Equals($expected, $actual, [System.StringComparison]::OrdinalIgnoreCase)
}

Export-ModuleMember -Function @(
    'Get-CpgConfigValue',
    'Test-CpgLoopbackHost',
    'ConvertTo-CpgHttpProxyUri',
    'ConvertFrom-CpgProxyServer',
    'Protect-CpgProxyUri',
    'Test-CpgRootUsesProxy',
    'Get-CpgCodexApp',
    'Test-CpgCodexRootProcess',
    'Test-CpgInstallMarker'
)
