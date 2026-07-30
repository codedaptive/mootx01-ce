// SensitivityInheritanceTests.swift
//
// Sensitivity inheritance (§D.1, §D.2) at the LocusKit layer:
//
//   - consolidateTransactionally stamps each _consolidated_from tunnel with
//     max(vague, constituent) adjective sensitivity (bits 6–11, cookbook §2.3).
//   - foldInTransactionally stamps the supersedes tunnel with v2's tier and
//     each _consolidated_from tunnel with max(v2, constituent) tier.
//   - propose stamps the proposal's own adjectiveBitmap bits 6–11 with the
//     target drawer's adjective sensitivity (§D.2).
//
// All tests operate at the DrawerStore / Estate layer; no GLK required.

import Foundation
import Testing
import SubstrateKernel
@testable import LocusKit

@Suite("SensitivityInheritanceTests — tunnel stamp + proposal stamp (§D.1, §D.2)")
struct SensitivityInheritanceTests {

    // MARK: - Fixture helpers

    private func t(_ epoch: TimeInterval) -> Date {
        Date(timeIntervalSince1970: epoch)
    }

    private func makeTempURL() -> URL {
        let name = "locuskit-sensitest-\(UUID().uuidString).sqlite"
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("sqlite-wal"))
        try? FileManager.default.removeItem(at: url.appendingPathExtension("sqlite-shm"))
    }

    private func makeStore() async throws -> (DrawerStore, URL) {
        let url = makeTempURL()
        let store = try await DrawerStore(storage: TestStorage.sqlite(url))
        return (store, url)
    }

    /// Create a plain episodic drawer with a given adjective sensitivity.
    private func episodicDrawer(id: String, sensitivity: AdjectiveSensitivity) -> Drawer {
        let adjBitmap = BitField.writeField(
            Int64(sensitivity.rawValue), into: 0, shift: 6, width: 6)
        return Drawer(
            id: TestStorage.tid(id),
            content: "episodic content \(id)",
            parentNodeId: "test-parent",
            addedBy: "newton",
            filedAt: t(1_700_000_000),
            embeddingModelID: "test-model-v1",
            adjectiveBitmap: adjBitmap
        )
    }

    /// Create a vague drawer with isVague (bit 20) set and a given sensitivity.
    private func vagueDrawer(id: String, sensitivity: AdjectiveSensitivity) -> Drawer {
        let adjBitmap = BitField.writeField(
            Int64(sensitivity.rawValue), into: 0, shift: 6, width: 6)
        return Drawer(
            id: TestStorage.tid(id),
            content: "vague summary \(id)",
            parentNodeId: "test-parent",
            addedBy: "newton",
            filedAt: t(1_700_001_000),
            embeddingModelID: "test-model-v1",
            adjectiveBitmap: adjBitmap,
            operationalBitmap: DrawerFeatureFlags.isVague.rawValue
        )
    }

    // MARK: - consolidateTransactionally tunnel stamp

    @Test("consolidateTransactionally stamps _consolidated_from tunnels with max(vague, constituent) sensitivity")
    func consolidate_tunnelsCarryMaxSensitivity() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }

        // One normal constituent and one restricted constituent;
        // vague drawer is at normal. Tunnel to the restricted constituent
        // must carry restricted; tunnel to the normal constituent inherits
        // the vague tier (normal).
        let d1 = episodicDrawer(id: "d1", sensitivity: .normal)
        let d2 = episodicDrawer(id: "d2", sensitivity: .restricted)
        let d3 = episodicDrawer(id: "d3", sensitivity: .normal)
        for d in [d1, d2, d3] { try await store.addDrawer(d) }

        let vague = vagueDrawer(id: "v1", sensitivity: .normal)
        try await store.consolidateTransactionally(
            vagueDrawer: vague,
            constituentIDs: [d1.id, d2.id, d3.id],
            addedBy: "newton",
            now: t(1_700_002_000)
        )

        // Fetch all tunnels for this consolidation.
        let allTunnels = try await store.tunnelsTouching(vague.id)

        // Tunnel to the restricted constituent must carry restricted sensitivity.
        let tunnelToD2 = allTunnels.first { $0.targetDrawerId == d2.id }
        let t2 = try #require(tunnelToD2, "tunnel to restricted constituent must exist")
        #expect(t2.adjectiveSensitivity == .restricted,
                "tunnel to restricted constituent must carry .restricted tier")

        // Tunnel to normal constituent inherits vague tier (normal).
        let tunnelToD1 = allTunnels.first { $0.targetDrawerId == d1.id }
        let t1 = try #require(tunnelToD1, "tunnel to normal constituent must exist")
        #expect(t1.adjectiveSensitivity == .normal,
                "tunnel to normal constituent inherits vague tier (.normal)")
    }

    @Test("consolidateTransactionally: vague drawer elevated lifts all tunnel tiers to elevated")
    func consolidate_vagueElevatedLiftsAllTunnels() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }

        let d1 = episodicDrawer(id: "d1", sensitivity: .normal)
        let d2 = episodicDrawer(id: "d2", sensitivity: .normal)
        let d3 = episodicDrawer(id: "d3", sensitivity: .normal)
        for d in [d1, d2, d3] { try await store.addDrawer(d) }

        // Vague drawer stamped elevated (e.g. repair sweep scenario).
        let vague = vagueDrawer(id: "v1", sensitivity: .elevated)
        try await store.consolidateTransactionally(
            vagueDrawer: vague,
            constituentIDs: [d1.id, d2.id, d3.id],
            addedBy: "newton",
            now: t(1_700_002_000)
        )

        let allTunnels = try await store.tunnelsTouching(vague.id)
        // All three tunnels must carry elevated (from the vague drawer).
        let cfTunnels = allTunnels.filter { $0.label == "_consolidated_from" }
        #expect(cfTunnels.count == 3)
        for tun in cfTunnels {
            #expect(tun.adjectiveSensitivity == .elevated,
                    "vague drawer at .elevated must lift tunnel tier to .elevated")
        }
    }

    // MARK: - foldInTransactionally tunnel stamp

    @Test("foldInTransactionally supersedes tunnel carries v2 sensitivity")
    func foldIn_supersedesTunnelCarriesV2Sensitivity() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }

        // Baseline: 3 normal constituents, vague v1 at normal.
        let d1 = episodicDrawer(id: "d1", sensitivity: .normal)
        let d2 = episodicDrawer(id: "d2", sensitivity: .normal)
        let d3 = episodicDrawer(id: "d3", sensitivity: .normal)
        for d in [d1, d2, d3] { try await store.addDrawer(d) }
        let v1 = vagueDrawer(id: "v1", sensitivity: .normal)
        try await store.consolidateTransactionally(
            vagueDrawer: v1,
            constituentIDs: [d1.id, d2.id, d3.id],
            addedBy: "newton",
            now: t(1_700_002_000)
        )

        // A fourth normal constituent folds in; v2 is stamped elevated
        // (e.g. it absorbed a new elevated constituent at the GLK layer).
        let d4 = episodicDrawer(id: "d4", sensitivity: .elevated)
        try await store.addDrawer(d4)
        let v2 = vagueDrawer(id: "v2", sensitivity: .elevated)
        // Share lineageID with v1 (required by foldIn precondition).
        let v2WithLineage = Drawer(
            id: TestStorage.tid("v2"),
            content: "vague v2",
            parentNodeId: "test-parent",
            addedBy: "newton",
            filedAt: t(1_700_003_000),
            embeddingModelID: "test-model-v1",
            adjectiveBitmap: BitField.writeField(
                Int64(AdjectiveSensitivity.elevated.rawValue), into: 0, shift: 6, width: 6),
            operationalBitmap: DrawerFeatureFlags.isVague.rawValue,
            lineageID: v1.lineageID
        )
        try await store.foldInTransactionally(
            vagueV2: v2WithLineage,
            priorVagueID: v1.id,
            enlargedConstituentIDs: [d1.id, d2.id, d3.id, d4.id],
            addedBy: "newton",
            now: t(1_700_004_000)
        )

        // Supersedes tunnel must carry v2's elevated tier.
        let allTunnels = try await store.tunnelsTouching(v2WithLineage.id)
        let supersedesTun = allTunnels.first { $0.kind == .supersedes }
        let st = try #require(supersedesTun, "supersedes tunnel must exist")
        #expect(st.adjectiveSensitivity == .elevated,
                "supersedes tunnel must carry v2's .elevated sensitivity")
    }

    @Test("foldInTransactionally _consolidated_from tunnels carry max(v2, constituent) sensitivity")
    func foldIn_cfTunnelsCarryMaxSensitivity() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }

        let d1 = episodicDrawer(id: "d1", sensitivity: .normal)
        let d2 = episodicDrawer(id: "d2", sensitivity: .restricted)
        let d3 = episodicDrawer(id: "d3", sensitivity: .normal)
        for d in [d1, d2, d3] { try await store.addDrawer(d) }
        let v1 = vagueDrawer(id: "v1", sensitivity: .normal)
        try await store.consolidateTransactionally(
            vagueDrawer: v1,
            constituentIDs: [d1.id, d2.id, d3.id],
            addedBy: "newton",
            now: t(1_700_002_000)
        )

        // v2 is at normal; constituent d2 is restricted → d2's tunnel must be restricted.
        let d4 = episodicDrawer(id: "d4", sensitivity: .normal)
        try await store.addDrawer(d4)
        let v2WithLineage = Drawer(
            id: TestStorage.tid("v2"),
            content: "vague v2",
            parentNodeId: "test-parent",
            addedBy: "newton",
            filedAt: t(1_700_003_000),
            embeddingModelID: "test-model-v1",
            operationalBitmap: DrawerFeatureFlags.isVague.rawValue,
            lineageID: v1.lineageID
        )
        try await store.foldInTransactionally(
            vagueV2: v2WithLineage,
            priorVagueID: v1.id,
            enlargedConstituentIDs: [d1.id, d2.id, d3.id, d4.id],
            addedBy: "newton",
            now: t(1_700_004_000)
        )

        let allTunnels = try await store.tunnelsTouching(v2WithLineage.id)
        let tunnelToD2 = allTunnels.first {
            $0.label == "_consolidated_from" && $0.targetDrawerId == d2.id
        }
        let t2 = try #require(tunnelToD2, "tunnel to restricted constituent must exist")
        #expect(t2.adjectiveSensitivity == .restricted,
                "_consolidated_from tunnel to restricted constituent must carry .restricted")

        let tunnelToD1 = allTunnels.first {
            $0.label == "_consolidated_from" && $0.targetDrawerId == d1.id
        }
        let t1 = try #require(tunnelToD1)
        #expect(t1.adjectiveSensitivity == .normal,
                "_consolidated_from tunnel to normal constituent carries .normal when v2 is normal")
    }

    // MARK: - proposal sensitivity stamp (§D.2)

    @Test("propose stamps proposal adjectiveBitmap bits 6–11 with target drawer's sensitivity")
    func propose_inheritsTargetSensitivity() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("locuskit-prop-sens-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("estate.sqlite3")
        defer { try? FileManager.default.removeItem(at: dir) }

        // Capture a restricted drawer and propose against it.
        let estate = try await Estate.create(
            storage: TestStorage.sqlite(path),
            owner: OwnerCredentials(ownerIdentifier: "test-owner")
        )
        let frame = CaptureFrame(
            content: "restricted knowledge",
            channel: .typed,
            room: "test-room",
            latticeAnchor: LatticeAnchor(udcCode: "005"),
            addedBy: "test-agent",
            embeddingModelID: "minilm-v1",
            sensitivity: .restricted
        )
        let target = try await estate.capture(frame)
        #expect(target.adjectiveSensitivity == .restricted,
                "target drawer must carry .restricted tier")

        let proposal = try await estate.propose(
            ProposeFrame(
                target: target.id,
                kind: .mutateDrawer,
                justification: "test"
            ),
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )

        // Proposal's adjective sensitivity bits 6–11 must reflect the target's tier.
        #expect(proposal.adjectiveSensitivity == .restricted,
                "proposal must inherit target drawer's .restricted sensitivity in bits 6–11")
    }

    @Test("propose on a normal target leaves proposal sensitivity at .normal")
    func propose_normalTargetLeavesNormalSensitivity() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("locuskit-prop-norm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("estate.sqlite3")
        defer { try? FileManager.default.removeItem(at: dir) }

        let estate = try await Estate.create(
            storage: TestStorage.sqlite(path),
            owner: OwnerCredentials(ownerIdentifier: "test-owner")
        )
        let frame = CaptureFrame(
            content: "normal knowledge",
            channel: .typed,
            room: "test-room",
            latticeAnchor: LatticeAnchor(udcCode: "005"),
            addedBy: "test-agent",
            embeddingModelID: "minilm-v1"
            // sensitivity defaults to .normal
        )
        let target = try await estate.capture(frame)
        let proposal = try await estate.propose(
            ProposeFrame(target: target.id, kind: .mutateDrawer, justification: "test"),
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        #expect(proposal.adjectiveSensitivity == .normal,
                "proposal against a .normal target must carry .normal sensitivity")
    }

    @Test("propose on a secret target stamps proposal with .secret sensitivity")
    func propose_secretTargetStampsSecret() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("locuskit-prop-secret-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("estate.sqlite3")
        defer { try? FileManager.default.removeItem(at: dir) }

        let estate = try await Estate.create(
            storage: TestStorage.sqlite(path),
            owner: OwnerCredentials(ownerIdentifier: "test-owner")
        )
        let frame = CaptureFrame(
            content: "secret knowledge",
            channel: .typed,
            room: "classified",
            latticeAnchor: LatticeAnchor(udcCode: "005"),
            addedBy: "test-agent",
            embeddingModelID: "minilm-v1",
            sensitivity: .secret
        )
        let target = try await estate.capture(frame)
        let proposal = try await estate.propose(
            ProposeFrame(target: target.id, kind: .mutateDrawer, justification: "test"),
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        #expect(proposal.adjectiveSensitivity == .secret,
                "proposal against a .secret target must carry .secret sensitivity")
    }
}

// MARK: - DrawerStore tunnel helper

private extension DrawerStore {

    /// Fetch all non-tombstoned tunnels touching `drawerID` (as source or target).
    /// Test-only helper layered on the public `allTunnels()` surface.
    func tunnelsTouching(_ drawerID: String) async throws -> [Tunnel] {
        let all = try await allTunnels()
        return all.filter { $0.sourceDrawerId == drawerID || $0.targetDrawerId == drawerID }
    }
}
