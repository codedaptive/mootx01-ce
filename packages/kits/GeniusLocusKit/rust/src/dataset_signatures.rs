//! dataset_signatures.rs — MX-TAB-5 layered dataset signatures (Rust port).
//!
//! Byte-identical mirror of
//! `GeniusLocusKit/Sources/GeniusLocusKit/Intake/DatasetSignatures.swift`.
//!
//! ## Architecture
//!
//! Two tiers of content fingerprint are computed and stored in the dataset
//! handle's `DatasetHandleContent` JSON payload:
//!
//!   **Tier 1 (table):** One SHA-256 over the dataset schema (column names and
//!   declared types, sorted ascending) concatenated with up to
//!   `DATASET_SIGNATURE_SAMPLE_SIZE` (128) sampled rows in backend default
//!   order. Domain tag `0x10` distinguishes this preimage from Merkle
//!   node/leaf preimages (`0x00`–`0x03`). Stored in
//!   `DatasetHandleContent::table_signature`.
//!
//!   **Tier 2 (column):** One SHA-256 per column over (name, declared type,
//!   value-distribution sketch). The sketch: distinct count, null count, min,
//!   max from `ColumnStats`, plus top-`DATASET_SIGNATURE_TOP_K` (20)
//!   most-frequent values derived from `sampled_rows`. Domain tag `0x11`.
//!   Stored in `DatasetHandleContent::column_signatures` keyed by column name.
//!
//! ## Why SHA-256 / reuse rationale
//!
//! The existing codebase already uses `substrate_kernel::sha256::hash` for
//! content-addressing audit log entries (cookbook §5.1). The same FIPS 180-4
//! primitive produces byte-identical output across Swift and Rust legs — the
//! conformance harness gates this four ways. Domain tags (`0x10`/`0x11`)
//! isolate these preimages from the Merkle scheme's (`0x00`–`0x03`) without
//! requiring a separate primitive.
//!
//! ## No row fingerprints (MX-TABULAR open question 1, resolved)
//!
//! Individual row fingerprints are explicitly out of scope. This module
//! operates on pre-fetched `sampled_rows` passed by the tool layer (MX-TAB-7),
//! keeping query overhead under caller control.
//!
//! ## Call contract for MX-TAB-7
//!
//! ```text
//! // Fetch the sample (at most DATASET_SIGNATURE_SAMPLE_SIZE rows).
//! let sampled_rows = dataset_store.query_rows(
//!     dataset_id, None, &[], Some(DATASET_SIGNATURE_SAMPLE_SIZE), None, None
//! )?;
//! let stats_by_col = columns.iter()
//!     .map(|c| Ok((c.name.clone(), dataset_store.column_stats(dataset_id, &c.name)?)))
//!     .collect::<Result<_, _>>()?;
//! let updated_drawer = compute_dataset_signatures(
//!     &estate, &drawer_id, &columns, &stats_by_col, &sampled_rows
//! )?;
//! ```

use locus_kit::dataset_handle::DatasetColumnSummary;
use locus_kit::drawer::Drawer;
use locus_kit::error::LocusKitError;
use locus_kit::estate::Estate;
use persistence_kit::types::{StorageRow, TypedValue};
use std::collections::{BTreeMap, HashMap};
use substrate_kernel::sha256::hash as sha256_hash;
use substrate_types::{Fingerprint256, HLC};

// ColumnStats is in persistence_kit
use persistence_kit::dataset_store::ColumnStats;

// MARK: - Sampling and sketch constants

/// Maximum number of rows sampled when computing the table-level signature
/// (tier 1). Rows are taken in backend default order — rowid ascending for
/// SQLite. Both Swift and Rust legs use the same constant so the sample
/// window is identical regardless of platform.
///
/// Mirrors Swift `datasetSignatureSampleSize` in `DatasetSignatures.swift`.
pub const DATASET_SIGNATURE_SAMPLE_SIZE: usize = 128;

