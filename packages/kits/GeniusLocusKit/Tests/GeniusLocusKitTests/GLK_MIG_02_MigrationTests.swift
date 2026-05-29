// GLK_MIG_02_MigrationTests.swift
//
// Conformance tests for the GeniusLocusKit migration API (GLK-MIG-02).
//
// Tests are written RED-first: they compile against the type
// declarations introduced in Parts 2-4. All nine test cases document
// the API contract before any production code lands.
//
// The nine tests cover:
//   1. importFromMemPalace creates drawers for each entry
//   2. importFromMemPalace never silently drops entries (C-13 zero-loss)
//   3. importFromMemPalace empty corpus returns empty report
//   4. runParallel writes to target in .writeToTarget mode
//   5. runParallel stop() prevents further captures
//   6. verifyMigration returns .identical for fully migrated corpus
//   7. verifyMigration returns .diverged for missing entry
//   8. MigrationReport is fully Sendable (compile-time check)
//   9. ExternalCorpus round-trip encode/decode via URL

import XCTest
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import GeniusLocusKit

final class GLK_MIG_02_MigrationTests: XCTestCase {

    // MARK: - Fixtures

    /// A minimal `InMemoryStorage` opened as a fresh estate.
    private func makeKit() -> GeniusLocusKit {
        GeniusLocusKit()
    }

    private func makeOwner() -> OwnerCredentials {
        OwnerCredentials(ownerIdentifier: "test-owner")
    }

    private func makeStorage() -> InMemoryStorage {
        let config = EstateConfiguration(
            estateID: UUID(),
            backend: .inMemory
        )
        return InMemoryStorage(configuration: config)
    }

    /// Build an ExternalCorpus with n entries whose content is unique
    /// enough that the content-match filter can distinguish them.
    private func makeCorpus(count: Int, prefix: String = "migration-test") -> ExternalCorpus {
        let entries = (0..<count).map { i in
            ExternalEntry(
                id: "\(prefix)-entry-\(i)",
                content: "Unique content for \(prefix) entry \(i): the quick brown fox",
                tags: ["tag-\(i)"]
            )
        }
        return ExternalCorpus(name: "\(prefix)-corpus", entries: entries)
    }

    // MARK: - Test 1: importFromMemPalace creates drawers for each entry

    func testImportFromMemPalaceCreatesDrawersForEachEntry() async throws {
        let kit = makeKit()
        let corpus = makeCorpus(count: 3)
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

        let (handle, report) = try await kit.importFromMemPalace(
            corpus,
            targetStorage: makeStorage(),
            owner: makeOwner(),
            now: now
        )

        // The report must record exactly 3 drawer rows.
        XCTAssertEqual(report.rowsByNoun["drawer"], 3,
            "importFromMemPalace must create one drawer per corpus entry")

        // The opened estate must contain the captured drawers.
        let frame = RecallFrame(
            filterChain: [.unconfirmed],
            hydrationLevel: .structured,
            ordering: .byCaptureTimeDesc
        )
        let rows = try await kit.recall(handle, frame)
        XCTAssertEqual(rows.count, 3,
            "Three drawers must be present in the target estate")
    }

    // MARK: - Test 2: importFromMemPalace never silently drops entries (C-13)

    func testImportFromMemPalaceNeverSilentlyDropsEntries() async throws {
        let kit = makeKit()
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

        // Mix of valid and empty-content entries. Empty entries are
        // unmappable but must still appear in the report as unmapped,
        // not silently discarded (spec conformance C-13 zero-loss invariant).
        let entries = [
            ExternalEntry(id: "e1", content: "Real content alpha", tags: []),
            ExternalEntry(id: "e2", content: "", tags: []),   // empty — unmappable
            ExternalEntry(id: "e3", content: "Real content beta", tags: []),
        ]
        let corpus = ExternalCorpus(name: "partial", entries: entries)

        let (_, report) = try await kit.importFromMemPalace(
            corpus,
            targetStorage: makeStorage(),
            owner: makeOwner(),
            now: now
        )

        let totalAccounted = (report.rowsByNoun["drawer"] ?? 0)
            + report.unmappedConcepts.count
        XCTAssertEqual(totalAccounted, 3,
            "Every entry must appear in drawers or unmappedConcepts — none dropped")
    }

    // MARK: - Test 3: importFromMemPalace empty corpus returns empty report

    func testImportFromMemPalaceEmptyCorpusReturnsEmptyReport() async throws {
        let kit = makeKit()
        let corpus = ExternalCorpus(name: "empty", entries: [])
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

        let (_, report) = try await kit.importFromMemPalace(
            corpus,
            targetStorage: makeStorage(),
            owner: makeOwner(),
            now: now
        )

        XCTAssertNil(report.rowsByNoun["drawer"],
            "No drawers should be created for an empty corpus")
        XCTAssertTrue(report.unmappedConcepts.isEmpty,
            "No unmapped concepts for an empty corpus")
        XCTAssertTrue(report.warnings.isEmpty,
            "No warnings for an empty corpus")
    }

    // MARK: - Test 4: runParallel writes to target in .writeToTarget mode

