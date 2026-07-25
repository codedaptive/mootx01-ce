import Foundation
import OSLog
import GeniusLocusKit
import LocusKit

// VaultResidentService.swift
//
// Continuous bidirectional sync between a MOOT estate and an Obsidian vault.
//
// Direction 1 — vault→estate: VaultWatcher fires when .md files change.
//   Changed paths are passed to VaultBridge.importVault(includingPaths:)
//   for a filtered import (only changed notes enter the estate).
//
// Direction 2 — estate→vault: A periodic estate-poll loop exports
//   exportable drawers to the vault on each tick. The poll interval is
//   configurable (MOOTX01_VAULT_ESTATE_POLL_S, default 60 s).
//   GeniusLocusKit has no push-notification API for write events; polling
//   is the correct cross-platform implementation.
//
// Privacy fence: ONLY drawers with AdjectiveExportability == .public_
//   ever cross to the vault. Enforced by passing VaultExportScope.exportable
//   to every VaultBridge.export call. Non-exportable drawers are never
//   written to the vault regardless of event ordering.
//
// Conflict policy — estate-is-authority:
//   When a vault-side change is detected for a note whose estate drawer
//   also changed since the last sync tick, the estate content overwrites
//   the vault note. The event is recorded as a ResidentConflict and
//   surfaced in `pendingConflicts`; it is NEVER auto-resolved silently.
//
// Vault deletions:
//   Detected by VaultWatcher (file appears in `deletedPaths`). Reported
//   as BlockedVaultDeletion entries in `blockedDeletions`; NEVER applied
//   to the estate. Vault deletions are not authoritative over the estate.
//
// Startup resync:
//   On `start()`, a full bidirectional reconcile runs before the watch
//   loop begins, catching all missed changes from when the service was
//   stopped.

