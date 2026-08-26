import Foundation
import Observation

// MARK: - LANControlModel  (APP-07 — Portable LAN Controls)
//
// Observable presentation model for APP-07.
// Backed by an injected LANControlPort conformer (no singleton, no global writer).
// All mutable state is driven by daemon-supplied values; the model never
// recomputes a business outcome the port did not supply.
//
// CRITICAL: this model MUST NOT import, reference, or drive MootGateway's
// MootLANServer actor. All LAN state flows through the injected port only.
//
// Swift 6 strict-concurrency: @MainActor isolates all mutable state;
// the port is held as `any LANControlPort` (Sendable), safe across isolation.
//
// Requirement 1: LAN serving is off by default — `servingStatus` property
// default is `.stopped`, set before the first port interaction.
//
// Fail-closed discipline enforced throughout:
// - `servingStatus` advances to `.active` ONLY when daemon returns `.started`.
// - `servingStatus` advances to `.stopped` ONLY when daemon returns `.stopped`.
// - Ineligible counts are stored separately — never merged into eligible.
// - Denied/failed outcomes store the daemon's word verbatim; no success state.

@MainActor
@Observable
public final class LANControlModel {

    // MARK: - Serving status

    /// Daemon-confirmed serving status.
    ///
    /// Requirement 1: initialized to `.stopped` — LAN serving is off by default.
    /// Must NOT be optimistically set to `.active` before daemon confirmation.
    /// Must NOT be set to `.stopped` on a failed stop (requirement 7).
    public private(set) var servingStatus: LANServingStatus = .stopped

    /// True while a status load is in flight.
    public private(set) var isLoadingStatus = false

    // MARK: - Serving policy

    /// Daemon-supplied policy including eligible and ineligible counts.
    /// `nil` until first `loadServingPolicy()` call.
    ///
    /// Requirement 5: `ineligibleCount` must always be surfaced as excluded —
    /// the model never merges it into `eligibleCount`.
    public private(set) var servingPolicy: LANServingPolicy?

    /// Outcome of the most recent policy read. A failed reconnect preserves the
    /// last confirmed policy while marking it stale instead of replacing it
    /// with plausible-looking zero counts.
    public private(set) var lastPolicyLoadOutcome: LANServingPolicyLoadOutcome?

    public private(set) var isLoadingPolicy = false

    // MARK: - Operation guard

    /// True while any mutating operation (start/stop/refresh) is in flight.
    /// Guards against concurrent submissions.
    public private(set) var isOperationInFlight = false

    // MARK: - Start / stop outcomes

    /// The daemon's response to the most recent start request.
    /// `nil` until the first `startServing()` call.
    public private(set) var lastStartOutcome: LANStartOutcome?

    /// The daemon's response to the most recent stop request.
    /// `.stopped` appears here ONLY when the daemon confirms — requirement 7.
    /// `nil` until the first `stopServing()` call.
    public private(set) var lastStopOutcome: LANStopOutcome?

    // MARK: - Eligibility

    /// The daemon's response to the most recent eligibility refresh.
    /// `nil` until the first `refreshEligibility()` call.
    public private(set) var lastEligibilityOutcome: LANEligibilityUpdateOutcome?

    // MARK: - Port

    /// Injected port. Production: INTEGRATION-02 adapter.
    /// Tests: FakeLANPort (defined in CommunityBoundaryTests/LAN/).
    ///
    /// CRITICAL: this port MUST NOT be MootGateway's MootLANServer or any type
    /// that drives it. The feature-local port is the only LAN interface here.
    private let port: any LANControlPort

    // MARK: - Init

    /// - Parameter port: injected port conformer. Never constructed here;
    ///   always supplied by the call site (no singleton, no global writer).
    ///
    /// Post-init state: `servingStatus == .stopped` (requirement 1).
    public init(port: any LANControlPort) {
        self.port = port
        // servingStatus defaults to .stopped via the property initializer above.
        // No port call is made at init time — status is explicitly loaded on demand.
    }

    // MARK: - Load

    /// Load the daemon's current serving status.
    ///
    /// Fail-closed: if the daemon is unreachable, the port returns `.blocked`;
    /// the model stores that verbatim — it never substitutes `.stopped` for
    /// a daemon that has not confirmed it stopped. Guards concurrent load calls.
    public func loadServingStatus() async {
        guard !isLoadingStatus else { return }
        isLoadingStatus = true
        defer { isLoadingStatus = false }
        servingStatus = await port.loadServingStatus()
    }

