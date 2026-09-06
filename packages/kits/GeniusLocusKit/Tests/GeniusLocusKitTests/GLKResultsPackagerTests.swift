// GLKResultsPackagerTests.swift
//
// Golden-pin conformance tests for GLKResultsPackager (PACKAGER mission).
//
// Coverage:
//   A. never mode — fast path: rowsOnly, all hits returned, no cliff cutoff.
//   B. CONFIDENT gate — golden fixture: high margin + high lane agreement +
//      answer containment → level=l0AnswerOnly, confidence=confident.
//   C. INTERMEDIATE gate — golden fixture: moderate margin, low lane agreement
//      → level=l1Full, confidence=intermediate.
//   D. WEAK gate — golden fixture: very low margin (m1 < t1')
//      → level=rowsOnly, no answer block.
//   E. Cliff cutoff — verifies rows stop at the score cliff (cliffs at index 2
//      when the spec c=0.20 threshold is exceeded).
//   F. PackagerThresholds — decode from RecallTuningManifest JSON, partial JSON
//      fills spec defaults, and packagerThresholds projection matches manually
//      constructed PackagerThresholds.
//
// These tests form the Swift half of the dual-port conformance gate. The Rust
// twin (packager.rs) must produce the same gate branch for the same fixture
// inputs — verified in AriaMcpKit Rust tests against the same numeric seeds.
//
// No estate or async machinery required — GLKResultsPackager is a pure function.

import Testing
import Foundation
import LocusKit
@testable import GeniusLocusKit

// MARK: - Fixture helpers

/// Build a minimal Drawer suitable for containment signal tests.
private func makeDrawer(id: String = UUID().uuidString, content: String) -> LocusKit.Drawer {
    Drawer(
        id: id,
        content: content,
        parentNodeId: "test-wing-id",
        addedBy: "packager-test",
        filedAt: Date(timeIntervalSince1970: 0),
        embeddingModelID: "test-model-v1"
    )
}

/// Build a RecallHit with the given final score and dense score.
///
/// - Parameters:
///   - id: Drawer row identifier (RowID string).
///   - finalScore: Value used for scoring and margin computation.
///   - denseScore: Dense float-lane signal (for m3 spread computation).
///   - drawer: Optional hydrated drawer (required for m4 containment).
private func makeHit(
    id: String = UUID().uuidString,
    finalScore: Float,
    denseScore: Float = 0.5,
    drawer: LocusKit.Drawer? = nil
) -> RecallHit {
    RecallHit(
        id: id,
        drawer: drawer,
        sources: [.locusBitmap],
        score: RecallScoreVector(
            locus: finalScore,
            bm25: 0,
            vector: 0,
            fieldFit: 0,
            coOccurrence: 0,
            temporal: 0,
            graph: 0,
            preference: 0,
            redundancyPenalty: 0,
            final: finalScore,
            dense: denseScore
        ),
        explanation: []
    )
}

/// Build a minimal GLKRecallRequest for fixture use.
private let fixtureRequest = GLKRecallRequest(
    frame: RecallFrame(filterChain: []),
    mode: .locusOnly,
    scoring: .raw,
    limit: 20,
    fallback: .failClosed,
    origin: .internal
)

/// Build a minimal RecallPlan for fixture use.
private let fixturePlan = RecallPlan(
    effectiveMode: .locusOnly,
    frontierK: 64,
    weights: .uniform
)

/// Build a GLKRecallResult from hits and an optional union profile.
private func makeResult(
    hits: [RecallHit],
    signalAgreement: Float = 0.0
) -> GLKRecallResult {
    let profile: RecallUnionProfile? = signalAgreement > 0
        ? RecallUnionProfile(
            locusSharpness: 0.5,
            bm25Sharpness: 0.0,
            vectorSharpness: 0.0,
            signalAgreement: signalAgreement,
            redundancy: 0.0,
            matrixCoherence: 0.0
          )
        : nil
    return GLKRecallResult(
        request: fixtureRequest,
        plan: fixturePlan,
        unionProfile: profile,
        hits: hits,
        denseLaneStatus: nil,
        degradedStages: [],
        laneRanks: [:],
        queryLatticeAnchor: nil
    )
}

