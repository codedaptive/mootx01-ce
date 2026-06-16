import CognitionKit
import Foundation
import GeniusLocusKit
import LatticeLib
import LocusKit
import NeuronKit
import SubstrateTypes

/// Read the topology snapshot cadence from the environment.
///
/// `MOOTX01_TOPOLOGY_CADENCE_SECONDS` controls how often the governor recomputes
/// and stores the topology snapshot. Default 300 s (5 min). The env value is
/// multiplied by 1 000 to match the millisecond resolution used throughout the
/// governor tick machinery. Invalid or absent values fall back silently to the default.
///
/// This is a free function (not a method) so it can be referenced in a default
/// argument of `AutonomicGovernor.init` without the Swift restriction on
/// referencing `self` or `Self` in default argument expressions.
public func autonomicGovernorDefaultTopologyCadenceMs() -> Int {
    guard let raw = ProcessInfo.processInfo.environment["MOOTX01_TOPOLOGY_CADENCE_SECONDS"],
          let secs = Int(raw), secs >= 0
    else { return 300_000 }
    return secs * 1000
}

/// Read the pool-reduce cadence from the environment.
///
/// `MOOTX01_POOL_REDUCE_CADENCE_SECONDS` controls the MINIMUM spacing between
/// novel-token reduce passes. Default 0 — NEAR-REALTIME: the reducer is
/// considered every governor tick, gated cheaply by its own no-op-safe scan (an
/// absent/empty pool directory is a single enumerate that returns
/// `result.isNoop`, so an idle tick costs nothing). When the novel-token pool
/// crosses the submission threshold a file lands in the pool directory, and the
/// very next tick folds it into the writable WordClassTable artifact and live-
/// swaps the running tagger. The reduce latency floor is therefore the base
/// tick (`MOOTX01_BRAIN_TICK_MS`), not a fixed hour.
///
/// A positive value reinstates a minimum spacing (test determinism / load
/// throttling); 0 is the shipping near-realtime default. Invalid or absent
/// values fall back to 0. This supersedes the prior hourly cadence (cookbook
/// §2.2 rewrite). A free function (not a method) so it can be a default argument
/// of `AutonomicGovernor.init` without the Swift `self`/`Self` restriction in
/// default-argument expressions.
public func autonomicGovernorDefaultPoolReduceCadenceMs() -> Int {
    guard let raw = ProcessInfo.processInfo.environment["MOOTX01_POOL_REDUCE_CADENCE_SECONDS"],
          let secs = Int(raw), secs >= 0
    else { return 0 }
    return secs * 1000
}

