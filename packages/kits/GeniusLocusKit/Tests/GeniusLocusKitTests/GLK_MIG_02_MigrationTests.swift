// GLK_MIG_02_MigrationTests.swift
//
// Conformance tests for the GeniusLocusKit migration API (GLK-MIG-02).
//
// Coverage note (VK-ADAPT-01 Part 3): decode + zero-loss + provenance
// + idempotency coverage for the adapter → bridge import path lives in
// VaultKit's ExchangeAdapterTests per data-movement privacy tiers
//
// The remaining five tests cover:
//   1. runParallel writes to target in .writeToTarget mode
//   2. runParallel stop() prevents further captures
//   3. verifyMigration returns .identical for fully migrated corpus
//   4. verifyMigration returns .diverged for missing entry
//   5. MigrationReport is fully Sendable (compile-time check)

import Testing
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import GeniusLocusKit

@Suite("GLK-MIG-02 migration API")
struct GLK_MIG_02_MigrationTests {

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

    /// Open a fresh estate and populate it with one captured drawer per
    /// corpus entry, using the consolidated import-path provenance
    /// (channel: .importedFile, sourceType: .imported, provenanceChannel:
    /// .fileImport). This is the sanctioned corpus-construction helper
    /// for verifyMigration tests (VK-ADAPT-01 Part 3, data-movement privacy tiers).
    private func populateEstate(
        kit: GeniusLocusKit,
        corpus: ExternalCorpus,
        now: Date
    ) async throws -> EstateHandle {
        let handle = try await kit.open(storage: makeStorage(), owner: makeOwner())
        for entry in corpus.entries {
            guard !entry.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            let frame = CaptureFrame(
                content: entry.content,
                channel: .importedFile,
                room: "migration",
                latticeAnchor: .udc("000"),
                addedBy: "migration-import",
                embeddingModelID: "migration-v1",
                provenanceChannel: .fileImport,
                sourceType: .imported,
                eventTime: now
            )
            _ = try await kit.capture(handle, frame)
        }
        return handle
    }

    // MARK: - Test 1: runParallel writes to target in .writeToTarget mode

    @Test
    func runParallelWritesToTargetInWriteToTargetMode() async throws {
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
        #expect(targetRows.count == 1,
            ".writeToTarget mode must route captures to the target estate")

        let _ = now // suppress unused-var warning — now is part of the test's fixture intent
    }

    // MARK: - Test 2: runParallel stop() prevents further captures

    @Test
    func runParallelStopPreventsFurtherCaptures() async throws {
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
            Issue.record("capture after stop() must throw MigrationError.parallelRunStopped")
        } catch let err as MigrationError {
            #expect(err == .parallelRunStopped,
                "stop() must cause subsequent captures to throw .parallelRunStopped")
        }
    }

    // MARK: - Test 3: verifyMigration returns .identical for fully migrated corpus

    @Test
    func verifyMigrationReturnIdenticalForFullyMigratedCorpus() async throws {
        let kit = makeKit()
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

        // Populate the estate via the consolidated import-path provenance
        // (importedFile channel, imported sourceType) so all entries are
        // present. verifyMigration uses content-match recall with the
        // .unconfirmed filter, which matches this capture state.
        let corpus = makeCorpus(count: 2, prefix: "verify-identical")
        let handle = try await populateEstate(kit: kit, corpus: corpus, now: now)

        let result = try await kit.verifyMigration(estate: handle, against: corpus, now: now)

        switch result {
        case .identical:
            break // expected
        case .diverged(let divergences):
            Issue.record("Expected .identical but got .diverged with \(divergences.count) divergences: \(divergences.map { $0.entryID })")
        }
    }

    // MARK: - Test 4: verifyMigration returns .diverged for missing entry

    @Test
    func verifyMigrationReturnsDivergedForMissingEntry() async throws {
        let kit = makeKit()
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

        // Populate the estate with only the first entry of the corpus,
        // then verify against a two-entry corpus — the second entry is absent.
        let partialCorpus = makeCorpus(count: 1, prefix: "verify-diverged")
        let handle = try await populateEstate(kit: kit, corpus: partialCorpus, now: now)

        // Build a larger corpus that includes an entry the estate does not have.
        let fullCorpus = makeCorpus(count: 2, prefix: "verify-diverged")

        let result = try await kit.verifyMigration(estate: handle, against: fullCorpus, now: now)

        switch result {
        case .identical:
            Issue.record("Expected .diverged when corpus has entry not in estate")
        case .diverged(let divergences):
            #expect(divergences.count == 1,
                "One missing entry should produce exactly one divergence")
            #expect(divergences.first?.entryID == "verify-diverged-entry-1",
                "The diverged entry should be the one not imported")
        }
    }

    // MARK: - Test 5: MigrationReport is fully Sendable (compile-time check)

    /// This test validates the compile-time `Sendable` conformance of
    /// `MigrationReport`. If the struct or any of its fields is not
    /// `Sendable`, this actor-boundary crossing will fail to compile.
    @Test
    func migrationReportIsFullySendable() async throws {
        let report = MigrationReport(
            rowsByNoun: ["drawer": 1],
            unmappedConcepts: [UnmappedConcept(entryID: "x", reason: "test")],
            warnings: [MigrationWarning(message: "test warning")]
        )

        // Cross an actor boundary. The compiler rejects non-Sendable
        // values here, turning the conformance requirement into a
        // build-time gate.
        let captured: MigrationReport = await Task.detached { report }.value

        #expect(captured.rowsByNoun["drawer"] == 1)
        #expect(captured.unmappedConcepts.count == 1)
        #expect(captured.warnings.count == 1)
    }
}
