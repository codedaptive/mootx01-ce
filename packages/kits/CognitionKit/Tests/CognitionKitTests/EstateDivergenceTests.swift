import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit
import PersistenceKit
import PersistenceKitInMemory
@testable import CognitionKit

/// EstateDivergenceLens — federated-category lens (category 9,
/// SPEC § 4.2), the NON-private, same-device half: compare two estates'
/// room distributions by Jensen-Shannon / KL divergence (NeuronKit
/// `drift`) — low = organized alike, high = they diverge. The
/// coordinator holds both estates, so it's one recipe over two handles
/// reading BOTH estates' distributions directly (the privacy-preserving
/// federation half is MindOverlapLens). Read-only. Swift peer of
/// run_estate_divergence.
@Suite("EstateDivergenceTests")
struct EstateDivergenceTests {

    private func openEstates() async throws -> (GeniusLocusKit, EstateHandle, EstateHandle) {
        let kit = GeniusLocusKit()
        func open(_ owner: String) async throws -> EstateHandle {
            let storage = InMemoryStorage(
                configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
            return try await kit.open(
                storage: storage, owner: OwnerCredentials(ownerIdentifier: owner))
        }
        return (kit, try await open("estate-a"), try await open("estate-b"))
    }

    private func capture(
        _ kit: GeniusLocusKit, _ handle: EstateHandle, room: String
    ) async throws {
        let frame = CaptureFrame(
            content: "content",
            channel: .typed,
            room: room,
            latticeAnchor: .udc("0"),
            addedBy: "alice",
            embeddingModelID: "test-v1")
        _ = try await kit.capture(handle, frame)
    }

    private var unconfirmed: LocusKit.RecallFrame {
        LocusKit.RecallFrame(filterChain: [.unconfirmed])
    }

    // CK-ED-1: two estates filed into disjoint rooms diverge sharply;
    // the lens computes one mind against another.
    @Test("disjoint minds diverge")
    func disjointMindsDiverge() async throws {
        let (kit, a, b) = try await openEstates()
        for _ in 0..<3 { try await capture(kit, a, room: "philosophy") }
        for _ in 0..<3 { try await capture(kit, b, room: "cooking") }

        let out = try await EstateDivergenceLens.run(
            kit: kit, handleA: a, handleB: b, frame: unconfirmed)

        #expect(out.aCount == 3)
        #expect(out.bCount == 3)
        #expect(out.divergence.jensenShannon > 0.5, "disjoint minds diverge")
    }

    // CK-ED-2: two estates organized the same way converge (near-zero
    // divergence).
    @Test("aligned minds converge")
    func alignedMindsConverge() async throws {
        let (kit, a, b) = try await openEstates()
        try await capture(kit, a, room: "philosophy")
        try await capture(kit, b, room: "philosophy")

        let out = try await EstateDivergenceLens.run(
            kit: kit, handleA: a, handleB: b, frame: unconfirmed)

        #expect(abs(out.divergence.jensenShannon) < 1e-5, "aligned minds converge")
    }

    // CK-ED-3: either estate empty ⇒ zero divergence (guarded —
    // nothing to compare).
    @Test("an empty estate is guarded to zero divergence")
    func emptyEstateIsGuarded() async throws {
        let (kit, a, b) = try await openEstates()
        try await capture(kit, a, room: "philosophy")

        let out = try await EstateDivergenceLens.run(
            kit: kit, handleA: a, handleB: b, frame: unconfirmed)

        #expect(out.aCount == 1)
        #expect(out.bCount == 0)
        #expect(out.divergence.jensenShannon == 0)
    }
}
