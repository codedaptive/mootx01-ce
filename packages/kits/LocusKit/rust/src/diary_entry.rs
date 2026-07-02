//! Diary entry struct. Ports `DiaryEntry.swift`.
//!
//! A first-person record written by an agent. Diary entries are the
//! audit trail of what an agent thought, did, or learned at a point in
//! time. They live alongside drawers in the MemPalace surface but are
//! queried separately so that an agent's diary can be read back
//! chronologically.
//!
//! `wing` defaults conventionally to `wing_<agent_name>` and `room` to
//! `"diary"` (callers honour the convention; the type does not enforce
//! it). The wing-per-agent convention exists so that one agent's diary
//! cannot leak into another's search results when wing filtering is
//! applied.
//!
//! `embedding_model_id` is present from Rev 1.0 for the same reason as
//! on `Drawer`: the modelID-tagging contract must be enforceable from
//! day one even though embeddings are not generated in this rung.
//!
//! `tombstoned_at` and `removed_by_batch` are present from Rev 1.0 so
//! the schema does not need to migrate when the soft-delete workflow
//! lands.
//!
//! ## Swift-to-Rust shape changes
//!
//! - `Date filedAt` → `i64 filed_at` (epoch milliseconds, ADR-023). Same convention
//!   across the LocusKit Rust port.
//! - `Date? tombstonedAt` → `Option<i64> tombstoned_at`.
//! - `id: String = UUID().uuidString` Swift default → Rust callers
//!   supply `id` explicitly.

/// A first-person record written by an agent.
///
/// Mirrors `DiaryEntry.swift` field-for-field.
// `Eq` and `Hash` cannot be derived because `reward: Option<f64>` does not
// implement them (f64 is not Hash). `PartialEq` is sufficient for test
// assertions and is retained.
#[derive(Debug, Clone, PartialEq)]
pub struct DiaryEntry {
    /// Stable identifier supplied by the caller.
    pub id: String,

    /// Name of the agent that wrote this entry.
    pub agent_name: String,

    /// The entry text. Verbatim, no transformation.
    pub entry: String,

    /// Free-form topic tag. Used by callers to group entries by
    /// session, project, or theme; LocusKit does not validate.
    pub topic: String,

    /// Wing this entry is filed under. Conventionally
    /// `wing_<agent_name>`; not enforced here.
    pub wing: String,

    /// Room within the wing. Conventionally `"diary"`; not enforced
    /// here.
    pub room: String,

    /// When the entry was written. Epoch seconds in the Rust port; the
    /// SQLite column is TEXT ISO8601 per the fleet rule.
    pub filed_at: i64,

    /// Identifier of the embedding model that produced (or will
    /// produce) the vector for this entry.
    pub embedding_model_id: String,

    /// When this entry was tombstoned, if it has been. Reserved for
    /// the Rev 2.0 soft-delete workflow.
    pub tombstoned_at: Option<i64>,

    /// Batch identifier used for receipt-based rollback of a
    /// tombstone. Reserved for the Rev 2.0 soft-delete workflow.
    pub removed_by_batch: Option<String>,

    /// Operational bitmap encoding `DiaryEventClass` (bits 0–3),
    /// `DiarySeverity` (bits 4–6), `DiaryActorClass` (bits 7–9),
    /// `DiaryBatchMembership` (bits 10–12), and `requires_followup`
    /// (bit 13) per spec § 5.6. Bits 14–63 reserved. Defaults to 0
    /// (capture / trace / user / standalone / informational). Decoded
    /// via the accessors in `diary_operational.rs`.
    pub operational_bitmap: i64,

    /// Explicit quality signal assigned at write time — the
    /// `DiaryEntry.reward` field that satisfies NEURONKIT_SPEC § 3.1
    /// step 1a. When `Some(v)`, `v` is a score in `[0, 1]` supplied by
    /// the caller (user rating, model confidence, etc.). When `None` the
    /// dreaming daemon falls back to the implicit `RecallTraceItem.used`
    /// source (step 1b). Stored as REAL nullable in SQLite.
    pub reward: Option<f64>,

    /// Human-readable provenance tag for how `reward` was derived.
    /// Examples: `"user-rating"`, `"model-confidence"`. `None` when
    /// `reward` is `None`. Stored as TEXT nullable.
    pub reward_provenance: Option<String>,
}

impl DiaryEntry {
    /// Construct an entry with `operational_bitmap = 0`, no tombstone
    /// fields, and no explicit reward. Mirrors the Swift designated
    /// initializer's defaulting behaviour.
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        id: String,
        agent_name: String,
        entry: String,
        topic: String,
        wing: String,
        room: String,
        filed_at: i64,
        embedding_model_id: String,
    ) -> Self {
        DiaryEntry {
            id,
            agent_name,
            entry,
            topic,
            wing,
            room,
            filed_at,
            embedding_model_id,
            tombstoned_at: None,
            removed_by_batch: None,
            operational_bitmap: 0,
            reward: None,
            reward_provenance: None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> DiaryEntry {
        DiaryEntry::new(
            "d-1".to_string(),
            "skippy".to_string(),
            "session note".to_string(),
            "session-2026-05-23".to_string(),
            "wing_skippy".to_string(),
            "diary".to_string(),
            1_700_000_000,
            "test-v1".to_string(),
        )
    }

    #[test]
    fn defaults_match_swift_initializer() {
        let e = sample();
        assert_eq!(e.operational_bitmap, 0);
        assert_eq!(e.tombstoned_at, None);
        assert_eq!(e.removed_by_batch, None);
    }

    #[test]
    fn fields_round_trip() {
        let mut e = sample();
        e.operational_bitmap = 0xFF;
        e.tombstoned_at = Some(1_700_001_000);
        e.removed_by_batch = Some("b-1".to_string());

        let cloned = e.clone();
        assert_eq!(cloned, e);
    }

    #[test]
    fn equality_is_field_wise() {
        let e1 = sample();
        let mut e2 = sample();
        assert_eq!(e1, e2);
        e2.entry = "different".to_string();
        assert_ne!(e1, e2);
    }
}