/// The resident Autonomic Governor (see ADR-LOOPBACKHTTP-001 §17).
///
/// mootx01 is the headless resident server that owns the whole vertical, so it
/// is what triggers the Brain. This loop drives the Brain's cadence work on each
/// daemon's own interval: dreaming (NeuronKit), maintenance (NeuronKit), and the
/// standing-signal scheduler (GeniusLocusKit). It runs alongside the HTTP
/// transport for the lifetime of the resident process.
///
/// DETERMINISM (ARIA_MCP_SPEC §9/§17): the loop is the ONLY scheduler. It reads
/// the clock once per tick and injects that `now` into every daemon; the daemons
/// never read `Date()` themselves (the conformance contract). Each daemon
/// self-gates on its own interval — `pump(now:)` returns `nil` until its interval
/// has elapsed — so the loop can tick at a coarse base granularity and let each
/// daemon decide whether to fire.
///
/// RESILIENCE: a pump failure logs to stderr and the loop continues — the
/// governor must never crash the daemon. Task cancellation (process shutdown)
/// breaks the loop cleanly; it is never treated as a pump error (which would
/// busy-spin).
///
/// POLICY (P2): cadence policy comes from in-memory stores seeded with spec
/// defaults (dreaming 30 s, maintenance 5 min). P3 swaps these for the manifest
/// store so an operator's policy survives restarts; the seam is unchanged.
public actor AutonomicGovernor {

    private let kit: GeniusLocusKit
    private let handle: EstateHandle
    private let dreaming: DreamingDaemon
    private let maintenance: MaintenanceDaemon
    /// Base loop granularity in milliseconds — the sampling resolution for the
    /// daemons' own (longer) cadences, not a cadence itself.
    private let baseTickMs: Int
    /// How often graph analytics (Keystones + Constellation per wing) fire.
    /// Default 10 minutes; pass 0 in tests to fire on every tick.
    private let graphAnalyticsIntervalMs: Int
    /// Wall-clock instant of the most recent graphAnalyticsScan dispatch.
    /// Nil on first tick so the scan fires immediately at startup.
    private var lastGraphAnalyticsFired: Date? = nil
    /// Cadence for the topology snapshot duty in milliseconds.
    /// Configurable via MOOTX01_TOPOLOGY_CADENCE_SECONDS (default 300 s).
    /// Pass 0 in tests to fire on every tick.
    private let topologyCadenceMs: Int
    /// Wall-clock instant of the most recent topologySnapshotDuty dispatch.
    /// Nil on first tick so the duty fires immediately at startup.
    private var lastTopologySnapshotFired: Date? = nil
    /// Called by topologySnapshotDuty when a snapshot is ready.
    /// Nil when no stats store is configured (no consumer to write to).
    /// Injected in ResidentDaemon so AriaMCP never imports ObserverSink directly.
    private let topologyHandler: (@Sendable (String, Date, Data) async -> Void)?
    /// Monitoring gate for the topology duty. Checked at each due cadence
    /// BEFORE any estate read or compute: false skips the entire duty for
    /// that interval ("off is free"). Nil = always run. Injected in
    /// ResidentDaemon from the stats store's live monitoring flag, so a
    /// moot-mgr on/off flip takes effect at the next cadence without restart.
    private let topologyGate: (@Sendable () async -> Bool)?
    /// Process-local dirty token of the most recent COMPUTED topology snapshot
    /// inputs. When the next due cadence yields the same token, the duty skips
    /// the Louvain/centrality math, the encode, and the store write — the
    /// stored snapshot is still current (generatedTs therefore means "when the
    /// content last changed", not "when the duty last ran"). In-memory only:
    /// reset to nil at every process start, never persisted, never compared
    /// across processes.
    private var lastTopologyInputsToken: TopologyInputsToken? = nil
    /// Minimum spacing between PoolReducer (novel-token merge-back) passes, in
    /// milliseconds. Default 0 — NEAR-REALTIME: considered every tick, gated by
    /// the reducer's own no-op-safe scan, then live-swaps the running tagger on a
    /// non-noop merge. A positive MOOTX01_POOL_REDUCE_CADENCE_SECONDS reinstates a
    /// minimum spacing (test determinism / load throttling).
    private let poolReduceCadenceMs: Int
    /// Wall-clock instant of the most recent PoolReducer run. Nil on first tick
    /// so the reduce fires immediately at startup (folding any pool accumulated
    /// while the daemon was down).
    private var lastPoolReduceFired: Date? = nil
    /// Pool directory the reducer scans, resolved once at construction from the
    /// LatticeLib convention (LATTICE_POOL_DIR or the platform default). Nil only
    /// in tests that opt out of the reduce path.
    private let poolDirectory: URL?
    /// Writable WordClassTable artifact the reducer merges into (sibling of the
    /// pool directory). Resolved once at construction. Nil only in tests.
    private let poolTableArtifactURL: URL?
    /// Injected for deterministic tests; production reads the wall clock.
    private let clock: @Sendable () -> Date

    public init(
        kit: GeniusLocusKit,
        handle: EstateHandle,
        baseTickMs: Int = 5000,
        graphAnalyticsIntervalMs: Int = 600_000,
        topologyCadenceMs: Int = autonomicGovernorDefaultTopologyCadenceMs(),
        poolReduceCadenceMs: Int = autonomicGovernorDefaultPoolReduceCadenceMs(),
        topologyHandler: (@Sendable (String, Date, Data) async -> Void)? = nil,
        topologyGate: (@Sendable () async -> Bool)? = nil,
        // Pool paths default to the LatticeLib-resolved convention. Tests pass
        // explicit temp paths (or nil to skip the reduce path entirely).
        poolDirectory: URL? = NovelPoolSubmitter.poolDirectory(),
        poolTableArtifactURL: URL? = NovelPoolSubmitter.tableArtifactURL(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.kit = kit
        self.handle = handle
        self.baseTickMs = baseTickMs
        self.graphAnalyticsIntervalMs = graphAnalyticsIntervalMs
        self.topologyCadenceMs = topologyCadenceMs
        self.poolReduceCadenceMs = poolReduceCadenceMs
        self.poolDirectory = poolDirectory
        self.poolTableArtifactURL = poolTableArtifactURL
        self.topologyHandler = topologyHandler
        self.topologyGate = topologyGate
        self.clock = clock
        // Construct the daemons against the live estate via NeuronKit's seam
        // adapters. In-memory policy stores for P2 (P3 → manifest store).
        self.dreaming = NeuronKit.dreamingDaemon(
            reader: EstateDreamingReader(handle: handle, kit: kit),
            sink: EstateDreamingSink(handle: handle, kit: kit),
            policyStore: InMemoryDreamingPolicyStore()
        )
        self.maintenance = MaintenanceDaemon(
            reader: EstateMaintenanceReader(handle: handle, kit: kit),
            sink: EstateMaintenanceSink(handle: handle, kit: kit),
            policyStore: InMemoryMaintenancePolicyStore()
        )
    }


    /// What fired on one tick — returned for tests; ignored by `run()`.
    public struct GovernorReport: Sendable {
        public let dreamingFired: Bool
        public let maintenanceFired: Bool
        public let signalsTicked: Bool
        /// True when this tick dispatched a graph-analytics scan Task.
        public let graphAnalyticsFired: Bool
        /// True when this tick dispatched a topology-snapshot duty Task.
        public let topologySnapshotFired: Bool
        /// True when this tick ran the PoolReducer (novel-token merge-back).
        /// Reflects the near-realtime gate firing — true even on an empty-pool
        /// no-op, false on a reduce error (logged; the loop continues) or when
        /// no pool paths are configured.
        public let poolReduceFired: Bool
        /// True when this tick LIVE-SWAPPED the word-class table after a
        /// non-noop reduce merged novel tokens — the running tagger adopted the
        /// new table in-session (no restart). False on a noop/absent reduce.
        public let tableSwapped: Bool
        /// The word-class table version after this tick. Bumped on every live
        /// swap; lets tests/telemetry observe in-session learning.
        public let tableVersion: UInt64
    }

    /// Run the governor loop until the task is cancelled (process shutdown).
    public func run() async {
        // Load persisted cadence policy once (best-effort; an empty store leaves
        // the spec defaults in place).
        do { try await dreaming.loadPersistedPolicy() }
        catch { Logging.stderr.log("AutonomicGovernor: dreaming policy load failed: \(error)") }
        do { try await maintenance.loadPersistedPolicy() }
        catch { Logging.stderr.log("AutonomicGovernor: maintenance policy load failed: \(error)") }

        Logging.stderr.log("AutonomicGovernor started (base tick \(baseTickMs)ms)")
        while !Task.isCancelled {
            _ = await tick(now: clock())
            // Sleep OUTSIDE the per-pump catches. Task.sleep throws
            // CancellationError on shutdown — break the loop; never log-and-continue
            // (that would spin at 100% CPU). Any sleep error ends the loop.
            do { try await Task.sleep(nanoseconds: UInt64(baseTickMs) * 1_000_000) }
            catch { break }
        }
        Logging.stderr.log("AutonomicGovernor stopped")
    }

    /// One governor iteration with an injected `now`. Each daemon self-gates; each
    /// call is isolated so one daemon's failure cannot stop the others or the
    /// loop. Exposed for deterministic tests.
    @discardableResult
    public func tick(now: Date) async -> GovernorReport {
        var dreamingFired = false
        var maintenanceFired = false
        var signalsTicked = false

        do { dreamingFired = try await dreaming.pump(now: now) != nil }
        catch { Logging.stderr.log("AutonomicGovernor: dreaming pump error: \(error)") }

        do { maintenanceFired = try await maintenance.pump(now: now) != nil }
        catch { Logging.stderr.log("AutonomicGovernor: maintenance pump error: \(error)") }

        // Standing signals: the resident daemon registers the default standing
        // signals once at bootstrap (AriaResident.runResidentDaemon, before this
        // loop starts), so on the live path signalTick finds a registered
        // scheduler and drives real propose/associate emissions. The
        // schedulerNotStarted branch below remains the safety net: a test
        // governor with no registration, or a defensive path where no VectorStore
        // was available to register against, benign-skips rather than erroring —
        // treating it as an error would spam stderr every tick AND mask real
        // failures. Other (non-schedulerNotStarted) errors are still logged.
        do {
            try await kit.signalTick(in: handle, now: now)
            signalsTicked = true
        } catch let error as GeniusLocusKitError {
            if case .schedulerNotStarted = error {
                // benign — no standing signals registered yet, nothing to tick.
            } else {
                Logging.stderr.log("AutonomicGovernor: signalTick error: \(error)")
            }
        } catch {
            Logging.stderr.log("AutonomicGovernor: signalTick error: \(error)")
        }

        // Graph analytics: fire Keystones + Constellation per wing on the configured
        // interval (default 10 min). First tick fires immediately (lastGraphAnalyticsFired
        // is nil). The scan runs in an unstructured Task (actor-inherited context;
        // graphAnalyticsScan is nonisolated, so the actor's executor is released at
        // its first await — tick() returns without stalling). Errors are logged and
        // never propagated to tick().
        let graphAnalyticsElapsed = lastGraphAnalyticsFired.map {
            now.timeIntervalSince($0) * 1000 >= Double(graphAnalyticsIntervalMs)
        } ?? true

        if graphAnalyticsElapsed {
            lastGraphAnalyticsFired = now
            Task { [kit, handle, now] in
                do { try await AutonomicGovernor.graphAnalyticsScan(kit: kit, handle: handle, now: now) }
                catch { Logging.stderr.log("AutonomicGovernor: graphAnalyticsScan error: \(error)") }
            }
        }

        // Topology snapshot duty: estate-read + NeuronKit.graphTopology + encode + store write.
        // Fires on first tick (lastTopologySnapshotFired is nil) and then on every
        // MOOTX01_TOPOLOGY_CADENCE_SECONDS interval (default 300 s). When no handler
        // is wired (no stats store configured), the elapsed flag is still tracked so
        // the interval resets correctly if a handler is later injected in a future
        // process start. Two cheap escapes before the expensive work:
        //   1. topologyGate (the live monitoring flag): false skips the interval
        //      entirely — no estate read, no math ("off is free").
        //   2. The inputs dirty token inside the duty: an unchanged estate skips
        //      the math/encode/write and keeps the stored snapshot current.
        let topologyElapsed = lastTopologySnapshotFired.map {
            now.timeIntervalSince($0) * 1000 >= Double(topologyCadenceMs)
        } ?? true

        if topologyElapsed {
            lastTopologySnapshotFired = now
            if let handler = topologyHandler {
                // nonisolated static func — actor executor released at first await.
                Task { [kit, handle, now, handler, topologyGate, lastTopologyInputsToken] in
                    if let gate = topologyGate, !(await gate()) { return }
                    do {
                        let token = try await AutonomicGovernor.topologySnapshotDuty(
                            kit: kit, handle: handle, now: now,
                            previous: lastTopologyInputsToken,
                            handler: handler)
                        await self.recordTopologyInputsToken(token)
                    } catch {
                        Logging.stderr.log("AutonomicGovernor: topologySnapshotDuty error: \(error)")
                    }
                }
            }
        }

        // Pool reducer (novel-token merge-back) + LIVE TAGGER SWAP — the
        // in-session learning loop. NEAR-REALTIME: considered every tick
        // (poolReduceCadenceMs default 0), fold accumulated novel-token
        // submissions from the pool directory into the writable WordClassTable
        // artifact, then atomically swap the running tagger onto the merged
        // table. Runs inline because PoolReducer.reduce is cheap on the common
        // path — when the pool directory is absent or empty it is a single
        // `fileExists`/enumerate and returns a no-op (idempotent contract), so an
        // idle tick costs nothing. When the novel-token pool crosses the
        // submission threshold a file lands here and the next tick merges it; the
        // reduce latency floor is the base tick (MOOTX01_BRAIN_TICK_MS).
        //
        // LIVE SWAP at the safe point: after a NON-NOOP reduce writes the merged
        // writable artifact, WordClassTableCache.reloadFromPrecedence() re-resolves
        // it (writable-first) and atomically publishes it. The running tagger
        // adopts the merged tokens on its very next wordClass call — in-session,
        // no process restart (cookbook §1.3/§2.2). The swap is the LAST step after
        // the reduce returns, with no reader holding a long-lived snapshot, so it
        // is a safe point. A noop reduce performs no swap (the table is unchanged).
        //
        // Idempotent + no-op-safe: a drained pool reduces to nothing; re-running
        // does not re-add. Errors are logged and the loop continues — a reducer
        // failure must never crash the daemon. Skipped entirely when no pool
        // paths are configured (test opt-out).
        let poolReduceElapsed = lastPoolReduceFired.map {
            now.timeIntervalSince($0) * 1000 >= Double(poolReduceCadenceMs)
        } ?? true
        var poolReduceFired = false
        var tableSwapped = false
        if poolReduceElapsed, let poolDir = poolDirectory, let tableURL = poolTableArtifactURL {
            lastPoolReduceFired = now
            poolReduceFired = true
            do {
                let result = try PoolReducer.reduce(
                    poolDirectory: poolDir,
                    tableArtifactURL: tableURL,
                    now: now)
                if !result.isNoop {
                    Logging.stderr.log("AutonomicGovernor: pool reduce merged \(result.nounsAdded) nouns + \(result.verbsAdded) verbs (consumed \(result.consumed), quarantined \(result.quarantined))")
                    // Live atomic swap at the safe point: adopt the just-merged
                    // table in-session. Only on a non-noop reduce — a noop wrote
                    // nothing new, so the running table is already current. Swap
                    // from the SAME artifact path the reducer just wrote
                    // (`tableURL`), so the running tagger learns the merged tokens
                    // (parity with the Rust governor, which swaps from its
                    // configured pool_table_artifact).
                    let newVersion = WordClassTableCache.reload(fromArtifact: tableURL)
                    tableSwapped = true
                    Logging.stderr.log("AutonomicGovernor: live word-class table swap → version \(newVersion)")
                }
            } catch {
                // A missing/unwritable table artifact is the expected state until
                // a writable table is provisioned; log once per fire, never crash.
                Logging.stderr.log("AutonomicGovernor: pool reduce skipped (\(error))")
            }
        }

        return GovernorReport(
            dreamingFired: dreamingFired,
            maintenanceFired: maintenanceFired,
            signalsTicked: signalsTicked,
            graphAnalyticsFired: graphAnalyticsElapsed,
            topologySnapshotFired: topologyElapsed,
            poolReduceFired: poolReduceFired,
            tableSwapped: tableSwapped,
            tableVersion: WordClassTableCache.version
        )
    }

    /// Run Keystones and Constellation lenses for every wing in the estate.
    ///
    /// Enumerates wings by collecting distinct `.wing` values from all
    /// non-tombstoned drawers (the established GLK pattern — GeniusLocusKit
    /// exposes no dedicated listWings API; `kit.allDrawers(in:)` is the
    /// GLK-compliant path per the DreamingReads surface). A wing with no
    /// tunnels produces empty results and completes without error (C-16).
    /// Any failure propagates to the caller, which logs and swallows it so
    /// tick() remains resilient.
    ///
    /// - Parameters:
    ///   - kit: The live GeniusLocusKit actor.
    ///   - handle: The estate to analyse.
    ///   - now: Injected instant (determinism requirement — never read Date() here).
    static func graphAnalyticsScan(
        kit: GeniusLocusKit,
        handle: EstateHandle,
        now: Date
    ) async throws {
        let drawers = try await kit.allDrawers(in: handle)
        // Collect distinct wings from non-tombstoned drawers, sorted for
        // deterministic iteration order.
        let wings = Set(drawers.compactMap { $0.tombstonedAt == nil ? $0.wing : nil }).sorted()
        for wing in wings {
            _ = try await Keystones.run(kit: kit, handle: handle, wing: wing, topK: 100)
            _ = try await ConstellationLens.run(kit: kit, handle: handle, wing: wing)
        }
    }

    // MARK: - Topology snapshot duty

    /// Compute the full topology snapshot and deliver it to the handler.
    ///
    /// This duty performs the full estate I/O that was formerly inline in HTTPServer:
    /// drawer/tunnel/KGFact reads, tombstone-instant resolution (audit-trail fallback),
    /// NeuronKit.graphTopology, and JSON encoding. The encoded bytes include a
    /// `generatedTs` field (ISO-8601 of `now`) so consumers can display staleness.
    ///
    /// The handler receives the estate UUID string, the generation instant, and the
    /// raw JSON bytes. In production the handler writes to `StatsStore` via closure
    /// injection in ResidentDaemon (keeping AriaMCP free of ObserverSink).
    ///
    /// Content-safety: node fields are UUIDs, NounType ordinals, floats, booleans,
    /// or ISO-8601 timestamps. No drawer text or rung content crosses this surface
    /// (concepts §1.6 content boundary).
    ///
    /// Determinism: `now` is injected by the tick — never reads `Date()` here.
    ///
    /// - Parameters:
    ///   - kit:     The live GeniusLocusKit actor.
    ///   - handle:  The estate to snapshot.
    ///   - now:     The generation instant (injected by the governor tick).
    ///   - handler: Called once with (estateID, generatedAt, jsonBytes).
    public static func topologySnapshotDuty(
        kit: GeniusLocusKit,
        handle: EstateHandle,
        now: Date,
        previous: TopologyInputsToken? = nil,
        handler: @Sendable (String, Date, Data) async -> Void
    ) async throws -> TopologyInputsToken {
        let locus = try await kit.estate(for: handle)

        // Raw estate reads — same as the former HTTPServer.graphSnapshot path.
        // The state axis is the authoritative dead signal; tombstonedAt is the
        // stored instant when available, with an audit-trail fallback for expunged rows.
        let allDrawerRows = try await locus.allDrawers()
        let allTunnelRows = try await locus.allTunnels()
        let kgFacts = try await locus.allKGFacts()

        // Dirty check: compute the process-local inputs token BEFORE the
        // expensive work (tombstone audit resolution, Louvain, centrality,
        // encode, write). An unchanged token means the stored snapshot is still
        // current, so the duty returns without touching the store — generatedTs
        // keeps meaning "when the content last changed". The token is built from
        // already-fetched rows only (no extra estate reads): on an idle estate
        // the duty's cost collapses to the three reads. The token is never
        // persisted — it is returned to the governor as in-memory state only.
        let token = TopologyInputsToken(drawers: allDrawerRows,
                                        tunnels: allTunnelRows,
                                        factCount: kgFacts.count)
        if let previous, token == previous {
            return token
        }

        // Tombstone instant resolution: prefer decoded tombstonedAt (round-trips cleanly
        // for most rows); fall back to the sealed audit trail's `tombstone` event for
        // rows whose stamp does not round-trip (expunge path stamps non-fractional ISO-8601
        // that the fractional-seconds reader cannot reconstruct — the audit trail is the
        // authoritative source for those rows).
        func resolveTombstoneInstant(_ d: Drawer) async throws -> Date? {
            if let at = d.tombstonedAt { return at }
            let events = try await locus.auditTrail(rowID: d.id)
            guard let event = events.last(where: { $0.verb == RowVerb.tombstone.rawValue })
            else { return nil }
            return Date(timeIntervalSince1970: Double(event.hlc.physicalTime) / 1000.0)
        }

        var drawerInputs: [TopologyDrawerInput] = []
        drawerInputs.reserveCapacity(allDrawerRows.count)
        for d in allDrawerRows {
            let dead = d.state == .tombstoned || d.tombstonedAt != nil
            drawerInputs.append(TopologyDrawerInput(
                id: d.id, udcCode: d.udcCode,
                filedAt: d.filedAt, eventTime: d.eventTime,
                tombstoned: dead,
                tombstonedAt: dead ? try await resolveTombstoneInstant(d) : nil))
        }
        let tunnelInputs = allTunnelRows.map { t in
            TopologyTunnelInput(sourceDrawerId: t.sourceDrawerId,
                                targetDrawerId: t.targetDrawerId,
                                filedAt: t.filedAt, tombstonedAt: t.tombstonedAt)
        }
        let factInputs = kgFacts.map { f in
            TopologyFactInput(subject: f.subject, sourceDrawerID: f.sourceDrawerID)
        }

        let topo = NeuronKit.graphTopology(drawers: drawerInputs,
                                           tunnels: tunnelInputs,
                                           facts: factInputs)

        let nodes = topo.nodes.map { n in
            TopologySnapshotNode(
                id: n.id,
                nounType: 0,           // NounType 0 = drawer
                communityId: n.communityId,
                centrality: n.centrality,
                anomaly: false,         // anomaly detection not yet surfaced from graphTopology
                lastActiveTs: n.lastActiveTs,
                createdTs: n.createdTs,
                tombstonedTs: n.tombstonedTs)
        }
        let edges = topo.edges.map { e in
            TopologySnapshotEdge(
                source: e.source, target: e.target,
                edgeType: e.edgeType,
                weight: e.weight,
                decayedWeight: e.weight,  // no decay at this layer; mirrors weight
                createdTs: e.createdTs,
                tombstonedTs: e.tombstonedTs)
        }
        // NeuronKit community summaries map straight through — same field names.
        let communities = topo.communities.map { c in
            TopologySnapshotCommunity(id: c.id, size: c.size, dominantUdcCode: c.dominantUdcCode)
        }

        // ISO-8601 generatedTs stamped with the injected `now` — never calls Date() here.
        let generatedTs = topologyISO8601(now)
        let payload = TopologySnapshotPayload(
            nodes: nodes,
            edges: edges,
            structurePending: false,
            communities: communities,
            generatedTs: generatedTs)

        // Deterministic encoding: JSONEncoder with sorted keys so two identical estates
        // at the same `now` produce byte-identical payloads.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(payload)

        await handler(handle.estateUUID.uuidString, now, body)
        return token
    }

    /// Record the process-local inputs token of the last computed (or
    /// confirmed-current) topology snapshot. Actor-isolated write-back from the
    /// duty Task. In-memory governor state only — never persisted.
    private func recordTopologyInputsToken(_ token: TopologyInputsToken) {
        lastTopologyInputsToken = token
    }

    /// Format a Date as ISO-8601 UTC with millisecond precision.
    ///
    /// Matches the format used throughout the wire protocol
    /// ("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"). Injected `now` is the only clock
    /// source — never calls Date() here.
    private static func topologyISO8601(_ date: Date) -> String {
        // Static formatter is thread-safe (DateFormatter is thread-unsafe, but
        // this is initialised once via a lazy static let and never mutated after init).
        topologyDateFormatter.string(from: date)
    }

    private static let topologyDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")!
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return f
    }()
}

