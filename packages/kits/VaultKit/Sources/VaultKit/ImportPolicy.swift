// ImportPolicy.swift
//
// The single source of truth for the import write-strategy policy shared by
// EVERY source gate — MemPalace (PalaceBridge), Obsidian / OKF / Markdown vaults
// (VaultBridge). The gates differ only in how they READ a source and build
// CaptureFrames; the downstream is identical for all of them: capture →
// enqueue → drain → encode. This type holds the one policy knob that decision
// shares, so adding a new gate never re-invents the write strategy ("the ingest
// module is just a different gate").
//
// Mirrors the Rust `import_policy` constants.

/// The import write-strategy policy. SPEED (foreground/background drain QoS) is
/// caller-declared per import and lives on `EncodeSpeed`; the WRITE strategy
/// (bulk transaction vs per-item stream) is chosen automatically by source size
/// via `streamThreshold` — never by the caller.
enum ImportPolicy {
    /// Source-size gate for write strategy (NOT user-controlled). A source with
    /// this many items or fewer is written in one bulk `captureBatch` transaction
    /// (fast, one fsync); a larger source streams via per-item `capture()` so no
    /// single transaction holds the write lock across hundreds of thousands of
    /// rows. 250k mirrors the ">250k records" boundary at which a single bulk
    /// transaction stops being safe; tune here (one place, all gates) if it moves.
    static let streamThreshold = 250_000

    /// Whether a source of `itemCount` items should be written in one bulk
    /// transaction (`true`) or streamed per-item (`false`).
    static func useBulk(itemCount: Int) -> Bool {
        itemCount <= streamThreshold
    }
}
