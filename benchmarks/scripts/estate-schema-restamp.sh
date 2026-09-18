#!/usr/bin/env bash
# estate-schema-restamp.sh — correct the estate schema stamp on artifacts whose
# LAYOUT is already 1.1 while their manifest still says 1.0.
#
#   probe   <estate-dir>          classify one estate, print the verdict
#   restamp <root> [--dry-run]    walk a tree, restamp what qualifies
#
# WHY THIS EXISTS. `schema_version` was set to "1.0" on 2026-05-28 at v1.0
# ratification and never moved. The estate layout did: the shared-content
# cutover replaced the legacy `chunks` copy lane, and the 2026-08-15 shadow-
# generation swap added vector generations. Estates built today are 1.1 in
# every respect except the string that names them. This is a labelling
# correction, not a migration — no data is converted, and an estate that
# genuinely needs converting is refused rather than relabelled.
#
# THE PROBE IS STRUCTURAL, mirroring SharedContentMigrationDetection:
#
#   chunks table present            -> LEGACY. Refuse: it needs the real
#                                     migration, and relabelling it would hide
#                                     that it never ran.
#   chunks absent, CorpusKit ver 0  -> FRESH (1.1 layout). Restamp when the
#                                     manifest reads 1.0.
#   chunks absent, CorpusKit ver >0 -> CORRUPT. Refuse: the product treats an
#                                     unreadable table at a registered version
#                                     as corruption, and so does this.
#
# WHAT IT WRITES, per qualifying estate:
#   estate.sqlite  manifest row  schema_version : 1.0 -> 1.1
#   artifact.json  estate_schema_version        : 1.0 -> 1.1   (when present)
#
# Both are idempotent. An estate already at 1.1 is reported and skipped.

set -uo pipefail

TARGET_VERSION="1.1"
FROM_VERSION="1.0"

usage() {
  echo "usage: estate-schema-restamp.sh probe <estate-dir>" >&2
  echo "       estate-schema-restamp.sh restamp <root> [--dry-run]" >&2
  exit 2
}

# ── probe_estate <estate.sqlite> -> prints one verdict word ─────────────────
#   fresh-1.0     layout is 1.1, manifest says 1.0   -> restamp
#   fresh-1.1     layout is 1.1, manifest says 1.1   -> nothing to do
#   fresh-other   layout is 1.1, manifest says something else -> refuse
#   legacy        chunks lane present                -> refuse
#   corrupt       chunks absent at a registered CorpusKit version -> refuse
#   unreadable    not an openable database           -> refuse
probe_estate() {
  local db="$1"
  [ -f "$db" ] || { echo "unreadable"; return; }

  local manifest
  manifest=$(sqlite3 -cmd '.timeout 5000' "$db" \
             "select value from manifest where key='schema_version';" 2>/dev/null)
  if [ -z "$manifest" ]; then echo "unreadable"; return; fi

  local has_chunks
  has_chunks=$(sqlite3 -cmd '.timeout 5000' "$db" \
               "select count(*) from sqlite_master where type='table' and name='chunks';" 2>/dev/null)
  if [ "${has_chunks:-0}" != "0" ]; then echo "legacy"; return; fi

  # The legacy copy lane is gone. A registered CorpusKit migration version with
  # no chunks table is the corruption case the product refuses to reclassify.
  local corpus_version
  corpus_version=$(sqlite3 -cmd '.timeout 5000' "$db" \
                   "select version from _storagekit_migrations where kit_id='CorpusKit';" 2>/dev/null)
  if [ -n "$corpus_version" ] && [ "$corpus_version" != "0" ]; then echo "corrupt"; return; fi

  case "$manifest" in
    "$FROM_VERSION")   echo "fresh-1.0" ;;
    "$TARGET_VERSION") echo "fresh-1.1" ;;
    *)                 echo "fresh-other:$manifest" ;;
  esac
}

# ── restamp_estate <estate-dir> <dry-run 0|1> -> 0 restamped, 1 skipped ─────
restamp_estate() {
  local dir="$1" dry="$2"
  local db="$dir/estate.sqlite"
  local verdict; verdict=$(probe_estate "$db")

  case "$verdict" in
    fresh-1.0)
      if [ "$dry" = "1" ]; then echo "  would restamp  $dir"; return 0; fi
      sqlite3 -cmd '.timeout 10000' "$db" \
        "update manifest set value='$TARGET_VERSION' where key='schema_version';" 2>/dev/null || {
          echo "  WRITE FAILED   $dir"; return 1; }
      # The artifact manifest beside the estate, when this is a cached artifact.
      local aj="$dir/../artifact.json"
      if [ -f "$aj" ]; then
        python3 - "$aj" "$TARGET_VERSION" <<'PY' || { echo "  ARTIFACT JSON FAILED $aj"; return 1; }
import json, sys
path, target = sys.argv[1], sys.argv[2]
with open(path) as f: d = json.load(f)
d["estate_schema_version"] = target
with open(path, "w") as f: json.dump(d, f, indent=2, sort_keys=True); f.write("\n")
PY
      fi
      echo "  restamped      $dir"
      return 0 ;;
    fresh-1.1)  echo "  already 1.1    $dir"; return 1 ;;
    legacy)     echo "  REFUSED legacy layout (needs the real migration): $dir"; return 1 ;;
    corrupt)    echo "  REFUSED corrupt (chunks absent at a registered CorpusKit version): $dir"; return 1 ;;
    unreadable) echo "  REFUSED unreadable database: $dir"; return 1 ;;
    *)          echo "  REFUSED unexpected manifest version ($verdict): $dir"; return 1 ;;
  esac
}

[ $# -ge 2 ] || usage
CMD="$1"; ROOT="${2%/}"
DRY=0; [ "${3:-}" = "--dry-run" ] && DRY=1

case "$CMD" in

  probe)
    probe_estate "$ROOT/estate.sqlite"
    ;;

  restamp)
    [ -d "$ROOT" ] || { echo "[restamp] FATAL: no such root: $ROOT" >&2; exit 1; }
    [ "$DRY" = "1" ] && echo "[restamp] DRY RUN — nothing is written"
    echo "[restamp] walking $ROOT"
    done_n=0; skip_n=0
    # Every directory holding an estate.sqlite is one estate, at any depth: the
    # artifact layout nests it under <set>/<unit>/estate/, the landscape cache
    # under <entry>/, and a bare estate directory is itself the target.
    while IFS= read -r db; do
      dir=$(dirname "$db")
      if restamp_estate "$dir" "$DRY"; then done_n=$((done_n + 1)); else skip_n=$((skip_n + 1)); fi
    done < <(find "$ROOT" -name estate.sqlite -type f | sort)
    echo "[restamp] $done_n restamped, $skip_n skipped"
    ;;

  *) usage ;;
esac
