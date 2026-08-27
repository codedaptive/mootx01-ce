import Foundation
import Observation

// MARK: - ReviewCenterModel  (APP-04 — Complete Review Center)
//
// Observable presentation model for the Review Center feature.
// Backed by an injected ReviewCenterPort conformer (no singleton, no global
// writer). All mutable state is driven by daemon-supplied values; the model
// never recomputes a business outcome the port did not supply.
//
// Swift 6 strict-concurrency: @MainActor isolates all mutable published
// state; the port is held as `any ReviewCenterPort` (Sendable), so it is
// safe to pass across actor boundaries inside async calls.

@MainActor
@Observable
public final class ReviewCenterModel {

    // MARK: - Dashboard

    /// Daemon-supplied mode statuses. `nil` until the first `loadDashboard()` call.
    public private(set) var dashboardState: ReviewDashboardState?

    /// True while a dashboard load is in flight.
    public private(set) var isLoadingDashboard = false

    // MARK: - Active session

    /// The current active session (if any).
    public private(set) var activeSession: ReviewSession?

    /// True while a session load is in flight.
    public private(set) var isLoadingSession = false

    /// User-visible explanation when the last session load was blocked, or when
    /// session completion failed.
    public private(set) var sessionBlockReason: String?

    // MARK: - Action state

    /// The action whose effect is being previewed (selected but not yet applied).
    /// The model keeps this after a refusal so the user can correct or retry.
    public var pendingAction: ReviewAction?

    /// True while an action operation is in flight.
    public private(set) var isApplyingAction = false

    /// The outcome the daemon returned for the most recent action operation.
    /// `nil` until the first apply/reverse/resolve call completes.
    public private(set) var lastActionOutcome: ReviewActionOutcome?

    // MARK: - Duplicate resolution

    /// The group the user has selected for resolution (not yet submitted).
    public var pendingGroupID: UUID?

    /// The resolution choice selected for the pending group.
    public var pendingChoiceID: UUID?

    // MARK: - Completion

    /// The daemon's receipt for the completed session. `nil` until the session
    /// is completed (or until a reconnect finds a previously completed session).
    public private(set) var completionReceipt: ReviewCompletionReceipt?

    /// FIX 2: Daemon-supplied reason when the most recent `completeSession()` call
    /// failed. Distinct from `sessionBlockReason` (which covers session-load failures)
    /// so the view can show completion failures inside sessionContent while the
    /// session is still non-nil.
    ///
    /// Set to the daemon's reason on `.failed` from `completeSession()`; cleared on
    /// `.completed`. The view reads this field to surface the failure inside
    /// sessionContent — the outer if/else chain is unreachable from within an active
    /// session because `activeSession` is never cleared on completion failure.
    public private(set) var lastCompletionFailureReason: String?

    // MARK: - Port

    /// Injected port. Production: INTEGRATION-02 adapter.
    /// Tests: FakeReviewPort (defined in CommunityBoundaryTests/Review/).
    private let port: any ReviewCenterPort

    // MARK: - Init

    /// - Parameter port: the injected port conformer. Never constructed here;
    ///   always supplied by the call site (no singleton, no global writer).
    public init(port: any ReviewCenterPort) {
        self.port = port
    }

    // MARK: - Dashboard

    /// Load (or refresh) the dashboard state from the daemon.
    /// The daemon is the sole source of mode availability — the model renders
    /// what it receives without re-deriving any status itself.
    public func loadDashboard() async {
        isLoadingDashboard = true
        defer { isLoadingDashboard = false }
        dashboardState = await port.loadDashboard()
    }

    // MARK: - Session

    /// Load or reconnect to a review session for the given kind.
    ///
    /// Reconnect: if the daemon already has an in-progress session for this
    /// kind it returns the same canonical session (same id, same completionStatus)
    /// — this is how requirement 7 (interrupted-session restoration) is satisfied.
    /// The model surfaces whatever the daemon supplies; it never synthesises
    /// a session of its own.
    public func loadSession(kind: ReviewSessionKind) async {
        isLoadingSession = true
        sessionBlockReason = nil
        defer { isLoadingSession = false }
        switch await port.loadSession(kind: kind) {
        case .session(let session):
            activeSession = session
            // Restore completion receipt when the daemon reports the session
            // was already completed — reconnect case for requirement 7 and 8.
            if case .completed(let receipt) = session.completionStatus {
                completionReceipt = receipt
            } else {
                completionReceipt = nil
            }
        case .blocked(let reason):
            // Fail-closed: no session is surfaced without daemon authority.
            activeSession = nil
            completionReceipt = nil
            pendingAction = nil
            pendingGroupID = nil
            pendingChoiceID = nil
            lastActionOutcome = nil
            sessionBlockReason = reason
        }
    }

