#!/bin/bash
set -euo pipefail
set +x

fail() {
  printf '%s\n' "$1" >&2
  exit "${2:-66}"
}

runner_self_test_mode=0
if [[ "${1:-}" == "--self-test" ]]; then
  runner_self_test_mode=1
  shift
  [[ "$#" == 0 ]] || fail U7_RUNNER_SELF_TEST_INVALID 64
  if [[ -z "${U7_RUN_DIR:-}" ]]; then
    printf '%s\n' 'U7_RUNNER_SELF_TEST_OK'
    exit 0
  fi
fi

: "${U7_RUN_DIR:?U7_RUN_DIR is required}"
: "${U7_HOST_TOOL:?U7_HOST_TOOL is required}"
: "${U7_XCODEBUILD:?U7_XCODEBUILD is required}"
: "${U7_XCRESULTTOOL:?U7_XCRESULTTOOL is required}"
: "${U7_PACKAGE_DIR:?U7_PACKAGE_DIR is required}"
: "${U7_DEST_A:?U7_DEST_A is required}"
: "${U7_DEST_B:?U7_DEST_B is required}"
: "${U7_DEST_C:?U7_DEST_C is required}"

# Self-test execution is admitted only through the explicit argument and only
# with a tool that implements the deliberately non-Xcode attestation command.
# Real xcodebuild rejects this command, keeping tests incapable of crossing the
# live build boundary even when the caller accidentally supplies its path.
if [[ "${runner_self_test_mode}" == 1 ]]; then
  for self_test_tool in "${U7_XCODEBUILD}" "${U7_XCRESULTTOOL}"; do
    [[ -f "${self_test_tool}" && ! -L "${self_test_tool}" \
      && -x "${self_test_tool}" ]] || fail U7_RUNNER_SELF_TEST_TOOL_INVALID 65
    self_test_attestation="$("${self_test_tool}" --u7-self-test-attest 2>/dev/null)" \
      || fail U7_RUNNER_SELF_TEST_TOOL_INVALID 65
    [[ "${self_test_attestation}" == U7_FAKE_XCODEBUILD_V1 ]] \
      || fail U7_RUNNER_SELF_TEST_TOOL_INVALID 65
  done
fi

[[ -z "${U7_PROJECT+x}" && -z "${U7_WORKSPACE+x}" \
  && -z "${U7_SCHEME+x}" ]] || fail U7_RUNNER_CONTAINER_MODE_FORBIDDEN 65

package_directory="$(cd "${U7_PACKAGE_DIR}" 2>/dev/null && /bin/pwd -P)" \
  || fail U7_RUNNER_PACKAGE_INVALID 65
[[ "${U7_PACKAGE_DIR}" == "${package_directory}" \
  && -f "${package_directory}/Package.swift" \
  && -d "${package_directory}/U7LiveProofHost" \
  && -d "${package_directory}/Tests/ConvergenceKitSecretSyncConformanceTests" ]] \
  || fail U7_RUNNER_PACKAGE_INVALID 65
/usr/bin/grep -q 'name:[[:space:]]*"ConvergenceKit"' \
  "${package_directory}/Package.swift" || fail U7_RUNNER_PACKAGE_INVALID 65
readonly scheme='ConvergenceKit-Package'

[[ "${U7_DEST_A}" != "${U7_DEST_B}" && "${U7_DEST_A}" != "${U7_DEST_C}" \
  && "${U7_DEST_B}" != "${U7_DEST_C}" ]] || fail U7_RUNNER_MATRIX_INVALID 65

umask 077
mkdir -p "${U7_RUN_DIR}"
chmod 700 "${U7_RUN_DIR}"
[[ ! -L "${U7_RUN_DIR}" ]] || fail U7_RUNNER_PRIVATE_PATH_INVALID 65
run_directory="$(cd "${U7_RUN_DIR}" && /bin/pwd -P)" \
  || fail U7_RUNNER_PRIVATE_PATH_INVALID 65
