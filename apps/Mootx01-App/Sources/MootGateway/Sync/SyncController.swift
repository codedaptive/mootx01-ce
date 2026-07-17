import Foundation
import ConvergenceKit
import PersistenceKit
import OSLog

// MARK: - SyncController  (app-side orchestration of ConvergenceKit sync)
//
// Sync itself lives in ConvergenceKit (CloudKitSyncEngine / NoSyncEngine
// behind the SyncEngine protocol) — this controller does NOT reimplement it.
// It only wires the engine to the estate's live Storage and drives the
// enable → push/pull → disable lifecycle from the app.
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

    public init(bridge: MootBridge) {
        self.bridge = bridge
    }

    /// Enable the injected engine against the estate's OWN Storage instance —
    /// the same one the ARIA verbs write through, so the engine observes the
    /// exact rows the estate mutates. For real device sync inject
    /// `CloudKitSyncEngine(containerIdentifier:)`; tests inject `NoSyncEngine()`.
    public func enable(engine: any SyncEngine, manifest: SyncManifest) async throws {
        try await engine.enable(manifest: manifest, storage: bridge.estateStorage())
        self.engine = engine
        log.info("sync enabled: kit \(manifest.kitID, privacy: .public), zone \(manifest.zoneIdentifier, privacy: .public)")
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
    }

    public func state() async -> SyncState? {
        await engine?.state
    }
}
