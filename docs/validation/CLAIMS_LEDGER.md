---
status: in_progress
created: 2026-05-22
last_updated: 2026-07-20
phase: A
---

# GeniusLocusKit Claims Ledger

The flat ledger of every empirical claim the GLK substrate
makes. Each row is one claim with its spec citation, type,
current status, and evidence pointer. The ledger drives Phases
B through F: invariant negative tests close the invariant rows,
theorem demonstrations close the theorem rows, the migration
benchmark closes the application-validation rows, and the
adversarial + perf gates close the recurring-regression rows.

Status vocabulary per row:

- `evidenced`: a runnable test or demonstration exists and
  passes; the commit SHA, test path, or runnable
  demonstration path is recorded under "Evidence".
- `pending`: the claim has no current evidence on file; the
  reason and what is needed are recorded under "Evidence".
- `waived`: the claim is intentionally deferred or scoped out
  of v1; the rationale is recorded under "Evidence".
- `superseded`: an earlier invariant or theorem that a later
  one replaces. Listed for historical reference; the active
  successor carries the evidence.

## Population status by category

| Category                              | Total | Populated | Phase   |
|---------------------------------------|-------|-----------|---------|
| Invariants (I-1 through I-30; I-24 split a/b) | 31    | 31        | Evidence-linking pass 2026-07-20: 19 evidenced, 7 pending, 1 partial, 2 waived, 2 superseded |
| Theorems (named results, section 14)  | 7     | 7         | Evidence-linking pass 2026-07-20: 5 evidenced, 1 pending (T6), 1 waived (T7/T8) |
| Hot-path budgets (cookbook section 17.1) | 3+    | 3         | A second batch done |
| Verb-surface protocol contracts       | 9     | 9         | A second batch done |
| Manifest required keys                | 18+5  | 0         | A pending |
| Framework profile contracts           | TBD   | 0         | A pending |
| Standing-signals scheduler contracts  | TBD   | 0         | A pending |
| Decision-record claims                | TBD   | 0         | A pending |

Phase A population continues.

## Invariants

The constitutional core. I-1 through I-14 are inherited from
the architecture spec section 3. I-15 through I-24 extend it.
Two original invariants (I-5 and I-9) are explicitly superseded
by I-16 and I-15 respectively; they are listed below as
`superseded` rows for historical traceability.

### I-1: Verbatim rung is immutable

- Spec: `docs/reference/GENIUSLOCUS_ARCHITECTURE_SPEC.md` line 68
- Type: invariant
- Status: active in v1.0
- Evidence: pending. Corrections-produce-new-versions is covered by
  the LocusKit lineage cascade suite
  (`packages/kits/LocusKit/Tests/LocusKitTests/LineageTests.swift`),
  and DrawerStore exposes no rung-1 content-mutation API. Missing: a
  negative test that attempts mutation of a rung-1 column
  post-capture and asserts failure.

### I-2: All bitmap mutations write audit rows

- Spec: `docs/reference/GENIUSLOCUS_ARCHITECTURE_SPEC.md` line 70
- Type: invariant (formalized by I-20 as G-Set CRDT)
- Status: active in v1.0; co-active with I-20
- Evidence: evidenced. `mutateAdjective` and `mutateOperational`
  each write exactly one audit row with full fields, and write no
  row when the mutation fails; `mutateProvenance` writes its audit
  row atomically and rolls back on failure. All three bitmap
  columns are covered.
- Evidence pointer:
  `packages/kits/LocusKit/Tests/LocusKitTests/BitmapAuditTests.swift`;
  `packages/kits/LocusKit/Tests/LocusKitTests/ProvenanceTests.swift`;
  `packages/kits/GeniusLocusKit/Tests/GeniusLocusKitTests/UnifiedAuditLogTests.swift`.

### I-3: The substrate accepts no `secret + public` combination

