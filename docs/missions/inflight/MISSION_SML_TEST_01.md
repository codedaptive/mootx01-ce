# Mission SML-TEST-01 — SubstrateML library test leg (swift-testing, both legs)

## Priority: P1
## Stream: smltest
## Branch from: main
## Depends on: None
## Parallel safe with: sktest, slibtest (disjoint packages)

---

## Context

SubstrateML ships 23 library source files and builds clean on both legs. The Rust leg has
70 `#[test]` functions. The Swift library test leg is a 1-function package smoke test
(`SubstrateMLTests.swift`) plus one real per-type suite (`FloatSimHashTests.swift`,
5 methods) — all `import XCTest`, registering as "0 tests in 0 suites" under the
swift-testing runner. So 1 of 23 types has authored coverage and even that does not run.

This mission builds the missing Swift library test leg: per-source-file swift-testing
suites mirroring `Sources/`, proving each shipped type works, asserting the behavior set the
corresponding Rust `#[test]` module asserts. TEST-ONLY — no production source modified.
Follows the ST-TEST-01 pattern (SubstrateTypes: 145 @Test, both legs green).

The conformance harness at `docs/validation/substrate_math_performance/` (EE-only) tests
algorithm validity, NOT library implementation, and is NOT coverage. Off-limits.

## Read First

- Library types: `packages/libs/SubstrateML/Sources/SubstrateML/*.swift` (23 files: ActionOutcomeMatrix, AnomalyDetection, AuditLogFold, BradleyTerry, CommunityDetection, CompositeDistance, DPORReduction, EigenvalueCentrality, FFT, FeatureExtractors, FloatSimHash, InformationTheory, LLMCalibrationCurve, LatticeDistance, MatrixDecay, MomentSummary, NMFAlternatingLeastSquares, PairingHandshake, PartialStateRecall, RandomWalks, TemporalCompression, TierAscendingQuery, TierContributionFingerprint).
- Existing: `Tests/SubstrateMLTests/SubstrateMLTests.swift` (XCTest smoke), `FloatSimHashTests.swift` (XCTest, 5 methods — convert + keep).
- swift-testing reference style: `packages/kits/LatticeKit/Tests/LatticeKitTests/CodeTests.swift`.
- Rust behavior to mirror: `packages/libs/SubstrateML/rust/src/*.rs` inline `#[test]` (70 tests).
- swift-testing wiring precedent: `packages/libs/SubstrateTypes/Package.swift`.

## Known Ambiguities

1. Numerical/iterative algorithms (BradleyTerry SGD, NMF ALS, FFT, EigenvalueCentrality,
   DPORReduction) — assert against the same tolerances/fixed-iteration expectations the Rust
   tests use. Mirror Rust's tolerance and seed choices; do not invent stricter bounds.
2. RNG-dependent suites (RandomWalks, FloatSimHash, PairingHandshake) — use the same
   deterministic seeds the Rust tests use so results are reproducible and comparable.

## Files You Will Modify

| File | Change |
|---|---|
| `packages/libs/SubstrateML/Tests/SubstrateMLTests/SubstrateMLTests.swift` | rewrite XCTest -> swift-testing (keep as package smoke) |
| `packages/libs/SubstrateML/Tests/SubstrateMLTests/FloatSimHashTests.swift` | convert XCTest -> swift-testing (preserve 5) |
| `.../ActionOutcomeMatrixTests.swift` | CREATE |
| `.../AnomalyDetectionTests.swift` | CREATE |
| `.../AuditLogFoldTests.swift` | CREATE |
| `.../BradleyTerryTests.swift` | CREATE |
| `.../CommunityDetectionTests.swift` | CREATE |
| `.../CompositeDistanceTests.swift` | CREATE |
| `.../DPORReductionTests.swift` | CREATE |
| `.../EigenvalueCentralityTests.swift` | CREATE |
| `.../FFTTests.swift` | CREATE |
| `.../FeatureExtractorsTests.swift` | CREATE |
| `.../InformationTheoryTests.swift` | CREATE |
| `.../LLMCalibrationCurveTests.swift` | CREATE |
| `.../LatticeDistanceTests.swift` | CREATE |
| `.../MatrixDecayTests.swift` | CREATE |
| `.../MomentSummaryTests.swift` | CREATE |
| `.../NMFAlternatingLeastSquaresTests.swift` | CREATE |
| `.../PairingHandshakeTests.swift` | CREATE |
| `.../PartialStateRecallTests.swift` | CREATE |
| `.../RandomWalksTests.swift` | CREATE |
| `.../TemporalCompressionTests.swift` | CREATE |
| `.../TierAscendingQueryTests.swift` | CREATE |
| `.../TierContributionFingerprintTests.swift` | CREATE |
| `packages/libs/SubstrateML/Package.swift` | conditional: additive swift-testing dep only if absent |

