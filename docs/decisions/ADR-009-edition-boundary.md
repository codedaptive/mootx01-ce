---
status: decided
question: How do the Enterprise (EE) and Community (CE) editions share one codebase without drifting, and how do features and bug fixes flow between them?
authors: MOOTx01 maintainers
date: 2026-06-15
relates_to:
  - docs/decisions/ADR-005-mootx01-app-envelope-and-parity-boundary.md
  - EDITION_BOUNDARY.md
supersedes: none
context:
  - CE (codedaptive/mootx01-ce) is the public open-core subset; EE is the private superset and source of truth.
  - The two were a forked, diverged history; CE was just re-published as a faithful file-level mirror of EE shared source at 1.0.0-beta.
  - We are splitting maintenance into two version lines (EE = v1.x.0 features, CE = v1.0.x fixes) and need a boundary that stays clean.
---

# ADR-009 — Edition boundary: shared core, edition surface, EE-only

## Context

MOOTx01 ships in two editions (see `EDITIONS.md`): the open-core **Community
Edition (CE)** and the superset **Enterprise Edition (EE)**. EE is the source of
truth; CE is published from it. After the 1.0.0-beta re-publish, CE's shared
source is byte-identical to EE's — but nothing *guarantees* it stays that way,
the boundary lives only as a hardcoded path list in a migration script, and a
handful of shared files reference EE-only paths (so CE cannot build/test itself
standalone).

We are also splitting the version lines:

- **EE branch (`build`/`develop`) = v1.x.0** — new features bump the **minor**.
- **CE branch (`main`) = v1.0.x** — bug fixes bump the **patch**, cut from the
  published 1.0 baseline (not from EE HEAD, which already carries unreleased
  features — cutting a patch from EE HEAD would drag them in).

For that split to be maintainable, the boundary must be **declared, checkable,
and free of shared→EE-only coupling**.

## Decision

### 1. Every path is exactly one of three classes

1. **SHARED** — byte-identical in both editions; the *only* thing that flows
   between them. `packages/**`, `apps/**` (except `apps/moot-bridge` — see note),
   `examples/**`, `docs/**` (except `docs/AGENTS.md` / `docs/CLAUDE.md`).
2. **EDITION-SURFACE** — present in both, but each edition owns its copy and it
   **never flows**: root `README.md`, root `Makefile`, `.gitignore`,
   `install.sh`, `install-local.sh`, `.github/workflows/*`, `CHANGELOG.md`,
   `VERSIONING.md`.
3. **EE-ONLY** — never in CE: `ee-edition/**` (the consolidated maintainer
   trees — `tools/`, `port/`, `docs_internal/`, `scripts/`), plus the
   root-required agent files `.claude/` and `CLAUDE.md` (Claude Code requires
   these at the repo root; they cannot be relocated) and `docs/AGENTS.md`.

The authoritative enumeration lives in **`EDITION_BOUNDARY.md`** (repo root,
present in both editions). This ADR is the rationale; that file is the contract a
sync script and CI read.

### 2. The core invariant

**SHARED code may never reference an EE-only path.** A shared kit that reads a
fixture from `tools/`, a shared Makefile target that shells into `tools/`, or a
shared comment that cites `docs_internal/...` or `.claude/rules/...` breaks CE's
ability to build, test, and gate itself standalone. Such references are bugs and
are removed (vendor the fixture into the kit, move the rule to public `docs/`,
etc.).

### 3. Flow model

```
EE build/develop ──(features, v1.1.0 …)──► source of truth, superset
      ▲  │
 backport│  │ feature-sync (EE→CE, SHARED paths only, each public drop)
(cherry- │  ▼
 pick)   │  CE main ──(bug fixes, v1.0.1 …)──► published 1.0 line
```

- **Features**: authored on EE only, minor bump; published to CE by re-running
  the per-package content-replace for SHARED paths only.
- **Bug fixes**: authored on **CE `main`** (v1.0.x patch). Because the fixed file
  is SHARED (byte-identical), the same commit cherry-picks cleanly back into EE
  `build`, so the next feature-sync does not reintroduce the bug. A CE bug-fix
  commit must touch **only SHARED paths**; any edition-surface part is hand-applied
  to EE, not cherry-picked.

The model only works while SHARED stays byte-identical — enforced by the
shared-drift check (`diff -rq` of SHARED paths) and a CI self-containment check.

### Note on `apps/moot-bridge`

moot-bridge (a transport-level MCP memory multiplexer) is reclassified from
EE-only to **SHARED, source-only**: it builds on CE packages with zero external
dependencies and ships to CE as documented source, but stays out of the
installers and release assets (the `release` target and `release.yml` build only
`mootx01` + `moot-mgr`). Advanced users compile it from its README; average users
never see it.

## Consequences

- The boundary is declared once (`EDITION_BOUNDARY.md`) and checkable in CI, not
  implicit in a script.
- CE is self-contained: it builds, tests, and runs its quality gates with no
  EE-only path present.
- Movable EE-only trees consolidate under `ee-edition/` so the boundary is visible
  in the tree; `.claude/`, `CLAUDE.md`, and `docs/AGENTS.md` remain the only
  root-level EE-only exceptions.
- A trivial change to a SHARED file can be proven to cherry-pick cleanly in both
  directions — the operational test that the boundary is healthy.

## Open questions

- None blocking. The `ee-edition/` consolidation and the per-mission fixes that
  remove the existing shared→EE-only couplings are tracked separately.

## Update — 2026-06-15: branch names superseded

The branch names used above (under "splitting the version lines" and in the flow
diagram) are superseded. The repository now follows the `VERSIONING.md` §2.1
branch scheme:

- **CE** uses `stable/1.0.x` — the default, permanent 1.0 line, where release
  tags land — and `develop/1.0.x` for active development. The former CE `main`
  branch has been retired.
- **EE** uses `develop`. The former `build` branch has been retired.

The version-line **decision is unchanged**: CE patches (v1.0.x) are cut from the
published baseline, EE minors (v1.x.0) carry features. Only the branch *names*
changed. See `VERSIONING.md` for the authoritative branch and tag conventions.
