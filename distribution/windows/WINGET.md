# Winget — how a release reaches the Windows Package Manager

MOOTx01 is distributed on Windows as a standalone setup EXE (download and
double-click) and through the [Windows Package Manager][winget]
(`winget install Codedaptive.MOOTx01`). Both come from the same release
tag, and the winget path is automated. This document says what the
automation does and what a maintainer does when it needs attention.

## What a release tag does

The Community Edition repository's `.github/workflows/release.yml` (the lane
that publishes to winget; the Enterprise lane ships no public Windows build
and signs nothing) runs on a `vX.Y.Z` tag:

1. Builds `mootx01.exe` and `moot-mgr.exe` for x86_64 and arm64, signs them
   (see [`SIGNING.md`](SIGNING.md)), builds the Inno Setup EXE for each
   architecture, signs that, and publishes the four assets with
   `checksums.txt` and its minisign signature.
2. `update-winget` rewrites the three manifests in [`winget/`](./winget/)
   with the new version, the two `InstallerUrl` values, and the SHA-256 of
   the published EXEs, and commits them back to the release branch. The
   manifests in the tree therefore describe the latest published release.
3. `winget-tag` submits the release to the community [`winget-pkgs`][winget-pkgs]
   repository with [`wingetcreate`][wingetcreate], which downloads the
   published EXEs and computes their hashes itself. Pre-release tags
   (`-beta`, `-rc`) are skipped: winget lists only final versions.

The three manifests are:

| File | Purpose |
|---|---|
| `Codedaptive.MOOTx01.yaml` | Version manifest: package id, version, default locale |
| `Codedaptive.MOOTx01.installer.yaml` | Installer URLs, SHA-256, silent switches, scope |
| `Codedaptive.MOOTx01.locale.en-US.yaml` | Publisher, license, name, description |

`PackageVersion` is identical across the three, and `License` in the locale
manifest must match the repository `LICENSE`.

## When a maintainer has to step in

- **The winget-pkgs PR fails validation.** The winget-pkgs CI installs and
  uninstalls the package in a clean VM under `/VERYSILENT`. The installer's
  post-install client-wiring step is `skipifsilent` and the uninstall notice
  is gated on `not UninstallSilent`, so neither blocks the VM. A Defender
  `validationDefender` failure means the EXE was not signed; check the
  release run's signing step.
- **Re-submitting without rebuilding.** Run `release.yml` manually with the
  `winget-tag` input set to the tag. That re-runs only the submission.
- **Hand-fixing a manifest.** `update-winget.sh <version>` rewrites the three
  files from the published assets; hash the published EXE, never a local
  build. Validate on a Windows box with
  `winget validate --manifest distribution\windows\winget` before opening a
  PR by hand.

## Publisher identity

`Codedaptive.MOOTx01` is the package identifier, `<Publisher>.<Package>`. It
was claimed on the first accepted submission and stays stable across
releases.

[winget]: https://learn.microsoft.com/windows/package-manager/
[winget-pkgs]: https://github.com/microsoft/winget-pkgs
[wingetcreate]: https://github.com/microsoft/winget-create
