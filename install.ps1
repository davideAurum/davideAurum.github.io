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
       Update: disables the Portly Server task while the folders are swapped (so a Portly tab cannot
       start the old copy again), stops the Portly processes running from <InstallDir>\app (also those
       running as portly-supervisor.exe / portly-server.exe from %LOCALAPPDATA%\Portly\node), copies the database to
       <data folder>\backups\portly-before-<version>-<time>.db, keeps the old version as
       <InstallDir>\app.previous and moves the new one to <InstallDir>\app. If the new version
       does not start, the old one and the database copy are put back and the old one is started
       again (the database the new version left is kept as backups\portly-failed-<version>-<time>.db).
       Each folder is renamed in one step: if a file in it is in use, nothing moves and the old
       version is started again.
    5. Links node_modules\@portly\shared to the package's shared folder (a junction).
    6. With -PagesUrl: saves the Pages site's address as PORTLY_PAGES_URL (as setup.ps1 does).
    7. Runs app\scripts\install-autostart.ps1 with app\runtime\node.exe (the scheduled task, run as
       copies of that node.exe named portly-supervisor.exe and portly-server.exe, and the launcher
       the new-tab extension uses; starts Portly and waits for it), then
       app\scripts\install-cli.ps1 (the portly command).
    8. New install: shows how to load the new-tab extension from <InstallDir>\app\extension.
       Update: says when the extension changed and needs a Reload.

    With -OnlyNewer -StatusFile (portly --update --unattended, run by the Portly Updater task), only
    a newer version is installed and each stage goes into the status file, in closed values only,
    because that file reaches other PCs (docs\design\update-button.md section 13). One install runs
    at a time.

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

.PARAMETER OnlyNewer
    Install only a version newer than the installed one: anything else stops before changing
    anything, -Force included.

.PARAMETER StatusFile
    Report how the update goes in this file (the server's update-status.json). A `requested` run
    the server left there is carried on; otherwise a new run starts. Downloads get a time limit.

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
    [switch]$OnlyNewer,
    [string]$StatusFile,
    [switch]$DryRun
)

