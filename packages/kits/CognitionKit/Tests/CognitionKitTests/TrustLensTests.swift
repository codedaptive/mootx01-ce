import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
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
        LocusKit.RecallFrame(filterChain: [.unconfirmed])
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
}
