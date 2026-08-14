// PerfHealthHandlers.swift
//
// Wire type and payload builder for GET /api/perf-health.
//
// The Perf Health panel surfaces the daily performance-health indicator
// written by NeuronKit's EstatePerformanceHealthDuty (A7) into
// PersistenceStatsSink. One current sample (all 11 metric fields,
// audit-derived) and an ingest-p50 trend series (oldest first) are exposed.
//
// D6 boundary (docs/decisions/DECISION_OBSERVER_AGGREGATION_2026-08-14.md):
//   display only — no alert thresholds, no general query surface.
//   Daily samples + retained trend are approved.
//
// Content-safety: only metadata crosses this surface — timing durations as
// Double (ms), unbounded counts as Double, ISO-8601 timestamps. No rung or
// memory content (GUI SPEC §10, HTTPReadAPI.swift SECURITY BOUNDARY).

import Foundation
import ObserverSink

// MARK: - Trend point

/// One point in the ingest-p50 trend series.
///
/// Each point corresponds to a single daily `EstatePerformanceHealthDuty` run.
/// Values are audit-derived from the estate's captured audit events (D6 boundary).
public struct PerfHealthTrendPointPayload: Encodable, Sendable, Equatable {
    /// ISO-8601 timestamp of the duty run that produced this sample.
    public let ts: String
    /// Ingest p50 duration in milliseconds, audit-derived.
    public let ingestP50Ms: Double

    public init(ts: String, ingestP50Ms: Double) {
        self.ts = ts
        self.ingestP50Ms = ingestP50Ms
    }
}

// MARK: - Current sample (all 11 metrics)

/// The most recent daily performance-health sample for the matching estate set.
///
/// All timing fields are in milliseconds. All values are audit-derived from the
/// estate's captured audit events via `EstatePerformanceHealthDuty` (A7 / D6).
///
/// Fields are `nil` when the duty has not yet produced a sample (estate is new
/// or the daily cadence has not yet fired).
public struct PerfHealthSamplePayload: Encodable, Sendable, Equatable {
    /// ISO-8601 timestamp of the duty run that produced this sample.
    public let ts: String
    /// INGEST p50 duration (ms), audit-derived.
    public let ingestP50Ms: Double?
    /// INGEST p95 duration (ms), audit-derived.
    public let ingestP95Ms: Double?
    /// CYCLE vector-tier p50 duration (ms), audit-derived.
    public let cycleVectorP50Ms: Double?
    /// CYCLE vector-tier p95 duration (ms), audit-derived.
    public let cycleVectorP95Ms: Double?
    /// CYCLE novel-tier p50 duration (ms), audit-derived.
    public let cycleNovelP50Ms: Double?
    /// CYCLE novel-tier p95 duration (ms), audit-derived.
    public let cycleNovelP95Ms: Double?
    /// Count of novel-tier cycles that exceeded the unbounded threshold, audit-derived.
    public let cycleNovelUnbounded: Double?
    /// CYCLE dreamt-tier p50 duration (ms), audit-derived.
    public let cycleDreamtP50Ms: Double?
    /// CYCLE dreamt-tier p95 duration (ms), audit-derived.
    public let cycleDreamtP95Ms: Double?
    /// Count of dreamt-tier cycles that exceeded the unbounded threshold, audit-derived.
    public let cycleDreamtUnbounded: Double?
    /// Count of ingest capture events measured in this duty window, audit-derived.
    public let ingestSampleCount: Double?

