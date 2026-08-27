import Foundation
import MootCommunityUI

// MARK: - FakeReviewPort  (APP-04 boundary tests)
//
// Contract-compatible fake daemon conformer for ReviewCenterPort.
// Lives in the test tree; production code never imports or instantiates this.
//
// The real gateway adapter (INTEGRATION-02) substitutes at the same
// ReviewCenterPort abstraction in production.
//
// Design: actor so Swift 6 strict concurrency is satisfied without
// @unchecked Sendable. Tests configure via async setters before calling
// model methods; call-log reads are awaited after model operations.
//
// UUID provenance: all synthetic IDs in this file use the reserved
// synthetic namespace (first group = one hex character repeated eight times,
// e.g. AAAAAAAA-…). No real estate id can collide with these.

actor FakeReviewPort: ReviewCenterPort {

    // MARK: - Configurable results (set per test via setters)

    private var _dashboardResult: ReviewDashboardState
    private var _sessionResults: [ReviewSessionKind: ReviewSessionResult]
    private var _actionOutcome: ReviewActionOutcome
    private var _completionResult: ReviewCompletionResult

    // MARK: - Call log

    private(set) var callLog: [String] = []

    // MARK: - Init

    init(
        dashboard: ReviewDashboardState = ReviewDashboardState(modeStates: [:]),
        sessionResults: [ReviewSessionKind: ReviewSessionResult] = [:],
        actionOutcome: ReviewActionOutcome = .applied,
        completionResult: ReviewCompletionResult = .completed(
            receipt: ReviewCompletionReceipt(
                sessionID: Fakes.sessionID("AAAAAAAA-0000-4000-8000-000000000099"),
                completedAt: Fakes.epoch,
                summary: ""
            )
        )
    ) {
        _dashboardResult = dashboard
        _sessionResults = sessionResults
        _actionOutcome = actionOutcome
        _completionResult = completionResult
    }

    // MARK: - Setters (awaitable from @MainActor tests)

    func setDashboard(_ result: ReviewDashboardState) {
        _dashboardResult = result
    }

    func setSession(_ result: ReviewSessionResult, for kind: ReviewSessionKind) {
        _sessionResults[kind] = result
    }

    func setActionOutcome(_ outcome: ReviewActionOutcome) {
        _actionOutcome = outcome
    }

    func setCompletionResult(_ result: ReviewCompletionResult) {
        _completionResult = result
    }

    // MARK: - ReviewCenterPort

    func loadDashboard() async -> ReviewDashboardState {
        callLog.append("loadDashboard")
        return _dashboardResult
    }

    func loadSession(kind: ReviewSessionKind) async -> ReviewSessionResult {
        callLog.append("loadSession(\(kind.rawValue))")
        return _sessionResults[kind] ?? .blocked(reason: "fake: no session configured for \(kind.rawValue)")
    }

    func applyAction(_ actionID: UUID, in sessionID: UUID) async -> ReviewActionOutcome {
        callLog.append("applyAction(\(actionID.uuidString.prefix(8)))")
        return _actionOutcome
    }

    func reverseAction(_ actionID: UUID, in sessionID: UUID) async -> ReviewActionOutcome {
        callLog.append("reverseAction(\(actionID.uuidString.prefix(8)))")
        return _actionOutcome
    }

    func resolveGroup(
        _ groupID: UUID,
        choiceID: UUID,
        in sessionID: UUID
    ) async -> ReviewActionOutcome {
        callLog.append("resolveGroup(\(groupID.uuidString.prefix(8)))")
        return _actionOutcome
    }

    func completeSession(_ sessionID: UUID) async -> ReviewCompletionResult {
        callLog.append("completeSession(\(sessionID.uuidString.prefix(8)))")
        return _completionResult
    }
}

// MARK: - Fakes — synthetic test data factory
//
// All UUIDs use the reserved synthetic namespace:
// first group = one hex character repeated eight times.
// Shape matches what the real daemon would supply, but contains no estate data.

enum Fakes {

    /// A fixed epoch for deterministic date comparisons in tests.
    static let epoch = Date(timeIntervalSinceReferenceDate: 0)

    // MARK: ID helpers

    static func sessionID(_ string: String) -> UUID {
        UUID(uuidString: string)!
    }

    // MARK: Session IDs (AAAAAAAA-…)

    static let session1ID = UUID(uuidString: "AAAAAAAA-0001-4000-8000-000000000001")!
    static let session2ID = UUID(uuidString: "AAAAAAAA-0002-4000-8000-000000000002")!
    static let session3ID = UUID(uuidString: "AAAAAAAA-0003-4000-8000-000000000003")!

