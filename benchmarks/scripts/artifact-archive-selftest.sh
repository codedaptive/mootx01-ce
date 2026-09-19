#!/usr/bin/env bash
# artifact-archive-selftest.sh — proves artifact-archive.sh against throwaway
# directories, never against real artifacts.
#
# Everything happens under one temporary root that this script creates and
# removes. No real cache, no real archive, no environment variable that could
# point it at either. Run it before trusting `make archive` or
# `make clean-local` with anything that matters.
#
# The cases, in the order they run:
#   1. two-level layout (estate cache): copy, verify, clean removes everything
#   2. one-level layout (landscape cache): same
#   3. archive missing a unit          -> clean KEEPS that unit, exits nonzero
#   4. archive copy truncated          -> clean KEEPS that unit, exits nonzero
#   5. archive root empty              -> clean REFUSES outright
#   6. archive root absent             -> clean REFUSES outright
#
# Cases 3 to 6 are the ones worth having. A clean that deletes only what it
# should is easy; a clean that REFUSES when the other copy is not there is the
# property that keeps 542 GB of artifacts alive.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCHIVE_SH="$HERE/artifact-archive.sh"
[ -x "$ARCHIVE_SH" ] || chmod +x "$ARCHIVE_SH"

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/artifact-archive-selftest.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

pass=0; fail=0
ok()   { echo "  PASS  $*"; pass=$((pass + 1)); }
bad()  { echo "  FAIL  $*"; fail=$((fail + 1)); }

# make_unit <dir> <n-files>
make_unit() {
  mkdir -p "$1"
  for i in $(seq 1 "$2"); do
    printf 'unit %s file %s payload\n' "$(basename "$1")" "$i" > "$1/file$i.dat"
  done
}

# ── Case 1: two-level layout, the estate-cache shape ────────────────────────
echo "[selftest] case 1 — two-level layout, full round trip"
L="$ROOT/c1/local"; A="$ROOT/c1/archive"
make_unit "$L/setA/unit1" 3
make_unit "$L/setA/unit2" 2
make_unit "$L/setB/unit3" 4
"$ARCHIVE_SH" copy   "$L" "$A" >/dev/null 2>&1 || bad "case 1: copy failed"
"$ARCHIVE_SH" verify "$L" "$A" >/dev/null 2>&1 && ok "case 1: verify passes after copy" \
                                              || bad "case 1: verify failed after copy"
[ -f "$A/setA/unit1/file1.dat" ] && ok "case 1: archive holds the files" \
                                 || bad "case 1: archive is missing files"
"$ARCHIVE_SH" clean  "$L" "$A" >/dev/null 2>&1 && ok "case 1: clean succeeded" \
                                              || bad "case 1: clean reported failure"
if [ ! -d "$L/setA/unit1" ] && [ ! -d "$L/setB/unit3" ]; then
  ok "case 1: local units removed"
else
  bad "case 1: local units survived a clean"
fi
[ -f "$A/setA/unit1/file1.dat" ] && ok "case 1: archive untouched by clean" \
                                 || bad "case 1: clean damaged the archive"

# ── Case 2: one-level layout, the landscape-cache shape ─────────────────────
echo "[selftest] case 2 — one-level layout"
L="$ROOT/c2/local"; A="$ROOT/c2/archive"
make_unit "$L/rows2000" 2
make_unit "$L/rows10000" 3
"$ARCHIVE_SH" copy  "$L" "$A" >/dev/null 2>&1
"$ARCHIVE_SH" clean "$L" "$A" >/dev/null 2>&1 && ok "case 2: clean succeeded" \
                                             || bad "case 2: clean reported failure"
[ ! -d "$L/rows2000" ] && ok "case 2: local entry removed" \
                       || bad "case 2: local entry survived"
[ -f "$A/rows10000/file1.dat" ] && ok "case 2: archive holds the entry" \
                                || bad "case 2: archive is missing the entry"

