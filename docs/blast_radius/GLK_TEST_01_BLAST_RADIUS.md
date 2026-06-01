# Blast Radius Report — GLK-TEST-01 (GeniusLocusKit library test leg → swift-testing)

Mission: `docs/missions/inflight/MISSION_GLK_TEST_01.md`
Stream: gl · Branch: `stream/gl-geniuslocuskit-test-leg`
Tier: **net-new / test-only** — no production source touched. Converts 20 XCTest
files to swift-testing and adds per-type gap suites. No-cap tier.

## Status: PROCEED — no RESCOPE required

Smythe pre-flight verdict: **YELLOW** (`docs/blast_radius/GLK_TEST_01_PREFLIGHT.md`).
Zero blockers. Two documentation inaccuracies in the mission prose — non-blocking,
reconciled below. Both legs green at baseline.

Baseline test counts (verified, branch `stream/gl-geniuslocuskit-test-leg`):
- Swift `swift test`: exit 0. **XCTest runner: 148 executed, 0 failures.**
  **swift-testing runner: "0 tests in 0 suites"** — the bug this mission fixes.
  20 files, all `import XCTest`, zero `import Testing`.
- Rust `cargo test`: exit 0. **99 passed, 0 failed** (13 unit + 86 integration).

## MUST_UPDATE list

| File | In mission table? | Change | Classification |
|---|---|---|---|
| `Tests/GeniusLocusKitTests/CompositionConformanceTests.swift` | yes | XCTest → swift-testing | MUST_UPDATE |
| `Tests/GeniusLocusKitTests/CoordinatorLifecycleTests.swift` | yes | XCTest → swift-testing | MUST_UPDATE |
| `Tests/GeniusLocusKitTests/CrossEstateFederationTests.swift` | yes | XCTest → swift-testing | MUST_UPDATE |
| `Tests/GeniusLocusKitTests/CrossEstateOverlapTests.swift` | yes | XCTest → swift-testing | MUST_UPDATE |
| `Tests/GeniusLocusKitTests/ENC02_DecayDerivedKeyTests.swift` | yes | XCTest → swift-testing | MUST_UPDATE |
| `Tests/GeniusLocusKitTests/EstateIsolationTests.swift` | yes | XCTest → swift-testing | MUST_UPDATE |
| `Tests/GeniusLocusKitTests/GLK_COW_01_BranchTests.swift` | yes | XCTest → swift-testing | MUST_UPDATE |
| `Tests/GeniusLocusKitTests/GLK_MIG_02_MigrationTests.swift` | yes | XCTest → swift-testing | MUST_UPDATE |
| `Tests/GeniusLocusKitTests/GLK03_AuditIntegrationTests.swift` | yes | XCTest → swift-testing | MUST_UPDATE |
| `Tests/GeniusLocusKitTests/GRT_AuditEmissionTests.swift` | yes | XCTest → swift-testing | MUST_UPDATE |
| `Tests/GeniusLocusKitTests/GRT01_GrantTests.swift` | yes | XCTest → swift-testing | MUST_UPDATE |
| `Tests/GeniusLocusKitTests/MatrixTierTests.swift` | yes | XCTest → swift-testing | MUST_UPDATE |
| `Tests/GeniusLocusKitTests/PerformanceGateTests.swift` | yes | XCTest → swift-testing | MUST_UPDATE |
| `Tests/GeniusLocusKitTests/PromotionTargetTests.swift` | yes | XCTest → swift-testing | MUST_UPDATE |
| `Tests/GeniusLocusKitTests/StandingSignalSchedulerTests.swift` | yes | XCTest → swift-testing | MUST_UPDATE |
| `Tests/GeniusLocusKitTests/StandingSignalsTests.swift` | yes | XCTest → swift-testing | MUST_UPDATE |
| `Tests/GeniusLocusKitTests/TheoremsTests.swift` | yes | XCTest → swift-testing | MUST_UPDATE |
| `Tests/GeniusLocusKitTests/TrainingDaemonTests.swift` | yes | XCTest → swift-testing | MUST_UPDATE |
| `Tests/GeniusLocusKitTests/UnifiedAuditLogTests.swift` | yes | XCTest → swift-testing | MUST_UPDATE |
| `Tests/GeniusLocusKitTests/VerbSurfaceTests.swift` | yes | XCTest → swift-testing | MUST_UPDATE |
| `Tests/GeniusLocusKitTests/` (new per-type suites — TBD by Bilby after reading each file) | yes (CREATE) | new swift-testing suites for uncovered source types | MUST_UPDATE (new) |
| `packages/kits/GeniusLocusKit/Package.swift` | yes (conditional) | **no change** — swift-testing bundled in Swift 6.3.2; `import Testing` resolves with no package dep. Conditional "only if absent" → absent AND not needed. | NOT MODIFIED (conditional no-op) |