(All CREATE paths under `packages/libs/SubstrateML/Tests/SubstrateMLTests/`.)

## Files You MUST NOT Modify

- `packages/libs/SubstrateML/Sources/**` — released production code. If a test reveals a real bug, STOP and report.
- `packages/libs/SubstrateML/rust/**` — complete; behavior reference only.
- `docs/validation/**` — off-limits.
- Any other package.

## Implementation Parts

### Part 1 — Framework + deterministic value-type suites
Confirm swift-testing wiring. Rewrite the smoke; convert FloatSimHashTests. Author the
deterministic, non-iterative suites first: AuditLogFold, CompositeDistance, LatticeDistance,
InformationTheory, MomentSummary, TierContributionFingerprint, TierAscendingQuery,
TemporalCompression, ActionOutcomeMatrix. Mirror Rust behavior/seeds.
**Commit:** `test(substrateml): swift-testing framework + deterministic suites (Swift)`
→ verify: `cd packages/libs/SubstrateML && swift test` green; no `import XCTest` remains.

### Part 2 — Iterative/numerical + RNG suites
Author the rest: BradleyTerry, NMFAlternatingLeastSquares, FFT, EigenvalueCentrality,
DPORReduction, AnomalyDetection, CommunityDetection, LLMCalibrationCurve, MatrixDecay,
PairingHandshake, PartialStateRecall, RandomWalks, FeatureExtractors. Use Rust's tolerances
and seeds (Known Ambiguities 1, 2).
**Commit:** `test(substrateml): iterative/numerical + RNG suites (Swift)`
→ verify: `swift test` green; every Sources/ type has a peer test file.

### Part 3 — Parity, both legs
Confirm each Swift suite asserts its Rust counterpart's behavior set; add missing. Run both.
**Commit:** `test(substrateml): Swift/Rust library-test parity confirmed`
→ verify: `swift test` green and `cd rust && cargo test` green (70 expected); zero warnings both legs.

## Test Requirements

- swift-testing only; zero `import XCTest` in the package.
- Every `Sources/SubstrateML/` type has a peer test file.
- Each suite asserts its Rust counterpart's behavior set, with matching tolerances/seeds.
- `swift test` green; `cargo test` green (70); zero warnings both legs.
- No production source modified.

## Test Verification Log
### Baseline: Swift authored = smoke (1) + FloatSimHash (5), registering 0 under runner; Rust #[test] = 70 (verify).
### Final: `cd packages/libs/SubstrateML && swift test 2>&1 | tail -20` exit 0, @Test count recorded, verbatim tail; `cd rust && cargo test` exit 0, 70 passed.

## Verification

SubstrateML has a complete Swift library test leg in swift-testing, one peer suite per
shipped type, asserting the Rust behavior set with matching tolerances/seeds. No production
source changed. Both legs green, zero warnings. Harness untouched.

## Success Criteria

Every SubstrateML type has a swift-testing peer suite; smoke + FloatSimHash converted;
Swift/Rust parity; both legs green; production untouched.

## Signal File

Write to: /Users/bob/devlop/ddfactory/control/signals/.done-smltest
