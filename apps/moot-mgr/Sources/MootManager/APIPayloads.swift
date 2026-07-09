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

// MARK: - DropboxSummaryPayload (nested in ServerPayload)

/// Per-dropbox activity summary for the Connects tab and Overview observer panel.
///
/// Summarises how many metric samples and events each observer dropbox has emitted
/// into the stats store, plus the ISO-8601 timestamp of the most-recent sample.
/// Dropbox name is the `dropboxID` string the emitting consumer registers with the
/// `PersistenceStatsSink` (e.g. "aria_mcp.server", "substrate.kernel").
public struct DropboxSummaryPayload: Codable, Sendable, Equatable {
    /// The observer dropbox identifier (emitter-registered string).
    public let name: String
    /// Number of metric samples from this dropbox currently in the store.
    public let metricCount: Int
    /// Number of event samples from this dropbox currently in the store.
    public let eventCount: Int
    /// ISO-8601 UTC timestamp of the most-recent sample (metric or event) from
    /// this dropbox, or nil when no samples have been received (impossible in
    /// practice — a dropbox only appears here after emitting).
    public let lastSeenISO: String?

    public init(name: String, metricCount: Int, eventCount: Int, lastSeenISO: String?) {
        self.name = name
        self.metricCount = metricCount
        self.eventCount = eventCount
        self.lastSeenISO = lastSeenISO
    }
}

// MARK: - ServerPayload (GET /api/server)

/// Server / process / monitoring-state summary (GUI SPEC §4.1, §10 Overview row).
///
/// Estate-agnostic. Sources what the resident host knows about itself and the
/// stats store: process uptime, the global monitoring flag, the count of distinct
/// estates seen in the event samples, total sample volume, and — when monitoring
/// is ON and the daemon has run long enough for the 30-second cadence to fire —
/// live process metrics (RSS, CPU, RPC count, connections, protocol version, and
/// kernel backend). All server-metric fields are optional: nil until substrate
/// probes land; the dashboard renders n/a for nil fields (not "pending" chips —
/// these are honest absent values, not planned future probes).
///
/// Derived rates (rpcRate, cpuPct) are computed from the delta between the two
/// most-recent stored samples of server.rpc_count and server.cpu_user_ms. They
/// are nil when fewer than two samples exist (cold start or monitoring just toggled on).
///
/// byDropbox lists every observer dropbox seen in the store with its sample counts,
/// powering the Connects tab and the Overview "Top Observers" panel.
///
/// capabilities lists the shipped NeuronKit capability names from CognitionKit's
/// compile-time shippedNeuronKitCapabilities constant.
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
    /// Total page count of the stats store SQLite file. nil when the backend
    /// does not report page-level stats (e.g. InMemory).
    public let storePageCount: Int?
    /// Free-list page count — pages allocated but unused. Non-zero indicates
    /// fragmentation; a VACUUM would reclaim these. nil when unavailable.
    public let storeFreelistPageCount: Int?
    /// WAL frame count — frames written but not yet checkpointed back to the
    /// main database file. High counts indicate infrequent checkpointing. nil
    /// when the backend is not in WAL mode or stats are unavailable.
    public let storeWalFrameCount: Int?
    /// SQLite page-cache hit ratio in [0, 1]. Values close to 1.0 mean most
    /// reads are served from memory; values below ~0.8 suggest cache pressure.
    /// nil when the backend does not report cache stats.
    public let storeCacheHitRatio: Double?
    /// Cumulative transaction commit count since the store was opened. nil when
    /// the backend does not report transaction counters.
    public let storeTransactionCommitCount: Int64?
    /// Total data rows across all tables in the stats store. nil when the
    /// backend does not report row counts.
    public let storeRowCount: Int?
    /// Process RSS in megabytes. nil until substrate probes land.
    public let rssMb: Double?
    /// User-mode CPU time in milliseconds since process start. nil until substrate probes land.
    public let cpuUserMs: Double?
    /// Total RPC calls since process start. nil until substrate probes land.
    public let rpcCount: Int?
    /// Active HTTP connection count. nil until substrate probes land.
    public let connections: Int?
    /// MCP protocol version string. nil until substrate probes land.
    public let protoVersion: String?
    /// Kernel backend kind string (e.g. "simd", "scalar"). nil until substrate probes land.
    public let kernelBackend: String?
    /// RPC calls per second, derived from the delta of the two most-recent
    /// server.rpc_count samples. nil when fewer than two samples exist.
    public let rpcRate: Double?
    /// Approximate user-mode CPU percentage, derived from the delta of the two
    /// most-recent server.cpu_user_ms samples divided by wall-clock delta × 100.
    /// nil when fewer than two samples exist or the sample interval is zero.
    public let cpuPct: Double?
    /// Per-dropbox sample counts, sorted by dropbox name. Powers the Connects tab
    /// and the Overview "Top Observers" ranked list.
    public let byDropbox: [DropboxSummaryPayload]
    /// Shipped NeuronKit capability names from CognitionKit's compile-time constant.
    /// Replaces the hardcoded "pending Phase-2" capability row in the dashboard.
    public let capabilities: [String]

    public init(
        monitoringEnabled: Bool,
        uptimeSeconds: Int,
        estateCount: Int,
        totalMetrics: Int,
        totalEvents: Int,
        storeSizeBytes: Int64,
        storePageCount: Int? = nil,
        storeFreelistPageCount: Int? = nil,
        storeWalFrameCount: Int? = nil,
        storeCacheHitRatio: Double? = nil,
        storeTransactionCommitCount: Int64? = nil,
        storeRowCount: Int? = nil,
        rssMb: Double? = nil,
        cpuUserMs: Double? = nil,
        rpcCount: Int? = nil,
        connections: Int? = nil,
        protoVersion: String? = nil,
        kernelBackend: String? = nil,
        rpcRate: Double? = nil,
        cpuPct: Double? = nil,
        byDropbox: [DropboxSummaryPayload] = [],
        capabilities: [String] = []
    ) {
        self.monitoringEnabled = monitoringEnabled
        self.uptimeSeconds = uptimeSeconds
        self.estateCount = estateCount
        self.totalMetrics = totalMetrics
        self.totalEvents = totalEvents
        self.storeSizeBytes = storeSizeBytes
        self.storePageCount = storePageCount
        self.storeFreelistPageCount = storeFreelistPageCount
        self.storeWalFrameCount = storeWalFrameCount
        self.storeCacheHitRatio = storeCacheHitRatio
        self.storeTransactionCommitCount = storeTransactionCommitCount
        self.storeRowCount = storeRowCount
        self.rssMb = rssMb
        self.cpuUserMs = cpuUserMs
        self.rpcCount = rpcCount
        self.connections = connections
        self.protoVersion = protoVersion
        self.kernelBackend = kernelBackend
        self.rpcRate = rpcRate
        self.cpuPct = cpuPct
        self.byDropbox = byDropbox
        self.capabilities = capabilities
    }
}

