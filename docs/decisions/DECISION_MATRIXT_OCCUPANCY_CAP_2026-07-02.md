---
status: decided
question: How should the temporal-causality (T) fold be bounded so a degenerate time-window in a bulk historical import cannot drive the rebuild into quadratic time and unbounded memory?
authors: MOOTx01 maintainers
date: 2026-07-02
relates_to:
  - docs/engineering/GENIUSLOCUS_ENGINEERING_COOKBOOK.md (§6.4 — amended)
  - docs/reference/SUBSTRATEML_SPEC.md (§5.22 TemporalCausalityFold)
  - docs/decisions/DECISION_MATRIXT_HOURLY_CADENCE_2026-06-04.md
  - docs/decisions/ADR-004-event-time-two-clock-ingest-primitive.md
supersedes: none
context:
  - The T fold pairs each new entry against every earlier in-window entry (256-minute window), nested over field-value coordinates. Cost is O(events × in-window-neighbours × coords²).
  - A 50k-drawer MemPalace import placed 82% of all events (41,364 of 50,143) inside a single hour (2026-05-04T20). A cold full-rebuild paired ~41k² events; the high-cardinality wikidataQID coordinate (added for co-occurrence signal) generated ~10M distinct T keys, driving the rebuild to 9.9 GB RSS and >18 minutes without completing.
  - Keying the T fold off event_time (ADR-004) is correct, but it is exactly what surfaces a dense historical cluster as a single window.
---

# DECISION — MatrixT Occupancy Cap and QID Exclusion from T

**Scope:** `SubstrateML.TemporalCausalityFold`; `GeniusLocusKit.MatrixTier`
          temporal rebuild path (`rebuildTemporal` / `rebuild_temporal_from`);
          amends GENIUSLOCUS_ENGINEERING_COOKBOOK §6.4.

---

## Context

The temporal causality matrix T is populated by folding the audit log: for
each new entry, pair it against every earlier entry still inside the
256-minute window, emitting one directional lag-bucketed key per
(source-coord, target-coord) pair. This is quadratic in the number of
events that share a window.

Real capture traffic never fills a 256-minute window densely, so the
quadratic term stayed dormant. A bulk historical import broke that
assumption: an old MemPalace migration stamped 82% of a 50k estate with
event_times inside one hour. Once the matrix build was wired to run at
daemon launch (parity with the Swift resident), a cold full-rebuild of that
estate walked straight into the quadratic case — 9.9 GB RSS, >18 minutes,
no completion. The memory term was dominated by the `wikidataQID`
coordinate: a high-cardinality per-content concept whose cross-event
pairing produces a distinct T key for every pair of distinct concepts.

## Decision

Two independent bounds, applied identically in the Swift and Rust ports and
conformance-gated:

1. **Occupancy cap — `maxWindowOccupancy` / `MAX_WINDOW_OCCUPANCY = 512`.**
   The fold's pairing buffer retains only the 512 most-recent in-window
   entries as sources; older in-window entries are dropped (the buffer is
   ascending by clock, so the oldest are at the front). This bounds both the
   per-entry window-eviction scan and the pairing loop to
   O(events × 512), converting the quadratic pass into a linear one. The
   dropped sources are the oldest in the window — the weakest temporal
   proximity — so the near-lag causal signal the T matrix exists to capture
   is preserved. The cap never triggers for windows holding ≤ 512 entries,
   so all pre-existing conformance vectors are unaffected.

2. **Exclude `wikidataQID` from T; retain it in O.** The QID is the
   high-cardinality per-content concept the FDC classifier resolves. It is
   meaningful for co-occurrence (O — which concepts appear *together* in one
   event) but as a temporal (T — which concept *precedes* which across
   events) coordinate it pairs every distinct concept with every other,
   generating a unique source×target key per content pair. That is noise
   rather than causal signal, and it was the dominant term in the T-key
   blow-up. QID is dropped only in the T build path; it remains a
   co-occurrence coordinate in O unchanged.

## Rationale

- The cap is the load-bearing fix for *time*: even with QID removed, the
  low-cardinality bitmap coordinates still pair O(window²) times without it.
- The QID exclusion is the load-bearing fix for *memory* (distinct-key
  count) and is the correct signal-quality call independently: temporal
  causality between unique content concepts is not a learnable structure.
- N = 512 is chosen as a power-of-two bound comfortably above the density of
  any genuine (non-degenerate) capture window while cutting the pathological
  case by ~80× on the observed estate.

## Consequences

- The T matrix on an estate with a dense (> 512-event) window now reflects
  the 512 nearest-in-time sources per target rather than the full window.
  This is a deliberate, documented approximation, not a bug.
- `incremental_update` remains bit-identical to `full_rebuild`: the buffer is
  built identically regardless of the watermark, so both paths apply the same
  cap. The `incrementalUpdateMatchesFullRebuildAtEverySplit` conformance test
  passes with the cap and QID exclusion in place, on both ports.
- End-to-end: the cold launch rebuild of the 50k import completes in ~15 s at
  1.76 GB RSS (was 9.9 GB / >18 min), and persists its snapshot so subsequent
  launches load-and-fold-tail cheaply.

## Alternatives considered

- **Occupancy cap alone** — bounds time but leaves the QID key-explosion
  memory term; rejected as incomplete.
- **QID-from-T alone** — removes the memory term but leaves the O(window²)
  bitmap pairing time cost; rejected as incomplete.
- **Sampling / probabilistic thinning of dense windows** — rejected:
  non-deterministic, breaks bit-identical cross-port conformance.
