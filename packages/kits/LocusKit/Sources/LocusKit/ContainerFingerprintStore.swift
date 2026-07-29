// ContainerFingerprintStore.swift
//
// Per-container bitmap aggregates for two independent pruning mechanisms
// (spec § 11.5).
//
// OR aggregate (adjectiveOR, operationalOR, provenanceOR): the bitwise OR
// of every active drawer's three bitmap fields. Recall filter ordering
// (§ 7.9.4 step 1) tests these before any per-row scan: a container
// whose OR lacks a required bit holds no matching row and is pruned.
// Soundness: a bit left set after the only row carrying it was withdrawn
// is a harmless over-approximation — extra set bits forgo a prune but
// never prune a container that holds a match. The estate ORs each
// capture in; bit-clearing mutations need no synchronous fix; rebuildAll
// at open tightens the over-approximation.
//
// AND aggregate (operationalAND): the bitwise AND of every active
// drawer's operationalBitmap. This is an under-approximation (lower
// bound): a false-absent bit is safe (room scanned unnecessarily), but
// a false-present bit is UNSAFE (room skipped with eligible work). The
// AND is initialized to -1 (AND-identity) so an empty container does
// not falsely satisfy any AND-check. The distillation sweep checks
// `(operationalAND & (1<<19)) != 0` to skip rooms whose every drawer
// carries bit 19 (hasCurrentRepresentation). rebuildAll at estate open
// recomputes the AND from scratch to raise stale under-approximations.
// Capture ORs lower the AND (always safe). Distillation set-events
// cannot raise the AND by the invariant — only rebuildAll can raise it.
// Bit-clear events on live drawers call andInOperational immediately.

import Foundation
import PersistenceKit
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
import SubstrateLib
import SubstrateTypes

/// Bitmap aggregates for one container (wing or room).
///
/// Three OR fields are an over-approximation (upper bound) of the active
/// drawer set; one AND field is an under-approximation (lower bound) of
/// the active drawers' operationalBitmap. See file header for the
/// soundness argument for each direction.
public struct ContainerFingerprint: Sendable, Equatable {
    /// Bitwise OR of every active drawer's adjectiveBitmap in this container.
    public var adjective: Int64
    /// Bitwise OR of every active drawer's operationalBitmap in this container.
    public var operational: Int64
    /// Bitwise OR of every active drawer's provenance in this container.
    public var provenance: Int64
    /// Bitwise AND of every active drawer's operationalBitmap in this container.
    /// Under-approximation: default -1 (AND-identity, all bits set) so an
    /// absent/empty container does not falsely satisfy any AND-check.
    /// Only `rebuildAll` can raise a bit; captures and clears can only lower.
    public var operationalAnd: Int64

    /// OR-identity (zero element): all OR fields zero, AND field at the
    /// AND-identity (-1, all bits set). Starting value for fold operations.
    public static let zero = ContainerFingerprint(adjective: 0, operational: 0, provenance: 0)

    /// Full initializer. `operationalAnd` defaults to -1 (AND-identity) so
    /// callers that only deal with OR fields (tests, legacy code) do not
    /// need to supply it.
    public init(adjective: Int64, operational: Int64, provenance: Int64,
                operationalAnd: Int64 = -1) {
        self.adjective = adjective
        self.operational = operational
        self.provenance = provenance
        self.operationalAnd = operationalAnd
    }

    /// Merge two container fingerprints: OR the three OR fields (via
    /// `SubstrateLib.ORReduce.reduce`, cookbook § 8.5), AND the
    /// operationalAnd fields.
    ///
    /// The ORReduce call is identical to the prior three-field version —
    /// block 3 carries the AND value and is excluded from ORReduce by
    /// operating on a separate i64. The OR is commutative, associative,
    /// and idempotent (CRDT join); the AND is likewise, so fold order is
    /// irrelevant to the result.
    ///
    /// Callers constructing a delta for `orInto` must set `operationalAnd`
    /// to the drawer's actual operationalBitmap (not -1) to make the AND
    /// fold meaningful. See `orIn` for the canonical call site.
    public func merging(_ other: ContainerFingerprint) -> ContainerFingerprint {
        let lhs = Fingerprint256(
            block0: UInt64(bitPattern: adjective),
            block1: UInt64(bitPattern: operational),
            block2: UInt64(bitPattern: provenance),
            block3: 0)
        let rhs = Fingerprint256(
            block0: UInt64(bitPattern: other.adjective),
            block1: UInt64(bitPattern: other.operational),
            block2: UInt64(bitPattern: other.provenance),
            block3: 0)
        let merged = ORReduce.reduce([lhs, rhs])
        return ContainerFingerprint(
            adjective: Int64(bitPattern: merged.block0),
            operational: Int64(bitPattern: merged.block1),
            provenance: Int64(bitPattern: merged.block2),
            operationalAnd: operationalAnd & other.operationalAnd)
    }
}

