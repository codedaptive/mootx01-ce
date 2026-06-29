// ContainerFingerprintStore.swift
//
// The per-container OR-reduction aggregates of spec section 11.5: for
// each container (wing, then room) the bitwise OR of every active
// drawer's three bitmap fields. Recall filter ordering (section 7.9.4
// step 1) tests these before any per-row scan, so a container whose OR
// lacks a bit that the chain requires set holds no matching row and is
// pruned.
//
// Soundness rests on two properties of OR. First, the aggregate must
// cover every active row, or a required bit living only in an omitted
// row would be absent and the container falsely pruned; the Estate
// backfills on open and ORs each capture in, so the aggregate always
// covers the active set. Second, a bit left set after the only row
// carrying it was withdrawn makes the aggregate an over-approximation,
// which is harmless: extra set bits only forgo a prune, they never
// prune a container that still holds a match. Bit-clearing mutations
// therefore need no synchronous fix; a periodic rebuild tightens the
// aggregate when it is worth doing.

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

/// The OR of the three bitmap fields over some set of drawers.
public struct ContainerFingerprint: Sendable, Equatable {
    public var adjective: Int64
    public var operational: Int64
    public var provenance: Int64

    public static let zero = ContainerFingerprint(adjective: 0, operational: 0, provenance: 0)

    public init(adjective: Int64, operational: Int64, provenance: Int64) {
        self.adjective = adjective
        self.operational = operational
        self.provenance = provenance
    }

    /// The OR of two container fingerprints, used to roll rooms up to
    /// a wing and to fold a new row in.
    ///
    /// Routes through `SubstrateLib.ORReduce.reduce` (cookbook § 8.5),
    /// the substrate's universal aggregation primitive — proven
    /// commutative, associative, and idempotent, which is what makes
    /// the container-pruning soundness argument (cookbook § 11.5) work
    /// and what gives the CRDT join its convergence guarantee.
    ///
    /// The three Int64 bitmaps pack into blocks 0/1/2 of a
    /// `Fingerprint256` with block 3 reserved zero. The block layout
    /// here is a packing convention for the math primitive, not the
    /// cookbook § 3 SimHash-block semantics: `ORReduce` operates on the
    /// 256 bits without interpreting them.
    ///
    /// Bit-identical to the prior three-Int64 OR for every input.
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
            provenance: Int64(bitPattern: merged.block2))
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

    /// OR one drawer's bitmaps into its room-level and wing-level rows.
    /// Called on every capture.
    public func orIn(wing: String, room: String,
                     adjective: Int64, operational: Int64, provenance: Int64,
                     now: Date = Date()) async throws {
        let delta = ContainerFingerprint(adjective: adjective,
                                         operational: operational,
                                         provenance: provenance)
        try await orInto(wing: wing, room: room, delta, now: now)
        try await orInto(wing: wing, room: Self.wingRollupRoom, delta, now: now)
    }

    private func orInto(wing: String, room: String,
                        _ delta: ContainerFingerprint, now: Date) async throws {
        let merged = (try await get(wing: wing, room: room) ?? .zero).merging(delta)
        try await put(wing: wing, room: room, merged, now: now)
    }

    // MARK: - Rebuild (tightening after bit-clearing mutations)

    /// Recompute a room's OR from its active drawers and replace the
    /// stored row. Use after withdrawals or expunges, or to backfill.
    @discardableResult
    public func rebuildRoom(wing: String, room: String,
                            activeDrawers: [Drawer],
                            now: Date = Date()) async throws -> ContainerFingerprint {
        var acc = ContainerFingerprint.zero
        for d in activeDrawers {
            acc = acc.merging(ContainerFingerprint(adjective: d.adjectiveBitmap,
                                                   operational: d.operationalBitmap,
                                                   provenance: d.provenance))
        }
        try await put(wing: wing, room: room, acc, now: now)
        return acc
    }

    /// Recompute a wing-level row as the OR of its room-level rows.
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

    /// Rebuild every container from the full active drawer set, so the
    /// aggregate covers all active rows. Called on open to make an
    /// existing estate's aggregate complete and therefore sound.
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
                "updatedAt": .timestamp(now)
            ],
            conflictColumns: ["wing", "room"])
    }

    private static func fingerprintFromRow(_ row: StorageRow) -> ContainerFingerprint {
        ContainerFingerprint(adjective: int64(row["adjectiveOR"]),
                             operational: int64(row["operationalOR"]),
                             provenance: int64(row["provenanceOR"]))
    }

    private static func int64(_ v: TypedValue?) -> Int64 {
        switch v {
        case let .bitmap(i)?: return i
        case let .int(i)?: return i
        default: return 0
        }
    }
}