    /// Dismiss the last action outcome (e.g. after the user reads the banner).
    public func dismissActionOutcome() {
        lastActionOutcome = nil
    }

    /// Dismiss the active session without completing it.
    /// The next `loadSession(kind:)` call will reconnect to the same
    /// canonical session if it is still in progress (requirement 7).
    public func closeSession() {
        activeSession = nil
        pendingAction = nil
        pendingGroupID = nil
        pendingChoiceID = nil
        lastActionOutcome = nil
    }

    // MARK: - Actions

    /// Select an action for effect-preview. Does NOT apply the action.
    /// The view layer shows `pendingAction.expectedEffect` before presenting
    /// the confirm button, satisfying requirement 3.
    public func selectAction(_ action: ReviewAction) {
        pendingAction = action
    }

    /// Apply the pending action and record the daemon's outcome.
    ///
    /// The model clears `pendingAction` only on `.applied` or `.alreadyApplied`
    /// so the user can correct or retry after `.conflict`, `.staleSession`,
    /// `.refused`, or `.failed`. This satisfies the false-success discipline:
    /// only an explicit success outcome clears the pending state.
    public func applyPendingAction() async {
        guard let action = pendingAction,
              let session = activeSession else { return }
        isApplyingAction = true
        defer { isApplyingAction = false }
        let outcome = await port.applyAction(action.id, in: session.id)
        lastActionOutcome = outcome
        // Clear the pending action only on definitive success outcomes —
        // never on conflict, stale, refused, or failed (user may retry).
        switch outcome {
        case .applied, .alreadyApplied:
            pendingAction = nil
        case .conflict, .staleSession, .refused, .failed:
            // Keep pendingAction so the user can correct and resubmit.
            break
        }
    }

    /// Reverse a previously applied action.
    ///
    /// Only called when `action.reversalAvailable` is true (the view layer
    /// disables the reversal control otherwise). The port re-validates and
    /// may return `.refused` if reversal is no longer available — that
    /// outcome is surfaced verbatim (requirement 4).
    public func reverseAction(_ action: ReviewAction) async {
        guard let session = activeSession else { return }
        let outcome = await port.reverseAction(action.id, in: session.id)
        lastActionOutcome = outcome
    }

    // MARK: - Duplicate groups

    /// Submit a duplicate group resolution using a daemon-approved choice.
    ///
    /// Only `DuplicateGroup.resolutionChoices` choices may be submitted
    /// — the view only presents those choices (requirement 6). The daemon
    /// re-validates on receipt and the outcome is surfaced verbatim.
    public func resolveGroup(groupID: UUID, choiceID: UUID) async {
        guard let session = activeSession else { return }
        let outcome = await port.resolveGroup(groupID, choiceID: choiceID, in: session.id)
        lastActionOutcome = outcome
        // Clear pending group only on definitive success.
        if case .applied = outcome {
            pendingGroupID = nil
            pendingChoiceID = nil
        }
    }

    // MARK: - Completion

    /// Complete the active session and collect the daemon's receipt (requirement 8).
    ///
    /// On success, `completionReceipt` is set to the daemon's official record and
    /// `lastCompletionFailureReason` is cleared.
    /// On failure, `lastCompletionFailureReason` is set to the daemon's explanation
    /// so the view can surface it inside sessionContent while `activeSession` remains
    /// non-nil. `sessionBlockReason` is also set for backwards compatibility.
    ///
    /// The model never synthesises a receipt; it only displays what the daemon supplies.
    public func completeSession() async {
        guard let session = activeSession else { return }
        switch await port.completeSession(session.id) {
        case .completed(let receipt):
            completionReceipt = receipt
            // FIX 2: clear any prior completion failure now that success arrived.
            lastCompletionFailureReason = nil
        case .failed(let reason):
            // Fail-closed: no receipt is shown without daemon confirmation.
            // FIX 2: store failure in the dedicated field so the view can reach it
            // inside sessionContent (activeSession is still non-nil at this point,
            // so the outer if/else chain's sessionBlockReason branch is unreachable).
            lastCompletionFailureReason = reason
            sessionBlockReason = reason
        }
    }

    /// Dismiss the last completion failure reason (e.g. after the user reads the banner).
    public func dismissCompletionFailure() {
        lastCompletionFailureReason = nil
    }
}
