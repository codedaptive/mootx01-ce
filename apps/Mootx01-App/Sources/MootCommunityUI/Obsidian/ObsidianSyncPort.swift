import Foundation

// MARK: - ObsidianSyncPort  (APP-05 — Obsidian Synchronization Controls)
//
// Feature-local presentation port. Lossless projection of CONTRACT-05.
//
// The real gateway adapter (INTEGRATION-02) substitutes at this abstraction;
// until that integration ships, all ObsidianSyncModel behavior is exercised
// against a fake daemon conformer in CommunityBoundaryTests/Obsidian/.
//
// FAIL-CLOSED rule (verbatim from the Community 1.1 requirements):
// "When required authority, policy, data, daemon availability, compatibility,
//  or recovery state cannot be proven, the operation does not proceed and does
//  not fall back to a less protected path."
//
// Nothing in this file reaches MootGateway, SQLite, PersistenceKit,
// LocusKit, or GeniusLocusKit. All business rules and state transitions are
// daemon-owned. Models render typed daemon state and submit typed requests;
// they never recompute daemon outcomes.

// MARK: - ObsidianAuthorizationState

/// CONTRACT-05: Daemon-reported authorization state for the configured vault.
///
/// The model renders this state directly — it never infers authorization
/// validity from any other source (no filesystem checks, no cached credentials).
public enum ObsidianAuthorizationState: Sendable, Equatable {
    /// A vault is configured and access is currently authorized.
    case valid(vaultURL: URL, displayName: String)
    /// No vault has been selected. The user must pick one before sync is possible.
    case missing
    /// A vault is configured but authorization has lapsed or been revoked.
    /// The user must re-authorize (or replace) this vault before sync resumes.
    case needsRenewal(vaultURL: URL, displayName: String, reason: String)
}

// MARK: - ObsidianCheckpoint

/// CONTRACT-05: The daemon's record of the last successful synchronization
/// checkpoint. Provided by the daemon; the model displays it verbatim.
public struct ObsidianCheckpoint: Sendable, Equatable {
    /// When the last successful sync completed. Injected from the daemon;
    /// the model never reads a clock to derive this value.
    public let timestamp: Date
    /// Number of records confirmed synchronized at this checkpoint.
    public let recordCount: Int

    public init(timestamp: Date, recordCount: Int) {
        self.timestamp = timestamp
        self.recordCount = recordCount
    }
}

// MARK: - ObsidianSyncProgress

/// CONTRACT-05: Outstanding work as of the current synchronization pass.
/// Daemon-supplied; the model renders it without recomputing totals.
public struct ObsidianSyncProgress: Sendable, Equatable {
    /// Records not yet synchronized in the current pass.
    public let pendingCount: Int
    /// Total records in scope for the current pass.
    public let totalCount: Int

    public init(pendingCount: Int, totalCount: Int) {
        self.pendingCount = pendingCount
        self.totalCount = totalCount
    }
}

// MARK: - ObsidianSyncStatus

/// CONTRACT-05: Nine distinct typed synchronization statuses reported by the daemon.
///
/// Requirement 4 (verbatim from APP-05): Status distinguishes starting, scanning,
/// synchronizing, idle, waiting, paused, interrupted, blocked, and failed.
///
/// The model surfaces each case verbatim; it never collapses two daemon states
/// into one display state.
///
/// Critical: `.blocked` is structurally distinct from `.idle` — an unreachable
/// daemon or inaccessible vault MUST yield `.blocked`, never `.idle`
/// (requirement 8: unavailable daemon shown as blocked, not successful idle).
public enum ObsidianSyncStatus: Sendable, Equatable {
    /// The sync engine is initializing; not yet scanning.
    case starting
    /// The vault is being scanned to discover records (post-start, pre-sync).
    case scanning
    /// Actively transferring records. Progress is provided when the daemon
    /// supplies outstanding-work counts.
    case synchronizing(progress: ObsidianSyncProgress?)
    /// No work is currently outstanding. The checkpoint is provided when the
    /// daemon has a successful prior checkpoint on record.
    case idle(checkpoint: ObsidianCheckpoint?)
    /// Sync is scheduled but not yet due. The wakeup date is provided when
    /// the daemon reports one.
    case waiting(until: Date?)
    /// Sync has been deliberately paused by user or policy.
    case paused
    /// Sync was interrupted (e.g. network loss, system sleep). The daemon
    /// reports whether the interruption is retryable (requirement 6: retry
    /// offered only for retryable conditions).
    case interrupted(reason: String, retryable: Bool)
    /// The daemon is unavailable OR the vault is inaccessible. Must be
    /// surfaced as blocked — NOT as idle — satisfying requirement 8.
    case blocked(reason: String)
    /// A failure condition. The daemon reports whether it is retryable.
    case failed(reason: String, retryable: Bool)
}

// MARK: - ObsidianSyncStatus view helpers

extension ObsidianSyncStatus {
    /// FIX 5: True when the status is `.idle`. Used by the view to suppress the
    /// model-level checkpoint footer in the idle case (the idle associated value
    /// already shows it, and showing both would be a duplicate).
    var isIdle: Bool {
        if case .idle = self { return true }
        return false
    }
}

// MARK: - VaultSelectionOutcome

