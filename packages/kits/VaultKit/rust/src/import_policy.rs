//! import_policy.rs — the single source of truth for the import write-strategy
//! policy shared by EVERY source gate: MemPalace (palace_bridge), Obsidian / OKF
//! / Markdown vaults (vault_bridge). Gates differ only in how they READ a source
//! and build CaptureFrames; the downstream is identical for all of them
//! (capture → enqueue → drain → encode). This module holds the one policy knob
//! they share, so a new gate never re-invents the write strategy ("the ingest
//! module is just a different gate"). Mirrors Swift `ImportPolicy`.

/// Rows per bulk `capture_batch` transaction (NOT user-controlled). The palace
/// bulk path submits frames in windows of this size — one transaction per
/// window — so no single transaction materializes an unbounded classified batch
/// in memory or holds the SQLite write lock across an arbitrarily large source
/// (codex 26c7a364). A source at or under the window is one transaction,
/// identical to the pre-window behavior; larger sources split into
/// ceil(n / 125_000) sequential transactions. Atomicity is per WINDOW: a
/// failure rolls back the current window only (earlier windows stay committed
/// — acceptable for import, which is lineage-idempotent and re-runnable).
pub const BULK_WINDOW: usize = 125_000;

/// Source-size gate for the RETIRED per-item streaming write strategy. The
/// stream branch is disabled (2026-07-02, see palace_bridge) and queued for
/// removal at the 1.1 release gate; this constant and `use_bulk` are kept so
/// the preserved-verbatim disabled branch still reads true at the 1.1 review.
/// The ACTIVE large-source safety valve is `BULK_WINDOW` above. The Obsidian /
/// OKF gate (vault_bridge) still consults `use_bulk` live.
pub const STREAM_THRESHOLD: usize = 250_000;

/// Whether a source of `item_count` items should be written bulk (`true`) or
/// streamed per-item (`false`). Live for vault_bridge; palace_bridge's copy of
/// this gate is disabled (bulk unconditional, windowed by `BULK_WINDOW`).
pub fn use_bulk(item_count: usize) -> bool {
    item_count <= STREAM_THRESHOLD
}