// MARK: - Test suite

@Suite("GLKResultsPackager — gate branches and modes")
struct GLKResultsPackagerTests {

    private let packager = GLKResultsPackager()
    private let thresholds = PackagerThresholds.default // t1=0.25, t2=0.50, t1'=0.05, t3'=0.10, c=0.20, kMin=3, kMax=20

    // MARK: A — never mode fast path

    /// Golden pin A: answer:never → rowsOnly, all hits, no cliff cutoff.
    ///
    /// The never path is the byte-identical-to-today fast path; the packager
    /// must return ALL hits from the result unchanged, with level=rowsOnly and
    /// no answer block. The cliff cutoff is explicitly NOT applied.
    @Test("never mode returns rowsOnly with all hits (golden pin A)")
    func neverModeReturnsAllHits() {
        let hits = [
            makeHit(id: "h1", finalScore: 0.9),
            makeHit(id: "h2", finalScore: 0.7),
            makeHit(id: "h3", finalScore: 0.5),
            makeHit(id: "h4", finalScore: 0.3),
            makeHit(id: "h5", finalScore: 0.1),
        ]
        let result = makeResult(hits: hits)
        let packaged = packager.package(result: result, mode: .never, composedAnswer: nil)

        // Golden pins: level=rowsOnly, no block, all 5 hits, totalCount=5.
        #expect(packaged.level == .rowsOnly)
        #expect(packaged.answerBlock == nil)
        #expect(packaged.rows.count == 5)
        #expect(packaged.totalCount == 5)
        // The first and last row IDs must match (order preserved).
        #expect(packaged.rows.first?.id == "h1")
        #expect(packaged.rows.last?.id == "h5")
    }

    // MARK: B — CONFIDENT gate (golden pin)

    /// Golden pin B: CONFIDENT fixture.
    ///
    /// Fixture:
    ///   hits[0].final = 0.90, hits[1].final = 0.30
    ///   → m1 = (0.90−0.30)/0.90 = 0.667 (rounded: 0.67) ≥ t1=0.25 ✓
    ///   signalAgreement = 0.80 → m2 = 0.80 ≥ t2=0.50 ✓
    ///   dense scores: [0.9, 0.5] → spread ≈ 0.2 ≥ t3'=0.10 ✓ (not WEAK)
    ///   m4: answer "fruit banana content" appears in drawer content ✓
    ///   → gate: CONFIDENT
    ///   mode=auto → level=l0AnswerOnly, confidence=confident.
    @Test("auto mode CONFIDENT gate returns l0AnswerOnly (golden pin B)")
    func autoConfidentGateL0() {
        // The drawer content for the top hit — the answer text must have ≥60%
        // of its distinctive words present here (distinctiv = length > 3, not stopword).
        let topDrawer = makeDrawer(
            id: "drawer-B",
            content: "fruit banana mango recall content test paragraph information"
        )
        // Answer text: distinctive words "fruit", "banana", "information" → all in content.
        let answer = "fruit banana information"

        let hits = [
            makeHit(id: "h-B1", finalScore: 0.90, denseScore: 0.90, drawer: topDrawer),
            makeHit(id: "h-B2", finalScore: 0.30, denseScore: 0.50),
        ]
        // signalAgreement=0.80 → m2=0.80 ≥ t2=0.50
        let result = makeResult(hits: hits, signalAgreement: 0.80)
        let packaged = packager.package(
            result: result,
            mode: .auto,
            composedAnswer: answer,
            thresholds: thresholds
        )

        // Golden pins.
        #expect(packaged.level == .l0AnswerOnly)
        #expect(packaged.answerBlock != nil)
        #expect(packaged.answerBlock?.confidence == .confident)
        // L0: no rows sent to the client (answer only).
        #expect(packaged.rows.isEmpty)
        // totalCount carries the real hit count.
        #expect(packaged.totalCount == 2)
    }

    // MARK: Citations and the empty-answer containment rule
    // (Rust twin: packager_parity.rs `citations_are_the_first_five_hydrated_hits`
    // and `auto_with_no_answer_text_never_reaches_confident`)

