# install.ps1 — mootx01 Windows installer
#
# Downloads a prebuilt mootx01.exe from GitHub Releases and wires it into
# every MCP client found on this machine. No compiler or build tools required.
#
# Standard one-liner install (the TLS 1.2 set is required on Windows PowerShell
# 5.1, which otherwise negotiates TLS 1.0/1.1 and is refused by GitHub's CDN):
#   [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; iex "& { $(irm https://raw.githubusercontent.com/codedaptive/mootx01-ce/stable/1.0.x/install.ps1) }"
#
# With options:
#   iex "& { $(irm https://...) } -Uninstall"
#   iex "& { $(irm https://...) } -Local"
#   iex "& { $(irm https://...) } -NoPermissions"
#
# Or clone the repo and run directly:
#   .\install.ps1 [-Uninstall] [-Local] [-NoPermissions] [-Version v1.2.3]
#
# Environment variables (override defaults):
#   MOOTX01_VERSION      release tag to install (default: latest)
#   MOOTX01_INSTALL_DIR  directory for the binary (default: ~/.mootx01/bin)
#   MOOTX01_BIN_DIR      directory added to PATH  (default: ~/.local/bin)

[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$Local,
    [switch]$NoPermissions,
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
$BIN_DIR     = if ($env:MOOTX01_BIN_DIR)     { $env:MOOTX01_BIN_DIR }     else { Join-Path $HOME ".local\bin" }
$BINARY      = Join-Path $INSTALL_DIR "mootx01.exe"
$MGR_BINARY  = Join-Path $INSTALL_DIR "moot-mgr.exe"
$SERVER_NAME = "mootx01"
$RESIDENT_URL = "http://127.0.0.1:4242"

# ── ARIA tool permission entries ────────────────────────────────────────────

$ARIA_TOOLS = @(
    "moot_capture_drawer","moot_reanchor_drawer","moot_mutate_drawer",
    "moot_withdraw_drawer","moot_expunge_drawer","moot_drawer_recall",
    "moot_capture_tunnel","moot_mutate_tunnel","moot_withdraw_tunnel",
    "moot_expunge_tunnel","moot_tunnel_recall",
    "moot_mutate_kgFact","moot_withdraw_kgFact","moot_expunge_kgFact","moot_kgFact_recall",
    "moot_diaryEntry_recall",
    "moot_mutate_proposal","moot_withdraw_proposal","moot_expunge_proposal","moot_proposal_recall",
    "moot_mutate_association","moot_expunge_association","moot_association_recall",
    "moot_mutate_learnedReference","moot_withdraw_learnedReference",
    "moot_expunge_learnedReference","moot_learnedReference_recall","moot_learn_learnedReference",
    "moot_cross_estate_recall",
    "moot_list_recipes","moot_grounded_synthesis",
    "moot_run_migration_benchmark","moot_confirm_migration_promotion",
    "moot_keystones","moot_constellation","moot_free_association",
    "moot_theme_weather","moot_latent_themes","moot_bias",
    "moot_drift","moot_contradiction","moot_trust_grounded_synthesis",
    "moot_partial_cue_recall","moot_anticipate","moot_tunnel_successor",
    "moot_mind_overlap","moot_estate_divergence",
    "moot_association_rules","moot_formal_concepts",
    "moot_vault_export","moot_vault_import","moot_vault_status","moot_vault_reconcile"
) | ForEach-Object { "mcp__mootx01__$_" }

# ── Client definitions ──────────────────────────────────────────────────────

# Each client: id, displayName, configPath (absolute), detectPath (absolute or $null),
# supportsHTTP (wire url entry instead of command entry).
# Windows paths mirror macOS paths from ClientConfig.swift.
# No resident daemon on Windows yet — all clients use stdio (command entry).
function Get-Clients {
    @(
        @{
            id          = "claude-desktop"
            display     = "Claude Desktop"
            config      = Join-Path $env:APPDATA "Claude\claude_desktop_config.json"
            detect      = Join-Path $env:LOCALAPPDATA "AnthropicClaude"
            http        = $false
        },
        @{
            id          = "claude-code"
            display     = "Claude Code"
            config      = Join-Path $HOME ".claude.json"
            detect      = $null   # checked via Get-Command below
            detectCmd   = "claude"
            localConfig = ".mcp.json"
            http        = $false
        },
        @{
            id          = "cursor"
            display     = "Cursor"
            config      = Join-Path $HOME ".cursor\mcp.json"
            detect      = Join-Path $env:LOCALAPPDATA "Programs\cursor\Cursor.exe"
            http        = $false
        },
        @{
            id          = "cline"
            display     = "Cline"
            config      = Join-Path $env:APPDATA "Code\User\globalStorage\saoudrizwan.claude-dev\settings\cline_mcp_settings.json"
            detectDir   = Join-Path $HOME ".vscode\extensions"
            detectPrefix = "saoudrizwan.claude-dev-"
            http        = $false
        },
        @{
            id          = "continue"
            display     = "Continue"
            config      = Join-Path $HOME ".continue\mcpServers\mootx01.yaml"
            detect      = Join-Path $HOME ".continue"
            http        = $false
            yaml        = $true
        }
    )
}

function Test-ClientPresent($client) {
    if ($client.ContainsKey("detectCmd")) {
        # Claude Code: check if the CLI is on PATH or config file exists
        $onPath = $null -ne (Get-Command $client.detectCmd -ErrorAction SilentlyContinue)
        $hasConfig = Test-Path $client.config
        return $onPath -or $hasConfig
    }
    if ($client.ContainsKey("detectDir")) {
        # Cline: check for saoudrizwan.claude-dev-* in extensions dir
        if (-not (Test-Path $client.detectDir)) { return $false }
        return $null -ne (Get-ChildItem $client.detectDir -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name.StartsWith($client.detectPrefix) } |
            Select-Object -First 1)
    }
    if ($null -eq $client.detect) { return $true }
    return Test-Path $client.detect
}

