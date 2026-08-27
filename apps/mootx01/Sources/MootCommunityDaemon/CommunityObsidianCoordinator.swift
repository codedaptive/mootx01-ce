// CommunityObsidianCoordinator.swift
//
// Daemon-owned lifecycle coordinator for the Obsidian continuous-sync service
// (Wave C1: CORE-06).
//
// ARCHITECTURE
// ───────────────────────────────────────────────────────────────────────────
// This actor WRAPS VaultResidentService (and its underlying VaultWatcher,
// VaultBridge, ObsidianAdapter, and VaultExportScope) — it does NOT rebuild
// sync mechanics. All vault↔estate movement is delegated to VaultResidentService.
//
// The coordinator owns:
//   1. Two durable sidecar files:
//      - obsidian-authorization.json  — vault URL, displayName, bookmark data,
//                                       validity state (valid | needsRenewal).
//      - obsidian-state.json          — enabled flag, checkpointAt, recordCount,
//                                       and the current interruption/error state.
//   2. Lifecycle of VaultResidentService: start on enable, stop on disable.
//   3. Runtime status projection: maps the current service state onto the
//      contract's ObsidianStatus union honestly.
//   4. A periodic health-check task (default 30 s; injectable for tests)
//      that verifies vault directory accessibility and transitions to
//      interrupted{vault-access-revoked, retryable:true} when it fails.
//
// BOOKMARK HANDLING DECISION
// ───────────────────────────────────────────────────────────────────────────
// The contract specifies `bookmark: base64` in VaultSelectionArguments. On
// macOS, Obsidian typically provides security-scoped bookmarks (NSURL bookmarks
// with NSURLBookmarkCreationWithSecurityScope) that survive restarts and survive
// the vault being moved. Security-scoped bookmarks are an app-sandbox feature
// and require entitlements — they are not available in the daemon process context.
//
// Decision: in the daemon/test context, the base64 data is interpreted as a
// UTF-8-encoded file:// URL string. The coordinator decodes base64 → UTF-8 →
// URL and validates it resolves to an accessible directory. This is documented
// explicitly so the production composition root can supply proper bookmark data
// (a file URL encoded as base64) or wrap the coordinator with a security-scoped
// resolver if the daemon ever runs sandboxed.
//
// The bookmarkData is stored in obsidian-authorization.json verbatim so a future
// security-scoped re-resolution path can use it without migration.
//
// PRIVACY FENCE
// ───────────────────────────────────────────────────────────────────────────
// VaultResidentService always calls VaultBridge.export with scope: .exportable
// (AdjectiveExportability == .public_). Non-exportable drawers (private/restricted/
// secret/default) NEVER reach the vault through this service. The fence is
// enforced inside VaultResidentService and VaultBridge — the coordinator does
// not re-enforce it but the acceptance test verifies it end-to-end.
//
// IDEMPOTENCY
// ───────────────────────────────────────────────────────────────────────────
// VaultBridge.export is idempotent: repeated observation of the same exportable
// drawer produces the same vault note, not duplicates. The VaultBridge uses a
// note's stableSourceKey to derive the vault path; writing the same content to
// the same path is a no-op at the filesystem level and a drawersSkippedUnchanged
// event at the coordinator level.
//
// CHECKPOINT DURABILITY
// ───────────────────────────────────────────────────────────────────────────
// checkpointAt and recordCount are persisted to obsidian-state.json after every
// successful startup resync. A new coordinator instance (fresh daemon restart)
// reads these from disk — the checkpoint survives restarts. The service performs
// a full bidirectional resync on start(), which is idempotent due to the
// drawersSkippedUnchanged dedup in VaultBridge. Content that was already synced
// before the restart is not duplicated.
//
// SIDECAR: obsidian-authorization.json
// ───────────────────────────────────────────────────────────────────────────
// { "vaultURL": "file:///...", "displayName": "...", "bookmarkData": "<base64>",
//   "needsRenewal": false, "renewalReason": null }
//
// SIDECAR: obsidian-state.json
// ───────────────────────────────────────────────────────────────────────────
// { "enabled": false, "checkpointAt": null, "recordCount": null,
//   "interruptedReason": null, "interruptedRetryable": null }
//
// Both sidecars are written atomically (write .tmp then rename) so a crash
// mid-write never corrupts them.