U7_RUN_DIR="${run_directory}"
transient="$(mktemp -d "${U7_RUN_DIR}/transient.XXXXXX")"
derived_root="${U7_RUN_DIR}/derived-data"
mac_derived="${derived_root}/macos"
ios_derived="${derived_root}/iphoneos"
mkdir -p "${mac_derived}" "${ios_derived}"
chmod 700 "${derived_root}" "${mac_derived}" "${ios_derived}"
[[ ! -L "${derived_root}" && ! -L "${mac_derived}" && ! -L "${ios_derived}" \
  && "$(cd "${derived_root}" && /bin/pwd -P)" == "${run_directory}/derived-data" \
  && "$(cd "${mac_derived}" && /bin/pwd -P)" == "${run_directory}/derived-data/macos" \
  && "$(cd "${ios_derived}" && /bin/pwd -P)" == "${run_directory}/derived-data/iphoneos" ]] \
  || fail U7_RUNNER_PRIVATE_PATH_INVALID 65
invocation_copies=()
cleanup_transient() {
  local copy
  set +u
  for copy in "${invocation_copies[@]}"; do
    /bin/rm -f -- "${copy}" 2>/dev/null || true
  done
  set -u
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

# XCTest proof inputs are carried only in the validated xctestrun copy. Strip
# every inherited host-shell proof variable from all Xcode subprocesses.
sanitized_environment=(/usr/bin/env)
while IFS='=' read -r variable _; do
  case "${variable}" in
    MOOT_SECRET_SYNC_*) sanitized_environment+=(-u "${variable}") ;;
  esac
done < <(/usr/bin/env)

run_xcode_checked() {
  local code="$1"
  shift
  local log="${transient}/command-$RANDOM.log"
  if ! (cd "${package_directory}" \
    && "${sanitized_environment[@]}" "$@") >"${log}" 2>&1; then
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

plist_helper="${transient}/xctestrun-helper.py"
/bin/cat >"${plist_helper}" <<'PYTHON'
import hashlib
import json
import os
import plistlib
import stat
import sys

TARGET = "ConvergenceKitSecretSyncConformanceTests"
PREFIX = "MOOT_SECRET_SYNC_"

def die():
    raise SystemExit(1)

def beneath(path, root):
    try:
        return os.path.commonpath([os.path.realpath(path), os.path.realpath(root)]) == os.path.realpath(root)
    except ValueError:
        return False

def no_symlink_components(path, root):
    absolute_root = os.path.abspath(root)
    absolute_path = os.path.abspath(path)
    if not beneath(absolute_path, absolute_root):
        return False
    try:
        if os.path.commonpath([absolute_path, absolute_root]) != absolute_root:
            return False
    except ValueError:
        return False
    relative = os.path.relpath(absolute_path, absolute_root)
    current = absolute_root
    if relative == ".":
        return not os.path.islink(current)
    for component in relative.split(os.sep):
        current = os.path.join(current, component)
        if os.path.islink(current):
            return False
    return True

def require_regular_owned(info, mode=None):
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
        die()
    if mode is not None and stat.S_IMODE(info.st_mode) != mode:
        die()
    return info

def regular_owned(path, mode=None):
    try:
        return require_regular_owned(os.lstat(path), mode)
    except OSError:
        die()

def read_regular_bytes(path, mode=None):
    path_info = regular_owned(path, mode)
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except OSError:
        die()
    try:
        opened = require_regular_owned(os.fstat(descriptor), mode)
        if (opened.st_dev, opened.st_ino) != (path_info.st_dev, path_info.st_ino):
            die()
        chunks = []
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        return b"".join(chunks), opened
    finally:
        os.close(descriptor)

def read_plist(path):
    try:
        data, _ = read_regular_bytes(path)
        return plistlib.loads(data)
    except Exception:
        die()

def target_entry(document):
    if not isinstance(document, dict):
        die()
    metadata = document.get("__xctestrun_metadata__")
    configurations = document.get("TestConfigurations")
    if not isinstance(metadata, dict) or metadata.get("FormatVersion") != 2:
        die()
    if not isinstance(configurations, list) or not configurations:
        die()
    matches = []
    for configuration_index, configuration in enumerate(configurations):
        if not isinstance(configuration, dict):
            die()
        targets = configuration.get("TestTargets")
        if not isinstance(targets, list):
            die()
        for target_index, target in enumerate(targets):
            if not isinstance(target, dict):
                die()
            environment = target.get("EnvironmentVariables", {})
            if not isinstance(environment, dict) or not all(
                isinstance(key, str) and isinstance(value, str)
                for key, value in environment.items()
            ):
                die()
            if target.get("BlueprintName") == TARGET:
                matches.append((configuration_index, target_index, target))
            elif any(key.startswith(PREFIX) for key in environment):
                die()
    if len(matches) != 1:
        die()
    return matches[0]

def load_environment(path):
    regular_owned(path, 0o600)
    try:
        with open(path, "r", encoding="utf-8") as handle:
            value = json.load(handle)
    except Exception:
        die()
    if not isinstance(value, dict) or not value or not all(
        isinstance(key, str) and key.startswith(PREFIX) and isinstance(item, str)
        for key, item in value.items()
    ):
        die()
    if "MOOT_SECRET_SYNC_HOST_AUTHORITY_PUBLIC_KEY" in value:
        die()
    return value

def stable_identity(info):
    return "{}:{}:{:o}".format(info.st_dev, info.st_ino, stat.S_IMODE(info.st_mode))

def write_all(descriptor, data):
    remaining = memoryview(data)
    while remaining:
        written = os.write(descriptor, remaining)
        if written <= 0:
            die()
        remaining = remaining[written:]

def overwrite_bound(path, data, expected_identity):
    descriptor = os.open(path, os.O_WRONLY | os.O_NOFOLLOW)
    try:
        opened = require_regular_owned(os.fstat(descriptor))
        if stable_identity(opened) != expected_identity:
            die()
        os.ftruncate(descriptor, 0)
        write_all(descriptor, data)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)