// MARK: - Topology inputs dirty token

/// A cheap, order-independent CHANGE-DETECTION token over the topology duty's
/// INPUTS, which skips recomputation when the estate is unchanged between
/// cadences. This is a PROCESS-LOCAL DIRTY TOKEN, not a stable fingerprint:
/// it is in-memory governor state, NEVER persisted to storage, and NEVER
/// compared across processes. It is built from Swift `hashValue` (process-
/// local, salted per process launch), so two processes will produce different
/// tokens for identical estates — that is correct and sufficient, because the
/// only comparison ever made is `previous == current` WITHIN a single running
/// governor. Do NOT treat this as cross-process evidence and do NOT swap in a
/// substrate Fingerprint256/SimHash primitive: that would over-engineer an
/// in-memory change-detector whose entire lifetime is one process.
///
/// Built from already-fetched rows only — counts, maximum ingest/event
/// instants, dead counts, and an order-independent inputs digest (overflow
/// sum of per-drawer id+udcCode hashes, catching re-anchoring that changes
/// neither counts nor timestamps).
///
/// Sensitivity (what forces a recompute): drawer/tunnel/fact adds and
/// removes, tombstones, new ingests (max filedAt), re-activity (max
/// eventTime → lastActiveTs recency), and udcCode re-anchoring. A content
/// edit that changes none of these does not alter the topology payload and
/// correctly skips.
public struct TopologyInputsToken: Sendable, Equatable {
    let drawerCount: Int
    let tunnelCount: Int
    let factCount: Int
    let deadDrawerCount: Int
    let deadTunnelCount: Int
    let maxFiledAt: Date?
    let maxEventTime: Date?
    /// Order-independent overflow sum of per-drawer id+udcCode `hashValue`s.
    /// Process-local (Swift hashing is salted per launch) — only ever compared
    /// to another token from the SAME process. Never persisted.
    let inputsDigest: Int

