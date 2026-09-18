// TimingSidecar.swift — timing sidecar written beside accuracy reports.
//
// REGISTER RULES (FINAL_REPORT_2026-08-20 §7):
//   - Accuracy report files carry figures + identity ONLY — timing NEVER enters
//     them. The accuracy report shape is UNCHANGED when --timing-sidecar is set.
//   - Timing goes to SIDECAR files (this module).
//   - One pass per cell. No overwrite (writeRecordNeverOverwrite enforces this).
//
// Activation: --timing-sidecar on any of the four accuracy lanes:
//   longmemeval, locomo, lmeb, membench.
// Default off: a run without the flag produces no sidecar, and the accuracy
// report is byte-identical in structure to a pre-sidecar run.
//
// Sidecar filename: <report-basename>.timing.json
//   e.g. lme-s-20260820T120000Z.json → lme-s-20260820T120000Z.timing.json

import Foundation

// MARK: - Sidecar types

/// Per-unit timing entry in the sidecar. One entry per measured query.
struct TimingSidecarUnit: Codable, Sendable {
    /// Unit identifier (questionID, itemID, or queryID depending on lane).
    /// Matches the identifier used in the accuracy report for cross-reference.
    let unitID: String
    /// Wall-clock duration of the moot_memory_search call, in seconds.
    let queryLatencySeconds: Double

    enum CodingKeys: String, CodingKey {
        case unitID = "unit_id"
        case queryLatencySeconds = "query_latency_seconds"
    }
}

/// Aggregate p50/p95 over all units in the sidecar.
struct TimingSidecarAggregate: Codable, Sendable {
    /// Number of units with a measured latency. May be less than the run's
    /// total unit count when some units lack latency data (e.g. LME arm=dense
    /// with no exact query).
    let count: Int
    /// Nearest-rank p50 of query_latency_seconds across all units.
    let p50Seconds: Double
    /// Nearest-rank p95 of query_latency_seconds across all units.
    let p95Seconds: Double

    enum CodingKeys: String, CodingKey {
        case count
        case p50Seconds = "p50_seconds"
        case p95Seconds = "p95_seconds"
    }
}

/// Timing sidecar written beside each accuracy report when --timing-sidecar is set.
///
/// Contains per-unit wall-clock query latency and aggregate p50/p95.
/// Does NOT contain recall figures — those stay in the accuracy report.
///
/// artifact_type = "timing_sidecar" so the file kind is unambiguous without
/// reading field names. The field distinguishes it from "throughput" artifacts
/// (ThroughputRunner.swift) and from the accuracy reports themselves.
struct TimingSidecar: Codable, Sendable {
    /// Constant type tag. Always "timing_sidecar".
    let artifactType: String
    /// Lane name: "longmemeval", "locomo", "lmeb", or "membench".
    let lane: String
    /// Run serial from --run-id or UTC timestamp. Matches the accuracy report's serial.
    let runID: String
    /// Binary and protocol identity, duplicated from the accuracy report.
    /// Allows the sidecar to be interpreted independently of the report.
    let runIdentity: IdentityEnvironment
    /// Per-unit query latencies in run order.
    let units: [TimingSidecarUnit]
    /// Aggregate p50 and p95 over all units.
    let aggregate: TimingSidecarAggregate

    enum CodingKeys: String, CodingKey {
        case artifactType = "artifact_type"
        case lane
        case runID = "run_id"
        case runIdentity = "run_identity"
        case units
        case aggregate
    }
}

// MARK: - Percentile

/// Nearest-rank percentile over an array of latency values.
///
/// Uses the same formula as TimingSeries.p95 and RollingSeries.p95 (this codebase's
/// established convention): rank = ⌈p × N⌉, index = clamp(rank - 1, 0, N-1).
/// Returns 0.0 when the input is empty.
///
/// - Parameters:
///   - values: Query latencies in any order (sorted internally).
///   - p: Percentile in [0.0, 1.0].
func latencyPercentile(values: [Double], p: Double) -> Double {
    guard !values.isEmpty else { return 0.0 }
    let sorted = values.sorted()
    let n = sorted.count
    let rank = Int((p * Double(n)).rounded(.up))
    let index = min(max(rank, 1) - 1, n - 1)
    return sorted[index]
}

// MARK: - Build

/// Builds a timing sidecar from per-unit latency measurements.
///
/// LME note: `queryLatencySeconds` is `Double?` on `LMEQuestionResult` — pass only
/// units where the value is non-nil (use the exact arm's value when non-nil,
/// the dense arm's `denseQueryLatencySeconds` otherwise). Units with no
/// measurable latency are excluded by the caller before calling this function.
///
/// - Parameters:
///   - lane: Lane name.
///   - runID: Run serial (from resolveRunSerial).
///   - identity: Binary identity duplicated from the accuracy report.
///   - unitLatencies: Ordered pairs of (unitID, queryLatencySeconds).
///     Units with nil latency are excluded before calling this function.
func makeTimingSidecar(
    lane: String,
    runID: String,
    identity: IdentityEnvironment,
    unitLatencies: [(id: String, latencySeconds: Double)]
) -> TimingSidecar {
    let units = unitLatencies.map {
        TimingSidecarUnit(unitID: $0.id, queryLatencySeconds: $0.latencySeconds)
    }
    let latencies = unitLatencies.map(\.latencySeconds)
    let aggregate = TimingSidecarAggregate(
        count: latencies.count,
        p50Seconds: latencyPercentile(values: latencies, p: 0.50),
        p95Seconds: latencyPercentile(values: latencies, p: 0.95)
    )
    return TimingSidecar(
        artifactType: "timing_sidecar",
        lane: lane,
        runID: runID,
        runIdentity: identity,
        units: units,
        aggregate: aggregate
    )
}

// MARK: - Write

/// Writes a timing sidecar beside the given accuracy report URL.
///
/// Derives the sidecar path by replacing the report's ".json" extension with
/// ".timing.json". Example:
///   lme-s-20260820T120000Z.json → lme-s-20260820T120000Z.timing.json
///
/// Uses `writeRecordNeverOverwrite` (O_CREAT | O_EXCL) — a second run with the
/// same serial must carry a different run-id, not overwrite this sidecar.
///
/// - Parameters:
///   - sidecar: The sidecar to write.
///   - reportURL: URL of the accuracy report already written. The sidecar is
///     placed in the same directory.
func writeTimingSidecar(_ sidecar: TimingSidecar, beside reportURL: URL) throws {
    let sidecarURL = reportURL
        .deletingPathExtension()
        .appendingPathExtension("timing.json")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(sidecar)
    try writeRecordNeverOverwrite(data, to: sidecarURL)
}