def validate(path, root, expected_platform, authority_path, mode=None, expected_environment=None):
    if not beneath(path, root) or not no_symlink_components(path, root):
        die()
    try:
        data, path_info = read_regular_bytes(path, mode)
        document = plistlib.loads(data)
    except Exception:
        die()
    _, _, target = target_entry(document)
    raw_bundle = target.get("TestBundlePath")
    if not isinstance(raw_bundle, str) or not raw_bundle.startswith("__TESTROOT__/"):
        die()
    bundle_candidate = os.path.join(os.path.dirname(path), raw_bundle[len("__TESTROOT__/"):])
    if not no_symlink_components(bundle_candidate, root):
        die()
    bundle = os.path.realpath(bundle_candidate)
    if not beneath(bundle, root) or not os.path.isdir(bundle):
        die()
    suffix = ("Contents", "Info.plist") if expected_platform == "MacOSX" else ("Info.plist",)
    info_path = os.path.join(bundle, *suffix)
    if not beneath(info_path, root) or not no_symlink_components(info_path, root):
        die()
    info = read_plist(info_path)
    expected_name = "macosx" if expected_platform == "MacOSX" else "iphoneos"
    if info.get("CFBundleSupportedPlatforms") != [expected_platform]:
        die()
    if info.get("DTPlatformName") not in (None, expected_name):
        die()
    try:
        authority_data, _ = read_regular_bytes(authority_path, 0o600)
        authority = authority_data.decode("utf-8").strip()
    except Exception:
        die()
    if not authority or info.get("MOOTSecretSyncHostAuthorityPublicKey") != authority:
        die()
    if expected_environment is not None:
        actual = {
            key: value for key, value in target.get("EnvironmentVariables", {}).items()
            if key.startswith(PREFIX)
        }
        if actual != expected_environment:
            die()
    digest = hashlib.sha256(data).hexdigest()
    return document, digest, stable_identity(path_info), data

action = sys.argv[1]
if action == "discover":
    root, platform, authority_path = sys.argv[2:5]
    products = os.path.join(root, "Build", "Products")
    candidates = []
    for directory, names, files in os.walk(products, followlinks=False):
        names[:] = [name for name in names if not os.path.islink(os.path.join(directory, name))]
        candidates.extend(os.path.join(directory, name) for name in files if name.endswith(".xctestrun"))
    if len(candidates) != 1:
        die()
    _, digest, identity, _ = validate(candidates[0], root, platform, authority_path)
    print(digest + "\t" + identity + "\t" + os.path.realpath(candidates[0]))
