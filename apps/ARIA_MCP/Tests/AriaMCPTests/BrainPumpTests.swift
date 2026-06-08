import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

/// Deterministic coverage for the resident Brain pump: cadence firing with an
/// injected clock, and the benign no-scheduler skip for standing signals. The
/// loop itself (`run()`) is a thin Task.sleep wrapper over `tick(now:)`; these
/// drive `tick(now:)` directly so there are no wall-clock sleeps.
@Suite("Brain pump", .serialized)
struct BrainPumpTests {

    private func makeEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "brainpump-tests")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory)
        )
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        return (kit, handle)
    }

    @Test func firstTickFiresDreamingAndMaintenance() async throws {
        let (kit, handle) = try await makeEstate()
        let pump = BrainPump(kit: kit, handle: handle)
        // A daemon's first pump always fires (no prior run to gate against).
        let report = await pump.tick(now: Date(timeIntervalSince1970: 1_000_000))
        #expect(report.dreamingFired)
        #expect(report.maintenanceFired)
    }

    @Test func dreamingRespectsCadence() async throws {
        let (kit, handle) = try await makeEstate()
        let pump = BrainPump(kit: kit, handle: handle)
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        _ = await pump.tick(now: t0)                                  // first fires
        let early = await pump.tick(now: t0.addingTimeInterval(29))   // < 30s default
        #expect(!early.dreamingFired)
        let due = await pump.tick(now: t0.addingTimeInterval(30))     // 30s → fires
        #expect(due.dreamingFired)
    }

    @Test func signalTickBenignWhenNoSchedulerRegistered() async throws {
        let (kit, handle) = try await makeEstate()
        let pump = BrainPump(kit: kit, handle: handle)
        // No standing signal registered → signalTick throws schedulerNotStarted,
        // which the pump treats as a benign skip: tick returns normally with
        // signalsTicked == false, never throwing or spamming.
        let report = await pump.tick(now: Date(timeIntervalSince1970: 3_000_000))
        #expect(!report.signalsTicked)
    }
}
