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
attack_aliases=()
cleanup_transient() {
  local copy alias
  set +u
  for copy in "${invocation_copies[@]}"; do
    /bin/rm -f -- "${copy}" 2>/dev/null || true
  done
  for alias in "${attack_aliases[@]}"; do
    /bin/rm -f -- "${alias}" 2>/dev/null || true
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
import re
import secrets
import stat
import sys

TARGET = "ConvergenceKitSecretSyncConformanceTests"
PREFIX = "MOOT_SECRET_SYNC_"
PROBE_KEYS = frozenset({
    PREFIX + "LIVE_PROOF", PREFIX + "RUN_NAMESPACE",
    PREFIX + "DEVICE_ROLE", PREFIX + "SIGNED_RUN_MANIFEST",
})
ORDINARY_KEYS = PROBE_KEYS | frozenset({
    PREFIX + "PHASE", PREFIX + "OPERATOR_ATTESTATION",
    PREFIX + "HOST_LAUNCH_GRANT",
})
CLEANUP_KEYS = ORDINARY_KEYS | frozenset({
    PREFIX + "CLEANUP_AUTHORIZATION", PREFIX + "STAGE_INVENTORY",
    PREFIX + "STAGE_RECEIPT",
})

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
    if (stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode)
            or info.st_uid != os.getuid() or info.st_nlink != 1):
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

def open_bound_directory(path, custody_root):
    absolute_path = os.path.abspath(path)
    absolute_root = os.path.abspath(custody_root)
    if (path != absolute_path or custody_root != absolute_root
            or os.path.normpath(path) != path
            or os.path.realpath(custody_root) != custody_root
            or not beneath(path, custody_root)
            or not no_symlink_components(path, custody_root)):
        die()
    try:
        path_info = os.lstat(path)
        descriptor = os.open(
            path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
        )
    except OSError:
        die()
    try:
        opened = os.fstat(descriptor)
        if ((path_info.st_dev, path_info.st_ino) != (opened.st_dev, opened.st_ino)
                or stat.S_ISLNK(opened.st_mode)
                or not stat.S_ISDIR(opened.st_mode)
                or opened.st_uid != os.getuid()
                or stat.S_IMODE(opened.st_mode) & 0o077):
            die()
        return descriptor
    except Exception:
        os.close(descriptor)
        raise

def read_directory_entry(directory_descriptor, name):
    try:
        path_info = os.stat(
            name, dir_fd=directory_descriptor, follow_symlinks=False
        )
        descriptor = os.open(
            name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory_descriptor
        )
    except OSError:
        die()
    try:
        opened = require_regular_owned(os.fstat(descriptor))
        if ((path_info.st_dev, path_info.st_ino)
                != (opened.st_dev, opened.st_ino)):
            die()
        chunks = []
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        return b"".join(chunks)
    finally:
        os.close(descriptor)

def write_private_entry(directory_descriptor, name, data):
    try:
        descriptor = os.open(
            name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o600, dir_fd=directory_descriptor
        )
    except OSError:
        die()
    try:
        write_all(descriptor, data)
        os.fchmod(descriptor, 0o600)
        os.fsync(descriptor)
        require_regular_owned(os.fstat(descriptor), 0o600)
    finally:
        os.close(descriptor)

