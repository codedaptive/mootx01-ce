import Foundation

// Manifest.swift — the transfer manifest, ground truth for verification.
//
// The manifest lists exactly what was transferred from source to target.
// The benchmarker verifies each manifest entry against the TARGET — the
// manifest, not the source's live state, is the authority for "did this
// item make it and rank correctly." This is what lets the accuracy floor
// be measured without hand-labeling: a transferred entry is a known item
// that must reappear at rank 1 when queried on the target.

/// Outcome of attempting to transfer one entry to the target. An enum, not
/// a Bool — a permanently failed entry is recorded as `.failed` rather than
/// silently dropped, so the manifest stays a complete record of the attempt.
enum TransferOutcome: String, Codable, Sendable, Equatable {
    case transferred
    case failed
}

/// One transferred entry. `transferredAt` is an ISO8601 TEXT timestamp.
struct ManifestEntry: Codable, Sendable, Equatable {
    let id: String
    let content: String
    let transferredAt: String
    let outcome: TransferOutcome
}

/// A single verification probe derived from a manifest entry: query the
/// target's `query` tool with the entry's content and expect the entry's
/// id at rank 1. The manifest is the ground truth for `expectedRank1ID`.
struct VerificationQuery: Sendable, Equatable {
    let queryTool: String        // the target's "query" verb
    let queryText: String        // what to search the target for
    let expectedRank1ID: String  // manifest ground truth: this id must rank 1
}

/// The ground-truth record of a transfer run.
struct Manifest: Codable, Sendable, Equatable {
    private(set) var entries: [ManifestEntry]
    /// Per-write capture latencies (seconds) measured during transfer. The
    /// manifest is the only artifact carried from the `transfer` subcommand
    /// to the separate `benchmark` subcommand, so the capture series is
    /// persisted here to let the benchmark report show all three latencies.
    private(set) var captureLatencies: [Double]

    init(entries: [ManifestEntry] = [], captureLatencies: [Double] = []) {
        self.entries = entries
        self.captureLatencies = captureLatencies
    }

    // Custom Codable so a manifest written without `captureLatencies` (or by
    // an older build) still decodes, defaulting the series to empty.
    private enum CodingKeys: String, CodingKey { case entries, captureLatencies }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.entries = try c.decode([ManifestEntry].self, forKey: .entries)
        self.captureLatencies = try c.decodeIfPresent([Double].self, forKey: .captureLatencies) ?? []
    }

    /// Appends a recorded entry.
    mutating func record(_ entry: ManifestEntry) {
        entries.append(entry)
    }

    /// Records one capture latency (seconds) measured while writing to target.
    mutating func recordCaptureLatency(_ seconds: Double) {
        captureLatencies.append(seconds)
    }

    /// True when an entry with this id was recorded (any outcome).
    func contains(id: String) -> Bool {
        entries.contains { $0.id == id }
    }

    /// One verification query per successfully transferred entry. Failed
    /// entries are excluded — there is nothing to verify on the target for
    /// an entry that never landed. Each query carries the manifest's
    /// expected rank-1 id, which is the ground truth the target is checked
    /// against.
    func verificationQueries(verbMap: EndpointConfig.VerbMap) -> [VerificationQuery] {
        entries
            .filter { $0.outcome == .transferred }
            .map { entry in
                VerificationQuery(
                    queryTool: verbMap.query,
                    queryText: entry.content,
                    expectedRank1ID: entry.id
                )
            }
    }
}
