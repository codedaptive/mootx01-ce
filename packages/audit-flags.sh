#!/usr/bin/env bash
#
# Finder color-flag helper for security-audit triage.
#
#   flag    Red    = files ADDED on this branch vs develop (new code)
#           Orange = files CHANGED on this branch vs develop
#   clear   remove the labels set by a previous `flag` run
#
# Labels are classic Finder color labels stored in each file's
# com.apple.FinderInfo extended attribute. They are LOCAL ONLY — xattrs
# are not preserved by `zip` or by git, so these flags exist purely for
# visual triage in Finder on this machine. This is intentional (see the
# plan: local Finder triage was the chosen scope).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$HERE/.audit-flagged"

# AppleScript Finder "label index" values. Verified empirically on
# macOS 26 by reading back kMDItemFSLabel: label index 2 -> FSLabel 6
# (Red), label index 1 -> FSLabel 7 (Orange). NOTE: the AppleScript
# index order is the REVERSE of the raw FSLabel color numbers, so do
# NOT substitute 6/7 here — that would color files green/gray instead.
RED=2
ORANGE=1
NONE=0

# Set a single file's Finder label. $1 = absolute path, $2 = label index.
set_label() {
    osascript \
        -e 'on run {p, n}' \
        -e 'tell application "Finder" to set label index of (POSIX file p as alias) to (n as integer)' \
        -e 'end run' \
        -- "$1" "$2" >/dev/null
}

cmd_flag() {
    local base
    # merge-base, not the develop tip: we want only what THIS branch
    # introduced, unaffected by commits that landed on develop since.
    base="$(git merge-base develop HEAD)"

    : > "$MANIFEST"
    local count=0 status path rest color rel abs

    # --relative yields paths relative to packages/ (we run git in HERE);
    # -M detects renames so a rename is one R entry, not add+delete.
    while IFS=$'\t' read -r status path rest; do
        case "$status" in
            A)   color=$RED;    rel="$path" ;;   # added  -> new
            M)   color=$ORANGE; rel="$path" ;;   # modified -> changed
            R*)  color=$ORANGE; rel="$rest" ;;   # renamed: new path in $rest
            C*)  color=$ORANGE; rel="$rest" ;;   # copied:  new path in $rest
            D)   continue ;;                     # deleted: no file to color
            *)   continue ;;
        esac
        abs="$HERE/$rel"
        [ -f "$abs" ] || continue
        set_label "$abs" "$color"
        printf '%s\n' "$abs" >> "$MANIFEST"
        if [ "$color" = "$RED" ]; then echo "RED    $rel"; else echo "ORANGE $rel"; fi
        count=$((count + 1))
    done < <(cd "$HERE" && git diff --name-status --relative -M "$base" -- .)

    echo "Flagged $count file(s). Manifest: $MANIFEST"
}

cmd_clear() {
    if [ ! -f "$MANIFEST" ]; then
        echo "No manifest ($MANIFEST); nothing to clear."
        return 0
    fi
    local count=0 abs
    while IFS= read -r abs; do
        [ -n "$abs" ] || continue
        [ -e "$abs" ] || continue
        set_label "$abs" "$NONE"
        count=$((count + 1))
    done < "$MANIFEST"
    rm -f "$MANIFEST"
    echo "Cleared $count file(s); removed manifest."
}

case "${1:-}" in
    flag)  cmd_flag ;;
    clear) cmd_clear ;;
    *) echo "usage: $(basename "$0") {flag|clear}" >&2; exit 2 ;;
esac