def reject_duplicate_object_keys(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            die()
        value[key] = item
    return value

def admit_evidence(export_directory, custody_root, expected_identifier,
                   evidence_kind, output_directory):
    expected_labels = {
        "probe": ("probe",),
        "ordinary": ("receipt",),
        "stage": ("receipt", "inventory"),
    }
    logical_patterns = {
        "probe": re.compile(
            r"u7-ledger-probe-v1_0_[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-"
            r"[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\.json"
        ),
        "receipt": re.compile(
            r"u7-phase-receipt-v1_0_[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-"
            r"[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\.json"
        ),
        "inventory": re.compile(
            r"u7-stage-inventory-v1_0_[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-"
            r"[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\.json"
        ),
    }
    if evidence_kind not in expected_labels or not expected_identifier:
        die()
    export_descriptor = open_bound_directory(export_directory, custody_root)
    output_descriptor = open_bound_directory(output_directory, custody_root)
    try:
        if os.listdir(output_descriptor):
            die()
        try:
            manifest = json.loads(
                read_directory_entry(export_descriptor, "manifest.json")
                .decode("utf-8"), object_pairs_hook=reject_duplicate_object_keys
            )
        except Exception:
            die()
        if not isinstance(manifest, list) or len(manifest) != 1:
            die()
        group = manifest[0]
        if (not isinstance(group, dict)
                or not {"testIdentifier", "attachments"}.issubset(group)
                or not set(group).issubset({
                    "testIdentifier", "testIdentifierURL", "attachments"
                })
                or group["testIdentifier"] != expected_identifier
                or not isinstance(group["testIdentifier"], str)
                or ("testIdentifierURL" in group
                    and not isinstance(group["testIdentifierURL"], str))
                or not isinstance(group["attachments"], list)):
            die()
        required_attachment_keys = {
            "exportedFileName", "suggestedHumanReadableName",
            "isAssociatedWithFailure", "configurationName",
            "deviceName", "deviceId",
        }
        optional_attachment_keys = {
            "timestamp", "repetitionNumber", "arguments",
        }
        expected = expected_labels[evidence_kind]
        admitted = {}
        exported_names = set()
        for attachment in group["attachments"]:
            if (not isinstance(attachment, dict)
                    or not required_attachment_keys.issubset(attachment)
                    or not set(attachment).issubset(
                        required_attachment_keys | optional_attachment_keys
                    )):
                die()
            for key in (
                "exportedFileName", "suggestedHumanReadableName",
                "configurationName", "deviceName", "deviceId",
            ):
                if not isinstance(attachment[key], str) or not attachment[key]:
                    die()
            if attachment["isAssociatedWithFailure"] is not False:
                die()
            if ("repetitionNumber" in attachment
                    and (not isinstance(attachment["repetitionNumber"], int)
                         or isinstance(attachment["repetitionNumber"], bool))):
                die()
            if ("timestamp" in attachment
                    and (isinstance(attachment["timestamp"], bool)
                         or not isinstance(
                             attachment["timestamp"], (int, float, str)
                         ))):
                die()
            if ("arguments" in attachment
                    and (not isinstance(attachment["arguments"], list)
                         or not all(
                             isinstance(value, str)
                             for value in attachment["arguments"]
                         ))):
                die()
            exported_name = attachment["exportedFileName"]
            if (exported_name in (".", "..", "manifest.json")
                    or exported_name != os.path.basename(exported_name)
                    or os.path.normpath(exported_name) != exported_name
                    or "/" in exported_name or "\\" in exported_name
                    or exported_name in exported_names):
                die()
            exported_names.add(exported_name)
            suggested_name = attachment["suggestedHumanReadableName"]
            labels = [
                label for label, pattern in logical_patterns.items()
                if pattern.fullmatch(suggested_name)
            ]
            if len(labels) != 1 or labels[0] not in expected or labels[0] in admitted:
                die()
            admitted[labels[0]] = read_directory_entry(
                export_descriptor, exported_name
            )
        if tuple(label for label in expected if label in admitted) != expected:
            die()
        if len(group["attachments"]) != len(expected):
            die()
        if set(os.listdir(export_descriptor)) != exported_names | {"manifest.json"}:
            die()
        output_names = {
            "probe": "probe.json",
            "receipt": "receipt.json",
            "inventory": "inventory.json",
        }
        output_paths = []
        for label in expected:
            name = output_names[label]
            write_private_entry(output_descriptor, name, admitted[label])
            output_paths.append(os.path.join(output_directory, name))
        os.fsync(output_descriptor)
        return output_paths
    finally:
        os.close(export_descriptor)
        os.close(output_descriptor)

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

def load_environment(path, expected_digest, expected_identity):
    try:
        data, info = read_regular_bytes(path, 0o600)
        if (hashlib.sha256(data).hexdigest() != expected_digest
                or stable_identity(info) != expected_identity):
            die()
        value = json.loads(data.decode("utf-8"))
    except Exception:
        die()
    if not isinstance(value, dict) or not value or not all(
        isinstance(key, str) and key.startswith(PREFIX) and isinstance(item, str)
        for key, item in value.items()
    ):
        die()
    keys = frozenset(value)
    if keys == PROBE_KEYS:
        pass
    elif keys == ORDINARY_KEYS:
        if value[PREFIX + "PHASE"] == "cleanup":
            die()
    elif keys == CLEANUP_KEYS:
        if value[PREFIX + "PHASE"] != "cleanup":
            die()
    else:
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

def authority_document(data, expected_authority_digest):
    try:
        document = plistlib.loads(data)
    except Exception:
        die()
    if (not isinstance(document, dict)
            or set(document) != {"MOOTSecretSyncHostAuthorityPublicKey"}):
        die()
    authority = document["MOOTSecretSyncHostAuthorityPublicKey"]
    if (not isinstance(authority, str) or not authority
            or hashlib.sha256(authority.encode("utf-8")).hexdigest()
                != expected_authority_digest):
        die()
    return document

def validate_authority(path, root, expected_digest, expected_identity,
                       expected_authority_digest):
    absolute_root = os.path.abspath(root)
    absolute_path = os.path.abspath(path)
    if (root != absolute_root or path != absolute_path
            or os.path.normpath(path) != path
            or os.path.realpath(root) != root
            or not beneath(path, root) or not no_symlink_components(path, root)):
        die()
    relative = os.path.relpath(path, root)
    if (relative == "." or relative.startswith(".." + os.sep)
            or not os.path.basename(root).startswith("transient.")):
        die()
    data, info = read_regular_bytes(path, 0o600)
    if (hashlib.sha256(data).hexdigest() != expected_digest
            or stable_identity(info) != expected_identity):
        die()
    authority_document(data, expected_authority_digest)

def create_authority(root, authority):
    if (not authority or root != os.path.abspath(root)
            or root != os.path.realpath(root) or os.path.islink(root)):
        die()
    data = plistlib.dumps(
        {"MOOTSecretSyncHostAuthorityPublicKey": authority},
        fmt=plistlib.FMT_BINARY, sort_keys=True
    )
    path = os.path.join(root, "authority-" + secrets.token_hex(16) + ".plist")
    descriptor = os.open(
        path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600
    )
    try:
        write_all(descriptor, data)
        os.fchmod(descriptor, 0o600)
        os.fsync(descriptor)
        info = require_regular_owned(os.fstat(descriptor), 0o600)
        digest = hashlib.sha256(data).hexdigest()
        identity = stable_identity(info)
    finally:
        os.close(descriptor)
    print("\t".join((
        digest, identity, hashlib.sha256(authority.encode("utf-8")).hexdigest(), path
    )))

def mutate_authority(path, mode, authority):
    documents = {
        "malformed": b"not-a-plist",
        "non-dictionary": plistlib.dumps([authority], fmt=plistlib.FMT_BINARY),
        "extra-key": plistlib.dumps({
            "MOOTSecretSyncHostAuthorityPublicKey": authority,
            "Unexpected": "forbidden",
        }, fmt=plistlib.FMT_BINARY, sort_keys=True),
        "absent-key": plistlib.dumps({}, fmt=plistlib.FMT_BINARY),
        "wrong-key": plistlib.dumps({
            "MOOTSecretSyncHostAuthorityPublicKEY": authority,
        }, fmt=plistlib.FMT_BINARY, sort_keys=True),
        "empty-authority": plistlib.dumps({
            "MOOTSecretSyncHostAuthorityPublicKey": "",
        }, fmt=plistlib.FMT_BINARY, sort_keys=True),
        "wrong-authority": plistlib.dumps({
            "MOOTSecretSyncHostAuthorityPublicKey": "WRONG-AUTHORITY",
        }, fmt=plistlib.FMT_BINARY, sort_keys=True),
        "same-inode-mutation": plistlib.dumps({
            "MOOTSecretSyncHostAuthorityPublicKey": authority + " ",
        }, fmt=plistlib.FMT_BINARY, sort_keys=True),
    }
    if mode not in documents:
        die()
    descriptor = os.open(path, os.O_WRONLY | os.O_NOFOLLOW)
    try:
        require_regular_owned(os.fstat(descriptor), 0o600)
        os.ftruncate(descriptor, 0)
        write_all(descriptor, documents[mode])
        os.fsync(descriptor)
    finally:
        os.close(descriptor)

def validate(path, root, expected_platform, authority_digest, mode=None, expected_environment=None):
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
    authority = info.get("MOOTSecretSyncHostAuthorityPublicKey")
    if (not isinstance(authority, str) or not authority
            or hashlib.sha256(authority.encode("utf-8")).hexdigest()
                != authority_digest):
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
if action == "create-authority":
    authority = sys.stdin.buffer.read().decode("utf-8")
    create_authority(sys.argv[2], authority)
elif action == "validate-authority":
    validate_authority(*sys.argv[2:7])
elif action == "mutate-authority":
    authority = sys.stdin.buffer.read().decode("utf-8")
    mutate_authority(sys.argv[2], sys.argv[3], authority)
elif action == "discover":
    root, platform, authority_digest = sys.argv[2:5]
    products = os.path.join(root, "Build", "Products")
    candidates = []
    for directory, names, files in os.walk(products, followlinks=False):
        names[:] = [name for name in names if not os.path.islink(os.path.join(directory, name))]
        candidates.extend(os.path.join(directory, name) for name in files if name.endswith(".xctestrun"))
    if len(candidates) != 1:
        die()
    _, digest, identity, _ = validate(candidates[0], root, platform, authority_digest)
    print(digest + "\t" + identity + "\t" + os.path.realpath(candidates[0]))
elif action == "inject":
    (source, copy, root, platform, authority_digest, environment_path,
     environment_digest, environment_identity, source_digest, source_identity,
     injection_attack) = sys.argv[2:13]
    document, current_source_digest, current_source_identity, data = validate(
        source, root, platform, authority_digest
    )
    if (current_source_digest != source_digest or current_source_identity != source_identity
            or os.path.dirname(source) != os.path.dirname(copy)):
        die()
    if os.path.lexists(copy) or not beneath(copy, root):
        die()
    if injection_attack not in ("none", "source-window", "copy-window"):
        die()
    source_window_mutated = injection_attack == "source-window"
    if source_window_mutated:
        mutated = bytearray(data)
        if not mutated:
            die()
        mutated[0] ^= 0xff
        overwrite_bound(source, mutated, source_identity)
    try:
        configuration_index, target_index, target = target_entry(document)
        environment = dict(target.get("EnvironmentVariables", {}))
        for key in list(environment):
            if key.startswith(PREFIX):
                del environment[key]
        expected_environment = load_environment(
            environment_path, environment_digest, environment_identity
        )
        environment.update(expected_environment)
        document["TestConfigurations"][configuration_index]["TestTargets"][target_index]["EnvironmentVariables"] = environment
        intended = plistlib.dumps(document, fmt=plistlib.FMT_BINARY, sort_keys=True)
        intended_digest = hashlib.sha256(intended).hexdigest()
        temporary = copy + ".new"
        descriptor = os.open(
            temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600
        )
        try:
            write_all(descriptor, intended)
            os.fchmod(descriptor, 0o600)
            os.fsync(descriptor)
            intended_identity = stable_identity(require_regular_owned(os.fstat(descriptor), 0o600))
        finally:
            os.close(descriptor)
        os.replace(temporary, copy)
    finally:
        if source_window_mutated:
            overwrite_bound(source, data, source_identity)
    directory_descriptor = os.open(os.path.dirname(copy), os.O_RDONLY)
    try:
        os.fsync(directory_descriptor)
    finally:
        os.close(directory_descriptor)
    if injection_attack == "copy-window":
        mutated = bytearray(intended)
        mutated[0] ^= 0xff
        overwrite_bound(copy, mutated, intended_identity)
    _, digest, identity, _ = validate(copy, root, platform, authority_digest, 0o600, expected_environment)
    if digest != intended_digest or identity != intended_identity:
        die()
    print(digest + "\t" + identity)
elif action == "verify":
    (source, copy, root, platform, authority_digest, environment_path,
     environment_digest, environment_identity, source_digest, source_identity,
     copy_digest, copy_identity) = sys.argv[2:14]
    _, current_source_digest, current_source_identity, _ = validate(source, root, platform, authority_digest)
    expected_environment = load_environment(
        environment_path, environment_digest, environment_identity
    )
    _, current_copy_digest, current_copy_identity, _ = validate(
        copy, root, platform, authority_digest, 0o600, expected_environment
    )
    if (current_source_digest != source_digest or current_source_identity != source_identity
            or current_copy_digest != copy_digest or current_copy_identity != copy_identity):
        die()
    if os.path.dirname(source) != os.path.dirname(copy):
        die()
elif action == "admit-evidence":
    print("\t".join(admit_evidence(*sys.argv[2:7])))
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
      "${authority_digest}"
}

