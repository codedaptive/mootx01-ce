// DatasetSignatures.swift
// GeniusLocusKit — Intake
//
// MX-TAB-5: Layered dataset signatures (tier 1: table, tier 2: column).
//
// ## Architecture
//
// Two tiers of content fingerprint are computed and stored in the dataset
// handle's DatasetHandleContent JSON payload:
//
//   Tier 1 (table): One SHA-256 over the dataset schema (column names and
//   declared types, sorted ascending by name) concatenated with up to
//   `datasetSignatureSampleSize` (128) sampled rows in backend default order
//   (rowid asc for SQLite, insertion order for InMemory). Domain tag 0x10
//   distinguishes this preimage from Merkle node/leaf preimages (0x00–0x03).
//   Stored in DatasetHandleContent.tableSignature.
//
//   Tier 2 (column): One SHA-256 per column over (name, declared type,
//   value-distribution sketch). The sketch: distinct count, null count, min,
//   max from ColumnStats, plus the top-K (K=20, `datasetSignatureTopKCount`)
//   most-frequent values derived from `sampledRows`. Domain tag 0x11.
//   Stored in DatasetHandleContent.columnSignatures keyed by column name.
//
// ## Why SHA-256 / reuse rationale
//
// The existing codebase already uses SHA-256 (via SubstrateKernel.SHA256)
// for content-addressing audit log entries (cookbook §5.1). The same
// FIPS 180-4 primitive produces byte-identical output across Swift and Rust
// legs — the conformance harness gates this four ways. Inventing a second
// content-hash scheme for dataset signatures would add maintenance surface
// with no benefit. Domain tags (0x10/0x11) isolate these preimages from
// the Merkle scheme's (0x00–0x03) without requiring a separate primitive.
//
// ## No row fingerprints (MX-TABULAR open question 1, resolved)
//
// Individual row fingerprints are explicitly out of scope. This file does not
// read individual dataset rows directly; it operates on pre-fetched
// `sampledRows` passed by the tool layer (MX-TAB-7), keeping query overhead
// under caller control.
//
// ## Dreaming / matrix safety
//
// The updated handle drawer flows into recall exactly like any other drawer.
// Updating the `content` JSON column does not feed the association matrix or
// trigger distillation / dreaming — the matrix tier reads adjective and
// operational bitmaps, not the JSON content blob.
//
// ## Call contract for MX-TAB-7
//
// The MX-TAB-7 tool layer (moot_file_dataset) calls:
//
//   let sampledRows = try await datasetStore.queryRows(
//       id: datasetId, predicate: nil, orderBy: [],
//       limit: datasetSignatureSampleSize, offset: nil, columns: nil
//   )
//   let statsByColumn = try await Dictionary(uniqueKeysWithValues:
//       columns.map { ($0.name, try await datasetStore.columnStats(id: datasetId, column: $0.name)) }
//   )
//   let updatedDrawer = try await kit.computeDatasetSignatures(
//       handle: handle, drawerId: drawerID, columns: columns,
//       columnStats: statsByColumn, sampledRows: sampledRows, now: now
//   )
//
// Mirrors: GeniusLocusKit/rust/src/dataset_signatures.rs

import Foundation
import LocusKit
import PersistenceKit
import SubstrateKernel

// MARK: - Sampling and sketch constants

/// Maximum number of rows sampled when computing the table-level signature
/// (tier 1). Rows are taken in backend default order — rowid ascending for
/// SQLite, insertion order for InMemory. Both Swift and Rust legs use the
/// same constant so the sample window is identical regardless of platform.
///
/// The constant is `public` so MX-TAB-7's tool layer can pass it to
/// `DatasetStore.queryRows(limit:)` without hard-coding the number.
///
/// Mirrors Rust constant `DATASET_SIGNATURE_SAMPLE_SIZE` in
/// `genius_locus_kit::dataset_signatures`.
public let datasetSignatureSampleSize: Int = 128

/// Number of most-frequent values included in each column's tier-2 sketch.
///
/// Top-K values are derived from `sampledRows` (not a separate query) and
/// sorted by canonical byte representation ascending for determinism. Both
/// Swift and Rust legs must use the same K so column signatures are
/// byte-identical.
///
/// Mirrors Rust constant `DATASET_SIGNATURE_TOP_K` in
/// `genius_locus_kit::dataset_signatures`.
public let datasetSignatureTopKCount: Int = 20

// MARK: - GeniusLocusKit extension

