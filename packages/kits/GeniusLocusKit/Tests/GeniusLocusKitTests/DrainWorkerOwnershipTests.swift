// DrainWorkerOwnershipTests.swift — a kit released without close leaves no
// engine alive. The on_encoded rider and the drain worker both hold the
// engine weakly, so the kit's registration is the last owner: releasing it
// deinitializes the engine and returns its worker. This is the shape of a
// host that opens an estate, captures, and lets the kit go; an orphaned
// worker would keep indexing under the composition policy that engine was
// opened with. Twin of the Rust GLK drain_worker_ownership_tests.

import CorpusKit
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import SubstrateTypes
import Testing
@testable import GeniusLocusKit

@Suite("Drain worker ownership — GLK")
struct GLKDrainWorkerOwnershipTests {

    private func eventuallyNil<T: AnyObject>(
        within limit: Duration = .seconds(5), _ read: () -> T?
    ) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if read() == nil { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return read() == nil
    }

    @Test("releasing the kit without close deinitializes the estate's engine")
    func releasedKitLeavesNoEngine() async throws {
        weak var weakEngine: CorpusContentEngine?
        do {
            let kit = GeniusLocusKit()
            let storage = InMemoryStorage(
                configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
            let params = EstateProvisionParams(
                estateName: "Drain Ownership",
                kind: .glk,
                zoomWindowLow: 1,
                zoomWindowHigh: 10,
                frameworkProfile: "KnowledgeWork",
                syncMode: .none
            )
            let handle = try await kit.provision(
                storage: storage,
                owner: OwnerCredentials(ownerIdentifier: "drain-ownership-tests"),
                params: params,
                embeddingModels: [.deterministic])
            // A capture enqueues an encode job, so the rider and the worker
            // are both live when the kit goes.
            let frame = CaptureFrame(
                content: "a capture whose encode job may still be in flight",
                channel: .typed,
                room: "notes",
                latticeAnchor: .udc("000"),
                addedBy: "drain-ownership-tests",
                embeddingModelID: "test-model-v1"
            )
            _ = try await kit.capture(handle, frame, mode: .impatient)
            weakEngine = await kit.corpusKits[handle]
            #expect(weakEngine != nil, "a .glk estate wires an engine")
        }
        let released = await eventuallyNil { weakEngine }
        #expect(released, "neither the on_encoded rider nor the drain worker may keep the engine alive once the kit is released")
    }
}
