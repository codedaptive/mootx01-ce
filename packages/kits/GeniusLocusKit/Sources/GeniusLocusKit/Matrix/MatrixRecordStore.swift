import Foundation
import PersistenceKit
import SubstrateTypes

public enum MatrixRecordError: Error, Sendable, Equatable {
    case corrupt(String)
    case workingSetLimit(String)
    case publicationConflict
    case sourceChanged
    case maintenanceUnavailable
}

/// Typed row persistence. No method encodes or binds a complete matrix.
/// The refresh owner serializes generation publication; calibration uses its
/// own transactions and is deliberately absent from generation writes.
public actor MatrixRecordStore {
    public static let batchSize = 256
    public static let defaultCellLimit = 1_000_000
    public static let schemaDeclaration = SchemaDeclaration(
        kitID: "GeniusLocusKitMatrixRecords", version: 2,
        tables: [
            TableDeclaration(name: "matrix_state", columns: [
                .text("estate_id", nullable: false), .text("active_generation", nullable: true),
                .text("migration_phase", nullable: false), .int("reclaimed_bytes", nullable: false),
                .text("reason", nullable: true), .json("ext", nullable: true)
            ], primaryKey: ["estate_id"]),
            TableDeclaration(name: "matrix_generations", columns: [
                .text("estate_id", nullable: false), .text("generation", nullable: false),
                .text("phase", nullable: false), .int("cell_count", nullable: false),
                .int("live_row_count", nullable: false),
                .int("last_physical_ms"), .int("last_logical"), .int("last_node"),
                .int("temporal_physical_ms"), .int("temporal_logical"), .int("temporal_node"),
                .int("decayed_as_of_ms", nullable: false),
                .timestamp("updated_at", nullable: false), .json("ext", nullable: true)
            ], primaryKey: ["estate_id", "generation"]),
            TableDeclaration(name: "matrix_cells", columns: [
                .text("estate_id", nullable: false), .text("generation", nullable: false),
                .text("cell_id", nullable: false), .text("family", nullable: false),
                .text("a_field", nullable: false), .text("a_kind", nullable: false),
                .text("a_value", nullable: false), .text("b_field", nullable: false),
                .text("b_kind", nullable: false), .text("b_value", nullable: false),
                .int("lag", nullable: false), .int("count", nullable: true),
                .float("decayed", nullable: true), .json("ext", nullable: true)
            ], primaryKey: ["estate_id", "generation", "cell_id"]),
            TableDeclaration(name: "matrix_calibration", columns: [
                .text("estate_id", nullable: false), .text("model_id", nullable: false),
                .int("bucket", nullable: false), .int("count", nullable: false),
                .float("success_rate", nullable: false), .float("updated_seconds", nullable: true),
                .json("ext", nullable: true)
            ], primaryKey: ["estate_id", "model_id", "bucket"])
        ])

    let storage: any Storage
    public init(storage: any Storage) { self.storage = storage }

    public func prepare() async throws {
        try await storage.migrate(to: Self.schemaDeclaration)
    }

    package static func estateKey(_ id: UUID) -> String { id.uuidString.lowercased() }
    package static func estatePredicate(_ table: String, _ estateID: UUID) -> StoragePredicate {
        .eq(Column(table: table, name: "estate_id"), .text(estateKey(estateID)))
    }
    private static func generationPredicate(_ table: String, _ estateID: UUID, _ generation: String) -> StoragePredicate {
        .and([estatePredicate(table, estateID), .eq(Column(table: table, name: "generation"), .text(generation))])
    }

    public func state(estateID: UUID) async throws -> StorageRow? {
        guard try await storage.currentSchemaVersion(for: Self.schemaDeclaration.kitID) > 0 else { return nil }
        return try await storage.rowStore.query(table: "matrix_state", where: Self.estatePredicate("matrix_state", estateID),
                                         orderBy: [], limit: 1, offset: nil).first
    }

    public func activeGeneration(estateID: UUID) async throws -> String? {
        guard let row = try await state(estateID: estateID) else { return nil }
        if case let .text(value)? = row["active_generation"] { return value }
        return nil
    }

    package func statusMetadata(estateID: UUID) async throws -> MatrixRefreshStatus {
        var status = MatrixRefreshStatus()
        guard let state = try await state(estateID: estateID) else { return status }
        status.migrationPhase = Self.text(state.values, "migration_phase")
        status.reclaimedBytes = Self.int(state.values, "reclaimed_bytes")
        if case let .text(generation)? = state["active_generation"] {
            status.generation = generation
            if let row = try await storage.rowStore.query(table: "matrix_generations",
                where: Self.generationPredicate("matrix_generations", estateID, generation),
                orderBy: [], limit: 1, offset: nil).first {
                status.watermark = try Self.watermark(row, prefix: "last")
            }
        }
        return status
    }

    package func setMigration(estateID: UUID, phase: String, reclaimedBytes: Int64 = 0, reason: String? = nil) async throws {
        var values = try await state(estateID: estateID)?.values ?? Self.emptyState(estateID)
        values["migration_phase"] = .text(phase)
        values["reclaimed_bytes"] = .int(reclaimedBytes)
        values["reason"] = reason.map(TypedValue.text) ?? .null
        try await storage.rowStore.upsert(table: "matrix_state", values: values, conflictColumns: ["estate_id"])
    }

    private static func emptyState(_ estateID: UUID) -> [String: TypedValue] {
        ["estate_id": .text(estateKey(estateID)), "active_generation": .null,
         "migration_phase": .text("complete"), "reclaimed_bytes": .int(0), "reason": .null]
    }

    /// Deterministic, bounded batches make retry into the same staging generation
    /// idempotent. A watermark never denotes partially stored cells.
    package func stage(estateID: UUID, tier: MatrixTier, generation: String, now: Date,
                       cellLimit: Int = defaultCellLimit) async throws {
        let size = tier.fieldPresence.count + tier.coOccurrence.count + tier.temporalCausality.count
            + tier.coOccurrenceDecayed.count + tier.temporalCausalityDecayed.count
        guard size <= cellLimit else { throw MatrixRecordError.workingSetLimit("matrix cell budget exceeded") }
        try Task.checkCancellation()
        let keys = Self.cellKeys(tier)
        let count = keys.count
        try await storage.rowStore.upsert(table: "matrix_generations", values: [
            "estate_id": .text(Self.estateKey(estateID)), "generation": .text(generation),
            "phase": .text("staging"), "cell_count": .int(Int64(count)),
            "live_row_count": .int(tier.liveRowCount),
            "last_physical_ms": .int(tier.lastHLC.physicalTime), "last_logical": .int(Int64(tier.lastHLC.logicalCount)),
            "last_node": .int(Int64(tier.lastHLC.nodeID)),
            "temporal_physical_ms": .int(tier.temporalWatermarkHLC.physicalTime),
            "temporal_logical": .int(Int64(tier.temporalWatermarkHLC.logicalCount)),
            "temporal_node": .int(Int64(tier.temporalWatermarkHLC.nodeID)),
            "decayed_as_of_ms": .int(tier.decayedAsOfMs),
            "updated_at": .timestamp(now)
        ], conflictColumns: ["estate_id", "generation"])
        var cursor = 0
        while cursor < count {
            try Task.checkCancellation()
            let end = min(cursor + Self.batchSize, count)
            let batch = keys[cursor..<end].map { Self.cellRow(tier, key: $0) }
            try await storage.transaction(isolation: .serializable) { tx in
                for var row in batch {
                    row["estate_id"] = .text(Self.estateKey(estateID)); row["generation"] = .text(generation)
                    try await tx.rowStore.upsert(table: "matrix_cells", values: row,
                                                conflictColumns: ["estate_id", "generation", "cell_id"])
                }
            }
            cursor = end
            await Task.yield()
        }
        guard try await storage.rowStore.count(table: "matrix_cells", where:
            Self.generationPredicate("matrix_cells", estateID, generation)) == count else {
            throw MatrixRecordError.corrupt("staging generation cell count mismatch")
        }
        _ = try await storage.rowStore.update(table: "matrix_generations", values: ["phase": .text("ready")],
            where: Self.generationPredicate("matrix_generations", estateID, generation))
    }

    package func publish(estateID: UUID, generation: String, expected: String?, auditCount: Int? = nil) async throws {
        try Task.checkCancellation()
        try await storage.transaction(isolation: .serializable) { tx in
            if let auditCount, try await tx.auditLog.count() != auditCount { throw MatrixRecordError.sourceChanged }
            let state = try await tx.rowStore.query(table: "matrix_state",
                where: Self.estatePredicate("matrix_state", estateID), orderBy: [], limit: 1, offset: nil).first
            var values = state?.values ?? Self.emptyState(estateID)
            let current: String? = if case let .text(value)? = values["active_generation"] { value } else { nil }
            guard current == expected else { throw MatrixRecordError.publicationConflict }
            let metadata = try await tx.rowStore.query(table: "matrix_generations",
                where: Self.generationPredicate("matrix_generations", estateID, generation),
                orderBy: [], limit: 1, offset: nil).first
            guard let metadata, Self.text(metadata.values, "phase") == "ready" else {
                throw MatrixRecordError.corrupt("attempt to publish incomplete generation")
            }
            values["active_generation"] = .text(generation)
            try Task.checkCancellation()
            try await tx.rowStore.upsert(table: "matrix_state", values: values, conflictColumns: ["estate_id"])
        }
    }

    public func load(estateID: UUID, cellLimit: Int = defaultCellLimit) async throws -> MatrixTier? {
        guard let generation = try await activeGeneration(estateID: estateID) else { return nil }
        return try await loadGeneration(estateID: estateID, generation: generation, cellLimit: cellLimit)
    }

    package func loadGeneration(estateID: UUID, generation: String, cellLimit: Int = defaultCellLimit) async throws -> MatrixTier {
        guard let meta = try await storage.rowStore.query(table: "matrix_generations",
            where: Self.generationPredicate("matrix_generations", estateID, generation), orderBy: [], limit: 1, offset: nil).first,
            Self.text(meta.values, "phase") == "ready" else {
            throw MatrixRecordError.corrupt("missing completed generation metadata")
        }
        let last = try Self.watermark(meta, prefix: "last")
        let temporal = try Self.watermark(meta, prefix: "temporal")
        let count = Int(Self.int(meta.values, "cell_count"))
        guard count >= 0, count <= cellLimit else { throw MatrixRecordError.workingSetLimit("stored matrix cell budget exceeded") }
        var f: [MatrixFieldCell: Int64] = [:], o: [MatrixCoOccurKey: Int64] = [:]
        var t: [MatrixTemporalKey: Int64] = [:], od: [MatrixCoOccurKey: Double] = [:], td: [MatrixTemporalKey: Double] = [:]
        var offset = 0
        var lastCellID: String?
        while offset < count {
            try Task.checkCancellation()
            let cursor = lastCellID
            var predicate = Self.generationPredicate("matrix_cells", estateID, generation)
            if let cursor { predicate = .and([predicate, .gt(Column(table: "matrix_cells", name: "cell_id"), .text(cursor))]) }
            let rows = try await storage.rowStore.query(table: "matrix_cells",
                where: predicate,
                orderBy: [OrderClause(column: Column(table: "matrix_cells", name: "cell_id"), direction: .ascending)],
                limit: Self.batchSize, offset: nil)
            guard !rows.isEmpty else { throw MatrixRecordError.corrupt("truncated matrix generation") }
            for row in rows {
                let v = row.values, n = Self.int(v, "count")
                let decay: Double? = if case let .float(value)? = row["decayed"] { value } else { nil }
                switch Self.text(v, "family") {
                case "f":
                    guard let bit = Int(Self.text(v, "a_value")), (0...63).contains(bit) else { throw MatrixRecordError.corrupt("invalid field bit") }
                    f[MatrixFieldCell(fieldPath: Self.text(v, "a_field"), bitPosition: bit)] = n
                case "o":
                    let key = MatrixCoOccurKey(try Self.coord(v, "a"), try Self.coord(v, "b"))
                    if case .int? = row["count"] { o[key] = n }; if let decay { od[key] = decay }
                case "t":
                    let key = MatrixTemporalKey(source: try Self.coord(v, "a"), target: try Self.coord(v, "b"), lagBucket: Int(Self.int(v, "lag")))
                    if case .int? = row["count"] { t[key] = n }; if let decay { td[key] = decay }
                default: throw MatrixRecordError.corrupt("unknown matrix cell family")
                }
            }
            offset += rows.count
            lastCellID = rows.last.flatMap { if case let .text(id)? = $0["cell_id"] { id } else { nil } }
        }
        guard offset == count else { throw MatrixRecordError.corrupt("matrix count mismatch") }
        return MatrixTier(fieldPresence: f, coOccurrence: o, temporalCausality: t,
            liveRowCount: Self.int(meta.values, "live_row_count"), lastHLC: last, temporalWatermarkHLC: temporal,
            coOccurrenceDecayed: od, temporalCausalityDecayed: td, decayedAsOfMs: Self.int(meta.values, "decayed_as_of_ms"))
    }

    package static func watermark(_ row: StorageRow, prefix: String) throws -> HLC {
        guard case let .int(physical)? = row[prefix + "_physical_ms"],
              case let .int(logical)? = row[prefix + "_logical"], let logical32 = Int32(exactly: logical),
              case let .int(node)? = row[prefix + "_node"], let node32 = Int32(exactly: node) else {
            throw MatrixRecordError.corrupt("invalid matrix watermark")
        }
        return HLC(physicalTime: physical, logicalCount: logical32, nodeID: node32)
    }

    public func saveCalibration(estateID: UUID, registry: MatrixCalibrationRegistry, modelID: String) async throws {
        guard let curve = registry.curves[modelID] else { return }
        let timestamp = registry.updateTimestamps[modelID].map { $0 + Date.timeIntervalBetween1970AndReferenceDate }
        try await storage.transaction(isolation: .serializable) { tx in
            try await Self.writeCurve(tx.rowStore, estateID: estateID, modelID: modelID, curve: curve, timestamp: timestamp)
        }
    }

    private static func writeCurve(_ rows: any RowStore, estateID: UUID, modelID: String,
                                   curve: MatrixCalibrationCurve, timestamp: Double?) async throws {
        guard curve.buckets.count == 20, timestamp?.isFinite != false else {
            throw MatrixRecordError.corrupt("invalid calibration curve or timestamp")
        }
        for (index, bucket) in curve.buckets.enumerated() {
            guard bucket.count >= 0, bucket.successRate.isFinite, (0...1).contains(bucket.successRate) else {
                throw MatrixRecordError.corrupt("invalid calibration bucket")
            }
            try await rows.upsert(table: "matrix_calibration", values: [
                    "estate_id": .text(Self.estateKey(estateID)), "model_id": .text(modelID),
                    "bucket": .int(Int64(index)), "count": .int(Int64(bucket.count)),
                    "success_rate": .float(Double(bucket.successRate)),
                    "updated_seconds": timestamp.map(TypedValue.float) ?? .null
                ], conflictColumns: ["estate_id", "model_id", "bucket"])
        }
    }

    /// Read/modify/write the twenty buckets in ONE transaction. Actor isolation
    /// alone is insufficient: actors can reenter while awaiting storage.
    public func recordCalibration(estateID: UUID, modelID: String, confidence: Float,
                                  outcome: MatrixCalibrationOutcome, now: Date) async throws -> MatrixCalibrationCurve {
        guard confidence.isFinite else { throw MatrixRecordError.corrupt("nonfinite confidence") }
        return try await storage.transaction(isolation: .serializable) { tx in
            let rows = try await tx.rowStore.query(table: "matrix_calibration", where: .and([
                Self.estatePredicate("matrix_calibration", estateID),
                .eq(Column(table: "matrix_calibration", name: "model_id"), .text(modelID))
            ]), orderBy: [], limit: 21, offset: nil)
            var buckets = Array(repeating: MatrixCalibrationBucket(), count: 20)
            var timestamp: Double?
            if !rows.isEmpty {
                guard rows.count == 20 else { throw MatrixRecordError.corrupt("incomplete calibration curve") }
                var seen: Set<Int> = []
                let storedTimestamp = rows[0]["updated_seconds"] ?? .null
                for row in rows {
                    guard case let .int(index)? = row["bucket"], (0..<20).contains(index),
                          case let .int(count)? = row["count"], (0...Int64(Int32.max - 1)).contains(count),
                          case let .float(rate)? = row["success_rate"], rate.isFinite, (0...1).contains(rate),
                          seen.insert(Int(index)).inserted,
                          (row["updated_seconds"] ?? .null) == storedTimestamp else { throw MatrixRecordError.corrupt("invalid calibration record") }
                    buckets[Int(index)] = MatrixCalibrationBucket(count: Int32(count), successRate: Float(rate))
                    if case let .float(value)? = row["updated_seconds"] {
                        guard value.isFinite, timestamp == nil || timestamp == value else { throw MatrixRecordError.corrupt("inconsistent calibration timestamp") }
                        timestamp = value
                    }
                }
            }
            var registry = MatrixCalibrationRegistry(curves: [modelID: MatrixCalibrationCurve(buckets: buckets)],
                updateTimestamps: timestamp.map { [modelID: $0 - Date.timeIntervalBetween1970AndReferenceDate] } ?? [:])
            registry.recordWithDecay(modelID: modelID, claimedConfidence: confidence, outcome: outcome, now: now)
            let curve = registry.curves[modelID]!
            try await Self.writeCurve(tx.rowStore, estateID: estateID, modelID: modelID, curve: curve,
                                      timestamp: now.timeIntervalSince1970)
            return curve
        }
    }

    /// Retain the current and preceding generation. Delete older/interrupted
    /// generations in bounded transactions, never rewriting a matrix BLOB.
    package func prune(estateID: UUID, keeping generations: Set<String>) async throws {
        let metadata = try await storage.rowStore.query(table: "matrix_generations",
            where: Self.estatePredicate("matrix_generations", estateID), orderBy: [], limit: nil, offset: nil)
        for generationRow in metadata {
            let generation = Self.text(generationRow.values, "generation")
            if generations.contains(generation) { continue }
            while true {
                try Task.checkCancellation()
                let deleted = try await storage.transaction(isolation: .serializable) { tx -> Int in
                    let state = try await tx.rowStore.query(table: "matrix_state", where: Self.estatePredicate("matrix_state", estateID), orderBy: [], limit: 1, offset: nil).first
                    if state?["active_generation"] == .text(generation) { return 0 }
                    let rows = try await tx.rowStore.query(table: "matrix_cells",
                        where: Self.generationPredicate("matrix_cells", estateID, generation), orderBy: [], limit: Self.batchSize, offset: nil)
                    for row in rows {
                        _ = try await tx.rowStore.delete(table: "matrix_cells", where: .and([
                            Self.generationPredicate("matrix_cells", estateID, generation),
                            .eq(Column(table: "matrix_cells", name: "cell_id"), row["cell_id"]!)
                        ]))
                    }
                    if rows.isEmpty {
                        _ = try await tx.rowStore.delete(table: "matrix_generations", where: Self.generationPredicate("matrix_generations", estateID, generation))
                    }
                    return rows.count
                }
                if deleted == 0 { break }
                await Task.yield()
            }
        }
    }

    public func loadCalibration(estateID: UUID) async throws -> MatrixCalibrationRegistry {
        var curves: [String: MatrixCalibrationCurve] = [:], times: [String: Double] = [:]
        var pending: [String: [MatrixCalibrationBucket]] = [:], seen: [String: Set<Int>] = [:]
        var timestamps: [String: TypedValue] = [:]
        var offset = 0
        while true {
            let rows = try await storage.rowStore.query(table: "matrix_calibration", where: Self.estatePredicate("matrix_calibration", estateID),
                orderBy: [OrderClause(column: Column(table: "matrix_calibration", name: "model_id"), direction: .ascending),
                          OrderClause(column: Column(table: "matrix_calibration", name: "bucket"), direction: .ascending)],
                limit: Self.batchSize, offset: offset)
            for row in rows {
                let model = Self.text(row.values, "model_id"), index = Int(Self.int(row.values, "bucket"))
                let count = Self.int(row.values, "count")
                guard (0..<20).contains(index), count >= 0, count <= Int32.max,
                    case let .float(rate)? = row["success_rate"], rate.isFinite, (0...1).contains(rate),
                    seen[model, default: []].insert(index).inserted else {
                    throw MatrixRecordError.corrupt("invalid calibration bucket")
                }
                if pending[model] == nil { pending[model] = Array(repeating: MatrixCalibrationBucket(), count: 20) }
                pending[model]?[index] = MatrixCalibrationBucket(count: Int32(count), successRate: Float(rate))
                let storedTimestamp = row["updated_seconds"] ?? .null
                guard timestamps[model] == nil || timestamps[model] == storedTimestamp else {
                    throw MatrixRecordError.corrupt("inconsistent calibration timestamp")
                }
                timestamps[model] = storedTimestamp
                switch storedTimestamp {
                case .float(let timestamp) where timestamp.isFinite:
                    times[model] = timestamp - Date.timeIntervalBetween1970AndReferenceDate
                case .null: break
                default: throw MatrixRecordError.corrupt("invalid calibration timestamp")
                }
            }
            offset += rows.count
            if rows.count < Self.batchSize { break }
        }
        for (model, buckets) in pending {
            guard seen[model]?.count == 20 else { throw MatrixRecordError.corrupt("incomplete calibration curve") }
            curves[model] = MatrixCalibrationCurve(buckets: buckets)
        }
        return MatrixCalibrationRegistry(curves: curves, updateTimestamps: times)
    }

    /// Derived generations only. Calibration is not disposable matrix cache.
    public func invalidate(estateID: UUID) async throws {
        _ = try await storage.rowStore.update(table: "matrix_state", values: ["active_generation": .null], where: Self.estatePredicate("matrix_state", estateID))
    }

    package static func text(_ v: [String: TypedValue], _ key: String) -> String {
        if case let .text(value)? = v[key] { return value }; return ""
    }
    package static func int(_ v: [String: TypedValue], _ key: String) -> Int64 {
        if case let .int(value)? = v[key] { return value }; return 0
    }
    private static func parts(_ coord: MatrixValueCoord) -> [String] {
        switch coord.value {
        case .null: [coord.fieldPath, "null", ""]
        case .bitmap(let value): [coord.fieldPath, "bitmap", String(value)]
        case .integer(let value): [coord.fieldPath, "integer", String(value)]
        case .string(let value): [coord.fieldPath, "string", value]
        case .bytes(let value): [coord.fieldPath, "bytes", Data(value).base64EncodedString()]
        }
    }
    private static func coord(_ v: [String: TypedValue], _ prefix: String) throws -> MatrixValueCoord {
        let value: UnifiedAuditValue
        let payload = text(v, prefix + "_value")
        switch text(v, prefix + "_kind") {
        case "null": value = .null
        case "bitmap": guard let n = UInt64(payload) else { throw MatrixRecordError.corrupt("invalid bitmap") }; value = .bitmap(n)
        case "integer": guard let n = Int64(payload) else { throw MatrixRecordError.corrupt("invalid integer") }; value = .integer(n)
        case "string": value = .string(payload)
        case "bytes": guard let bytes = Data(base64Encoded: payload) else { throw MatrixRecordError.corrupt("invalid bytes") }; value = .bytes(Array(bytes))
        default: throw MatrixRecordError.corrupt("invalid coordinate kind")
        }
        return MatrixValueCoord(fieldPath: text(v, prefix + "_field"), value: value)
    }
    private enum CellKey {
        case field(MatrixFieldCell), occurrence(MatrixCoOccurKey), temporal(MatrixTemporalKey)
    }
    private static func cellKeys(_ tier: MatrixTier) -> [CellKey] {
        tier.fieldPresence.keys.map(CellKey.field)
        + tier.coOccurrence.keys.map(CellKey.occurrence)
        + tier.coOccurrenceDecayed.keys.filter { tier.coOccurrence[$0] == nil }.map(CellKey.occurrence)
        + tier.temporalCausality.keys.map(CellKey.temporal)
        + tier.temporalCausalityDecayed.keys.filter { tier.temporalCausality[$0] == nil }.map(CellKey.temporal)
    }
    private static func cellRow(_ tier: MatrixTier, key: CellKey) -> [String: TypedValue] {
        func row(_ family: String, _ a: [String], _ b: [String], _ lag: Int, _ count: Int64?, _ decay: Double?) -> [String: TypedValue] {
            let key = ([family] + a + b + [String(lag)]).map { "\($0.utf8.count):\($0)" }.joined()
            return ["cell_id": .text(key), "family": .text(family),
                    "a_field": .text(a[0]), "a_kind": .text(a[1]), "a_value": .text(a[2]),
                    "b_field": .text(b[0]), "b_kind": .text(b[1]), "b_value": .text(b[2]),
                    "lag": .int(Int64(lag)), "count": count.map(TypedValue.int) ?? .null, "decayed": decay.map(TypedValue.float) ?? .null]
        }
        switch key {
        case .field(let key):
            return row("f", [key.fieldPath, "bit", String(key.bitPosition)], ["", "", ""], 0, tier.fieldPresence[key], nil)
        case .occurrence(let key):
            let a = parts(key.a), b = parts(key.b)
            let ascending = a.lexicographicallyPrecedes(b, by: { $0.utf8.lexicographicallyPrecedes($1.utf8) })
            return row("o", ascending ? a : b, ascending ? b : a, 0, tier.coOccurrence[key], tier.coOccurrenceDecayed[key])
        case .temporal(let key):
            return row("t", parts(key.source), parts(key.target), key.lagBucket, tier.temporalCausality[key], tier.temporalCausalityDecayed[key])
        }
    }
}
