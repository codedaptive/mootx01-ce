import Foundation
import GeniusLocusKit
import NeuronKit

/// The resident Brain pump (see ADR-LOOPBACKHTTP-001 §17).
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
/// RESILIENCE: a pump failure logs to stderr and the loop continues — the Brain
/// pump must never crash the daemon. Task cancellation (process shutdown) breaks
/// the loop cleanly; it is never treated as a pump error (which would busy-spin).
///
/// POLICY (P2): cadence policy comes from in-memory stores seeded with spec
/// defaults (dreaming 30 s, maintenance 5 min). P3 swaps these for the manifest
/// store so an operator's policy survives restarts; the seam is unchanged.
public actor BrainPump {

    private let kit: GeniusLocusKit
    private let handle: EstateHandle
    private let dreaming: DreamingDaemon
    private let maintenance: MaintenanceDaemon
    /// Base loop granularity in milliseconds — the sampling resolution for the
    /// daemons' own (longer) cadences, not a cadence itself.
    private let baseTickMs: Int
    /// Injected for deterministic tests; production reads the wall clock.
    private let clock: @Sendable () -> Date

    public init(
        kit: GeniusLocusKit,
        handle: EstateHandle,
        baseTickMs: Int = 5000,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.kit = kit
        self.handle = handle
        self.baseTickMs = baseTickMs
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
    public struct TickReport: Sendable {
        public let dreamingFired: Bool
        public let maintenanceFired: Bool
        public let signalsTicked: Bool
    }

    /// Run the pump loop until the task is cancelled (process shutdown).
    public func run() async {
        // Load persisted cadence policy once (best-effort; an empty store leaves
        // the spec defaults in place).
        do { try await dreaming.loadPersistedPolicy() }
        catch { Logging.stderr.log("BrainPump: dreaming policy load failed: \(error)") }
        do { try await maintenance.loadPersistedPolicy() }
        catch { Logging.stderr.log("BrainPump: maintenance policy load failed: \(error)") }

        Logging.stderr.log("BrainPump started (base tick \(baseTickMs)ms)")
        while !Task.isCancelled {
            _ = await tick(now: clock())
            // Sleep OUTSIDE the per-pump catches. Task.sleep throws
            // CancellationError on shutdown — break the loop; never log-and-continue
            // (that would spin at 100% CPU). Any sleep error ends the loop.
            do { try await Task.sleep(nanoseconds: UInt64(baseTickMs) * 1_000_000) }
            catch { break }
        }
        Logging.stderr.log("BrainPump stopped")
    }

    /// One pump iteration with an injected `now`. Each daemon self-gates; each
    /// call is isolated so one daemon's failure cannot stop the others or the
    /// loop. Exposed for deterministic tests.
    @discardableResult
    public func tick(now: Date) async -> TickReport {
        var dreamingFired = false
        var maintenanceFired = false
        var signalsTicked = false

        do { dreamingFired = try await dreaming.pump(now: now) != nil }
        catch { Logging.stderr.log("BrainPump: dreaming pump error: \(error)") }

        do { maintenanceFired = try await maintenance.pump(now: now) != nil }
        catch { Logging.stderr.log("BrainPump: maintenance pump error: \(error)") }

        // Standing signals: tick only fires once a signal has been registered for
        // the estate (the scheduler is minted lazily by registerStandingSignal).
        // Until then signalTick throws schedulerNotStarted — a benign skip here,
        // not an error: signal registration is a later phase, and treating it as
        // an error would spam stderr every tick AND mask real failures.
        do {
            try await kit.signalTick(in: handle, now: now)
            signalsTicked = true
        } catch let error as GeniusLocusKitError {
            if case .schedulerNotStarted = error {
                // benign — no standing signals registered yet, nothing to tick.
            } else {
                Logging.stderr.log("BrainPump: signalTick error: \(error)")
            }
        } catch {
            Logging.stderr.log("BrainPump: signalTick error: \(error)")
        }

        return TickReport(
            dreamingFired: dreamingFired,
            maintenanceFired: maintenanceFired,
            signalsTicked: signalsTicked
        )
    }
}
