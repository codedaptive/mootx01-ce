---
status: in_progress
created: 2026-05-22
last_updated: 2026-06-14
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
| Invariants (I-1 through I-30)         | 30    | 24        | A first batch done; I-25..I-30 (2026-05-28 decisions) added, evidence pending |
| Theorems (named results, section 14)  | 7     | 7         | A second batch done (paper numbering reconciliation deferred) |
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

- Spec: `docs/reference/GENIUSLOCUS_ARCHITECTURE_SPEC.md` line 70
- Type: invariant
- Status: active in v1.0
- Evidence: pending. Expected location: a Swift test under
  `Tests/GeniusLocusKitTests/` that attempts mutation of a
  rung-1 column post-capture and asserts failure. The
  row-immutability contract is committed; exact test path to
  confirm.

### I-2: All bitmap mutations write audit rows

- Spec: `docs/reference/GENIUSLOCUS_ARCHITECTURE_SPEC.md` line 72
- Type: invariant (formalized by I-20 as G-Set CRDT)
- Status: active in v1.0; co-active with I-20
- Evidence: pending. The unified audit log with per-estate
  G-Set folding is implemented; the negative test
  surface is in those test files. Confirm path.

### I-3: The substrate accepts no `secret + public` combination

- Spec: `docs/reference/GENIUSLOCUS_ARCHITECTURE_SPEC.md` line 74
- Type: invariant (subsumed by I-22's forbidden combinations enumeration)
- Status: active in v1.0; co-active with I-22
- Evidence: pending. The maintenance-daemon scan and the verb
  layer rejection are both required surfaces. The maintenance
  scan runs via the standing signal; verb-layer rejection
  should be in the verb-surface tests.

### I-4: Every model-generated rung carries `model_id` and `model_version`

- Spec: `docs/reference/GENIUSLOCUS_ARCHITECTURE_SPEC.md` line 76
- Type: invariant
- Status: active in v1.0
- Evidence: pending. Per-rung model identification is a row
  schema property; the negative test would attempt to write a
  rung 2/3/4 without model_id and assert failure.

### I-5: Every drawer carries a lattice anchor (superseded)

- Spec: `docs/reference/GENIUSLOCUS_ARCHITECTURE_SPEC.md` line 78
- Type: invariant
- Status: superseded by I-16 (universal lattice anchor extends
  this from drawer-only to all noun types)
- Evidence: historical; the active version's evidence is
  under I-16.

### I-6: Audit rows can be tombstoned but not modified

- Spec: `docs/reference/GENIUSLOCUS_ARCHITECTURE_SPEC.md` line 80
- Type: invariant
- Status: active in v1.0
- Evidence: pending. Only the `expunge` verb mutates audit
  rows. Negative test attempts an audit-row update via any
  other path and asserts failure. The expunge-tombstoning
  positive test confirms expunge does work as specified.

### I-7: The verb count is fixed at nine

- Spec: `docs/reference/GENIUSLOCUS_ARCHITECTURE_SPEC.md` line 82
- Type: invariant
- Status: active in v1.0
- Evidence: pending. The nine-verb surface and AriaLexiconLib
  conformance are implemented. The verb
  count is a static contract; the conformance test should
  assert exactly nine verbs by name.

### I-8: The adjective category count is fixed at four

- Spec: `docs/reference/GENIUSLOCUS_ARCHITECTURE_SPEC.md` line 84
- Type: invariant
- Status: active in v1.0
- Evidence: pending. State, trust, sensitivity, exportability.
  Static contract; the conformance test asserts exactly four
  named categories.

### I-9: Field width is 4 bits in the bitmap tier (superseded)

- Spec: `docs/reference/GENIUSLOCUS_ARCHITECTURE_SPEC.md` line 86
- Type: invariant
- Status: superseded by I-15 (6-bit field-width floor)
- Evidence: historical; the active version's evidence is
  under I-15.

### I-10: Every bitmap field reserves at least 30% growth space

- Spec: `docs/reference/GENIUSLOCUS_ARCHITECTURE_SPEC.md` line 88
- Type: invariant
- Status: active in v1.0
- Evidence: pending. The check is a static analysis over the
  manifest's bitmap layout; a unit test asserts each field's
  used-values count is at most 70% of its capacity.

### I-11: Bitmap layouts within a published version are stable

- Spec: `docs/reference/GENIUSLOCUS_ARCHITECTURE_SPEC.md` line 90
- Type: invariant
- Status: active in v1.0
- Evidence: pending. The negative test attempts a layout
  mutation under a published manifest and asserts failure;
  the positive test confirms `bitmap_layout_version` bump
  produces a new manifest version.

### I-12: The substrate provides storage; applications do not bring their own

- Spec: `docs/reference/GENIUSLOCUS_ARCHITECTURE_SPEC.md` line 92
- Type: invariant
- Status: active in v1.0
- Evidence: evidenced by composition. GLK depends on LocusKit,
  VectorKit, and CorpusKit per the kit-composition test
  surfaces; no external storage adapter exists.
- Evidence pointer: the kit-composition tests. To confirm
  specific test path.

### I-13: Federation is not a substrate concern

- Spec: `docs/reference/GENIUSLOCUS_ARCHITECTURE_SPEC.md` line 94
- Type: invariant
- Status: active in v1.0
- Evidence: evidenced by absence. The substrate kit graph
  contains no network or RPC surface. Confirmed by
  inspection; a structural test enumerating GLK's exported
  symbols and asserting none reach outside the local kit
  graph would formalize this.

### I-14: Provenance is set at write and mutated only via the audit-recorded path

- Spec: `docs/reference/GENIUSLOCUS_ARCHITECTURE_SPEC.md` line 96
- Type: invariant
- Status: active in v1.0
- Evidence: pending. The verb-layer test surface should show
  that `capture`, `propose`, `learn`, and `associate` set
  provenance; that `mutate_bitmap` writes an audit row for
  any provenance change; that no other path mutates
  provenance.

### I-15: 6-bit field-width floor

- Spec: `docs/engineering/GENIUSLOCUS_ENGINEERING_COOKBOOK.md` line 163
- Type: invariant (supersedes I-9)
- Status: active in v1.0
- Evidence: pending. Bitmap field widths now floor at 6 bits;
  the unit test asserts manifest layout conformance.

### I-16: Every row has a lattice anchor

- Spec: `docs/engineering/GENIUSLOCUS_ENGINEERING_COOKBOOK.md` line 424
- Type: invariant (supersedes I-5, extends drawer-only to universal)
- Status: active in v1.0
- Evidence: pending. Drawers, tunnels, associations, all noun
  types carry a lattice anchor. Test asserts schema-level
  presence of `lattice_anchor` across all noun row types.

### I-17: Cross-noun fingerprint compatibility

- Spec: `docs/engineering/GENIUSLOCUS_ENGINEERING_COOKBOOK.md` line 713
- Type: invariant
- Status: active in v1.0
- Evidence: pending. All noun fingerprints share a compatible
  256-bit format; cross-noun Hamming distance is meaningful.
  Test asserts fingerprint shape conformance across nouns.

### I-18: Runtime view is bit-sliced 3D tensor

- Spec: `docs/engineering/GENIUSLOCUS_ENGINEERING_COOKBOOK.md` line 803
- Type: invariant (constitutional working-set layout)
- Status: active in v1.0
- Evidence: pending. Working set is held as memory-mapped
  bit-slice arrays. Test asserts the runtime view's shape and
  the round-trip from row-format to bit-slice and back.

### I-19: Kernel layer is portable across SIMD families

- Spec: `docs/engineering/GENIUSLOCUS_ENGINEERING_COOKBOOK.md` line 872
- Type: invariant
- Status: active in v1.0
- Evidence: evidenced by the four-cell conformance gate and
  the cross-language byte-equality test for all 24 primitives.
- Evidence pointer: the four-way conformance
  matrix; current as of develop tip `7da4413`.

### I-20: Audit log is a Grow-Only Set CRDT

- Spec: `docs/engineering/GENIUSLOCUS_ENGINEERING_COOKBOOK.md` line 952
- Type: invariant (formalizes I-2 with CRDT properties)
- Status: active in v1.0; co-active with I-2
- Evidence: evidenced by the unified audit log
  implementation with per-estate G-Set folding.
- Evidence pointer: commit `8a191ff`; specific test
  path to confirm.

### I-21: Sync convergence

- Spec: `docs/engineering/GENIUSLOCUS_ENGINEERING_COOKBOOK.md` line 1007
- Type: invariant
- Status: active in v1.0
- Evidence: pending. Given two replicas R_A and R_B of the
  same estate, convergence under bidirectional sync. The
  negative test injects divergent histories and asserts
  convergence on merge.

### I-22: Forbidden state-combination invariants

- Spec: `docs/engineering/GENIUSLOCUS_ENGINEERING_COOKBOOK.md` line 1780
- Type: invariant (enumeration of forbidden combinations including the original I-3)
- Status: active in v1.0
- Evidence: partial. The `secret + public` case (subsuming
  the original I-3) is covered alongside any additional combinations
  the cookbook enumerates. Phase A to extract the full list
  in a subsequent pass.

### I-23: Pairing algebra (binary arity in v1)

- Spec: `docs/engineering/GENIUSLOCUS_ENGINEERING_COOKBOOK.md` line 2234
- Type: invariant
- Status: active in v1.0
- Evidence: pending. Associations are binary in v1; n-ary
  deferred to a future AssociationCluster noun. Test asserts
  the row schema rejects n-ary associations.

### I-24: Tier aggregation provides (ε, δ)-DP

- Spec: `docs/engineering/GENIUSLOCUS_ENGINEERING_COOKBOOK.md` line 2352
- Type: invariant
- Status: active in v1.0
- Evidence: pending. Tier aggregation provides differential
  privacy with declared (ε, δ) bounds. The test asserts the
  DP budget tracking and the aggregation output's noise
  distribution.

### I-25: One implementation per atomic

- Spec: `docs/engineering/GENIUSLOCUS_ENGINEERING_COOKBOOK.md` §1.4;
  `docs/concepts/MOOTX01_AND_ARIA_CANON.md` ("the substrate owns the atomics")
- Type: invariant (2026-05-28)
- Status: active in v1.0
- Evidence: pending. Every substrate atomic lives in SubstrateLib
  and is consumed by name; no kit reimplements the math. Negative
  test: a grep/structural check that no kit source reimplements a
  listed primitive. The 2026-05-27 atomic-centralization cascade
  (BitField, SHA256, HLC) is the positive evidence; confirm test
  paths in the LocusKit/GLK suites.

### I-26: Capture writes a sealed genesis event

- Spec: `docs/decisions/DECISION_CAPTURE_GENESIS_EVENT_2026-05-28.md`
- Type: invariant (2026-05-28; retired the bitmap_audit /
  provenance_audit tables)
- Status: active in v1.0
- Evidence: pending. Capture routes through `AuditGate.admit` with
  `prior = nil`, sealing a genesis event before any mutation.
  Positive test exists in the LocusKit audit suite
  (`auditTrail` after capture returns the genesis event); confirm
  path and add the negative (no bare-INSERT capture path).

### I-27: Single HLC maker (clock triangle)

- Spec: `docs/decisions/DECISION_CLOCK_TRIANGLE_TIME_MODEL_2026-05-28.md`
- Type: invariant (2026-05-28)
- Status: active in v1.0
- Evidence: pending. The top-ranking entity makes the clock;
  holders receive it (`HLCGenerator` injected vs made). Test
  asserts one generator per estate and one `send()` per write.

### I-28: Integrity triangle / custody mode

- Spec: `docs/decisions/DECISION_CLOCK_TRIANGLE_TIME_MODEL_2026-05-28.md`
- Type: invariant (2026-05-28; rejected the dual-clock model)
- Status: active in v1.0
- Evidence: pending. The audit chain, the HLC, and the estate
  identity form the integrity triangle; custody mode governs who
  may stamp. Test asserts events seal estate uuid + HLC + row id
  consistently (see the first-open identity regression test in
  the LocusKit DrawerStore suites).

### I-29: Row identity is a UUID

- Spec: `docs/decisions/DECISION_ROW_IDENTITY_UUID_2026-05-28.md`
- Type: invariant (2026-05-28)
- Status: active in v1.0
- Evidence: pending. Every gated write requires a UUID row id;
  a non-UUID id fails loudly (`requireUuid`). Test asserts the
  throw on a non-UUID id and identity stability across
  configurations.

### I-30: Substrate ships as four packages

- Spec: `docs/decisions/DECISION_SUBSTRATELIB_PRESHIP_REFACTOR_2026-05-28.md`
  + the 2026-05-29 addendum (SubstrateLib retained as the
  orchestration package)
- Type: invariant (2026-05-28, restated 2026-05-29)
- Status: active in v1.0
- Evidence: pending. The substrate is SubstrateTypes,
  SubstrateKernel, SubstrateML, and SubstrateLib (orchestration).
  Structural test: each symbol resolves to exactly one package;
  SubstrateLib depends on the other three. Migration in progress.

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
- Evidence pointer: ConvergenceKit tests; specific path to confirm.

### T2: Cross-noun Hamming well-definedness (I-17)

- Spec: substrate mathematics reference, named results
- Type: theorem
- Status: active in v1.0
- Evidence: evidenced by SubstrateLib and LocusKit fingerprint
  tests. Uniform four-block widths and deterministic null
  sub-hashes make d_H a well-defined distance across all noun
  types.
- Evidence pointer: SubstrateLib and LocusKit fingerprint tests;
  specific paths to confirm.

### T3: Pruning equivalence

- Spec: substrate mathematics reference, named results;
  cookbook section 5
- Type: theorem
- Status: active in v1.0
- Evidence: evidenced by LocusKit recall tests. Container-pruned
  recall returns the same result as a full scan; OR-pruning skips
  a container only when no row could match.
- Evidence pointer: LocusKit recall tests; specific path to
  confirm.

### T4: Automaton safety, liveness, and reachability

- Spec: substrate mathematics reference, named results;
  cookbook section 13
- Type: theorem (paper Thm 4)
- Status: active in v1.0
- Evidence: evidenced. Demonstrated by the LocusKit
  `DrawerStateValidator` suite and the theorem demonstrations.
- Evidence pointer: LocusKit DrawerStateValidator;
  `GeniusLocusKit/Tests/GeniusLocusKitTests/TheoremsTests.swift`
  at commit `fa27ca2`.

### T5: Performance budget (paper Theorem 5)

- Spec: substrate mathematics reference, named results;
  paper Theorem 5
- Type: theorem (performance gate)
- Status: active in v1.0; **the load-bearing performance budget**
- Evidence: evidenced and met. P99 capture under 100 ms
  on the iPhone profile and enrichment at least 60 drawers per
  hour on the Mac profile.
- Evidence pointer:
  `GeniusLocusKit/Tests/GeniusLocusKitTests/PerformanceGateTests.swift`
  at commit `fa27ca2`; the perf gate reports P99 capture
  0.262 ms (well under the 100 ms budget) and enrichment far above
  the 60 drawers per hour floor.

### T6: Pairing non-transitivity (I-23)

- Spec: substrate mathematics reference, named results;
  cookbook section 11
- Type: theorem
- Status: active in v1.0
- Evidence: pending. No implicit cross-perimeter comparability;
  enforced by refusing unshared-seed comparisons. The negative
  test attempts a comparison across estates without a shared
  pairing seed and asserts refusal.

### T7 and T8: Paper-numbered demonstrations

- Spec: paper section 13 and Appendix C
- Type: theorem (paper numbering 7 and 8; named-result mapping pending)
- Status: active in v1.0
- Evidence: evidenced by the theorem demonstrations.
  Statements require paper section 13 read to align with the
  named-result list. Phase A defers full statement
  capture to a focused later pass.
- Evidence pointer:
  `GeniusLocusKit/Tests/GeniusLocusKitTests/TheoremsTests.swift`
  at commit `fa27ca2`.

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
  `GeniusLocusKit/Tests/GeniusLocusKitTests/PerformanceGateTests.swift`
  at commit `fa27ca2`.

### HP2: Enrichment rate at least 60 drawers per hour on Mac

- Spec: paper Theorem 5; cookbook section 17.1
- Type: hot-path budget
- Status: active in v1.0; **met**
- Evidence: evidenced. The perf gate measured enrichment rate far above
  the 60 drawers per hour floor on Mac profile.
- Evidence pointer:
  `GeniusLocusKit/Tests/GeniusLocusKitTests/PerformanceGateTests.swift`
  at commit `fa27ca2`.

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
  `docs/validation/substrate_math_performance/README.md`
  at commit `7da4413`. The 100 microsecond budget is unmet by
  any kernel measured; section 17.5 analysis suggests the
  memory bandwidth floor is the binding constraint, not the
  algorithm. Future work would require either reducing bytes
  read (bit-slice layout per I-18, deferred) or hardware beyond
  the M-series memory subsystem.
- Evidence pointer: the substrate-math performance baseline table.

## Protocol contracts: the nine-verb surface

Invariant I-7 fixes the verb count at nine. The verbs are
defined in the cookbook section 10 and implemented at commit
`3c34a9a`. Each verb has signature, preconditions,
and postconditions that conformance tests must verify.

### V1: capture

- Spec: cookbook section 10
- Type: protocol contract (verb)
- Status: active in v1.0
- Evidence: evidenced by the verb-surface tests.
- Evidence pointer:
  `GeniusLocusKit/Sources/GeniusLocusKit/Verbs/VerbSurface.swift`
  and verb tests at commit `3c34a9a`; specific test path to
  confirm.

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
- Evidence pointer: same as V1; the standing-signals tests at
  commit `1809eda`.

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
serial dispatch (commit `aae7d5d`). The contracts:
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

Current count after second batch:

- 18 pending invariant rows; 2 evidenced (I-12, I-19); 2 partial (I-3 by I-22 subsumption, I-22 enumeration to complete); 2 superseded historical (I-5, I-9).
- 1 pending theorem row (T6 pairing non-transitivity); 6 evidenced (T1, T2, T3, T4, T5, T7-T8).
- 0 pending hot-path budgets; 2 met (HP1 capture, HP2 enrichment); 1 unmet aspirational (HP3 hamming top-K, against the memory bandwidth floor).
- 0 pending verb-surface rows; 9 evidenced (V1 through V9).

Total evidenced after batch 2: 22 (was 2). Pending: 19 (was 18; T6 added). Met-with-budget-known: 3 (HP1 met, HP2 met, HP3 unmet but bounded).

Protocol contracts, manifest required keys, framework profile
contracts, standing-signals scheduler contracts, and the 27
decision records still queued for a focused Phase A session.
