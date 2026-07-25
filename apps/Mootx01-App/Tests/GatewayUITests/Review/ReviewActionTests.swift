import Testing
import Foundation
import AriaMCP
import MootGateway
@testable import GatewayUI

// MARK: - ReviewActionTests  (FAB5-G2 Part 2)
//
// The mission's Part 2 verify line: "action test proves no mutation without an
// explicit tap." That is the first suite below, and it is proved by counting
// calls on a recorder rather than by reading the view code:
//
//   * staging every action the Review Center can offer performs zero calls
//   * cancelling performs zero calls
//   * committing performs exactly one, with the right tool and arguments
//   * committing with nothing staged performs zero
//
// The rest of the file pins the suggestion policy (which section offers what,
// and — as importantly — which offers nothing, since inventing an action with no
// substrate behind it is the failure mode here) and the honesty of the
// confirmation text for the two verbs the substrate cannot reverse.

// MARK: - Recorder

/// Records every mutation asked of it and performs none.
///
/// `@MainActor` to match the seam, which lets a test read `calls` synchronously
/// right after an `await` — no actor hop between the action and the assertion, so
/// a zero-call assertion cannot pass merely because it ran too early.
@MainActor
final class RecordingActionPerformer: ReviewActionPerforming {
    private(set) var calls: [ReviewAction] = []
    /// Substrate reply to hand back. Defaults to the shape
    /// `ToolDispatcher.runRetireFact` actually returns.
    var reply = "retired fact 8F3EB809-10CD-40C0-9989-49EE6FA85A8D"
    var repliesWithError = false

    func perform(_ action: ReviewAction) async -> ReviewActionOutcome {
        calls.append(action)
        return ReviewActionOutcome(
            action: action, message: reply, isError: repliesWithError)
    }
}

// MARK: - 1. No mutation without an explicit tap

@Suite("Review actions — nothing mutates without a tap (FAB5-G2)")
@MainActor
struct ReviewActionGateTests {

    @Test("a fresh coordinator has performed nothing and has nothing staged")
    func startsClean() {
        let performer = RecordingActionPerformer()
        let coordinator = ReviewActionCoordinator(performer: performer)
        #expect(performer.calls.isEmpty)
        #expect(coordinator.pending == nil)
        #expect(coordinator.lastOutcome == nil)
        #expect(coordinator.settledSubjectIDs.isEmpty)
    }

    @Test("staging every action mutates nothing", arguments: ReviewActionTestFixtures.everyAction)
    func requestPerformsNothing(action: ReviewAction) {
        let performer = RecordingActionPerformer()
        let coordinator = ReviewActionCoordinator(performer: performer)
        coordinator.request(action)
        // THE INVARIANT. A tap on a suggestion button stages and nothing else.
        #expect(performer.calls.isEmpty)
        #expect(coordinator.pending == action)
        #expect(coordinator.lastOutcome == nil)
    }

    @Test("staging repeatedly, then cancelling, still mutates nothing")
    func cancelPerformsNothing() {
        let performer = RecordingActionPerformer()
        let coordinator = ReviewActionCoordinator(performer: performer)
        for action in ReviewActionTestFixtures.everyAction {
            coordinator.request(action)
        }
        coordinator.cancelPending()
        #expect(performer.calls.isEmpty)
        #expect(coordinator.pending == nil)
        #expect(coordinator.settledSubjectIDs.isEmpty)
    }

    @Test("committing performs exactly one call, and only the staged action", arguments: ReviewActionTestFixtures.everyAction)
    func commitPerformsExactlyOne(action: ReviewAction) async {
        let performer = RecordingActionPerformer()
        let coordinator = ReviewActionCoordinator(performer: performer)
        coordinator.request(action)
        await coordinator.commitPending()
        #expect(performer.calls == [action])
        #expect(coordinator.pending == nil)
        #expect(coordinator.lastOutcome?.action == action)
    }

