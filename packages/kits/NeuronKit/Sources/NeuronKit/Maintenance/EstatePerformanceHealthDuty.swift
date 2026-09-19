// EstatePerformanceHealthDuty.swift
//
// Production adapter that binds `PerformanceHealthDuty` to a live
// GeniusLocusKit estate (A7 / Phase-4 §6).
//
// ── Why this lives in NeuronKit, not GeniusLocusKit ────────────────────────
// `PerformanceHealthDuty` is declared in NeuronKit (MaintenanceSeams.swift).
// A conforming type must import NeuronKit. GeniusLocusKit is a downstream
// dependency of NeuronKit (GLK sits below NK in the stack), so GLK cannot
// import NK without a circular package dependency. NeuronKit is the only
// package that can see both the protocol and the GLK audit surface, making
// it the natural home — the same constraint that placed `EstateThetaBasisRetrainHook`
// and `EstateMaintenanceSink` here.
//
// ── Consumption pattern ───────────────────────────────────────────────────
// Pages `GeniusLocusKit.auditEvents(_:after:limit:)` in a loop until
// exhausted, converts SubstrateTypes.AuditEvent → NeuronKit.TimingAuditEvent,
// and feeds the full window to `deriveTimings(events:sinceExclusiveMs:)`.
// Results are emitted via `Intellectus.report(.metric(...))` — the same
// PersistenceStatsSink write path the resident observer uses for live samples
// (D6 boundary expansion, docs/decisions/DECISION_OBSERVER_AGGREGATION_2026-08-14.md).
//
// ── Watermark discipline (A6) ─────────────────────────────────────────────
// Paging cursor: HLC(physicalTime: watermarkMs, logicalCount: 0, nodeID: 0).
// Because HLC ordering is (physicalTime, logicalCount, nodeID), this cursor
// sits at the very start of the given millisecond. Events whose physicalTime
// equals watermarkMs but with logicalCount > 0 or nodeID != 0 are re-fetched;
// deriveTimings' `sinceExclusiveMs` guard excludes their captures from
// double-counting. The re-fetch is bounded to the overlap millisecond and is
// safe.
//
// ── Page size ────────────────────────────────────────────────────────────
// PAGE_SIZE = 2 000 events: a day of moderate activity (< 2000 audit writes/day)
// fits in a single page; busier estates drain in successive pages within one
// duty call. The daily duty is best-effort; each call is bounded to at most
// MAX_PAGES pages so a pathologically large estate does not stall the daemon.
//
// ── Failure handling ─────────────────────────────────────────────────────
// Store and derivation failures throw to the daemon's catch block, where they
// are logged and swallowed — a stale health sample degrades trend accuracy; it
// does not break the daemon's proposal and diary functions.

import Foundation
import GeniusLocusKit
import IntellectusLib
import OSLog

// SubstrateTypes.HLC is the HLC type used for the audit cursor.
import struct SubstrateTypes.HLC
import struct SubstrateTypes.AuditEvent

/// Production `PerformanceHealthDuty` that reads audit events from a live estate,
/// derives INGEST and CYCLE timing samples, and emits them via Intellectus.
///
/// - Pages `GeniusLocusKit.auditEvents(_:after:limit:)` from the caller-supplied
///   watermark, in batches of `EstatePerformanceHealthDuty.pageSize` events.
/// - Converts each `AuditEvent` → `TimingAuditEvent` and feeds the full window
///   to `NeuronKit.deriveTimings(events:sinceExclusiveMs:)`.
/// - Reports derived samples via `Intellectus.report(.metric(...))`:
///   `neuronkit.perf_health.ingest_p50_ms`, `neuronkit.perf_health.ingest_p95_ms`,
///   `neuronkit.perf_health.cycle_vector_p50_ms`, `neuronkit.perf_health.cycle_vector_p95_ms`,
///   `neuronkit.perf_health.cycle_novel_p50_ms`, `neuronkit.perf_health.cycle_novel_p95_ms`,
///   `neuronkit.perf_health.cycle_novel_unbounded`, `neuronkit.perf_health.cycle_dreamt_p50_ms`,
///   `neuronkit.perf_health.cycle_dreamt_p95_ms`, `neuronkit.perf_health.cycle_dreamt_unbounded`,
///   `neuronkit.perf_health.ingest_sample_count`.
/// - Returns the new watermark (last event's HLC physical time, epoch ms).
public struct EstatePerformanceHealthDuty: PerformanceHealthDuty {

