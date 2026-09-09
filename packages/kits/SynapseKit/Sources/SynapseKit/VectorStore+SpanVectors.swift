// VectorStore+SpanVectors.swift
//
// Encoder span rows in the `vectors` table (ENCODER_RERANK_CONTRACT §3,
// SYNAPSEKIT_SPEC § I-4a). A retrieval-trained sentence encoder splits each
// drawer's content into overlapping word windows ("spans"); every span is
// stored as ONE `vectors` row under the encoder's model id:
//
//   item_id       = the drawer UUID
//   vector_index  = the span index (0-based, span order)
//   kind          = 2 (int8), dim = the model dimension
//   payload       = dim bytes, two's-complement int8 (SubstrateKernel Int8Vec)
//   scale         = the per-vector dequantisation scale (REAL)
//   generation    = the model's serving generation (0 unless a swap happened)
//   ext           = {"cv":"<content_version>","e":<end_word>,"s":<start_word>}
//
// No new table and no new column: this is the multi-vector row shape the
// table has carried since Lane F (`vector_index`), with the int8 lane now
// populated under the ratified quantisation policy. Whole-record encoder
// vectors are never stored — spans only.
//
// Why a dedicated API instead of `addPayloads`: a span set is replaced as a
// unit. Re-encoding a drawer after a content edit must never leave a stale
// tail (old span 7 surviving next to new spans 0–5), so `writeSpanVectors`
// deletes the item's span rows and inserts the new set in ONE transaction.
// Span rows never enter the resident Hamming array or a float index: the
// rerank stage fetches them per query by item id (`spanVectors`) and scores
// them with `Int8Vec.dotQuery`; that is the whole read path.
//
// `ext` is written by hand with sorted keys and minimal escaping so the
// Swift and Rust ports emit byte-identical text (Foundation's
// JSONSerialization escapes "/" and the Rust port carries no JSON library).
// Reading is tolerant of key order.
//
// Rust twin: rust/src/vector_store/span_vectors.rs.

import Foundation
import PersistenceKit

/// One span to persist through `VectorStore.writeSpanVectors`.
///
/// `int8` and `scale` come straight from `Int8Vec.quantize` over the
/// encoder's L2-normalised span vector. `startWord`/`endWord` are the
/// half-open word bounds `[startWord, endWord)` of the span in the
/// product's word split, kept so the composer can render the evidence
/// snippet without re-spanning. `contentVersion` is the drawer's
/// FNV-1a64 of the drawer content at encode time; a later content write changes it, which
/// is how a stale span set is recognised.
public struct SpanVectorInput: Sendable, Equatable {
    /// Span index within the item (0-based, in span order). Stored as
    /// `vector_index`; unique within one write.
    public let index: UInt32
    /// Quantised coefficients, exactly `dim` entries.
    public let int8: [Int8]
    /// Per-vector dequantisation scale (`Int8Vec.quantize` output).
    public let scale: Float
    /// First word of the span (inclusive).
    public let startWord: Int
    /// End word of the span (exclusive).
    public let endWord: Int
    /// The FNV-1a64 content version of the drawer the span was cut from.
    public let contentVersion: String

    public init(index: UInt32, int8: [Int8], scale: Float,
                startWord: Int, endWord: Int, contentVersion: String) {
        self.index = index
        self.int8 = int8
        self.scale = scale
        self.startWord = startWord
        self.endWord = endWord
        self.contentVersion = contentVersion
    }
}

/// One span row read back through `VectorStore.spanVectors`. Same fields as
/// `SpanVectorInput`; a distinct type so the write shape and the read shape
/// can diverge later without an API break.
public struct SpanVectorRow: Sendable, Equatable {
    public let index: UInt32
    public let int8: [Int8]
    public let scale: Float
    public let startWord: Int
    public let endWord: Int
    public let contentVersion: String

