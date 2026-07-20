// matrix/persistence.rs — selectable persistence backend.
//
// Rust mirror of `MatrixPersistence.swift`. Per
// durable matrix snapshots, persistence is a
// per-estate mode:
//   - InMemory: the tier is rebuilt from the audit log on cold start;
//                load returns None; save is a no-op.
//   - Snapshotted(path): serialized to a file at an HLC watermark;
//                load reads it; save writes atomically.
//
// The on-wire snapshot uses a simple length-prefixed encoding so the
// Rust port does not pull a serde dependency. Cross-port snapshot
// compatibility is not required at this mission (each port owns its
// own snapshot file); the conformance vectors compare in-memory tier
// state only.

use std::fs;
use std::io::{Read, Write};
use std::path::PathBuf;

use super::calibration::MatrixCalibrationRegistry;
use super::matrix::MatrixTier;
use crate::audit::UnifiedAuditLog;
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md. If you
// need a SimHash, Hamming distance, OR-reduce, Fingerprint256 op,
// HammingNN top-K, HLC tick, AuditGate admit, MatrixDecay, audit-
// log fold, Bradley-Terry update, NMF, FFT, eigenvalue centrality,
// or any other substrate primitive, it's already in substrate-types,
// substrate-kernel, or substrate-ml. CI catches drift four ways.
// See packages/libs/Substrate{Types,Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
use substrate_types::hlc::HLC;

// MARK: - Mode

#[derive(Clone, Debug, PartialEq)]
pub enum MatrixPersistenceMode {
    InMemory,
    Snapshotted { file: PathBuf },
}

// MARK: - Snapshot

#[derive(Clone, Debug, PartialEq)]
pub struct MatrixSnapshot {
    pub schema_version: i32,
    pub hlc_watermark: HLC,
    pub tier: MatrixTier,
    pub calibration: MatrixCalibrationRegistry,
}

impl MatrixSnapshot {
    /// Binary snapshot format version.
    ///
    /// v1 (initial): F/O/T/calibration-curves + temporal_watermark trailer (16 bytes).
    ///   update_timestamps always loaded as empty HashMap (no per-model decay baseline).
    ///
    /// v2 (2026-06-28): same as v1, plus update_timestamps section appended after
    ///   temporal_watermark. update_timestamps is the per-model last-observation
    ///   time (f64 epoch-seconds) required by MatrixCalibrationRegistry::record_with_decay.
    ///   Without this field, the first record_with_decay after restart has no last_ts
    ///   and silently skips decay computation. Schema is NOT FROZEN; no data exists
    ///   to migrate — a clean v1→v2 bump is safe. Callers that load a v1 snapshot
    ///   receive an empty update_timestamps (same behavior as before this fix).
    pub const CURRENT_SCHEMA_VERSION: i32 = 2;

    pub fn new(
        tier: MatrixTier,
        calibration: MatrixCalibrationRegistry,
        hlc_watermark: HLC,
    ) -> Self {
        Self {
            schema_version: Self::CURRENT_SCHEMA_VERSION,
            hlc_watermark,
            tier,
            calibration,
        }
    }
}

// MARK: - Errors

#[derive(Debug)]
pub enum MatrixPersistenceError {
    SnapshotDecodeFailed(String),
    SnapshotEncodeFailed(String),
    SchemaVersionMismatch { found: i32, expected: i32 },
}

impl std::fmt::Display for MatrixPersistenceError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::SnapshotDecodeFailed(s) => {
                write!(f, "snapshot decode failed: {s}")
            }
            Self::SnapshotEncodeFailed(s) => {
                write!(f, "snapshot encode failed: {s}")
            }
            Self::SchemaVersionMismatch { found, expected } => write!(
                f,
                "schema version mismatch: found {found}, expected {expected}"
            ),
        }
    }
}

impl std::error::Error for MatrixPersistenceError {}

// MARK: - Backend

pub struct MatrixPersistenceBackend {
    pub mode: MatrixPersistenceMode,
}

impl MatrixPersistenceBackend {
    pub fn new(mode: MatrixPersistenceMode) -> Self {
        Self { mode }
    }

