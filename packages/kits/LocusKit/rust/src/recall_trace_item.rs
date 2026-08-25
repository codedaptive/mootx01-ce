//! RecallTraceItem — the "later two-source reward" hook noun.
//!
//! Ports `RecallTraceItem.swift`. Every recall operation stamps one
//! `RecallTraceItem` per returned drawer row so the reward path can
//! later distinguish rows the user acted on (`used == true`) from rows
//! returned but ignored (`used == false`). Bradley-Terry (cookbook §8.12)
//! consumes this distinction when computing tournament weights.
//!
//! The `used` flag is bit 0 of `operational_bitmap` — no stored `bool`
//! field appears on this struct (schema invariant: all boolean state lives
//! in Int64 bitmap fields). The accessor method follows the canonical
//! bitmap-patterns contract.
//!
//! ## Bitmap reservation for RecallTraceItem.operational_bitmap
//!
//!   bit 0   used          ASSIGNED — true when the recalled row was
//!                         subsequently acted on by the reward path.
//!   bits 1–63  FREE (63 bits headroom).

// ---------------------------------------------------------------------------
// RecallTraceItem
// ---------------------------------------------------------------------------

/// A record of one row returned by a recall operation.
///
/// The struct is the Rust parallel of Swift `RecallTraceItem`. All fields
/// map directly; `score` is `Option<f64>` (nullable REAL) and `recalled_at`
/// is stored as a TEXT ISO8601 string in SQLite — the substrate's canonical
/// date storage format.
#[derive(Debug, Clone, PartialEq)]
pub struct RecallTraceItem {
    /// Stable identifier for this trace row.
    pub id: String,

    /// The recalled drawer's identifier.
    pub target: String,

    /// When the recall that produced this row was executed.
    /// Stored as TEXT ISO8601 in SQLite (fleet date-storage rule).
    pub recalled_at: String, // ISO8601 string; matching SQLite TEXT storage

    /// Similarity score assigned by the recall, if available. `None`
    /// means the recall did not produce a score for this row.
    pub score: Option<f64>,

    /// Operational bitmap. Bit 0 = used. Bits 1–63 reserved.
    /// Defaults to 0 (unused).
    pub operational_bitmap: i64,

    // Lane attribution (W2.5 Track R(a), schema v15). All nullable TEXT
    // in SQLite: `None` for rows written before v15 and for writers below
    // the recall coordinator (the plain locus recall verb has no door
    // identity). No query text is ever stored (privacy ruling 2026-08-20).
    /// Door identity — the tool or recipe that issued the recall
    /// (e.g. "memory_search", "recall_precise", "recall_temporal").
    pub door: Option<String>,

    /// Composition identity — the lane composition active at trace time
    /// (e.g. "unionBest/matrixAware", a shaped preset name).
    pub composition: Option<String>,

    /// Per-lane 1-based rank of `target` at trace time, packed as JSON in
    /// fixed lane order via [`RecallTraceItem::pack_lane_ranks`]. An absent
    /// key means that lane did not surface the target.
    pub lane_ranks: Option<String>,
}

impl RecallTraceItem {
    /// Bit 0 of `operational_bitmap`: the row was consumed by the two-source
    /// reward path. Mirrors `RecallTraceItem.flagUsed` in Swift.
    pub const FLAG_USED: i64 = 1 << 0; // bit 0

    /// Create a new `RecallTraceItem`.
    ///
    /// `recalled_at` is an ISO8601 string (TEXT in SQLite). Score is
    /// optional — pass `None` for ordered-by-capture-time recalls that
    /// produce no similarity score.
    pub fn new(
        id: impl Into<String>,
        target: impl Into<String>,
        recalled_at: impl Into<String>,
        score: Option<f64>,
        operational_bitmap: i64,
    ) -> Self {
        Self {
            id: id.into(),
            target: target.into(),
            recalled_at: recalled_at.into(),
            score,
            operational_bitmap,
            // Attribution defaults to None — the Swift twin defaults the
            // same three init parameters to nil. The recall coordinator is
            // the writer that fills them, via `with_attribution`.
            door: None,
            composition: None,
            lane_ranks: None,
        }
    }

    /// Return a copy carrying the lane-attribution trio (W2.5 Track R(a)).
    /// Mirrors the Swift initializer's defaulted `door:`/`composition:`/
    /// `laneRanks:` parameters — the recall coordinator is the only
    /// production caller.
    pub fn with_attribution(
        mut self,
        door: Option<String>,
        composition: Option<String>,
        lane_ranks: Option<String>,
    ) -> Self {
        self.door = door;
        self.composition = composition;
        self.lane_ranks = lane_ranks;
        self
    }