    public init(
        ts: String,
        ingestP50Ms: Double?,
        ingestP95Ms: Double?,
        cycleVectorP50Ms: Double?,
        cycleVectorP95Ms: Double?,
        cycleNovelP50Ms: Double?,
        cycleNovelP95Ms: Double?,
        cycleNovelUnbounded: Double?,
        cycleDreamtP50Ms: Double?,
        cycleDreamtP95Ms: Double?,
        cycleDreamtUnbounded: Double?,
        ingestSampleCount: Double?
    ) {
        self.ts = ts
        self.ingestP50Ms = ingestP50Ms
        self.ingestP95Ms = ingestP95Ms
        self.cycleVectorP50Ms = cycleVectorP50Ms
        self.cycleVectorP95Ms = cycleVectorP95Ms
        self.cycleNovelP50Ms = cycleNovelP50Ms
        self.cycleNovelP95Ms = cycleNovelP95Ms
        self.cycleNovelUnbounded = cycleNovelUnbounded
        self.cycleDreamtP50Ms = cycleDreamtP50Ms
        self.cycleDreamtP95Ms = cycleDreamtP95Ms
        self.cycleDreamtUnbounded = cycleDreamtUnbounded
        self.ingestSampleCount = ingestSampleCount
    }
}

// MARK: - Top-level payload

/// `GET /api/perf-health` — daily performance-health indicator with trend.
///
/// Sources the audit-derived timing samples written by
/// `EstatePerformanceHealthDuty` (A7) into `PersistenceStatsSink`.
///
/// D6 boundary: display only, no alerting, no general query surface.
/// (docs/decisions/DECISION_OBSERVER_AGGREGATION_2026-08-14.md)
public struct PerfHealthPayload: Encodable, Sendable, Equatable {
    /// True when the manager has not been started (store unavailable).
    public let pending: Bool
    /// Estate UUID filter applied to this response.
    /// `nil` when no filter was requested (data across all estates).
    public let estate: String?
    /// Most recent audit-derived sample for the matching estate set.
    /// `nil` when no samples exist (duty has not run yet).
    public let latestSample: PerfHealthSamplePayload?
    /// Ingest p50 trend series, oldest first (one point per duty run).
    /// Reflects the `estate` filter when supplied.
    public let trend: [PerfHealthTrendPointPayload]

    public init(
        pending: Bool,
        estate: String?,
        latestSample: PerfHealthSamplePayload?,
        trend: [PerfHealthTrendPointPayload]
    ) {
        self.pending = pending
        self.estate = estate
        self.latestSample = latestSample
        self.trend = trend
    }
}

// MARK: - MootManager perf-health builder

extension MootManager {

    // The 11 metric keys written by EstatePerformanceHealthDuty (A7).
    // Source: NeuronKit/Sources/NeuronKit/Maintenance/EstatePerformanceHealthDuty.swift
    private static let perfHealthMetricNames: Set<String> = [
        "neuronkit.perf_health.ingest_p50_ms",
        "neuronkit.perf_health.ingest_p95_ms",
        "neuronkit.perf_health.cycle_vector_p50_ms",
        "neuronkit.perf_health.cycle_vector_p95_ms",
        "neuronkit.perf_health.cycle_novel_p50_ms",
        "neuronkit.perf_health.cycle_novel_p95_ms",
        "neuronkit.perf_health.cycle_novel_unbounded",
        "neuronkit.perf_health.cycle_dreamt_p50_ms",
        "neuronkit.perf_health.cycle_dreamt_p95_ms",
        "neuronkit.perf_health.cycle_dreamt_unbounded",
        "neuronkit.perf_health.ingest_sample_count",
    ]

