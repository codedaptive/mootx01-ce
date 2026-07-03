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
    /// Rows per bulk `captureBatch` transaction (NOT user-controlled). The palace
    /// bulk path submits frames in windows of this size — one transaction per
    /// window — so no single transaction materializes an unbounded classified
    /// batch in memory or holds the SQLite write lock across an arbitrarily
    /// large source (codex 26c7a364). A source at or under the window is one
    /// transaction, identical to the pre-window behavior; larger sources split
    /// into ceil(n / 125_000) sequential transactions. Atomicity is per WINDOW:
    /// a failure rolls back the current window only (earlier windows stay
    /// committed — acceptable for import, which is lineage-idempotent and
    /// re-runnable). Mirrors Rust `import_policy::BULK_WINDOW`.
    static let bulkWindow = 125_000

    /// Source-size gate for the RETIRED per-item streaming write strategy. The
    /// stream branch is disabled (2026-07-02, see PalaceBridge) and queued for
    /// removal at the 1.1 release gate; this constant and `useBulk` are kept so
    /// the preserved-verbatim disabled branch still reads true at the 1.1
    /// review. The ACTIVE large-source safety valve is `bulkWindow` above. The
    /// Obsidian / OKF gate (VaultBridge) still consults `useBulk` live.
    static let streamThreshold = 250_000

    /// Whether a source of `itemCount` items should be written bulk (`true`) or
    /// streamed per-item (`false`). Live for VaultBridge; PalaceBridge's copy of
    /// this gate is disabled (bulk unconditional, windowed by `bulkWindow`).
    static func useBulk(itemCount: Int) -> Bool {
        itemCount <= streamThreshold
    }
}
