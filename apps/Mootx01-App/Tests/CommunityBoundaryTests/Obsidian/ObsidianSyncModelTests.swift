import Foundation
import MootCommunityUI
import Testing

// MARK: - ObsidianSyncModelTests  (APP-05 boundary tests)
//
// Covers all eight required observable behaviors from the Community 1.1
// APP-05 requirements. Every test exercises ObsidianSyncModel through
// FakeObsidianPort — no live estate, no gateway, no daemon.
//
// FALSE-SUCCESS DISCIPLINE: where the port returns a non-success outcome,
// the test asserts the model surfaces that exact outcome and NEVER the
// success variant. The model must not recompute or soften the daemon's word.
//
// UUID provenance: all test IDs use the synthetic namespace (ObsidianFakes).

@Suite("Obsidian sync model behavior")
@MainActor
struct ObsidianSyncModelTests {

    // MARK: - Behavior 1: Vault selection and replacement (requirement 1)

    @Test("selectVault surfaces selected outcome when daemon accepts")
    func vaultSelectionAccepted() async throws {
        let url = ObsidianFakes.vaultURL
        let fake = FakeObsidianPort(
            authState: .valid(vaultURL: url, displayName: "My Vault"),
            selectionOutcome: .selected(vaultURL: url, displayName: "My Vault")
        )
        let model = ObsidianSyncModel(port: fake)

        await model.selectVault()

        let outcome = try #require(model.lastVaultSelectionOutcome,
                                   "lastVaultSelectionOutcome must be set after selectVault")
        #expect(outcome == .selected(vaultURL: url, displayName: "My Vault"))
        let log = await fake.callLog
        #expect(log.contains("selectVault"))
    }

    @Test("selectVault surfaces cancellation without advancing auth state")
    func vaultSelectionCancelled() async throws {
        let fake = FakeObsidianPort(
            authState: .missing,
            selectionOutcome: .cancelled
        )
        let model = ObsidianSyncModel(port: fake)

        await model.selectVault()

        let outcome = try #require(model.lastVaultSelectionOutcome)
        #expect(outcome == .cancelled)
        let log = await fake.callLog
        #expect(log.contains("selectVault"))
        // On cancellation the model must NOT call loadAuthorizationState.
        #expect(!log.contains("loadAuthorizationState"),
                "Cancelled selection must not reload auth state")
    }

    @Test("selectVault preserves denial reason verbatim")
    func vaultSelectionDenied() async throws {
        let fake = FakeObsidianPort(
            selectionOutcome: .denied(reason: "path-not-authorized")
        )
        let model = ObsidianSyncModel(port: fake)

        await model.selectVault()

        let outcome = try #require(model.lastVaultSelectionOutcome)
        #expect(outcome == .denied(reason: "path-not-authorized"))
    }

    @Test("selectVault replacement: outcome reflects newly selected vault")
    func vaultReplacement() async throws {
        let replacementURL = ObsidianFakes.replacementVaultURL
        let fake = FakeObsidianPort(
            authState: .valid(vaultURL: ObsidianFakes.vaultURL, displayName: "Old Vault"),
            selectionOutcome: .selected(vaultURL: replacementURL, displayName: "New Vault")
        )
        let model = ObsidianSyncModel(port: fake)
        await model.loadAuthorizationState()

        await model.selectVault()

        let outcome = try #require(model.lastVaultSelectionOutcome)
        if case .selected(let url, let name) = outcome {
            #expect(url == replacementURL)
            #expect(name == "New Vault")
        } else {
            Issue.record("Expected .selected outcome for vault replacement, got \(outcome)")
        }
    }

    // MARK: - Behavior 2: Authorization display (requirement 2)

    @Test("loadAuthorizationState reflects valid authorization")
    func authorizationValid() async throws {
        let url = ObsidianFakes.vaultURL
        let fake = FakeObsidianPort(
            authState: .valid(vaultURL: url, displayName: "Synced Vault")
        )
        let model = ObsidianSyncModel(port: fake)

        await model.loadAuthorizationState()

        let state = try #require(model.authorizationState)
        #expect(state == .valid(vaultURL: url, displayName: "Synced Vault"))
    }

    @Test("loadAuthorizationState reflects missing authorization")
    func authorizationMissing() async throws {
        let fake = FakeObsidianPort(authState: .missing)
        let model = ObsidianSyncModel(port: fake)

        await model.loadAuthorizationState()

        #expect(model.authorizationState == .missing)
    }

    @Test("loadAuthorizationState reflects needs-renewal with reason")
    func authorizationNeedsRenewal() async throws {
        let url = ObsidianFakes.vaultURL
        let fake = FakeObsidianPort(
            authState: .needsRenewal(
                vaultURL: url,
                displayName: "Revoked Vault",
                reason: "access-revoked-by-user"
            )
        )
        let model = ObsidianSyncModel(port: fake)

        await model.loadAuthorizationState()

        let state = try #require(model.authorizationState)
        #expect(state == .needsRenewal(
            vaultURL: url,
            displayName: "Revoked Vault",
            reason: "access-revoked-by-user"
        ))
    }

    // MARK: - Behavior 3: Enable and disable (requirement 3)

    @Test("enableSync records enabled outcome and reloads status")
    func enableSyncRecordsEnabled() async throws {
        let fake = FakeObsidianPort(
            status: .idle(checkpoint: nil),
            enableOutcome: .enabled,
            statusAfterEnable: .starting
        )
        let model = ObsidianSyncModel(port: fake)

        await model.enableSync()

        #expect(model.lastEnableOutcome == .enabled)
        // Status must be reloaded from the daemon after enablement confirms.
        #expect(model.syncStatus == .starting)
        let log = await fake.callLog
        #expect(log.contains("enableSync"))
        #expect(log.contains("loadStatus"),
                "Model must reload status after the daemon confirms enable")
    }

    @Test("enableSync during blocked state surfaces refusal — never success")
    func enableSyncBlockedStateRefused() async throws {
        let fake = FakeObsidianPort(
            status: .blocked(reason: "daemon-offline"),
            enableOutcome: .refused(reason: "daemon-not-reachable")
        )
        let model = ObsidianSyncModel(port: fake)
        await model.loadStatus()

        await model.enableSync()

        let outcome = try #require(model.lastEnableOutcome)
        if case .refused(let r) = outcome {
            #expect(r == "daemon-not-reachable")
        } else {
            Issue.record("Expected .refused, got \(outcome)")
        }
        // Structural guard: must NOT have advanced to .enabled.
        if case .enabled = model.lastEnableOutcome {
            Issue.record("Enable during blocked state must never surface as .enabled")
        }
    }

    @Test("disableSync records disabledOnly report from daemon")
    func disableSyncOnly() async throws {
        let fake = FakeObsidianPort(
            status: .idle(checkpoint: nil),
            disablementReport: .disabledOnly
        )
        let model = ObsidianSyncModel(port: fake)

        await model.disableSync()

        #expect(model.lastDisablementReport == .disabledOnly)
        let log = await fake.callLog
        #expect(log.contains("disableSync"))
    }

    // MARK: - Behavior 4: Status distinguishes all nine states (requirement 4)

    @Test("loadStatus reflects starting")
    func statusStarting() async {
        let model = ObsidianSyncModel(port: FakeObsidianPort(status: .starting))
        await model.loadStatus()
        #expect(model.syncStatus == .starting)
    }

    @Test("loadStatus reflects scanning")
    func statusScanning() async {
        let model = ObsidianSyncModel(port: FakeObsidianPort(status: .scanning))
        await model.loadStatus()
        #expect(model.syncStatus == .scanning)
    }

    @Test("loadStatus reflects synchronizing with progress")
    func statusSynchronizing() async {
        let progress = ObsidianFakes.progress(pending: 5, total: 20)
        let model = ObsidianSyncModel(
            port: FakeObsidianPort(status: .synchronizing(progress: progress))
        )
        await model.loadStatus()
        #expect(model.syncStatus == .synchronizing(progress: progress))
    }

    @Test("loadStatus reflects idle with checkpoint")
    func statusIdleWithCheckpoint() async {
        let cp = ObsidianFakes.checkpoint()
        let model = ObsidianSyncModel(
            port: FakeObsidianPort(status: .idle(checkpoint: cp))
        )
        await model.loadStatus()
        #expect(model.syncStatus == .idle(checkpoint: cp))
    }

    @Test("loadStatus reflects waiting with scheduled date")
    func statusWaiting() async {
        let model = ObsidianSyncModel(
            port: FakeObsidianPort(status: .waiting(until: ObsidianFakes.epoch))
        )
        await model.loadStatus()
        #expect(model.syncStatus == .waiting(until: ObsidianFakes.epoch))
    }

    @Test("loadStatus reflects paused")
    func statusPaused() async {
        let model = ObsidianSyncModel(port: FakeObsidianPort(status: .paused))
        await model.loadStatus()
        #expect(model.syncStatus == .paused)
    }

    @Test("loadStatus reflects interrupted with retryable flag")
    func statusInterrupted() async {
        let model = ObsidianSyncModel(
            port: FakeObsidianPort(
                status: .interrupted(reason: "network-lost", retryable: true)
            )
        )
        await model.loadStatus()
        #expect(model.syncStatus == .interrupted(reason: "network-lost", retryable: true))
    }

    @Test("loadStatus reflects blocked — not idle (requirement 8)")
    func statusBlocked() async {
        let model = ObsidianSyncModel(
            port: FakeObsidianPort(status: .blocked(reason: "vault-inaccessible"))
        )
        await model.loadStatus()
        #expect(model.syncStatus == .blocked(reason: "vault-inaccessible"))
        // Structural guard: blocked must NOT match idle.
        if case .idle = model.syncStatus {
            Issue.record("Blocked status must never collapse to idle (requirement 8)")
        }
    }

    @Test("loadStatus reflects failed with terminal flag")
    func statusFailed() async {
        let model = ObsidianSyncModel(
            port: FakeObsidianPort(
                status: .failed(reason: "corrupt-vault", retryable: false)
            )
        )
        await model.loadStatus()
        #expect(model.syncStatus == .failed(reason: "corrupt-vault", retryable: false))
    }

    // MARK: - Behavior 5: Checkpoint and outstanding work (requirement 5)

    @Test("idle status carries daemon checkpoint with record count")
    func idleCheckpointRecordCount() async throws {
        let cp = ObsidianFakes.checkpoint(timestamp: ObsidianFakes.epoch, recordCount: 100)
        let model = ObsidianSyncModel(
            port: FakeObsidianPort(status: .idle(checkpoint: cp))
        )
        await model.loadStatus()
        if case .idle(let checkpoint) = model.syncStatus {
            let resolved = try #require(checkpoint,
                                        "idle status must carry the daemon's checkpoint")
            #expect(resolved.recordCount == 100)
            #expect(resolved.timestamp == ObsidianFakes.epoch)
        } else {
            Issue.record("Expected .idle status with checkpoint")
        }
    }

    @Test("synchronizing status carries daemon pending work count")
    func synchronizingPendingWork() async throws {
        let prog = ObsidianFakes.progress(pending: 17, total: 50)
        let model = ObsidianSyncModel(
            port: FakeObsidianPort(status: .synchronizing(progress: prog))
        )
        await model.loadStatus()
        if case .synchronizing(let progress) = model.syncStatus {
            let resolved = try #require(progress,
                                        "synchronizing status must carry daemon progress")
            #expect(resolved.pendingCount == 17)
            #expect(resolved.totalCount == 50)
        } else {
            Issue.record("Expected .synchronizing status with progress")
        }
    }

    // MARK: - Behavior 6: Retry offered only for retryable conditions (requirement 6)

    @Test("isRetryAvailable is true after loading interrupted+retryable status")
    func retryAvailableForRetryableInterruption() async {
        let model = ObsidianSyncModel(
            port: FakeObsidianPort(
                status: .interrupted(reason: "timeout", retryable: true)
            )
        )
        await model.loadStatus()
        #expect(model.isRetryAvailable == true)
    }

    @Test("isRetryAvailable is false for non-retryable interruption")
    func retryNotAvailableForNonRetryableInterruption() async {
        let model = ObsidianSyncModel(
            port: FakeObsidianPort(
                status: .interrupted(reason: "auth-failed", retryable: false)
            )
        )
        await model.loadStatus()
        #expect(model.isRetryAvailable == false)
    }

    @Test("isRetryAvailable is false for healthy idle")
    func retryNotAvailableForIdle() async {
        let model = ObsidianSyncModel(
            port: FakeObsidianPort(status: .idle(checkpoint: nil))
        )
        await model.loadStatus()
        #expect(model.isRetryAvailable == false)
    }

    @Test("isRetryAvailable is true for retryable failure")
    func retryAvailableForRetryableFailure() async {
        let model = ObsidianSyncModel(
            port: FakeObsidianPort(
                status: .failed(reason: "timeout", retryable: true)
            )
        )
        await model.loadStatus()
        #expect(model.isRetryAvailable == true)
    }

    @Test("isRetryAvailable is false for terminal failure")
    func retryNotAvailableForTerminalFailure() async {
        let model = ObsidianSyncModel(
            port: FakeObsidianPort(
                status: .failed(reason: "fatal", retryable: false)
            )
        )
        await model.loadStatus()
        #expect(model.isRetryAvailable == false)
    }

    @Test("retrySync records restarted outcome when daemon accepts")
    func retrySyncAccepted() async throws {
        let fake = FakeObsidianPort(
            status: .interrupted(reason: "network-lost", retryable: true),
            retryOutcome: .restarted
        )
        let model = ObsidianSyncModel(port: fake)

        await model.retrySync()

        #expect(model.lastRetryOutcome == .restarted)
        let log = await fake.callLog
        #expect(log.contains("retrySync"))
    }

    @Test("retrySync records refused outcome verbatim when daemon refuses")
    func retrySyncRefused() async throws {
        let fake = FakeObsidianPort(
            retryOutcome: .refused(reason: "not-retryable")
        )
        let model = ObsidianSyncModel(port: fake)

        await model.retrySync()

        let outcome = try #require(model.lastRetryOutcome)
        if case .refused(let r) = outcome {
            #expect(r == "not-retryable")
        } else {
            Issue.record("Expected .refused retry outcome, got \(outcome)")
        }
    }

    // MARK: - Behavior 7: Disable does not claim data removed unless daemon reports it (requirement 7)

    @Test("disabledOnly report does not imply data removal")
    func disableOnlyReportAccurate() async throws {
        let fake = FakeObsidianPort(disablementReport: .disabledOnly)
        let model = ObsidianSyncModel(port: fake)

        await model.disableSync()

        let report = try #require(model.lastDisablementReport)
        #expect(report == .disabledOnly,
                "Must not claim data removal when daemon returned disabledOnly")
        // Structural guard: must NOT be disabledAndRemoved.
        if case .disabledAndRemoved = report {
            Issue.record("Model claimed data removed when daemon did not report removal")
        }
    }

    @Test("disabledAndRemoved report is surfaced only when daemon explicitly reports removal")
    func disableAndRemovedReportFromDaemon() async throws {
        let fake = FakeObsidianPort(disablementReport: .disabledAndRemoved)
        let model = ObsidianSyncModel(port: fake)

        await model.disableSync()

        let report = try #require(model.lastDisablementReport)
        #expect(report == .disabledAndRemoved)
    }

    @Test("settings remain truthful: disablement report persists across status reload")
    func settingsTruthfulAfterStatusReload() async throws {
        let fake = FakeObsidianPort(
            status: .idle(checkpoint: nil),
            disablementReport: .disabledOnly
        )
        let model = ObsidianSyncModel(port: fake)

        await model.disableSync()
        // Simulate reconnect / status refresh.
        await model.loadStatus()

        // The disablement report must be preserved — not cleared on reload.
        let report = try #require(model.lastDisablementReport)
        #expect(report == .disabledOnly,
                "Disablement report must survive a status reload (state persistence)")
    }

    // MARK: - Behavior 8: Unavailable daemon or inaccessible vault → blocked, not idle (requirement 8)

    @Test("blocked status is structurally distinct from idle")
    func blockedNotIdle() async {
        let model = ObsidianSyncModel(
            port: FakeObsidianPort(status: .blocked(reason: "daemon-unavailable"))
        )
        await model.loadStatus()

        #expect(model.syncStatus == .blocked(reason: "daemon-unavailable"))
        if case .idle = model.syncStatus {
            Issue.record("Blocked must never be rendered as idle (requirement 8)")
        }
    }

    @Test("inaccessible vault yields blocked with reason, not idle")
    func inaccessibleVaultIsBlocked() async {
        let model = ObsidianSyncModel(
            port: FakeObsidianPort(status: .blocked(reason: "vault-path-inaccessible"))
        )
        await model.loadStatus()

        if case .blocked(let reason) = model.syncStatus {
            #expect(reason == "vault-path-inaccessible")
        } else {
            Issue.record(
                "Inaccessible vault must yield .blocked, got \(String(describing: model.syncStatus))"
            )
        }
    }

    // MARK: - FIX 1: Non-success outcome surfacing

    // The views cannot be directly tested in this harness (no SwiftUI runtime).
    // These tests verify the model exposes outcome fields in the form the views
    // consume and that user-visible reason strings are derivable (non-nil).

    @Test("FIX 1: vault selection denial exposed in lastVaultSelectionOutcome")
    func vaultSelectionDenialExposedForView() async throws {
        let fake = FakeObsidianPort(
            selectionOutcome: .denied(reason: "path-not-authorized")
        )
        let model = ObsidianSyncModel(port: fake)

        await model.selectVault()

        let outcome = try #require(model.lastVaultSelectionOutcome)
        if case .denied(let reason) = outcome {
            // The view interpolates this reason into String(localized:) — must be non-nil.
            #expect(!reason.isEmpty, "denial reason must be non-empty for the view to surface")
            #expect(reason == "path-not-authorized")
        } else {
            Issue.record("Expected .denied vault selection outcome, got \(outcome)")
        }
    }

    @Test("FIX 1: enable refusal exposed in lastEnableOutcome with reason")
    func enableRefusalExposedForView() async throws {
        let fake = FakeObsidianPort(
            status: .blocked(reason: "daemon-offline"),
            enableOutcome: .refused(reason: "daemon-not-reachable")
        )
        let model = ObsidianSyncModel(port: fake)
        await model.loadStatus()

        await model.enableSync()

        let outcome = try #require(model.lastEnableOutcome)
        if case .refused(let reason) = outcome {
            #expect(!reason.isEmpty)
            #expect(reason == "daemon-not-reachable")
        } else {
            Issue.record("Expected .refused enable outcome, got \(outcome)")
        }
        // Structural guard: status must not advance on refusal.
        #expect(model.syncStatus == .blocked(reason: "daemon-offline"))
    }

    @Test("FIX 1: enable failure exposed in lastEnableOutcome with reason")
    func enableFailureExposedForView() async throws {
        let fake = FakeObsidianPort(
            enableOutcome: .failed(reason: "system-error")
        )
        let model = ObsidianSyncModel(port: fake)

        await model.enableSync()

        let outcome = try #require(model.lastEnableOutcome)
        if case .failed(let reason) = outcome {
            #expect(!reason.isEmpty)
            #expect(reason == "system-error")
        } else {
            Issue.record("Expected .failed enable outcome, got \(outcome)")
        }
    }

    @Test("FIX 1: retry refusal exposed in lastRetryOutcome with reason")
    func retryRefusalExposedForView() async throws {
        let fake = FakeObsidianPort(
            retryOutcome: .refused(reason: "not-retryable")
        )
        let model = ObsidianSyncModel(port: fake)

        await model.retrySync()

        let outcome = try #require(model.lastRetryOutcome)
        if case .refused(let reason) = outcome {
            #expect(!reason.isEmpty)
            #expect(reason == "not-retryable")
        } else {
            Issue.record("Expected .refused retry outcome, got \(outcome)")
        }
    }

    @Test("FIX 1: retry failure exposed in lastRetryOutcome with reason")
    func retryFailureExposedForView() async throws {
        let fake = FakeObsidianPort(
            retryOutcome: .failed(reason: "connection-lost")
        )
        let model = ObsidianSyncModel(port: fake)

        await model.retrySync()

        let outcome = try #require(model.lastRetryOutcome)
        if case .failed(let reason) = outcome {
            #expect(!reason.isEmpty)
            #expect(reason == "connection-lost")
        } else {
            Issue.record("Expected .failed retry outcome, got \(outcome)")
        }
    }

    // MARK: - FIX 5: CONTRACT-05 losslessness — checkpoint survives non-idle statuses

    // RED/GREEN evidence: before the port change (FIX 5), FakeObsidianPort had no
    // loadLastCheckpoint() method and ObsidianSyncModel had no lastCheckpoint property.
    // These tests would have failed to compile, constituting the RED state. After the
    // fix, they compile and pass (GREEN).

    @Test("FIX 5: checkpoint survives .interrupted status — lastCheckpoint is non-nil")
    func checkpointSurvivesInterruptedStatus() async throws {
        // This is the primary fixture test for FIX 5. Before the fix, a model in
        // .interrupted state had no way to surface the last checkpoint — the only
        // checkpoint path was through .idle's associated value. This test verifies
        // the checkpoint is preserved independently of status.
        let cp = ObsidianFakes.checkpoint(timestamp: ObsidianFakes.epoch, recordCount: 77)
        let fake = FakeObsidianPort(
            status: .interrupted(reason: "network-lost", retryable: true),
            lastCheckpoint: cp
        )
        let model = ObsidianSyncModel(port: fake)

        await model.loadStatus()

        // Status must be .interrupted — the checkpoint must not have changed it.
        #expect(model.syncStatus == .interrupted(reason: "network-lost", retryable: true))
        // lastCheckpoint must be non-nil even though status is not .idle.
        let checkpoint = try #require(
            model.lastCheckpoint,
            "lastCheckpoint must be non-nil when port returns a checkpoint and status is .interrupted"
        )
        #expect(checkpoint.recordCount == 77)
        #expect(checkpoint.timestamp == ObsidianFakes.epoch)
        let log = await fake.callLog
        #expect(log.contains("loadLastCheckpoint"),
                "port.loadLastCheckpoint() must be called during loadStatus()")
    }

    @Test("FIX 5: checkpoint survives .waiting status")
    func checkpointSurvivesWaitingStatus() async throws {
        let cp = ObsidianFakes.checkpoint(recordCount: 55)
        let fake = FakeObsidianPort(
            status: .waiting(until: ObsidianFakes.epoch),
            lastCheckpoint: cp
        )
        let model = ObsidianSyncModel(port: fake)

        await model.loadStatus()

        #expect(model.syncStatus == .waiting(until: ObsidianFakes.epoch))
        let checkpoint = try #require(model.lastCheckpoint)
        #expect(checkpoint.recordCount == 55)
    }

    @Test("FIX 5: checkpoint survives .paused status")
    func checkpointSurvivesPausedStatus() async throws {
        let cp = ObsidianFakes.checkpoint(recordCount: 100)
        let fake = FakeObsidianPort(
            status: .paused,
            lastCheckpoint: cp
        )
        let model = ObsidianSyncModel(port: fake)

        await model.loadStatus()

        #expect(model.syncStatus == .paused)
        let checkpoint = try #require(model.lastCheckpoint)
        #expect(checkpoint.recordCount == 100)
    }

    @Test("FIX 5: checkpoint survives .synchronizing status")
    func checkpointSurvivestSynchronizingStatus() async throws {
        let cp = ObsidianFakes.checkpoint(recordCount: 30)
        let fake = FakeObsidianPort(
            status: .synchronizing(progress: ObsidianFakes.progress(pending: 5, total: 50)),
            lastCheckpoint: cp
        )
        let model = ObsidianSyncModel(port: fake)

        await model.loadStatus()

        if case .synchronizing = model.syncStatus {} else {
            Issue.record("Expected .synchronizing status")
        }
        let checkpoint = try #require(model.lastCheckpoint)
        #expect(checkpoint.recordCount == 30)
    }

    @Test("FIX 5: lastCheckpoint is nil when port returns nil (first-run case)")
    func checkpointNilOnFirstRun() async {
        let fake = FakeObsidianPort(
            status: .idle(checkpoint: nil),
            lastCheckpoint: nil  // Explicit nil — no prior checkpoint exists.
        )
        let model = ObsidianSyncModel(port: fake)

        await model.loadStatus()

        // nil is the honest state when no checkpoint exists — the model must not
        // synthesise a checkpoint.
        #expect(model.lastCheckpoint == nil,
                "lastCheckpoint must be nil when port returns nil")
    }

    @Test("revoked access surfaces needsRenewal in authorization state")
    func revokedAccessNeedsRenewal() async throws {
        let url = ObsidianFakes.vaultURL
        let fake = FakeObsidianPort(
            status: .blocked(reason: "authorization-revoked"),
            authState: .needsRenewal(
                vaultURL: url,
                displayName: "Revoked Vault",
                reason: "authorization-revoked"
            )
        )
        let model = ObsidianSyncModel(port: fake)

        await model.loadStatus()
        await model.loadAuthorizationState()

        // Both states must reflect the revoked condition accurately.
        #expect(model.syncStatus == .blocked(reason: "authorization-revoked"))
        let authState = try #require(model.authorizationState)
        if case .needsRenewal(_, _, let reason) = authState {
            #expect(reason == "authorization-revoked")
        } else {
            Issue.record("Expected .needsRenewal for revoked authorization")
        }
    }
}
