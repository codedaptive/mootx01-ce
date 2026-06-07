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
    /// Held on the actor (in-process) rather than persisted: the Phase-1
    /// `StatsStore` exposes only typed monitoring/retention-cutoff control
    /// accessors and no generic control upsert, so a custom window cannot be
    /// durably written without modifying ObserverSink (out of this mission's
    /// directory — see the blast-radius note). The default-window path is
    /// unaffected; a restart falls back to the configured default. Durable
    /// custom-window persistence is a noted follow-up.
    private var retentionOverride: TimeInterval?

    /// The cutoff the most-recent `runRetention(now:)` pass used, surfaced by
    /// `/api/config` so the dashboard can show when data was last rolled off.
    ///
    /// Tracked on the actor (not read back from the store's control row): the
    /// Phase-1 `StatsStore` has no public reader for its `retention_cutoff`
    /// control row, and adding one would mean editing ObserverSink (outside this
    /// mission's directory). The host runs the retention loop in-process, so the
    /// actor is the authoritative owner of "what cutoff did we last apply." It
    /// holds the epoch-zero sentinel until the first pass runs (matching the
    /// store's own seed value, so the API reports the same "never" before the
    /// first roll-off).
    private var lastRetentionCutoff: Date = Date(timeIntervalSince1970: 0)

    private let logger = Logger(subsystem: "com.mootx01.kit", category: "MootManager")

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
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let store = try StatsStore(url: config.storeURL)
        try await store.open()
        self.store = store
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

        // Pull all samples (no dropbox filter) and aggregate in-process. Phase 1
        // is single-host with bounded retention, so a full scan is acceptable;
        // SQL-side GROUP BY aggregation is a Phase-3 dashboard optimisation.
        let metrics = try await store.queryMetrics(dropboxID: nil)
        let events = try await store.queryEvents(dropboxID: nil)

        // By-dropbox: count metrics and events per dropbox id.
        var dropboxMetricCounts: [String: Int] = [:]
        var dropboxEventCounts: [String: Int] = [:]
        for m in metrics { dropboxMetricCounts[m.dropboxID, default: 0] += 1 }
        for e in events { dropboxEventCounts[e.dropboxID, default: 0] += 1 }
        let dropboxKeys = Set(dropboxMetricCounts.keys).union(dropboxEventCounts.keys)
        let byDropbox = dropboxKeys.sorted().map { key in
            GroupCount(
                key: key,
                metricCount: dropboxMetricCounts[key] ?? 0,
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
            totalMetrics: metrics.count,
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
    /// - Parameter window: The new retention window in seconds (must be > 0).
    /// - Throws: `ManagerError.invalidRetention` if `window <= 0`.
    public func setRetention(window: TimeInterval) throws {
        guard window > 0 else { throw ManagerError.invalidRetention }
        retentionOverride = window
        logger.info("MootManager retention window set to \(window)s")
    }

    // MARK: - HTTP read-API payload builders
    //
    // These project the store's current contents into the GUI-SPEC §10 payload
    // shapes. All are metadata-only (counts, enums, ISO-8601 strings) — the
    // content-safety invariant (concepts §1.6) is enforced here at the boundary:
    // nothing that could carry rung/memory content is read or projected.

    /// Build the `GET /api/server` payload.
    ///
    /// - Parameters:
    ///   - now: Current time, stamped on the DB-health snapshot (caller owns the clock).
    ///   - uptimeSeconds: Whole seconds the resident host has been running.
    /// - Returns: A `ServerPayload`.
    /// - Throws: `StorageError` / `ManagerError.notStarted`.
    public func serverPayload(now: Date, uptimeSeconds: Int) async throws -> ServerPayload {
        let store = try requireStore()
        let monitoringEnabled = try await store.isMonitoringEnabled()
        let metrics = try await store.queryMetrics(dropboxID: nil)
        let events = try await store.queryEvents(dropboxID: nil)
        let estateCount = Set(events.map(\.estate)).count
        let health = try await store.storageStats(now: now)
        return ServerPayload(
            monitoringEnabled: monitoringEnabled,
            uptimeSeconds: uptimeSeconds,
            estateCount: estateCount,
            totalMetrics: metrics.count,
            totalEvents: events.count,
            storeSizeBytes: health?.logicalSizeBytes ?? 0
        )
    }

    /// Build the `GET /api/estates` payload: per-estate event rollups.
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
        let rollups = counts.keys.sorted().map { id in
            EstatePayload(
                id: id,
                eventCount: counts[id] ?? 0,
                lastEventTs: lastTs[id].map { Self.iso8601String(from: $0) }
            )
        }
        return EstatesPayload(estates: rollups)
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

    /// Build the `GET /api/graph` payload: the Topology node-link snapshot.
    ///
    /// ## Data sources and the structure gap
    ///
    /// moot-mgr is a pure observer — it owns the ObserverSink stats store and
    /// has no estate DB or MCP client. Graph STRUCTURE (per-node `NounType`
    /// rows, per-edge tunnel/kgFact/association relations) lives in the live
    /// estate, reached over the mootx01 MCP (`moot_estate_map` /
    /// `moot_connection_map`) — a path this host does not have. So `nodes` and
    /// `edges` are empty and `structurePending` is true, with the gap
    /// enumerated in `pending`. No nodes/edges are fabricated (A1 honesty
    /// pattern; PoC spec §4.1 content boundary).
    ///
    /// What this host CAN source is the VizGraph telemetry the SubstrateML
    /// analytics emit through IntellectusLib → ObserverSink when monitoring is
    /// on (`VizGraphSignals`). Those metric samples are aggregate completion
    /// signals tagged by `estate`; this builder reads them from the stats store,
    /// keeps the latest sample per (estate, signal), and projects them as the
    /// analytic overlay (`analytics`) plus a per-estate community rollup
    /// (`communities`) derived from `community.assignment`.
    ///
    /// - Parameters:
    ///   - now: Current time, stamped as the snapshot timestamp (caller owns the
    ///     clock — determinism applies to engines, not this projection).
    ///   - estate: Optional estate filter (the `?estate=` query value). Echoed
    ///     back; sampling/scoping is a no-op while structure is pending.
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

        // Read all metric samples and keep only the VizGraph telemetry. Phase-1
        // retention bounds the store, so a full scan + in-process filter is fine
        // (same approach as status()/serverPayload()).
        let metrics = try await store.queryMetrics(dropboxID: nil)
        let vizMetrics = metrics.filter { vizSignals.contains($0.name) }

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

        // Per-estate community rollup from the `community.assignment` signal,
        // whose value is the number of communities discovered for that estate
        // (VizGraphSignals.swift). One swatch per community, brand-derived colour.
        var communities: [GraphCommunityPayload] = []
        for key in latest.keys.sorted(by: { $0.estate < $1.estate })
            where key.signal == "community.assignment" {
            let communityCount = max(0, Int(latest[key]!.value.rounded()))
            for i in 0..<communityCount {
                communities.append(GraphCommunityPayload(
                    id: i, estate: key.estate, color: Self.communityColor(i)
                ))
            }
        }

        // The structure gap, enumerated honestly (A1 pattern). Always pending in
        // this cut — the resident host cannot reach the estate graph.
        let pending = [
            "nodes: per-node NounType rows require the live estate (mootx01 MCP moot_estate_map) — not reachable from the resident observer host",
            "edges: tunnel/kgFact/association relations require the live estate (mootx01 MCP moot_connection_map) — not reachable from the resident observer host",
            "per-node centrality / community / anomaly: stored in the estate's row_keystone_score column, not in the observer stats store (VizGraphSignals.swift)",
        ]

        return GraphPayload(
            nodes: [],
            edges: [],
            communities: communities,
            analytics: analytics,
            structurePending: true,
            pending: pending,
            estate: (estate?.isEmpty == false ? estate! : "all"),
            snapshotTs: Self.iso8601String(from: now)
        )
    }

    /// A brand-derived community colour for swatch index `i` (orange/blue family
    /// with desaturated mid-range fills, PoC spec §3.1). Deterministic by index
    /// so the legend is stable across snapshots; cycles for large community sets.
    static func communityColor(_ i: Int) -> String {
        let palette = [
            "#ff8c00", "#3ab4ff", "#ffb74d", "#64c8ff",
            "#b478ff", "#00d28c", "#ff5078", "#ffc83c",
        ]
        return palette[i % palette.count]
    }

    /// Project an `EventRow` to its metadata-only wire payload.
    /// Centralised so the SSE path and the snapshot path emit identical shapes.
    static func projectEvent(_ e: EventRow) -> EventPayload {
        EventPayload(
            ts: iso8601String(from: e.ts),
            kind: e.kind,
            nounType: e.nounType,
            estate: e.estate,
            dropbox: e.dropboxID
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
