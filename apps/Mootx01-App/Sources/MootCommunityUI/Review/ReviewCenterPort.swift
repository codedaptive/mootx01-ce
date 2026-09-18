import Foundation

// MARK: - ReviewCenterPort  (APP-04 — Complete Review Center)
//
// Feature-local presentation port. Lossless projection of CONTRACT-04.
//
// The real gateway adapter (INTEGRATION-02) substitutes at this abstraction;
// until that integration ships, all ReviewCenterModel behaviour is exercised
// against a fake daemon conformer in CommunityBoundaryTests/Review/.
//
// FAIL-CLOSED rule (verbatim from the Community 1.1 requirements):
// "When required authority, policy, data, daemon availability, compatibility,
//  or recovery state cannot be proven, the operation does not proceed and does
//  not fall back to a less protected path."
//
// Nothing in this file reaches MootGateway, SQLite, PersistenceKit,
// LocusKit, or GeniusLocusKit. The Community app is NOT an estate database
// owner; all business rules, duplicate decisions, and state transitions are
// daemon-owned. Models render typed daemon state and submit typed requests;
// they never recompute daemon outcomes.

// MARK: - ReviewSessionKind

/// The three interactive review modes exposed by APP-04.
///
/// `dashboard` (estate-wide summary) is surfaced through `ReviewModeStatus`
/// per-mode state, not as a runnable session kind — keeping the session
/// contract narrow and the daemon as the sole arbiter of review lifecycle.
public enum ReviewSessionKind: String, Sendable, Codable, CaseIterable, Identifiable,
    Hashable {
    case morning
    case endOfDay
    case weekly
    public var id: String { rawValue }

    /// Stable display key — resolved by the view layer via String(localized:).
    var displayKey: String {
        switch self {
        case .morning:  "review.kind.morning"
        case .endOfDay: "review.kind.end.of.day"
        case .weekly:   "review.kind.weekly"
        }
    }
}

// MARK: - ReviewModeStatus

/// CONTRACT-04: Canonical status of one review mode slot, as the daemon
/// reports it on the dashboard.
public enum ReviewModeStatus: Sendable, Equatable {
    /// The mode exists and can be started.
    case available
    /// The daemon's schedule says this mode is due now.
    case due
    /// A session is already in progress; the UUID lets the model reconnect to
    /// the same canonical session rather than creating a duplicate.
    case inProgress(sessionID: UUID)
    /// The session was successfully completed. The receipt is the daemon's
    /// official record of what was covered.
    case completed(receipt: ReviewCompletionReceipt)
    /// The daemon cannot offer this mode right now, with an explanation.
    case blocked(reason: String)
}

// MARK: - ReviewDashboardState

/// CONTRACT-04: Dashboard view of all three review modes, as the daemon
/// supplies it. Models render this; they never derive availability themselves.
public struct ReviewDashboardState: Sendable, Equatable {
    /// Daemon-supplied status per mode.
    public let modeStates: [ReviewSessionKind: ReviewModeStatus]

    public init(modeStates: [ReviewSessionKind: ReviewModeStatus]) {
        self.modeStates = modeStates
    }

    /// Ordered entries for deterministic view iteration (declaration order).
    public var orderedModes: [(kind: ReviewSessionKind, status: ReviewModeStatus)] {
        ReviewSessionKind.allCases.compactMap { kind in
            modeStates[kind].map { (kind, $0) }
        }
    }
}

// MARK: - ReviewSessionItem

/// CONTRACT-04: One item within a review section.
public struct ReviewSessionItem: Sendable, Identifiable, Equatable {
    /// Stable within the session.
    public let id: UUID
    /// Daemon-supplied display subject (not a localization key — estate data).
    public let subject: String
    /// Additional daemon-supplied context. May be empty.
    public let detail: String

    public init(id: UUID, subject: String, detail: String = "") {
        self.id = id
        self.subject = subject
        self.detail = detail
    }
}

// MARK: - ReviewSessionSection

/// CONTRACT-04: One titled group of items within a session. Ordered by the
/// daemon; the model preserves that order without re-sorting.
public struct ReviewSessionSection: Sendable, Identifiable, Equatable {
    /// Stable within the session.
    public let id: UUID
    /// Daemon-supplied section title (display text, not a localization key).
    public let title: String
    /// Items in the daemon's supplied order.
    public let items: [ReviewSessionItem]

