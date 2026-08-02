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

capture_checked U7_RUNNER_INSPECT_FAILED "${transient}/inspect.out" \
  "${U7_HOST_TOOL}" inspect --run-dir "${U7_RUN_DIR}"
inspect_line="$(/usr/bin/tr -d '\n' <"${transient}/inspect.out")"
IFS=: read -r inspect_tag start_index pending_state pending_role pending_phase \
  pending_grant_name terminal_state <<<"${inspect_line}"
[[ "${inspect_tag}" == U7_HOST_INSPECT && "${start_index}" =~ ^[0-9]+$ \
  && ("${pending_state}" == none || "${pending_state}" == pending) \
  && ("${terminal_state}" == active || "${terminal_state}" == terminal) ]] \
  || fail U7_RUNNER_INSPECT_FAILED
if [[ "${terminal_state}" == terminal ]]; then
  run_checked U7_RUNNER_FINALIZE_FAILED \
    "${U7_HOST_TOOL}" finalize --run-dir "${U7_RUN_DIR}"
  printf '%s\n' 'U7_RUNNER_OK'
  exit 0
fi

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
[[ ! -s "${U7_RUN_DIR}/cleanup-authorization.json" ]] \
  || cleanup_authorization="$(base64_file "${U7_RUN_DIR}/cleanup-authorization.json")"
[[ ! -s "${U7_RUN_DIR}/stage-inventory.json" ]] \
  || stage_inventory="$(base64_file "${U7_RUN_DIR}/stage-inventory.json")"
[[ ! -s "${U7_RUN_DIR}/stage-receipt.json" ]] \
  || stage_receipt="$(base64_file "${U7_RUN_DIR}/stage-receipt.json")"

interrupt_if_requested() {
  local key="$1"
  local candidate="$2"
  if [[ "${U7_RUNNER_SELF_TEST_MODE:-0}" == 1 \
    && "${!key:-}" == "${candidate}" ]]; then
    fail U7_RUNNER_SELF_TEST_INTERRUPT 75
  fi
}

remove_pending_material() {
  local candidate="$1"
  local number
  number="$(printf '%02d' "${candidate}")"
  /bin/rm -f -- "${U7_RUN_DIR}/grant-${number}.json" \
    "${U7_RUN_DIR}/pending-receipt-${number}.json"
  if [[ -d "${U7_RUN_DIR}/pending-result-${number}.xcresult" ]]; then
    /bin/rm -rf -- "${U7_RUN_DIR}/pending-result-${number}.xcresult"
  fi
}

recover_stage_material() {
  local result="$1"
  local output="${transient}/recovered-stage"
  mkdir -p "${output}"
  run_checked U7_RUNNER_PHASE_EXPORT_FAILED \
    "${U7_XCRESULTTOOL}" export attachments --path "${result}" \
      --output-path "${output}"
  local receipt inventory
  receipt="$(locate_attachment "${output}" 'u7-phase-receipt-v1.json')"
  inventory="$(locate_attachment "${output}" 'u7-stage-inventory-v1.json')"
  /bin/cp "${receipt}" "${U7_RUN_DIR}/stage-receipt.json"
  /bin/cp "${inventory}" "${U7_RUN_DIR}/stage-inventory.json"
  chmod 600 "${U7_RUN_DIR}/stage-receipt.json" \
    "${U7_RUN_DIR}/stage-inventory.json"
  stage_receipt="$(base64_file "${U7_RUN_DIR}/stage-receipt.json")"
  stage_inventory="$(base64_file "${U7_RUN_DIR}/stage-inventory.json")"
}

# Accepted steps are authoritative in signed host state. Remove their stale
# local launch material, recovering stage attachments first when a crash landed
# after receipt acceptance but before the durable stage copy.
for ((completed = 0; completed < start_index; completed++)); do
  if [[ "${completed}" == 4 && -z "${stage_inventory}" \
    && -d "${U7_RUN_DIR}/pending-result-04.xcresult" ]]; then
    recover_stage_material "${U7_RUN_DIR}/pending-result-04.xcresult"
  fi
  remove_pending_material "${completed}"
done

authorize_cleanup_if_needed() {
  [[ "${start_index}" -lt 5 || -n "${cleanup_authorization}" ]] && return 0
  [[ -n "${stage_inventory}" && -n "${stage_receipt}" ]] \
    || fail U7_RUNNER_EVIDENCE_MISSING
  run_checked U7_RUNNER_CLEANUP_AUTH_FAILED \
    "${U7_HOST_TOOL}" authorize-cleanup --run-dir "${U7_RUN_DIR}" \
      --inventory "${U7_RUN_DIR}/stage-inventory.json" \
      --output 'cleanup-authorization.json'
  [[ -s "${U7_RUN_DIR}/cleanup-authorization.json" ]] \
    || fail U7_RUNNER_EVIDENCE_MISSING
  cleanup_authorization="$(base64_file "${U7_RUN_DIR}/cleanup-authorization.json")"
  interrupt_if_requested U7_SELF_TEST_INTERRUPT_AFTER_AUTHORIZATION_INDEX 4
}