/// Number of most-frequent values included in each column's tier-2 sketch.
///
/// Top-K values are derived from `sampled_rows` (not a separate query) and
/// sorted by canonical byte representation ascending for determinism. Both
/// legs must use the same K so column signatures are byte-identical.
///
/// Mirrors Swift `datasetSignatureTopKCount` in `DatasetSignatures.swift`.
pub const DATASET_SIGNATURE_TOP_K: usize = 20;

// MARK: - Public entry point

/// Compute and persist layered signatures for a dataset handle (MX-TAB-5).
///
/// Computes a tier-1 table signature (schema + sampled content) and one
/// tier-2 column signature per declared column, then calls
/// `Estate::patch_dataset_handle_signatures` to persist both tiers into
/// the handle's `DatasetHandleContent` JSON.
///
/// Mirrors Swift `GeniusLocusKit.computeDatasetSignatures(...)` in
/// `DatasetSignatures.swift`.
///
/// - `estate`: The LocusKit estate that owns the dataset handle drawer.
/// - `drawer_id`: Row id of the dataset handle drawer.
/// - `columns`: Column schema summaries at handle-creation time. Sorted
///   ascending by name inside the preimage computation.
/// - `column_stats`: Per-column aggregate statistics keyed by column name.
///   Missing entries are treated as all-zero stats.
/// - `sampled_rows`: Up to `DATASET_SIGNATURE_SAMPLE_SIZE` rows fetched from
///   the dataset table in backend default order.
pub fn compute_dataset_signatures(
    estate: &Estate,
    drawer_id: &str,
    columns: &[DatasetColumnSummary],
    column_stats: &HashMap<String, ColumnStats>,
    sampled_rows: &[StorageRow],
) -> Result<Drawer, LocusKitError> {
    // --- Tier 1: table signature ---
    //
    // Preimage: domain tag 0x10 + column schema (sorted by name asc) +
    // sample row count + each sampled row's key-value pairs (keys sorted).
    let table_preimage = table_signature_preimage(columns, sampled_rows);
    let table_sig_bytes = sha256_hash(&table_preimage);
    let table_signature = hex_encode(&table_sig_bytes);

    // --- Tier 2: per-column signatures ---
    //
    // Preimage: domain tag 0x11 + column name + declared type + stats fields
    // (count, distinct_count, null_count, min, max) + top-K most-frequent
    // values from sampled_rows (sorted by canonical bytes asc for determinism).
    let mut col_signatures: HashMap<String, String> = HashMap::new();
    for col in columns {
        let zero_stats = ColumnStats {
            count: 0,
            distinct_count: 0,
            null_count: 0,
            min: TypedValue::Null,
            max: TypedValue::Null,
        };
        let stats = column_stats.get(&col.name).unwrap_or(&zero_stats);
        let top_k = compute_top_k(&col.name, sampled_rows, DATASET_SIGNATURE_TOP_K);
        let col_preimage =
            column_signature_preimage(&col.name, &col.data_type, stats, &top_k);
        let col_sig_bytes = sha256_hash(&col_preimage);
        col_signatures.insert(col.name.clone(), hex_encode(&col_sig_bytes));
    }

    // Persist both tiers to the handle drawer.
    estate.patch_dataset_handle_signatures(drawer_id, &table_signature, col_signatures)
}

// MARK: - Preimage builders

