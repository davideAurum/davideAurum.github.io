<#
.SYNOPSIS
    Sets up Portly on a new Windows PC in one go: prerequisites, code, dependencies, build,
    autostart and the `portly` command.

.DESCRIPTION
    1. Installs what is missing with winget: Git (only when the code must be cloned) and Node.js
       24, the major package.json pins (winget's OpenJS.NodeJS.24, or OpenJS.NodeJS.LTS while that
       still is 24). A PC with another Node.js major stops here with what to do, naming the
       winget id that carries 24 today. Upgrades npm when it is older than 11.10 (package.json
       requires it).
    2. Gets the code: when this script runs from a Portly checkout it uses that checkout;
       otherwise (for example `irm <url> | iex`) it clones -RepoUrl into -InstallDir and runs
       that checkout's copy of this script, so the rest always
       matches the code being installed. An existing checkout in -InstallDir is reused as it is.
    3. With -PagesUrl: saves the Pages site's address as the user environment variable
       PORTLY_PAGES_URL (or removes it with -PagesUrl off) before Portly is started. With
       -RemoteOrigin: saves the address your other PCs use (through a reverse proxy on this PC,
       docs\setup\other-pcs.md) as PORTLY_REMOTE_ORIGIN (or removes it with -RemoteOrigin off).
    4. npm ci (exactly the locked dependencies; install scripts stay disabled by .npmrc).
    5. npm run build (web\dist, the page the server serves).
    6. scripts\install-autostart.ps1: the Portly Server scheduled task and the native host the
       new-tab extension uses to start it; starts Portly and waits for /api/health.
    7. scripts\install-cli.ps1: the `portly` command (portly --status, --rebuild, ...).
    8. The new-tab extension cannot be installed by a script (Chrome and Edge only load unpacked
       extensions by hand): prints the steps, copies the extension folder's path to the clipboard
       and opens the browser's extensions page. New tabs follow Portly on this PC: its Pages
       site when PORTLY_PAGES_URL is set, otherwise Portly itself.

    Self-contained (it does not use lib\Common.ps1) so it also runs on its own, before any
    checkout exists. Safe to run again: every step skips or repeats harmlessly.
    Your accounts are not copied: credentials are encrypted for this PC's Windows user, so connect
    them again in Settings. Layout and settings move with Settings -> Export / Import.

.PARAMETER InstallDir
    Where to clone Portly when this script is not run from a checkout
    (default %USERPROFILE%\Coding\Portly).

.PARAMETER RepoUrl
    Repository to clone (default https://github.com/davideAurum/Portly.git).

.PARAMETER Branch
    Branch to clone (default main).

.PARAMETER PagesUrl
    The address of your Portly Pages site, for example https://<user>.github.io/ (hybrid mode,
    docs\setup\pages-local-server.md). Saved as the user environment variable PORTLY_PAGES_URL
    before Portly is started, so it answers that site, and new tabs open it. 'off' removes the
    variable: new tabs then open Portly on this PC. Without -PagesUrl the variable is left as it
    is (unset on a new PC).

.PARAMETER RemoteOrigin
    The address your other PCs use to reach Portly on this PC, given by a reverse proxy you run
    here such as Tailscale Serve, for example https://<pc>.<tailnet>.ts.net (docs\setup\other-pcs.md).
    Saved as the user environment variable PORTLY_REMOTE_ORIGIN before Portly is started, so it
    also listens for the proxy on the port after its own (5758 by default) and lets each PC in
    once you approve it in Settings -> Devices. 'off' removes the variable (and PORTLY_REMOTE_PORT).
    Without -RemoteOrigin the variable is left as it is (unset on a new PC: Portly listens on this
    PC only). On an installed PC add -Trigger Logon when you use Logon mode: the task is replaced.

.PARAMETER Trigger
    Passed to install-autostart.ps1: Browser (default; the extension starts Portly) or Logon.

.PARAMETER NoHomebaseCopy
    Passed to install-autostart.ps1: on a PC that ran Homebase, start Portly from scratch instead
    of copying Homebase's data and HOMEBASE_* variables (Homebase's task is still removed). Later
    runs without it do not copy the variables either.

.PARAMETER SkipAutostart
    Do not register the scheduled task and native host (start Portly with scripts\start.ps1).

.PARAMETER SkipCli
    Do not install the `portly` command.

.PARAMETER NoBrowser
    Do not open the browser's extensions page or copy to the clipboard.

