#!/bin/bash
set -euo pipefail
set +x

fail() {
  printf '%s\n' "$1" >&2
  exit "${2:-66}"
}

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

[[ "${U7_DEST_A}" != "${U7_DEST_B}" && "${U7_DEST_A}" != "${U7_DEST_C}" \
  && "${U7_DEST_B}" != "${U7_DEST_C}" ]] || fail U7_RUNNER_MATRIX_INVALID 65

umask 077
mkdir -p "${U7_RUN_DIR}"
chmod 700 "${U7_RUN_DIR}"
transient="$(mktemp -d "${U7_RUN_DIR}/transient.XXXXXX")"
cleanup_transient() {
  chmod -R u+w "${transient}" 2>/dev/null || true
  rm -rf -- "${transient}"
}
trap cleanup_transient EXIT HUP INT TERM

# Command output can contain physical destinations or private selectors. It is
# retained only in the private transient directory and is never echoed.
run_checked() {
  local code="$1"
  shift
  local log="${transient}/command-$RANDOM.log"
  if ! "$@" >"${log}" 2>&1; then
    fail "${code}"
  fi
}

capture_checked() {
  local code="$1"
  local output="$2"
  shift 2
  local log="${transient}/command-$RANDOM.log"
  if ! "$@" >"${output}" 2>"${log}"; then
    fail "${code}"
  fi
}

base64_file() {
  /usr/bin/base64 <"$1" | /usr/bin/tr -d '\n'
}

destination_digest() {
  /usr/bin/printf '%s' "$1" \
    | /usr/bin/openssl dgst -sha256 -binary \
    | /usr/bin/base64 \
    | /usr/bin/tr -d '\n'
}

locate_attachment() {
  local directory="$1"
  local filename="$2"
  local matches
  matches="$(/usr/bin/find "${directory}" -type f -name "${filename}" -print)"
  [[ -n "${matches}" && "${matches}" != *$'\n'* ]] \
    || fail U7_RUNNER_EVIDENCE_MISSING
  /usr/bin/printf '%s' "${matches}"
}

namespace="${U7_RUN_NAMESPACE:-u7-$(/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]')}"
capture_checked U7_RUNNER_HOST_INIT_FAILED "${transient}/host-init.out" \
  "${U7_HOST_TOOL}" init --run-dir "${U7_RUN_DIR}" --namespace "${namespace}"
capture_checked U7_RUNNER_HOST_KEY_FAILED "${transient}/authority.b64" \
  "${U7_HOST_TOOL}" public-key --run-dir "${U7_RUN_DIR}"
authority="$(/usr/bin/tr -d '\n' <"${transient}/authority.b64")"
[[ -n "${authority}" && -s "${U7_RUN_DIR}/run-manifest.json" ]] \
  || fail U7_RUNNER_EVIDENCE_MISSING
manifest="$(base64_file "${U7_RUN_DIR}/run-manifest.json")"

run_checked U7_RUNNER_BUILD_FAILED \
  "${U7_XCODEBUILD}" build-for-testing \
  -project "${U7_PROJECT}" -scheme "${U7_SCHEME}" \
  -destination "${U7_DEST_A}" \
  "INFOPLIST_KEY_MOOTSecretSyncHostAuthorityPublicKey=${authority}"

phases=(
  'credential:A:mac' 'credential:B:iPhone' 'credential:C:iPad'
  'backgroundDenied:A:mac' 'stage:A:mac'
  'conditionalHead:A:mac' 'conditionalHead:B:iPhone'
  'verify:A:mac' 'verify:B:iPhone' 'verify:C:iPad'
  'offline:A:mac' 'revoke:C:iPad' 'recovery:A:mac' 'rotation:A:mac'
  'restart:A:mac' 'audit:A:mac' 'cleanup:B:iPhone' 'cleanup:C:iPad'
  'cleanup:A:mac'
)