    public init(id: UUID, title: String, items: [ReviewSessionItem]) {
        self.id = id
        self.title = title
        self.items = items
    }
}

// MARK: - ReviewAction

/// CONTRACT-04: A proposed action within a session.
///
/// The model shows `expectedEffect` BEFORE asking the user to confirm, so
/// the user always knows what will happen. Reversibility is daemon-reported
/// per-action and per-application — the model never infers it.
public struct ReviewAction: Sendable, Identifiable, Equatable {
    /// Stable within the session and across reconnects.
    public let id: UUID
    /// Daemon-supplied description of what this action will do. Shown in the
    /// UI before the user confirms, satisfying the "explain effect first" rule.
    public let expectedEffect: String
    /// Whether the daemon marks this action as reversible in general.
    public let isReversible: Bool
    /// Whether the daemon currently says reversal is available for this action.
    /// Changes after application — the model re-reads from the session state
    /// rather than inferring availability itself.
    public let reversalAvailable: Bool

    public init(
        id: UUID,
        expectedEffect: String,
        isReversible: Bool,
        reversalAvailable: Bool
    ) {
        self.id = id
        self.expectedEffect = expectedEffect
        self.isReversible = isReversible
        self.reversalAvailable = reversalAvailable
    }
}

// MARK: - DuplicateResolutionChoice

/// One daemon-approved resolution option for a duplicate group.
/// Only daemon-approved choices may be submitted — the model never invents
/// its own resolution.
public struct DuplicateResolutionChoice: Sendable, Identifiable, Equatable {
    public let id: UUID
    /// Daemon-supplied description of what this choice does.
    public let description: String

    public init(id: UUID, description: String) {
        self.id = id
        self.description = description
    }
}

// MARK: - DuplicateGroup

/// CONTRACT-04: One group of records the daemon has identified as duplicates.
/// The UI surfaces `involvedRecordIDs` so the user can inspect which records
/// are involved, and `resolutionChoices` so only daemon-sanctioned options
/// are presented.
public struct DuplicateGroup: Sendable, Identifiable, Equatable {
    /// Stable within the session.
    public let id: UUID
    /// Daemon-supplied explanation of why these records are related.
    public let reason: String
    /// UUIDs of the records the daemon identified as duplicates.
    public let involvedRecordIDs: [UUID]
    /// The only legal resolution choices — provided by the daemon.
    public let resolutionChoices: [DuplicateResolutionChoice]

    public init(
        id: UUID,
        reason: String,
        involvedRecordIDs: [UUID],
        resolutionChoices: [DuplicateResolutionChoice]
    ) {
        self.id = id
        self.reason = reason
        self.involvedRecordIDs = involvedRecordIDs
        self.resolutionChoices = resolutionChoices
    }
}

// MARK: - ReviewCompletionReceipt

/// CONTRACT-04: The daemon's official record that a session was completed.
/// Persisted by the daemon; the model only displays it.
public struct ReviewCompletionReceipt: Sendable, Equatable {
    public let sessionID: UUID
    public let completedAt: Date
    /// Daemon-supplied summary of what the session covered.
    public let summary: String

    public init(sessionID: UUID, completedAt: Date, summary: String) {
        self.sessionID = sessionID
        self.completedAt = completedAt
        self.summary = summary
    }
}

// MARK: - ReviewSessionCompletionStatus

/// CONTRACT-04: Daemon-reported completion state of a session.
public enum ReviewSessionCompletionStatus: Sendable, Equatable {
    /// Started but not yet completed.
    case inProgress
    /// Successfully completed; the receipt is the canonical record.
    case completed(receipt: ReviewCompletionReceipt)
    /// Not yet started (e.g. fresh session that was just loaded).
    case notStarted
}

// MARK: - ReviewSession

/// CONTRACT-04: The full state of a review session, as the daemon reports it.
///
/// Stable identity: a session's `id` is assigned by the daemon and survives
/// reconnect. If the user leaves and returns to an in-progress review, the
/// daemon returns the SAME session (same `id`, same `completionStatus`), not
/// a new one — enabling the canonical-status reconnect requirement.
public struct ReviewSession: Sendable, Identifiable, Equatable {
    /// Daemon-assigned stable identity.
    public let id: UUID
    public let kind: ReviewSessionKind
    /// When the daemon generated this session (injected — never a clock read).
    public let generatedAt: Date
    /// Opaque tag identifying the estate snapshot the session was built from.
    public let sourceEstateState: String
    /// Ordered sections in the daemon's supplied order.
    public let orderedSections: [ReviewSessionSection]
    /// Proposed actions (may be empty).
    public let proposedActions: [ReviewAction]
    /// Duplicate groups (may be empty).
    public let duplicateGroups: [DuplicateGroup]
    /// Daemon-reported completion status (inProgress, completed, or notStarted).
    public let completionStatus: ReviewSessionCompletionStatus

