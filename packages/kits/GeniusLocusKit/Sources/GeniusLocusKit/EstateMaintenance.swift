// EstateMaintenance.swift
//
// Narrow SPI for destructive, offline developer maintenance. This surface is
// intentionally not part of the ordinary GeniusLocusKit API: callers must opt
// in with `@_spi(EstateMaintenance) import GeniusLocusKit` and must operate on
// a quiesced copy of an estate.

import Foundation
@_spi(EstateMaintenance) import CorpusKit
import LocusKit
import PersistenceKit
import SubstrateTypes

/// Count summary returned by `recordPhysicalRemovalEvents`.
@_spi(EstateMaintenance)
public struct PhysicalRemovalAuditSummary: Sendable, Equatable {
    public let requested: Int
    public let appended: Int
    public let alreadyNonLive: Int
    public let missing: Int

    public init(requested: Int, appended: Int, alreadyNonLive: Int, missing: Int) {
        self.requested = requested
        self.appended = appended
        self.alreadyNonLive = alreadyNonLive
        self.missing = missing
    }
}

/// Summary of the accelerator rebuild performed by `rebuildAfterPhysicalRemoval`.
@_spi(EstateMaintenance)
public struct PhysicalRemovalRebuildSummary: Sendable, Equatable {
    public let liveDrawerCount: Int
    public let matrixLiveRowCount: Int
    public let activeChunkCount: Int
    public let rebuiltBundleRooms: Int
    public let rebuiltBundleWings: Int

    public init(
        liveDrawerCount: Int,
        matrixLiveRowCount: Int,
        activeChunkCount: Int,
        rebuiltBundleRooms: Int,
        rebuiltBundleWings: Int
    ) {
        self.liveDrawerCount = liveDrawerCount
        self.matrixLiveRowCount = matrixLiveRowCount
        self.activeChunkCount = activeChunkCount
        self.rebuiltBundleRooms = rebuiltBundleRooms
        self.rebuiltBundleWings = rebuiltBundleWings
    }
}

extension GeniusLocusKit {
    /// Append one balancing expunge event for every requested drawer whose
    /// audit stream still contributes a live Matrix row.
    ///
    /// Normal `expunge` is deliberately not used: it requires the ordinary
    /// accepted-to-tombstone transition and mutates the drawer projection. Estate
    /// surgery needs an audit-only statement of physical removal before raw SQL
    /// removes the projection. `beforeBitmaps` is nil so AuditBridge emits all
    /// three bitmap fields; MatrixTier therefore subtracts the complete capture
    /// fingerprint rather than only the adjective field changed by a normal
    /// tombstone transition.
    @_spi(EstateMaintenance)
    public func recordPhysicalRemovalEvents(
        for handle: EstateHandle,
        drawerIDs: [String],
        now: Date,
        actor: String = "estate-surgery"
    ) async throws -> PhysicalRemovalAuditSummary {
        guard let storage = storages[handle] else {
            throw GeniusLocusKitError.estateNotOpen(estateUUID: handle.estateUUID)
        }
        // Bypass the Estate actor isolation — estate maintenance is an
        // offline operation on a quiesced copy, so direct DrawerStore
        // access is both safe and necessary (Estate.store is internal to
        // LocusKit and unavailable from GeniusLocusKit).
        let drawerStore = try await DrawerStore(storage: storage)
        let estate = try estate(for: handle)
        let globalLog = try await auditLog(for: handle)
        let latestHLC = globalLog.orderedEntries.last?.hlc ?? .zero
        let nowMillis = Int64(now.timeIntervalSince1970 * 1_000)
        let initialPhysical = max(nowMillis, latestHLC.physicalTime == Int64.max
            ? latestHLC.physicalTime
            : latestHLC.physicalTime + 1)
        var clock = HLCGenerator(
            nodeID: 0x4553_5453,
            lastPhysical: initialPhysical,
            lastLogical: 0
        )

        var appended = 0
        var alreadyNonLive = 0
        var missing = 0

        for drawerID in Array(Set(drawerIDs)).sorted() {
            guard let drawer = try await drawerStore.getDrawer(id: drawerID) else {
                missing += 1
                continue
            }
            guard let rowID = UUID(uuidString: drawer.id) else {
                throw GeniusLocusKitError.underlyingEstateFailure(
                    reason: "estate maintenance: drawer id is not a UUID: \(drawer.id)")
            }

            let rowLog = UnifiedAuditLog(
                entries: globalLog.entries(forRow: rowID, tier: .locus))
            guard MatrixTier.rebuild(from: rowLog).liveRowCount > 0 else {
                alreadyNonLive += 1
                continue
            }

            let anchor: SubstrateTypes.LatticeAnchor
            if let qid = drawer.wikidataQID {
                anchor = SubstrateTypes.LatticeAnchor.udcQid(drawer.udcCode, qid: qid)
            } else {
                anchor = SubstrateTypes.LatticeAnchor.udc(drawer.udcCode)
            }
            let bitmaps = (
                adjective: drawer.adjectiveBitmap,
                operational: drawer.operationalBitmap,
                provenance: drawer.provenance
            )
            let event = AuditEvent(
                estateUuid: await estate.estateUUID,
                rowId: rowID,
                hlc: clock.send(now: initialPhysical),
                verb: "expunge",
                beforeBitmaps: nil,
                afterBitmaps: bitmaps,
                beforeLatticeAnchor: nil,
                afterLatticeAnchor: anchor,
                actor: actor,
                reason: "offline physical removal by estate-surgery"
            )
            try await drawerStore.appendAuditEvent(event)
            appended += 1
        }

        return PhysicalRemovalAuditSummary(
            requested: Set(drawerIDs).count,
            appended: appended,
            alreadyNonLive: alreadyNonLive,
            missing: missing
        )
    }

