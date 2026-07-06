import Foundation
import GeniusLocusKit
import LatticeLib
import LocusKit
import OSLog
import SubstrateTypes

/// Fleet-standard OSLog channel for the AutonomicGovernor.
///
/// Uses subsystem "com.mootx01.kit" and category "NeuronKit" per CLAUDE.md.
/// Private to this file — callers use the module-level `logger` symbol defined here.
private let logger = Logger(subsystem: "com.mootx01.kit", category: "NeuronKit")

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
/// values fall back to 0. A free function (not a method) so it can be a default
/// argument of `AutonomicGovernor.init` without the Swift `self`/`Self`
/// restriction in default-argument expressions.
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
/// LAYERING: The AutonomicGovernor lives in NeuronKit because it coordinates
/// NeuronKit's own daemons (DreamingDaemon, MaintenanceDaemon) and presses
/// GeniusLocusKit buttons (signalTick, registerGraphCache, registerPreferenceStore).
/// The MCP / AriaMcpKit host starts the governor and injects host-coupled
/// concerns (topology snapshot handler, topology monitoring gate, graph-analytics
/// handler) as closures so NeuronKit never imports AriaMcpKit or CognitionKit.
/// The injection seam is the same pattern as the existing `topologyHandler`.
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
///
/// AUTO-REINDEX: the DreamingDaemon is constructed with an
/// `EstateCorpusGrowthProbe`, so distributional embedding bases are retrained
/// automatically when corpus growth crosses the threshold. The governor logs
/// "auto-reindex: on" at startup to confirm the probe is live.
public actor AutonomicGovernor {

    private let kit: GeniusLocusKit
    private let handle: EstateHandle
    private let dreaming: DreamingDaemon
    private let maintenance: MaintenanceDaemon
    /// Base loop granularity in milliseconds — the sampling resolution for the
    /// daemons' own (longer) cadences, not a cadence itself.
    private let baseTickMs: Int
    /// How often graph analytics fire (host-injected handler). Default 10 minutes;
    /// pass 0 in tests to fire on every tick. When `graphAnalyticsHandler` is nil,
    /// the cadence gate still advances (so the interval resets correctly), but the
    /// duty is a no-op.
    private let graphAnalyticsIntervalMs: Int
    /// Wall-clock instant of the most recent graphAnalytics dispatch.
    /// Nil on first tick so the scan fires immediately at startup.
    private var lastGraphAnalyticsFired: Date? = nil
    /// Host-injected graph analytics handler. Called by the governor on its cadence
    /// with the live kit, handle, and deterministic `now`. The handler is the
    /// host's (AriaMcpKit's) CognitionKit-based Keystones + Constellation scan.
    /// Nil = no graph analytics duty (acceptable for estates that don't need it).
    ///
    /// Injected here so NeuronKit never imports CognitionKit (which would invert
    /// the layering: CognitionKit depends on NeuronKit, not the reverse).
    private let graphAnalyticsHandler: (@Sendable (GeniusLocusKit, EstateHandle, Date) async throws -> Void)?
    /// How often the graph-centrality producer (graphCentralityScan) fires —
    /// computes per-drawer eigenvalue centrality and registers the GraphCache
    /// the recall `graph` column reads. Default 10 minutes (same cadence as
    /// graph analytics — both ride the estate structure graph); pass 0 in
    /// tests to fire on every tick.
    private let graphCentralityIntervalMs: Int
    /// Wall-clock instant of the most recent graphCentralityScan dispatch.
    /// Nil on first tick so the producer fires immediately at startup (the
    /// `graph` column is live from the first cadence, not after a delay).
    private var lastGraphCentralityFired: Date? = nil
    /// How often the preference producer (preferenceScan) fires — fits per-drawer
    /// Bradley-Terry preference strengths from the recall-trace reward history and
    /// registers the PreferenceStore the recall `preference` column reads. Default
    /// 10 minutes (same cadence as the graph-centrality producer — both ride
    /// estate-wide reads); pass 0 in tests to fire on every tick.
    private let preferenceIntervalMs: Int
    /// Wall-clock instant of the most recent preferenceScan dispatch. Nil on first
    /// tick so the producer fires immediately at startup (the `preference` column
    /// is live from the first cadence, not after a delay).
    private var lastPreferenceFired: Date? = nil
    /// Cadence for the topology snapshot duty in milliseconds.
    /// Configurable via MOOTX01_TOPOLOGY_CADENCE_SECONDS (default 300 s).
    /// Pass 0 in tests to fire on every tick.
    private let topologyCadenceMs: Int
    /// Wall-clock instant of the most recent topologySnapshotDuty dispatch.
    /// Nil on first tick so the duty fires immediately at startup.
    private var lastTopologySnapshotFired: Date? = nil
    /// Called by topologySnapshotDuty when a snapshot is ready.
    /// Nil when no stats store is configured (no consumer to write to).
    /// Injected by the host (AriaResident) so NeuronKit never imports ObserverSink
    /// directly. This matches the design principle that keeps AriaMCP free of
    /// telemetry imports.
    /// The fourth argument is the stable topology-inputs `fingerprint`, persisted
    /// beside the snapshot (F5) so the next process start can skip the recompute
    /// when the estate is unchanged.
    private let topologyHandler: (@Sendable (String, Date, Data, String) async -> Void)?
    /// Loads the persisted topology fingerprint for this estate on start, so the
    /// first post-restart duty can compare against it and skip the `graphTopology`
    /// recompute when nothing changed. Injected by the host (reads ObserverSink);
    /// nil = no persistence (the first duty always recomputes). Symmetric to
    /// `topologyHandler`.
    private let topologyFingerprintLoader: (@Sendable () async -> String?)?
    /// Whether the persisted fingerprint has been loaded into
    /// `lastTopologyFingerprint` yet (one-shot, on the first topology duty).
    private var topologyFingerprintLoaded = false
    /// Monitoring gate for the topology duty. Checked at each due cadence
    /// BEFORE any estate read or compute: false skips the entire duty for
    /// that interval ("off is free"). Nil = always run. Injected by the host
    /// from the stats store's live monitoring flag, so a moot-mgr on/off flip
    /// takes effect at the next cadence without restart.
    private let topologyGate: (@Sendable () async -> Bool)?
    /// Stable `fingerprint` of the most recent COMPUTED topology snapshot inputs.
    /// When the next due cadence yields the same fingerprint, the duty skips the
    /// Louvain/centrality math, the encode, and the store write — the stored
    /// snapshot is still current (generatedTs therefore means "when the content
    /// last changed", not "when the duty last ran"). Seeded on the first duty from
    /// the persisted fingerprint (F5, via `topologyFingerprintLoader`) so the skip
    /// holds across process restarts, then updated after every recompute.
    private var lastTopologyFingerprint: String? = nil
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
    /// Minimum spacing between GC sweep passes, in milliseconds.
    /// Default 30 000 (30 s = 2× the DrainLease TTL of 15 s). The sweep is a
    /// cheap probe-only read; 30 s gives enough margin that a stale lease
    /// (TTL-expired after 15 s without heartbeat) is detected in at most one
    /// TTL interval after the drainer dies. Pass 0 in tests to fire every tick.
    private let gcSweepIntervalMs: Int
    /// Wall-clock instant of the most recent GC sweep. Nil on first tick so the
    /// sweep fires immediately at startup (catches any orphaned cur rows from a
    /// previous crashed session before the first drain fires).
    private var lastGCSweepFired: Date? = nil

    public init(
        kit: GeniusLocusKit,
        handle: EstateHandle,
        baseTickMs: Int = 5000,
        graphAnalyticsIntervalMs: Int = 600_000,
        graphCentralityIntervalMs: Int = 600_000,
        preferenceIntervalMs: Int = 600_000,
        topologyCadenceMs: Int = autonomicGovernorDefaultTopologyCadenceMs(),
        poolReduceCadenceMs: Int = autonomicGovernorDefaultPoolReduceCadenceMs(),
        topologyHandler: (@Sendable (String, Date, Data, String) async -> Void)? = nil,
        topologyFingerprintLoader: (@Sendable () async -> String?)? = nil,
        topologyGate: (@Sendable () async -> Bool)? = nil,
        // Graph analytics handler: the host (AriaMcpKit) injects the
        // CognitionKit-based Keystones + Constellation scan. Nil = no graph
        // analytics duty. This injection seam keeps NeuronKit free of CognitionKit
        // (CognitionKit depends on NeuronKit, so importing it here would invert
        // the layer stack).
        graphAnalyticsHandler: (@Sendable (GeniusLocusKit, EstateHandle, Date) async throws -> Void)? = nil,
        // Pool paths default to the LatticeLib-resolved convention. Tests pass
        // explicit temp paths (or nil to skip the reduce path entirely).
        poolDirectory: URL? = NovelPoolSubmitter.poolDirectory(),
        poolTableArtifactURL: URL? = NovelPoolSubmitter.tableArtifactURL(),
        // GC sweep cadence: 30 s (2× DrainLease TTL = 15 s). Pass 0 in tests to
        // fire every tick and verify the sweep runs without waiting 30 s.
        gcSweepIntervalMs: Int = 30_000,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.kit = kit
        self.handle = handle
        self.baseTickMs = baseTickMs
        self.graphAnalyticsIntervalMs = graphAnalyticsIntervalMs
        self.graphAnalyticsHandler = graphAnalyticsHandler
        self.graphCentralityIntervalMs = graphCentralityIntervalMs
        self.preferenceIntervalMs = preferenceIntervalMs
        self.topologyCadenceMs = topologyCadenceMs
        self.poolReduceCadenceMs = poolReduceCadenceMs
        self.poolDirectory = poolDirectory
        self.poolTableArtifactURL = poolTableArtifactURL
        self.topologyHandler = topologyHandler
        self.topologyFingerprintLoader = topologyFingerprintLoader
        self.topologyGate = topologyGate
        self.gcSweepIntervalMs = gcSweepIntervalMs
        self.clock = clock
        // Construct the daemons against the live estate via NeuronKit's seam
        // adapters. Production persists policy, bandit, and daemon cycle state to
        // the estate manifest (F6 / ADR-020) so a restart continues from the prior
        // run's state instead of re-discovering and re-proposing — the store reads
        // and writes THROUGH the public substrate interface (kit.estate(for:) →
        // Estate.meta/setMeta), keeping NeuronKit's reach B-1-compliant.
        //
        // AUTO-REINDEX: wire an EstateCorpusGrowthProbe so distributional embedding
        // bases are retrained automatically when corpus growth crosses the threshold.
        // The probe is optional in DreamingDaemon — a nil probe silently skips the
        // auto-reindex gate each cycle (no error, no log spam). The production governor
        // always passes a live probe; tests may omit it by constructing DreamingDaemon
        // directly with growthProbe: nil.
        self.dreaming = DreamingDaemon(
            reader: EstateDreamingReader(handle: handle, kit: kit),
            sink: EstateDreamingSink(handle: handle, kit: kit),
            rewardSource: RecallTraceRewardSource(),
            policyStore: EstateManifestDreamingPolicyStore(handle: handle, kit: kit),
            growthProbe: EstateCorpusGrowthProbe(handle: handle, kit: kit)
        )
        self.maintenance = MaintenanceDaemon(
            reader: EstateMaintenanceReader(handle: handle, kit: kit),
            sink: EstateMaintenanceSink(handle: handle, kit: kit),
            policyStore: EstateManifestMaintenancePolicyStore(handle: handle, kit: kit)
        )
    }


    /// What fired on one tick — returned for tests; ignored by `run()`.
    public struct GovernorReport: Sendable {
        public let dreamingFired: Bool
        public let maintenanceFired: Bool
        public let signalsTicked: Bool
        /// True when this tick dispatched a graph-analytics scan Task.
        public let graphAnalyticsFired: Bool
        /// True when this tick dispatched a graph-centrality producer Task —
        /// the duty that computes per-drawer eigenvalue centrality and
        /// registers the GraphCache the recall `graph` column reads.
        public let graphCentralityFired: Bool
        /// True when this tick dispatched a preference producer Task — the duty
        /// that fits per-drawer Bradley-Terry preference strengths from the
        /// recall-trace reward history and registers the PreferenceStore the
        /// recall `preference` column reads.
        public let preferenceFired: Bool
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
        /// True when this tick dispatched a GC sweep Task via
        /// `kit.sweepStaleInFlightJobs`. The sweep probes stream drain leases
        /// and reclaims orphaned cur→new rows for stale streams (Mission #54).
        /// False when the cadence has not yet elapsed (30 s default).
        public let gcSweepFired: Bool
    }

    /// Run the governor loop until the task is cancelled (process shutdown).
    public func run() async {
        // Load persisted cadence policy once (best-effort; an empty store leaves
        // the spec defaults in place).
        do { try await dreaming.loadPersistedPolicy() }
        catch { logger.error("AutonomicGovernor: dreaming policy load failed: \(error)") }
        do { try await maintenance.loadPersistedPolicy() }
        catch { logger.error("AutonomicGovernor: maintenance policy load failed: \(error)") }

        // Confirm auto-reindex is wired (the EstateCorpusGrowthProbe is always
        // passed at construction in the production governor).
        let tickMs = baseTickMs
        logger.info("AutonomicGovernor started (base tick \(tickMs)ms, auto-reindex: on)")
        while !Task.isCancelled {
            _ = await tick(now: clock())
            // Sleep OUTSIDE the per-pump catches. Task.sleep throws
            // CancellationError on shutdown — break the loop; never log-and-continue
            // (that would spin at 100% CPU). Any sleep error ends the loop.
            do { try await Task.sleep(nanoseconds: UInt64(baseTickMs) * 1_000_000) }
            catch { break }
        }
        logger.info("AutonomicGovernor stopped")
    }

    /// One governor iteration with an injected `now`. Each daemon self-gates; each
    /// call is isolated so one daemon's failure cannot stop the others or the
    /// loop. Exposed for deterministic tests.
    @discardableResult
    public func tick(now: Date) async -> GovernorReport {
        var dreamingFired = false
        var maintenanceFired = false
        var signalsTicked = false

        // REM dispatch table (ADR-021 Phase 6, T11): iterate the shared table so
        // all four cadences are driven uniformly by the governor. The table is
        // defined in RemCycleTable.swift and consumed identically by the
        // dream_runner, so the cycle roster is declared exactly once.
        //
        // ALPHA gate: timer-due AND queue non-empty (ADR-021 Phase 4 §12.2).
        //   nil  = queue not yet mounted — skip (safe direction).
        //   0    = queue mounted but empty — skip (idle ticks cost nothing).
        //   n>0  = items waiting; proceed to pump + drain.
        // THETA/BETA/OMEGA: purely cadence-gated (each carries its own last-run
        //   timestamp in DreamingDaemonState, persisted via F6/ADR-020).
        // The Swift reader seams are lazy (reads happen inside runCycle), so the
        // timer-due fast-out for ALPHA keeps the tick symmetric with the Rust
        // governor (whose EstateDreamingReader snapshots eagerly and MUST be gated
        // before it is built).
        for entry in remCycleTable {
            switch entry.kind {
            case .alpha:
                // Read pending count once; it drives both the timer path and the event path.
                // nil = queue not yet mounted (skip); 0 = empty (skip); n>0 = proceed.
                let pending = await kit.dreamingQueuePendingCount(for: handle)
                // Timer gate: drives the standard ALPHA cycle for .timer and .hybrid modes.
                if await dreaming.timerDue(now: now) {
                    if let count = pending, count > 0 {
                        do { dreamingFired = try await dreaming.pump(now: now) != nil }
                        catch { logger.error("AutonomicGovernor: \(entry.name) pump error: \(error)") }
                    }
                    // else: nil (not mounted) or 0 (empty) — no-op this tick.
                }
                // Event gate: drives pumpOnEvent for .event and .hybrid trigger modes on
                // every tick, independent of the timer cadence. pumpOnEvent is self-gating —
                // it is a no-op when the daemon's trigger mode is .timer, so timer-only
                // estates pay nothing beyond the nil-check here. This wires near-realtime
                // dreaming for event-driven estates so cycles fire as observations arrive
                // rather than waiting for the next cadence tick. Mirrors Rust
                // autonomic_governor::run_loop pump_on_event path. (NK-2/NK-6 planned hardening)
                if let count = pending, count > 0 {
                    do {
                        if try await dreaming.pumpOnEvent(observationCount: count, now: now) != nil {
                            dreamingFired = true
                        }
                    }
                    catch { logger.error("AutonomicGovernor: \(entry.name) pumpOnEvent error: \(error)") }
                }
            case .theta:
                if await dreaming.thetaDue(now: now) {
                    do { _ = try await dreaming.runThetaCycle(now: now) }
                    catch { logger.error("AutonomicGovernor: \(entry.name) cycle error: \(error)") }
                }
            case .beta:
                if await dreaming.betaDue(now: now) {
                    do { _ = try await dreaming.runBetaCycle(now: now) }
                    catch { logger.error("AutonomicGovernor: \(entry.name) cycle error: \(error)") }
                }
            case .omega:
                if await dreaming.omegaDue(now: now) {
                    do { _ = try await dreaming.runOmegaCycle(now: now) }
                    catch { logger.error("AutonomicGovernor: \(entry.name) cycle error: \(error)") }
                }
            }
        }

        if await maintenance.due(now: now) {
            do { maintenanceFired = try await maintenance.pump(now: now) != nil }
            catch { logger.error("AutonomicGovernor: maintenance pump error: \(error)") }
        }

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
                logger.error("AutonomicGovernor: signalTick error: \(error)")
            }
        } catch {
            logger.error("AutonomicGovernor: signalTick error: \(error)")
        }

        // Graph analytics: fire on the configured interval (default 10 min).
        // The host injects the handler (graphAnalyticsHandler) which performs
        // CognitionKit's Keystones + Constellation scan per wing. When the
        // handler is nil no scan runs but the cadence gate still advances so
        // the interval resets correctly. First tick fires immediately
        // (lastGraphAnalyticsFired is nil). The scan runs in an unstructured
        // Task (handler is nonisolated) so tick() returns without stalling.
        let graphAnalyticsElapsed = lastGraphAnalyticsFired.map {
            now.timeIntervalSince($0) * 1000 >= Double(graphAnalyticsIntervalMs)
        } ?? true

        if graphAnalyticsElapsed {
            lastGraphAnalyticsFired = now
            if let handler = graphAnalyticsHandler {
                Task { [kit, handle, now, handler] in
                    do { try await handler(kit, handle, now) }
                    catch { logger.error("AutonomicGovernor: graphAnalytics error: \(error)") }
                }
            }
        }

        // Graph-centrality producer: compute per-drawer eigenvalue centrality
        // and register the GraphCache the recall `graph` column reads. Same
        // cadence shape as graph analytics (default 10 min, 0 = every tick).
        // First tick fires immediately (lastGraphCentralityFired is nil) so the
        // `graph` column is live from startup rather than dark for one cadence.
        // The scan runs in an unstructured Task (graphCentralityScan is a
        // nonisolated static func — the actor executor is released at its first
        // await, so tick() returns without stalling). Errors are logged and
        // never propagated to tick().
        let graphCentralityElapsed = lastGraphCentralityFired.map {
            now.timeIntervalSince($0) * 1000 >= Double(graphCentralityIntervalMs)
        } ?? true

        if graphCentralityElapsed {
            lastGraphCentralityFired = now
            Task { [kit, handle, now] in
                do { try await AutonomicGovernor.graphCentralityScan(kit: kit, handle: handle, now: now) }
                catch { logger.error("AutonomicGovernor: graphCentralityScan error: \(error)") }
            }
        }

        // Preference producer: fit per-drawer Bradley-Terry preference strengths
        // from the recall-trace reward history and register the PreferenceStore
        // the recall `preference` column reads. Same cadence shape as the
        // graph-centrality producer (default 10 min, 0 = every tick). First tick
        // fires immediately (lastPreferenceFired is nil) so the `preference`
        // column is live from startup rather than dark for one cadence. The scan
        // runs in an unstructured Task (preferenceScan is a nonisolated static
        // func — the actor executor is released at its first await, so tick()
        // returns without stalling). Errors are logged and never propagated to
        // tick().
        let preferenceElapsed = lastPreferenceFired.map {
            now.timeIntervalSince($0) * 1000 >= Double(preferenceIntervalMs)
        } ?? true

        if preferenceElapsed {
            lastPreferenceFired = now
            Task { [kit, handle, now] in
                do { try await AutonomicGovernor.preferenceScan(kit: kit, handle: handle, now: now) }
                catch { logger.error("AutonomicGovernor: preferenceScan error: \(error)") }
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
                Task { [kit, handle, now, handler, topologyGate] in
                    if let gate = topologyGate, !(await gate()) { return }
                    // Seed the comparison fingerprint, loading the persisted one once
                    // (F5) so the first post-restart duty skips the recompute when the
                    // estate is unchanged.
                    let previousFingerprint = await self.topologyFingerprintForDuty()

                    // Bug 2 fix (ADR025-AUDITLOG-GOVERNOR): audit-count watermark check
                    // BEFORE the full-estate load inside topologySnapshotDuty.
                    //
                    // `topologySnapshotDuty` loads allDrawers + allTunnels + allKGFacts
                    // before checking its fingerprint, so the full O(N) data load was paid
                    // even on the "nothing changed, skip" path. Adding the audit-count
                    // check here — one O(1) COUNT(*) SQL call — gates the entire duty call
                    // when the estate is verifiably unchanged. The skip requires both:
                    //   1. A valid previous fingerprint (we have run at least once)
                    //   2. No new audit events since the last topology-count watermark
                    // If either condition is absent, proceed to the full duty.
                    if previousFingerprint != nil {
                        do {
                            let estate = try await kit.estate(for: handle)
                            let savedCountRaw = try await estate.meta(
                                key: NeuronKitManifestKey.topologyCount)
                            let savedCount = savedCountRaw.flatMap { Int($0) }
                            let changed = try await kit.hasAuditGrown(for: handle, since: savedCount)
                            if !changed {
                                // Estate provably unchanged — skip the full duty.
                                return
                            }
                        } catch {
                            // Watermark probe failed (transient I/O); fall through to the
                            // full duty as a safe fallback. The duty's own fingerprint check
                            // provides the final skip guard.
                            logger.debug(
                                "AutonomicGovernor: topology watermark probe error (falling through): \(error)")
                        }
                    }

                    do {
                        let token = try await AutonomicGovernor.topologySnapshotDuty(
                            kit: kit, handle: handle, now: now,
                            previousFingerprint: previousFingerprint,
                            handler: handler)
                        self.recordTopologyInputsToken(token)
                        // Save the topology audit-count watermark after a successful duty
                        // run so the next cadence tick can short-circuit at this level.
                        do {
                            let estate = try await kit.estate(for: handle)
                            let currentCount = try await kit.auditEventCount(for: handle)
                            try await estate.setMeta(
                                key: NeuronKitManifestKey.topologyCount,
                                value: String(currentCount))
                        } catch {
                            // Non-fatal: next tick will re-run the full duty and re-save.
                            logger.debug(
                                "AutonomicGovernor: topology count watermark save error: \(error)")
                        }
                    } catch {
                        logger.error("AutonomicGovernor: topologySnapshotDuty error: \(error)")
                    }
                }
            }
        }

        // GC sweep: reclaim orphaned in-flight (cur) queue rows for streams
        // whose drainer has died without the daemon restarting (mid-run worker
        // death case, Mission #54). Fires at a 30 s cadence (2× DrainLease TTL);
        // first tick fires immediately (lastGCSweepFired nil) to catch jobs left
        // by a previous crashed session before the first drain attempts them.
        // Runs in an unstructured Task so tick() returns without stalling.
        let gcSweepElapsed = lastGCSweepFired.map {
            now.timeIntervalSince($0) * 1000 >= Double(gcSweepIntervalMs)
        } ?? true
        if gcSweepElapsed {
            lastGCSweepFired = now
            Task { [kit, handle, now] in
                await kit.sweepStaleInFlightJobs(for: handle, now: now)
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
            // Bounded near-realtime drain: reduce at most poolReduceFileCap of the
            // OLDEST submissions this tick. A larger backlog drains over successive
            // ticks. The reduce runs synchronously on the tick, so an unbounded
            // pass would stall it — but SKIPPING the reduce when over cap (the prior
            // "planned hardening" behaviour) deadlocked: over cap, the very reduce
            // that shrinks the pool never ran, so the pool grew without bound. The
            // batch cap keeps each tick bounded AND always makes progress. Parity:
            // mirrors autonomic_governor.rs.
            lastPoolReduceFired = now
            poolReduceFired = true
            do {
                let result = try PoolReducer.reduce(
                    poolDirectory: poolDir,
                    tableArtifactURL: tableURL,
                    now: now,
                    maxFiles: AutonomicGovernor.poolReduceFileCap)
                if !result.isNoop {
                    logger.info("AutonomicGovernor: pool reduce merged \(result.nounsAdded) nouns + \(result.verbsAdded) verbs (consumed \(result.consumed), quarantined \(result.quarantined))")
                    // Live atomic swap at the safe point: adopt the just-merged
                    // table in-session. Only on a non-noop reduce — a noop wrote
                    // nothing new, so the running table is already current. Swap
                    // from the SAME artifact path the reducer just wrote
                    // (`tableURL`), so the running tagger learns the merged tokens.
                    let newVersion = WordClassTableCache.reload(fromArtifact: tableURL)
                    tableSwapped = true
                    logger.info("AutonomicGovernor: live word-class table swap → version \(newVersion)")
                }
            } catch {
                // A missing/unwritable table artifact is the expected state until
                // a writable table is provisioned; log once per fire, never crash.
                logger.error("AutonomicGovernor: pool reduce skipped (\(error))")
            }
        }

        return GovernorReport(
            dreamingFired: dreamingFired,
            maintenanceFired: maintenanceFired,
            signalsTicked: signalsTicked,
            graphAnalyticsFired: graphAnalyticsElapsed,
            graphCentralityFired: graphCentralityElapsed,
            preferenceFired: preferenceElapsed,
            topologySnapshotFired: topologyElapsed,
            poolReduceFired: poolReduceFired,
            tableSwapped: tableSwapped,
            tableVersion: WordClassTableCache.version,
            gcSweepFired: gcSweepElapsed
        )
    }

    /// Run Keystones and Constellation lenses for every wing in the estate.
    ///
    /// NOTE: This static func is no longer called directly by the governor's
    /// tick(). The graphAnalyticsHandler closure (injected by the host) performs
    /// this duty using CognitionKit's Keystones and ConstellationLens, keeping
    /// CognitionKit out of NeuronKit (CognitionKit depends on NeuronKit, not the
    /// reverse). This func is retained here as documentation of the intended
    /// call shape so the host-side injection matches exactly.
    ///
    /// - Parameters:
    ///   - kit: The live GeniusLocusKit actor.
    ///   - handle: The estate to analyse.
    ///   - now: Injected instant (determinism requirement — never read Date() here).
    static func graphAnalyticsScanShape(
        kit: GeniusLocusKit,
        handle: EstateHandle,
        now: Date
    ) async throws {
        // Called as: graphAnalyticsHandler = { kit, handle, now in
        //     let drawers = try await kit.allDrawers(in: handle)
        //     let wings = Set(drawers.compactMap { $0.tombstonedAt == nil ? $0.wing : nil }).sorted()
        //     for wing in wings {
        //         _ = try await Keystones.run(kit: kit, handle: handle, wing: wing, topK: 100)
        //         _ = try await ConstellationLens.run(kit: kit, handle: handle, wing: wing)
        //     }
        // }
        // See AriaResident.runResidentDaemon for the wired implementation.
    }

    // MARK: - Planned-hardening caps

    /// Maximum number of live drawers scored per graph-centrality scan.
    ///
    /// Planned hardening: prevents per-tick O(n²) edge build on large estates.
    /// Drawers beyond the cap score 0.0 per spec C-16 ("a drawer with no
    /// structural edges has no centrality"). The cap is applied to the live
    /// drawer set sorted ascending by id, so the capped subset is stable and
    /// deterministic across ports. Parity: matches `GRAPH_CENTRALITY_SCAN_NODE_CAP`
    /// in autonomic_governor.rs.
    private static let graphCentralityScanNodeCap = 10_000

    /// Maximum number of pool submissions the PoolReducer duty drains per tick.
    ///
    /// The reduce runs synchronously on the tick, so it processes at most this
    /// many of the OLDEST submissions per run; a larger backlog drains over
    /// successive ticks (bounded near-realtime drain). This replaced an earlier
    /// "defer the reduce when the pool exceeds this cap" behaviour, which
    /// deadlocked: over cap, the very reduce that would shrink the pool was
    /// skipped, so the pool grew without bound. Parity: matches
    /// `POOL_REDUCE_FILE_CAP` in autonomic_governor.rs.
    private static let poolReduceFileCap = 500

    // MARK: - Graph-centrality producer duty

    /// Compute per-drawer eigenvalue centrality for the whole estate and
    /// register it as a `GraphCache`, taking the `unionBest` / `matrixAware`
    /// recall `graph` score column from dark to live.
    ///
    /// Math ownership (I-17): this duty owns NO math. Eigenvalue centrality is
    /// the conformance-gated SubstrateML primitive surfaced by
    /// `NeuronKit.keystones`; the duty only shapes the graph and caches the
    /// scores. It is a faithful cadence wrapper of a direct `keystones` call
    /// on the same graph — the cross-port conformance gate proves exactly that.
    ///
    /// Adjacency = drawers + tunnels + kg_facts, unit weight (the keystones
    /// model). Built by `GraphCentralityAdjacency.build`, whose Rust twin
    /// (`graph_centrality_adjacency`) produces the identical edge multiset, so
    /// the two ports compute identical centralities for the same estate.
    ///
    /// Determinism: `now` is injected by the tick — never reads `Date()` here.
    /// The duty's only side effect is the cache registration (idempotent
    /// re-registration replaces the prior snapshot). An empty estate (no live
    /// drawers, or no edges) registers an empty cache — every `graphScore` is
    /// 0.0, identical to "no cache registered", which is correct (C-16).
    ///
    /// Reads go through the public GeniusLocusKit verb surface (`allDrawers`,
    /// `allTunnels`, `recallKGFacts`) — no LocusKit reach-around (B-1).
    ///
    /// - Parameters:
    ///   - kit:    The live GeniusLocusKit actor.
    ///   - handle: The estate to score.
    ///   - now:    Injected instant (determinism requirement).
    public static func graphCentralityScan(
        kit: GeniusLocusKit,
        handle: EstateHandle,
        now: Date
    ) async throws {
        // Bug 3 fix (ADR025-AUDITLOG-GOVERNOR): skip full-estate load + O(N²)
        // eigenvalue recompute when no new audit events exist since the last scan.
        //
        // Strategy: persist computed scores + an audit-event-count watermark to
        // estate.meta. On each cadence, check the watermark first (one O(1) SQL
        // COUNT(*) call) before touching allDrawers/allTunnels/allKGFacts. When
        // the estate is unchanged, re-register the cached scores and return — the
        // recall `graph` column continues serving correct values with zero load.
        let estate = try await kit.estate(for: handle)
        let savedCountRaw = try await estate.meta(key: NeuronKitManifestKey.centralityCount)
        let savedCount: Int? = savedCountRaw.flatMap { Int($0) }

        // Cheap watermark probe: no new events → estate unchanged → skip recompute.
        let changed = try await kit.hasAuditGrown(for: handle, since: savedCount)
        if !changed,
           let scoresJSON = try await estate.meta(key: NeuronKitManifestKey.centralityScores),
           let scoresData = scoresJSON.data(using: .utf8),
           let cachedScores = try? JSONDecoder().decode([String: Float].self, from: scoresData),
           !cachedScores.isEmpty {
            // Estate unchanged and valid cache present — re-register and return.
            // This avoids allDrawers + allTunnels + allKGFacts + eigenvalue compute.
            await kit.registerGraphCache(GraphCentralityCache(scores: cachedScores), for: handle)
            return
        }

        // Estate changed (or first run, or cache absent): full load + recompute.
        let allDrawers = try await kit.allDrawers(in: handle)
        let tunnels = try await kit.allTunnels(in: handle)
        let facts = try await kit.recallKGFacts(handle)

        // Planned hardening: cap the scan to graphCentralityScanNodeCap live
        // drawers. Drawers beyond the cap score 0.0 — correct per spec C-16
        // ("a drawer with no structural edges has no centrality"). The cap is
        // applied to live (non-tombstoned) drawers sorted ascending by id,
        // matching GraphCentralityAdjacency.build's own deterministic ordering,
        // so both ports produce the same capped subset from the same estate state.
        // Parity: mirrors GRAPH_CENTRALITY_SCAN_NODE_CAP in autonomic_governor.rs.
        let liveDrawers = allDrawers.filter { $0.tombstonedAt == nil }
            .sorted { $0.id < $1.id }
        let drawers: [Drawer]
        if liveDrawers.count > graphCentralityScanNodeCap {
            logger.warning(
                "AutonomicGovernor.graphCentralityScan: \(liveDrawers.count) live drawers exceeds cap \(graphCentralityScanNodeCap); scoring first \(graphCentralityScanNodeCap) (planned hardening)")
            drawers = Array(liveDrawers.prefix(graphCentralityScanNodeCap))
        } else {
            drawers = liveDrawers
        }

        let graph = GraphCentralityAdjacency.build(
            drawers: drawers, tunnels: tunnels, facts: facts)

        // keystones over ALL nodes (topK = node count) gives every live
        // drawer's centrality, not just the top ranks. Empty node set ⇒
        // empty result ⇒ empty cache (C-16).
        // Estate and now are threaded from the caller so telemetry carries
        // the correct estate tag and timestamp (never read Date() here).
        let ranked = NeuronKit.keystones(
            nodeIDs: graph.nodeIDs,
            edges: graph.edges,
            topK: graph.nodeIDs.count,
            estate: handle.estateUUID.uuidString,
            now: now)

        var scores: [String: Float] = Dictionary(minimumCapacity: ranked.count)
        for keystone in ranked {
            // NeuronKit.Keystone.centrality is Double (the SubstrateML scalar);
            // the GraphCache surface is Float. The narrowing is the documented
            // float boundary the cross-port conformance gate compares at.
            scores[keystone.id] = Float(keystone.centrality)
        }

        await kit.registerGraphCache(GraphCentralityCache(scores: scores), for: handle)

        // Persist computed scores + current audit-event-count watermark so the
        // next cadence invocation can skip this full load when unchanged.
        let currentCount = try await kit.auditEventCount(for: handle)
        if let scoresData = try? JSONEncoder().encode(scores),
           let scoresJSON = String(data: scoresData, encoding: .utf8) {
            try await estate.setMeta(key: NeuronKitManifestKey.centralityScores, value: scoresJSON)
        }
        try await estate.setMeta(
            key: NeuronKitManifestKey.centralityCount,
            value: String(currentCount))
    }

    // MARK: - Preference producer duty

    /// Fit per-drawer Bradley-Terry preference strengths from the estate's
    /// recall-trace reward history and register them as a `PreferenceStore`,
    /// taking the `unionBest` / `matrixAware` recall `preference` score column
    /// from dark to live.
    ///
    /// Math ownership (I-17): this duty owns NO fitting math. The Bradley-Terry
    /// preference fit is the conformance-gated SubstrateML primitive surfaced by
    /// `NeuronKit.learnedPreference` (the `Bias` lens, anchor reduction); the duty
    /// only shapes the outcomes and caches the strengths.
    ///
    /// Window: all retained recall traces up to `now` (`since = .distantPast`).
    /// Retention is bounded by the maintenance prune cycle. Deterministic — a
    /// pure function of the recorded rows and `now`; never reads `Date()` here.
    ///
    /// - Parameters:
    ///   - kit:    The live GeniusLocusKit actor.
    ///   - handle: The estate to score.
    ///   - now:    Injected instant (determinism requirement).
    /// Maximum recall traces consumed per preference cadence tick. Bounded to prevent
    /// full-history loads on large estates. The most-recent `preferenceTracesWindowLimit`
    /// traces represent the strongest signal for Bradley-Terry fitting; older traces
    /// have decayed relevance and are excluded on each cadence tick.
    ///
    /// A full refit over all traces is triggered only on an explicit `reindex` or
    /// `dream` call — not on the governor cadence. The maintenance prune cycle bounds
    /// total trace retention independently.
    ///
    /// Parity: mirrors PREFERENCE_TRACES_WINDOW_LIMIT in autonomic_governor.rs.
    internal static let preferenceTracesWindowLimit = 1_000

    public static func preferenceScan(
        kit: GeniusLocusKit,
        handle: EstateHandle,
        now: Date
    ) async throws {
        // Bug 4 fix (ADR025-AUDITLOG-GOVERNOR): skip full-history trace load +
        // full Bradley-Terry refit when no new audit events exist since the last scan.
        //
        // Strategy (mirrors graphCentralityScan): persist fitted scores + audit-event-
        // count watermark to estate.meta. On each cadence, check the watermark first
        // (one O(1) COUNT(*) call). When unchanged, re-register the cached preference
        // scores and return immediately — the `preference` recall column keeps serving
        // correct values with zero trace load.
        //
        // When changed: load traces bounded to the most-recent `preferenceTracesWindowLimit`
        // entries (suffix of the result from `since: .distantPast`) instead of the
        // unbounded `.distantPast` window. Bradley-Terry fitting over this bounded window
        // keeps the preference model current without O(all-history) RAM growth. The
        // fitted strengths are persisted after each compute so process restarts are free.
        let estate = try await kit.estate(for: handle)
        let savedCountRaw = try await estate.meta(key: NeuronKitManifestKey.preferenceCount)
        let savedCount: Int? = savedCountRaw.flatMap { Int($0) }

        // Cheap watermark probe.
        let changed = try await kit.hasAuditGrown(for: handle, since: savedCount)
        if !changed,
           let scoresJSON = try await estate.meta(key: NeuronKitManifestKey.preferenceScores),
           let scoresData = scoresJSON.data(using: .utf8),
           let cachedScores = try? JSONDecoder().decode([String: Float].self, from: scoresData),
           !cachedScores.isEmpty {
            await kit.registerPreferenceStore(PreferenceCache(scores: cachedScores), for: handle)
            return
        }

        // Changed (or first run): load bounded recent-trace window + refit.
        // `since: .distantPast` loads ALL traces; suffix to `preferenceTracesWindowLimit`
        // bounds the window. The refit uses only these recent traces — sufficient for
        // up-to-date preference estimation; older history is excluded per the documented
        // window contract above.
        let allTraces = try await kit.recentRecallTraces(
            in: handle, since: .distantPast, now: now)
        let traces = Array(allTraces.suffix(AutonomicGovernor.preferenceTracesWindowLimit))

        let records = PreferenceOutcomes.build(traces: traces)

        let strengths = try NeuronKit.learnedPreference(
            records: records.map {
                (label: $0.label, endorsements: $0.endorsements, dismissals: $0.dismissals)
            })

        var scores: [String: Float] = Dictionary(minimumCapacity: strengths.count)
        for strength in strengths {
            scores[strength.label] = Float(strength.strength)
        }

        await kit.registerPreferenceStore(PreferenceCache(scores: scores), for: handle)

        // Persist scores + watermark for the next cadence invocation.
        let currentCount = try await kit.auditEventCount(for: handle)
        if let scoresData = try? JSONEncoder().encode(scores),
           let scoresJSON = String(data: scoresData, encoding: .utf8) {
            try await estate.setMeta(key: NeuronKitManifestKey.preferenceScores, value: scoresJSON)
        }
        try await estate.setMeta(
            key: NeuronKitManifestKey.preferenceCount,
            value: String(currentCount))
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
    /// injection in AriaResident (keeping AriaMCP and NeuronKit free of ObserverSink).
    ///
    /// Determinism: `now` is injected by the tick — never reads `Date()` here.
    ///
    /// - Parameters:
    ///   - kit:     The live GeniusLocusKit actor.
    ///   - handle:  The estate to snapshot.
    ///   - now:     The generation instant (injected by the governor tick).
    ///   - handler: Called once with (estateID, generatedAt, jsonBytes, fingerprint).
    public static func topologySnapshotDuty(
        kit: GeniusLocusKit,
        handle: EstateHandle,
        now: Date,
        previousFingerprint: String? = nil,
        handler: @Sendable (String, Date, Data, String) async -> Void
    ) async throws -> TopologyInputsToken {
        let locus = try await kit.estate(for: handle)

        let allDrawerRows = try await locus.allDrawers()
        let allTunnelRows = try await locus.allTunnels()
        let kgFacts = try await locus.allKGFacts()

        // Dirty check: compute the stable inputs fingerprint BEFORE the expensive
        // work. An unchanged fingerprint means the stored snapshot is still current,
        // so the duty returns without touching the store. The fingerprint is stable
        // across process launches, so this skip holds across a restart too (F5).
        let token = TopologyInputsToken(drawers: allDrawerRows,
                                        tunnels: allTunnelRows,
                                        factCount: kgFacts.count)
        if let previousFingerprint, token.fingerprint == previousFingerprint {
            return token
        }

        // Tombstone instant resolution: prefer decoded tombstonedAt; fall back to
        // the sealed audit trail's `tombstone` event for rows whose stamp does not
        // round-trip (expunge path stamps non-fractional ISO-8601 the fractional-
        // seconds reader cannot reconstruct — the audit trail is authoritative there).
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

        // Thread estate UUID and the caller-supplied `now` so VizGraph analytics
        // rows carry the correct estate tag and timestamp. The governor already
        // receives both via its duty parameters; pass them rather than letting
        // SubstrateML silently emit with empty estate and epoch-0 ts.
        let topo = NeuronKit.graphTopology(drawers: drawerInputs,
                                           tunnels: tunnelInputs,
                                           facts: factInputs,
                                           estate: handle.estateUUID.uuidString,
                                           now: now)

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

        await handler(handle.estateUUID.uuidString, now, body, token.fingerprint)
        return token
    }

    /// Record the stable inputs fingerprint of the last computed (or
    /// confirmed-current) topology snapshot. Actor-isolated write-back from the
    /// duty Task. The host persists the same fingerprint beside the snapshot via
    /// the handler, so this in-memory value and the on-disk one stay in lockstep.
    private func recordTopologyInputsToken(_ token: TopologyInputsToken) {
        lastTopologyFingerprint = token.fingerprint
        topologyFingerprintLoaded = true
    }

    /// Return the fingerprint to compare this duty against, loading the persisted
    /// one once (F5) so the first post-restart duty skips the `graphTopology`
    /// recompute when the estate is unchanged. After the first load (or the first
    /// recompute) this returns the in-memory value with no further I/O.
    private func topologyFingerprintForDuty() async -> String? {
        if !topologyFingerprintLoaded {
            topologyFingerprintLoaded = true
            if lastTopologyFingerprint == nil, let loader = topologyFingerprintLoader {
                lastTopologyFingerprint = await loader()
            }
        }
        return lastTopologyFingerprint
    }

    // MARK: - Test-facing accessors

    /// The dreaming daemon's current trigger mode. Exposed for deterministic tests
    /// that need to observe the bandit-selected mode after a cycle and conditionally
    /// assert on dreaming behavior. (NK-2 planned hardening: pumpOnEvent is now
    /// wired — tests that assumed only pump() fires need to account for the mode.)
    public func dreamingTriggerMode() async -> DreamingTriggerMode {
        await dreaming.currentTriggerMode()
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
/// INPUTS, used to skip recomputation when the estate is unchanged between
/// cadences. Its `fingerprint` is a STABLE, process-independent string: it is
/// persisted beside the topology snapshot and loaded on the next process start,
/// so an unchanged estate skips the expensive `graphTopology` recompute even
/// across a restart (F5). The digest is FNV-1a over canonical bytes — NOT Swift
/// `hashValue`, which is salted per launch and would not compare across processes.
///
/// Built from already-fetched rows only — counts, maximum ingest/event instants,
/// dead counts, and an order-independent inputs digest (overflow sum of per-drawer
/// id+udcCode FNV hashes, catching re-anchoring that changes neither counts nor
/// timestamps).
public struct TopologyInputsToken: Sendable, Equatable {
    public let drawerCount: Int
    public let tunnelCount: Int
    public let factCount: Int
    public let deadDrawerCount: Int
    public let deadTunnelCount: Int
    public let maxFiledAt: Date?
    public let maxEventTime: Date?
    /// Order-independent overflow sum of per-drawer FNV-1a(id + udcCode) hashes.
    /// STABLE across process launches (FNV, not Swift `hashValue`) so the
    /// `fingerprint` persists and compares across restarts.
    public let inputsDigest: UInt64

    // Package-internal initialiser — tests in the same module use this; cross-module
    // consumers receive tokens from the governor itself, never construct them directly.
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
        // Overflow-add of per-drawer STABLE hashes keeps the digest
        // order-independent across query order AND identical across process runs.
        var digest: UInt64 = 0
        for d in drawers {
            digest = digest &+ Self.fnv1a("\(d.id)\u{1}\(d.udcCode)")
        }
        self.inputsDigest = digest
    }

    /// FNV-1a 64-bit over a string's UTF-8 — a small, stable, process-independent
    /// hash (no external dependency, no Swift `hashValue` salt).
    static func fnv1a(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in s.utf8 {
            h ^= UInt64(byte)
            h = h &* 0x0000_0100_0000_01b3
        }
        return h
    }

    /// Stable, persistable fingerprint of these inputs. Two tokens are equal iff
    /// their fingerprints are equal, so the duty's dirty-check compares
    /// fingerprints — and the same comparison holds across process restarts when
    /// one side is loaded from disk.
    public var fingerprint: String {
        let filed = maxFiledAt.map { String($0.timeIntervalSince1970) } ?? "-"
        let event = maxEventTime.map { String($0.timeIntervalSince1970) } ?? "-"
        return "\(drawerCount):\(tunnelCount):\(factCount):\(deadDrawerCount):\(deadTunnelCount):\(filed):\(event):\(inputsDigest)"
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
/// `generatedTs` is the ISO-8601 instant when the governor computed the snapshot.
/// Consumers can use it to display staleness. `structurePending: false` indicates
/// real data. The pending response (no snapshot yet) is served directly as static
/// bytes without decoding — callers should NOT expect `generatedTs` in a pending
/// response.
struct TopologySnapshotPayload: Codable, Sendable {
    let nodes: [TopologySnapshotNode]
    let edges: [TopologySnapshotEdge]
    let structurePending: Bool
    let communities: [TopologySnapshotCommunity]
    /// ISO-8601 UTC timestamp of when the governor produced this snapshot.
    let generatedTs: String
}