    @Test("committing with nothing staged performs nothing")
    func commitWithoutStagingPerformsNothing() async {
        let performer = RecordingActionPerformer()
        let coordinator = ReviewActionCoordinator(performer: performer)
        await coordinator.commitPending()
        #expect(performer.calls.isEmpty)
        #expect(coordinator.lastOutcome == nil)
    }

    @Test("committing twice on one staged action performs one call, not two")
    func doubleCommitPerformsOnce() async {
        // The confirm button can be tapped twice before the prompt dismisses.
        let performer = RecordingActionPerformer()
        let coordinator = ReviewActionCoordinator(performer: performer)
        coordinator.request(ReviewActionTestFixtures.everyAction[0])
        await coordinator.commitPending()
        await coordinator.commitPending()
        #expect(performer.calls.count == 1)
    }

    @Test("a successful action settles its row; a refused one does not")
    func onlySuccessSettlesTheRow() async {
        let performer = RecordingActionPerformer()
        let coordinator = ReviewActionCoordinator(performer: performer)
        let factID = "8F3EB809-10CD-40C0-9989-49EE6FA85A8D"

        performer.repliesWithError = true
        performer.reply = "moot_retire_fact: fact not found"
        coordinator.request(.retireFact(id: factID))
        await coordinator.commitPending()
        // A refusal must leave the decision open — hiding the buttons would
        // strand the user with an unfinished action and no way to retry.
        #expect(coordinator.settledSubjectIDs.isEmpty)

        performer.repliesWithError = false
        performer.reply = "retired fact \(factID)"
        coordinator.request(.retireFact(id: factID))
        await coordinator.commitPending()
        #expect(coordinator.settledSubjectIDs.contains(factID))
        #expect(performer.calls.count == 2)
    }

    @Test("the substrate's reply is carried verbatim to the row that was acted on")
    func outcomeIsCarriedVerbatimToTheRightRow() async {
        let performer = RecordingActionPerformer()
        performer.reply = "moot_review_tunnel: DAAAE428 rejected — the link is withdrawn."
        let coordinator = ReviewActionCoordinator(performer: performer)
        let tunnelID = "DAAAE428-B717-4053-93F7-77AD5E561438"
        coordinator.request(.rejectTunnel(id: tunnelID))
        await coordinator.commitPending()

        let acted = ReviewActionTestFixtures.item(subjectID: tunnelID)
        let other = ReviewActionTestFixtures.item(subjectID: "OTHER-ROW")
        #expect(coordinator.outcomeMessage(for: acted) == performer.reply)
        #expect(coordinator.outcomeMessage(for: other) == nil)
        #expect(coordinator.isSettled(acted))
        #expect(!coordinator.isSettled(other))
    }

    @Test("an item with no subjectID is never settled by another row's action")
    func nilSubjectIDIsNeverSettled() async {
        // Drift items are aggregate scores with no estate row (subjectID nil).
        let performer = RecordingActionPerformer()
        let coordinator = ReviewActionCoordinator(performer: performer)
        coordinator.request(.retireFact(id: "some-fact"))
        await coordinator.commitPending()
        let aggregate = ReviewActionTestFixtures.item(subjectID: nil)
        #expect(!coordinator.isSettled(aggregate))
        #expect(coordinator.outcomeMessage(for: aggregate) == nil)
    }
}

// MARK: - 2. Tool routing

@Suite("Review actions — routing to registered ARIA tools (FAB5-G2)")
struct ReviewActionRoutingTests {

