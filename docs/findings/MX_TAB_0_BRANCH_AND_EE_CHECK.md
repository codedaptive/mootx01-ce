---
title: MX-TAB-0 — Forward-merge cadence check and EE shared-file divergence check
version: v0.1
status: complete
date: 2026-07-11
relates_to:
  - docs/missions/drafts/MX_TABULAR_SPEC.md
---

# MX-TAB-0 — Forward-merge and EE divergence findings

Mission MX-TAB-0 of the MX-TABULAR set: wire the develop/1.0.x →
develop/1.1.x forward-merge cadence, run the EE shared-file divergence
check, record findings. The branch cut itself predates this mission.

## Forward-merge state (develop/1.0.x → develop/1.1.x)

`git log origin/develop/1.0.x ^origin/develop/1.1.x` returns **zero
commits** as of 2026-07-11. Every fix on the bug line is already merged
forward; develop/1.1.x sits on current fixes. The standing cadence
(merge forward per fix, plus before every mission branch cut) is
restated in the spec's "Branching and flow" section and needs no
repair — the precondition for cutting MX-TABULAR missions is met.

## EE shared-file divergence check

Precondition for the first EE backport merge (spec, "Branching and
flow"): verify EE's unreleased WIP has not diverged the shared
substrate files. Method: recursive working-tree diff of the four
shared kits between the EE checkout (develop/1.1.x, commit 2cd6fd505)
and CE develop/1.1.x (commit 313596c6).

| Kit | Tracked-source divergence |
|---|---|
| PersistenceKit | none — `.DS_Store` files only |
| LocusKit | none — `.claude/` and Rust `target/` build dirs only |
| GeniusLocusKit | none — Rust `target/` build dir only |
| AriaMcpKit | none — `.claude/` and Rust `target/` build dirs only |

**Verdict: zero tracked-source divergence.** EE backports from CE
develop/1.1.x can proceed per-mission with no reconciliation debt.

## ContentKind sweep (MX-TAB-3 Blast Radius seed)

Repo-wide sweep for `ContentKind` (Swift) and `ContentKind|content_kind`
(Rust): **19 Swift files and 28 Rust files, all under `packages/`** —
no reference sites in `apps/`, `scripts/`, or elsewhere. The spec's
preliminary site list names symbols not present in CE (DreamingDaemon,
AuditBridge, EstateLifecycle, StandingSignalScheduler, SyncRecord,
ObsidianAdapter); the authoritative enumeration for MX-TAB-3 is the
compiler (exhaustive switch/match failures) plus a hand inspection of
every defaulted switch at the swept sites, recorded in that mission's
Blast Radius Report.

One spec correction feeding MX-TAB-3: `ContentKind` already carries
`fingerprintOnly = 6` (F12 cascade, cookbook v0.6), which the spec's
case list omits. `dataset` therefore lands at raw value 7 —
within the 4-bit kind slot — and the cookbook §2.4 contiguity
declaration is part of MX-TAB-3's blast radius.