/// Build the byte preimage for the tier-1 table signature.
///
/// Format (big-endian integers throughout):
///
///   `0x10`                      1 byte  — domain tag (table signature)
///   u32 BE column_count         4 bytes — number of declared columns
///   for each column (sorted by name ascending):
///     u32 BE name_len           4 bytes
///     name UTF-8                name_len bytes
///     u32 BE type_len           4 bytes
///     type UTF-8                type_len bytes
///   u32 BE sample_row_count     4 bytes — actual number of sampled rows
///   for each sampled row (in argument order):
///     u32 BE key_count          4 bytes
///     for each key (sorted ascending):
///       u32 BE key_len          4 bytes
///       key UTF-8               key_len bytes
///       canonical_value_bytes   variable
///
/// Mirrors Swift `DatasetSignatureComputer.tableSignaturePreimage` in
/// `DatasetSignatures.swift`.
pub fn table_signature_preimage(
    columns: &[DatasetColumnSummary],
    sampled_rows: &[StorageRow],
) -> Vec<u8> {
    let mut out = Vec::new();
    // Domain tag: 0x10 distinguishes from Merkle preimages (0x00–0x03).
    out.push(0x10);
    // Column schema: sort by name ascending for determinism.
    let mut sorted_cols: Vec<&DatasetColumnSummary> = columns.iter().collect();
    sorted_cols.sort_by(|a, b| a.name.cmp(&b.name));
    append_u32_be(&mut out, sorted_cols.len() as u32);
    for col in &sorted_cols {
        append_length_prefixed_utf8(&mut out, &col.name);
        append_length_prefixed_utf8(&mut out, &col.data_type);
    }
    // Sampled rows: count, then each row's key-value pairs (keys sorted).
    append_u32_be(&mut out, sampled_rows.len() as u32);
    for row in sampled_rows {
        let mut sorted_keys: Vec<&str> = row.values.keys().map(|s| s.as_str()).collect();
        sorted_keys.sort();
        append_u32_be(&mut out, sorted_keys.len() as u32);
        for key in sorted_keys {
            append_length_prefixed_utf8(&mut out, key);
            let value = row.values.get(key).unwrap_or(&TypedValue::Null);
            out.extend_from_slice(&canonical_value_bytes(value));
        }
    }
    out
}

/// Build the byte preimage for one tier-2 column signature.
///
/// Format (big-endian integers throughout):
///
///   `0x11`                      1 byte  — domain tag (column signature)
///   u32 BE name_len             4 bytes
///   name UTF-8                  name_len bytes
///   u32 BE type_len             4 bytes
///   type UTF-8                  type_len bytes
///   i64 BE count                8 bytes — ColumnStats.count
///   i64 BE distinct_count       8 bytes — ColumnStats.distinct_count
///   i64 BE null_count           8 bytes — ColumnStats.null_count
///   canonical_value_bytes(min)  variable
///   canonical_value_bytes(max)  variable
///   u32 BE top_k_actual         4 bytes — actual entries (≤ K=20)
///   for each top-K entry (sorted by canonical value bytes asc):
///     canonical_value_bytes     variable — the value
///     u64 BE occurrence_count   8 bytes — frequency in sampled_rows
///
/// Mirrors Swift `DatasetSignatureComputer.columnSignaturePreimage` in
/// `DatasetSignatures.swift`.
pub fn column_signature_preimage(
    name: &str,
    data_type: &str,
    stats: &ColumnStats,
    top_k_values: &[(TypedValue, u64)],
) -> Vec<u8> {
    let mut out = Vec::new();
    // Domain tag: 0x11 distinguishes column from table (0x10) preimages.
    out.push(0x11);
    append_length_prefixed_utf8(&mut out, name);
    append_length_prefixed_utf8(&mut out, data_type);
    append_i64_be(&mut out, stats.count);
    append_i64_be(&mut out, stats.distinct_count);
    append_i64_be(&mut out, stats.null_count);
    out.extend_from_slice(&canonical_value_bytes(&stats.min));
    out.extend_from_slice(&canonical_value_bytes(&stats.max));
    // Sort top-K entries by canonical byte representation ascending for
    // determinism. Frequency order is discarded at this stage so the
    // preimage is stable regardless of hash-map or sort instability.
    let mut sorted_top_k: Vec<&(TypedValue, u64)> = top_k_values.iter().collect();
    sorted_top_k.sort_by(|a, b| {
        canonical_value_bytes(&a.0).cmp(&canonical_value_bytes(&b.0))
    });
    append_u32_be(&mut out, sorted_top_k.len() as u32);
    for (value, count) in sorted_top_k {
        out.extend_from_slice(&canonical_value_bytes(value));
        append_u64_be(&mut out, *count);
    }
    out
}

// MARK: - Top-K computation