// MARK: - QueueStats (nested in EstatePayload)

/// Queue backpressure snapshot for one estate (GUI SPEC §4.3, §10 Pipeline row).
///
/// All fields are optional: absent when no queue metric samples exist yet for
/// this estate. Populated by MootManager.estatesPayload() from the latest
/// queue.* and locuskit.gate.* metric samples in the stats store.
public struct QueueStats: Codable, Sendable, Equatable {
    /// Pending job count at the last drain snapshot.
    public let depth: Double?
    /// Jobs claimed by the last drain call.
    public let drainCount: Double?
    /// True when the queue was non-empty but drain returned 0 (backpressure signal).
    public let idleNonempty: Bool?
    /// Median drain latency in milliseconds over the recent sampling window.
    public let latencyP50Ms: Double?
    /// 95th-percentile drain latency in milliseconds over the recent sampling window.
    public let latencyP95Ms: Double?
    /// Age of the head-of-line job in seconds at last drain snapshot.
    public let headOfLineAgeS: Double?
    /// Cumulative gate admits (locuskit.gate.admit_count, latest sample value).
    public let gateAdmitCount: Double?
    /// Cumulative gate rejects (locuskit.gate.reject_count, latest sample value).
    public let gateRejectCount: Double?

    public init(
        depth: Double?,
        drainCount: Double?,
        idleNonempty: Bool?,
        latencyP50Ms: Double?,
        latencyP95Ms: Double?,
        headOfLineAgeS: Double?,
        gateAdmitCount: Double?,
        gateRejectCount: Double?
    ) {
        self.depth = depth
        self.drainCount = drainCount
        self.idleNonempty = idleNonempty
        self.latencyP50Ms = latencyP50Ms
        self.latencyP95Ms = latencyP95Ms
        self.headOfLineAgeS = headOfLineAgeS
        self.gateAdmitCount = gateAdmitCount
        self.gateRejectCount = gateRejectCount
    }
}

// MARK: - ContentCountsPayload (nested in EstatePayload)