    /// Force authoritative rebuilds after a staged physical removal.
    ///
    /// The Matrix snapshot is discarded first so retained or scrubbed audit
    /// history is folded from zero. Corpus maintenance reconstructs BM25 and
    /// maintained counts, retrains the basis, and replaces surviving vectors.
    /// LocusKit open rebuilds container fingerprints; affected Bundle A rows
    /// are reconstructed from surviving drawers, while unreconstructable
    /// Bundle B history remains cleared. The final full-tree rollup replaces
    /// all surviving Merkle roots.
    @_spi(EstateMaintenance)
    public func rebuildAfterPhysicalRemoval(
        for handle: EstateHandle,
        affectedWingIDs: [String],
        now: Date
    ) async throws -> PhysicalRemovalRebuildSummary {
        guard let storage = storages[handle] else {
            throw GeniusLocusKitError.estateNotOpen(estateUUID: handle.estateUUID)
        }
        let snapshotStore = MatrixSnapshotStore(storage: storage)
        try await snapshotStore.deleteAll()
        // Direct DrawerStore access for live-drawer enumeration — offline
        // maintenance context, same justification as recordPhysicalRemovalEvents.
        let drawerStore = try await DrawerStore(storage: storage)

        // corpusKits holds CorpusContentEngine (the GLK content-engine type at HEAD).
        // The SPI method on CorpusContentEngine rebuilds BM25, counts, and vectors
        // from the surviving active content set.
        let corpusSummary: CorpusPhysicalRemovalRebuildSummary?
        if let corpus = corpusKits[handle] {
            corpusSummary = try await corpus.rebuildAfterPhysicalRemoval(now: now)
        } else {
            corpusSummary = nil
        }

        let estate = try estate(for: handle)
        let bundleSummary = try await rebuildAffectedNodeBundles(
            storage: storage,
            estate: estate,
            affectedWingIDs: affectedWingIDs,
            now: now)
        try await rebuildDerivedAccelerators(for: handle, now: now)

        try await estate.rollupAllMerkleRoots(now: now)
        let liveDrawers = try await drawerStore.allDrawers().filter { $0.tombstonedAt == nil }
        let replayedLiveRows = MatrixTier.rebuild(
            from: try await auditLog(for: handle)).liveRowCount
        guard let matrixTier = matrixTiers[handle],
              let persisted = try await snapshotStore.load(estateID: handle.estateUUID),
              persisted.tier == matrixTier,
              matrixTier.liveRowCount == replayedLiveRows else {
            throw GeniusLocusKitError.underlyingEstateFailure(
                reason: "estate maintenance: rebuilt Matrix did not match audit replay")
        }
        return PhysicalRemovalRebuildSummary(
            liveDrawerCount: liveDrawers.count,
            matrixLiveRowCount: Int(matrixTier.liveRowCount),
            activeChunkCount: corpusSummary?.activeChunkCount ?? 0,
            rebuiltBundleRooms: bundleSummary.rebuiltRooms,
            rebuiltBundleWings: bundleSummary.rebuiltWings
        )
    }

    private func rebuildAffectedNodeBundles(
        storage: any Storage,
        estate: LocusKit.Estate,
        affectedWingIDs: [String],
        now: Date
    ) async throws -> (rebuiltRooms: Int, rebuiltWings: Int) {
        let drawerStore = try await DrawerStore(storage: storage)
        let bundleStore = try await NodeBundleStore(storage: storage)
        let estateID = await estate.estateUUID
        let materializer = BundleMaterializer(
            drawers: drawerStore,
            bundles: bundleStore,
            families: EstateFingerprintFamilies(
                estateUUID: estateID.uuidString))

        var rebuiltRooms = 0
        var rebuiltWings = 0
        for wingID in Array(Set(affectedWingIDs)).sorted() {
            guard let id = UUID(uuidString: wingID),
                  let wing = try await estate.nodeStore.getNode(id: id),
                  wing.depth == 1,
                  wing.lifecycle == 0 else { continue }
            let rooms = try await estate.nodeStore.childNodes(parentId: id)
                .filter { $0.depth == 2 && $0.lifecycle == 0 }
                .sorted { $0.lookupName < $1.lookupName }
            for room in rooms {
                try await materializer.materializeRoom(
                    wing: wing.displayName, room: room.displayName, now: now)
                rebuiltRooms += 1
            }
            try await materializer.rollUpWing(wing: wing.displayName, now: now)
            rebuiltWings += 1
        }
        return (rebuiltRooms, rebuiltWings)
    }
}