$InstTriggerGiven = $PSBoundParameters.ContainsKey('Trigger')
$InstManifestName = 'portly-release.json'
$InstPlatform = 'win-x64'
$InstTaskName = 'Portly Server'
$InstKeepBackups = 3
$InstMoveAttempts = 20
# With nobody watching, a download may not hang. The Portly Updater task's own limit is 15 minutes.
$InstUnattendedTimeoutSeconds = 600
# The run being reported in -StatusFile, and the code a failure from here on would report.
$script:InstRun = $null
$script:InstFailCode = 'unknown'

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
    $timeout = if ([string]::IsNullOrWhiteSpace($StatusFile)) { 0 } else { $InstUnattendedTimeoutSeconds }
    try {
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec $timeout -ErrorAction Stop
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

# Renames a folder in one step, retrying for up to 10 s while something (an antivirus scan, an
# Explorer window) still holds a file in it. Directory.Move is all or nothing; Windows PowerShell
# 5.1's Move-Item instead falls back to moving the files one by one and stops at the first one in
# use, leaving the folder split in two.
function Move-InstFolder {
    param([Parameter(Mandatory)][string]$From, [Parameter(Mandatory)][string]$To)
    for ($attempt = 1; ; $attempt++) {
        try {
            [System.IO.Directory]::Move($From, $To)
            return
        } catch {
            if ($attempt -ge $InstMoveAttempts) {
                $reason = if ($null -ne $_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
                throw ("Could not move $From to $To ($reason). Close any window, terminal or program " +
                    'using a file in that folder and run this again.')
            }
            Start-Sleep -Milliseconds 500
        }
    }
}

# Enables or disables the Portly Server task; returns whether that worked. While it is disabled, a
# Portly tab that finds the server gone cannot have the launcher start it again.
function Set-InstTaskEnabled {
    param([bool]$Enabled)
    try {
        if ($Enabled) {
            $null = Enable-ScheduledTask -TaskName $InstTaskName -TaskPath '\' -ErrorAction Stop
        } else {
            $null = Disable-ScheduledTask -TaskName $InstTaskName -TaskPath '\' -ErrorAction Stop
        }
        return $true
    } catch {
        $verb = if ($Enabled) { 'enable' } else { 'disable' }
        Write-Warning "Could not $verb the '$InstTaskName' task: $($_.Exception.Message)"
        return $false
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
# update, and starts it again when the task runs it. Returns whether it came back.
function Restore-InstPrevious {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)]$Task, [Parameter(Mandatory)][string]$Mode,
        [string]$Backup, [Parameter(Mandatory)][string]$Label)
    $app = Join-Path $Root 'app'
    $previous = Join-Path $Root 'app.previous'
    $failed = Join-Path $Root 'app.failed'
    Write-InstStep 'Putting the previous version back'
    $taskDisabled = $Task.Ours -and (Set-InstTaskEnabled -Enabled $false)
    if ($Task.Ours) { try { Stop-ScheduledTask -TaskName $InstTaskName -TaskPath '\' -ErrorAction Stop } catch { } }
    try {
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
    } finally {
        if ($taskDisabled) { $null = Set-InstTaskEnabled -Enabled $true }
    }
    if ($Task.Ours -and -not $SkipAutostart) {
        if ((Invoke-InstAutostart -AppDir $app -Mode $Mode) -ne 0) {
            Write-InstFailure 'The previous version did not start either; see the output above (portly --status --logs).'
            return $false
        }
    }
    Write-InstOk "The previous version is back in $app (the new one is in $failed)."
    return $true
}

# One part of a version: a whole number without leading zeros that a JavaScript number holds
# exactly, as shared/src/version.ts reads it, else $null.
function ConvertTo-InstVersionNumber {
    param([Parameter(Mandatory)][string]$Text)
    if ($Text.Length -gt 1 -and $Text.StartsWith('0', [System.StringComparison]::Ordinal)) { return $null }
    $value = [long]0
    if (-not [long]::TryParse($Text, [ref]$value) -or $value -gt 9007199254740991) { return $null }
    return $value
}

# A version's parts, or $null for anything shared/src/version.ts would not read.
function ConvertTo-InstVersion {
    param([AllowEmptyString()][string]$Text)
    if ($Text.Length -gt 40) { return $null }
    $match = [regex]::Match($Text, '^([0-9]+)\.([0-9]+)\.([0-9]+)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?\z')
    if (-not $match.Success) { return $null }
    $core = New-Object System.Collections.Generic.List[long]
    foreach ($group in 1..3) {
        $number = ConvertTo-InstVersionNumber -Text $match.Groups[$group].Value
        if ($null -eq $number) { return $null }
        $core.Add($number)
    }
    $prerelease = New-Object System.Collections.Generic.List[object]
    if ($match.Groups[4].Success) {
        foreach ($part in $match.Groups[4].Value.Split('.')) {
            $identifier = $part
            if ($part -match '^[0-9]+$') {
                $identifier = ConvertTo-InstVersionNumber -Text $part
                if ($null -eq $identifier) { return $null }
            }
            $prerelease.Add($identifier)
        }
    }
    return [pscustomobject]@{ Core = $core.ToArray(); Prerelease = $prerelease.ToArray() }
}

# Portly's version order, a port of compareVersions in shared/src/version.ts (this script is
# self-contained), with the table shared/src/__fixtures__/version-order.json for both: negative
# when $One is older than $Other, positive when newer, 0 when they rank the same, $null when either
# can't be read. Words compare ordinally: -lt on strings follows the culture and ignores case.
function Compare-InstVersion {
    param([AllowEmptyString()][string]$One, [AllowEmptyString()][string]$Other)
    $first = ConvertTo-InstVersion -Text $One
    $second = ConvertTo-InstVersion -Text $Other
    if ($null -eq $first -or $null -eq $second) { return $null }
    for ($i = 0; $i -lt 3; $i++) {
        if ($first.Core[$i] -lt $second.Core[$i]) { return -1 }
        if ($first.Core[$i] -gt $second.Core[$i]) { return 1 }
    }
    $firstPre = $first.Prerelease
    $secondPre = $second.Prerelease
    # A release is newer than its own prereleases.
    if ($firstPre.Length -eq 0 -or $secondPre.Length -eq 0) { return $secondPre.Length - $firstPre.Length }
    for ($i = 0; $i -lt $firstPre.Length; $i++) {
        if ($i -ge $secondPre.Length) { return 1 }
        $left = $firstPre[$i]
        $right = $secondPre[$i]
        $leftNumber = $left -is [long]
        $rightNumber = $right -is [long]
        if ($leftNumber -and $rightNumber) {
            if ($left -lt $right) { return -1 }
            if ($left -gt $right) { return 1 }
            continue
        }
        # Numbers sort before words.
        if ($leftNumber) { return -1 }
        if ($rightNumber) { return 1 }
        $order = [string]::CompareOrdinal($left, $right)
        if ($order -ne 0) { return $order }
    }
    return $firstPre.Length - $secondPre.Length
}

# True only when $Candidate is certainly newer: a version that can't be read never is.
function Test-InstNewer {
    param([AllowEmptyString()][string]$Candidate, [AllowEmptyString()][string]$Than)
    $order = Compare-InstVersion -One $Candidate -Other $Than
    return $null -ne $order -and $order -gt 0
}

# With -OnlyNewer, stops unless $Candidate is newer than what is installed.
function Assert-InstNewer {
    param([string]$Candidate, [string]$Installed)
    if (-not $OnlyNewer -or -not $Candidate -or -not $Installed) { return }
    if (Test-InstNewer -Candidate $Candidate -Than $Installed) { return }
    Set-InstRun -FailCode 'not_newer'
    throw "Portly $Candidate is not newer than the installed $Installed, so nothing was changed."
}

function Get-InstUtcStamp {
    return [System.DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
}

# The `requested` run the server left in -StatusFile, or $null. PowerShell 7 reads the date as a
# date, Windows PowerShell as text.
function Read-InstRequestedRun {
    if ([string]::IsNullOrWhiteSpace($StatusFile)) { return $null }
    $file = $null
    try { $file = Read-InstJson -Path $StatusFile } catch { return $null }
    if ($null -eq $file -or (Get-InstProperty $file 'state') -ne 'requested') { return $null }
    $started = Get-InstProperty $file 'startedAt'
    if ($started -is [datetime]) {
        $started = $started.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
    }
    $id = "$(Get-InstProperty $file 'id')"
    $from = "$(Get-InstProperty $file 'from')"
    if ($id -notmatch '^[0-9A-Za-z-]{1,64}$' -or -not (Test-InstVersion $from) -or
        "$started" -notmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$') {
        return $null
    }
    return [pscustomobject]@{ Id = $id; From = $from; StartedAt = "$started" }
}

# Starts reporting: the server's `requested` run, or a new one when an install was named.
function Initialize-InstRun {
    param([string]$InstalledVersion)
    if ([string]::IsNullOrWhiteSpace($StatusFile) -or $DryRun) { return }
    $requested = Read-InstRequestedRun
    if ($null -eq $requested -and -not $InstalledVersion) { return }
    $script:InstRun = [ordered]@{
        id               = if ($null -ne $requested) { $requested.Id } else { [guid]::NewGuid().ToString() }
        state            = 'requested'
        from             = if ($null -ne $requested) { $requested.From } else { $InstalledVersion }
        to               = $null
        startedAt        = if ($null -ne $requested) { $requested.StartedAt } else { Get-InstUtcStamp }
        finishedAt       = $null
        code             = $null
        extensionChanged = $false
    }
}

# Replaces -StatusFile in one step. A report that cannot be written never stops an update.
function Write-InstRun {
    if ($null -eq $script:InstRun) { return }
    $temp = "$StatusFile.$([guid]::NewGuid().ToString('N')).new"
    try {
        [System.IO.File]::WriteAllText($temp, ($script:InstRun | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding($false)))
        for ($attempt = 1; ; $attempt++) {
            try {
                if (Test-Path -LiteralPath $StatusFile -PathType Leaf) {
                    # No backup. A plain $null reaches the method as an empty path.
                    [System.IO.File]::Replace($temp, $StatusFile, [System.Management.Automation.Language.NullString]::Value)
                } else {
                    [System.IO.File]::Move($temp, $StatusFile)
                }
                return
            } catch {
                if ($attempt -ge 10) { throw }
                Start-Sleep -Milliseconds 100
            }
        }
    } catch {
        Write-Warning "Could not write the update status: $($_.Exception.Message)"
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    }
}

# Moves the reported run on, and names what a failure from here on would report.
function Set-InstRun {
    param([string]$State, [string]$FailCode, [string]$To)
    if ($FailCode) { $script:InstFailCode = $FailCode }
    if ($null -eq $script:InstRun -or (-not $State -and -not $To)) { return }
    if ($State) { $script:InstRun.state = $State }
    if ($To) { $script:InstRun.to = $To }
    Write-InstRun
}

function Complete-InstRun {
    param([Parameter(Mandatory)][string]$State, [string]$Code, [bool]$ExtensionChanged = $false)
    if ($null -eq $script:InstRun) { return }
    $script:InstRun.state = $State
    $script:InstRun.code = if ($Code) { $Code } else { $null }
    $script:InstRun.extensionChanged = $ExtensionChanged
    $script:InstRun.finishedAt = Get-InstUtcStamp
    Write-InstRun
    $script:InstRun = $null
}

# One install at a time, for this user in any session (a terminal, the task, an SSH login): the
# mutex object, or $null while another install holds it. Another install at a higher or lower
# integrity level shows as access denied.
function Enter-InstLock {
    $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $lock = $null
    try {
        $lock = New-Object System.Threading.Mutex($false, "Global\PortlyInstall-$user")
    } catch {
        if ($_.Exception.GetBaseException() -is [System.UnauthorizedAccessException]) { return $null }
        throw
    }
    try {
        if ($lock.WaitOne(0)) { return $lock }
    } catch {
        # The last install died holding it: it is ours now.
        if ($_.Exception.GetBaseException() -is [System.Threading.AbandonedMutexException]) { return $lock }
        $lock.Dispose()
        throw
    }
    $lock.Dispose()
    return $null
}

function Exit-InstLock {
    param($Lock)
    if ($null -eq $Lock) { return }
    try { $Lock.ReleaseMutex() } catch { }
    $Lock.Dispose()
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
    Initialize-InstRun -InstalledVersion $installedVersion

    $work = Join-Path ([System.IO.Path]::GetTempPath()) ('portly-install-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $work -Force
    try {
        Set-InstRun -State 'downloading' -FailCode 'download_failed'
        $release = Resolve-InstRelease -Work $work
        Set-InstRun -To $release.Version
        Assert-InstNewer -Candidate $release.Version -Installed $installedVersion
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
        Set-InstRun -State 'installing' -FailCode 'checksum_mismatch'
        if ($release.Sha256) {
            $actual = Get-InstSha256 -Path $zip
            if ($actual -ne $release.Sha256) {
                throw "The package's SHA-256 is $actual, not $($release.Sha256) as published. Nothing was installed."
            }
            Write-InstOk 'SHA-256 checked'
        } else {
            Write-Warning 'No SHA-256 to check the package against (no -Sha256 and no portly-release.json next to it).'
        }

        Set-InstRun -FailCode 'unknown'
        Write-InstStep "Unpacking into $staged"
        if (-not (Test-Path -LiteralPath $root)) { $null = New-Item -ItemType Directory -Path $root -Force }
        Remove-InstAppFolder -Path $staged
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $staged)
        $new = Test-InstPackage -Dir $staged -ExpectedVersion $release.Version
        $newVersion = "$($new.version)"
        Set-InstRun -To $newVersion
        try {
            Assert-InstNewer -Candidate $newVersion -Installed $installedVersion
        } catch {
            Remove-InstAppFolder -Path $staged
            throw
        }
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
        Set-InstRun -FailCode 'file_in_use'
        $task = Get-InstTask -AppDir $app
        $mode = if ($InstTriggerGiven) { $Trigger } else { $task.Mode }
        Write-InstStep "Updating Portly $installedVersion to $newVersion"
        # The task stays disabled while the folders are swapped: a Portly tab that finds the server
        # gone asks the launcher to run the task, which would start the old copy again and hold its files.
        $taskDisabled = $task.Ours -and (Set-InstTaskEnabled -Enabled $false)
        if ($task.Ours) { try { Stop-ScheduledTask -TaskName $InstTaskName -TaskPath '\' -ErrorAction Stop } catch { } }
        $swapped = $false
        try {
            $stopped = Stop-InstAppProcesses -AppDir $app
            if ($stopped -gt 0) { Write-InstInfo "Stopped $stopped Portly process(es)." }
            $backup = Backup-InstDatabase -Label $installedVersion
            if ($null -ne $backup) { Write-InstInfo "Database copied to $backup" }
            Remove-InstAppFolder -Path $previous
            Remove-InstLinks -AppDir $app
            Move-InstFolder -From $app -To $previous
            try {
                Move-InstFolder -From $staged -To $app
            } catch {
                Move-InstFolder -From $previous -To $app
                throw
            }
            $swapped = $true
        } finally {
            if ($taskDisabled) { $null = Set-InstTaskEnabled -Enabled $true }
            if (-not $swapped) {
                # Nothing was replaced: the old version is linked and started again.
                if (Test-Path -LiteralPath $app) { Initialize-InstLinks -AppDir $app }
                if ($task.Ours) { try { Start-ScheduledTask -TaskName $InstTaskName -TaskPath '\' } catch { } }
            }
        }
        Set-InstRun -State 'restarting' -FailCode 'did_not_start'
        Initialize-InstLinks -AppDir $app
        Set-InstPagesUrl

        if (-not $SkipAutostart) {
            if ($task.Ours -or -not $task.Exists) {
                if ((Invoke-InstAutostart -AppDir $app -Mode $mode) -ne 0) {
                    Write-InstFailure "Portly $newVersion did not start (see above)."
                    $restored = Restore-InstPrevious -Root $root -Task $task -Mode $mode -Backup $backup -Label $newVersion | Select-Object -Last 1
                    Complete-InstRun -State $(if ($restored) { 'rolled-back' } else { 'failed' }) -Code 'did_not_start'
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
        Write-InstOk "Updated Portly $installedVersion -> $newVersion. The previous version is kept in $previous."
        # Last, so it is still on screen when the output ends (the scripts above print a lot).
        $oldExtension = "$(Get-InstProperty $installed 'extensionVersion')"
        $newExtension = "$(Get-InstProperty $new 'extensionVersion')"
        Complete-InstRun -State 'done' -ExtensionChanged ($oldExtension -ne $newExtension)
        if ($oldExtension -ne $newExtension) {
            Write-Warning ("The new-tab extension changed ($oldExtension -> $newExtension): click Reload on " +
                'Portly New Tab in chrome://extensions (or edge://extensions).')
        }
        return 0
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$savedOutputEncoding = [Console]::OutputEncoding
$installExitCode = 1
$installLock = $null
try {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    if (-not $DryRun) {
        $installLock = Enter-InstLock
        if ($null -eq $installLock) {
            Initialize-InstRun
            throw 'Another Portly install or update is running. Wait for it to finish and run this again.'
        }
    }
    $installExitCode = Invoke-InstMain | Select-Object -Last 1
} catch {
    Write-InstFailure $_.Exception.Message
    $installExitCode = 1
} finally {
    # Whatever the run did not report itself.
    if ($installExitCode -eq 0) { Complete-InstRun -State 'done' } else { Complete-InstRun -State 'failed' -Code $script:InstFailCode }
    Exit-InstLock -Lock $installLock
    try { [Console]::OutputEncoding = $savedOutputEncoding } catch { }
}
# Run as a file: exit with the result. Run with irm | iex: leave the caller's window open.
if ($PSCommandPath) { exit ([int]$installExitCode) }
