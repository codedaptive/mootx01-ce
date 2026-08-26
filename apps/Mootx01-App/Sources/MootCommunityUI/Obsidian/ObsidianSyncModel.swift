import Foundation
import Observation

// MARK: - ObsidianSyncModel  (APP-05 — Obsidian Synchronization Controls)
//
// Observable presentation model for APP-05.
// Backed by an injected ObsidianSyncPort conformer (no singleton, no global
// writer). All mutable state is driven by daemon-supplied values; the model
// never recomputes a business outcome the port did not supply.
//
// Swift 6 strict-concurrency: @MainActor isolates all mutable published
// state; the port is held as `any ObsidianSyncPort` (Sendable), so it is
// safe to pass across actor boundaries inside async calls.
//
// Fail-closed discipline enforced throughout:
// - Enable/disable/retry operations advance state ONLY when the daemon confirms.
// - Disablement report is stored verbatim — the model never infers data removal.
// - Blocked status is rendered as blocked (not idle), satisfying requirement 8.

@MainActor
@Observable
public final class ObsidianSyncModel {

    // MARK: - Sync status

    /// Daemon-supplied sync status. `nil` until the first `loadStatus()` call.
    ///
    /// When `.blocked`, the UI must render this as a failure state — never as
    /// a healthy idle (requirement 8: unavailable daemon shown as blocked).
    public private(set) var syncStatus: ObsidianSyncStatus?

    /// True while a status load is in flight.
    public private(set) var isLoadingStatus = false

    // MARK: - Authorization

    /// Daemon-supplied authorization state. `nil` until first
    /// `loadAuthorizationState()` call. Requirement 2: shows valid/missing/
    /// needsRenewal as reported by the daemon.
    public private(set) var authorizationState: ObsidianAuthorizationState?

    // MARK: - Operation guard

    /// True while any mutating operation (enable/disable/retry/selectVault) is
    /// in flight. Prevents concurrent submissions; the view must disable controls
    /// while this is true.
    public private(set) var isOperationInFlight = false

    // MARK: - Vault selection

    /// The outcome of the most recent vault selection operation.
    /// Preserved after a cancellation or denial so the view can surface the
    /// result without losing prior context. Requirement 1: both cancelled and
    /// denied outcomes are stored verbatim — the model does not silently discard
    /// non-success vault selection outcomes.
    public private(set) var lastVaultSelectionOutcome: VaultSelectionOutcome?

    // MARK: - Enable / disable

    /// The daemon's response to the most recent enable request.
    public private(set) var lastEnableOutcome: ObsidianEnableOutcome?

    /// The daemon's disablement report from the most recent disable request.
    ///
    /// Requirement 7 (verbatim): "Disabling synchronization does not claim that
    /// data was removed unless the daemon reports removal." The view MUST read
    /// this field to determine whether data was removed — it must not infer
    /// data removal from the status transition alone.
    public private(set) var lastDisablementReport: ObsidianDisablementReport?

    // MARK: - Retry

    /// The daemon's response to the most recent retry request.
    public private(set) var lastRetryOutcome: ObsidianRetryOutcome?

    // MARK: - Checkpoint (FIX 5 — CONTRACT-05 losslessness)

    /// FIX 5: The last successful synchronization checkpoint, stored independently
    /// of the current sync status.
    ///
    /// Previously, the checkpoint was only accessible from `.idle`'s associated
    /// value, dropping it silently during `.interrupted`, `.waiting`, `.paused`,
    /// and `.synchronizing` states. This property carries it across all statuses
    /// so the view can surface it regardless of what `syncStatus` currently holds.
    ///
    /// `nil` until the first `loadStatus()` call, or when no successful checkpoint
    /// exists. Set to `nil` only when the daemon confirms no prior checkpoint —
    /// never cleared optimistically by a status transition.
    public private(set) var lastCheckpoint: ObsidianCheckpoint?

    // MARK: - Port

    /// Injected port. Production: INTEGRATION-02 adapter.
    /// Tests: FakeObsidianPort (defined in CommunityBoundaryTests/Obsidian/).
    private let port: any ObsidianSyncPort

    // MARK: - Init

    /// - Parameter port: the injected port conformer. Never constructed here;
    ///   always supplied by the call site (no singleton, no global writer).
    public init(port: any ObsidianSyncPort) {
        self.port = port
    }

    // MARK: - Load