## Reconciled method count

**True @Test-eligible method count: 148** (not 146 as the mission states).

Mission prose inaccuracy: the mission says "146 XCTest methods." The XCTest
runner reports "Executed 148 tests." `grep -c "func test"` across all 20 files
sums to 148. No helpers, no lifecycle overrides — both "extra" methods are
legitimate test functions in `PerformanceGateTests.swift`.

Bilby must preserve all **148** assertions.

### Per-file method counts (all @Test-eligible)

| File | Methods |
|---|---|
| `VerbSurfaceTests.swift` | 16 |
| `UnifiedAuditLogTests.swift` | 16 |
| `StandingSignalSchedulerTests.swift` | 13 |
| `TrainingDaemonTests.swift` | 11 |
| `MatrixTierTests.swift` | 11 |
| `GLK_COW_01_BranchTests.swift` | 10 |
| `GLK_MIG_02_MigrationTests.swift` | 9 |
| `StandingSignalsTests.swift` | 8 |
| `GRT01_GrantTests.swift` | 8 |
| `GLK03_AuditIntegrationTests.swift` | 7 |
| `ENC02_DecayDerivedKeyTests.swift` | 7 |
| `CrossEstateFederationTests.swift` | 6 |
| `TheoremsTests.swift` | 4 |
| `PromotionTargetTests.swift` | 4 |
| `CrossEstateOverlapTests.swift` | 4 |
| `CoordinatorLifecycleTests.swift` | 4 |
| `CompositionConformanceTests.swift` | 4 |
| `GRT_AuditEmissionTests.swift` | 3 |
| `PerformanceGateTests.swift` | 2 |
| `EstateIsolationTests.swift` | 1 |
| **TOTAL** | **148** |

## Source-type → test-file map (46 source files)

All paths relative to `packages/kits/GeniusLocusKit/Sources/GeniusLocusKit/`.