    pub fn load(&self) -> Result<Option<MatrixSnapshot>, MatrixPersistenceError> {
        match &self.mode {
            MatrixPersistenceMode::InMemory => Ok(None),
            MatrixPersistenceMode::Snapshotted { file } => {
                if !file.exists() {
                    return Ok(None);
                }
                let mut f = fs::File::open(file).map_err(|e| {
                    MatrixPersistenceError::SnapshotDecodeFailed(format!("read failed: {e}"))
                })?;
                let mut bytes = Vec::new();
                f.read_to_end(&mut bytes).map_err(|e| {
                    MatrixPersistenceError::SnapshotDecodeFailed(format!("read failed: {e}"))
                })?;
                let snap = decode_snapshot(&bytes)?;
                if snap.schema_version != MatrixSnapshot::CURRENT_SCHEMA_VERSION {
                    return Err(MatrixPersistenceError::SchemaVersionMismatch {
                        found: snap.schema_version,
                        expected: MatrixSnapshot::CURRENT_SCHEMA_VERSION,
                    });
                }
                Ok(Some(snap))
            }
        }
    }

    pub fn save(&self, snapshot: &MatrixSnapshot) -> Result<(), MatrixPersistenceError> {
        match &self.mode {
            MatrixPersistenceMode::InMemory => Ok(()),
            MatrixPersistenceMode::Snapshotted { file } => {
                let bytes = encode_snapshot(snapshot);
                let tmp = file.with_extension("tmp");
                {
                    let mut f = fs::File::create(&tmp).map_err(|e| {
                        MatrixPersistenceError::SnapshotEncodeFailed(format!(
                            "create tmp failed: {e}"
                        ))
                    })?;
                    f.write_all(&bytes).map_err(|e| {
                        MatrixPersistenceError::SnapshotEncodeFailed(format!("write failed: {e}"))
                    })?;
                    f.sync_all().ok();
                }
                let _ = fs::remove_file(file);
                fs::rename(&tmp, file).map_err(|e| {
                    MatrixPersistenceError::SnapshotEncodeFailed(format!("rename failed: {e}"))
                })?;
                Ok(())
            }
        }
    }

    /// Rebuild from log and save. Mirrors the Swift entry-point's
    /// behavior: both modes replay the full log. The audit log is
    /// content-addressed (G-Set) and the rebuild is associative, so a
    /// full replay is correct in both cases and simpler than a
    /// load-then-tail-replay path. The watermark is preserved in the
    /// saved snapshot for the dreaming daemon (GLK-07).
    pub fn rebuild(
        &self,
        log: &UnifiedAuditLog,
        calibration: MatrixCalibrationRegistry,
    ) -> Result<MatrixSnapshot, MatrixPersistenceError> {
        let tier = MatrixTier::rebuild(log);
        let watermark = tier.last_hlc;
        let snap = MatrixSnapshot::new(tier, calibration, watermark);
        self.save(&snap)?;
        Ok(snap)
    }
}

// MARK: - Encoding
//
// Length-prefixed binary encoding. Not used for cross-leg comparison
// in this mission; the conformance harness compares in-memory tier
// state, not on-disk bytes.

