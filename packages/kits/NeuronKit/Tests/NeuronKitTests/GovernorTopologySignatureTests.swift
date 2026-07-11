// GovernorTopologySignatureTests.swift
//
// Tests for the composite topology-change signature introduced in mission B3
// (topology-coverage fix for AutonomicGovernor, 1.0.28 PATCH).
//
// Root finding (Kong analysis, AUDIT_COVERAGE_TUNNEL_FACT):
// The Swift governor's graphCentralityScan and topologySnapshotDuty gated
// recompute on `hasAuditGrown` — an audit-event-count watermark. Standalone
// tunnel writes (DrawerStore.addTunnel) and KG-fact writes (DrawerStore.addKGFact)
// do bare row inserts with NO audit event, so the audit count did not advance
// after a tunnel-only or KG-fact-only change. Centrality and topology both skipped
// recompute on the next cadence tick even though the graph structure had changed.
//
// Fix: `topologyChangeSignature(for:)` returns the composite string
// "\(auditCount),\(tunnelCount),\(kgFactCount)" — three O(1) COUNT(*) calls that
// together cover all three topology-affecting write paths. `graphCentralityScan`
// and `topologySnapshotDuty` compare the saved composite against the current
// composite; any difference triggers recompute. `preferenceScan` intentionally
// retains the audit-only watermark (recall traces are not affected by tunnels or
// KG-facts; audit-only is correct and sufficient there).
//
// Coverage:
//   §1: topologyChangeSignature probe
//     • Empty estate returns "0,0,0".
//     • Drawer capture advances the audit component.
//     • Tunnel-only write advances the tunnel component; audit component unchanged.
//     • KG-fact-only write advances the kgfact component; audit component unchanged.
//   §2: graphCentralityScan reacts to the composite signature
//     • After first scan, centralityCount meta key holds the composite sig.
//     • After a tunnel-only change, second scan recomputes and updates the sig.
//     • After a KG-fact-only change, second scan recomputes and updates the sig.
//     • On a no-op tick (nothing changed), second scan skips; sig unchanged.

import Foundation
import Testing
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import NeuronKit

private let t0 = Date(timeIntervalSince1970: 1_750_000_000)

// MARK: - Estate factory

