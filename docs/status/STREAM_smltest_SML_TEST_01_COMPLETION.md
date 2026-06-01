# COMPLETION: SML-TEST-01 — SubstrateML Swift library test leg (swift-testing, both legs)

**Status: COMPLETE**
Stream: smltest · Branch: `stream/sm-substrateml-test-leg`
Baseline: `b42db96` · Head: `5800b6b`
Mission: `docs/missions/inflight/MISSION_SML_TEST_01.md`
Date: 2026-05-31

---

## Summary

SubstrateML now has a complete Swift library test leg in swift-testing:
one peer suite per shipped `Sources/SubstrateML/` type (23 types), asserting
the behavior set its Rust `#[test]` counterpart asserts (matching
tolerances and seeds), and deriving from the documented property set for the
11 Rust files that carry no inline tests. The XCTest package smoke and the
XCTest `FloatSimHashTests` (5 methods) are converted to swift-testing; zero
`import XCTest` remains. No production source was modified. Both legs are
green with zero warnings; the conformance harness (`docs/validation/**`) was
untouched.

Baseline reality matched the mission exactly: 23 source types, 2 XCTest test
files registering as "0 tests in 0 suites" under the swift-testing runner,
70 Rust `#[test]`.

## What Was Done

- **Part 1 — framework + deterministic suites** — `f6d850b`
  (`test(substrateml): swift-testing framework + deterministic suites (Swift)`)
  - Rewrote `SubstrateMLTests.swift` (package smoke) XCTest → swift-testing.
  - Converted `FloatSimHashTests.swift` (5 methods preserved). The two
    formerly-unseeded-`Float.random` tests now use the **Rust mirror's
    deterministic input vectors** (Smythe warning #2), so they are
    reproducible and cross-leg comparable.
  - Authored the 9 deterministic, non-iterative peer suites: AuditLogFold,
    CompositeDistance, LatticeDistance, InformationTheory, MomentSummary,
    TierContributionFingerprint, TierAscendingQuery, TemporalCompression,
    ActionOutcomeMatrix.
  - Verify: `swift test` 77 tests / 11 suites, exit 0; no `import XCTest`.
- **Part 2 — iterative/numerical + RNG suites** — `9a18602`
  (`test(substrateml): iterative/numerical + RNG suites (Swift)`)
  - Authored the remaining 13 suites: BradleyTerry, FFT,
    EigenvalueCentrality, CommunityDetection, RandomWalks, PairingHandshake,
    MatrixDecay, PartialStateRecall (mirror Rust `#[test]`), and
    NMFAlternatingLeastSquares, DPORReduction, AnomalyDetection,
    LLMCalibrationCurve, FeatureExtractors (derived from documented
    properties). RNG suites reuse Rust's SplitMix64 seeds (Known
    Ambiguity 2).
  - Verify: `swift test` 150 tests / 24 suites, exit 0; every `Sources/`
    type has a peer suite; zero warnings.
- **Part 3 — parity, both legs** — `e00df32`
  (`test(substrateml): Swift/Rust library-test parity confirmed`)
  - Parity audit; both legs run green; documented two legitimate divergences.
- **Blast Radius Report** — `5800b6b` (`docs(substrateml): blast radius report`).

## Test Verification Log

### Baseline (mission start, commit b42db96)
- `swift test`: exit 0 — 6 XCTest cases execute (1 smoke + 5 FloatSimHash),
  but the swift-testing runner reports **"Test run with 0 tests in 0 suites
  passed"** (XCTest registers as 0 under the swift-testing runner — exactly
  the gap the mission addresses).
- `cargo test`: exit 0, **70** passed.

### Final (commit 5800b6b)
- Command: `cd packages/libs/SubstrateML && swift test`
  - Exit code: **0**
  - Pass count: **150** `@Test` in **24** suites (23 type peer suites + the
    package smoke).
  - Tail (verbatim): `Test run with 150 tests in 24 suites passed after 0.021 seconds.`
  - `swift build --build-tests` warnings: **0**
- Command: `cd packages/libs/SubstrateML/rust && cargo test`
  - Exit code: **0**
  - Pass count: **70** (unchanged from baseline — no Rust touched).
  - Tail (verbatim): `test result: ok. 70 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s`
  - `cargo` warnings: **0**

Both independently re-run and confirmed by Adams (§10).

### Parity map (Rust `#[test]` module → Swift suite)
| Rust file | #[test] | Swift suite | Mirror |
|---|---|---|---|
| lattice_distance.rs | 11 | LatticeDistanceTests | 11 (case-for-case) |
| partial_state_recall.rs | 7 | PartialStateRecallTests | 7 |
| decay.rs | 7 | MatrixDecayTests | 7 |
| moment_summary.rs | 6 | MomentSummaryTests | 6 |
| fft.rs | 6 | FFTTests | 5 (+1 documented divergence) |
| random_walks.rs | 5 | RandomWalksTests | 5 |
| float_simhash.rs | 5 | FloatSimHashTests | 5 |
| eigenvalue_centrality.rs | 5 | EigenvalueCentralityTests | 5 |
| composite_distance.rs | 5 | CompositeDistanceTests | 5 |
| community_detection.rs | 5 | CommunityDetectionTests | 5 |
| pairing.rs | 4 | PairingHandshakeTests | 3 (+1 documented divergence) |
| bradley_terry.rs | 4 | BradleyTerryTests | 4 |
| **(11 test-less files)** | 0 | derived suites | property-set coverage |

Rust total: **70** `#[test]`. Swift total: **150** `@Test` (mirror + derived).

