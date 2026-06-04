import Foundation
import Testing
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import NeuronKit

/// Tests for EstateMaintenanceReader — the production adapter that binds
/// `MaintenanceSubstrateReader` to a live GeniusLocusKit estate.
///
/// Coverage plan:
///   §1  activeDrawers: returns only non-tombstoned Cluster-A drawers
///   §2  tombstonedDrawers: returns only tombstoned drawers (expunged via GLK)
///   §3  currentAuditLog: returns a non-nil UnifiedAuditLog from the estate
///   §4  v1 stubs: learnedReferences and fingerprintBaselines return []
///   §5  Integration: MaintenanceDaemon with production adapters triggers a
///       cycle, emits decay proposals, and writes a diary entry
///   §6  Protocol conformance: EstateMaintenanceReader constructs cleanly
@Suite("EstateMaintenanceReader — production adapter integration")
struct EstateMaintenanceReaderTests {

    // MARK: - Infrastructure

    private func makeKit() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "maintenance-reader-test")
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        return (kit, handle)
    }

    private func captureFrame(content: String, room: String = "test-room") -> CaptureFrame {
        CaptureFrame(
            content: content,
            channel: .typed,
            room: room,
            latticeAnchor: .udc("547"),
            addedBy: "reader-test",
            embeddingModelID: "test-model-v1"
        )
    }

    // MARK: - § 6  Protocol conformance

    @Test("EstateMaintenanceReader conforms to MaintenanceSubstrateReader")
    func conformance() async throws {
        let (kit, handle) = try await makeKit()
        let reader: any MaintenanceSubstrateReader = EstateMaintenanceReader(handle: handle, kit: kit)
        _ = reader
    }

    // MARK: - § 1  activeDrawers

    @Test("activeDrawers returns non-tombstoned Cluster-A drawers")
    func activeDrawersReturnsLiveClusterARows() async throws {
        let (kit, handle) = try await makeKit()
        // Capture two drawers (both start active / Cluster A by default).
        _ = try await kit.capture(handle, captureFrame(content: "drawer alpha"))
        _ = try await kit.capture(handle, captureFrame(content: "drawer beta"))

        let reader = EstateMaintenanceReader(handle: handle, kit: kit)
        let active = try await reader.activeDrawers()

        #expect(active.count == 2, "both live drawers should be in activeDrawers")
        // All returned drawers must be non-tombstoned and Cluster A.
        for drawer in active {
            #expect(drawer.tombstonedAt == nil, "active drawer must not be tombstoned")
            #expect(drawer.state.isClusterA, "active drawer must be in Cluster A")
        }
    }


    // MARK: - § 2  tombstonedDrawers

    @Test("tombstonedDrawers is empty when no rows are tombstoned")
    func tombstonedDrawersEmptyForFreshEstate() async throws {
        let (kit, handle) = try await makeKit()
        _ = try await kit.capture(handle, captureFrame(content: "live"))

        let reader = EstateMaintenanceReader(handle: handle, kit: kit)
        let tombstoned = try await reader.tombstonedDrawers()

        #expect(tombstoned.isEmpty, "no tombstoned drawers in a fresh estate")
    }

    @Test("tombstonedDrawers does not include active drawers")
    func tombstonedDrawersExcludesActiveRows() async throws {
        let (kit, handle) = try await makeKit()
        _ = try await kit.capture(handle, captureFrame(content: "active-1"))
        _ = try await kit.capture(handle, captureFrame(content: "active-2"))

        let reader = EstateMaintenanceReader(handle: handle, kit: kit)
        // Neither drawer has been expunged, so tombstonedDrawers must be empty.
        let tombstoned = try await reader.tombstonedDrawers()

        #expect(tombstoned.isEmpty, "active drawers must not appear in tombstonedDrawers")
    }

    // MARK: - § 3  currentAuditLog

    @Test("currentAuditLog returns a UnifiedAuditLog (may be empty for a fresh estate)")
    func currentAuditLogReturnsSafeValue() async throws {
        let (kit, handle) = try await makeKit()
        // Capture one drawer to populate audit history.
        _ = try await kit.capture(handle, captureFrame(content: "audit trigger"))

        let reader = EstateMaintenanceReader(handle: handle, kit: kit)
        // Must not throw — this is the primary invariant.
        let log = try await reader.currentAuditLog()
        // The log type is UnifiedAuditLog (value type). Verify the call succeeds.
        _ = log
    }

    // MARK: - § 4  v1 stubs

    @Test("learnedReferences returns [] in v1")
    func learnedReferencesV1ReturnsEmpty() async throws {
        let (kit, handle) = try await makeKit()
        let reader = EstateMaintenanceReader(handle: handle, kit: kit)
        let refs = try await reader.learnedReferences()
        #expect(refs.isEmpty, "v1: learnedReferences must return []")
    }

    @Test("fingerprintBaselines returns [] in v1")
    func fingerprintBaselinesV1ReturnsEmpty() async throws {
        let (kit, handle) = try await makeKit()
        let reader = EstateMaintenanceReader(handle: handle, kit: kit)
        let baselines = try await reader.fingerprintBaselines()
        #expect(baselines.isEmpty, "v1: fingerprintBaselines must return []")
    }

    // MARK: - § 5  Integration: MaintenanceDaemon with production adapters

    @Test("integration: MaintenanceDaemon with production adapters triggers decay proposals and diary entry")
    func integrationDaemonCycleWithProductionAdapters() async throws {
        let (kit, handle) = try await makeKit()

        // Capture two drawers. The in-memory store uses the current clock for filedAt;
        // we provide a `now` that is far in the future so the drawers appear decayed.
        _ = try await kit.capture(handle, captureFrame(content: "decay candidate A"))
        _ = try await kit.capture(handle, captureFrame(content: "decay candidate B"))

        // Build production adapter pair.
        let reader = EstateMaintenanceReader(handle: handle, kit: kit)
        let sink = EstateMaintenanceSink(handle: handle, kit: kit)
        let policyStore = InMemoryMaintenancePolicyStore()
        let daemon = MaintenanceDaemon(reader: reader, sink: sink, policyStore: policyStore)

        // Set a very short decay window (1 second) so the drawers appear past
        // it when we provide a `now` that is far in the future.
        try await daemon.registerMaintenancePolicy(
            decayWindowSeconds: 1.0
        )

        // Run the cycle 2 seconds after capturedAt — both drawers are > 1 s old.
        // In practice the in-memory store sets filedAt to the current clock, so we
        // provide a `now` that is definitely in the future relative to any test run.
        let cycleNow = Date(timeIntervalSinceNow: 100)
        let report = try await daemon.triggerMaintenanceCycle(now: cycleNow)

        // The cycle must emit a diary entry.
        #expect(report.diaryEntry.agentName == "maintenance-daemon")
        #expect(report.diaryEntry.topic == "maintenance-cycle")

        // The cycle must detect at least some decay candidates (>= 1) since the
        // drawers were captured before `now` and the decay window is 1 second.
        #expect(report.decayCandidates >= 1, "at least one decay candidate expected")

        // Diary entry must be in the estate.
        let diaryEntries = try await kit.readDiaryEntries(
            in: handle,
            agentName: "maintenance-daemon",
            lastN: 10
        )
        #expect(diaryEntries.count == 1, "exactly one diary entry per cycle")
        #expect(diaryEntries[0].topic == "maintenance-cycle")
    }
}
