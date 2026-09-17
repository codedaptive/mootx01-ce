// AnomalyFlagSweep.swift
//
// Room-cohesion anomaly-flag sweep for GeniusLocusKit (§11.18,
// anomalous-flag recall prefilter).
//
// Scores each drawer's mean shingle-similarity to its room peers,
// derives z-scores from the room's cohesion distribution, and
// sets/clears bit 26 (`isAnomalous`) of `operationalBitmap`.
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
// SubstrateML is the direct dependency for AnomalyDetection and
// ShingleSimilarity — both are already available to GeniusLocusKit
// and are conformance-gated byte-identical Swift+Rust implementations.
//
// Sweep properties:
//   • Room minimum size: 3 drawers (z-score not meaningful for < 3 peers)
//   • Cohesion metric: mean char-4-shingle Jaccard to all room peers
//   • Gate: z-score ≤ −threshold (low-cohesion outlier) → isAnomalous = true
//   • Default threshold: 2.0 (≈ 2σ below-mean cutoff)
//   • Derived signal: no audit event, no lifecycle/lineage field touched
//   • Complexity: O(n²) per room, so the resident never scores the whole
//     estate at once: the sweep is a row-debt DUTY (§ DUTY_LIFECYCLE) whose
//     debt is the set of rooms touched since they were last scored, found by
//     folding the estate's audit events; a batch scores a bounded number of
//     owed rooms with the cohesion math off the kit actor. `anomalyFlagSweep`
//     remains the whole-estate form (tests, operator tooling).

import Foundation
import QueueKit
import SubstrateTypes
import MootProductIdentity
import LocusKit
import OSLog
import SubstrateML

// MARK: - Anomaly sweep constants

public extension GeniusLocusKit {

    /// Minimum drawers per room to run the z-score computation (§11.18).
    ///
    /// Below this threshold, the standard deviation is either zero or
    /// statistically unstable. All drawers in under-threshold rooms
    /// have bit 26 cleared — not anomalous by definition.
    static let anomalySweepMinRoomSize: Int = 3

    /// Default z-score threshold for the negative-cohesion anomaly gate (§11.18).
    ///
    /// A drawer is flagged anomalous when its cohesion z-score ≤ −threshold.
    /// Default 2.0 balances sensitivity (catches ~2σ below-mean drawers)
    /// against false-positive rate (~2.3% under a normal distribution).
    static let anomalySweepDefaultThreshold: Float32 = 2.0
}

// MARK: - Anomaly flag sweep

extension GeniusLocusKit {

    /// Logger for the anomaly-flag sweep, fleet-standard subsystem + category.
    private static var anomalyLog: Logger {
        Logger(subsystem: MootProductIdentity.Logging.subsystem, category: "GeniusLocusKit")
    }

    // MARK: Whole-estate form