    init(drawers: [Drawer], tunnels: [Tunnel], factCount: Int) {
        self.drawerCount = drawers.count
        self.tunnelCount = tunnels.count
        self.factCount = factCount
        self.deadDrawerCount = drawers.lazy
            .filter { $0.state == .tombstoned || $0.tombstonedAt != nil }.count
        self.deadTunnelCount = tunnels.lazy.filter { $0.tombstonedAt != nil }.count
        let drawerMaxFiled = drawers.lazy.map(\.filedAt).max()
        let tunnelMaxFiled = tunnels.lazy.map(\.filedAt).max()
        self.maxFiledAt = [drawerMaxFiled, tunnelMaxFiled].compactMap { $0 }.max()
        self.maxEventTime = drawers.lazy.map(\.eventTime).max()
        // Overflow-add keeps the digest order-independent across query order.
        var digest = 0
        for d in drawers { digest = digest &+ d.id.hashValue &+ d.udcCode.hashValue }
        self.inputsDigest = digest
    }
}

// MARK: - Topology snapshot wire-shape types

/// Graph node in the governor's topology snapshot payload.
///
/// Fields match moot-mgr's `GraphNodePayload` so bytes can be decoded at the
/// proxy without field translation. `tombstonedTs` is ALWAYS present on the wire
/// (explicit JSON null for live entities per the VIZ_V2 dissolution contract).
struct TopologySnapshotNode: Codable, Sendable {
    let id: String
    let nounType: Int
    let communityId: Int
    let centrality: Double
    let anomaly: Bool
    let lastActiveTs: String?
    let createdTs: String?
    let tombstonedTs: String?

