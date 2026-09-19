#!/usr/bin/env bash
# smoke-check.sh — the assertion half of `make smoke`.
#
# A smoke pass runs one real unit per arm of every lane into ONE output
# directory. This script is what makes that pass worth running: it checks the
# directory the way a collision would show up, and compiles the result set into
# a single readable summary.
#
# Why it exists. On 2026-08-17 four matrix arms each wrote
# `matrix-report-seed20260816.json` — one path — and the last arm silently
# replaced the other three. 4h19m of measurement was gone, and nothing failed:
# every lane exited 0, and the surviving report looked healthy. The defect is
# invisible per lane and obvious across lanes, which is precisely what a
# one-unit-per-arm pass into a shared directory exposes in minutes.
#
# Checks, in order of what a violation costs:
#   1. COLLISION   — two records resolving to one filename.
#   2. PAIRING     — a report whose params sidecar names a different arm.
#   3. ORPHAN      — a sidecar with no report, or a report with no sidecar.
#   4. COVERAGE    — fewer records than arms attempted.
#
# Usage: smoke-check.sh <out-dir> <expected-arms-file>
# Exit 0 when every check passes; 1 on any violation.

set -uo pipefail

OUT="${1:?usage: smoke-check.sh <out-dir> <expected-arms-file>}"
EXPECTED="${2:?usage: smoke-check.sh <out-dir> <expected-arms-file>}"
SUMMARY="$OUT/smoke-summary.md"

[ -d "$OUT" ] || { echo "[smoke-check] FATAL: no such directory: $OUT"; exit 1; }
[ -f "$EXPECTED" ] || { echo "[smoke-check] FATAL: no arms file: $EXPECTED"; exit 1; }

violations=0
note() { echo "[smoke-check] $*"; }
fail() { echo "[smoke-check] VIOLATION: $*"; violations=$((violations + 1)); }

# ── 1. Collision ────────────────────────────────────────────────────────────
# Records are written with O_EXCL, so a collision now raises inside the lane
# rather than replacing a file. This check is the belt to that suspenders: it
# catches a collision that happened via any other path (a copy, a move, a lane
# that still writes with fs::write).
note "checking for colliding record names"
dupes=$(find "$OUT" -maxdepth 1 -name '*.json' -exec basename {} \; \
        | sort | uniq -d)
if [ -n "$dupes" ]; then
  fail "duplicate record names: $dupes"
fi

