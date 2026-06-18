# install.ps1 — mootx01 Windows installer
#
# Downloads a prebuilt mootx01.exe from GitHub Releases and places it on your
# PATH. No compiler or build tools required. Wiring mootx01 into your AI clients
# is the `mootx01 install` step (interactive menu, full client roster) — the same
# command macOS and Linux users run after the shell installer. This script only
# places the binaries; the cross-platform Rust CLI owns client detection and
# wiring (core/clients.rs), so every platform sees the identical client roster.
#
# Standard one-liner install (the TLS 1.2 set is required on Windows PowerShell
# 5.1, which otherwise negotiates TLS 1.0/1.1 and is refused by GitHub's CDN):
#   [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; iex "& { $(irm https://raw.githubusercontent.com/codedaptive/mootx01-ce/stable/1.0.x/install.ps1) }"
#
# Uninstall (removes the binaries + PATH entry, and delegates client-wiring and
# scheduled-task cleanup to `mootx01 uninstall`):
#   iex "& { $(irm https://...) } -Uninstall"
#
# Or clone the repo and run directly:
#   .\install.ps1 [-Uninstall] [-Version v1.2.3]
#
# Environment variables (override defaults):
#   MOOTX01_VERSION      release tag to install (default: latest)
#   MOOTX01_INSTALL_DIR  directory for the binary (default: ~/.mootx01/bin)

