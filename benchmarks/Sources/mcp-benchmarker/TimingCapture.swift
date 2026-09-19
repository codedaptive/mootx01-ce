// TimingCapture.swift
// C4 (benchmark reset 2026-08-13): leg-level capture of the estate's
// audit-derived timing report — the four CYCLE tiers plus INGEST samples —
// via the moot_timing_report maintenance tool (C3+A6 derivation engine,
// §6b one-derivation-two-consumers; the harness is the first consumer).
//
// The harness cannot link the kits (layering rule: benchmark deps are
// IntellectusLib + ObserverSink only), so the tiers arrive as the tool's
// rendered report text and are embedded verbatim in the lane report JSON.
// The renderer is byte-compatible across the Swift and Rust servers, so
// the embedded text also serves cross-port parity diffs.

import Foundation

/// Manages timing-report capture across the units of one benchmark leg.
///
/// Create one sampler at the start of a leg; call `capture(using:)` at each
/// unit's settle point (after ingest → drain → dream → reindex, while the
/// unit's estate is still alive). The fetch closure runs on the FIRST unit
/// only; all subsequent units return the cached text with no MCP calls
/// issued. Sampling once per leg mirrors the DegeneracyGuard precedent
/// (C5): every unit of a leg builds the same estate shape, so one settled
/// estate's timing profile represents the leg. The report labels the
/// sampling explicitly (`timing_sampling`) so the cap is never silent.
///
/// Thread-safety: an actor, safe under C6 parallel units — concurrent
/// callers serialise here, and exactly one issues the fetch.
public actor LegTimingSampler {

    /// True once the first capture attempt has completed (even if it failed —
    /// a fetch error is not retried on later units; the report field stays
    /// nil and the failure was already logged by the caller).
    private var captured = false
    /// The report text from the first unit's capture. Nil until captured,
    /// and nil permanently when the first fetch failed.
    private var cachedReport: String?

    public init() {}

    /// Executes or skips the timing-report fetch for one unit.
    ///
    /// - `fetch`: async closure that calls `moot_timing_report` on the unit's
    ///   live MCP client and returns the report text (nil on error). Called
    ///   only on the leg's first unit.
    /// - Returns: the leg's timing report text (first unit's capture), or nil
    ///   when the first capture failed.
    public func capture(
        using fetch: @Sendable () async -> String?
    ) async -> String? {
        if captured { return cachedReport }
        captured = true
        cachedReport = await fetch()
        return cachedReport
    }

    /// The leg's captured report text without triggering a fetch. Nil when
    /// no unit reached a capture point (e.g. every unit restored from the
    /// artifact cache) or the first capture failed.
    public func text() -> String? {
        cachedReport
    }
}

/// Calls `moot_timing_report` on a live client and returns the rendered
/// report text. A full-history scan (no `since_ms`) is correct here: lane
/// estates are born inside the run, so the audit log holds exactly this
/// unit's activity and no watermark is needed.
///
/// Errors are swallowed into nil by design — timing capture is
/// observability riding an accuracy lane, and a capture failure must never
/// abort a measurement run. The caller logs the miss.
func fetchTimingReport(client: MCPClient) async -> String? {
    guard let result = try? await client.callTool(
        AriaV2Surface.timingReport,
        arguments: [:],
        format: .mootV2
    ) else { return nil }
    let text = result.textBlocks.joined(separator: "\n")
    return text.isEmpty ? nil : text
}
