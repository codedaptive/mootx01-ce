// EncoderModelStore.swift
//
// The span-encoder registry (ENCODER_RERANK_CONTRACT §2, LocusKit schema
// v19): one `encoder_models` row per shipped model per device, exactly one
// row `is_active = 1` at a time. The active row is what the recall stage
// and the span-encode duty read; this actor is the only writer.
//
// Activation is the one operation with estate-wide reach: switching the
// active model clears bit 27 (`spanIndexed`) on every drawer so the duty
// re-encodes the whole estate under the new model. The rows of the old
// model stay in `vectors` until `mootx01 upgrade`'s reclaim removes them;
// they are never read because the recall stage queries by the ACTIVE
// model id.
//
// Bit 27 is cleared row by row inside one serializable transaction:
// PersistenceKit's RowStore has no bitwise UPDATE expression (an UPDATE
// takes literal values), and the runtime path never issues backend SQL
// (LocusKit design note: no SchemaOperation.custom outside migrations).
// Only rows that carry the bit are touched, so a fresh estate pays one
// projected SELECT.
//
// Rust twin: rust/src/encoder_model_store.rs.

import Foundation
import PersistenceKit

/// Pooling strategy an encoder applies over its token states.
public enum Pooling: String, Sendable, Equatable, Codable {
    /// Mean over the token states (all-MiniLM-L6-v2, bge-small).
    case mean
    /// The [CLS] token state.
    case cls
}

/// One `encoder_models` row (ENCODER_RERANK_CONTRACT §2, §7).
///
/// The registry row IS the encoder contract: everything the factory needs
/// to load the model and everything the spanner needs to cut spans lives
/// here, so the recall stage, the duty and the upgrade read one row and
/// agree. `modelID` is `<model>-w<window_words>`; the span window is part
/// of the identity because a different window is a different index.
public struct EncoderModelRow: Sendable, Equatable, Codable {
    /// `<model>-w<window_words>`, e.g. `minilm-l6-v2-w60`. Primary key.
    public let modelID: String
    /// The weights revision (HF revision short hash or the Apple asset
    /// version string). A weights change is a new version and a re-index.
    public let modelVersion: String
    /// Embedding dimension (384 for all-MiniLM-L6-v2).
    public let dim: Int
    /// Prefix applied to queries before encoding; "" when the card has none.
    public let queryPrefix: String
    /// Prefix applied to documents (spans) before encoding; "" when none.
    public let docPrefix: String
    /// Pooling over token states.
    public let pooling: Pooling
    /// sha256 hex of the vendored vocab file; the factory refuses a model
    /// whose vocab does not hash to this.
    public let tokenizerHash: String
    /// Span window in words.
    public let windowWords: Int
    /// Overlap divisor: 2 = half overlap (step = window / 2).
    public let overlapDivisor: Int
    /// Cap on spans per drawer (32); the spanner widens the step to fit.
    public let maxSpans: Int
    /// The model's maximum sequence length in tokens.
    public let maxSequence: Int
    /// Whether this row is the configured model on this device. Decoded
    /// from the INTEGER `is_active` column (no Bool stored properties on
    /// the row; this is the value type the row decodes into).
    public let isActive: Bool

    public init(modelID: String, modelVersion: String, dim: Int,
                queryPrefix: String, docPrefix: String, pooling: Pooling,
                tokenizerHash: String, windowWords: Int, overlapDivisor: Int,
                maxSpans: Int, maxSequence: Int, isActive: Bool = false) {
        self.modelID = modelID
        self.modelVersion = modelVersion
        self.dim = dim
        self.queryPrefix = queryPrefix
        self.docPrefix = docPrefix
        self.pooling = pooling
        self.tokenizerHash = tokenizerHash
        self.windowWords = windowWords
        self.overlapDivisor = overlapDivisor
        self.maxSpans = maxSpans
        self.maxSequence = maxSequence
        self.isActive = isActive
    }
}

