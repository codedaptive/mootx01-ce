# Blast Radius Report — SML-TEST-01 (SubstrateML Swift library test leg)

**Tier:** net-new test work (no-cap). No Critical Primitives touched.
**Mission:** `docs/missions/inflight/MISSION_SML_TEST_01.md`
**Baseline:** `b42db96` · **Head:** `e00df32`

## Nature of the change

TEST-ONLY. The mission adds the missing Swift library test leg for
SubstrateML in swift-testing. No production source (`Sources/**`,
`rust/**`) and no off-limits surface (`docs/validation/**`) is modified.

## MUST_UPDATE / file set (matches the mission's "Files You Will Modify")

Created (23 peer test suites, one per `Sources/SubstrateML/<Type>.swift`):
- ActionOutcomeMatrixTests, AnomalyDetectionTests, AuditLogFoldTests,
  BradleyTerryTests, CommunityDetectionTests, CompositeDistanceTests,
  DPORReductionTests, EigenvalueCentralityTests, FFTTests,
  FeatureExtractorsTests, InformationTheoryTests, LLMCalibrationCurveTests,
  LatticeDistanceTests, MatrixDecayTests, MomentSummaryTests,
  NMFAlternatingLeastSquaresTests, PairingHandshakeTests,
  PartialStateRecallTests, RandomWalksTests, TemporalCompressionTests,
  TierAscendingQueryTests, TierContributionFingerprintTests.
  (FloatSimHash's peer suite is the converted `FloatSimHashTests.swift`.)

Rewritten / converted (XCTest → swift-testing):
- `Tests/SubstrateMLTests/SubstrateMLTests.swift` (package smoke).
- `Tests/SubstrateMLTests/FloatSimHashTests.swift` (5 methods preserved,
  now using the Rust mirror's deterministic input vectors — no unseeded RNG).

Supporting docs (not production):
- `docs/blast_radius/SML_TEST_01_PREFLIGHT.md` (Smythe), this report,
  and the inflight mission file.

## Package.swift

NOT modified. The mission's Package.swift row was conditional ("additive
swift-testing dep only if absent"). swift-testing is toolchain-bundled
(LatticeKit imports `Testing` with no package dependency; Smythe
confirmed), so no dependency addition is required. Condition resolved to
"present" ⇒ no change.

## Prohibited-pattern check

No bridges, shims, partial migrations, `@available(deprecated)`, TODO/FIXME,
or silenced warnings introduced. No `import XCTest` remains in the package.

## Verification

- `swift test`: 150 @Test in 24 suites, exit 0, zero warnings.
- `cargo test`: 70 passed, exit 0, zero warnings (unchanged from baseline —
  no Rust touched).

## Documented divergences (parity, not gaps)

1. FFT `non_power_of_two_panics` (Rust) — Swift enforces via `precondition`,
   which traps the process and is not catchable by swift-testing
   `#expect(throws:)`. Mirrored 5 of 6 FFT tests; the trap is a
   language-level untestable, not a missing assertion.
2. pairing `diversified_seeds_differ_per_block` (Rust) — directly tests
   `HyperplaneFamily.diversifiedSeed`, a SubstrateTypes internal, so it
   belongs to the SubstrateTypes test leg. Covered indirectly here by the
   distinct-blocks assertion (distinct block hashes ⇒ distinct seeds).
