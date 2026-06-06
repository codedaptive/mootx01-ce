// StatusReport.swift
//
// The read/status surface data model for moot-mgr Phase 1 (CLI). The HTTP
// dashboard is Phase 3 (MANAGER_1.0_PLAN.md §3); this is the structured
// summary the CLI `status` subcommand prints.
//
// By-estate / by-dropbox granularity (MANAGER_1.0_PLAN.md §5 item 4, RESOLVED
// by Bob): the summary groups samples BY DROPBOX and BY ESTATE rather than
// collapsing to a single global figure. Headline counts (totals) are kept too,
// but the per-group breakdowns are the primary view.

import Foundation
import ObserverSink
import PersistenceKit

// MARK: - GroupCount

/// Sample counts attributed to one group key (a dropbox id or an estate id).
public struct GroupCount: Sendable, Equatable {
    /// The group key — a dropbox id (for by-dropbox groups) or an estate id
    /// (for by-estate groups).
    public let key: String
    /// Number of metric samples attributed to this group.
    public let metricCount: Int
    /// Number of event samples attributed to this group.
    public let eventCount: Int

    public init(key: String, metricCount: Int, eventCount: Int) {
        self.key = key
        self.metricCount = metricCount
        self.eventCount = eventCount
    }
}

// MARK: - StatusReport

/// A point-in-time summary of the manager's stats store.
///
/// Built by `MootManager.status(now:recentEventLimit:)`. Carries the global
/// monitoring flag, headline totals, per-dropbox and per-estate breakdowns,
/// the most-recent events, and the store's own DB-layer health.
///
/// Not `Equatable`: `EventRow` (from ObserverSink) is not `Equatable`, so the
/// report as a whole has no value-equality. Tests assert on individual fields.
public struct StatusReport: Sendable {

    /// Whether monitoring is currently enabled (the global on/off switch).
    public let monitoringEnabled: Bool

    /// Total metric samples in the store across all dropboxes.
    public let totalMetrics: Int

    /// Total event samples in the store across all dropboxes.
    public let totalEvents: Int

    /// Per-dropbox sample breakdown, sorted by key for stable output.
    public let byDropbox: [GroupCount]

    /// Per-estate event breakdown, sorted by key for stable output.
    /// Estate attribution comes from event samples only (metric samples carry
    /// a dropbox id but not an estate id — estate is an event-level field).
    public let byEstate: [GroupCount]

    /// The most-recent events (newest first), up to the caller's limit.
    public let recentEvents: [EventRow]

    /// DB-layer health of the manager's own stats store, or `nil` if the
    /// backend does not support introspection.
    public let storeHealth: StorageStats?

    public init(
        monitoringEnabled: Bool,
        totalMetrics: Int,
        totalEvents: Int,
        byDropbox: [GroupCount],
        byEstate: [GroupCount],
        recentEvents: [EventRow],
        storeHealth: StorageStats?
    ) {
        self.monitoringEnabled = monitoringEnabled
        self.totalMetrics = totalMetrics
        self.totalEvents = totalEvents
        self.byDropbox = byDropbox
        self.byEstate = byEstate
        self.recentEvents = recentEvents
        self.storeHealth = storeHealth
    }
}

// MARK: - Plain-text rendering

extension StatusReport {

    /// Render the report as a plain-text block for the CLI `status` subcommand.
    ///
    /// Deterministic: groups are pre-sorted by key, so the same store state
    /// renders identically. Timestamps use ISO-8601 UTC for stable output.
    ///
    /// - Returns: A multi-line human-readable summary.
    public func renderText() -> String {
        var lines: [String] = []
        lines.append("moot-mgr status")
        lines.append("  monitoring: \(monitoringEnabled ? "ON" : "OFF")")
        lines.append("  totals: \(totalMetrics) metrics, \(totalEvents) events")

        lines.append("  by dropbox:")
        if byDropbox.isEmpty {
            lines.append("    (none)")
        } else {
            for g in byDropbox {
                lines.append("    \(g.key): \(g.metricCount) metrics, \(g.eventCount) events")
            }
        }

        lines.append("  by estate:")
        if byEstate.isEmpty {
            lines.append("    (none)")
        } else {
            for g in byEstate {
                lines.append("    \(g.key): \(g.eventCount) events")
            }
        }

        lines.append("  recent events:")
        if recentEvents.isEmpty {
            lines.append("    (none)")
        } else {
            for ev in recentEvents {
                let ts = StatusReport.iso8601Formatter.string(from: ev.ts)
                lines.append("    [\(ts)] \(ev.kind) noun=\(ev.nounType) estate=\(ev.estate) dropbox=\(ev.dropboxID)")
            }
        }

        lines.append("  store health:")
        if let h = storeHealth {
            lines.append("    size: \(h.logicalSizeBytes) bytes")
            if let pages = h.pageCount { lines.append("    pages: \(pages)") }
            if let free = h.freelistPageCount { lines.append("    freelist pages: \(free)") }
            if let wal = h.walFrameCount { lines.append("    WAL frames: \(wal)") }
            if let hit = h.cacheHitRatio { lines.append("    cache hit ratio: \(hit)") }
        } else {
            lines.append("    (introspection unavailable)")
        }

        return lines.joined(separator: "\n")
    }

    /// Shared ISO-8601 UTC formatter for rendering event timestamps.
    /// Matches the StatsStore storage format so rendered times equal stored times.
    static let iso8601Formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")!
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return f
    }()
}
