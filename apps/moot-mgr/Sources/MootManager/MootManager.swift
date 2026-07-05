// MootManager.swift
//
// The manager core: store ownership, the global monitoring on/off switch, the
// retention window/loop, and the read/status surface. A PURE OBSERVER — it
// never hosts an estate DB (MANAGER_1.0_PLAN.md §1).
//
// Responsibilities (Phase 1 spine, MANAGER_1.0_PLAN.md §3):
//   1. Provision/own the ObserverSink StatsStore (SQLite) at a configurable
//      path. The manager migrates the store on start (StatsStore.open()).
//   2. Own the global on/off switch — setMonitoring(_:) writes the control
//      flag row. This IS the broadcast: consumers' sinks read the flag.
//   3. Run a retention pass — runRetention(now:) computes cutoff = now - window
//      (the app may read the clock here; determinism applies to engines/libs,
//      not the app's own loop) and rolls off old rows via StatsStore's
//      caller-supplied-cutoff retention engine.
//   4. Expose a read/status surface — status(now:recentEventLimit:) summarises
//      samples grouped BY DROPBOX and BY ESTATE (§5 item 4 ruling), recent
//      events, and the store's own DB-layer health.
//
// Registration in this cut = consumers emit with a dropbox_id; the manager
// reads/groups by it. A formal registrations/heartbeat table is a noted
// FOLLOW-UP, not in this mission.
//
// Threading: MootManager is an actor — the manager process is single-instance,
// and actor isolation gives a clean Sendable boundary around the open store.

import Foundation
import OSLog
import ObserverSink
import PersistenceKit
import AriaLexiconLib
import CognitionKit
import LatticeLib

// MARK: - Stored graph snapshot helpers (internal for tests)

/// Decodable envelope for the topology snapshot stored in `topology_snapshots`
/// by the autonomic governor. Only the fields moot-mgr needs to compose into
/// `GraphPayload` are decoded; the `analytics` overlay is sourced locally from
/// the stats store.
///
/// Nodes/edges decode as the shared `GraphNodePayload`/`GraphEdgePayload`
/// wire shapes, so per-entity fields (`createdTs`, `tombstonedTs` — the
/// VIZ_V2 dissolution timestamp on tombstoned drawers/tunnels) pass through
/// unchanged: absent-key-tolerant on decode, explicit JSON null on re-encode.
struct StoredGraphPayload: Decodable {
    let nodes: [GraphNodePayload]
    let edges: [GraphEdgePayload]
    let structurePending: Bool
    /// Raw community descriptors written by the governor.
    /// Optional so a snapshot predating VIZ_V2 still decodes; nil falls back
    /// to the local count-only rollup.
    let communities: [ARIACommunityDescriptor]?
    /// ISO-8601 instant the governor produced this snapshot. Optional so
    /// older snapshots without the field still decode.
    let generatedTs: String?
}

/// One raw community descriptor on the ARIA_MCP graph wire (VIZ_V2 contract):
/// `{id, size, dominantUdcCode}`. The dominant UDC code is enriched to an FDC
/// heading label and dropped at this proxy — it never crosses to the browser
/// (content boundary keeps labels only).
struct ARIACommunityDescriptor: Decodable {
    /// Louvain community id (matches `GraphNodePayload.communityId`).
    let id: Int
    /// Member-drawer count.
    let size: Int
    /// Most frequent non-empty `udcCode` among the community's member drawers;
    /// "" when none. Optional-tolerant decode for older daemons.
    let dominantUdcCode: String?

    init(id: Int, size: Int, dominantUdcCode: String?) {
        self.id = id
        self.size = size
        self.dominantUdcCode = dominantUdcCode
    }
}

// MARK: - MootManager

