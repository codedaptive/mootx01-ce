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
// docs/engineering/HARNESS_REFERENCE.md. If you
// need a SimHash, Hamming distance, OR-reduce, Fingerprint256 op,
// HammingNN top-K, HLC tick, AuditGate admit, MatrixDecay, audit-
// log fold, Bradley-Terry update, NMF, FFT, eigenvalue centrality,
// or any other substrate primitive, it's already in substrate-types,
// substrate-kernel, or substrate-ml. CI catches drift four ways.
// See packages/libs/Substrate{Types,Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
use substrate_ml::temporal_causality_fold::{
    fold as tcf_fold, TemporalAuditEntry, TemporalFieldCoord,
};
use substrate_types::hlc::HLC;

use crate::audit::{
    AuditTier, EntryUUID, UnifiedAuditEntry, UnifiedAuditLog, UnifiedAuditValue, UnifiedAuditVerb,
};

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
    /// HLC of the last audit entry processed by `rebuild_temporal`.
    ///
    /// Mirrors Swift `MatrixTier.temporalWatermarkHLC`. The hourly
    /// TemporalCausalitySignal uses this watermark to process only entries
    /// that arrived since the last T-population pass, avoiding redundant
    /// reprocessing of the full log. Initialized to `HLC::ZERO` (no pass
    /// has run yet) and advanced by every `rebuild_temporal` call.
    pub temporal_watermark_hlc: HLC,
}