# ── JSON helpers ────────────────────────────────────────────────────────────

# Recursively turn the PSCustomObject tree that ConvertFrom-Json returns into
# nested hashtables. Windows PowerShell 5.1 (the default shell) has no
# `-AsHashtable` switch — it is PowerShell 6+ only — and the rest of this script
# manipulates configs through hashtable semantics (.ContainsKey, indexer
# assignment, .Remove, .Count). The `,` (unary comma) on the array branches stops
# PowerShell from unrolling single-element and empty arrays, so `args: []` and
# the like round-trip back through ConvertTo-Json unchanged.
function ConvertTo-HashtableTree($obj) {
    if ($null -eq $obj) { return $null }
    if ($obj -is [System.Collections.IEnumerable] -and $obj -isnot [string]) {
        $list = @()
        foreach ($item in $obj) { $list += ,(ConvertTo-HashtableTree $item) }
        return ,$list
    }
    if ($obj.GetType().Name -eq 'PSCustomObject') {
        $ht = @{}
        foreach ($prop in $obj.PSObject.Properties) {
            $ht[$prop.Name] = ConvertTo-HashtableTree $prop.Value
        }
        return $ht
    }
    return $obj
}

function Read-JsonFile($path) {
    if (Test-Path $path) {
        $raw = Get-Content $path -Raw -Encoding UTF8
        # ConvertFrom-Json without -AsHashtable yields a PSCustomObject tree in
        # every PowerShell version; ConvertTo-HashtableTree gives us the
        # hashtable contract the callers expect.
        return ConvertTo-HashtableTree ($raw | ConvertFrom-Json)
    }
    return @{}
}

function Write-JsonFile($path, $obj) {
    $dir = Split-Path $path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    $tmp = "$path.tmp"
    $obj | ConvertTo-Json -Depth 10 | Set-Content $tmp -Encoding UTF8 -NoNewline
    Move-Item -Force $tmp $path
}

# ── Wire / unwire a JSON MCP client ────────────────────────────────────────

function Install-JsonClient($client, $binaryPath, $configPath) {
    $cfg = Read-JsonFile $configPath
    if (-not $cfg.ContainsKey("mcpServers")) { $cfg["mcpServers"] = @{} }

    # stdio entry — command points at the placed binary
    $cfg["mcpServers"][$SERVER_NAME] = @{
        command = $binaryPath
        args    = @()
        env     = @{}
    }
    Write-JsonFile $configPath $cfg
    Write-Host "  Wired $($client.display) → $configPath"
}

function Uninstall-JsonClient($client, $configPath) {
    if (-not (Test-Path $configPath)) { return }
    $cfg = Read-JsonFile $configPath
    if ($cfg.ContainsKey("mcpServers") -and $cfg["mcpServers"].ContainsKey($SERVER_NAME)) {
        $cfg["mcpServers"].Remove($SERVER_NAME)
        if ($cfg["mcpServers"].Count -eq 0) { $cfg.Remove("mcpServers") }
        Write-JsonFile $configPath $cfg
        Write-Host "  Removed $($client.display) entry from $configPath"
    }
}

# ── Wire / unwire the Continue YAML client ─────────────────────────────────

function Install-ContinueClient($client, $binaryPath, $configPath) {
    $dir = Split-Path $configPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    "command: $binaryPath`nargs: []`n" | Set-Content $configPath -Encoding UTF8
    Write-Host "  Wired $($client.display) → $configPath"
}

function Uninstall-ContinueClient($configPath) {
    if (Test-Path $configPath) {
        Remove-Item $configPath -Force
        Write-Host "  Removed Continue config: $configPath"
    }
}

# ── Claude Code permissions ─────────────────────────────────────────────────

function Merge-Permissions($settingsPath) {
    $cfg = Read-JsonFile $settingsPath
    if (-not $cfg.ContainsKey("permissions")) { $cfg["permissions"] = @{} }
    if (-not $cfg["permissions"].ContainsKey("allow")) { $cfg["permissions"]["allow"] = @() }

    $existing = [System.Collections.Generic.HashSet[string]]$cfg["permissions"]["allow"]
    $added = 0
    foreach ($entry in $ARIA_TOOLS) {
        if ($existing.Add($entry)) { $added++ }
    }
    $cfg["permissions"]["allow"] = @($existing)
    Write-JsonFile $settingsPath $cfg
    Write-Host "  Merged $added ARIA tool permissions → $settingsPath"
}

