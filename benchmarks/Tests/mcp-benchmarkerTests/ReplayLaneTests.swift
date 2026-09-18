import Testing
@testable import mcp_benchmarker

// ReplayLaneTests — pure unit tests for the replay lane fingerprint and
// comparison logic.
//
// These tests cover only the deterministic comparison logic: fingerprint
// construction, field comparison, section-presence drift, and the
// exact-equality contract for timing-excluded fields. No binary is spawned,
// no estate is provisioned, no network is touched. The live replay loop is
// covered by the shakedown harness, not by this suite.
//
// All five tests are pure-logic and must compile and pass without any
// external dependencies.

// MARK: - Helpers

/// Builds a `SupersessionScores` from explicit field values. Used to
/// construct test fingerprints without running a live supersession lane.
private func makeScores(
    queryCount: Int = 40,
    currentWinRate: Double = 0.975,
    currentFoundRate: Double = 1.0,
    meanStaleInTopK: Double = 0.05,
    meanCurrentRank: Double = 1.2,
    p50LatencySeconds: Double = 0.045   // timing field — must NOT appear in fingerprint
) -> SupersessionScores {
    SupersessionScores(
        queryCount: queryCount,
        currentWinRate: currentWinRate,
        currentFoundRate: currentFoundRate,
        meanStaleInTopK: meanStaleInTopK,
        meanCurrentRank: meanCurrentRank,
        p50LatencySeconds: p50LatencySeconds)
}

/// Builds a `SupersessionLaneOutcome` with no optional sections. Used when
/// the test does not require the contradiction sweep or structured tier.
private func makeOutcomeBase() -> SupersessionLaneOutcome {
    SupersessionLaneOutcome(queryResults: [], contradiction: nil, structured: nil, tiered: nil)
}

/// Builds a `SupersessionLaneOutcome` with a contradiction outcome.
private func makeOutcomeWithContradiction(
    plantedCount: Int = 10,
    detectedAnyTier: Int = 8,
    detectedProposed: Int = 7,
    flaggedOutsidePlanted: Int = 3,
    huntSeconds: Double = 1.2          // timing field — must NOT appear in fingerprint
) -> SupersessionLaneOutcome {
    SupersessionLaneOutcome(
        queryResults: [],
        contradiction: SupersessionContradictionOutcome(
            plantedCount:          plantedCount,
            detectedAnyTier:       detectedAnyTier,
            detectedProposed:      detectedProposed,
            flaggedOutsidePlanted: flaggedOutsidePlanted,
            huntSeconds:           huntSeconds),
        structured: nil,
        tiered: nil)
}

/// Builds a `SupersessionLaneOutcome` with a structured-tier outcome.
private func makeOutcomeWithStructuredTier(
    plantedCount: Int = 10,
    provenPlanted: Int = 9,
    provenOutsidePlanted: Int = 0,
    provenReported: Int = 9,
    historicalReported: Int = 30,
    coverageProjected: Int = 45,
    coverageScanned: Int = 45,
    tierSeconds: Double = 2.5           // timing field — must NOT appear in fingerprint
) -> SupersessionLaneOutcome {
    SupersessionLaneOutcome(
        queryResults: [],
        contradiction: nil,
        structured: StructuredTierOutcome(
            plantedCount:         plantedCount,
            provenPlanted:        provenPlanted,
            provenOutsidePlanted: provenOutsidePlanted,
            provenReported:       provenReported,
            historicalReported:   historicalReported,
            coverageProjected:    coverageProjected,
            coverageScanned:      coverageScanned,
            tierSeconds:          tierSeconds),
        tiered: nil)
}

/// Builds a `SupersessionLaneOutcome` with a tiered scoring outcome.
///
/// Timing fields (`tier2PurposeSeconds`, `tier3PurposeSeconds`,
/// `synthesisWallSeconds`) are accepted as parameters here so callers can
/// verify that they do NOT appear in the fingerprint: passing two distinct
/// timing values into otherwise-identical outcomes must produce equal
/// fingerprints.
private func makeOutcomeWithTiered(
    tier2PlantedCount: Int = 10,
    tier2Detected: Int = 8,
    tier3PlantedCount: Int = 5,
    tier3Detected: Int = 4,
    tierInflation: Int = 0,
    decoyHitsHard: Int = 0,
    decoyHitsKnownLimitation: Int = 0,
    purposeSeconds: Double = 1.5        // timing field — must NOT appear in fingerprint
) -> SupersessionLaneOutcome {
    SupersessionLaneOutcome(
        queryResults: [],
        contradiction: nil,
        structured: nil,
        tiered: TieredScoringOutcome(
            tier2PlantedCount:    tier2PlantedCount,
            tier2Detected:        tier2Detected,
            tier2PurposeSeconds:  purposeSeconds,
            tier3PlantedCount:    tier3PlantedCount,
            tier3Detected:        tier3Detected,
            tier3PurposeSeconds:  purposeSeconds,
            tier1PlantedCount:    nil,
            tier1Detected:        nil,
            tier1PurposeSeconds:  nil,
            decoyHits:            DecoyHitCounts(
                                      hard: decoyHitsHard,
                                      knownLimitation: decoyHitsKnownLimitation),
            tierInflation:        tierInflation,
            laneSeconds:          [],
            synthesisWallSeconds: nil))
}

