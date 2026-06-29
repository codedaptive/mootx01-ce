//! import_policy.rs — the single source of truth for the import write-strategy
//! policy shared by EVERY source gate: MemPalace (palace_bridge), Obsidian / OKF
//! / Markdown vaults (vault_bridge). Gates differ only in how they READ a source
//! and build CaptureFrames; the downstream is identical for all of them
//! (capture → enqueue → drain → encode). This module holds the one policy knob
//! they share, so a new gate never re-invents the write strategy ("the ingest
//! module is just a different gate"). Mirrors Swift `ImportPolicy`.

/// Source-size gate for write strategy (NOT user-controlled). A source with this
/// many items or fewer is written in one bulk `capture_batch` transaction (fast,
/// one fsync); a larger one streams via per-item capture so no single
/// transaction holds the write lock across hundreds of thousands of rows. 250k
/// mirrors the ">250k records" boundary at which a single bulk transaction stops
/// being safe; tune here (one place, all gates) if it moves.
pub const STREAM_THRESHOLD: usize = 250_000;

/// Whether a source of `item_count` items should be written in one bulk
/// transaction (`true`) or streamed per-item (`false`).
pub fn use_bulk(item_count: usize) -> bool {
    item_count <= STREAM_THRESHOLD
}
