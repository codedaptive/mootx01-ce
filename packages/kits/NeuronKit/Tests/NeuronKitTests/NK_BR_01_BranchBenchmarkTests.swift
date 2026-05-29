import XCTest
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import GeniusLocusKit
@testable import NeuronKit

/// Branch ops + migration-benchmark tests — NK-BR-01.
///
/// Covers the four NeuronKit entry points (`deriveBranch`,
/// `promoteBranch`, `mergeDrawers`, `benchmark`) plus the
/// `ExternalCorpus` decode/`asRecallFrames()` surface and the C-13
/// migration-loss invariant (and its read-only corollary).
///
/// Estate setup mirrors `GLK_COW_01_BranchTests` — an in-memory estate
/// opened through `GeniusLocusKit`, captured into through the branch
/// handle's own `capture`. The benchmark fixtures build an
/// `ExternalCorpus` whose entry `id`s equal the captured `Drawer.id`s,
/// so a content-driven `contentMatches` recall maps each expected
/// concept onto the drawer the migration produced.
final class NK_BR_01_BranchBenchmarkTests: XCTestCase {

    // MARK: - Helpers

    /// Open a fresh estate through GeniusLocusKit backed by in-memory
    /// storage. Mirrors the canonical GLK-COW-01 estate-open helper.
    private func openEstate(owner: String = "nk-br-01-owner") async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let storage = InMemoryStorage(configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        let credentials = OwnerCredentials(ownerIdentifier: owner)
        _ = try await LocusKit.Estate.create(storage: storage, owner: credentials)
        let handle = try await kit.open(storage: storage, owner: credentials)
        return (kit, handle)
    }

    /// Capture one drawer into a branch and return the stored `Drawer`
    /// (whose generated `id` the corpus fixtures correlate against).
    private func captureIntoBranch(_ branch: any BranchHandle, content: String) async throws -> Drawer {
        let frame = CaptureFrame(
            content: content,
            channel: .typed,
            room: "nk-br-01",
            latticeAnchor: .udc("000"),
            addedBy: "nk-br-01",
            embeddingModelID: "test-model-v1"
        )
        return try await branch.capture(frame)
    }

    /// Count rows currently recall-able from a branch via a bare
    /// content-agnostic chain — used by the read-only corollary test.
    private func branchRowCount(_ branch: any BranchHandle) async throws -> Int {
        let frame = RecallFrame(
            filterChain: [.unconfirmed],
            hydrationLevel: .structured,
            ordering: .byCaptureTimeDesc
        )
        return try await branch.recall(frame).count
    }

    // MARK: - Test 1: deriveBranch returns an active, depth-1 handle

    func testDeriveBranchReturnsActiveDepthOneHandle() async throws {
        let (kit, handle) = try await openEstate()
        let branch = try await NeuronKit.deriveBranch(name: "t1-branch", from: handle, in: kit)
        XCTAssertEqual(branch.status, .active)
        XCTAssertEqual(branch.lineageDepth, 1)
    }

    // MARK: - Test 2: promoteBranch transitions the branch to .won

    func testPromoteBranchTransitionsToWon() async throws {
        let (kit, handle) = try await openEstate()
        let branch = try await NeuronKit.deriveBranch(name: "t2-branch", from: handle, in: kit)
        _ = try await captureIntoBranch(branch, content: "t2-promotable-row")

        try await NeuronKit.promoteBranch(branch, replacing: handle, in: kit)
        XCTAssertEqual(branch.status, .won)
    }

    // MARK: - Test 3: mergeDrawers merges the requested present drawers

    func testMergeDrawersMergesRequestedPresentDrawers() async throws {
        let (kit, handle) = try await openEstate()
        let branch = try await NeuronKit.deriveBranch(name: "t3-branch", from: handle, in: kit)
        let rowA = try await captureIntoBranch(branch, content: "t3-row-a")
        let rowB = try await captureIntoBranch(branch, content: "t3-row-b")

        let report = try await NeuronKit.mergeDrawers([rowA.id, rowB.id], from: branch, into: handle, in: kit)
        // Both requested IDs are present in the branch, so both merge.
        XCTAssertEqual(report.merged.count, 2)
    }

    // MARK: - Test 4: ExternalCorpus.load(from:) decodes a MemPalace export