    private enum CodingKeys: String, CodingKey {
        case id, nounType, communityId, centrality, anomaly
        case lastActiveTs, createdTs, tombstonedTs
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(nounType, forKey: .nounType)
        try c.encode(communityId, forKey: .communityId)
        try c.encode(centrality, forKey: .centrality)
        try c.encode(anomaly, forKey: .anomaly)
        try c.encodeIfPresent(lastActiveTs, forKey: .lastActiveTs)
        try c.encodeIfPresent(createdTs, forKey: .createdTs)
        // tombstonedTs is ALWAYS present: explicit null for live entities (VIZ_V2 contract).
        try c.encode(tombstonedTs, forKey: .tombstonedTs)
    }
}

/// Graph edge in the governor's topology snapshot payload.
struct TopologySnapshotEdge: Codable, Sendable {
    let source: String
    let target: String
    let edgeType: String
    let weight: Double
    let decayedWeight: Double
    let createdTs: String?
    let tombstonedTs: String?

    private enum CodingKeys: String, CodingKey {
        case source, target, edgeType, weight, decayedWeight
        case createdTs, tombstonedTs
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(source, forKey: .source)
        try c.encode(target, forKey: .target)
        try c.encode(edgeType, forKey: .edgeType)
        try c.encode(weight, forKey: .weight)
        try c.encode(decayedWeight, forKey: .decayedWeight)
        try c.encodeIfPresent(createdTs, forKey: .createdTs)
        // tombstonedTs is ALWAYS present: explicit null for live entities (VIZ_V2 contract).
        try c.encode(tombstonedTs, forKey: .tombstonedTs)
    }
}

/// Community summary in the governor's topology snapshot payload.
struct TopologySnapshotCommunity: Codable, Sendable {
    let id: Int
    let size: Int
    let dominantUdcCode: String
}

/// Full payload produced by the governor's topology-snapshot duty.
///
/// `generatedTs` is new in this format (was not in the former HTTPServer inline response);
/// it is the ISO-8601 instant when the governor computed the snapshot. Consumers can
/// use it to display staleness. `structurePending: false` indicates real data.
/// The pending response (no snapshot yet) is served directly as static bytes without
/// decoding — callers should NOT expect `generatedTs` in a pending response.
struct TopologySnapshotPayload: Codable, Sendable {
    let nodes: [TopologySnapshotNode]
    let edges: [TopologySnapshotEdge]
    let structurePending: Bool
    let communities: [TopologySnapshotCommunity]
    /// ISO-8601 UTC timestamp of when the governor produced this snapshot.
    let generatedTs: String
}
