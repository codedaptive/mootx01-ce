// CloudKitSyncEngine.swift
//
// CloudKit-backed sync. A generalized SyncCoordinator
// pattern: setup zone, push pending local changes,
// pull remote changes since last token,
// apply via PersistenceKit. No CloudKit subscription is created.
//
// ConvergenceKit-CloudKit listens to StorageObserver for outbound changes
// and queues them for push. On pull, decodes CKRecords into
// DecodedRecord values via CKRecordMapping.decode, then applies through
// rowStore directly (which fires StorageObserver naturally, waking
// downstream watchers).
//
// Engine internals are split across Engine/:
//   CloudKitStateActor.swift      — actor shell, state, enable/disable
//   PushCycle.swift               — outbound push path
//   PullCycle.swift               — inbound pull + deletion path
//   ApplyInbound.swift            — conflict-policy apply switch
//   SyncMetaStore.swift           — _ck_sync_meta side table
//   EngineClock.swift             — nowMillis() helper
//   AdaptivePollScheduler.swift   — adaptive tiered poll loop + nudge seam (B-11)

import Foundation
import ConvergenceKit
import PersistenceKit

public final class CloudKitSyncEngine: SyncEngine, Sendable {
    let stateActor: CloudKitStateActor
    let containerIdentifier: String?

    // Holds the active AdaptivePollScheduler behind an actor seam so
    // CloudKitSyncEngine remains Sendable. Nil when polling is not enabled.
    // Both `start` (from enable) and `stop` (from disable/nudge) hop through
    // this actor so mutations are always serialised.
    private let _schedulerBox = SchedulerBox()

    // Whether enable() should auto-start a default AdaptivePollScheduler.
    //
    // WHY default false: existing tests (TwoEstateFixture and all prior P1-P4
    // test targets) call enable() and then drive push/pull manually. Auto-starting
    // a poll loop in those tests would race against manual pull() calls and break
    // deterministic assertion windows. Set true only in host-app targets that hold
    // a running RunLoop and want background inbound polling.
    private let _autoStartPolling: Bool

    /// Construct with a container identifier. Pass nil to use
    /// `CKContainer.default()` at enable() time (requires the host
    /// app to declare an iCloud entitlement). The container is
    /// not resolved until enable() so the engine can be
    /// instantiated in unit tests without iCloud configuration.
    ///
    /// - Parameters:
    ///   - containerIdentifier: iCloud container to use. Nil → default container.
    ///   - enablePolling: When true, `enable()` starts an `AdaptivePollScheduler`
    ///     that automatically polls for inbound changes using the adaptive tier
    ///     cadence defined in `PollTierPolicy`. Default false so existing tests
    ///     that drive push/pull manually are not affected.
    public init(containerIdentifier: String? = nil, enablePolling: Bool = false) {
        self.containerIdentifier = containerIdentifier
        self.stateActor = CloudKitStateActor(containerIdentifier: containerIdentifier)
        self._autoStartPolling = enablePolling
    }

    public func enable(manifest: SyncManifest, storage: any Storage) async throws {
        try await stateActor.enable(manifest: manifest, storage: storage)
        if _autoStartPolling {
            // Create a default scheduler whose pull closure calls this engine's
            // pull() method. The closure captures a weak reference so there is no
            // retain cycle between the engine and the scheduler.
            let scheduler = AdaptivePollScheduler(pull: { [weak self] in
                guard let self else { return .empty }
                return try await self.pull()
            })
            await _schedulerBox.set(scheduler)
            await scheduler.start()
        }
    }

    public func disable() async throws {
        // Stop the scheduler before disabling the engine so any in-flight pull
        // completes before the engine tears down its storage references.
        let scheduler = await _schedulerBox.get()
        await scheduler?.stop()
        await _schedulerBox.set(nil)
        await stateActor.disable()
    }

    public func push() async throws -> SyncReceipt {
        try await stateActor.push()
    }

    public func pull() async throws -> SyncReceipt {
        try await stateActor.pull()
    }

    public func subscribe() -> AsyncStream<SyncEvent> {
        let (stream, continuation) = AsyncStream<SyncEvent>.makeStream(bufferingPolicy: .bufferingOldest(256))
        let task = Task { await stateActor.attachSubscriber(continuation) }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    public var state: SyncState {
        get async { await stateActor.currentState }
    }

    // MARK: - Accelerator surface (B-11)

    /// Nudge: fire an immediate inbound pull and reset the poll tier to fast.
    ///
    /// This is THE SEAM for external accelerators (SPEC B-11, INTERFACE § 2):
    ///   - P3-M3 — `OutboxDrainDebouncer` calls nudge() after draining a push
    ///             batch so the remote peer's response arrives sooner than idle
    ///             cadence would deliver it.
    ///   - Future — APNs wakeup handler calls nudge() rather than pull() directly;
    ///             the scheduler manages tier accounting.
    ///   - Future — Local IPC from a companion process signals nudge() to wake
    ///             the poll loop.
    ///
    /// If a scheduler is active, nudge() delegates to it (interrupt sleep + pull).
    /// If no scheduler is running (enablePolling: false), nudge() fires a one-shot
    /// pull directly — callers can use it as a manual accelerator even without
    /// background polling active.
    public func nudge() async {
        if let scheduler = await _schedulerBox.get() {
            await scheduler.nudge()
        } else {
            // No scheduler running: fire a direct pull as a one-shot accelerator.
            _ = try? await pull()
        }
    }
}

// MARK: - SchedulerBox (private)

/// Actor that safely holds a nullable AdaptivePollScheduler.
///
/// CloudKitSyncEngine is `Sendable` and `final class`, so all stored properties
/// must be `Sendable` or protected by a synchronization mechanism. Using an actor
/// here satisfies both: actors are unconditionally `Sendable`, and property
/// mutations are serialised through actor isolation.
private actor SchedulerBox {
    private var scheduler: AdaptivePollScheduler?
    func set(_ s: AdaptivePollScheduler?) { scheduler = s }
    func get() -> AdaptivePollScheduler?  { scheduler }
}