| Source group | Source file | Peer test file | Coverage |
|---|---|---|---|
| `Audit/` | `AuditBridge.swift` | `GLK03_AuditIntegrationTests.swift` | partial |
| `Audit/` | `AuditChainReport.swift` | `UnifiedAuditLogTests.swift` | partial |
| `Audit/` | `AuditChainVerifier.swift` | `UnifiedAuditLogTests.swift` | partial |
| `Audit/` | `AuditProjection.swift` | `GLK03_AuditIntegrationTests.swift` | partial |
| `Audit/` | `AuditRecovery.swift` | `UnifiedAuditLogTests.swift` | partial |
| `Audit/` | `UnifiedAuditLog.swift` | `UnifiedAuditLogTests.swift` | primary |
| `Brain/` | `ProposalKind.swift` | `StandingSignalSchedulerTests.swift` | partial |
| `Brain/` | `SignalAPI.swift` | `StandingSignalSchedulerTests.swift` | partial |
| `Brain/` | `SignalSchedule.swift` | `StandingSignalSchedulerTests.swift` | partial |
| `Brain/` | `StandingSignalScheduler.swift` | `StandingSignalSchedulerTests.swift` | primary |
| `Brain/Signals/` | `ByReferenceValiditySignal.swift` | `StandingSignalsTests.swift` | present |
| `Brain/Signals/` | `DecaySweepSignal.swift` | `StandingSignalsTests.swift` | present |
| `Brain/Signals/` | `DefaultStandingSignals.swift` | `StandingSignalsTests.swift` | primary |
| `Brain/Signals/` | `DreamingSignal.swift` | `StandingSignalsTests.swift` | present |
| `Brain/Signals/` | `EndOfDayTournamentSignal.swift` | `StandingSignalsTests.swift` | present |
| `Brain/Signals/` | `MaintenanceSignal.swift` | `StandingSignalsTests.swift` | present |
| `Brain/Signals/` | `VectorSimilaritySignal.swift` | `StandingSignalsTests.swift` | present |
| `Branches/` | `BranchHandle.swift` | `GLK_COW_01_BranchTests.swift` | present |
| `Branches/` | `BranchTypes.swift` | `GLK_COW_01_BranchTests.swift` | present |
| `Branches/` | `EstateBranch.swift` | `GLK_COW_01_BranchTests.swift` | primary |
| `Federation/` | `CrossEstateFederation.swift` | `CrossEstateFederationTests.swift` | primary |
| `Federation/` | `FederatedRecallResult.swift` | `CrossEstateFederationTests.swift` | partial |
| `Grants/` | `Grant.swift` | `GRT01_GrantTests.swift` | primary |
| `Grants/` | `GrantStore.swift` | `GRT01_GrantTests.swift` | present |
| `Grants/` | `LagrangeDecayKey.swift` | `ENC02_DecayDerivedKeyTests.swift` | primary |
| `Grants/` | `ScopeKeyVault.swift` | `GRT01_GrantTests.swift` | partial |
| `Matrix/` | `Calibration.swift` | `MatrixTierTests.swift` | partial |
| `Matrix/` | `LatentFactors.swift` | `MatrixTierTests.swift` | partial |
| `Matrix/` | `MatrixPersistence.swift` | `MatrixTierTests.swift` | partial |
| `Matrix/` | `MatrixTier.swift` | `MatrixTierTests.swift` | primary |
| `Migration/` | `ExternalCorpus.swift` | `GLK_MIG_02_MigrationTests.swift` | present |
| `Migration/` | `MigrationAPI.swift` | `GLK_MIG_02_MigrationTests.swift` | primary |
| `Migration/` | `MigrationTypes.swift` | `GLK_MIG_02_MigrationTests.swift` | present |
| `Migration/` | `ParallelRunHandle.swift` | `GLK_MIG_02_MigrationTests.swift` | present |
| `Training/` | `EnrichmentPipeline.swift` | `TrainingDaemonTests.swift` | present |
| `Training/` | `ThresholdGate.swift` | `TrainingDaemonTests.swift` | present |
| `Training/` | `TrainingDaemon.swift` | `TrainingDaemonTests.swift` | primary |
| `Verbs/` | `AriaLexiconConformance.swift` | `VerbSurfaceTests.swift` | present |
| `Verbs/` | `Frames.swift` | `VerbSurfaceTests.swift` | present |
| `Verbs/` | `VerbError.swift` | `VerbSurfaceTests.swift` | partial |
| `Verbs/` | `VerbSurface.swift` | `VerbSurfaceTests.swift` | primary |
| root | `CrossEstateRead.swift` | `CrossEstateFederationTests.swift` | partial |
| root | `EstateCoordinator.swift` | `CoordinatorLifecycleTests.swift` | primary |
| root | `EstateHandle.swift` | `CoordinatorLifecycleTests.swift` | present |
| root | `GeniusLocusKit.swift` | `CompositionConformanceTests.swift` | primary |
| root | `GeniusLocusKitError.swift` | none dedicated | GAP |

**Confirmed gaps (Part 2 candidates):**
- `GeniusLocusKitError.swift` — no dedicated error-type test. Bilby should
  add error-type assertions; lightest option is folding into
  `CoordinatorLifecycleTests` or creating `GeniusLocusKitErrorTests.swift`.
