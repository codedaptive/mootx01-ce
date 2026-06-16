// NodeBundleStore.swift
//
// Persistence for the bundle-algebra count-vector aggregates, one per
// node (wing/room) per bundle kind, in the node_bundles table. The
// per-row drawer fingerprint is never stored; only these aggregates
// are (DECISION_BUNDLE_ALGEBRA_AND_ERASURE_2026-05-20 and the storage
// discussion of 2026-05-20). The store reads and writes the count-
// vector; the BundleMaterializer computes it.

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

public actor NodeBundleStore {

    /// Which bundle a row holds. "A" is the active centroid, the fold
    /// of the node's currently active members. "B" is the departed
    /// accumulator, eager-folded at departure time.
    public enum BundleKind: String, Sendable {
        case activeA = "A"
        case departedB = "B"
    }

    let storage: any Storage

    /// Construct against a Storage and open the LocusKit schema. The
    /// open is idempotent, so sharing one Storage with a DrawerStore is
    /// safe.
    public init(storage: any Storage) async throws {
        self.storage = storage
        try await storage.open(schema: LocusKitSchema.schema)
    }

    // MARK: - Count-vector wire encoding

    /// Encode a count-vector's 256 counts as little-endian UInt32,
    /// exactly 1024 bytes. `n` is stored in its own column, not here.
    static func encodeCounts(_ cv: CountVector256) -> Data {
        var data = Data(capacity: 256 * 4)
        for c in cv.counts {
            var le = c.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Decode 1024 little-endian UInt32 bytes plus the member count
    /// back into a count-vector. Throws `LocusKitError.invalidContent`
    /// when the blob is the wrong size; mirrors the Rust port's
    /// `Result<CountVector256, LocusKitError>` return rather than
    /// trapping on a malformed/empty cell (e.g. when `blobValue`
    /// returns `Data()` on a missing-or-mistyped row), so a corrupt
    /// row surfaces as a recoverable error instead of taking down the
    /// process.
    static func decodeCounts(_ data: Data, n: UInt32) throws -> CountVector256 {
        guard data.count == 256 * 4 else {
            throw LocusKitError.invalidContent(
                "node_bundles counts blob must be exactly 1024 bytes, got \(data.count)")
        }
        var counts = [UInt32](repeating: 0, count: 256)
        data.withUnsafeBytes { raw in
            for i in 0..<256 {
                counts[i] = UInt32(littleEndian:
                    raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self))
            }
        }
        return CountVector256(counts: counts, n: n)
    }

    // MARK: - Read and write

    /// Write (insert or replace) a node's bundle. Last write wins,
    /// which is correct for Bundle A recompute and Bundle B updates.
    public func put(wing: String, room: String, kind: BundleKind,
                    _ cv: CountVector256, now: Date = Date()) async throws {
        try await storage.rowStore.upsert(
            table: "node_bundles",
            values: [
                "wing": .text(wing),
                "room": .text(room),
                "bundleKind": .text(kind.rawValue),
                "n": .int(Int64(cv.n)),
                "counts": .blob(Self.encodeCounts(cv)),
                "updatedAt": .timestamp(now)
            ],
            conflictColumns: ["wing", "room", "bundleKind"])
    }

    /// Read a node's bundle, or nil if it has not been materialized.
    public func get(wing: String, room: String,
                    kind: BundleKind) async throws -> CountVector256? {
        let rows = try await storage.rowStore.query(
            table: "node_bundles",
            where: .and([
                .eq(Column(table: "node_bundles", name: "wing"), .text(wing)),
                .eq(Column(table: "node_bundles", name: "room"), .text(room)),
                .eq(Column(table: "node_bundles", name: "bundleKind"), .text(kind.rawValue))
            ]),
            orderBy: [], limit: 1, offset: nil)
        guard let row = rows.first else { return nil }
        return try Self.bundleFromRow(row)
    }

    /// All room-level bundles of one kind under a wing, excluding the
    /// wing-level roll-up row (room == ""). Used by the wing roll-up.
    public func rooms(forWing wing: String,
                      kind: BundleKind) async throws -> [(room: String, bundle: CountVector256)] {
        let rows = try await storage.rowStore.query(
            table: "node_bundles",
            where: .and([
                .eq(Column(table: "node_bundles", name: "wing"), .text(wing)),
                .eq(Column(table: "node_bundles", name: "bundleKind"), .text(kind.rawValue)),
                .not(.eq(Column(table: "node_bundles", name: "room"), .text("")))
            ]),
            orderBy: [OrderClause(column: Column(table: "node_bundles", name: "room"),
                                  direction: .ascending)],
            limit: nil, offset: nil)
        return try rows.map { row in
            (room: Self.stringValue(row["room"]),
             bundle: try Self.bundleFromRow(row))
        }
    }

    // MARK: - Row decoding

    private static func bundleFromRow(_ row: StorageRow) throws -> CountVector256 {
        let n = UInt32(truncatingIfNeeded: intValue(row["n"]))
        let counts = blobValue(row["counts"])
        return try decodeCounts(counts, n: n)
    }

    private static func stringValue(_ v: TypedValue?) -> String {
        if case let .text(s)? = v { return s }
        return ""
    }

    private static func intValue(_ v: TypedValue?) -> Int64 {
        if case let .int(i)? = v { return i }
        return 0
    }

    private static func blobValue(_ v: TypedValue?) -> Data {
        if case let .blob(d)? = v { return d }
        return Data()
    }
}