    @Test("each action names its registered tool and required arguments")
    func toolsAndArguments() {
        // Argument NAMES differ per tool: `id` for the fact and memory verbs,
        // `tunnel_id` + `verdict` for the tunnel verb. A wrong name is a runtime
        // tool failure, not a compile error, which is why this is pinned.
        let retire = ReviewAction.retireFact(id: "F1")
        #expect(retire.tool == "moot_retire_fact")
        #expect(retire.arguments == ["id": .string("F1")])

        let accept = ReviewAction.acceptTunnel(id: "T1")
        #expect(accept.tool == "moot_review_tunnel")
        #expect(accept.arguments == [
            "tunnel_id": .string("T1"), "verdict": .string("accept"),
        ])

        let reject = ReviewAction.rejectTunnel(id: "T1")
        #expect(reject.tool == "moot_review_tunnel")
        #expect(reject.arguments == [
            "tunnel_id": .string("T1"), "verdict": .string("reject"),
        ])

        let confirm = ReviewAction.confirmMemory(id: "D1")
        #expect(confirm.tool == "moot_confirm_memory")
        #expect(confirm.arguments == ["id": .string("D1")])
    }

    @Test("every action routes to a read-only-free mutation verb, never an erase")
    func noHardDeleteIsReachable() {
        // The Review Center may retire, settle, and confirm. It must never be
        // able to reach moot_erase_memory or moot_withdraw_memory — a review is
        // housekeeping, not deletion.
        let forbidden = ["moot_erase_memory", "moot_withdraw_memory", "moot_consolidate"]
        for action in ReviewActionTestFixtures.everyAction {
            #expect(!forbidden.contains(action.tool))
        }
    }

    @Test("no action exists for merging duplicates")
    func noMergeActionExists() {
        // The roadmap names "duplicated" memories, but no merge or
        // duplicate-detection verb exists at the ARIA surface, so FAB5-G1 ships
        // `duplicates` as an explained gap and this layer offers no button.
        // Asserted rather than assumed, so adding a merge case cannot pass
        // review silently.
        let tools = Set(ReviewActionTestFixtures.everyAction.map(\.tool))
        #expect(tools.count == 3)
        #expect(!tools.contains { $0.contains("merge") })
        #expect(!tools.contains { $0.contains("consolidate") })
    }
}

// MARK: - 3. Suggestion policy

@Suite("Review actions — which rows get which suggestions (FAB5-G2)")
struct ReviewSuggestionPolicyTests {

    @Test("a retire-ready fact offers Retire")
    func retireReadyOffersRetire() {
        let item = ReviewActionTestFixtures.item(subjectID: "FACT-1")
        let actions = ReviewAction.suggestions(forSectionID: "retire-ready", item: item)
        #expect(actions == [.retireFact(id: "FACT-1")])
    }

