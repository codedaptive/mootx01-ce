// APIPayloads.swift
//
// Codable payload structs for the moot-mgr loopback HTTP read-API (P3).
//
// These shapes match the GUI SPEC §10 "Data bindings (consolidated)" table so
// the Concept-B web dashboard (and the PC/Linux build that serves the same web
// assets) can bind directly. Only the subset of fields the Phase-1 stats store
// can actually source is populated; fields the SPEC lists but that depend on
// not-yet-built substrate metrics (kernel backend, RPC rate, per-estate queue
// subtree, rung completeness, HLC drift) are OMITTED rather than faked — a
// faked metric in a read API is worse than an absent one (the dashboard renders
// its monitoring-off / not-available states for absent fields).
//
// CONTENT-SAFETY INVARIANT (concepts §1.6, GUI SPEC §10): every field here is
// metadata only — counts, enums, ISO-8601 timestamps, booleans, identifiers.
// No rung/memory content is ever projected onto a read payload. If a future
// field would carry recalled content, it does NOT belong in this file.
//
// Timestamps are emitted as ISO-8601 UTC TEXT (matching the store's on-disk
// format) so the wire format is stable and human-readable, never epoch floats.

import Foundation

// MARK: - ServerPayload (GET /api/server)

/// Server / process / monitoring-state summary (GUI SPEC §4.1, §10 Overview row).
///
/// Estate-agnostic. Sources only what the resident host knows about itself and
/// the stats store: process uptime, the global monitoring flag, the count of
/// distinct estates seen in the event samples, and total sample volume. Process
/// RSS/CPU/RPC-rate and kernel-backend fields from the SPEC are omitted until
/// the host gains those probes (they are not in the Phase-1 stats store).
public struct ServerPayload: Codable, Sendable, Equatable {
    /// Whether the global monitoring flow-down switch is ON.
    public let monitoringEnabled: Bool
    /// Whole seconds the resident host has been running (host-supplied; the
    /// caller owns the clock).
    public let uptimeSeconds: Int
    /// Number of distinct estates observed in the event samples.
    public let estateCount: Int
    /// Total metric samples currently retained in the store.
    public let totalMetrics: Int
    /// Total event samples currently retained in the store.
    public let totalEvents: Int
    /// Logical size of the stats store file in bytes (DB-layer health).
    public let storeSizeBytes: Int64

    public init(
        monitoringEnabled: Bool,
        uptimeSeconds: Int,
        estateCount: Int,
        totalMetrics: Int,
        totalEvents: Int,
        storeSizeBytes: Int64
    ) {
        self.monitoringEnabled = monitoringEnabled
        self.uptimeSeconds = uptimeSeconds
        self.estateCount = estateCount
        self.totalMetrics = totalMetrics
        self.totalEvents = totalEvents
        self.storeSizeBytes = storeSizeBytes
    }
}

// MARK: - EstatePayload (GET /api/estates)

/// One estate's rollup (GUI SPEC §4.2, §10 Estates row).
///
/// Estate attribution is an event-level field in the Phase-1 schema (metric
/// samples carry a dropbox id but no estate id), so the per-estate rollup is
/// event-derived: event count and the newest event timestamp for that estate.
/// Backend/kind/queue/rung fields require the GLK substrate metrics (P2/P6) and
/// are omitted here.
public struct EstatePayload: Codable, Sendable, Equatable {
    /// Estate identifier string.
    public let id: String
    /// Number of event samples attributed to this estate.
    public let eventCount: Int
    /// ISO-8601 UTC timestamp of the most-recent event for this estate, or nil
    /// if (impossibly) none — present whenever eventCount > 0.
    public let lastEventTs: String?

    public init(id: String, eventCount: Int, lastEventTs: String?) {
        self.id = id
        self.eventCount = eventCount
        self.lastEventTs = lastEventTs
    }
}

/// Envelope for GET /api/estates.
public struct EstatesPayload: Codable, Sendable, Equatable {
    /// Per-estate rollups, sorted by id for stable output.
    public let estates: [EstatePayload]

    public init(estates: [EstatePayload]) {
        self.estates = estates
    }
}

// MARK: - EventPayload (GET /api/events)

/// One recorded event row, projected for the Activity view / SSE stream
/// (GUI SPEC §4.4, §10 Activity row). Metadata only — no rung content.
public struct EventPayload: Codable, Sendable, Equatable {
    /// ISO-8601 UTC timestamp.
    public let ts: String
    /// EventKind raw string: "capture" or "think".
    public let kind: String
    /// NounType ordinal from SubstrateTypes.
    public let nounType: Int
    /// Estate identifier string.
    public let estate: String
    /// Consumer dropbox identifier (the source layer/process).
    public let dropbox: String

    public init(ts: String, kind: String, nounType: Int, estate: String, dropbox: String) {
        self.ts = ts
        self.kind = kind
        self.nounType = nounType
        self.estate = estate
        self.dropbox = dropbox
    }
}

/// Envelope for the non-streaming GET /api/events response.
public struct EventsPayload: Codable, Sendable, Equatable {
    /// Recent events, newest first.
    public let events: [EventPayload]

    public init(events: [EventPayload]) {
        self.events = events
    }
}

// MARK: - ConfigPayload (GET /api/config)

/// Current monitoring configuration (GUI SPEC §4.6, §10 Configuration row).
///
/// The read-only projection of the control state the dashboard's Configuration
/// view renders: the monitoring flag, the retention window in seconds, and the
/// ISO-8601 cutoff the last retention pass used.
public struct ConfigPayload: Codable, Sendable, Equatable {
    /// Whether monitoring is currently enabled.
    public let monitoringEnabled: Bool
    /// The active retention window in whole seconds.
    public let retentionSeconds: Int
    /// ISO-8601 UTC timestamp the last retention pass rolled off data older than,
    /// or the epoch-zero sentinel ("1970-01-01T00:00:00.000Z") if none has run.
    public let retentionCutoff: String

    public init(monitoringEnabled: Bool, retentionSeconds: Int, retentionCutoff: String) {
        self.monitoringEnabled = monitoringEnabled
        self.retentionSeconds = retentionSeconds
        self.retentionCutoff = retentionCutoff
    }
}

// MARK: - ControlResult (POST /api/control/* and UDS responses)

/// Result of a gated control verb. Returned as JSON over both the token+Origin
/// HTTP control surface and the UDS control surface.
public struct ControlResult: Codable, Sendable, Equatable {
    /// Whether the verb was applied.
    public let ok: Bool
    /// Human-readable detail (e.g. "monitoring: ON", "retention: 3600s").
    public let detail: String

    public init(ok: Bool, detail: String) {
        self.ok = ok
        self.detail = detail
    }
}

// MARK: - JSON encoding helper

/// Shared JSON encoder for read/control payloads.
///
/// Sorted keys make responses byte-stable (testable; cache-friendly); no
/// pretty-printing keeps the wire compact. Dates are never encoded directly —
/// every timestamp field above is already an ISO-8601 String, so no date
/// strategy is needed (and none is set, to avoid an accidental epoch-float path).
public enum APIJSON {
    /// Encode a Codable payload to compact, key-sorted JSON `Data`.
    ///
    /// - Parameter value: The payload to encode.
    /// - Returns: UTF-8 JSON data.
    /// - Throws: An encoding error if the value is not representable.
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}