/// The MOOTx01 observer/manager. Owns the central stats store, the global
/// monitoring switch, and the retention window.
///
/// ## Lifecycle
///
/// ```swift
/// let manager = MootManager(config: .fromEnvironment())
/// try await manager.start()          // provision + migrate the store
/// try await manager.setMonitoring(true)
/// let report = try await manager.status(now: Date())
/// _ = try await manager.runRetention(now: Date())
/// await manager.stop()
/// ```
public actor MootManager {

    // MARK: - State

    /// The resolved configuration (store path + retention window/cadence).
    public let config: ManagerConfig

    /// The owned stats store. Non-nil after `start()` succeeds.
    private var store: StatsStore?

    /// Runtime override of the retention window, set via the gated control
    /// channel (`set retention`). `nil` means "use `config.retentionWindow`".
    ///
    /// Persisted to a JSON sidecar file (`moot-mgr-prefs.json`) next to the
    /// stats store so the override survives process restart. Loaded in `start()`
    /// and written in `setRetention(window:)`. The manager owns that directory,
    /// so it owns the sidecar file.
    private var retentionOverride: TimeInterval?

    /// The cutoff the most-recent `runRetention(now:)` pass used, surfaced by
    /// `/api/config` so the dashboard can show when data was last rolled off.
    ///
    /// The cutoff the most-recent `runRetention(now:)` pass used, surfaced by
    /// `/api/config` so the dashboard can show when data was last rolled off.
    ///
    /// Tracked on the actor rather than read back from the store's `retention_cutoff`
    /// control row because `StatsStore` has no public reader for that row — the
    /// control row exists as a durable audit record for the governor, not as a
    /// runtime read-back surface. The host runs the retention loop in-process so
    /// the actor is the authoritative owner of "what cutoff did we last apply."
    /// Holds the epoch-zero sentinel until the first pass runs (matching the
    /// store's own seed value, so the API reports the same "never" before the
    /// first roll-off).
    private var lastRetentionCutoff: Date = Date(timeIntervalSince1970: 0)

    /// Single-slot cache of the decoded + FDC-enriched topology snapshot,
    /// keyed by (estate filter, raw snapshot bytes). The governor rewrites
    /// the snapshot only when estate content changes; the dashboard polls
    /// far more often — a hit skips the ~1MB JSONDecoder pass and every
    /// FDC label lookup (see graphPayload).
    private var topologyEnrichmentCache: (
        estateKey: String?, raw: Data,
        nodes: [GraphNodePayload], edges: [GraphEdgePayload],
        communities: [GraphCommunityPayload]?, generatedTs: String?
    )? = nil

    private let logger = Logger(subsystem: "com.mootx01.kit", category: "MootManager")

    // MARK: - ARIA_MCP proxy

    /// Base URL for ARIA_MCP read endpoints. Read from `ARIA_MCP_API_BASE` at
    /// process start; defaults to the standard resident-daemon loopback address.
    private static let ariaAPIBase: String =
        ProcessInfo.processInfo.environment["ARIA_MCP_API_BASE"] ?? "http://127.0.0.1:4242"

    /// Ephemeral URLSession for ARIA_MCP read requests. Short 3-second timeout
    /// so the pure-observer host degrades gracefully when the daemon is unreachable.
    private static let ariaSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3.0
        config.timeoutIntervalForResource = 3.0
        return URLSession(configuration: config)
    }()

    // MARK: - Initialisation

    /// Create a manager with the given configuration. Call `start()` before
    /// any other method to provision and open the store.
    ///
    /// - Parameter config: The resolved configuration.
    public init(config: ManagerConfig) {
        self.config = config
    }

    // MARK: - Lifecycle

    /// Provision and open the stats store, applying the schema/migrations.
    ///
    /// Creates the store's parent directory if needed (the manager owns the
    /// file; the operator does not pre-create it), constructs the `StatsStore`,
    /// and calls `open()` which seeds the control rows.
    ///
    /// Idempotent at the store level — `StatsStore.open()` is forward-only.
    /// Calling `start()` twice re-opens cleanly.
    ///
    /// - Throws: `StorageError` if the store cannot be opened, or a file-system
    ///   error if the parent directory cannot be created.
    public func start() async throws {
        // Ensure the parent directory exists. The manager owns its store file;
        // it is responsible for creating the directory tree.
        let parent = config.storeURL.deletingLastPathComponent()
        // Restrict the stats store directory to the owning user (planned hardening).
        // SQLite WAL/SHM files land here and must not be readable by other local
        // users. Mirrors Rust `start()` which calls `set_permissions(0o700)`.
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let store = try StatsStore(url: config.storeURL)
        try await store.open()
        self.store = store
        // Restore any persisted retention override so the window survives restart.
        // The sidecar is written by setRetention(window:) and lives alongside the
        // stats store. If absent or unparseable, retentionOverride stays nil and
        // the configured default applies (the safe, expected behaviour on first start).
        retentionOverride = loadPersistedRetentionOverride()
        logger.info("MootManager started; store at \(self.config.storeURL.path)")
    }

    /// Close the store cleanly. Idempotent.
    public func stop() async {
        await store?.close()
        store = nil
    }

    // MARK: - Monitoring switch

    /// Set the global monitoring on/off switch.
    ///
    /// Writes the control flag row in the store. This is the broadcast: every
    /// consumer's `PersistenceStatsSink` reads the row on each `receive(_:)`
    /// and goes silent when the flag is "0" (flag-row signal, MANAGER_1.0_PLAN.md
    /// §5 item 3, confirmed by Bob).
    ///
    /// - Parameter enabled: `true` to enable monitoring fleet-wide; `false` to
    ///   silence all consumers.
    /// - Throws: `StorageError` on I/O failure or `ManagerError.notStarted`.
    public func setMonitoring(_ enabled: Bool) async throws {
        let store = try requireStore()
        try await store.setMonitoringEnabled(enabled)
        logger.info("MootManager monitoring set to \(enabled ? "ON" : "OFF")")
    }

    /// Read the current global monitoring state from the control flag row.
    ///
    /// - Returns: `true` if monitoring is enabled.
    /// - Throws: `StorageError` on I/O failure or `ManagerError.notStarted`.
    public func isMonitoring() async throws -> Bool {
        let store = try requireStore()
        return try await store.isMonitoringEnabled()
    }

    // MARK: - Retention

    /// Run one retention pass: roll off samples older than the retention window.
    ///
    /// Computes `cutoff = now - config.retentionWindow` and deletes metric and
    /// event rows with `ts < cutoff`. The cutoff is computed here (the app's own
    /// loop may read the clock) and passed into `StatsStore`'s retention engine,
    /// which takes the cutoff as a parameter — no `Date()` inside the engine.
    ///
    /// - Parameter now: The current time (the manager's loop supplies it; tests
    ///   inject a deterministic value).
    /// - Returns: The total number of rows deleted (metrics + events).
    /// - Throws: `StorageError` on I/O failure or `ManagerError.notStarted`.
    @discardableResult
    public func runRetention(now: Date) async throws -> Int {
        let store = try requireStore()
        // Use the runtime override when the control channel has set one;
        // otherwise the configured default window.
        let cutoff = now.addingTimeInterval(-effectiveRetentionWindow)
        let metricsDeleted = try await store.deleteMetricsBefore(cutoff: cutoff, now: now)
        let eventsDeleted = try await store.deleteEventsBefore(cutoff: cutoff, now: now)
        let total = metricsDeleted + eventsDeleted
        // Record the cutoff this pass applied so /api/config can report it.
        lastRetentionCutoff = cutoff
        logger.info("MootManager retention pass deleted \(total) rows (cutoff \(cutoff))")
        return total
    }

    // MARK: - Read / status surface

    /// Build a `StatusReport` summarising the store's current contents.
    ///
    /// Groups samples BY DROPBOX and BY ESTATE (MANAGER_1.0_PLAN.md §5 item 4),
    /// lists the most-recent events, and reports the store's own DB-layer health.
    ///
    /// - Parameters:
    ///   - now: The current time, stamped on the store-health snapshot
    ///     (determinism: the caller owns the clock).
    ///   - recentEventLimit: Maximum number of recent events to include
    ///     (newest first). Defaults to 20.
    /// - Returns: A `StatusReport`.
    /// - Throws: `StorageError` on I/O failure or `ManagerError.notStarted`.
    public func status(now: Date, recentEventLimit: Int = 20) async throws -> StatusReport {
        let store = try requireStore()

        let monitoringEnabled = try await store.isMonitoringEnabled()

        // `countMetrics()` issues a SQL COUNT(*) with no predicate — no row decoding, O(1).
        // This replaces the previous `queryMetrics(dropboxID: nil)` full-table scan which
        // was catastrophic at 6M rows (dashboard 504 timeout observed in production).
        let totalMetrics = try await store.countMetrics()
        let events = try await store.queryEvents(dropboxID: nil)

        // Per-dropbox metric counts: use aggregate queries indexed on dropbox_id
        // instead of loading+decoding every metric row. Driver IDs come from events
        // (bounded by retention; every metric-emitting estate also emits events).
        var dropboxEventCounts: [String: Int] = [:]
        for e in events { dropboxEventCounts[e.dropboxID, default: 0] += 1 }
        let eventDropboxIDs = Array(Set(events.map(\.dropboxID)))
        let metricAggregates = try await store.queryMetricAggregatesByDropbox(
            forDropboxIDs: eventDropboxIDs
        )
        let metricAggByID = Dictionary(
            metricAggregates.map { ($0.dropboxID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let dropboxKeys = Set(eventDropboxIDs).union(metricAggByID.keys)
        let byDropbox = dropboxKeys.sorted().map { key in
            GroupCount(
                key: key,
                metricCount: metricAggByID[key]?.metricCount ?? 0,
                eventCount: dropboxEventCounts[key] ?? 0
            )
        }

        // By-estate: estate attribution is an event-level field (metric samples
        // carry no estate id), so the by-estate breakdown counts events only.
        var estateEventCounts: [String: Int] = [:]
        for e in events { estateEventCounts[e.estate, default: 0] += 1 }
        let byEstate = estateEventCounts.keys.sorted().map { key in
            GroupCount(key: key, metricCount: 0, eventCount: estateEventCounts[key] ?? 0)
        }

        // Recent events: queryEvents returns oldest-first; take the newest tail
        // and reverse so the report is newest-first.
        let recent = Array(events.suffix(max(0, recentEventLimit)).reversed())

        // Store DB-layer health (the manager's own store, via StorageIntrospection).
        let health = try await store.storageStats(now: now)

        return StatusReport(
            monitoringEnabled: monitoringEnabled,
            totalMetrics: totalMetrics,
            totalEvents: events.count,
            byDropbox: byDropbox,
            byEstate: byEstate,
            recentEvents: recent,
            storeHealth: health
        )
    }

    // MARK: - Retention window (runtime-settable via control channel)

    /// The retention window currently in effect: the runtime override if the
    /// control channel set one, else the configured default.
    public var effectiveRetentionWindow: TimeInterval {
        retentionOverride ?? config.retentionWindow
    }

    /// Set the retention window at runtime (the gated `set retention` verb).
    ///
    /// A non-positive window is rejected — a zero window would roll off all data
    /// on the next pass, and negative is meaningless. The new window takes effect
    /// on the next `runRetention(now:)` and is reflected in `/api/config`.
    ///
    /// The override is persisted to a JSON sidecar file so it survives process
    /// restart. A write failure is logged but does not surface as an error — the
    /// in-process override applies immediately regardless of disk state.
    ///
    /// - Parameter window: The new retention window in seconds (must be > 0).
    /// - Throws: `ManagerError.invalidRetention` if `window <= 0`.
    public func setRetention(window: TimeInterval) throws {
        guard window > 0 else { throw ManagerError.invalidRetention }
        retentionOverride = window
        persistRetentionOverride(window)
        logger.info("MootManager retention window set to \(window)s")
    }

    // MARK: - Retention override persistence

    /// Sidecar file path for the persisted retention override, alongside the stats store.
    ///
    /// The filename is derived from the store filename stem (e.g. `moot-mgr.sqlite`
    /// → `moot-mgr-prefs.json`) so that two manager instances whose stores live in
    /// the same parent directory do not share the same prefs file (filename collision
    /// fix). Mirrors Rust `retention_prefs_path()`. The manager owns the directory
    /// and therefore the sidecar file.
    private var retentionPrefsURL: URL {
        let storeName = config.storeURL.deletingPathExtension().lastPathComponent
        return config.storeURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(storeName)-prefs.json", isDirectory: false)
    }

    /// Persist the retention override to the sidecar JSON file.
    ///
    /// A best-effort write: logs on failure but does not throw. The in-process
    /// value is authoritative for the current run; persistence is for restart
    /// survival. Format: `{"retentionWindow": <seconds>}`.
    private func persistRetentionOverride(_ window: TimeInterval) {
        let payload: [String: Double] = ["retentionWindow": window]
        do {
            let data = try JSONEncoder().encode(payload)
            try data.write(to: retentionPrefsURL, options: .atomic)
        } catch {
            logger.error("MootManager: failed to persist retention override: \(error)")
        }
    }

    /// Load the persisted retention override from the sidecar JSON file, if present.
    ///
    /// Returns nil when the file is absent (first start, or the file was removed)
    /// or when the stored value is non-positive (guards against a corrupted write).
    /// Called once in `start()` after the store opens.
    private func loadPersistedRetentionOverride() -> TimeInterval? {
        guard let data = try? Data(contentsOf: retentionPrefsURL) else { return nil }
        guard let payload = try? JSONDecoder().decode([String: Double].self, from: data),
              let window = payload["retentionWindow"],
              window > 0
        else { return nil }
        logger.info("MootManager: restored retention override from prefs: \(window)s")
        return window
    }

    // MARK: - HTTP read-API payload builders
    //
    // These project the store's current contents into the GUI-SPEC §10 payload
    // shapes. All are metadata-only (counts, enums, ISO-8601 strings) — the
    // content-safety invariant (concepts §1.6) is enforced here at the boundary:
    // nothing that could carry rung/memory content is read or projected.

    /// Build the `GET /api/server` payload.
    ///
    /// Includes live process metrics (RSS, CPU, RPC count, connections, protocol
    /// version, kernel backend) when the corresponding server.* and
    /// substrate.kernel.backend_selected samples exist in the store. All server-metric
    /// fields default to nil when no samples exist — the dashboard renders n/a chips
    /// for nil fields rather than fabricating values.
    ///
    /// - Parameters:
    ///   - now: Current time, stamped on the DB-health snapshot (caller owns the clock).
    ///   - uptimeSeconds: Whole seconds the resident host has been running.
    /// - Returns: A `ServerPayload`.
    /// - Throws: `StorageError` / `ManagerError.notStarted`.
    public func serverPayload(now: Date, uptimeSeconds: Int) async throws -> ServerPayload {
        let store = try requireStore()
        let monitoringEnabled = try await store.isMonitoringEnabled()
        // countMetrics() issues a SQL COUNT(*) — no row decoding, O(1) cost.
        let totalMetrics = try await store.countMetrics()
        let events = try await store.queryEvents(dropboxID: nil)
        let estateCount = Set(events.map(\.estate)).count
        let health = try await store.storageStats(now: now)

        // --- Server metric extraction (latest + second-latest per named metric) ---
        //
        // Bounded query: the name set is fixed and small (6 names). Using the targeted
        // SQL query instead of filtering `allMetrics` in-memory bounds the server-metric
        // surface to its intended names and avoids the DoS window where a noisy producer
        // floods arbitrary metric names into the server section. Mirrors the strategy
        // already used in `estatesPayload()` and `graphPayload()` for their named sets.
        let serverMetricNames: Set<String> = [
            "server.rss_mb", "server.cpu_user_ms", "server.rpc_count",
            "server.connections", "server.proto_version",
            "substrate.kernel.backend_selected",
        ]
        let serverMetrics = try await store.queryMetricsByNames(serverMetricNames)
        // latestByName[name] = (newer, older) — older is nil until the second sample arrives.
        var latestByName: [String: (MetricRow, MetricRow?)] = [:]
        for m in serverMetrics {
            if let (prev, _) = latestByName[m.name] {
                if m.ts > prev.ts {
                    // m is newer than current best — demote current best to the second slot
                    latestByName[m.name] = (m, prev)
                } else if latestByName[m.name]?.1 == nil || m.ts > latestByName[m.name]!.1!.ts {
                    // m is older than current best but newer than current second-best
                    latestByName[m.name] = (prev, m)
                }
            } else {
                latestByName[m.name] = (m, nil)
            }
        }

        let rssMb       = latestByName["server.rss_mb"].map { $0.0.value }
        let cpuUserMs   = latestByName["server.cpu_user_ms"].map { $0.0.value }
        let rpcCount    = latestByName["server.rpc_count"].map { Int($0.0.value) }
        let connections = latestByName["server.connections"].map { Int($0.0.value) }
        // protoVersion is carried in the "version" tag on the server.proto_version sample.
        let protoVersion  = latestByName["server.proto_version"].flatMap { $0.0.tags["version"] }
        // kernelBackend is carried in the "backend" tag on the backend_selected sample.
        let kernelBackend = latestByName["substrate.kernel.backend_selected"].flatMap { $0.0.tags["backend"] }

        // --- Delta-derived rates ---
        // rpcRate: delta RPC count / wall seconds between the two most-recent samples.
        // Nil when fewer than two samples exist (cold start, monitoring just enabled).
        let rpcRate: Double? = {
            guard let (newer, older) = latestByName["server.rpc_count"],
                  let olderRow = older else { return nil }
            let wallSeconds = newer.ts.timeIntervalSince(olderRow.ts)
            guard wallSeconds > 0 else { return nil }
            return max(0, newer.value - olderRow.value) / wallSeconds
        }()

        // cpuPct: (delta cpu_user_ms / wall_ms) * 100. Approximates the user-mode
        // CPU fraction consumed by this process between the two most-recent samples.
        let cpuPct: Double? = {
            guard let (newer, older) = latestByName["server.cpu_user_ms"],
                  let olderRow = older else { return nil }
            let wallMs = newer.ts.timeIntervalSince(olderRow.ts) * 1000.0
            guard wallMs > 0 else { return nil }
            return min(100.0, max(0, (newer.value - olderRow.value) / wallMs * 100.0))
        }()

        // --- Per-dropbox summaries for the Connects tab and Overview observers panel ---
        //
        // Replaces the previous `queryMetrics(dropboxID: nil)` full-table scan.
        // At 6M rows that scan caused a 504 timeout on every dashboard poll.
        // Instead: use `queryMetricAggregatesByDropbox` which issues one indexed
        // COUNT(*) + one LIMIT 1 projected ts-column read per estate — O(log n) total.
        //
        // Driver IDs come from events (already in memory, bounded by retention).
        // Every metric-emitting estate also emits events, so event-derived IDs
        // cover all active estates for the per-dropbox summary panel.
        var metricCountByDropbox: [String: Int] = [:]
        var lastMetricTsByDropbox: [String: Date] = [:]
        let payloadDropboxIDs = Array(Set(events.map(\.dropboxID)))
        let payloadAggregates = try await store.queryMetricAggregatesByDropbox(
            forDropboxIDs: payloadDropboxIDs
        )
        for agg in payloadAggregates {
            metricCountByDropbox[agg.dropboxID] = agg.metricCount
            // lastMetricTs is ISO-8601 TEXT; parse to Date for the lastSeen comparison below.
            if let ts = agg.lastMetricTs, let d = Self.iso8601Date(from: ts) {
                lastMetricTsByDropbox[agg.dropboxID] = d
            }
        }
        var eventCountByDropbox: [String: Int] = [:]
        var lastEventTsByDropbox: [String: Date] = [:]
        for e in events {
            eventCountByDropbox[e.dropboxID, default: 0] += 1
            if let prev = lastEventTsByDropbox[e.dropboxID] {
                if e.ts > prev { lastEventTsByDropbox[e.dropboxID] = e.ts }
            } else {
                lastEventTsByDropbox[e.dropboxID] = e.ts
            }
        }
        let allDropboxIDs = Set(payloadDropboxIDs).union(Set(eventCountByDropbox.keys))
        let byDropbox: [DropboxSummaryPayload] = allDropboxIDs.sorted().map { id in
            let lastMetric = lastMetricTsByDropbox[id]
            let lastEvent  = lastEventTsByDropbox[id]
            // Pick the more-recent of the metric and event timestamps for last-seen.
            let lastSeen: Date?
            switch (lastMetric, lastEvent) {
            case let (m?, e?) where m > e: lastSeen = m
            case let (_, e?):              lastSeen = e
            case let (m?, _):              lastSeen = m
            case (nil, nil):               lastSeen = nil
            }
            return DropboxSummaryPayload(
                name: id,
                metricCount: metricCountByDropbox[id] ?? 0,
                eventCount: eventCountByDropbox[id] ?? 0,
                lastSeenISO: lastSeen.map { Self.iso8601String(from: $0) }
            )
        }

        // --- NeuronKit capabilities from CognitionKit compile-time constant ---
        // shippedNeuronKitCapabilities is a Set<NeuronKitCapability> defined as a let
        // constant in CognitionKit. Sorted for stable JSON output.
        let capabilities = shippedNeuronKitCapabilities.map(\.rawValue).sorted()

        return ServerPayload(
            monitoringEnabled: monitoringEnabled,
            uptimeSeconds: uptimeSeconds,
            estateCount: estateCount,
            totalMetrics: totalMetrics,
            totalEvents: events.count,
            storeSizeBytes: health?.logicalSizeBytes ?? 0,
            storePageCount: health?.pageCount,
            storeFreelistPageCount: health?.freelistPageCount,
            storeWalFrameCount: health?.walFrameCount,
            storeCacheHitRatio: health?.cacheHitRatio,
            storeTransactionCommitCount: health?.transactionCommitCount,
            storeRowCount: health?.rowCount,
            rssMb: rssMb,
            cpuUserMs: cpuUserMs,
            rpcCount: rpcCount,
            connections: connections,
            protoVersion: protoVersion,
            kernelBackend: kernelBackend,
            rpcRate: rpcRate,
            cpuPct: cpuPct,
            byDropbox: byDropbox,
            capabilities: capabilities
        )
    }

    /// Build the `GET /api/estates` payload: per-estate event rollups with queue stats.
    ///
    /// Event counts are derived from the event-level estate tag. Queue and gate
    /// metrics are read from the latest queue.* and locuskit.gate.* metric samples,
    /// keyed by the `estate` tag. When no samples exist for an estate, `queue` is nil.
    ///
    /// - Returns: An `EstatesPayload`, estates sorted by id.
    /// - Throws: `StorageError` / `ManagerError.notStarted`.
    public func estatesPayload() async throws -> EstatesPayload {
        let store = try requireStore()
        // queryEvents returns oldest-first; the per-estate last-event timestamp
        // is therefore the timestamp of the LAST row seen for each estate.
        let events = try await store.queryEvents(dropboxID: nil)
        var counts: [String: Int] = [:]
        var lastTs: [String: Date] = [:]
        for e in events {
            counts[e.estate, default: 0] += 1
            // Keep the maximum ts per estate (events arrive oldest-first, but
            // take the max explicitly so the result is order-independent).
            if let prev = lastTs[e.estate] {
                if e.ts > prev { lastTs[e.estate] = e.ts }
            } else {
                lastTs[e.estate] = e.ts
            }
        }

        // For each estate (dropbox) we only need the LATEST sample per queue metric —
        // not every historical row. With 6.3M rows in the metric_samples table a
        // `WHERE name IN (...)` still full-scans that 6.3M set when the flooded names
        // ARE those queue.* names. The replacement method issues one indexed query per
        // (name, dropboxID) pair and returns ≤1 row per pair: 8 names × N dropboxes =
        // at most 8N rows regardless of table size, each hitting
        // idx_metric_samples_dropbox_id + ts-descending LIMIT 1 (O(log n) per query).
        let queueMetricNames: Set<String> = [
            "queue.depth", "queue.drain_count", "queue.idle_nonempty",
            "queue.latency_p50_ms", "queue.latency_p95_ms",
            "queue.head_of_line_age_s",
            "locuskit.gate.admit_count", "locuskit.gate.reject_count",
        ]
        // Restrict to the dropboxIDs seen in the event stream — same set of
        // dropboxes that report queue metrics. Unknown dropboxes produce no rows.
        let queueDropboxIDs = Array(Set(events.map(\.dropboxID)))
        let queueMetrics = try await store.queryLatestMetricsByNamesAndDropboxes(
            queueMetricNames, dropboxIDs: queueDropboxIDs
        )

        // Group by (estate, metric-name): keep the most-recent sample per key.
        struct QKey: Hashable { let estate: String; let metric: String }
        var latest: [QKey: MetricRow] = [:]
        for m in queueMetrics {
            let est = m.tags["estate"] ?? "unknown"
            let key = QKey(estate: est, metric: m.name)
            if let prev = latest[key] {
                if m.ts > prev.ts { latest[key] = m }
            } else {
                latest[key] = m
            }
        }

        // Build a QueueStats for each estate that has any queue metric samples.
        func latestValue(estate: String, metric: String) -> Double? {
            latest[QKey(estate: estate, metric: metric)].map { $0.value }
        }

        let rollups = counts.keys.sorted().map { id -> EstatePayload in
            // Build QueueStats only when at least one queue sample exists for this estate.
            let hasQueueData = queueMetricNames.contains { latestValue(estate: id, metric: $0) != nil }
            let queueStats: QueueStats? = hasQueueData ? QueueStats(
                depth: latestValue(estate: id, metric: "queue.depth"),
                drainCount: latestValue(estate: id, metric: "queue.drain_count"),
                idleNonempty: latestValue(estate: id, metric: "queue.idle_nonempty").map { $0 > 0 },
                latencyP50Ms: latestValue(estate: id, metric: "queue.latency_p50_ms"),
                latencyP95Ms: latestValue(estate: id, metric: "queue.latency_p95_ms"),
                headOfLineAgeS: latestValue(estate: id, metric: "queue.head_of_line_age_s"),
                gateAdmitCount: latestValue(estate: id, metric: "locuskit.gate.admit_count"),
                gateRejectCount: latestValue(estate: id, metric: "locuskit.gate.reject_count")
            ) : nil
            return EstatePayload(
                id: id,
                eventCount: counts[id] ?? 0,
                lastEventTs: lastTs[id].map { Self.iso8601String(from: $0) },
                queue: queueStats
            )
        }
        // Try to proxy ARIA_MCP for the admin/hosted estate list. On failure
        // (daemon unreachable, decode error) return nil admin so the caller falls
        // back to its local admin source (HTTPReadAPI merges adminSection ?? base.admin).
        var ariaAdmin: EstateAdminPayload? = nil
        if let url = URL(string: Self.ariaAPIBase + "/api/admin/estates") {
            do {
                let (data, _) = try await Self.ariaSession.data(from: url)
                ariaAdmin = try JSONDecoder().decode(EstateAdminPayload.self, from: data)
            } catch {
                logger.debug("ARIA_MCP admin/estates proxy unavailable: \(String(describing: error))")
            }
        }

        return EstatesPayload(estates: rollups, admin: ariaAdmin)
    }

    /// Build the `GET /api/events` payload: the most-recent events, newest first.
    ///
    /// - Parameter limit: Maximum events to include (newest first). Default 100.
    /// - Returns: An `EventsPayload`.
    /// - Throws: `StorageError` / `ManagerError.notStarted`.
    public func eventsPayload(limit: Int = 100) async throws -> EventsPayload {
        let store = try requireStore()
        let events = try await store.queryEvents(dropboxID: nil)
        let recent = Array(events.suffix(max(0, limit)).reversed())
        return EventsPayload(events: recent.map(Self.projectEvent))
    }

    /// Build the `GET /api/config` payload: current monitoring config.
    ///
    /// - Returns: A `ConfigPayload`.
    /// - Throws: `StorageError` / `ManagerError.notStarted`.
    public func configPayload() async throws -> ConfigPayload {
        let store = try requireStore()
        let monitoringEnabled = try await store.isMonitoringEnabled()
        return ConfigPayload(
            monitoringEnabled: monitoringEnabled,
            retentionSeconds: Int(effectiveRetentionWindow),
            retentionCutoff: Self.iso8601String(from: lastRetentionCutoff)
        )
    }

    /// Build the `GET /api/lexicon` payload: the ARIA grammar as static JSON.
    ///
    /// Enumerates AriaLexiconLib compile-time enums (Noun, Verb, Adjective) and the
    /// Acceptance matrix, then appends LatticeLib FDC metadata. No store access —
    /// all data is derived from compile-time constants, so this method never throws
    /// a StorageError and does not need the store to be started. Declared `async`
    /// for consistency with the rest of the payload surface (called from an actor).
    ///
    /// - Returns: A `LexiconPayload` ready for JSON encoding.
    public func lexiconPayload() async -> LexiconPayload {
        let nouns      = Noun.allCases.map(\.rawValue)
        let verbs      = Verb.allCases.map(\.rawValue)
        let adjectives = Adjective.allCases.map(\.rawValue)

        // Build the acceptance matrix: noun raw value → sorted array of accepted verb raw values.
        var acceptance: [String: [String]] = [:]
        for noun in Noun.allCases {
            acceptance[noun.rawValue] = Acceptance.verbs(for: noun).map(\.rawValue).sorted()
        }

        return LexiconPayload(
            nouns: nouns,
            verbs: verbs,
            adjectives: adjectives,
            acceptance: acceptance,
            fdcAvailable: FDC.isAvailable,
            fdcDataVersion: FDC.dataVersion,
            latticeVersion: LatticeLib.version
        )
    }

    /// Build the `GET /api/graph` payload: the Topology node-link snapshot.
    ///
    /// ## Data sources
    ///
    /// **Structure (nodes/edges):** read from the shared stats store's
    /// `topology_snapshots` table. The autonomic governor writes a snapshot row
    /// per estate on its cadence (default 300s); when no snapshot is available
    /// yet (governor startup pass not complete) `structurePending` is `true`
    /// and `nodes`/`edges` are empty. The A1 honesty pattern: a faked node
    /// graph is worse than an absent one (PoC spec §4.1 content boundary).
    ///
    /// **Analytic overlay (analytics/communities):** always sourced locally from
    /// the ObserverSink stats store (VizGraph signals emitted by SubstrateML).
    ///
    /// - Parameters:
    ///   - now: Current time, stamped as the snapshot timestamp (caller owns the
    ///     clock — determinism applies to engines, not this projection).
    ///   - estate: Optional estate filter (the `?estate=` query value). Used as
    ///     the estate key for the store lookup; also filters the local analytic
    ///     overlay to the matching estate tag.
    /// - Returns: A `GraphPayload`.
    /// - Throws: `StorageError` / `ManagerError.notStarted`.
    public func graphPayload(now: Date, estate: String? = nil) async throws -> GraphPayload {
        let store = try requireStore()

        // The canonical VizGraph signal names (SubstrateML/VizGraphSignals.swift).
        // Kept inline (not imported from SubstrateML) so moot-mgr does not take a
        // dependency on the analytics layer just to recognise its metric names —
        // these strings are the wire contract between emitter and reader.
        let vizSignals: Set<String> = [
            "community.assignment", "centrality.score", "nmf.factor",
            "anomaly.flag", "edge.decayed_weight",
        ]

        // VizGraph signal metrics: filter by event dropboxIDs to prevent a full
        // metric_samples table scan when millions of unrelated rows are present.
        // Unlike queue metrics (one dropbox per estate), VizGraph signals from
        // SubstrateML may be emitted by a single dropboxID for multiple estates —
        // the estate is carried as a row tag, not encoded in the dropboxID.  So
        // queryMetricsByNames per dropboxID is used (not queryLatestMetricsByNames
        // AndDropboxes) to ensure rows for ALL estates within a dropboxID are
        // returned; the analytics code below keeps the latest per (estate, signal).
        let vizEvents = try await store.queryEvents(dropboxID: nil)
        let vizDropboxIDs = Array(Set(vizEvents.map(\.dropboxID)))
        var vizMetrics: [MetricRow] = []
        for dropboxID in vizDropboxIDs {
            let rows = try await store.queryMetricsByNames(vizSignals, dropboxID: dropboxID)
            vizMetrics.append(contentsOf: rows)
        }

        // Group by (estate, signal). Estate is a metric tag (VizGraphSignals);
        // samples missing it are bucketed under "unknown" rather than dropped.
        struct Key: Hashable { let estate: String; let signal: String }
        var latest: [Key: MetricRow] = [:]
        var counts: [Key: Int] = [:]
        for m in vizMetrics {
            // Honour the optional estate filter against the sample's estate tag.
            let est = m.tags["estate"] ?? "unknown"
            if let estate, !estate.isEmpty, estate != "all", est != estate { continue }
            let key = Key(estate: est, signal: m.name)
            counts[key, default: 0] += 1
            if let prev = latest[key] {
                if m.ts > prev.ts { latest[key] = m }
            } else {
                latest[key] = m
            }
        }

        // Analytic overlay rows, sorted (estate, signal) for byte-stable output.
        let analytics = latest.keys
            .sorted { $0.estate != $1.estate ? $0.estate < $1.estate : $0.signal < $1.signal }
            .map { key -> GraphAnalyticPayload in
                let row = latest[key]!
                return GraphAnalyticPayload(
                    estate: key.estate,
                    signal: key.signal,
                    value: row.value,
                    ts: Self.iso8601String(from: row.ts),
                    sampleCount: counts[key] ?? 0
                )
            }

        // Fallback community rollup from the `community.assignment` signal,
        // whose value is the number of communities discovered for that estate
        // (VizGraphSignals.swift). The signal carries only the count, so each
        // entry is a count-only placeholder: nil label (no udcCode locally),
        // size 0 (memberships unknown), id = running legend index. Replaced by
        // ARIA's enriched descriptors when the proxy succeeds below.
        var communities: [GraphCommunityPayload] = []
        for key in latest.keys.sorted(by: { $0.estate < $1.estate })
            where key.signal == "community.assignment" {
            // Cap the untrusted metric value to prevent a crafted sample from
            // triggering an unbounded allocation loop. 10,000 community nodes is
            // a generous ceiling; legitimate graph analytics never approach it.
            // Mirrors Rust `graph_payload()` which uses `.max(0.0).min(10_000.0)`.
            let communityCount = max(0, min(Int(latest[key]!.value.rounded()), 10_000))
            for _ in 0..<communityCount {
                communities.append(GraphCommunityPayload(
                    id: communities.count, label: nil, size: 0
                ))
            }
        }

        // Read the topology snapshot from the shared stats store.
        // The governor writes one row per estate UUID on its cadence; when no
        // snapshot has been written yet (fresh start, first duty not complete),
        // returns structurePending:true with the honest enumeration below.
        var liveNodes: [GraphNodePayload] = []
        var liveEdges: [GraphEdgePayload] = []
        var structurePending = true
        var generatedTs: String? = nil
        var pendingReasons: [String] = [
            "topology snapshot not yet available — the autonomic governor has not completed its first duty cycle",
        ]

        // Estate filter "all"/empty/nil — the dashboard's DEFAULT view — reads
        // the newest snapshot across all estates (nil key); an explicit estate
        // filter reads that estate's row.
        let estateKey: String? = (estate?.isEmpty == false && estate != "all") ? estate : nil
        if let snapshotData = try? await store.latestTopologySnapshot(estate: estateKey) {
            // Enrichment cache: the snapshot only changes when the governor
            // writes (and the dirty check means: only when the estate
            // changed), but the dashboard polls far more often. Decoding the
            // ~1MB payload and running the FDC label enrichment on every
            // poll re-derives identical results — so the decoded+enriched
            // product is cached, keyed by (estateKey, raw bytes). The byte
            // compare is a ~50µs memcmp; a hit skips the JSONDecoder pass
            // and all FDC lookups. Single-slot: the dashboard polls one
            // estate view at a time, and an estate-filter switch just
            // repopulates on the next request.
            if let cached = topologyEnrichmentCache,
               cached.estateKey == estateKey, cached.raw == snapshotData {
                liveNodes = cached.nodes
                liveEdges = cached.edges
                structurePending = false
                generatedTs = cached.generatedTs
                pendingReasons = []
                if let enriched = cached.communities { communities = enriched }
            } else if let stored = try? JSONDecoder().decode(StoredGraphPayload.self, from: snapshotData),
                      !stored.structurePending {
                liveNodes = stored.nodes
                liveEdges = stored.edges
                structurePending = false
                generatedTs = stored.generatedTs
                pendingReasons = []
                // VIZ_V2 L3: prefer governor's real community descriptors,
                // enriched with FDC labels (raw dominantUdcCode dropped here).
                // Keep the local count-only rollup when the snapshot predates
                // the communities field.
                var enriched: [GraphCommunityPayload]? = nil
                if let raw = stored.communities {
                    enriched = Self.enrichCommunities(raw)
                    communities = enriched!
                }
                topologyEnrichmentCache = (estateKey, snapshotData,
                                           stored.nodes, stored.edges,
                                           enriched, stored.generatedTs)
            }
        }

        return GraphPayload(
            nodes: liveNodes,
            edges: liveEdges,
            communities: communities,
            analytics: analytics,
            structurePending: structurePending,
            pending: pendingReasons,
            generatedTs: generatedTs,
            estate: (estate?.isEmpty == false ? estate! : "all"),
            snapshotTs: Self.iso8601String(from: now)
        )
    }

    // MARK: - Lattice snapshot (GET /api/lattice)

    /// Build the `GET /api/lattice` payload: active lattice addresses with
    /// drawer counts, proxied from ARIA_MCP and annotated with FDC labels.
    ///
    /// Proxies ARIA_MCP's `GET /api/lattice` endpoint (which groups non-tombstoned
    /// drawers by their `udcCode` and returns code + count pairs). On any
    /// failure — daemon unreachable, decode error, timeout — returns
    /// `pending: true` with an empty address list so the dashboard degrades
    /// gracefully. Labels are resolved from the bundled `FDCFrame` via
    /// `FDC.label(for:)` without touching the estate; nil label means the
    /// code is MDCC or otherwise not in the current FDC frame.
    ///
    /// CONTENT-SAFETY INVARIANT: only classification codes, FDC heading labels
    /// (from the bundled taxonomy, not from estate content), and integer counts
    /// cross this surface.
    public func latticePayload() async -> LatticeSnapshotPayload {
        // The ARIA_MCP raw proxy response shape (code + count only, no labels).
        struct ARIALatticeAddress: Decodable { let code: String; let count: Int }
        struct ARIALatticePayload: Decodable { let addresses: [ARIALatticeAddress] }

        guard let url = URL(string: Self.ariaAPIBase + "/api/lattice") else {
            return LatticeSnapshotPayload(addresses: [], pending: true)
        }
        do {
            let (data, _) = try await Self.ariaSession.data(from: url)
            let proxy = try JSONDecoder().decode(ARIALatticePayload.self, from: data)
            let addresses = proxy.addresses.map { entry in
                LatticeAddressPayload(
                    code: entry.code,
                    label: FDC.label(for: entry.code),
                    count: entry.count
                )
            }
            return LatticeSnapshotPayload(addresses: addresses, pending: false)
        } catch {
            logger.debug("ARIA_MCP lattice proxy unavailable: \(String(describing: error))")
            return LatticeSnapshotPayload(addresses: [], pending: true)
        }
    }

    /// Enrich ARIA community descriptors to the browser wire shape (VIZ_V2 L3):
    /// `{id, size, dominantUdcCode}` → `{id, label, size}`.
    ///
    /// The dominant UDC code is resolved to its FDC heading label via
    /// `FDC.label(for:)` (bundled taxonomy — never estate content) and then
    /// DROPPED: a raw classification code is an estate-derived datum and stays
    /// behind this content boundary; only the heading label crosses. An empty,
    /// MDCC, or unknown code yields a nil label (JSON null). ARIA's
    /// size-descending order is preserved.
    static func enrichCommunities(_ raw: [ARIACommunityDescriptor]) -> [GraphCommunityPayload] {
        raw.map { descriptor in
            GraphCommunityPayload(
                id: descriptor.id,
                // FDC.label(for:) returns nil for "" — no special-casing needed.
                label: FDC.label(for: descriptor.dominantUdcCode ?? ""),
                size: descriptor.size
            )
        }
    }

    /// Project an `EventRow` to its metadata-only wire payload.
    /// Centralised so the SSE path and the snapshot path emit identical shapes.
    /// An empty `rowIDStr` projects to nil so the wire carries null, never ""
    /// (VIZ_V2 L1 contract).
    static func projectEvent(_ e: EventRow) -> EventPayload {
        EventPayload(
            ts: iso8601String(from: e.ts),
            kind: e.kind,
            nounType: e.nounType,
            estate: e.estate,
            dropbox: e.dropboxID,
            drawerId: e.rowIDStr.isEmpty ? nil : e.rowIDStr
        )
    }

    // MARK: - ISO-8601 formatting

    /// Format a `Date` as ISO-8601 UTC TEXT, matching the store's on-disk format
    /// ("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'") so wire timestamps equal stored ones.
    ///
    /// Local to MootManager (not reusing ObserverSink's internal formatter,
    /// which is not part of its public surface) — the format string is the
    /// single source of agreement between the two.
    static func iso8601String(from date: Date) -> String {
        iso8601Formatter.string(from: date)
    }

    /// Parse an ISO-8601 UTC string produced by StatsStore's aggregate queries.
    ///
    /// Used to convert the `lastMetricTs` ISO-8601 string from
    /// `DropboxMetricAggregate` to a `Date` for comparison with event timestamps.
    /// Returns `nil` when the string cannot be parsed (e.g. empty or corrupt row).
    static func iso8601Date(from string: String) -> Date? {
        iso8601Formatter.date(from: string)
    }

    /// Shared ISO-8601 UTC formatter for read-API timestamps. Static constant —
    /// initialised once, never mutated, safe to share across the actor.
    private static let iso8601Formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")!
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return f
    }()

    // MARK: - Store access (for in-process consumers / tests)

    /// The opened stats store, for an in-process consumer that wants to install
    /// a `PersistenceStatsSink` against the manager's store (e.g. the
    /// integration test or a co-resident consumer).
    ///
    /// - Returns: The opened `StatsStore`.
    /// - Throws: `ManagerError.notStarted` if `start()` has not been called.
    public func statsStore() throws -> StatsStore {
        try requireStore()
    }

    // MARK: - Internal helpers

    /// Return the opened store or throw `ManagerError.notStarted`.
    private func requireStore() throws -> StatsStore {
        guard let store else { throw ManagerError.notStarted }
        return store
    }
}

// MARK: - ManagerError

/// Errors raised by `MootManager` operations.
///
/// Structured enum per the project error-handling rule (no optionals-plus-logging).
public enum ManagerError: Error, Sendable, Equatable {
    /// A manager operation was called before `start()` opened the store.
    case notStarted
    /// A retention window of zero or less was supplied to `setRetention(window:)`.
    case invalidRetention
}