cleanup_authorization=""
stage_inventory=""
stage_receipt=""
index=0
# The sequence remains one visible loop because each accepted receipt mutates
# the authority state consumed by the immediately following grant. Splitting or
# parallelizing this loop would destroy the protocol's evidence-before-grant
# ordering, including the stage-to-cleanup authorization checkpoint.
for item in "${phases[@]}"; do
  phase="${item%%:*}"
  remainder="${item#*:}"
  role="${remainder%%:*}"
  platform="${remainder##*:}"
  case "${role}" in
    A) destination="${U7_DEST_A}" ;;
    B) destination="${U7_DEST_B}" ;;
    C) destination="${U7_DEST_C}" ;;
    *) fail U7_RUNNER_MATRIX_INVALID 67 ;;
  esac
  binding="$(destination_digest "${destination}")"
  phase_directory="${transient}/$(printf '%02d' "${index}")-${phase}-${role}"
  mkdir -p "${phase_directory}/probe-attachments" "${phase_directory}/phase-attachments"
  probe_result="${phase_directory}/probe.xcresult"
  phase_result="${phase_directory}/phase.xcresult"

  run_checked U7_RUNNER_PROBE_FAILED \
    /usr/bin/env \
      MOOT_SECRET_SYNC_LIVE_PROOF=1 \
      MOOT_SECRET_SYNC_RUN_NAMESPACE="${namespace}" \
      MOOT_SECRET_SYNC_DEVICE_ROLE="${role}" \
      MOOT_SECRET_SYNC_SIGNED_RUN_MANIFEST="${manifest}" \
    "${U7_XCODEBUILD}" test-without-building \
      -project "${U7_PROJECT}" -scheme "${U7_SCHEME}" \
      -destination "${destination}" -resultBundlePath "${probe_result}" \
      -only-testing:ConvergenceKitSecretSyncConformanceTests/SecretSyncLiveCloudKitProofTests/ledgerProbe
  run_checked U7_RUNNER_PROBE_EXPORT_FAILED \
    "${U7_XCRESULTTOOL}" export attachments --path "${probe_result}" \
      --output-path "${phase_directory}/probe-attachments"
  probe="$(locate_attachment "${phase_directory}/probe-attachments" 'u7-ledger-probe-v1.json')"

  grant_name="grant-$(printf '%02d' "${index}").json"
  grant="${U7_RUN_DIR}/${grant_name}"
  run_checked U7_RUNNER_GRANT_FAILED \
    "${U7_HOST_TOOL}" issue-grant --run-dir "${U7_RUN_DIR}" \
      --role "${role}" --phase "${phase}" --platform "${platform}" \
      --destination-digest "${binding}" --probe "${probe}" --output "${grant_name}"
  [[ -s "${grant}" ]] || fail U7_RUNNER_EVIDENCE_MISSING

  phase_environment=(
    MOOT_SECRET_SYNC_LIVE_PROOF=1
    MOOT_SECRET_SYNC_OPERATOR_ATTESTATION=AUTHORIZED_U7_HOST_LAUNCH_GRANT
    MOOT_SECRET_SYNC_RUN_NAMESPACE="${namespace}"
    MOOT_SECRET_SYNC_DEVICE_ROLE="${role}"
    MOOT_SECRET_SYNC_PHASE="${phase}"
    MOOT_SECRET_SYNC_SIGNED_RUN_MANIFEST="${manifest}"
    MOOT_SECRET_SYNC_HOST_LAUNCH_GRANT="$(base64_file "${grant}")"
  )
  if [[ "${phase}" == cleanup ]]; then
    [[ -n "${cleanup_authorization}" && -n "${stage_inventory}" \
      && -n "${stage_receipt}" ]] || fail U7_RUNNER_EVIDENCE_MISSING
    phase_environment+=(
      MOOT_SECRET_SYNC_CLEANUP_AUTHORIZATION="${cleanup_authorization}"
      MOOT_SECRET_SYNC_STAGE_INVENTORY="${stage_inventory}"
      MOOT_SECRET_SYNC_STAGE_RECEIPT="${stage_receipt}"
    )
  fi
  run_checked U7_RUNNER_PHASE_FAILED \
    /usr/bin/env "${phase_environment[@]}" \
    "${U7_XCODEBUILD}" test-without-building \
      -project "${U7_PROJECT}" -scheme "${U7_SCHEME}" \
      -destination "${destination}" -resultBundlePath "${phase_result}" \
      -only-testing:ConvergenceKitSecretSyncConformanceTests/SecretSyncLiveCloudKitProofTests/externalPhase
  run_checked U7_RUNNER_PHASE_EXPORT_FAILED \
    "${U7_XCRESULTTOOL}" export attachments --path "${phase_result}" \
      --output-path "${phase_directory}/phase-attachments"
  receipt="$(locate_attachment "${phase_directory}/phase-attachments" 'u7-phase-receipt-v1.json')"
  run_checked U7_RUNNER_RECEIPT_REJECTED \
    "${U7_HOST_TOOL}" accept-receipt --run-dir "${U7_RUN_DIR}" \
      --receipt "${receipt}" --result-id "$(basename "${phase_result}")-${index}"

  if [[ "${phase}" == stage ]]; then
    inventory="$(locate_attachment "${phase_directory}/phase-attachments" 'u7-stage-inventory-v1.json')"
    inventory_name='stage-inventory.json'
    /bin/cp "${inventory}" "${U7_RUN_DIR}/${inventory_name}"
    chmod 600 "${U7_RUN_DIR}/${inventory_name}"
    cleanup_name='cleanup-authorization.json'
    run_checked U7_RUNNER_CLEANUP_AUTH_FAILED \
      "${U7_HOST_TOOL}" authorize-cleanup --run-dir "${U7_RUN_DIR}" \
        --inventory "${U7_RUN_DIR}/${inventory_name}" \
        --output "${cleanup_name}"
    [[ -s "${U7_RUN_DIR}/${cleanup_name}" ]] || fail U7_RUNNER_EVIDENCE_MISSING
    cleanup_authorization="$(base64_file "${U7_RUN_DIR}/${cleanup_name}")"
    stage_inventory="$(base64_file "${U7_RUN_DIR}/${inventory_name}")"
    stage_receipt="$(base64_file "${receipt}")"
  fi
  printf 'U7_PHASE_OK:%s:%s\n' "${phase}" "${role}"
  index=$((index + 1))
done

printf '%s\n' 'U7_RUNNER_OK'
