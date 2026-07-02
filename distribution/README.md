# distribution/ — Platform Installer Resources

Resources consumed by the CI release pipeline to build native OS installers
alongside the existing curl-pipe and Homebrew install paths.

## macOS (.pkg)

`distribution/macos/` contains:

- `distribution.xml` — productbuild distribution descriptor (welcome → license → install)
- `build-pkg.sh` — assembles the .pkg from pre-built binaries + the setup assistant
- `Info.plist` — app bundle metadata for the setup assistant
- `scripts/postinstall` — creates PATH symlinks + launches the setup assistant
- `resources/` — HTML panels shown in the macOS Installer.app UI

The .pkg installs to `~/.mootx01/` (user-scoped, no admin elevation for file
placement). The postinstall script runs as root but writes to the user's home.
After file placement, it launches the Mootx01 Setup assistant
(`apps/Mootx01-Setup/`) which detects installed AI clients and lets the user
choose which ones to wire — a GUI projection of the same `mootx01 install`
flow the terminal users see.

Signing requires two certificates:
- **Developer ID Application** (existing) — codesigns the setup assistant binary
- **Developer ID Installer** (new) — signs the .pkg itself via `productsign`

Notarization uses the existing `notarytool` + API key pipeline.

## Windows (Inno Setup)

`distribution/windows/` contains:

- `mootx01-setup.iss` — Inno Setup 6 script

Produces a single `mootx01-<version>-windows-<arch>-setup.exe` that places
binaries in `%USERPROFILE%\.mootx01\bin`, adds the directory to the user PATH,
and runs `mootx01 install` as a post-install step for interactive client wiring.
Uninstall calls `mootx01 uninstall --yes` before removing files and preserves
the estate data directory.

No Authenticode code signing — Windows SmartScreen will show a warning on first
download. The project website carries a disclaimer about this.

This is a deliberate, documented accepted risk (SECURITY 927f38c4), not an
oversight. Windows Authenticode signing requires an EV/OV code-signing
certificate (annual cost, and EV needs a hardware token or cloud HSM that
complicates CI). Until install volume justifies that recurring expense, Windows
installers ship unsigned; integrity is provided out-of-band via `checksums.txt`
and its minisign signature (`checksums.txt.minisig`, verified against
`distribution/minisign.pub`). When a certificate is acquired, add a fail-closed
`signtool sign` step to the two Windows build jobs in
`.github/workflows/release.yml` and update this note. macOS `.pkg` installers,
by contrast, ARE signed (Developer ID Installer) and notarized, and the release
fails closed if that identity is absent.