/// Derive the top-K most-frequent values for `column_name` from `sampled_rows`.
///
/// Uses only the already-fetched sample — no additional query is issued.
/// When multiple values tie for the K-th rank, tie-breaking is by canonical
/// byte representation ascending (same order as the preimage sort), producing
/// a deterministic K-entry set for any fixed sample.
///
/// Rows missing `column_name` are silently skipped (not counted as null).
///
/// Mirrors Swift `DatasetSignatureComputer.computeTopK` in
/// `DatasetSignatures.swift`.
pub fn compute_top_k(
    column_name: &str,
    sampled_rows: &[StorageRow],
    k: usize,
) -> Vec<(TypedValue, u64)> {
    // Tally frequencies using canonical byte representation as the key.
    // Canonical bytes encode the type tag, so distinct types never collide.
    let mut tally: BTreeMap<Vec<u8>, (TypedValue, u64)> = BTreeMap::new();
    for row in sampled_rows {
        if let Some(value) = row.values.get(column_name) {
            let key = canonical_value_bytes(value);
            let entry = tally.entry(key).or_insert_with(|| (value.clone(), 0));
            entry.1 += 1;
        }
    }
    // Sort: frequency descending; ties broken by canonical bytes ascending.
    let mut sorted: Vec<(TypedValue, u64)> = tally.into_values().collect();
    sorted.sort_by(|a, b| {
        if a.1 != b.1 {
            return b.1.cmp(&a.1); // frequency descending
        }
        // tie-break by canonical bytes ascending
        canonical_value_bytes(&a.0).cmp(&canonical_value_bytes(&b.0))
    });
    sorted.truncate(k);
    sorted
}

// MARK: - Canonical value bytes

/// Encode a `TypedValue` to its canonical byte representation.
///
/// The encoding is a type tag followed by a value-specific payload.
/// Big-endian integers throughout for cross-platform parity with Swift.
///
/// Tag assignments (must match Swift `DatasetSignatureComputer.canonicalValueBytes`):
///   `0x00`  Null
///   `0x01`  Bool   — 1 payload byte (0x01 = true, 0x00 = false)
///   `0x02`  Int    — 8 bytes i64 BE
///   `0x03`  Bitmap — 8 bytes i64 BE (same wire as Int; tag is distinct)
///   `0x04`  Float  — 8 bytes u64 BE (f64.to_bits() big-endian)
///   `0x05`  Text   — u32 BE length + UTF-8 bytes
///   `0x06`  Blob   — u32 BE length + raw bytes
///   `0x07`  Uuid   — 16 bytes in RFC 4122 byte order
///   `0x08`  Timestamp — 8 bytes i64 BE (the stored i64 value directly)
///   `0x09`  Json   — u32 BE length + raw bytes
///   `0x0A`  Hlc    — 8 bytes u64 BE (HLC packed value)
///   `0x0B`  Fingerprint — 32 bytes
///   `0x0C`  Array  — u32 BE element count + recursive encoding
///
/// Mirrors Swift `DatasetSignatureComputer.canonicalValueBytes` in
/// `DatasetSignatures.swift`.
pub fn canonical_value_bytes(value: &TypedValue) -> Vec<u8> {
    let mut out = Vec::new();
    match value {
        TypedValue::Null => {
            out.push(0x00);
        }
        TypedValue::Bool(b) => {
            out.push(0x01);
            out.push(if *b { 0x01 } else { 0x00 });
        }
        TypedValue::Int(i) => {
            out.push(0x02);
            append_i64_be(&mut out, *i);
        }
        TypedValue::Bitmap(i) => {
            // Same wire as Int but distinct tag (0x03 vs 0x02) so
            // Int(7) ≠ Bitmap(7) in the fingerprint.
            out.push(0x03);
            append_i64_be(&mut out, *i);
        }
        TypedValue::Float(f) => {
            // f64 bit-pattern as u64 BE — matches Swift f64.bitPattern big-endian.
            // NaN bit-patterns are preserved exactly.
            out.push(0x04);
            append_u64_be(&mut out, f.to_bits());
        }
        TypedValue::Text(s) => {
            out.push(0x05);
            let bytes = s.as_bytes();
            append_u32_be(&mut out, bytes.len() as u32);
            out.extend_from_slice(bytes);
        }
        TypedValue::Blob(b) => {
            out.push(0x06);
            append_u32_be(&mut out, b.len() as u32);
            out.extend_from_slice(b);
        }
        TypedValue::Uuid(u) => {
            // RFC 4122 big-endian 16 bytes. `uuid::Uuid::as_bytes()` returns
            // the 16 bytes in RFC 4122 field order, matching Swift's `uuid.uuid`.
            out.push(0x07);
            out.extend_from_slice(u.as_bytes());
        }
        TypedValue::Timestamp(i) => {
            // The Rust Timestamp is an i64 stored directly (seconds since epoch
            // in the persistence layer). Swift truncates Date.timeIntervalSince1970
            // to i64 seconds. Both legs produce the same bytes from the same stored
            // integer. See timestamp note in the Swift equivalent.
            out.push(0x08);
            append_i64_be(&mut out, *i);
        }
        TypedValue::Json(b) => {
            out.push(0x09);
            append_u32_be(&mut out, b.len() as u32);
            out.extend_from_slice(b);
        }
        TypedValue::Hlc(h) => {
            // HLC packed as u64 BE. Mirrors Swift `h.packed` (u64).
            out.push(0x0A);
            append_u64_be(&mut out, hlc_packed(h));
        }
        TypedValue::Fingerprint(f) => {
            out.push(0x0B);
            out.extend_from_slice(&fingerprint_bytes(f));
        }
        TypedValue::Array(elements) => {
            out.push(0x0C);
            append_u32_be(&mut out, elements.len() as u32);
            for elem in elements {
                out.extend_from_slice(&canonical_value_bytes(elem));
            }
        }
    }
    out
}

