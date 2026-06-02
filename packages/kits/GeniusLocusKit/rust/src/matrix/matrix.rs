// matrix/matrix.rs — F, C, O, T family.
//
// Rust mirror of `MatrixTier.swift`. The coordinate types, update
// semantics, decay, and rebuild-from-audit-log path all match the
// Swift reference bit-for-bit on the shared test vectors.

use std::collections::HashMap;
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

use crate::audit::{AuditTier, EntryUUID, UnifiedAuditLog, UnifiedAuditValue, UnifiedAuditVerb};

// MARK: - Coordinate types

#[derive(Clone, Debug, Eq, PartialEq, Hash)]
pub struct MatrixFieldCell {
    pub field_path: String,
    pub bit_position: u8,
}

impl MatrixFieldCell {
    pub fn new(field_path: impl Into<String>, bit_position: u8) -> Self {
        assert!(bit_position < 64, "bit_position out of 64-bit block range");
        Self {
            field_path: field_path.into(),
            bit_position,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Hash)]
pub struct MatrixValueCoord {
    pub field_path: String,
    pub value: UnifiedAuditValue,
}

impl MatrixValueCoord {
    pub fn new(field_path: impl Into<String>, value: UnifiedAuditValue) -> Self {
        Self {
            field_path: field_path.into(),
            value,
        }
    }

    fn canonical_rank(&self) -> i128 {
        match &self.value {
            UnifiedAuditValue::Null => 0,
            UnifiedAuditValue::Bitmap(v) => 1 + (*v as i128),
            UnifiedAuditValue::Integer(v) => 2 + (*v as i128),
            UnifiedAuditValue::StringValue(s) => 3 + s.len() as i128,
            UnifiedAuditValue::Bytes(b) => 4 + b.len() as i128,
        }
    }
}

/// Canonical-ordered co-occurrence key. Symmetric in inputs.
#[derive(Clone, Debug, Eq, PartialEq, Hash)]
pub struct MatrixCoOccurKey {
    pub a: MatrixValueCoord,
    pub b: MatrixValueCoord,
}

impl MatrixCoOccurKey {
    pub fn new(x: MatrixValueCoord, y: MatrixValueCoord) -> Self {
        // Canonical order: by field_path, then by value's canonical
        // rank. Symmetric in inputs.
        let less = if x.field_path != y.field_path {
            x.field_path < y.field_path
        } else {
            x.canonical_rank() < y.canonical_rank()
        };
        if less {
            Self { a: x, b: y }
        } else {
            Self { a: y, b: x }
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Hash)]
pub struct MatrixTemporalKey {
    pub source: MatrixValueCoord,
    pub target: MatrixValueCoord,
    pub lag_bucket: u32,
}

// MARK: - Matrix tier

#[derive(Clone, Debug, PartialEq)]
pub struct MatrixTier {
    pub field_presence: HashMap<MatrixFieldCell, i64>,
    pub co_occurrence: HashMap<MatrixCoOccurKey, i64>,
    pub temporal_causality: HashMap<MatrixTemporalKey, i64>,
    pub live_row_count: i64,
    pub last_hlc: HLC,
}

impl Default for MatrixTier {
    fn default() -> Self {
        Self {
            field_presence: HashMap::new(),
            co_occurrence: HashMap::new(),
            temporal_causality: HashMap::new(),
            live_row_count: 0,
            last_hlc: HLC::new(0, 0, 0),
        }
    }
}

impl MatrixTier {
    /// Log-spaced lag bucket boundaries in minutes (cookbook §6.4).
    pub const LAG_BUCKETS: &'static [u32] = &[1, 2, 4, 8, 16, 32, 64, 128];

    /// Window cap on T pairs in minutes (cookbook §6.4).
    pub const TEMPORAL_WINDOW_MINUTES: u32 = 256;

    pub fn new() -> Self {
        Self::default()
    }

    /// C[field, bit] = F[field, bit] / N_rows.
    pub fn correlation(&self, cell: &MatrixFieldCell) -> f64 {
        if self.live_row_count <= 0 {
            return 0.0;
        }
        let count = *self.field_presence.get(cell).unwrap_or(&0);
        count as f64 / self.live_row_count as f64
    }

    /// Apply one captured row's fingerprint. Mirrors the Swift entry
    /// point bit-for-bit: F is updated per set bit; O is updated for
    /// every distinct coordinate pair from the row's contributing
    /// fields.
    pub fn apply_capture(
        &mut self,
        bitmap_fields: &[(String, u64)],
        value_fields: &[MatrixValueCoord],
        hlc: HLC,
        delta: i64,
    ) {
        // F: walk every set bit.
        for (path, bitmap) in bitmap_fields {
            let mut b = *bitmap;
            while b != 0 {
                let bit_pos = b.trailing_zeros() as u8;
                let cell = MatrixFieldCell::new(path.clone(), bit_pos);
                add_signed(&mut self.field_presence, cell, delta);
                b &= b.wrapping_sub(1);
            }
        }

        // O: co-occurrence over the row's (field, value) coordinates.
        let mut coords: Vec<MatrixValueCoord> = value_fields.to_vec();
        coords.reserve(value_fields.len() + bitmap_fields.len());
        for (path, bm) in bitmap_fields {
            if *bm != 0 {
                coords.push(MatrixValueCoord::new(
                    path.clone(),
                    UnifiedAuditValue::Bitmap(*bm),
                ));
            }
        }
        if coords.len() >= 2 {
            for i in 0..(coords.len() - 1) {
                for j in (i + 1)..coords.len() {
                    let key = MatrixCoOccurKey::new(coords[i].clone(), coords[j].clone());
                    add_signed(&mut self.co_occurrence, key, delta);
                }
            }
        }

        self.live_row_count = (self.live_row_count + delta).max(0);
        if hlc > self.last_hlc {
            self.last_hlc = hlc;
        }
    }