    public init(index: UInt32, int8: [Int8], scale: Float,
                startWord: Int, endWord: Int, contentVersion: String) {
        self.index = index
        self.int8 = int8
        self.scale = scale
        self.startWord = startWord
        self.endWord = endWord
        self.contentVersion = contentVersion
    }
}

/// A malformed serving-generation span row observed by a strict reader.
///
/// Generic span retrieval deliberately skips malformed rows so ordinary
/// recall remains available. Strict transcript rerank instead needs the
/// observation: it refuses the entire request rather than quietly scoring a
/// partial head.
public struct StrictSpanVectorMalformedRow: Sendable, Equatable {
    /// Drawer id from the stored row, which is necessarily one of the ids the
    /// strict snapshot requested.
    public let itemID: String
    /// Stored span index when the value has the expected integer shape.
    public let index: UInt32?

    public init(itemID: String, index: UInt32?) {
        self.itemID = itemID
        self.index = index
    }
}

/// An all-or-nothing read receipt for strict transcript rerank.
///
/// `servingGeneration` pins the exact serving lane read by `rows`; callers
/// must revalidate this receipt immediately before treating a strict rerank
/// as applied. `malformedRows` retains evidence which the tolerant
/// `spanVectors` API intentionally omits.
public struct StrictSpanVectorSnapshot: Sendable, Equatable {
    public let modelID: String
    public let servingGeneration: Int64
    public let rows: [String: [SpanVectorRow]]
    public let malformedRows: [StrictSpanVectorMalformedRow]

    public init(
        modelID: String,
        servingGeneration: Int64,
        rows: [String: [SpanVectorRow]],
        malformedRows: [StrictSpanVectorMalformedRow]
    ) {
        self.modelID = modelID
        self.servingGeneration = servingGeneration
        self.rows = rows
        self.malformedRows = malformedRows
    }
}

extension VectorStore {

    /// Upper bound on ids per `IN (...)` clause. SQLite caps expression-tree
    /// depth at 1000; 900 leaves headroom for the surrounding predicate.
    static let spanQueryIDChunk = 900

    // MARK: - Write

    /// Replace every span row of `(itemID, modelID)` with `spans`, atomically.
    ///
    /// Deletes the item's existing int8 rows under `modelID` at the serving
    /// generation and inserts one row per span inside ONE transaction, so a
    /// reader never observes a mix of the old and the new span set. Passing
    /// an empty `spans` removes the item's spans (a drawer whose content
    /// shrank to nothing).
    ///
    /// - Parameters:
    ///   - itemID: the drawer UUID.
    ///   - modelID: the encoder identity (`<model>-w<window_words>`).
    ///   - modelVersion: the encoder weights revision.
    ///   - spans: the item's complete span set; all vectors share one `dim`.
    ///   - filedAt: the filing instant, passed in (determinism discipline:
    ///     the store never reads the clock).
    /// - Throws: `SynapseKitError.invalidPayload` when the spans disagree on
    ///   dimension, carry an empty vector, repeat an index, or invert a word
    ///   range; storage errors propagate unchanged.
    public func writeSpanVectors(
        itemID: String,
        modelID: String,
        modelVersion: String,
        spans: [SpanVectorInput],
        filedAt: Date
    ) async throws {
        try Self.validateSpanSet(spans, itemID: itemID)
        let servingGen = try await _servingGeneration(for: modelID)
        try await storage.rowStore.beginTransaction()
        do {
            _ = try await storage.rowStore.delete(
                table: "vectors",
                where: Self.spanRowsPredicate(itemID: itemID, modelID: modelID, generation: servingGen)
            )
            for span in spans {
                let values: [String: TypedValue] = [
                    "id":            .uuid(UUID()),
                    "item_id":       .text(itemID),
                    "vector_index":  .int(Int64(span.index)),
                    "model_id":      .text(modelID),
                    "model_version": .text(modelVersion),
                    "kind":          .int(Int64(VectorKind.int8.rawValue)),
                    "dim":           .int(Int64(span.int8.count)),
                    "payload":       .blob(Data(span.int8.map { UInt8(bitPattern: $0) })),
                    "scale":         .float(Double(span.scale)),
                    "filed_at":      .timestamp(filedAt),
                    "ext":           .text(Self.encodeSpanExt(
                                         start: span.startWord, end: span.endWord,
                                         contentVersion: span.contentVersion)),
                    "generation":    .int(servingGen),
                ]
                _ = try await storage.rowStore.insert(table: "vectors", values: values)
            }
            try await storage.rowStore.commitTransaction()
        } catch {
            try? await storage.rowStore.rollbackTransaction()
            throw error
        }
    }