    /// Seven hits, two of them unhydrated (a tombstoned row the lane still
    /// scored). The block's citation ids are the first five hits filtered to
    /// the hydrated ones: `hits.prefix(5).compactMap { $0.drawer?.id }`.
    @Test("citations are the first five hydrated hits")
    func citationsAreTheFirstFiveHydratedHits() {
        let content = "fruit banana mango recall content test paragraph information"
        // Top margin (0.90 → 0.30) clears t1; the tail steps down by 0.05.
        let hits: [RecallHit] = (0..<7).map { i in
            let score: Float = i == 0 ? 0.90 : 0.30 - 0.05 * Float(i - 1)
            let drawer = (i == 1 || i == 3) ? nil : makeDrawer(id: "h-\(i)", content: content)
            return makeHit(id: "h-\(i)", finalScore: score, denseScore: score, drawer: drawer)
        }
        let packaged = packager.package(
            result: makeResult(hits: hits, signalAgreement: 0.80),
            mode: .auto,
            composedAnswer: "fruit banana information",
            thresholds: thresholds
        )
        #expect(packaged.answerBlock?.confidence == .confident)
        #expect(packaged.answerBlock?.citationIDs == ["h-0", "h-2", "h-4"])
    }

    /// With no composed answer the containment signal is undefined and reads
    /// false, so the gate never reaches CONFIDENT and, with no text to show,
    /// no block is emitted: auto degrades to rowsOnly whatever the margins say.
    @Test("auto with no answer text never reaches CONFIDENT")
    func autoWithNoAnswerTextNeverReachesConfident() {
        let content = "fruit banana mango recall content test paragraph information"
        let hits = [
            makeHit(id: "h-0", finalScore: 0.90, denseScore: 0.90, drawer: makeDrawer(id: "h-0", content: content)),
            makeHit(id: "h-1", finalScore: 0.30, denseScore: 0.50, drawer: makeDrawer(id: "h-1", content: content)),
        ]
        let result = makeResult(hits: hits, signalAgreement: 0.80)
        let withAnswer = packager.package(
            result: result, mode: .auto, composedAnswer: "fruit banana information", thresholds: thresholds)
        #expect(withAnswer.answerBlock?.confidence == .confident, "control: the same hits reach CONFIDENT with a contained answer")
        let without = packager.package(result: result, mode: .auto, composedAnswer: nil, thresholds: thresholds)
        #expect(without.answerBlock == nil)
        #expect(without.level == .rowsOnly)
    }

    // MARK: C — INTERMEDIATE gate (golden pin)

    /// Golden pin C: INTERMEDIATE fixture.
    ///
    /// Fixture:
    ///   hits[0].final = 0.70, hits[1].final = 0.40
    ///   → m1 = (0.70−0.40)/0.70 ≈ 0.43 ≥ t1=0.25 ✓
    ///   signalAgreement = 0.30 → m2 = 0.30 < t2=0.50 → CONFIDENT fails
    ///   dense scores varied → m3 ≥ t3'=0.10 (not WEAK on m3)
    ///   m1=0.43 ≥ t1'=0.05 (not WEAK on m1)
    ///   → gate: INTERMEDIATE
    ///   mode=auto → level=l1Full, confidence=intermediate.
    @Test("auto mode INTERMEDIATE gate returns l1Full (golden pin C)")
    func autoIntermediateGateL1() {
        let answer = "moderate recall result intermediate"
        let hits = [
            makeHit(id: "h-C1", finalScore: 0.70, denseScore: 0.80),
            makeHit(id: "h-C2", finalScore: 0.40, denseScore: 0.50),
            makeHit(id: "h-C3", finalScore: 0.30, denseScore: 0.30),
        ]
        // signalAgreement=0.30 → m2=0.30 < t2=0.50 → CONFIDENT gate fails.
        let result = makeResult(hits: hits, signalAgreement: 0.30)
        let packaged = packager.package(
            result: result,
            mode: .auto,
            composedAnswer: answer,
            thresholds: thresholds
        )

        // Golden pins.
        #expect(packaged.level == .l1Full)
        #expect(packaged.answerBlock != nil)
        #expect(packaged.answerBlock?.confidence == .intermediate)
        // L1: rows included (cliff cutoff may trim, but kMin=3 so at least 3 rows).
        #expect(packaged.rows.count >= thresholds.kMin)
        #expect(packaged.totalCount == 3)
    }