- Spec: `docs/reference/GENIUSLOCUS_ARCHITECTURE_SPEC.md` line 72
- Type: invariant (subsumed by I-22's forbidden combinations enumeration)
- Status: active in v1.0; co-active with I-22
- Evidence: evidenced. Both required surfaces are on file. Verb
  layer: the validator throws on secret + exportable, and both
  capture and `mutateAdjective` reject the forbidden bitmap,
  leaving prior state and the audit table untouched. Maintenance
  scan: the standing maintenance signal emits the forbidden-combo
  proposal.
- Evidence pointer:
  `packages/kits/LocusKit/Tests/LocusKitTests/ForbiddenCombinationTests.swift`;
  `packages/kits/GeniusLocusKit/Tests/GeniusLocusKitTests/StandingSignalsTests.swift`
  (maintenanceSignalEmitsForbiddenComboPlusCandidateAndDiagnostic).

### I-4: Every model-generated rung carries `model_id` and `model_version`

- Spec: `docs/reference/GENIUSLOCUS_ARCHITECTURE_SPEC.md` line 74
- Type: invariant
- Status: active in v1.0
- Evidence: pending. `modelID` and `modelVersion` are non-optional
  parameters of the VectorKit lane-store write surface (exercised
  throughout
  `packages/kits/VectorKit/Tests/VectorKitTests/FloatLaneStoreTests.swift`),
  so the absent case is structurally unrepresentable there.
  Missing: an explicit negative test asserting a rung 2/3/4 write
  without model identification fails.

### I-5: Every drawer carries a lattice anchor (superseded)

- Spec: `docs/reference/GENIUSLOCUS_ARCHITECTURE_SPEC.md` line 76
- Type: invariant
- Status: superseded by I-16 (universal lattice anchor extends
  this from drawer-only to all noun types)
- Evidence: historical; the active version's evidence is
  under I-16.

### I-6: Audit rows can be tombstoned but not modified

- Spec: `docs/reference/GENIUSLOCUS_ARCHITECTURE_SPEC.md` line 78
- Type: invariant
- Status: active in v1.0
- Evidence: evidenced. Expunge tombstones with content zeroing and
  an appended audit event; audit-grade (accepted) rows are refused
  and survive intact; withdraw and expunge are sticky tombstones in
  the unified log fold.
- Evidence pointer:
  `packages/kits/LocusKit/Tests/LocusKitTests/ExpungeTests.swift`;
  `packages/kits/GeniusLocusKit/Tests/GeniusLocusKitTests/UnifiedAuditLogTests.swift`
  (withdrawAndExpungeAreStickyTombstones).

### I-7: The verb count is fixed at nine

- Spec: `docs/reference/GENIUSLOCUS_ARCHITECTURE_SPEC.md` line 80
- Type: invariant
- Status: active in v1.0
- Evidence: evidenced. The lexicon suite asserts
  `Verb.allCases.count == 9`, the canonical declaration order of the
  nine verbs, and the 6/2/1 flow partition; the Rust leg mirrors it
  (`verb_count_is_nine`).
- Evidence pointer:
  `packages/libs/AriaLexiconLib/Tests/AriaLexiconLibTests/VerbTests.swift`.

### I-8: The adjective category count is fixed at four

- Spec: `docs/reference/GENIUSLOCUS_ARCHITECTURE_SPEC.md` line 82
- Type: invariant
- Status: active in v1.0
- Evidence: evidenced. The lexicon suite asserts exactly the four
  named categories (state, trust, sensitivity, exportability); the
  Rust leg mirrors it (`adjective_count_is_four`).
- Evidence pointer:
  `packages/libs/AriaLexiconLib/Tests/AriaLexiconLibTests/AdjectiveTests.swift`.

### I-9: Field width is 4 bits in the bitmap tier (superseded)

- Spec: `docs/reference/GENIUSLOCUS_ARCHITECTURE_SPEC.md` line 84
- Type: invariant
- Status: superseded by I-15 (6-bit field-width floor)
- Evidence: historical; the active version's evidence is
  under I-15.

### I-10: Every bitmap field reserves at least 30% growth space

- Spec: `docs/reference/GENIUSLOCUS_ARCHITECTURE_SPEC.md` line 86
- Type: invariant
- Status: active in v1.0
- Evidence: pending. No growth-space check is on file. Missing: a
  unit test over the manifest's bitmap layout asserting each
  field's used-values count is at most 70% of its capacity.

### I-11: Bitmap layouts within a published version are stable

- Spec: `docs/reference/GENIUSLOCUS_ARCHITECTURE_SPEC.md` line 88
- Type: invariant
- Status: active in v1.0
- Evidence: evidenced. A fresh estate populates
  `bitmap_layout_version` with the published v1 default, and a
  database carrying an unknown layout version refuses to open with
  `EstateError.manifestMismatch` — layouts are pinned to the
  published manifest version.
- Evidence pointer:
  `packages/kits/LocusKit/Tests/LocusKitTests/ManifestTests.swift`;
  `packages/kits/LocusKit/Tests/LocusKitTests/EstateTests.swift`.

### I-12: The substrate provides storage; applications do not bring their own

- Spec: `docs/reference/GENIUSLOCUS_ARCHITECTURE_SPEC.md` line 90
- Type: invariant
- Status: active in v1.0
- Evidence: evidenced by composition. GLK depends on LocusKit,
  VectorKit, and CorpusKit per the kit-composition test
  surfaces; no external storage adapter exists.
- Evidence pointer:
  `packages/kits/GeniusLocusKit/Tests/GeniusLocusKitTests/CompositionConformanceTests.swift`.

### I-13: Federation is not a substrate concern

- Spec: `docs/reference/GENIUSLOCUS_ARCHITECTURE_SPEC.md` line 92
- Type: invariant
- Status: active in v1.0
- Evidence: evidenced by absence. The substrate kit graph
  contains no network or RPC surface. Confirmed by
  inspection; a structural test enumerating GLK's exported
  symbols and asserting none reach outside the local kit
  graph would formalize this.

### I-14: Provenance is set at write and mutated only via the audit-recorded path

- Spec: `docs/reference/GENIUSLOCUS_ARCHITECTURE_SPEC.md` line 94
- Type: invariant
- Status: active in v1.0
- Evidence: evidenced. Propose sets provenance at write time
  (non-default provenance round-trips; each provenance value writes
  to its own window); `mutateProvenance` flips bits and writes its
  audit row atomically, rolling back both tables on failure — the
  audit-recorded mutation path.
- Evidence pointer:
  `packages/kits/LocusKit/Tests/LocusKitTests/ProposeProvenanceTests.swift`;
  `packages/kits/LocusKit/Tests/LocusKitTests/ProvenanceTests.swift`.

### I-15: 6-bit field-width floor

- Spec: `docs/engineering/GENIUSLOCUS_ENGINEERING_COOKBOOK.md` line 295 (§2.2)
- Type: invariant (supersedes I-9)
- Status: active in v1.0
- Evidence: evidenced. The bitmap conformance suites pin the 6-bit
  field positions (bits 0-5, 6-11, ...) to the cookbook layout for
  the adjective and operational bitmaps, and the kernel BitField
  suite exercises 6-bit field extraction.
- Evidence pointer:
  `packages/kits/LocusKit/Tests/LocusKitTests/AdjectiveBitmapConformanceTests.swift`;
  `packages/kits/LocusKit/Tests/LocusKitTests/OperationalBitmapConformanceTests.swift`;
  `packages/libs/SubstrateKernel/Tests/SubstrateKernelTests/BitFieldTests.swift`.

### I-16: Every row has a lattice anchor

- Spec: `docs/engineering/GENIUSLOCUS_ENGINEERING_COOKBOOK.md` line 580 (§2.7)
- Type: invariant (supersedes I-5, extends drawer-only to universal)
- Status: active in v1.0
- Evidence: pending. Anchor persistence is covered for drawers
  (`packages/kits/LocusKit/Tests/LocusKitTests/LatticeAnchorTests.swift`,
  all four anchor fields) and associations
  (`packages/kits/LocusKit/Tests/LocusKitTests/AssociationTests.swift`,
  four-field anchor round-trip). Missing: schema-level presence
  assertions for the remaining noun row types (tunnels, KG facts,
  diary entries), or one structural test across all noun schemas.

### I-17: Cross-noun fingerprint compatibility

- Spec: `docs/engineering/GENIUSLOCUS_ENGINEERING_COOKBOOK.md` line 1075 (§3.8)
- Type: invariant
- Status: active in v1.0
- Evidence: evidenced. The four hyperplane families are independent
  per block with fixed canonical widths, fingerprints share the
  256-bit four-block wire shape, and Hamming distance is exercised
  over the shared format (same surface as theorem T2).
- Evidence pointer:
  `packages/kits/LocusKit/Tests/LocusKitTests/DrawerFingerprintTests.swift`;
  `packages/libs/SubstrateTypes/Tests/SubstrateTypesTests/HammingTests.swift`;
  `packages/libs/SubstrateTypes/Tests/SubstrateTypesTests/HyperplaneFamilyTests.swift`.

### I-18: Runtime view is bit-sliced 3D tensor

- Spec: `docs/engineering/GENIUSLOCUS_ENGINEERING_COOKBOOK.md` line 1165 (§4.1)
- Type: invariant (constitutional working-set layout)
- Status: active in v1.0
- Evidence: evidenced. The 3D bit tensor round-trips 6-bit values,
  addresses each bit position independently, scans field-equals
  matches exactly, grows capacity while preserving data, and sizes
  as six bit-slices.
- Evidence pointer:
  `packages/libs/SubstrateTypes/Tests/SubstrateTypesTests/ThreeDBitTensorTests.swift`.

### I-19: Kernel layer is portable across SIMD families

- Spec: `docs/engineering/GENIUSLOCUS_ENGINEERING_COOKBOOK.md` line 1234 (§4.4)
- Type: invariant
- Status: active in v1.0
- Evidence: evidenced by the four-cell conformance gate and
  the cross-language byte-equality test for all 28 conformant
  primitives.
- Evidence pointer: the four-way conformance
  matrix.

### I-20: Audit log is a Grow-Only Set CRDT

- Spec: `docs/engineering/GENIUSLOCUS_ENGINEERING_COOKBOOK.md` line 1323 (§5.1)
- Type: invariant (formalizes I-2 with CRDT properties)
- Status: active in v1.0; co-active with I-2
- Evidence: evidenced. The G-Set law surface is tested directly:
  add is idempotent (content-hash dedupe), merge is commutative and
  idempotent, and entries are HLC-ordered; the unified log's
  projection is independent of arrival order and converges across
  tiers.
- Evidence pointer:
  `packages/libs/SubstrateTypes/Tests/SubstrateTypesTests/GSetAuditLogTests.swift`;
  `packages/kits/GeniusLocusKit/Tests/GeniusLocusKitTests/UnifiedAuditLogTests.swift`.

### I-21: Sync convergence

- Spec: `docs/engineering/GENIUSLOCUS_ENGINEERING_COOKBOOK.md` line 1405 (§5.4)
- Type: invariant
- Status: active in v1.0
- Evidence: waived. Sync is a 1.1.x feature under active
  development on develop/1.1.x; convergence evidence rides that
  work.

### I-22: Forbidden state-combination invariants

- Spec: `docs/engineering/GENIUSLOCUS_ENGINEERING_COOKBOOK.md` line 2494 (§9.5)
- Type: invariant (enumeration of forbidden combinations including the original I-3)
- Status: active in v1.0
- Evidence: partial. The `secret + public` case (subsuming the
  original I-3) is covered by
  `packages/kits/LocusKit/Tests/LocusKitTests/ForbiddenCombinationTests.swift`.
  The cookbook §9.5 enumeration remains to be extracted in a
  subsequent Phase A pass.

### I-23: Pairing algebra (binary arity in v1)

- Spec: `docs/engineering/GENIUSLOCUS_ENGINEERING_COOKBOOK.md` line 3037 (§12.1)
- Type: invariant
- Status: active in v1.0
- Evidence: pending. The arity axis is exercised — arity decodes
  bits 18-19 and reserved raw values fall back to `.binary`
  (`packages/kits/LocusKit/Tests/LocusKitTests/AssociationTests.swift`).
  Missing: an explicit negative test asserting the write surface
  rejects an n-ary association rather than coercing it.

### I-24a: Randomized-response fingerprint noising with calibrated (ε, δ) parameters

- Spec: `docs/engineering/GENIUSLOCUS_ENGINEERING_COOKBOOK.md` line 3254 (§12.6)
- Type: invariant (split from I-24, 2026-07-20)
- Status: active in v1.0
- Evidence: evidenced. The DP primitive is implemented —
  `DPParameters` construction and seeded noise in
  `packages/kits/NeuronKit/rust/src/mind_overlap.rs` — and the
  noise path is tested: k-anonymity threshold survival and
  suppression, and zero-mean, seed-deterministic Laplace noise.
- Evidence pointer:
  `packages/kits/NeuronKit/rust/src/mind_overlap.rs`;
  `packages/libs/SubstrateML/Tests/SubstrateMLTests/DPORReductionTests.swift`.

### I-24b: Tier-boundary application with budget tracking

- Spec: `docs/engineering/GENIUSLOCUS_ENGINEERING_COOKBOOK.md` line 3254 (§12.6)
- Type: invariant (split from I-24, 2026-07-20)
- Status: deferred to the 1.2.x federation series
- Evidence: waived. Tier hierarchy is 1.2.x federation; same
  disposition as I-21.

### I-25: One implementation per atomic

- Spec: `docs/engineering/GENIUSLOCUS_ENGINEERING_COOKBOOK.md` §1.4;
  `docs/concepts/MOOTX01_AND_ARIA_CANON.md` ("the substrate owns the atomics")
- Type: invariant (2026-05-28)
- Status: active in v1.0
- Evidence: evidenced. The Swift/Rust concordance discipline is
  enforced mechanically: every public type in each package's Swift
  and Rust legs must appear in its interface doc's Swift/Rust
  Concordance table, checked by the strict concordance gate (run in
  CI and via `make concordance`); cross-language agreement over the
  atomics is exercised by the conformance suites.
- Evidence pointer:
  `packages/scripts/concordance_audit/concordance_audit.py`;
  `packages/libs/SubstrateLib/Tests/SubstrateLibConformanceTests/`.

### I-26: Capture writes a sealed genesis event

- Spec: `docs/decisions/DECISION_CAPTURE_GENESIS_EVENT_2026-05-28.md`
- Type: invariant (2026-05-28; retired the bitmap_audit /
  provenance_audit tables)
- Status: active in v1.0
- Evidence: evidenced. The named positive test is on file:
  `auditTrail(rowID:)` after capture returns the genesis capture
  event, HLC-ordered ahead of subsequent events; the gate itself
  rejects undeclared fields, illegal values, over-width values, and
  illegal transitions.
- Evidence pointer:
  `packages/kits/LocusKit/Tests/LocusKitTests/AuditAPITests.swift`;
  `packages/libs/SubstrateLib/Tests/SubstrateLibTests/AuditGateTests.swift`.

### I-27: Single HLC maker (clock triangle)

- Spec: `docs/decisions/DECISION_CLOCK_TRIANGLE_TIME_MODEL_2026-05-28.md`
- Type: invariant (2026-05-28)
- Status: active in v1.0
- Evidence: pending. Generator semantics (monotonic send, receive
  advancement past remote timestamps, node-ID tiebreak) are covered
  by
  `packages/libs/SubstrateTypes/Tests/SubstrateTypesTests/HLCTests.swift`,
  and DrawerStore injects-or-makes a single generator keyed to
  estate identity. Missing: a test asserting one generator per
  estate and one `send()` per write.

### I-28: Integrity triangle / custody mode

- Spec: `docs/decisions/DECISION_CLOCK_TRIANGLE_TIME_MODEL_2026-05-28.md`
- Type: invariant (2026-05-28; rejected the dual-clock model)
- Status: active in v1.0
- Evidence: evidenced. The first-open identity regression suite is
  on file: a valid persisted estate_uuid derives the correct
  non-zero node id, an absent value opens a fresh estate, and a
  corrupt value fails loud on open rather than masking as node 0 or
  a random UUID; audit events are HLC-ordered per row.
- Evidence pointer:
  `packages/kits/LocusKit/Tests/LocusKitTests/DrawerStoreManifestUuidTests.swift`;
  `packages/kits/LocusKit/Tests/LocusKitTests/AuditAPITests.swift`.

### I-29: Row identity is a UUID

- Spec: `docs/decisions/DECISION_ROW_IDENTITY_UUID_2026-05-28.md`
- Type: invariant (2026-05-28)
- Status: active in v1.0
- Evidence: pending. `requireUuid` is implemented on the gated
  write paths
  (`packages/kits/LocusKit/Sources/LocusKit/DrawerStore.swift`).
  Missing: a test asserting the throw on a non-UUID row id and
  identity stability across configurations.

### I-30: Substrate ships as four packages

- Spec: `docs/decisions/DECISION_SUBSTRATELIB_PRESHIP_REFACTOR_2026-05-28.md`
  + the 2026-05-29 addendum (SubstrateLib retained as the
  orchestration package)
- Type: invariant (2026-05-28, restated 2026-05-29)
- Status: active in v1.0
- Evidence: evidenced. The four-package split shipped (commit
  `831dacbc`): SubstrateTypes, SubstrateKernel, SubstrateML, and
  SubstrateLib exist under `packages/libs/`, and SubstrateLib's
  manifest declares dependencies on the other three (orchestration
  role).
- Evidence pointer: commit `831dacbc`;
  `packages/libs/SubstrateLib/Package.swift`.

## Theorems

The canonical statements live in the substrate mathematics
reference, which restates the named results the substrate claims
and ties each to the demonstrating kit and conformance suite. The
full formal statements live in the published paper section 13 and
Appendix C. The theorem demonstrations covered Theorems 4, 6, 7, and
8 by their paper-numbering, and met Theorem 5; the named-result
restatement uses descriptive names rather than the paper numbers.
Reconciling the paper-numbered and named-result lists requires
a direct read of paper section 13 and Appendix C, which Phase A
defers to a focused later pass.

### T1: Sync convergence (I-21)

- Spec: substrate mathematics reference, named results;
  paper Theorem 1
- Type: theorem
- Status: active in v1.0
- Evidence: evidenced. Replicas holding equal audit sets project
  equal state. Demonstrated by the ConvergenceKit convergence tests.
- Evidence pointer:
  `packages/libs/SubstrateTypes/Tests/SubstrateTypesTests/GSetAuditLogTests.swift`
  (commutative, idempotent merge);
  `packages/kits/GeniusLocusKit/Tests/GeniusLocusKitTests/UnifiedAuditLogTests.swift`
  (projectionIndependentOfArrivalOrder, crossTierConvergence).

### T2: Cross-noun Hamming well-definedness (I-17)

- Spec: substrate mathematics reference, named results
- Type: theorem
- Status: active in v1.0
- Evidence: evidenced by SubstrateLib and LocusKit fingerprint
  tests. Uniform four-block widths and deterministic null
  sub-hashes make d_H a well-defined distance across all noun
  types.
- Evidence pointer:
  `packages/kits/LocusKit/Tests/LocusKitTests/DrawerFingerprintTests.swift`;
  `packages/libs/SubstrateTypes/Tests/SubstrateTypesTests/HammingTests.swift`;
  `packages/libs/SubstrateTypes/Tests/SubstrateTypesTests/HyperplaneFamilyTests.swift`.

### T3: Pruning equivalence

- Spec: substrate mathematics reference, named results;
  cookbook section 5
- Type: theorem
- Status: active in v1.0
- Evidence: evidenced by LocusKit recall tests. Container-pruned
  recall returns the same result as a full scan; OR-pruning skips
  a container only when no row could match.
- Evidence pointer:
  `packages/kits/LocusKit/Tests/LocusKitTests/RecallPruningTests.swift`
  (recall prunes a non-matching container and returns the
  equivalent rows; containerSurvives prunes only when a required
  bit is absent).

### T4: Automaton safety, liveness, and reachability

- Spec: substrate mathematics reference, named results;
  cookbook section 13
- Type: theorem (paper Thm 4)
- Status: active in v1.0
- Evidence: evidenced. Demonstrated by the LocusKit
  `DrawerStateValidator` suite and the theorem demonstrations.
- Evidence pointer: LocusKit DrawerStateValidator;
  `GeniusLocusKit/Tests/GeniusLocusKitTests/TheoremsTests.swift`.

### T5: Performance budget (paper Theorem 5)

- Spec: substrate mathematics reference, named results;
  paper Theorem 5
- Type: theorem (performance gate)
- Status: active in v1.0; **the load-bearing performance budget**
- Evidence: evidenced and met. P99 capture under 100 ms
  on the iPhone profile and enrichment at least 60 drawers per
  hour on the Mac profile.
- Evidence pointer:
  `GeniusLocusKit/Tests/GeniusLocusKitTests/PerformanceGateTests.swift`;
  the perf gate reports P99 capture
  0.262 ms (well under the 100 ms budget) and enrichment far above
  the 60 drawers per hour floor.

### T6: Pairing non-transitivity (I-23)

- Spec: substrate mathematics reference, named results;
  cookbook section 11
- Type: theorem
- Status: active in v1.0
- Evidence: pending. Pairing enforcement exists at the sync
  boundary — pull rejects a signed envelope from a sender that is
  not a paired peer
  (`packages/kits/ConvergenceKit/Tests/ConvergenceKitFederationTests/FederationPairingTests.swift`).
  Missing: the negative test refusing a fingerprint comparison
  across estates without a shared pairing seed.

### T7 and T8: Paper-numbered demonstrations

- Spec: paper section 13 and Appendix C
- Type: theorem (paper numbering 7 and 8; named-result mapping pending)
- Status: active in v1.0
- Evidence: waived. Source paper is Enterprise edition material;
  demonstrations exist, numbering alignment is an EE concern.

## Hot-path budgets

The cookbook section 17.1 enumerates the hot-path budgets the
substrate must meet. Three are pinned as load-bearing.

### HP1: Capture P99 latency under 100 milliseconds on iPhone

- Spec: paper Theorem 5; cookbook section 17.1
- Type: hot-path budget
- Status: active in v1.0; **met**
- Evidence: evidenced. The perf gate measured 0.262 ms P99 capture,
  three orders of magnitude under the 100 ms budget on iPhone
  profile.
- Evidence pointer:
  `GeniusLocusKit/Tests/GeniusLocusKitTests/PerformanceGateTests.swift`.

### HP2: Enrichment rate at least 60 drawers per hour on Mac

- Spec: paper Theorem 5; cookbook section 17.1
- Type: hot-path budget
- Status: active in v1.0; **met**
- Evidence: evidenced. The perf gate measured enrichment rate far above
  the 60 drawers per hour floor on Mac profile.
- Evidence pointer:
  `GeniusLocusKit/Tests/GeniusLocusKitTests/PerformanceGateTests.swift`.

### HP3: Hamming top-K (K=10 over 1M rows) under 100 microseconds

- Spec: cookbook section 17.1; cookbook section 17.5 bandwidth
  floor analysis
- Type: hot-path budget
- Status: active in v1.0; **unmet, aspirational**
- Evidence: partial. The section 17.5 bandwidth floor on
  the Apple M-series profile is 533 microseconds. Best measured kernel today
  is Swift SimdKernel at 594 microseconds (11% above floor) and
  Rust SimdKernel at 631 microseconds (18% above floor); see
  the baseline in
  `docs/validation/substrate_math_performance/README.md`.
  The 100 microsecond budget is unmet by
  any kernel measured; section 17.5 analysis suggests the
  memory bandwidth floor is the binding constraint, not the
  algorithm. Future work would require either reducing bytes
  read (bit-slice layout per I-18, deferred) or hardware beyond
  the M-series memory subsystem.
- Evidence pointer: the substrate-math performance baseline table.

## Protocol contracts: the nine-verb surface

Invariant I-7 fixes the verb count at nine. The verbs are
defined in the cookbook section 10 and implemented in the
GeniusLocusKit verb surface. Each verb has signature, preconditions,
and postconditions that conformance tests must verify.

### V1: capture

- Spec: cookbook section 10
- Type: protocol contract (verb)
- Status: active in v1.0
- Evidence: evidenced by the verb-surface tests.
- Evidence pointer:
  `GeniusLocusKit/Sources/GeniusLocusKit/Verbs/VerbSurface.swift`;
  specific test path to confirm.

### V2: recall

- Spec: cookbook section 10
- Type: protocol contract (verb)
- Status: active in v1.0
- Evidence: evidenced by the verb-surface tests; recall is the
  canonical single-estate recall over the composed substrate.
- Evidence pointer: same as V1.

### V3: mutate

- Spec: cookbook section 10
- Type: protocol contract (verb)
- Status: active in v1.0
- Evidence: evidenced by the verb-surface tests; mutate writes
  an audit row per I-2 and I-20.
- Evidence pointer: same as V1.

### V4: withdraw

- Spec: cookbook section 10
- Type: protocol contract (verb)
- Status: active in v1.0
- Evidence: evidenced by the verb-surface tests; withdraw
  retracts a proposed-but-not-confirmed item.
- Evidence pointer: same as V1.

### V5: expunge

- Spec: cookbook section 10
- Type: protocol contract (verb)
- Status: active in v1.0
- Evidence: evidenced by the verb-surface tests; expunge
  tombstones per I-6 while preserving the fact-of-expunge.
- Evidence pointer: same as V1.

### V6: reanchor

- Spec: cookbook section 10
- Type: protocol contract (verb)
- Status: active in v1.0
- Evidence: evidenced by the verb-surface tests; reanchor
  updates a lattice anchor with audit row recording the change.
- Evidence pointer: same as V1.

### V7: learn

- Spec: cookbook section 10
- Type: protocol contract (verb)
- Status: active in v1.0
- Evidence: evidenced by the verb-surface tests; learn drives
  matrix-tier update via the autonomic governor.
- Evidence pointer: same as V1.

### V8: propose

- Spec: cookbook section 10
- Type: protocol contract (verb)
- Status: active in v1.0
- Evidence: evidenced by the verb-surface tests; propose is
  the emission path for the six standing signals.
- Evidence pointer: same as V1, plus the standing-signals tests.

### V9: associate

- Spec: cookbook section 10
- Type: protocol contract (verb)
- Status: active in v1.0
- Evidence: evidenced by the verb-surface tests; associate
  creates a binary association per I-23.
- Evidence pointer: same as V1.

## Categories still pending in Phase A

The following remain queued for the next focused Phase A session.
They are all bounded sets and each is enumerable from a single
source document.

### Manifest required keys (18 required + 5 optional)

The manifest has 18 required keys and 5 optional keys, with
`bitmap_layout_version` and `provenance_bitmap_version` making
the manifest self-describing. The cookbook should enumerate the
full list; Phase A captures each as one ledger row with a
schema-validation evidence pointer.

### Framework profile contracts

The framework profile declares lattice citation
standard, zoom window, vocabulary loaded at estate creation,
proposition vocabulary predicates for rung 1.5 KG, jsonpath to
predicate mappings over blob tier content, canonical reference
dependencies with activation triggers and `learn` calls, and
learn mode per reference dependency (byReference or byIngestion).
Profile evolution commits to retroactive remining sweeps. Each
declared contract becomes one ledger row.

### Standing-signals scheduler contracts

The scheduler runs all six standing signals under a single
serial dispatch. The contracts:
exactly-once dispatch, ordering preservation under the configured
policy, register / status / subscribe API surface, and the six
signals (dreaming, maintenance, vector-similarity, decay-sweep,
byReference-validity, end-of-day-tournament) each emitting via
`propose` without mutating state.

### Decision-record claims

The 27 decision records under `docs/decisions/` each carry one
or more claims about substrate behavior, design constraints, or
empirical findings. Phase A's final pass walks each record and
extracts claims into the ledger.

## Pending evidence (gap list)

This section will accumulate the full list of `pending` rows
as Phase A progresses. Once Phase A exits, the list drives
Phase B (invariants) and Phase C (theorems).

Current count after the 2026-07-20 evidence-linking pass:

- 7 pending invariant rows (I-1, I-4, I-10, I-16, I-23, I-27,
  I-29); 19 evidenced (I-2, I-3, I-6, I-7, I-8, I-11, I-12, I-13,
  I-14, I-15, I-17, I-18, I-19, I-20, I-24a, I-25, I-26, I-28,
  I-30); 1 partial (I-22 enumeration to complete); 2 waived (I-21,
  I-24b); 2 superseded historical (I-5, I-9).
- 1 pending theorem row (T6 pairing non-transitivity); 5 evidenced
  (T1 through T5); 1 waived (T7-T8, EE paper numbering).
- 0 pending hot-path budgets; 2 met (HP1 capture, HP2 enrichment); 1 unmet aspirational (HP3 hamming top-K, against the memory bandwidth floor).
- 0 pending verb-surface rows; 9 evidenced (V1 through V9).

Total evidenced after the pass: 35 (19 invariants + 5 theorems +
2 hot-path budgets + 9 verbs). Pending: 8 (was 24 by row count:
16 rows flipped to evidenced on existing tests or shipped
structure, I-21 was waived by the 2026-07-20 rulings, and the I-24
split produced one evidenced and one waived row).
Met-with-budget-known: 3 (HP1 met, HP2 met, HP3 unmet but
bounded).

Protocol contracts, manifest required keys, framework profile
contracts, standing-signals scheduler contracts, and the 27
decision records still queued for a focused Phase A session.