- `ProposalKind.swift` — partially covered; Rust has 2 dedicated
  `proposal_kind_*` tests in `scheduler_parity.rs`. Gap suite: fold into
  `StandingSignalSchedulerTests` or create `ProposalKindTests.swift`.
- `ScopeKeyVault.swift` — partial coverage in `GRT01_GrantTests`. Bilby
  confirms depth after reading the file.
- `FederatedRecallResult.swift` — exercised indirectly through federation
  tests. Bilby confirms per read.
- `AuditChainReport`, `AuditChainVerifier`, `AuditRecovery` — folded into
  `UnifiedAuditLogTests`. Bilby confirms per read.

## Rust parity table (99 `#[test]` functions, 12 files)

Mission inaccuracy: the mission states "13 Rust `#[test]` functions." Reality:
99 across 12 files. The 13 is the unit test binary (inline tests in `src/`).
The integration suite in `tests/` adds 86 more. All 99 pass. Bilby must confirm
parity for all 99, not just 13.

### Unit tests (`src/` inline — 13)

| Rust `#[test]` | File | Swift peer candidate |
|---|---|---|
| `co1_capture_then_recall_returns_the_row` | `src/coordinator.rs` | `VerbSurfaceTests: testCaptureThenRecall` |
| `co2_withdraw_transitions_state` | `src/coordinator.rs` | `VerbSurfaceTests: testWithdrawRoundTrip` |
| `co3_expunge_requires_confirmation` | `src/coordinator.rs` | `VerbSurfaceTests: testExpungeWithoutConfirmationRaisesGuard` |
| `co4_empty_reanchor_is_refused` | `src/coordinator.rs` | `VerbSurfaceTests: testReanchorEmptyRaisesGuard` |
| `co5_mutate_confirm_transitions_confirmation` | `src/coordinator.rs` | `VerbSurfaceTests: testMutateConfirmRoundTripTransitionsConfirmation` |
| `co5b_state_axis_mutate_is_not_supported` | `src/coordinator.rs` | `VerbSurfaceTests: testMutateStateAxisKindSurfacesNotSupported` |
| `co6_verb_on_closed_handle_is_estate_not_open` | `src/coordinator.rs` | `VerbSurfaceTests: testProposeOnStaleHandleRaisesEstateNotOpen` |
| `br1_derive_snapshots_parent` | `src/branches.rs` | `GLK_COW_01_BranchTests` |
| `br2_branch_capture_isolated_and_diffed` | `src/branches.rs` | `GLK_COW_01_BranchTests` |
| `br3_promote_moves_new_rows_and_wins` | `src/branches.rs` | `GLK_COW_01_BranchTests` |
| `br4_merge_cherry_picks` | `src/branches.rs` | `GLK_COW_01_BranchTests` |
| `br5_branch_of_branch_lineage_depth` | `src/branches.rs` | `GLK_COW_01_BranchTests` |
| `br6_discard_and_not_tracked_guard` | `src/branches.rs` | `GLK_COW_01_BranchTests` |

### Integration tests (`tests/` — 86)

#### `tests/verb_parity.rs` (10)

| Rust `#[test]` | Swift peer candidate |
|---|---|
| `verb_count_and_names_match_swift` | `VerbSurfaceTests` |
| `surface_verb_names_match_swift` | `VerbSurfaceTests` |
| `noun_count_matches_swift` | `VerbSurfaceTests` |
| `acceptance_matrix_matches_swift` | `VerbSurfaceTests` |
| `vector_rejects_every_verb` | `VerbSurfaceTests` |
| `surface_targets_are_all_accepted` | `VerbSurfaceTests` |
| `reanchor_empty_raises_guard` | `VerbSurfaceTests` |
| `expunge_without_confirmation_raises_guard` | `VerbSurfaceTests` |
| `propose_raises_not_supported` | `VerbSurfaceTests` |
| `associate_raises_not_supported` | `VerbSurfaceTests` |

#### `tests/audit_parity.rs` (15)