/// Read/write surface over `encoder_models` (both ports).
public actor EncoderModelStore {

    let storage: any Storage

    /// Wrap an already-opened Storage (the LocusKit schema is opened by
    /// `DrawerStore`; this actor issues RowStore operations only).
    public init(storage: any Storage) {
        self.storage = storage
    }

    /// The active registry row, or nil when no model is registered or
    /// none is active (lexical-only recall).
    public func active() async throws -> EncoderModelRow? {
        let rows = try await storage.rowStore.query(
            table: "encoder_models",
            where: .eq(Column(table: "encoder_models", name: "is_active"), .int(1)),
            orderBy: [OrderClause(column: Column(table: "encoder_models", name: "model_id"), direction: .ascending)],
            limit: 1,
            offset: nil
        )
        guard let row = rows.first else { return nil }
        return try Self.spec(from: row)
    }

    /// Every registry row, ordered by model id.
    public func all() async throws -> [EncoderModelRow] {
        let rows = try await storage.rowStore.query(
            table: "encoder_models",
            where: .isTrue,
            orderBy: [OrderClause(column: Column(table: "encoder_models", name: "model_id"), direction: .ascending)],
            limit: nil,
            offset: nil
        )
        return try rows.map { try Self.spec(from: $0) }
    }

    /// Insert or replace one registry row keyed by `modelID`. `isActive` on
    /// the spec is written as given; use `activate(modelID:)` to switch the
    /// configured model, which is the path that also invalidates the span
    /// index. Validation: non-empty ids, positive dimensions and windows,
    /// `overlapDivisor >= 1`, `maxSpans >= 1`.
    public func upsert(_ spec: EncoderModelRow) async throws {
        try Self.validate(spec)
        _ = try await storage.rowStore.upsert(
            table: "encoder_models",
            values: [
                "model_id": .text(spec.modelID),
                "model_version": .text(spec.modelVersion),
                "dim": .int(Int64(spec.dim)),
                "query_prefix": .text(spec.queryPrefix),
                "doc_prefix": .text(spec.docPrefix),
                "pooling": .text(spec.pooling.rawValue),
                "tokenizer_hash": .text(spec.tokenizerHash),
                "window_words": .int(Int64(spec.windowWords)),
                "overlap_divisor": .int(Int64(spec.overlapDivisor)),
                "max_spans": .int(Int64(spec.maxSpans)),
                "max_sequence": .int(Int64(spec.maxSequence)),
                "is_active": .int(spec.isActive ? 1 : 0),
                "ext": .null,
            ],
            conflictColumns: ["model_id"]
        )
    }

    /// Make `modelID` the one active row and clear bit 27 (`spanIndexed`)
    /// on every drawer that carries it, all in one serializable
    /// transaction, so the span-encode duty re-encodes the estate under
    /// the new model. Idempotent: activating the already-active model still
    /// clears the bit (a forced re-encode), which is the safe direction.
    ///
    /// - Returns: the number of drawers whose bit 27 was cleared.
    /// - Throws: `LocusKitError.invalidContent` when no row has `modelID`.
    @discardableResult
    public func activate(modelID: String) async throws -> Int {
        return try await storage.transaction(isolation: .serializable) { txn in
            let target = try await txn.rowStore.query(
                table: "encoder_models",
                where: .eq(Column(table: "encoder_models", name: "model_id"), .text(modelID)),
                orderBy: [], limit: 1, offset: nil, columns: ["model_id"]
            )
            guard !target.isEmpty else {
                throw LocusKitError.invalidContent("encoder_models has no row for model_id \(modelID)")
            }
            _ = try await txn.rowStore.update(
                table: "encoder_models",
                values: ["is_active": .int(0)],
                where: .eq(Column(table: "encoder_models", name: "is_active"), .int(1))
            )
            _ = try await txn.rowStore.update(
                table: "encoder_models",
                values: ["is_active": .int(1)],
                where: .eq(Column(table: "encoder_models", name: "model_id"), .text(modelID))
            )
            // Estate-wide bit 27 clear: projected read of the rows that
            // carry the bit, then one UPDATE per row with the literal
            // cleared value (RowStore has no bitwise UPDATE expression).
            let carriers = try await txn.rowStore.query(
                table: "drawers",
                where: .bitmaskAll(Column(table: "drawers", name: "operationalBitmap"),
                                   mask: DrawerFeatureFlags.spanIndexed.rawValue),
                orderBy: [], limit: nil, offset: nil,
                columns: ["id", "operationalBitmap"]
            )
            var cleared = 0
            for row in carriers {
                guard case let .text(id) = row["id"] ?? .null else { continue }
                let current = Self.bitmapValue(row["operationalBitmap"])
                cleared += try await txn.rowStore.update(
                    table: "drawers",
                    values: ["operationalBitmap": .bitmap(current & ~DrawerFeatureFlags.spanIndexed.rawValue)],
                    where: .eq(Column(table: "drawers", name: "id"), .text(id))
                )
            }
            return cleared
        }
    }

    // MARK: - Helpers

    /// An Int64 bitmap column as read back: `.bitmap` from the declared
    /// column, `.int` from a raw SQLite read; anything else decodes to 0.
    static func bitmapValue(_ v: TypedValue?) -> Int64 {
        switch v {
        case .int(let i), .bitmap(let i): return i
        default: return 0
        }
    }

    static func validate(_ spec: EncoderModelRow) throws {
        func require(_ ok: Bool, _ what: String) throws {
            if !ok { throw LocusKitError.invalidContent("EncoderModelRow: \(what)") }
        }
        try require(!spec.modelID.isEmpty, "modelID must not be empty")
        try require(!spec.modelVersion.isEmpty, "modelVersion must not be empty")
        try require(spec.dim > 0, "dim must be positive")
        try require(spec.windowWords > 0, "windowWords must be positive")
        try require(spec.overlapDivisor >= 1, "overlapDivisor must be >= 1")
        try require(spec.maxSpans >= 1, "maxSpans must be >= 1")
        try require(spec.maxSequence > 0, "maxSequence must be positive")
    }

    static func spec(from row: StorageRow) throws -> EncoderModelRow {
        func text(_ key: String) throws -> String {
            guard case let .text(v) = row[key] ?? .null else {
                throw LocusKitError.corruptStoredValue(table: "encoder_models", column: key, storedText: "(null)")
            }
            return v
        }
        func int(_ key: String) throws -> Int {
            guard case let .int(v) = row[key] ?? .null else {
                throw LocusKitError.corruptStoredValue(table: "encoder_models", column: key, storedText: "(null)")
            }
            return Int(v)
        }
        let poolingText = try text("pooling")
        guard let pooling = Pooling(rawValue: poolingText) else {
            throw LocusKitError.corruptStoredValue(table: "encoder_models", column: "pooling", storedText: poolingText)
        }
        return EncoderModelRow(
            modelID: try text("model_id"),
            modelVersion: try text("model_version"),
            dim: try int("dim"),
            queryPrefix: try text("query_prefix"),
            docPrefix: try text("doc_prefix"),
            pooling: pooling,
            tokenizerHash: try text("tokenizer_hash"),
            windowWords: try int("window_words"),
            overlapDivisor: try int("overlap_divisor"),
            maxSpans: try int("max_spans"),
            maxSequence: try int("max_sequence"),
            isActive: try int("is_active") != 0
        )
    }
}