write_environment_spec() {
  local output="$1"
  shift
  /usr/bin/python3 -c '
import hashlib, json, os, stat, sys
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
data = json.dumps(environment, sort_keys=True, separators=(",", ":")).encode("utf-8")
descriptor = os.open(
    output, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600
)
try:
    remaining = memoryview(data)
    while remaining:
        written = os.write(descriptor, remaining)
        if written <= 0:
            raise SystemExit(1)
        remaining = remaining[written:]
    os.fchmod(descriptor, 0o600)
    os.fsync(descriptor)
    info = os.fstat(descriptor)
    if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
            or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) != 0o600):
        raise SystemExit(1)
    identity = "{}:{}:{:o}".format(info.st_dev, info.st_ino, stat.S_IMODE(info.st_mode))
    print(hashlib.sha256(data).hexdigest() + "\t" + identity)
finally:
    os.close(descriptor)
' "${output}" < <(printf '%s\0' "$@") \
    || fail U7_RUNNER_ENVIRONMENT_INVALID
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
  if [[ "${runner_self_test_mode}" == 1 ]]; then
    case "${U7_SELF_TEST_XCTESTRUN_ATTACK:-}" in
      source-window|copy-window)
        injection_attack="${U7_SELF_TEST_XCTESTRUN_ATTACK}"
        ;;
    esac
  fi
  if [[ "${runner_self_test_mode}" == 1 \
    && "${U7_SELF_TEST_XCTESTRUN_ATTACK:-}" == environment-extra-key ]]; then
    set -- "$@" MOOT_SECRET_SYNC_UNKNOWN=forbidden
  fi
  local environment_binding environment_digest environment_identity
  environment_binding="$(write_environment_spec "${environment_spec}" "$@")"
  IFS=$'\t' read -r environment_digest environment_identity \
    <<<"${environment_binding}"
  [[ "${environment_digest}" =~ ^[0-9a-f]{64}$ \
    && "${environment_identity}" =~ ^[0-9]+:[0-9]+:[0-7]+$ ]] \
    || fail U7_RUNNER_ENVIRONMENT_INVALID
  if [[ "${runner_self_test_mode}" == 1 ]]; then
    case "${U7_SELF_TEST_XCTESTRUN_ATTACK:-}" in
      environment-replace)
        /bin/cp -p "${environment_spec}" "${environment_spec}.replacement"
        /bin/mv -f "${environment_spec}.replacement" "${environment_spec}"
        ;;
      environment-mutate)
        /usr/bin/printf ' ' >>"${environment_spec}"
        ;;
      environment-symlink)
        /bin/cp -p "${environment_spec}" "${environment_spec}.target"
        /bin/rm -f "${environment_spec}"
        /bin/ln -s "${environment_spec}.target" "${environment_spec}"
        ;;
      environment-hardlink)
        local environment_alias="${U7_RUN_DIR}/../u7-retained-environment-hardlink.json"
        /bin/ln "${environment_spec}" "${environment_alias}"
        attack_aliases+=("${environment_alias}")
        ;;
    esac
  fi
  capture_checked U7_RUNNER_XCTESTRUN_INVALID "${digest_file}" \
    /usr/bin/python3 "${plist_helper}" inject "${source}" "${copy}" \
      "${root}" "${platform}" "${authority_digest}" \
      "${environment_spec}" "${environment_digest}" "${environment_identity}" \
      "${source_digest}" "${source_identity}" "${injection_attack}"
  invocation_copies+=("${copy}")
  local copy_digest copy_identity
  IFS=$'\t' read -r copy_digest copy_identity <"${digest_file}"
  [[ "${copy_digest}" =~ ^[0-9a-f]{64}$ \
    && "${copy_identity}" =~ ^[0-9]+:[0-9]+:[0-7]+$ ]] \
    || fail U7_RUNNER_XCTESTRUN_INVALID
  prepared_copy="${copy}"
  prepared_environment_spec="${environment_spec}"
  prepared_environment_digest="${environment_digest}"
  prepared_environment_identity="${environment_identity}"
  prepared_copy_digest="${copy_digest}"
  prepared_copy_identity="${copy_identity}"
}

