---
status: decided
question: Which layer owns the autonomic governor (the loop that drives dreaming, maintenance, training, the matrix tier, and Bradley-Terry), and how should the Brain-layer kits (CognitionKit, NeuronKit, GeniusLocusKit) and the MCP relate?
authors: MOOTx01 maintainers
date: 2026-06-20
version: v1.0
relates_to:
  - CLAUDE.md (GeniusLocusKit role bullet — propagation pending, owner-only file)
  - docs/concepts/topology-assets/mootx01_topology_v1.0.svg (redraw pending — read-only, promote via custodian)
  - docs/concepts/TOPOLOGY.md (propagation pending — read-only)
  - docs/reference/GENIUSLOCUSKIT_SPEC.md
  - docs/reference/GENIUSLOCUSKIT_INTERFACE.md
supersedes: none
clarifies: the CLAUDE.md / topology framing that GeniusLocusKit "runs the Brain layer / autonomous orchestrator"
---

# ADR-017 — Brain-layer logical model and AutonomicGovernor placement

## Context

The topology diagram and the CLAUDE.md role bullet described **GeniusLocusKit (GLK)** as the "autonomous orchestrator" that "runs the Brain layer." This is structurally impossible and seeded a real review: the dependency direction is **NeuronKit → GLK** (NeuronKit depends on GLK; GLK depends on neither NeuronKit nor CognitionKit). A kit cannot *drive* daemons that live in a kit *above* it. GLK can only **emit** standing signals (`DreamingSignal`, etc.) and **expose** API (`signalTick`, `corpusChunkCount`, `reindexCorpus`, the nine verbs); it cannot run the loop.

In the shipped code the loop's single driver — `AutonomicGovernor` — was located inside **AriaMcpKit**, the MCP interface/gateway kit. That works (no inversion, one driver, both `mootx01 serve` and `aria-mcp-server` start it via the shared `AriaResident.runResidentDaemon`), but it **conflates two distinct concerns**: the external *interface* (the voice / perimeter) and the *autonomic governor* (the substrate's self-maintenance, which runs regardless of external traffic).

## Decision (the canonical logical model)

Layers and roles, top to bottom:

- **MCP / AriaMcpKit** — the **interface** the AI issues commands through; routes to CognitionKit / NeuronKit / GLK **by complexity**. It is the resident-process **host**: it *starts* the governor, it does not own scheduling logic.
- **CognitionKit** — the layer that **executes commands** (behaviour recipes).
- **NeuronKit** — the **complex coordination of algorithms, automation, scheduled processors, and daemons**. **The `AutonomicGovernor` lives here.**
- **GeniusLocusKit** — **the layer with the buttons**: the nine verbs, the standing-signal *registry*, the matrix-tier and training-daemon *types*, the data custodian. It **emits** signals and **exposes** API; it does **not** drive the loop and is **not** the "autonomous orchestrator."

Dependency direction (must not invert): CognitionKit → NeuronKit → GLK → substrate kits. The MCP composes/depends on all three.

## What shipped

Realized in CE commit `9003ae3f8` (`refactor/governor-to-neuronkit`):

- `AutonomicGovernor` (+ `GraphCentralityProducer`, `PreferenceProducer`) **moved from AriaMcpKit into NeuronKit**, both Swift and Rust ports.
- Layering guard verified: **NeuronKit imports zero CognitionKit, zero AriaMcpKit** (both languages).
- Real cross-layer couplings were **injected, not moved down**:
  - the CognitionKit graph-analytics scan reaches the governor via a `graphAnalyticsHandler` closure supplied by `AriaResident`;
  - host telemetry (`StatsStore`) reaches the governor via a `GovernorTopologySink` trait, with `StatsStoreTopologySink` as the AriaMcpKit adapter.
- `AriaResident` (the MCP-side host) constructs and starts the governor; it no longer owns it.
- Auto-reindex: `EstateCorpusGrowthProbe` is now constructed inside the governor and handed to `DreamingDaemon` — always on, logged at start (closes the corpus-vocabulary-staleness gap; the dreaming daemon reindexes on +25-chunk growth).

Both binaries build; NeuronKit/AriaMcpKit/GLK green on swift + cargo; resident daemon live-verified (capture/recall/dream through the relocated governor).

## Consequences

- The Brain loop has one driver, correctly layered, in NeuronKit.
- **Six-months-from-now anchor:** "is the dreaming daemon run by serve?" → **yes**, via `AriaResident.runResidentDaemon` → one `AutonomicGovernor` (NeuronKit) → `governor.run()/tick`. Do **not** re-litigate by reading `apps/mootx01/Package.swift` (NeuronKit is pulled transitively); read the governor's `tick`.

## Propagation (docs to correct to this model — not code, tracked separately)

These are read-only or owner-only and must be updated by the custodian / owner, not in this branch:
1. **CLAUDE.md** GLK bullet — change "runs the Brain layer / autonomous orchestrator" to "GLK *defines* the standing-signal scheduler, matrix tier, and training-daemon types and *emits* signals; the `AutonomicGovernor` (NeuronKit, started by the AriaResident host) *drives* them." (Owner: Bob.)
2. **docs/concepts/topology-assets/mootx01_topology_v1.0.svg** + **TOPOLOGY.md** — redraw per the corrected-diagram spec below. (Read-only; promote via Nagatha. Draft at `docs_internal/analysis/mootx01_topology_corrected_draft.svg`.)
3. **docs/reference/GENIUSLOCUSKIT_SPEC.md / _INTERFACE.md** — align the "coordinates / standing-signal scheduler / training daemon" prose to "defines + emits, driven by the governor" (governed-doc edit, version bump per VERSIONING.md §5).

## Corrected-diagram spec (for the redraw)

- **NeuronKit** subtitle: `subconscious · algorithms · daemons · autonomic governor`.
- **GeniusLocusKit** subtitle: drop "autonomous orchestrator"; use `N estates · nine verbs · signal registry · data custodian` and `the buttons · emits standing signals · one queue per estate`.
- **ARIA_MCP**: it is not only "the voice / read perimeter" — it **issues commands by complexity** to CognitionKit / NeuronKit / GLK **and hosts/starts the NeuronKit governor**. Show a "hosts AutonomicGovernor (NeuronKit)" note; keep the secure-perimeter framing for the write gate.
- Arrows unchanged in direction (CognitionKit→NeuronKit→GLK; MCP→all three); relabel the MCP→kit arrows "issue commands (by complexity)" rather than "R-only voice."

## Related cleanup (Kong review, 2026-06-20)

- **F1** — GLK `TrainingDaemon` is an orphan (no production caller; not among the 8 default standing signals). **Wire it** as a standing-signal `SignalSpec`; do **not** delete without proving the live matrix-training path subsumes its transition-count-gated `runOnce` (`DECISION_TRAINING_DAEMON_THRESHOLD_2026-05-21`). Removal-to-tidy collides with the no-feature-removal rule.
- **F2** — ~15 "Brain pump" / "BrainPump" prose/help sites → "autonomic governor" (code-comment sweep; symbol `AutonomicGovernor` is already correct).
- **F3** — the propagation items above.
