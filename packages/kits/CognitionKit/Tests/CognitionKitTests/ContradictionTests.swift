import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit
import PersistenceKit
import PersistenceKitInMemory
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
}