    /// Build the `GET /api/perf-health` payload.
    ///
    /// Returns the most recent audit-derived performance-health sample and an
    /// ingest-p50 trend series (oldest first). Both are filtered to the given
    /// estate UUID when supplied. With no filter, data spans all estates.
    ///
    /// Values originate in `PersistenceStatsSink` rows written by
    /// `EstatePerformanceHealthDuty` on a 24 h cadence (A7). Expect at most
    /// one new trend point per estate per day.
    ///
    /// D6 boundary: display only. No alerting, no general query surface.
    ///
    /// - Parameter estate: Estate UUID to filter by. `nil` returns data across
    ///   all estates (union of all duty runs).
    /// - Returns: A valid `PerfHealthPayload`. Returns `pending: true` when
    ///   the manager has not been started. Returns `latestSample: nil, trend: []`
    ///   when no samples have been written yet.
    // Deliberately one function rather than split helpers: the body is seven
    // sequential phases over ONE query result (guard → query → estate filter →
    // build-latest-map → derive trend anchor → build latest sample → build
    // trend series), and each later phase reads the same intermediate maps.
    // Splitting would thread three dictionaries through five signatures for
    // no clarity gain.
    public func perfHealthPayload(estate: String? = nil) async throws -> PerfHealthPayload {
        // Return pending when the manager has not been started (no store yet).
        // Mirrors the ReviewPayload.pending pattern — callers get a valid payload,
        // not a 500.
        guard let store = try? statsStore() else {
            return PerfHealthPayload(pending: true, estate: estate,
                                     latestSample: nil, trend: [])
        }

        // Query all perf-health metric rows ascending (oldest first, no limit).
        // Each row carries an `estate` tag containing the estate UUID, written
        // by EstatePerformanceHealthDuty at duty-run time.
        let rows = try await store.queryMetricsByNames(Self.perfHealthMetricNames)

        // Apply estate-UUID filter when requested.
        let filtered: [MetricRow]
        if let uuid = estate {
            filtered = rows.filter { $0.tags["estate"] == uuid }
        } else {
            filtered = rows
        }

        // Build name → latest MetricRow map: ascending order means the last row
        // per name is the most recent sample.
        var latestByName: [String: MetricRow] = [:]
        for row in filtered {
            latestByName[row.name] = row   // later iterations overwrite earlier
        }

        // Derive the current-sample timestamp from the ingest_p50_ms anchor row
        // (the first metric emitted per duty run). Fall back to the chronologically
        // latest row across any metric when ingest_p50_ms is absent.
        let anchorRow: MetricRow? =
            latestByName["neuronkit.perf_health.ingest_p50_ms"]
            ?? latestByName.values.sorted { $0.ts < $1.ts }.last

        let latestSample: PerfHealthSamplePayload? = anchorRow.map { anchor in
            PerfHealthSamplePayload(
                ts: Self.iso8601String(from: anchor.ts),
                ingestP50Ms:         latestByName["neuronkit.perf_health.ingest_p50_ms"]?.value,
                ingestP95Ms:         latestByName["neuronkit.perf_health.ingest_p95_ms"]?.value,
                cycleVectorP50Ms:    latestByName["neuronkit.perf_health.cycle_vector_p50_ms"]?.value,
                cycleVectorP95Ms:    latestByName["neuronkit.perf_health.cycle_vector_p95_ms"]?.value,
                cycleNovelP50Ms:     latestByName["neuronkit.perf_health.cycle_novel_p50_ms"]?.value,
                cycleNovelP95Ms:     latestByName["neuronkit.perf_health.cycle_novel_p95_ms"]?.value,
                cycleNovelUnbounded: latestByName["neuronkit.perf_health.cycle_novel_unbounded"]?.value,
                cycleDreamtP50Ms:    latestByName["neuronkit.perf_health.cycle_dreamt_p50_ms"]?.value,
                cycleDreamtP95Ms:    latestByName["neuronkit.perf_health.cycle_dreamt_p95_ms"]?.value,
                cycleDreamtUnbounded: latestByName["neuronkit.perf_health.cycle_dreamt_unbounded"]?.value,
                ingestSampleCount:   latestByName["neuronkit.perf_health.ingest_sample_count"]?.value
            )
        }

        // Build the ingest-p50 trend series from all ingest_p50_ms rows in
        // ascending (oldest-first) order.
        let trendRows = filtered.filter { $0.name == "neuronkit.perf_health.ingest_p50_ms" }
        let trend: [PerfHealthTrendPointPayload] = trendRows.map { row in
            PerfHealthTrendPointPayload(
                ts: Self.iso8601String(from: row.ts),
                ingestP50Ms: row.value
            )
        }

        return PerfHealthPayload(
            pending: false,
            estate: estate,
            latestSample: latestSample,
            trend: trend
        )
    }
}
