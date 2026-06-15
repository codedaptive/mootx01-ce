//! SurfacedRecallLedger — per-session record of drawer ids surfaced to the
//! AI client by `moot_memory_search`.
//!
//! The ledger is the ARIA boundary implementation of the trace-reward wiring
//! design (DESIGN_TRACE_REWARD_2026-06-12.md). When `moot_memory_search`
//! surfaces a drawer, its id is recorded here with the wall-clock time of the
//! recall. When a subsequent dereference verb (`moot_withdraw_memory`,
//! `moot_update_memory`, `moot_confirm_memory`, `moot_move_memory`) acts on
//! a drawer id that is present in the ledger, this module calls
//! `coordinator.mark_recall_used` on that id so the dreaming daemon's reward
//! sweep later assigns reward 1.0.
//!
//! Scope of "used" (option E from the design memo = B∪C):
//!   - "surfaced" = the id appeared in a `moot_memory_search` result within
//!     the current stdio session.
//!   - "used" = the same id appears in a later dereference call.
//!   - Graph verbs (`moot_link_memories`, `moot_connection_map`) are NOT
//!     dereference verbs in v1 (read-only blind spot; accepted per design).
//!
//! The ledger is session-scoped (one per Dispatcher instance, i.e. one per
//! stdio connection). Entries are never pruned during the session; the memory
//! footprint is bounded by the session length × average result set size.
//! Entries carry the surfaced_at timestamp so `mark_recall_used` can pass the
//! correct `now` bound to the retention-window query.
//!
//! Interior mutability: the ledger is wrapped in `Mutex` so the `Dispatcher`
//! (which takes `&self`) can mutate session state without requiring `&mut`.

use std::collections::HashMap;
use std::sync::Mutex;

/// One entry in the ledger: the wall-clock time (seconds since Unix epoch)
/// when the drawer was surfaced to the client.
#[derive(Debug, Clone)]
pub struct LedgerEntry {
    /// The drawer id that was surfaced.
    pub drawer_id: String,
    /// Wall-clock time (seconds since Unix epoch, i64) when the drawer was
    /// surfaced by `moot_memory_search`. Used as the `now` upper-bound when
    /// `mark_recall_used` is called (the trace rows' `recalledAt` should be
    /// close to but not after this value in a real session; we pass `now +1`
    /// to account for sub-second jitter).
    pub surfaced_at_secs: i64,
}

/// Session-scoped ledger of drawer ids that were returned to the AI client
/// by `moot_memory_search`. Thread-safe via internal `Mutex`.
///
/// Use `record_surfaced` after a `moot_memory_search` call.
/// Use `note_usage` from a dereference verb to trigger the reward mark.
#[derive(Debug, Default)]
pub struct SurfacedRecallLedger {
    // map: drawer_id → LedgerEntry (last surfaced_at wins on duplicates)
    inner: Mutex<HashMap<String, LedgerEntry>>,
}

impl SurfacedRecallLedger {
    /// Create a new empty ledger.
    pub fn new() -> Self {
        Self::default()
    }

    /// Record that `drawer_ids` were just surfaced by `moot_memory_search`.
    ///
    /// `surfaced_at_secs` is the wall-clock time of the recall (Unix epoch
    /// seconds). Any existing entry for the same id is overwritten with the
    /// latest surfaced_at so the retention window stays current.
    pub fn record_surfaced(&self, drawer_ids: &[String], surfaced_at_secs: i64) {
        if let Ok(mut map) = self.inner.lock() {
            for id in drawer_ids {
                map.insert(
                    id.clone(),
                    LedgerEntry {
                        drawer_id: id.clone(),
                        surfaced_at_secs,
                    },
                );
            }
        }
    }

    /// Look up the ledger entry for `drawer_id`. Returns `None` if the id
    /// was never surfaced in this session.
    pub fn get(&self, drawer_id: &str) -> Option<LedgerEntry> {
        self.inner
            .lock()
            .ok()
            .and_then(|map| map.get(drawer_id).cloned())
    }

    /// Returns true if `drawer_id` was surfaced in this session.
    pub fn contains(&self, drawer_id: &str) -> bool {
        self.inner
            .lock()
            .ok()
            .map(|map| map.contains_key(drawer_id))
            .unwrap_or(false)
    }
}