    // MARK: - Constants

    /// Events fetched per audit-log page. 2 000 covers a day of moderate estate
    /// activity in a single round-trip; busier estates drain across successive pages.
    public static let pageSize = 2_000

    /// Maximum pages per duty call, bounding the call to ≤ 20 000 events.
    /// Pathologically large estates accumulate a remaining-window debt that the
    /// next call's watermark advances — no data is lost, just deferred one day.
    public static let maxPages = 10

    // MARK: - State

    private let handle: EstateHandle
    private let kit: GeniusLocusKit

    private static let log = Logger(
        subsystem: NeuronKitLogging.subsystem,
        category: "NeuronKit"
    )

    // MARK: - Init

    /// Construct a duty bound to the addressed estate.
    ///
    /// - Parameters:
    ///   - handle: The estate whose audit log this duty derives timing samples from.
    ///   - kit: The GeniusLocusKit actor that owns the estate registry.
    public init(handle: EstateHandle, kit: GeniusLocusKit) {
        self.handle = handle
        self.kit = kit
    }

    // MARK: - PerformanceHealthDuty

    /// Page the estate audit log from `watermarkMs`, derive INGEST and CYCLE
    /// timing samples, emit them via Intellectus, and return the new watermark.
    ///
    /// Paging stops when the audit log returns fewer than `pageSize` events
    /// (exhausted) or after `maxPages` pages (cap). Returns the original
    /// `watermarkMs` when the log has no new events.
    ///
    /// - Parameters:
    ///   - watermarkMs: HLC physical-time watermark (epoch ms). 0 = start from
    ///     the beginning of the log (first call or reset).
    ///   - now: Deterministic timestamp from the caller.
    /// - Returns: HLC physical-time of the last event consumed (the new watermark).
    public func runHealthDuty(watermarkMs: Int64, now: Date) async throws -> Int64 {
        // Page audit events from the watermark cursor. The HLC cursor sits at the
        // start of `watermarkMs` millisecond; re-fetched events at the same ms are
        // filtered by deriveTimings' sinceExclusiveMs guard.
        let cursor: HLC? = watermarkMs > 0
            ? HLC(physicalTime: watermarkMs, logicalCount: 0, nodeID: 0)
            : nil

        var allEvents: [TimingAuditEvent] = []
        var pageCursor: HLC? = cursor

        for _ in 0..<Self.maxPages {
            let page = try await kit.auditEvents(handle, after: pageCursor, limit: Self.pageSize)
            guard !page.isEmpty else { break }

            // Map SubstrateTypes.AuditEvent → NeuronKit.TimingAuditEvent.
            // Only verb, physicalTime, rowId, and reason are consumed by deriveTimings;
            // the bitmap and lattice fields are timing-derivation irrelevant.
            let mapped = page.map { e in
                TimingAuditEvent(
                    verb: e.verb,
                    physicalTimeMs: e.hlc.physicalTime,
                    rowID: e.rowId,
                    reason: e.reason
                )
            }
            allEvents.append(contentsOf: mapped)

            // Advance cursor to the last event of this page for the next page.
            pageCursor = page.last.map(\.hlc)

            if page.count < Self.pageSize {
                // Fewer than a full page — audit log is exhausted for this window.
                break
            }
        }

        guard !allEvents.isEmpty else {
            // No new events since the last run — nothing to derive.
            return watermarkMs
        }

        // Run the pure derivation engine. `sinceExclusiveMs = watermarkMs` ensures
        // captures at or before the prior watermark are excluded from measurement
        // (A6 exactly-once contract).
        let derivation = deriveTimings(events: allEvents, sinceExclusiveMs: watermarkMs)

        // Emit derived samples via the existing Intellectus path.
        // The receiver is the resident observer's PersistenceStatsSink, which
        // forwards to the stats store (D6 boundary expansion).
        let ts = now.timeIntervalSince1970
        let tags: [String: String] = ["estate": handle.estateUUID.uuidString]

        emitPercentiles(
            name: "neuronkit.perf_health.ingest",
            samples: derivation.ingestExactMs,
            ts: ts, tags: tags
        )
        emitPercentiles(
            name: "neuronkit.perf_health.cycle_vector",
            samples: derivation.cycleVectorMs,
            ts: ts, tags: tags
        )
        emitPercentiles(
            name: "neuronkit.perf_health.cycle_novel",
            samples: derivation.cycleNovelMs,
            ts: ts, tags: tags
        )
        Intellectus.report(.metric(
            name: "neuronkit.perf_health.cycle_novel_unbounded",
            value: Double(derivation.cycleNovelUnbounded),
            tags: tags,
            ts: ts
        ))
        emitPercentiles(
            name: "neuronkit.perf_health.cycle_dreamt",
            samples: derivation.cycleDreamtMs,
            ts: ts, tags: tags
        )
        Intellectus.report(.metric(
            name: "neuronkit.perf_health.cycle_dreamt_unbounded",
            value: Double(derivation.cycleDreamtUnbounded),
            tags: tags,
            ts: ts
        ))
        // Ingest sample count: how many single-row captures were measured this window.
        Intellectus.report(.metric(
            name: "neuronkit.perf_health.ingest_sample_count",
            value: Double(derivation.ingestExactMs.count),
            tags: tags,
            ts: ts
        ))

        let sampleCount = derivation.ingestExactMs.count
        let newWatermarkMs = derivation.watermarkMs
        Self.log.info(
            "perf-health duty: estate \(handle.estateUUID, privacy: .public) derived \(sampleCount, privacy: .public) ingest samples, watermark \(watermarkMs, privacy: .public) → \(newWatermarkMs, privacy: .public)"
        )

        return derivation.watermarkMs
    }