[CmdletBinding()]
param(
    [switch]$Uninstall,
    [string]$Version = $env:MOOTX01_VERSION
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 (the default shell) negotiates TLS 1.0/1.1 out of the
# box on older .NET; GitHub's raw + release CDNs require TLS 1.2 and reset the
# connection otherwise. -bor adds 1.2 to whatever is already enabled rather than
# replacing it, so a machine already on 1.3 keeps it.
[Net.ServicePointManager]::SecurityProtocol = `
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$REPO        = if ($env:MOOTX01_REPO)        { $env:MOOTX01_REPO }        else { "codedaptive/mootx01-ce" }
$MOOTX01_ROOT        = Join-Path $HOME ".mootx01"
$DEFAULT_INSTALL_DIR = Join-Path $MOOTX01_ROOT "bin"
$INSTALL_DIR = if ($env:MOOTX01_INSTALL_DIR) { $env:MOOTX01_INSTALL_DIR } else { $DEFAULT_INSTALL_DIR }
$BINARY      = Join-Path $INSTALL_DIR "mootx01.exe"
$MGR_BINARY  = Join-Path $INSTALL_DIR "moot-mgr.exe"

# ── PATH helper ─────────────────────────────────────────────────────────────

function Add-ToUserPath($dir) {
    # Persist the dir on the *user* PATH so mootx01 is callable by name in every
    # future terminal. [string] casts a missing ($null) value to "" — works in
    # Windows PowerShell 5.1 (the default shell) as well as 7+; the `??` operator
    # is 7+ only.
    $current = [string][Environment]::GetEnvironmentVariable("PATH", "User")
    $parts = $current -split ";" | Where-Object { $_ -ne "" }
    if ($parts -notcontains $dir) {
        $newPath = ($parts + $dir) -join ";"
        [Environment]::SetEnvironmentVariable("PATH", $newPath, "User")
        Write-Host "  Added $dir to your user PATH (persists for new terminals)"
    } else {
        Write-Host "  $dir already on your user PATH"
    }

    # Persisting the user PATH does NOT update the running process — a setx-style
    # write is only picked up by terminals started afterward. Mirror the dir into
    # this session's $env:PATH too so the `mootx01 install` hand-off below works
    # immediately, in the same window, without a restart.
    if (($env:PATH -split ";") -notcontains $dir) {
        $env:PATH = "$env:PATH;$dir"
    }
}

function Remove-FromUserPath($dir) {
    # [string] casts a missing ($null) value to "" — works in Windows PowerShell
    # 5.1 (the default shell) as well as PowerShell 7+. The `??` operator is 7+ only.
    $current = [string][Environment]::GetEnvironmentVariable("PATH", "User")
    $parts = $current -split ";" | Where-Object { $_ -ne "" -and $_ -ne $dir }
    [Environment]::SetEnvironmentVariable("PATH", ($parts -join ";"), "User")
}

# ════════════════════════════════════════════════════════════════════════════
# UNINSTALL
# ════════════════════════════════════════════════════════════════════════════

if ($Uninstall) {
    Write-Host "Uninstalling mootx01..."

    # `mootx01 uninstall` removes the MCP-client wirings, revokes Claude Code
    # permissions, and unregisters the mootx01 / mootx01-mgr scheduled tasks —
    # all through the full cross-platform client roster and the task names it
    # owns (commands/uninstall.rs). Run it BEFORE the binary is deleted; the
    # PowerShell side never reimplements wiring, so it never reimplements unwiring.
    if (Test-Path $BINARY) {
        try {
            & $BINARY uninstall --yes
        } catch {
            Write-Warning "Could not run '$BINARY uninstall': $_`nClient wirings and scheduled tasks may remain — re-run 'mootx01 uninstall' if it is still on PATH."
        }
    } else {
        Write-Warning "mootx01.exe not found; client wirings and the mootx01 / mootx01-mgr scheduled tasks may remain. Run 'mootx01 uninstall' if it is still on PATH."
    }

    # Remove the binaries we installed. NEVER blindly delete the install dir's
    # parent — with a custom MOOTX01_INSTALL_DIR (e.g. C:\Tools or C:\Users\bob\bin)
    # that would take an unrelated user directory with it.
    foreach ($exe in @($BINARY, $MGR_BINARY)) {
        if (Test-Path $exe) {
            Remove-Item -Force $exe
            Write-Host "  Removed $exe"
        }
    }
    # Default layout ($HOME\.mootx01\bin): remove the whole ~/.mootx01 root, which
    # we own. Custom layout: remove the install dir only if our binaries left it
    # empty, and never touch its parent.
    if ($INSTALL_DIR -eq $DEFAULT_INSTALL_DIR) {
        if (Test-Path $MOOTX01_ROOT) {
            Remove-Item -Recurse -Force $MOOTX01_ROOT
            Write-Host "  Removed $MOOTX01_ROOT"
        }
    } elseif ((Test-Path $INSTALL_DIR) -and -not (Get-ChildItem -Force $INSTALL_DIR)) {
        Remove-Item -Force $INSTALL_DIR
        Write-Host "  Removed $INSTALL_DIR"
    } elseif (Test-Path $INSTALL_DIR) {
        Write-Host "  Left $INSTALL_DIR in place (not empty; removed only MOOTx01 binaries)"
    }
    Remove-FromUserPath $INSTALL_DIR

    Write-Host ""
    $dataDir = if ($env:MOOTX01_DATA_DIR) { $env:MOOTX01_DATA_DIR } else { Join-Path $env:LOCALAPPDATA "MOOTx01" }
    Write-Host "mootx01 removed. Your estate data at $dataDir was not touched."
    Write-Host "Delete that directory manually if you want to remove your data."
    exit 0
}

# ════════════════════════════════════════════════════════════════════════════
# INSTALL
# ════════════════════════════════════════════════════════════════════════════

# 1. Resolve version
if (-not $Version) {
    Write-Host "Resolving latest version..."
    try {
        $rel = Invoke-RestMethod "https://api.github.com/repos/$REPO/releases/latest"
        $Version = $rel.tag_name
    } catch {
        Write-Error "Could not resolve latest version. Set `$env:MOOTX01_VERSION or pass -Version."
        exit 1
    }
}
if (-not $Version.StartsWith("v")) { $Version = "v$Version" }

# 2. Download (arch-aware: a real arm64 artifact ships alongside x86_64).
#    PROCESSOR_ARCHITEW6432 catches an x86-emulated shell on an ARM64 machine.
$machineArch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
$arch    = if ($machineArch -eq "ARM64") { "arm64" } else { "x86_64" }
$asset   = "mootx01-${Version}-windows-${arch}.zip"
$url     = "https://github.com/$REPO/releases/download/$Version/$asset"
$tmpDir  = Join-Path $env:TEMP "mootx01-install-$([System.IO.Path]::GetRandomFileName())"
New-Item -ItemType Directory -Force $tmpDir | Out-Null