    func testRunParallelWritesToTargetInWriteToTargetMode() async throws {
        let kit = makeKit()
        let owner = makeOwner()
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let source = try await kit.open(storage: makeStorage(), owner: owner)
        let target = try await kit.open(storage: makeStorage(), owner: owner)

        let handle = try await kit.runParallel(source: source, target: target, mode: .writeToTarget)

        let frame = CaptureFrame(
            content: "Parallel run test content",
            channel: .typed,
            room: "migration",
            latticeAnchor: .udc("000"),
            addedBy: "test",
            embeddingModelID: "test-v1"
        )
        // Capture via the parallel handle — should land in target.
        _ = try await handle.capture(frame)

        // Target should have one drawer; source should have none.
        let targetRecall = RecallFrame(
            filterChain: [.unconfirmed],
            hydrationLevel: .structured,
            ordering: .byCaptureTimeDesc
        )
        let targetRows = try await kit.recall(target, targetRecall)
        XCTAssertEqual(targetRows.count, 1,
            ".writeToTarget mode must route captures to the target estate")

        let _ = now // suppress unused-var warning — now is part of the test's fixture intent
    }

    // MARK: - Test 5: runParallel stop() prevents further captures

    func testRunParallelStopPreventsFurtherCaptures() async throws {
        let kit = makeKit()
        let owner = makeOwner()
        let source = try await kit.open(storage: makeStorage(), owner: owner)
        let target = try await kit.open(storage: makeStorage(), owner: owner)

        let handle = try await kit.runParallel(source: source, target: target, mode: .writeToTarget)
        await handle.stop()

        let frame = CaptureFrame(
            content: "Should not be captured",
            channel: .typed,
            room: "migration",
            latticeAnchor: .udc("000"),
            addedBy: "test",
            embeddingModelID: "test-v1"
        )
        do {
            _ = try await handle.capture(frame)
            XCTFail("capture after stop() must throw MigrationError.parallelRunStopped")
        } catch let err as MigrationError {
            XCTAssertEqual(err, .parallelRunStopped,
                "stop() must cause subsequent captures to throw .parallelRunStopped")
        }
    }

    // MARK: - Test 6: verifyMigration returns .identical for fully migrated corpus

    func testVerifyMigrationReturnIdenticalForFullyMigratedCorpus() async throws {
        let kit = makeKit()
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

        // Import a corpus so all entries are present in the estate.
        let corpus = makeCorpus(count: 2, prefix: "verify-identical")
        let (handle, _) = try await kit.importFromMemPalace(
            corpus,
            targetStorage: makeStorage(),
            owner: makeOwner(),
            now: now
        )

        let result = try await kit.verifyMigration(estate: handle, against: corpus, now: now)

        // importFromMemPalace captured all entries by content; verifyMigration
        // uses content-match recall so every entry should be found.
        switch result {
        case .identical:
            break // expected
        case .diverged(let divergences):
            XCTFail("Expected .identical but got .diverged with \(divergences.count) divergences: \(divergences.map { $0.entryID })")
        }
    }

    // MARK: - Test 7: verifyMigration returns .diverged for missing entry

    func testVerifyMigrationReturnsDivergedForMissingEntry() async throws {
        let kit = makeKit()
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

        // Import only one entry, then verify against a two-entry corpus.
        let partialCorpus = makeCorpus(count: 1, prefix: "verify-diverged")
        let (handle, _) = try await kit.importFromMemPalace(
            partialCorpus,
            targetStorage: makeStorage(),
            owner: makeOwner(),
            now: now
        )

        // Build a larger corpus that includes an entry the estate does not have.
        let fullCorpus = makeCorpus(count: 2, prefix: "verify-diverged")

        let result = try await kit.verifyMigration(estate: handle, against: fullCorpus, now: now)

        switch result {
        case .identical:
            XCTFail("Expected .diverged when corpus has entry not in estate")
        case .diverged(let divergences):
            XCTAssertEqual(divergences.count, 1,
                "One missing entry should produce exactly one divergence")
            XCTAssertEqual(divergences.first?.entryID, "verify-diverged-entry-1",
                "The diverged entry should be the one not imported")
        }
    }

    // MARK: - Test 8: MigrationReport is fully Sendable (compile-time check)

    /// This test validates the compile-time `Sendable` conformance of
    /// `MigrationReport`. If the struct or any of its fields is not
    /// `Sendable`, this actor-boundary crossing will fail to compile.
    func testMigrationReportIsFullySendable() async throws {
        let report = MigrationReport(
            rowsByNoun: ["drawer": 1],
            unmappedConcepts: [UnmappedConcept(entryID: "x", reason: "test")],
            warnings: [MigrationWarning(message: "test warning")]
        )

        // Cross an actor boundary. The compiler rejects non-Sendable
        // values here, turning the conformance requirement into a
        // build-time gate.
        let captured: MigrationReport = await Task.detached { report }.value

        XCTAssertEqual(captured.rowsByNoun["drawer"], 1)
        XCTAssertEqual(captured.unmappedConcepts.count, 1)
        XCTAssertEqual(captured.warnings.count, 1)
    }

    // MARK: - Test 9: ExternalCorpus round-trip encode/decode via URL

    func testExternalCorpusLoadFromURL() throws {
        let original = ExternalCorpus(
            name: "round-trip-test",
            entries: [
                ExternalEntry(id: "rt-1", content: "Content one", tags: ["a", "b"]),
                ExternalEntry(id: "rt-2", content: "Content two", tags: []),
            ]
        )

        // Encode to a temp file, then decode via ExternalCorpus.load(from:).
        let encoded = try JSONEncoder().encode(original)
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("GLK_MIG_02_roundtrip_\(UUID().uuidString).json")
        try encoded.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let decoded = try ExternalCorpus.load(from: url)
        XCTAssertEqual(decoded, original,
            "ExternalCorpus must round-trip through JSON encode/decode")
        XCTAssertEqual(decoded.entries.count, 2)
        XCTAssertEqual(decoded.entries[0].id, "rt-1")
        XCTAssertEqual(decoded.entries[1].tags, [])
    }
}