    @Test("a PROPOSED contradiction offers Accept and Reject, in that order", arguments: ["contradicted", "conflicts", "open-work"])
    func proposedTunnelOffersBoth(sectionID: String) {
        let item = ReviewActionTestFixtures.item(
            subjectID: "TUNNEL-1", status: .proposed)
        let actions = ReviewAction.suggestions(forSectionID: sectionID, item: item)
        #expect(actions == [
            .acceptTunnel(id: "TUNNEL-1"), .rejectTunnel(id: "TUNNEL-1"),
        ])
    }

    @Test("a RECORDED contradiction offers nothing — it is already settled", arguments: ["contradicted", "conflicts", "open-work"])
    func recordedTunnelOffersNothing(sectionID: String) {
        // moot_review_tunnel refuses a settled edge ("a settled edge cannot be
        // rewritten by a stale review"), so offering the button would produce a
        // guaranteed refusal.
        let item = ReviewActionTestFixtures.item(
            subjectID: "TUNNEL-1", status: .recorded)
        #expect(ReviewAction.suggestions(forSectionID: sectionID, item: item).isEmpty)
    }

    @Test("a drawer row offers Confirm", arguments: ["keystones", "context", "changes"])
    func drawerOffersConfirm(sectionID: String) {
        let item = ReviewActionTestFixtures.item(subjectID: "DRAWER-1")
        #expect(ReviewAction.suggestions(forSectionID: sectionID, item: item)
            == [.confirmMemory(id: "DRAWER-1")])
    }

    @Test("sections whose subjectID is not an estate row offer nothing", arguments: [
        "momentum", "fading", "drift", "duplicates", "journal", "decisions", "attention",
    ])
    func unactionableSectionsOfferNothing(sectionID: String) {
        // momentum/fading carry a ROOM NAME, which no mutation verb accepts.
        // drift and duplicates carry no subject at all. journal, decisions, and
        // attention are read surfaces in this build.
        let item = ReviewActionTestFixtures.item(subjectID: "architecture")
        #expect(ReviewAction.suggestions(forSectionID: sectionID, item: item).isEmpty)
    }

    @Test("an item with no subjectID is never actionable, whatever its section", arguments: [
        "retire-ready", "contradicted", "open-work", "keystones", "context", "changes",
    ])
    func missingSubjectIDIsNeverActionable(sectionID: String) {
        let nilSubject = ReviewActionTestFixtures.item(
            subjectID: nil, status: .proposed)
        #expect(ReviewAction.suggestions(forSectionID: sectionID, item: nilSubject).isEmpty)
        let emptySubject = ReviewActionTestFixtures.item(
            subjectID: "", status: .proposed)
        #expect(ReviewAction.suggestions(forSectionID: sectionID, item: emptySubject).isEmpty)
    }

    @Test("the real weekly report's actionable rows are exactly the expected ones")
    func weeklyReportSuggestionsAreCorrect() async {
        // Against a report built by the REAL FAB5-G1 builder, not a hand-made
        // one — this is what catches a section id drifting apart from the policy.
        let report = await ReviewUIFixtures.report(.weekly)
        var offered: [String: Set<String>] = [:]
        for section in report.sections {
            for item in section.items {
                let actions = ReviewAction.suggestions(
                    forSectionID: section.id, item: item)
                if !actions.isEmpty {
                    offered[section.id, default: []].formUnion(actions.map(\.tool))
                }
            }
        }
        #expect(offered["retire-ready"] == ["moot_retire_fact"])
        #expect(offered["contradicted"] == ["moot_review_tunnel"])
        // Fading rows are rooms, drift rows are aggregates, duplicates is a gap.
        #expect(offered["fading"] == nil)
        #expect(offered["drift"] == nil)
        #expect(offered["duplicates"] == nil)
    }

    @Test("the real dashboard and morning reports offer only their drawer and tunnel rows")
    func dashboardAndMorningSuggestions() async {
        let dashboard = await ReviewUIFixtures.report(.dashboard)
        let momentum = dashboard.sections.first { $0.id == "momentum" }
        #expect(momentum?.items.isEmpty == false)
        for item in momentum?.items ?? [] {
            #expect(ReviewAction.suggestions(forSectionID: "momentum", item: item).isEmpty)
        }
        let keystones = dashboard.sections.first { $0.id == "keystones" }
        #expect(keystones?.items.isEmpty == false)
        for item in keystones?.items ?? [] {
            #expect(ReviewAction.suggestions(forSectionID: "keystones", item: item)
                == [.confirmMemory(id: item.subjectID ?? "")])
        }

        let morning = await ReviewUIFixtures.report(.morning)
        let openWork = morning.sections.first { $0.id == "open-work" }
        #expect(openWork?.items.isEmpty == false)
        for item in openWork?.items ?? [] {
            #expect(ReviewAction.suggestions(forSectionID: "open-work", item: item).count == 2)
        }
        // Journal entries carry no subjectID at all.
        let journal = morning.sections.first { $0.id == "journal" }
        for item in journal?.items ?? [] {
            #expect(ReviewAction.suggestions(forSectionID: "journal", item: item).isEmpty)
        }
    }
}

// MARK: - 4. Honesty of the confirmation text

@Suite("Review actions — permanence is stated, not implied (FAB5-G2)")
struct ReviewActionHonestyTests {