    // MARK: Section IDs (CCCCCCCC-…)

    static let section1ID = UUID(uuidString: "CCCCCCCC-0001-4000-8000-000000000001")!
    static let section2ID = UUID(uuidString: "CCCCCCCC-0002-4000-8000-000000000002")!

    // MARK: Item IDs (DDDDDDDD-…)

    static let item1ID = UUID(uuidString: "DDDDDDDD-0001-4000-8000-000000000001")!
    static let item2ID = UUID(uuidString: "DDDDDDDD-0002-4000-8000-000000000002")!

    // MARK: Action IDs (BBBBBBBB-…)

    static let action1ID = UUID(uuidString: "BBBBBBBB-0001-4000-8000-000000000001")!
    static let action2ID = UUID(uuidString: "BBBBBBBB-0002-4000-8000-000000000002")!

    // MARK: Group IDs (EEEEEEEE-…)

    static let group1ID = UUID(uuidString: "EEEEEEEE-0001-4000-8000-000000000001")!

    // MARK: Choice IDs (FFFFFFFF-…)

    static let choice1ID = UUID(uuidString: "FFFFFFFF-0001-4000-8000-000000000001")!
    static let choice2ID = UUID(uuidString: "FFFFFFFF-0002-4000-8000-000000000002")!

    // MARK: Record IDs inside duplicate groups (11111111-…, 22222222-…)

    static let record1ID = UUID(uuidString: "11111111-0001-4111-8111-000000000001")!
    static let record2ID = UUID(uuidString: "22222222-0001-4222-8222-000000000001")!

    // MARK: Completion receipt ID (99999999-…)

    static let receiptSessionID = UUID(uuidString: "99999999-0001-4000-8000-000000000001")!

    // MARK: Data builders

    static func item(
        id: UUID = item1ID,
        subject: String = "Synthetic item subject",
        detail: String = ""
    ) -> ReviewSessionItem {
        ReviewSessionItem(id: id, subject: subject, detail: detail)
    }

    static func section(
        id: UUID = section1ID,
        title: String = "Synthetic Section",
        items: [ReviewSessionItem] = [item()]
    ) -> ReviewSessionSection {
        ReviewSessionSection(id: id, title: title, items: items)
    }

    static func action(
        id: UUID = action1ID,
        effect: String = "Archive synthetic record",
        isReversible: Bool = true,
        reversalAvailable: Bool = true
    ) -> ReviewAction {
        ReviewAction(
            id: id,
            expectedEffect: effect,
            isReversible: isReversible,
            reversalAvailable: reversalAvailable
        )
    }

    static func duplicateGroup(
        id: UUID = group1ID,
        reason: String = "The daemon matched the records' canonical source fingerprint.",
        involvedRecordIDs: [UUID] = [record1ID, record2ID],
        choices: [DuplicateResolutionChoice] = [
            DuplicateResolutionChoice(id: choice1ID, description: "Keep first record"),
            DuplicateResolutionChoice(id: choice2ID, description: "Keep second record"),
        ]
    ) -> DuplicateGroup {
        DuplicateGroup(
            id: id,
            reason: reason,
            involvedRecordIDs: involvedRecordIDs,
            resolutionChoices: choices
        )
    }

    static func receipt(
        sessionID: UUID = receiptSessionID,
        completedAt: Date = epoch,
        summary: String = "Synthetic review completed"
    ) -> ReviewCompletionReceipt {
        ReviewCompletionReceipt(sessionID: sessionID, completedAt: completedAt, summary: summary)
    }

    static func session(
        id: UUID = session1ID,
        kind: ReviewSessionKind = .morning,
        sections: [ReviewSessionSection] = [section()],
        actions: [ReviewAction] = [],
        groups: [DuplicateGroup] = [],
        status: ReviewSessionCompletionStatus = .notStarted
    ) -> ReviewSession {
        ReviewSession(
            id: id,
            kind: kind,
            generatedAt: epoch,
            sourceEstateState: "synthetic-estate-state-v1",
            orderedSections: sections,
            proposedActions: actions,
            duplicateGroups: groups,
            completionStatus: status
        )
    }

    static func emptySession(kind: ReviewSessionKind) -> ReviewSession {
        session(id: session2ID, kind: kind, sections: [], actions: [], groups: [])
    }

    static func dashboard(
        morning: ReviewModeStatus = .available,
        endOfDay: ReviewModeStatus = .available,
        weekly: ReviewModeStatus = .available
    ) -> ReviewDashboardState {
        ReviewDashboardState(modeStates: [
            .morning: morning,
            .endOfDay: endOfDay,
            .weekly: weekly,
        ])
    }
}