    // MARK: - Read

    /// The span rows of every item in `itemIDs` under `modelID`, serving
    /// generation only, keyed by item id and ordered by span index.
    ///
    /// Items with no span rows are absent from the result (the rerank stage
    /// keeps them at their lexical rank). Ids are queried in chunks of
    /// `spanQueryIDChunk`, so a 1000-item head is two statements. A row whose
    /// payload, scale, or `ext` is malformed is skipped, matching the store's
    /// other read paths (`storedVector(from:)`), because one bad row must not
    /// take a query down.
    public func spanVectors(
        itemIDs: [String],
        modelID: String
    ) async throws -> [String: [SpanVectorRow]] {
        guard !itemIDs.isEmpty else { return [:] }
        let servingGen = try await _servingGeneration(for: modelID)
        var result: [String: [SpanVectorRow]] = [:]
        let unique = Array(Set(itemIDs))
        var start = 0
        while start < unique.count {
            let end = min(start + Self.spanQueryIDChunk, unique.count)
            let chunk = unique[start..<end].map { TypedValue.text($0) }
            start = end
            let rows = try await storage.rowStore.query(
                table: "vectors",
                where: .and([
                    .in(Column(table: "vectors", name: "item_id"), chunk),
                    .eq(Column(table: "vectors", name: "model_id"), .text(modelID)),
                    .eq(Column(table: "vectors", name: "kind"), .int(Int64(VectorKind.int8.rawValue))),
                    .eq(Column(table: "vectors", name: "generation"), .int(servingGen)),
                ]),
                orderBy: [
                    OrderClause(column: Column(table: "vectors", name: "item_id"), direction: .ascending),
                    OrderClause(column: Column(table: "vectors", name: "vector_index"), direction: .ascending),
                ],
                limit: nil,
                offset: nil
            )
            for row in rows {
                guard case let .text(itemID) = row["item_id"] ?? .null,
                      let span = Self.spanRow(from: row) else { continue }
                result[itemID, default: []].append(span)
            }
        }
        return result
    }

