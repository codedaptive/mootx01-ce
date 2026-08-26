#!/bin/bash
set -euo pipefail

if [[ $# -eq 2 && "$1" == "--repo-root" ]]; then
  repo_root="$(cd "$2" && pwd)"
elif [[ $# -eq 0 ]]; then
  app_root_from_script="$(cd "$(dirname "$0")/.." && pwd)"
  repo_root="$(cd "$app_root_from_script/../.." && pwd)"
else
  echo "usage: $0 [--repo-root PATH]" >&2
  exit 64
fi

app_root="$repo_root/apps/Mootx01-App"
project_contract="$app_root/project.community.yml"
package_contract="$app_root/Package.community.swift"
[[ -f "$project_contract" ]] || project_contract="$app_root/project.yml"
[[ -f "$package_contract" ]] || package_contract="$app_root/Package.swift"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/mootx01-community-verify.XXXXXX")"
trap '/bin/rm -rf -- "$scratch"' EXIT

# Version handshake only. Shape, classification and exhaustiveness are decided
# by scripts/repo_sync/community_export.py, invoked below in the EE workshop.
# That module lives under EE-only scripts/ and is absent from a CE projection,
# so this side checks the version it was written against and nothing more.
/usr/bin/jq -e '
  .schema == 3 and
  (.copy | type == "array") and
  (.rename | type == "object") and
  (.replace | type == "array") and
  (.remove | type == "array") and
  (.lockfileOriginHashes | type == "object") and
  (.ceGuardRequired | type == "array") and
  (.forbidden | type == "array")
' "$app_root/community-export.json" >/dev/null || {
  echo "Community export manifest is not a valid schema-3 contract" >&2
  exit 1
}

# In the EE workshop, prove three things the CE side structurally cannot.
#
# Exhaustiveness needs the tracked git tree -- the set of files that EXIST in
# EE -- and a CE projection has neither that tree nor the private files in it.
# So the exhaustiveness invariant is enforced here and in port-verify.py, and
# the projection stays verifiable with nothing private on disk.
#
# The forbidden/SHARED agreement is the other EE-only check: a forbidden path
# the ordinary port lane still calls SHARED is removed by this publisher and
# faithfully restored by the next routine port, so the leak closes and reopens
# on a schedule nobody watches.
# Presence of Sources/MootProGateway is what distinguishes the EE workshop
# from a CE projection. In the workshop the port tooling MUST be present: a
# missing edition-boundary.conf used to fold into this condition and skip the
# checks silently, so an incomplete checkout still printed "verified". The
# strongest checks in this script now live here, so absence is an error.
if [[ -d "$app_root/Sources/MootProGateway" ]]; then
  [[ -f "$repo_root/scripts/repo_sync/edition-boundary.conf" ]] || {
    echo "EE workshop is missing scripts/repo_sync/edition-boundary.conf" >&2
    exit 1
  }
  [[ -f "$repo_root/scripts/repo_sync/community_export.py" ]] || {
    echo "EE workshop is missing scripts/repo_sync/community_export.py" >&2
    exit 1
  }
  /usr/bin/python3 - "$repo_root" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
sys.path.insert(0, str(root / "scripts/repo_sync"))
import community_export
from boundary import parse_conf

# Run the validator's own fixtures before trusting its verdict: a validator
# that had silently stopped detecting anything would otherwise report a clean
# tree, and the report would be indistinguishable from a real pass.
community_export.self_test()

manifest = community_export.load(
    (root / "apps/Mootx01-App/community-export.json").read_text())

findings = community_export.audit(manifest, community_export.tracked_paths(root))
if findings:
    print("Community export contract is not exhaustive:", file=sys.stderr)
    for finding in findings:
        print(f"  {finding}", file=sys.stderr)
    raise SystemExit(1)

ee_only, surface = parse_conf(root / "scripts/repo_sync/edition-boundary.conf")
conflicts = community_export.forbidden_shared_conflicts(manifest, ee_only, surface)
if conflicts:
    print("Community forbidden paths are still classified SHARED:", file=sys.stderr)
    for path in conflicts:
        print(f"  {path}", file=sys.stderr)
    raise SystemExit(1)
PY
fi

if [[ ! -d "$app_root/Sources/MootProGateway" ]]; then
  while IFS=$'\t' read -r relative expected_hash; do
    actual_hash="$(/usr/bin/jq -r '.originHash' "$repo_root/$relative")"
    if [[ "$actual_hash" != "$expected_hash" ]]; then
      echo "Community lockfile origin hash mismatch: $relative" >&2
      exit 1
    fi
  done < <(/usr/bin/jq -r '.lockfileOriginHashes | to_entries[] | [.key, .value] | @tsv' "$app_root/community-export.json")
fi

app_lock_before="$(/usr/bin/shasum -a 256 "$app_root/Package.resolved" | awk '{print $1}')"

scanner="$app_root/scripts/check-community-imports.py"
/usr/bin/python3 "$scanner" --self-test
/usr/bin/python3 "$scanner" \
  "$app_root/CommunityApp" \
  "$app_root/Sources/MootCommunityGateway" \
  "$app_root/Sources/MootCommunityUI" \
  "$app_root/Tests/CommunityBoundaryTests"

if ! /usr/bin/grep -q -E 'product:[[:space:]]+MootCommunityUI' "$project_contract"; then
  echo "Community project does not link MootCommunityUI" >&2
  exit 1
fi

if /usr/bin/grep -q -E 'MootProUI|MootProGateway|MootEnterprise|CloudKit|Mootx01-Widget|Mootx01-Share' "$project_contract"; then
  echo "Community project names a private product or service" >&2
  exit 1
fi

if /usr/bin/grep -q -E 'MootPro|MootEnterprise|product\(name: "MootIntentKit"' "$package_contract"; then
  echo "Community package manifest names a private module" >&2
  exit 1
fi

if [[ ! -d "$app_root/Sources/MootProGateway" ]]; then
  guard="$repo_root/scripts/prepush_ee_leak_guard.sh"
  [[ -f "$guard" ]] || {
    echo "CE push guard is missing: scripts/prepush_ee_leak_guard.sh" >&2
    exit 1
  }
  /usr/bin/python3 - "$app_root/community-export.json" "$guard" <<'PY'
import json
import pathlib
import re
import sys

manifest = json.loads(pathlib.Path(sys.argv[1]).read_text())
text = pathlib.Path(sys.argv[2]).read_text()
match = re.search(r"EE_ONLY_RE=(['\"])(.*?)\1", text, re.S)
if not match:
    print("CE push guard has no parseable EE_ONLY_RE", file=sys.stderr)
    raise SystemExit(1)
pattern = match.group(2)
prefix = "^("
suffix = ")(/|$)"
if not pattern.startswith(prefix) or not pattern.endswith(suffix):
    print("CE push guard EE_ONLY_RE does not use the governed anchored shape", file=sys.stderr)
    raise SystemExit(1)
body = pattern[len(prefix):-len(suffix)]
guarded = {entry.replace("\\", "").rstrip("/") for entry in body.split("|")}
required = {entry.rstrip("/") for entry in manifest["ceGuardRequired"]}
missing = sorted(required - guarded)
if missing:
    print("CE push guard omits Community-private package paths:", file=sys.stderr)
    for path in missing:
        print(f"  {path}", file=sys.stderr)
    raise SystemExit(1)
PY

  while IFS= read -r forbidden; do
    if [[ -e "$repo_root/$forbidden" ]]; then
      echo "Community projection contains forbidden path: $forbidden" >&2
      exit 1
    fi
  done < <(/usr/bin/jq -r '.forbidden[]' "$app_root/community-export.json")
fi

community_dependencies="$(swift package --package-path "$app_root" --scratch-path "$scratch/app" dump-package \
  | /usr/bin/jq -r '.targets[] | select(.name == "MootCommunityUI") | .dependencies[] | if has("byName") then .byName[0] else .product[0] end' \
  | sort)"
if [[ "$community_dependencies" != "MootCommunityGateway" ]]; then
  echo "Community UI dependency graph is not the exact open boundary:" >&2
  echo "$community_dependencies" >&2
  exit 1
fi

gateway_dependencies="$(swift package --package-path "$app_root" --scratch-path "$scratch/app" dump-package \
  | /usr/bin/jq -r '.targets[] | select(.name == "MootCommunityGateway") | .dependencies[] | if has("byName") then .byName[0] else .product[0] end' \
  | sort)"
if [[ "$gateway_dependencies" != "AriaMCPWire" ]]; then
  echo "Community gateway dependency graph is not wire-only:" >&2
  echo "$gateway_dependencies" >&2
  exit 1
fi

swift build --disable-automatic-resolution --package-path "$app_root" --scratch-path "$scratch/app" --target MootCommunityUI

# A projected CE tree has no private targets, so its complete package tests are
# the strongest proof that the publication carries executable test coverage.
# In the EE workshop the full package includes Pro suites; those run in the
# ordinary repository gate instead of this narrow boundary verifier.
if [[ ! -d "$app_root/Sources/MootProGateway" ]]; then
  swift test --disable-automatic-resolution --package-path "$app_root" --scratch-path "$scratch/app"
fi


app_lock_after="$(/usr/bin/shasum -a 256 "$app_root/Package.resolved" | awk '{print $1}')"
if [[ "$app_lock_before" != "$app_lock_after" ]]; then
  echo "Community verification mutated a governed Package.resolved" >&2
  exit 1
fi

echo "Community source and dependency boundary verified"
