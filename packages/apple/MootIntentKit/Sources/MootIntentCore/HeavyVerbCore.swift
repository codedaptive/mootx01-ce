import Foundation
import AriaMCP   // JSONValue

// MARK: - Heavy-verb core  (M-MXA-3R)
//
// Identifier-free execution + progress plumbing for the four heavy ARIA
// verbs. Same core/surface split as batch curation (M-MXA-2R): this file is
// kit-floor, symbol-free of 2027-wave APIs, and fully testable on a macOS 26
// host; the LongRunningIntent/CancellableIntent surface lives in
// HeavyVerbIntents.swift, @available 27.
//
// Verb semantics, verified in the dispatcher (cancellation table source):
//   - reindex        → moot_reindex RETURNS IMMEDIATELY; work runs detached
//                      in the server; moot_drain_status is the progress feed.
//                      Cancel = stop watching; the substrate task is not
//                      interruptible and runs to completion by design.
//   - palace import  → moot_palace_import BLOCKS until done; the four import
//                      guards (tombstone/dedup/sensitivity floor/tunnel
//                      signature) are applied inside the call. Cancel =
//                      abandon the wait; the call itself completes, so a
//                      cancelled import can NEVER leave a partial-guard
//                      state. Progress feed: drain status (encode queue).
//   - vault import   → moot_vault_import, same blocking/guard/cancel shape.
//   - dream          → moot_dream BLOCKS (accelerator rebuild + one dreaming
//                      cycle). Cancel = abandon the wait, same rationale.

/// One drain's snapshot from `moot_drain_status`.
public struct DrainSnapshot: Sendable, Equatable {
    public let name: String
    public let isDraining: Bool
    public let pending: Int
    public let inFlight: Int

    public init(name: String, isDraining: Bool, pending: Int, inFlight: Int) {
        self.name = name
        self.isDraining = isDraining
        self.pending = pending
        self.inFlight = inFlight
    }
}

public enum HeavyVerbCore {

    // MARK: verbs

    /// Kick a reindex. Returns the tool's acknowledgement text (also the
    /// "already running" text — the server enforces single-flight).
    public static func startReindex(caller: any MootToolCalling) async throws -> String {
        try await call("moot_reindex", [:], caller: caller)
    }

    public static func importPalace(
        path: String, background: Bool, caller: any MootToolCalling
    ) async throws -> String {
        try await call("moot_palace_import", [
            "palace_path": .string(path),
            "mode": .string(background ? "background" : "foreground"),
        ], caller: caller)
    }

    public static func importVault(
        path: String, background: Bool, caller: any MootToolCalling
    ) async throws -> String {
        try await call("moot_vault_import", [
            "vaultPath": .string(path),
            "mode": .string(background ? "background" : "foreground"),
        ], caller: caller)
    }

    public static func dream(caller: any MootToolCalling) async throws -> String {
        try await call("moot_dream", [:], caller: caller)
    }

    private static func call(
        _ tool: String, _ args: [String: JSONValue], caller: any MootToolCalling
    ) async throws -> String {
        let result = await caller.callTool(tool, arguments: args)
        if result.isError { throw IntentToolError.substrateRefused(result.text) }
        return result.text
    }

    // MARK: progress feed

    /// Snapshot the drain queues (the progress feed for every heavy verb).
    public static func drainSnapshots(caller: any MootToolCalling) async -> [DrainSnapshot] {
        let result = await caller.callTool("moot_drain_status", arguments: [:])
        guard !result.isError else { return [] }
        return parseDrainStatus(result.text)
    }

    /// Parse `moot_drain_status` text:
    ///   drains: N
    ///     <name>: draining|idle — pending: X, in_flight: Y[, detail]
    /// "drains: none" and malformed lines parse to []. Pure, testable.
    public static func parseDrainStatus(_ text: String) -> [DrainSnapshot] {
        var out: [DrainSnapshot] = []
        for raw in text.split(separator: "\n").dropFirst() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let nameEnd = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<nameEnd])
            let rest = line[line.index(after: nameEnd)...]
            let isDraining = rest.contains("draining")
            guard let pending = intField("pending:", in: rest),
                  let inFlight = intField("in_flight:", in: rest) else { continue }
            out.append(DrainSnapshot(
                name: name, isDraining: isDraining, pending: pending, inFlight: inFlight
            ))
        }
        return out
    }

    private static func intField(_ label: String, in text: Substring) -> Int? {
        guard let range = text.range(of: label) else { return nil }
        let tail = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
        let digits = tail.prefix(while: \.isNumber)
        return Int(digits)
    }

    /// Outstanding work across all drains — the number a Progress object
    /// counts down. Zero with nothing draining means "settled".
    public static func outstandingWork(_ snapshots: [DrainSnapshot]) -> Int {
        snapshots.reduce(0) { $0 + $1.pending + $1.inFlight }
    }
}