    // MARK: - Private helpers

    /// Emit p50 and p95 percentile metrics for an ascending-sorted sample array.
    ///
    /// The two metrics are `\(name)_p50_ms` and `\(name)_p95_ms`. When the
    /// sample array is empty, both metrics are emitted with value 0 so the
    /// stats store registers the absence rather than missing the row entirely —
    /// a downstream consumer can distinguish "0 samples" from "duty did not run."
    private func emitPercentiles(
        name: String,
        samples: [Int64],
        ts: Double,
        tags: [String: String]
    ) {
        let p50 = percentile(samples, fraction: 0.50)
        let p95 = percentile(samples, fraction: 0.95)
        Intellectus.report(.metric(
            name: "\(name)_p50_ms",
            value: Double(p50),
            tags: tags,
            ts: ts
        ))
        Intellectus.report(.metric(
            name: "\(name)_p95_ms",
            value: Double(p95),
            tags: tags,
            ts: ts
        ))
    }

    /// Nearest-rank percentile over an ascending-sorted Int64 array.
    ///
    /// Returns 0 for an empty array. The nearest-rank method is simple,
    /// deterministic, and produces the same result regardless of interpolation
    /// scheme — matching what the benchmark harness uses for the same data.
    private func percentile(_ sorted: [Int64], fraction: Double) -> Int64 {
        guard !sorted.isEmpty else { return 0 }
        // Nearest-rank: index = ceil(fraction * n) - 1, clamped.
        let idx = max(0, min(sorted.count - 1, Int(ceil(fraction * Double(sorted.count))) - 1))
        return sorted[idx]
    }
}