/// CONTRACT-05: The outcome of a user-initiated vault selection operation.
///
/// The daemon (or OS authorization broker) is the authority on whether a
/// vault location was accepted. Cancelled and denied are structurally
/// distinct so the model can surface accurate feedback.
public enum VaultSelectionOutcome: Sendable, Equatable {
    /// The user selected a vault and the daemon accepted the authorization.
    case selected(vaultURL: URL, displayName: String)
    /// The user dismissed the picker without selecting a vault.
    case cancelled
    /// The selection was denied (e.g. authorization refused, path invalid).
    case denied(reason: String)
}

// MARK: - ObsidianEnableOutcome

/// CONTRACT-05: The daemon's response to an enable-sync request.
///
/// Fail-closed: if the daemon does not return `.enabled`, the model preserves
/// the caller's draft state and surfaces the refusal or failure verbatim.
public enum ObsidianEnableOutcome: Sendable, Equatable {
    /// Synchronization has been enabled; the daemon is now active.
    case enabled
    /// The daemon refused (e.g. authorization missing, policy violation).
    case refused(reason: String)
    /// The operation failed for a system reason.
    case failed(reason: String)
}

// MARK: - ObsidianDisablementReport

/// CONTRACT-05: The daemon's report after a disable-sync request.
///
/// Requirement 7 (verbatim): "Disabling synchronization does not claim that
/// data was removed unless the daemon reports removal."
///
/// The model MUST show `.disabledOnly` unless the daemon explicitly returns
/// `.disabledAndRemoved`. The model never infers data removal independently.
public enum ObsidianDisablementReport: Sendable, Equatable {
    /// Sync was disabled. The daemon did NOT report that local data was removed.
    case disabledOnly
    /// Sync was disabled AND the daemon explicitly reports that local data was
    /// removed.
    case disabledAndRemoved
    /// The disable operation failed.
    case failed(reason: String)
}

// MARK: - ObsidianRetryOutcome

/// CONTRACT-05: The daemon's response to a retry-sync request.
///
/// Retry must only be offered when the current status is retryable
/// (requirement 6). The model must not offer retry controls for non-retryable
/// conditions. The outcome is always the daemon's word — never inferred.
public enum ObsidianRetryOutcome: Sendable, Equatable {
    /// The daemon accepted the retry; sync is restarting.
    case restarted
    /// The daemon refused the retry (e.g. condition is no longer retryable).
    case refused(reason: String)
    /// The retry attempt failed for a system reason.
    case failed(reason: String)
}

// MARK: - ObsidianSyncPort

/// Feature-local presentation port for APP-05 Obsidian Synchronization Controls.
/// Lossless projection of CONTRACT-05.
///
/// The real gateway adapter (INTEGRATION-02) substitutes at this abstraction.
/// Models receive a conformer through injection and never construct one
/// themselves — no global/singleton writer.
///
/// All conformers must be `Sendable` so the model (a `@MainActor` class) can
/// hold and await them across isolation boundaries.
///
/// FAIL-CLOSED: when daemon state cannot be proven, the operation does not
/// proceed and does not fall back to a less-protected path. The port
/// communicates failure through typed outcomes, never through silent no-ops.
public protocol ObsidianSyncPort: Sendable {

    /// Load the daemon's current synchronization status.
    ///
    /// An unreachable daemon or inaccessible vault MUST yield `.blocked`,
    /// not `.idle`. Conformers must not substitute a synthesized idle when
    /// the daemon is unavailable (requirement 8).
    func loadStatus() async -> ObsidianSyncStatus

    /// FIX 5 (CONTRACT-05 losslessness): Load the last successful checkpoint
    /// independently of the current sync status.
    ///
    /// The checkpoint was previously only recoverable from the `.idle` associated
    /// value, meaning `.interrupted`, `.waiting`, `.paused`, and `.synchronizing`
    /// states all silently lost it. This separate load preserves it across all
    /// non-idle statuses so the view can surface it regardless of current state.
    ///
    /// Returns `nil` when no successful checkpoint exists (first-run case).
    /// An unreachable daemon MUST return `nil`, never a synthesized checkpoint.
    func loadLastCheckpoint() async -> ObsidianCheckpoint?

    /// Load the daemon's current vault authorization state.
    func loadAuthorizationState() async -> ObsidianAuthorizationState

    /// Present the vault picker and attempt authorization.
    ///
    /// The user may cancel or the daemon may deny the selection; both outcomes
    /// are typed and surfaced verbatim by the model (requirement 1).
    func selectVault() async -> VaultSelectionOutcome

    /// Request the daemon to enable synchronization.
    ///
    /// Fail-closed: if the daemon is unavailable or refuses, the model
    /// surfaces the failure and preserves the user's pending state.
    func enableSync() async -> ObsidianEnableOutcome

    /// Request the daemon to disable synchronization.
    ///
    /// The report distinguishes whether the daemon removed local data from
    /// whether it only stopped syncing (requirement 7).
    func disableSync() async -> ObsidianDisablementReport

    /// Request the daemon to retry a retryable failure or interruption.
    ///
    /// Must only be called when the current status is retryable. Conformers
    /// may return `.refused` if the status has changed since the UI loaded.
    func retrySync() async -> ObsidianRetryOutcome
}