/// Open a fresh in-memory estate via GeniusLocusKit.
/// Pattern mirrors GovernorGCSweepTests and RecallTunnelsTests.
private func openEstate(owner ownerTag: String) async throws -> (GeniusLocusKit, EstateHandle) {
    let kit = GeniusLocusKit()
    let owner = OwnerCredentials(ownerIdentifier: "gov-topo-sig-\(ownerTag)")
    let storage = InMemoryStorage(
        configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
    _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
    let handle = try await kit.open(storage: storage, owner: owner)
    return (kit, handle)
}

// MARK: - Write helpers

/// Capture a drawer via the direct estate path (writes one audit event).
@discardableResult
private func captureDrawer(
    _ estate: Estate,
    tag: String,
    room: String = "sig-test-room"
) async throws -> Drawer {
    try await estate.capture(CaptureFrame(
        content: "sig-test-content-\(tag)",
        channel: .typed,
        room: room,
        latticeAnchor: LatticeAnchor.udc("000"),
        addedBy: "sig-test",
        embeddingModelID: "test-model-v1"))
}

/// Add a tunnel between two drawers via the direct estate path.
/// A tunnel is a bare row insert with NO audit event — only tunnelCount advances.
@discardableResult
private func addTunnel(
    _ estate: Estate,
    srcDrawerID: String? = nil,
    tgtDrawerID: String? = nil
) async throws -> Tunnel {
    try await estate.capture(TunnelCaptureFrame(
        sourceWing: "sig-test-wing",
        sourceRoom: "sig-test-room",
        targetWing: "sig-test-wing",
        targetRoom: "sig-test-room",
        label: "sig-test-edge",
        addedBy: "sig-test",
        sourceDrawerId: srcDrawerID,
        targetDrawerId: tgtDrawerID,
        kind: .references))
}

/// File a KG-fact via the GeniusLocusKit verb surface.
/// KG-fact writes are bare row inserts with NO audit event — only kgfactCount advances.
@discardableResult
private func addKGFact(
    _ kit: GeniusLocusKit,
    _ handle: EstateHandle,
    subject: String = "SigTestSubject",
    now: Date = t0
) async throws -> KGFact {
    try await kit.captureKGFact(
        handle,
        subject: subject,
        predicate: "is",
        object: "SigTestObject",
        now: now)
}

// MARK: - §1: topologyChangeSignature probe

@Suite("Composite topology-change signature — probe behavior (§1)", .serialized)
struct TopologySignatureProbeTests {

    @Test("empty estate signature is 0,0,0")
    func emptyEstateSignatureIsZeroTuple() async throws {
        let (kit, handle) = try await openEstate(owner: "empty")
        let sig = try await kit.topologyChangeSignature(for: handle)
        #expect(sig == "0,0,0",
            "an estate with no writes must produce the '0,0,0' sentinel")
        try await kit.close(handle)
    }

    @Test("drawer capture advances audit component; tunnel and kgfact stay 0")
    func drawerCaptureAdvancesAuditComponent() async throws {
        let (kit, handle) = try await openEstate(owner: "drawer")
        let before = try await kit.topologyChangeSignature(for: handle)
        #expect(before == "0,0,0")

        let estate = try await kit.estate(for: handle)
        _ = try await captureDrawer(estate, tag: "alpha")

        let after = try await kit.topologyChangeSignature(for: handle)
        let parts = after.split(separator: ",")
        #expect(parts.count == 3,
            "signature must always have exactly three comma-separated counts")
        #expect(Int(parts[0])! > 0,
            "audit component must be positive after a drawer capture")
        #expect(parts[1] == "0",
            "tunnel component must remain 0 after drawer-only capture")
        #expect(parts[2] == "0",
            "kgfact component must remain 0 after drawer-only capture")
        #expect(after != before,
            "signature must differ after a drawer capture")
        try await kit.close(handle)
    }

    @Test("tunnel-only write advances tunnel component; audit component unchanged")
    func tunnelOnlyWriteAdvancesTunnelComponent() async throws {
        let (kit, handle) = try await openEstate(owner: "tunnel")

        // Capture two drawers (each writes an audit event).
        let estate = try await kit.estate(for: handle)
        let d1 = try await captureDrawer(estate, tag: "d1")
        let d2 = try await captureDrawer(estate, tag: "d2")

        let afterDrawers = try await kit.topologyChangeSignature(for: handle)
        let auditBeforeTunnel = Int(afterDrawers.split(separator: ",")[0])!

        // Add a tunnel — NO audit event.
        _ = try await addTunnel(estate, srcDrawerID: d1.id, tgtDrawerID: d2.id)

        let afterTunnel = try await kit.topologyChangeSignature(for: handle)
        let parts = afterTunnel.split(separator: ",")
        #expect(parts.count == 3)
        #expect(Int(parts[0])! == auditBeforeTunnel,
            "audit component must NOT change after a tunnel-only write")
        #expect(Int(parts[1])! == 1,
            "tunnel component must advance to 1 after one tunnel write")
        #expect(parts[2] == "0",
            "kgfact component must stay at 0")
        #expect(afterTunnel != afterDrawers,
            "composite signature must differ after a tunnel-only write")
        try await kit.close(handle)
    }

    @Test("KG-fact-only write advances kgfact component; audit component unchanged")
    func kgFactOnlyWriteAdvancesKGFactComponent() async throws {
        let (kit, handle) = try await openEstate(owner: "kgfact")

        // Capture a drawer (writes an audit event).
        let estate = try await kit.estate(for: handle)
        _ = try await captureDrawer(estate, tag: "base")

        let afterDrawer = try await kit.topologyChangeSignature(for: handle)
        let auditBeforeFact = Int(afterDrawer.split(separator: ",")[0])!

        // Add a KG-fact — NO audit event.
        _ = try await addKGFact(kit, handle)

        let afterFact = try await kit.topologyChangeSignature(for: handle)
        let parts = afterFact.split(separator: ",")
        #expect(parts.count == 3)
        #expect(Int(parts[0])! == auditBeforeFact,
            "audit component must NOT change after a KG-fact-only write")
        #expect(parts[1] == "0",
            "tunnel component must stay at 0")
        #expect(Int(parts[2])! == 1,
            "kgfact component must advance to 1 after one KG-fact write")
        #expect(afterFact != afterDrawer,
            "composite signature must differ after a KG-fact-only write")
        try await kit.close(handle)
    }
}