// MARK: - Byte helpers (big-endian)

fn append_u32_be(out: &mut Vec<u8>, v: u32) {
    out.push((v >> 24) as u8);
    out.push((v >> 16) as u8);
    out.push((v >> 8) as u8);
    out.push(v as u8);
}

fn append_u64_be(out: &mut Vec<u8>, v: u64) {
    out.push((v >> 56) as u8);
    out.push((v >> 48) as u8);
    out.push((v >> 40) as u8);
    out.push((v >> 32) as u8);
    out.push((v >> 24) as u8);
    out.push((v >> 16) as u8);
    out.push((v >> 8) as u8);
    out.push(v as u8);
}

fn append_i64_be(out: &mut Vec<u8>, v: i64) {
    append_u64_be(out, v as u64);
}

/// Append a u32-BE length prefix followed by the string's UTF-8 bytes.
fn append_length_prefixed_utf8(out: &mut Vec<u8>, s: &str) {
    let bytes = s.as_bytes();
    append_u32_be(out, bytes.len() as u32);
    out.extend_from_slice(bytes);
}

fn hex_encode(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{:02x}", b)).collect()
}

/// Extract the packed u64 from an HLC value.
///
/// HLC wire format: physical time in the lower 40 bits, logical count in
/// bits 40–55, node ID in bits 56–63. Matches Swift's `HLC.packed: UInt64`.
fn hlc_packed(h: &HLC) -> u64 {
    // The HLC struct fields: physicalTime (i64), logicalCount (i32), nodeID (i32).
    // Packed form: node (8 bits, truncated) | logical (16 bits, truncated) | phys (40 bits).
    let node = (h.node_id as u64 & 0xFF) << 56;
    let logical = ((h.logical_count as u64) & 0xFFFF) << 40;
    let phys = (h.physical_time as u64) & 0xFF_FFFF_FFFF;
    node | logical | phys
}

