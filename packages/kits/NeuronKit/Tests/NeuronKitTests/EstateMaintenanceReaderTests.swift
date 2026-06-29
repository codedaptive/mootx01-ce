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
///   §3  currentAuditLog: returns a UnifiedAuditLog whose chain verifies
///   §4  signal reads: learnedReferences (empty for estate with no references),
///       and fingerprintBaselines (empty for fresh estate — no content yet)
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

    // MARK: - § 4  Signal reads

    @Test("learnedReferences returns [] for estate with no references")
    func learnedReferencesEmptyForEstateWithNoReferences() async throws {
        // No references filed in the estate → learnedReferences returns [].
        // The implementation reads from recallLearnedReferences; an estate
        // with zero references yields zero observations.
        let (kit, handle) = try await makeKit()
        let reader = EstateMaintenanceReader(handle: handle, kit: kit)
        let refs = try await reader.learnedReferences()
        #expect(refs.isEmpty, "no references in estate → learnedReferences returns []")
    }

    @Test("fingerprintBaselines is empty for a fresh estate (no container aggregate yet)")
    func fingerprintBaselinesEmptyForFreshEstate() async throws {
        // No drawers captured → the container-fingerprint aggregate is empty →
        // no room-level observations. The read path is exercised (no throw).
        let (kit, handle) = try await makeKit()
        let reader = EstateMaintenanceReader(handle: handle, kit: kit)
        let baselines = try await reader.fingerprintBaselines()
        #expect(baselines.isEmpty, "fresh estate → no room-level fingerprints")
    }

    @Test("fingerprintBaselines returns a real per-node drift observation after capture")
    func fingerprintBaselinesReturnsRealObservationAfterCapture() async throws {
        // The reader computes OR-aggregates of drawer bitmaps grouped by
        // parentNodeId (room-level node per ADR-017). After a capture the
        // reader returns one observation for that node with a real,
        // non-negative drift fraction.
        let (kit, handle) = try await makeKit()
        _ = try await kit.capture(handle, captureFrame(content: "alpha", room: "study"))

        let reader = EstateMaintenanceReader(handle: handle, kit: kit)
        let baselines = try await reader.fingerprintBaselines()
        #expect(!baselines.isEmpty, "a captured drawer populates a node-level fingerprint")
        // scopeKey is the parentNodeId — a UUID string, not wing/room.
        // nodeId matches scopeKey in the current implementation.
        if let first = baselines.first {
            #expect(!first.scopeKey.isEmpty, "scope key is non-empty")
            #expect(first.nodeId == first.scopeKey, "nodeId matches scopeKey")
            #expect(first.driftFraction >= 0.0 && first.driftFraction <= 1.0)
        }
    }

    @Test("currentAuditLog feeds a verifiable, intact chain after capture")
    func currentAuditLogYieldsVerifiableChain() async throws {
        // The audit-integrity signal: a captured drawer produces a non-empty
        // audit log whose chain verifies clean through AuditChainVerifier.
        let (kit, handle) = try await makeKit()
        _ = try await kit.capture(handle, captureFrame(content: "audit alpha"))

        let reader = EstateMaintenanceReader(handle: handle, kit: kit)
        let log = try await reader.currentAuditLog()
        let report = AuditChainVerifier.verify(log)
        #expect(report.valid, "a freshly captured chain is intact")
        #expect(report.firstBrokenAt == nil)
        #expect(report.entryCount == log.orderedEntries.count)
    }

    @Test("activeDrawers/tombstonedDrawers use the bounded scan and return seeded rows")
    func boundedScanReturnsSeededRows() async throws {
        let (kit, handle) = try await makeKit()
        for i in 0..<3 {
            _ = try await kit.capture(handle, captureFrame(content: "row \(i)"))
        }
        let reader = EstateMaintenanceReader(handle: handle, kit: kit)
        let active = try await reader.activeDrawers()
        #expect(active.count == 3, "all three live rows are read via the bounded scan")
        let tombstoned = try await reader.tombstonedDrawers()
        #expect(tombstoned.isEmpty, "nothing tombstoned yet")
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