authorize_cleanup_if_needed
index="${start_index}"
# The sequence remains one visible loop because each accepted receipt mutates
# the authority state consumed by the immediately following grant. Splitting or
# parallelizing this loop would destroy the protocol's evidence-before-grant
# ordering, including the stage-to-cleanup authorization checkpoint.
while [[ "${index}" -lt "${#phases[@]}" ]]; do
  item="${phases[${index}]}"
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
  number="$(printf '%02d' "${index}")"
  phase_directory="${transient}/${number}-${phase}-${role}"
  mkdir -p "${phase_directory}/probe-attachments" "${phase_directory}/phase-attachments"
  probe_result="${phase_directory}/probe.xcresult"
  phase_result="${U7_RUN_DIR}/pending-result-${number}.xcresult"
  grant_name="grant-${number}.json"
  grant="${U7_RUN_DIR}/${grant_name}"
  if [[ "${pending_state}" == pending ]]; then
    [[ "${pending_role}" == "${role}" && "${pending_phase}" == "${phase}" \
      && "${pending_grant_name}" == "${grant_name}" ]] \
      || fail U7_RUNNER_INSPECT_FAILED
  else
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
    interrupt_if_requested U7_SELF_TEST_INTERRUPT_BEFORE_GRANT_INDEX "${index}"
    run_checked U7_RUNNER_GRANT_FAILED \
      "${U7_HOST_TOOL}" issue-grant --run-dir "${U7_RUN_DIR}" \
        --role "${role}" --phase "${phase}" --platform "${platform}" \
        --destination-digest "${binding}" --probe "${probe}" --output "${grant_name}"
    interrupt_if_requested U7_SELF_TEST_INTERRUPT_AFTER_GRANT_INDEX "${index}"
  fi
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
  if [[ ! -d "${phase_result}" ]]; then
    phase_log="${transient}/phase-${number}.log"
    if ! /usr/bin/env "${phase_environment[@]}" \
      "${U7_XCODEBUILD}" test-without-building \
      -project "${U7_PROJECT}" -scheme "${U7_SCHEME}" \
      -destination "${destination}" -resultBundlePath "${phase_result}" \
      -only-testing:ConvergenceKitSecretSyncConformanceTests/SecretSyncLiveCloudKitProofTests/externalPhase \
      >"${phase_log}" 2>&1; then
      /bin/rm -rf -- "${phase_result}"
      fail U7_RUNNER_PHASE_FAILED
    fi
    interrupt_if_requested U7_SELF_TEST_INTERRUPT_AFTER_RESULT_INDEX "${index}"
  fi
  run_checked U7_RUNNER_PHASE_EXPORT_FAILED \
    "${U7_XCRESULTTOOL}" export attachments --path "${phase_result}" \
      --output-path "${phase_directory}/phase-attachments"
  receipt_matches="$(/usr/bin/find "${phase_directory}/phase-attachments" \
    -type f -name 'u7-phase-receipt-v1.json' -print)"
  if [[ -z "${receipt_matches}" || "${receipt_matches}" == *$'\n'* ]]; then
    /bin/rm -rf -- "${phase_result}"
    fail U7_RUNNER_EVIDENCE_MISSING
  fi
  receipt="${receipt_matches}"
  inventory=""
  if [[ "${phase}" == stage ]]; then
    inventory_matches="$(/usr/bin/find "${phase_directory}/phase-attachments" \
      -type f -name 'u7-stage-inventory-v1.json' -print)"
    if [[ -z "${inventory_matches}" || "${inventory_matches}" == *$'\n'* ]]; then
      /bin/rm -rf -- "${phase_result}"
      fail U7_RUNNER_EVIDENCE_MISSING
    fi
    inventory="${inventory_matches}"
  fi
  /bin/cp "${receipt}" "${U7_RUN_DIR}/pending-receipt-${number}.json"
  chmod 600 "${U7_RUN_DIR}/pending-receipt-${number}.json"
  receipt_log="${transient}/receipt-${number}.log"
  if ! "${U7_HOST_TOOL}" accept-receipt --run-dir "${U7_RUN_DIR}" \
    --receipt "${U7_RUN_DIR}/pending-receipt-${number}.json" \
    --result-id "pending-result-${number}.xcresult" \
    >"${receipt_log}" 2>&1; then
    /bin/rm -f -- "${U7_RUN_DIR}/pending-receipt-${number}.json"
    /bin/rm -rf -- "${phase_result}"
    fail U7_RUNNER_RECEIPT_REJECTED
  fi
  interrupt_if_requested U7_SELF_TEST_INTERRUPT_AFTER_RECEIPT_INDEX "${index}"

  if [[ "${phase}" == stage ]]; then
    /bin/cp "${inventory}" "${U7_RUN_DIR}/stage-inventory.json"
    /bin/cp "${receipt}" "${U7_RUN_DIR}/stage-receipt.json"
    chmod 600 "${U7_RUN_DIR}/stage-inventory.json" "${U7_RUN_DIR}/stage-receipt.json"
    stage_inventory="$(base64_file "${U7_RUN_DIR}/stage-inventory.json")"
    stage_receipt="$(base64_file "${U7_RUN_DIR}/stage-receipt.json")"
  fi
  remove_pending_material "${index}"
  printf 'U7_PHASE_OK:%s:%s\n' "${phase}" "${role}"
  index=$((index + 1))
  start_index="${index}"
  pending_state=none
  authorize_cleanup_if_needed
done

run_checked U7_RUNNER_FINALIZE_FAILED \
  "${U7_HOST_TOOL}" finalize --run-dir "${U7_RUN_DIR}"
printf '%s\n' 'U7_RUNNER_OK'
