# install.ps1 — mootx01 Windows installer
#
# Downloads a prebuilt mootx01.exe from GitHub Releases and places it on your
# PATH. No compiler or build tools required. Wiring mootx01 into your AI clients
# is the `mootx01 install` step (interactive menu, full client roster) — the same
# command macOS and Linux users run after the shell installer. This script only
# places the binaries; the cross-platform Rust CLI owns client detection and
# wiring (core/clients.rs), so every platform sees the identical client roster.
#
# Install — DO NOT pipe this script straight into the interpreter
# (`irm ... | iex`): that executes remote code before you can review it or
# verify its integrity. Download it, then run it locally. The TLS 1.2 line is
# required on Windows PowerShell 5.1, which otherwise negotiates TLS 1.0/1.1
# and is refused by GitHub's CDN:
#   [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
#   irm https://raw.githubusercontent.com/codedaptive/mootx01-ce/stable/1.0.x/install.ps1 -OutFile install.ps1
#   # review install.ps1, then:
#   .\install.ps1
#
# Uninstall (removes the binaries + PATH entry, and delegates client-wiring and
# scheduled-task cleanup to `mootx01 uninstall`):
#   .\install.ps1 -Uninstall
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
# VERIFICATION HELPERS
# ════════════════════════════════════════════════════════════════════════════

# The Ed25519 public key for this release, embedded byte-identical to
# distribution/minisign.pub (line 2). Verifying against an embedded constant —
# rather than fetching the key over the network — means an attacker who
# controls the download host cannot substitute a key. The key id is
# BC4D1E6ABCB5B788; the 42-byte blob is 2-byte algo "Ed" + 8-byte key id +
# 32-byte Ed25519 public key.
$MINISIGN_PUBKEY_B64 = "RWSIt7W8ah5NvMXMLQ3+T2flXrQ+J6xoDxDrL62I+8iEkR04YIAlXa12"

