#!/bin/bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
package_dir="$(cd "$script_dir/.." && pwd)"
project_path="$script_dir/U3SignedHost.xcodeproj"
scheme="U3SignedHost"

signing_identity="${U3_SIGNING_IDENTITY:-}"
profile_path="${U3_PROVISIONING_PROFILE:-}"
application_id="${U3_APP_ID:-}"
team_id="${U3_TEAM_ID:-}"

usage() {
  printf '%s\n' \
    'usage: run-physical-proof.sh [--identity NAME] [--profile PATH]' \
    '       [--app-id BUNDLE_ID] [--team TEAM_ID]'
}

fail() {
  printf 'U3_SIGNED_HOST_RESULT=%s\n' "$1"
  exit 1
}

decode_profile() {
  local source_path="$1"
  local output_path="$2"
  security cms -D -i "$source_path" >"$output_path" 2>/dev/null
}

profile_value() {
  local decoded_path="$1"
  local key_path="$2"
  /usr/libexec/PlistBuddy -c "Print :$key_path" "$decoded_path" 2>/dev/null
}

profile_signing_mode_for() {
  local decoded_path="$1"
  local managed_value
  managed_value="$(profile_value "$decoded_path" 'IsXcodeManaged' || true)"

  # Xcode-managed profiles must be selected through automatic signing. An
  # absent marker is the established shape for manually managed profiles.
  case "$managed_value" in
    true)
      printf '%s\n' 'managed'
      ;;
    false|'')
      printf '%s\n' 'manual'
      ;;
    *)
      return 1
      ;;
  esac
}

run_signed_build() {
  local signing_mode="$1"
  local derived_data="$2"
  local build_log="$3"

  if [[ "$signing_mode" == "managed" ]]; then
    # Automatic signing accepts Xcode-managed development profiles only with
    # the generic identity class. The selected profile is still proven below
    # by its embedded UUID and signed entitlement relationship.
    xcodebuild \
      -project "$project_path" \
      -scheme "$scheme" \
      -configuration Debug \
      -destination 'platform=macOS,arch=arm64' \
      -derivedDataPath "$derived_data" \
      CODE_SIGN_STYLE=Automatic \
      CODE_SIGN_IDENTITY='Apple Development' \
      DEVELOPMENT_TEAM="$team_id" \
      PRODUCT_BUNDLE_IDENTIFIER="$application_id" \
      build >"$build_log" 2>&1
  else
    xcodebuild \
      -project "$project_path" \
      -scheme "$scheme" \
      -configuration Debug \
      -destination 'platform=macOS,arch=arm64' \
      -derivedDataPath "$derived_data" \
      CODE_SIGN_STYLE=Manual \
      CODE_SIGN_IDENTITY="$signing_identity" \
      DEVELOPMENT_TEAM="$team_id" \
      PRODUCT_BUNDLE_IDENTIFIER="$application_id" \
      PROVISIONING_PROFILE_SPECIFIER="$profile_name" \
      build >"$build_log" 2>&1
  fi
}

profile_is_match() {
  local decoded_path="$1"
  local candidate_team candidate_application candidate_platform candidate_group
  candidate_team="$(profile_value "$decoded_path" 'TeamIdentifier:0' || true)"
  # macOS profiles use the namespaced application identifier and may omit
  # get-task-allow. The Apple Development identity, macOS platform, team,
  # exact bundle suffix, and authorized Keychain group form the fail-closed
  # development-profile relationship checked here and by xcodebuild.
  candidate_application="$(
    profile_value \
      "$decoded_path" \
      'Entitlements:com.apple.application-identifier' || true
  )"
  candidate_platform="$(profile_value "$decoded_path" 'Platform:0' || true)"
  candidate_group="$(
    profile_value \
      "$decoded_path" \
      'Entitlements:keychain-access-groups:0' || true
  )"

  [[ -n "$candidate_team" && -n "$candidate_application" ]] || return 1
  [[ "$candidate_application" =~ ^[A-Z0-9]+\.[A-Za-z0-9.-]+$ ]] || return 1
  [[ "$candidate_application" == "$candidate_team."* ]] || return 1
  [[ "$candidate_platform" == "OSX" || "$candidate_platform" == "macOS" ]] \
    || return 1
  [[
    "$candidate_group" == "$candidate_application"
      || "$candidate_group" == "$candidate_team.*"
  ]] || return 1
  [[ -z "$team_id" || "$candidate_team" == "$team_id" ]] || return 1
  [[ -z "$application_id" || "$candidate_application" == *".$application_id" ]] \
    || return 1
}