public extension GeniusLocusKit {

    /// Compute and persist layered signatures for a dataset handle (MX-TAB-5).
    ///
    /// Derives and stores two tiers of content fingerprint in the handle's
    /// `DatasetHandleContent` JSON payload. See file header for the full
    /// architecture description.
    ///
    /// - Parameters:
    ///   - handle: Estate handle identifying the estate that owns the drawer.
    ///   - drawerId: Row id of the dataset handle drawer (`Drawer.id`).
    ///   - columns: Column schema summaries at handle-creation time. These are
    ///     the columns whose names and declared types enter the preimage. Columns
    ///     are sorted by name ascending inside the preimage computation — the
    ///     caller need not pre-sort.
    ///   - columnStats: Per-column aggregate statistics keyed by column name
    ///     (from `DatasetStore.columnStats`). Missing entries default to all-zero
    ///     stats (count=0, distinctCount=0, nullCount=0, min=null, max=null).
    ///   - sampledRows: Up to `datasetSignatureSampleSize` rows fetched from
    ///     the dataset table in backend default order (from
    ///     `DatasetStore.queryRows(limit: datasetSignatureSampleSize)`). The
    ///     exact row count is encoded in the preimage so an empty or partial
    ///     sample still produces a valid, deterministic signature.
    ///   - now: Caller-supplied timestamp (deterministic-engine rule — callers
    ///     must not call `Date()` inside engine or store methods).
    /// - Returns: The updated `Drawer` read back from storage, with
    ///   `tableSignature` and `columnSignatures` populated in its content JSON.
    /// - Throws: `LocusKitError.drawerNotFound` when `drawerId` does not exist.
    ///   `LocusKitError.invalidContent` when the stored content JSON is malformed.
    ///   `GeniusLocusKitError.estateNotOpen` when `handle` is stale.
    func computeDatasetSignatures(
        handle: EstateHandle,
        drawerId: String,
        columns: [DatasetColumnSummary],
        columnStats: [String: ColumnStats],
        sampledRows: [StorageRow],
        now: Date
    ) async throws -> Drawer {
        try requireMounted(handle, verb: "computeDatasetSignatures")
        let estate = try estate(for: handle)

        // --- Tier 1: table signature ---
        //
        // Preimage: domain tag 0x10 + column schema (sorted by name asc) +
        // sample row count + each sampled row's key-value pairs (keys sorted).
        // See DatasetSignatureComputer.tableSignaturePreimage for full detail.
        let tablePreimage = DatasetSignatureComputer.tableSignaturePreimage(
            columns: columns,
            sampledRows: sampledRows
        )
        let tableSigBytes = SHA256.hash(tablePreimage)
        let tableSignature = tableSigBytes.map { String(format: "%02x", $0) }.joined()

        // --- Tier 2: per-column signatures ---
        //
        // Preimage: domain tag 0x11 + column name + declared type + stats fields
        // (count, distinctCount, nullCount, min, max) + top-K most-frequent
        // values from sampledRows (sorted by canonical bytes asc for determinism).
        // Top-K is derived from sampledRows, not a separate query.
        var colSignatures: [String: String] = [:]
        for col in columns {
            // Default to all-zero stats when the caller omits a column entry.
            let stats = columnStats[col.name] ?? ColumnStats(
                count: 0, distinctCount: 0, nullCount: 0,
                min: .null, max: .null
            )
            let topK = DatasetSignatureComputer.computeTopK(
                columnName: col.name,
                sampledRows: sampledRows,
                k: datasetSignatureTopKCount
            )
            let colPreimage = DatasetSignatureComputer.columnSignaturePreimage(
                name: col.name,
                dataType: col.dataType,
                stats: stats,
                topKValues: topK
            )
            let colSigBytes = SHA256.hash(colPreimage)
            colSignatures[col.name] = colSigBytes.map { String(format: "%02x", $0) }.joined()
        }

        // Persist both tiers to the handle drawer.
        return try await estate.patchDatasetHandleSignatures(
            rowID: drawerId,
            tableSignature: tableSignature,
            columnSignatures: colSignatures,
            now: now
        )
    }
}

// MARK: - DatasetSignatureComputer

/// Pure, stateless computation helpers for dataset signature preimages.
///
/// Extracted as a separate enum so the preimage logic can be unit-tested
/// without an actor or live storage backend. All methods are deterministic
/// given the same inputs.
///
/// Mirrors Rust module-level functions in `dataset_signatures.rs`.
enum DatasetSignatureComputer {