.PARAMETER DryRun
    Print what would happen and change nothing. When winget is present and Node.js is missing
    (or another major), it still asks winget, read-only, which package carries Node.js 24, so
    the plan and the message name the id that works today.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\setup.ps1

.EXAMPLE
    & ([scriptblock]::Create((irm <url of this file>))) -InstallDir D:\Portly

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\setup.ps1 -PagesUrl https://me.github.io/

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\setup.ps1 -RemoteOrigin https://pc.tailnet.ts.net
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:USERPROFILE 'Coding\Portly'),
    [string]$RepoUrl = 'https://github.com/davideAurum/Portly.git',
    [string]$Branch = 'main',
    [string]$PagesUrl,
    [string]$RemoteOrigin,
    [ValidateSet('Browser', 'Logon')][string]$Trigger = 'Browser',
    [switch]$NoHomebaseCopy,
    [switch]$SkipAutostart,
    [switch]$SkipCli,
    [switch]$NoBrowser,
    [switch]$DryRun
)

# Node.js 24: the major package.json pins in engines.node, which npm's engine-strict enforces, so
# this script and lib\Common.ps1's Resolve-HbNode refuse any other major too. check-scripts.ps1
# keeps $SetupNodeMajor equal to $PortlyNodeMajor in lib\Common.ps1; this script cannot dot-source
# that file because it also runs on its own, before any checkout exists.
$SetupNodeMajor = 24
# winget's packages that install that major, tried in this order: winget gives a major its own
# id (OpenJS.NodeJS.22, ...) once it is no longer winget's LTS; until then OpenJS.NodeJS.LTS is
# the one that installs it, and it is used only while its version still is that major.
$SetupNodePackage = "OpenJS.NodeJS.$SetupNodeMajor"
$SetupNodeLtsPackage = 'OpenJS.NodeJS.LTS'
$SetupMinNpm = [version]'11.10.0'
$SetupGitPackage = 'Git.Git'

function Write-SetupStep { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-SetupOk { param([string]$Message) Write-Host "OK  $Message" -ForegroundColor Green }
function Write-SetupInfo { param([string]$Message = '') Write-Host "    $Message" }
function Write-SetupFailure { param([string]$Message) Write-Host "ERROR: $Message" -ForegroundColor Red }

# This session's PATH again from the registry, so programs winget just installed are found.
function Update-SetupPath {
    $machine = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [System.Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ';'
}

function Get-SetupCommand {
    param([Parameter(Mandatory)][string]$Name)
    return Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
}

# Runs a program, shows its output, throws when it fails.
function Invoke-SetupProgram {
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$Arguments = @(), [string]$WorkingDirectory)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    if ($WorkingDirectory) { Push-Location -LiteralPath $WorkingDirectory }
    try {
        & $FilePath @Arguments | Out-Host
        $exitCode = $LASTEXITCODE
    } finally {
        if ($WorkingDirectory) { Pop-Location }
        $ErrorActionPreference = $previous
    }
    if ($exitCode -ne 0) {
        throw "$([System.IO.Path]::GetFileName($FilePath)) $($Arguments -join ' ') failed (exit code $exitCode)."
    }
}

# Version of node.exe on PATH (x.y.z), or $null when there is none.
function Get-SetupNodeVersion {
    $node = Get-SetupCommand 'node.exe'
    if ($null -eq $node) { return $null }
    $text = "$(& $node.Source -p 'process.versions.node' 2>$null)".Trim()
    if ($text -notmatch '^[0-9]+\.[0-9]+\.[0-9]+') { return $null }
    return $Matches[0]
}

# The major of a version string (x.y.z), or 0 for $null.
function Get-SetupMajor {
    param([string]$Version)
    if ([string]::IsNullOrWhiteSpace($Version)) { return 0 }
    return [int]$Version.Split('.')[0]
}

# The winget install command for a package id, as the arguments winget gets.
function Get-SetupWingetInstallArguments {
    param([Parameter(Mandatory)][string]$Id)
    return @('install', '--id', $Id, '--exact', '--source', 'winget', '--accept-package-agreements', '--accept-source-agreements')
}

# The version winget would install for a package id (x.y.z), or $null when winget does not list
# that id. Read-only: 'winget search --exact' prints one table row, "<name> <id> <version>",
# which is read by the id so the column headings' language does not matter.
function Get-SetupWingetVersion {
    param([Parameter(Mandatory)][string]$Winget, [Parameter(Mandatory)][string]$Id)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $lines = @(& $Winget search --id $Id --exact --source winget --accept-source-agreements 2>$null | ForEach-Object { "$_" })
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
    if ($exitCode -ne 0) { return $null }
    $pattern = '\s' + [regex]::Escape($Id) + '\s+([0-9]+\.[0-9]+\.[0-9]+)'
    foreach ($line in $lines) {
        if ($line -match $pattern) { return $Matches[1] }
    }
    return $null
}

# The winget package that installs Node.js $SetupNodeMajor right now (Id and Version), or $null.
function Find-SetupNodePackage {
    param([Parameter(Mandatory)][string]$Winget)
    foreach ($id in @($SetupNodePackage, $SetupNodeLtsPackage)) {
        $version = Get-SetupWingetVersion -Winget $Winget -Id $id
        if ($null -ne $version -and (Get-SetupMajor $version) -eq $SetupNodeMajor) {
            return [pscustomobject]@{ Id = $id; Version = $version }
        }
    }
    return $null
}

function Get-SetupNpmVersion {
    $npm = Get-SetupCommand 'npm.cmd'
    if ($null -eq $npm) { return $null }
    $text = "$(& $npm.Source -v 2>$null)".Trim()
    if ($text -notmatch '^[0-9]+\.[0-9]+\.[0-9]+') { return $null }
    return [version]$Matches[0]
}

function Install-SetupWingetPackage {
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$What)
    $winget = Get-SetupCommand 'winget.exe'
    if ($null -eq $winget) {
        throw ("$What is missing and winget is not available to install it. Install 'App Installer' from the " +
            "Microsoft Store (it provides winget), or install $What yourself, then run this again.")
    }
    $arguments = Get-SetupWingetInstallArguments -Id $Id
    Write-SetupInfo "winget $($arguments -join ' ')"
    if ($DryRun) { return }
    # winget exits non-zero for "already installed"; whether the program now works is checked by the caller.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $winget.Source @arguments | Out-Host } finally { $ErrorActionPreference = $previous }
    Update-SetupPath
}