Write-Host "Installing mootx01 $Version (windows-$arch)..."
try {
    Invoke-WebRequest $url -OutFile (Join-Path $tmpDir $asset)
} catch {
    Write-Error "Download failed: $url`n$_"
    Remove-Item -Recurse -Force $tmpDir
    exit 1
}

# 3. Extract + place binaries
Expand-Archive (Join-Path $tmpDir $asset) -DestinationPath $tmpDir -Force
if (-not (Test-Path (Join-Path $tmpDir "mootx01.exe"))) {
    Write-Error "Archive did not contain mootx01.exe"
    Remove-Item -Recurse -Force $tmpDir
    exit 1
}

New-Item -ItemType Directory -Force $INSTALL_DIR | Out-Null

# Stop any running mootx01 / moot-mgr before overwriting their binaries. Windows
# locks a running .exe, so reinstalling over a live install — or after an
# uninstall that left a detached/orphaned moot-mgr running — would fail the
# Copy-Item below with a sharing violation. Stop the scheduled tasks first (the
# clean path), then force-kill any surviving process by image name (covers
# orphaned/manually-started instances), then let the file handles release.
foreach ($task in @("mootx01", "mootx01-mgr")) {
    Stop-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue | Out-Null
}
foreach ($proc in @("mootx01", "moot-mgr")) {
    Get-Process -Name $proc -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Milliseconds 400

Copy-Item -Force (Join-Path $tmpDir "mootx01.exe") $BINARY
Write-Host "  Installed $BINARY"

# moot-mgr.exe (the management & monitoring console) ships in the Windows
# archive alongside mootx01.exe. Place it beside mootx01.exe so the
# `mootx01 install` follow-up registers the mgr Task Scheduler task (it keys
# off moot-mgr.exe sitting next to mootx01.exe — see commands/install.rs).
$mgrSrc = Join-Path $tmpDir "moot-mgr.exe"
if (Test-Path $mgrSrc) {
    Copy-Item -Force $mgrSrc $MGR_BINARY
    Write-Host "  Installed $MGR_BINARY"
}

Remove-Item -Recurse -Force $tmpDir

# 4. Add the install dir (which holds mootx01.exe) to the user PATH so `mootx01`
#    is callable by name. Windows has no convenient unprivileged symlink, so we
#    PATH the real dir rather than shim into a separate bin dir.
Add-ToUserPath $INSTALL_DIR

# 5. Hand off to the CLI for client wiring. Detection + wiring lives in the Rust
#    `mootx01 install` command (core/clients.rs), which knows the full client
#    roster — verified live on Windows 11 — and registers the mootx01 / mootx01-mgr
#    Task Scheduler services. This is the same second step macOS and Linux take,
#    so all three platforms share one wiring implementation and one client list.
Write-Host ""
Write-Host "mootx01 $Version installed."
Write-Host ""
Write-Host "Next: wire mootx01 into your AI clients (interactive menu):"
Write-Host "  mootx01 install"
Write-Host ""
Write-Host "Vault (import/export to disk) is ON by default. For a more secure position:"
Write-Host "  mootx01 install --vault-off   # disables import/export"
Write-Host ""
Write-Host "That step also registers moot-mgr, the management console, as a Task"
Write-Host "Scheduler service (starts now, restarts at login) — dashboard at"
Write-Host "http://127.0.0.1:4200. Or run it yourself any time with 'moot-mgr serve'."

# mootx01 is on the persisted user PATH (every new terminal) and on THIS
# session's PATH (Add-ToUserPath mirrored it into $env:PATH), so `mootx01`
# should resolve right here. Verify, and if some environment policy stopped the
# PATH update from taking, tell the user exactly how to fix it rather than
# leaving them with a "command not found".
Write-Host ""
if (Get-Command mootx01 -ErrorAction SilentlyContinue) {
    Write-Host "'mootx01' is on your PATH and ready to use in this terminal."
} else {
    # The dir was already persisted to the user PATH above, so a fresh terminal
    # will pick it up; the full-path call works right now without waiting.
    Write-Host "'mootx01' isn't resolving in this terminal yet. To use it:"
    Write-Host "  - open a NEW terminal ($INSTALL_DIR was added to your user PATH), or"
    Write-Host "  - run it by full path right now:  $BINARY install"
}
