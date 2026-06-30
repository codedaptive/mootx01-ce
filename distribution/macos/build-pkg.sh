#!/bin/bash
# build-pkg.sh — assemble the macOS .pkg installer from pre-built binaries.
#
# Usage:
#   ./build-pkg.sh <version> <arch> <mootx01-binary> <moot-mgr-binary> <setup-binary>
#
# Produces: mootx01-<version>-macos-<arch>.pkg (signed + ready for notarization).
#
# Strategy: the .pkg installs the payload into a root-owned staging area under
# /Library/Application Support/com.codedaptive.mootx01/staging. The postinstall
# script validates that staging area (ownership, not-a-symlink, permissions) then
# relocates the files to ~/.mootx01/ in the *installing user's* home.
# Using /Library/Application Support instead of /tmp eliminates the world-writable
# staging attack surface: /Library is owned by root:wheel and not world-writable,
# so a local attacker cannot pre-create or race-modify the staging directory.
#
# Requires:
#   - pkgbuild, productbuild, productsign, codesign (Xcode command line tools)
#   - INSTALLER_IDENTITY env var (e.g. "Developer ID Installer: Codedaptive, LLC (G94X5T5GK7)")
#   - APP_IDENTITY env var (e.g. "Developer ID Application: Codedaptive, LLC (G94X5T5GK7)")
#     used to seal the bundled Mootx01Setup.app so the .pkg passes notarization.

set -euo pipefail

VERSION="${1:?Usage: build-pkg.sh <version> <arch> <mootx01> <moot-mgr> <setup>}"
ARCH="${2:?}"
MOOTX01_BIN="${3:?}"
MGR_BIN="${4:?}"
SETUP_BIN="${5:?}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DIST_DIR="$SCRIPT_DIR"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PKG_ID="com.codedaptive.mootx01"
ASSET="mootx01-${VERSION}-macos-${ARCH}.pkg"

echo "Building macOS .pkg: $ASSET"

# 1. Stage the payload. The .pkg places these into a root-owned staging directory
#    under /Library/Application Support; the postinstall script validates and
#    moves them to ~/.mootx01/. /Library/Application Support is owned by
#    root:wheel (mode 755, not world-writable), so no local attacker can
#    pre-create or race-replace this staging path without root.
STAGING_ROOT="/Library/Application Support/com.codedaptive.mootx01/staging"
PAYLOAD="$WORK/payload${STAGING_ROOT}"
mkdir -p "$PAYLOAD/bin"
cp "$MOOTX01_BIN" "$PAYLOAD/bin/mootx01"
cp "$MGR_BIN"     "$PAYLOAD/bin/moot-mgr"
chmod 755 "$PAYLOAD/bin/mootx01" "$PAYLOAD/bin/moot-mgr"

# 2. Build the setup assistant .app bundle from the bare executable.
APP="$PAYLOAD/Mootx01Setup.app"
mkdir -p "$APP/Contents/MacOS"
cp "$SETUP_BIN"              "$APP/Contents/MacOS/Mootx01Setup"
cp "$DIST_DIR/Info.plist"    "$APP/Contents/Info.plist"
chmod 755 "$APP/Contents/MacOS/Mootx01Setup"

# Copy any SPM resource bundles beside the setup binary into the .app.
SETUP_DIR="$(dirname "$SETUP_BIN")"
for bundle in "$SETUP_DIR"/*.bundle; do
    [ -d "$bundle" ] && ditto "$bundle" "$APP/Contents/MacOS/$(basename "$bundle")"
done

# Seal the assembled .app bundle. The bare setup executable was already
# runtime-signed before it was copied in, but notarization requires the WHOLE
# .app bundle (its Info.plist, nested resource bundles, and main executable) to
# carry a Developer ID Application signature with the hardened runtime. Sign
# inside-out: any nested resource bundles that embed a Mach-O first, then the
# .app itself. Without this seal the notary service returns status: Invalid.
if [ -n "${APP_IDENTITY:-}" ]; then
    find "$APP/Contents/MacOS" -name '*.bundle' -type d -print0 \
        | while IFS= read -r -d '' nested; do
            codesign --force --options runtime --timestamp \
                --sign "$APP_IDENTITY" "$nested"
        done
    codesign --force --options runtime --timestamp \
        --sign "$APP_IDENTITY" "$APP"
    codesign --verify --strict --verbose=2 "$APP"
    echo "Signed .app bundle: $APP"
else
    echo "WARNING: APP_IDENTITY not set — .app bundle left unsigned (notarization will fail)"
fi

# Copy resource bundles for the CLI binaries too.
MOOTX01_DIR="$(dirname "$MOOTX01_BIN")"
for bundle in "$MOOTX01_DIR"/*.bundle; do
    [ -d "$bundle" ] && ditto "$bundle" "$PAYLOAD/bin/$(basename "$bundle")"
done
MGR_DIR="$(dirname "$MGR_BIN")"
for bundle in "$MGR_DIR"/*.bundle; do
    [ -d "$bundle" ] && ditto "$bundle" "$PAYLOAD/bin/$(basename "$bundle")"
done

echo "Payload contents:"
find "$WORK/payload" -type f | sed "s|$WORK/payload||"

# 3. Build the component package.
COMPONENT="$WORK/mootx01-component.pkg"
pkgbuild \
    --root "$WORK/payload" \
    --identifier "$PKG_ID" \
    --version "${VERSION#v}" \
    --install-location "/" \
    --scripts "$DIST_DIR/scripts" \
    "$COMPONENT"

echo "Component package: $(du -h "$COMPONENT" | cut -f1)"

# 4. Build the distribution (product) package with branded panels.
UNSIGNED="$WORK/mootx01-unsigned.pkg"
productbuild \
    --distribution "$DIST_DIR/distribution.xml" \
    --resources "$DIST_DIR/resources" \
    --package-path "$WORK" \
    "$UNSIGNED"

echo "Unsigned package: $(du -h "$UNSIGNED" | cut -f1)"

# 5. Sign the package (if INSTALLER_IDENTITY is set).
if [ -n "${INSTALLER_IDENTITY:-}" ]; then
    productsign \
        --sign "$INSTALLER_IDENTITY" \
        "$UNSIGNED" \
        "$ASSET"
    echo "Signed: $ASSET ($(du -h "$ASSET" | cut -f1))"
else
    cp "$UNSIGNED" "$ASSET"
    echo "WARNING: unsigned package (INSTALLER_IDENTITY not set): $ASSET"
fi

echo "Done: $(pwd)/$ASSET"
