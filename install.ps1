<#
.SYNOPSIS
    Installs Portly from a release package, or updates an installed copy. Needs no Git, Node.js,
    npm or administrator rights: the package carries its own Node.js runtime.

.DESCRIPTION
    1. Finds the release: the latest one published in -ReleaseRepo (its portly-release.json names
       the package and its SHA-256), the one named by -Version, or a package already on this PC
       (-ZipPath; checked against -Sha256, or the portly-release.json next to it).
    2. Downloads the package into a temporary folder and checks its SHA-256.
    3. Unpacks it into <InstallDir>\app.new and checks it is a Portly release for Windows x64.
    4. New install: moves it to <InstallDir>\app.
       Update: stops the Portly processes running from <InstallDir>\app (also those running as
       portly-supervisor.exe / portly-server.exe from %LOCALAPPDATA%\Portly\node), copies the database to
       <data folder>\backups\portly-before-<version>-<time>.db, keeps the old version as
       <InstallDir>\app.previous and moves the new one to <InstallDir>\app. If the new version
       does not start, the old one and the database copy are put back and the old one is started
       again (the database the new version left is kept as backups\portly-failed-<version>-<time>.db).
    5. Links node_modules\@portly\shared to the package's shared folder (a junction).
    6. With -PagesUrl: saves the Pages site's address as PORTLY_PAGES_URL (as setup.ps1 does).
    7. Runs app\scripts\install-autostart.ps1 with app\runtime\node.exe (the scheduled task, run as
       copies of that node.exe named portly-supervisor.exe and portly-server.exe, and the launcher
       the new-tab extension uses; starts Portly and waits for it), then
       app\scripts\install-cli.ps1 (the portly command).
    8. New install: shows how to load the new-tab extension from <InstallDir>\app\extension.
       Update: says when the extension changed and needs a Reload.

    Your data (%LOCALAPPDATA%\Portly, or PORTLY_DATA_DIR) is never moved or deleted.
    Self-contained, so it also runs as `irm <url> | iex` before anything is installed; installed
    copies run it for `portly --update`. See docs\setup\releases.md.

.PARAMETER InstallDir
    Where Portly is installed (default %LOCALAPPDATA%\Programs\Portly). The program lives in
    <InstallDir>\app.

.PARAMETER ReleaseRepo
    The public GitHub repository the releases are published in, as owner/name
    (default davideAurum/Portly).

.PARAMETER Version
    Install this published version (for example 0.2.0-alpha.1) instead of the latest one.

.PARAMETER ZipPath
    Install this package (portly-<version>-win-x64.zip) instead of downloading one.

.PARAMETER Sha256
    The SHA-256 the package must have. Without it, -ZipPath is checked against the
    portly-release.json in the same folder when there is one.

.PARAMETER PagesUrl
    The address of your Portly Pages site (saved as PORTLY_PAGES_URL), or 'off' to remove it.
    Without it, the setting is left as it is.

.PARAMETER Trigger
    Passed to install-autostart.ps1: Browser (the extension starts Portly) or Logon. Default: the
    mode the installed task already has, Browser for a new install.

.PARAMETER Force
    Install even when this version is already installed.

.PARAMETER SkipAutostart
    Do not run install-autostart.ps1 (start Portly with app\scripts\start.ps1).

.PARAMETER SkipCli
    Do not install the portly command.

.PARAMETER NoBrowser
    Do not open the browser's extensions page or copy to the clipboard.

.PARAMETER DryRun
    Say which release would be installed and where, and change nothing (nothing is downloaded
    but the small portly-release.json).

.EXAMPLE
    irm https://davideaurum.github.io/install.ps1 | iex

