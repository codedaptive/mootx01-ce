import Foundation
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
import SubstrateTypes
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import PersistenceKitSQLite
import QueueKit

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
    ///
    /// selects the queue backend based on the
    /// estate's storage configuration:
    ///   - SQLite estate → the shared encrypted `queue.sqlite` sibling,
    ///     derived via `EstateConfiguration.queueSibling("queue.sqlite")`.
    ///     Signal jobs survive process restarts; the scheduler picks up
    ///     pending signals on re-open without data loss.
    ///   - InMemory estate → transient in-memory backend (estate is
    ///     ephemeral, so durability is irrelevant).
    ///
    /// A `DrainLease` keyed `"signals"` is held for SQLite estates so
    /// a future multi-process deployment can safely share the queue.sqlite
    /// without two processes racing to claim signal jobs. InMemory estates
    /// are always single-process — no lease needed.
    internal func ensureScheduler(for handle: EstateHandle) async throws -> StandingSignalScheduler {
        if let existing = schedulers[handle] { return existing }
        // The node id used by the scheduler's HLC generator is
        // derived from the estate handle's UUID so two estates on
        // one device produce distinguishable HLC streams. Stable per
        // handle so a scheduler opened from the same handle resumes
        // the same HLC family across restarts.
        // Assemble the first four UUID bytes big-endian into a UInt32, then
        // bit-cast to Int32. Each byte is widened to UInt32 BEFORE shifting —
        // shifting a UInt8 by 24/16/8 would mask the shift amount to the operand
        // width (24 & 7 == 0) and collapse to a single-byte value. The Rust
        // mirror does the byte-identical `u32::from_be_bytes([b0,b1,b2,b3]) as i32`.
        let b = handle.estateUUID.uuid
        let nodeID = Int32(bitPattern:
            (UInt32(b.0) << 24) | (UInt32(b.1) << 16) | (UInt32(b.2) << 8) | UInt32(b.3))
        let hlc = HLCGenerator(nodeID: nodeID)
        let dispatcher = SchedulerDispatcher(kit: self)

        // T5: select backend based on the estate's durability.
        let queue: QueueKit
        var signalDrainLease: DrainLease? = nil
        let cfg = storages[handle]?.configuration

        if case .sqlite = cfg?.backend {
            // Persistent estate: share the estate's `queue.sqlite` sibling
            // (same encrypted SQLite the encode stream uses). Signal jobs
            // become crash-durable — pending emissions survive a restart.
            // `queueSibling` is deterministic: same estate UUID → same path
            // and encryption key, so every process that re-opens this estate
            // mounts the same queue.sqlite.
            let siblingCfg = try cfg!.queueSibling(filename: "queue.sqlite")
            let qs = try SQLiteStorage(configuration: siblingCfg)
            try await PersistenceKitBackend.openSchema(on: qs)
            let backend = PersistenceKitBackend(storage: qs)
            queue = QueueKit(backend: backend)
            queue.estateTag = "signals"

            // Stream-keyed drain lease (T2): prevents two processes from
            // racing to claim signal jobs on the same queue.sqlite.
            // Instance token = PID + handle's ObjectIdentifier so PID-reuse
            // after a crash does not impersonate the previous holder.
            let estateDir = siblingCfg.backend.sqliteURL!.deletingLastPathComponent()
            signalDrainLease = DrainLease(
                directory: estateDir,
                stream: "signals",
                instanceToken: "\(ObjectIdentifier(self))"
            )
        } else {
            // InMemory (ephemeral) estate: transient queue, no crash recovery,
            // no cross-process lease. Use the estate's own UUID as the store ID
            // so diagnostics correlate cleanly; avoids UUID() nondeterminism.
            let storeID = cfg?.estateID ?? handle.estateUUID
            let qs = InMemoryStorage(configuration: EstateConfiguration(
                estateID: storeID,
                backend: .inMemory))
            try await PersistenceKitBackend.openSchema(on: qs)
            let backend = PersistenceKitBackend(storage: qs)
            queue = QueueKit(backend: backend)
            queue.estateTag = "signals_inmemory"
            // InMemory estates are always single-process — no lease needed.
        }

        let scheduler = StandingSignalScheduler(
            handle: handle,
            hlcGenerator: hlc,
            dispatcher: dispatcher,
            queue: queue,
            drainLease: signalDrainLease)
        schedulers[handle] = scheduler
        return scheduler
    }
}

/// Default dispatcher: routes `propose` and `associate` emissions
/// through the GLK actor's existing verb surface (GLK-02). The
/// scheduler holds a typed reference so the dispatch is a single
/// call-site whose contract is checked at compile time.
///
/// The `propose` and `associate` verb bodies are fully live in
/// GLK-02. The scheduler (`StandingSignalScheduler`) still recognises
/// `VerbError.notSupportedByEstate` and records it as
/// `routedButVerbStubbed` for verbs that remain partially stubbed
/// (e.g., `mutate` state-axis kinds). This dispatcher requires no
/// changes as further verb bodies are completed.
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

// MARK: - BackendConfiguration helper (SignalAPI-local)

private extension BackendConfiguration {
    /// Extract the SQLite file URL from a `.sqlite` backend.
    /// Returns nil for `.inMemory` and `.postgres` backends.
    /// Mirrors the same helper in CorpusIngestQueue.swift; private
    /// here to keep the extension scoped to this file.
    var sqliteURL: URL? {
        if case let .sqlite(url, _) = self { return url }
        return nil
    }
}