pub(crate) fn encode_snapshot(s: &MatrixSnapshot) -> Vec<u8> {
    use super::matrix::{MatrixCoOccurKey, MatrixFieldCell, MatrixTemporalKey, MatrixValueCoord};
    use crate::audit::UnifiedAuditValue;

    fn put_u32(out: &mut Vec<u8>, v: u32) {
        out.extend_from_slice(&v.to_le_bytes());
    }
    fn put_u64(out: &mut Vec<u8>, v: u64) {
        out.extend_from_slice(&v.to_le_bytes());
    }
    fn put_i64(out: &mut Vec<u8>, v: i64) {
        out.extend_from_slice(&v.to_le_bytes());
    }
    fn put_i32(out: &mut Vec<u8>, v: i32) {
        out.extend_from_slice(&v.to_le_bytes());
    }
    fn put_str(out: &mut Vec<u8>, s: &str) {
        put_u32(out, s.len() as u32);
        out.extend_from_slice(s.as_bytes());
    }
    fn put_value(out: &mut Vec<u8>, v: &UnifiedAuditValue) {
        match v {
            UnifiedAuditValue::Null => out.push(0),
            UnifiedAuditValue::Bitmap(b) => {
                out.push(1);
                put_u64(out, *b);
            }
            UnifiedAuditValue::Integer(i) => {
                out.push(2);
                put_i64(out, *i);
            }
            UnifiedAuditValue::StringValue(s) => {
                out.push(3);
                put_str(out, s);
            }
            UnifiedAuditValue::Bytes(b) => {
                out.push(4);
                put_u32(out, b.len() as u32);
                out.extend_from_slice(b);
            }
        }
    }
    fn put_coord(out: &mut Vec<u8>, c: &MatrixValueCoord) {
        put_str(out, &c.field_path);
        put_value(out, &c.value);
    }

    let mut out = Vec::new();
    put_i32(&mut out, s.schema_version);
    put_i64(&mut out, s.hlc_watermark.physical_time);
    put_i32(&mut out, s.hlc_watermark.logical_count);
    put_i32(&mut out, s.hlc_watermark.node_id);

    // Tier
    put_i64(&mut out, s.tier.live_row_count);
    put_i64(&mut out, s.tier.last_hlc.physical_time);
    put_i32(&mut out, s.tier.last_hlc.logical_count);
    put_i32(&mut out, s.tier.last_hlc.node_id);

    // F
    let mut fcells: Vec<(&MatrixFieldCell, &i64)> = s.tier.field_presence.iter().collect();
    fcells.sort_by(|a, b| {
        a.0.field_path
            .cmp(&b.0.field_path)
            .then(a.0.bit_position.cmp(&b.0.bit_position))
    });
    put_u32(&mut out, fcells.len() as u32);
    for (k, v) in fcells {
        put_str(&mut out, &k.field_path);
        out.push(k.bit_position);
        put_i64(&mut out, *v);
    }

    // O
    let mut okeys: Vec<(&MatrixCoOccurKey, &i64)> = s.tier.co_occurrence.iter().collect();
    okeys.sort_by(|a, b| {
        a.0.a
            .field_path
            .cmp(&b.0.a.field_path)
            .then(a.0.b.field_path.cmp(&b.0.b.field_path))
    });
    put_u32(&mut out, okeys.len() as u32);
    for (k, v) in okeys {
        put_coord(&mut out, &k.a);
        put_coord(&mut out, &k.b);
        put_i64(&mut out, *v);
    }

    // T
    let mut tkeys: Vec<(&MatrixTemporalKey, &i64)> = s.tier.temporal_causality.iter().collect();
    tkeys.sort_by(|a, b| {
        a.0.source
            .field_path
            .cmp(&b.0.source.field_path)
            .then(a.0.target.field_path.cmp(&b.0.target.field_path))
            .then(a.0.lag_bucket.cmp(&b.0.lag_bucket))
    });
    put_u32(&mut out, tkeys.len() as u32);
    for (k, v) in tkeys {
        put_coord(&mut out, &k.source);
        put_coord(&mut out, &k.target);
        put_u32(&mut out, k.lag_bucket);
        put_i64(&mut out, *v);
    }

    // Calibration: per-model curve, 20 buckets each.
    let mut curves: Vec<(&String, _)> = s.calibration.curves.iter().collect();
    curves.sort_by(|a, b| a.0.cmp(b.0));
    put_u32(&mut out, curves.len() as u32);
    for (model_id, curve) in curves {
        put_str(&mut out, model_id);
        put_u32(&mut out, curve.buckets.len() as u32);
        for bucket in &curve.buckets {
            put_i32(&mut out, bucket.count);
            out.extend_from_slice(&bucket.success_rate.to_le_bytes());
        }
    }

    // temporal_watermark_hlc — 16 bytes (i64 + i32 + i32).
    // v1-format snapshots end here; v2 appends update_timestamps below.
    put_i64(&mut out, s.tier.temporal_watermark_hlc.physical_time);
    put_i32(&mut out, s.tier.temporal_watermark_hlc.logical_count);
    put_i32(&mut out, s.tier.temporal_watermark_hlc.node_id);

    // update_timestamps (v2 section): per-model last-observation time (f64 epoch-seconds).
    //
    // Required by MatrixCalibrationRegistry::record_with_decay to compute the elapsed
    // time since last observation for decay math. Without this field, the first
    // record_with_decay after restart has no last_ts and silently skips decay.
    //
    // Format: u32 count, then (str model_id, f64 timestamp) pairs, sorted by model_id
    // for deterministic output. Decoders check schema_version: v1 gets empty map,
    // v2 reads this section. Parity: Swift Codable already serializes this field
    // through MatrixCalibrationRegistry.Codable — this section makes Rust match.
    let mut ts_entries: Vec<(&String, &f64)> = s.calibration.update_timestamps.iter().collect();
    ts_entries.sort_by(|a, b| a.0.cmp(b.0));
    put_u32(&mut out, ts_entries.len() as u32);
    for (model_id, ts) in ts_entries {
        put_str(&mut out, model_id);
        out.extend_from_slice(&ts.to_le_bytes());
    }

    out
}

