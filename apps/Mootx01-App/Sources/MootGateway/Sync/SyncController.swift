import Foundation
import ConvergenceKit
import PersistenceKit
import LocusKit
import OSLog

// MARK: - SyncController  (app-side orchestration of ConvergenceKit sync)
//
// Drives ConvergenceKit's CloudKitSyncEngine from the app's ambient beats
// (launch, foregrounding, on-power tick) — the same moments ShareInboxDrain
// and WidgetSnapshotRefresher use. Enables once against the estate's live
// Storage (via SyncController), then push/pulls each beat.
//
// GeniusLocusKit.registerSyncEngine is status-reporting only (it feeds the
// moot_estate_status `sync:` token); it does NOT drive the lifecycle — the
// app must, which is this type's whole job.
//
// The SyncManifest is INJECTED, never hardcoded here: SyncedTable.name must
// be a real PersistenceKit table in the estate schema (the engine throws
// .schemaMismatch/.kitMismatch otherwise), so manifest construction is a
// schema-verified concern for the caller, not a guess in this file.

public actor SyncController {

    public enum SyncControllerError: Error, CustomStringConvertible {
        case notEnabled
        public var description: String {
            "Sync is not enabled — call enable(engine:manifest:) before push/pull."
        }
    }

    private let bridge: MootBridge
    private var engine: (any SyncEngine)?
    private let log = Logger(subsystem: "com.codedaptive.mootx01", category: "sync")

    /// Retained reference to the active SensitivityFilteredStorage.
    ///
    /// Used by updateCeiling(to:) to lower the ceiling and emit retraction tombstones
    /// when tier authorization is revoked (FAB5-ST). Cleared when disable() tears down
    /// the engine.
    private var filteredStorage: SensitivityFilteredStorage?

    /// Optional federation session manager. When set, `disable()` cascades to
    /// `federationSessionManager?.endSession()` (try?) after disabling the
    /// CloudKit engine, ensuring both sync paths tear down together.
    ///
    /// Wire via `setFederationSessionManager(_:)` after construction.
    /// Not set at init to avoid circular dependencies.
    private var federationSessionManager: FederationSessionManager?

    public init(bridge: MootBridge) {
        self.bridge = bridge
    }

    /// Wire a `FederationSessionManager` so it is torn down when this controller
    /// is disabled. The manager's `endSession()` is called (best-effort via `try?`)
    /// only when a session is active — it is a no-op if no session is active.
    ///
    /// Call this after constructing the session manager and before any sync beats.
    public func setFederationSessionManager(_ manager: FederationSessionManager) {
        self.federationSessionManager = manager
    }

    /// Enable the injected engine against the estate's OWN Storage instance —
    /// the same one the ARIA verbs write through, so the engine observes the
    /// exact rows the estate mutates. For real device sync inject
    /// `CloudKitSyncEngine(containerIdentifier:)`; tests inject `NoSyncEngine()`.
    ///
    /// The sensitivity ceiling wraps storage BEFORE it is passed to `engine.enable()`.
    ///
    /// WHY this ordering is mandatory (Perkins Amendment 1, CVK-ICLOUD P5-M1):
    /// `AppliedBatch.storage` (IntegrityHook.swift:56) IS the handle engine.enable()
    /// received. Hook writes carry origin == .local and flow into the outbox
    /// (hook-writes-must-ship, Kong Q2 adjudication). Passing the unwrapped rawStorage
    /// to enable() would let hook-repair writes on restricted/secret rows carry
    /// origin == .local, enter the outbox, and cross the CloudKit wire — leaking
    /// above-ceiling content even though the initial change event was filtered.
    /// The SensitivityFilteredStorage wrapper must be the single handle the engine holds.
    ///
    /// - Parameters:
    ///   - engine: Concrete sync engine (`CloudKitSyncEngine` or `NoSyncEngine`).
    ///   - manifest: The per-estate sync manifest (tables, policies, kitID).
    ///   - ceiling: Sensitivity ceiling for outbound suppression and inbound gating.
    ///     Defaults to `.elevated` (normal + elevated sync; restricted + secret gated).
    ///   - backendName: Human-readable label registered with GeniusLocusKit for
    ///     `moot_estate_status sync:` reporting ("cloudkit", "none", etc.).
    public func enable(
        engine: any SyncEngine,
        manifest: SyncManifest,
        ceiling: AdjectiveSensitivity = .elevated,
        backendName: String = "cloudkit"
    ) async throws {
        let rawStorage = await bridge.estateStorage()
        // Wrap storage before enable() — Perkins Amendment 1 invariant (see above).
        let wrapped = SensitivityFilteredStorage(wrapping: rawStorage, ceiling: ceiling)
        try await engine.enable(manifest: manifest, storage: wrapped)
        self.engine = engine
        self.filteredStorage = wrapped  // retain for ceiling updates (FAB5-ST)
        // Register with GeniusLocusKit so moot_estate_status sync: reports real state.
        // This is status-reporting only — it does NOT drive the engine lifecycle.
        try await bridge.registerSyncEngine(engine, backendName: backendName)
        log.info("sync enabled: kit \(manifest.kitID, privacy: .public), zone \(manifest.zoneIdentifier, privacy: .public), ceiling \(ceiling.rawValue, privacy: .private)")
    }

    /// Pull remote changes (engine applies + reconciles), then push local.
    /// Pull-before-push so remote merges before we re-publish.
    @discardableResult
    public func sync() async throws -> (pulled: SyncReceipt, pushed: SyncReceipt) {
        let pulled = try await pull()
        let pushed = try await push()
        return (pulled, pushed)
    }

    @discardableResult
    public func push() async throws -> SyncReceipt {
        guard let engine else { throw SyncControllerError.notEnabled }
        return try await engine.push()
    }

    @discardableResult
    public func pull() async throws -> SyncReceipt {
        guard let engine else { throw SyncControllerError.notEnabled }
        return try await engine.pull()
    }

    public func disable() async throws {
        try await engine?.disable()
        engine = nil
        filteredStorage = nil  // release FAB5-ST reference
        // Cascade to federation session if one is active.
        // Uses try? — a failing endSession during controller teardown is logged
        // by the session manager itself; we do not re-throw here.
        try? await federationSessionManager?.endSession()
    }

    public func state() async -> SyncState? {
        await engine?.state
    }

    // MARK: - FAB5-ST: Dynamic ceiling

    /// Lower the sensitivity ceiling to `newCeiling`, retracting above-ceiling rows.
    ///
    /// Calls `SensitivityFilteredStorage.retractAndLowerCeiling(to:tables:)` which:
    /// 1. Scans base storage for drawers whose `adjectiveBitmap` exceeds `newCeiling`.
    /// 2. Yields WB1-style tombstones into the retraction stream (merged into the
    ///    drawers observer), so the sync engine ships them on the next push cycle.
    /// 3. Updates the ceiling atomically.
    ///
    /// Raising the ceiling (newCeiling > current) is also valid — no tombstones are
    /// emitted (no rows exceed the higher ceiling), and the ceiling is updated so new
    /// syncs use the higher bound.
    ///
    /// No-op when sync is not currently enabled.
    public func updateCeiling(to newCeiling: AdjectiveSensitivity) async {
        guard let fs = filteredStorage else { return }
        // Only drawers carry adjectiveBitmap in the standard estate schema.
        await fs.retractAndLowerCeiling(to: newCeiling, tables: ["drawers"])
        log.info("sync ceiling updated: \(newCeiling.rawValue, privacy: .private)")
    }
}