# ── Case 3: a unit the archive never received ───────────────────────────────
echo "[selftest] case 3 — unit missing from the archive"
L="$ROOT/c3/local"; A="$ROOT/c3/archive"
make_unit "$L/setA/copied" 2
make_unit "$L/setA/never" 2
"$ARCHIVE_SH" copy "$L" "$A" >/dev/null 2>&1
rm -rf "$A/setA/never"                       # the archive loses one unit
"$ARCHIVE_SH" clean "$L" "$A" >/dev/null 2>&1 && bad "case 3: clean exited 0 with a unit unarchived" \
                                             || ok "case 3: clean exits nonzero"
[ -d "$L/setA/never" ]  && ok "case 3: unarchived unit KEPT" \
                        || bad "case 3: unarchived unit was DELETED"
[ ! -d "$L/setA/copied" ] && ok "case 3: verified unit still removed" \
                          || bad "case 3: verified unit was not removed"

# ── Case 4: an archive copy that is short a file ────────────────────────────
echo "[selftest] case 4 — truncated archive copy"
L="$ROOT/c4/local"; A="$ROOT/c4/archive"
make_unit "$L/setA/partial" 4
"$ARCHIVE_SH" copy "$L" "$A" >/dev/null 2>&1
rm -f "$A/setA/partial/file4.dat"            # an interrupted copy
"$ARCHIVE_SH" clean "$L" "$A" >/dev/null 2>&1 && bad "case 4: clean exited 0 on a short copy" \
                                             || ok "case 4: clean exits nonzero"
[ -d "$L/setA/partial" ] && ok "case 4: partially-archived unit KEPT" \
                         || bad "case 4: partially-archived unit was DELETED"

# ── Case 4b: same byte count, different content is NOT caught (documented) ──
echo "[selftest] case 4b — equal size, different bytes (known limit)"
L="$ROOT/c4b/local"; A="$ROOT/c4b/archive"
make_unit "$L/setA/silent" 1
"$ARCHIVE_SH" copy "$L" "$A" >/dev/null 2>&1
# Same length, different content. The check compares counts and sizes, so this
# passes by design; the script's header says so rather than implying a hash.
# Length-preserving mutation: tr is a byte-for-byte substitution, so the file
# keeps its exact size and only its content differs.
tr 'a-z' 'A-Z' < "$A/setA/silent/file1.dat" > "$A/setA/silent/file1.tmp"
mv "$A/setA/silent/file1.tmp" "$A/setA/silent/file1.dat"
"$ARCHIVE_SH" verify "$L" "$A" >/dev/null 2>&1 \
  && ok "case 4b: content drift passes (documented limit, not a hash check)" \
  || bad "case 4b: unexpected — verify caught content drift"

# ── Case 5: empty archive root ──────────────────────────────────────────────
echo "[selftest] case 5 — empty archive root"
L="$ROOT/c5/local"; A="$ROOT/c5/archive"
make_unit "$L/setA/unit1" 2
mkdir -p "$A"
"$ARCHIVE_SH" clean "$L" "$A" >/dev/null 2>&1 && bad "case 5: clean ran against an empty archive" \
                                             || ok "case 5: clean REFUSES an empty archive"
[ -d "$L/setA/unit1" ] && ok "case 5: local units untouched" \
                       || bad "case 5: local units were deleted"

# ── Case 6: archive root absent ─────────────────────────────────────────────
echo "[selftest] case 6 — archive root absent"
L="$ROOT/c6/local"; A="$ROOT/c6/nonexistent"
make_unit "$L/setA/unit1" 2
"$ARCHIVE_SH" clean "$L" "$A" >/dev/null 2>&1 && bad "case 6: clean ran with no archive root" \
                                             || ok "case 6: clean REFUSES an absent archive"
[ -d "$L/setA/unit1" ] && ok "case 6: local units untouched" \
                       || bad "case 6: local units were deleted"

echo
echo "[selftest] $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
