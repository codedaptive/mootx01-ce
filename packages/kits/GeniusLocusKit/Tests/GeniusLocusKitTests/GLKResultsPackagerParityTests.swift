// GLKResultsPackagerParityTests.swift
//
// Cross-port conformance test for GLKResultsPackager (Adams Finding 7).
//
// Reads ONE shared JSON fixture at
//   Tests/Conformance/packager_golden_pins.json
// and asserts identical level/confidence/has_answer_block/row_count per
// gate branch — the golden-pin-twin discipline: one fixture, two ports,
// same assertions.
//
// The Rust twin is
//   rust/tests/packager_parity.rs
// and must pass on the same fixture with the same expected values.
//
// No estate or async machinery required — GLKResultsPackager is a pure function.
// Fixture location is resolved at runtime via #filePath so the test needs no
// SwiftPM resources declaration and works identically under swift test and Xcode.

import Testing
import Foundation
import LocusKit
@testable import GeniusLocusKit

// MARK: - Fixture types

private struct PackagerFixture: Decodable {
    let thresholds: ThresholdFixture
    let pins: [Pin]
}

private struct ThresholdFixture: Decodable {
    let t1: Double
    let t2: Double
    let t1_prime: Double   // swiftlint:disable:this identifier_name
    let t3_prime: Double   // swiftlint:disable:this identifier_name
    let c: Double
    let k_min: Int         // swiftlint:disable:this identifier_name
    let k_max: Int         // swiftlint:disable:this identifier_name
}

private struct Pin: Decodable {
    let id: String
    let mode: String
    let composed_answer: String?   // swiftlint:disable:this identifier_name
    let hits: [HitFixture]
    let expected: ExpectedFixture
}

// Per hit, span_cosine and lexical_rank are the span rerank stage's evidence:
// the best span cosine under the active encoder and the item's 1-based rank in
// the lexical head. Both null means the stage did not score the hit.
private struct HitFixture: Decodable {
    let id: String
    let final_score: Float         // swiftlint:disable:this identifier_name
    let span_cosine: Float?        // swiftlint:disable:this identifier_name
    let lexical_rank: Int?         // swiftlint:disable:this identifier_name
    let drawer_content: String?    // swiftlint:disable:this identifier_name
}

private struct ExpectedFixture: Decodable {
    let level: String
    let confidence: String?
    let has_answer_block: Bool     // swiftlint:disable:this identifier_name
    let row_count: Int             // swiftlint:disable:this identifier_name
    let total_count: Int           // swiftlint:disable:this identifier_name
}

// MARK: - Fixture helpers (mirrors GLKResultsPackagerTests.swift)

/// Build a minimal Drawer for containment signal tests.
private func makeDrawer(id: String, content: String) -> Drawer {
    Drawer(
        id: id,
        content: content,
        parentNodeId: "test-wing-id",
        addedBy: "packager-parity-test",
        filedAt: Date(timeIntervalSince1970: 0),
        embeddingModelID: "test-model-v1"
    )
}

/// Build a RecallHit from fixture values.
///
/// Attaches a `SpanRerankHit` when `span_cosine` is present so the packager's
/// footrule (m2) and cosine spread (m3) read the span evidence from the fixture.
private func makeHit(from hf: HitFixture) -> RecallHit {
    let drawer: Drawer? = hf.drawer_content.map { makeDrawer(id: hf.id, content: $0) }
    let spanHit: SpanRerankHit? = hf.span_cosine.map { cosine in
        SpanRerankHit(
            itemID: hf.id,
            bestSpanIndex: 0,
            bestSpanStart: 0,
            bestSpanEnd: 0,
            cosine: cosine,
            bm25Rank: hf.lexical_rank ?? 0)
    }
    return RecallHit(
        id: hf.id,
        drawer: drawer,
        sources: [.locusBitmap],
        score: RecallScoreVector(
            locus: hf.final_score,
            bm25: 0,
            vector: 0,
            fieldFit: 0,
            coOccurrence: 0,
            temporal: 0,
            graph: 0,
            preference: 0,
            redundancyPenalty: 0,
            final: hf.final_score,
            dense: 0
        ),
        explanation: [],
        spanHit: spanHit
    )
}