    // MARK: Table signature preimage

    /// Build the byte preimage for the tier-1 table signature.
    ///
    /// Format (big-endian integers throughout):
    ///
    ///   [0x10]                      1 byte  — domain tag (table signature)
    ///   u32 BE column_count         4 bytes — number of declared columns
    ///   for each column (sorted by name ascending):
    ///     u32 BE name_len           4 bytes
    ///     name UTF-8                name_len bytes
    ///     u32 BE type_len           4 bytes
    ///     type UTF-8                type_len bytes
    ///   u32 BE sample_row_count     4 bytes — actual number of sampled rows
    ///   for each sampled row (in argument order — caller supplies rows
    ///       in backend default / rowid-asc order):
    ///     u32 BE key_count          4 bytes — number of keys in this row
    ///     for each key (sorted ascending):
    ///       u32 BE key_len          4 bytes
    ///       key UTF-8               key_len bytes
    ///       canonical_value_bytes   variable — TypedValue encoding (see below)
    ///
    /// Columns are sorted by name ascending so the preimage is independent of
    /// schema declaration order. Row key-value pairs are also sorted by key
    /// ascending for the same reason (backend column order can vary).
    static func tableSignaturePreimage(
        columns: [DatasetColumnSummary],
        sampledRows: [StorageRow]
    ) -> [UInt8] {
        var out = [UInt8]()
        // Domain tag: 0x10 distinguishes from Merkle preimages (0x00–0x03).
        out.append(0x10)
        // Column schema: sort by name ascending for determinism.
        let sortedCols = columns.sorted { $0.name < $1.name }
        appendU32BE(&out, UInt32(sortedCols.count))
        for col in sortedCols {
            appendLengthPrefixedUTF8(&out, col.name)
            appendLengthPrefixedUTF8(&out, col.dataType)
        }
        // Sampled rows: count, then each row's key-value pairs (keys sorted).
        appendU32BE(&out, UInt32(sampledRows.count))
        for row in sampledRows {
            let sortedKeys = row.values.keys.sorted()
            appendU32BE(&out, UInt32(sortedKeys.count))
            for key in sortedKeys {
                appendLengthPrefixedUTF8(&out, key)
                if let value = row[key] {
                    out += canonicalValueBytes(value)
                } else {
                    out += canonicalValueBytes(.null)
                }
            }
        }
        return out
    }

    // MARK: Column signature preimage

    /// Build the byte preimage for one tier-2 column signature.
    ///
    /// Format (big-endian integers throughout):
    ///
    ///   [0x11]                      1 byte  — domain tag (column signature)
    ///   u32 BE name_len             4 bytes
    ///   name UTF-8                  name_len bytes
    ///   u32 BE type_len             4 bytes
    ///   type UTF-8                  type_len bytes
    ///   i64 BE count                8 bytes — ColumnStats.count
    ///   i64 BE distinct_count       8 bytes — ColumnStats.distinctCount
    ///   i64 BE null_count           8 bytes — ColumnStats.nullCount
    ///   canonical_value_bytes(min)  variable
    ///   canonical_value_bytes(max)  variable
    ///   u32 BE top_k_actual         4 bytes — actual top-K entries (≤ K=20)
    ///   for each top-K entry (sorted by canonical value bytes asc):
    ///     canonical_value_bytes     variable — the value
    ///     u64 BE occurrence_count   8 bytes — frequency in sampledRows
    ///
    /// Top-K entries are sorted by canonical byte representation ascending
    /// (not by frequency) so the preimage is independent of hash-map iteration
    /// order and produces identical bytes on every run.
    static func columnSignaturePreimage(
        name: String,
        dataType: String,
        stats: ColumnStats,
        topKValues: [(value: TypedValue, count: UInt64)]
    ) -> [UInt8] {
        var out = [UInt8]()
        // Domain tag: 0x11 distinguishes column from table (0x10) preimages.
        out.append(0x11)
        appendLengthPrefixedUTF8(&out, name)
        appendLengthPrefixedUTF8(&out, dataType)
        appendI64BE(&out, stats.count)
        appendI64BE(&out, stats.distinctCount)
        appendI64BE(&out, stats.nullCount)
        out += canonicalValueBytes(stats.min)
        out += canonicalValueBytes(stats.max)
        // Sort top-K entries by canonical byte representation ascending for
        // determinism. Frequency order is intentionally discarded here so the
        // preimage is stable regardless of hash-map or sort instability.
        let sorted = topKValues.sorted { a, b in
            canonicalValueBytes(a.value).lexicographicallyPrecedes(
                canonicalValueBytes(b.value)
            )
        }
        appendU32BE(&out, UInt32(sorted.count))
        for entry in sorted {
            out += canonicalValueBytes(entry.value)
            appendU64BE(&out, entry.count)
        }
        return out
    }

