import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit
import PersistenceKit
import PersistenceKitInMemory
import PersistenceKitSQLite
@testable import CognitionKit

/// Contradiction — surprise lens (category 5, SPEC § 4.2), the
/// odd-one-out. Recall a set, score each drawer's content cohesion with
/// its peers (mean shingle similarity), and flag the ones whose
/// cohesion is anomalously LOW (a negative-z outlier) — the memory in
/// tension with the rest. Read-only, end-to-end over a real estate.
/// Swift peer of run_contradiction.
@Suite("ContradictionTests")
struct ContradictionTests {

    private func openEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        let handle = try await kit.open(
            storage: storage,
            owner: OwnerCredentials(ownerIdentifier: "contradiction-test"))
        return (kit, handle)
    }

    private func capture(
        _ kit: GeniusLocusKit, _ handle: EstateHandle, content: String
    ) async throws -> String {
        let frame = CaptureFrame(
            content: content,
            channel: .typed,
            room: "study",
            latticeAnchor: .udc("0"),
            addedBy: "alice",
            embeddingModelID: "test-v1")
        return try await kit.capture(handle, frame).id
    }

    private var unconfirmed: LocusKit.RecallFrame {
        LocusKit.RecallFrame(filterChain: [.unconfirmed])
    }

    // CK-CN-1: three mutually-similar memories plus one totally
    // unrelated one — the unrelated drawer is flagged as the
    // odd-one-out (its cohesion is the low outlier).
    @Test("the unrelated memory is flagged as the odd-one-out")
    func unrelatedMemoryIsFlagged() async throws {
        let (kit, handle) = try await openEstate()
        _ = try await capture(kit, handle, content: "the quick brown fox jumps over the lazy dog")
        _ = try await capture(kit, handle, content: "the quick brown fox runs past the lazy dog")
        _ = try await capture(kit, handle, content: "a quick brown fox and a lazy dog")
        let odd = try await capture(kit, handle, content: "zzz qqq vvv mmm kkk www")

        // threshold 1.5 sits in the gap: with n = 4 the stark low
        // outlier reaches z ≈ −1.73, while a coherent set's small
        // spread cannot exceed it.
        let out = try await Contradiction.run(
            kit: kit, handle: handle, frame: unconfirmed, threshold: 1.5)

        #expect(out.considered == 4)
        #expect(out.outliers.contains(odd), "the unrelated memory is the odd-one-out")
    }

    // CK-CN-2: a coherent set (identical content ⇒ uniform cohesion,
    // zero spread) has no contradictions — the anomaly scan's
    // zero-spread guard.
    @Test("a coherent set has no odd-one-out")
    func coherentSetNoOutliers() async throws {
        let (kit, handle) = try await openEstate()
        for _ in 0..<3 {
            _ = try await capture(kit, handle, content: "the quick brown fox jumps")
        }

        let out = try await Contradiction.run(
            kit: kit, handle: handle, frame: unconfirmed, threshold: 1.5)

        #expect(out.outliers.isEmpty, "a coherent set has no odd-one-out")
    }

    // CK-CN-3: fewer than 3 drawers cannot define "fit" — guarded to no
    // outliers.
    @Test("fewer than three drawers is guarded")
    func fewerThanThreeIsGuarded() async throws {
        let (kit, handle) = try await openEstate()
        _ = try await capture(kit, handle, content: "alpha")
        _ = try await capture(kit, handle, content: "omega")

        let out = try await Contradiction.run(
            kit: kit, handle: handle, frame: unconfirmed, threshold: 1.5)

        #expect(out.considered == 2)
        #expect(out.outliers.isEmpty)
    }

    // CK-CN-4: SQLite-backed estate — proves the .full hydration override
    // is exercised against the real blob-gated storage path.
    //
    // InMemory returns content regardless of hydrationLevel, masking the bug
    // described in inspection finding C4-Swift. SQLite enforces spec § 7.3
    // strictly: .structured recall returns content = "" for every drawer.
    // Without the .full override in Contradiction.run, all pairwise
    // shingleSimilarity scores are 0/0 (uniform-zero cohesion vector) and
    // the outlier detector runs on a flat cohesion vector — silent garbage.
    //
    // Setup: 4-drawer estate — three drawers share highly-similar fox/dog
    // content; one drawer is a clear outlier ("zzz qqq vvv mmm kkk www").
    // With n = 4 the z-score for the outlier's cohesion is ≈ −1.73, which
    // exceeds threshold 1.5. (n = 3 only reaches ≈ −1.41, not enough.)
    //
    // Assertions:
    //   a. considered == 4 (all drawers in scope)
    //   b. at least one outlier detected — only possible when content
    //      bodies are non-empty (proves .full hydration ran against SQLite)
    //   c. the outlier is the anomalous drawer, not one of the fox/dog set
    @Test("SQLite backend: outlier is detected with non-zero cohesion values")
    func sqliteBackendOutlierDetected() async throws {
        // Create a fresh SQLite-backed estate in the process temp directory.
        // Each test run gets a unique file so parallel test execution is safe.
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent(
            "cognitionkit-contradiction-test-\(UUID().uuidString).sqlite")
        defer {
            // Clean up SQLite file and WAL/SHM sidecars after the test.
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: url.path + "-wal"))
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: url.path + "-shm"))
        }

        let storage = try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: url)))
        let kit = GeniusLocusKit()
        let handle = try await kit.open(
            storage: storage,
            owner: OwnerCredentials(ownerIdentifier: "contradiction-sqlite-test"))

        // Three similar drawers (fox/dog content — high shingle overlap
        // with each other, so each has moderate cohesion with the set).
        _ = try await capture(kit, handle,
            content: "the quick brown fox jumps over the lazy dog")
        _ = try await capture(kit, handle,
            content: "the quick brown fox runs past the lazy dog")
        _ = try await capture(kit, handle,
            content: "a quick brown fox and a lazy dog")
        // One clear outlier: no shared tokens with the fox/dog set.
        // z-score for its cohesion (≈ −1.73 with n = 4) exceeds 1.5.
        let odd = try await capture(kit, handle,
            content: "zzz qqq vvv mmm kkk www")

        let out = try await Contradiction.run(
            kit: kit, handle: handle, frame: unconfirmed, threshold: 1.5)

        // a. All four drawers were considered.
        #expect(out.considered == 4,
            "all four SQLite-backed drawers must be in scope")

        // b. At least one outlier detected — only possible when content
        //    bodies are non-empty (proves .full hydration ran against SQLite).
        #expect(!out.outliers.isEmpty,
            "outlier detection requires non-empty content; empty = .structured hydration bug")

        // c. The anomalous drawer is the one flagged, not a fox/dog drawer.
        #expect(out.outliers.contains(odd),
            "the content-outlier drawer must be flagged, not one of the similar fox/dog set")
    }
}
