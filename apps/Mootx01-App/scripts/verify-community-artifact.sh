#!/bin/bash
set -euo pipefail

distribution=false
expected_team=""

usage() {
  echo "usage: $0 [--distribution] [--team-id TEAM_ID] /path/to/Mootx01\\ Community.app" >&2
  exit 64
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --distribution)
      distribution=true
      shift
      ;;
    --team-id)
      [[ $# -ge 2 ]] || usage
      expected_team="$2"
      shift 2
      ;;
    --*) usage ;;
    *) break ;;
  esac
done

[[ $# -eq 1 ]] || usage
app="$1"
[[ -d "$app" ]] || { echo "Community app bundle not found: $app" >&2; exit 66; }

fail() {
  echo "Community artifact verification failed: $*" >&2
  exit 1
}

info="$app/Contents/Info.plist"
binary="$app/Contents/MacOS/Mootx01 Community"
privacy="$app/Contents/Resources/PrivacyInfo.xcprivacy"
localization="$app/Contents/Resources/en.lproj/Localizable.strings"
profile="$app/Contents/embedded.provisionprofile"
[[ -f "$info" ]] || fail "Info.plist is missing"
[[ -x "$binary" ]] || fail "the Community executable is missing"
[[ -f "$privacy" ]] || fail "PrivacyInfo.xcprivacy is missing"
[[ -f "$localization" ]] || fail "English localization is missing"
[[ -f "$profile" ]] || fail "the embedded provisioning profile is missing"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$app" >/dev/null 2>&1 \
  || fail "deep strict code-sign verification did not pass"

signature="$(/usr/bin/codesign -dvvv "$app" 2>&1)"
/usr/bin/grep -q 'flags=.*runtime' <<<"$signature" \
  || fail "the hardened-runtime code-signing flag is absent"

authority="$(/usr/bin/sed -n 's/^Authority=//p' <<<"$signature" | /usr/bin/head -1)"
team="$(/usr/bin/sed -n 's/^TeamIdentifier=//p' <<<"$signature")"
[[ -n "$authority" && "$authority" != "-" ]] || fail "the bundle is unsigned or ad-hoc signed"
[[ -n "$team" && "$team" != "not set" ]] || fail "the signature has no TeamIdentifier"
if [[ -n "$expected_team" && "$team" != "$expected_team" ]]; then
  fail "TeamIdentifier is $team, expected $expected_team"
fi

if $distribution; then
  [[ "$authority" == Developer\ ID\ Application:* ]] \
    || fail "distribution mode requires a Developer ID Application signature; found $authority"
  /usr/sbin/spctl --assess --type execute --verbose=2 "$app" >/dev/null 2>&1 \
    || fail "Gatekeeper did not accept the distribution artifact (notarization/stapling incomplete)"
fi

scratch="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/mootx01-community-artifact.XXXXXX")"
trap '/bin/rm -rf -- "$scratch"' EXIT
/usr/bin/codesign -d --entitlements :- "$app" >"$scratch/entitlements.plist" 2>/dev/null \
  || fail "signed entitlements could not be read"
/usr/bin/security cms -D -i "$profile" >"$scratch/profile.plist" 2>/dev/null \
  || fail "embedded provisioning profile could not be decoded"

/usr/bin/python3 - "$info" "$privacy" "$scratch/entitlements.plist" \
  "$scratch/profile.plist" "$team" "$distribution" <<'PY'
import plistlib
import sys

info_path, privacy_path, entitlements_path, profile_path, team, distribution_raw = sys.argv[1:]
distribution = distribution_raw == "true"

def load(path):
    with open(path, "rb") as handle:
        return plistlib.load(handle)

info = load(info_path)
expected_info = {
    "CFBundleIdentifier": "com.codedaptive.mootx01.community.macos",
    "CFBundleDisplayName": "MOOTx01 Community",
    "CFBundleExecutable": "Mootx01 Community",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": "1.1.0",
    "CFBundleVersion": "1",
    "LSMinimumSystemVersion": "27.0",
    "LSApplicationCategoryType": "public.app-category.productivity",
    "ITSAppUsesNonExemptEncryption": False,
}
for key, expected in expected_info.items():
    actual = info.get(key)
    if actual != expected:
        raise SystemExit(f"Info.plist {key} is {actual!r}, expected {expected!r}")
if info.get("CFBundleSupportedPlatforms") != ["MacOSX"]:
    raise SystemExit("Info.plist does not identify exactly the macOS platform")

privacy = load(privacy_path)
if privacy.get("NSPrivacyTracking") is not False:
    raise SystemExit("privacy manifest must explicitly disable tracking")
if privacy.get("NSPrivacyTrackingDomains") != []:
    raise SystemExit("privacy manifest declares tracking domains")
if privacy.get("NSPrivacyCollectedDataTypes") != []:
    raise SystemExit("privacy manifest declares collected data")
if not isinstance(privacy.get("NSPrivacyAccessedAPITypes"), list):
    raise SystemExit("privacy manifest has no accessed-API declaration")

entitlements = load(entitlements_path)
required = {
    "com.apple.security.app-sandbox": True,
    "com.apple.security.network.client": True,
    "com.apple.security.files.user-selected.read-write": True,
    "com.apple.security.application-groups": [f"{team}.group.com.codedaptive.mootx01"],
    "keychain-access-groups": [f"{team}.com.codedaptive.mootx01.shared"],
    "com.apple.developer.team-identifier": team,
    "com.apple.application-identifier": f"{team}.com.codedaptive.mootx01.community.macos",
}
for key, expected in required.items():
    actual = entitlements.get(key)
    if actual != expected:
        raise SystemExit(f"signed entitlement {key} is {actual!r}, expected {expected!r}")

allowed = set(required) | {"com.apple.security.get-task-allow", "beta-reports-active"}
unexpected = sorted(set(entitlements) - allowed)
if unexpected:
    raise SystemExit("unexpected signed entitlements: " + ", ".join(unexpected))
if distribution and entitlements.get("com.apple.security.get-task-allow", False):
    raise SystemExit("distribution artifact carries get-task-allow")

profile = load(profile_path)
profile_entitlements = profile.get("Entitlements")
if not isinstance(profile_entitlements, dict):
    raise SystemExit("embedded profile has no entitlement authorization")

expected_application = f"{team}.com.codedaptive.mootx01.community.macos"
if profile_entitlements.get("com.apple.application-identifier") != expected_application:
    raise SystemExit("embedded profile does not authorize the Community application identifier")
if profile_entitlements.get("com.apple.developer.team-identifier") != team:
    raise SystemExit("embedded profile does not authorize the signing team")

def authorizes(values, expected):
    return isinstance(values, list) and (
        expected in values or f"{team}.*" in values
    )

expected_app_group = f"{team}.group.com.codedaptive.mootx01"
if not authorizes(
    profile_entitlements.get("com.apple.security.application-groups"),
    expected_app_group,
):
    raise SystemExit(
        "embedded profile does not authorize the Community/daemon App Group"
    )

expected_keychain_group = f"{team}.com.codedaptive.mootx01.shared"
if not authorizes(
    profile_entitlements.get("keychain-access-groups"),
    expected_keychain_group,
):
    raise SystemExit(
        "embedded profile does not authorize the Community/daemon Keychain group"
    )
PY

while IFS= read -r linked; do
  case "$linked" in
    /System/Library/*|/usr/lib/*) ;;
    *) fail "non-system linked image: $linked" ;;
  esac
done < <(/usr/bin/otool -L "$binary" | /usr/bin/tail -n +2 | /usr/bin/awk '{print $1}')

for forbidden_dir in Frameworks PlugIns XPCServices Extensions Library/SystemExtensions; do
  [[ ! -e "$app/Contents/$forbidden_dir" ]] \
    || fail "unexpected bundled component directory: Contents/$forbidden_dir"
done

if /usr/bin/find "$app/Contents" -print \
  | /usr/bin/grep -Eiq 'MootPro|MootEnterprise|Fulcrum|ProductDock|WorkPacket|Federation|CloudKit'; then
  fail "a forbidden edition capability is named in the bundle inventory"
fi

if /usr/bin/nm -gjU "$binary" 2>/dev/null \
  | /usr/bin/grep -Eiq 'MootPro|MootEnterprise|Fulcrum|ProductDock|WorkPacket|Federation|CloudKit'; then
  fail "a forbidden edition capability is present in the executable symbol inventory"
fi

echo "Community artifact verified ($($distribution && echo distribution || echo development), team $team)"
