---
title: Topology V2 Phase 4 — Folds (governor-side subcommunities)
version: v0.1
status: draft
date: 2026-07-09
description: "Mission draft: split large graph communities into persistent subclusters (folds) computed by the autonomic governor, so the dashboard renders internal topic pockets inside big lobes."
relates_to:
  - docs/reference/MOOT_MGR_SPEC.md
  - docs/reference/NEURONKIT_SPEC.md
---

# Topology V2 Phase 4 — Folds

## Goal

A 2,000-node lobe must not render as one undifferentiated blob with one
label. Large communities get internal **folds** — subclusters derived from
local graph structure plus drawer-level FDC distribution — rendered as
topic pockets inside the lobe, each with its own confidence label.

## Why governor-side (decision already made)

Client-side clustering was rejected during V2 phases 1–2: a fold recomputed
in the browser re-randomizes on every refresh, undercutting the "living
patterns" reading and contradicting the estate (the folds would be cosmetic
structure the substrate does not store). Folds therefore are computed by the
autonomic governor (CognitionKit recipe cadence), persisted in the topology
snapshot, and rendered — never invented — by the dashboard.

## Sketch (to be scoped at dispatch)

1. **NeuronKit lens**: sub-Louvain (or label-propagation) pass WITHIN each
   community above a size threshold (~200 members), seeded by intra-community
   edges; emit `foldId` per node (nullable — small communities have none).
   Swift leads, Rust mirrors, conformance-tested.
2. **Snapshot**: `foldId` on the stored node (additive, tolerant decode —
   same pattern as `udcCode` in V2-P1a).
3. **moot-mgr wire**: dictionary/parallel-array encoding alongside
   `codes`/`codeIndex` (same 5 MB ceiling test extension).
4. **Dashboard**: fold sub-centers inside the lobe scatter; per-fold FDC
   purity/confidence mini-labels at zoom; picker unchanged (folds are not
   filter identities in v1 of this mission).

## Blast radius (verify at dispatch — SPEC-BEFORE-REALITY)

TopologyAnalysis (both legs), AutonomicGovernor snapshot writer (both legs),
moot-mgr GraphPayload (both legs), DashboardAssets. Same file set as
V2-P1a/P1b/P2a — re-run codegraph impact at dispatch; do not trust this
list as terrain.

## Open questions for Kong review

- Fold stability across governor cycles (Louvain renumbering already forced
  label-keyed picker identity; folds need an analogous stable key —
  candidate: dominant-code + rank within community).
- Size threshold and max folds per lobe (render legibility budget).
- Interaction with the Codex FDC hardening: post-reclassification estates
  have cleaner code distributions; fold seeding should use the hardened
  classifier output only (no 000/unclassified seeding).