    /// Read every requested serving-generation span row without discarding
    /// malformed rows, returning a receipt that can be revalidated before a
    /// strict transcript result is applied.
    ///
    /// This API is intentionally separate from `spanVectors`: generic recall
    /// keeps its established tolerant behavior. A strict caller must reject a
    /// nonempty `malformedRows` collection and call
    /// `revalidatesStrictSpanVectorSnapshot` before publishing its result.
    public func strictSpanVectorSnapshot(
        itemIDs: [String],
        modelID: String
    ) async throws -> StrictSpanVectorSnapshot {
        let servingGeneration = try await _servingGeneration(for: modelID)
        guard !itemIDs.isEmpty else {
            return StrictSpanVectorSnapshot(
                modelID: modelID, servingGeneration: servingGeneration,
                rows: [:], malformedRows: [])
        }
        var result: [String: [SpanVectorRow]] = [:]
        var malformed: [StrictSpanVectorMalformedRow] = []
        let unique = Array(Set(itemIDs))
        var start = 0
        while start < unique.count {
            let end = min(start + Self.spanQueryIDChunk, unique.count)
            let chunk = unique[start..<end].map { TypedValue.text($0) }
            start = end
            let rows = try await storage.rowStore.query(
                table: "vectors",
                where: .and([
                    .in(Column(table: "vectors", name: "item_id"), chunk),
                    .eq(Column(table: "vectors", name: "model_id"), .text(modelID)),
                    .eq(Column(table: "vectors", name: "kind"), .int(Int64(VectorKind.int8.rawValue))),
                    .eq(Column(table: "vectors", name: "generation"), .int(servingGeneration)),
                ]),
                orderBy: [
                    OrderClause(column: Column(table: "vectors", name: "item_id"), direction: .ascending),
                    OrderClause(column: Column(table: "vectors", name: "vector_index"), direction: .ascending),
                ],
                limit: nil,
                offset: nil
            )
            for row in rows {
                // The query predicate admits only requested, text item ids
                // written by VectorStore. Keep a malformed row observable if
                // a damaged database violates that shape nonetheless.
                guard case let .text(itemID) = row["item_id"] ?? .null else {
                    continue
                }
                if let span = Self.spanRow(from: row) {
                    result[itemID, default: []].append(span)
                } else {
                    malformed.append(StrictSpanVectorMalformedRow(
                        itemID: itemID, index: Self.spanIndex(from: row)))
                }
            }
        }
        return StrictSpanVectorSnapshot(
            modelID: modelID, servingGeneration: servingGeneration,
            rows: result, malformedRows: malformed)
    }

    /// Whether `snapshot` still describes the serving generation of its
    /// model. It makes no content claim; strict callers validate every row's
    /// content version separately.
    public func revalidatesStrictSpanVectorSnapshot(
        _ snapshot: StrictSpanVectorSnapshot
    ) async throws -> Bool {
        try await _servingGeneration(for: snapshot.modelID) == snapshot.servingGeneration
    }

    // MARK: - Delete

    /// Remove every span row of `(itemID, modelID)` across all generations.
    /// Used when a drawer is expunged; a content edit goes through
    /// `writeSpanVectors` instead, which replaces rather than deletes.
    public func deleteSpanVectors(itemID: String, modelID: String) async throws {
        _ = try await storage.rowStore.delete(
            table: "vectors",
            where: .and([
                .eq(Column(table: "vectors", name: "item_id"), .text(itemID)),
                .eq(Column(table: "vectors", name: "model_id"), .text(modelID)),
                .eq(Column(table: "vectors", name: "kind"), .int(Int64(VectorKind.int8.rawValue))),
            ])
        )
    }

    // MARK: - Reclaim (mootx01 upgrade)

