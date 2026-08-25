#!/bin/bash
# build-pkg.sh — assemble the macOS .pkg installer from pre-built binaries.
#
# Usage:
#   ./build-pkg.sh <version> <arch> <mootx01-binary> <moot-mgr-binary> <setup-binary> [daemon-binary]
#
# [daemon-binary] (MACD-2c2): the mootx01-daemon thin-shell executable. When
# supplied it is wrapped app-like as bin/Mootx01DaemonProvider.app (the signed
# daemon provider bundle) inside the payload; the postinstall's existing bin/
# relocation places it at ~/.mootx01/bin/Mootx01DaemonProvider.app, where
# `mootx01 install` registers and starts the enabled Community provider
# (InstallerCore DaemonBundle is the constant surface these spellings are
# parity-checked against).
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

VERSION="${1:?Usage: build-pkg.sh <version> <arch> <mootx01> <moot-mgr> <setup> [daemon]}"
ARCH="${2:?}"
MOOTX01_BIN="${3:?}"
MGR_BIN="${4:?}"
SETUP_BIN="${5:?}"
DAEMON_BIN="${6:-}"

# NEW-4 (Perkins): the entire daemon-bundle block below — including its signing,
# entitlement and profile guards — is skipped when DAEMON_BIN is empty. A
# find-miss in CI would therefore publish a signed, notarized pkg with NO
# provider bundle and no guard ever firing. Under REQUIRE_SIGNING the bundle is
# mandatory, so its absence fails the build here, before anything is staged.
if [ -n "${REQUIRE_SIGNING:-}" ] && [ -z "$DAEMON_BIN" ]; then
    echo "ERROR: REQUIRE_SIGNING is set but no daemon provider binary was passed" >&2
    echo "       (argument 6 is empty). A release pkg must carry the signed daemon" >&2
    echo "       provider bundle; publishing without it would ship an installer whose" >&2
    echo "       provider is simply missing, with none of the signing guards reached." >&2
    exit 1
fi
if [ -n "${REQUIRE_SIGNING:-}" ] && [ ! -f "$DAEMON_BIN" ]; then
    echo "ERROR: REQUIRE_SIGNING is set but the daemon provider binary does not exist:" >&2
    echo "       $DAEMON_BIN" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DIST_DIR="$SCRIPT_DIR"
# Explicit temp root: `mktemp -d` with no template does not reliably honor
# TMPDIR on macOS (it can fall back to the per-user confstr directory), and
# build-product placement is a policy matter for CI and dev-volume builds
# alike. Naming the template makes the location observable and overridable.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mootx01-pkg-build.XXXXXXXX")"
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

# 1b. MACD-2c2: wrap the daemon provider shell app-like as
#     bin/Mootx01DaemonProvider.app. The bundle rides the bin/ relocation
#     contract (postinstall places bin/ wholesale), so no second placement
#     rule exists. LaunchAgent ProgramArguments point INSIDE this bundle's
#     Contents/MacOS — never at a raw binary (mission hard rule); the
#     spellings here are parity-checked against InstallerCore DaemonBundle.
if [ -n "$DAEMON_BIN" ]; then
    DAEMON_APP="$PAYLOAD/bin/Mootx01DaemonProvider.app"
    mkdir -p "$DAEMON_APP/Contents/MacOS"
    cp "$DAEMON_BIN" "$DAEMON_APP/Contents/MacOS/Mootx01DaemonProvider"
    chmod 755 "$DAEMON_APP/Contents/MacOS/Mootx01DaemonProvider"
    # A minimal, generated Info.plist: the bundle is a background executable
    # (LSUIElement), identified as the DIRECT-install daemon provider —
    # distinct from the sandboxed nested helper's identifier.
    cat > "$DAEMON_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.codedaptive.mootx01.macos.daemonprovider</string>
    <key>CFBundleExecutable</key>
    <string>Mootx01DaemonProvider</string>
    <key>CFBundleName</key>
    <string>Mootx01DaemonProvider</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION#v}</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST
    if [ -n "${APP_IDENTITY:-}" ]; then
        # The provider is only ELIGIBLE at runtime if its signature carries the
        # App Group and the team Keychain group: ProviderEligibilityJudge
        # refuses a signed process whose entitlements lack them, and K_install
        # lives in the team Keychain group. Signing without entitlements ships
        # a structurally ineligible daemon (Adams MAJOR-4), so the entitlements
        # are generated here — with the TEAM PREFIX EXPANDED, because codesign
        # does not expand $(AppIdentifierPrefix) (that is an Xcode substitution)
        # and an unexpanded group would match nothing while looking correct.
        #
        # The team id comes from APP_IDENTITY's trailing "(TEAMID)" — the same
        # identity that signs, so the prefix can never disagree with the signer.
        DAEMON_TEAM_ID="$(printf '%s' "$APP_IDENTITY" | /usr/bin/sed -n 's/.*(\([A-Z0-9]\{6,\}\))$/\1/p')"
        if [ -z "$DAEMON_TEAM_ID" ]; then
            echo "ERROR: cannot extract a team identifier from APP_IDENTITY" >&2
            echo "       (expected a trailing \"(TEAMID)\"): $APP_IDENTITY" >&2
            exit 1
        fi
        DAEMON_ENTITLEMENTS="$WORK/daemon-provider.entitlements"
        cat > "$DAEMON_ENTITLEMENTS" <<ENTITLEMENTS
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.application-groups</key>
    <array>
        <string>${DAEMON_TEAM_ID}.group.com.codedaptive.mootx01</string>
    </array>
    <key>keychain-access-groups</key>
    <array>
        <string>${DAEMON_TEAM_ID}.com.codedaptive.mootx01.shared</string>
    </array>