    func testExternalCorpusLoadDecodesExport() async throws {
        let json = """
        {
          "name": "test-corpus",
          "entries": [
            { "id": "c1", "content": "alpha concept", "tags": ["x"] },
            { "id": "c2", "content": "bravo concept", "tags": [] },
            { "id": "c3", "content": "charlie concept", "tags": ["y", "z"] }
          ]
        }
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nk-br-01-\(UUID().uuidString).json")
        try json.data(using: .utf8)!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let corpus = try ExternalCorpus.load(from: url)
        XCTAssertEqual(corpus.name, "test-corpus")
        XCTAssertEqual(corpus.entries.count, 3)
    }

    // MARK: - Test 5: asRecallFrames yields one frame per entry

    func testAsRecallFramesYieldsOneFramePerEntry() {
        let corpus = ExternalCorpus(name: "frames", entries: [
            ExternalEntry(id: "c1", content: "alpha", tags: []),
            ExternalEntry(id: "c2", content: "bravo", tags: []),
        ])
        XCTAssertEqual(corpus.asRecallFrames().count, corpus.entries.count)
    }

    // MARK: - Test 6: benchmark on a lossless branch — overlap 1.0, no loss

    func testBenchmarkLosslessBranchHasFullOverlapAndNoLoss() async throws {
        let (kit, handle) = try await openEstate()
        let branch = try await NeuronKit.deriveBranch(name: "t6-branch", from: handle, in: kit)
        // Distinct contents with no substring collisions so each
        // contentMatches query resolves to exactly one drawer.
        let a = try await captureIntoBranch(branch, content: "t6-alpha-concept")
        let b = try await captureIntoBranch(branch, content: "t6-bravo-concept")
        let c = try await captureIntoBranch(branch, content: "t6-charlie-concept")

        let corpus = ExternalCorpus(name: "t6", entries: [
            ExternalEntry(id: a.id, content: a.content, tags: []),
            ExternalEntry(id: b.id, content: b.content, tags: []),
            ExternalEntry(id: c.id, content: c.content, tags: []),
        ])

        let report = try await NeuronKit.benchmark(
            branch: branch, against: corpus, now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(report.recallOverlap, 1.0, accuracy: 1e-6)
        XCTAssertTrue(report.notFoundInBranch.isEmpty)
    }

    // MARK: - Test 7: C-13 — a missing concept surfaces in notFoundInBranch

    func testBenchmarkMissingConceptIsZeroToleranceLoss() async throws {
        let (kit, handle) = try await openEstate()
        let branch = try await NeuronKit.deriveBranch(name: "t7-branch", from: handle, in: kit)
        let a = try await captureIntoBranch(branch, content: "t7-alpha-concept")
        let b = try await captureIntoBranch(branch, content: "t7-bravo-concept")

        // "charlie" was never migrated into the branch — its concept ID
        // is the silent migration loss C-13 must catch.
        let missingID = "t7-missing-charlie-id"
        let corpus = ExternalCorpus(name: "t7", entries: [
            ExternalEntry(id: a.id, content: a.content, tags: []),
            ExternalEntry(id: b.id, content: b.content, tags: []),
            ExternalEntry(id: missingID, content: "t7-charlie-concept", tags: []),
        ])

        let report = try await NeuronKit.benchmark(
            branch: branch, against: corpus, now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(report.notFoundInBranch.count, 1)
        XCTAssertEqual(report.notFoundInBranch.first, missingID)
        XCTAssertLessThan(report.recallOverlap, 1.0)
    }

    // MARK: - Test 8: newInBranch — a branch drawer absent from the origin

    func testBenchmarkReportsNewInBranch() async throws {
        let (kit, handle) = try await openEstate()
        let branch = try await NeuronKit.deriveBranch(name: "t8-branch", from: handle, in: kit)
        // Both drawers contain "t8-shared"; only `base` is in the corpus.
        let base = try await captureIntoBranch(branch, content: "t8-shared")
        let extra = try await captureIntoBranch(branch, content: "t8-shared extra")

        let corpus = ExternalCorpus(name: "t8", entries: [
            ExternalEntry(id: base.id, content: "t8-shared", tags: []),
        ])

        let report = try await NeuronKit.benchmark(
            branch: branch, against: corpus, now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        // `extra` matches the "t8-shared" query but is not an expected
        // concept, so it is reported as new-in-branch.
        XCTAssertTrue(report.newInBranch.contains(extra.id))
    }

    // MARK: - Test 9: every metric field is finite and in [0, 1]

    func testBenchmarkMetricsAreFiniteAndBounded() async throws {
        let (kit, handle) = try await openEstate()
        let branch = try await NeuronKit.deriveBranch(name: "t9-branch", from: handle, in: kit)
        let a = try await captureIntoBranch(branch, content: "t9-alpha-concept")
        let b = try await captureIntoBranch(branch, content: "t9-bravo-concept")

        let corpus = ExternalCorpus(name: "t9", entries: [
            ExternalEntry(id: a.id, content: a.content, tags: []),
            ExternalEntry(id: b.id, content: b.content, tags: []),
        ])

        let report = try await NeuronKit.benchmark(
            branch: branch, against: corpus, now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(report.queryCount, 2)
        for metric in [report.recallOverlap, report.recallPrecision, report.meanReciprocalRank] {
            XCTAssertTrue(metric.isFinite)
            XCTAssertGreaterThanOrEqual(metric, 0.0)
            XCTAssertLessThanOrEqual(metric, 1.0)
        }
    }

    // MARK: - Test 10: C-13 corollary — benchmark is read-only

    func testBenchmarkIsReadOnly() async throws {
        let (kit, handle) = try await openEstate()
        let branch = try await NeuronKit.deriveBranch(name: "t10-branch", from: handle, in: kit)
        _ = try await captureIntoBranch(branch, content: "t10-alpha-concept")
        _ = try await captureIntoBranch(branch, content: "t10-bravo-concept")

        let corpus = ExternalCorpus(name: "t10", entries: [
            ExternalEntry(id: "t10-a", content: "t10-alpha-concept", tags: []),
            ExternalEntry(id: "t10-b", content: "t10-bravo-concept", tags: []),
        ])

        let countBefore = try await branchRowCount(branch)
        _ = try await NeuronKit.benchmark(
            branch: branch, against: corpus, now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let countAfter = try await branchRowCount(branch)
        XCTAssertEqual(countBefore, countAfter,
            "benchmark must issue no write verbs — branch drawer count must be unchanged")
    }
}
