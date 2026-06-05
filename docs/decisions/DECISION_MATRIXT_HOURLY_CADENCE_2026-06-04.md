---
status: decided
question: What cadence should the T-matrix (temporal causality) population pass run at?
authors: Design Council
date: 2026-06-04
relates_to:
  - docs/engineering/GENIUSLOCUS_ENGINEERING_COOKBOOK_v1.0_2026-05-28.md (§6.4 — superseded)
  - docs/reference/GENIUSLOCUSKIT_SPEC_v0.8.md (§11.2 standing-signal inventory)
  - docs/reference/SUBSTRATEML_SPEC_v0.8.md (§5.22 TemporalCausalityFold)
supersedes: cookbook §6.4 weekly cadence specification
---

# DECISION — MatrixT Hourly Population Cadence

**Date:** 2026-06-04  
**Status:** Decided (Design Council, 2026-06-04)  
**Scope:** MatrixTier T-population pass; TemporalCausalitySignal cadence;
          GeniusLocusKit standing-signal inventory §11.2.

---

## Context

Cookbook §6.4 (GENIUSLOCUS_ENGINEERING_COOKBOOK v1.0, 2026-05-28) specifies
the temporal causality matrix T's update rule as a "dreaming daemon pass,
weekly." The passage was written before the MatrixT write path existed and
before the hourly standing-signal scheduler was designed.

Design Council reviewed the cadence on 2026-06-04 and concluded that weekly
was underspecified — it conflated the dreaming daemon's weekly cold-path work
(NMF, eigenvalue centrality) with the T-population pass, which has different
performance characteristics and freshness requirements.

At the time of this decision:
- `MatrixTier.applyTemporalEvent` exists but has no production write path.
- The dreaming daemon (weekly) has no mechanism to execute the T fold.
- The standing-signal scheduler can run an hourly signal with zero dreaming
  daemon involvement.

---

## Decision

**The T-population pass runs hourly (3 600 seconds cadence).**

The signal is registered as `TemporalCausalitySignal` in
`GeniusLocusKit.registerDefaultStandingSignals` via `defaultSpec()`. The fold
engine `TemporalCausalityFold` (SubstrateML) is called from
`MatrixTier.rebuildTemporal(from:)` at each fire.

---

## Rationale

**Fresh within 1 hour.** Temporal causality signals ("A causes B") are most
useful when the pattern is fresh. A weekly batch would leave 7 days of capture
events unprocessed. An hourly batch keeps T within 1 hour of the live audit log,
which is adequate for the Brain layer's T-scored recall.

**Off capture hot path.** The fold is pure and runs off the capture hot path —
it reads the audit log, not the live capture stream. Hourly scheduling does not
add any per-capture overhead.

**Scheduling cost is predictable.** The fold is O(n × window) where n is the
number of audit entries since the last watermark (bounded by entries in the
preceding hour) and window is 256 minutes (a constant). An hourly budget is
predictable and does not accumulate a large "catch-up" batch the way a weekly
run would after a week of captures.

**Avoids dreaming daemon dependency.** Making T depend on the weekly dreaming
daemon would block the first T data until the daemon fires, delay T after estate
restore, and entangle the dreaming daemon's complex NMF/eigenvalue machinery
with the comparatively simple T fold. Decoupling is cleaner.

**Implementation boundary.** The fold algorithm belongs in SubstrateML
(cold-path algorithms); the GeniusLocusKit standing-signal scheduler is the
correct scheduling surface. This boundary matches the existing DreamingSignal
pattern, where the signal is the trigger and the caller supplies the work
closure.

---

## What This Decision Does NOT Change

- The cookbook §6.4 file itself is not modified. This decision document records
  the supersedence; the cookbook is a reference artifact.
- The dreaming daemon weekly cadence (DreamingSignal) is unchanged.
- The T-matrix decay half-life (90 days, cookbook §6.8) is unchanged.
- The window cap (256 minutes, cookbook §6.4) is unchanged.
- The lag bucket boundaries ({1,2,4,8,16,32,64,128} minutes) are unchanged.

---

## Package Dependency Addition

This decision requires GeniusLocusKit to import SubstrateML (for
`TemporalCausalityFold`). The dependency is recorded in
`GeniusLocusKit/Package.swift`. This does not invert the kit layering graph:
GeniusLocusKit is the composition layer; SubstrateML is the algorithm layer
below it.

---

## Implementation

| Component | Location | Status |
|-----------|----------|--------|
| `TemporalCausalityFold` (Swift + Rust) | SubstrateML | Committed 2026-06-04 |
| `TemporalAuditEntry`, `TemporalFieldCoord`, `TemporalCausalityKey` | SubstrateML | Committed 2026-06-04 |
| `MatrixTier.temporalWatermarkHLC` | GeniusLocusKit Matrix/MatrixTier.swift | Committed 2026-06-04 |
| `MatrixTier.rebuildTemporal(from:)` | GeniusLocusKit Matrix/MatrixTier.swift | Committed 2026-06-04 |
| `TemporalCausalitySignal` (3 600 s) | GeniusLocusKit Brain/Signals/ | Committed 2026-06-04 |
| Registered in `defaultStandingSignalNames` | GeniusLocusKit Brain/Signals/DefaultStandingSignals.swift | Committed 2026-06-04 |
| Conformance vectors | docs/engineering/substrate_reference/test-harness/vectors/temporal_causality_fold.json | Committed 2026-06-04 |
