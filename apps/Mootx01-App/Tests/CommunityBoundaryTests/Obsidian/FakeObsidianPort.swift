import Foundation
import MootCommunityUI

// MARK: - FakeObsidianPort  (APP-05 boundary tests)
//
// Contract-compatible fake daemon conformer for ObsidianSyncPort.
// Lives in the test tree; production code never imports or instantiates this.
//
// The real gateway adapter (INTEGRATION-02) substitutes at the same
// ObsidianSyncPort abstraction in production.
//
// Design: actor so Swift 6 strict concurrency is satisfied without
// @unchecked Sendable. Tests configure via async setters before calling
// model methods; call-log reads are awaited after model operations.
//
// UUID provenance: all synthetic IDs in this file use the reserved
// synthetic namespace (first group = one hex character repeated eight times,
// e.g. AAAAAAAA-…). No real estate ID can collide with these.

actor FakeObsidianPort: ObsidianSyncPort {

    // MARK: - Configurable results (set per test via setters)

    private var _status: ObsidianSyncStatus
    private var _authState: ObsidianAuthorizationState
    private var _selectionOutcome: VaultSelectionOutcome
    private var _enableOutcome: ObsidianEnableOutcome
    private var _disablementReport: ObsidianDisablementReport
    private var _retryOutcome: ObsidianRetryOutcome
    /// Status returned by subsequent `loadStatus()` calls after a successful enable.
    /// Simulates the daemon state change that follows enablement.
    private var _statusAfterEnable: ObsidianSyncStatus?
    /// FIX 5: last successful checkpoint returned by loadLastCheckpoint(), independent
    /// of the current sync status. nil simulates a first-run (no prior checkpoint).
    private var _lastCheckpoint: ObsidianCheckpoint?

    // MARK: - Call log

    private(set) var callLog: [String] = []

    // MARK: - Init

    init(
        status: ObsidianSyncStatus = .idle(checkpoint: nil),
        authState: ObsidianAuthorizationState = .missing,
        selectionOutcome: VaultSelectionOutcome = .cancelled,
        enableOutcome: ObsidianEnableOutcome = .enabled,
        disablementReport: ObsidianDisablementReport = .disabledOnly,
        retryOutcome: ObsidianRetryOutcome = .restarted,
        statusAfterEnable: ObsidianSyncStatus? = nil,
        lastCheckpoint: ObsidianCheckpoint? = nil
    ) {
        _status = status
        _authState = authState
        _selectionOutcome = selectionOutcome
        _enableOutcome = enableOutcome
        _disablementReport = disablementReport
        _retryOutcome = retryOutcome
        _statusAfterEnable = statusAfterEnable
        _lastCheckpoint = lastCheckpoint
    }

    // MARK: - Setters (awaitable from @MainActor tests)

    func setStatus(_ s: ObsidianSyncStatus) { _status = s }
    func setAuthState(_ s: ObsidianAuthorizationState) { _authState = s }
    func setSelectionOutcome(_ o: VaultSelectionOutcome) { _selectionOutcome = o }
    func setEnableOutcome(_ o: ObsidianEnableOutcome) { _enableOutcome = o }
    func setDisablementReport(_ r: ObsidianDisablementReport) { _disablementReport = r }
    func setRetryOutcome(_ o: ObsidianRetryOutcome) { _retryOutcome = o }
    func setStatusAfterEnable(_ s: ObsidianSyncStatus?) { _statusAfterEnable = s }
    func setLastCheckpoint(_ cp: ObsidianCheckpoint?) { _lastCheckpoint = cp }

    // MARK: - ObsidianSyncPort

    func loadStatus() async -> ObsidianSyncStatus {
        callLog.append("loadStatus")
        return _status
    }

    func loadLastCheckpoint() async -> ObsidianCheckpoint? {
        callLog.append("loadLastCheckpoint")
        return _lastCheckpoint
    }

    func loadAuthorizationState() async -> ObsidianAuthorizationState {
        callLog.append("loadAuthorizationState")
        return _authState
    }

    func selectVault() async -> VaultSelectionOutcome {
        callLog.append("selectVault")
        return _selectionOutcome
    }

    func enableSync() async -> ObsidianEnableOutcome {
        callLog.append("enableSync")
        let outcome = _enableOutcome
        // When the daemon confirms enablement, simulate state change so that the
        // subsequent loadStatus() call the model issues returns the new status.
        if case .enabled = outcome, let next = _statusAfterEnable {
            _status = next
        }
        return outcome
    }

    func disableSync() async -> ObsidianDisablementReport {
        callLog.append("disableSync")
        return _disablementReport
    }

    func retrySync() async -> ObsidianRetryOutcome {
        callLog.append("retrySync")
        return _retryOutcome
    }
}

// MARK: - ObsidianFakes — synthetic test data factory
//
// All URLs use synthetic paths that cannot collide with real vault locations.
// All dates use the fixed epoch for deterministic comparisons.

enum ObsidianFakes {

    /// A fixed epoch for deterministic date comparisons in tests.
    static let epoch = Date(timeIntervalSinceReferenceDate: 0)

    /// Synthetic vault URL — never a real filesystem path.
    static let vaultURL = URL(string: "file:///synthetic/vault/AAAAAAAA-0001")!

    /// Synthetic replacement vault URL for replacement-selection tests.
    static let replacementVaultURL = URL(string: "file:///synthetic/vault/AAAAAAAA-0002")!

    static func checkpoint(
        timestamp: Date = epoch,
        recordCount: Int = 42
    ) -> ObsidianCheckpoint {
        ObsidianCheckpoint(timestamp: timestamp, recordCount: recordCount)
    }

    static func progress(
        pending: Int = 10,
        total: Int = 50
    ) -> ObsidianSyncProgress {
        ObsidianSyncProgress(pendingCount: pending, totalCount: total)
    }
}
