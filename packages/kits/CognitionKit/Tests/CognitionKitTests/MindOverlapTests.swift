import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit
import PersistenceKit
import PersistenceKitInMemory
@testable import CognitionKit

/// MindOverlapLens — federated lens (category 9, SPEC § 4.2),
/// privacy-preserving. Each estate's drawers are recalled and fingerprinted
/// locally under a SHARED hyperplane family, then reduced to ONE
/// differentially-private aggregate. The final overlap comparison uses only
/// the two aggregates; no individual drawer content crosses the estate
/// boundary. Estates are opened with FIXED estate UUIDs so the shared
/// family + DP seed (derived from both UUIDs) are deterministic — random
/// UUIDs would make the seeded noise, and the test, flaky. Swift peer of
/// run_mind_overlap.
@Suite("MindOverlapLensTests")
struct MindOverlapLensTests {

    private func openEstate(
        _ kit: GeniusLocusKit, uuid: UUID, owner: String
    ) async throws -> EstateHandle {
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: uuid, backend: .inMemory))
        return try await kit.open(
            storage: storage, owner: OwnerCredentials(ownerIdentifier: owner))
    }

    /// The fingerprint encodes the LATTICE anchor (concept block),
    /// structure, and channel — not raw text. Two estates are
    /// "convergent" when they share lattice anchors; `udc` is what makes
    /// the comparison meaningful.
    private func capture(
        _ kit: GeniusLocusKit, _ handle: EstateHandle,
        content: String, room: String, udc: String
    ) async throws {
        let frame = CaptureFrame(
            content: content,
            channel: .typed,
            room: room,
            latticeAnchor: .udc(udc),
            addedBy: "alice",
            embeddingModelID: "test-v1")
        _ = try await kit.capture(handle, frame)
    }

    private var unconfirmed: LocusKit.RecallFrame {
        LocusKit.RecallFrame(filterChain: [.unconfirmed])
    }

    private func fixedUUID(_ fill: UInt8) -> UUID {
        UUID(uuid: (fill, fill, fill, fill, fill, fill, fill, fill,
                    fill, fill, fill, fill, fill, fill, fill, fill))
    }

    // CK-MO-1: two estates with the SAME memories overlap more than an
    // estate and one with disjoint memories — computed only from the DP
    // summaries. The privacy-preserving overlap distinguishes convergent
    // from divergent minds.
    @Test("convergent minds overlap more than divergent ones")
    func convergentOverlapsMoreThanDivergent() async throws {
        let kit = GeniusLocusKit()
        let a = try await openEstate(kit, uuid: fixedUUID(1), owner: "a")
        let twin = try await openEstate(kit, uuid: fixedUUID(2), owner: "twin")
        let other = try await openEstate(kit, uuid: fixedUUID(3), owner: "other")

        // A and its twin share the same lattice anchors (concepts 1xx);
        // "other" is anchored in a disjoint region (concepts 6xx).
        for (i, udc) in ["100", "110", "120", "130", "140", "150"].enumerated() {
            try await capture(kit, a, content: "philosophy note \(i)", room: "study", udc: udc)
            try await capture(kit, twin, content: "philosophy note \(i)", room: "study", udc: udc)
        }
        for (i, udc) in ["600", "610", "620", "630", "640", "650"].enumerated() {
            try await capture(kit, other, content: "cooking note \(i)", room: "kitchen", udc: udc)
        }

        let convergent = try await MindOverlapLens.run(
            kit: kit, handleA: a, handleB: twin, frame: unconfirmed)
        let divergent = try await MindOverlapLens.run(
            kit: kit, handleA: a, handleB: other, frame: unconfirmed)

        #expect(convergent.overlap > divergent.overlap,
                "convergent minds overlap more")
    }

    // CK-MO-2: an empty estate yields zero overlap (guarded).
    @Test("an empty estate is guarded to zero overlap")
    func emptyEstateIsGuarded() async throws {
        let kit = GeniusLocusKit()
        let a = try await openEstate(kit, uuid: fixedUUID(4), owner: "a")
        let b = try await openEstate(kit, uuid: fixedUUID(5), owner: "b")
        try await capture(kit, a, content: "alpha", room: "study", udc: "100")
        // b is empty

        let out = try await MindOverlapLens.run(
            kit: kit, handleA: a, handleB: b, frame: unconfirmed)

        #expect(out.overlap == 0)
        #expect(out.aCount == 1)
        #expect(out.bCount == 0)
    }
}