</dict>
ENTITLEMENTS
        printf '</plist>\n' >> "$DAEMON_ENTITLEMENTS"
        # An App Group entitlement on a Developer ID artifact is only HONORED
        # when a provisioning profile granting it is embedded in the bundle;
        # without one the kernel refuses the launch outright (observed: SIGKILL
        # at exec, verified in the MACD-2c2 pkg proof). So the two must travel
        # together: entitlements without a profile is an artifact that cannot
        # run, which is worse than one that is merely ineligible.
        #
        # DAEMON_PROVISIONING_PROFILE is the path to the .provisionprofile that
        # grants group.com.codedaptive.mootx01 and the team Keychain group to
        # this bundle identifier. CI supplies it from a secret; a local layout
        # build may omit it and gets an honestly-labelled unrunnable artifact.
        if [ -n "${DAEMON_PROVISIONING_PROFILE:-}" ]; then
            [ -f "$DAEMON_PROVISIONING_PROFILE" ] || {
                echo "ERROR: DAEMON_PROVISIONING_PROFILE is set but not a file:" >&2
                echo "       $DAEMON_PROVISIONING_PROFILE" >&2
                exit 1
            }
            # A path check is NOT a validity check: any 18 bytes of garbage
            # satisfies `-f`, embeds happily, and passes the codesign
            # entitlement readback — producing exactly the signed, notarizable,
            # killed-at-exec artifact this guard exists to prevent. So the
            # profile's CONTENT is validated in the same fail-closed shape as
            # the readback below: it must decode as CMS, parse as a plist, and
            # NAME both entitlement groups it is supposed to grant.
            PROFILE_PLIST="$WORK/daemon-profile.plist"
            if ! /usr/bin/security cms -D -i "$DAEMON_PROVISIONING_PROFILE" \
                    > "$PROFILE_PLIST" 2>/dev/null; then
                echo "ERROR: DAEMON_PROVISIONING_PROFILE is not a decodable provisioning" >&2
                echo "       profile (security cms -D failed): $DAEMON_PROVISIONING_PROFILE" >&2
                exit 1
            fi
            if ! /usr/bin/plutil -p "$PROFILE_PLIST" > "$PROFILE_PLIST.txt" 2>/dev/null; then
                echo "ERROR: the decoded provisioning profile is not a readable plist:" >&2
                echo "       $DAEMON_PROVISIONING_PROFILE" >&2
                exit 1
            fi
            /usr/bin/python3 - "$PROFILE_PLIST" "$DAEMON_TEAM_ID" <<'PY'
import plistlib
import sys

path, team = sys.argv[1:]
with open(path, "rb") as stream:
    profile = plistlib.load(stream)
entitlements = profile.get("Entitlements", {})
expected_app = f"{team}.com.codedaptive.mootx01.macos.daemonprovider"
if entitlements.get("com.apple.application-identifier") != expected_app:
    raise SystemExit(f"profile application identifier must be {expected_app}")
groups = entitlements.get("com.apple.security.application-groups", [])
if "group.com.codedaptive.mootx01" not in groups:
    raise SystemExit("profile does not grant group.com.codedaptive.mootx01")
keychain = entitlements.get("keychain-access-groups", [])
if f"{team}.com.codedaptive.mootx01.shared" not in keychain and f"{team}.*" not in keychain:
    raise SystemExit("profile does not authorize the daemon Keychain access group")