    /// Delete the rows `mootx01 upgrade` reclaims: every row of the retired
    /// model ids, and every row whose generation is not its model's serving
    /// generation. Returns the two counts.
    ///
    /// Models with a shadow build in flight (`shadow_state == "building"`)
    /// are left alone: their shadow rows are work in progress, not garbage.
    /// Matching `hnsw_graph` rows go with their vectors. Because this is a
    /// maintenance pass over the durable table, the resident structures are
    /// rebuilt from the table afterwards whenever anything was deleted, so a
    /// long-lived store stays coherent; the upgrade opens a fresh store and
    /// pays nothing. Never runs inside a query path.
    @discardableResult
    public func reclaimRetiredVectorRows(
        retiredModelIDs: [String]
    ) async throws -> (retiredModelRows: Int, nonServingRows: Int) {
        var retiredRows = 0
        if !retiredModelIDs.isEmpty {
            let ids = retiredModelIDs.map { TypedValue.text($0) }
            retiredRows = try await storage.rowStore.delete(
                table: "vectors",
                where: .in(Column(table: "vectors", name: "model_id"), ids))
            _ = try await storage.rowStore.delete(
                table: "hnsw_graph",
                where: .in(Column(table: "hnsw_graph", name: "model_id"), ids))
            for id in retiredModelIDs {
                floatIndices.removeValue(forKey: id)
                liveFloatCounts.removeValue(forKey: id)
                _invalidateHNSWLane(for: id)
            }
        }

        // Serving generation per registered model; models with an active
        // shadow build are skipped entirely.
        var servingByModel: [String: Int64] = [:]
        var building: Set<String> = []
        let registry = try await storage.rowStore.query(
            table: "vector_generations", where: .isTrue, orderBy: [], limit: nil, offset: nil)
        for row in registry {
            guard case let .text(model) = row["model_id"] ?? .null else { continue }
            if case let .int(gen) = row["serving_generation"] ?? .null {
                servingByModel[model] = gen
            }
            if case let .text(state) = row["shadow_state"] ?? .null, state == "building" {
                building.insert(model)
            }
        }
        // Distinct (model, generation) pairs present in the table, read
        // through a two-column projection so no payload is materialised.
        let pairRows = try await storage.rowStore.query(
            table: "vectors", where: .isTrue, orderBy: [], limit: nil, offset: nil,
            columns: ["model_id", "generation"])
        var pairs: Set<String> = []
        var stale: [(model: String, generation: Int64)] = []
        for row in pairRows {
            guard case let .text(model) = row["model_id"] ?? .null else { continue }
            let generation: Int64
            if case let .int(g) = row["generation"] ?? .null { generation = g } else { generation = 0 }
            let key = "\(model)\u{0}\(generation)"
            guard pairs.insert(key).inserted else { continue }
            if building.contains(model) { continue }
            // Unregistered models serve generation 0 (never swapped).
            if generation != (servingByModel[model] ?? 0) {
                stale.append((model, generation))
            }
        }
        var nonServingRows = 0
        for (model, generation) in stale {
            nonServingRows += try await storage.rowStore.delete(
                table: "vectors",
                where: .and([
                    .eq(Column(table: "vectors", name: "model_id"), .text(model)),
                    .eq(Column(table: "vectors", name: "generation"), .int(generation)),
                ]))
            _ = try await storage.rowStore.delete(
                table: "hnsw_graph",
                where: .and([
                    .eq(Column(table: "hnsw_graph", name: "model_id"), .text(model)),
                    .eq(Column(table: "hnsw_graph", name: "generation"), .int(generation)),
                ]))
        }
        if retiredRows + nonServingRows > 0 {
            try await _rebuildBinaryIndexFromTable()
        }
        return (retiredRows, nonServingRows)
    }

    /// Delete every whole-record float row (`kind` 1, the `float32`
    /// payloads the retired whole-record dense lane read) and every
    /// `hnsw_graph` row (the float lane's graph, rebuilt from those rows
    /// and useless without them), then rebuild the resident binary index
    /// and the `.vec` sidecar from the surviving rows so the sidecar's live
    /// count and generation match the serving table. Returns the two row
    /// counts. Kind 0 (binary fingerprints) and kind 2 (int8 spans) are
    /// never touched.
    ///
    /// The GLK 1.6 to 1.7 migration capsule calls this once per populated
    /// estate. Idempotent: a vacuumed estate deletes nothing and the rebuild
    /// rewrites an identical sidecar. Never runs inside a query path.
    @discardableResult
    public func reclaimWholeRecordFloatRows() async throws -> (floatRows: Int, graphRows: Int) {
        let floatRows = try await storage.rowStore.delete(
            table: "vectors",
            where: .eq(Column(table: "vectors", name: "kind"),
                       .int(Int64(VectorKind.float32.rawValue))))
        let graphRows = try await storage.rowStore.delete(table: "hnsw_graph", where: .isTrue)
        // The resident float and HNSW state described rows that are gone.
        floatIndices.removeAll()
        _invalidateAllHNSWLanes()
        try await _rebuildBinaryIndexFromTable()
        return (floatRows, graphRows)
    }