/// Content-type breakdown for one estate — counts of each noun shape currently
/// stored in the estate's substrate.
///
/// Populated via the admin estate info surface when the host provisions an
/// estate (admin plane present). nil for externally-observed estates (observer-
/// only CLI cut) or when the admin plane hasn't materialised the estate yet.
/// The Resources tab renders these as per-estate rows; nil fields show "n/a".
public struct ContentCountsPayload: Codable, Sendable, Equatable {
    /// Number of Wing nodes in the estate's spatial tree.
    public let wingCount: Int
    /// Number of Drawer (noun type 0) rows.
    public let drawerCount: Int
    /// Number of KGFact (noun type 2) rows.
    public let kgFactCount: Int
    /// Number of DiaryEntry (noun type 3) rows.
    public let diaryEntryCount: Int
    /// Number of Proposal (noun type 4) rows.
    public let proposalCount: Int

    public init(
        wingCount: Int,
        drawerCount: Int,
        kgFactCount: Int,
        diaryEntryCount: Int,
        proposalCount: Int
    ) {
        self.wingCount = wingCount
        self.drawerCount = drawerCount
        self.kgFactCount = kgFactCount
        self.diaryEntryCount = diaryEntryCount
        self.proposalCount = proposalCount
    }
}

// MARK: - EstatePayload (GET /api/estates)

/// One estate's rollup (GUI SPEC §4.2, §10 Estates row).
///
/// Estate attribution is an event-level field in the Phase-1 schema (metric
/// samples carry a dropbox id but no estate id), so the per-estate rollup is
/// event-derived: event count and the newest event timestamp for that estate.
/// The `queue` field is populated from queue.* and locuskit.gate.* metric
/// samples when available; nil when no samples exist.
///
/// `contentCounts` is nil for externally-observed estates (observer-only mode)
/// and nil until the admin plane has materialised the estate — the Resources tab
/// renders "n/a" for nil fields rather than omitting the row.
public struct EstatePayload: Codable, Sendable, Equatable {
    /// Estate identifier string.
    public let id: String
    /// Number of event samples attributed to this estate.
    public let eventCount: Int
    /// ISO-8601 UTC timestamp of the most-recent event for this estate, or nil
    /// if (impossibly) none — present whenever eventCount > 0.
    public let lastEventTs: String?
    /// Queue backpressure snapshot for this estate, or nil when no queue metric
    /// samples have been received yet.
    public let queue: QueueStats?
    /// Per-noun content counts for the Resources tab. nil for externally-observed
    /// estates or when the admin plane hasn't materialised the estate.
    public let contentCounts: ContentCountsPayload?