PY
            cp "$DAEMON_PROVISIONING_PROFILE" "$DAEMON_APP/Contents/embedded.provisionprofile"
            echo "Embedded provisioning profile (content validated: identifier + App Group + Keychain)"
        elif [ -n "${REQUIRE_SIGNING:-}" ]; then
            echo "ERROR: the daemon provider bundle is signed with App Group and Keychain" >&2
            echo "       entitlements, but DAEMON_PROVISIONING_PROFILE is empty. Without an" >&2
            echo "       embedded profile granting those entitlements the artifact is killed" >&2
            echo "       at launch — refusing to publish a daemon that cannot start." >&2
            exit 1
        else
            echo "WARNING: no DAEMON_PROVISIONING_PROFILE — the entitled daemon bundle will"
            echo "         be REFUSED AT LAUNCH on this machine (local layout build only)."
        fi
        "$SCRIPT_DIR/sign-retry.sh" codesign --force --options runtime --timestamp \
            --entitlements "$DAEMON_ENTITLEMENTS" \
            --sign "$APP_IDENTITY" "$DAEMON_APP"
        codesign --verify --strict --verbose=2 "$DAEMON_APP"
        # Readback: assert the signature actually carries both groups rather
        # than trusting that the --entitlements flag was honored (Perkins
        # P-c2-10 mandates readback validation, not intent).
        DAEMON_ENTITLEMENT_READBACK="$(codesign -d --entitlements :- "$DAEMON_APP" 2>/dev/null || true)"
        printf '%s' "$DAEMON_ENTITLEMENT_READBACK" \
            | /usr/bin/grep -q "${DAEMON_TEAM_ID}.group.com.codedaptive.mootx01" \
            || { echo "ERROR: daemon bundle signature is missing the App Group entitlement" >&2; exit 1; }
        printf '%s' "$DAEMON_ENTITLEMENT_READBACK" \
            | /usr/bin/grep -q "${DAEMON_TEAM_ID}.com.codedaptive.mootx01.shared" \
            || { echo "ERROR: daemon bundle signature is missing the team Keychain group entitlement" >&2; exit 1; }
        echo "Signed daemon provider bundle (entitlements readback verified): $DAEMON_APP"
    elif [ -n "${REQUIRE_SIGNING:-}" ]; then
        # An unsigned daemon provider is not a degraded artifact, it is an
        # INELIGIBLE one: an unsigned shell is refused before the provider lock
        # by design. Shipping one would be the mission's "unsigned fallback"
        # hard stop (Adams MAJOR-7), so a release build fails closed here
        # exactly as it does for a missing installer identity.
        echo "ERROR: APP_IDENTITY is empty but REQUIRE_SIGNING is set — refusing to" >&2
        echo "       publish a pkg containing an unsigned (structurally ineligible)" >&2
        echo "       daemon provider bundle. Configure the application signing" >&2
        echo "       identity/secret, or unset REQUIRE_SIGNING for a local build." >&2
        exit 1
    else
        echo "WARNING: APP_IDENTITY not set — daemon provider bundle left unsigned"
        echo "         (local layout build only: an unsigned provider is refused"
        echo "          before the provider lock and can never be eligible)"
    fi
fi

# 2. Build the setup assistant .app bundle from the bare executable.
APP="$PAYLOAD/Mootx01Setup.app"
mkdir -p "$APP/Contents/MacOS"
cp "$SETUP_BIN"              "$APP/Contents/MacOS/Mootx01Setup"
cp "$DIST_DIR/Info.plist"    "$APP/Contents/Info.plist"
chmod 755 "$APP/Contents/MacOS/Mootx01Setup"