function Install-SetupNode {
    $version = Get-SetupNodeVersion
    $major = Get-SetupMajor $version
    if ($major -eq $SetupNodeMajor) {
        Write-SetupOk "Node.js $version found"
    } elseif ($major -gt 0) {
        # Another major, older or newer: npm ci would refuse it (engine-strict), so stop before
        # anything is installed, with the message lib\Common.ps1's Resolve-HbNode gives too. Only
        # one of the two winget ids carries the pinned major at a time, so when winget is at hand
        # the message also names the one that does today (a read-only lookup).
        $message = ("Portly needs Node.js $SetupNodeMajor, found v$version; install Node.js $SetupNodeMajor from https://nodejs.org/ " +
            "or with winget install $SetupNodePackage ($SetupNodeLtsPackage while winget's LTS is still $SetupNodeMajor), " +
            'open a new PowerShell window and run this again.')
        $winget = Get-SetupCommand 'winget.exe'
        if ($null -ne $winget) {
            $package = Find-SetupNodePackage -Winget $winget.Source
            if ($null -ne $package) {
                $message += " Today winget lists Node.js $($package.Version) as $($package.Id): winget $((Get-SetupWingetInstallArguments -Id $package.Id) -join ' ')"
            }
        }
        throw $message
    } else {
        Write-SetupStep "Node.js is not installed; installing Node.js $SetupNodeMajor with winget (Windows may ask for permission)"
        $winget = Get-SetupCommand 'winget.exe'
        if ($null -eq $winget) {
            if ($DryRun) {
                # The plan, without asking winget which of the two ids carries that major today.
                Write-SetupInfo "winget $((Get-SetupWingetInstallArguments -Id $SetupNodePackage) -join ' ')"
                Write-SetupInfo "(or $SetupNodeLtsPackage while winget's LTS is still Node.js $SetupNodeMajor; decided when it runs)"
                Write-SetupInfo ("winget is not available on this PC: install 'App Installer' from the Microsoft Store first, " +
                    "or Node.js $SetupNodeMajor from https://nodejs.org/")
                return
            }
            throw ("Node.js is missing and winget is not available to install it. Install 'App Installer' from the " +
                "Microsoft Store (it provides winget), or install Node.js $SetupNodeMajor from https://nodejs.org/, then run this again.")
        }
        $package = Find-SetupNodePackage -Winget $winget.Source
        if ($null -eq $package) {
            throw ("winget has no package that installs Node.js $SetupNodeMajor right now (no $SetupNodePackage, and " +
                "$SetupNodeLtsPackage is not $SetupNodeMajor.x). Install Node.js $SetupNodeMajor from https://nodejs.org/, " +
                'open a new PowerShell window and run this again.')
        }
        Write-SetupInfo "winget lists Node.js $($package.Version) as $($package.Id)"
        if ($package.Id -ne $SetupNodePackage) {
            Write-SetupInfo "(winget has no $SetupNodePackage yet: a major gets its own id once a newer LTS replaces it)"
        }
        Install-SetupWingetPackage -Id $package.Id -What "Node.js $SetupNodeMajor"
        if ($DryRun) { return }
        $version = Get-SetupNodeVersion
        if ((Get-SetupMajor $version) -ne $SetupNodeMajor) {
            $found = if ($null -eq $version) { 'none' } else { "v$version" }
            throw ("Node.js $SetupNodeMajor is still not on PATH (found: $found). Install it from https://nodejs.org/, " +
                'open a new PowerShell window and run this again.')
        }
        Write-SetupOk "Node.js $version installed"
    }

    $npmVersion = Get-SetupNpmVersion
    if ($null -ne $npmVersion -and $npmVersion -ge $SetupMinNpm) {
        Write-SetupOk "npm $npmVersion found"
        return
    }
    Write-SetupStep "npm $npmVersion is older than $SetupMinNpm; updating it: npm install -g npm@latest"
    if ($DryRun) { return }
    # Run from the profile folder so the repository's .npmrc does not apply to this global install.
    Invoke-SetupProgram -FilePath (Get-SetupCommand 'npm.cmd').Source -Arguments @('install', '-g', 'npm@latest', '--no-audit', '--no-fund') -WorkingDirectory $env:USERPROFILE
    $npmVersion = Get-SetupNpmVersion
    if ($null -eq $npmVersion -or $npmVersion -lt $SetupMinNpm) {
        throw "npm is still $npmVersion after the update. Open a new PowerShell window and run this again."
    }
    Write-SetupOk "npm $npmVersion"
}