# ── 2. Pairing ──────────────────────────────────────────────────────────────
# A params sidecar is <test>-<arm>-<serial>-params.json and its report is
# <test>-<arm>-<serial>.json. The pair must exist and the sidecar's own `arm`
# field must equal the arm in its name — a sidecar that labels a report it does
# not describe is how the 2026-08-17 loss presented after the fact.
note "checking report/sidecar pairing"
shopt -s nullglob
for sidecar in "$OUT"/*-params.json; do
  base=$(basename "$sidecar" -params.json)
  report="$OUT/$base.json"
  if [ ! -f "$report" ]; then
    # A lane that reports to stdout by design has a sidecar and no JSON report.
    # Those are named in the arms file with `stdout` and skipped here.
    lane=$(printf '%s' "$base" | cut -d- -f1)
    if grep -q "^${lane}[[:space:]].*[[:space:]]stdout$" "$EXPECTED" 2>/dev/null; then
      continue
    fi
    fail "sidecar without report: $(basename "$sidecar")"
    continue
  fi
  # The arm recorded inside the sidecar must match the arm in the filename.
  name_arm=$(printf '%s' "$base" | sed -E 's/^[a-z]+-(.*)-[0-9]{8}T[0-9]{6}Z$/\1/')
  file_arm=$(python3 -c "
import json,sys
try:
    print(json.load(open(sys.argv[1])).get('arm',''))
except Exception:
    print('')
" "$sidecar")
  if [ -n "$file_arm" ] && [ "$name_arm" != "$file_arm" ]; then
    fail "sidecar $(basename "$sidecar") names arm '$name_arm' but records arm '$file_arm'"
  fi
done

# ── 3. Orphan reports ───────────────────────────────────────────────────────
note "checking every report has its params sidecar"
for report in "$OUT"/*.json; do
  case "$report" in
    *-params.json) continue ;;
  esac
  base=$(basename "$report" .json)
  [ -f "$OUT/$base-params.json" ] || fail "report without sidecar: $(basename "$report")"
done

# ── 4. Coverage ─────────────────────────────────────────────────────────────
# Every arm the pass attempted must have left a record. A lane that exits
# nonzero leaves none, which is how the journey lane's missing live runner
# surfaces here rather than after six hours of matrix work.
note "checking every attempted arm produced a record"
while read -r lane arm kind; do
  [ -z "${lane:-}" ] && continue
  case "$lane" in \#*) continue ;; esac
  if [ "$kind" = "stdout" ]; then
    found=$(find "$OUT" -maxdepth 1 -name "$lane-$arm-*-params.json" | head -1)
  else
    found=$(find "$OUT" -maxdepth 1 -name "$lane-$arm-*.json" \
            -not -name '*-params.json' | head -1)
  fi
  [ -n "$found" ] || fail "no record for arm: $lane / $arm"
done < "$EXPECTED"

# ── Compiled summary ────────────────────────────────────────────────────────
# The point of a smoke pass is a complete result set you can read in one place.
{
  echo "# Smoke pass — $(basename "$OUT")"
  echo
  echo "One real unit per arm, every lane, one output directory."
  echo
  echo "| Lane | Arm | Record | Headline | Status |"
  echo "|---|---|---|---|---|"
  while read -r lane arm kind; do
    [ -z "${lane:-}" ] && continue
    case "$lane" in \#*) continue ;; esac
    if [ "$kind" = "stdout" ]; then
      rec=$(find "$OUT" -maxdepth 1 -name "$lane-$arm-*-params.json" -exec basename {} \; | head -1)
      head="(stdout lane — see $lane.log)"
    else
      rec=$(find "$OUT" -maxdepth 1 -name "$lane-$arm-*.json" -not -name '*-params.json' \
            -exec basename {} \; | head -1)
      if [ -n "$rec" ]; then
        head=$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
# Each lane keeps its headline in a different place. The first path that
# resolves wins, so a lane whose figures nest (journey) reads as well as one
# with a flat aggregate. A lane missing from this list prints '(no headline
# field)', which reads as a gap in this script rather than a gap in the record.
for path in (('aggregate','recall_at_10'),('aggregate','recall_any_at_10'),
             ('aggregate','mrr'),
             ('precise_miss_aggregate','target_over_decoy_rate'),
             ('vague_narrow_aggregate','true_found_rate'),
             ('failures',),('databases',)):
    cur=d; ok=True
    for k in path:
        if isinstance(cur,dict) and k in cur: cur=cur[k]
        else: ok=False; break
    if ok and not isinstance(cur,(dict,list)):
        print(f\"{'.'.join(path)}={cur}\"); break
else:
    print('(no headline field)')
" "$OUT/$rec" 2>/dev/null || echo "(unreadable)")
      else
        head="—"
      fi
    fi
    status=$([ -n "$rec" ] && echo "ok" || echo "MISSING")
    echo "| $lane | $arm | ${rec:-—} | $head | $status |"
  done < "$EXPECTED"
  echo
  if [ "$violations" -eq 0 ]; then
    echo "**No violations.** Names distinct, every report paired with its sidecar,"
    echo "every attempted arm left a record."
  else
    echo "**$violations violation(s).** See the smoke-check output above."
  fi
} > "$SUMMARY"

# ── 5. Keychain pollution guard (2026-08-26) ────────────────────────────────
# Every harness estate runs under the declared ephemeral posture (identity
# keys in-memory) and plaintext-optout / keyfile-backed encryption (no db-key
# mints), so a smoke pass must mint ZERO moot keychain items. Growth here is
# a posture regression in some lane's serve/upgrade wiring — the exact defect
# that silently accumulated ~1,000 items between 2026-08-13 and 2026-08-26.
note "checking keychain item count against pass baseline"
if [ -f "$OUT/keychain-baseline.txt" ]; then
  kc_before=$(cat "$OUT/keychain-baseline.txt")
  kc_after=$(security dump-keychain 2>/dev/null \
    | grep -c 'com\.mootx01\.estate\.identity\|com\.codedaptive\.mootx01' || echo 0)
  if [ "$kc_after" -gt "$kc_before" ]; then
    fail "keychain grew during the pass: $kc_before -> $kc_after moot items (a lane minted identity/db keys — ephemeral posture regression)"
  fi
fi

note "summary written to $SUMMARY"
if [ "$violations" -gt 0 ]; then
  note "FAILED with $violations violation(s)"
  exit 1
fi
note "PASS"
