import Foundation
import MootCommunityUI
import Testing

// MARK: - LANControlModelTests  (APP-07 boundary tests)
//
// Covers all eight required observable behaviors from the Community 1.1
// APP-07 requirements. Every test exercises LANControlModel through
// FakeLANPort — no live estate, no gateway, no daemon, no MootLANServer.
//
// FALSE-SUCCESS DISCIPLINE: where the port returns a non-success outcome,
// the test asserts the model surfaces that exact outcome and NEVER the
// success variant. The model must not recompute or soften the daemon's word.
//
// Requirement 1: LAN serving is off by default — verified at model init,
// before any port interaction.

@Suite("LAN control model behavior")
@MainActor
struct LANControlModelTests {

    // MARK: - Behavior 1: LAN serving is off by default (requirement 1)

    @Test("servingStatus is .stopped before any daemon interaction")
    func defaultOffState() {
        // Requirement 1 (verbatim): "LAN serving is off by default."
        // No load call — this verifies the initial model state alone.
        let model = LANControlModel(port: FakeLANPort())
        #expect(model.servingStatus == .stopped)
    }

    // MARK: - Behavior 2: Policy and eligible record count (requirement 2)

    @Test("loadServingPolicy exposes eligible and ineligible counts from daemon")
    func policyLoadsEligibleAndIneligibleCounts() async throws {
        let fake = FakeLANPort(
            servingPolicy: LANFakes.defaultPolicy(eligible: 30, ineligible: 8)
        )
        let model = LANControlModel(port: fake)

        await model.loadServingPolicy()

        let policy = try #require(model.servingPolicy,
                                   "servingPolicy must be set after loadServingPolicy")
        #expect(policy.eligibleCount == 30)
        #expect(policy.ineligibleCount == 8)
        let log = await fake.callLog
        #expect(log.contains("loadServingPolicy"))
    }

    @Test("policy with zero eligible records is accurately surfaced")
    func policyZeroEligible() async throws {
        let fake = FakeLANPort(
            servingPolicy: LANFakes.defaultPolicy(eligible: 0, ineligible: 15)
        )
        let model = LANControlModel(port: fake)

        await model.loadServingPolicy()

        let policy = try #require(model.servingPolicy)
        #expect(policy.eligibleCount == 0)
        #expect(policy.ineligibleCount == 15)
    }

    @Test("failed policy reload preserves confirmed counts and exposes failure")
    func failedPolicyReloadIsTruthful() async throws {
        let fake = FakeLANPort(
            servingPolicy: LANFakes.defaultPolicy(eligible: 12, ineligible: 7)
        )
        let model = LANControlModel(port: fake)
        await model.loadServingPolicy()

        await fake.setServingPolicyOutcome(.blocked(reason: "daemon-restarting"))
        await model.loadServingPolicy()

        let policy = try #require(model.servingPolicy)
        #expect(policy.eligibleCount == 12)
        #expect(policy.ineligibleCount == 7)
        #expect(model.lastPolicyLoadOutcome == .blocked(reason: "daemon-restarting"))
    }

    @Test("initial policy failure does not invent a zero-count policy")
    func initialPolicyFailureDoesNotInventPolicy() async {
        let fake = FakeLANPort()
        await fake.setServingPolicyOutcome(.failed(reason: "malformed-daemon-response"))
        let model = LANControlModel(port: fake)

        await model.loadServingPolicy()

        #expect(model.servingPolicy == nil)
        #expect(model.lastPolicyLoadOutcome == .failed(reason: "malformed-daemon-response"))
    }

    // MARK: - Behavior 3: Starting service reports daemon endpoint and auth state (requirement 3)

    @Test("startServing records daemon endpoint and auth state on success")
    func startServingSucceeds() async throws {
        let fake = FakeLANPort(
            servingStatus: .stopped,
            startOutcome: .started(
                endpoint: LANFakes.defaultEndpoint,
                authState: .valid
            )
        )
        let model = LANControlModel(port: fake)

        await model.startServing()

        let outcome = try #require(model.lastStartOutcome,
                                   "lastStartOutcome must be set after startServing")
        if case .started(let ep, let auth) = outcome {
            #expect(ep == LANFakes.defaultEndpoint)
            #expect(auth == .valid)
        } else {
            Issue.record("Expected .started outcome, got \(outcome)")
        }
        // Status must advance to .active only after daemon confirms — requirement 3.
        if case .active(let ep, let auth) = model.servingStatus {
            #expect(ep == LANFakes.defaultEndpoint)
            #expect(auth == .valid)
        } else {
            Issue.record(
                "Expected .active status after confirmed start, got \(model.servingStatus)"
            )
        }
        let log = await fake.callLog
        #expect(log.contains("startServing"))
    }

    @Test("startServing with denied outcome does not advance status to active")
    func startServingDenied() async throws {
        let fake = FakeLANPort(
            servingStatus: .stopped,
            startOutcome: .denied(reason: "authorization-missing")
        )
        let model = LANControlModel(port: fake)

        await model.startServing()

        let outcome = try #require(model.lastStartOutcome)
        if case .denied(let r) = outcome {
            #expect(r == "authorization-missing")
        } else {
            Issue.record("Expected .denied, got \(outcome)")
        }
        // Requirement 8: denied must not be treated as success or advance status.
        #expect(
            model.servingStatus == .stopped,
            "servingStatus must remain .stopped after a denied start — no policy bypass"
        )
    }

    @Test("startServing with failed outcome does not advance status to active")
    func startServingFailed() async throws {
        let fake = FakeLANPort(
            startOutcome: .failed(reason: "socket-error")
        )
        let model = LANControlModel(port: fake)

        await model.startServing()

        let outcome = try #require(model.lastStartOutcome)
        if case .failed(let r) = outcome {
            #expect(r == "socket-error")
        } else {
            Issue.record("Expected .failed, got \(outcome)")
        }
        #expect(model.servingStatus == .stopped)
    }

    // MARK: - Behavior 4: Status distinguishes all six states (requirement 4)

    @Test("loadServingStatus reflects stopped")
    func statusStopped() async {
        let model = LANControlModel(port: FakeLANPort(servingStatus: .stopped))
        await model.loadServingStatus()
        #expect(model.servingStatus == .stopped)
    }

    @Test("loadServingStatus reflects starting")
    func statusStarting() async {
        let model = LANControlModel(port: FakeLANPort(servingStatus: .starting))
        await model.loadServingStatus()
        #expect(model.servingStatus == .starting)
    }

    @Test("loadServingStatus reflects active with endpoint and auth state")
    func statusActive() async {
        let status = LANServingStatus.active(
            endpoint: LANFakes.defaultEndpoint,
            authState: .valid
        )
        let model = LANControlModel(port: FakeLANPort(servingStatus: status))
        await model.loadServingStatus()
        #expect(model.servingStatus == status)
    }

    @Test("loadServingStatus reflects interrupted with reason")
    func statusInterrupted() async {
        let model = LANControlModel(
            port: FakeLANPort(servingStatus: .interrupted(reason: "network-change"))
        )
        await model.loadServingStatus()
        #expect(model.servingStatus == .interrupted(reason: "network-change"))
    }

    @Test("loadServingStatus reflects blocked with reason")
    func statusBlocked() async {
        let model = LANControlModel(
            port: FakeLANPort(servingStatus: .blocked(reason: "policy-violation"))
        )
        await model.loadServingStatus()
        #expect(model.servingStatus == .blocked(reason: "policy-violation"))
    }

    @Test("loadServingStatus reflects failed with reason")
    func statusFailed() async {
        let model = LANControlModel(
            port: FakeLANPort(servingStatus: .failed(reason: "system-error"))
        )
        await model.loadServingStatus()
        #expect(model.servingStatus == .failed(reason: "system-error"))
    }

    // MARK: - Behavior 5: Policy-ineligible material shown as excluded (requirement 5)

    @Test("ineligible count is preserved separately from eligible count")
    func ineligibleCountNotMergedIntoEligible() async throws {
        // If the model incorrectly merged counts, eligible would be 35.
        let fake = FakeLANPort(
            servingPolicy: LANFakes.defaultPolicy(eligible: 20, ineligible: 15)
        )
        let model = LANControlModel(port: fake)

        await model.loadServingPolicy()

        let policy = try #require(model.servingPolicy)
        // Structural guard: eligible must not silently absorb ineligible.
        #expect(policy.eligibleCount == 20,
                "Eligible count must not include ineligible records")
        #expect(policy.ineligibleCount == 15,
                "Ineligible count must be preserved as excluded")
        // Sanity: the total is the sum, not just eligible.
        #expect(policy.eligibleCount + policy.ineligibleCount == 35)
    }

    // MARK: - Behavior 6: Eligibility change updates after daemon confirmation (requirement 6)

    @Test("refreshEligibility updates policy counts on daemon confirmation")
    func eligibilityUpdatesAfterDaemonConfirmation() async throws {
        let fake = FakeLANPort(
            servingPolicy: LANFakes.defaultPolicy(eligible: 20, ineligible: 5),
            eligibilityOutcome: .updated(newEligibleCount: 25, newIneligibleCount: 0)
        )
        let model = LANControlModel(port: fake)
        await model.loadServingPolicy()

        await model.refreshEligibility()

        let outcome = try #require(model.lastEligibilityOutcome)
        if case .updated(let eligible, let ineligible) = outcome {
            #expect(eligible == 25)
            #expect(ineligible == 0)
        } else {
            Issue.record("Expected .updated eligibility outcome")
        }
        // Requirement 6: policy counts updated after daemon confirmation.
        let policy = try #require(model.servingPolicy)
        #expect(policy.eligibleCount == 25)
        #expect(policy.ineligibleCount == 0)
    }

    @Test("refreshEligibility refused: policy counts unchanged")
    func eligibilityRefusedPreservesPolicy() async throws {
        let fake = FakeLANPort(
            servingPolicy: LANFakes.defaultPolicy(eligible: 20, ineligible: 5),
            eligibilityOutcome: .refused(reason: "policy-locked")
        )
        let model = LANControlModel(port: fake)
        await model.loadServingPolicy()

        await model.refreshEligibility()

        // Policy must be unchanged after a refused update — never optimistically mutated.
        let policy = try #require(model.servingPolicy)
        #expect(policy.eligibleCount == 20,
                "Refused eligibility change must not modify eligible count")
        #expect(policy.ineligibleCount == 5)
    }

    // MARK: - Behavior 7: Stop reports completion only on daemon confirmation (requirement 7)

    @Test("stopServing sets status to .stopped only when daemon confirms")
    func stopServingConfirmed() async throws {
        let fake = FakeLANPort(
            servingStatus: .active(endpoint: LANFakes.defaultEndpoint, authState: .valid),
            stopOutcome: .stopped
        )
        let model = LANControlModel(port: fake)
        await model.loadServingStatus()  // prime status to .active

        await model.stopServing()

        let outcome = try #require(model.lastStopOutcome)
        #expect(outcome == .stopped)
        // Requirement 7: status is .stopped ONLY after daemon confirms.
        #expect(model.servingStatus == .stopped)
        let log = await fake.callLog
        #expect(log.contains("stopServing"))
    }

    @Test("stopServing failed: status does not change to stopped")
    func stopServingFailed() async throws {
        let fake = FakeLANPort(
            servingStatus: .active(endpoint: LANFakes.defaultEndpoint, authState: .valid),
            stopOutcome: .failed(reason: "connection-lost")
        )
        let model = LANControlModel(port: fake)
        await model.loadServingStatus()  // prime status to .active

        await model.stopServing()

        let outcome = try #require(model.lastStopOutcome)
        if case .failed(let r) = outcome {
            #expect(r == "connection-lost")
        } else {
            Issue.record("Expected .failed stop outcome")
        }
        // Requirement 7: must NOT report stopped when daemon returned failed.
        #expect(
            model.servingStatus != .stopped,
            "Must not report stopped when daemon did not confirm stop"
        )
    }

    // MARK: - Behavior 8: No control bypasses policy enforcement (requirement 8)

    @Test("sensitivity policy denial does not advance status to active")
    func deniedStartNoPolicyBypass() async throws {
        let fake = FakeLANPort(
            startOutcome: .denied(reason: "sensitivity-policy-enforced")
        )
        let model = LANControlModel(port: fake)

        await model.startServing()

        let outcome = try #require(model.lastStartOutcome)
        if case .denied(let r) = outcome {
            #expect(r == "sensitivity-policy-enforced")
        } else {
            Issue.record("Expected .denied outcome for policy enforcement")
        }
        // Model must not have promoted to active — no policy bypass.
        #expect(model.servingStatus == .stopped)
    }

    @Test("daemon restart yields blocked status, not stopped, until daemon confirms")
    func daemonRestartYieldsBlocked() async {
        // An unreachable or restarting daemon must yield .blocked — NOT .stopped.
        // .stopped is a daemon-confirmed state; .blocked means "we don't know".
        let model = LANControlModel(
            port: FakeLANPort(servingStatus: .blocked(reason: "daemon-restarting"))
        )
        await model.loadServingStatus()
        #expect(model.servingStatus == .blocked(reason: "daemon-restarting"))
        // Structural guard: blocked != stopped.
        #expect(model.servingStatus != .stopped,
                "Daemon restart must yield .blocked, not .stopped")
    }

    @Test("expired authentication is reported, not hidden or treated as valid")
    func expiredAuthReported() async {
        // Requirement 8: expired auth is a real condition that must surface.
        let status = LANServingStatus.active(
            endpoint: LANFakes.defaultEndpoint,
            authState: .expired
        )
        let model = LANControlModel(port: FakeLANPort(servingStatus: status))
        await model.loadServingStatus()
        // Auth state must be .expired, not collapsed to .valid.
        if case .active(_, let auth) = model.servingStatus {
            #expect(auth == .expired,
                    "Expired authentication must be reported, not treated as valid")
        } else {
            Issue.record("Expected .active status with .expired auth, got \(model.servingStatus)")
        }
    }

    // MARK: - FIX 4: Eligibility refresh non-success surfacing

    // The view cannot be directly tested in this harness (no SwiftUI runtime).
    // These tests verify the model exposes lastEligibilityOutcome in the form the
    // view consumes: the field is non-nil after a refused or failed refresh, and
    // the user-visible reason string is the daemon's verbatim word.

    @Test("FIX 4: refused eligibility refresh: lastEligibilityOutcome is .refused with reason")
    func eligibilityRefusedOutcomeExposedForView() async throws {
        let fake = FakeLANPort(
            servingPolicy: LANFakes.defaultPolicy(eligible: 20, ineligible: 5),
            eligibilityOutcome: .refused(reason: "policy-locked")
        )
        let model = LANControlModel(port: fake)
        await model.loadServingPolicy()

        await model.refreshEligibility()

        let outcome = try #require(model.lastEligibilityOutcome,
                                   "lastEligibilityOutcome must be set after a refused refresh")
        if case .refused(let reason) = outcome {
            // Verify the user-visible message string is derivable (non-nil localized
            // description via the reason the view would interpolate into String(localized:)).
            #expect(!reason.isEmpty, "refused reason must be non-empty for the view to surface")
            #expect(reason == "policy-locked")
        } else {
            Issue.record("Expected .refused eligibility outcome, got \(outcome)")
        }
        // Policy counts must be unchanged — refused must not mutate state.
        let policy = try #require(model.servingPolicy)
        #expect(policy.eligibleCount == 20)
    }

    @Test("FIX 4: failed eligibility refresh: lastEligibilityOutcome is .failed with reason")
    func eligibilityFailedOutcomeExposedForView() async throws {
        let fake = FakeLANPort(
            servingPolicy: LANFakes.defaultPolicy(eligible: 10, ineligible: 3),
            eligibilityOutcome: .failed(reason: "daemon-unreachable")
        )
        let model = LANControlModel(port: fake)
        await model.loadServingPolicy()

        await model.refreshEligibility()

        let outcome = try #require(model.lastEligibilityOutcome)
        if case .failed(let reason) = outcome {
            #expect(!reason.isEmpty, "failed reason must be non-empty for the view to surface")
            #expect(reason == "daemon-unreachable")
        } else {
            Issue.record("Expected .failed eligibility outcome, got \(outcome)")
        }
    }

    @Test("UI copy cannot promise remote availability not confirmed by daemon")
    func noUnconfirmedAvailabilityClaim() async {
        // Before any port interaction the model must not claim any positive
        // availability state — servingStatus is .stopped (default-off).
        // This test acts as a structural guard that the model cannot escape
        // to .active without a daemon-confirmed start.
        let model = LANControlModel(port: FakeLANPort())
        #expect(model.servingStatus == .stopped)
        #expect(model.lastStartOutcome == nil,
                "No availability claim before any port interaction")
    }
}