verify_invocation_copy() {
  local source="$1"
  local copy="$2"
  local root="$3"
  local platform="$4"
  local environment_spec="$5"
  local environment_digest="$6"
  local environment_identity="$7"
  local source_digest="$8"
  local source_identity="$9"
  local copy_digest="${10}"
  local copy_identity="${11}"
  run_checked U7_RUNNER_XCTESTRUN_INVALID \
    /usr/bin/python3 "${plist_helper}" verify "${source}" "${copy}" \
      "${root}" "${platform}" "${authority_digest}" \
      "${environment_spec}" "${environment_digest}" "${environment_identity}" \
      "${source_digest}" "${source_identity}" "${copy_digest}" \
      "${copy_identity}"
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
    hardlink)
      local copy_alias="${U7_RUN_DIR}/../u7-retained-copy-hardlink.xctestrun"
      /bin/ln "${prepared_copy}" "${copy_alias}"
      attack_aliases+=("${copy_alias}")
      ;;
    source-hardlink)
      local source_alias="${U7_RUN_DIR}/../u7-retained-source-hardlink.xctestrun"
      /bin/ln "${source_xctestrun}" "${source_alias}"
      attack_aliases+=("${source_alias}")
      ;;
    source-window)
      # The embedded helper performs and restores this mutation between its
      # descriptor-bound validation and private-copy construction.
      ;;
    copy-window)
      # The embedded helper mutates the installed copy before it can establish
      # the intended digest and identity as the invocation baseline.
      ;;
    environment-replace|environment-mutate|environment-symlink|environment-hardlink|environment-extra-key)
      # prepare_invocation_copy performs these environment-spec attacks before
      # the embedded helper reads the intended invocation allowlist.
      ;;
    *)
      fail U7_RUNNER_XCTESTRUN_INVALID
      ;;
  esac
}