/// Extract the 32-byte wire representation from a Fingerprint256.
///
/// Uses `wire_bytes()` which is the Rust equivalent of Swift's `toBytes()`
/// (which returns `self.wireBytes`). Both produce the same 32-byte sequence.
fn fingerprint_bytes(f: &Fingerprint256) -> [u8; 32] {
    f.wire_bytes()
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use persistence_kit::dataset_store::ColumnStats;
    use persistence_kit::types::{StorageRow, TypedValue};
    use std::collections::BTreeMap;

    // MARK: - Cross-leg anchor hex constants (test-only)
    //
    // These hex strings are the expected SHA-256 output for the fixed anchor
    // fixture (one column "n" INTEGER, zero rows, all-zero stats).
    //
    // They are locked for cross-leg regression: the Swift counterpart in
    // `DatasetSignatureTests.DatasetSignatureAnchors` must equal these strings.
    // Do NOT update without also updating the Swift counterpart and documenting
    // the change in the commit message.

    /// SHA-256 of the 25-byte table anchor preimage (traced in
    /// `anchor_table_preimage_bytes`). Mirrors Swift `tableHex`.
    ///
    /// Established by running the Rust test to obtain the actual hash, then
    /// locking both legs. Do NOT update without also updating the Swift
    /// counterpart `DatasetSignatureAnchors.tableHex`.
    const ANCHOR_TABLE_SIG_HEX: &str =
        "29078b656d47f2be5f6b30917265db16116fac4f2f207049a92e1d48cf5b832b";

    /// SHA-256 of the 47-byte column anchor preimage (traced in
    /// `anchor_column_preimage_bytes`). Mirrors Swift `columnHex`.
    ///
    /// Established by running the Rust test to obtain the actual hash, then
    /// locking both legs. Do NOT update without also updating the Swift
    /// counterpart `DatasetSignatureAnchors.columnHex`.
    const ANCHOR_COLUMN_SIG_HEX: &str =
        "8280ce98f78f9324c28c38412f0de3bd14cdf9669c2aec80871919574bccfb05";

    // MARK: - Anchor preimage tests

    /// Verify the table signature preimage byte layout for the cross-leg anchor.
    ///
    /// Fixture: columns=[{name:"n", dataType:"INTEGER"}], sampled_rows=[].
    ///
    /// This is the Rust mirror of `DatasetSignatureTests.anchorTablePreimageBytes`
    /// in Swift. Both tests assert the same 25-byte sequence.
    #[test]
    fn anchor_table_preimage_bytes() {
        let cols = vec![DatasetColumnSummary {
            name: "n".to_string(),
            data_type: "INTEGER".to_string(),
        }];
        let preimage = table_signature_preimage(&cols, &[]);
        let expected: Vec<u8> = vec![
            0x10,                                          // domain tag
            0x00, 0x00, 0x00, 0x01,                        // column count = 1
            0x00, 0x00, 0x00, 0x01,                        // "n" length = 1
            0x6E,                                          // 'n'
            0x00, 0x00, 0x00, 0x07,                        // "INTEGER" length = 7
            0x49, 0x4E, 0x54, 0x45, 0x47, 0x45, 0x52,     // "INTEGER"
            0x00, 0x00, 0x00, 0x00,                        // sample_row_count = 0
        ];
        assert_eq!(preimage, expected, "table anchor preimage must match documented layout");
    }

    /// Verify the column signature preimage byte layout for the cross-leg anchor.
    ///
    /// Fixture: name="n", dataType="INTEGER", stats=all-zero, top_k=[].
    ///
    /// This is the Rust mirror of `DatasetSignatureTests.anchorColumnPreimageBytes`
    /// in Swift. Both tests assert the same 47-byte sequence.
    #[test]
    fn anchor_column_preimage_bytes() {
        let stats = ColumnStats {
            count: 0,
            distinct_count: 0,
            null_count: 0,
            min: TypedValue::Null,
            max: TypedValue::Null,
        };
        let preimage = column_signature_preimage("n", "INTEGER", &stats, &[]);
        let expected: Vec<u8> = vec![
            0x11,                                              // domain tag
            0x00, 0x00, 0x00, 0x01,                            // "n" length = 1
            0x6E,                                              // 'n'
            0x00, 0x00, 0x00, 0x07,                            // "INTEGER" length = 7
            0x49, 0x4E, 0x54, 0x45, 0x47, 0x45, 0x52,         // "INTEGER"
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,   // count = 0
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,   // distinct_count = 0
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,   // null_count = 0
            0x00,                                              // min = null
            0x00,                                              // max = null
            0x00, 0x00, 0x00, 0x00,                            // top_k_actual = 0
        ];
        assert_eq!(preimage, expected, "column anchor preimage must match documented layout");
    }

    // MARK: - Cross-leg anchor: SHA-256 of fixed preimage

    /// Assert the SHA-256 of the table anchor preimage equals the hardcoded
    /// expected hex. The Swift counterpart in `DatasetSignatureTests.swift`
    /// asserts the same hex string from the same preimage bytes.
    ///
    /// If this test fails after a preimage change, both legs must be updated
    /// together and the commit message must document the change.
    #[test]
    fn cross_leg_anchor_table_hash() {
        // 25-byte anchor preimage (see anchor_table_preimage_bytes for the layout).
        let preimage: Vec<u8> = vec![
            0x10,
            0x00, 0x00, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x01,
            0x6E,
            0x00, 0x00, 0x00, 0x07,
            0x49, 0x4E, 0x54, 0x45, 0x47, 0x45, 0x52,
            0x00, 0x00, 0x00, 0x00,
        ];
        let digest = sha256_hash(&preimage);
        let hex: String = digest.iter().map(|b| format!("{:02x}", b)).collect();
        assert_eq!(hex, ANCHOR_TABLE_SIG_HEX,
            "SHA-256 of table anchor preimage must equal the locked cross-leg hex");
    }

    /// Assert the SHA-256 of the column anchor preimage equals the hardcoded
    /// expected hex. The Swift counterpart asserts the same hex.
    #[test]
    fn cross_leg_anchor_column_hash() {
        // 47-byte anchor preimage (see anchor_column_preimage_bytes for the layout).
        let preimage: Vec<u8> = vec![
            0x11,
            0x00, 0x00, 0x00, 0x01,
            0x6E,
            0x00, 0x00, 0x00, 0x07,
            0x49, 0x4E, 0x54, 0x45, 0x47, 0x45, 0x52,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00,
            0x00,
            0x00, 0x00, 0x00, 0x00,
        ];
        let digest = sha256_hash(&preimage);
        let hex: String = digest.iter().map(|b| format!("{:02x}", b)).collect();
        assert_eq!(hex, ANCHOR_COLUMN_SIG_HEX,
            "SHA-256 of column anchor preimage must equal the locked cross-leg hex");
    }

    // MARK: - Canonical value bytes spot-checks

    #[test]
    fn canonical_null_is_single_zero() {
        assert_eq!(canonical_value_bytes(&TypedValue::Null), vec![0x00]);
    }

    #[test]
    fn canonical_bool_tags_and_values() {
        assert_eq!(canonical_value_bytes(&TypedValue::Bool(true)),  vec![0x01, 0x01]);
        assert_eq!(canonical_value_bytes(&TypedValue::Bool(false)), vec![0x01, 0x00]);
    }

    #[test]
    fn canonical_int_one_is_nine_bytes() {
        let bytes = canonical_value_bytes(&TypedValue::Int(1));
        assert_eq!(bytes.len(), 9, "tag(1) + i64(8) = 9 bytes");
        assert_eq!(bytes[0], 0x02, "int tag must be 0x02");
        assert_eq!(bytes[8], 0x01, "last byte of i64(1) BE must be 0x01");
        assert!(bytes[1..8].iter().all(|&b| b == 0x00),
            "upper 7 bytes of i64(1) must be 0x00");
    }

    #[test]
    fn canonical_int_and_bitmap_use_distinct_tags() {
        let int_bytes    = canonical_value_bytes(&TypedValue::Int(7));
        let bitmap_bytes = canonical_value_bytes(&TypedValue::Bitmap(7));
        assert_eq!(int_bytes[0],    0x02, "int tag must be 0x02");
        assert_eq!(bitmap_bytes[0], 0x03, "bitmap tag must be 0x03");
        assert_ne!(int_bytes, bitmap_bytes, "Int(7) and Bitmap(7) must differ");
    }

    #[test]
    fn canonical_float_one_uses_f64_bit_pattern() {
        // 1.0 f64 bit-pattern = 0x3FF0000000000000
        let bytes = canonical_value_bytes(&TypedValue::Float(1.0));
        assert_eq!(bytes.len(), 9, "tag(1) + u64(8) = 9 bytes");
        assert_eq!(bytes[0], 0x04, "float tag must be 0x04");
        assert_eq!(bytes[1], 0x3F, "first byte of f64(1.0) bit-pattern BE must be 0x3F");
        assert_eq!(bytes[2], 0xF0, "second byte must be 0xF0");
    }

    #[test]
    fn canonical_text_hi_exact_bytes() {
        // "hi" UTF-8 = [0x68, 0x69]
        let bytes = canonical_value_bytes(&TypedValue::Text("hi".to_string()));
        assert_eq!(bytes, vec![0x05, 0x00, 0x00, 0x00, 0x02, 0x68, 0x69]);
    }

    // MARK: - Top-K computation

    #[test]
    fn top_k_capped_at_k() {
        let rows: Vec<StorageRow> = (0i64..30)
            .map(|i| {
                let mut v = BTreeMap::new();
                v.insert("v".to_string(), TypedValue::Int(i));
                StorageRow { values: v }
            })
            .collect();
        let top_k = compute_top_k("v", &rows, 5);
        assert!(top_k.len() <= 5, "top-K must not exceed k=5");
    }

    #[test]
    fn top_k_most_frequent_ranks_first() {
        // Three rows with value 42, one row with value 99.
        let make_row = |v: i64| {
            let mut vals = BTreeMap::new();
            vals.insert("x".to_string(), TypedValue::Int(v));
            StorageRow { values: vals }
        };
        let rows = vec![make_row(42), make_row(42), make_row(42), make_row(99)];
        let top_k = compute_top_k("x", &rows, 10);
        assert_eq!(top_k.len(), 2, "expected exactly 2 distinct values");
        match &top_k[0].0 {
            TypedValue::Int(v) => assert_eq!(*v, 42, "most frequent must rank first"),
            _ => panic!("expected Int(42) as first top-K entry"),
        }
    }

    #[test]
    fn top_k_missing_key_is_skipped() {
        let mut v1 = BTreeMap::new();
        v1.insert("other".to_string(), TypedValue::Text("x".to_string()));
        let mut v2 = BTreeMap::new();
        v2.insert("target".to_string(), TypedValue::Int(1));
        let rows = vec![
            StorageRow { values: v1 },
            StorageRow { values: v2 },
        ];
        let top_k = compute_top_k("target", &rows, 10);
        assert_eq!(top_k.len(), 1, "row without the target key must be skipped");
    }

    // MARK: - Schema content affects the signature

    #[test]
    fn different_column_names_produce_different_preimages() {
        let p1 = table_signature_preimage(
            &[DatasetColumnSummary { name: "a".to_string(), data_type: "INTEGER".to_string() }],
            &[],
        );
        let p2 = table_signature_preimage(
            &[DatasetColumnSummary { name: "b".to_string(), data_type: "INTEGER".to_string() }],
            &[],
        );
        assert_ne!(p1, p2, "different column names must produce different preimages");
    }

    #[test]
    fn different_declared_types_produce_different_column_preimages() {
        let stats = ColumnStats { count: 0, distinct_count: 0, null_count: 0,
                                  min: TypedValue::Null, max: TypedValue::Null };
        let p1 = column_signature_preimage("x", "INTEGER", &stats, &[]);
        let p2 = column_signature_preimage("x", "TEXT", &stats, &[]);
        assert_ne!(p1, p2, "different declared types must produce different preimages");
    }
}

