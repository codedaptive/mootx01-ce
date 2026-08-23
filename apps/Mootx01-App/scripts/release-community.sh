#!/bin/bash
set -euo pipefail

app_root="$(cd "$(dirname "$0")/.." && pwd)"
repo_root="$(cd "$app_root/../.." && pwd)"
team_id="G94X5T5GK7"
scheme="Mootx01-Community-macOS"
output_root=""
notary_profile=""
prepare_only=false

usage() {
  local exit_code="${1:-64}"
  cat >&2 <<'USAGE'
usage: release-community.sh --output-root ABSOLUTE_PATH \
       [--notary-keychain-profile PROFILE | --prepare-only]

Builds the public Community project, exports it with Developer ID, and refuses
to continue unless the embedded profile authorizes the Community App Group.
The default path submits to Apple's notary service, staples the accepted ticket,
and emits a final zip plus SHA-256 checksum. --prepare-only stops after creating
the verified notarization-submission.zip.
USAGE
  exit "$exit_code"
}

fail() {
  echo "Community release failed: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-root)
      [[ $# -ge 2 ]] || usage
      output_root="$2"
      shift 2
      ;;
    --notary-keychain-profile)
      [[ $# -ge 2 ]] || usage
      notary_profile="$2"
      shift 2
      ;;
    --prepare-only)
      prepare_only=true
      shift
      ;;
    -h|--help)
      usage 0
      ;;
    *) usage ;;
  esac
done

[[ -n "$output_root" ]] || usage
[[ "$output_root" == /* && "/$output_root/" != *"/../"* ]] \
  || fail "--output-root must be an absolute non-traversing path"
case "$output_root" in
  /|"$repo_root"|"$repo_root"/*)
    fail "--output-root must be outside the source checkout"
    ;;
esac
if ! $prepare_only && [[ -z "$notary_profile" ]]; then
  fail "full release requires --notary-keychain-profile"
fi
if $prepare_only && [[ -n "$notary_profile" ]]; then
  fail "choose either --prepare-only or --notary-keychain-profile"
fi

[[ -f "$app_root/project.yml" ]] \
  || fail "project.yml is missing; run this from a projected CE checkout"
[[ ! -d "$app_root/Sources/MootProGateway" ]] \
  || fail "Community release must run from the public CE projection"
[[ -x "$app_root/scripts/verify-community-artifact.sh" ]] \
  || fail "artifact verifier is missing"
for tool in xcodegen xcodebuild xcrun ditto; do
  command -v "$tool" >/dev/null 2>&1 || fail "required tool is unavailable: $tool"
done

if [[ -e "$output_root" ]] && \
   [[ -n "$(/usr/bin/find "$output_root" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
  fail "--output-root must be empty: $output_root"
fi
mkdir -p "$output_root/derived-data" "$output_root/export" "$output_root/proof"

project="$app_root/Mootx01-App.xcodeproj"
archive="$output_root/Mootx01-Community.xcarchive"
export_root="$output_root/export"
app="$export_root/Mootx01 Community.app"
submission_zip="$output_root/notarization-submission.zip"

xcodegen generate --spec "$app_root/project.yml" --project "$app_root"
xcodebuild \
  -project "$project" \
  -scheme "$scheme" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$archive" \
  -derivedDataPath "$output_root/derived-data" \
  -allowProvisioningUpdates \
  archive

xcodebuild \
  -exportArchive \
  -archivePath "$archive" \
  -exportPath "$export_root" \
  -exportOptionsPlist "$app_root/scripts/Community-DeveloperID-ExportOptions.plist" \
  -allowProvisioningUpdates

env TMPDIR="$output_root/proof" \
  "$app_root/scripts/verify-community-artifact.sh" \
  --team-id "$team_id" \
  "$app"

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$submission_zip"

if $prepare_only; then
  echo "Community notarization input prepared at $submission_zip"
  exit 0
fi

notary_json="$(xcrun notarytool submit "$submission_zip" \
  --keychain-profile "$notary_profile" \
  --output-format json \
  --wait)"
echo "$notary_json"
submission_id="$(/usr/bin/python3 -c \
  'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$notary_json")"
notary_status="$(/usr/bin/python3 -c \
  'import json,sys; print(json.load(sys.stdin)["status"])' <<<"$notary_json")"
if [[ "$notary_status" != "Accepted" ]]; then
  xcrun notarytool log "$submission_id" \
    --keychain-profile "$notary_profile" || true
  fail "Apple notarization returned $notary_status"
fi

xcrun stapler staple "$app"
xcrun stapler validate "$app"
env TMPDIR="$output_root/proof" \
  "$app_root/scripts/verify-community-artifact.sh" \
  --distribution \
  --team-id "$team_id" \
  "$app"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$app/Contents/Info.plist")"
final_zip="$output_root/Mootx01-Community-${version}-macOS.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$final_zip"
/usr/bin/shasum -a 256 "$final_zip" >"$final_zip.sha256"

echo "Community release complete: $final_zip"