    /// Score every room and set/clear bit 26 (`isAnomalous`) on every drawer.
    ///
    /// This is a DERIVED SIGNAL write: no audit event, no supersession cascade,
    /// no lifecycle or lineage field touched. The bit is owned entirely by this
    /// sweep and should not be set through any other path.
    ///
    /// The resident does not call this: on a large estate it is minutes of
    /// pure compute. The resident pays `runAnomalySweepBatch` through the duty
    /// queue, which scores only rooms touched since their last scoring.
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
        var changed = 0
        for entry in try await estate.roomLevelFingerprints() {
            changed += try await scoreRoom(estate: estate, wing: entry.wing, room: entry.room,
                                           threshold: threshold, now: now)
        }
        Self.anomalyLog.debug(
            "anomalyFlagSweep: \(changed, privacy: .public) drawer(s) updated")
        return changed
    }

    // MARK: Incremental duty form (§ DUTY_LIFECYCLE)

    /// Checkpoint stream for the incremental sweep: one `cursor` row (the last
    /// audit HLC folded into room dirtiness) and one row per room (dirty or
    /// not). Lives in the estate's queue database beside the other duty state;
    /// no schema, no migration. A room with no row has never been scored and
    /// is owed.
    static var anomalySweepStream: StreamID { StreamID(rawValue: "anomaly-sweep-checkpoints") }
    static var anomalySweepCursorID: JobID { JobID(rawValue: "cursor") }
    static func anomalySweepRoomID(wing: String, room: String) -> JobID {
        JobID(rawValue: String(factSourceDigest("anomaly-room-v1|" + wing + "/" + room).prefix(32)))
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
    struct AnomalySweepRoomState: Codable, Sendable {
        var wing: String
        var room: String
        var dirty: Bool
    }

    /// The rooms owed a scoring: fold every audit event since the cursor into
    /// room dirtiness (a write to any drawer dirties its room), then list the
    /// rooms that are dirty or have never been scored. This is the duty's
    /// debt count and its work list.
    func anomalySweepOwedRooms(_ handle: EstateHandle, now: Date) async throws -> [(wing: String, room: String)] {
        let estate = try estate(for: handle)
        let checkpoints = try await factCheckpoints(handle)
        let stream = Self.anomalySweepStream
        let stamp = HLC(physicalTime: Int64(now.timeIntervalSince1970 * 1000), logicalCount: 0, nodeID: 0)

        // 1. Fold new audit events into dirty rooms, advancing the cursor.
        var cursorData = try await checkpoints.read(id: Self.anomalySweepCursorID, stream: stream)
        var after = try cursorData.map { try JSONDecoder().decode(AnomalySweepCursor.self, from: $0).hlc }
        var folds = 0
        while folds < 8 {
            let events = try await estate.auditEvents(after: after, limit: Self.anomalySweepAuditFold)
            guard let last = events.last else { break }
            let ids = Array(Set(events.map { $0.rowId.uuidString }))
            let drawers = try await estate.getDrawers(ids: ids)
            let names = try await resolveNodeNames(handle, parentNodeIds: Array(Set(drawers.map { $0.parentNodeId })))
            var touched: Set<String> = []
            for drawer in drawers {
                guard let name = names[drawer.parentNodeId] else { continue }
                let key = name.wing + "/" + name.room
                guard touched.insert(key).inserted else { continue }
                let id = Self.anomalySweepRoomID(wing: name.wing, room: name.room)
                let previous = try await checkpoints.read(id: id, stream: stream)
                let state = AnomalySweepRoomState(wing: name.wing, room: name.room, dirty: true)
                _ = try await checkpoints.compareAndSwap(id: id, stream: stream, expected: previous,
                    payload: try JSONEncoder().encode(state), stamp: stamp)
            }
            let next = try JSONEncoder().encode(AnomalySweepCursor(hlc: last.hlc))
            _ = try await checkpoints.compareAndSwap(id: Self.anomalySweepCursorID, stream: stream,
                expected: cursorData, payload: next, stamp: stamp)
            cursorData = next
            after = last.hlc
            folds += 1
            if events.count < Self.anomalySweepAuditFold { break }
        }

        // 2. Owed = dirty or never scored.
        var known: [String: Bool] = [:]
        for payload in try await checkpoints.payloads(stream: stream) {
            guard let state = try? JSONDecoder().decode(AnomalySweepRoomState.self, from: payload) else { continue }
            known[state.wing + "/" + state.room] = state.dirty
        }
        var owed: [(wing: String, room: String)] = []
        for entry in try await estate.roomLevelFingerprints() {
            if known[entry.wing + "/" + entry.room] ?? true { owed.append((entry.wing, entry.room)) }
        }
        return owed
    }

    /// Mark one room dirty in the anomaly-sweep checkpoint stream directly,
    /// bypassing the audit-event fold `anomalySweepOwedRooms` otherwise relies
    /// on (§11.18 F4).
    ///
    /// The fold cannot recover a drawer's PRIOR room from the audit trail: a
    /// reanchor's `AuditEvent.beforeLatticeAnchor`/`afterLatticeAnchor` record
    /// the UDC classification lattice code, not room membership — a pure
    /// room move with no `toLattice` leaves both anchors byte-identical (see
    /// `DrawerStore.reanchorGated`) — and the `drawers` row itself carries
    /// only the CURRENT `parent_node_id`, never a history of prior values.
    /// So once a reanchor has happened, "what room did this drawer just
    /// leave" is answerable only at the moment of the move, by the caller
    /// that already holds both the before and after room names. The GLK
    /// `reanchor` verb is that caller: it calls this once for the room the
    /// drawer left and once for the room it landed in, so a moved drawer's
    /// former room-mates are rescored (their cohesion peer set changed) in
    /// the same duty cycle as the room it joined.
    func markAnomalySweepRoomDirty(
        wing: String, room: String, for handle: EstateHandle, now: Date
    ) async throws {
        let checkpoints = try await factCheckpoints(handle)
        let stream = Self.anomalySweepStream
        let stamp = HLC(physicalTime: Int64(now.timeIntervalSince1970 * 1000), logicalCount: 0, nodeID: 0)
        let id = Self.anomalySweepRoomID(wing: wing, room: room)
        let previous = try await checkpoints.read(id: id, stream: stream)
        let state = AnomalySweepRoomState(wing: wing, room: room, dirty: true)
        _ = try await checkpoints.compareAndSwap(id: id, stream: stream, expected: previous,
            payload: try JSONEncoder().encode(state), stamp: stamp)
    }

    /// Score up to `limit` owed rooms and mark them clean. Returns the rooms
    /// scored; the duty queue carries the remainder forward.
    func runAnomalySweepBatch(_ handle: EstateHandle, limit: Int, now: Date) async throws -> Int {
        let estate = try estate(for: handle)
        let checkpoints = try await factCheckpoints(handle)
        let stream = Self.anomalySweepStream
        let stamp = HLC(physicalTime: Int64(now.timeIntervalSince1970 * 1000), logicalCount: 0, nodeID: 0)
        var scored = 0
        for (wing, room) in try await anomalySweepOwedRooms(handle, now: now).prefix(max(0, limit)) {
            _ = try await scoreRoom(estate: estate, wing: wing, room: room,
                                    threshold: Self.anomalySweepDefaultThreshold, now: now)
            let id = Self.anomalySweepRoomID(wing: wing, room: room)
            let previous = try await checkpoints.read(id: id, stream: stream)
            let clean = AnomalySweepRoomState(wing: wing, room: room, dirty: false)
            _ = try await checkpoints.compareAndSwap(id: id, stream: stream, expected: previous,
                payload: try JSONEncoder().encode(clean), stamp: stamp)
            scored += 1
        }
        if scored > 0 {
            Self.anomalyLog.debug("anomalySweepBatch: \(scored, privacy: .public) room(s) scored")
        }
        return scored
    }

    // MARK: One room

    /// Score one room: the O(n²) cohesion pass runs in a detached task so the
    /// kit actor keeps answering verbs while it computes; only the flag writes
    /// come back to the actor.
    private func scoreRoom(estate: LocusKit.Estate, wing: String, room: String,
                           threshold: Float32, now: Date) async throws -> Int {
        var changed = 0
        // Sensitivity cohort gate (codex finding 2026-08-26):
        // restricted/secret drawers are EXCLUDED from the cohesion
        // cohort entirely — they neither receive bit 26 nor influence
        // any other drawer's score. Including them let a caller without
        // a sensitivity grant plant visible probe rows and read
        // anomalous_filter results to observe lexical similarity to
        // hidden content. Excluded rows also get any stale bit 26
        // cleared, matching the small-room path's flag hygiene.
        let allDrawers = try await estate.drawersIn(wing: wing, room: room)
        var drawers: [Drawer] = []
        for drawer in allDrawers {
            if drawer.sensitivity == .restricted || drawer.sensitivity == .secret {
                if drawer.isAnomalous {
                    changed += try await estate.setAnomalousFlag(
                        drawerId: drawer.id, anomalous: false, now: now)
                }
            } else {
                drawers.append(drawer)
            }
        }
        guard !drawers.isEmpty else { return changed }

        if drawers.count < GeniusLocusKit.anomalySweepMinRoomSize {
            for drawer in drawers where drawer.isAnomalous {
                changed += try await estate.setAnomalousFlag(
                    drawerId: drawer.id, anomalous: false, now: now)
            }
            return changed
        }

        let contents = drawers.map(\.content)
        let flags: [Bool] = await Task.detached(priority: .utility) {
            let count = contents.count
            var cohesion: [Float32] = Array(repeating: 0, count: count)
            for i in 0..<count {
                var sum: Float32 = 0
                for j in 0..<count where i != j {
                    sum += ShingleSimilarity.similarity(contents[i], contents[j])
                }
                cohesion[i] = sum / Float32(count - 1)
            }
            let n = Float32(count)
            let mean = cohesion.reduce(0, +) / n
            let variance = cohesion.reduce(Float32(0)) { acc, x in
                let d = x - mean
                return acc + d * d
            } / n
            let stddev = variance.squareRoot()
            return cohesion.map { AnomalyDetection.zScore(value: $0, mean: mean, stddev: stddev) <= -threshold }
        }.value

        for (idx, drawer) in drawers.enumerated() {
            let shouldBeAnomalous = flags[idx]
            guard drawer.isAnomalous != shouldBeAnomalous else { continue }
            changed += try await estate.setAnomalousFlag(
                drawerId: drawer.id, anomalous: shouldBeAnomalous, now: now)
        }
        return changed
    }
}