public actor ContainerFingerprintStore {

    /// The room-key for a wing-level roll-up row, matching the
    /// node_bundles convention.
    public static let wingRollupRoom = ""

    let storage: any Storage

    public init(storage: any Storage) async throws {
        self.storage = storage
        try await storage.open(schema: LocusKitSchema.schema)
    }

    // MARK: - Read

    /// The OR fingerprint for a container, or nil if it has none yet.
    /// A nil result means the caller must scan: an absent aggregate is
    /// not an empty one, and pruning against it would be unsound.
    public func get(wing: String, room: String) async throws -> ContainerFingerprint? {
        let rows = try await storage.rowStore.query(
            table: "container_fingerprints",
            where: .and([
                .eq(Column(table: "container_fingerprints", name: "wing"), .text(wing)),
                .eq(Column(table: "container_fingerprints", name: "room"), .text(room))
            ]),
            orderBy: [], limit: 1, offset: nil)
        guard let row = rows.first else { return nil }
        return Self.fingerprintFromRow(row)
    }

    /// Every room-level container (room non-empty) with its OR
    /// fingerprint. Recall enumerates these to decide which containers
    /// to scan. The maintenance contract, backfill on open plus an
    /// OR-in per capture, keeps this set covering every active
    /// container, so enumerating it never misses a container that holds
    /// a match.
    public func roomLevelEntries() async throws
        -> [(wing: String, room: String, fingerprint: ContainerFingerprint)] {
        let rows = try await storage.rowStore.query(
            table: "container_fingerprints",
            where: .not(.eq(Column(table: "container_fingerprints", name: "room"),
                            .text(Self.wingRollupRoom))),
            orderBy: [OrderClause(column: Column(table: "container_fingerprints", name: "wing"),
                                  direction: .ascending)],
            limit: nil, offset: nil)
        return rows.map { (wing: Self.stringValueOf($0["wing"]),
                           room: Self.stringValueOf($0["room"]),
                           fingerprint: Self.fingerprintFromRow($0)) }
    }

    private static func stringValueOf(_ v: TypedValue?) -> String {
        if case let .text(s)? = v { return s }
        return ""
    }

    // MARK: - Incremental maintenance

    /// OR one drawer's bitmaps into its room-level and wing-level rows,
    /// and AND the operational bitmap into the operationalAND column.
    ///
    /// Called on every capture (new drawer, bit 19 clear) and on
    /// `setDistilledRepresentation` (bit 19 set). The AND semantics handle
    /// both correctly:
    /// - Capture (bit 19 = 0): ANDs 0 into operationalAND → lowers bit 19
    ///   in the AND (safe; room will not be skipped by the sweep).
    /// - Distillation (bit 19 = 1): ANDs 1 into operationalAND → no change
    ///   to bit 19 in the AND (deferred to rebuildAll; correct by invariant).
    ///
    /// Clear paths on tombstoned drawers need no fingerprint update (sweep
    /// excludes tombstoned rows). Clear paths on live drawers (in-place
    /// edits) must call `andInOperational` directly; see that method.
    public func orIn(wing: String, room: String,
                     adjective: Int64, operational: Int64, provenance: Int64,
                     now: Date = Date()) async throws {
        // operationalAnd: pass the actual operational bitmap so the AND fold
        // is meaningful. For a capture (bit 19 clear) this lowers the AND;
        // for a distillation (bit 19 set) the AND is unchanged (deferred).
        let delta = ContainerFingerprint(adjective: adjective,
                                         operational: operational,
                                         provenance: provenance,
                                         operationalAnd: operational)
        try await orInto(wing: wing, room: room, delta, now: now)
        try await orInto(wing: wing, room: Self.wingRollupRoom, delta, now: now)
    }

    private func orInto(wing: String, room: String,
                        _ delta: ContainerFingerprint, now: Date) async throws {
        let merged = (try await get(wing: wing, room: room) ?? .zero).merging(delta)
        try await put(wing: wing, room: room, merged, now: now)
    }

    /// AND an operational bitmap into the `operationalAND` column for the
    /// room and wing rows, leaving the three OR columns unchanged.
    ///
    /// Use this after a bit-CLEAR event on a LIVE (non-tombstoned) drawer
    /// to prevent the distillation sweep from falsely skipping the container.
    /// Lowering the AND is always safe (under-approximation → safe direction).
    ///
    /// Tombstone/expunge paths do NOT need to call this — the sweep only
    /// visits active drawers, so a tombstoned drawer's cleared bit 19 never
    /// causes the sweep to miss work.
    public func andInOperational(wing: String, room: String,
                                 operational: Int64,
                                 now: Date = Date()) async throws {
        try await andIntoOperational(wing: wing, room: room, operational: operational, now: now)
        try await andIntoOperational(wing: wing, room: Self.wingRollupRoom,
                                     operational: operational, now: now)
    }

    private func andIntoOperational(wing: String, room: String,
                                    operational: Int64, now: Date) async throws {
        guard var fp = try await get(wing: wing, room: room) else { return }
        fp.operationalAnd &= operational
        try await put(wing: wing, room: room, fp, now: now)
    }

    // MARK: - Rebuild (tightening after bit-clearing mutations)

    /// Recompute a room's OR and AND from its active drawers and replace
    /// the stored row. Use after withdrawals or expunges, or to backfill.
    ///
    /// For each drawer, the operationalBitmap is used both in the OR fold
    /// (via `merging`) and in the AND fold (via `operationalAnd:` param).
    /// The AND starts at -1 (identity) and is narrowed to the true AND
    /// of all drawers — this is the only path that can raise an AND bit.
    @discardableResult
    public func rebuildRoom(wing: String, room: String,
                            activeDrawers: [Drawer],
                            now: Date = Date()) async throws -> ContainerFingerprint {
        var acc = ContainerFingerprint.zero
        for d in activeDrawers {
            acc = acc.merging(ContainerFingerprint(adjective: d.adjectiveBitmap,
                                                   operational: d.operationalBitmap,
                                                   provenance: d.provenance,
                                                   operationalAnd: d.operationalBitmap))
        }
        try await put(wing: wing, room: room, acc, now: now)
        return acc
    }

    /// Recompute a wing-level row as the OR/AND of its room-level rows.
    /// The room rows already carry the correct `operationalAND`; this
    /// folds them into the wing rollup via `merging` (which ANDs them).
    @discardableResult
    public func rollUpWing(wing: String, now: Date = Date()) async throws -> ContainerFingerprint {
        let rows = try await storage.rowStore.query(
            table: "container_fingerprints",
            where: .and([
                .eq(Column(table: "container_fingerprints", name: "wing"), .text(wing)),
                .not(.eq(Column(table: "container_fingerprints", name: "room"),
                         .text(Self.wingRollupRoom)))
            ]),
            orderBy: [], limit: nil, offset: nil)
        var acc = ContainerFingerprint.zero
        for row in rows { acc = acc.merging(Self.fingerprintFromRow(row)) }
        try await put(wing: wing, room: Self.wingRollupRoom, acc, now: now)
        return acc
    }

    /// Rebuild every container from the full active drawer set, so both
    /// the OR and AND aggregates cover all active rows. Called on open
    /// to make an existing estate's aggregates complete and accurate.
    /// This is the ONLY path that can raise an AND bit (correct a stale
    /// under-approximation from a session that added new distilled rows).
    public func rebuildAll(
        activeDrawers: [Drawer],
        nodeNames: [String: (wing: String, room: String)],
        now: Date = Date()
    ) async throws {
        var byContainer: [String: [String: [Drawer]]] = [:]
        for d in activeDrawers {
            let names = nodeNames[d.parentNodeId] ?? (wing: "", room: "")
            byContainer[names.wing, default: [:]][names.room, default: []].append(d)
        }
        for (wing, rooms) in byContainer {
            for (room, drawers) in rooms {
                try await rebuildRoom(wing: wing, room: room, activeDrawers: drawers, now: now)
            }
            try await rollUpWing(wing: wing, now: now)
        }
    }

    // MARK: - Write and decode

    private func put(wing: String, room: String,
                     _ fp: ContainerFingerprint, now: Date) async throws {
        try await storage.rowStore.upsert(
            table: "container_fingerprints",
            values: [
                "wing": .text(wing),
                "room": .text(room),
                "adjectiveOR": .bitmap(fp.adjective),
                "operationalOR": .bitmap(fp.operational),
                "provenanceOR": .bitmap(fp.provenance),
                "operationalAND": .bitmap(fp.operationalAnd),
                "updatedAt": .timestamp(now)
            ],
            conflictColumns: ["wing", "room"])
    }

    private static func fingerprintFromRow(_ row: StorageRow) -> ContainerFingerprint {
        ContainerFingerprint(adjective: int64(row["adjectiveOR"]),
                             operational: int64(row["operationalOR"]),
                             provenance: int64(row["provenanceOR"]),
                             operationalAnd: int64OrMinusOne(row["operationalAND"]))
    }

    private static func int64(_ v: TypedValue?) -> Int64 {
        switch v {
        case let .bitmap(i)?: return i
        case let .int(i)?: return i
        default: return 0
        }
    }

    /// Read an Int64 bitmap value, defaulting to -1 (AND-identity) when
    /// the column is absent (e.g. a v10 row before the v11 migration runs).
    private static func int64OrMinusOne(_ v: TypedValue?) -> Int64 {
        switch v {
        case let .bitmap(i)?: return i
        case let .int(i)?: return i
        default: return -1
        }
    }
}