## Smythe Pre-flight

Verdict: **GREEN — proceed**, no RESCOPE.
(`docs/blast_radius/SML_TEST_01_PREFLIGHT.md`)
- Blast radius confirmed: 23 Swift sources, 23 Rust counterparts, 70 Rust
  tests, no orphans.
- swift-testing is toolchain-bundled (LatticeKit imports `Testing` with no
  Package.swift dependency) ⇒ the mission's conditional Package.swift row
  resolves to "present", no change required.
- Three warnings, all honored: (1) 11 Rust files have 0 `#[test]` → derive
  from bodies; (2) two FloatSimHash tests used unseeded `Float.random` →
  apply fixed deterministic vectors on conversion; (3) `tier_query.rs`
  documents an intentional Swift/Rust asymmetry (RecallScore/RecallResult/
  etc. have no Rust equivalent) → test the query protocol, not chase parity
  on Swift-only shapes.
- Public API surface fully public; `@testable import SubstrateML` is the
  correct import form.

## Adams Post-flight

Verdict: **PASS-WITH-FINDINGS.** Both BLOCKING checks PASS.
(`docs/blast_radius/SML_TEST_01_POSTFLIGHT.md`)
- **§9 Blast Radius Verification: PASS** — diff = exactly 27 files (24 test
  files + 3 docs), matching the BRR. Zero diff against `Sources/**`,
  `rust/**`, `docs/validation/**`; Package.swift unchanged; zero
  `import XCTest`; no prohibited patterns.
- **§10 Test Execution Verification: PASS** — independently re-ran both
  legs: swift exit 0 / 150 in 24 suites, cargo exit 0 / 70 — both MATCH.
- **Implementation review:** parity spot-checks (CompositeDistance,
  LatticeDistance, MatrixDecay, PartialStateRecall) clean and case-for-case.
  Derived suites are substantive (AuditLogFold tombstone-stickiness I-22,
  InformationTheory 13 closed-form properties, ActionOutcomeMatrix Wilson
  bound penalizing thin evidence). Both documented divergences judged
  legitimate. XCTest fully eliminated.

### Adams findings resolution
| # | Severity | Finding | Resolution |
|---|---|---|---|
| 1 | WARNING | Signal file `.done-smltest` not yet written | **Resolved by sequence** — per Bilby Execution Order the signal is written as the very next step *after* this completion report is committed (Duty 7). Written below. |

No CRITICAL or production-affecting findings. Hard gate (Adams §9/§10 PASS)
satisfied before signal.

## Self-review

- Diff (27 files, +2257 / −51) matches the BRR MUST_UPDATE set exactly: 23
  created peer suites + 2 XCTest→swift-testing conversions + 3 docs
  (Smythe pre-flight, this stream's BRR, inflight mission). The 51 deletions
  are the replaced XCTest bodies in the two converted files.
- No production source touched (`Sources/**`, `rust/**`), `docs/validation/**`
  untouched, Package.swift unchanged.
- No bridges, shims, TODOs, deprecations, secrets, or silenced warnings. No
  `import XCTest`. No view code (no palette/Dynamic-Type concerns).

## Conditional lifecycle agents — evaluated

- **Kong — NOT spawned.** No architectural decision, no primitive change, no
  cross-product surface. Pure test-only authoring against a settled API.
- **Simms / Friedlander / Nert — N/A.** No user-facing behavior, no views,
  no visual or accessibility surface.
- **Perkins — N/A.** No CloudKit/schema/FNode/BYOAI/URL-scheme/NL surface
  touched; test-only.
- **Nagatha docs-repo sync — deferred to post-merge** per standard flow;
  this completion report is written directly to `docs/status/` per the
  operative goal directive, and the signal file follows immediately.

## Discoveries

- **swift-testing is toolchain-bundled in this repo.** `import Testing`
  needs no Package.swift dependency (confirmed against LatticeKit and
  SubstrateTypes). Conditional "add dep only if absent" rows in test-leg
  missions will reliably resolve to "no change" here.
- **`SimHash.fingerprint(fromSubhashes:)` requires a 64-bit-input-per-block
  family**, not the 192/64/64/64 estate-local row family. It feeds each
  block a single 64-bit subhash word, so a family from
  `PairingHandshake.generateSharedFamily` (block 0 = 192-bit) trips the
  `HyperplaneFamily` mask-length precondition. FeatureExtractors tests build
  their family via `HyperplaneFamily.generate(..., inputBitLength: 64)` for
  all four blocks. (Caught during Part 2; not a production bug — it's the
  correct family shape for ambient subhash fingerprints.)
- **Float32 vs Double literal comparison** bites exact-equality assertions
  (`successRate == 2.0/3.0` promotes the Float32 to Double and fails);
  keep both sides Float32 (`Float32(2)/Float32(3)`) or compare with a
  tolerance. (Caught in Part 1.)

## Outstanding (out of scope — not addressed)

- **FFT non-power-of-two contract** is exercised only positively in Swift;
  the trap path is a `precondition` (process-trapping), not catchable by
  swift-testing `#expect(throws:)`. A death-test harness or an
  exit-test (`#expect(processExitsWith:)`) could close this if desired; left
  out as a language-level untestable, documented in `FFTTests.swift`.
- **`HyperplaneFamily.diversifiedSeed` direct unit test** belongs to the
  SubstrateTypes test leg (it is a SubstrateTypes internal). Indirectly
  covered here via the distinct-blocks assertion in `PairingHandshakeTests`.