    // MARK: D — WEAK gate (golden pin)

    /// Golden pin D: WEAK fixture.
    ///
    /// Fixture:
    ///   hits[0].final = 0.52, hits[1].final = 0.50
    ///   → m1 = (0.52−0.50)/0.52 ≈ 0.038 < t1'=0.05 → WEAK fires
    ///   → gate: WEAK
    ///   mode=auto → level=rowsOnly, no answer block.
    @Test("auto mode WEAK gate returns rowsOnly with no answer block (golden pin D)")
    func autoWeakGateRowsOnly() {
        let hits = [
            makeHit(id: "h-D1", finalScore: 0.520, denseScore: 0.5),
            makeHit(id: "h-D2", finalScore: 0.500, denseScore: 0.5),
            makeHit(id: "h-D3", finalScore: 0.480, denseScore: 0.5),
        ]
        // signalAgreement irrelevant — WEAK fires on m1 before reaching CONFIDENT.
        let result = makeResult(hits: hits, signalAgreement: 0.80)
        let packaged = packager.package(
            result: result,
            mode: .auto,
            composedAnswer: "some answer text",
            thresholds: thresholds
        )

        // Golden pins.
        #expect(packaged.level == .rowsOnly)
        #expect(packaged.answerBlock == nil)
        // totalCount reflects true hit count.
        #expect(packaged.totalCount == 3)
    }

    // MARK: E — cliff cutoff

    /// Cliff cutoff: scores cliff steeply after the fourth row.
    ///
    /// Fixture (7 hits, scores: 0.90, 0.85, 0.80, 0.75, 0.20, 0.18, 0.16):
    ///   n=7, kMin=3, kMax=7
    ///   spread = score[0] - score[6] = 0.90 - 0.16 = 0.74
    ///   threshold = 0.20 × 0.74 = 0.148
    ///   Loop starts at i=kMin=3:
    ///     i=3: gap = hits[3]-hits[4] = 0.75-0.20 = 0.55 ≥ 0.148 → cliff fires, cutoff=4.
    ///   Returns 4 rows (c1..c4). The algorithm always includes at least kMin=3 rows,
    ///   then checks for cliffs beyond kMin.
    @Test("cliff cutoff stops at score cliff between rows 4 and 5 (golden pin E)")
    func cliffCutoffStopsAtCliff() {
        let hits = [
            makeHit(id: "c1", finalScore: 0.90, denseScore: 0.90),
            makeHit(id: "c2", finalScore: 0.85, denseScore: 0.80),
            makeHit(id: "c3", finalScore: 0.80, denseScore: 0.70),
            makeHit(id: "c4", finalScore: 0.75, denseScore: 0.65),
            makeHit(id: "c5", finalScore: 0.20, denseScore: 0.20),
            makeHit(id: "c6", finalScore: 0.18, denseScore: 0.15),
            makeHit(id: "c7", finalScore: 0.16, denseScore: 0.10),
        ]
        // High margin + lane agreement so INTERMEDIATE gate fires (not WEAK).
        let result = makeResult(hits: hits, signalAgreement: 0.30)
        let packaged = packager.package(
            result: result,
            mode: .auto,
            composedAnswer: "answer text here",
            thresholds: thresholds
        )

        // The cliff at index 3→4 (0-indexed) fires: cutoff=4. The row at index 4
        // (c5, score 0.20) is excluded.
        #expect(packaged.rows.count == 4)
        #expect(packaged.rows.last?.id == "c4")
    }

    // MARK: E2 — always mode, kMin floor holds when no cliff fires