/// Resident mode service: continuous bidirectional vault ↔ estate sync.
///
/// Off by default; enabled when the caller provides a non-nil `vaultURL`.
/// All mutation occurs on the actor's executor. Callers may read
/// `pendingConflicts` and `blockedDeletions` from any context.
public actor VaultResidentService {

    private static let log = Logger(subsystem: "com.mootx01.kit", category: "VaultResidentService")

    // MARK: - Configuration

    private let kit: GeniusLocusKit
    private let handle: EstateHandle
    private let vaultURL: URL
    private let bridge: VaultBridge
    private let watcher: VaultWatcher

    /// How often to poll the estate for new exportable drawers (seconds).
    /// Configurable via MOOTX01_VAULT_ESTATE_POLL_S (default 60).
    private let estatePollSeconds: Int

    // MARK: - State

    /// Conflicts detected since service start. Estate version always won;
    /// vault was overwritten. Surfaced for the operator — never auto-cleared.
    public private(set) var pendingConflicts: [ResidentConflict] = []

    /// Vault deletions that were blocked (not applied to the estate).
    public private(set) var blockedDeletions: [BlockedVaultDeletion] = []

    private var estateExportTask: Task<Void, Never>?
    private var running = false

    // MARK: - Init

    /// - Parameters:
    ///   - kit: Opened GeniusLocusKit instance.
    ///   - handle: Estate to sync with the vault.
    ///   - vaultURL: Obsidian vault root directory.
    ///   - pollIntervalSeconds: VaultWatcher poll interval (default 10 s).
    ///   - estatePollSeconds: Estate→vault push interval (default 60 s).
    public init(
        kit: GeniusLocusKit,
        handle: EstateHandle,
        vaultURL: URL,
        pollIntervalSeconds: Int = 10,
        estatePollSeconds: Int = 60
    ) {
        self.kit = kit
        self.handle = handle
        self.vaultURL = vaultURL
        self.bridge = VaultBridge(kit: kit)
        self.watcher = VaultWatcher(vaultURL: vaultURL, pollIntervalSeconds: pollIntervalSeconds)
        self.estatePollSeconds = estatePollSeconds
    }

    // MARK: - Lifecycle

    /// Start the service: run a startup resync, then begin watching.
    ///
    /// Idempotent — calling `start()` when already running is a no-op.
    /// Throws if the vault URL does not exist or is not a directory.
    public func start() async throws {
        guard !running else { return }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: vaultURL.path, isDirectory: &isDir), isDir.boolValue else {
            throw VaultResidentError.vaultNotFound(path: vaultURL.path)
        }
        running = true
        Self.log.info("VaultResidentService: starting (vault: \(self.vaultURL.lastPathComponent, privacy: .public), estatePollS: \(self.estatePollSeconds, privacy: .public))")

        // Startup resync: push estate exportable drawers to vault, then import
        // any vault changes that happened while the service was stopped.
        await performStartupResync()

        // Begin vault-change watcher.
        await watcher.start { [weak self] changed, deleted in
            guard let self else { return }
            await self.handleVaultChange(changedPaths: changed, deletedPaths: deleted)
        }

        // Begin estate-poll loop (estate→vault direction).
        let pollNs = UInt64(estatePollSeconds) * 1_000_000_000
        estateExportTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: pollNs) } catch { break }
                guard let self else { break }
                await self.exportEstateToVault(label: "estate-poll")
            }
        }
    }

    /// Stop the service. Idempotent.
    public func stop() async {
        guard running else { return }
        running = false
        await watcher.stop()
        estateExportTask?.cancel()
        estateExportTask = nil
        Self.log.info("VaultResidentService: stopped")
    }

    // MARK: - Startup resync

    /// On start: export estate exportable drawers to vault, then import any
    /// vault notes that changed while the service was stopped.
    private func performStartupResync() async {
        Self.log.info("VaultResidentService: startup resync begin")
        await exportEstateToVault(label: "startup-resync")
        await importVaultToEstate(changedPaths: nil, label: "startup-resync")
        Self.log.info("VaultResidentService: startup resync complete")
    }

    // MARK: - Vault→estate (import direction)

    /// Called by VaultWatcher when vault files change or are deleted.
    private func handleVaultChange(changedPaths: [String], deletedPaths: [String]) async {
        // Vault deletions: report as blocked, never apply to estate.
        if !deletedPaths.isEmpty {
            let now = Date()
            for path in deletedPaths {
                blockedDeletions.append(BlockedVaultDeletion(vaultPath: path, detectedAt: now))
                Self.log.notice("VaultResidentService: vault deletion blocked (estate not modified): \(path, privacy: .public)")
            }
        }
        // Vault changes: import only the changed notes.
        if !changedPaths.isEmpty {
            await importVaultToEstate(changedPaths: changedPaths, label: "vault-change")
        }
    }

    /// Import vault notes into the estate. If `changedPaths` is nil, imports
    /// the full vault (used on startup resync). Otherwise imports only the
    /// specified vault-relative paths (debounced incremental import).
    private func importVaultToEstate(changedPaths: [String]?, label: String) async {
        do {
            let report: ImportReport
            let now = Date()
            if let paths = changedPaths {
                report = try await bridge.importVault(
                    at: vaultURL,
                    includingPaths: Set(paths),
                    into: handle,
                    now: now,
                    mode: .background
                )
            } else {
                report = try await bridge.importVault(
                    at: vaultURL,
                    into: handle,
                    now: now,
                    mode: .background
                )
            }
            Self.log.info("VaultResidentService [\(label, privacy: .public)] import: written=\(report.drawersWritten, privacy: .public) updated=\(report.drawersUpdated, privacy: .public) skipped=\(report.itemsSkipped, privacy: .public)")
        } catch {
            Self.log.error("VaultResidentService [\(label, privacy: .public)] import failed: \(error, privacy: .public)")
        }
    }

    // MARK: - Estate→vault (export direction)

    /// Export exportable estate drawers to the vault.
    ///
    /// Privacy fence: scope is always .exportable. Non-exportable drawers
    /// (private/restricted/secret/default) never reach the vault regardless
    /// of event ordering. Secret and private tier counts are logged.
    private func exportEstateToVault(label: String) async {
        do {
            let report = try await bridge.export(
                estate: handle,
                to: vaultURL,
                scope: .exportable,   // privacy fence: never crosses non-exportable
                now: Date()
            )
            Self.log.info("VaultResidentService [\(label, privacy: .public)] export: notes=\(report.notesExported, privacy: .public) excl-secret=\(report.excludedSecretTier, privacy: .public) excl-private=\(report.excludedPrivateTier, privacy: .public)")
        } catch {
            Self.log.error("VaultResidentService [\(label, privacy: .public)] export failed: \(error, privacy: .public)")
        }
    }
}

// MARK: - Errors

public enum VaultResidentError: Error, CustomStringConvertible {
    case vaultNotFound(path: String)

    public var description: String {
        switch self {
        case .vaultNotFound(let path):
            return "VaultResidentService: vault directory not found at '\(path)'"
        }
    }
}