function Remove-Permissions($settingsPath) {
    if (-not (Test-Path $settingsPath)) { return }
    $cfg = Read-JsonFile $settingsPath
    if (-not $cfg.ContainsKey("permissions")) { return }
    if (-not $cfg["permissions"].ContainsKey("allow")) { return }
    $toRemove = [System.Collections.Generic.HashSet[string]]$ARIA_TOOLS
    $cfg["permissions"]["allow"] = @($cfg["permissions"]["allow"] | Where-Object { -not $toRemove.Contains($_) })
    Write-JsonFile $settingsPath $cfg
    Write-Host "  Removed ARIA tool permissions from $settingsPath"
}

# ── PATH helper ─────────────────────────────────────────────────────────────

function Add-ToUserPath($dir) {
    # [string] casts a missing ($null) value to "" — works in Windows PowerShell
    # 5.1 (the default shell) as well as PowerShell 7+. The `??` operator is 7+ only.
    $current = [string][Environment]::GetEnvironmentVariable("PATH", "User")
    $parts = $current -split ";" | Where-Object { $_ -ne "" }
    if ($parts -notcontains $dir) {
        $newPath = ($parts + $dir) -join ";"
        [Environment]::SetEnvironmentVariable("PATH", $newPath, "User")
        Write-Host "  Added $dir to user PATH (restart your terminal to use mootx01)"
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

    # Unregister the background services (the mootx01 / mootx01-mgr Task Scheduler
    # logon tasks) via the Rust CLI BEFORE the binary is deleted — `mootx01
    # uninstall` is what knows the task names (commands/uninstall.rs). Skipping
    # this would leave logon tasks pointing at a deleted binary. Scheduled tasks
    # are global, so this only applies to a global uninstall; -Local removals are
    # project-scoped and register no tasks.
    if (-not $Local) {
        if (Test-Path $BINARY) {
            try {
                & $BINARY uninstall --yes | Out-Null
            } catch {
                Write-Warning "Could not run '$BINARY uninstall' to unregister scheduled tasks: $_"
            }
        } else {
            Write-Warning "mootx01.exe not found; the mootx01 / mootx01-mgr scheduled tasks may remain. Run 'mootx01 uninstall' if it is still on PATH."
        }
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

    # Remove MCP client entries
    $clients = Get-Clients
    foreach ($client in $clients) {
        $configPath = if ($Local -and $client.ContainsKey("localConfig")) {
            Join-Path (Get-Location) $client.localConfig
        } else { $client.config }

        if ($client.ContainsKey("yaml") -and $client.yaml) {
            Uninstall-ContinueClient $configPath
        } else {
            Uninstall-JsonClient $client $configPath
        }
    }

    # Remove permissions
    $settingsPath = if ($Local) {
        Join-Path (Get-Location) ".claude\settings.json"
    } else {
        Join-Path $HOME ".claude\settings.json"
    }
    Remove-Permissions $settingsPath

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
#    is callable by name, including the `mootx01 install` follow-up below. Windows
#    has no convenient unprivileged symlink, so we PATH the real dir rather than
#    shim into $BIN_DIR.
Add-ToUserPath $INSTALL_DIR

# 5. Wire MCP clients
Write-Host ""
Write-Host "Detecting MCP clients..."
$clients = Get-Clients
$wired   = @()
$skipped = @()

foreach ($client in $clients) {
    if (-not (Test-ClientPresent $client)) {
        $skipped += $client.display
        continue
    }

    $configPath = if ($Local -and $client.ContainsKey("localConfig")) {
        Join-Path (Get-Location) $client.localConfig
    } else { $client.config }

    if ($client.ContainsKey("yaml") -and $client.yaml) {
        Install-ContinueClient $client $BINARY $configPath
    } else {
        Install-JsonClient $client $BINARY $configPath
    }
    $wired += $client.display
}

# 6. Merge ARIA permissions into Claude Code settings
if (-not $NoPermissions) {
    Write-Host ""
    Write-Host "Writing ARIA tool permissions..."
    $settingsPath = if ($Local) {
        Join-Path (Get-Location) ".claude\settings.json"
    } else {
        Join-Path $HOME ".claude\settings.json"
    }
    Merge-Permissions $settingsPath
}

# 7. Summary
Write-Host ""
Write-Host "mootx01 $Version installed."
if ($wired.Count -gt 0) {
    Write-Host "  Wired:   $($wired -join ', ')"
    Write-Host "  Restart these clients to pick up the new MCP server."
}
if ($skipped.Count -gt 0) {
    Write-Host "  Skipped: $($skipped -join ', ') (not found — install them and re-run to wire)"
}
Write-Host ""
Write-Host "Next: restart your MCP client and look for 'mootx01' in its server list."