function Install-SetupGit {
    if ($null -ne (Get-SetupCommand 'git.exe')) { Write-SetupOk 'Git found'; return }
    Write-SetupStep 'Git is not installed; installing it'
    Install-SetupWingetPackage -Id $SetupGitPackage -What 'Git'
    if ($DryRun) { return }
    if ($null -eq (Get-SetupCommand 'git.exe')) {
        throw 'Git is still not on PATH. Open a new PowerShell window and run this again.'
    }
    Write-SetupOk 'Git installed'
}

function Test-SetupPagesOff { return "$PagesUrl".Trim() -eq 'off' }

# localhost, 127.0.0.1 or [::1], the hosts the server allows plain http for. Windows PowerShell
# reports an IPv6 host in its long form, so the address is parsed rather than compared as text.
function Test-SetupLoopbackHost {
    param([Parameter(Mandatory)][System.Uri]$Uri)
    if ($Uri.Host -eq 'localhost') { return $true }
    $ip = $null
    if (-not [System.Net.IPAddress]::TryParse($Uri.DnsSafeHost, [ref]$ip)) { return $false }
    return $ip.Equals([System.Net.IPAddress]::Loopback) -or $ip.Equals([System.Net.IPAddress]::IPv6Loopback)
}

# The -PagesUrl address normalised by the rules server/src/config.ts applies to
# PORTLY_PAGES_URL (https, or http on localhost/127.0.0.1/[::1]; no user name, password, query
# or fragment; a "/" is added at the end), so a typo fails before anything is installed. The server
# checks it again when install-autostart.ps1 starts it.
function ConvertTo-SetupPagesUrl {
    param([Parameter(Mandatory)][string]$Value)
    $text = $Value.Trim()
    $uri = $null
    $usage = "-PagesUrl must be the Pages site's full address, like https://<user>.github.io/, or 'off' (got '$Value')."
    if ($text -match '[?#\s]' -or -not [System.Uri]::TryCreate($text, [System.UriKind]::Absolute, [ref]$uri)) { throw $usage }
    if (-not ($uri.Scheme -eq 'https' -or ($uri.Scheme -eq 'http' -and (Test-SetupLoopbackHost -Uri $uri)))) {
        throw "$usage It must use https (http only for localhost, 127.0.0.1 or [::1])."
    }
    if ($uri.UserInfo) { throw "$usage It must not contain a user name or password." }
    $path = $uri.AbsolutePath
    if (-not $path.EndsWith('/')) { $path += '/' }
    return "$($uri.GetLeftPart([System.UriPartial]::Authority))$path"
}