elif action == "inject":
    (source, copy, root, platform, authority_path, environment_path,
     source_digest, source_identity, injection_attack) = sys.argv[2:11]
    _, current_source_digest, current_source_identity, data = validate(
        source, root, platform, authority_path
    )
    if (current_source_digest != source_digest or current_source_identity != source_identity
            or os.path.dirname(source) != os.path.dirname(copy)):
        die()
    if os.path.lexists(copy) or not beneath(copy, root):
        die()
    if injection_attack not in ("none", "source-window"):
        die()
    window_mutated = injection_attack == "source-window"
    if window_mutated:
        mutated = bytearray(data)
        if not mutated:
            die()
        mutated[0] ^= 0xff
        overwrite_bound(source, mutated, source_identity)
    try:
        output = os.open(copy, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        try:
            write_all(output, data)
            os.fsync(output)
        finally:
            os.close(output)
    finally:
        if window_mutated:
            overwrite_bound(source, data, source_identity)
    document = read_plist(copy)
    configuration_index, target_index, target = target_entry(document)
    environment = dict(target.get("EnvironmentVariables", {}))
    for key in list(environment):
        if key.startswith(PREFIX):
            del environment[key]
    expected_environment = load_environment(environment_path)
    environment.update(expected_environment)
    document["TestConfigurations"][configuration_index]["TestTargets"][target_index]["EnvironmentVariables"] = environment
    temporary = copy + ".new"
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
    try:
        with os.fdopen(descriptor, "wb", closefd=False) as handle:
            plistlib.dump(document, handle, fmt=plistlib.FMT_BINARY, sort_keys=True)
            handle.flush()
            os.fsync(handle.fileno())
    finally:
        os.close(descriptor)
    os.replace(temporary, copy)
    os.chmod(copy, 0o600)
    directory_descriptor = os.open(os.path.dirname(copy), os.O_RDONLY)
    try:
        os.fsync(directory_descriptor)
    finally:
        os.close(directory_descriptor)
    _, digest, identity, _ = validate(copy, root, platform, authority_path, 0o600, expected_environment)
    print(digest + "\t" + identity)
elif action == "verify":
    (source, copy, root, platform, authority_path, environment_path,
     source_digest, source_identity, copy_digest, copy_identity) = sys.argv[2:12]
    _, current_source_digest, current_source_identity, _ = validate(source, root, platform, authority_path)
    expected_environment = load_environment(environment_path)
    _, current_copy_digest, current_copy_identity, _ = validate(
        copy, root, platform, authority_path, 0o600, expected_environment
    )
    if (current_source_digest != source_digest or current_source_identity != source_identity
            or current_copy_digest != copy_digest or current_copy_identity != copy_identity):
        die()
    if os.path.dirname(source) != os.path.dirname(copy):
        die()
else:
    die()
PYTHON
chmod 600 "${plist_helper}"

discover_product() {
  local root="$1"
  local platform="$2"
  local output="$3"
  capture_checked U7_RUNNER_PRODUCT_INVALID "${output}" \
    /usr/bin/python3 "${plist_helper}" discover "${root}" "${platform}" \
      "${transient}/authority.b64"
}

write_environment_spec() {
  local output="$1"
  shift
  /usr/bin/python3 -c '
import json, os, sys
output = sys.argv[1]
items = sys.stdin.buffer.read().split(b"\0")
environment = {}
for item in items:
    if not item:
        continue
    key, separator, value = item.partition(b"=")
    if not separator or not key.startswith(b"MOOT_SECRET_SYNC_"):
        raise SystemExit(1)
    decoded_key = key.decode("utf-8")
    if decoded_key in environment:
        raise SystemExit(1)
    environment[decoded_key] = value.decode("utf-8")
descriptor = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
    json.dump(environment, handle, sort_keys=True, separators=(",", ":"))
    handle.flush()
    os.fsync(handle.fileno())
' "${output}" < <(printf '%s\0' "$@") || fail U7_RUNNER_ENVIRONMENT_INVALID
  chmod 600 "${output}"
}

prepare_invocation_copy() {
  local source="$1"
  local source_digest="$2"
  local source_identity="$3"
  local root="$4"
  local platform="$5"
  local label="$6"
  shift 6
  local copy="$(/usr/bin/dirname "${source}")/.u7-${label}-$(/usr/bin/basename "${transient}").xctestrun"
  local environment_spec="${transient}/${label}-environment.json"
  local digest_file="${transient}/${label}-digest.txt"
  local injection_attack=none
  if [[ "${runner_self_test_mode}" == 1 \
    && "${U7_SELF_TEST_XCTESTRUN_ATTACK:-}" == source-window ]]; then
    injection_attack=source-window
  fi
  write_environment_spec "${environment_spec}" "$@"
  capture_checked U7_RUNNER_XCTESTRUN_INVALID "${digest_file}" \
    /usr/bin/python3 "${plist_helper}" inject "${source}" "${copy}" \
      "${root}" "${platform}" "${transient}/authority.b64" \
      "${environment_spec}" "${source_digest}" "${source_identity}" \
      "${injection_attack}"
  invocation_copies+=("${copy}")
  local copy_digest copy_identity
  IFS=$'\t' read -r copy_digest copy_identity <"${digest_file}"
  [[ "${copy_digest}" =~ ^[0-9a-f]{64}$ \
    && "${copy_identity}" =~ ^[0-9]+:[0-9]+:[0-7]+$ ]] \
    || fail U7_RUNNER_XCTESTRUN_INVALID
  prepared_copy="${copy}"
  prepared_environment_spec="${environment_spec}"
  prepared_copy_digest="${copy_digest}"
  prepared_copy_identity="${copy_identity}"
}

verify_invocation_copy() {
  local source="$1"
  local copy="$2"
  local root="$3"
  local platform="$4"
  local environment_spec="$5"
  local source_digest="$6"
  local source_identity="$7"
  local copy_digest="$8"
  local copy_identity="$9"
  run_checked U7_RUNNER_XCTESTRUN_INVALID \
    /usr/bin/python3 "${plist_helper}" verify "${source}" "${copy}" \
      "${root}" "${platform}" "${transient}/authority.b64" \
      "${environment_spec}" "${source_digest}" "${source_identity}" \
      "${copy_digest}" "${copy_identity}"
}

attack_invocation_copy_if_requested() {
  [[ "${runner_self_test_mode}" == 1 ]] || return 0
  case "${U7_SELF_TEST_XCTESTRUN_ATTACK:-}" in
    '')
      ;;
    replace)
      /bin/cp -p "${prepared_copy}" "${prepared_copy}.replacement"
      /bin/mv -f "${prepared_copy}.replacement" "${prepared_copy}"
      ;;
    symlink)
      /bin/rm -f -- "${prepared_copy}"
      /bin/ln -s "${source_xctestrun}" "${prepared_copy}"
      ;;
    source-replace)
      /bin/cp -p "${source_xctestrun}" "${source_xctestrun}.replacement"
      /bin/mv -f "${source_xctestrun}.replacement" "${source_xctestrun}"
      ;;
    copy-mode)
      chmod 400 "${prepared_copy}"
      ;;
    source-mode)
      /usr/bin/python3 -c 'import os, stat, sys; p=sys.argv[1]; os.chmod(p, stat.S_IMODE(os.lstat(p).st_mode) ^ stat.S_IXUSR)' \
        "${source_xctestrun}"
      ;;
    source-window)
      # The embedded helper performs and restores this mutation between its
      # descriptor-bound validation and private-copy construction.
      ;;
    *)
      fail U7_RUNNER_XCTESTRUN_INVALID
      ;;
  esac
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
  /bin/rm -rf -- "${derived_root}"
  run_checked U7_RUNNER_FINALIZE_FAILED \
    "${U7_HOST_TOOL}" finalize --run-dir "${U7_RUN_DIR}"
  printf '%s\n' 'U7_RUNNER_OK'
  exit 0