| Rust `#[test]` | Swift peer candidate |
|---|---|
| `sha256_abc_vector_matches_fips` | `UnifiedAuditLogTests` / `GLK03_AuditIntegrationTests` |
| `sha256_empty_vector_matches_fips` | `UnifiedAuditLogTests` |
| `entry_id_is_deterministic` | `UnifiedAuditLogTests` |
| `entry_id_differs_when_tier_differs` | `UnifiedAuditLogTests` |
| `add_is_idempotent` | `UnifiedAuditLogTests` |
| `merge_is_commutative_and_idempotent` | `UnifiedAuditLogTests` |
| `cross_tier_convergence` | `UnifiedAuditLogTests` |
| `projection_independent_of_arrival_order` | `UnifiedAuditLogTests` |
| `as_of_reconstruction_spans_both_tiers` | `UnifiedAuditLogTests` |
| `recovery_reproduces_live_projection` | `UnifiedAuditLogTests` |
| `streaming_replay_matches_batch` | `UnifiedAuditLogTests` |
| `recovery_as_of_reconstructs_historical_state` | `UnifiedAuditLogTests` |
| `withdraw_and_expunge_are_sticky_tombstones` | `UnifiedAuditLogTests` |
| `row_scoping_honors_tier` | `UnifiedAuditLogTests` |
| `hlc_lexicographic_order` | `UnifiedAuditLogTests` |

#### `tests/scheduler_parity.rs` (12)

| Rust `#[test]` | Swift peer candidate |
|---|---|
| `emission_class_tags_match_swift_vocabulary` | `StandingSignalSchedulerTests` |
| `class_tag_per_emission_matches_swift_strings` | `StandingSignalSchedulerTests` |
| `registered_signal_appears_in_status` | `StandingSignalSchedulerTests` |
| `two_due_signals_dispatch_serially_in_one_lane` | `StandingSignalSchedulerTests` |
| `diagnostic_emission_is_recorded_in_status` | `StandingSignalSchedulerTests` |
| `propose_emission_routes_through_propose_verb` | `StandingSignalSchedulerTests` |
| `associate_emission_routes_through_associate_verb` | `StandingSignalSchedulerTests` |
| `mutate_candidate_routes_through_propose` | `StandingSignalSchedulerTests` |
| `event_trigger_only_fires_on_request` | `StandingSignalSchedulerTests` |
| `subscribe_to_unknown_signal_returns_not_registered` | `StandingSignalSchedulerTests` |
| `proposal_kind_raw_value_round_trip` | `StandingSignalSchedulerTests` / gap: `ProposalKindTests` |
| `proposal_kind_unknown_label_maps_to_other` | `StandingSignalSchedulerTests` / gap: `ProposalKindTests` |

#### `tests/training_parity.rs` (11)

| Rust `#[test]` | Swift peer candidate |
|---|---|
| `provisional_default_matches_decision_record` | `TrainingDaemonTests` |
| `gate_dormant_below_threshold` | `TrainingDaemonTests` |
| `gate_active_at_threshold` | `TrainingDaemonTests` |
| `gate_ignores_read_only_verbs` | `TrainingDaemonTests` |
| `negative_threshold_clamps_to_zero_and_always_admits` | `TrainingDaemonTests` |
| `enrichment_updates_matrices_from_audit_log` | `TrainingDaemonTests` |
| `enrichment_respects_watermark` | `TrainingDaemonTests` |
| `daemon_dormant_below_threshold_does_no_work` | `TrainingDaemonTests` |
| `daemon_active_at_threshold_fires_pipeline` | `TrainingDaemonTests` |
| `daemon_crosses_threshold_between_ticks` | `TrainingDaemonTests` |
| `daemon_reset_watermark_restarts_scan` | `TrainingDaemonTests` |

#### `tests/matrix_parity.rs` (11)