# -PagesUrl: saves the address as the user environment variable PORTLY_PAGES_URL ('off' removes
# it), and in this process too, so install-autostart.ps1 checks and starts the server with it.
function Set-SetupPagesUrl {
    if ([string]::IsNullOrWhiteSpace($PagesUrl)) { return }
    $prefix = if ($DryRun) { '[dry run] ' } else { '' }
    $name = 'PORTLY_PAGES_URL'
    if (Test-SetupPagesOff) {
        Write-SetupStep "${prefix}Pages site off: removing the user environment variable $name"
        if (-not $DryRun) {
            [System.Environment]::SetEnvironmentVariable($name, $null, 'User')
            Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
        }
        if (-not [string]::IsNullOrWhiteSpace([System.Environment]::GetEnvironmentVariable($name, 'Machine'))) {
            Write-Warning "$name is also set for the whole PC (machine environment variable); remove it there too (needs an administrator)."
        }
        Write-SetupInfo 'New tabs open Portly on this PC.'
        return
    }
    $url = ConvertTo-SetupPagesUrl -Value $PagesUrl
    Write-SetupStep "${prefix}Pages site: setting the user environment variable $name = $url"
    if (-not $DryRun) {
        [System.Environment]::SetEnvironmentVariable($name, $url, 'User')
        Set-Item -LiteralPath "Env:$name" -Value $url
    }
    Write-SetupInfo 'New tabs open that site; pair each browser with Portly there once (docs\setup\pages-local-server.md).'
}

function Test-SetupRemoteOff { return "$RemoteOrigin".Trim() -eq 'off' }

# The -RemoteOrigin address normalised by the rules server/src/config.ts applies to
# PORTLY_REMOTE_ORIGIN (https, or http on localhost/127.0.0.1/[::1]; the address only: no path,
# user name, password, query or fragment), so a typo fails before anything is installed. The
# server checks it again when install-autostart.ps1 starts it (and refuses its own address).
function ConvertTo-SetupRemoteOrigin {
    param([Parameter(Mandatory)][string]$Value)
    $text = $Value.Trim()
    $uri = $null
    $usage = "-RemoteOrigin must be the address your other PCs use, like https://<pc>.<tailnet>.ts.net, or 'off' (got '$Value')."
    if ($text -match '[?#\s]' -or -not [System.Uri]::TryCreate($text, [System.UriKind]::Absolute, [ref]$uri)) { throw $usage }
    if (-not ($uri.Scheme -eq 'https' -or ($uri.Scheme -eq 'http' -and (Test-SetupLoopbackHost -Uri $uri)))) {
        throw "$usage It must use https (http only for localhost, 127.0.0.1 or [::1])."
    }
    if ($uri.UserInfo) { throw "$usage It must not contain a user name or password." }
    if ($uri.AbsolutePath -ne '/' -and $uri.AbsolutePath -ne '') { throw "$usage It must be the address only, without a path." }
    # Portly's own address and the Pages site are refused by the server at start-up; refuse them
    # here too, before the variable is saved.
    if ((Test-SetupLoopbackHost -Uri $uri) -and "$($uri.Port)" -eq (Get-SetupOwnPort)) {
        throw "$usage That is Portly's own address on this PC; other PCs use the reverse proxy's address."
    }
    $pages = Get-SetupPagesOrigin
    if ($null -ne $pages -and $pages -eq $uri.GetLeftPart([System.UriPartial]::Authority)) {
        throw "$usage That is the Pages site's address, not the address other PCs use to reach Portly on this PC."
    }
    return $uri.GetLeftPart([System.UriPartial]::Authority)
}

# PORTLY_PORT as the server will read it (this process, then the user and machine variables; default 5757).
function Get-SetupOwnPort {
    foreach ($scope in @('Process', 'User', 'Machine')) {
        $value = [System.Environment]::GetEnvironmentVariable('PORTLY_PORT', $scope)
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value.Trim() }
    }
    return '5757'
}