    /// Load the daemon's current sync status and last successful checkpoint.
    ///
    /// FIX 5: loads both `syncStatus` and `lastCheckpoint` in a single call to
    /// keep them temporally consistent. `lastCheckpoint` is carried independently
    /// of `syncStatus` so interrupted/waiting/paused/synchronizing states no longer
    /// drop the checkpoint (CONTRACT-05 losslessness).
    ///
    /// Fail-closed: if the daemon is unavailable, the port returns `.blocked`;
    /// the model stores that verbatim — it never substitutes `.idle`.
    /// Guards against concurrent load calls with `isLoadingStatus`.
    public func loadStatus() async {
        guard !isLoadingStatus else { return }
        isLoadingStatus = true
        defer { isLoadingStatus = false }
        syncStatus = await port.loadStatus()
        // FIX 5: load the checkpoint independently so it survives non-idle statuses.
        // The port returns nil when no checkpoint exists; the model stores that verbatim.
        lastCheckpoint = await port.loadLastCheckpoint()
    }

    /// Load the daemon's current vault authorization state.
    public func loadAuthorizationState() async {
        authorizationState = await port.loadAuthorizationState()
    }

    // MARK: - Vault selection (requirement 1)

    /// Initiate vault selection or replacement via the daemon.
    ///
    /// The outcome — selected, cancelled, or denied — is stored verbatim in
    /// `lastVaultSelectionOutcome`. On a successful selection, authorization
    /// state is reloaded so the view reflects the newly accepted vault
    /// immediately. A cancelled or denied selection does NOT reload auth state
    /// and does NOT advance any other model property.
    ///
    /// Fail-closed: a denied selection does NOT advance to authorized state.
    public func selectVault() async {
        guard !isOperationInFlight else { return }
        isOperationInFlight = true
        defer { isOperationInFlight = false }
        let outcome = await port.selectVault()
        lastVaultSelectionOutcome = outcome
        // Reload authorization only when the daemon confirmed a selection.
        if case .selected = outcome {
            authorizationState = await port.loadAuthorizationState()
        }
        // Cancelled and denied: auth state is not touched. The view reads
        // lastVaultSelectionOutcome to show the correct feedback.
    }

    // MARK: - Enable / disable (requirement 3)

    /// Request the daemon to enable synchronization.
    ///
    /// Fail-closed: `syncStatus` is updated ONLY when the daemon returns
    /// `.enabled`. A `.refused` or `.failed` outcome stores the non-success
    /// result in `lastEnableOutcome` and leaves all other state unchanged.
    public func enableSync() async {
        guard !isOperationInFlight else { return }
        isOperationInFlight = true
        defer { isOperationInFlight = false }
        let outcome = await port.enableSync()
        lastEnableOutcome = outcome
        // Reload status only when the daemon confirms enablement.
        // A refused/failed enable must NOT trigger a status reload that could
        // inadvertently surface a stale "starting" state.
        if case .enabled = outcome {
            syncStatus = await port.loadStatus()
        }
    }

    /// Request the daemon to disable synchronization.
    ///
    /// Requirement 7: the disablement report is stored verbatim. The view reads
    /// `lastDisablementReport` to know whether data was removed — the model
    /// does NOT infer or synthesize a data-removal claim from the status change.
    ///
    /// Status is always reloaded after a disable call so the model reflects
    /// whatever the daemon reports as the new state (e.g. idle after graceful
    /// stop, or blocked if the daemon went away).
    public func disableSync() async {
        guard !isOperationInFlight else { return }
        isOperationInFlight = true
        defer { isOperationInFlight = false }
        let report = await port.disableSync()
        lastDisablementReport = report
        // Reload status to reflect daemon's new state after disablement.
        syncStatus = await port.loadStatus()
    }

    // MARK: - Retry (requirement 6)

    /// Request the daemon to retry a retryable failure or interruption.
    ///
    /// Requirement 6: the UI is responsible for offering this control only when
    /// `isRetryAvailable` is true. If the daemon's state has changed since the
    /// UI loaded (window closed, condition no longer retryable), the port
    /// returns `.refused`, which is stored verbatim.
    ///
    /// Fail-closed: status is reloaded ONLY when the daemon returns `.restarted`.
    public func retrySync() async {
        guard !isOperationInFlight else { return }
        isOperationInFlight = true
        defer { isOperationInFlight = false }
        let outcome = await port.retrySync()
        lastRetryOutcome = outcome
        // Reload status when daemon confirms the retry has started.
        if case .restarted = outcome {
            syncStatus = await port.loadStatus()
        }
        // .refused and .failed: status is not mutated (the prior state is still
        // the daemon's last confirmed word).
    }

    // MARK: - Derived helpers (view-layer convenience; no business logic)

    /// Whether the retry control should be offered to the user.
    ///
    /// Requirement 6 (verbatim): "Retry is offered only for retryable conditions."
    /// This is a purely structural test against the current `syncStatus`; the model
    /// does not contact the daemon to evaluate retryability.
    public var isRetryAvailable: Bool {
        guard let status = syncStatus else { return false }
        switch status {
        case .interrupted(_, let retryable): return retryable
        case .failed(_, let retryable):      return retryable
        default:                              return false
        }
    }
}