/// Build a GLKRecallResult from fixture hits.
///
/// m2 and m3 are now derived from SpanRerankHit evidence on each hit, so
/// no signal_agreement profile is needed.
private func makeResult(hits: [RecallHit]) -> GLKRecallResult {
    return GLKRecallResult(
        request: GLKRecallRequest(
            frame: RecallFrame(filterChain: []),
            mode: .locusOnly,
            scoring: .raw,
            limit: 20,
            fallback: .failClosed,
            origin: .internal
        ),
        plan: RecallPlan(effectiveMode: .locusOnly, frontierK: 64, weights: .uniform),
        unionProfile: nil,
        hits: hits,
        degradedStages: [],
        laneRanks: [:],
        queryLatticeAnchor: nil
    )
}

/// Parse mode string from fixture.
private func parseMode(_ s: String) -> PackagerAnswerMode {
    switch s {
    case "never": return .never
    case "always": return .always
    case "auto": return .auto
    default: fatalError("Unknown mode in fixture: \(s)")
    }
}

// MARK: - Test suite

@Suite("GLKResultsPackager — cross-port golden pins (parity twin)")
struct GLKResultsPackagerParityTests {

    private let packager = GLKResultsPackager()

    /// Resolve the shared fixture path from this Swift file's location.
    ///
    /// #filePath gives the absolute path of this source file at compile time.
    /// The fixture is at: Tests/Conformance/packager_golden_pins.json
    /// This file is at:   Tests/GeniusLocusKitTests/<this file>
    private func fixtureURL() -> URL {
        let thisFile = URL(fileURLWithPath: #filePath)
        return thisFile
            .deletingLastPathComponent()            // GeniusLocusKitTests/
            .deletingLastPathComponent()            // Tests/
            .appendingPathComponent("Conformance")
            .appendingPathComponent("packager_golden_pins.json")
    }

    @Test("all golden pins match Rust twin (packager_parity.rs)")
    func allPinsMatchRustTwin() throws {
        let url = fixtureURL()
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        let fixture = try decoder.decode(PackagerFixture.self, from: data)

        let thresholds = PackagerThresholds(
            t1: fixture.thresholds.t1,
            t2: fixture.thresholds.t2,
            t1Prime: fixture.thresholds.t1_prime,
            t3Prime: fixture.thresholds.t3_prime,
            c: fixture.thresholds.c,
            kMin: fixture.thresholds.k_min,
            kMax: fixture.thresholds.k_max
        )

        for pin in fixture.pins {
            let hits = pin.hits.map { makeHit(from: $0) }
            let result = makeResult(hits: hits)
            let mode = parseMode(pin.mode)
            let packaged = packager.package(
                result: result,
                mode: mode,
                composedAnswer: pin.composed_answer,
                thresholds: thresholds
            )

            // Assert level.
            let actualLevel = levelTag(packaged.level)
            #expect(
                actualLevel == pin.expected.level,
                "[\(pin.id)] level: expected '\(pin.expected.level)', got '\(actualLevel)'"
            )

            // Assert has_answer_block.
            let hasBlock = packaged.answerBlock != nil
            #expect(
                hasBlock == pin.expected.has_answer_block,
                "[\(pin.id)] has_answer_block: expected \(pin.expected.has_answer_block), got \(hasBlock)"
            )

            // Assert confidence when expected.
            if let expectedConf = pin.expected.confidence {
                guard let block = packaged.answerBlock else {
                    Issue.record("[\(pin.id)] expected answer block with confidence '\(expectedConf)', got nil")
                    continue
                }
                let actualConf = confidenceTag(block.confidence)
                #expect(
                    actualConf == expectedConf,
                    "[\(pin.id)] confidence: expected '\(expectedConf)', got '\(actualConf)'"
                )
            } else {
                // WEAK: spec §5 — no answer block universally.
                #expect(
                    packaged.answerBlock == nil,
                    "[\(pin.id)] expected no answer block (WEAK), but got Some"
                )
            }

            // Assert row_count.
            #expect(
                packaged.rows.count == pin.expected.row_count,
                "[\(pin.id)] row_count: expected \(pin.expected.row_count), got \(packaged.rows.count)"
            )

            // Assert total_count.
            #expect(
                packaged.totalCount == pin.expected.total_count,
                "[\(pin.id)] total_count: expected \(pin.expected.total_count), got \(packaged.totalCount)"
            )
        }
    }
}

// MARK: - String helpers

private func levelTag(_ level: GLKResponseLevel) -> String {
    switch level {
    case .l0AnswerOnly: return "l0AnswerOnly"
    case .l1Full:       return "l1Full"
    case .rowsOnly:     return "rowsOnly"
    }
}

private func confidenceTag(_ confidence: PackagerConfidenceLevel) -> String {
    switch confidence {
    case .confident:    return "confident"
    case .intermediate: return "intermediate"
    case .weak:         return "weak"
    }
}