    public init(
        id: String,
        eventCount: Int,
        lastEventTs: String?,
        queue: QueueStats? = nil,
        contentCounts: ContentCountsPayload? = nil
    ) {
        self.id = id
        self.eventCount = eventCount
        self.lastEventTs = lastEventTs
        self.queue = queue
        self.contentCounts = contentCounts
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
    /// The estate row UUID string this event touched (`EventRow.rowIDStr`), or
    /// nil when the emitter supplied none. A UUID only — content-safe (VIZ_V2
    /// L1 wire contract); lets the dashboard correlate activity rows with
    /// topology nodes.
    public let drawerId: String?

    public init(ts: String, kind: String, nounType: Int, estate: String, dropbox: String,
                drawerId: String?) {
        self.ts = ts
        self.kind = kind
        self.nounType = nounType
        self.estate = estate
        self.dropbox = dropbox
        self.drawerId = drawerId
    }

    /// Custom encode so `drawerId` is always present on the wire — an explicit
    /// JSON null when nil (the VIZ_V2 contract pins null, never an absent key
    /// or empty string). Decoding stays synthesized (tolerates absent keys).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ts, forKey: .ts)
        try c.encode(kind, forKey: .kind)
        try c.encode(nounType, forKey: .nounType)
        try c.encode(estate, forKey: .estate)
        try c.encode(dropbox, forKey: .dropbox)
        try c.encode(drawerId, forKey: .drawerId)  // Optional encodes nil as null.
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

/// Compact wire-format edge for the `/api/graph` response (FIX 2b).
///
/// Each edge encodes as a JSON array `[sourceIndex, targetIndex, weight, edgeTypeOrdinal]`
/// to eliminate per-edge key overhead. UUID strings are replaced with integer indices into
/// the parallel `ids` array, and the edge-type string is replaced with a small integer.
///
/// Edge-type ordinal mapping (matches app.js `edgeTypeNames` constant):
/// - 0 = "tunnel"      (default, most common)
/// - 1 = "kgFact"
/// - 2 = "association"
/// - 3 = "nmf_bond"
///
/// Encoding 70k edges as `[[si, ti, w, et]]` vs `{source, target, edgeType, weight, tombstonedTs}`
/// reduces the edge section from ~8 MB to ~1 MB for a real-estate snapshot (70k edges ×
/// 36-char UUIDs × 2 = ~5 MB saved from source/target alone).
public struct CompactEdge: Encodable, Sendable, Equatable {
    /// Index of the source node in the parallel `ids` array.
    public let si: Int
    /// Index of the target node in the parallel `ids` array.
    public let ti: Int
    /// Raw edge weight in [0, 1].
    public let w: Double
    /// Edge-type ordinal: 0=tunnel, 1=kgFact, 2=association, 3=nmf_bond.
    public let et: Int

    public init(si: Int, ti: Int, w: Double, et: Int) {
        self.si = si; self.ti = ti; self.w = w; self.et = et
    }

    /// Map an ARIA edge-type string to its compact ordinal.
    public static func edgeTypeOrdinal(_ type: String) -> Int {
        switch type {
        case "kgFact":      return 1
        case "association": return 2
        case "nmf_bond":    return 3
        default:            return 0  // "tunnel" and any unrecognised type
        }
    }

    /// Encodes as a flat JSON array `[si, ti, w, et]` — no keys, no brackets overhead.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(si)
        try c.encode(ti)
        try c.encode(w)
        try c.encode(et)
    }
}

/// The Topology node-link snapshot (PoC spec §4.1, GUI SPEC Topology section).
///
/// ## Data sources
///
/// **Structure (nodes/edges):** sourced by proxying ARIA_MCP's
/// `GET /api/graph` endpoint (MootManager.graphPayload). When ARIA_MCP is
/// reachable, `structurePending` is `false` and `nodes`/`edges` are populated
/// from the live estate. When ARIA_MCP is not reachable, the fallback is the
/// honest pending state: `nodes`/`edges` are empty, `structurePending` is
/// `true`, and `pending` enumerates the gap. The A1 honesty pattern
/// (APIPayloads header): a faked node graph is worse than an absent one.
///
/// **Analytic overlay (analytics/communities):** always sourced locally from
/// the ObserverSink stats store (VizGraph signals from SubstrateML). Available
/// regardless of ARIA_MCP reachability.
///
/// CONTENT-SAFETY INVARIANT (concepts §1.6): every field here is metadata only
/// — identifiers, integer enums, float scores, ISO-8601 timestamps. No drawer
/// text, no KGFact predicates, no rung content (PoC spec §7).
/// The Topology node-link snapshot (PoC spec §4.1, GUI SPEC Topology section).
///
/// ## Wire format (FIX 2b compact layout)
///
/// Nodes are encoded as parallel arrays to eliminate per-node key overhead:
///
///   `ids`          — `[String]` UUID per node (one entry per node, in order)
///   `communityId`  — `[Int]` Louvain community id per node
///   `centrality`   — `[Double]` eigenvalue-centrality score per node in [0, 1]
///   `anomaly`      — `[Bool]` anomaly flag per node
///   `createdTs`    — `[String?]` ISO-8601 ingest timestamp or null per node
///   `tombstoned`   — `{indexStr: ts}` SPARSE map (only tombstoned nodes)
///
/// Edges are encoded as compact arrays-of-arrays:
///
///   `edges` — `[[si, ti, w, et], ...]` where si/ti are indices into `ids`,
///   w is the raw weight, et is the edge-type ordinal (see `CompactEdge`).
///
/// For 51k nodes / 70k edges the per-object format produced ~18 MB (UUID strings
/// dominate: 70k × 2 × 36-char UUIDs ≈ 5 MB in edges alone). The compact format
/// targets < 5 MB for the same fixture.
///
/// ## Backwards compatibility
///
/// Old per-object snapshots stored by the governor are decoded via
/// `StoredGraphPayload`/`GraphNodePayload`/`GraphEdgePayload` and transformed
/// at response-assembly time — no stored data changes format.
///
/// app.js detects the new format by checking `Array.isArray(g.ids)` (compact)
/// vs `Array.isArray(g.nodes)` (legacy per-object, no longer emitted).
///
/// CONTENT-SAFETY INVARIANT (concepts §1.6): all fields here are metadata only
/// — identifiers, integer enums, float scores, ISO-8601 timestamps. No drawer
/// text, no KGFact predicates, no rung content (PoC spec §7).
public struct GraphPayload: Encodable, Sendable {
    // MARK: - Parallel node arrays (compact wire format)

