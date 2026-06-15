import Testing
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import GeniusLocusKit

/// Estate isolation tests.
///
/// A write into estate A through its handle must NOT be visible through
/// estate B's handle. Each estate has its own injected `Storage`; the
/// coordinator does not share storage across estates, so isolation is
/// structural rather than enforced through any cross-estate access
/// control list.
@Suite("Estate isolation")
struct EstateIsolationTests {

    private func makeStorage() -> InMemoryStorage {
        InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory
        ))
    }

    /// Capture into estate A must not appear in a recall against
    /// estate B.
    @Test
    func writeIntoEstateAIsInvisibleInEstateB() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-iso")
        let sA = makeStorage()
        let sB = makeStorage()
        _ = try await LocusKit.Estate.create(storage: sA, owner: owner)
        _ = try await LocusKit.Estate.create(storage: sB, owner: owner)

        let hA = try await kit.open(storage: sA, owner: owner)
        let hB = try await kit.open(storage: sB, owner: owner)

        // Capture a drawer in A through the LocusKit verb surface.
        let estateA = try await kit.estate(for: hA)
        let frame = CaptureFrame(
            content: "A-only",
            channel: .typed,
            room: "r-A",
            latticeAnchor: .udc("004"),
            addedBy: "test",
            embeddingModelID: "model-v1"
        )
        let drawer = try await estateA.capture(frame)

        // Recall in B with a permissive filter; expect zero matches.
        //
        // `.userConfirmed` is included explicitly so the evaluator's
        // default-prepend pass (§ 7.9.5) does not insert
        // `.userConfirmed` — newly captured drawers have provenance==0
        // (no confirmation), and a `.userConfirmed` prepend would prune
        // them and mask the isolation we are trying to observe.
        let estateB = try await kit.estate(for: hB)
        let recall = RecallFrame(filterChain: [.userConfirmed])
        let stream = await estateB.recall(recall)
        var idsInB: [String] = []
        for await page in stream { idsInB.append(contentsOf: page.rows.map(\.id)) }
        #expect(idsInB == [],
            "estate B must not see drawer \(drawer.id) captured in estate A")

        // And the symmetric direction — A still sees its own drawer.
        let streamA = await estateA.recall(recall)
        var idsInA: [String] = []
        for await page in streamA { idsInA.append(contentsOf: page.rows.map(\.id)) }
        #expect(idsInA.contains(drawer.id),
            "estate A must still see its own drawer")
    }
}
