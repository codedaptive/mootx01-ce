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
# edition-surface path, not a leak). That single omission is the only allowed
# difference, and EE's scripts/repo_sync/check-boundary-drift.py asserts it:
# any other divergence between this regex, EDITION_BOUNDARY.md, and
# edition-boundary.conf fails `make check-edition-boundary` on the EE side.
# The three lists drifted silently before that check existed (docs/analysis and
# docs/status were added to the conf on 2026-08-03 and reached neither the
# manifest nor this regex until 2026-08-04).
#
# Invoked from .githooks/pre-push. Checks the index (tracked files only);
# untracked local noise is not a publication risk.

EE_ONLY_RE='^(ee-edition|tools|port|docs_internal|\.claude|\.agents|\.codex|CLAUDE\.md|CLAUDE-EE\.md|CLAUDE-CE\.md|docs/AGENTS\.md|docs/CLAUDE\.md|\.worktreeinclude|codex-code-comment-audit\.md|EDITION_BOUNDARY\.md|docs/archive|docs/missions|docs/findings|docs/analysis|docs/status|apps/moot-math-benchmark/HINTS-GO\.md|apps/moot-math-benchmark/HINTS-PYTHON\.md|benchmark-ee|benchmark)(/|$)'

leak=$(git ls-files | grep -E "$EE_ONLY_RE")
if [ -n "$leak" ]; then
    echo "PUSH BLOCKED: EE-only paths are tracked in this public repository:" >&2
    echo "$leak" | sed 's/^/    /' >&2
    echo "An EE→CE port picked a mixed commit. Split the source commit on the EE side (shared-only / EE-only) and re-port the shared half." >&2
    exit 1
fi

# ── Gate 2: root dot entries are ALLOWLISTED, not blocklisted ───────────────
#
# Gate 1 enumerates known EE-only paths. That is only as good as the list, and on
# 2026-08-05 the list was not good enough: `git add -A` during a release bump
# swept 92 files from .agents/ and .codex/ into this public repository, and this
# guard reported CLEAN because it named .claude and neither sibling. The content
# reached a pushed tag before anyone noticed.
#
# Enumerating what is forbidden cannot catch the next unnamed directory. So this
# gate inverts it: CE tracks exactly five root dot entries, and ANY other one is
# blocked on sight. A new agent tool, editor config, or cache directory is
# refused by default and has to be added here deliberately.
#
# Keep this list minimal. Every addition is a decision to publish something.
ALLOWED_ROOT_DOT='^\.(cargo|gitattributes|githooks|github|gitignore)($|/)'

unknown=$(git ls-files | grep -E '^\.' | grep -Ev "$ALLOWED_ROOT_DOT" | sed 's|/.*||' | sort -u)
if [ -n "$unknown" ]; then
    echo "PUSH BLOCKED: unexpected root dot entr(ies) tracked in this public repository:" >&2
    echo "$unknown" | sed 's/^/    /' >&2
    echo "CE tracks only: .cargo .gitattributes .githooks .github .gitignore" >&2
    echo "Anything else is refused by default. If it genuinely belongs in the public" >&2
    echo "repository, add it to ALLOWED_ROOT_DOT in this script deliberately; if it was" >&2
    echo "swept in by 'git add -A', untrack it." >&2
    exit 1
fi

# docs_internal must remain a SYMLINK into the EE checkout (the June
# leak-incident guard): writes aimed at it land in EE instead of creating a
# real internal-docs directory in this public repo. Git does not follow a
# symlink standing where a tracked path lives — a cherry-pick carrying
# docs_internal/ REPLACES the link with a real directory (observed
# 2026-07-30 porting the MXE-BB merge). Nothing was committed that time
# because .gitignore caught it, but the guard was silently gone.
top=$(git rev-parse --show-toplevel)
if [ -e "$top/docs_internal" ] && [ ! -L "$top/docs_internal" ]; then
    echo "PUSH BLOCKED: docs_internal is a real directory, not the guard symlink." >&2
    echo "    A port likely clobbered it. Restore with:" >&2
    echo "    rm -rf \"$top/docs_internal\" && ln -sfn ../mootx01-ee-develop_1.1.x/docs_internal \"$top/docs_internal\"" >&2
    exit 1
fi
exit 0
