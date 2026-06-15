import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import PersistenceKitSQLite
@testable import CognitionKit

/// TrustLens — provenance-weighted grounding (category 6, SPEC § 4.2).
/// Recall a set of drawers, rank them by how authoritative their
/// provenance is (source-type trust: canonical/user above derived,
/// confidence as tiebreak, id as the deterministic last key), and
/// synthesize the trust-ordered set so the most trustworthy memories
/// ground the context first. Read-only. End-to-end over a real estate —
/// no mocks. Swift peer of run_trust_grounded_synthesis.
@Suite("TrustLensTests")
struct TrustLensTests {

    private func openEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        let handle = try await kit.open(
            storage: storage,
            owner: OwnerCredentials(ownerIdentifier: "trust-lens-test"))
        return (kit, handle)
    }

    /// Capture a drawer with the given source type; return its minted id.
    private func capture(
        _ kit: GeniusLocusKit, _ handle: EstateHandle,
        content: String, sourceType: SourceType
    ) async throws -> String {
        var frame = CaptureFrame(
            content: content,
            channel: .typed,
            room: "study",
            latticeAnchor: .udc("0"),
            addedBy: "alice",
            embeddingModelID: "test-v1")
        frame.sourceType = sourceType
        return try await kit.capture(handle, frame).id
    }

    private var unconfirmed: LocusKit.RecallFrame {
        LocusKit.RecallFrame(filterChain: [.userConfirmed])
    }

    // CK-TR-1: the lens ranks by provenance trust — canonical memories
    // ground the context ahead of derived ones, end-to-end over a real
    // estate. The estate leans on what it most trusts.
    @Test("canonical memories outrank derived ones")
    func canonicalOutranksDerived() async throws {
        let (kit, handle) = try await openEstate()
        let c1 = try await capture(kit, handle, content: "canonical-a", sourceType: .canonical)
        let c2 = try await capture(kit, handle, content: "canonical-b", sourceType: .canonical)
        _ = try await capture(kit, handle, content: "derived-a", sourceType: .derived)
        _ = try await capture(kit, handle, content: "derived-b", sourceType: .derived)

        let out = try await TrustLens.run(
            kit: kit, handle: handle, frame: unconfirmed)

        #expect(out.rankedIDs.count == 4)
        #expect(Set(out.rankedIDs.prefix(2)) == Set([c1, c2]),
                "canonical memories rank first")
        #expect(out.highTrustCount == 2, "two canonical = two high-trust")
        #expect(!out.context.summary.isEmpty, "a grounded document is produced")
    }

    // CK-TR-2: an empty estate yields an empty ranking and zero
    // high-trust — guarded, no failure.
    @Test("empty estate is guarded")
    func emptyEstateIsGuarded() async throws {
        let (kit, handle) = try await openEstate()

        let out = try await TrustLens.run(
            kit: kit, handle: handle, frame: unconfirmed)

        #expect(out.rankedIDs.isEmpty)
        #expect(out.highTrustCount == 0)
    }

    // CK-TR-3: the ranking is a deterministic function of the estate —
    // the same recall ranks identically on every run (B-5/I-18 posture;
    // ties fall through source type and confidence to ascending id).
    @Test("ranking is deterministic across runs")
    func rankingIsDeterministic() async throws {
        let (kit, handle) = try await openEstate()
        for i in 0..<4 {
            _ = try await capture(
                kit, handle, content: "note-\(i)",
                sourceType: i % 2 == 0 ? .canonical : .derived)
        }

        let first = try await TrustLens.run(kit: kit, handle: handle, frame: unconfirmed)
        let second = try await TrustLens.run(kit: kit, handle: handle, frame: unconfirmed)

        #expect(first.rankedIDs == second.rankedIDs)
        #expect(first.highTrustCount == second.highTrustCount)
    }

    // CK-TR-4: SQLite-backed estate — proves the .full hydration override
    // is exercised against the real blob-gated storage path.
    //
    // InMemory returns content regardless of hydrationLevel, masking the bug
    // described in H-BROKEN-1/2 (H-BROKEN content-stripping family, fifth
    // instance). SQLite enforces spec § 7.3 strictly: .structured recall
    // returns content = "" for every drawer. Without the .full override in
    // TrustLens.run, ContextSynthesizer operates on empty content bodies and
    // produces a summary that is either empty or contains no memory substance.
    //
    // Setup: 3-drawer estate — two canonical drawers with substantive content,
    // one derived drawer. The canonical drawers have high-trust provenance and
    // content bodies the synthesizer can extract themes from.
    //
    // Assertions:
    //   a. considered == 3 (all drawers in scope, ranked)
    //   b. highTrustCount == 2 (the two canonical drawers)
    //   c. the context summary is non-empty — only possible when drawer
    //      content bodies are non-empty (proves .full hydration ran against
    //      SQLite, not the content-stripped .structured path)
    @Test("SQLite backend: synthesis produces non-empty context over real content")
    func sqliteBackendSynthesisNonEmpty() async throws {
        // Create a fresh SQLite-backed estate in the process temp directory.
        // Each test run gets a unique file so parallel test execution is safe.
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent(
            "cognitionkit-trustlens-test-\(UUID().uuidString).sqlite")
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
            owner: OwnerCredentials(ownerIdentifier: "trust-lens-sqlite-test"))

        // Two canonical drawers with substantive prose bodies — high-trust,
        // non-empty content for the synthesizer to extract themes from.
        let c1 = try await capture(kit, handle,
            content: "the substrate is local-first; sync is optional via ConvergenceKit",
            sourceType: .canonical)
        let c2 = try await capture(kit, handle,
            content: "vector storage uses sqlite-vec; embeddings live in VectorKit",
            sourceType: .canonical)
        // One derived drawer — lower trust, but still in the recall set.
        _ = try await capture(kit, handle,
            content: "observed pattern: recall latency increases with drawer count",
            sourceType: .derived)

        let out = try await TrustLens.run(
            kit: kit, handle: handle, frame: unconfirmed)

        // a. All three drawers were ranked.
        #expect(out.rankedIDs.count == 3,
            "all three SQLite-backed drawers must be ranked")

        // b. Exactly two high-trust drawers (the canonical pair).
        #expect(out.highTrustCount == 2,
            "two canonical drawers must register as high-trust")

        // c. The canonical drawers must rank first.
        #expect(Set(out.rankedIDs.prefix(2)) == Set([c1, c2]),
            "canonical drawers must rank ahead of the derived drawer")

        // d. The context summary is non-empty — the key proof that .full
        //    hydration ran against SQLite (content-bearing drawers were loaded).
        //    Under .structured hydration, content = "" for every drawer and the
        //    synthesizer produces an empty-pattern summary. This assertion
        //    fails if the .full override is absent.
        #expect(!out.context.summary.isEmpty,
            "context summary must be non-empty; empty = .structured hydration bug (H-BROKEN)")
    }
}
