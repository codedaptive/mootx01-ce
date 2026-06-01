# Smythe Pre-flight: SML-TEST-01

## Status
GREEN

## Status Details
- Blast radius: verified — 23 Swift sources, 2 XCTest test files, 70 Rust tests
- Prior art: none conflicting
- Environment: clean — worktree has only the untracked mission file
- Dependencies: satisfied — no prerequisite streams

---

## Blast Radius Reality

### Swift source files (23) — confirmed match
| Swift file | Rust counterpart | Rust tests |
|---|---|---|
| ActionOutcomeMatrix.swift | action_outcome.rs | 0 (real impl, no tests) |
| AnomalyDetection.swift | anomaly.rs | 0 (real impl, no tests) |
| AuditLogFold.swift | audit_log_fold.rs | 0 (real impl, no tests) |
| BradleyTerry.swift | bradley_terry.rs | 4 |
| CommunityDetection.swift | community_detection.rs | 5 |
| CompositeDistance.swift | composite_distance.rs | 5 |
| DPORReduction.swift | dp_or_reduce.rs | 0 (real impl, no tests) |
| EigenvalueCentrality.swift | eigenvalue_centrality.rs | 5 |
| FeatureExtractors.swift | feature_extractors.rs | 0 (real impl, no tests) |
| FFT.swift | fft.rs | 6 |
| FloatSimHash.swift | float_simhash.rs | 5 |
| InformationTheory.swift | info_theory.rs | 0 (real impl, no tests) |
| LatticeDistance.swift | lattice_distance.rs | 11 |
| LLMCalibrationCurve.swift | calibration.rs | 0 (real impl, no tests) |
| MatrixDecay.swift | decay.rs | 7 |
| MomentSummary.swift | moment_summary.rs | 6 |
| NMFAlternatingLeastSquares.swift | nmf.rs | 0 (real impl, no tests) |
| PairingHandshake.swift | pairing.rs | 4 |
| PartialStateRecall.swift | partial_state_recall.rs | 7 |
| RandomWalks.swift | random_walks.rs | 5 |
| TemporalCompression.swift | temporal_compression.rs | 0 (real impl, no tests) |
| TierAscendingQuery.swift | tier_query.rs | 0 (real impl, no tests) |
| TierContributionFingerprint.swift | tier_contribution.rs | 0 (real impl, no tests) |

Total Rust tests: 70 confirmed (grep count exact).

All 23 Swift files have a Rust counterpart. All Rust modules have a Swift peer.
No orphans in either direction.

### Rust-zero-test callout (important for Bilby)
10 Rust files carry 0 `#[test]`. These are NOT skeletons — all have real
implementation functions. Bilby must derive behavior tests from the Swift public
API and Rust function bodies directly. No Rust tests to mirror for:
ActionOutcomeMatrix, AnomalyDetection, AuditLogFold, DPORReduction,
FeatureExtractors, InformationTheory, LLMCalibrationCurve, NMF,
TemporalCompression, TierAscendingQuery, TierContributionFingerprint.

Mission says "mirror Rust tests" for these — Bilby must instead derive from
function semantics in the Rust source. This is a scope clarification, not a
blocker (the work is still test-only, still the same files, same deliverable).

---

## swift-testing Wiring

No Package.swift change needed. swift-testing is toolchain-bundled.

Evidence:
- `packages/kits/LatticeKit/Package.swift` — zero swift-testing dependency declared
- `LatticeKit/Tests/LatticeKitTests/CodeTests.swift` — `import Testing`, `@Suite`, `@Test` used directly
- LatticeKit tests run under swift test without any explicit swift-testing dep

SubstrateML's Package.swift currently declares no swift-testing dep, which is
correct. The conditional-add logic in the mission description is unnecessary;
Package.swift need not change at all. Bilby should confirm at the top of Part 1
(write a single `import Testing` test, `swift test`, green) before authoring 23 suites.

---

## Public API Surface

All 23 types have public declarations. Spot checks:

- `FloatSimHash` — `public enum`, `public static func project(vector:seed:)`
- `ActionOutcomeMatrix` — 21 public decls; structs, mutating methods, computed props
- Every file: 2–69 public decls (FeatureExtractors highest at 69)

Import strategy: `@testable import SubstrateML` (as existing tests use) is correct
and sufficient. No type requires internal-only access to write behavior tests — but
`@testable` is already the pattern and carries no cost.

---

## Existing Test Files

Two XCTest files, both must be converted:

1. `Tests/SubstrateMLTests/SubstrateMLTests.swift` — 1 test, smoke only, rewrite to swift-testing
2. `Tests/SubstrateMLTests/FloatSimHashTests.swift` — 5 tests, real behavior, convert preserving all 5

Both files currently `import XCTest`. Both must become `import Testing` with zero
`import XCTest` remaining in the package after Part 1.

Note: `testSimilarVectorsClose` and `testOrthogonalVectorsFarApart` in
FloatSimHashTests use `Float.random` without a fixed seed — they are
non-deterministic. Mission requirement says RNG-dependent suites use fixed seeds
(Known Ambiguity 2). Bilby should apply a fixed seed when converting these two.
The Rust float_simhash tests use seed `0xDEAD_BEEF` as the canonical value.

---

## Prior Art

None conflicting. No existing swift-testing scaffolding in SubstrateML.
No prior missions touching this package's test target.
Worktree status: only `docs/missions/inflight/MISSION_SML_TEST_01.md` untracked.

---

## Environment

Branch: `stream/sm-substrateml-test-leg` (correct per mission stream `smltest`)
Baseline per orchestrator: `swift test` exit 0 (6 XCTest, 0 swift-testing); `cargo test` exit 0 (70 passed)
Worktree: clean

---

## Blockers
None.

---

## Warnings

1. **10 Rust files have 0 tests.** Bilby must derive behavior tests for those types
   from the Rust implementation bodies, not from mirroring `#[test]` functions.
   Not a blocker. Affects Part 2 scope estimate — these 10 types require more
   independent test authoring than the mission brief implies.

2. **Two FloatSimHash tests use unseeded `Float.random`.** Convert with fixed seeds
   per Known Ambiguity 2. Rust float_simhash uses `0xDEAD_BEEF` as seed.
   Not a blocker. Authoring decision for Bilby.

3. **Package.swift conditional logic unnecessary.** swift-testing is toolchain-bundled.
   Package.swift does not need modification. If Bilby skips that edit entirely,
   the mission succeeds. Not a blocker.

---

## Bilby's Stated Approach
[Bilby to fill before proceeding]

Assessment: pending

---

## Actions (Bilby, in order)

1. Write a single-test `import Testing` file in `Tests/SubstrateMLTests/`, run
   `swift test` — confirm toolchain-bundled swift-testing works (no Package.swift
   change needed).
2. Rewrite `SubstrateMLTests.swift` to swift-testing smoke (1 `@Test`).
3. Convert `FloatSimHashTests.swift` — 5 tests, XCTest -> swift-testing, apply
   fixed seed to the two non-deterministic tests.
4. Author Part 1 deterministic suites (9 types): AuditLogFold, CompositeDistance,
   LatticeDistance, InformationTheory, MomentSummary, TierContributionFingerprint,
   TierAscendingQuery, TemporalCompression, ActionOutcomeMatrix.
5. Commit Part 1 and verify `swift test` green, zero `import XCTest` in the package.
6. Author Part 2 suites (13 types): BradleyTerry, NMF, FFT, EigenvalueCentrality,
   DPORReduction, AnomalyDetection, CommunityDetection, LLMCalibrationCurve,
   MatrixDecay, PairingHandshake, PartialStateRecall, RandomWalks, FeatureExtractors.
   For the 10 zero-Rust-test types in this batch, derive tests from implementation bodies.
7. Commit Part 2 and verify `swift test` green.
8. Part 3: confirm Swift/Rust parity, run both legs. Commit.
9. Write signal file: `/Users/bob/devlop/ddfactory/control/signals/.done-smltest`.

---

## Decision Needed
None. Terrain clear.