    // MARK: Top-K computation

    /// Derive the top-K most-frequent values for `columnName` from
    /// `sampledRows`.
    ///
    /// Uses only the already-fetched sample — no additional query is issued.
    /// When multiple values tie for the K-th frequency rank, tie-breaking is
    /// by canonical byte representation ascending (same order as the preimage
    /// sort), producing a deterministic K-entry set for any fixed sample.
    ///
    /// - Parameters:
    ///   - columnName: The column to tally. Rows missing this key are skipped
    ///     (treated as absent, not null).
    ///   - sampledRows: Pre-fetched sample rows from `DatasetStore.queryRows`.
    ///   - k: Maximum number of entries to return (`datasetSignatureTopKCount`).
    /// - Returns: Up to `k` (value, frequency) pairs, frequency descending,
    ///   ties broken by canonical bytes ascending.
    static func computeTopK(
        columnName: String,
        sampledRows: [StorageRow],
        k: Int
    ) -> [(value: TypedValue, count: UInt64)] {
        // Tally frequencies using canonical byte representation as the key.
        // Canonical bytes are used (not value equality) for two reasons:
        //   1. TypedValue is not Hashable across all cases.
        //   2. The canonical bytes already encode the type tag, so distinct
        //      types never collide (e.g. .int(1) ≠ .float(1.0)).
        var tally: [ArraySliceKey: (value: TypedValue, count: UInt64)] = [:]
        for row in sampledRows {
            guard let value = row[columnName] else { continue }
            let key = ArraySliceKey(bytes: canonicalValueBytes(value))
            if var existing = tally[key] {
                existing.count += 1
                tally[key] = existing
            } else {
                tally[key] = (value: value, count: 1)
            }
        }
        // Sort: frequency descending; ties broken by canonical bytes ascending.
        let sorted = tally.values.sorted { a, b in
            if a.count != b.count { return a.count > b.count }
            return canonicalValueBytes(a.value).lexicographicallyPrecedes(
                canonicalValueBytes(b.value)
            )
        }
        return Array(sorted.prefix(k))
    }

    // MARK: Canonical value bytes

