import Foundation

// MARK: - LANControlPort  (APP-07 — Portable LAN Controls)
//
// Feature-local presentation port. Lossless projection of CONTRACT-07.
//
// CRITICAL: MootGateway contains an in-process MootLANServer actor driven by
// the forbidden CommunityAppModel.toggleLAN. This port MUST NOT reference,
// drive, or import that server runtime. The LAN feature renders
// daemon-confirmed state through this feature-local port only.
//
// The real gateway adapter (INTEGRATION-02) substitutes at this abstraction;
// until that integration ships, all LANControlModel behavior is exercised
// against a fake daemon conformer in CommunityBoundaryTests/LAN/.
//
// FAIL-CLOSED rule (verbatim from the Community 1.1 requirements):
// "When required authority, policy, data, daemon availability, compatibility,
//  or recovery state cannot be proven, the operation does not proceed and does
//  not fall back to a less protected path."
//
// POLICY INTEGRITY (verbatim): "NEVER represent policy-ineligible material as
// shareable." Ineligible counts must be shown as excluded, never merged into
// the eligible count.

// MARK: - LANAuthenticationState

/// CONTRACT-07: Daemon-reported authentication state for active LAN serving.
///
/// The daemon owns authentication tokens; this enum is a typed projection of
/// what the daemon reports. The model never generates, validates, or renews
/// tokens itself — it renders this state verbatim.
///
/// Requirement 8: expired auth must be reported, not hidden or treated as
/// valid. A `.valid` auth state can only appear if the daemon confirms it.
public enum LANAuthenticationState: Sendable, Equatable {
    /// A valid auth token is in use (daemon-confirmed).
    case valid
    /// The authentication token has expired; re-authorization is required.
    case expired
    /// No authentication has been obtained yet (pre-start or post-stop state).
    case notObtained
}

// MARK: - LANServingPolicy

/// CONTRACT-07: The daemon's current policy for LAN serving eligibility.
///
/// Requirement 5 (verbatim): "Policy-ineligible material is shown as excluded,
/// not silently included." The model never merges `ineligibleCount` into
/// `eligibleCount`. Both values must be surfaced independently.
///
/// Requirement 2: the policy and eligible record count are readable before
/// serving is started.
public struct LANServingPolicy: Sendable, Equatable {
    /// Records currently eligible for LAN serving per daemon evaluation.
    public let eligibleCount: Int
    /// Records excluded by sensitivity, exportability, or LAN policy.
    /// Must be surfaced as excluded — never added to `eligibleCount`.
    public let ineligibleCount: Int
    /// Daemon-supplied human-readable description of policy constraints.
    public let policyDescription: String

    public init(
        eligibleCount: Int,
        ineligibleCount: Int,
        policyDescription: String
    ) {
        self.eligibleCount = eligibleCount
        self.ineligibleCount = ineligibleCount
        self.policyDescription = policyDescription
    }
}

/// Result of reading the current serving policy from the daemon.
///
/// A policy read can fail independently of the serving-status read. Keeping
/// that failure typed prevents an unavailable daemon from being represented as
/// a valid policy with zero eligible and zero excluded records.
public enum LANServingPolicyLoadOutcome: Sendable, Equatable {
    case loaded(LANServingPolicy)
    case blocked(reason: String)
    case failed(reason: String)
}

// MARK: - LANServingStatus

/// CONTRACT-07: Six typed serving statuses reported by the daemon.
///
/// Requirement 4 (verbatim): "The UI distinguishes stopped, starting, active,
/// interrupted, blocked, and failed."
///
/// The model surfaces each case verbatim; it never collapses daemon states.
///
/// Requirement 1: LAN serving is off by default — `LANControlModel` initializes
/// `servingStatus` to `.stopped`, not to any unknown or active state.
///
/// Requirement 7: `.stopped` is a daemon-confirmed state. An unreachable daemon
/// yields `.blocked`, not `.stopped`.
public enum LANServingStatus: Sendable, Equatable {
    /// No LAN serving is active. This is the daemon-confirmed stopped state AND
    /// the model's initial state (requirement 1). An unreachable daemon must NOT
    /// be rendered as `.stopped` — use `.blocked` for that.
    case stopped
    /// A start request has been submitted; awaiting daemon confirmation.
    case starting
    /// The daemon is actively serving on the reported endpoint.
    /// `authState` reflects what the daemon currently reports for this session;
    /// `.expired` must be surfaced, not hidden (requirement 8).
    case active(endpoint: String, authState: LANAuthenticationState)
    /// Serving was interrupted (e.g. network change). The daemon supplies the
    /// reason.
    case interrupted(reason: String)
    /// The daemon cannot serve (e.g. authorization missing, policy violation).
    case blocked(reason: String)
    /// Serving failed for a system reason.
    case failed(reason: String)
}

