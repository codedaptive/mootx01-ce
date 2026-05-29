# SubstrateLib

SubstrateLib is the math foundation of the GeniusLocus substrate. It is the first kit in the eleven-kit family defined in `docs/decisions/DECISION_KIT_GRAPH_REFACTOR_2026-05-19.md`.

Promoted from `docs/validation/substrate_math_performance/GeniusLocusReference/` on 2026-05-19. The reference implementation continues to exist as a checked-in artifact for cookbook cross-reference; SubstrateLib is the published product surface that downstream kits consume.

## What SubstrateLib holds

SubstrateLib owns the mathematical primitives that every other GeniusLocus kit depends on. The contents fall into seven topic groups:

**Fingerprint construction (paper §5).** The 256-bit four-block SimHash fingerprint that is the substrate's universal coordinate system for structural similarity. Four 64-bit blocks: Bitmap-LSH (block0), Lattice-LSH (block1), Lineage-and-Temporal (block2), Channel-and-Source (block3). Sources: `Fingerprint256.swift`, `SimHash.swift`, `HyperplaneFamily.swift`, `Hamming.swift`, `HammingNN.swift`, `ORReduce.swift`, `BitwiseArithmetic.swift`, `CompositeDistance.swift`, `LatticeDistance.swift`.

**Audit log CRDT (paper §6).** The Grow-Only Set CRDT under Hybrid Logical Clock ordering that is the substrate's source of truth. Append-only, merge-safe, projects to current state deterministically. Sources: `GSetAuditLog.swift`, `HLC.swift`, `AuditLogFold.swift`, `RowStateAutomaton.swift`.

**Matrix tier (paper §7).** The C, F, O, T matrices and their derived statistics (asymmetry profile, eigenvalue spectrum) that hold the substrate's accumulated learning. Sources: `MatrixC.swift`, `MatrixF.swift`, `MatrixO.swift`, `MatrixT.swift`, `MatrixDecay.swift`, `MomentSummary.swift`, `EigenvalueCentrality.swift`, `NMFAlternatingLeastSquares.swift`, `ActionOutcomeMatrix.swift`, `ThreeDBitTensor.swift`, `TemporalCompression.swift`.

**Kernel layer with learned dispatch (paper §11.3).** Portable kernel protocol with four specializations (NEON, BNNS, Metal, SIMD) and a scalar reference. Every backend produces bit-identical output to the scalar reference; learned dispatch routes hot operations to the best-measured backend per hardware. Sources: `PortableKernel.swift`, `PortableKernel-NEON.swift`, `PortableKernel-BNNS.swift`, `PortableKernel-Metal.swift`, `PortableKernel-SIMD.swift`.

**Federation primitives (paper §9).** Hyperplane family construction for cross-estate fingerprint compatibility, pairing handshake, tier-ascending query, tier contribution fingerprint, differentially-private OR-reduction. Sources: `HyperplaneFamily.swift`, `PairingHandshake.swift`, `TierAscendingQuery.swift`, `TierContributionFingerprint.swift`, `DPORReduction.swift`.

**Verbs and row-state (paper §10, spec §10).** The nine substrate verbs and the row-state automaton that validates verb preconditions and postconditions. Sources: `Verbs.swift`, `RowStateAutomaton.swift`, `PartialStateRecall.swift`.

**Mathematical supports.** Information theory primitives, FFT for periodicity analysis, Bradley-Terry pairwise ranking, community detection, random walks, calibration curves, anomaly detection, feature extractors. Sources: `InformationTheory.swift`, `FFT.swift`, `BradleyTerry.swift`, `CommunityDetection.swift`, `RandomWalks.swift`, `LLMCalibrationCurve.swift`, `AnomalyDetection.swift`, `FeatureExtractors.swift`, `DPORReduction.swift`.

**Recall types.** Substrate-layer wire types for ranked recall results and minimal row projections. Promoted from CognitionKit so federation and downstream cognition share one definition. Sources: `RecallTypes.swift`.

## What SubstrateLib does not hold

Several files from the reference implementation belong upstream in the kit graph. They were moved to `docs/validation/substrate_math_performance/upstream-staging/` during the SubstrateLib promotion and will be picked up by their target kits during subsequent missions.

| Reference file | Target kit |
|---|---|
| `glref-swift-ActuatorKit.swift` | NeuronKit (algorithm layer) |
| `glref-swift-CognitionKit.swift` | NeuronKit reasoning functions plus CognitionKit recipes |
| `glref-swift-DreamingDaemon.swift` | GeniusLocusKit Brain layer |
| `glref-swift-PortableCognitionBundle.swift` | ARIA_MCP or CognitionKit (caller-side bundle) |
| `glref-swift-SQLiteDurabilityTail.swift` | PersistenceKit-SQLite |
| `glref-swift-WorkingSetMmap.swift` | PersistenceKit-SQLite |

## Constitutional invariants enforced by SubstrateLib

SubstrateLib's mathematical implementation is the enforcement point for several invariants from the paper's Appendix A:

- **I-1 (verbatim rung sacred):** SubstrateLib's `Verbs.swift` exposes a capture verb that writes the verbatim content rung but provides no verb to mutate it. The immutability is structural in the verb surface.
- **I-17 (cross-noun fingerprint compatibility):** Every noun's fingerprint is constructed under the same four-block hyperplane family. SubstrateLib's `Fingerprint256` is one type, used identically for every noun.
- **I-19 (bit-identity across conformance cells):** Conformance tests in `Tests/SubstrateLibConformanceTests/` enforce that the scalar reference and every hardware kernel produce identical output for the same input.
- **I-22 (audit-trail-is-substrate):** The `GSetAuditLog` is the source of truth; current state is a projection. SubstrateLib ships the projection function (`AuditLogFold`); there is no separate state store.

## Recent changes

**2026-05-19:** `AuditEvent` gained an `eventID: UUID` field (defaulted to `UUID()` so existing call sites compile unchanged). The `(eventID, hlc)` compound key gives PersistenceKit's `AuditLog` append idempotence, which is what makes the G-Set CRDT semantics work cleanly across sync boundaries. Consumers constructing audit events from scratch should let the eventID default unless they have a specific reason to set one (e.g. deserializing a sync-inbound event).

## Building and testing

```
cd SubstrateLib
swift build
swift test
```

Requires Swift 6.0 or later. Tested on Apple Silicon macOS 14+; Linux x86_64 conformance is enforced by the external test harness.

## Public API stability

Once shipped, public API in SubstrateLib follows semantic versioning. Breaking changes require a major version bump and a corresponding decision record in `docs/decisions/`. The v1.0 public surface is the surface inherited from the Phase 2 closure (2026-05-18) plus the `RecallTypes.swift` extraction.

## Cookbook cross-reference

Each source file's header comment names the cookbook section it implements. The cookbook (`docs/engineering/GENIUSLOCUS_ENGINEERING_COOKBOOK_v0.36_2026-05-16.md`) remains the authoritative specification for the mathematics SubstrateLib implements.