| Rust `#[test]` | Swift peer candidate |
|---|---|
| `field_presence_counts_set_bits` | `MatrixTierTests` |
| `correlation_derives_from_field_presence` | `MatrixTierTests` |
| `co_occurrence_canonical_symmetric` | `MatrixTierTests` |
| `temporal_lag_bucketing` | `MatrixTierTests` |
| `rebuild_from_audit_log_equals_incremental` | `MatrixTierTests` |
| `in_memory_mode_rebuilds_but_does_not_persist` | `MatrixTierTests` |
| `snapshotted_mode_round_trips_exactly` | `MatrixTierTests` |
| `persistence_modes_agree_on_tier` | `MatrixTierTests` |
| `calibration_deflates_overconfidence` | `MatrixTierTests` |
| `nmf_approximates_input_matrix` | `MatrixTierTests` |
| `nmf_deterministic_across_runs` | `MatrixTierTests` |

#### `tests/standing_signals_parity.rs` (10)

| Rust `#[test]` | Swift peer candidate |
|---|---|
| `default_signal_names_and_cadences_match_swift_reference` | `StandingSignalsTests` |
| `default_standing_signal_names_helper_returns_canonical_order` | `StandingSignalsTests` |
| `default_standing_signal_specs_returns_six_specs_with_interval_triggers` | `StandingSignalsTests` |
| `dreaming_signal_emits_propose_and_associate` | `StandingSignalsTests` |
| `maintenance_signal_emits_two_proposes_and_one_diagnostic` | `StandingSignalsTests` |
| `vector_similarity_signal_emits_associate_and_diagnostic` | `StandingSignalsTests` |
| `decay_sweep_signal_routes_through_propose` | `StandingSignalsTests` |
| `by_reference_validity_signal_emits_propose_and_diagnostic` | `StandingSignalsTests` |
| `end_of_day_tournament_signal_emits_propose_and_diagnostic` | `StandingSignalsTests` |
| `registering_all_six_default_specs_produces_six_reports` | `StandingSignalsTests` |

#### `tests/parity.rs` (8)

| Rust `#[test]` | Swift peer candidate |
|---|---|
| `lifecycle_three_estates` | `CoordinatorLifecycleTests` |
| `close_leaves_remaining_handles_live` | `CoordinatorLifecycleTests` |
| `duplicate_open_is_rejected` | `CoordinatorLifecycleTests` |
| `overlap_routes_to_low_and_mid` | `CrossEstateOverlapTests` |
| `overlap_routes_to_high_only` | `CrossEstateOverlapTests` |
| `disjoint_region_returns_empty` | `CrossEstateOverlapTests` |
| `inverted_region_throws` | `CrossEstateOverlapTests` |
| `fan_out_returns_contribution_per_overlapping_estate` | `CrossEstateFederationTests` |

#### `tests/theorems_tests.rs` (4)

| Rust `#[test]` | Swift peer candidate |
|---|---|
| `theorem_4_model_version_upgrade_preserves_every_transition` | `TheoremsTests: testTheorem4_ModelVersionUpgradePreservesEveryTransition` |
| `theorem_6_storage_fidelity_round_trip_reversibility` | `TheoremsTests: testTheorem6_StorageFidelityRoundTripReversibility` |
| `theorem_7_first_class_corrections_four_version_lifecycle` | `TheoremsTests: testTheorem7_FirstClassCorrectionsFourVersionLifecycle` |
| `theorem_8_provenance_confirmed_bit_selects_exactly_confirmed_rows` | `TheoremsTests: testTheorem8_ProvenanceConfirmedBitSelectsExactlyConfirmedRows` |

#### `tests/composition_conformance_tests.rs` (3)

| Rust `#[test]` | Swift peer candidate |
|---|---|
| `multi_estate_open_and_fan_out_routes_by_overlap` | `CompositionConformanceTests` |
| `unified_audit_projection_and_enrichment_fold_both_tiers` | `CompositionConformanceTests` |
| `training_daemon_composes_with_enrichment_and_gate` | `CompositionConformanceTests` |

#### `tests/performance_gate_tests.rs` (2)

