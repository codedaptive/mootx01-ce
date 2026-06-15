// PostgreSQLConnection.swift
//
// Helpers for executing SQL against a PostgresConnection with
// our TypedValue bindings.

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
import SubstrateTypes
@preconcurrency import PostgresNIO

extension PostgresConnection {

    func executeSimple(_ sql: String, logger: Logger) async throws {
        do {
            _ = try await self.query(PostgresQuery(unsafeSQL: sql), logger: logger)
        } catch {
            throw StorageError.backendError(underlying: "PG exec failed: \(error) sql=\(sql)")
        }
    }

    func executeParameterized(_ sql: String, bindings: [TypedValue], logger: Logger) async throws -> PostgresRowSequence {
        var query = PostgresQuery(unsafeSQL: sql)
        query.binds = makeBindings(bindings)
        do {
            return try await self.query(query, logger: logger)
        } catch {
            throw StorageError.backendError(underlying: "PG query failed: \(error) sql=\(sql)")
        }
    }
}

/// Build PostgresBindings from TypedValues.
func makeBindings(_ values: [TypedValue]) -> PostgresBindings {
    var bindings = PostgresBindings(capacity: values.count)
    for v in values {
        switch v {
        case .null:
            bindings.appendNull()
        case .bool(let b):
            bindings.append(b)
        case .int(let i), .bitmap(let i):
            bindings.append(i)
        case .float(let f):
            bindings.append(f)
        case .text(let s):
            bindings.append(s)
        case .blob(let d):
            try? bindings.append(d, context: .default)
        case .uuid(let u):
            bindings.append(u)
        case .timestamp(let date):
            bindings.append(date)
        case .json(let data):
            // Bind as text; backend treats JSONB column as text on insert.
            let s = String(data: data, encoding: .utf8) ?? "{}"
            bindings.append(s)
        case .hlc(let hlc):
            bindings.append(Int64(bitPattern: hlc.packed))
        case .fingerprint(let fp):
            var data = Data()
            withUnsafeBytes(of: fp.block0.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: fp.block1.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: fp.block2.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: fp.block3.littleEndian) { data.append(contentsOf: $0) }
            try? bindings.append(data, context: .default)
        case .array(let arr):
            // Encode as JSON.
            let encoded = (try? JSONSerialization.data(withJSONObject: arr.map { encodeForJSON($0) })) ?? Data("[]".utf8)
            let s = String(data: encoded, encoding: .utf8) ?? "[]"
            bindings.append(s)
        }
    }
    return bindings
}

private func encodeForJSON(_ v: TypedValue) -> Any {
    switch v {
    case .null: return NSNull()
    case .bool(let b): return b
    case .int(let i), .bitmap(let i): return i
    case .float(let f): return f
    case .text(let s): return s
    case .uuid(let u): return u.uuidString
    case .timestamp(let d): return ISO8601DateFormatter().string(from: d)
    default: return NSNull()
    }
}

/// Decode a PostgresRow into a [String: TypedValue] using the
/// declared column types.
func decodeRow(_ row: PostgresRow, columns: [ColumnDeclaration]) -> [String: TypedValue] {
    var out: [String: TypedValue] = [:]
    let randomAccessRow = row.makeRandomAccess()
    for col in columns {
        // PostgresRandomAccessRow's by-name subscript is non-throwing and
        // returns the cell directly. `columns` always describes the query's own
        // projection, so every name is present in the row.
        let cell = randomAccessRow[col.name]
        out[col.name] = decodeCell(cell, type: col.type)
    }
    return out
}

private func decodeCell(_ cell: PostgresRandomAccessRow.Element, type: ColumnType) -> TypedValue {
    do {
        switch type {
        case .uuid:
            let u: UUID = try cell.decode(UUID.self, context: .default)
            return .uuid(u)
        case .bitmap:
            let i: Int64 = try cell.decode(Int64.self, context: .default)
            return .bitmap(i)
        case .int:
            let i: Int64 = try cell.decode(Int64.self, context: .default)
            return .int(i)
        case .text:
            let s: String = try cell.decode(String.self, context: .default)
            return .text(s)
        case .timestamp:
            let d: Date = try cell.decode(Date.self, context: .default)
            return .timestamp(d)
        case .float:
            let f: Double = try cell.decode(Double.self, context: .default)
            return .float(f)
        case .bool:
            let b: Bool = try cell.decode(Bool.self, context: .default)
            return .bool(b)
        case .blob:
            let d: ByteBuffer = try cell.decode(ByteBuffer.self, context: .default)
            return .blob(Data(buffer: d))
        case .json:
            let s: String = try cell.decode(String.self, context: .default)
            return .json(Data(s.utf8))
        case .hlc:
            let i: Int64 = try cell.decode(Int64.self, context: .default)
            // Use the canonical inverse: HLC(packed:) matches HLC.packed's
            // layout (node<<56 | logical<<40 | physical).
            return .hlc(HLC(packed: UInt64(bitPattern: i)))
        case .fingerprint:
            let d: ByteBuffer = try cell.decode(ByteBuffer.self, context: .default)
            let data = Data(buffer: d)
            guard data.count >= 32 else { return .null }
            let b0 = data[0..<8].withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }
            let b1 = data[8..<16].withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }
            let b2 = data[16..<24].withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }
            let b3 = data[24..<32].withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }
            return .fingerprint(Fingerprint256(block0: b0, block1: b1, block2: b2, block3: b3))
        }
    } catch {
        return .null
    }
}

import Logging
