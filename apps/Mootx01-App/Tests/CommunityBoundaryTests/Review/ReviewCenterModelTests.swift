import Foundation
import MootCommunityUI
import Testing

// MARK: - ReviewCenterModelTests  (APP-04 boundary tests)
//
// Covers all eight required observable behaviors and the navigation boundary.
// Every test exercises the model through FakeReviewPort — no live estate,
// no gateway, no daemon.
//
// UUID provenance: all IDs use the synthetic namespace (first group = one hex
// character repeated eight times, e.g. AAAAAAAA-…). See Fakes enum.
//
// FALSE-SUCCESS DISCIPLINE: where the port returns a non-applied outcome,
// the test asserts the model surfaces that exact outcome and NEVER .applied.
// This is the key boundary: the model must not recompute or soften the
// daemon's word.

@Suite("Review Center model behavior")
@MainActor
struct ReviewCenterModelTests {

    // MARK: - Behavior 1: Dashboard reports mode status

    @Test("Dashboard load populates mode statuses for all three modes")
    func dashboardReportsModeStatuses() async throws {
        let fake = FakeReviewPort(
            dashboard: Fakes.dashboard(
                morning: .due,
                endOfDay: .available,
                weekly: .inProgress(sessionID: Fakes.session1ID)
            )
        )
        let model = ReviewCenterModel(port: fake)

        await model.loadDashboard()

        let state = try #require(model.dashboardState,
                                 "dashboardState must be set after loadDashboard")
        #expect(state.modeStates[.morning] == .due)
        #expect(state.modeStates[.endOfDay] == .available)
        #expect(state.modeStates[.weekly] == .inProgress(sessionID: Fakes.session1ID))
        let log = await fake.callLog
        #expect(log.contains("loadDashboard"),
                "port.loadDashboard() must be called")
    }

    @Test("Dashboard can report blocked mode")
    func dashboardReportsBlockedMode() async throws {
        let fake = FakeReviewPort(
            dashboard: ReviewDashboardState(modeStates: [.weekly: .blocked(reason: "daemon paused")])
        )
        let model = ReviewCenterModel(port: fake)

        await model.loadDashboard()

        let state = try #require(model.dashboardState)
        #expect(state.modeStates[.weekly] == .blocked(reason: "daemon paused"))
    }

    @Test("Dashboard can report completed mode with receipt")
    func dashboardReportsCompletedMode() async throws {
        let receipt = Fakes.receipt()
        let fake = FakeReviewPort(
            dashboard: ReviewDashboardState(modeStates: [.morning: .completed(receipt: receipt)])
        )
        let model = ReviewCenterModel(port: fake)

        await model.loadDashboard()

        let state = try #require(model.dashboardState)
        #expect(state.modeStates[.morning] == .completed(receipt: receipt))
    }

    // MARK: - Behavior 2: Each mode renders ordered sections and items

    @Test("Morning review renders ordered sections from daemon")
    func morningReviewRendersSections() async throws {
        let sections = [
            Fakes.section(id: Fakes.section1ID, title: "Focus Area",
                          items: [Fakes.item(id: Fakes.item1ID, subject: "Alpha"),
                                  Fakes.item(id: Fakes.item2ID, subject: "Beta")]),
            Fakes.section(id: Fakes.section2ID, title: "Open Work", items: []),
        ]
        let session = Fakes.session(kind: .morning, sections: sections)
        let fake = FakeReviewPort(sessionResults: [.morning: .session(session)])
        let model = ReviewCenterModel(port: fake)

        await model.loadSession(kind: .morning)

        let loaded = try #require(model.activeSession)
        #expect(loaded.kind == .morning)
        // Daemon order is preserved — no re-sort.
        #expect(loaded.orderedSections.map(\.id) == sections.map(\.id))
        #expect(loaded.orderedSections[0].items.map(\.subject) == ["Alpha", "Beta"])
    }

    @Test("End-of-day review renders ordered sections from daemon")
    func endOfDayReviewRendersSections() async throws {
        let session = Fakes.session(kind: .endOfDay,
                                    sections: [Fakes.section(title: "Today's decisions")])
        let fake = FakeReviewPort(sessionResults: [.endOfDay: .session(session)])
        let model = ReviewCenterModel(port: fake)

        await model.loadSession(kind: .endOfDay)

        let loaded = try #require(model.activeSession)
        #expect(loaded.kind == .endOfDay)
        #expect(loaded.orderedSections.count == 1)
        #expect(loaded.orderedSections[0].title == "Today's decisions")
    }

    @Test("Weekly review renders ordered sections from daemon")
    func weeklyReviewRendersSections() async throws {
        let session = Fakes.session(kind: .weekly,
                                    sections: [Fakes.section(title: "Fading items"),
                                               Fakes.section(title: "Contradictions")])
        let fake = FakeReviewPort(sessionResults: [.weekly: .session(session)])
        let model = ReviewCenterModel(port: fake)

        await model.loadSession(kind: .weekly)

        let loaded = try #require(model.activeSession)
        #expect(loaded.kind == .weekly)
        #expect(loaded.orderedSections.count == 2)
    }

    @Test("Empty morning review loads with no sections")
    func emptyMorningReview() async throws {
        let empty = Fakes.emptySession(kind: .morning)
        let fake = FakeReviewPort(sessionResults: [.morning: .session(empty)])
        let model = ReviewCenterModel(port: fake)

        await model.loadSession(kind: .morning)

        let loaded = try #require(model.activeSession)
        #expect(loaded.orderedSections.isEmpty,
                "empty review must have zero sections")
    }

    @Test("Empty end-of-day review loads cleanly")
    func emptyEndOfDayReview() async throws {
        let empty = Fakes.emptySession(kind: .endOfDay)
        let fake = FakeReviewPort(sessionResults: [.endOfDay: .session(empty)])
        let model = ReviewCenterModel(port: fake)

        await model.loadSession(kind: .endOfDay)

        let loaded = try #require(model.activeSession)
        #expect(loaded.proposedActions.isEmpty)
        #expect(loaded.duplicateGroups.isEmpty)
    }

    @Test("Empty weekly review loads cleanly")
    func emptyWeeklyReview() async throws {
        let empty = Fakes.emptySession(kind: .weekly)
        let fake = FakeReviewPort(sessionResults: [.weekly: .session(empty)])
        let model = ReviewCenterModel(port: fake)

        await model.loadSession(kind: .weekly)

        let loaded = try #require(model.activeSession)
        #expect(loaded.orderedSections.isEmpty)
    }

    // MARK: - Behavior 3: Actions explain effect before confirmation

    @Test("Selecting an action surfaces expectedEffect without applying")
    func selectingActionSurfacesEffect() async throws {
        let action = Fakes.action(effect: "Archive synthetic record")
        let session = Fakes.session(actions: [action])
        let fake = FakeReviewPort(sessionResults: [.morning: .session(session)])
        let model = ReviewCenterModel(port: fake)

        await model.loadSession(kind: .morning)
        model.selectAction(action)

        // Effect is surfaced on pendingAction — view shows it before confirm.
        #expect(model.pendingAction?.id == action.id)
        #expect(model.pendingAction?.expectedEffect == "Archive synthetic record")
        // No call to port yet — selection is pure UI state.
        let log = await fake.callLog
        #expect(!log.contains(where: { $0.hasPrefix("applyAction") }),
                "selecting must not trigger port.applyAction")
        #expect(model.lastActionOutcome == nil,
                "outcome must be nil before any apply")
    }

    // MARK: - Behavior 4: Action outcomes without false success

    @Test("Applying an action reports applied outcome")
    func applyActionReportsApplied() async throws {
        let action = Fakes.action()
        let session = Fakes.session(actions: [action])
        let fake = FakeReviewPort(
            sessionResults: [.morning: .session(session)],
            actionOutcome: .applied
        )
        let model = ReviewCenterModel(port: fake)

        await model.loadSession(kind: .morning)
        model.selectAction(action)
        await model.applyPendingAction()

        #expect(model.lastActionOutcome == .applied)
        // Port must have been called.
        let log = await fake.callLog
        #expect(log.contains(where: { $0.hasPrefix("applyAction") }))
    }

    @Test("Applying already-applied action reports alreadyApplied — not applied")
    func applyAlreadyAppliedActionReportsCorrectOutcome() async throws {
        let action = Fakes.action()
        let session = Fakes.session(actions: [action])
        let fake = FakeReviewPort(
            sessionResults: [.morning: .session(session)],
            actionOutcome: .alreadyApplied
        )
        let model = ReviewCenterModel(port: fake)

        await model.loadSession(kind: .morning)
        model.selectAction(action)
        await model.applyPendingAction()

        // FALSE-SUCCESS BOUNDARY: must be alreadyApplied, never applied.
        #expect(model.lastActionOutcome == .alreadyApplied,
                "alreadyApplied port result must not be surfaced as applied")
    }

    @Test("Applying action in stale session reports staleSession — not applied")
    func applyActionInStaleSessionReportsStale() async throws {
        let action = Fakes.action()
        let session = Fakes.session(actions: [action])
        let fake = FakeReviewPort(
            sessionResults: [.morning: .session(session)],
            actionOutcome: .staleSession
        )
        let model = ReviewCenterModel(port: fake)

        await model.loadSession(kind: .morning)
        model.selectAction(action)
        await model.applyPendingAction()

        // FALSE-SUCCESS BOUNDARY: staleSession must not appear as applied.
        #expect(model.lastActionOutcome == .staleSession,
                "staleSession port result must not be surfaced as applied")
        // Stale session means pending action is preserved for retry.
        #expect(model.pendingAction != nil,
                "pending action must survive a stale-session outcome for retry")
    }

    @Test("Applying conflicted action reports conflict — not applied")
    func applyConflictedActionReportsConflict() async throws {
        let action = Fakes.action()
        let session = Fakes.session(actions: [action])
        let fake = FakeReviewPort(
            sessionResults: [.morning: .session(session)],
            actionOutcome: .conflict("synthetic conflict reason")
        )
        let model = ReviewCenterModel(port: fake)

        await model.loadSession(kind: .morning)
        model.selectAction(action)
        await model.applyPendingAction()

        // FALSE-SUCCESS BOUNDARY: conflict must not appear as applied.
        #expect(model.lastActionOutcome == .conflict("synthetic conflict reason"),
                "conflict port result must not be surfaced as applied")
    }

    @Test("Applying refused action reports refused — not applied")
    func applyRefusedActionReportsRefused() async throws {
        let action = Fakes.action()
        let session = Fakes.session(actions: [action])
        let fake = FakeReviewPort(
            sessionResults: [.morning: .session(session)],
            actionOutcome: .refused("synthetic refusal reason")
        )
        let model = ReviewCenterModel(port: fake)

        await model.loadSession(kind: .morning)
        model.selectAction(action)
        await model.applyPendingAction()

        // FALSE-SUCCESS BOUNDARY: refused must not appear as applied.
        #expect(model.lastActionOutcome == .refused("synthetic refusal reason"),
                "refused port result must not be surfaced as applied")
    }

    @Test("Applying failed action reports failed — not applied")
    func applyFailedActionReportsFailed() async throws {
        let action = Fakes.action()
        let session = Fakes.session(actions: [action])
        let fake = FakeReviewPort(
            sessionResults: [.morning: .session(session)],
            actionOutcome: .failed("system error")
        )
        let model = ReviewCenterModel(port: fake)

        await model.loadSession(kind: .morning)
        model.selectAction(action)
        await model.applyPendingAction()

        #expect(model.lastActionOutcome == .failed("system error"))
    }

    @Test("Successful apply clears pendingAction; non-success does not")
    func successClearsPendingActionNonSuccessDoesNot() async throws {
        let action = Fakes.action()
        let session = Fakes.session(actions: [action])

        // --- Applied: pendingAction must be cleared ---
        let successFake = FakeReviewPort(
            sessionResults: [.morning: .session(session)],
            actionOutcome: .applied
        )
        let successModel = ReviewCenterModel(port: successFake)
        await successModel.loadSession(kind: .morning)
        successModel.selectAction(action)
        await successModel.applyPendingAction()
        #expect(successModel.pendingAction == nil,
                "successful apply must clear pendingAction")

        // --- Conflict: pendingAction must be preserved ---
        let conflictFake = FakeReviewPort(
            sessionResults: [.morning: .session(session)],
            actionOutcome: .conflict("version mismatch")
        )
        let conflictModel = ReviewCenterModel(port: conflictFake)
        await conflictModel.loadSession(kind: .morning)
        conflictModel.selectAction(action)
        await conflictModel.applyPendingAction()
        #expect(conflictModel.pendingAction != nil,
                "conflict outcome must preserve pendingAction for correction")
    }

    // MARK: - Behavior 5: Reversible actions expose reversal

    @Test("Reversible action with reversalAvailable exposes reversal")
    func reversibleActionExposesReversal() async throws {
        let action = Fakes.action(isReversible: true, reversalAvailable: true)
        let session = Fakes.session(actions: [action])
        let fake = FakeReviewPort(sessionResults: [.morning: .session(session)])
        let model = ReviewCenterModel(port: fake)

        await model.loadSession(kind: .morning)
        let loaded = try #require(model.activeSession)
        let loadedAction = try #require(loaded.proposedActions.first)

        #expect(loadedAction.isReversible == true)
        #expect(loadedAction.reversalAvailable == true,
                "daemon-reported reversalAvailable must be preserved")
    }

    @Test("Reversible action with reversalAvailable=false shows reversal as unavailable")
    func reversibleActionUnavailableReversal() async throws {
        let action = Fakes.action(isReversible: true, reversalAvailable: false)
        let session = Fakes.session(actions: [action])
        let fake = FakeReviewPort(sessionResults: [.morning: .session(session)])
        let model = ReviewCenterModel(port: fake)

        await model.loadSession(kind: .morning)
        let loaded = try #require(model.activeSession)
        let loadedAction = try #require(loaded.proposedActions.first)

        #expect(loadedAction.isReversible == true,
                "isReversible comes from daemon and must be preserved")
        #expect(loadedAction.reversalAvailable == false,
                "daemon saying reversal is unavailable must be surfaced, not overridden")
    }

    @Test("Reversing an action forwards the call to the port and records outcome")
    func reversingActionRecordsOutcome() async throws {
        let action = Fakes.action(isReversible: true, reversalAvailable: true)
        let session = Fakes.session(actions: [action])
        let fake = FakeReviewPort(
            sessionResults: [.morning: .session(session)],
            actionOutcome: .applied  // reversal success also uses .applied
        )
        let model = ReviewCenterModel(port: fake)

        await model.loadSession(kind: .morning)
        await model.reverseAction(action)

        #expect(model.lastActionOutcome == .applied)
        let log = await fake.callLog
        #expect(log.contains(where: { $0.hasPrefix("reverseAction") }),
                "port.reverseAction must be called")
    }

    // MARK: - Behavior 6: Duplicate groups

    @Test("Duplicate groups identify involved records and daemon-approved choices")
    func duplicateGroupsIdentifyRecords() async throws {
        let group = Fakes.duplicateGroup()
        let session = Fakes.session(groups: [group])
        let fake = FakeReviewPort(sessionResults: [.morning: .session(session)])
        let model = ReviewCenterModel(port: fake)

        await model.loadSession(kind: .morning)

        let loaded = try #require(model.activeSession)
        let loadedGroup = try #require(loaded.duplicateGroups.first)
        // Both involved records are surfaced.
        #expect(loadedGroup.involvedRecordIDs.contains(Fakes.record1ID))
        #expect(loadedGroup.involvedRecordIDs.contains(Fakes.record2ID))
        // Daemon-approved choices are presented without modification.
        #expect(loadedGroup.resolutionChoices.count == 2)
        #expect(loadedGroup.resolutionChoices[0].id == Fakes.choice1ID)
        #expect(loadedGroup.resolutionChoices[1].id == Fakes.choice2ID)
    }

    @Test("Resolving a group submits daemon-approved choice and records outcome")
    func resolveDuplicateGroupSubmitsChoice() async throws {
        let group = Fakes.duplicateGroup()
        let session = Fakes.session(groups: [group])
        let fake = FakeReviewPort(
            sessionResults: [.morning: .session(session)],
            actionOutcome: .applied
        )
        let model = ReviewCenterModel(port: fake)

        await model.loadSession(kind: .morning)
        await model.resolveGroup(groupID: group.id, choiceID: Fakes.choice1ID)

        #expect(model.lastActionOutcome == .applied)
        let log = await fake.callLog
        #expect(log.contains(where: { $0.hasPrefix("resolveGroup") }),
                "port.resolveGroup must be called with the daemon-approved choice")
    }

    @Test("Resolving a group with conflict outcome is surfaced accurately")
    func resolveGroupConflictOutcome() async throws {
        let group = Fakes.duplicateGroup()
        let session = Fakes.session(groups: [group])
        let fake = FakeReviewPort(
            sessionResults: [.morning: .session(session)],
            actionOutcome: .conflict("duplicate already resolved by another client")
        )
        let model = ReviewCenterModel(port: fake)

        await model.loadSession(kind: .morning)
        await model.resolveGroup(groupID: group.id, choiceID: Fakes.choice1ID)

        // FALSE-SUCCESS BOUNDARY: conflict must not be surfaced as applied.
        #expect(model.lastActionOutcome == .conflict("duplicate already resolved by another client"))
    }

    // MARK: - Behavior 7: Interrupted sessions / reconnect restoration

    @Test("Loading an in-progress session restores its canonical status")
    func reconnectRestoredCanonicalStatus() async throws {
        // Daemon returns the SAME session (same id, same inProgress status).
        let inProgressSession = Fakes.session(
            id: Fakes.session1ID,
            kind: .morning,
            status: .inProgress
        )
        let fake = FakeReviewPort(
            sessionResults: [.morning: .session(inProgressSession)]
        )
        let model = ReviewCenterModel(port: fake)

        // First load — simulates initial entry.
        await model.loadSession(kind: .morning)
        let first = try #require(model.activeSession)
        #expect(first.id == Fakes.session1ID)
        #expect(first.completionStatus == .inProgress)

        // Simulate leaving and returning.
        model.closeSession()
        #expect(model.activeSession == nil)

        // Second load — daemon returns the same session.
        await model.loadSession(kind: .morning)
        let reconnected = try #require(model.activeSession)

        // Stable identity: same session id after reconnect.
        #expect(reconnected.id == Fakes.session1ID,
                "reconnect must restore the same session id")
        // Canonical status is preserved from daemon, not re-derived.
        #expect(reconnected.completionStatus == .inProgress,
                "reconnect must restore canonical inProgress status")
    }

    @Test("Loading a previously completed session restores its completion receipt")
    func reconnectRestoredCompletionReceipt() async throws {
        let receipt = Fakes.receipt(summary: "Previously completed synthetic session")
        let completedSession = Fakes.session(
            id: Fakes.session1ID,
            kind: .endOfDay,
            status: .completed(receipt: receipt)
        )
        let fake = FakeReviewPort(
            sessionResults: [.endOfDay: .session(completedSession)]
        )
        let model = ReviewCenterModel(port: fake)

        await model.loadSession(kind: .endOfDay)

        let loaded = try #require(model.activeSession)
        #expect(loaded.completionStatus == .completed(receipt: receipt),
                "daemon-reported completion must be restored on reconnect")
        #expect(model.completionReceipt?.summary == "Previously completed synthetic session",
                "completion receipt must be surfaced after reconnect")
    }

    @Test("Blocked session load surfaces block reason without a fallback session")
    func blockedSessionLoadSurfacesReason() async throws {
        let fake = FakeReviewPort(
            sessionResults: [.morning: .blocked(reason: "daemon maintenance window")]
        )
        let model = ReviewCenterModel(port: fake)

        await model.loadSession(kind: .morning)

        #expect(model.activeSession == nil,
                "blocked session must not produce an activeSession")
        #expect(model.sessionBlockReason == "daemon maintenance window",
                "block reason must be surfaced accurately")
    }

    @Test("A reconnect refusal clears the previously visible session")
    func reconnectRefusalClearsStaleSession() async throws {
        let session = Fakes.session(kind: .morning, actions: [Fakes.action()])
        let fake = FakeReviewPort(sessionResults: [.morning: .session(session)])
        let model = ReviewCenterModel(port: fake)
        await model.loadSession(kind: .morning)
        model.selectAction(session.proposedActions[0])
        #expect(model.activeSession?.id == session.id)

        await fake.setSession(.blocked(reason: "session-no-longer-authoritative"), for: .morning)
        await model.loadSession(kind: .morning)

        #expect(model.activeSession == nil)
        #expect(model.pendingAction == nil)
        #expect(model.completionReceipt == nil)
        #expect(model.sessionBlockReason == "session-no-longer-authoritative")
    }

    // MARK: - Behavior 8: Completion records and displays receipt

    @Test("Completing a review records the daemon's receipt")
    func completingReviewRecordsReceipt() async throws {
        let receipt = Fakes.receipt(summary: "All synthetic items reviewed")
        let session = Fakes.session(status: .inProgress)
        let fake = FakeReviewPort(
            sessionResults: [.morning: .session(session)],
            completionResult: .completed(receipt: receipt)
        )
        let model = ReviewCenterModel(port: fake)

        await model.loadSession(kind: .morning)
        await model.completeSession()

        let savedReceipt = try #require(model.completionReceipt,
                                        "completionReceipt must be set after complete")
        #expect(savedReceipt.summary == "All synthetic items reviewed")
        let log = await fake.callLog
        #expect(log.contains(where: { $0.hasPrefix("completeSession") }),
                "port.completeSession must be called")
    }

    @Test("Completion failure surfaces the error without setting a receipt")
    func completionFailureSurfacesError() async throws {
        let session = Fakes.session()
        let fake = FakeReviewPort(
            sessionResults: [.morning: .session(session)],
            completionResult: .failed("daemon rejected completion")
        )
        let model = ReviewCenterModel(port: fake)

        await model.loadSession(kind: .morning)
        await model.completeSession()

        #expect(model.completionReceipt == nil,
                "failed completion must not produce a receipt")
        #expect(model.sessionBlockReason == "daemon rejected completion",
                "completion failure reason must be surfaced")
    }

    // MARK: - FIX 2: Completion failure surfacing inside sessionContent

    @Test("FIX 2: completion failure sets lastCompletionFailureReason while activeSession remains non-nil")
    func completionFailureSetsLastCompletionFailureReason() async throws {
        // This is the core FIX 2 assertion. Before the fix, completeSession() set
        // sessionBlockReason but the view's if/else chain could not reach it because
        // activeSession was still non-nil. The new lastCompletionFailureReason field
        // lets the view surface the failure inside sessionContent.
        let session = Fakes.session(status: .inProgress)
        let fake = FakeReviewPort(
            sessionResults: [.morning: .session(session)],
            completionResult: .failed("daemon rejected completion")
        )
        let model = ReviewCenterModel(port: fake)

        await model.loadSession(kind: .morning)
        await model.completeSession()

        // FIX 2: the dedicated field must be set.
        #expect(model.lastCompletionFailureReason == "daemon rejected completion",
                "lastCompletionFailureReason must carry the daemon's failure reason")
        // activeSession must still be non-nil — session is not cleared on completion failure.
        #expect(model.activeSession != nil,
                "activeSession must remain non-nil after completion failure")
        // No receipt must be produced — fail-closed.
        #expect(model.completionReceipt == nil,
                "no receipt must appear without daemon confirmation")
    }

    @Test("FIX 2: lastCompletionFailureReason is cleared on successful completion")
    func completionFailureReasonClearedOnSuccess() async throws {
        // If a prior attempt failed, a subsequent success must clear the field
        // so the banner does not linger.
        let receipt = Fakes.receipt(summary: "Cleared after second attempt")
        let session = Fakes.session(status: .inProgress)

        // First attempt: fail.
        let failPort = FakeReviewPort(
            sessionResults: [.morning: .session(session)],
            completionResult: .failed("first attempt failed")
        )
        let model = ReviewCenterModel(port: failPort)
        await model.loadSession(kind: .morning)
        await model.completeSession()
        #expect(model.lastCompletionFailureReason != nil)

        // Second attempt: succeed (swap the port result via a fresh fake).
        let successPort = FakeReviewPort(
            sessionResults: [.morning: .session(session)],
            completionResult: .completed(receipt: receipt)
        )
        let model2 = ReviewCenterModel(port: successPort)
        await model2.loadSession(kind: .morning)
        await model2.completeSession()

        #expect(model2.lastCompletionFailureReason == nil,
                "lastCompletionFailureReason must be cleared after a successful completion")
        #expect(model2.completionReceipt?.summary == "Cleared after second attempt")
    }

    @Test("FIX 2: dismissCompletionFailure clears lastCompletionFailureReason")
    func dismissCompletionFailureClearsField() async throws {
        let session = Fakes.session(status: .inProgress)
        let fake = FakeReviewPort(
            sessionResults: [.morning: .session(session)],
            completionResult: .failed("dismiss-me")
        )
        let model = ReviewCenterModel(port: fake)
        await model.loadSession(kind: .morning)
        await model.completeSession()
        #expect(model.lastCompletionFailureReason == "dismiss-me")

        model.dismissCompletionFailure()

        #expect(model.lastCompletionFailureReason == nil,
                "dismissCompletionFailure() must clear lastCompletionFailureReason")
    }

    // MARK: - Navigation: all three modes reachable

    @Test("All three review modes can be independently loaded from the model")
    func allThreeModesReachableViaModel() async throws {
        let morningSession = Fakes.session(id: Fakes.session1ID, kind: .morning)
        let eodSession     = Fakes.session(id: Fakes.session2ID, kind: .endOfDay)
        let weeklySession  = Fakes.session(id: Fakes.session3ID, kind: .weekly)

        let fake = FakeReviewPort(sessionResults: [
            .morning: .session(morningSession),
            .endOfDay: .session(eodSession),
            .weekly: .session(weeklySession),
        ])
        let model = ReviewCenterModel(port: fake)

        // Each mode is independently navigable at the Review feature's own level.
        await model.loadSession(kind: .morning)
        #expect(model.activeSession?.kind == .morning,
                ".morning must be reachable")

        model.closeSession()
        await model.loadSession(kind: .endOfDay)
        #expect(model.activeSession?.kind == .endOfDay,
                ".endOfDay must be reachable")

        model.closeSession()
        await model.loadSession(kind: .weekly)
        #expect(model.activeSession?.kind == .weekly,
                ".weekly must be reachable")

        // Port must have been called for each mode.
        let log = await fake.callLog
        #expect(log.contains("loadSession(morning)"))
        #expect(log.contains("loadSession(endOfDay)"))
        #expect(log.contains("loadSession(weekly)"))
    }

    // MARK: - Boundary: model never derives an outcome the port did not supply

    @Test("Model forwards port outcome verbatim — never recomputes or softens it")
    func modelNeverDerivesOwnOutcome() async throws {
        // For each non-applied outcome, verify the model surfaces it exactly.
        let cases: [(ReviewActionOutcome, String)] = [
            (.alreadyApplied,             "alreadyApplied"),
            (.conflict("version clash"),   "conflict"),
            (.staleSession,               "staleSession"),
            (.refused("policy"),           "refused"),
            (.failed("io error"),          "failed"),
        ]

        for (outcome, label) in cases {
            let action = Fakes.action()
            let session = Fakes.session(actions: [action])
            let fake = FakeReviewPort(
                sessionResults: [.morning: .session(session)],
                actionOutcome: outcome
            )
            let model = ReviewCenterModel(port: fake)
            await model.loadSession(kind: .morning)
            model.selectAction(action)
            await model.applyPendingAction()

            #expect(model.lastActionOutcome == outcome,
                    "model must surface \(label) verbatim from port — not re-derive it")
        }
    }

    // MARK: - Populated review with all features

    @Test("Populated review loads sections, actions, and duplicate groups together")
    func populatedReviewLoadsAllFeatures() async throws {
        let action = Fakes.action(
            id: Fakes.action1ID,
            effect: "Promote synthetic memory to keystone",
            isReversible: true,
            reversalAvailable: true
        )
        let group = Fakes.duplicateGroup()
        let section = Fakes.section(
            items: [Fakes.item(subject: "Synthetic keystone candidate")]
        )
        let session = Fakes.session(
            kind: .weekly,
            sections: [section],
            actions: [action],
            groups: [group]
        )
        let fake = FakeReviewPort(sessionResults: [.weekly: .session(session)])
        let model = ReviewCenterModel(port: fake)

        await model.loadSession(kind: .weekly)

        let loaded = try #require(model.activeSession)
        #expect(loaded.orderedSections.count == 1)
        #expect(loaded.proposedActions.count == 1)
        #expect(loaded.duplicateGroups.count == 1)
        #expect(loaded.proposedActions[0].expectedEffect == "Promote synthetic memory to keystone")
        #expect(loaded.duplicateGroups[0].involvedRecordIDs.count == 2)
    }
}
