// matrix/persistence.rs — selectable persistence backend.
//
// Rust mirror of `MatrixPersistence.swift`. Per
// DECISION_MATRIX_TIER_PERSISTENCE_2026-05-21, persistence is a
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

use crate::audit::UnifiedAuditLog;
use super::calibration::MatrixCalibrationRegistry;
use super::matrix::MatrixTier;
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE_v1.0_2026-05-28.md. If you
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
    pub const CURRENT_SCHEMA_VERSION: i32 = 1;

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
                    MatrixPersistenceError::SnapshotDecodeFailed(format!(
                        "read failed: {e}"
                    ))
                })?;
                let mut bytes = Vec::new();
                f.read_to_end(&mut bytes).map_err(|e| {
                    MatrixPersistenceError::SnapshotDecodeFailed(format!(
                        "read failed: {e}"
                    ))
                })?;
                let snap = decode_snapshot(&bytes)?;
                if snap.schema_version != MatrixSnapshot::CURRENT_SCHEMA_VERSION
                {
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
                        MatrixPersistenceError::SnapshotEncodeFailed(format!(
                            "write failed: {e}"
                        ))
                    })?;
                    f.sync_all().ok();
                }
                let _ = fs::remove_file(file);
                fs::rename(&tmp, file).map_err(|e| {
                    MatrixPersistenceError::SnapshotEncodeFailed(format!(
                        "rename failed: {e}"
                    ))
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
// Length-prefixed binary encoding. Not used for cross-port comparison
// in this mission; the conformance harness compares in-memory tier
// state, not on-disk bytes.

fn encode_snapshot(s: &MatrixSnapshot) -> Vec<u8> {
    use super::matrix::{
        MatrixCoOccurKey, MatrixFieldCell, MatrixTemporalKey, MatrixValueCoord,
    };
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
    let mut fcells: Vec<(&MatrixFieldCell, &i64)> =
        s.tier.field_presence.iter().collect();
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
    let mut okeys: Vec<(&MatrixCoOccurKey, &i64)> =
        s.tier.co_occurrence.iter().collect();
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
    let mut tkeys: Vec<(&MatrixTemporalKey, &i64)> =
        s.tier.temporal_causality.iter().collect();
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

    out
}

fn decode_snapshot(bytes: &[u8]) -> Result<MatrixSnapshot, MatrixPersistenceError> {
    use super::calibration::{
        MatrixCalibrationBucket, MatrixCalibrationCurve, MatrixCalibrationRegistry,
    };
    use super::matrix::{
        MatrixCoOccurKey, MatrixFieldCell, MatrixTemporalKey, MatrixTier,
        MatrixValueCoord,
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
            String::from_utf8(b.to_vec()).map_err(|e| {
                MatrixPersistenceError::SnapshotDecodeFailed(format!(
                    "utf8: {e}"
                ))
            })
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
        tier.co_occurrence
            .insert(MatrixCoOccurKey { a, b }, v);
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
    let calibration = MatrixCalibrationRegistry { curves };

    Ok(MatrixSnapshot {
        schema_version,
        hlc_watermark: watermark,
        tier,
        calibration,
    })
}