    @Test("exactly the two irreversible verbs are marked permanent")
    func permanenceMatchesTheSubstrate() {
        // Verified at pre-flight against the ARIA surface: no un-retire verb
        // exists for a KG fact, and a rejected tunnel pair is never re-proposed.
        // Accepting activates an edge but destroys nothing, and confirming is
        // undone by moot_update_memory(mutation: "contest").
        #expect(ReviewAction.retireFact(id: "F").isPermanent)
        #expect(ReviewAction.rejectTunnel(id: "T").isPermanent)
        #expect(!ReviewAction.acceptTunnel(id: "T").isPermanent)
        #expect(!ReviewAction.confirmMemory(id: "D").isPermanent)
    }

    @Test("every permanent action says so in words, not only by button role")
    func permanentActionsSayCannotBeUndone() {
        // A destructive button role is a visual and VoiceOver signal; the
        // sentence is what a user actually reads before committing.
        for action in ReviewActionTestFixtures.everyAction where action.isPermanent {
            #expect(action.confirmationMessage.contains("cannot be undone"),
                    "\(action) does not state its permanence")
        }
    }

    @Test("no action promises an undo the substrate cannot deliver")
    func nothingClaimsReversibility() {
        for action in ReviewActionTestFixtures.everyAction {
            let message = action.confirmationMessage.lowercased()
            #expect(!message.contains("undo it"))
            #expect(!message.contains("you can undo"))
            #expect(!message.contains("reversible"))
        }
    }

    @Test("every action has distinct button, VoiceOver, title, and message text")
    func displayTextIsCompleteAndDistinct() {
        let actions = ReviewActionTestFixtures.everyAction
        for action in actions {
            #expect(!action.label.isEmpty)
            #expect(!action.accessibilityLabel.isEmpty)
            #expect(!action.confirmationTitle.isEmpty)
            #expect(!action.confirmationMessage.isEmpty)
            // The screen-reader label must carry more than the bare verb: a
            // VoiceOver user hears the button out of its visual context.
            #expect(action.accessibilityLabel != action.label)
        }
        #expect(Set(actions.map(\.label)).count == actions.count)
        #expect(Set(actions.map(\.accessibilityLabel)).count == actions.count)
        #expect(Set(actions.map(\.confirmationTitle)).count == actions.count)
        #expect(Set(actions.map(\.confirmationMessage)).count == actions.count)
    }

    @Test("the retire message explains that re-filing is not a restore")
    func retireMessageExplainsRefile() {
        // The one place a user could reasonably assume an undo exists: re-filing
        // the same subject/predicate/object. It produces a NEW fact row, which is
        // a materially different thing, so the prompt says so.
        let message = ReviewAction.retireFact(id: "F").confirmationMessage
        #expect(message.contains("new fact"))
    }
}

// MARK: - Fixtures

enum ReviewActionTestFixtures {
    /// One of every action the Review Center can offer, so the gate is proved for
    /// all four verbs rather than for a convenient one. Ids are real rows from
    /// FAB5-G1's live capture.
    static let everyAction: [ReviewAction] = [
        .retireFact(id: "8F3EB809-10CD-40C0-9989-49EE6FA85A8D"),
        .acceptTunnel(id: "DAAAE428-B717-4053-93F7-77AD5E561438"),
        .rejectTunnel(id: "DAAAE428-B717-4053-93F7-77AD5E561438"),
        .confirmMemory(id: "DFA470F5-4D6C-48E6-AF8C-56E535F1DD43"),
    ]

    /// A minimal item — only the fields the action policy reads.
    static func item(
        subjectID: String?,
        status: ReviewItemStatus = .recorded
    ) -> ReviewItem {
        ReviewItem(
            id: "test:\(subjectID ?? "none")",
            title: subjectID ?? "aggregate",
            detail: "fixture row",
            subjectID: subjectID,
            status: status,
            provenance: ReviewProvenance(
                surface: .contradiction, responseLine: "fixture line"))
    }
}
