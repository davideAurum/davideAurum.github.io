<#
.SYNOPSIS
    Sets up Portly on a new Windows PC in one go: prerequisites, code, dependencies, build,
    autostart and the `portly` command.

.DESCRIPTION
    1. Installs what is missing with winget: Git (only when the code must be cloned) and Node.js
       LTS (24 or newer). Upgrades npm when it is older than 11.10 (package.json requires it).
    2. Gets the code: when this script runs from a Portly checkout it uses that checkout;
       otherwise (for example `irm <url> | iex`) it clones -RepoUrl into -InstallDir and runs
       that checkout's copy of this script, so the rest always
       matches the code being installed. An existing checkout in -InstallDir is reused as it is.
    3. With -PagesUrl: saves the Pages site's address as the user environment variable
       PORTLY_PAGES_URL (or removes it with -PagesUrl off) before Portly is started.
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
    Print what would happen and change nothing.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\setup.ps1

.EXAMPLE
    & ([scriptblock]::Create((irm <url of this file>))) -InstallDir D:\Portly

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\setup.ps1 -PagesUrl https://me.github.io/
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:USERPROFILE 'Coding\Portly'),
    [string]$RepoUrl = 'https://github.com/davideAurum/Portly.git',
    [string]$Branch = 'main',
    [string]$PagesUrl,
    [ValidateSet('Browser', 'Logon')][string]$Trigger = 'Browser',
    [switch]$NoHomebaseCopy,
    [switch]$SkipAutostart,
    [switch]$SkipCli,
    [switch]$NoBrowser,
    [switch]$DryRun
)

$SetupMinNodeMajor = 24
$SetupMinNpm = [version]'11.10.0'
$SetupNodePackage = 'OpenJS.NodeJS.LTS'
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

# Major version of node.exe on PATH, or 0 when there is none.
function Get-SetupNodeMajor {
    $node = Get-SetupCommand 'node.exe'
    if ($null -eq $node) { return 0 }
    $text = "$(& $node.Source -p 'process.versions.node' 2>$null)".Trim()
    if ($text -notmatch '^([0-9]+)\.') { return 0 }
    return [int]$Matches[1]
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
    $arguments = @('install', '--id', $Id, '--exact', '--source', 'winget', '--accept-package-agreements', '--accept-source-agreements')
    Write-SetupInfo "winget $($arguments -join ' ')"
    if ($DryRun) { return }
    # winget exits non-zero for "already installed"; whether the program now works is checked by the caller.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $winget.Source @arguments | Out-Host } finally { $ErrorActionPreference = $previous }
    Update-SetupPath
}

function Install-SetupNode {
    $major = Get-SetupNodeMajor
    if ($major -ge $SetupMinNodeMajor) {
        Write-SetupOk "Node.js $major found"
    } else {
        $found = if ($major -gt 0) { "Node.js $major is too old" } else { 'Node.js is not installed' }
        Write-SetupStep "$found; installing Node.js LTS (Windows may ask for permission)"
        Install-SetupWingetPackage -Id $SetupNodePackage -What 'Node.js'
        if ($DryRun) { return }
        $major = Get-SetupNodeMajor
        if ($major -lt $SetupMinNodeMajor) {
            throw ("Node.js $SetupMinNodeMajor or newer is still not on PATH (found: $major). Install it from " +
                'https://nodejs.org/, open a new PowerShell window and run this again.')
        }
        Write-SetupOk "Node.js $major installed"
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
    $loopback = @('localhost', '127.0.0.1', '[::1]')
    if (-not ($uri.Scheme -eq 'https' -or ($uri.Scheme -eq 'http' -and $loopback -contains $uri.Host))) {
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
    # A mistyped -PagesUrl fails now, before anything is downloaded.
    if (-not [string]::IsNullOrWhiteSpace($PagesUrl) -and -not (Test-SetupPagesOff)) { $null = ConvertTo-SetupPagesUrl -Value $PagesUrl }
    Install-SetupGit
    if (Test-SetupCheckout -Path $target) {
        if (-not (Test-Path -LiteralPath (Join-Path $target 'scripts\setup.ps1') -PathType Leaf)) {
            throw "The checkout in $target is older than this script. Update it (git -C ""$target"" pull) and run this again."
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
    Set-SetupPagesUrl
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