    /// Encode a `TypedValue` to its canonical byte representation.
    ///
    /// The encoding is a type tag followed by a value-specific payload.
    /// Big-endian integers throughout for cross-platform parity.
    ///
    /// Tag assignments:
    ///   0x00  null
    ///   0x01  bool   — 1 payload byte (0x01 = true, 0x00 = false)
    ///   0x02  int    — 8 bytes i64 BE
    ///   0x03  bitmap — 8 bytes i64 BE (same wire as int; tag is distinct)
    ///   0x04  float  — 8 bytes u64 BE (f64.bitPattern; NaN bit-patterns
    ///                  are preserved — two NaN values are only equal if they
    ///                  have identical bit patterns, which is correct for a
    ///                  content fingerprint)
    ///   0x05  text   — u32 BE length + UTF-8 bytes
    ///   0x06  blob   — u32 BE length + raw bytes
    ///   0x07  uuid   — 16 bytes in RFC 4122 byte order (big-endian)
    ///   0x08  timestamp — 8 bytes i64 BE (seconds since Unix epoch,
    ///                     truncated; see note below)
    ///   0x09  json   — u32 BE length + raw JSON bytes
    ///   0x0A  hlc    — 8 bytes u64 BE (HLC.packed)
    ///   0x0B  fingerprint — 32 bytes (Fingerprint256.toBytes())
    ///   0x0C  array  — u32 BE element count + recursive encoding
    ///
    /// Timestamp note: Swift `Date.timeIntervalSince1970` is truncated to
    /// `Int64` (seconds). Rust `TypedValue::Timestamp(i64)` stores the same
    /// i64 precision. Sub-second values are lost. In practice, dataset rows
    /// use INTEGER / TEXT / REAL column types; timestamp values in dataset
    /// tables are uncommon in v1. The encoding is correct for the parity
    /// tests, which use only .null, .int, .float, and .text fixtures.
    ///
    /// Mirrors Rust `canonical_value_bytes` in `dataset_signatures.rs`.
    static func canonicalValueBytes(_ value: TypedValue) -> [UInt8] {
        var out = [UInt8]()
        switch value {
        case .null:
            out.append(0x00)

        case .bool(let b):
            out.append(0x01)
            out.append(b ? 0x01 : 0x00)

        case .int(let i):
            out.append(0x02)
            appendI64BE(&out, i)

        case .bitmap(let i):
            // Same wire encoding as .int but distinct tag (0x03 vs 0x02)
            // so int(7) ≠ bitmap(7) in the fingerprint.
            out.append(0x03)
            appendI64BE(&out, i)

        case .float(let d):
            // f64 bit-pattern as u64 BE — matches Rust f64::to_bits().to_be_bytes().
            // NaN bit-patterns are preserved exactly so two distinct NaN payloads
            // hash differently (correct for content fingerprints).
            out.append(0x04)
            appendU64BE(&out, d.bitPattern)

        case .text(let s):
            out.append(0x05)
            let bytes = Array(s.utf8)
            appendU32BE(&out, UInt32(bytes.count))
            out += bytes

        case .blob(let data):
            out.append(0x06)
            let bytes = [UInt8](data)
            appendU32BE(&out, UInt32(bytes.count))
            out += bytes

        case .uuid(let u):
            // RFC 4122 big-endian 16 bytes. Swift UUID.uuid is a tuple
            // of 16 UInt8 values in big-endian field order.
            out.append(0x07)
            let m = u.uuid
            out += [m.0, m.1, m.2, m.3, m.4, m.5, m.6, m.7,
                    m.8, m.9, m.10, m.11, m.12, m.13, m.14, m.15]

        case .timestamp(let d):
            // Encode as i64 seconds since Unix epoch (truncated). Sub-second
            // precision is lost; see the full note in the function doc comment.
            out.append(0x08)
            appendI64BE(&out, Int64(d.timeIntervalSince1970))

        case .json(let data):
            out.append(0x09)
            let bytes = [UInt8](data)
            appendU32BE(&out, UInt32(bytes.count))
            out += bytes

        case .hlc(let h):
            // HLC.packed is u64 (physicalTime in lower 40 bits, logicalCount
            // in bits 40–55, nodeID in bits 56–63). Big-endian 8 bytes.
            out.append(0x0A)
            appendU64BE(&out, h.packed)

        case .fingerprint(let f):
            out.append(0x0B)
            out += f.toBytes()

        case .array(let elements):
            out.append(0x0C)
            appendU32BE(&out, UInt32(elements.count))
            for elem in elements {
                out += canonicalValueBytes(elem)
            }
        }
        return out
    }

    // MARK: - Byte helpers (big-endian, no Foundation dependency)

    private static func appendU32BE(_ out: inout [UInt8], _ v: UInt32) {
        out.append(UInt8((v >> 24) & 0xFF))
        out.append(UInt8((v >> 16) & 0xFF))
        out.append(UInt8((v >> 8)  & 0xFF))
        out.append(UInt8(v         & 0xFF))
    }

    private static func appendU64BE(_ out: inout [UInt8], _ v: UInt64) {
        out.append(UInt8((v >> 56) & 0xFF))
        out.append(UInt8((v >> 48) & 0xFF))
        out.append(UInt8((v >> 40) & 0xFF))
        out.append(UInt8((v >> 32) & 0xFF))
        out.append(UInt8((v >> 24) & 0xFF))
        out.append(UInt8((v >> 16) & 0xFF))
        out.append(UInt8((v >> 8)  & 0xFF))
        out.append(UInt8(v         & 0xFF))
    }

    private static func appendI64BE(_ out: inout [UInt8], _ v: Int64) {
        appendU64BE(&out, UInt64(bitPattern: v))
    }

    /// Append a u32-BE length prefix followed by the string's UTF-8 bytes.
    private static func appendLengthPrefixedUTF8(_ out: inout [UInt8], _ s: String) {
        let bytes = Array(s.utf8)
        appendU32BE(&out, UInt32(bytes.count))
        out += bytes
    }
}

// MARK: - ArraySliceKey (private hash helper)

/// Hashable wrapper for `[UInt8]` used as a dictionary key in `computeTopK`.
///
/// Swift does not conform `[UInt8]` to `Hashable` directly usable as a
/// dict key without a wrapper. This type hashes the byte array content.
private struct ArraySliceKey: Hashable {
    let bytes: [UInt8]
}
