// CognitionVectorConformanceTests.swift
//
// The shared-vector conformance gate for the migration_ranking family
// (CognitionKit, BYCOPY_MIGRATION_001). One artifact —
// Fixtures/cognition_vectors.json — holds the inputs AND the expected
// outputs for every pure migration-ranking operation. This suite and
// the Rust `rust/tests/cognition_conformance.rs` both read it, so the
// two versions are gated against the SAME vectors instead of
// mirrored-by-copy literals. Floats are carried as bit-pattern hex
// strings ("0x3f800000") so equality is exact and JSON-precision-safe.
//
// Regenerate (after a DELIBERATE behavioral change only):
//   RECORD_COGNITION_VECTORS=1 swift test --filter CognitionVectorConformance
// then re-run both legs in verify mode. A mismatch in verify mode is a
// cross-version drift signal, never something to silence by re-recording.

import Testing
import Foundation
@testable import CognitionKit

// MARK: - Bit-pattern hex codecs

private func hex(_ value: Float) -> String { String(format: "0x%08x", value.bitPattern) }
private func float(_ s: String) -> Float { Float(bitPattern: UInt32(s.dropFirst(2), radix: 16)!) }

// MARK: - Vector schema (mirrored by rust/tests/cognition_conformance.rs)

private struct CognitionVectors: Codable {

    // firstDuplicate cases: `expected` is nil when no duplicate exists.
    struct FirstDuplicateCase: Codable {
        let names: [String]
        var expected: String?
    }

    // lostConcepts cases: expected is the sorted union of dropped + notFound.
    struct LostConceptsCase: Codable {
        let dropped: [String]
        let notFound: [String]
        var expected: [String]
    }

    // partitionOrigin cases: entries → (migratable, dropped) ids.
    struct PartitionEntry: Codable { let id: String; let content: String }
    struct PartitionOriginCase: Codable {
        let entries: [PartitionEntry]
        var expectedMigratable: [String]
        var expectedDropped: [String]
    }

    // migrationRank cases: PlanOutcome array → RankingResult fields.
    // Floats as f32 hex. winner is nil when the ranking is empty.
    struct OutcomeInput: Codable {
        let name: String
        let recallOverlap: String    // f32 hex (input)
        let meanReciprocalRank: String // f32 hex (input)
        let lost: [String]
    }
    struct RankedPlanEntry: Codable {
        let name: String
        let recallOverlap: String    // f32 hex
        let meanReciprocalRank: String // f32 hex
        let combinedScore: String    // f32 hex
    }
    struct DisqualifiedEntry: Codable {
        let name: String
        let lostConcepts: [String]
    }
    struct MigrationRankCase: Codable {
        let outcomes: [OutcomeInput]
        var expectedRankings: [RankedPlanEntry]
        var expectedDisqualified: [DisqualifiedEntry]
        var expectedWinner: String?
    }

    var firstDuplicate: [FirstDuplicateCase]
    var lostConcepts: [LostConceptsCase]
    var partitionOrigin: [PartitionOriginCase]
    var migrationRank: [MigrationRankCase]
}

// MARK: - The gate

@Suite("Cognition vector conformance (shared artifact, BYCOPY_MIGRATION_001)", .serialized)
struct CognitionVectorConformanceTests {

    private static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/cognition_vectors.json")
    }

    private func load() throws -> CognitionVectors {
        let data = try Data(contentsOf: Self.fixtureURL)
        return try JSONDecoder().decode(CognitionVectors.self, from: data)
    }

    private func computed(from vectors: CognitionVectors) -> CognitionVectors {
        var v = vectors

        // firstDuplicate: fill expected from the pure Swift function.
        v.firstDuplicate = vectors.firstDuplicate.map { c in
            var c = c
            c.expected = MigrationRanking.firstDuplicate(c.names)
            return c
        }

        // lostConcepts: fill expected.
        v.lostConcepts = vectors.lostConcepts.map { c in
            var c = c
            c.expected = MigrationRanking.lostConcepts(dropped: c.dropped, notFound: c.notFound)
            return c
        }

        // partitionOrigin: fill expectedMigratable and expectedDropped.
        v.partitionOrigin = vectors.partitionOrigin.map { c in
            var c = c
            let result = MigrationRanking.partitionOrigin(
                c.entries.map { (id: $0.id, content: $0.content) })
            c.expectedMigratable = result.migratable
            c.expectedDropped = result.dropped
            return c
        }

        // migrationRank: build PlanOutcome array, run rank(), fill expected fields.
        v.migrationRank = vectors.migrationRank.map { c in
            var c = c
            let outcomes = c.outcomes.map {
                MigrationRanking.PlanOutcome(
                    name: $0.name,
                    recallOverlap: float($0.recallOverlap),
                    meanReciprocalRank: float($0.meanReciprocalRank),
                    lost: $0.lost)
            }
            let result = MigrationRanking.rank(outcomes)
            c.expectedRankings = result.rankings.map {
                CognitionVectors.RankedPlanEntry(
                    name: $0.name,
                    recallOverlap: hex($0.recallOverlap),
                    meanReciprocalRank: hex($0.meanReciprocalRank),
                    combinedScore: hex($0.combinedScore))
            }
            c.expectedDisqualified = result.disqualified.map {
                CognitionVectors.DisqualifiedEntry(
                    name: $0.name, lostConcepts: $0.lostConcepts)
            }
            c.expectedWinner = result.winner
            return c
        }

        return v
    }

    @Test("every migration-ranking function reproduces the shared vectors")
    func migrationRankingReproducesSharedVectors() throws {
        let vectors = try load()
        let live = computed(from: vectors)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let expected = try encoder.encode(vectors)
        let actual = try encoder.encode(live)

        if ProcessInfo.processInfo.environment["RECORD_COGNITION_VECTORS"] == "1" {
            try actual.write(to: Self.fixtureURL)
            Issue.record(
                "RECORD MODE: re-recorded \(Self.fixtureURL.lastPathComponent); rerun in verify mode")
            return
        }

        #expect(expected == actual,
                "cross-version drift: migration_ranking no longer reproduces the shared vectors")
    }
}