admit_evidence() {
  local directory="$1"
  local test_identifier="$2"
  local evidence_kind="$3"
  local output="$4"
  local binding_file="${transient}/evidence-$RANDOM.txt"
  mkdir "${output}"
  chmod 700 "${output}"
  capture_checked U7_RUNNER_EVIDENCE_MISSING "${binding_file}" \
    /usr/bin/python3 "${plist_helper}" admit-evidence \
      "${directory}" "${transient}" "${test_identifier}" \
      "${evidence_kind}" "${output}"
  IFS=$'\t' read -r admitted_primary admitted_secondary <"${binding_file}"
  [[ -n "${admitted_primary}" ]] || fail U7_RUNNER_EVIDENCE_MISSING
  if [[ "${evidence_kind}" == stage ]]; then
    [[ -n "${admitted_secondary}" ]] || fail U7_RUNNER_EVIDENCE_MISSING
  else
    [[ -z "${admitted_secondary}" ]] || fail U7_RUNNER_EVIDENCE_MISSING
  fi
}

create_authority_plist() {
  local log="${transient}/authority-plist-create.log"
  local binding
  if ! binding="$(/usr/bin/printf '%s' "${authority}" \
    | /usr/bin/python3 "${plist_helper}" create-authority "${transient}" \
      2>"${log}")"; then
    fail U7_RUNNER_INFOPLIST_INVALID
  fi
  IFS=$'\t' read -r authority_plist_digest authority_plist_identity \
    authority_digest authority_plist <<<"${binding}"
  [[ "${authority_plist_digest}" =~ ^[0-9a-f]{64}$ \
    && "${authority_plist_identity}" =~ ^[0-9]+:[0-9]+:[0-7]+$ \
    && "${authority_digest}" =~ ^[0-9a-f]{64}$ \
    && -n "${authority_plist}" ]] || fail U7_RUNNER_INFOPLIST_INVALID
}

