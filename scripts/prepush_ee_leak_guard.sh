#!/bin/sh
# prepush_ee_leak_guard.sh — refuse to push while any EE-only path is tracked.
#
# The EE→CE port lane cherry-picks commits from the private EE repository.
# A mixed commit (SHARED + EE-only paths) would create private tooling in
# this public repository; this guard is the unconditional every-push
# backstop behind the split-commit discipline enforced on the EE side.
#
# The path list mirrors the [ee-only] section of EE's edition-boundary
# manifest, minus `scripts` — CE owns its own scripts/ directory (an
# edition-surface path, not a leak). Update both together.
#
# Invoked from .githooks/pre-push. Checks the index (tracked files only);
# untracked local noise is not a publication risk.

EE_ONLY_RE='^(ee-edition|tools|port|docs_internal|\.claude|CLAUDE\.md|CLAUDE-EE\.md|CLAUDE-CE\.md|docs/AGENTS\.md|docs/CLAUDE\.md|\.worktreeinclude|codex-code-comment-audit\.md|EDITION_BOUNDARY\.md|docs/archive|docs/missions|docs/findings|apps/moot-math-benchmark/HINTS-GO\.md|apps/moot-math-benchmark/HINTS-PYTHON\.md)(/|$)'

leak=$(git ls-files | grep -E "$EE_ONLY_RE")
if [ -n "$leak" ]; then
    echo "PUSH BLOCKED: EE-only paths are tracked in this public repository:" >&2
    echo "$leak" | sed 's/^/    /' >&2
    echo "An EE→CE port picked a mixed commit. Split the source commit on the EE side (shared-only / EE-only) and re-port the shared half." >&2
    exit 1
fi
exit 0