| Rust `#[test]` | Swift peer candidate |
|---|---|
| `theorem_5_capture_p99_under_iphone_budget` | `PerformanceGateTests: testTheorem5_CaptureP99UnderIPhoneBudget` |
| `theorem_5_enrichment_throughput_clears_mac_floor` | `PerformanceGateTests: testTheorem5_EnrichmentThroughputClearsMacFloor` |

## Files NOT modified (per mission's MUST NOT list)

- `packages/kits/GeniusLocusKit/Sources/**` — released production code. Untouched.
- `packages/kits/GeniusLocusKit/rust/**` — Rust behavior reference only. Untouched.
- `docs/validation/**` — off-limits conformance harness. Untouched.
- Any other package. Untouched.

## Documentation inaccuracies surfaced (non-blocking)

### 1. Swift method count: mission says 146, reality is 148

Mission Context and the "Files You Will Modify" table both say 146. The XCTest
runner and per-file grep agree: 148. Both additional methods are genuine test
functions in `PerformanceGateTests.swift` — not helpers, not excluded. Bilby
preserves all 148. Recorded for Skippy.

### 2. Rust `#[test]` count: mission says 13, reality is 99

Mission Context says "The Rust leg has 13 `#[test]` functions." The 13 is the
unit test binary only (`src/coordinator.rs` + `src/branches.rs` inline tests).
The integration suite in `tests/` adds 86 across 10 files. Total: 99.
All 99 pass. Bilby must address parity for all 99. Recorded for Skippy.

## Stated approach (Bilby, per Smythe's pre-flight ask)

File-by-file mechanical conversion, fidelity-first, in three parts:

- **Part 1 — convert all 20 files.** Read each file fully; rewrite it preserving
  every statement verbatim except: `import XCTest` → `import Testing`;
  `final class FooTests: XCTestCase` → `@Suite("…") struct FooTests`; each
  `func testBar()` → `@Test func bar()` (drop the `test` prefix, lowercase the
  first char; keep `async`/`throws`); and the assertion macros translated 1:1 —
  `XCTAssertEqual(a,b)`→`#expect(a == b)`, `XCTAssertNotEqual`→`!=`,
  `XCTAssertTrue(x)`→`#expect(x)`, `XCTAssertFalse(x)`→`#expect(!x)`,
  `XCTAssertNil(x)`→`#expect(x == nil)`, `XCTAssertNotNil(x)`→`#expect(x != nil)`,
  `XCTAssertGreaterThan`→`>`, `…OrEqual`→`>=`, `XCTAssertLessThan`→`<`,
  `…OrEqual`→`<=`, `XCTAssertThrowsError(try f())`→`#expect(throws:){ try f() }`
  (specific error type where the original inspected it),
  `XCTAssertNoThrow(try f())`→`#expect(throws: Never.self){ try f() }`,
  `try XCTUnwrap(x)`→`try #require(x)`, `XCTFail(m)`→`Issue.record(m)`.
  Trailing message strings are carried through as the `#expect` comment argument.
  `setUp`/`tearDown` → struct `init`/per-test as needed (none observed so far).
  Private helper methods and file-scope helper types preserved verbatim.
  All 148 assertions preserved. Verify: `swift test` green, ≥148 registered,
  zero `import XCTest`.
- **Part 2 — fill per-type gaps.** Add peer suites for source types lacking
  coverage, primarily `GeniusLocusKitError` and `ProposalKind` (Rust has 2
  dedicated `proposal_kind_*` tests). Confirm `ScopeKeyVault`,
  `FederatedRecallResult`, `AuditChain*` depth by reading.
- **Part 3 — parity.** Confirm the Swift peers assert the Rust behaviors
  (13 inline `src/` per mission scope; the 86 integration peers already exist
  by suite). Add any genuinely missing. Run both legs; record verbatim.

## Test verification (filled at completion)

- `swift test`: exit 0, >= 148 @Test registered under the swift-testing runner,
  zero `import XCTest` remaining. To be recorded verbatim.
- `cargo test`: exit 0, 99 passed (unchanged — Rust leg not touched). To be
  recorded.