validate_authority_plist() {
  local log="${transient}/authority-plist-validate-$RANDOM.log"
  if ! /usr/bin/python3 "${plist_helper}" validate-authority \
    "${authority_plist}" "${transient}" "${authority_plist_digest}" \
    "${authority_plist_identity}" "${authority_digest}" \
    >"${log}" 2>&1; then
    fail U7_RUNNER_INFOPLIST_INVALID
  fi
}

mutate_authority_plist() {
  local mode="$1"
  local log="${transient}/authority-plist-mutate.log"
  if ! /usr/bin/printf '%s' "${authority}" \
    | /usr/bin/python3 "${plist_helper}" mutate-authority \
      "${authority_plist}" "${mode}" >"${log}" 2>&1; then
    fail U7_RUNNER_INFOPLIST_INVALID
  fi
}

authority_attack=""
if [[ "${runner_self_test_mode}" == 1 ]]; then
  authority_attack="${U7_SELF_TEST_INFOPLIST_ATTACK:-}"
fi

apply_authority_attack_before_mac() {
  case "${authority_attack}" in
    ''|legacy-only|legacy-reappearance|missing-infoplist|duplicate-infoplist|relative-infoplist|empty-infoplist|unexpected-infoplist|missing-generate|duplicate-generate|between-build-replace|between-build-mutation|between-build-path|between-build-authority)
      ;;
    replace)
      /bin/cp -p "${authority_plist}" "${authority_plist}.replacement"
      /bin/mv -f "${authority_plist}.replacement" "${authority_plist}"
      ;;
    same-inode-mutation|malformed|non-dictionary|extra-key|absent-key|wrong-key|empty-authority|wrong-authority)
      mutate_authority_plist "${authority_attack}"
      ;;
    symlink)
      /bin/cp -p "${authority_plist}" "${authority_plist}.target"
      /bin/rm -f -- "${authority_plist}"
      /bin/ln -s "${authority_plist}.target" "${authority_plist}"
      ;;
    hardlink)
      local alias="${U7_RUN_DIR}/../u7-retained-authority-hardlink.plist"
      [[ ! -e "${alias}" && ! -L "${alias}" ]] \
        || fail U7_RUNNER_INFOPLIST_INVALID
      attack_aliases+=("${alias}")
      /bin/ln "${authority_plist}" "${alias}" \
        || fail U7_RUNNER_INFOPLIST_INVALID
      ;;
    mode)
      /bin/chmod 400 "${authority_plist}"
      ;;
    lexical-traversal)
      authority_plist="${transient}/../$(/usr/bin/basename "${transient}")/$(/usr/bin/basename "${authority_plist}")"
      ;;
    outside-path|stale-carrier|second-run-reuse)
      local external="${U7_RUN_DIR}/u7-${authority_attack}.plist"
      [[ ! -e "${external}" && ! -L "${external}" ]] \
        || fail U7_RUNNER_INFOPLIST_INVALID
      attack_aliases+=("${external}")
      /bin/cp -p "${authority_plist}" "${external}"
      authority_plist="${external}"
      ;;
    resolved-escape)
      local external="${U7_RUN_DIR}/u7-resolved-escape.plist"
      local escape="${transient}/escape"
      [[ ! -e "${external}" && ! -L "${external}" ]] \
        || fail U7_RUNNER_INFOPLIST_INVALID
      attack_aliases+=("${external}")
      /bin/cp -p "${authority_plist}" "${external}"
      /bin/ln -s "${U7_RUN_DIR}" "${escape}"
      authority_plist="${escape}/$(/usr/bin/basename "${external}")"
      ;;
    *) fail U7_RUNNER_INFOPLIST_INVALID ;;
  esac
}