// MARK: - LANStartOutcome

/// CONTRACT-07: The daemon's response after a start-serving request.
///
/// Requirement 3 (verbatim): "Starting service requires the contract's required
/// authorization and reports the actual endpoint and authentication state
/// returned by the daemon."
///
/// Fail-closed: the model advances `servingStatus` to `.active` ONLY on
/// `.started`. A `.denied` or `.failed` must be surfaced verbatim; the model
/// must not optimistically promote itself to an active state.
///
/// Requirement 8: a `.denied` outcome means the daemon enforced policy.
/// No code path in the model bypasses that enforcement.
public enum LANStartOutcome: Sendable, Equatable {
    /// The daemon confirmed serving has started; endpoint and auth are
    /// daemon-supplied and must be rendered verbatim.
    case started(endpoint: String, authState: LANAuthenticationState)
    /// The daemon denied the start (policy, auth, or eligibility enforcement).
    case denied(reason: String)
    /// The start operation failed for a system reason.
    case failed(reason: String)
}

// MARK: - LANStopOutcome

/// CONTRACT-07: The daemon's response after a stop-serving request.
///
/// Requirement 7 (verbatim): "Stopping service reports completion only when
/// the daemon confirms it is no longer serving."
///
/// `.stopped` is ONLY surfaced here — and only reflected in `servingStatus` —
/// when the daemon explicitly returns this case. A system failure returns
/// `.failed` and does NOT advance `servingStatus` to `.stopped`.
public enum LANStopOutcome: Sendable, Equatable {
    /// The daemon confirmed it is no longer serving.
    case stopped
    /// The stop operation failed for a system reason.
    case failed(reason: String)
}

// MARK: - LANEligibilityUpdateOutcome

/// CONTRACT-07: The daemon's response to an eligibility-refresh request.
///
/// Requirement 6 (verbatim): "Changing eligibility updates the displayed
/// effective state after daemon confirmation."
///
/// The model updates counts ONLY on `.updated` from the daemon — never
/// optimistically.
public enum LANEligibilityUpdateOutcome: Sendable, Equatable {
    /// The daemon re-evaluated eligibility and returned new counts.
    case updated(newEligibleCount: Int, newIneligibleCount: Int)
    /// The daemon refused the eligibility change.
    case refused(reason: String)
    /// The update failed for a system reason.
    case failed(reason: String)
}

// MARK: - LANControlPort

/// Feature-local presentation port for APP-07 Portable LAN Controls.
/// Lossless projection of CONTRACT-07.
///
/// CRITICAL: this port MUST NOT drive or import MootGateway's MootLANServer.
/// The real gateway adapter (INTEGRATION-02) substitutes at this abstraction.
/// Models receive a conformer through injection — no global/singleton.
///
/// FAIL-CLOSED: when daemon state cannot be proven, the operation does not
/// proceed and does not fall back to a less-protected path.
public protocol LANControlPort: Sendable {

    /// Load the daemon's current LAN serving status.
    ///
    /// An unreachable daemon MUST yield `.blocked`, not `.stopped`. The model
    /// relies on this contract to correctly distinguish a daemon-confirmed stop
    /// from a daemon-unavailable situation (requirement 7).
    func loadServingStatus() async -> LANServingStatus

    /// Load the daemon's current serving policy and eligibility counts.
    ///
    /// The returned policy's `ineligibleCount` must be surfaced as excluded,
    /// never merged into `eligibleCount` (requirement 5).
    func loadServingPolicy() async -> LANServingPolicyLoadOutcome

    /// Request the daemon to start LAN serving.
    ///
    /// Fail-closed: `servingStatus` is advanced to `.active` ONLY on `.started`.
    /// A `.denied` or `.failed` must be surfaced verbatim; no state mutation
    /// implying success may occur. No bypass of policy, sensitivity, or
    /// exportability enforcement (requirement 8).
    func startServing() async -> LANStartOutcome

    /// Request the daemon to stop LAN serving.
    ///
    /// Requirement 7: the model reports `.stopped` ONLY when this method
    /// returns `.stopped`. A system failure must return `.failed` — never
    /// `.stopped` — so the model can surface an accurate failure state.
    func stopServing() async -> LANStopOutcome

    /// Request the daemon to re-evaluate eligibility.
    ///
    /// Requirement 6: the model updates counts only on `.updated`.
    /// A `.refused` or `.failed` must leave the current policy unchanged.
    func refreshEligibility() async -> LANEligibilityUpdateOutcome
}
