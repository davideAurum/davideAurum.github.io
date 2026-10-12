<#
.SYNOPSIS
    Sets up Homebase on a new Windows PC in one go: prerequisites, code, dependencies, build,
    autostart and the `homebase` command.

.DESCRIPTION
    1. Installs what is missing with winget: Git (only when the code must be cloned) and Node.js
       LTS (24 or newer). Upgrades npm when it is older than 11.10 (package.json requires it).
    2. Gets the code: when this script runs from a Homebase checkout it uses that checkout;
       otherwise (for example `irm <url> | iex`) it clones -RepoUrl into -InstallDir (GitHub may
       ask you to sign in) and runs that checkout's copy of this script, so the rest always
       matches the code being installed. An existing checkout in -InstallDir is reused as it is.
    3. npm ci (exactly the locked dependencies; install scripts stay disabled by .npmrc).
    4. npm run build (web\dist, the page the server serves).
    5. scripts\install-autostart.ps1: the Homebase Server scheduled task and the native host the
       new-tab extension uses to start it; starts Homebase and waits for /api/health.
    6. scripts\install-cli.ps1: the `homebase` command (homebase --status, --rebuild, ...).
    7. The new-tab extension cannot be installed by a script (Chrome and Edge only load unpacked
       extensions by hand): prints the steps, copies the extension folder's path to the clipboard
       and opens the browser's extensions page.

    Self-contained (it does not use lib\Common.ps1) so it also runs on its own, before any
    checkout exists. Safe to run again: every step skips or repeats harmlessly.
    Your accounts are not copied: credentials are encrypted for this PC's Windows user, so connect
    them again in Settings. Layout and settings move with Settings -> Export / Import.

.PARAMETER InstallDir
    Where to clone Homebase when this script is not run from a checkout
    (default %USERPROFILE%\Coding\Homebase).

.PARAMETER RepoUrl
    Repository to clone (default https://github.com/davideAurum/Homebase.git).

.PARAMETER Branch
    Branch to clone (default main).

.PARAMETER Trigger
    Passed to install-autostart.ps1: Browser (default; the extension starts Homebase) or Logon.

.PARAMETER SkipAutostart
    Do not register the scheduled task and native host (start Homebase with scripts\start.ps1).

.PARAMETER SkipCli
    Do not install the `homebase` command.

.PARAMETER NoBrowser
    Do not open the browser's extensions page or copy to the clipboard.

.PARAMETER DryRun
    Print what would happen and change nothing.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\setup.ps1

.EXAMPLE
    & ([scriptblock]::Create((irm <url of this file>))) -InstallDir D:\Homebase
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:USERPROFILE 'Coding\Homebase'),
    [string]$RepoUrl = 'https://github.com/davideAurum/Homebase.git',
    [string]$Branch = 'main',
    [ValidateSet('Browser', 'Logon')][string]$Trigger = 'Browser',
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

# Clones (or reuses) -InstallDir and runs its scripts\setup.ps1 with the same options.
function Invoke-SetupFromClone {
    $target = [System.IO.Path]::GetFullPath($InstallDir)
    Install-SetupGit
    if (Test-SetupCheckout -Path $target) {
        if (-not (Test-Path -LiteralPath (Join-Path $target 'scripts\setup.ps1') -PathType Leaf)) {
            throw "The checkout in $target is older than this script. Update it (git -C ""$target"" pull) and run this again."
        }
        Write-SetupOk "Using the existing checkout in $target (update it later with: homebase --rebuild)"
    } elseif ((Test-Path -LiteralPath $target) -and @(Get-ChildItem -LiteralPath $target -Force).Count -gt 0) {
        throw "$target exists and is not an empty folder or a Homebase checkout. Pass -InstallDir with another folder."
    } else {
        Write-SetupStep "Cloning $RepoUrl ($Branch) into $target (GitHub may ask you to sign in)"
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
    foreach ($name in @('SkipAutostart', 'SkipCli', 'NoBrowser', 'DryRun')) {
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
        throw ("This is a temporary worktree ($RepoRoot); autostart and the homebase command must not point into it. " +
            'Run scripts\setup.ps1 from the main checkout instead.')
    }
    $prefix = if ($DryRun) { '[dry run] ' } else { '' }
    Write-SetupStep "${prefix}Setting up Homebase in $RepoRoot"
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
        Write-SetupInfo 'Autostart skipped. Start Homebase with: scripts\start.ps1'
    } else {
        Write-SetupStep "${prefix}Autostart: scripts\install-autostart.ps1 -Trigger $Trigger"
        $autostartArgs = @('-Trigger', $Trigger)
        if ($DryRun) { $autostartArgs += '-DryRun' }
        if ((Invoke-SetupScript -RepoRoot $RepoRoot -Script 'install-autostart.ps1' -Arguments $autostartArgs) -ne 0) {
            $failed += 'install-autostart.ps1'
        }
    }

    if (-not $SkipCli) {
        Write-SetupStep "${prefix}The homebase command: scripts\install-cli.ps1"
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
    Write-SetupOk 'Homebase is set up: http://localhost:5757'
    Write-SetupInfo 'Then connect your accounts in Settings (docs\SETUP.md#connect-your-accounts).'
    Write-SetupInfo 'Open a new terminal to use the homebase command (homebase --status).'
    return 0
}

function Invoke-Setup {
    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
        throw 'Homebase runs on Windows (DPAPI vault, Task Scheduler).'
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