pub(crate) fn decode_snapshot(bytes: &[u8]) -> Result<MatrixSnapshot, MatrixPersistenceError> {
    use super::calibration::{
        MatrixCalibrationBucket, MatrixCalibrationCurve, MatrixCalibrationRegistry,
    };
    use super::matrix::{
        MatrixCoOccurKey, MatrixFieldCell, MatrixTemporalKey, MatrixTier, MatrixValueCoord,
    };
    use crate::audit::UnifiedAuditValue;
    use std::collections::HashMap;

    struct Reader<'a> {
        buf: &'a [u8],
        pos: usize,
    }
    impl<'a> Reader<'a> {
        fn read_bytes(&mut self, n: usize) -> Result<&'a [u8], MatrixPersistenceError> {
            if self.pos + n > self.buf.len() {
                return Err(MatrixPersistenceError::SnapshotDecodeFailed(
                    "short read".into(),
                ));
            }
            let s = &self.buf[self.pos..self.pos + n];
            self.pos += n;
            Ok(s)
        }
        fn u32(&mut self) -> Result<u32, MatrixPersistenceError> {
            let b = self.read_bytes(4)?;
            Ok(u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
        }
        fn u64(&mut self) -> Result<u64, MatrixPersistenceError> {
            let b = self.read_bytes(8)?;
            let mut a = [0u8; 8];
            a.copy_from_slice(b);
            Ok(u64::from_le_bytes(a))
        }
        fn i64(&mut self) -> Result<i64, MatrixPersistenceError> {
            Ok(self.u64()? as i64)
        }
        fn i32(&mut self) -> Result<i32, MatrixPersistenceError> {
            Ok(self.u32()? as i32)
        }
        fn u8(&mut self) -> Result<u8, MatrixPersistenceError> {
            Ok(self.read_bytes(1)?[0])
        }
        fn string(&mut self) -> Result<String, MatrixPersistenceError> {
            let len = self.u32()? as usize;
            let b = self.read_bytes(len)?;
            String::from_utf8(b.to_vec())
                .map_err(|e| MatrixPersistenceError::SnapshotDecodeFailed(format!("utf8: {e}")))
        }
        fn value(&mut self) -> Result<UnifiedAuditValue, MatrixPersistenceError> {
            let tag = self.u8()?;
            match tag {
                0 => Ok(UnifiedAuditValue::Null),
                1 => Ok(UnifiedAuditValue::Bitmap(self.u64()?)),
                2 => Ok(UnifiedAuditValue::Integer(self.i64()?)),
                3 => Ok(UnifiedAuditValue::StringValue(self.string()?)),
                4 => {
                    let n = self.u32()? as usize;
                    let b = self.read_bytes(n)?;
                    Ok(UnifiedAuditValue::Bytes(b.to_vec()))
                }
                other => Err(MatrixPersistenceError::SnapshotDecodeFailed(format!(
                    "unknown value tag {other}"
                ))),
            }
        }
        fn coord(&mut self) -> Result<MatrixValueCoord, MatrixPersistenceError> {
            let path = self.string()?;
            let value = self.value()?;
            Ok(MatrixValueCoord::new(path, value))
        }
        fn f32(&mut self) -> Result<f32, MatrixPersistenceError> {
            let b = self.read_bytes(4)?;
            Ok(f32::from_le_bytes([b[0], b[1], b[2], b[3]]))
        }
    }

    let mut r = Reader { buf: bytes, pos: 0 };
    let schema_version = r.i32()?;
    let wm_pt = r.i64()?;
    let wm_lc = r.i32()?;
    let wm_node = r.i32()?;
    let watermark = HLC::new(wm_pt, wm_lc, wm_node);

    let mut tier = MatrixTier::new();
    tier.live_row_count = r.i64()?;
    let last_pt = r.i64()?;
    let last_lc = r.i32()?;
    let last_node = r.i32()?;
    tier.last_hlc = HLC::new(last_pt, last_lc, last_node);

    let n_f = r.u32()? as usize;
    for _ in 0..n_f {
        let path = r.string()?;
        let bit = r.u8()?;
        let v = r.i64()?;
        tier.field_presence
            .insert(MatrixFieldCell::new(path, bit), v);
    }

    let n_o = r.u32()? as usize;
    for _ in 0..n_o {
        let a = r.coord()?;
        let b = r.coord()?;
        let v = r.i64()?;
        // Direct insert: the encoder already wrote keys in canonical
        // ordering; preserve that ordering on decode by skipping
        // re-canonicalisation.
        tier.co_occurrence.insert(MatrixCoOccurKey { a, b }, v);
    }

    let n_t = r.u32()? as usize;
    for _ in 0..n_t {
        let source = r.coord()?;
        let target = r.coord()?;
        let lag = r.u32()?;
        let v = r.i64()?;
        tier.temporal_causality.insert(
            MatrixTemporalKey {
                source,
                target,
                lag_bucket: lag,
            },
            v,
        );
    }

    let n_curves = r.u32()? as usize;
    let mut curves: HashMap<String, MatrixCalibrationCurve> = HashMap::new();
    for _ in 0..n_curves {
        let id = r.string()?;
        let n_b = r.u32()? as usize;
        let mut buckets = Vec::with_capacity(n_b);
        for _ in 0..n_b {
            let count = r.i32()?;
            let rate = r.f32()?;
            buckets.push(MatrixCalibrationBucket {
                count,
                success_rate: rate,
            });
        }
        curves.insert(id, MatrixCalibrationCurve { buckets });
    }
    // temporal_watermark_hlc — 16 bytes (i64 + i32 + i32).
    //
    // Tail layout by schema_version:
    //   v1, no trailer:  remaining == 0  → HLC::ZERO (legacy; no update_timestamps follows).
    //   v1, with trailer: remaining == 16 → read HLC; no update_timestamps section.
    //   v2:              remaining >= 16 mandatory (temporal_watermark) + mandatory
    //                    update_timestamps count (≥4 bytes for u32). A v2 blob with
    //                    remaining == 0 OR with no bytes after the watermark is CORRUPT
    //                    (truncated), not a valid legacy path — fail with a decode error
    //                    so MatrixSnapshotStore.load returns None and triggers a full
    //                    rebuild rather than accepting a v2 snapshot with a reset watermark
    //                    that could replay temporal deltas over already-loaded state.
    let remaining = r.buf.len() - r.pos;

    // For v2, a missing temporal_watermark section is a corruption indicator —
    // v2 blobs MUST contain the full tail. Reject before reading anything from it.
    if schema_version >= 2 && remaining < 16 {
        return Err(MatrixPersistenceError::SnapshotDecodeFailed(format!(
            "truncated v2 snapshot: expected ≥16 bytes for temporal_watermark, found {remaining}"
        )));
    }

    tier.temporal_watermark_hlc = if remaining >= 16 {
        let pt = r.i64()?;
        let lc = r.i32()?;
        let node = r.i32()?;
        HLC::new(pt, lc, node)
    } else {
        // remaining == 0 and schema_version < 2 (v1 without watermark trailer).
        // Mirrors Swift's `decodeIfPresent(HLC.self, forKey: .temporalWatermarkHLC) ?? .zero`.
        HLC::ZERO
    };

    // update_timestamps section (v2 mandatory tail): per-model last-observation time
    // (f64 epoch-seconds). Required for decay math in MatrixCalibrationRegistry::
    // record_with_decay. A missing section on a v2 blob is a corruption indicator —
    // the encoder always writes this section for v2 (even if empty, writing count=0).
    //
    // Decision tree:
    //   v1, no watermark (remaining was 0): r.pos == r.buf.len() → empty map (OK, v1 path).
    //   v1, watermark present (remaining was 16): r.pos == r.buf.len() → empty map (OK, v1).
    //   v2, watermark read but no bytes left: r.pos >= r.buf.len() → CORRUPT — reject.
    //   v2, watermark read, bytes remain: decode the timestamps section.
    let mut update_timestamps = std::collections::HashMap::new();
    if schema_version >= 2 {
        // v2 mandates the update_timestamps section (count field at minimum).
        // An encoder always writes the 4-byte u32 count even for an empty map.
        if r.pos >= r.buf.len() {
            return Err(MatrixPersistenceError::SnapshotDecodeFailed(
                "truncated v2 snapshot: update_timestamps section is absent after temporal_watermark".into(),
            ));
        }
        let n_ts = r.u32()? as usize;
        for _ in 0..n_ts {
            let model_id = r.string()?;
            let ts_bytes = r.read_bytes(8)?;
            let ts = f64::from_le_bytes([
                ts_bytes[0], ts_bytes[1], ts_bytes[2], ts_bytes[3],
                ts_bytes[4], ts_bytes[5], ts_bytes[6], ts_bytes[7],
            ]);
            update_timestamps.insert(model_id, ts);
        }
    }
    // v1 path: update_timestamps remains empty — first record_with_decay applies
    // no decay (no elapsed time to compute from a missing baseline), matching
    // prior behavior while preserving calibration curves read above.

    let calibration = MatrixCalibrationRegistry { curves, update_timestamps };

    Ok(MatrixSnapshot {
        schema_version,
        hlc_watermark: watermark,
        tier,
        calibration,
    })
}