# The Pages site's origin: -PagesUrl when given (not 'off'), else the user variable; $null without one.
function Get-SetupPagesOrigin {
    $value = if (-not [string]::IsNullOrWhiteSpace($PagesUrl) -and -not (Test-SetupPagesOff)) { $PagesUrl } else { [System.Environment]::GetEnvironmentVariable('PORTLY_PAGES_URL', 'User') }
    if ([string]::IsNullOrWhiteSpace($value) -or "$value".Trim() -eq 'off') { return $null }
    $uri = $null
    if (-not [System.Uri]::TryCreate($value.Trim(), [System.UriKind]::Absolute, [ref]$uri)) { return $null }
    return $uri.GetLeftPart([System.UriPartial]::Authority)
}

# -RemoteOrigin: saves the address as the user environment variable PORTLY_REMOTE_ORIGIN ('off'
# removes it), and in this process too, so install-autostart.ps1 checks and starts the server with it.
function Set-SetupRemoteOrigin {
    if ([string]::IsNullOrWhiteSpace($RemoteOrigin)) { return }
    $prefix = if ($DryRun) { '[dry run] ' } else { '' }
    $name = 'PORTLY_REMOTE_ORIGIN'
    if (Test-SetupRemoteOff) {
        # The port only means something with the origin (the server refuses it alone): both go.
        Write-SetupStep "${prefix}Other PCs off: removing the user environment variables $name and PORTLY_REMOTE_PORT"
        foreach ($each in @($name, 'PORTLY_REMOTE_PORT')) {
            if (-not $DryRun) {
                [System.Environment]::SetEnvironmentVariable($each, $null, 'User')
                Remove-Item -LiteralPath "Env:$each" -ErrorAction SilentlyContinue
            }
            if (-not [string]::IsNullOrWhiteSpace([System.Environment]::GetEnvironmentVariable($each, 'Machine'))) {
                Write-Warning "$each is also set for the whole PC (machine environment variable); remove it there too (needs an administrator)."
            }
        }
        Write-SetupInfo 'Portly listens on this PC only again; PCs connected before are refused (remove them in Settings -> Devices).'
        return
    }
    $origin = ConvertTo-SetupRemoteOrigin -Value $RemoteOrigin
    Write-SetupStep "${prefix}Other PCs: setting the user environment variable $name = $origin"
    if (-not $DryRun) {
        [System.Environment]::SetEnvironmentVariable($name, $origin, 'User')
        Set-Item -LiteralPath "Env:$name" -Value $origin
    }
    Write-SetupInfo 'The reverse proxy must forward to the port after Portly''s own (5758 by default: tailscale serve --bg 5758); approve each PC in Settings -> Devices (docs\setup\other-pcs.md).'
}

function Test-SetupCheckout {
    param([Parameter(Mandatory)][string]$Path)
    return (Test-Path -LiteralPath (Join-Path $Path 'package.json') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $Path 'server\src\index.ts') -PathType Leaf)
}

# The checkout this script belongs to, or $null when it runs on its own (irm | iex, a copy).
function Get-SetupOwnCheckout {
    if ([string]::IsNullOrEmpty($PSScriptRoot)) { return $null }
    $root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    if (Test-SetupCheckout -Path $root) { return $root }
    return $null
}

# The branch and last commit of a checkout ("main at 1a2b3c4 from 2026-10-01"), or $null.
function Get-SetupCheckoutCommit {
    param([Parameter(Mandatory)][string]$Path)
    $git = Get-SetupCommand 'git.exe'
    if ($null -eq $git) { return $null }
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $branch = "$(& $git.Source -C $Path rev-parse --abbrev-ref HEAD 2>$null)".Trim()
        $last = "$(& $git.Source -C $Path log -1 '--format=%h from %cs' 2>$null)".Trim()
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrEmpty($last)) { return $null }
        if ([string]::IsNullOrEmpty($branch)) { return $last }
        return "$branch at $last"
    } catch {
        return $null
    } finally {
        $ErrorActionPreference = $previous
    }
}

