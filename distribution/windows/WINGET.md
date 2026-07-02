# Winget submission — per-release process

MOOTx01 is distributed on Windows both as a standalone setup EXE (download
and double-click) and through the [Windows Package Manager][winget]
(`winget install Codedaptive.MOOTx01`). This document is the per-release
runbook for the winget path.

The manifests live in [`winget/`](./winget/):

| File | Purpose |
|---|---|
| `Codedaptive.MOOTx01.yaml` | Version manifest — package id + version + default locale |
| `Codedaptive.MOOTx01.installer.yaml` | Installer URLs, SHA-256, silent switches, scope |
| `Codedaptive.MOOTx01.locale.en-US.yaml` | Publisher, license, name, description |

These are the source of truth. The copies that land in the community
[`winget-pkgs`][winget-pkgs] repo are generated from them each release.

## What the release build already produces

The GitHub release workflow (`.github/workflows/release.yml`) builds the
Inno Setup EXE for both architectures and publishes them as release assets,
alongside a `checksums.txt` file and a minisign signature. For a release tagged
`vX.Y.Z-beta` the relevant assets are:

- `mootx01-X.Y.Z-windows-x86_64-setup.exe`
- `mootx01-X.Y.Z-windows-arm64-setup.exe`
- `checksums.txt` (contains the SHA-256 for every asset)

No extra CI is needed to *produce* the installer — the winget work is purely
authoring the manifest and submitting it.

## Per-release steps

1. **Confirm the release is published** with both Windows setup EXEs attached.
   Note the exact tag (e.g. `v1.0.5-beta`).

2. **Bump the version** in all three manifest files. `PackageVersion` must be
   identical across `Codedaptive.MOOTx01.yaml`,
   `Codedaptive.MOOTx01.installer.yaml`, and
   `Codedaptive.MOOTx01.locale.en-US.yaml`. Use the clean semver
   (`1.0.5`), not the tag qualifier.

3. **Update the two `InstallerUrl` values** in
   `Codedaptive.MOOTx01.installer.yaml` to point at the new tag's assets.

4. **Fill the two `InstallerSha256` values** from the published checksums.
   Do NOT recompute locally from a local build — hash the *published* asset,
   so the manifest matches what users actually download:

   ```powershell
   # From the release assets (x64 shown; repeat for arm64):
   $u = "https://github.com/codedaptive/mootx01-ce/releases/download/v1.0.5-beta/mootx01-1.0.5-windows-x86_64-setup.exe"
   irm $u -OutFile setup.exe
   (Get-FileHash setup.exe -Algorithm SHA256).Hash
   ```

   or read it straight out of the release's `checksums.txt`. Winget wants the
   hash uppercase; the manifest accepts either case. The placeholder in the
   committed manifest is 64 zeros — winget validation rejects it, which is
   deliberate: a submission that skipped this step fails loudly instead of
   shipping a wrong hash.

5. **Validate locally** on a Windows box with winget's client installed:

   ```powershell
   winget validate --manifest distribution\windows\winget
   # Optional end-to-end install test in a sandbox:
   winget install --manifest distribution\windows\winget
   ```

6. **Submit to the community repo.** Fork/branch [`winget-pkgs`][winget-pkgs]
   and copy the three files to the versioned path
   `manifests/c/Codedaptive/MOOTx01/<version>/`, then open a PR. The
   [`wingetcreate`][wingetcreate] tool automates the copy, version bump, and
   PR:

   ```powershell
   wingetcreate update Codedaptive.MOOTx01 `
     --version 1.0.5 `
     --urls "<x64 url>" "<arm64 url>" `
     --submit
   ```

   `wingetcreate update` re-downloads the URLs and computes the SHA-256 for
   you, so step 4 is a cross-check when using it rather than a manual edit.

7. **Wait for validation.** The winget-pkgs CI installs the package in a
   clean VM and uninstalls it. This is why the installer must complete fully
   unattended under `/VERYSILENT /SUPPRESSMSGBOXES` — the post-install
   client-wiring checkbox is `skipifsilent` and the uninstall notice is
   gated on `not UninstallSilent`, so neither blocks the VM.

## Notes

- **Pre-release / beta.** The community winget-pkgs repo does not list
  pre-release versions. While MOOTx01 is in `-beta`, the standalone EXE and
  the `install.ps1` script (download-then-run) are the Windows distribution
  channels; the
  manifests here are staged and validated so the winget submission is a
  single clean step the moment a non-beta `X.Y.Z` release ships. Keep the
  manifests current against the latest beta so the eventual submission is
  not a from-scratch effort.

- **Publisher identity.** `Codedaptive.MOOTx01` is the package identifier —
  `<Publisher>.<Package>`. It is claimed on first accepted submission; keep
  it stable across releases.

- **SmartScreen.** The setup EXE is unsigned (no Authenticode cert), so a
  direct download shows a SmartScreen warning on first run. Installing via
  winget does not surface that prompt. Signing is a separate, cost-gated
  decision (EV/OV code-signing certificate).

[winget]: https://learn.microsoft.com/windows/package-manager/
[winget-pkgs]: https://github.com/microsoft/winget-pkgs
[wingetcreate]: https://github.com/microsoft/winget-create
