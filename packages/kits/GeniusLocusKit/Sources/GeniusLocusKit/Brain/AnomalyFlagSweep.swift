// AnomalyFlagSweep.swift
//
// Container-cohesion anomaly-flag sweep for GeniusLocusKit (§11.18,
// anomalous-flag recall prefilter; ADR-026, spec § CHESTS).
//
// Scores each drawer's mean shingle-similarity to its peers in the same
// CONTAINER (a chest, or the room itself while the room has never been
// re-binned), derives z-scores from the container's cohesion distribution,
// and sets/clears bit 26 (`isAnomalous`) of `operationalBitmap`.
//
// Design mirrors the cohesion math in CognitionKit's Contradiction
// recipe (ShingleSimilarity.similarity + negative-z outlier gate),
// but writes a PERSISTENT flag instead of returning a transient list.
// The sweep lives in GeniusLocusKit (not NeuronKit) because it calls
// the write primitive `Estate.setAnomalousFlag` — a LocusKit write
// that GeniusLocusKit owns as the composition layer. NeuronKit depends
// on GeniusLocusKit, so the reverse direction (GLK importing NeuronKit)
// would create a circular dependency.
//
// SubstrateML is the direct dependency for AnomalyDetection,
// ShingleSimilarity and CohesionRoster — conformance-gated byte-identical
// Swift+Rust implementations.
//
// Sweep properties:
//   • Container minimum size: 3 drawers (z-score not meaningful for < 3 peers)
//   • Cohesion metric: mean char-3-shingle Jaccard to all container peers
//   • Gate: z-score ≤ −threshold (low-cohesion outlier) → isAnomalous = true
//   • Default threshold: 2.0 (≈ 2σ below-mean cutoff)
//   • Derived signal: no audit event, no lifecycle/lineage field touched
//   • Incremental: a roster row per container (queue checkpoint store,
//     stream `anomaly-sweep-checkpoints`) keeps every member's exact
//     integer sum of quantised similarities to its peers (CohesionRoster).
//     A write that adds or removes a drawer costs one pass over the
//     container, not a square; the square is paid once, on a container's
//     first scoring, and a container is at most `ChestPlacement.capacity`
//     drawers, so it is bounded. A container at or above capacity is not
//     scored: its room is owed a re-bin (ChestRebin.swift) instead.
//   • Fallback: a member whose old content cannot be recovered (expunged,
//     or a digest that no longer matches) rescores the container whole and
//     replaces the roster.
//   • `anomalyFlagSweep` remains the whole-estate form (tests, operator
//     tooling): every container rescored whole.

import EngramLib
import Foundation
import QueueKit
import SubstrateTypes
import MootProductIdentity
import LocusKit
import OSLog
import SubstrateML

// MARK: - Anomaly sweep constants

public extension GeniusLocusKit {

    /// Minimum drawers per container to run the z-score computation (§11.18).
    ///
    /// Below this threshold, the standard deviation is either zero or
    /// statistically unstable. All drawers in under-threshold containers
    /// have bit 26 cleared — not anomalous by definition.
    static let anomalySweepMinRoomSize: Int = 3

    /// Default z-score threshold for the negative-cohesion anomaly gate (§11.18).
    ///
    /// A drawer is flagged anomalous when its cohesion z-score ≤ −threshold.
    /// Default 2.0 balances sensitivity (catches ~2σ below-mean drawers)
    /// against false-positive rate (~2.3% under a normal distribution).
    static let anomalySweepDefaultThreshold: Float32 = 2.0
}

/// One unit of the anomaly sweep: a container (a chest, or a room holding
/// drawers directly) and the room it belongs to.
public struct AnomalyContainer: Sendable, Equatable, Hashable {
    /// The container node id, the drawers' `parentNodeId`.
    public let nodeId: String
    public let wing: String
    public let room: String
    public init(nodeId: String, wing: String, room: String) {
        self.nodeId = nodeId; self.wing = wing; self.room = room
    }
}

// MARK: - Anomaly flag sweep

extension GeniusLocusKit {

    /// Logger for the anomaly-flag sweep, fleet-standard subsystem + category.
    private static var anomalyLog: Logger {
        Logger(subsystem: MootProductIdentity.Logging.subsystem, category: "GeniusLocusKit")
    }

