<#
.SYNOPSIS
    Downloads the Portly New Tab extension from the Pages site into a folder, ready for
    Load unpacked in Chrome or Edge, or updates a folder it filled before. Needs no Git, Node.js,
    npm or administrator rights, and installs no server.

.DESCRIPTION
    1. Reads <SiteUrl>/portly-extension.json (the version, the zip's name and its SHA-256), or
       uses a zip already on this PC (-ZipPath; checked against -Sha256, or the
       portly-extension.json next to it).
    2. Downloads portly-extension.zip into a temporary folder and checks its SHA-256.
    3. Unpacks it into <Destination>.new and checks it is Portly New Tab with Portly's fixed
       extension ID (the "key" in its manifest.json).
    4. Moves it to <Destination>. When <Destination> already holds Portly New Tab it is replaced
       (it must hold nothing else); the browser keeps the extension and its settings, and only
       needs a Reload.
    5. New install: shows the Load unpacked steps, puts the folder path on the clipboard and
       opens the browser's extensions page.

    The browser still has to load the folder itself: Chrome and Edge do not let a script install
    an extension that is not in their store. Self-contained, so it also runs as `irm <url> | iex`.
    See docs\setup\extension.md.

.PARAMETER SiteUrl
    The Pages site to download from (default https://davideaurum.github.io/). https only (http
    for localhost, 127.0.0.1 or [::1]).

.PARAMETER Destination
    The folder the extension goes into (default %LOCALAPPDATA%\Programs\Portly\extension). Load
    unpacked points the browser at this folder, so keep it where it is.

.PARAMETER ZipPath
    Use this portly-extension.zip instead of downloading one.

.PARAMETER Sha256
    The SHA-256 the zip must have. Without it, -ZipPath is checked against the
    portly-extension.json in the same folder when there is one.

.PARAMETER Force
    Replace the folder even when it already holds this version.

.PARAMETER NoBrowser
    Do not open the browser's extensions page or copy to the clipboard.

.PARAMETER DryRun
    Say which version would go where, and change nothing (nothing is downloaded but the small
    portly-extension.json).

.EXAMPLE
    irm https://davideaurum.github.io/get-extension.ps1 | iex

.EXAMPLE
    & ([scriptblock]::Create((irm https://davideaurum.github.io/get-extension.ps1))) -Destination D:\Portly\extension

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\get-extension.ps1 -ZipPath .\portly-extension.zip
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$SiteUrl = 'https://davideaurum.github.io/',
    [string]$Destination = (Join-Path $env:LOCALAPPDATA 'Programs\Portly\extension'),
    [string]$ZipPath,
    [string]$Sha256,
    [switch]$Force,
    [switch]$NoBrowser,
    [switch]$DryRun
)

$ExtInfoName = 'portly-extension.json'
$ExtPackageName = 'portly-extension.zip'
$ExtName = 'Portly New Tab'
# The public "key" in extension\manifest.json: it fixes the extension ID
# (nbaolbakegefnefgojdokagajincnfjj), which the launcher answers. check-scripts.ps1 compares them.
$ExtKey = 'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAi4fwJClMi9zC1h1jhYaFMkcGydu20VsOeLnpqac4MuAnNF5QeB5uigfv+ykBRMSLtii4JJIOWDEy9j789bay+Sr8QSUnNJITIGcBYXPmvy8vTWr+QKRJTTDYhwJP7rLnqC9jDuQwa8n1+SJUGXbEu9afI7/N50hz6nvfJyiFX4yaLM7i96259osCiuy2TIc099FbKxT2A1acRFMFD3p+2V/9uzyLRaLwjPdgqdW2i9VbGHHBw41gJ0aWgDtUIWHYLD5q6Fb8wL6ARHxrpvx8AuGZ8UjtolgYJabqheqnpK11Hz9gaKHX+C79L2skMKV1rpwWRM7bPtvx8NIyuzJmGwIDAQAB' # gitleaks:allow (a public key, the one in manifest.json)

function Write-ExtStep { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-ExtOk { param([string]$Message) Write-Host "OK  $Message" -ForegroundColor Green }
function Write-ExtInfo { param([string]$Message = '') Write-Host "    $Message" }
function Write-ExtFailure { param([string]$Message) Write-Host "ERROR: $Message" -ForegroundColor Red }

function Get-ExtProperty {
    param($Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Read-ExtJson {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        return [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json
    } catch {
        throw "$Path is not valid JSON: $($_.Exception.Message)"
    }
}

# Extension versions as Chrome accepts them: one to four dot-separated numbers.
function Test-ExtVersion {
    param([string]$Value)
    return $Value -match '^[0-9]+(\.[0-9]+){0,3}$'
}

# The site's address with a trailing '/', by the rules install.ps1 applies to -PagesUrl.
function ConvertTo-ExtSiteUrl {
    param([Parameter(Mandatory)][string]$Value)
    $text = $Value.Trim()
    $uri = $null
    $usage = "-SiteUrl must be the Pages site's full address, like https://<user>.github.io/ (got '$Value')."
    if ($text -match '[?#\s]' -or -not [System.Uri]::TryCreate($text, [System.UriKind]::Absolute, [ref]$uri)) { throw $usage }
    $loopback = @('localhost', '127.0.0.1', '[::1]')
    if (-not ($uri.Scheme -eq 'https' -or ($uri.Scheme -eq 'http' -and $loopback -contains $uri.Host))) {
        throw "$usage It must use https (http only for localhost, 127.0.0.1 or [::1])."
    }
    if ($uri.UserInfo) { throw "$usage It must not contain a user name or password." }
    $path = $uri.AbsolutePath
    if (-not $path.EndsWith('/')) { $path += '/' }
    return "$($uri.GetLeftPart([System.UriPartial]::Authority))$path"
}

function Invoke-ExtDownload {
    param([Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][string]$OutFile, [Parameter(Mandatory)][string]$What)
    # Windows PowerShell 5.1 may not offer TLS 1.2 by default, and its progress bar slows
    # Invoke-WebRequest down a lot.
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
    } catch { }
    $previousProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -ErrorAction Stop
    } catch {
        $status = $null
        try { $status = [int]$_.Exception.Response.StatusCode } catch { }
        if ($status -eq 404) { throw "$What was not found ($Url). The Pages site may not have been published with it yet." }
        throw "Could not download $What from $Url : $($_.Exception.Message)"
    } finally {
        $ProgressPreference = $previousProgress
    }
}

# Which zip to use: Version (null when unknown until unpacked), Package (path or URL), Sha256
# (null when there is nothing to check against), Local (true for -ZipPath).
function Resolve-ExtPackage {
    param([Parameter(Mandatory)][string]$Work)
    $expectedHash = if ([string]::IsNullOrWhiteSpace($Sha256)) { $null } else { $Sha256.Trim().ToLowerInvariant() }
    if ($null -ne $expectedHash -and $expectedHash -notmatch '^[0-9a-f]{64}$') {
        throw "-Sha256 must be 64 hexadecimal characters (got '$Sha256')."
    }
    if (-not [string]::IsNullOrWhiteSpace($ZipPath)) {
        if (-not (Test-Path -LiteralPath $ZipPath -PathType Leaf)) { throw "-ZipPath: $ZipPath does not exist." }
        $zip = (Resolve-Path -LiteralPath $ZipPath).ProviderPath
        $version = $null
        $info = Read-ExtJson -Path (Join-Path (Split-Path -Parent $zip) $ExtInfoName)
        if ($null -ne $info -and "$(Get-ExtProperty $info 'package')" -ieq [System.IO.Path]::GetFileName($zip)) {
            $version = "$(Get-ExtProperty $info 'version')"
            if ($null -eq $expectedHash) { $expectedHash = "$(Get-ExtProperty $info 'sha256')".ToLowerInvariant() }
        }
        return [pscustomobject]@{ Version = $version; Package = $zip; Sha256 = $expectedHash; Local = $true }
    }
    $site = ConvertTo-ExtSiteUrl -Value $SiteUrl
    $infoUrl = "$site$ExtInfoName"
    $infoPath = Join-Path $Work $ExtInfoName
    Invoke-ExtDownload -Url $infoUrl -OutFile $infoPath -What "The extension's description"
    $info = Read-ExtJson -Path $infoPath
    $version = "$(Get-ExtProperty $info 'version')"
    $hash = "$(Get-ExtProperty $info 'sha256')".ToLowerInvariant()
    if ((Get-ExtProperty $info 'name') -ne 'portly-extension' -or "$(Get-ExtProperty $info 'package')" -ne $ExtPackageName -or
        -not (Test-ExtVersion $version) -or $hash -notmatch '^[0-9a-f]{64}$') {
        throw "$infoUrl is not a valid description of the Portly extension."
    }
    if ($null -ne $expectedHash -and $expectedHash -ne $hash) {
        throw "-Sha256 does not match the SHA-256 the site publishes for version $version."
    }
    return [pscustomobject]@{ Version = $version; Package = "$site$ExtPackageName"; Sha256 = $hash; Local = $false }
}

# The manifest of Portly New Tab in $Dir, $null when $Dir holds no manifest.json; throws for
# another extension.
function Read-ExtManifest {
    param([Parameter(Mandatory)][string]$Dir)
    $manifest = Read-ExtJson -Path (Join-Path $Dir 'manifest.json')
    if ($null -eq $manifest) { return $null }
    if ((Get-ExtProperty $manifest 'name') -ne $ExtName -or (Get-ExtProperty $manifest 'key') -ne $ExtKey) {
        throw "$Dir\manifest.json is not Portly New Tab (another name, or not Portly's extension ID)."
    }
    return $manifest
}

# Renames a folder, retrying while something (an antivirus scan, an Explorer window) still holds
# a file in it.
function Move-ExtFolder {
    param([Parameter(Mandatory)][string]$From, [Parameter(Mandatory)][string]$To)
    for ($attempt = 1; ; $attempt++) {
        try {
            Move-Item -LiteralPath $From -Destination $To -ErrorAction Stop
            return
        } catch {
            if ($attempt -ge 10) {
                throw ("Could not move $From to $To ($($_.Exception.Message)). Close any window or program " +
                    'using a file in that folder and run this again.')
            }
            Start-Sleep -Milliseconds 500
        }
    }
}

function Show-ExtSteps {
    param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][string]$Site)
    Write-ExtStep 'Last step, by hand: load the extension in Chrome or Edge'
    Write-ExtInfo '1. Open chrome://extensions (Edge: edge://extensions).'
    Write-ExtInfo '2. Turn on Developer mode (and leave it on: Chrome runs unpacked extensions only then).'
    Write-ExtInfo "3. Load unpacked -> select $Dir"
    Write-ExtInfo '4. Open a new tab and keep the new tab page the extension set.'
    Write-ExtInfo 'Without Portly on this PC: Details -> Extension options -> New tab opens:'
    Write-ExtInfo "The Pages site, address $Site"
    if ($NoBrowser) { return }
    try { Set-Clipboard -Value $Dir; Write-ExtInfo '(The folder path is on the clipboard.)' } catch { }
    foreach ($browser in @(@{ Exe = 'chrome.exe'; Url = 'chrome://extensions' }, @{ Exe = 'msedge.exe'; Url = 'edge://extensions' })) {
        $key = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$($browser.Exe)"
        try {
            $path = (Get-Item -LiteralPath $key -ErrorAction Stop).GetValue('')
            if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) {
                Start-Process -FilePath $path -ArgumentList $browser.Url
                return
            }
        } catch { }
    }
}

function Invoke-ExtMain {
    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $site = ConvertTo-ExtSiteUrl -Value $SiteUrl
    $dest = [System.IO.Path]::GetFullPath($Destination).TrimEnd('\')
    $staged = "$dest.new"
    $previous = "$dest.previous"
    $release = Join-Path $env:LOCALAPPDATA 'Programs\Portly\app\extension'
    if ([string]::Equals($release, $dest, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$dest belongs to the Portly install on this PC; portly --update keeps it up to date. Pass -Destination with another folder."
    }

    $installed = $null
    if (Test-Path -LiteralPath $dest -PathType Leaf) { throw "$dest is a file, not a folder. Pass -Destination with another folder." }
    if (Test-Path -LiteralPath $dest) {
        $installed = Read-ExtManifest -Dir $dest
        if ($null -eq $installed -and @(Get-ChildItem -LiteralPath $dest -Force).Count -gt 0) {
            throw "$dest is not empty and holds no Portly New Tab. Pass -Destination with another folder."
        }
    }
    $installedVersion = if ($null -ne $installed) { "$(Get-ExtProperty $installed 'version')" } else { $null }

    $work = Join-Path ([System.IO.Path]::GetTempPath()) ('portly-extension-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $work -Force
    try {
        $package = Resolve-ExtPackage -Work $work
        $label = if ($package.Version) { $package.Version } else { 'the zip' }
        if ($null -ne $installedVersion -and $package.Version -eq $installedVersion -and -not $Force) {
            Write-ExtOk "Portly New Tab $installedVersion is already in $dest (-Force replaces it)."
            return 0
        }
        if ($DryRun) {
            $action = if ($null -ne $installedVersion) { "update Portly New Tab $installedVersion to $label" } else { "put Portly New Tab $label" }
            Write-ExtStep "[dry run] Would $action in $dest"
            Write-ExtInfo "Package: $($package.Package)"
            Write-ExtInfo "SHA-256: $(if ($package.Sha256) { $package.Sha256 } else { 'none to check against' })"
            Write-ExtOk 'Dry run finished; nothing was changed.'
            return 0
        }

        $zip = $package.Package
        if (-not $package.Local) {
            Write-ExtStep "Downloading Portly New Tab $label"
            $zip = Join-Path $work $ExtPackageName
            Invoke-ExtDownload -Url $package.Package -OutFile $zip -What 'The extension'
        }
        if ($package.Sha256) {
            $actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($actual -ne $package.Sha256) {
                throw "The zip's SHA-256 is $actual, not $($package.Sha256) as published. Nothing was changed."
            }
            Write-ExtOk 'SHA-256 checked'
        } else {
            Write-Warning "No SHA-256 to check the zip against (no -Sha256 and no $ExtInfoName next to it)."
        }

        Write-ExtStep "Unpacking into $staged"
        $parent = Split-Path -Parent $dest
        if (-not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent -Force }
        if (Test-Path -LiteralPath $staged) { Remove-Item -LiteralPath $staged -Recurse -Force }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $staged)
        $new = $null
        try { $new = Read-ExtManifest -Dir $staged } catch { }
        if ($null -eq $new) {
            Remove-Item -LiteralPath $staged -Recurse -Force
            throw "The zip does not hold Portly New Tab (no manifest.json with Portly's name and extension ID). Nothing was changed."
        }
        $newVersion = "$(Get-ExtProperty $new 'version')"
        if ($package.Version -and $newVersion -ne $package.Version) {
            Remove-Item -LiteralPath $staged -Recurse -Force
            throw "The zip holds version $newVersion, not $($package.Version). Nothing was changed."
        }

        if (Test-Path -LiteralPath $previous) { Remove-Item -LiteralPath $previous -Recurse -Force }
        if (Test-Path -LiteralPath $dest) { Move-ExtFolder -From $dest -To $previous }
        try {
            Move-ExtFolder -From $staged -To $dest
        } catch {
            if (Test-Path -LiteralPath $previous) { Move-ExtFolder -From $previous -To $dest }
            throw
        }
        if (Test-Path -LiteralPath $previous) { Remove-Item -LiteralPath $previous -Recurse -Force -ErrorAction SilentlyContinue }

        if ($null -ne $installedVersion) {
            Write-ExtOk "Updated Portly New Tab $installedVersion -> $newVersion in $dest"
            Write-ExtInfo 'Click Reload on Portly New Tab in chrome://extensions (or edge://extensions).'
            return 0
        }
        Write-ExtOk "Portly New Tab $newVersion is in $dest"
        if (Test-Path -LiteralPath (Join-Path $release 'manifest.json') -PathType Leaf) {
            Write-ExtInfo "Portly is also installed on this PC, with the extension in $release."
            Write-ExtInfo 'Load only one of the two folders: both are the same extension.'
        }
        Show-ExtSteps -Dir $dest -Site $site
        return 0
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$savedOutputEncoding = [Console]::OutputEncoding
$extExitCode = 1
try {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $extExitCode = Invoke-ExtMain | Select-Object -Last 1
} catch {
    Write-ExtFailure $_.Exception.Message
    $extExitCode = 1
} finally {
    try { [Console]::OutputEncoding = $savedOutputEncoding } catch { }
}
# Run as a file: exit with the result. Run with irm | iex: leave the caller's window open.
if ($PSCommandPath) { exit ([int]$extExitCode) }
