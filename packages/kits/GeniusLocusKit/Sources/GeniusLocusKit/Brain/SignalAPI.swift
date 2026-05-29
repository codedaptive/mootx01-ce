import Foundation
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE_v1.0_2026-05-28.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
import SubstrateTypes
import LocusKit

/// The standing-signals API on `GeniusLocusKit`.
///
/// Architecture spec §7.8.5 declares this as four methods on the
/// `Estate` handle. In the MOOTx01 composition shape the surface
/// lives on the `GeniusLocusKit` actor with an `EstateHandle`
/// argument, matching the per-handle dispatch model GLK-02
/// established for the unified verb surface. One scheduler is
/// minted per estate the first time `registerStandingSignal` is
/// invoked against that handle; subsequent calls reuse it.
///
/// Concurrency: the GLK actor isolates the scheduler registry and
/// the dispatcher closure both. The scheduler is itself an actor,
/// so the path is GLK actor → StandingSignalScheduler actor →
/// QueueKit (which has its own internal serialization via
/// `.serializable` transactions on its storage backend). The
/// single-serial-lane decision holds across the full pipeline.
public extension GeniusLocusKit {

    /// Register a custom signal against the addressed estate's
    /// scheduler. Architecture spec §7.8.5:
    /// `registerStandingSignal(spec) -> SignalID`. The first call
    /// against a given `handle` lazily mints the scheduler for that
    /// estate.
    func registerStandingSignal(
        _ spec: SignalSpec,
        in handle: EstateHandle,
        now: Date
    ) async throws -> SignalID {
        _ = try estate(for: handle)
        let scheduler = try await ensureScheduler(for: handle)
        return await scheduler.register(spec, registeredAt: now)
    }

    /// Snapshot of every registered signal's status for the estate
    /// addressed by `handle`. Architecture spec §7.8.5:
    /// `signalStatus() -> [SignalReport]`. Raises
    /// `schedulerNotStarted` if no scheduler exists yet.
    func signalStatus(in handle: EstateHandle) async throws -> [SignalReport] {
        _ = try estate(for: handle)
        guard let scheduler = schedulers[handle] else {
            throw GeniusLocusKitError.schedulerNotStarted(estateUUID: handle.estateUUID)
        }
        return await scheduler.report()
    }

    /// Receive a callback whenever the named signal emits.
    /// Architecture spec §7.8.5:
    /// `signalSubscribe(SignalID, callback)`.
    @discardableResult
    func signalSubscribe(
        _ signalID: SignalID,
        in handle: EstateHandle,
        callback: @escaping @Sendable (SignalEmission) -> Void
    ) async throws -> SubscriptionID {
        _ = try estate(for: handle)
        guard let scheduler = schedulers[handle] else {
            throw GeniusLocusKitError.schedulerNotStarted(estateUUID: handle.estateUUID)
        }
        return try await scheduler.subscribe(signalID, callback: callback)
    }

    /// Detach a previously-installed subscription. Architecture spec
    /// §7.8.5: `signalUnsubscribe(SignalID)`. Idempotent — calling
    /// against a stale SubscriptionID or an unknown SignalID is a
    /// no-op.
    func signalUnsubscribe(
        _ signalID: SignalID,
        subscription: SubscriptionID,
        in handle: EstateHandle
    ) async throws {
        _ = try estate(for: handle)
        guard let scheduler = schedulers[handle] else {
            // No scheduler means no subscriptions ever existed; the
            // idempotent contract surfaces this as success rather
            // than an error.
            return
        }
        await scheduler.unsubscribe(signalID, subscription)
    }

    /// Advance every estate's scheduler at `now`. Each scheduler is
    /// independent; per the single-serial-lane decision they do not
    /// share a lane across estates. The caller iterates one tick per
    /// estate.
    func signalTick(in handle: EstateHandle, now: Date) async throws {
        _ = try estate(for: handle)
        guard let scheduler = schedulers[handle] else {
            throw GeniusLocusKitError.schedulerNotStarted(estateUUID: handle.estateUUID)
        }
        try await scheduler.tick(now: now)
    }

    /// Fire an event-trigger signal explicitly. The `event` and
    /// `condition` trigger families do not have a wall-clock next-due;
    /// the application calls `signalRequestFire` to notify the
    /// scheduler that the event has occurred.
    func signalRequestFire(
        _ signalID: SignalID,
        in handle: EstateHandle,
        now: Date
    ) async throws {
        _ = try estate(for: handle)
        guard let scheduler = schedulers[handle] else {
            throw GeniusLocusKitError.schedulerNotStarted(estateUUID: handle.estateUUID)
        }
        try await scheduler.requestFire(signalID, now: now)
    }

    /// Number of estates with an active scheduler. Diagnostic
    /// accessor; production callers use `signalStatus(in:)` for
    /// per-estate detail.
    var openSchedulerCount: Int { schedulers.count }

    // MARK: - Internals

    /// Lazy-mint the per-estate scheduler. The GLK actor isolates
    /// access to `schedulers`, so first-call concurrency is safe.
    internal func ensureScheduler(for handle: EstateHandle) async throws -> StandingSignalScheduler {
        if let existing = schedulers[handle] { return existing }
        // The node id used by the scheduler's HLC generator is
        // derived from the estate handle's UUID so two estates on
        // one device produce distinguishable HLC streams. Stable per
        // handle so a scheduler reopened from the same handle would
        // resume the same HLC family (relevant when persistence
        // lands in a later sub-mission).
        let nodeID = Int32(
            bitPattern: UInt32(truncatingIfNeeded:
                handle.estateUUID.uuid.0 &<< 24 |
                handle.estateUUID.uuid.1 &<< 16 |
                handle.estateUUID.uuid.2 &<< 8 |
                handle.estateUUID.uuid.3))
        let hlc = HLCGenerator(nodeID: nodeID)
        let dispatcher = SchedulerDispatcher(kit: self)
        let scheduler = try await StandingSignalScheduler(
            handle: handle,
            hlcGenerator: hlc,
            dispatcher: dispatcher)
        schedulers[handle] = scheduler
        return scheduler
    }
}

/// Default dispatcher: routes `propose` and `associate` emissions
/// through the GLK actor's existing verb surface (GLK-02). The
/// scheduler holds a typed reference so the dispatch is a single
/// call-site whose contract is checked at compile time.
///
/// Today the GLK-02 surface raises `VerbError.notSupportedByEstate`
/// for both verbs because LocusKit's Brain-layer verb bodies have
/// not yet shipped. The scheduler recognises that error and records
/// the outcome as `routedButVerbStubbed`. When the Brain layer's
/// verb bodies land in a later sub-mission this dispatcher's
/// behaviour does not need to change.
internal struct SchedulerDispatcher: SignalDispatcher {
    /// Captured weakly through an unowned reference to avoid a
    /// retain cycle with the scheduler. The GLK actor outlives its
    /// schedulers (it owns them in `schedulers`), so the unowned
    /// access is safe.
    let kit: GeniusLocusKit

    func dispatchPropose(handle: EstateHandle, frame: ProposeFrame) async throws {
        try await kit.propose(handle, frame)
    }

    func dispatchAssociate(handle: EstateHandle, frame: AssociateFrame) async throws {
        try await kit.associate(handle, frame)
    }
}
