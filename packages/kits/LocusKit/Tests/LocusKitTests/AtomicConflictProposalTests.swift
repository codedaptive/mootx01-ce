import Foundation
import Testing
import PersistenceKit
@testable import LocusKit

@Suite("AtomicConflictProposalTests")
struct AtomicConflictProposalTests {
    private func makeFixture() async throws -> (DrawerStore, any Storage, URL, Drawer, Drawer) {
        let url = TestStorage.tempURL()
        let storage = TestStorage.sqlite(url)
        let store = try await DrawerStore(storage: storage)
        let nodes = NodeStore(storage: storage)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let root = try await nodes.createRoot(displayName: "Estate", now: now)
        let wing = try await nodes.createNode(displayName: "Wing", parentId: root.id, now: now)
        let room = try await nodes.createNode(displayName: "Room", parentId: wing.id, now: now)
        let source = Drawer(
            id: TestStorage.tid("atomic-source"), content: "source evidence",
            parentNodeId: room.id.uuidString, addedBy: "test", filedAt: now,
            embeddingModelID: "test-model")
        let target = Drawer(
            id: TestStorage.tid("atomic-target"), content: "target evidence",
            parentNodeId: room.id.uuidString, addedBy: "test", filedAt: now,
            embeddingModelID: "test-model")
        try await store.addDrawer(source)
        try await store.addDrawer(target)
        return (store, storage, url, source, target)
    }

    private func request(source: Drawer, target: Drawer) -> AtomicConflictProposalRequest {
        let ordered = [source.id.lowercased(), target.id.lowercased()].sorted()
        let pairKey = "\(ordered[0])||\(ordered[1])"   // the hunt's canonical spelling
        let sourceDigest = AtomicConflictProposalRequest.drawerDigest(id: source.id, content: source.content)
        let targetDigest = AtomicConflictProposalRequest.drawerDigest(id: target.id, content: target.content)
        let renewalKey = "tier1:\(pairKey):evidence-1"
        return AtomicConflictProposalRequest(
            sourceDrawerID: source.id, targetDrawerID: target.id,
            pairKey: pairKey, tier: 1, renewalKey: renewalKey,
            evidenceID: "evidence-1", sourceDigest: sourceDigest,
            targetDigest: targetDigest,
            evidenceDigest: AtomicConflictProposalRequest.evidenceDigest(
                pairKey: pairKey, tier: 1, renewalKey: renewalKey,
                evidenceID: "evidence-1", sourceDigest: sourceDigest,
                targetDigest: targetDigest),
            label: "\(renewalKey) proposed contradiction", addedBy: "test",
            filedAt: Date(timeIntervalSince1970: 1_700_000_001),
            declinePolicy: { _ in false })
    }

    @Test("atomic conflict proposal creates once, replays the stored tunnel, and rejects stale evidence")
    func createReplayAndStaleRevalidation() async throws {
        let (store, _, url, source, target) = try await makeFixture()
        defer { TestStorage.cleanup(url) }
        let valid = request(source: source, target: target)

        let created = try await store.fileAtomicConflictProposal(valid)
        let createdTunnel = try #require(created.tunnel)
        #expect(createdTunnel.lifecycle == .proposed)

        let replayed = try await store.fileAtomicConflictProposal(valid)
        let replayedTunnel = try #require(replayed.tunnel)
        #expect(replayedTunnel.id == createdTunnel.id)
        #expect(replayedTunnel.lifecycle == .proposed)
        #expect(try await store.allTunnels().filter { $0.kind == .contradicts }.count == 1)

        let stale = AtomicConflictProposalRequest(
            sourceDrawerID: valid.sourceDrawerID, targetDrawerID: valid.targetDrawerID,
            pairKey: valid.pairKey, tier: valid.tier, renewalKey: valid.renewalKey,
            evidenceID: valid.evidenceID, sourceDigest: String(repeating: "0", count: 64),
            targetDigest: valid.targetDigest, evidenceDigest: valid.evidenceDigest,
            label: valid.label, addedBy: valid.addedBy, filedAt: valid.filedAt,
            declinePolicy: valid.declinePolicy)
        if case .stale = try await store.fileAtomicConflictProposal(stale) {
            // Expected: validation and write share one serializable transaction.
        } else {
            Issue.record("stale evidence must not create or replay a proposal")
        }
        #expect(try await store.allTunnels().filter { $0.kind == .contradicts }.count == 1)
    }

    @Test("selected evidence tombstoned after analysis cannot file a contradiction")
    func tombstonedSelectedEvidenceDoesNotWrite() async throws {
        let (store, storage, url, source, target) = try await makeFixture()
        defer { TestStorage.cleanup(url) }
        let selected = request(source: source, target: target)

        _ = try await storage.rowStore.update(
            table: "drawers",
            values: ["tombstonedAt": .timestamp(Date(timeIntervalSince1970: 1_700_000_002))],
            where: .eq(Column(table: "drawers", name: "id"), .text(source.id))
        )

        if case .stale = try await store.fileAtomicConflictProposal(selected) {
            // Expected: selection no longer identifies live evidence.
        } else {
            Issue.record("tombstoned selected evidence must not file a contradiction")
        }
        #expect(try await store.allTunnels().filter { $0.kind == .contradicts }.isEmpty)
    }

    @Test("selected evidence withdrawn after analysis cannot file a contradiction")
    func withdrawnSelectedEvidenceDoesNotWrite() async throws {
        let (store, _, url, source, target) = try await makeFixture()
        defer { TestStorage.cleanup(url) }
        let selected = request(source: source, target: target)

        try await store.mutateState(
            drawerId: source.id,
            to: .withdrawn,
            via: .retract,
            changedBy: "test"
        )

        if case .stale = try await store.fileAtomicConflictProposal(selected) {
            // Expected: selection no longer identifies currently believed evidence.
        } else {
            Issue.record("withdrawn selected evidence must not file a contradiction")
        }
        #expect(try await store.allTunnels().filter { $0.kind == .contradicts }.isEmpty)
    }

    @Test("superseded replay reports settled without filing a replacement")
    func supersededReplayIsSettled() async throws {
        let (store, _, url, source, target) = try await makeFixture()
        defer { TestStorage.cleanup(url) }
        let selected = request(source: source, target: target)
        let superseded = Tunnel(
            id: UUID().uuidString,
            sourceWing: "Wing", sourceRoom: "Room", sourceDrawerId: source.id,
            targetWing: "Wing", targetRoom: "Room", targetDrawerId: target.id,
            label: selected.label, kind: .contradicts,
            operationalBitmap: Int64(TunnelLifecycle.superseded.rawValue << 3),
            addedBy: "test", filedAt: selected.filedAt
        )
        try await store.addTunnel(superseded)

        if case .settled = try await store.fileAtomicConflictProposal(selected) {
            // Expected: the selected replay identity already reached a terminal lifecycle.
        } else {
            Issue.record("superseded replay must report settled")
        }
        #expect(try await store.allTunnels().filter { $0.kind == .contradicts }.count == 1)
    }
}

private extension AtomicConflictProposalOutcome {
    var tunnel: Tunnel? {
        switch self {
        case .created(let tunnel), .existing(let tunnel): tunnel
        case .settled, .stale: nil
        }
    }
}