# Copy any SPM resource bundles beside the setup binary into the .app.
# Resource bundles belong in Contents/Resources (Bundle.main.resourceURL is
# the first place SPM's resource accessor looks inside an .app); staging them
# in Contents/MacOS both violates bundle layout and made codesign treat them
# as code bundles ("bundle format unrecognized" on resource-only bundles).
SETUP_DIR="$(dirname "$SETUP_BIN")"
mkdir -p "$APP/Contents/Resources"
for bundle in "$SETUP_DIR"/*.bundle; do
    [ -d "$bundle" ] && ditto "$bundle" "$APP/Contents/Resources/$(basename "$bundle")"
done

# Seal the assembled .app bundle. The bare setup executable was already
# runtime-signed before it was copied in, but notarization requires the WHOLE
# .app bundle (its Info.plist, nested resource bundles, and main executable) to
# carry a Developer ID Application signature with the hardened runtime. Sign
# inside-out: any nested resource bundles that embed a Mach-O first, then the
# .app itself. Without this seal the notary service returns status: Invalid.
if [ -n "${APP_IDENTITY:-}" ]; then
    # sign-retry.sh: --timestamp contacts Apple's TSA, which blips; retry
    # transient outages instead of failing the build (see sign-retry.sh).
    # Sign only nested bundles that actually embed Mach-O code. Resource-only
    # bundles (e.g. PersistenceKit_SQLCipher.bundle) are not code and are
    # covered by the outer .app seal; codesigning them directly fails with
    # "bundle format unrecognized, invalid, or unsuitable".
    find "$APP/Contents" -name '*.bundle' -type d -print0 \
        | while IFS= read -r -d '' nested; do
            if find "$nested" -type f -print0 | xargs -0 file 2>/dev/null | grep -q 'Mach-O'; then
                "$SCRIPT_DIR/sign-retry.sh" codesign --force --options runtime --timestamp \
                    --sign "$APP_IDENTITY" "$nested"
            else
                echo "Skipping resource-only bundle (sealed by .app signature): $nested"
            fi
        done
    "$SCRIPT_DIR/sign-retry.sh" codesign --force --options runtime --timestamp \
        --sign "$APP_IDENTITY" "$APP"
    codesign --verify --strict --verbose=2 "$APP"
    echo "Signed .app bundle: $APP"
elif [ -n "${REQUIRE_SIGNING:-}" ]; then
    echo "ERROR: APP_IDENTITY is empty but REQUIRE_SIGNING is set — refusing to" >&2
    echo "       publish a pkg containing an unsigned setup assistant .app." >&2
    exit 1
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
#
# The Distribution XML is generated per-arch: hostArchitectures on the
# <options/> element (the only place Installer reads it) must name the
# payload's architecture, or Installer treats the package as Intel-only
# and prompts Apple Silicon Macs to install Rosetta. Rewritten with an
# XML parser, never sed/regex (.claude/rules/no-regex-structured-files.md).
# python3 is safe here: build-pkg.sh only runs on CI runners and dev
# machines with Xcode tools, never on end-user Macs (unlike postinstall).
DIST_XML="$WORK/distribution.xml"
python3 - "$DIST_DIR/distribution.xml" "$DIST_XML" "$ARCH" <<'PY'
import sys
import xml.etree.ElementTree as ET

src, dst, arch = sys.argv[1], sys.argv[2], sys.argv[3]
tree = ET.parse(src)
options = tree.getroot().find("options")
if options is None:
    raise SystemExit("distribution.xml: missing <options/> element "
                     "(hostArchitectures anchor) — refusing to build a "
                     "pkg that would prompt for Rosetta")
options.set("hostArchitectures", arch)
tree.write(dst, encoding="utf-8", xml_declaration=True)
PY

UNSIGNED="$WORK/mootx01-unsigned.pkg"
productbuild \
    --distribution "$DIST_XML" \
    --resources "$DIST_DIR/resources" \
    --package-path "$WORK" \
    "$UNSIGNED"

echo "Unsigned package: $(du -h "$UNSIGNED" | cut -f1)"

# 5. Sign the package.
#
# The .pkg is a root-authorized installer, so a RELEASE build must fail
# closed rather than ship unsigned (SECURITY 927f38c4). The release workflow's
# pkg job sets REQUIRE_SIGNING=1 (.github/workflows/release.yml, "Build .pkg"
# step) together with APP_IDENTITY and DAEMON_PROVISIONING_PROFILE; without an
# installer identity there, the build aborts. LOCAL builds (`make pkg`, the CE installer harness) leave
# REQUIRE_SIGNING unset and are allowed to produce an unsigned, clearly
# labeled package for layout testing — those artifacts are never published.
if [ -n "${INSTALLER_IDENTITY:-}" ]; then
    # productsign timestamps unconditionally — same TSA dependency, same retry.
    "$SCRIPT_DIR/sign-retry.sh" productsign \
        --sign "$INSTALLER_IDENTITY" \
        "$UNSIGNED" \
        "$ASSET"
    echo "Signed: $ASSET ($(du -h "$ASSET" | cut -f1))"
elif [ -n "${REQUIRE_SIGNING:-}" ]; then
    echo "ERROR: INSTALLER_IDENTITY is empty but REQUIRE_SIGNING is set — refusing to" >&2
    echo "       publish an unsigned root-authorized .pkg. Configure the installer" >&2
    echo "       signing identity/secret, or unset REQUIRE_SIGNING for a local build." >&2
    exit 1
else
    cp "$UNSIGNED" "$ASSET"
    echo "WARNING: unsigned package (local build, INSTALLER_IDENTITY not set): $ASSET"
fi

echo "Done: $(pwd)/$ASSET"