// MARK: - §2: graphCentralityScan + composite signature

@Suite("graphCentralityScan — composite signature watermark (§2)", .serialized)
struct GraphCentralityScanSignatureTests {

    @Test("first scan stores composite signature in centralityCount meta key")
    func firstScanStoresCompositeSignature() async throws {
        let (kit, handle) = try await openEstate(owner: "cscan-store")

        // Set up two drawers + one tunnel so scores are non-empty.
        let estate = try await kit.estate(for: handle)
        let d1 = try await captureDrawer(estate, tag: "d1")
        let d2 = try await captureDrawer(estate, tag: "d2")
        _ = try await addTunnel(estate, srcDrawerID: d1.id, tgtDrawerID: d2.id)

        try await AutonomicGovernor.graphCentralityScan(kit: kit, handle: handle, now: t0)

        let savedSig = try await estate.meta(key: NeuronKitManifestKey.centralityCount)
        let currentSig = try await kit.topologyChangeSignature(for: handle)

        // Saved sig must equal the composite that was current at scan time.
        #expect(savedSig == currentSig,
            "centralityCount meta key must equal the composite signature after a scan")

        // Stored value must be the three-part composite, not the old bare-Int format.
        let parts = (savedSig ?? "").split(separator: ",")
        #expect(parts.count == 3,
            "stored centralityCount must have three comma-separated counts")

        // Tunnel component must be 1 (one tunnel was added before the scan).
        #expect(parts[1] == "1",
            "tunnel component of stored sig must be 1 after one tunnel was added")
        try await kit.close(handle)
    }

    @Test("graphCentralityScan recomputes after tunnel-only change (bug: audit-only watermark would skip)")
    func scanRecomputesAfterTunnelOnlyChange() async throws {
        let (kit, handle) = try await openEstate(owner: "cscan-tunnel")

        // Step 1: capture two drawers (audit events fire).
        let estate = try await kit.estate(for: handle)
        let d1 = try await captureDrawer(estate, tag: "d1")
        let d2 = try await captureDrawer(estate, tag: "d2")

        // Step 2: first scan — computes centrality, saves sig "2,0,0".
        try await AutonomicGovernor.graphCentralityScan(kit: kit, handle: handle, now: t0)
        let sigAfterFirstScan = try await estate.meta(key: NeuronKitManifestKey.centralityCount)
        #expect(sigAfterFirstScan?.split(separator: ",").count == 3,
            "first scan must store a three-part composite signature")

        // Step 3: add a tunnel — NO audit event; audit count unchanged.
        // An audit-only watermark would incorrectly see "no change" here.
        _ = try await addTunnel(estate, srcDrawerID: d1.id, tgtDrawerID: d2.id)

        // Step 4: second scan — the composite signature detects tunnelCount advancing
        // ("2,0,0" → "2,1,0") and recomputes, updating centralityCount.
        try await AutonomicGovernor.graphCentralityScan(
            kit: kit, handle: handle, now: t0.addingTimeInterval(1))
        let sigAfterSecondScan = try await estate.meta(key: NeuronKitManifestKey.centralityCount)

        #expect(sigAfterSecondScan != sigAfterFirstScan,
            "centralityCount must update after a tunnel-only change triggers recompute")

        // Tunnel component of the new sig must be 1.
        let parts = (sigAfterSecondScan ?? "").split(separator: ",")
        #expect(parts.count == 3)
        #expect(parts[1] == "1",
            "tunnel component of updated sig must be 1 after one tunnel was added")
        try await kit.close(handle)
    }

    @Test("graphCentralityScan recomputes after KG-fact-only change (bug: audit-only watermark would skip)")
    func scanRecomputesAfterKGFactOnlyChange() async throws {
        let (kit, handle) = try await openEstate(owner: "cscan-kgfact")

        // Step 1: capture a drawer (audit event fires).
        let estate = try await kit.estate(for: handle)
        _ = try await captureDrawer(estate, tag: "base")

        // Step 2: first scan — computes centrality, saves sig "1,0,0".
        try await AutonomicGovernor.graphCentralityScan(kit: kit, handle: handle, now: t0)
        let sigAfterFirstScan = try await estate.meta(key: NeuronKitManifestKey.centralityCount)
        #expect(sigAfterFirstScan?.split(separator: ",").count == 3,
            "first scan must store a three-part composite signature")

        // Step 3: add a KG-fact — NO audit event; audit count unchanged.
        // An audit-only watermark would incorrectly see "no change" here.
        _ = try await addKGFact(kit, handle)

        // Step 4: second scan — the composite signature detects kgfactCount advancing
        // ("1,0,0" → "1,0,1") and recomputes, updating centralityCount.
        try await AutonomicGovernor.graphCentralityScan(
            kit: kit, handle: handle, now: t0.addingTimeInterval(1))
        let sigAfterSecondScan = try await estate.meta(key: NeuronKitManifestKey.centralityCount)

        #expect(sigAfterSecondScan != sigAfterFirstScan,
            "centralityCount must update after a KG-fact-only change triggers recompute")

        // KGFact component of the new sig must be 1.
        let parts = (sigAfterSecondScan ?? "").split(separator: ",")
        #expect(parts.count == 3)
        #expect(parts[2] == "1",
            "kgfact component of updated sig must be 1 after one KG-fact was added")
        try await kit.close(handle)
    }

    @Test("graphCentralityScan skips recompute on a no-op tick; centralityCount unchanged")
    func scanSkipsOnNoOpTick() async throws {
        let (kit, handle) = try await openEstate(owner: "cscan-noop")

        // Set up two drawers + a tunnel so the first scan produces non-empty scores
        // (non-empty scores are required for the skip-path to engage on the second tick).
        let estate = try await kit.estate(for: handle)
        let d1 = try await captureDrawer(estate, tag: "d1")
        let d2 = try await captureDrawer(estate, tag: "d2")
        _ = try await addTunnel(estate, srcDrawerID: d1.id, tgtDrawerID: d2.id)

        // First scan: computes centrality, saves sig and scores.
        try await AutonomicGovernor.graphCentralityScan(kit: kit, handle: handle, now: t0)
        let sigAfterFirstScan = try await estate.meta(key: NeuronKitManifestKey.centralityCount)

        // Second scan: nothing changed — signature must be identical, skip path fires.
        // The centralityCount meta key must remain at the same value (skip path does NOT
        // call setMeta; re-reading produces the same string set by the first scan).
        try await AutonomicGovernor.graphCentralityScan(
            kit: kit, handle: handle, now: t0.addingTimeInterval(1))
        let sigAfterSecondScan = try await estate.meta(key: NeuronKitManifestKey.centralityCount)

        #expect(sigAfterSecondScan == sigAfterFirstScan,
            "centralityCount must be unchanged on a no-op tick (skip path does not update the key)")
        try await kit.close(handle)
    }
}