    // MARK: Whole-estate form

    /// Score every container whole and set/clear bit 26 (`isAnomalous`) on
    /// every drawer, replacing every roster.
    ///
    /// This is a DERIVED SIGNAL write: no audit event, no supersession cascade,
    /// no lifecycle or lineage field touched. The bit is owned entirely by this
    /// sweep and should not be set through any other path.
    ///
    /// The resident does not call this: on a large estate it is minutes of
    /// pure compute. The resident pays `runAnomalySweepBatch` through the duty
    /// queue, which scores only containers touched since their last scoring,
    /// incrementally.
    ///
    /// - Parameters:
    ///   - handle: The estate handle to sweep. Must be open in this kit.
    ///   - threshold: Z-score threshold; drawers with z ≤ −threshold are
    ///     flagged. Default `anomalySweepDefaultThreshold` (2.0).
    ///   - now: Caller-supplied instant (deterministic clock discipline).
    /// - Returns: Count of drawers whose bit 26 changed state.
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if `handle` is stale.
    public func anomalyFlagSweep(
        handle: EstateHandle,
        threshold: Float32 = GeniusLocusKit.anomalySweepDefaultThreshold,
        now: Date
    ) async throws -> Int {
        let estate = try estate(for: handle)
        let checkpoints = try await factCheckpoints(handle)
        var changed = 0
        for entry in try await estate.roomLevelFingerprints() {
            for range in try await estate.containers(in: entry.wing, room: entry.room) {
                let container = AnomalyContainer(nodeId: range.chestNodeId, wing: entry.wing, room: entry.room)
                changed += try await scoreContainer(estate: estate, checkpoints: checkpoints, container: container,
                                                    threshold: threshold, whole: true, now: now)
            }
        }
        Self.anomalyLog.debug(
            "anomalyFlagSweep: \(changed, privacy: .public) drawer(s) updated")
        return changed
    }

    // MARK: Incremental duty form (§ DUTY_LIFECYCLE, § CHESTS)

    /// Checkpoint stream for the incremental sweep: one `cursor` row (the last
    /// audit HLC folded into container dirtiness) and one roster row per
    /// container keyed by its node id. Lives in the estate's queue database
    /// beside the other duty state; no schema, no migration. A container with
    /// no row has never been scored and is owed.
    static var anomalySweepStream: StreamID { StreamID(rawValue: "anomaly-sweep-checkpoints") }
    static var anomalySweepCursorID: JobID { JobID(rawValue: "cursor") }
    static func anomalySweepRosterID(containerNodeId: String) -> JobID {
        JobID(rawValue: containerNodeId.lowercased())
    }
    /// Audit events folded per debt read; bounded so a burst of writes costs
    /// a few passes, never one long one.
    static let anomalySweepAuditFold = 2_000

    struct AnomalySweepCursor: Codable, Sendable {
        var physicalTime: Int64
        var logicalCount: Int32
        var nodeID: Int32
        var hlc: HLC { HLC(physicalTime: physicalTime, logicalCount: logicalCount, nodeID: nodeID) }
        init(hlc: HLC) { physicalTime = hlc.physicalTime; logicalCount = hlc.logicalCount; nodeID = hlc.nodeID }
    }
    /// The roster row: the container, its room, whether a write touched it
    /// since its last scoring, and the exact integer sums of its members.
    /// `roster.entries` is the truth every pass reconciles against.
    struct AnomalySweepRosterRow: Codable, Sendable {
        var container: String
        var wing: String
        var room: String
        var dirty: Bool
        var roster: CohesionRoster
    }

    /// The content digest a roster entry is scored under: a drawer whose
    /// digest differs from its entry has different content than the sum was
    /// computed with.
    static func anomalyContentDigest(_ content: String) -> String {
        factSourceDigest(content)
    }

    private func readRoster(_ checkpoints: QueueCheckpointStore, containerNodeId: String) async throws -> (Data?, AnomalySweepRosterRow?) {
        let data = try await checkpoints.read(id: Self.anomalySweepRosterID(containerNodeId: containerNodeId), stream: Self.anomalySweepStream)
        let row = try data.map { try JSONDecoder().decode(AnomalySweepRosterRow.self, from: $0) }
        return (data, row)
    }