    /// The fixed lane-key emission order for `lane_ranks`. Must stay
    /// identical to Swift `RecallTraceItem.laneRankOrder` — the packed
    /// string is a cross-port conformance surface.
    pub const LANE_RANK_ORDER: [&'static str; 4] = ["locus", "bm25", "hamming", "dense"];

    /// Pack per-lane 1-based ranks into the canonical `lane_ranks` JSON
    /// string. Keys emit in `LANE_RANK_ORDER` (absent lanes skipped);
    /// an empty map returns `None`. Built by hand, not serde, because both
    /// ports must emit byte-identical strings for the same ranks and the
    /// keys are drawn from `LANE_RANK_ORDER` only (no escaping needed).
    pub fn pack_lane_ranks(ranks: &std::collections::HashMap<String, i64>) -> Option<String> {
        let mut parts: Vec<String> = Vec::new();
        for lane in Self::LANE_RANK_ORDER {
            if let Some(rank) = ranks.get(lane) {
                parts.push(format!("\"{lane}\":{rank}"));
            }
        }
        if parts.is_empty() {
            return None;
        }
        Some(format!("{{{}}}", parts.join(",")))
    }

    /// True when the two-source reward path has consumed this trace row.
    ///
    /// Backed by bit 0 of `operational_bitmap`; there is no stored bool
    /// field on this struct — all boolean state lives in bitmap fields.
    pub fn used(&self) -> bool {
        self.operational_bitmap & Self::FLAG_USED != 0
    }

    /// Return a new `RecallTraceItem` with bit 0 of `operational_bitmap`
    /// set. All other fields and bits are preserved.
    ///
    /// The Swift implementation persists the mutation to SQLite directly;
    /// this pure-value method applies the bitmap transformation so callers
    /// can construct the updated value to persist via their own storage layer.
    pub fn with_used(&self) -> Self {
        Self {
            operational_bitmap: self.operational_bitmap | Self::FLAG_USED,
            ..self.clone()
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn make_item(operational_bitmap: i64) -> RecallTraceItem {
        RecallTraceItem::new(
            "trace-001",
            "drawer-abc",
            "2024-01-01T00:00:00Z",
            None,
            operational_bitmap,
        )
    }

    // § 1  Bitmap constant

    #[test]
    fn flag_used_is_bit_zero() {
        // The constant must equal 1 (2^0). Any other value silently corrupts
        // on-disk data that existing rows carry.
        assert_eq!(RecallTraceItem::FLAG_USED, 1);
    }

    // § 2  used() accessor

    #[test]
    fn used_false_when_bitmap_zero() {
        let item = make_item(0);
        assert!(!item.used());
    }

    #[test]
    fn used_true_when_bit_zero_set() {
        let item = make_item(RecallTraceItem::FLAG_USED);
        assert!(item.used());
    }

    #[test]
    fn used_false_when_only_higher_bits_set() {
        // bit 1 only — used must remain false
        let item = make_item(2);
        assert!(!item.used());
    }

    // § 3  with_used() transformation

    #[test]
    fn with_used_sets_bit_zero() {
        let item = make_item(0);
        let marked = item.with_used();
        assert!(marked.used());
    }

    #[test]
    fn with_used_preserves_other_bits() {
        // Bit 2 pre-set; with_used must not clear it.
        let item = make_item(0b100);
        let marked = item.with_used();
        assert!(marked.used(), "bit 0 must be set after with_used");
        assert!(marked.operational_bitmap & 0b100 != 0, "bit 2 must survive");
    }

    #[test]
    fn with_used_is_idempotent() {
        let item = make_item(RecallTraceItem::FLAG_USED);
        let again = item.with_used();
        assert!(again.used());
        assert_eq!(again.operational_bitmap, RecallTraceItem::FLAG_USED);
    }

    #[test]
    fn with_used_does_not_mutate_original() {
        let item = make_item(0);
        let _ = item.with_used();
        assert!(!item.used(), "original must remain unchanged");
    }

    // § 4  Field identity

    #[test]
    fn fields_round_trip_through_new() {
        let item = RecallTraceItem::new("t-id", "d-target", "2024-06-15T10:30:00Z", Some(0.875), 0);
        assert_eq!(item.id, "t-id");
        assert_eq!(item.target, "d-target");
        assert_eq!(item.recalled_at, "2024-06-15T10:30:00Z");
        assert_eq!(item.score, Some(0.875));
        assert_eq!(item.operational_bitmap, 0);
    }

    #[test]
    fn score_none_round_trips() {
        let item = RecallTraceItem::new("t-nil", "d-nil", "2024-01-01T00:00:00Z", None, 0);
        assert!(item.score.is_none());
    }

    // § 5  Lane attribution (v15, W2.5 Track R(a))

    #[test]
    fn new_defaults_attribution_to_none() {
        let item = make_item(0);
        assert!(item.door.is_none());
        assert!(item.composition.is_none());
        assert!(item.lane_ranks.is_none());
    }

    #[test]
    fn with_attribution_carries_trio_and_with_used_preserves_it() {
        let item = make_item(0).with_attribution(
            Some("memory_search".to_string()),
            Some("unionBest/matrixAware".to_string()),
            Some("{\"locus\":1}".to_string()),
        );
        let marked = item.with_used();
        assert!(marked.used());
        assert_eq!(marked.door.as_deref(), Some("memory_search"));
        assert_eq!(marked.composition.as_deref(), Some("unionBest/matrixAware"));
        assert_eq!(marked.lane_ranks.as_deref(), Some("{\"locus\":1}"));
    }

    #[test]
    fn pack_lane_ranks_golden_pin() {
        // CROSS-PORT PIN: Swift `packLaneRanksGoldenPin` asserts the
        // identical string for the identical map. Lane order is
        // LANE_RANK_ORDER regardless of map iteration order.
        let ranks: std::collections::HashMap<String, i64> = [
            ("dense".to_string(), 2),
            ("locus".to_string(), 3),
            ("hamming".to_string(), 7),
            ("bm25".to_string(), 1),
        ]
        .into_iter()
        .collect();
        assert_eq!(
            RecallTraceItem::pack_lane_ranks(&ranks).as_deref(),
            Some("{\"locus\":3,\"bm25\":1,\"hamming\":7,\"dense\":2}")
        );
    }

    #[test]
    fn pack_lane_ranks_partial_and_empty() {
        let partial: std::collections::HashMap<String, i64> =
            [("dense".to_string(), 2), ("bm25".to_string(), 1)]
                .into_iter()
                .collect();
        assert_eq!(
            RecallTraceItem::pack_lane_ranks(&partial).as_deref(),
            Some("{\"bm25\":1,\"dense\":2}")
        );
        assert!(RecallTraceItem::pack_lane_ranks(&std::collections::HashMap::new()).is_none());
    }
}
