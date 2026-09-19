#!/usr/bin/env bash
# artifact-archive.sh — copy artifacts to the archive, and remove local copies
# ONLY where a verified archive copy exists.
#
# Three subcommands, deliberately separate so no single command both copies and
# deletes:
#
#   copy   <local-root> <archive-root>   rsync every unit local -> archive
#   verify <local-root> <archive-root>   compare unit by unit, report, exit 1 on any mismatch
#   clean  <local-root> <archive-root>   delete a local unit ONLY when its archive copy verifies
#
# A "unit" is one directory two levels below the root: <root>/<set>/<unit>.
# That is the artifact layout the estate cache uses (set name, then question or
# conversation id). A root whose entries are one level deep (the landscape
# cache) is handled too: units are then <root>/<entry>.
#
# WHAT VERIFICATION MEANS HERE. For each unit the check compares the number of
# regular files and the total byte count, local against archive. It does not
# hash 542 GB of estate databases: that would take longer than rebuilding them.
# rsync already verifies each file's contents during transfer, so the residual
# risk this check covers is a truncated or interrupted copy, which is exactly
# what a count-and-size comparison catches. A silently corrupted byte inside an
# otherwise complete file is NOT covered, and is not claimed to be.
#
# The clean subcommand refuses to delete anything when the archive root is
# absent or empty, and skips (never deletes) any unit that fails verification.
# It reports what it skipped and exits nonzero, so a partial archive can never
# read as a completed one.

set -uo pipefail

usage() {
  echo "usage: artifact-archive.sh {copy|verify|clean} <local-root> <archive-root>" >&2
  exit 2
}

[ $# -eq 3 ] || usage
CMD="$1"; LOCAL="${2%/}"; ARCHIVE="${3%/}"

[ -d "$LOCAL" ] || { echo "[archive] FATAL: no local root: $LOCAL" >&2; exit 1; }

# ── unit enumeration ────────────────────────────────────────────────────────
# Units are <set>/<unit> when the root holds set directories that themselves
# hold unit directories, and <entry> when the root's entries are the artifacts
# (the landscape cache). Detected per set rather than assumed, so one script
# serves both trees.
units() {
  local root="$1" set_dir unit_dir
  for set_dir in "$root"/*/; do
    [ -d "$set_dir" ] || continue
    local set_name; set_name=$(basename "$set_dir")
    local has_sub=0
    for unit_dir in "$set_dir"*/; do
      [ -d "$unit_dir" ] || continue
      has_sub=1
      echo "$set_name/$(basename "$unit_dir")"
    done
    # A set directory with no subdirectories IS the unit (landscape cache).
    [ "$has_sub" -eq 0 ] && echo "$set_name"
  done
}

# file count and total bytes for one directory.
#
# One `stat` per FILE is what the first version did, and it made a verify over
# 19,514 units unusably slow — the process spawns dominate, not the I/O. This
# batches through xargs, so a unit of any size costs a handful of processes.
# Apparent size (%z), never disk usage: the local copy sits on APFS with
# cloned blocks and the archive does not, so block counts legitimately differ
# for identical content while apparent size does not.
measure() {
  local dir="$1"
  if [ ! -d "$dir" ]; then echo "0 0"; return; fi
  local count bytes
  count=$(find "$dir" -type f | wc -l | tr -d ' ')
  bytes=$(find "$dir" -type f -print0 2>/dev/null \
          | xargs -0 stat -f '%z' 2>/dev/null \
          | awk '{s+=$1} END {print s+0}')
  echo "$count $bytes"
}

# verify_unit <unit> -> 0 when the archive copy matches, 1 otherwise
verify_unit() {
  local unit="$1"
  local l a
  l=$(measure "$LOCAL/$unit")
  a=$(measure "$ARCHIVE/$unit")
  if [ ! -d "$ARCHIVE/$unit" ]; then
    echo "  MISSING   $unit (no archive copy)"
    return 1
  fi
  if [ "$l" != "$a" ]; then
    echo "  MISMATCH  $unit (local: $l files/bytes, archive: $a)"
    return 1
  fi
  echo "  ok        $unit ($l files/bytes)"
  return 0
}

case "$CMD" in

  copy)
    [ -d "$ARCHIVE" ] || mkdir -p "$ARCHIVE" || {
      echo "[archive] FATAL: cannot create archive root: $ARCHIVE" >&2; exit 1; }
    echo "[archive] copying $LOCAL -> $ARCHIVE"
    # -a preserves everything; no --delete, so the archive is only ever added
    # to by this script. Copy, never move: the local copy is removed by the
    # clean subcommand and only after verification.
    rsync -a "$LOCAL"/ "$ARCHIVE"/ || {
      echo "[archive] FATAL: rsync failed" >&2; exit 1; }
    echo "[archive] copy complete"
    ;;

  verify)
    echo "[archive] verifying $LOCAL against $ARCHIVE"
    fails=0; total=0
    while read -r unit; do
      [ -z "$unit" ] && continue
      total=$((total + 1))
      verify_unit "$unit" || fails=$((fails + 1))
    done < <(units "$LOCAL")
    echo "[archive] $((total - fails))/$total units verified"
    [ "$fails" -eq 0 ] || { echo "[archive] $fails unit(s) NOT safe to remove"; exit 1; }
    ;;

  clean)
    # Refuse outright on an absent or empty archive: removing local artifacts
    # with nothing on the other side is the one outcome this script exists to
    # prevent.
    [ -d "$ARCHIVE" ] || { echo "[archive] REFUSING: no archive root at $ARCHIVE" >&2; exit 1; }
    if [ -z "$(ls -A "$ARCHIVE" 2>/dev/null)" ]; then
      echo "[archive] REFUSING: archive root is empty: $ARCHIVE" >&2; exit 1
    fi
    echo "[archive] removing local units that verify against $ARCHIVE"
    removed=0; skipped=0
    while read -r unit; do
      [ -z "$unit" ] && continue
      if verify_unit "$unit" >/dev/null 2>&1; then
        rm -rf "${LOCAL:?}/$unit" && removed=$((removed + 1))
        echo "  removed   $unit"
      else
        skipped=$((skipped + 1))
        verify_unit "$unit"          # print WHY it was skipped
        echo "  KEPT      $unit"
      fi
    done < <(units "$LOCAL")
    echo "[archive] removed $removed unit(s), kept $skipped"
    [ "$skipped" -eq 0 ] || exit 1
    ;;

  *) usage ;;
esac