    private func writeRoster(_ checkpoints: QueueCheckpointStore, expected: Data?, row: AnomalySweepRosterRow, now: Date) async throws {
        let stamp = HLC(physicalTime: Int64(now.timeIntervalSince1970 * 1000), logicalCount: 0, nodeID: 0)
        _ = try await checkpoints.compareAndSwap(id: Self.anomalySweepRosterID(containerNodeId: row.container),
            stream: Self.anomalySweepStream, expected: expected, payload: try JSONEncoder().encode(row), stamp: stamp)
    }

    /// Mark one container owed a scoring, keeping its roster so the next
    /// pass is incremental. A container with no row yet gets an empty one
    /// (owed by construction either way; the row records the room so the
    /// owed list can name it).
    func markAnomalySweepContainerDirty(_ container: AnomalyContainer, for handle: EstateHandle, now: Date) async throws {
        let checkpoints = try await factCheckpoints(handle)
        let (data, existing) = try await readRoster(checkpoints, containerNodeId: container.nodeId)
        var row = existing ?? AnomalySweepRosterRow(container: container.nodeId.lowercased(), wing: container.wing,
                                                     room: container.room, dirty: true, roster: CohesionRoster())
        row.dirty = true
        try await writeRoster(checkpoints, expected: data, row: row, now: now)
    }

    /// The containers a drawer parent id denotes, named through the node
    /// tree; nil when the id is not a room or a chest.
    private func anomalyContainer(estate: LocusKit.Estate, parentNodeId: String) async throws -> AnomalyContainer? {
        let names = try await estate.resolveNodeNames(parentNodeIds: [parentNodeId])
        guard let name = names[parentNodeId] else { return nil }
        return AnomalyContainer(nodeId: parentNodeId, wing: name.wing, room: name.room)
    }

    /// Every container of a room, from the tree (chests, plus the room
    /// itself while it holds drawers directly).
    func anomalyContainers(estate: LocusKit.Estate, wing: String, room: String) async throws -> [(AnomalyContainer, count: Int)] {
        try await estate.containers(in: wing, room: room).map {
            (AnomalyContainer(nodeId: $0.chestNodeId, wing: wing, room: room), $0.count)
        }
    }

    /// The containers owed a scoring: fold every audit event since the cursor
    /// into container dirtiness (a write to any drawer dirties its container;
    /// a room's re-bin event dirties every container of that room), then list
    /// the containers that are dirty or have never been scored, skipping any
    /// at or above `ChestPlacement.capacity` (owed a re-bin, not a scoring).
    /// This is the duty's debt count and its work list.
    func anomalySweepOwedContainers(_ handle: EstateHandle, now: Date) async throws -> [AnomalyContainer] {
        let estate = try estate(for: handle)
        let checkpoints = try await factCheckpoints(handle)
        let stream = Self.anomalySweepStream
        let stamp = HLC(physicalTime: Int64(now.timeIntervalSince1970 * 1000), logicalCount: 0, nodeID: 0)

        // 1. Fold new audit events into dirty containers, advancing the cursor.
        var cursorData = try await checkpoints.read(id: Self.anomalySweepCursorID, stream: stream)
        var after = try cursorData.map { try JSONDecoder().decode(AnomalySweepCursor.self, from: $0).hlc }
        var folds = 0
        while folds < 8 {
            let events = try await estate.auditEvents(after: after, limit: Self.anomalySweepAuditFold)
            guard let last = events.last else { break }
            let ids = Array(Set(events.map { $0.rowId.uuidString }))
            let drawers = try await estate.getDrawers(ids: ids)
            var touched: Set<String> = []
            for drawer in drawers where touched.insert(drawer.parentNodeId).inserted {
                guard let container = try await anomalyContainer(estate: estate, parentNodeId: drawer.parentNodeId) else { continue }
                try await markAnomalySweepContainerDirty(container, for: handle, now: now)
            }
            // A re-bin's one event names the room node: every container of
            // that room changed membership.
            let drawerIds = Set(drawers.map { $0.id.lowercased() })
            for event in events where event.verb == LocusKit.Estate.chestRebinVerb
                && !drawerIds.contains(event.rowId.uuidString.lowercased()) {
                let roomId = event.rowId.uuidString
                guard let name = try await estate.resolveNodeNames(parentNodeIds: [roomId])[roomId] else { continue }
                for (container, _) in try await anomalyContainers(estate: estate, wing: name.wing, room: name.room) {
                    try await markAnomalySweepContainerDirty(container, for: handle, now: now)
                }
            }
            let next = try JSONEncoder().encode(AnomalySweepCursor(hlc: last.hlc))
            _ = try await checkpoints.compareAndSwap(id: Self.anomalySweepCursorID, stream: stream,
                expected: cursorData, payload: next, stamp: stamp)
            cursorData = next
            after = last.hlc
            folds += 1
            if events.count < Self.anomalySweepAuditFold { break }
        }

        // 2. Owed = dirty or never scored, and under capacity.
        var known: [String: Bool] = [:]
        for payload in try await checkpoints.payloads(stream: stream) {
            guard let row = try? JSONDecoder().decode(AnomalySweepRosterRow.self, from: payload) else { continue }
            known[row.container] = row.dirty
        }
        var owed: [AnomalyContainer] = []
        for entry in try await estate.roomLevelFingerprints() {
            for (container, count) in try await anomalyContainers(estate: estate, wing: entry.wing, room: entry.room) {
                if count >= ChestPlacement.capacity { continue }
                if known[container.nodeId.lowercased()] ?? true { owed.append(container) }
            }
        }
        return owed
    }