    /// With only 3 hits total (n=3, kMax=3), the loop is empty (i in 3..<3)
    /// and cutoff = kMin = 3. All 3 rows are returned.
    ///
    /// Dense scores must be spread wide (0.90, 0.50, 0.10) to keep m3 above
    /// the WEAK t3' floor of 0.10: stddev([0.90,0.50,0.10]) ≈ 0.327 ≥ 0.10.
    /// m1 = (0.90−0.85)/0.90 ≈ 0.056 < t1=0.25 so CONFIDENT does not fire
    /// and signalAgreement=0.40 < t2=0.50 also prevents CONFIDENT → INTERMEDIATE.
    @Test("always mode returns l1Full with all hits when no cliff fires")
    func alwaysModeAllHitsWhenNoCliff() {
        let hits = [
            makeHit(id: "a1", finalScore: 0.90, denseScore: 0.90),
            makeHit(id: "a2", finalScore: 0.85, denseScore: 0.50),
            makeHit(id: "a3", finalScore: 0.80, denseScore: 0.10),
        ]
        let result = makeResult(hits: hits, signalAgreement: 0.40)
        let packaged = packager.package(
            result: result,
            mode: .always,
            composedAnswer: "answer text",
            thresholds: thresholds
        )

        // always mode: l1Full + answer block + all rows (no cliff, n=kMin).
        #expect(packaged.level == .l1Full)
        #expect(packaged.answerBlock != nil)
        // n=3 = kMin; loop is empty; all 3 rows returned.
        #expect(packaged.rows.count == 3)
    }
}

// MARK: - PackagerThresholds decode tests

@Suite("PackagerThresholds — RecallTuningManifest projection")
struct PackagerThresholdsDecodeTests {

    // MARK: F1 — default projection matches .default

    @Test("RecallTuningManifest.default.packagerThresholds equals PackagerThresholds.default")
    func defaultManifestProjectsToDefaultThresholds() {
        let manifest = RecallTuningManifest.default
        let projected = manifest.packagerThresholds
        #expect(projected == PackagerThresholds.default)
    }

    // MARK: F2 — partial JSON (packager keys absent) fills spec defaults

    @Test("manifest decoded from JSON with no packager keys projects to spec-default thresholds")
    func partialJSONFillsPackagerDefaults() throws {
        // Only classic tuning keys present — packager keys absent.
        let json = #"{"rrf_k": 80, "mmr_lambda": 0.6}"#.data(using: .utf8)!
        let manifest = try JSONDecoder().decode(RecallTuningManifest.self, from: json)
        let projected = manifest.packagerThresholds
        // All packager threshold fields must equal the spec defaults.
        #expect(abs(projected.t1 - 0.25) < 1e-9)
        #expect(abs(projected.t2 - 0.50) < 1e-9)
        #expect(abs(projected.t1Prime - 0.05) < 1e-9)
        #expect(abs(projected.t3Prime - 0.10) < 1e-9)
        #expect(abs(projected.c - 0.20) < 1e-9)
        #expect(projected.kMin == 3)
        #expect(projected.kMax == 20)
    }

    // MARK: F3 — golden pin: custom packager keys round-trip

    @Test("manifest with custom packager keys round-trips exactly (golden pin F)")
    func goldenPinPackagerThresholds() throws {
        // Golden pin: t1=0.30, t2=0.60, t1'=0.08, t3'=0.15, c=0.25, kMin=5, kMax=15.
        let json = #"""
        {
            "rrf_k": 60,
            "mmr_lambda": 0.7,
            "packager_t1": 0.30,
            "packager_t2": 0.60,
            "packager_t1_prime": 0.08,
            "packager_t3_prime": 0.15,
            "packager_c": 0.25,
            "packager_k_min": 5,
            "packager_k_max": 15
        }
        """#.data(using: .utf8)!
        let manifest = try JSONDecoder().decode(RecallTuningManifest.self, from: json)
        let projected = manifest.packagerThresholds

        // Golden pin: exact values from the JSON.
        #expect(abs(projected.t1 - 0.30) < 1e-9)
        #expect(abs(projected.t2 - 0.60) < 1e-9)
        #expect(abs(projected.t1Prime - 0.08) < 1e-9)
        #expect(abs(projected.t3Prime - 0.15) < 1e-9)
        #expect(abs(projected.c - 0.25) < 1e-9)
        #expect(projected.kMin == 5)
        #expect(projected.kMax == 15)
        // Verify the projected value equals the manually constructed one.
        let manual = PackagerThresholds(
            t1: 0.30, t2: 0.60, t1Prime: 0.08, t3Prime: 0.15,
            c: 0.25, kMin: 5, kMax: 15
        )
        #expect(projected == manual)
    }
}