# Clones (or reuses) -InstallDir and runs its scripts\setup.ps1 with the same options.
function Invoke-SetupFromClone {
    $target = [System.IO.Path]::GetFullPath($InstallDir)
    # A mistyped -PagesUrl or -RemoteOrigin fails now, before anything is downloaded.
    if (-not [string]::IsNullOrWhiteSpace($PagesUrl) -and -not (Test-SetupPagesOff)) { $null = ConvertTo-SetupPagesUrl -Value $PagesUrl }
    if (-not [string]::IsNullOrWhiteSpace($RemoteOrigin) -and -not (Test-SetupRemoteOff)) { $null = ConvertTo-SetupRemoteOrigin -Value $RemoteOrigin }
    Install-SetupGit
    if (Test-SetupCheckout -Path $target) {
        $targetSetup = Join-Path $target 'scripts\setup.ps1'
        if (-not (Test-Path -LiteralPath $targetSetup -PathType Leaf)) {
            throw "The checkout in $target is older than this script. Update it (git -C ""$target"" pull) and run this again."
        }
        if (-not [string]::IsNullOrWhiteSpace($RemoteOrigin) -and -not (Select-String -LiteralPath $targetSetup -Pattern '\$RemoteOrigin' -Quiet)) {
            throw "The checkout in $target is older than this script and does not know -RemoteOrigin. Update it (git -C ""$target"" pull) and run this again."
        }
        Write-SetupOk "Found an existing checkout in $target. Setup uses its code as it is and does not update it."
        $commit = Get-SetupCheckoutCommit -Path $target
        if ($null -ne $commit) { Write-SetupInfo "Its code: $commit" }
        Write-SetupInfo "To set up the newest code instead: git -C ""$target"" pull, then run setup again."
        Write-SetupInfo "To update it later: git -C ""$target"" pull, then portly --rebuild."
    } elseif ((Test-Path -LiteralPath $target) -and @(Get-ChildItem -LiteralPath $target -Force).Count -gt 0) {
        throw "$target exists and is not an empty folder or a Portly checkout. Pass -InstallDir with another folder."
    } else {
        Write-SetupStep "Cloning $RepoUrl ($Branch) into $target"
        if ($DryRun) {
            Write-SetupInfo 'Dry run: the remaining steps come from the cloned checkout and are not shown.'
            return 0
        }
        $parent = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent | Out-Null }
        Invoke-SetupProgram -FilePath (Get-SetupCommand 'git.exe').Source -Arguments @('clone', '--branch', $Branch, $RepoUrl, $target)
        Write-SetupOk "Cloned into $target"
    }

    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $target 'scripts\setup.ps1'), '-Trigger', $Trigger)
    if (-not [string]::IsNullOrWhiteSpace($PagesUrl)) { $arguments += @('-PagesUrl', $PagesUrl.Trim()) }
    if (-not [string]::IsNullOrWhiteSpace($RemoteOrigin)) { $arguments += @('-RemoteOrigin', $RemoteOrigin.Trim()) }
    foreach ($name in @('NoHomebaseCopy', 'SkipAutostart', 'SkipCli', 'NoBrowser', 'DryRun')) {
        if ((Get-Variable -Name $name -ValueOnly).IsPresent) { $arguments += "-$name" }
    }
    $powershell = (Get-Process -Id $PID).Path
    & $powershell @arguments | Out-Host
    return $LASTEXITCODE
}

# Runs another script of this checkout in its own PowerShell process; returns its exit code.
function Invoke-SetupScript {
    param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$Script, [string[]]$Arguments = @())
    $powershell = (Get-Process -Id $PID).Path
    & $powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "scripts\$Script") @Arguments | Out-Host
    return $LASTEXITCODE
}