// MARK: - Tests

@Suite("ReplayLane fingerprint and comparison")
struct ReplayLaneTests {

    // ── Test 1: identical fingerprints produce an empty diff list ─────────

    @Test("identical fingerprints produce an empty diff list")
    func identicalFingerprintsProduceEmptyDiff() {
        let scores  = makeScores()
        let outcome = makeOutcomeBase()
        let fp = ReplayFingerprint(scores: scores, outcome: outcome)
        // Comparing a fingerprint against itself must yield no diffs: this is
        // the DETERMINISTIC base case.
        let diffs = compareReplayFingerprints(baseline: fp, candidate: fp)
        #expect(diffs.isEmpty,
                "identical fingerprints must produce an empty diff list; got: \(diffs.map(\.fieldName))")
    }

    // ── Test 2: timing fields do not appear in fingerprint ────────────────

    @Test("fingerprints differing only in timing fields compare equal")
    func timingFieldsExcludedFromFingerprint() {
        // Two scores identical in every deterministic field, differing only in
        // the wall-clock p50LatencySeconds. The fingerprint must exclude timing
        // so that a slow run on loaded hardware does not trigger a false DRIFT.
        let slowScores = makeScores(p50LatencySeconds: 0.500)
        let fastScores = makeScores(p50LatencySeconds: 0.010)
        let outcome = makeOutcomeBase()
        let slow = ReplayFingerprint(scores: slowScores, outcome: outcome)
        let fast = ReplayFingerprint(scores: fastScores, outcome: outcome)
        // The two fingerprints should be equal because timing is excluded.
        let diffs = compareReplayFingerprints(baseline: slow, candidate: fast)
        #expect(diffs.isEmpty,
                "timing-only difference must not appear as a diff; got: \(diffs.map(\.fieldName))")
        // Confirm the fingerprints are Equatable-equal too.
        #expect(slow == fast,
                "fingerprints differing only in timing must be Equatable-equal")
    }

    // ── Test 3: a single numeric field perturbed is reported ──────────────

    @Test("perturbing a single score field reports exactly that field")
    func singleFieldPerturbedReportsExactlyThatField() {
        let baseScores = makeScores(currentWinRate: 0.900)
        let pertScores = makeScores(currentWinRate: 0.875)   // different
        let outcome = makeOutcomeBase()
        let base = ReplayFingerprint(scores: baseScores, outcome: outcome)
        let pert = ReplayFingerprint(scores: pertScores, outcome: outcome)
        let diffs = compareReplayFingerprints(baseline: base, candidate: pert)
        #expect(diffs.count == 1,
                "exactly one field must differ; got \(diffs.count): \(diffs.map(\.fieldName))")
        let diff = diffs[0]
        #expect(diff.fieldName == "currentWinRate",
                "the reported field must be 'currentWinRate', got '\(diff.fieldName)'")
        #expect(diff.baselineValue.contains("0.9"),
                "baseline value must contain 0.9; got '\(diff.baselineValue)'")
        #expect(diff.candidateValue.contains("0.875"),
                "candidate value must contain 0.875; got '\(diff.candidateValue)'")
    }

    // ── Test 4: contradiction section present vs absent reports section-presence drift

    @Test("contradiction section present in one run but absent in other reports section-presence drift")
    func contradictionSectionPresenceIsDrift() {
        let scores = makeScores()
        let outcomeWith    = makeOutcomeWithContradiction()
        let outcomeWithout = makeOutcomeBase()
        let fpWith    = ReplayFingerprint(scores: scores, outcome: outcomeWith)
        let fpWithout = ReplayFingerprint(scores: scores, outcome: outcomeWithout)
        // Baseline has contradiction, candidate does not: section-presence DRIFT.
        let diffs = compareReplayFingerprints(baseline: fpWith, candidate: fpWithout)
        let names = Set(diffs.map(\.fieldName))
        #expect(names.contains("contradiction.present"),
                "section-presence diff must appear when contradiction runs in one fingerprint only; got: \(names)")
        // The baseline's presence value must be "true".
        if let presenceDiff = diffs.first(where: { $0.fieldName == "contradiction.present" }) {
            #expect(presenceDiff.baselineValue == "true",
                    "baseline must report 'true' for contradiction.present; got '\(presenceDiff.baselineValue)'")
            #expect(presenceDiff.candidateValue == "false",
                    "candidate must report 'false' for contradiction.present; got '\(presenceDiff.candidateValue)'")
        }
    }

    // ── Test 5: a structured-tier field perturbed is reported ─────────────

    @Test("perturbing a structured-tier field reports exactly that field")
    func structuredTierFieldPerturbedIsReported() {
        let scores = makeScores()
        // Two outcomes with identical structured-tier except provenPlanted.
        let outcomeA = makeOutcomeWithStructuredTier(provenPlanted: 9)
        let outcomeB = makeOutcomeWithStructuredTier(provenPlanted: 8)
        let fpA = ReplayFingerprint(scores: scores, outcome: outcomeA)
        let fpB = ReplayFingerprint(scores: scores, outcome: outcomeB)
        let diffs = compareReplayFingerprints(baseline: fpA, candidate: fpB)
        let names = Set(diffs.map(\.fieldName))
        #expect(names.contains("structuredTier.provenPlanted"),
                "structuredTier.provenPlanted must appear in diffs; got: \(names)")
        // Verify the field count: only provenPlanted changed; tierSeconds is
        // excluded, so the diff must have exactly one entry.
        #expect(diffs.count == 1,
                "exactly one structured-tier field must differ; got \(diffs.count): \(names)")
    }

    // ── Test 6: the table renderer produces the full report ───────────────
    // Covers the formatting path the pure comparison tests cannot reach —
    // the first live shakedown segfaulted here (String(format:) %s with a
    // Swift String) while tests 1-5 stayed green.

    @Test("renderer emits every row, both verdicts, and the verdict line")
    func rendererEmitsFullTable() {
        let scores = makeScores()
        let fpA = ReplayFingerprint(
            scores: scores, outcome: makeOutcomeWithStructuredTier(provenPlanted: 9))
        let fpB = ReplayFingerprint(
            scores: scores, outcome: makeOutcomeWithStructuredTier(provenPlanted: 8))
        let diffs = compareReplayFingerprints(baseline: fpA, candidate: fpB)

        let drift = renderReplayFieldTable(
            baseline: fpA, candidate: fpB, diffs: diffs,
            candidateRunIndex: 2, seed: 20260725, totalRuns: 2)
        #expect(drift.contains("field"), "header row must render")
        #expect(drift.contains("queryCount"), "score rows must render")
        #expect(drift.contains("structuredTier.provenPlanted"),
                "structured-tier rows must render when both sides carry the section")
        #expect(drift.contains("DRIFT"), "the perturbed field must show DRIFT")
        #expect(drift.contains("MATCH"), "matching fields must still be listed")
        #expect(drift.contains("[replay] verdict: DRIFT — 1 field(s) differ across runs"))

        let clean = renderReplayFieldTable(
            baseline: fpA, candidate: fpA, diffs: [],
            candidateRunIndex: 2, seed: 20260725, totalRuns: 2)
        #expect(clean.contains("[replay] verdict: DETERMINISTIC (2 runs, seed 20260725)"))
        #expect(!clean.contains("DRIFT"), "an all-MATCH table must carry no DRIFT verdicts")
    }

    // ── Test 7: tiered section present in one run but absent in other reports drift

    @Test("tiered section present in one run but absent in other reports section-presence drift")
    func tieredSectionPresenceIsDrift() {
        let scores = makeScores()
        let outcomeWith    = makeOutcomeWithTiered()
        let outcomeWithout = makeOutcomeBase()
        let fpWith    = ReplayFingerprint(scores: scores, outcome: outcomeWith)
        let fpWithout = ReplayFingerprint(scores: scores, outcome: outcomeWithout)
        // Baseline has tiered section, candidate does not: section-presence DRIFT.
        let diffs = compareReplayFingerprints(baseline: fpWith, candidate: fpWithout)
        let names = Set(diffs.map(\.fieldName))
        #expect(names.contains("tiered.present"),
                "section-presence diff must appear when tiered runs in one fingerprint only; got: \(names)")
        if let presenceDiff = diffs.first(where: { $0.fieldName == "tiered.present" }) {
            #expect(presenceDiff.baselineValue == "true",
                    "baseline must report 'true' for tiered.present; got '\(presenceDiff.baselineValue)'")
            #expect(presenceDiff.candidateValue == "false",
                    "candidate must report 'false' for tiered.present; got '\(presenceDiff.candidateValue)'")
        }
    }

    // ── Test 8: a tiered count field perturbed is reported ────────────────

    @Test("perturbing tier2Detected reports exactly that field")
    func tieredCountFieldPerturbedIsReported() {
        let scores = makeScores()
        // Two outcomes identical except tier2Detected.
        let outcomeA = makeOutcomeWithTiered(tier2Detected: 8)
        let outcomeB = makeOutcomeWithTiered(tier2Detected: 7)   // one fewer detected
        let fpA = ReplayFingerprint(scores: scores, outcome: outcomeA)
        let fpB = ReplayFingerprint(scores: scores, outcome: outcomeB)
        let diffs = compareReplayFingerprints(baseline: fpA, candidate: fpB)
        let names = Set(diffs.map(\.fieldName))
        #expect(names.contains("tiered.tier2Detected"),
                "tiered.tier2Detected must appear in diffs; got: \(names)")
        // Only tier2Detected changed; timing fields are excluded, so the diff
        // must have exactly one entry.
        #expect(diffs.count == 1,
                "exactly one tiered field must differ; got \(diffs.count): \(names)")
    }
}