    /// Node UUIDs — one entry per node, in insertion order. All other parallel
    /// arrays index into this array by position.
    private let ids: [String]
    /// Louvain community id per node (matches `communityId` on stored nodes).
    /// Int8Array-able in JS for most real graphs (community count < 128).
    private let communityId: [Int]
    /// Eigenvalue-centrality score per node in [0, 1].
    private let centrality: [Double]
    /// Anomaly-detection flag per node.
    private let anomaly: [Bool]
    /// ISO-8601 ingest timestamp per node (drawer's filedAt), or null when the
    /// daemon did not supply one. Nil entries encode as explicit JSON nulls.
    private let createdTs: [String?]
    /// Sparse tombstone map: string(nodeIndex) → ISO-8601 ts.
    /// Only live entries for tombstoned nodes; live nodes are absent.
    /// Saves ~50 bytes per live node vs a full parallel array (most nodes alive).
    private let tombstoned: [String: String]

    // MARK: - Compact edges

    /// Compact edge array: each element is `[si, ti, w, et]`.
    /// `si`/`ti` are indices into `ids`; `et` is the edge-type ordinal.
    /// See `CompactEdge` for edge-type ordinal mapping.
    private let edges: [CompactEdge]

    // MARK: - Unchanged fields

    /// Community legend entries `{id, code, label, size}` (VIZ_V2 L3). When a
    /// snapshot is available these are governor-produced descriptors enriched
    /// with FDC heading labels, with the dominant classification code passed
    /// through (same content basis as `/api/lattice`, which serves raw codes;
    /// the dashboard derives community colors from the code digits). On
    /// fallback they are count-only placeholders from the
    /// `community.assignment` VizGraph signal.
    public let communities: [GraphCommunityPayload]
    /// The VizGraph analytic-signal summary sourced from the stats store —
    /// one row per (estate, signal) with the latest value + freshness.
    public let analytics: [GraphAnalyticPayload]
    /// True when the topology snapshot has not yet been produced by the governor
    /// (first duty cycle not complete). The renderer shows an explicit pending
    /// state rather than an empty canvas implying "no graph".
    public let structurePending: Bool
    /// Human-readable reasons structure is pending — the enumerated gap the
    /// Topology view surfaces (never silently empty).
    public let pending: [String]
    /// ISO-8601 instant the governor produced the stored snapshot. Nil when
    /// structurePending is true (no snapshot yet). Encodes as explicit JSON null.
    public let generatedTs: String?
    /// The estate filter echoed back (the `?estate=` query value, or "all" when
    /// unfiltered).
    public let estate: String
    /// ISO-8601 UTC timestamp this response was assembled.
    public let snapshotTs: String

    /// Build a `GraphPayload` from stored per-object nodes and edges.
    ///
    /// Transforms the per-object representation used by the governor's stored
    /// snapshots (`StoredGraphPayload`) into the compact parallel-array wire
    /// format at response-assembly time. Stored data is never re-written.
    ///
    /// Edges whose source or target UUID is not in the node set are dropped
    /// (consistent with the pre-existing filtering in the topology snapshot
    /// pipeline — should not occur in practice but guarded for safety).
    public init(
        nodes: [GraphNodePayload],
        edges: [GraphEdgePayload],
        communities: [GraphCommunityPayload],
        analytics: [GraphAnalyticPayload],
        structurePending: Bool,
        pending: [String],
        generatedTs: String?,
        estate: String,
        snapshotTs: String
    ) {
        // Build node index map and all parallel arrays in one pass.
        var indexMap: [String: Int] = [:]
        indexMap.reserveCapacity(nodes.count)
        var idsArr:         [String]   = []; idsArr.reserveCapacity(nodes.count)
        var communityIdArr: [Int]      = []; communityIdArr.reserveCapacity(nodes.count)
        var centralityArr:  [Double]   = []; centralityArr.reserveCapacity(nodes.count)
        var anomalyArr:     [Bool]     = []; anomalyArr.reserveCapacity(nodes.count)
        var createdTsArr:   [String?]  = []; createdTsArr.reserveCapacity(nodes.count)
        var tombstonedMap:  [String: String] = [:]
        for (i, n) in nodes.enumerated() {
            indexMap[n.id] = i
            idsArr.append(n.id)
            communityIdArr.append(n.communityId)
            centralityArr.append(n.centrality)
            anomalyArr.append(n.anomaly)
            createdTsArr.append(n.createdTs)
            if let ts = n.tombstonedTs { tombstonedMap["\(i)"] = ts }
        }
        self.ids         = idsArr
        self.communityId = communityIdArr
        self.centrality  = centralityArr
        self.anomaly     = anomalyArr
        self.createdTs   = createdTsArr
        self.tombstoned  = tombstonedMap

        // Build compact edges — drop edges whose endpoints are not in the node set.
        var compactEdges: [CompactEdge] = []; compactEdges.reserveCapacity(edges.count)
        for e in edges {
            guard let si = indexMap[e.source], let ti = indexMap[e.target] else { continue }
            compactEdges.append(CompactEdge(
                si: si, ti: ti,
                w: e.weight,
                et: CompactEdge.edgeTypeOrdinal(e.edgeType)
            ))
        }
        self.edges = compactEdges

        self.communities     = communities
        self.analytics       = analytics
        self.structurePending = structurePending
        self.pending         = pending
        self.generatedTs     = generatedTs
        self.estate          = estate
        self.snapshotTs      = snapshotTs
    }