    /// Load the daemon's policy and eligibility counts.
    ///
    /// Requirement 5: the policy is stored verbatim; the model never merges
    /// `ineligibleCount` into `eligibleCount`. Both values remain independent.
    public func loadServingPolicy() async {
        guard !isLoadingPolicy else { return }
        isLoadingPolicy = true
        defer { isLoadingPolicy = false }
        let outcome = await port.loadServingPolicy()
        lastPolicyLoadOutcome = outcome
        if case .loaded(let policy) = outcome {
            servingPolicy = policy
        }
    }

    // MARK: - Start (requirement 3, requirement 8)

    /// Request the daemon to start LAN serving.
    ///
    /// Requirement 3: the model advances `servingStatus` to `.active` ONLY
    /// when the daemon returns `.started` with a confirmed endpoint and auth state.
    /// Both values are stored verbatim — the model never synthesizes them.
    ///
    /// Fail-closed: `.denied` or `.failed` outcomes are stored in
    /// `lastStartOutcome` and `servingStatus` is NOT mutated. No code path
    /// allows promotion to `.active` without daemon confirmation.
    ///
    /// Requirement 8: the model contains no mechanism to bypass the daemon's
    /// policy, sensitivity, or exportability enforcement. Denied starts are
    /// final from the model's perspective — it records the denial and stops.
    public func startServing() async {
        guard !isOperationInFlight else { return }
        isOperationInFlight = true
        defer { isOperationInFlight = false }
        let outcome = await port.startServing()
        lastStartOutcome = outcome
        if case .started(let endpoint, let authState) = outcome {
            // Advance status ONLY on daemon confirmation — requirement 3.
            // Both endpoint and authState are daemon-supplied; the model never
            // invents or infers these values.
            servingStatus = .active(endpoint: endpoint, authState: authState)
        }
        // .denied or .failed: servingStatus is not mutated. The prior state
        // (e.g. .stopped) remains as the daemon's last confirmed word.
    }

    // MARK: - Stop (requirement 7)

    /// Request the daemon to stop LAN serving.
    ///
    /// Requirement 7 (verbatim): "Stopping service reports completion only when
    /// the daemon confirms it is no longer serving."
    ///
    /// `servingStatus` is set to `.stopped` ONLY when the daemon returns
    /// `.stopped`. A `.failed` outcome stores the failure verbatim and leaves
    /// `servingStatus` unchanged — the view must NOT optimistically render a
    /// stopped state on failure.
    public func stopServing() async {
        guard !isOperationInFlight else { return }
        isOperationInFlight = true
        defer { isOperationInFlight = false }
        let outcome = await port.stopServing()
        lastStopOutcome = outcome
        if case .stopped = outcome {
            // Daemon confirmed — only now do we report stopped.
            servingStatus = .stopped
        }
        // .failed: servingStatus is not mutated. The view reads lastStopOutcome
        // to surface the failure reason without claiming service has stopped.
    }

    // MARK: - Eligibility (requirement 6)

    /// Request the daemon to re-evaluate LAN serving eligibility.
    ///
    /// Requirement 6 (verbatim): "Changing eligibility updates the displayed
    /// effective state after daemon confirmation."
    ///
    /// Counts are updated ONLY on `.updated` from the daemon — never
    /// optimistically. A `.refused` or `.failed` outcome leaves the current
    /// policy state unchanged; the view reads `lastEligibilityOutcome` for
    /// the failure reason.
    ///
    /// Requirement 5 preserved on update: the model carries the daemon-supplied
    /// `newIneligibleCount` into the updated policy's `ineligibleCount` field,
    /// never merging it into `eligibleCount`.
    public func refreshEligibility() async {
        guard !isOperationInFlight else { return }
        isOperationInFlight = true
        defer { isOperationInFlight = false }
        let outcome = await port.refreshEligibility()
        lastEligibilityOutcome = outcome
        if case .updated(let eligible, let ineligible) = outcome {
            // Rebuild the policy with daemon-confirmed counts, carrying the
            // existing description forward. The ineligible count remains separate
            // — never added to the eligible total (requirement 5).
            servingPolicy = LANServingPolicy(
                eligibleCount: eligible,
                ineligibleCount: ineligible,
                policyDescription: servingPolicy?.policyDescription ?? ""
            )
        }
        // .refused or .failed: servingPolicy is not mutated.
    }
}