    /// Update one cell of the temporal matrix.
    pub fn apply_temporal_event(
        &mut self,
        source: MatrixValueCoord,
        target: MatrixValueCoord,
        delta_minutes: u32,
        delta: i64,
    ) {
        if delta_minutes == 0 || delta_minutes > Self::TEMPORAL_WINDOW_MINUTES {
            return;
        }
        let bucket = Self::lag_bucket_for_minutes(delta_minutes);
        let key = MatrixTemporalKey {
            source,
            target,
            lag_bucket: bucket,
        };
        add_signed(&mut self.temporal_causality, key, delta);
    }

    pub fn lag_bucket_for_minutes(minutes: u32) -> u32 {
        for b in Self::LAG_BUCKETS {
            if minutes <= *b {
                return *b;
            }
        }
        *Self::LAG_BUCKETS.last().unwrap_or(&128)
    }

    /// Apply lazy multiplicative decay per cookbook §6.8. F and C do
    /// not decay; O half-life is 365 days; T half-life is 90 days.
    pub fn apply_decay(&mut self, elapsed_days: f64, o_half_life_days: f64, t_half_life_days: f64) {
        if elapsed_days < 1.0 {
            return;
        }
        let o_factor = 0.5_f64.powf(elapsed_days / o_half_life_days);
        let t_factor = 0.5_f64.powf(elapsed_days / t_half_life_days);

        let o_keys: Vec<_> = self.co_occurrence.keys().cloned().collect();
        for k in o_keys {
            let v = *self.co_occurrence.get(&k).unwrap();
            let decayed = (v as f64 * o_factor).round() as i64;
            if decayed > 0 {
                self.co_occurrence.insert(k, decayed);
            } else {
                self.co_occurrence.remove(&k);
            }
        }
        let t_keys: Vec<_> = self.temporal_causality.keys().cloned().collect();
        for k in t_keys {
            let v = *self.temporal_causality.get(&k).unwrap();
            let decayed = (v as f64 * t_factor).round() as i64;
            if decayed > 0 {
                self.temporal_causality.insert(k, decayed);
            } else {
                self.temporal_causality.remove(&k);
            }
        }
    }

    /// Rebuild from the unified audit log. Replays in HLC order;
    /// matches the Swift reference's bundling-by-(tier, row, hlc) so
    /// the F and O passes see all of a row's fingerprint fields
    /// together.
    pub fn rebuild(log: &UnifiedAuditLog) -> Self {
        let mut tier = MatrixTier::new();
        let entries = log.ordered_entries();

        // (tier, row, hlc) bundle key.
        type RowKey = (AuditTier, EntryUUID, HLC);
        let mut bundle: HashMap<RowKey, Vec<(String, u64)>> = HashMap::new();
        let mut value_bundle: HashMap<RowKey, Vec<MatrixValueCoord>> = HashMap::new();
        let mut bundle_sign: HashMap<RowKey, i64> = HashMap::new();
        let mut bundle_order: Vec<RowKey> = Vec::new();

        for entry in entries {
            let key: RowKey = (entry.tier, entry.row_id, entry.hlc);

            let sign: Option<i64> = match entry.verb {
                UnifiedAuditVerb::Capture => Some(1),
                UnifiedAuditVerb::Expunge => Some(-1),
                UnifiedAuditVerb::Withdraw => {
                    tier.live_row_count = (tier.live_row_count - 1).max(0);
                    None
                }
                _ => None,
            };
            let Some(s) = sign else { continue };

            if !bundle_sign.contains_key(&key) {
                bundle_order.push(key);
            }
            bundle_sign.insert(key, s);

            match &entry.after_value {
                UnifiedAuditValue::Bitmap(v) => {
                    bundle
                        .entry(key)
                        .or_default()
                        .push((entry.field_path.clone(), *v));
                }
                _ => {
                    value_bundle
                        .entry(key)
                        .or_default()
                        .push(MatrixValueCoord::new(
                            entry.field_path.clone(),
                            entry.after_value.clone(),
                        ));
                }
            }
        }

        for key in bundle_order {
            let sign = *bundle_sign.get(&key).unwrap();
            let bm = bundle.remove(&key).unwrap_or_default();
            let vs = value_bundle.remove(&key).unwrap_or_default();
            tier.apply_capture(&bm, &vs, key.2, sign);
        }

        tier
    }
}

fn add_signed<K: std::hash::Hash + Eq>(map: &mut HashMap<K, i64>, key: K, delta: i64) {
    let next = map.get(&key).copied().unwrap_or(0) + delta;
    if next > 0 {
        map.insert(key, next);
    } else {
        map.remove(&key);
    }
}
