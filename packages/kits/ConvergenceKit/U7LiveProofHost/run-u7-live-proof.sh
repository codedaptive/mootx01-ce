#!/bin/bash
set -euo pipefail
set +x

if [[ "${1:-}" == "--self-test" ]]; then
  printf '%s\n' 'U7_RUNNER_SELF_TEST_OK'
  exit 0
fi

: "${U7_RUN_DIR:?U7_RUN_DIR is required}"
: "${U7_HOST_TOOL:?U7_HOST_TOOL is required}"
: "${U7_XCODEBUILD:?U7_XCODEBUILD is required}"
: "${U7_XCRESULTTOOL:?U7_XCRESULTTOOL is required}"
: "${U7_PROJECT:?U7_PROJECT is required}"
: "${U7_SCHEME:?U7_SCHEME is required}"
: "${U7_DEST_A:?U7_DEST_A is required}"
: "${U7_DEST_B:?U7_DEST_B is required}"
: "${U7_DEST_C:?U7_DEST_C is required}"

[[ "${U7_DEST_A}" != "${U7_DEST_B}" && "${U7_DEST_A}" != "${U7_DEST_C}" && "${U7_DEST_B}" != "${U7_DEST_C}" ]] || exit 65
umask 077
mkdir -p "${U7_RUN_DIR}"
chmod 700 "${U7_RUN_DIR}"

redact() {
  sed -e "s|${U7_DEST_A}|<destination-A>|g" -e "s|${U7_DEST_B}|<destination-B>|g" -e "s|${U7_DEST_C}|<destination-C>|g"
}

run_checked() {
  local log="${U7_RUN_DIR}/command.log"
  if ! "$@" >"${log}" 2>&1; then
    redact <"${log}" >&2
    printf '%s\n' 'U7_RUNNER_COMMAND_FAILED' >&2
    exit 66
  fi
}

run_checked "${U7_XCODEBUILD}" build-for-testing -project "${U7_PROJECT}" -scheme "${U7_SCHEME}"

phases=(
  'credential:A' 'credential:B' 'credential:C' 'backgroundDenied:A' 'stage:A'
  'authorizeCleanup:A' 'conditionalHead:A' 'conditionalHead:B' 'verify:A'
  'verify:B' 'verify:C' 'offline:A' 'revoke:C' 'recovery:A' 'rotation:A'
  'restart:A' 'audit:A' 'cleanup:B' 'cleanup:C' 'cleanup:A'
)

for item in "${phases[@]}"; do
  phase="${item%%:*}"; role="${item##*:}"
  case "${role}" in A) destination="${U7_DEST_A}";; B) destination="${U7_DEST_B}";; C) destination="${U7_DEST_C}";; *) exit 67;; esac
  if [[ "${phase}" != 'authorizeCleanup' ]]; then
    run_checked "${U7_XCODEBUILD}" test-without-building -destination "${destination}" -only-testing:ConvergenceKitSecretSyncConformanceTests/SecretSyncLiveCloudKitProofTests/ledgerProbe
    run_checked "${U7_XCRESULTTOOL}" export attachments --path "${U7_RUN_DIR}/probe.xcresult" --output-path "${U7_RUN_DIR}/probe"
    run_checked "${U7_XCODEBUILD}" test-without-building -destination "${destination}" -only-testing:ConvergenceKitSecretSyncConformanceTests/SecretSyncLiveCloudKitProofTests/externalPhase
  fi
  printf 'U7_PHASE_OK:%s:%s\n' "${phase}" "${role}"
done

find "${U7_RUN_DIR}" -type f \( -name '*.xcresult' -o -name 'manifest.json' \) -delete
printf '%s\n' 'U7_RUNNER_OK'