    // MARK: - Encoding

    private enum CodingKeys: String, CodingKey {
        case ids, communityId, centrality, anomaly, createdTs, tombstoned, edges
        case communities, analytics, structurePending, pending, generatedTs, estate, snapshotTs
    }

    /// Custom encode — parallel node arrays + compact edges + `generatedTs` as explicit null.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // Parallel node arrays (compact layout).
        try c.encode(ids,         forKey: .ids)
        try c.encode(communityId, forKey: .communityId)
        try c.encode(centrality,  forKey: .centrality)
        try c.encode(anomaly,     forKey: .anomaly)
        // createdTs: encodes nil entries as explicit JSON nulls (VIZ_V2 contract).
        var createdTsC = c.nestedUnkeyedContainer(forKey: .createdTs)
        for ts in createdTs { try createdTsC.encode(ts) }  // nil encodes as null
        try c.encode(tombstoned,  forKey: .tombstoned)
        // Compact edges: each encodes as [si, ti, w, et] via CompactEdge.encode(to:).
        try c.encode(edges,       forKey: .edges)
        // Unchanged envelope fields.
        try c.encode(communities,      forKey: .communities)
        try c.encode(analytics,        forKey: .analytics)
        try c.encode(structurePending, forKey: .structurePending)
        try c.encode(pending,          forKey: .pending)
        try c.encode(generatedTs,      forKey: .generatedTs)  // nil → explicit null
        try c.encode(estate,           forKey: .estate)
        try c.encode(snapshotTs,       forKey: .snapshotTs)
    }
}

/// One graph node (PoC spec §4.1). Structural — sourced from the live estate's
/// `NounType` rows via the ARIA_MCP proxy. Populated when ARIA_MCP is reachable;
/// the array is empty on fallback (see `GraphPayload.structurePending`).
public struct GraphNodePayload: Codable, Sendable, Equatable {
    /// Row identifier (UUID string) — an identifier, never content.
    public let id: String
    /// Louvain community id this node belongs to (drives cluster colour).
    public let communityId: Int
    /// Eigenvalue-centrality score in [0, 1]; scales the rendered radius.
    public let centrality: Double
    /// Whether anomaly detection flagged this node as a structural outlier.
    public let anomaly: Bool
    /// ISO-8601 UTC ingest timestamp — the drawer's `filedAt` (ingest clock,
    /// VIZ_V2 L0) — or nil when the daemon did not supply one. Drives the
    /// renderer's age axis (strata depth / recency brightness).
    public let createdTs: String?
    /// ISO-8601 UTC tombstone timestamp (VIZ_V2 dissolution), or nil when the
    /// node is alive now. Tombstoned drawers ARE included in the graph payload
    /// so playback can render entities within [createdTs, tombstonedTs); the
    /// live view hides them. Dead nodes carry the sentinels communityId -1
    /// (no community) and centrality 0.0 — all graph math upstream runs over
    /// live entities only.
    public let tombstonedTs: String?

    // nounType and lastActiveTs removed from wire format (FIX 2 — payload
    // trim): nounType was redundant (all drawers are type 0, JS defaults to 0);
    // lastActiveTs is not surfaced by the dashboard renderer.  Both fields are
    // still decoded via synthesised Codable — keys present in existing snapshots
    // on disk are silently ignored by the decoder.

    public init(
        id: String, communityId: Int,
        centrality: Double, anomaly: Bool,
        createdTs: String?, tombstonedTs: String?
    ) {
        self.id = id
        self.communityId = communityId
        self.centrality = centrality
        self.anomaly = anomaly
        self.createdTs = createdTs
        self.tombstonedTs = tombstonedTs
    }