function Show-SetupExtensionSteps {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $extension = Join-Path $RepoRoot 'extension'
    Write-SetupStep 'Last step, by hand: load the new-tab extension in Chrome or Edge'
    Write-SetupInfo '1. Open chrome://extensions (Edge: edge://extensions).'
    Write-SetupInfo '2. Turn on Developer mode.'
    Write-SetupInfo "3. Load unpacked -> select $extension"
    Write-SetupInfo 'Details: docs\setup\extension.md'
    if ($NoBrowser -or $DryRun) { return }
    try { Set-Clipboard -Value $extension; Write-SetupInfo '(The folder path is on the clipboard.)' } catch { }
    $browsers = @(
        @{ Exe = 'chrome.exe'; Url = 'chrome://extensions' },
        @{ Exe = 'msedge.exe'; Url = 'edge://extensions' }
    )
    foreach ($browser in $browsers) {
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

function Invoke-SetupHere {
    param([Parameter(Mandatory)][string]$RepoRoot)
    if ($RepoRoot -match '\\\.claude\\worktrees\\' -and -not $DryRun) {
        throw ("This is a temporary worktree ($RepoRoot); autostart and the portly command must not point into it. " +
            'Run scripts\setup.ps1 from the main checkout instead.')
    }
    $prefix = if ($DryRun) { '[dry run] ' } else { '' }
    Write-SetupStep "${prefix}Setting up Portly in $RepoRoot"
    # Both checked before either is saved: a mistyped second option must not leave the first behind.
    if (-not [string]::IsNullOrWhiteSpace($PagesUrl) -and -not (Test-SetupPagesOff)) { $null = ConvertTo-SetupPagesUrl -Value $PagesUrl }
    if (-not [string]::IsNullOrWhiteSpace($RemoteOrigin) -and -not (Test-SetupRemoteOff)) { $null = ConvertTo-SetupRemoteOrigin -Value $RemoteOrigin }
    Set-SetupPagesUrl
    Set-SetupRemoteOrigin
    Install-SetupNode
    $npm = if ($DryRun) { $null } else { (Get-SetupCommand 'npm.cmd').Source }

    Write-SetupStep "${prefix}Installing dependencies: npm ci"
    if (-not $DryRun) {
        Invoke-SetupProgram -FilePath $npm -Arguments @('ci', '--no-audit', '--no-fund') -WorkingDirectory $RepoRoot
        Write-SetupOk 'Dependencies installed'
    }

    Write-SetupStep "${prefix}Building the web app (web\dist): npm run build"
    if (-not $DryRun) {
        Invoke-SetupProgram -FilePath $npm -Arguments @('run', 'build') -WorkingDirectory $RepoRoot
        Write-SetupOk 'Built web\dist'
    }

    $failed = @()
    if ($SkipAutostart) {
        Write-SetupInfo 'Autostart skipped. Start Portly with: scripts\start.ps1'
    } else {
        Write-SetupStep "${prefix}Autostart: scripts\install-autostart.ps1 -Trigger $Trigger"
        $autostartArgs = @('-Trigger', $Trigger)
        if ($NoHomebaseCopy) { $autostartArgs += '-NoHomebaseCopy' }
        if ($DryRun) { $autostartArgs += '-DryRun' }
        if ((Invoke-SetupScript -RepoRoot $RepoRoot -Script 'install-autostart.ps1' -Arguments $autostartArgs) -ne 0) {
            $failed += 'install-autostart.ps1'
        }
    }

    if (-not $SkipCli) {
        Write-SetupStep "${prefix}The portly command: scripts\install-cli.ps1"
        $cliArgs = @()
        if ($DryRun) { $cliArgs += '-DryRun' }
        if ((Invoke-SetupScript -RepoRoot $RepoRoot -Script 'install-cli.ps1' -Arguments $cliArgs) -ne 0) {
            $failed += 'install-cli.ps1'
        }
    }

    Show-SetupExtensionSteps -RepoRoot $RepoRoot

    if ($failed.Count -gt 0) {
        Write-SetupFailure "Setup finished, but $($failed -join ' and ') failed (see above). Fix that and run this script again."
        return 1
    }
    if ($DryRun) { Write-SetupOk 'Dry run finished; nothing was changed.'; return 0 }
    Write-SetupOk 'Portly is set up: http://localhost:5757'
    Write-SetupInfo 'Then connect your accounts in Settings (docs\SETUP.md#connect-your-accounts).'
    Write-SetupInfo 'Open a new terminal to use the portly command (portly --status).'
    return 0
}

function Invoke-Setup {
    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
        throw 'Portly runs on Windows (DPAPI vault, Task Scheduler).'
    }
    $checkout = Get-SetupOwnCheckout
    if ($null -eq $checkout) { return Invoke-SetupFromClone }
    return Invoke-SetupHere -RepoRoot $checkout
}

# npm and Vite write UTF-8; read it as UTF-8 so their output is not garbled.
$savedOutputEncoding = [Console]::OutputEncoding
$setupExitCode = 1
try {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $setupExitCode = Invoke-Setup | Select-Object -Last 1
} catch {
    Write-SetupFailure $_.Exception.Message
    $setupExitCode = 1
} finally {
    try { [Console]::OutputEncoding = $savedOutputEncoding } catch { }
}
# Run as a file: exit with the result. Run with irm | iex: leave the caller's window open.
if ($PSCommandPath) { exit ([int]$setupExitCode) }