main() {
while (($#)); do
  case "$1" in
    --identity)
      (($# >= 2)) || fail "invalid-arguments"
      signing_identity="$2"
      shift 2
      ;;
    --profile)
      (($# >= 2)) || fail "invalid-arguments"
      profile_path="$2"
      shift 2
      ;;
    --app-id)
      (($# >= 2)) || fail "invalid-arguments"
      application_id="$2"
      shift 2
      ;;
    --team)
      (($# >= 2)) || fail "invalid-arguments"
      team_id="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "invalid-arguments"
      ;;
  esac
done

[[ -z "$application_id" || "$application_id" =~ ^[A-Za-z0-9.-]+$ ]] \
  || fail "invalid-arguments"
[[ -z "$team_id" || "$team_id" =~ ^[A-Z0-9]+$ ]] \
  || fail "invalid-arguments"

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/u3-signed-host.XXXXXX")"
cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT

identity_inventory="$work_dir/signing-identities.txt"
security find-identity -v -p codesigning >"$identity_inventory" 2>/dev/null \
  || fail "signing-identity-unavailable"

if [[ -z "$signing_identity" ]]; then
  identity_count="$({
    awk -F'"' '/Apple Development/ { print $2 }' "$identity_inventory"
  } | wc -l | tr -d ' ')"
  [[ "$identity_count" == "1" ]] || fail "signing-identity-ambiguous"
  signing_identity="$({
    awk -F'"' '/Apple Development/ { print $2 }' "$identity_inventory"
  } | head -1)"
else
  identity_count="$(
    awk -F'"' -v expected="$signing_identity" \
      '$2 == expected { count += 1 } END { print count + 0 }' \
      "$identity_inventory"
  )"
  [[ "$identity_count" != "0" ]] || fail "signing-identity-unavailable"
  [[ "$identity_count" == "1" ]] || fail "signing-identity-ambiguous"
fi

selected_profile="$work_dir/selected-profile.plist"
if [[ -n "$profile_path" ]]; then
  [[ -f "$profile_path" ]] || fail "provisioning-profile-unavailable"
  decode_profile "$profile_path" "$selected_profile" \
    || fail "provisioning-profile-invalid"
  profile_is_match "$selected_profile" \
    || fail "provisioning-profile-mismatch"
else
  shopt -s nullglob
  candidates=(
    "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/"*
    "$HOME/Library/MobileDevice/Provisioning Profiles/"*
  )
  shopt -u nullglob
  match_count=0
  for candidate in "${candidates[@]}"; do
    [[ -f "$candidate" ]] || continue
    decoded_candidate="$work_dir/profile-$match_count.plist"
    decode_profile "$candidate" "$decoded_candidate" || continue
    if profile_is_match "$decoded_candidate"; then
      match_count=$((match_count + 1))
      profile_path="$candidate"
      cp "$decoded_candidate" "$selected_profile"
    fi
  done
  [[ "$match_count" == "1" ]] || fail "provisioning-profile-ambiguous"
fi

profile_team="$(profile_value "$selected_profile" 'TeamIdentifier:0')"
profile_application="$(
  profile_value \
    "$selected_profile" \
    'Entitlements:com.apple.application-identifier'
)"
profile_name="$(profile_value "$selected_profile" 'Name')"
profile_uuid="$(profile_value "$selected_profile" 'UUID')"
profile_bundle_id="${profile_application#*.}"
signing_mode="$(profile_signing_mode_for "$selected_profile")" \
  || fail "provisioning-profile-invalid"

[[ -n "$team_id" ]] || team_id="$profile_team"
[[ -n "$application_id" ]] || application_id="$profile_bundle_id"
[[ "$team_id" == "$profile_team" ]] || fail "provisioning-profile-mismatch"
[[ "$application_id" == "$profile_bundle_id" ]] \
  || fail "provisioning-profile-mismatch"
[[ -n "$profile_name" && -n "$profile_uuid" ]] \
  || fail "provisioning-profile-invalid"

# The unsigned SwiftPM helper must reach the real production Security seam and
# emit only the stable entitlement classification. A generic crypto failure is
# not accepted as proof that the environment defect is understood.
unsigned_log="$work_dir/unsigned-proof.log"
set +e
(
  cd "$package_dir"
  SECRET_SYNC_HARDWARE_PROOF=1 swift test --no-parallel \
    --filter SecretSyncCustodyContractTests.supportedHardwareProof
) >"$unsigned_log" 2>&1
unsigned_status=$?
set -e
[[ "$unsigned_status" != "0" ]] || fail "unsigned-runner-unexpected-pass"
grep -q 'missingEntitlement' "$unsigned_log" \
  || fail "unsigned-classification-failed"
printf '%s\n' 'U3_SIGNED_HOST_UNSIGNED_CLASSIFICATION=missing-entitlement'

derived_data="$work_dir/DerivedData"
build_log="$work_dir/xcodebuild.log"
if ! run_signed_build "$signing_mode" "$derived_data" "$build_log"; then
  fail "signed-build-failed"
fi

app_path="$derived_data/Build/Products/Debug/U3SignedHost.app"
[[ -d "$app_path" ]] || fail "signed-build-missing-product"
codesign --verify --deep --strict "$app_path" >/dev/null 2>&1 \
  || fail "signature-verification-failed"

signed_entitlements="$work_dir/signed-entitlements.plist"
codesign -d --entitlements :- "$app_path" >"$signed_entitlements" 2>/dev/null \
  || fail "signed-entitlements-unavailable"
signed_application="$(
  profile_value "$signed_entitlements" 'com.apple.application-identifier' || true
)"
signed_team="$(
  profile_value "$signed_entitlements" 'com.apple.developer.team-identifier' || true
)"
signed_group="$(
  profile_value "$signed_entitlements" 'keychain-access-groups:0' || true
)"
[[ "$signed_application" == "$profile_application" ]] \
  || fail "signed-entitlements-mismatch"
[[ "$signed_team" == "$team_id" ]] || fail "signed-entitlements-mismatch"
[[ "$signed_group" == "$profile_application" ]] \
  || fail "signed-entitlements-mismatch"

embedded_profile="$app_path/Contents/embedded.provisionprofile"
[[ -f "$embedded_profile" ]] || fail "embedded-profile-missing"
embedded_plist="$work_dir/embedded-profile.plist"
decode_profile "$embedded_profile" "$embedded_plist" \
  || fail "embedded-profile-invalid"
embedded_uuid="$(profile_value "$embedded_plist" 'UUID' || true)"
[[ "$embedded_uuid" == "$profile_uuid" ]] \
  || fail "embedded-profile-mismatch"

"$app_path/Contents/MacOS/U3SignedHost"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