.EXAMPLE
    & ([scriptblock]::Create((irm https://davideaurum.github.io/install.ps1))) -PagesUrl https://me.github.io/

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -ZipPath .\portly-0.2.0-alpha.1-win-x64.zip
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'Programs\Portly'),
    [string]$ReleaseRepo = 'davideAurum/Portly',
    [string]$Version,
    [string]$ZipPath,
    [string]$Sha256,
    [string]$PagesUrl,
    [ValidateSet('Browser', 'Logon')][string]$Trigger = 'Browser',
    [switch]$Force,
    [switch]$SkipAutostart,
    [switch]$SkipCli,
    [switch]$NoBrowser,
    [switch]$DryRun
)

$InstTriggerGiven = $PSBoundParameters.ContainsKey('Trigger')
$InstManifestName = 'portly-release.json'
$InstPlatform = 'win-x64'
$InstTaskName = 'Portly Server'
$InstKeepBackups = 3

function Write-InstStep { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-InstOk { param([string]$Message) Write-Host "OK  $Message" -ForegroundColor Green }
function Write-InstInfo { param([string]$Message = '') Write-Host "    $Message" }
function Write-InstFailure { param([string]$Message) Write-Host "ERROR: $Message" -ForegroundColor Red }

function Get-InstProperty {
    param($Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Read-InstJson {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        return [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json
    } catch {
        throw "$Path is not valid JSON: $($_.Exception.Message)"
    }
}

# The release.json a package carries at its root, or $null when $Dir holds none.
function Read-InstRelease {
    param([Parameter(Mandatory)][string]$Dir)
    $info = Read-InstJson -Path (Join-Path $Dir 'release.json')
    if ($null -eq $info) { return $null }
    if ((Get-InstProperty $info 'name') -ne 'portly' -or "$(Get-InstProperty $info 'version')" -eq '') {
        throw "$Dir\release.json does not describe a Portly release."
    }
    return $info
}

# Version strings as published: 1.2.3 with an optional -prerelease (letters, digits, dots, dashes).
function Test-InstVersion {
    param([string]$Value)
    return $Value -match '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'
}

function Get-InstSha256 {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Invoke-InstDownload {
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
        if ($status -eq 404) { throw "$What was not found ($Url)." }
        throw "Could not download $What from $Url : $($_.Exception.Message)"
    } finally {
        $ProgressPreference = $previousProgress
    }
}

# Which package to install: Version (null when unknown until unpacked), Package (path or URL),
# Sha256 (null when there is nothing to check against), Local (true for -ZipPath).
function Resolve-InstRelease {
    param([Parameter(Mandatory)][string]$Work)
    $expectedHash = if ([string]::IsNullOrWhiteSpace($Sha256)) { $null } else { $Sha256.Trim().ToLowerInvariant() }
    if ($null -ne $expectedHash -and $expectedHash -notmatch '^[0-9a-f]{64}$') {
        throw "-Sha256 must be 64 hexadecimal characters (got '$Sha256')."
    }
    if (-not [string]::IsNullOrWhiteSpace($ZipPath)) {
        if (-not (Test-Path -LiteralPath $ZipPath -PathType Leaf)) { throw "-ZipPath: $ZipPath does not exist." }
        $zip = (Resolve-Path -LiteralPath $ZipPath).ProviderPath
        $version = $null
        $manifest = Read-InstJson -Path (Join-Path (Split-Path -Parent $zip) $InstManifestName)
        if ($null -ne $manifest -and "$(Get-InstProperty $manifest 'package')" -ieq [System.IO.Path]::GetFileName($zip)) {
            $version = "$(Get-InstProperty $manifest 'version')"
            if ($null -eq $expectedHash) { $expectedHash = "$(Get-InstProperty $manifest 'sha256')".ToLowerInvariant() }
        }
        return [pscustomobject]@{ Version = $version; Package = $zip; Sha256 = $expectedHash; Local = $true }
    }
    if ($ReleaseRepo -notmatch '^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$') { throw "-ReleaseRepo must be owner/name (got '$ReleaseRepo')." }
    if (-not [string]::IsNullOrWhiteSpace($Version) -and -not (Test-InstVersion $Version)) {
        throw "-Version must look like 0.2.0 or 0.2.0-alpha.1 (got '$Version')."
    }
    $base = "https://github.com/$ReleaseRepo/releases"
    $manifestUrl = if ([string]::IsNullOrWhiteSpace($Version)) { "$base/latest/download/$InstManifestName" } else { "$base/download/v$Version/$InstManifestName" }
    $what = if ([string]::IsNullOrWhiteSpace($Version)) { "The latest release of $ReleaseRepo" } else { "Release $Version of $ReleaseRepo" }
    $manifestPath = Join-Path $Work $InstManifestName
    Invoke-InstDownload -Url $manifestUrl -OutFile $manifestPath -What $what
    $manifest = Read-InstJson -Path $manifestPath
    $version = "$(Get-InstProperty $manifest 'version')"
    $package = "$(Get-InstProperty $manifest 'package')"
    $hash = "$(Get-InstProperty $manifest 'sha256')".ToLowerInvariant()
    if ((Get-InstProperty $manifest 'name') -ne 'portly' -or (Get-InstProperty $manifest 'platform') -ne $InstPlatform -or
        -not (Test-InstVersion $version) -or $package -notmatch '^portly-[0-9A-Za-z.-]+-win-x64\.zip$' -or $hash -notmatch '^[0-9a-f]{64}$') {
        throw "$manifestUrl is not a valid Portly release description."
    }
    if (-not [string]::IsNullOrWhiteSpace($Version) -and $version -ne $Version) {
        throw "$manifestUrl describes version $version, not $Version."
    }
    if ($null -ne $expectedHash -and $expectedHash -ne $hash) {
        throw "-Sha256 does not match the SHA-256 published for $version."
    }
    return [pscustomobject]@{ Version = $version; Package = "$base/download/v$version/$package"; Sha256 = $hash; Local = $false }
}

# The attributes of the entry itself (links are not followed), or $null when there is none.
function Get-InstAttributes {
    param([Parameter(Mandatory)][string]$Path)
    try { return [System.IO.File]::GetAttributes($Path) } catch { return $null }
}

# Removes the junctions under node_modules\@portly (never what they point to), so the folder
# can be moved or deleted without touching another copy's files.
function Remove-InstLinks {
    param([Parameter(Mandatory)][string]$AppDir)
    $scope = Join-Path $AppDir 'node_modules\@portly'
    if ($null -eq (Get-InstAttributes -Path $scope)) { return }
    foreach ($entry in @([System.IO.Directory]::GetFileSystemEntries($scope))) {
        $attributes = Get-InstAttributes -Path $entry
        if ($null -ne $attributes -and ($attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            [System.IO.Directory]::Delete($entry)
        }
    }
}

# node_modules\@portly\shared -> <AppDir>\shared (Common.ps1 Initialize-HbReleaseLinks does the
# same for the scripts in the package).
function Initialize-InstLinks {
    param([Parameter(Mandatory)][string]$AppDir)
    Remove-InstLinks -AppDir $AppDir
    $scope = Join-Path $AppDir 'node_modules\@portly'
    if (-not (Test-Path -LiteralPath $scope)) { $null = New-Item -ItemType Directory -Path $scope -Force }
    $null = New-Item -ItemType Junction -Path (Join-Path $scope 'shared') -Target (Join-Path $AppDir 'shared')
}

function Remove-InstAppFolder {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    Remove-InstLinks -AppDir $Path
    Remove-Item -LiteralPath $Path -Recurse -Force
}

# Renames a folder, retrying while something (an antivirus scan, an Explorer window) still holds
# a file in it.
function Move-InstFolder {
    param([Parameter(Mandatory)][string]$From, [Parameter(Mandatory)][string]$To)
    for ($attempt = 1; ; $attempt++) {
        try {
            Move-Item -LiteralPath $From -Destination $To -ErrorAction Stop
            return
        } catch {
            if ($attempt -ge 10) {
                throw ("Could not move $From to $To ($($_.Exception.Message)). Close any window, terminal or program " +
                    'using a file in that folder and run this again.')
            }
            Start-Sleep -Milliseconds 500
        }
    }
}

# Every process whose program lives under $AppDir (the bundled node.exe: supervisor, server and
# its workers), and every one of Portly's named copies of it (portly-supervisor.exe,
# portly-server.exe in %LOCALAPPDATA%\Portly\node) whose command line names a file under $AppDir,
# stopped and waited for. Returns how many there were.
function Stop-InstAppProcesses {
    param([Parameter(Mandatory)][string]$AppDir)
    $prefix = $AppDir.TrimEnd('\') + '\'
    $copies = (Join-Path $env:LOCALAPPDATA 'Portly\node').TrimEnd('\') + '\'
    $processes = @(Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue | Where-Object {
            $_.ExecutablePath -and ($_.ExecutablePath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase) -or
                ($_.ExecutablePath.StartsWith($copies, [System.StringComparison]::OrdinalIgnoreCase) -and
                "$($_.CommandLine)".IndexOf($prefix, [System.StringComparison]::OrdinalIgnoreCase) -ge 0))
        })
    foreach ($process in $processes) {
        try { Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop } catch { }
    }
    foreach ($process in $processes) {
        try { Wait-Process -Id $process.ProcessId -Timeout 10 -ErrorAction SilentlyContinue } catch { }
    }
    return $processes.Count
}

# The Portly Server task: whether it exists, whether it runs this copy (its action names
# <AppDir>\server\src\supervisor.ts) and its mode (a logon trigger or none).
function Get-InstTask {
    param([Parameter(Mandatory)][string]$AppDir)
    $task = $null
    try { $task = Get-ScheduledTask -TaskName $InstTaskName -TaskPath '\' -ErrorAction Stop | Select-Object -First 1 } catch { }
    if ($null -eq $task) { return [pscustomobject]@{ Exists = $false; Ours = $false; Mode = 'Browser'; Runs = '' } }
    $needle = (Join-Path $AppDir 'server\src\supervisor.ts').ToLowerInvariant()
    $arguments = (@($task.Actions) | ForEach-Object { "$($_.Arguments)" }) -join ' '
    $mode = if (@(@($task.Triggers) | Where-Object { $null -ne $_ }).Count -gt 0) { 'Logon' } else { 'Browser' }
    return [pscustomobject]@{ Exists = $true; Ours = $arguments.ToLowerInvariant().Contains($needle); Mode = $mode; Runs = $arguments }
}

# Where the server keeps its data: PORTLY_DATA_DIR (this process, then the user's and the PC's
# setting), else %LOCALAPPDATA%\Portly. $null for a relative setting (resolved by the server).
function Get-InstDataDir {
    foreach ($scope in @('Process', 'User', 'Machine')) {
        $value = [System.Environment]::GetEnvironmentVariable('PORTLY_DATA_DIR', $scope)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $value = $value.Trim()
            if ([System.IO.Path]::IsPathRooted($value)) { return $value }
            return $null
        }
    }
    return (Join-Path $env:LOCALAPPDATA 'Portly')
}

# Copies portly.db (and its -wal/-shm files) into backups\ while Portly is stopped, and keeps
# the newest $InstKeepBackups of these copies. Returns the copy's path, or $null.
function Backup-InstDatabase {
    param([Parameter(Mandatory)][string]$Label)
    $dataDir = Get-InstDataDir
    if ($null -eq $dataDir) {
        Write-Warning 'PORTLY_DATA_DIR is a relative path; no database copy was made before the update.'
        return $null
    }
    $db = Join-Path $dataDir 'portly.db'
    if (-not (Test-Path -LiteralPath $db -PathType Leaf)) { return $null }
    $backups = Join-Path $dataDir 'backups'
    if (-not (Test-Path -LiteralPath $backups)) { $null = New-Item -ItemType Directory -Path $backups -Force }
    $name = "portly-before-$Label-$((Get-Date).ToString('yyyyMMdd-HHmmss')).db"
    $copy = Join-Path $backups $name
    Copy-Item -LiteralPath $db -Destination $copy
    foreach ($suffix in @('-wal', '-shm')) {
        if (Test-Path -LiteralPath "$db$suffix" -PathType Leaf) { Copy-Item -LiteralPath "$db$suffix" -Destination "$copy$suffix" }
    }
    Remove-InstOldBackups -Dir $backups -Filter 'portly-before-*.db'
    return $copy
}

# Keeps the newest $InstKeepBackups database copies matching -Filter (with their -wal/-shm files).
function Remove-InstOldBackups {
    param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][string]$Filter)
    $old = @(Get-ChildItem -LiteralPath $Dir -Filter $Filter -File | Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -Skip $InstKeepBackups)
    foreach ($file in $old) {
        foreach ($path in @($file.FullName, "$($file.FullName)-wal", "$($file.FullName)-shm")) {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
        }
    }
}

# After a failed update, puts the copy Backup-InstDatabase made back as portly.db, so the previous
# version opens the data it left (the new version may already have changed it). The database the
# failed version left is kept as backups\portly-failed-<Label>-<time>.db. Portly must be stopped.
# Returns that copy's path ($null when there was no database to keep).
function Restore-InstDatabase {
    param([Parameter(Mandatory)][string]$Backup, [Parameter(Mandatory)][string]$Label)
    $backups = Split-Path -Parent $Backup
    $db = Join-Path (Split-Path -Parent $backups) 'portly.db'
    $kept = $null
    if (Test-Path -LiteralPath $db -PathType Leaf) {
        $kept = Join-Path $backups "portly-failed-$Label-$((Get-Date).ToString('yyyyMMdd-HHmmss')).db"
        Move-Item -LiteralPath $db -Destination $kept
    }
    foreach ($suffix in @('-wal', '-shm')) {
        if (Test-Path -LiteralPath "$db$suffix" -PathType Leaf) {
            if ($null -ne $kept) { Move-Item -LiteralPath "$db$suffix" -Destination "$kept$suffix" } else { Remove-Item -LiteralPath "$db$suffix" -Force }
        }
    }
    Copy-Item -LiteralPath $Backup -Destination $db
    foreach ($suffix in @('-wal', '-shm')) {
        if (Test-Path -LiteralPath "$Backup$suffix" -PathType Leaf) { Copy-Item -LiteralPath "$Backup$suffix" -Destination "$db$suffix" }
    }
    Remove-InstOldBackups -Dir $backups -Filter 'portly-failed-*.db'
    return $kept
}

# The -PagesUrl address normalised by the rules server/src/config.ts applies (as setup.ps1).
function ConvertTo-InstPagesUrl {
    param([Parameter(Mandatory)][string]$Value)
    $text = $Value.Trim()
    $uri = $null
    $usage = "-PagesUrl must be the Pages site's full address, like https://<user>.github.io/, or 'off' (got '$Value')."
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

function Set-InstPagesUrl {
    if ([string]::IsNullOrWhiteSpace($PagesUrl)) { return }
    $name = 'PORTLY_PAGES_URL'
    if ($PagesUrl.Trim() -eq 'off') {
        Write-InstStep "Pages site off: removing the user environment variable $name"
        [System.Environment]::SetEnvironmentVariable($name, $null, 'User')
        Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
        return
    }
    $url = ConvertTo-InstPagesUrl -Value $PagesUrl
    Write-InstStep "Pages site: setting the user environment variable $name = $url"
    [System.Environment]::SetEnvironmentVariable($name, $url, 'User')
    Set-Item -LiteralPath "Env:$name" -Value $url
}

# Runs a script of the installed package in its own PowerShell process; returns its exit code.
function Invoke-InstScript {
    param([Parameter(Mandatory)][string]$AppDir, [Parameter(Mandatory)][string]$Script, [string[]]$Arguments = @())
    $powershell = (Get-Process -Id $PID).Path
    & $powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $AppDir "scripts\$Script") @Arguments | Out-Host
    return $LASTEXITCODE
}

function Invoke-InstAutostart {
    param([Parameter(Mandatory)][string]$AppDir, [Parameter(Mandatory)][string]$Mode)
    Write-InstStep "Autostart: scripts\install-autostart.ps1 -Trigger $Mode"
    $node = Join-Path $AppDir 'runtime\node.exe'
    return (Invoke-InstScript -AppDir $AppDir -Script 'install-autostart.ps1' -Arguments @('-Trigger', $Mode, '-NodePath', $node))
}

function Show-InstExtensionSteps {
    param([Parameter(Mandatory)][string]$AppDir)
    $extension = Join-Path $AppDir 'extension'
    Write-InstStep 'Last step, by hand: load the new-tab extension in Chrome or Edge'
    Write-InstInfo '1. Open chrome://extensions (Edge: edge://extensions).'
    Write-InstInfo '2. Turn on Developer mode.'
    Write-InstInfo "3. Load unpacked -> select $extension"
    Write-InstInfo "Details: $AppDir\docs\setup\extension.md"
    if ($NoBrowser) { return }
    try { Set-Clipboard -Value $extension; Write-InstInfo '(The folder path is on the clipboard.)' } catch { }
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

# Checks an unpacked package and returns its release.json.
function Test-InstPackage {
    param([Parameter(Mandatory)][string]$Dir, [string]$ExpectedVersion)
    $info = Read-InstRelease -Dir $Dir
    if ($null -eq $info) { throw 'The package has no release.json: it is not a Portly release package.' }
    if ((Get-InstProperty $info 'platform') -ne $InstPlatform) {
        throw "The package is for $(Get-InstProperty $info 'platform'), not $InstPlatform."
    }
    if ($ExpectedVersion -and "$(Get-InstProperty $info 'version')" -ne $ExpectedVersion) {
        throw "The package contains version $(Get-InstProperty $info 'version'), not $ExpectedVersion."
    }
    foreach ($required in @('runtime\node.exe', 'server\src\supervisor.ts', 'shared\package.json', 'web\dist\index.html',
            'extension\manifest.json', 'scripts\install-autostart.ps1', 'scripts\lib\Common.ps1', 'node_modules\hono\package.json')) {
        if (-not (Test-Path -LiteralPath (Join-Path $Dir $required) -PathType Leaf)) { throw "The package is incomplete: $required is missing." }
    }
    return $info
}

# Puts the previous version and the database copied before the update back after a failed
# update, and starts it again when the task runs it.
function Restore-InstPrevious {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)]$Task, [Parameter(Mandatory)][string]$Mode,
        [string]$Backup, [Parameter(Mandatory)][string]$Label)
    $app = Join-Path $Root 'app'
    $previous = Join-Path $Root 'app.previous'
    $failed = Join-Path $Root 'app.failed'
    Write-InstStep 'Putting the previous version back'
    $null = Stop-InstAppProcesses -AppDir $app
    if (-not [string]::IsNullOrEmpty($Backup)) {
        try {
            $kept = Restore-InstDatabase -Backup $Backup -Label $Label
            Write-InstOk "The database copied before the update is back (from $Backup)."
            if ($null -ne $kept) { Write-InstInfo "The database Portly $Label left is kept in $kept" }
        } catch {
            Write-Warning "Could not put the database copied before the update back: $($_.Exception.Message). It is in $Backup."
        }
    }
    Remove-InstAppFolder -Path $failed
    if (Test-Path -LiteralPath $app) {
        Remove-InstLinks -AppDir $app
        Move-InstFolder -From $app -To $failed
    }
    Move-InstFolder -From $previous -To $app
    Initialize-InstLinks -AppDir $app
    if ($Task.Ours -and -not $SkipAutostart) {
        if ((Invoke-InstAutostart -AppDir $app -Mode $Mode) -ne 0) {
            Write-InstFailure 'The previous version did not start either; see the output above (portly --status --logs).'
            return
        }
    }
    Write-InstOk "The previous version is back in $app (the new one is in $failed)."
}

function Invoke-InstMain {
    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
        throw 'Portly runs on Windows (DPAPI vault, Task Scheduler).'
    }
    $root = [System.IO.Path]::GetFullPath($InstallDir)
    $app = Join-Path $root 'app'
    $staged = Join-Path $root 'app.new'
    $previous = Join-Path $root 'app.previous'
    if (-not [string]::IsNullOrWhiteSpace($PagesUrl) -and $PagesUrl.Trim() -ne 'off') { $null = ConvertTo-InstPagesUrl -Value $PagesUrl }
    $installed = Read-InstRelease -Dir $app
    if ($null -eq $installed -and (Test-Path -LiteralPath $app)) {
        throw "$app exists but is not a Portly release install. Pass -InstallDir with another folder."
    }
    $installedVersion = if ($null -ne $installed) { "$($installed.version)" } else { $null }

    $work = Join-Path ([System.IO.Path]::GetTempPath()) ('portly-install-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $work -Force
    try {
        $release = Resolve-InstRelease -Work $work
        $label = if ($release.Version) { $release.Version } else { 'the package' }
        if ($null -ne $installedVersion -and $release.Version -eq $installedVersion -and -not $Force) {
            Write-InstOk "Portly $installedVersion is already installed in $app (-Force reinstalls it)."
            return 0
        }
        if ($DryRun) {
            $action = if ($null -ne $installedVersion) { "update Portly $installedVersion to $label" } else { "install Portly $label" }
            Write-InstStep "[dry run] Would $action in $app"
            Write-InstInfo "Package: $($release.Package)"
            Write-InstInfo "SHA-256: $(if ($release.Sha256) { $release.Sha256 } else { 'none to check against' })"
            Write-InstOk 'Dry run finished; nothing was changed.'
            return 0
        }

        $zip = $release.Package
        if (-not $release.Local) {
            Write-InstStep "Downloading Portly $label"
            $zip = Join-Path $work ([System.IO.Path]::GetFileName($release.Package))
            Invoke-InstDownload -Url $release.Package -OutFile $zip -What "The package of release $label"
        }
        if ($release.Sha256) {
            $actual = Get-InstSha256 -Path $zip
            if ($actual -ne $release.Sha256) {
                throw "The package's SHA-256 is $actual, not $($release.Sha256) as published. Nothing was installed."
            }
            Write-InstOk 'SHA-256 checked'
        } else {
            Write-Warning 'No SHA-256 to check the package against (no -Sha256 and no portly-release.json next to it).'
        }

        Write-InstStep "Unpacking into $staged"
        if (-not (Test-Path -LiteralPath $root)) { $null = New-Item -ItemType Directory -Path $root -Force }
        Remove-InstAppFolder -Path $staged
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $staged)
        $new = Test-InstPackage -Dir $staged -ExpectedVersion $release.Version
        $newVersion = "$($new.version)"
        if ($null -ne $installedVersion -and $newVersion -eq $installedVersion -and -not $Force) {
            Remove-InstAppFolder -Path $staged
            Write-InstOk "Portly $installedVersion is already installed in $app (-Force reinstalls it)."
            return 0
        }

        if ($null -eq $installed) {
            Move-InstFolder -From $staged -To $app
            Initialize-InstLinks -AppDir $app
            Write-InstOk "Portly $newVersion is in $app"
            Set-InstPagesUrl
            $failed = @()
            $mode = if ($InstTriggerGiven) { $Trigger } else { 'Browser' }
            if (-not $SkipAutostart -and (Invoke-InstAutostart -AppDir $app -Mode $mode) -ne 0) { $failed += 'install-autostart.ps1' }
            if (-not $SkipCli) {
                Write-InstStep 'The portly command: scripts\install-cli.ps1'
                if ((Invoke-InstScript -AppDir $app -Script 'install-cli.ps1') -ne 0) { $failed += 'install-cli.ps1' }
            }
            Show-InstExtensionSteps -AppDir $app
            if ($failed.Count -gt 0) {
                Write-InstFailure "Portly is installed, but $($failed -join ' and ') failed (see above). Fix that and run this again."
                return 1
            }
            Write-InstOk 'Portly is installed: http://localhost:5757'
            Write-InstInfo 'Then connect your accounts in Settings. Open a new terminal to use the portly command.'
            return 0
        }

        # Update.
        $task = Get-InstTask -AppDir $app
        $mode = if ($InstTriggerGiven) { $Trigger } else { $task.Mode }
        Write-InstStep "Updating Portly $installedVersion to $newVersion"
        if ($task.Ours) { try { Stop-ScheduledTask -TaskName $InstTaskName -TaskPath '\' -ErrorAction Stop } catch { } }
        $stopped = Stop-InstAppProcesses -AppDir $app
        if ($stopped -gt 0) { Write-InstInfo "Stopped $stopped Portly process(es)." }
        $backup = Backup-InstDatabase -Label $installedVersion
        if ($null -ne $backup) { Write-InstInfo "Database copied to $backup" }
        Remove-InstAppFolder -Path $previous
        Remove-InstLinks -AppDir $app
        try {
            Move-InstFolder -From $app -To $previous
        } catch {
            Initialize-InstLinks -AppDir $app
            if ($task.Ours) { try { Start-ScheduledTask -TaskName $InstTaskName -TaskPath '\' } catch { } }
            throw
        }
        try {
            Move-InstFolder -From $staged -To $app
        } catch {
            Move-InstFolder -From $previous -To $app
            Initialize-InstLinks -AppDir $app
            if ($task.Ours) { try { Start-ScheduledTask -TaskName $InstTaskName -TaskPath '\' } catch { } }
            throw
        }
        Initialize-InstLinks -AppDir $app
        Set-InstPagesUrl

        if (-not $SkipAutostart) {
            if ($task.Ours -or -not $task.Exists) {
                if ((Invoke-InstAutostart -AppDir $app -Mode $mode) -ne 0) {
                    Write-InstFailure "Portly $newVersion did not start (see above)."
                    Restore-InstPrevious -Root $root -Task $task -Mode $mode -Backup $backup -Label $newVersion
                    return 1
                }
            } else {
                Write-Warning ("The '$InstTaskName' task runs another copy of Portly ($($task.Runs)). To let it run this one, " +
                    "run: powershell -NoProfile -ExecutionPolicy Bypass -File ""$app\scripts\install-autostart.ps1""")
            }
        }
        if (-not $SkipCli) {
            Write-InstStep 'The portly command: scripts\install-cli.ps1'
            if ((Invoke-InstScript -AppDir $app -Script 'install-cli.ps1') -ne 0) { Write-Warning 'install-cli.ps1 failed (see above).' }
        }
        $oldExtension = "$(Get-InstProperty $installed 'extensionVersion')"
        $newExtension = "$(Get-InstProperty $new 'extensionVersion')"
        if ($oldExtension -ne $newExtension) {
            Write-InstStep "The new-tab extension changed ($oldExtension -> $newExtension)"
            Write-InstInfo 'Click Reload on Portly New Tab in chrome://extensions (or edge://extensions).'
        }
        Write-InstOk "Updated Portly $installedVersion -> $newVersion. The previous version is kept in $previous."
        return 0
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$savedOutputEncoding = [Console]::OutputEncoding
$installExitCode = 1
try {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $installExitCode = Invoke-InstMain | Select-Object -Last 1
} catch {
    Write-InstFailure $_.Exception.Message
    $installExitCode = 1
} finally {
    try { [Console]::OutputEncoding = $savedOutputEncoding } catch { }
}
# Run as a file: exit with the result. Run with irm | iex: leave the caller's window open.
if ($PSCommandPath) { exit ([int]$installExitCode) }