fi

run_xcode_checked U7_RUNNER_BUILD_FAILED \
  "${U7_XCODEBUILD}" build-for-testing \
  -scheme "${scheme}" -derivedDataPath "${mac_derived}" \
  -destination "${U7_DEST_A}" \
  "INFOPLIST_KEY_MOOTSecretSyncHostAuthorityPublicKey=${authority}"
discover_product "${mac_derived}" MacOSX "${transient}/mac-product.txt"
IFS=$'\t' read -r mac_source_digest mac_source_identity mac_source \
  <"${transient}/mac-product.txt"
[[ "${mac_source_digest}" =~ ^[0-9a-f]{64}$ \
  && "${mac_source_identity}" =~ ^[0-9]+:[0-9]+:[0-7]+$ \
  && -n "${mac_source}" ]] \
  || fail U7_RUNNER_PRODUCT_INVALID

# One authorized iPhone destination builds the shared iOS test products used
# by both the iPhone and iPad phases; both platform builds precede every run.
run_xcode_checked U7_RUNNER_BUILD_FAILED \
  "${U7_XCODEBUILD}" build-for-testing \
  -scheme "${scheme}" -derivedDataPath "${ios_derived}" \
  -destination "${U7_DEST_B}" \
  "INFOPLIST_KEY_MOOTSecretSyncHostAuthorityPublicKey=${authority}"