apply_authority_attack_between_builds() {
  case "${authority_attack}" in
    between-build-replace)
      /bin/cp -p "${authority_plist}" "${authority_plist}.replacement"
      /bin/mv -f "${authority_plist}.replacement" "${authority_plist}"
      ;;
    between-build-mutation)
      mutate_authority_plist same-inode-mutation
      ;;
    between-build-path)
      /bin/cp -p "${authority_plist}" "${authority_plist}.second"
      authority_plist="${authority_plist}.second"
      ;;
    between-build-authority)
      mutate_authority_plist wrong-authority
      ;;
  esac
}

prepare_authority_build_settings() {
  local stage="$1"
  local legacy_setting_prefix='INFOPLIST_KEY_MOOTSecretSyncHostAuthorityPublic''Key='
  authority_build_settings=(
    GENERATE_INFOPLIST_FILE=NO
    "INFOPLIST_FILE=${authority_plist}"
  )
  if [[ "${stage}" == mac ]]; then
    case "${authority_attack}" in
      legacy-only)
        authority_build_settings=("${legacy_setting_prefix}${authority}")
        ;;
      legacy-reappearance)
        authority_build_settings+=("${legacy_setting_prefix}${authority}")
        ;;
      missing-infoplist) authority_build_settings=(GENERATE_INFOPLIST_FILE=NO) ;;
      duplicate-infoplist) authority_build_settings+=("INFOPLIST_FILE=${authority_plist}") ;;
      relative-infoplist) authority_build_settings[1]='INFOPLIST_FILE=relative.plist' ;;
      empty-infoplist) authority_build_settings[1]='INFOPLIST_FILE=' ;;
      unexpected-infoplist) authority_build_settings[1]="INFOPLIST_FILE=${authority_plist}.unexpected" ;;
      missing-generate) authority_build_settings=("INFOPLIST_FILE=${authority_plist}") ;;
      duplicate-generate) authority_build_settings+=(GENERATE_INFOPLIST_FILE=NO) ;;
    esac
  fi
  local generate_count=0 plist_count=0 legacy_count=0 setting
  for setting in "${authority_build_settings[@]}"; do
    case "${setting}" in
      GENERATE_INFOPLIST_FILE=NO) generate_count=$((generate_count + 1)) ;;
      INFOPLIST_FILE=*)
        plist_count=$((plist_count + 1))
        [[ "${setting}" == "INFOPLIST_FILE=${authority_plist}" ]] \
          || fail U7_RUNNER_INFOPLIST_INVALID
        ;;
      "${legacy_setting_prefix}"*)
        legacy_count=$((legacy_count + 1))
        ;;
      *) fail U7_RUNNER_INFOPLIST_INVALID ;;
    esac
  done
  [[ "${#authority_build_settings[@]}" == 2 \
    && "${generate_count}" == 1 && "${plist_count}" == 1 \
    && "${legacy_count}" == 0 ]] || fail U7_RUNNER_INFOPLIST_INVALID
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

create_authority_plist
apply_authority_attack_before_mac
validate_authority_plist
prepare_authority_build_settings mac
run_xcode_checked U7_RUNNER_BUILD_FAILED \
  "${U7_XCODEBUILD}" build-for-testing \
  -scheme "${scheme}" -derivedDataPath "${mac_derived}" \
  -destination "${U7_DEST_A}" \
  "${authority_build_settings[@]}"