    /// Score up to `limit` owed containers and mark them clean. Returns the
    /// containers scored; the duty queue carries the remainder forward.
    func runAnomalySweepBatch(_ handle: EstateHandle, limit: Int, now: Date) async throws -> Int {
        let estate = try estate(for: handle)
        let checkpoints = try await factCheckpoints(handle)
        var scored = 0
        for container in try await anomalySweepOwedContainers(handle, now: now).prefix(max(0, limit)) {
            _ = try await scoreContainer(estate: estate, checkpoints: checkpoints, container: container,
                                         threshold: Self.anomalySweepDefaultThreshold, whole: false, now: now)
            scored += 1
        }
        if scored > 0 {
            Self.anomalyLog.debug("anomalySweepBatch: \(scored, privacy: .public) container(s) scored")
        }
        return scored
    }

    // MARK: One container

    /// Score one container against its roster and write the flags that
    /// flipped. `whole` rescores from nothing and replaces the roster;
    /// otherwise the pass is a reconcile: members gone from the container
    /// are removed from the sums (their content still present unless
    /// expunged), members new to it are added, and only when a removed
    /// member's old content cannot be recovered is the container rescored
    /// whole. The pairwise work runs in a detached task so the kit actor
    /// keeps answering verbs while it computes; only the writes come back
    /// to the actor. Returns the count of drawers whose bit 26 changed.
    private func scoreContainer(estate: LocusKit.Estate, checkpoints: QueueCheckpointStore,
                                container: AnomalyContainer, threshold: Float32,
                                whole: Bool, now: Date) async throws -> Int {
        var changed = 0
        // Sensitivity cohort gate (codex finding 2026-08-26):
        // restricted/secret drawers are EXCLUDED from the cohesion
        // cohort entirely — they neither receive bit 26 nor influence
        // any other drawer's score. Including them let a caller without
        // a sensitivity grant plant visible probe rows and read
        // anomalous_filter results to observe lexical similarity to
        // hidden content. Excluded rows also get any stale bit 26
        // cleared, matching the small-container path's flag hygiene.
        let allDrawers = try await estate.drawersIn(containerNodeId: container.nodeId)
        var drawers: [Drawer] = []
        for drawer in allDrawers {
            // Adjective sensitivity: the field the read-side containment gate
            // enforces, so the cohort excludes exactly what an ungranted
            // caller cannot read (the provenance sensitivity is a separate
            // field capture does not set from the frame).
            if drawer.adjectiveSensitivity == .restricted || drawer.adjectiveSensitivity == .secret {
                if drawer.isAnomalous {
                    changed += try await estate.setAnomalousFlag(
                        drawerId: drawer.id, anomalous: false, now: now)
                }
            } else {
                drawers.append(drawer)
            }
        }
        // Members are visited in id order so the roster's entry order, and
        // therefore its row bytes, are the same on both ports.
        drawers.sort { $0.id.lowercased() < $1.id.lowercased() }

        let (rosterData, existing) = try await readRoster(checkpoints, containerNodeId: container.nodeId)
        var row = existing ?? AnomalySweepRosterRow(container: container.nodeId.lowercased(), wing: container.wing,
                                                     room: container.room, dirty: true, roster: CohesionRoster())

        // The reconcile plan against the stored roster.
        let live: [(id: String, digest: String, content: String)] = drawers.map {
            ($0.id.lowercased(), Self.anomalyContentDigest($0.content), $0.content)
        }
        let liveDigest = Dictionary(uniqueKeysWithValues: live.map { ($0.id, $0.digest) })
        var removed: [(id: String, digest: String)] = []
        var kept = Set<String>()
        for entry in row.roster.entries {
            if liveDigest[entry.id] == entry.digest { kept.insert(entry.id) } else { removed.append((entry.id, entry.digest)) }
        }
        // Old content for the removed members: a tombstoned drawer still
        // carries its content; an expunged one (zeroed) or one whose
        // digest moved cannot be subtracted exactly, so the container is
        // rescored whole.
        var removedContent: [String: String] = [:]
        var rescoreWhole = whole || existing == nil
        if !rescoreWhole && !removed.isEmpty {
            let olds = try await estate.getDrawers(ids: removed.map(\.id))
            let byId = Dictionary(uniqueKeysWithValues: olds.map { ($0.id.lowercased(), $0) })
            for (id, digest) in removed {
                if let old = byId[id], Self.anomalyContentDigest(old.content) == digest {
                    removedContent[id] = old.content
                } else {
                    rescoreWhole = true
                    break
                }
            }
        }

        let startRoster = rescoreWhole ? CohesionRoster() : row.roster
        let keptIds = rescoreWhole ? Set<String>() : kept
        let plan = (live: live, removed: removed, removedContent: removedContent, start: startRoster, kept: keptIds)
        let minimum = GeniusLocusKit.anomalySweepMinRoomSize
        let (roster, flags): (CohesionRoster, [String: Bool]) = await Task.detached(priority: .utility) {
            var roster = plan.start
            var shingles: [String: Set<String>] = [:]
            for member in plan.live { shingles[member.id] = ShingleSimilarity.shingles(member.content) }
            // Remove: the old content against every entry still in the roster.
            for (id, _) in plan.removed {
                let old = ShingleSimilarity.shingles(plan.removedContent[id] ?? "")
                let sims = roster.entries.filter { $0.id != id }.map {
                    CohesionRoster.quantise(ShingleSimilarity.similarity(old, shingles[$0.id] ?? []))
                }
                roster.remove(id: id, similarities: sims)
            }
            // Add: every live member the roster does not hold, in id order.
            for member in plan.live where !plan.kept.contains(member.id) {
                let mine = shingles[member.id] ?? []
                let sims = roster.entries.map {
                    CohesionRoster.quantise(ShingleSimilarity.similarity(mine, shingles[$0.id] ?? []))
                }
                roster.add(id: member.id, digest: member.digest, similarities: sims)
            }
            let flags = Dictionary(uniqueKeysWithValues:
                roster.flags(threshold: threshold, minimumSize: minimum).map { ($0.id, $0.anomalous) })
            return (roster, flags)
        }.value

        for drawer in drawers {
            let shouldBeAnomalous = flags[drawer.id.lowercased()] ?? false
            guard drawer.isAnomalous != shouldBeAnomalous else { continue }
            changed += try await estate.setAnomalousFlag(
                drawerId: drawer.id, anomalous: shouldBeAnomalous, now: now)
        }
        row.roster = roster
        row.dirty = false
        try await writeRoster(checkpoints, expected: rosterData, row: row, now: now)
        return changed
    }
}