    // MARK: - Helpers

    /// The serving-generation span rows of one item under one model.
    static func spanRowsPredicate(itemID: String, modelID: String, generation: Int64) -> StoragePredicate {
        .and([
            .eq(Column(table: "vectors", name: "item_id"), .text(itemID)),
            .eq(Column(table: "vectors", name: "model_id"), .text(modelID)),
            .eq(Column(table: "vectors", name: "kind"), .int(Int64(VectorKind.int8.rawValue))),
            .eq(Column(table: "vectors", name: "generation"), .int(generation)),
        ])
    }

    /// One dimension, non-empty vectors, unique indexes, ordered word ranges.
    static func validateSpanSet(_ spans: [SpanVectorInput], itemID: String) throws {
        guard let first = spans.first else { return }
        let dim = first.int8.count
        guard dim > 0 else {
            throw SynapseKitError.invalidPayload("writeSpanVectors(\(itemID)): span vectors must not be empty")
        }
        var seen: Set<UInt32> = []
        for span in spans {
            guard span.int8.count == dim else {
                throw SynapseKitError.invalidPayload(
                    "writeSpanVectors(\(itemID)): span \(span.index) has dim \(span.int8.count), expected \(dim)")
            }
            guard seen.insert(span.index).inserted else {
                throw SynapseKitError.invalidPayload("writeSpanVectors(\(itemID)): duplicate span index \(span.index)")
            }
            guard span.startWord >= 0, span.endWord >= span.startWord else {
                throw SynapseKitError.invalidPayload(
                    "writeSpanVectors(\(itemID)): span \(span.index) has word range [\(span.startWord), \(span.endWord))")
            }
        }
    }

    /// `{"cv":"…","e":N,"s":N}` with sorted keys and minimal JSON string
    /// escaping (quote, backslash, control characters as \u00XX). Byte-
    /// identical to the Rust writer by construction.
    static func encodeSpanExt(start: Int, end: Int, contentVersion: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(contentVersion.utf8.count)
        for scalar in contentVersion.unicodeScalars {
            switch scalar {
            case "\"": escaped += "\\\""
            case "\\": escaped += "\\\\"
            case _ where scalar.value < 0x20:
                escaped += String(format: "\\u%04x", scalar.value)
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return "{\"cv\":\"\(escaped)\",\"e\":\(end),\"s\":\(start)}"
    }

    /// Decode one `vectors` row into a span row; nil when malformed.
    static func spanRow(from row: StorageRow) -> SpanVectorRow? {
        guard case let .int(index) = row["vector_index"] ?? .null, index >= 0, index <= Int64(UInt32.max),
              case let .int(dim) = row["dim"] ?? .null, dim > 0,
              case let .blob(bytes) = row["payload"] ?? .null, bytes.count == Int(dim),
              case let .float(scale) = row["scale"] ?? .null,
              case let .text(ext) = row["ext"] ?? .null,
              let bounds = decodeSpanExt(ext) else {
            return nil
        }
        return SpanVectorRow(
            index: UInt32(index),
            int8: bytes.map { Int8(bitPattern: $0) },
            scale: Float(scale),
            startWord: bounds.start,
            endWord: bounds.end,
            contentVersion: bounds.contentVersion
        )
    }

    static func spanIndex(from row: StorageRow) -> UInt32? {
        guard case let .int(index) = row["vector_index"] ?? .null,
              index >= 0, index <= Int64(UInt32.max) else {
            return nil
        }
        return UInt32(index)
    }

    /// Parse the `ext` JSON object; key order is not assumed.
    static func decodeSpanExt(_ text: String) -> (start: Int, end: Int, contentVersion: String)? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let start = (object["s"] as? NSNumber)?.intValue,
              let end = (object["e"] as? NSNumber)?.intValue,
              let contentVersion = object["cv"] as? String else {
            return nil
        }
        return (start, end, contentVersion)
    }
}