discover_product "${mac_derived}" MacOSX "${transient}/mac-product.txt"
IFS=$'\t' read -r mac_source_digest mac_source_identity mac_source \
  <"${transient}/mac-product.txt"
[[ "${mac_source_digest}" =~ ^[0-9a-f]{64}$ \
  && "${mac_source_identity}" =~ ^[0-9]+:[0-9]+:[0-7]+$ \
  && -n "${mac_source}" ]] \
  || fail U7_RUNNER_PRODUCT_INVALID

# One authorized iPhone destination builds the shared iOS test products used
# by both the iPhone and iPad phases; both platform builds precede every run.
apply_authority_attack_between_builds
validate_authority_plist
prepare_authority_build_settings ios
run_xcode_checked U7_RUNNER_BUILD_FAILED \
  "${U7_XCODEBUILD}" build-for-testing \
  -scheme "${scheme}" -derivedDataPath "${ios_derived}" \
  -destination "${U7_DEST_B}" \
  "${authority_build_settings[@]}"
discover_product "${ios_derived}" iPhoneOS "${transient}/ios-product.txt"
IFS=$'\t' read -r ios_source_digest ios_source_identity ios_source \
  <"${transient}/ios-product.txt"
[[ "${ios_source_digest}" =~ ^[0-9a-f]{64}$ \
  && "${ios_source_identity}" =~ ^[0-9]+:[0-9]+:[0-7]+$ \
  && -n "${ios_source}" ]] \
  || fail U7_RUNNER_PRODUCT_INVALID
validate_authority_plist

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
  admit_evidence "${output}" \
    'SecretSyncLiveCloudKitProofTests/externalPhase()' \
    stage "${output}/admitted"
  receipt="${admitted_primary}"
  inventory="${admitted_secondary}"
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
      "${prepared_environment_digest}" "${prepared_environment_identity}" \
      "${source_digest}" "${source_identity}" "${prepared_copy_digest}" \
      "${prepared_copy_identity}"
    run_xcode_checked U7_RUNNER_PROBE_FAILED \
      "${U7_XCODEBUILD}" test-without-building \
        -xctestrun "${prepared_copy}" \
        -destination "${destination}" -resultBundlePath "${probe_result}" \
        '-only-testing:ConvergenceKitSecretSyncConformanceTests/SecretSyncLiveCloudKitProofTests/ledgerProbe()'
    run_checked U7_RUNNER_PROBE_EXPORT_FAILED \
      "${U7_XCRESULTTOOL}" export attachments --path "${probe_result}" \
        --output-path "${phase_directory}/probe-attachments"
    admit_evidence "${phase_directory}/probe-attachments" \
      'SecretSyncLiveCloudKitProofTests/ledgerProbe()' \
      probe "${phase_directory}/probe-admitted"
    probe="${admitted_primary}"
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
      "${prepared_environment_digest}" "${prepared_environment_identity}" \
      "${source_digest}" "${source_identity}" "${prepared_copy_digest}" \
      "${prepared_copy_identity}"
    phase_log="${transient}/phase-${number}.log"
    if ! (cd "${package_directory}" \
      && "${sanitized_environment[@]}" \
      "${U7_XCODEBUILD}" test-without-building \
      -xctestrun "${prepared_copy}" \
      -destination "${destination}" -resultBundlePath "${phase_result}" \
      '-only-testing:ConvergenceKitSecretSyncConformanceTests/SecretSyncLiveCloudKitProofTests/externalPhase()' \
      ) >"${phase_log}" 2>&1; then
      /bin/rm -rf -- "${phase_result}"
      fail U7_RUNNER_PHASE_FAILED
    fi
    interrupt_if_requested U7_SELF_TEST_INTERRUPT_AFTER_RESULT_INDEX "${index}"
  fi
  run_checked U7_RUNNER_PHASE_EXPORT_FAILED \
    "${U7_XCRESULTTOOL}" export attachments --path "${phase_result}" \
      --output-path "${phase_directory}/phase-attachments"
  evidence_kind=ordinary
  [[ "${phase}" != stage ]] || evidence_kind=stage
  admit_evidence "${phase_directory}/phase-attachments" \
    'SecretSyncLiveCloudKitProofTests/externalPhase()' \
    "${evidence_kind}" "${phase_directory}/phase-admitted"
  receipt="${admitted_primary}"
  inventory="${admitted_secondary}"
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