import Foundation
import OSLog
import AriaMCP
import GeniusLocusKit
import LocusKit
import VaultKit

private let log = Logger(subsystem: "com.mootx01", category: "CommunityObsidianCoordinator")

// MARK: - Persisted types

/// Persisted Obsidian authorization state (obsidian-authorization.json).
private struct PersistedAuthorization: Codable, Sendable {
    /// Resolved file URL as a string ("file:///path/to/vault").
    var vaultURL: String
    /// Human-readable vault display name.
    var displayName: String
    /// Base64-encoded bookmark data. In the daemon context this is the
    /// base64 of the UTF-8 file URL (see BOOKMARK HANDLING DECISION above).
    /// Stored verbatim for future security-scoped re-resolution.
    var bookmarkData: String
    /// Whether the authorization needs renewal (vault inaccessible, permission revoked).
    var needsRenewal: Bool
    /// Reason code for renewal requirement (only when needsRenewal = true).
    var renewalReason: String?
}

/// Persisted sync service state (obsidian-state.json).
private struct PersistedSyncState: Codable, Sendable {
    /// Whether the sync service is in the enabled state.
    var enabled: Bool
    /// ISO8601 timestamp of the last successful sync checkpoint (nil if never synced).
    var checkpointAt: String?
    /// Number of records in the vault at the last checkpoint (nil if never synced).
    var recordCount: Int?
    /// Reason code for an interruption (nil when not interrupted).
    var interruptedReason: String?
    /// Whether the interruption is retryable (nil when not interrupted).
    var interruptedRetryable: Bool?
}

// MARK: - Runtime phase

/// In-memory sync phase — not persisted, derives from service lifecycle.
///
/// The persisted state (enabled, interruptedReason) is authoritative across
/// restarts. The runtime phase tracks the current in-memory service state.
private enum RuntimePhase: Sendable {
    /// Service is stopped (either disabled or not yet started).
    case stopped
    /// Service started; startup resync in progress.
    case starting
    /// Service running normally — no known error.
    case running
    /// Service stopped due to vault inaccessibility or error.
    case interrupted(reason: String, retryable: Bool)
}

// MARK: - CommunityObsidianCoordinator