// ─────────────────────────────────────────────────────────────────────
// Part 2 regression tests: v2 truncation path.
//
// Verifies that:
//   1. A complete v2 blob decodes successfully.
//   2. A complete v1 blob (no temporal_watermark, no update_timestamps) decodes
//      successfully with HLC::ZERO and an empty update_timestamps map.
//   3. A v2 blob truncated BEFORE the temporal_watermark (remaining == 0 after
//      calibration curves) is REJECTED with a decode error.
//   4. A v2 blob that has the temporal_watermark but NO update_timestamps section
//      (truncated at the watermark boundary) is REJECTED with a decode error.
//
// Prior to the fix, cases 3 and 4 were silently accepted, returning a snapshot
// with HLC::ZERO or an empty update_timestamps map — allowing incremental_update
// to replay temporal deltas over already-loaded state from a reset watermark.
// ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod v2_truncation_tests {
    use super::{decode_snapshot, encode_snapshot, MatrixSnapshot, MatrixPersistenceError};
    use super::super::calibration::MatrixCalibrationRegistry;
    use super::super::matrix::MatrixTier;
    use substrate_types::hlc::HLC;

    fn make_v2_snapshot() -> MatrixSnapshot {
        MatrixSnapshot::new(
            MatrixTier::new(),
            MatrixCalibrationRegistry::default(),
            HLC::new(1_000, 0, 1),
        )
    }

    /// A complete v2 snapshot round-trips through encode → decode without error.
    #[test]
    fn v2_complete_blob_decodes_ok() {
        let snap = make_v2_snapshot();
        assert_eq!(snap.schema_version, 2, "test fixture must be schema_version 2");
        let bytes = encode_snapshot(&snap);
        let decoded = decode_snapshot(&bytes).expect("complete v2 blob must decode");
        assert_eq!(decoded.schema_version, 2);
        assert_eq!(decoded.hlc_watermark, snap.hlc_watermark);
    }

    /// A v1 snapshot (schema_version forced to 1, no temporal_watermark or
    /// update_timestamps written) decodes without error, yielding HLC::ZERO
    /// and an empty update_timestamps map — preserving pre-v2 behavior.
    #[test]
    fn v1_blob_decodes_ok_with_zero_watermark_and_empty_timestamps() {
        // Build a v1 blob by encoding a v2 snapshot and patching schema_version to 1.
        // A real v1 blob has no temporal_watermark or update_timestamps trailer, so
        // we encode a v2 (which DOES write those sections) and trim the final
        // 16 (temporal_watermark) + 4 (ts count u32) bytes = 20 bytes.
        let mut snap = make_v2_snapshot();
        snap.schema_version = 1;
        // Encode with schema_version=1: the encoder writes temporal_watermark
        // and update_timestamps regardless of schema_version (the encoder always
        // emits the full v2 layout). To simulate a genuine v1 blob (no tail),
        // encode a v2, set version=1 in the first 4 bytes, then strip the 20-byte tail.
        let mut bytes = encode_snapshot(&snap);
        // Patch the first 4 bytes (little-endian i32) to schema_version = 1.
        bytes[0] = 1; bytes[1] = 0; bytes[2] = 0; bytes[3] = 0;
        // Strip the 20-byte v2 tail (16 temporal_watermark + 4 ts count).
        let tail_len = 16 + 4; // watermark(i64+i32+i32) + u32(0 ts)
        if bytes.len() >= tail_len {
            bytes.truncate(bytes.len() - tail_len);
        }
        let decoded = decode_snapshot(&bytes).expect("v1 blob without trailer must decode");
        assert_eq!(decoded.schema_version, 1);
        assert_eq!(
            decoded.tier.temporal_watermark_hlc,
            HLC::ZERO,
            "v1 without watermark → HLC::ZERO"
        );
        assert!(
            decoded.calibration.update_timestamps.is_empty(),
            "v1 without timestamps → empty map"
        );
    }

    /// A v2 blob truncated AFTER calibration curves but BEFORE the temporal_watermark
    /// (remaining == 0 when we reach the watermark field) must be REJECTED.
    /// Before the fix: remaining==0 + schema_version>=2 yielded HLC::ZERO silently.
    #[test]
    fn v2_truncated_before_watermark_is_rejected() {
        let snap = make_v2_snapshot();
        let bytes = encode_snapshot(&snap);
        // Strip the final 16+4 = 20 bytes (temporal_watermark + ts count).
        // This leaves a v2 blob with remaining==0 at the watermark decode point.
        assert!(
            bytes.len() >= 20,
            "encoded snapshot must be at least 20 bytes to truncate"
        );
        let truncated = &bytes[..bytes.len() - 20];
        let result = decode_snapshot(truncated);
        assert!(
            result.is_err(),
            "truncated v2 blob (no watermark) must be rejected, got Ok"
        );
        if let Err(MatrixPersistenceError::SnapshotDecodeFailed(msg)) = &result {
            assert!(
                msg.contains("truncated v2"),
                "error message must mention 'truncated v2', got: {msg}"
            );
        }
    }

    /// A v2 blob with temporal_watermark present but NO update_timestamps section
    /// (truncated between watermark and ts count) must be REJECTED.
    /// Before the fix: r.pos>=r.buf.len() after watermark yielded empty timestamps silently.
    #[test]
    fn v2_truncated_after_watermark_missing_ts_section_is_rejected() {
        let snap = make_v2_snapshot();
        let bytes = encode_snapshot(&snap);
        // Strip only the 4-byte ts-count (u32) and any ts entries.
        // The encoded v2 with empty update_timestamps writes exactly 4 bytes for count=0.
        // After stripping those 4 bytes, temporal_watermark is present but ts section missing.
        assert!(
            bytes.len() >= 4,
            "encoded snapshot must be at least 4 bytes to strip ts count"
        );
        let truncated = &bytes[..bytes.len() - 4];
        let result = decode_snapshot(truncated);
        assert!(
            result.is_err(),
            "v2 blob with watermark but no ts section must be rejected, got Ok"
        );
        if let Err(MatrixPersistenceError::SnapshotDecodeFailed(msg)) = &result {
            assert!(
                msg.contains("truncated v2") || msg.contains("absent"),
                "error message must identify the truncation, got: {msg}"
            );
        }
    }
}