    public init(
        id: UUID,
        kind: ReviewSessionKind,
        generatedAt: Date,
        sourceEstateState: String,
        orderedSections: [ReviewSessionSection],
        proposedActions: [ReviewAction],
        duplicateGroups: [DuplicateGroup],
        completionStatus: ReviewSessionCompletionStatus
    ) {
        self.id = id
        self.kind = kind
        self.generatedAt = generatedAt
        self.sourceEstateState = sourceEstateState
        self.orderedSections = orderedSections
        self.proposedActions = proposedActions
        self.duplicateGroups = duplicateGroups
        self.completionStatus = completionStatus
    }
}

// MARK: - ReviewActionOutcome

/// CONTRACT-04: The outcome the daemon returns for an action or resolution.
///
/// Every false-success path is structurally prohibited: if outcome is not
/// `.applied`, the model surfaces the accurate non-success case and never
/// pretends the operation succeeded.
public enum ReviewActionOutcome: Sendable, Equatable {
    /// The action was successfully applied.
    case applied
    /// The daemon reports this action was already applied (idempotent repeat).
    case alreadyApplied
    /// A state conflict prevents the action; the associated string is the
    /// daemon's explanation.
    case conflict(String)
    /// The session state the client holds is stale; reconnect is required.
    case staleSession
    /// The daemon refused the action with an explanation.
    case refused(String)
    /// The operation failed for a system reason.
    case failed(String)
}

// MARK: - ReviewSessionResult

/// The result of loading or reconnecting to a session via the port.
public enum ReviewSessionResult: Sendable, Equatable {
    /// A session — either freshly created or canonically reconnected.
    case session(ReviewSession)
    /// The daemon could not produce a session; the reason explains why.
    case blocked(reason: String)
}

// MARK: - ReviewCompletionResult

/// The result of completing a session via the port.
public enum ReviewCompletionResult: Sendable, Equatable {
    /// Completion was recorded; the receipt is the daemon's canonical record.
    case completed(receipt: ReviewCompletionReceipt)
    /// Completion failed.
    case failed(String)
}

// MARK: - ReviewCenterPort

/// Feature-local presentation port for APP-04 Complete Review Center.
/// Lossless projection of CONTRACT-04.
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
/// communicates failure through typed outcomes, never through exceptions or
/// silent no-ops.
public protocol ReviewCenterPort: Sendable {

    /// Load the dashboard: which modes are available, due, in-progress,
    /// completed, or blocked. The daemon is the sole source of this state;
    /// the model renders it without re-deriving any status itself.
    func loadDashboard() async -> ReviewDashboardState

    /// Load or reconnect to a review session for the given kind.
    ///
    /// Reconnect: if an in-progress session already exists for this kind, the
    /// daemon returns the SAME canonical session (same id, same status), not a
    /// new one. This satisfies requirement 7 (interrupted-session restoration).
    func loadSession(kind: ReviewSessionKind) async -> ReviewSessionResult

    /// Apply an action within a session. The outcome is always the daemon's
    /// authoritative result — never inferred by the model.
    func applyAction(_ actionID: UUID, in sessionID: UUID) async -> ReviewActionOutcome

    /// Reverse a previously applied action.
    ///
    /// Fail-closed: if the daemon no longer reports reversal available, the port
    /// returns `.refused` rather than attempting a silent no-op.
    func reverseAction(_ actionID: UUID, in sessionID: UUID) async -> ReviewActionOutcome

    /// Submit a duplicate group resolution using a daemon-approved choice.
    /// Submitting a choice not in `DuplicateGroup.resolutionChoices` is a
    /// protocol violation; conformers may return `.refused` in that case.
    func resolveGroup(
        _ groupID: UUID,
        choiceID: UUID,
        in sessionID: UUID
    ) async -> ReviewActionOutcome

    /// Record the session as complete and collect the daemon's receipt.
    func completeSession(_ sessionID: UUID) async -> ReviewCompletionResult
}
