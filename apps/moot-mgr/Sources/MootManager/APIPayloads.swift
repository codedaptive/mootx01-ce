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
///
/// Two sections: the event-derived rollups (`estates` — every estate the host
/// has SEEN in the stats stream, including externally self-reporting ones) and
/// the admin section (`admin` — the estates the host itself PROVISIONS and mounts,
/// carrying their kind/backend/mount-state, GUI SPEC §4.2). The admin section is
/// nil on a host with no admin plane wired (the observer-only CLI cut).
public struct EstatesPayload: Codable, Sendable, Equatable {
    /// Per-estate event rollups, sorted by id for stable output.
    public let estates: [EstatePayload]
    /// Admin-hosted estates with their mount-state badges, or nil when the host
    /// has no admin plane.
    public let admin: EstateAdminPayload?

    public init(estates: [EstatePayload], admin: EstateAdminPayload? = nil) {
        self.estates = estates
        self.admin = admin
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

// MARK: - GraphPayload (GET /api/graph)

/// The Topology node-link snapshot (PoC spec §4.1, GUI SPEC Topology section).
///
/// ## What the resident host can actually source
///
/// moot-mgr is a PURE OBSERVER (Package.swift): it owns the ObserverSink
/// `StatsStore` and nothing else. It has NO estate database and NO MCP client,
/// so the graph STRUCTURE the PoC spec idealises — per-node `NounType` rows and
/// per-edge tunnel/kgFact/association relations — is NOT reachable from here.
/// That structure lives in the live estate and is reached over the mootx01 MCP
/// (`moot_estate_map` / `moot_connection_map`), a path the resident host does
/// not have.
///
/// What the host CAN read is the VizGraph telemetry the SubstrateML analytics
/// emit through IntellectusLib → ObserverSink when monitoring is on
/// (`SubstrateML/VizGraphSignals.swift`). Those are **aggregate completion
/// signals** — per-estate community count, centrality-pass completion, anomaly
/// z-score, NMF reconstruction error, edge-decay factor — keyed by `estate` in
/// the metric tags, NOT per-node row_id→score maps. (The per-node centrality
/// scores are deliberately stored in the estate's own `row_keystone_score`
/// column per VizGraphSignals.swift, not in the stats store.)
///
/// So this payload serves the analytic overlay that IS available (`analytics`,
/// `communities`) and reports the missing structure honestly: `nodes`/`edges`
/// are empty, `structurePending` is `true`, and `pending` enumerates the gap.
/// The A1 honesty pattern (APIPayloads header): a faked node graph in a read
/// API is worse than an absent one — the Topology view renders an explicit
/// pending state, never invented nodes.
///
/// CONTENT-SAFETY INVARIANT (concepts §1.6): every field here is metadata only
/// — identifiers, integer enums, float scores, ISO-8601 timestamps. No drawer
/// text, no KGFact predicates, no rung content (PoC spec §7).
public struct GraphPayload: Codable, Sendable, Equatable {
    /// Graph nodes. EMPTY in this cut — node structure requires the live estate
    /// (see the type doc); the resident host cannot source it, so it is left
    /// empty rather than fabricated.
    public let nodes: [GraphNodePayload]
    /// Graph edges. EMPTY in this cut — same reason as `nodes`.
    public let edges: [GraphEdgePayload]
    /// Per-estate community rollups derived from the `community.assignment`
    /// VizGraph signal (count + brand-derived colour). Available without
    /// structure because the signal carries the community count per estate.
    public let communities: [GraphCommunityPayload]
    /// The VizGraph analytic-signal summary the host could read from the stats
    /// store — one row per (estate, signal) with the latest value + freshness.
    public let analytics: [GraphAnalyticPayload]
    /// True when per-node/per-edge structure is not available from the resident
    /// host (always true in this cut). The renderer reads this to show the
    /// honest pending state instead of an empty canvas implying "no graph".
    public let structurePending: Bool
    /// Human-readable reasons structure is pending — the enumerated gap the
    /// Topology view surfaces (never silently empty).
    public let pending: [String]
    /// The estate filter echoed back (the `?estate=` query value, or "all" when
    /// unfiltered). Accepted-but-not-yet-acted-on while structure is pending.
    public let estate: String
    /// ISO-8601 UTC timestamp this snapshot was assembled.
    public let snapshotTs: String

    public init(
        nodes: [GraphNodePayload],
        edges: [GraphEdgePayload],
        communities: [GraphCommunityPayload],
        analytics: [GraphAnalyticPayload],
        structurePending: Bool,
        pending: [String],
        estate: String,
        snapshotTs: String
    ) {
        self.nodes = nodes
        self.edges = edges
        self.communities = communities
        self.analytics = analytics
        self.structurePending = structurePending
        self.pending = pending
        self.estate = estate
        self.snapshotTs = snapshotTs
    }
}

/// One graph node (PoC spec §4.1). Structural — sourced from the live estate's
/// `NounType` rows, which the resident host cannot reach (see `GraphPayload`).
/// The shape is defined so the renderer and the doc agree on the contract for
/// when estate access lands; the array is empty in this cut.
public struct GraphNodePayload: Codable, Sendable, Equatable {
    /// Row identifier (UUID string) — an identifier, never content.
    public let id: String
    /// `NounType` ordinal (SubstrateTypes) selecting the node's visual treatment.
    public let nounType: Int
    /// Louvain community id this node belongs to (drives cluster colour).
    public let communityId: Int
    /// Eigenvalue-centrality score in [0, 1]; scales the rendered radius.
    public let centrality: Double
    /// Whether anomaly detection flagged this node as a structural outlier.
    public let anomaly: Bool
    /// ISO-8601 UTC timestamp of the node's last activity, or nil.
    public let lastActiveTs: String?

    public init(
        id: String, nounType: Int, communityId: Int,
        centrality: Double, anomaly: Bool, lastActiveTs: String?
    ) {
        self.id = id
        self.nounType = nounType
        self.communityId = communityId
        self.centrality = centrality
        self.anomaly = anomaly
        self.lastActiveTs = lastActiveTs
    }
}

/// One graph edge (PoC spec §4.1). Structural — empty in this cut for the same
/// reason as `GraphNodePayload`.
public struct GraphEdgePayload: Codable, Sendable, Equatable {
    /// Source node id (UUID string).
    public let source: String
    /// Target node id (UUID string).
    public let target: String
    /// "tunnel" | "kgFact" | "association" | "nmf_bond" (PoC spec §1.2).
    public let edgeType: String
    /// Raw edge weight in [0, 1].
    public let weight: Double
    /// MatrixDecay-decayed weight in [0, 1] (drives opacity + pull).
    public let decayedWeight: Double

    public init(source: String, target: String, edgeType: String, weight: Double, decayedWeight: Double) {
        self.source = source
        self.target = target
        self.edgeType = edgeType
        self.weight = weight
        self.decayedWeight = decayedWeight
    }
}

/// A community rollup derived from the `community.assignment` VizGraph signal.
/// Available without structure — the signal carries the community count and
/// node count per estate in its tags / value.
public struct GraphCommunityPayload: Codable, Sendable, Equatable {
    /// Synthetic community index (0-based) within its estate. Hashed to a colour
    /// by the renderer; without per-node assignments these are placeholders for
    /// the legend's "N communities" readout, not node memberships.
    public let id: Int
    /// The estate this community count belongs to.
    public let estate: String
    /// Brand-derived colour for the community swatch (orange/blue family).
    public let color: String

    public init(id: Int, estate: String, color: String) {
        self.id = id
        self.estate = estate
        self.color = color
    }
}

/// One VizGraph analytic-signal summary row: the latest value the resident host
/// read from the stats store for a (estate, signal) pair, plus its freshness.
///
/// These ARE serveable from the resident host (the analytic overlay) because
/// they are aggregate completion metrics tagged by estate.
public struct GraphAnalyticPayload: Codable, Sendable, Equatable {
    /// The estate the signal was emitted for.
    public let estate: String
    /// Canonical signal name (`VizGraphSignals.*`): "community.assignment",
    /// "centrality.score", "nmf.factor", "anomaly.flag", "edge.decayed_weight".
    public let signal: String
    /// The latest sample value (semantics per VizGraphSignals.swift — e.g.
    /// community count, completion indicator, reconstruction error, z-score,
    /// decay factor).
    public let value: Double
    /// ISO-8601 UTC timestamp of the latest sample for this (estate, signal).
    public let ts: String
    /// Number of samples retained for this (estate, signal) — a freshness/volume
    /// hint for the overlay.
    public let sampleCount: Int

    public init(estate: String, signal: String, value: Double, ts: String, sampleCount: Int) {
        self.estate = estate
        self.signal = signal
        self.value = value
        self.ts = ts
        self.sampleCount = sampleCount
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

// MARK: - ControlResponse (uniform envelope for applyControl)

/// A pre-encoded control-verb response: the JSON body plus the `ok` flag used to
/// pick the HTTP status code. The gated control surfaces (`handleControl` over
/// HTTP, `ControlChannel.serve` over UDS) both call `applyControl` and need ONE
/// encode path even though different verbs return different result shapes —
/// `ControlResult` (monitoring/retention) vs `EstateAdminResult` (admin). The
/// envelope encodes the concrete result once, here, so the call sites stay shape-
/// agnostic: they read `ok` for the status and write `json` verbatim.
public struct ControlResponse: Sendable {
    /// Whether the verb succeeded (drives the HTTP status: 200 vs 400).
    public let ok: Bool
    /// The encoded JSON body of the concrete result (sorted-keys, compact).
    public let json: Data

    /// Wrap a concrete `Encodable` result, encoding it once. A failed encode
    /// degrades to a minimal `{"ok":false,…}` body so a surface never sends
    /// empty bytes.
    public static func of<T: Encodable>(_ result: T) -> ControlResponse {
        // `ok` is recovered from the encoded JSON so the envelope does not need a
        // shared protocol across the two result types: both encode an "ok" key.
        if let data = try? APIJSON.encode(result),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let ok = obj["ok"] as? Bool {
            return ControlResponse(ok: ok, json: data)
        }
        return ControlResponse(ok: false, json: Data(#"{"ok":false,"detail":"encode"}"#.utf8))
    }

    private init(ok: Bool, json: Data) {
        self.ok = ok
        self.json = json
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
