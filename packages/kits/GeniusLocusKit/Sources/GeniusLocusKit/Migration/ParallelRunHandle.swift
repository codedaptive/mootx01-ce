// ParallelRunHandle.swift
//
// Controls a dual-estate parallel capture run during a migration
// (GLK-MIG-02). The handle routes new captures to one or both estates
// according to the chosen `ParallelCaptureMode` and can be stopped to
// prevent further writes.

import Foundation
import LocusKit
import OSLog

/// Controls a dual-estate parallel capture run.
///
/// An `actor` because it holds mutable stopped-state (`stopped`) that
/// must be consistent across concurrent capture calls arriving from
/// different tasks.
///
/// **Note on `stopped: Bool`:** The `stopped` stored property is NOT
/// a schema-entity bitmap violation. `ParallelRunHandle` is a transient
/// control object that is never persisted to SQLite; it holds no entity
/// schema. The no-Bool-on-entities rule applies exclusively to persisted
/// nouns (Drawer, Tunnel, KGFact, DiaryEntry, etc.). Boolean state on a
/// transient control actor is correct Swift.
///
/// **Note on `unowned kit`:** The handle holds an `unowned` reference
/// to the `GeniusLocusKit` actor that created it to avoid a retain cycle:
/// `GeniusLocusKit` is also an actor, and a mutual strong reference
/// between two actors could prevent deallocation. Because `runParallel`
/// is called on the kit and the handle is not stored in the kit's
/// registry, the caller owns both the kit and the handle, and the
/// lifetime relationship is owner → kit → no handle ref, owner → handle
/// → kit (unowned). The handle will never outlive the kit in normal use.
public actor ParallelRunHandle {

    /// The logger for migration routing decisions. Fleet-standard
    /// subsystem and category per CLAUDE.md.
    private static let logger = Logger(
        subsystem: "com.mootx01.kit",
        category: "GeniusLocusKit"
    )

    /// The source estate (the old estate being migrated away from).
    /// Kept open during the parallel run so `.readFromSource` and
    /// `.mirrorBoth` modes can continue reading and writing to it.
    public let source: EstateHandle

    /// The target estate (the new estate being migrated into). All
    /// capture modes write here; this is the estate that must pass
    /// `verifyMigration` before the source is decommissioned.
    public let target: EstateHandle

    /// How new captures are routed during this run. Set at construction
    /// and not mutable: changing the routing mode mid-run is a new
    /// `runParallel` call.
    public let mode: ParallelCaptureMode

    /// Whether this run has been stopped. Once true, all subsequent
    /// `capture` calls throw `MigrationError.parallelRunStopped`.
    /// Irreversible — a stopped handle cannot be restarted.
    private var stopped: Bool = false

    /// The kit that owns this handle's estates. Unowned to avoid a
    /// retain cycle: the caller who opened the estates also holds the
    /// kit reference; no separate cycle is formed here.
    private unowned let kit: GeniusLocusKit

    /// Construct a parallel run handle. Internal because only
    /// `GeniusLocusKit.runParallel` issues handles; outside callers
    /// receive handles back from `runParallel` and never construct
    /// their own.
    init(
        source: EstateHandle,
        target: EstateHandle,
        mode: ParallelCaptureMode,
        kit: GeniusLocusKit
    ) {
        self.source = source
        self.target = target
        self.mode = mode
        self.kit = kit
    }

    // MARK: - capture

    /// File a new drawer according to the run's capture mode.
    ///
    /// Routes the capture to the target, both estates, or target-only
    /// (with source readable) depending on `mode`. Throws
    /// `MigrationError.parallelRunStopped` if `stop()` has been called.
    ///
    /// For `.mirrorBoth`, captures to target and source are issued
    /// concurrently via `async let`. The target's result is returned;
    /// if the source capture fails, the error is surfaced (both writes
    /// must succeed in mirror mode).
    public func capture(_ frame: CaptureFrame) async throws -> Drawer {
        guard !stopped else {
            throw MigrationError.parallelRunStopped
        }
        switch mode {
        case .writeToTarget:
            // Captures go only to the target. Source is kept open for
            // reads but receives no writes during this mode.
            return try await kit.capture(target, frame)

        case .readFromSource:
            // Reads come from source, new writes go to target.
            // The capture here writes to target; callers that need
            // source-fallback reads issue recalls directly on the source
            // handle via the kit's `recall` verb.
            return try await kit.capture(target, frame)

        case .mirrorBoth:
            // Concurrent writes to both estates. Both must succeed.
            // Target's result is returned; source write failure surfaces
            // to the caller.
            async let targetDrawer = kit.capture(target, frame)
            async let sourceDrawer = kit.capture(source, frame)
            _ = try await sourceDrawer   // surface any source failure
            return try await targetDrawer
        }
    }

    // MARK: - stop

    /// Permanently stop this parallel run.
    ///
    /// Once stopped, all subsequent `capture` calls throw
    /// `MigrationError.parallelRunStopped`. Stopping is irreversible;
    /// the caller must issue a new `runParallel` call to create a fresh
    /// handle. This models the lifecycle of a migration window: the
    /// window closes once, and any code that slipped past the close
    /// boundary gets a clear, debuggable error rather than writing to
    /// the wrong estate.
    public func stop() {
        stopped = true
        Self.logger.debug("ParallelRunHandle stopped — source=\(self.source.estateUUID, privacy: .public) target=\(self.target.estateUUID, privacy: .public)")
    }
}