discover_product "${ios_derived}" iPhoneOS "${transient}/ios-product.txt"
IFS=$'\t' read -r ios_source_digest ios_source_identity ios_source \
  <"${transient}/ios-product.txt"
[[ "${ios_source_digest}" =~ ^[0-9a-f]{64}$ \
  && "${ios_source_identity}" =~ ^[0-9]+:[0-9]+:[0-7]+$ \
  && -n "${ios_source}" ]] \
  || fail U7_RUNNER_PRODUCT_INVALID

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
  if [[ "${runner_self_test_mode}" == 1 \
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
    A)
      destination="${U7_DEST_A}"
      source_xctestrun="${mac_source}"
      source_digest="${mac_source_digest}"
      source_identity="${mac_source_identity}"
      source_root="${mac_derived}"
      product_platform=MacOSX
      ;;
    B)
      destination="${U7_DEST_B}"
      source_xctestrun="${ios_source}"
      source_digest="${ios_source_digest}"
      source_identity="${ios_source_identity}"
      source_root="${ios_derived}"
      product_platform=iPhoneOS
      ;;
    C)
      destination="${U7_DEST_C}"
      source_xctestrun="${ios_source}"
      source_digest="${ios_source_digest}"
      source_identity="${ios_source_identity}"
      source_root="${ios_derived}"
      product_platform=iPhoneOS
      ;;
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
    prepare_invocation_copy \
      "${source_xctestrun}" "${source_digest}" "${source_identity}" "${source_root}" \
      "${product_platform}" "${number}-probe-${role}" \
      MOOT_SECRET_SYNC_LIVE_PROOF=1 \
      MOOT_SECRET_SYNC_RUN_NAMESPACE="${namespace}" \
      MOOT_SECRET_SYNC_DEVICE_ROLE="${role}" \
      MOOT_SECRET_SYNC_SIGNED_RUN_MANIFEST="${manifest}"
    attack_invocation_copy_if_requested
    verify_invocation_copy \
      "${source_xctestrun}" "${prepared_copy}" "${source_root}" \
      "${product_platform}" "${prepared_environment_spec}" \
      "${source_digest}" "${source_identity}" "${prepared_copy_digest}" \
      "${prepared_copy_identity}"
    run_xcode_checked U7_RUNNER_PROBE_FAILED \
      "${U7_XCODEBUILD}" test-without-building \
        -xctestrun "${prepared_copy}" \
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
    prepare_invocation_copy \
      "${source_xctestrun}" "${source_digest}" "${source_identity}" "${source_root}" \
      "${product_platform}" "${number}-phase-${phase}-${role}" \
      "${phase_environment[@]}"
    verify_invocation_copy \
      "${source_xctestrun}" "${prepared_copy}" "${source_root}" \
      "${product_platform}" "${prepared_environment_spec}" \
      "${source_digest}" "${source_identity}" "${prepared_copy_digest}" \
      "${prepared_copy_identity}"
    phase_log="${transient}/phase-${number}.log"
    if ! (cd "${package_directory}" \
      && "${sanitized_environment[@]}" \
      "${U7_XCODEBUILD}" test-without-building \
      -xctestrun "${prepared_copy}" \
      -destination "${destination}" -resultBundlePath "${phase_result}" \
      -only-testing:ConvergenceKitSecretSyncConformanceTests/SecretSyncLiveCloudKitProofTests/externalPhase \
      ) >"${phase_log}" 2>&1; then
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

/bin/rm -rf -- "${derived_root}"
run_checked U7_RUNNER_FINALIZE_FAILED \
  "${U7_HOST_TOOL}" finalize --run-dir "${U7_RUN_DIR}"
printf '%s\n' 'U7_RUNNER_OK'