    /// Custom encode so the nullable timestamps are always present on the wire
    /// as explicit JSON nulls (VIZ_V2 contract). Decoding stays synthesized,
    /// so a daemon that omits `createdTs` or `tombstonedTs` still decodes (nil).
    /// nounType and lastActiveTs are omitted from the encode path (payload trim).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(communityId, forKey: .communityId)
        try c.encode(centrality, forKey: .centrality)
        try c.encode(anomaly, forKey: .anomaly)
        try c.encode(createdTs, forKey: .createdTs)          // nil → null
        try c.encode(tombstonedTs, forKey: .tombstonedTs)    // nil → null
    }
}

/// One graph edge (PoC spec §4.1). Structural — sourced via the ARIA_MCP proxy.
/// Populated when ARIA_MCP is reachable; the array is empty on fallback.
public struct GraphEdgePayload: Codable, Sendable, Equatable {
    /// Source node id (UUID string).
    public let source: String
    /// Target node id (UUID string).
    public let target: String
    /// "tunnel" | "kgFact" | "association" | "nmf_bond" (PoC spec §1.2).
    public let edgeType: String
    /// Raw edge weight in [0, 1].
    public let weight: Double
    /// ISO-8601 UTC tombstone timestamp (VIZ_V2 dissolution), or nil when the
    /// edge is alive now. Tombstoned tunnels ARE included in the graph payload
    /// with their real source/target so playback can render them within
    /// the dissolution window; they are excluded from adjacency upstream so
    /// they never shift community structure. kgFact derived edges remain
    /// live-facts-only: always nil here.
    public let tombstonedTs: String?

    // decayedWeight and createdTs removed from wire format (FIX 2 — payload
    // trim): decayedWeight is not consumed by the dashboard renderer;
    // createdTs added per-edge costs significant JSON bytes and the dashboard
    // does not display individual edge ages.  Keys present in existing
    // snapshots are silently ignored by the synthesised decoder.

    public init(source: String, target: String, edgeType: String, weight: Double,
                tombstonedTs: String?) {
        self.source = source
        self.target = target
        self.edgeType = edgeType
        self.weight = weight
        self.tombstonedTs = tombstonedTs
    }

    /// Custom encode so `tombstonedTs` is always present on the wire as an
    /// explicit JSON null when nil (VIZ_V2 contract). Decoding stays
    /// synthesized, so a daemon that omits the key still decodes (nil).
    /// decayedWeight and createdTs are omitted from the encode path (payload trim).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(source, forKey: .source)
        try c.encode(target, forKey: .target)
        try c.encode(edgeType, forKey: .edgeType)
        try c.encode(weight, forKey: .weight)
        try c.encode(tombstonedTs, forKey: .tombstonedTs)  // nil → null
    }
}

/// One community legend entry on the wire: `{id, code, label, size}` (VIZ_V2 L3).
///
/// Sourced two ways:
/// - **ARIA proxy (live):** ARIA_MCP ships `{id, size, dominantUdcCode}` sorted
///   by size descending; the proxy enriches the dominant UDC code to its FDC
///   heading label (`FDC.label(for:)`, bundled taxonomy — never estate content)
///   and passes the code through. The code crosses this surface on the same
///   basis as `/api/lattice`, which already serves raw classification codes
///   to the dashboard: a classification code is derived by a pure function of
///   a pinned public frame, never memory content. The dashboard derives the
///   community color from the code's digits (encoding rule: hundreds → hue,
///   tens → shade, ones → brightness).
/// - **Local fallback (structure pending):** derived from the
///   `community.assignment` VizGraph signal, which carries only the community
///   count per estate — so `code`/`label` are nil and `size` is 0 (unknown).
public struct GraphCommunityPayload: Codable, Sendable, Equatable {
    /// Community id. From ARIA this is the Louvain community id matching
    /// `GraphNodePayload.communityId`; in the local fallback it is a running
    /// 0-based legend index (no node memberships exist to match).
    public let id: Int
    /// The community's dominant UDC/FDC classification code (e.g. "657",
    /// "615.85"), or nil when ARIA reports none. Drives the digit-derived
    /// community color on the dashboard.
    public let code: String?
    /// FDC heading label for the community's dominant UDC code, or nil when
    /// the code is empty, MDCC, or otherwise not in the bundled FDC frame.
    public let label: String?
    /// Member-drawer count, or 0 in the local fallback (count unknown without
    /// ARIA structure).
    public let size: Int

    public init(id: Int, code: String?, label: String?, size: Int) {
        self.id = id
        self.code = code
        self.label = label
        self.size = size
    }

