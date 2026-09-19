#!/usr/bin/env bash
# estate-schema-restamp-selftest.sh — proves estate-schema-restamp.sh against
# synthetic databases under a temporary root. Touches no real estate.
#
# The cases:
#   1. fresh layout, manifest 1.0  -> restamped to 1.1, artifact.json too
#   2. fresh layout, manifest 1.1  -> skipped, nothing rewritten
#   3. legacy layout (chunks)      -> REFUSED, manifest untouched
#   4. chunks absent, CorpusKit v13 -> REFUSED as corrupt, manifest untouched
#   5. manifest reads something else -> REFUSED
#   6. --dry-run                    -> reports, writes nothing
#   7. running twice                -> idempotent, second pass is all skips
#
# Cases 3 to 5 matter most. Relabelling an estate that actually needs the
# migration would hide that it never ran, which is worse than leaving a stale
# label in place.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH="$HERE/estate-schema-restamp.sh"
[ -x "$SH" ] || chmod +x "$SH"

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/restamp-selftest.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

pass=0; fail=0
ok()  { echo "  PASS  $*"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $*"; fail=$((fail + 1)); }

# make_estate <unit-dir> <manifest-version> <with-chunks 0|1> <corpuskit-version|"">
#
# Builds <unit-dir>/artifact.json and <unit-dir>/estate/estate.sqlite carrying
# the manifest and migration tables the probe reads. The shared-content tables
# stand in for the post-cutover layout.
make_estate() {
  local unit="$1" version="$2" chunks="$3" corpus_ver="$4"
  mkdir -p "$unit/estate"
  printf '{\n  "benchmark": "selftest",\n  "estate_schema_version": "%s"\n}\n' "$version" > "$unit/artifact.json"
  local db="$unit/estate/estate.sqlite"
  sqlite3 "$db" "
    create table manifest (key text primary key not null, value text not null);
    insert into manifest values ('manifest_version','1.0');
    insert into manifest values ('schema_version','$version');
    create table _storagekit_migrations (kit_id text primary key not null, version integer not null, applied_at text not null);
    insert into _storagekit_migrations values ('LocusKit', 14, '2026-08-16T00:00:00Z');
    create table node_bundles (id text primary key not null);
    create table vector_generations (id text primary key not null);
  " 2>/dev/null
  [ "$chunks" = "1" ] && sqlite3 "$db" "create table chunks (id text primary key not null);" 2>/dev/null
  [ -n "$corpus_ver" ] && sqlite3 "$db" \
    "insert into _storagekit_migrations values ('CorpusKit', $corpus_ver, '2026-08-16T00:00:00Z');" 2>/dev/null
  return 0
}

stamp_of() { sqlite3 "$1/estate/estate.sqlite" "select value from manifest where key='schema_version';" 2>/dev/null; }
json_stamp_of() { python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['estate_schema_version'])" "$1/artifact.json" 2>/dev/null; }

# ── Build the tree ──────────────────────────────────────────────────────────
L="$ROOT/tree"
make_estate "$L/setA/fresh10"  "1.0" 0 ""
make_estate "$L/setA/fresh11"  "1.1" 0 ""
make_estate "$L/setA/legacy"   "1.0" 1 ""
make_estate "$L/setA/corrupt"  "1.0" 0 "13"
make_estate "$L/setA/oddver"   "0.9" 0 ""

# ── Probe verdicts ──────────────────────────────────────────────────────────
echo "[selftest] probe verdicts"
[ "$("$SH" probe "$L/setA/fresh10/estate")" = "fresh-1.0" ] && ok "probe: fresh 1.0" || bad "probe: fresh 1.0"
[ "$("$SH" probe "$L/setA/fresh11/estate")" = "fresh-1.1" ] && ok "probe: fresh 1.1" || bad "probe: fresh 1.1"
[ "$("$SH" probe "$L/setA/legacy/estate")"  = "legacy" ]    && ok "probe: legacy layout" || bad "probe: legacy layout"
[ "$("$SH" probe "$L/setA/corrupt/estate")" = "corrupt" ]   && ok "probe: corrupt" || bad "probe: corrupt"

# ── Case 6 first: dry run writes nothing ────────────────────────────────────
echo "[selftest] dry run"
"$SH" restamp "$L" --dry-run >/dev/null 2>&1
[ "$(stamp_of "$L/setA/fresh10")" = "1.0" ] && ok "dry run: nothing written" || bad "dry run: it wrote"

# ── The real pass ───────────────────────────────────────────────────────────
echo "[selftest] restamp pass"
"$SH" restamp "$L" >/dev/null 2>&1
[ "$(stamp_of "$L/setA/fresh10")" = "1.1" ]      && ok "fresh 1.0 -> 1.1 in the manifest" || bad "fresh 1.0 was not restamped"
[ "$(json_stamp_of "$L/setA/fresh10")" = "1.1" ] && ok "artifact.json restamped too" || bad "artifact.json not restamped"
[ "$(stamp_of "$L/setA/fresh11")" = "1.1" ]      && ok "already-1.1 estate unchanged" || bad "already-1.1 estate was altered"
[ "$(stamp_of "$L/setA/legacy")"  = "1.0" ]      && ok "legacy REFUSED, stamp untouched" || bad "legacy estate was relabelled"
[ "$(json_stamp_of "$L/setA/legacy")" = "1.0" ]  && ok "legacy artifact.json untouched" || bad "legacy artifact.json was rewritten"
[ "$(stamp_of "$L/setA/corrupt")" = "1.0" ]      && ok "corrupt REFUSED, stamp untouched" || bad "corrupt estate was relabelled"
[ "$(stamp_of "$L/setA/oddver")"  = "0.9" ]      && ok "unexpected version REFUSED" || bad "unexpected version was overwritten"

# ── Idempotence ─────────────────────────────────────────────────────────────
echo "[selftest] second pass"
out=$("$SH" restamp "$L" 2>&1)
echo "$out" | grep -q "1 restamped" && bad "second pass restamped again" || ok "second pass restamps nothing"
[ "$(stamp_of "$L/setA/fresh10")" = "1.1" ] && ok "stamp stable across passes" || bad "stamp changed on a second pass"

echo
echo "[selftest] $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