/// Daemon-owned lifecycle coordinator wrapping VaultResidentService.
///
/// Inject one instance into `CommunityContractDispatch` after constructing it
/// with the layout directory, kit, and handle. In production the layout URL is
/// `~/Library/Application Support/MOOTx01/`; in tests it is a per-test temp
/// directory.
///
/// The actor serializes all state access — concurrent tool calls are safe.
public actor CommunityObsidianCoordinator: Sendable {

    // MARK: - Stored properties

    /// The layout directory — parent of sidecars (obsidian-*.json).
    public let layoutURL: URL

    /// The GeniusLocusKit instance for VaultResidentService.
    private let kit: GeniusLocusKit

    /// The open estate handle for VaultResidentService.
    private let handle: EstateHandle

    /// Poll interval for the VaultWatcher inside VaultResidentService (seconds).
    /// Shorter in tests for faster cycle detection. Default 10 s.
    private let watcherPollSeconds: Int

    /// Estate→vault push interval inside VaultResidentService (seconds).
    /// Shorter in tests for faster convergence. Default 60 s.
    private let estatePollSeconds: Int

    /// Health-check interval: how often to verify vault directory access (seconds).
    /// Shorter in tests for rapid interrupted-state detection. Default 30 s.
    private let healthCheckSeconds: Int

    // MARK: - Derived paths

    private var authorizationURL: URL {
        layoutURL.appendingPathComponent("obsidian-authorization.json")
    }
    private var stateURL: URL {
        layoutURL.appendingPathComponent("obsidian-state.json")
    }

    // MARK: - Runtime state

    /// The live VaultResidentService (nil when service is not running).
    private var service: VaultResidentService?

    /// Background task that periodically checks vault health.
    private var healthTask: Task<Void, Never>?

    /// Current in-memory runtime phase. Derived from service state; not persisted.
    /// Initialized to .stopped on every coordinator instance (daemon restart starts
    /// from stopped; the persisted state tells us if we SHOULD be running).
    private var runtimePhase: RuntimePhase = .stopped

    // MARK: - Init

    /// Construct a coordinator.
    ///
    /// - Parameters:
    ///   - layoutURL:         Layout directory for sidecar files.
    ///   - kit:               Open GeniusLocusKit instance (for VaultResidentService).
    ///   - handle:            Open EstateHandle (for VaultResidentService).
    ///   - watcherPollSeconds: VaultWatcher poll interval inside VaultResidentService.
    ///   - estatePollSeconds: Estate→vault push interval inside VaultResidentService.
    ///   - healthCheckSeconds: Vault health-check interval.
    public init(
        layoutURL: URL,
        kit: GeniusLocusKit,
        handle: EstateHandle,
        watcherPollSeconds: Int = 10,
        estatePollSeconds: Int = 60,
        healthCheckSeconds: Int = 30
    ) {
        self.layoutURL = layoutURL
        self.kit = kit
        self.handle = handle
        self.watcherPollSeconds = watcherPollSeconds
        self.estatePollSeconds = estatePollSeconds
        self.healthCheckSeconds = healthCheckSeconds
    }

    // MARK: - Resume after restart

    /// Resume the service if the persisted state says enabled=true.
    ///
    /// Call this once from the composition root after constructing the coordinator.
    /// A new coordinator starts in .stopped phase regardless of the persisted flag;
    /// this method re-starts the service if appropriate.
    ///
    /// In tests, call this to simulate what the daemon does on startup.
    public func resumeIfEnabled() async {
        let state = readState()
        guard state.enabled else { return }
        // Guard: authorization must be present and valid.
        guard let auth = readAuthorization(), !auth.needsRenewal else { return }
        guard let vaultURL = URL(string: auth.vaultURL) else { return }
        do {
            try await startService(vaultURL: vaultURL)
            log.info("obsidian: resumed service after daemon restart (vault: \(auth.displayName, privacy: .public))")
        } catch {
            log.error("obsidian: resume failed: \(error, privacy: .public)")
            markInterrupted(reason: "vault-access-revoked", retryable: true)
        }
    }

    // MARK: - Endpoint: moot_community_obsidian_status

    /// Return the current sync service status as an ObsidianStatus union.
    ///
    /// Status projection rules (in priority order):
    ///   1. No authorization file → blocked{vault-authorization-missing}.
    ///   2. Auth.needsRenewal     → interrupted{vault-access-revoked, retryable:true}
    ///      (the vault was previously authorized but access was revoked; the caller
    ///      must call obsidian_authorization to see the full renewal details).
    ///   3. Service not enabled   → paused (with truthful checkpoint if available).
    ///   4. Runtime interrupted   → interrupted{reason, retryable} (persisted).
    ///   5. Runtime starting      → starting.
    ///   6. Runtime running       → idle (with checkpoint if available).
    public func status() async -> JSONValue {
        let state = readState()
        let auth = readAuthorization()

        // Rule 1: no vault selected → blocked.
        guard let auth else {
            return ObsidianStatus.blocked(
                reason: "vault-authorization-missing",
                checkpointAt: nil,
                recordCount: nil
            ).toJSONValue()
        }

        let checkpoint = parseISO8601(state.checkpointAt)
        let recordCount = state.recordCount

        // Rule 2: authorization needs renewal → interrupted (retryable=true).
        if auth.needsRenewal {
            return ObsidianStatus.interrupted(
                reason: "vault-access-revoked",
                retryable: true,
                checkpointAt: checkpoint,
                recordCount: recordCount
            ).toJSONValue()
        }

        // Rule 3: not enabled → paused.
        guard state.enabled else {
            return ObsidianStatus.paused(
                checkpointAt: checkpoint,
                recordCount: recordCount
            ).toJSONValue()
        }

        // Rule 4: persisted interruption (set by health-check task or start failure).
        if let reason = state.interruptedReason, let retryable = state.interruptedRetryable {
            return ObsidianStatus.interrupted(
                reason: reason,
                retryable: retryable,
                checkpointAt: checkpoint,
                recordCount: recordCount
            ).toJSONValue()
        }

        // Rule 5: runtime starting.
        if case .starting = runtimePhase {
            return ObsidianStatus.starting.toJSONValue()
        }

        // Rule 6: runtime interrupted (detected by health-check but not yet persisted —
        // this handles the in-flight case where health-check fired but state write is pending).
        if case let .interrupted(reason, retryable) = runtimePhase {
            return ObsidianStatus.interrupted(
                reason: reason,
                retryable: retryable,
                checkpointAt: checkpoint,
                recordCount: recordCount
            ).toJSONValue()
        }

        // Default: service is enabled and running — idle.
        return ObsidianStatus.idle(
            checkpointAt: checkpoint,
            recordCount: recordCount
        ).toJSONValue()
    }

    // MARK: - Endpoint: moot_community_obsidian_authorization

    /// Return the current authorization state.
    ///
    /// - missing:      No vault has been selected (obsidian-authorization.json absent).
    /// - valid:        Vault selected and authorization is current.
    /// - needsRenewal: Vault was authorized but access was revoked/expired.
    public func authorization() async -> JSONValue {
        guard let auth = readAuthorization() else {
            return ObsidianAuthorization.missing.toJSONValue()
        }
        if auth.needsRenewal, let reason = auth.renewalReason {
            return ObsidianAuthorization.needsRenewal(
                vaultURL: auth.vaultURL,
                displayName: auth.displayName,
                reason: reason
            ).toJSONValue()
        }
        return ObsidianAuthorization.valid(
            vaultURL: auth.vaultURL,
            displayName: auth.displayName
        ).toJSONValue()
    }

    // MARK: - Endpoint: moot_community_obsidian_select_vault

    /// Select a vault from a base64-encoded bookmark and a display name.
    ///
    /// Bookmark resolution (daemon context — see BOOKMARK HANDLING DECISION):
    /// base64 decode → UTF-8 string → URL. The URL must be a file:// URL
    /// pointing to an accessible directory. If it is not, returns denied.
    ///
    /// On success:
    ///   - Writes obsidian-authorization.json with the resolved URL.
    ///   - Returns selected{vaultURL, displayName}.
    ///
    /// On failure (bookmark invalid or not a directory):
    ///   - Returns denied{vault-authorization-missing}.
    public func selectVault(bookmark: Data, displayName: String) async -> JSONValue {
        // Decode the bookmark per the daemon convention.
        guard
            let urlString = String(data: bookmark, encoding: .utf8),
            let vaultURL = URL(string: urlString),
            vaultURL.isFileURL
        else {
            log.error("obsidian: select_vault: bookmark does not decode to a file URL")
            return VaultSelectionOutcome.denied(reason: "vault-authorization-missing").toJSONValue()
        }

        // Verify the URL resolves to an accessible directory.
        var isDir: ObjCBool = false
        guard
            FileManager.default.fileExists(atPath: vaultURL.path, isDirectory: &isDir),
            isDir.boolValue
        else {
            log.error("obsidian: select_vault: vault path is not an accessible directory: \(vaultURL.path, privacy: .public)")
            return VaultSelectionOutcome.denied(reason: "vault-authorization-missing").toJSONValue()
        }

        // Persist the authorization.
        let auth = PersistedAuthorization(
            vaultURL: vaultURL.absoluteString,
            displayName: displayName,
            bookmarkData: bookmark.base64EncodedString(),
            needsRenewal: false,
            renewalReason: nil
        )
        writeAuthorization(auth)
        log.info("obsidian: vault selected: \(displayName, privacy: .public) at \(vaultURL.path, privacy: .public)")
        return VaultSelectionOutcome.selected(
            vaultURL: vaultURL.absoluteString,
            displayName: displayName
        ).toJSONValue()
    }

    // MARK: - Endpoint: moot_community_obsidian_enable

    /// Enable the sync service.
    ///
    /// Preconditions (fail-closed):
    ///   - Authorization must exist and not need renewal → refused{vault-authorization-missing}.
    ///   - The vault URL must still be accessible → refused{vault-authorization-missing}.
    ///
    /// On success:
    ///   - Starts VaultResidentService (triggers startup resync).
    ///   - Updates obsidian-state.json (enabled=true, clears interruption state).
    ///   - Returns enabled.
    public func enable() async -> JSONValue {
        // Check authorization.
        guard let auth = readAuthorization() else {
            return ObsidianEnableOutcome.refused(reason: "vault-authorization-missing").toJSONValue()
        }
        guard !auth.needsRenewal else {
            return ObsidianEnableOutcome.refused(reason: "vault-authorization-missing").toJSONValue()
        }
        guard let vaultURL = URL(string: auth.vaultURL) else {
            return ObsidianEnableOutcome.refused(reason: "vault-authorization-missing").toJSONValue()
        }

        // Verify vault accessibility before starting.
        var isDir: ObjCBool = false
        guard
            FileManager.default.fileExists(atPath: vaultURL.path, isDirectory: &isDir),
            isDir.boolValue
        else {
            // Vault inaccessible — mark as needing renewal.
            markAuthNeedsRenewal(auth: auth, reason: "vault-access-revoked")
            return ObsidianEnableOutcome.refused(reason: "vault-authorization-missing").toJSONValue()
        }

        // Persist enabled state (clear any prior interruption).
        var state = readState()
        state.enabled = true
        state.interruptedReason = nil
        state.interruptedRetryable = nil
        writeState(state)

        // Start the service.
        do {
            try await startService(vaultURL: vaultURL)
        } catch {
            // Service failed to start — mark interrupted and persist.
            log.error("obsidian: enable: service start failed: \(error, privacy: .public)")
            markInterrupted(reason: "vault-access-revoked", retryable: true)
            return ObsidianEnableOutcome.failed(reason: "unexpected-failure").toJSONValue()
        }

        log.info("obsidian: service enabled (vault: \(auth.displayName, privacy: .public))")
        return ObsidianEnableOutcome.enabled.toJSONValue()
    }

    // MARK: - Endpoint: moot_community_obsidian_disable

    /// Disable the sync service.
    ///
    /// Preserves vault content on disk (policy per disable-preserves-content fixture).
    /// Reports truthful pending and checkpoint state.
    ///
    /// Returns:
    ///   - disabledOnly: service stopped, vault content preserved.
    ///   - failed{reason}: unexpected error during stop.
    public func disable() async -> JSONValue {
        // Stop the service and health check task.
        await stopService()

        // Persist disabled state (preserve checkpointAt/recordCount honestly).
        var state = readState()
        state.enabled = false
        // Do NOT clear checkpointAt/recordCount — preserve them truthfully.
        // Do NOT clear interruptedReason — callers can see the last error.
        writeState(state)

        log.info("obsidian: service disabled (vault content preserved)")
        // disabledOnly: vault content is preserved on disk, not removed.
        return ObsidianDisableOutcome.disabledOnly.toJSONValue()
    }

    // MARK: - Endpoint: moot_community_obsidian_retry

    /// Retry after an interruption.
    ///
    /// Preconditions:
    ///   - Prior state must be interrupted AND retryable=true →
    ///     else refused{sync-not-retryable}.
    ///   - Authorization must be present and valid → else refused.
    ///
    /// On success:
    ///   - Clears interruption state.
    ///   - Restarts VaultResidentService.
    ///   - Returns restarted.
    public func retry() async -> JSONValue {
        let state = readState()

        // The retry is valid when enabled=true AND an interruptedReason exists
        // AND it is retryable. If enabled=false, a retry is nonsensical (user
        // should call enable; retry is for recovering from mid-run failures).
        guard state.enabled else {
            return ObsidianRetryOutcome.refused(reason: "sync-not-retryable").toJSONValue()
        }

        // Check persisted interrupted state first.
        if let _ = state.interruptedReason {
            guard let retryable = state.interruptedRetryable, retryable else {
                return ObsidianRetryOutcome.refused(reason: "sync-not-retryable").toJSONValue()
            }
        }

        // Check runtime interrupted phase (not yet persisted).
        if case let .interrupted(_, retryable) = runtimePhase, !retryable {
            return ObsidianRetryOutcome.refused(reason: "sync-not-retryable").toJSONValue()
        }

        // For retry to make sense, there should be an interruption to recover from.
        // If neither persisted nor runtime interrupted state exists, refuse.
        let hasInterruption: Bool = {
            if case .interrupted = runtimePhase { return true }
            return state.interruptedReason != nil
        }()
        guard hasInterruption else {
            return ObsidianRetryOutcome.refused(reason: "sync-not-retryable").toJSONValue()
        }

        // Check authorization.
        guard let auth = readAuthorization(), !auth.needsRenewal,
              let vaultURL = URL(string: auth.vaultURL) else {
            return ObsidianRetryOutcome.refused(reason: "sync-not-retryable").toJSONValue()
        }

        // Clear interruption state and restart.
        var newState = readState()
        newState.interruptedReason = nil
        newState.interruptedRetryable = nil
        writeState(newState)
        runtimePhase = .stopped

        do {
            try await startService(vaultURL: vaultURL)
        } catch {
            log.error("obsidian: retry: service restart failed: \(error, privacy: .public)")
            markInterrupted(reason: "vault-access-revoked", retryable: true)
            return ObsidianRetryOutcome.failed(reason: "unexpected-failure").toJSONValue()
        }

        log.info("obsidian: service restarted after retry")
        return ObsidianRetryOutcome.restarted.toJSONValue()
    }

    // MARK: - Service lifecycle helpers

    /// Start VaultResidentService and update runtime phase.
    ///
    /// Sets runtimePhase to .starting before starting, then .running after.
    /// Starts the health-check task. Updates checkpoint after startup resync.
    private func startService(vaultURL: URL) async throws {
        // Stop any existing service cleanly before creating a new one.
        await stopService()

        runtimePhase = .starting
        let svc = VaultResidentService(
            kit: kit,
            handle: handle,
            vaultURL: vaultURL,
            pollIntervalSeconds: watcherPollSeconds,
            estatePollSeconds: estatePollSeconds
        )
        // start() performs the startup resync (estate→vault export + full vault→estate import).
        // Throws VaultResidentError.vaultNotFound if vault directory is gone at start time.
        try await svc.start()
        service = svc
        runtimePhase = .running

        // After startup resync, record the checkpoint. Count .md files in vault
        // as the record count (approximate: each exportable drawer → one .md file).
        updateCheckpoint(vaultURL: vaultURL)

        // Start the health-check background task.
        startHealthCheck(vaultURL: vaultURL)
    }

    /// Stop VaultResidentService and cancel the health-check task.
    private func stopService() async {
        healthTask?.cancel()
        healthTask = nil
        if let svc = service {
            await svc.stop()
            service = nil
        }
        if case .running = runtimePhase { runtimePhase = .stopped }
        else if case .starting = runtimePhase { runtimePhase = .stopped }
    }

    /// Start the background health-check task.
    ///
    /// The task periodically checks vault directory accessibility. If the vault
    /// becomes inaccessible mid-run, the service is stopped and the coordinator
    /// transitions to interrupted{vault-access-revoked, retryable:true}.
    private func startHealthCheck(vaultURL: URL) {
        let intervalNs = UInt64(healthCheckSeconds) * 1_000_000_000
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: intervalNs) } catch { break }
                guard let self else { break }
                let accessible = await self.isVaultAccessible(vaultURL: vaultURL)
                if !accessible {
                    await self.handleVaultLoss(vaultURL: vaultURL)
                    break
                }
            }
        }
    }

    /// Check whether the vault directory is accessible.
    private func isVaultAccessible(vaultURL: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: vaultURL.path, isDirectory: &isDir)
            && isDir.boolValue
    }

    /// Handle vault loss (directory removed or access revoked mid-run).
    ///
    /// Stops the service, transitions to interrupted state, and persists the
    /// error so status() and retry() reflect it accurately.
    private func handleVaultLoss(vaultURL: URL) async {
        log.warning("obsidian: vault became inaccessible — transitioning to interrupted: \(vaultURL.path, privacy: .public)")
        await stopService()
        markInterrupted(reason: "vault-access-revoked", retryable: true)
        // Also mark the authorization as needing renewal so obsidian_authorization
        // returns needsRenewal instead of valid (the vault URL can't be reached).
        if let auth = readAuthorization() {
            markAuthNeedsRenewal(auth: auth, reason: "vault-access-revoked")
        }
    }

    /// Persist an interrupted state.
    private func markInterrupted(reason: String, retryable: Bool) {
        runtimePhase = .interrupted(reason: reason, retryable: retryable)
        var state = readState()
        state.interruptedReason = reason
        state.interruptedRetryable = retryable
        writeState(state)
    }

    /// Persist authorization-needs-renewal state.
    private func markAuthNeedsRenewal(auth: PersistedAuthorization, reason: String) {
        var updated = auth
        updated.needsRenewal = true
        updated.renewalReason = reason
        writeAuthorization(updated)
    }

    /// Update the checkpoint after a successful sync.
    ///
    /// checkpointAt = current time.
    /// recordCount = number of .md files currently in the vault directory.
    private func updateCheckpoint(vaultURL: URL) {
        var state = readState()
        state.checkpointAt = iso8601Encode(Date())
        state.recordCount = countVaultMdFiles(vaultURL: vaultURL)
        writeState(state)
    }

    /// Count the number of .md files in the vault directory tree.
    ///
    /// Used as an approximation of record count (each exportable drawer →
    /// one .md note). Hidden files and non-.md files are excluded, matching
    /// VaultWatcher's enumeration policy.
    private func countVaultMdFiles(vaultURL: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: vaultURL,
            includingPropertiesForKeys: [],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var count = 0
        for case let url as URL in enumerator where url.pathExtension == "md" {
            count += 1
        }
        return count
    }

    // MARK: - Sidecar: obsidian-authorization.json

    /// Read authorization from disk. Returns nil if file absent or unparseable.
    private func readAuthorization() -> PersistedAuthorization? {
        guard let data = try? Data(contentsOf: authorizationURL) else { return nil }
        return try? JSONDecoder().decode(PersistedAuthorization.self, from: data)
    }

    /// Write authorization atomically (.tmp then rename).
    private func writeAuthorization(_ auth: PersistedAuthorization) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(auth) else {
            log.error("obsidian: authorization encode failed")
            return
        }
        atomicWrite(data: data, to: authorizationURL)
    }

    // MARK: - Sidecar: obsidian-state.json

    /// Read state from disk. Returns a default (disabled, no checkpoint) if absent/unparseable.
    private func readState() -> PersistedSyncState {
        guard let data = try? Data(contentsOf: stateURL) else {
            return PersistedSyncState(
                enabled: false,
                checkpointAt: nil,
                recordCount: nil,
                interruptedReason: nil,
                interruptedRetryable: nil
            )
        }
        return (try? JSONDecoder().decode(PersistedSyncState.self, from: data))
            ?? PersistedSyncState(
                enabled: false,
                checkpointAt: nil,
                recordCount: nil,
                interruptedReason: nil,
                interruptedRetryable: nil
            )
    }

    /// Write state atomically (.tmp then rename).
    private func writeState(_ state: PersistedSyncState) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(state) else {
            log.error("obsidian: state encode failed")
            return
        }
        atomicWrite(data: data, to: stateURL)
    }

    // MARK: - Atomic write helper

    /// Write data atomically by writing to a .tmp file then renaming.
    ///
    /// A crash mid-write never corrupts the target file — the rename is
    /// atomic at the kernel level on APFS/HFS+.
    private func atomicWrite(data: Data, to url: URL) {
        let tmp = url.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            // Fallback: write directly (less safe but preserves the intent).
            do {
                try data.write(to: url, options: .atomic)
                try? FileManager.default.removeItem(at: tmp)
            } catch {
                log.error("obsidian: atomic write failed to \(url.lastPathComponent, privacy: .public): \(error, privacy: .public)")
            }
        }
    }

    // MARK: - Date helpers

    /// Parse an ISO8601 date string back to a Date. Returns nil on failure.
    private func parseISO8601(_ str: String?) -> Date? {
        guard let str else { return nil }
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fmt.date(from: str) { return d }
        let fmt2 = ISO8601DateFormatter()
        fmt2.formatOptions = [.withInternetDateTime]
        return fmt2.date(from: str)
    }
}