    /// Custom encode so `code` and `label` are always present on the wire — an
    /// explicit JSON null when nil (VIZ_V2 contract). Decoding stays synthesized.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(code, forKey: .code)    // nil → null
        try c.encode(label, forKey: .label)  // nil → null
        try c.encode(size, forKey: .size)
    }
}

/// One VizGraph analytic-signal summary row: the latest value the resident host
/// read from the stats store for a (estate, signal) pair, plus its freshness.
///
/// These ARE serveable from the resident host (the analytic overlay the mission
/// asks for) because they are aggregate completion metrics tagged by estate.
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

// MARK: - LexiconPayload (GET /api/lexicon)

/// The ARIA grammar as static JSON — one call, zero runtime cost.
///
/// All fields are derived at startup from AriaLexiconLib's compile-time enum
/// definitions. The acceptance matrix is the full cross-product condensed to a
/// per-noun array of the verb strings that apply. The dashboard's Configuration
/// view renders these as an expandable ARIA Grammar panel.
///
/// LatticeLib metadata (FDC availability, data version, library version) is
/// included here because the Configuration view renders it alongside the lexicon
/// — one endpoint for all static capability/grammar data keeps the dashboard
/// load simple.
///
/// CONTENT-SAFETY INVARIANT: this payload contains only grammar vocabulary and
/// library version strings — never any estate or content data.
public struct LexiconPayload: Codable, Sendable, Equatable {
    /// All noun raw values from AriaLexiconLib.Noun.allCases (e.g. "drawer", "tunnel").
    public let nouns: [String]
    /// All verb raw values from AriaLexiconLib.Verb.allCases (e.g. "capture", "recall").
    public let verbs: [String]
    /// All adjective raw values from AriaLexiconLib.Adjective.allCases.
    public let adjectives: [String]
    /// Per-noun acceptance: maps each noun raw value to the set of verb raw values
    /// that Acceptance.verbs(for:) returns. Empty array for nouns that accept nothing
    /// (e.g. "vector" — substrate-managed, not directly verb-addressable).
    public let acceptance: [String: [String]]
    /// Whether the FDC (Frame Decimal Classification) index is loaded and available.
    /// Sourced from LatticeLib.FDC.isAvailable.
    public let fdcAvailable: Bool
    /// The FDC data version string (e.g. "2024.1"). Sourced from LatticeLib.FDC.dataVersion.
    public let fdcDataVersion: String
    /// The LatticeLib library version string. Sourced from LatticeLib.version.
    public let latticeVersion: String

    public init(
        nouns: [String],
        verbs: [String],
        adjectives: [String],
        acceptance: [String: [String]],
        fdcAvailable: Bool,
        fdcDataVersion: String,
        latticeVersion: String
    ) {
        self.nouns = nouns
        self.verbs = verbs
        self.adjectives = adjectives
        self.acceptance = acceptance
        self.fdcAvailable = fdcAvailable
        self.fdcDataVersion = fdcDataVersion
        self.latticeVersion = latticeVersion
    }
}

// MARK: - LatticeSnapshotPayload (GET /api/lattice)

/// One active lattice address and the number of drawers anchored to it.
///
/// CONTENT-SAFETY INVARIANT: only the classification code (a decimal string
/// from the FDC/MDCC taxonomy), its human-readable heading label (from the
/// bundled FDCFrame.json taxonomy — not from any estate content), and a
/// drawer count cross this surface. No drawer content is included.
public struct LatticeAddressPayload: Codable, Sendable, Equatable {
    /// The UDC/MDCC classification code, e.g. "540", "006.6".
    public let code: String
    /// The FDC frame heading label for this code (e.g. "Chemistry", "Computer
    /// graphics"). Nil when the code is not in the bundled frame (e.g. an MDCC
    /// code not yet in the FDC frame) or when LatticeLib is unavailable.
    public let label: String?
    /// Number of live (non-tombstoned) drawers anchored to this code.
    public let count: Int

    public init(code: String, label: String?, count: Int) {
        self.code = code
        self.label = label
        self.count = count
    }
}

/// The lattice address snapshot returned by `GET /api/lattice`.
///
/// CONTENT-SAFETY INVARIANT: only classification metadata and counts — never
/// estate content or rung text.
public struct LatticeSnapshotPayload: Codable, Sendable, Equatable {
    /// Active lattice addresses, sorted by count descending.
    public let addresses: [LatticeAddressPayload]
    /// True when ARIA_MCP was unreachable and the address list is empty.
    public let pending: Bool

    public init(addresses: [LatticeAddressPayload], pending: Bool) {
        self.addresses = addresses
        self.pending = pending
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