impl Default for MatrixTier {
    fn default() -> Self {
        Self {
            field_presence: HashMap::new(),
            co_occurrence: HashMap::new(),
            temporal_causality: HashMap::new(),
            live_row_count: 0,
            last_hlc: HLC::ZERO,
            temporal_watermark_hlc: HLC::ZERO,
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
        Self::apply_capture_entries(&mut tier, log.ordered_entries());
        tier
    }

    /// Apply capture/expunge/withdraw entries to `tier`'s F/O/C state in strict
    /// HLC order, IN PLACE on the passed tier. Mirrors Swift
    /// `MatrixTier.applyCaptureEntries(into:entries:)`.
    ///
    /// Shared by `rebuild` (fresh tier, all entries) and `incremental_update`
    /// (loaded snapshot, only entries past the cursor). Operating in place is the
    /// load-bearing correctness point for incremental: an expunge/withdraw of a
    /// row captured BEFORE the snapshot lands its `-1` on the existing `+1`.
    ///
    /// Applying ALL events in strict HLC order (rather than the prior design,
    /// which decremented withdraws during the parse loop before any capture was
    /// applied) is the correctness fix that makes live_row_count right and makes
    /// incremental hydration equal a full rebuild: a row is always captured before
    /// it is expunged/withdrawn, so in HLC order the running count never goes
    /// negative and the defensive clamp in `apply_capture` never fires. F/O are
    /// additive so their counts are order-independent; only the count and the
    /// clamp depend on order. At equal HLC, capture/expunge bundles apply before
    /// withdraws (the natural capture→withdraw order, and deterministic).
    fn apply_capture_entries<I>(tier: &mut MatrixTier, entries: I)
    where
        I: IntoIterator<Item = UnifiedAuditEntry>,
    {
        // (tier, row, hlc) bundle key.
        type RowKey = (AuditTier, EntryUUID, HLC);
        let mut bundle: HashMap<RowKey, Vec<(String, u64)>> = HashMap::new();
        let mut value_bundle: HashMap<RowKey, Vec<MatrixValueCoord>> = HashMap::new();
        let mut bundle_sign: HashMap<RowKey, i64> = HashMap::new();
        let mut bundle_order: Vec<RowKey> = Vec::new();
        let mut withdraw_hlcs: Vec<HLC> = Vec::new();

        for entry in entries {
            match entry.verb {
                UnifiedAuditVerb::Capture | UnifiedAuditVerb::Expunge => {
                    let key: RowKey = (entry.tier, entry.row_id, entry.hlc);
                    if !bundle_sign.contains_key(&key) {
                        bundle_order.push(key);
                    }
                    let s = if entry.verb == UnifiedAuditVerb::Capture { 1 } else { -1 };
                    bundle_sign.insert(key, s);
                    match entry.after_value {
                        UnifiedAuditValue::Bitmap(v) => {
                            bundle
                                .entry(key)
                                .or_default()
                                .push((entry.field_path.clone(), v));
                        }
                        other => {
                            value_bundle
                                .entry(key)
                                .or_default()
                                .push(MatrixValueCoord::new(entry.field_path.clone(), other));
                        }
                    }
                }
                UnifiedAuditVerb::Withdraw => {
                    // Soft tombstone: decrements live_row_count without touching
                    // F/O. Collected here and applied in HLC order below — it MUST
                    // run AFTER the captures it follows, and it advances last_hlc.
                    withdraw_hlcs.push(entry.hlc);
                }
                _ => continue,
            }
        }

        // Apply ALL events in strict (hlc, tie) order. Bundles tie before
        // withdraws at equal HLC (tie = first-seen index; withdraw ties offset
        // past every bundle).
        enum Event {
            Bundle(RowKey),
            Withdraw(HLC),
        }
        let mut events: Vec<(HLC, usize, Event)> =
            Vec::with_capacity(bundle_order.len() + withdraw_hlcs.len());
        for (i, key) in bundle_order.iter().enumerate() {
            events.push((key.2, i, Event::Bundle(*key)));
        }
        let withdraw_tie_base = bundle_order.len();
        for (j, h) in withdraw_hlcs.iter().enumerate() {
            events.push((*h, withdraw_tie_base + j, Event::Withdraw(*h)));
        }
        events.sort_by(|a, b| a.0.cmp(&b.0).then(a.1.cmp(&b.1)));

        for (_, _, ev) in events {
            match ev {
                Event::Bundle(key) => {
                    let sign = *bundle_sign.get(&key).unwrap_or(&1);
                    let bm = bundle.remove(&key).unwrap_or_default();
                    let vs = value_bundle.remove(&key).unwrap_or_default();
                    tier.apply_capture(&bm, &vs, key.2, sign);
                }
                Event::Withdraw(h) => {
                    tier.live_row_count = (tier.live_row_count - 1).max(0);
                    if h > tier.last_hlc {
                        tier.last_hlc = h;
                    }
                }
            }
        }
    }

    /// Rebuild the T (temporal causality) matrix from the unified audit log.
    ///
    /// Mirrors Swift `MatrixTier.rebuildTemporal(from:)` exactly. This is
    /// SEPARATE from `rebuild`, which populates F, C, and O. Temporal causality
    /// crosses *pairs* of rows captured at different times; F/O derive from
    /// individual rows. A full estate hydrate calls both:
    ///
    ///   let mut tier = MatrixTier::rebuild(&log);
    ///   let t_tier   = MatrixTier::rebuild_temporal(&log);
    ///   tier.temporal_causality    = t_tier.temporal_causality;
    ///   tier.temporal_watermark_hlc = t_tier.temporal_watermark_hlc;
    ///
    /// Implementation:
    ///   1. Filter log to capture/expunge verbs (same filter as `rebuild`).
    ///   2. Convert each UnifiedAuditEntry → TemporalAuditEntry using the
    ///      canonical after-value encoding:
    ///        .Bitmap(v)   → "bitmap:{v}"
    ///        .StringValue → "string:{s}"
    ///        .Integer(v)  → "integer:{v}"
    ///        .Bytes(b)    → "bytes:{count}"
    ///        .Null        → empty coord list (no coordinate, watermark advances)
    ///   3. Call `temporal_causality_fold::fold` with ZERO start watermark
    ///      (full rebuild always replays the full log).
    ///   4. Map each TemporalCausalityKey → (source, target, lag_bucket) and
    ///      call `apply_temporal_event` for each delta.
    ///   5. Set `temporal_watermark_hlc` to the fold's returned new_watermark.
    ///
    /// The rebuild is idempotent on the same log: replaying the same log twice
    /// from a fresh MatrixTier produces a cell-equal result because T counts
    /// pairs and the fold is deterministic.
    pub fn rebuild_temporal(log: &UnifiedAuditLog) -> Self {
        Self::rebuild_temporal_from(log, HLC::ZERO, &HashMap::new())
    }

    /// Rebuild T starting from a given watermark. Mirrors Swift
    /// `rebuildTemporal(from:startWatermark:)`. A full rebuild passes
    /// `HLC::ZERO` (process every entry as new); incremental hydration passes the
    /// persisted `temporal_watermark_hlc` so the fold emits only the new
    /// cross-pairs — including window-boundary pairs against pre-watermark
    /// entries — which merge additively onto the loaded T.
    pub fn rebuild_temporal_from(
        log: &UnifiedAuditLog,
        start_watermark: HLC,
        event_times: &HashMap<EntryUUID, i64>,
    ) -> Self {
        let mut tier = MatrixTier::new();

        // Temporal causality keys off the AUTHORED-IN-WORLD clock (event_time),
        // never the capture HLC — ADR-004: "all temporal-cognition primitives
        // key off eventTime, not filedAt." A bulk historical import stamps every
        // drawer with one capture HLC, so hlc-based lags are all 0 and no pairs
        // form; the real causal structure lives in each drawer's event_time. We
        // substitute event_time (ms) into the entry's physical_time, preserving
        // the real HLC's logical_count/node_id for a deterministic tie-break,
        // then re-sort into event_time order. Empty map (streaming/conformance,
        // event_time == capture_time) -> real HLC -> byte-identical. Mirrors Swift.
        let temporal_clock = |entry: &UnifiedAuditEntry| -> HLC {
            match event_times.get(&entry.row_id) {
                Some(&ev) => HLC {
                    physical_time: ev,
                    logical_count: entry.hlc.logical_count,
                    node_id: entry.hlc.node_id,
                },
                None => entry.hlc,
            }
        };

        // INCREMENTAL PRUNE (launch cost): drop entries older than one window
        // before the watermark — they emit no delta. The watermark and the entry
        // clock are both in event_time space, so the cutoff is consistent. A full
        // rebuild (start_watermark == ZERO) keeps every entry (cutoff i64::MIN).
        let temporal_cutoff_ms: i64 = if start_watermark == HLC::ZERO {
            i64::MIN
        } else {
            start_watermark.physical_time - (Self::TEMPORAL_WINDOW_MINUTES as i64) * 60_000
        };
        // Build (original_index, clock, coords); the index is a deterministic
        // secondary sort key so two rows with an identical substituted clock
        // order identically on both ports.
        let mut built: Vec<(usize, HLC, Vec<TemporalFieldCoord>)> = log
            .ordered_entries()
            .into_iter()
            .enumerate()
            .filter_map(|(idx, entry)| {
                if !matches!(entry.verb, UnifiedAuditVerb::Capture | UnifiedAuditVerb::Expunge) {
                    return None;
                }
                let clock = temporal_clock(&entry);
                if clock.physical_time < temporal_cutoff_ms {
                    return None;
                }
                let field_coords: Vec<TemporalFieldCoord> = match &entry.after_value {
                    UnifiedAuditValue::Bitmap(v) => vec![TemporalFieldCoord::new(
                        entry.field_path.clone(),
                        format!("bitmap:{}", v),
                    )],
                    UnifiedAuditValue::StringValue(s) => vec![TemporalFieldCoord::new(
                        entry.field_path.clone(),
                        format!("string:{}", s),
                    )],
                    UnifiedAuditValue::Integer(v) => vec![TemporalFieldCoord::new(
                        entry.field_path.clone(),
                        format!("integer:{}", v),
                    )],
                    UnifiedAuditValue::Bytes(b) => vec![TemporalFieldCoord::new(
                        entry.field_path.clone(),
                        format!("bytes:{}", b.len()),
                    )],
                    // Null after-value contributes no coordinate; the entry
                    // advances the watermark but generates no T pairs.
                    // Mirrors Swift: "case .null: coords = []"
                    UnifiedAuditValue::Null => vec![],
                };
                Some((idx, clock, field_coords))
            })
            .collect();
        built.sort_by(|a, b| a.1.cmp(&b.1).then_with(|| a.0.cmp(&b.0)));
        let temporal_entries: Vec<TemporalAuditEntry> = built
            .into_iter()
            .map(|(_, clock, coords)| TemporalAuditEntry::new(clock, coords))
            .collect();

        // Fold from the supplied watermark: ZERO for a full rebuild (every entry
        // is "new"), or the persisted temporal_watermark_hlc for incremental
        // hydration (only new cross-pairs emitted).
        let result = tcf_fold(
            &temporal_entries,
            Self::TEMPORAL_WINDOW_MINUTES as i32,
            start_watermark,
        );

        for (fold_key, delta) in result.deltas {
            // Map TemporalCausalityKey → (source, target, delta_minutes) for
            // apply_temporal_event. Pass lag_bucket directly as delta_minutes:
            // apply_temporal_event calls lag_bucket_for_minutes internally
            // and the bucket value maps to itself for every boundary value in
            // {1,2,4,8,16,32,64,128}.
            let src = MatrixValueCoord::new(
                fold_key.source.field_path.clone(),
                decode_value_repr(&fold_key.source.value_repr),
            );
            let tgt = MatrixValueCoord::new(
                fold_key.target.field_path.clone(),
                decode_value_repr(&fold_key.target.value_repr),
            );
            // lag_bucket is already a boundary value, so passing it as
            // delta_minutes maps to the same bucket inside apply_temporal_event.
            tier.apply_temporal_event(src, tgt, fold_key.lag_bucket as u32, delta);
        }

        tier.temporal_watermark_hlc = result.new_watermark;
        tier
    }

    /// Rebuild all matrix components (F, O, C, T) from the unified audit log
    /// in a single call.
    ///
    /// Mirrors `MatrixTier.fullRebuild(from:)` in Swift. Runs both passes and
    /// merges the temporal tier's T matrix and watermark into the F/O/C tier:
    ///
    ///   Pass 1 (`rebuild`):          populates F, O, C, live_row_count, last_hlc.
    ///   Pass 2 (`rebuild_temporal`): populates T, temporal_watermark_hlc.
    ///
    /// In Rust the `temporal_causality` and `temporal_watermark_hlc` fields are
    /// public, so the merge is performed directly (unlike Swift where
    /// `private(set)` required the merge to live inside the type). Both fields
    /// are overwritten from the temporal tier because a fresh `MatrixTier::new()`
    /// starts both at their zero values.
    ///
    /// Use this for hydrate-on-launch sequences (REPLICATION_GROUND_TRUTH.md §7)
    /// where the ordering contract is:
    ///   1. rows copied
    ///   2. audit events copied
    ///   3. matrix rebuild (both passes, in order)
    pub fn full_rebuild(log: &UnifiedAuditLog, event_times: &HashMap<EntryUUID, i64>) -> Self {
        // Pass 1: F, O, C, live_row_count, last_hlc.
        let mut tier = MatrixTier::rebuild(log);
        // Pass 2: T, temporal_watermark_hlc. Keys off event_time (ADR-004); the
        // map is empty for streaming/conformance (event_time == capture_time).
        let t_tier = MatrixTier::rebuild_temporal_from(log, HLC::ZERO, event_times);
        // Merge T into the F/O/C tier. Fields are pub in Rust so no helper needed.
        tier.temporal_causality = t_tier.temporal_causality;
        tier.temporal_watermark_hlc = t_tier.temporal_watermark_hlc;
        tier
    }

    /// Fold this (already-loaded snapshot) tier FORWARD over `log`, applying only
    /// the entries past the persisted cursors — the load-and-incremental-fold path
    /// that replaces a full rebuild on hydration so the matrix tier is read from
    /// its on-disk snapshot, never recomputed from the whole audit log on launch.
    /// Mirrors Swift `MatrixTier.incrementalUpdate(from:)`.
    ///
    /// F/O/C: replays capture/expunge/withdraw entries with `hlc > last_hlc`
    /// directly onto this tier via the shared `apply_capture_entries` (a row's
    /// fields share one HLC, so the cursor splits cleanly on row boundaries, and a
    /// post-snapshot expunge of a pre-snapshot row lands its `-1` on the existing
    /// count). T: re-folds the full log from `temporal_watermark_hlc`, so only the
    /// new cross-pairs — including window-boundary pairs against pre-watermark
    /// entries — are emitted and merged additively.
    ///
    /// Invariant (conformance-tested): for any whole-HLC split point, a snapshot
    /// `full_rebuild(prefix)` then `incremental_update(full_log)` equals
    /// `full_rebuild(full_log)` cell-for-cell.
    pub fn incremental_update(
        &mut self,
        log: &UnifiedAuditLog,
        event_times: &HashMap<EntryUUID, i64>,
    ) {
        // F/O/C — replay rows past the field cursor directly onto self.
        let fo_cursor = self.last_hlc;
        let new_entries: Vec<UnifiedAuditEntry> = log
            .ordered_entries()
            .into_iter()
            .filter(|e| e.hlc > fo_cursor)
            .collect();
        Self::apply_capture_entries(self, new_entries);

        // T — fold from the persisted temporal watermark (event_time space,
        // ADR-004); the fold emits only new cross-pairs, merged additively.
        let t_delta =
            MatrixTier::rebuild_temporal_from(log, self.temporal_watermark_hlc, event_times);
        for (key, count) in t_delta.temporal_causality {
            add_signed(&mut self.temporal_causality, key, count);
        }
        if t_delta.temporal_watermark_hlc > self.temporal_watermark_hlc {
            self.temporal_watermark_hlc = t_delta.temporal_watermark_hlc;
        }
    }
}

/// Decode a `TemporalFieldCoord.value_repr` string back to a
/// `UnifiedAuditValue`. Mirrors Swift `MatrixTier.decodeValueRepr(_:)`.
///
/// Encoding (applied in `rebuild_temporal`):
///   "bitmap:{v}"    → Bitmap(v)
///   "string:{s}"    → StringValue(s)
///   "integer:{v}"   → Integer(v)
///   "bytes:{count}" → Bytes([]) (content not round-tripped; only field
///                     identity matters for T-matrix keying)
///   "null"          → Null
///   anything else   → StringValue(repr) (safe fallback, matches Swift)
fn decode_value_repr(repr: &str) -> UnifiedAuditValue {
    if repr == "null" {
        return UnifiedAuditValue::Null;
    }
    if let Some(rest) = repr.strip_prefix("bitmap:") {
        if let Ok(v) = rest.parse::<u64>() {
            return UnifiedAuditValue::Bitmap(v);
        }
    }
    if let Some(rest) = repr.strip_prefix("integer:") {
        if let Ok(v) = rest.parse::<i64>() {
            return UnifiedAuditValue::Integer(v);
        }
    }
    if repr.starts_with("bytes:") {
        // Bytes content is not round-tripped; only the field identity
        // matters for T-matrix keying.
        return UnifiedAuditValue::Bytes(vec![]);
    }
    if let Some(rest) = repr.strip_prefix("string:") {
        return UnifiedAuditValue::StringValue(rest.to_string());
    }
    // Safe fallback: treat unknown reprs as string values. Matches Swift.
    UnifiedAuditValue::StringValue(repr.to_string())
}

fn add_signed<K: std::hash::Hash + Eq>(map: &mut HashMap<K, i64>, key: K, delta: i64) {
    let next = map.get(&key).copied().unwrap_or(0) + delta;
    if next > 0 {
        map.insert(key, next);
    } else {
        map.remove(&key);
    }
}