function Verify-MinisignSignature {
    # Verify a detached minisign Ed25519 signature of checksums.txt.
    #
    # minisign's "Ed" (raw) signature format:
    #   Line 1 — untrusted comment (ignored)
    #   Line 2 — base64( 2-byte algo "Ed" | 8-byte key-id | 64-byte Ed25519 sig )
    #   Line 3 — trusted comment (ignored for file-body verification)
    #   Line 4 — base64( 64-byte global sig covering line2_sig||trusted_comment )
    #
    # We delegate verification to the minisign binary (same as install.sh on
    # Linux) rather than attempting a .NET Ed25519 implementation. Rationale:
    #
    #   .NET Ed25519 support (OID 1.3.101.112) via ECDsa/AsymmetricAlgorithm is
    #   not reliably available across the Windows PowerShell install base:
    #     - PowerShell 5.1 / .NET Framework 4.x  — Ed25519 not supported
    #     - PowerShell 7.x / .NET 6 or 8         — Ed25519 not exposed cleanly
    #     - PowerShell 7.4+ / .NET 9              — supported, but not the default
    #   A pure-.NET implementation would silently degrade on PS 5.1 (the default
    #   Windows shell) or require fragile runtime-version detection. The minisign
    #   binary is a single self-contained Windows executable with no runtime
    #   dependencies and is available through all major Windows package managers.
    #
    # The trust root (the Ed25519 key bytes) is embedded as $MINISIGN_PUBKEY_B64
    # above — NOT fetched over the network — so an attacker who controls the
    # download host cannot substitute a different key.
    param(
        [string]$ChecksumsFile,
        [string]$SigFile,
        [string]$PubKeyB64
    )

    # Require the minisign binary. If it is missing, first try to bootstrap it
    # automatically via winget (the Windows 10/11 package manager) so the
    # one-line install completes on a clean box. This ONLY installs the
    # verifier — it never bypasses the signature check below. Verification stays
    # fully fail-closed: if the bootstrap is unavailable or fails, installation
    # is aborted rather than proceeding with an unverified binary.
    if (-not (Get-Command minisign -ErrorAction SilentlyContinue)) {
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            Write-Host "  minisign not found — installing it via winget (required to verify the release signature)..."
            # Non-interactive: accept agreements up front and disable prompts so
            # the piped (irm | iex) install cannot hang waiting for input.
            # --exact --id pins the well-known package rather than a name match.
            & winget install --id jedisct1.Minisign --exact --source winget `
                --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1 | Out-Host
            # winget places its shims under %LOCALAPPDATA%\Microsoft\WinGet\Links,
            # which is on the *persisted* user PATH but not this process's stale
            # copy. Refresh PATH from the registry (Machine + User) so the freshly
            # installed minisign is discoverable without opening a new shell.
            $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                        [System.Environment]::GetEnvironmentVariable('Path', 'User')
        }
    }

    # Fail closed if minisign is still unavailable (winget absent, or the
    # bootstrap failed). Clean up $tmpDir before exiting so the partial download
    # does not linger in %TEMP% (the caller does not get a chance to clean up
    # after exit 1).
    if (-not (Get-Command minisign -ErrorAction SilentlyContinue)) {
        Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
        Write-Error "mootx01: release signature verification requires the minisign binary."
        Write-Error "mootx01: automatic install via winget was unavailable or failed. Install it manually:"
        Write-Error "  winget install minisign      (Windows 10/11 Package Manager)"
        Write-Error "  scoop install minisign       (Scoop package manager)"
        Write-Error "  choco install minisign       (Chocolatey)"
        Write-Error "  https://jedisct1.github.io/minisign/ (direct download, zero dependencies)"
        Write-Error "mootx01: minisign verifies the Ed25519 release signature — do not bypass this check."
        exit 1
    }

    # Write the embedded public key to a temp file. The key is embedded as a
    # constant (not fetched) so the trust root survives even if the download
    # host is compromised. The temp file is removed in the finally block.
    $tmpPubKey = Join-Path $env:TEMP "mootx01-pubkey-$([System.IO.Path]::GetRandomFileName()).pub"
    try {
        # Reconstruct the minisign .pub file format: untrusted comment + key line.
        # The key id BC4D1E6ABCB5B788 matches distribution/minisign.pub in the repo.
        $pubKeyContent = "untrusted comment: minisign public key BC4D1E6ABCB5B788`n$PubKeyB64`n"
        [System.IO.File]::WriteAllText($tmpPubKey, $pubKeyContent, [System.Text.Encoding]::ASCII)

        # -V = verify, -p = public key file, -m = signed file, -x = detached sig
        $result = & minisign -V -p $tmpPubKey -m $ChecksumsFile -x $SigFile 2>&1
        if ($LASTEXITCODE -ne 0) {
            Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
            Write-Error "mootx01: minisign signature verification FAILED for checksums.txt."
            Write-Error "mootx01: the release may have been tampered with — do not proceed."
            Write-Error $result
            exit 1
        }
    } finally {
        Remove-Item -Force $tmpPubKey -ErrorAction SilentlyContinue
    }

    Write-Host "  Signature OK (checksums.txt Ed25519 verified)"
}

function Verify-Checksum {
    # Verify the SHA-256 digest of a downloaded asset against checksums.txt.
    # Fails closed — exits 1 on any mismatch or if the asset is absent from
    # checksums.txt.
    param(
        [string]$File,
        [string]$ChecksumsFile,
        [string]$AssetName
    )

    $lines = Get-Content $ChecksumsFile -Encoding UTF8
    $expected = $null
    foreach ($line in $lines) {
        # checksums.txt format: "<sha256hex>  <filename>" (two spaces, GNU sha256sum style)
        $parts = $line -split '\s+'
        if ($parts.Count -ge 2 -and $parts[-1] -eq $AssetName) {
            $expected = $parts[0]
            break
        }
    }
    if (-not $expected) {
        Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
        Write-Error "mootx01: no checksum entry found for '$AssetName' in checksums.txt."
        exit 1
    }

    $hash = (Get-FileHash $File -Algorithm SHA256).Hash.ToLower()
    if ($hash -ne $expected.ToLower()) {
        Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
        Write-Error "mootx01: SHA-256 checksum mismatch for $AssetName."
        Write-Error "  expected: $expected"
        Write-Error "  actual:   $hash"
        exit 1
    }
    Write-Host "  Checksum OK ($AssetName)"
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

# 3. Verify integrity BEFORE extracting.
#    Verification order (fail closed at each step):
#      a. Download checksums.txt and its detached Ed25519 signature.
#      b. Verify the minisign signature — confirms checksums.txt came from the
#         project maintainers and was not swapped in transit. Trust root is the
#         key embedded as $MINISIGN_PUBKEY_B64 above, NOT fetched over the network.
#      c. Verify the SHA-256 of the ZIP against checksums.txt — confirms the
#         archive was not corrupted or substituted.
#      Both steps must pass; failure at either step exits non-zero before any
#      code from the archive can be executed.
$checksumsUrl = "https://github.com/$REPO/releases/download/$Version/checksums.txt"
$sigUrl       = "https://github.com/$REPO/releases/download/$Version/checksums.txt.minisig"
try {
    Invoke-WebRequest $checksumsUrl -OutFile (Join-Path $tmpDir "checksums.txt")
} catch {
    Write-Error "mootx01: download failed: $checksumsUrl`n$_"
    Remove-Item -Recurse -Force $tmpDir
    exit 1
}
try {
    Invoke-WebRequest $sigUrl -OutFile (Join-Path $tmpDir "checksums.txt.minisig")
} catch {
    Write-Error "mootx01: download failed: $sigUrl`n$_"
    Remove-Item -Recurse -Force $tmpDir
    exit 1
}

# 3a. Verify Ed25519 signature of checksums.txt before trusting any digest it
#     records. This step must succeed before SHA-256 is even consulted.
Write-Host "Verifying release signature..."
Verify-MinisignSignature `
    -ChecksumsFile (Join-Path $tmpDir "checksums.txt") `
    -SigFile       (Join-Path $tmpDir "checksums.txt.minisig") `
    -PubKeyB64     $MINISIGN_PUBKEY_B64

# 3b. Verify the ZIP SHA-256 against the now-authenticated checksums.txt.
Write-Host "Verifying archive checksum..."
Verify-Checksum `
    -File          (Join-Path $tmpDir $asset) `
    -ChecksumsFile (Join-Path $tmpDir "checksums.txt") `
    -AssetName     $asset

# 3c. Extract AFTER both checks pass.
Expand-Archive (Join-Path $tmpDir $asset) -DestinationPath $tmpDir -Force
if (-not (Test-Path (Join-Path $tmpDir "mootx01.exe"))) {
    Write-Error "Archive did not contain mootx01.exe"
    Remove-Item -Recurse -Force $tmpDir
    exit 1
}

# 3d. Optional Authenticode check: verify the extracted executable carries a
#     valid digital signature from the expected publisher. Notarized/signed
#     binaries from the release pipeline pass; a substituted or unsigned binary
#     is rejected. Best-effort — warns rather than blocking if signature status
#     cannot be determined (e.g. older PowerShell without Get-AuthenticodeSignature).
foreach ($exeName in @("mootx01.exe", "moot-mgr.exe")) {
    $exePath = Join-Path $tmpDir $exeName
    if (-not (Test-Path $exePath)) { continue }
    try {
        $sig = Get-AuthenticodeSignature $exePath -ErrorAction Stop
        if ($sig.Status -ne "Valid") {
            Write-Error "mootx01: Authenticode check FAILED for $exeName (status: $($sig.Status))."
            Write-Error "mootx01: the binary may have been tampered with — do not proceed."
            Remove-Item -Recurse -Force $tmpDir
            exit 1
        }
        Write-Host "  Authenticode OK ($exeName — $($sig.SignerCertificate.Subject))"
    } catch {
        # Get-AuthenticodeSignature unavailable or threw unexpectedly. Treat as
        # advisory: the minisign + SHA-256 checks above already verified the
        # archive; this is a belt-and-suspenders code-signing check.
        Write-Warning "mootx01: could not check Authenticode signature for $exeName — skipping (non-fatal): $_"
    }
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
