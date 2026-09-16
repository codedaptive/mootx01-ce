import Foundation
import Testing
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaResident

@Suite("AriaResident preference signal reconciliation")
struct ResidentPreferenceReconciliationTests {
    private func estate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "resident-preference-tests")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        let handle = try await kit.open(storage: storage, owner: owner)
        return (kit, handle)
    }

    private func spec() -> SignalSpec {
        FactExtractionSignal.spec(factExtractionCycle: { _ in 0 })
    }

    @Test("signal follows on off on transitions")
    func onOffOn() async throws {
        let (kit, handle) = try await estate()
        var ids: [String: SignalID] = [:]
        let name = FactExtractionSignal.signalName

        try await AriaResident.reconcilePreferenceSignal(
            name: name, enabled: true, ids: &ids,
            kit: kit, handle: handle, now: Date()) { spec() }
        #expect(ids[name] != nil)
        try await AriaResident.reconcilePreferenceSignal(
            name: name, enabled: false, ids: &ids,
            kit: kit, handle: handle, now: Date()) { nil }
        #expect(ids[name] == nil)
        try await AriaResident.reconcilePreferenceSignal(
            name: name, enabled: true, ids: &ids,
            kit: kit, handle: handle, now: Date()) { spec() }
        #expect(ids[name] != nil)
    }

    @Test("failed preference read path removes all managed signals")
    func failedReadFailsClosed() async throws {
        let (kit, handle) = try await estate()
        var ids: [String: SignalID] = [:]
        for name in [FactExtractionSignal.signalName, MaintenanceSignal.signalName] {
            try await AriaResident.reconcilePreferenceSignal(
                name: name, enabled: true, ids: &ids,
                kit: kit, handle: handle, now: Date()) { spec() }
        }
        await AriaResident.failClosedPreferenceSignals(
            names: [FactExtractionSignal.signalName, MaintenanceSignal.signalName],
            ids: &ids, kit: kit, handle: handle, now: Date())
        #expect(ids.isEmpty)
    }

    @Test("failed unregister retains id for retry")
    func unregisterFailureRetainsID() async throws {
        let (kit, handle) = try await estate()
        let name = FactExtractionSignal.signalName
        var ids: [String: SignalID] = [:]
        try await AriaResident.reconcilePreferenceSignal(
            name: name, enabled: true, ids: &ids,
            kit: kit, handle: handle, now: Date()) { spec() }
        try await kit.close(handle)

        await AriaResident.failClosedPreferenceSignals(
            names: [name], ids: &ids, kit: kit, handle: handle, now: Date())
        #expect(ids[name] != nil)
    }
}
