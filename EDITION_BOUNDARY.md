---
title: Edition Boundary Manifest
version: 1.0.0
status: active
date: 2026-06-15
description: The authoritative path-class manifest separating the Community Edition (CE) subset from the Enterprise Edition (EE) superset.
---

# Edition Boundary Manifest

This file is the **authoritative enumeration** of which paths belong to which
edition. It is present in both editions and is read by the EE→CE sync tooling and
by CI. Rationale and the branch/version flow model live in
[`docs/decisions/ADR-009-edition-boundary.md`](docs/decisions/ADR-009-edition-boundary.md);
the editions themselves are described in [`EDITIONS.md`](EDITIONS.md).

Every path is exactly one of three classes:

- **SHARED** — byte-identical in both editions; the only thing that flows between
  EE and CE (features EE→CE, bug fixes CE→EE by cherry-pick). **Invariant: SHARED
  code may never reference an EE-only path.**
- **EDITION-SURFACE** — present in both editions, but each owns its copy; never
  flows.
- **EE-ONLY** — never published to CE.

**SHARED is defined by exclusion:** any tracked path that is not matched by an
EE-ONLY or EDITION-SURFACE entry below is SHARED.

The lists below are newline-delimited path globs (gitignore-style, relative to the
repo root). A leading `#` is a comment.

## EE-ONLY — never in CE

```edition-ee-only
# Consolidated maintainer trees (see ADR-009 §"ee-edition consolidation").
# Until the consolidation lands these live at the repo root; this manifest is
# updated in the same commit that moves them under ee-edition/.
ee-edition/
tools/
port/
docs_internal/
scripts/

# Root-required agent files — Claude Code requires these at the repo root, so
# they cannot move under ee-edition/. They are the only root-level EE-only
# exceptions besides the consolidated tree.
.claude/
CLAUDE.md
docs/AGENTS.md
docs/CLAUDE.md
```

## EDITION-SURFACE — present in both, each edition owns its copy (never flows)

```edition-surface
README.md
Makefile
.gitignore
install.sh
install-local.sh
.github/workflows/
CHANGELOG.md
VERSIONING.md
```

## SHARED — everything else (byte-identical across editions)

Defined by exclusion (everything not listed above). For orientation, the SHARED
core is:

```edition-shared-orientation
packages/
apps/                 # includes apps/moot-bridge (SHARED, source-only — see ADR-009)
examples/
docs/                 # except docs/AGENTS.md and docs/CLAUDE.md (EE-only, above)
```

## Notes

- **`apps/moot-bridge`** is SHARED but **source-only**: it ships to CE as
  documented source and is excluded from installers and release assets (the
  Makefile `release` target and `.github/workflows/release.yml` build only
  `mootx01` + `moot-mgr`).
- **The self-containment invariant** is checked by grepping SHARED paths for
  *repo-internal* EE-only references — `tools/` / `port/` used as filesystem
  paths, `docs_internal/`, and `.claude/rules/` specifically (not bare `.claude`,
  which legitimately appears as `~/.claude/settings.json` user config). It must
  return empty.
