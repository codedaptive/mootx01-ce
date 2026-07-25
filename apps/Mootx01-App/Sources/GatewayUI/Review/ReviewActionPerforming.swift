import Foundation
import AriaMCP        // JSONValue
import MootGateway
import MootIntentKit  // MootToolCalling

// MARK: - Review suggestions  (FAB5-G2 — suggest, then act only on a tap)
//
// ROADMAP.md, "Ask what MOOT remembers": "MOOTx01 will suggest. You remain in
// control. Memory changes stay inspectable and reversible."
//
// This file is where "you remain in control" is enforced structurally rather
// than by convention. Three types:
//
//   ReviewAction              what could be done to one item, and through which
//                             registered ARIA tool
//   ReviewActionPerforming    the narrow mutation seam (one method), so a test
//                             can substitute a recorder for the live bridge
//   ReviewActionCoordinator   the two-phase gate: asking is not doing
//
// THE INVARIANT, and why it is shaped this way. A suggestion row cannot mutate
// anything, because a row has no way to reach the estate: the only path is
// `ReviewActionCoordinator.commitPending()`, and the only way to get a pending
// action is `request(_:)`, which sets state and calls nothing. So "no mutation
// without an explicit tap" is a property of the type, not a promise about the
// view code, and `ReviewActionTests` asserts it by counting calls on a recorder.
//
// REVERSIBILITY, honestly. The substrate has no inverse for two of these verbs
// (verified at pre-flight against ToolProjection/ToolDispatch): a rejected
// tunnel is never re-proposed, and no un-retire verb exists for a KG fact —
// re-filing with `moot_file_fact` produces a NEW row, which is not an undo. So
// no Undo button ships. Instead every permanent action states its permanence in
// its confirmation prompt, and `ReviewAction.isPermanent` is what drives both
// that wording and the destructive button role. Kong ruling D3.

// MARK: - ReviewAction

/// One thing the user may choose to do to one review item.
///
/// Each case names the registered ARIA tool it routes to. No case invents a
/// capability: `merge` is absent because no merge or duplicate-detection verb
/// exists at the ARIA surface at all (which is why FAB5-G1 ships Weekly's
/// `duplicates` section as an explained gap, and why this enum has no
/// `duplicates` counterpart).
enum ReviewAction: Hashable, Sendable {
    /// `moot_retire_fact(id:)` — invalidate a KG fact whose subject+predicate
    /// has more than one active object. PERMANENT.
    case retireFact(id: String)
    /// `moot_review_tunnel(tunnel_id:, verdict: "accept")` — activate a proposed
    /// `contradicts` edge. No inverse verb exists once activated.
    case acceptTunnel(id: String)
    /// `moot_review_tunnel(tunnel_id:, verdict: "reject")` — withdraw a proposed
    /// edge. PERMANENT: the pair is never re-proposed.
    case rejectTunnel(id: String)
    /// `moot_confirm_memory(id:)` — mark a drawer user-verified. The one
    /// reversible action here: `moot_update_memory(id:, mutation: "contest")`
    /// undoes it, and confirming forecloses nothing in the first place.
    case confirmMemory(id: String)

    /// The registered tool name. A typo here is a runtime tool-not-found, so
    /// these are transcribed from `ToolDispatch`'s dispatch switch.
    var tool: String {
        switch self {
        case .retireFact: return "moot_retire_fact"
        case .acceptTunnel, .rejectTunnel: return "moot_review_tunnel"
        case .confirmMemory: return "moot_confirm_memory"
        }
    }

    /// The argument dictionary the tool requires. Argument NAMES differ per tool
    /// (`id` for the fact and memory verbs, `tunnel_id` plus `verdict` for the
    /// tunnel verb) — verified against `ToolDispatcher.runRetireFact`,
    /// `runReviewTunnel`, and `runConfirmMemory`.
    var arguments: [String: JSONValue] {
        switch self {
        case .retireFact(let id), .confirmMemory(let id):
            return ["id": .string(id)]
        case .acceptTunnel(let id):
            return ["tunnel_id": .string(id), "verdict": .string("accept")]
        case .rejectTunnel(let id):
            return ["tunnel_id": .string(id), "verdict": .string("reject")]
        }
    }

    /// The estate row this acts on, for display in the confirmation prompt.
    var subjectID: String {
        switch self {
        case .retireFact(let id), .acceptTunnel(let id),
             .rejectTunnel(let id), .confirmMemory(let id):
            return id
        }
    }

    /// Whether the substrate offers no way back. Drives the destructive button
    /// role and the permanence sentence in the prompt.
    var isPermanent: Bool {
        switch self {
        case .retireFact, .rejectTunnel: return true
        // Accepting activates an edge and no verb un-activates it, but nothing is
        // destroyed and the linked drawers stay fully actionable — so it is not
        // presented as a destructive act.
        case .acceptTunnel, .confirmMemory: return false
        }
    }

    // MARK: Display text

    /// The button label.
    var label: String {
        switch self {
        case .retireFact: return String(localized: "Retire")
        case .acceptTunnel: return String(localized: "Accept")
        case .rejectTunnel: return String(localized: "Reject")
        case .confirmMemory: return String(localized: "Confirm")
        }
    }

    /// The VoiceOver label. Distinct from `label` because a screen reader hears
    /// the button out of its visual context, so "Retire" alone is ambiguous.
    var accessibilityLabel: String {
        switch self {
        case .retireFact: return String(localized: "Retire this fact")
        case .acceptTunnel: return String(localized: "Accept this contradiction")
        case .rejectTunnel: return String(localized: "Reject this contradiction")
        case .confirmMemory: return String(localized: "Confirm this memory")
        }
    }

    /// The confirmation prompt's title.
    var confirmationTitle: String {
        switch self {
        case .retireFact: return String(localized: "Retire this fact?")
        case .acceptTunnel: return String(localized: "Accept this contradiction?")
        case .rejectTunnel: return String(localized: "Reject this contradiction?")
        case .confirmMemory: return String(localized: "Confirm this memory?")
        }
    }

    /// The confirmation prompt's body: what the action does, and — for the two
    /// permanent verbs — that it cannot be taken back. The permanence sentence is
    /// not optional polish; it is the only honest thing to say about a verb the
    /// substrate cannot reverse.
    var confirmationMessage: String {
        switch self {
        case .retireFact:
            return String(localized: "The fact stops being active. This cannot be undone — MOOT has no un-retire, and re-filing it later would create a new fact rather than restore this one.")
        case .acceptTunnel:
            return String(localized: "The contradiction becomes a recorded link between these two memories.")
        case .rejectTunnel:
            return String(localized: "The proposed link is withdrawn. This cannot be undone — this pair will never be suggested again.")
        case .confirmMemory:
            return String(localized: "The memory is marked as verified by you. You can contest it later.")
        }
    }

    // MARK: Suggestion rules

    /// The actions offered for one item of one section, in button order.
    ///
    /// The whole action policy lives here so the rules are in one readable place
    /// and are testable without a view. Each mapping is grounded in what FAB5-G1
    /// actually puts in `subjectID` for that section (verified at pre-flight):
    ///
    ///   retire-ready            KG fact row id      → Retire
    ///   contradicted, conflicts,
    ///   open-work               tunnel id           → Accept / Reject
    ///   keystones, context,
    ///   changes                 drawer id           → Confirm
    ///   fading, momentum        room name           → nothing takes a room name
    ///   drift, duplicates       nil                 → nothing to act on
    ///
    /// Two guards apply to every case: an item with no `subjectID` is never
    /// actionable, and a tunnel is only settleable while `.proposed` — a
    /// `.recorded` edge is already decided and `moot_review_tunnel` refuses it
    /// ("a settled edge cannot be rewritten by a stale review").
    static func suggestions(
        forSectionID sectionID: String, item: ReviewItem
    ) -> [ReviewAction] {
        guard let subjectID = item.subjectID, !subjectID.isEmpty else { return [] }
        switch sectionID {
        case "retire-ready":
            return [.retireFact(id: subjectID)]
        case "contradicted", "conflicts", "open-work":
            guard item.status == .proposed else { return [] }
            return [.acceptTunnel(id: subjectID), .rejectTunnel(id: subjectID)]
        case "keystones", "context", "changes":
            return [.confirmMemory(id: subjectID)]
        default:
            return []
        }
    }
}

// MARK: - ReviewActionPerforming

/// The seam every review mutation goes through. One method, deliberately: it
/// cannot grow into a second tool-calling abstraction beside `MootToolCalling`,
/// and a test conformance has exactly one thing to record.
///
/// `@MainActor` because the production conformance resolves the live bridge off
/// the main-actor `AppModel` on each call — the bridge attaches asynchronously
/// after launch, so a performer built at view-construction time cannot capture
/// it once.
@MainActor
protocol ReviewActionPerforming {
    /// Run one action against the estate.
    ///
    /// Non-throwing, like FAB5-G1's read seam: a refusal is an outcome to show
    /// the user, not an error to unwind through the view.
    func perform(_ action: ReviewAction) async -> ReviewActionOutcome
}

/// What came back. `message` is the substrate's own text — "retired fact <id>",
/// or its refusal reason — and is shown verbatim, never localized. The single
/// exception is the no-estate-attached case below, where there are no substrate
/// words to quote.
struct ReviewActionOutcome: Equatable, Sendable {
    let action: ReviewAction
    let message: String
    let isError: Bool
}

// MARK: - AppModelReviewActionPerformer

/// Drives the app's live tool surface. The production conformance.
///
/// Uses the SAME seam FAB5-G1's reader uses (`MootToolCalling`, which
/// `MootBridge` conforms to) — but note that these are MUTATION verbs where G1's
/// were read verbs. If a future `MootBridge` adds gating on mutation verbs (rate
/// limits, a confirmation ceiling), this performer inherits it silently; that is
/// acceptable today because no such gate exists, and this comment is the record
/// of the dependency.
@MainActor
struct AppModelReviewActionPerformer: ReviewActionPerforming {
    /// Resolved per call, not captured once: `AppModel.bridge` is nil until
    /// `AppModel.start()` attaches it.
    private let resolveCaller: () -> (any MootToolCalling)?

    init(resolveCaller: @escaping () -> (any MootToolCalling)?) {
        self.resolveCaller = resolveCaller
    }

    init(appModel: AppModel) {
        self.init(resolveCaller: { [weak appModel] in appModel?.bridge })
    }

    func perform(_ action: ReviewAction) async -> ReviewActionOutcome {
        guard let caller = resolveCaller() else {
            // No substrate text exists for this, so this one message is UI copy.
            return ReviewActionOutcome(
                action: action,
                message: String(localized: "Not attached to an estate — nothing was changed."),
                isError: true)
        }
        let result = await caller.callTool(action.tool, arguments: action.arguments)
        return ReviewActionOutcome(
            action: action, message: result.text, isError: result.isError)
    }
}

// MARK: - ReviewActionCoordinator

/// The two-phase gate between a suggestion and a mutation.
///
/// `request(_:)` stages an action and performs nothing. `commitPending()` is the
/// only method that reaches the estate, and it can only act on what `request`
/// staged. `cancelPending()` discards. A view binds its confirmation prompt to
/// `pending`; the prompt's confirm button is the explicit tap the mission
/// requires, and `ReviewActionTests` proves the ordering by counting calls.
@MainActor
@Observable
final class ReviewActionCoordinator {
    /// The action awaiting the user's confirmation, or nil.
    private(set) var pending: ReviewAction?
    /// The last completed action's result, for the inline receipt under the row.
    private(set) var lastOutcome: ReviewActionOutcome?
    /// Actions that have completed successfully, so a settled row can stop
    /// offering buttons without rebuilding the whole report. Keyed by estate row
    /// id, since that is what a `ReviewItem` carries.
    private(set) var settledSubjectIDs: Set<String> = []
    /// True while a commit is in flight, so the prompt's button cannot be
    /// double-tapped into two calls.
    private(set) var isPerforming = false

    private let performer: any ReviewActionPerforming

    init(performer: any ReviewActionPerforming) {
        self.performer = performer
    }

    /// Stage an action for confirmation. Performs NOTHING — this is the whole
    /// point of the type.
    func request(_ action: ReviewAction) {
        guard !isPerforming else { return }
        pending = action
    }

    /// Discard the staged action.
    func cancelPending() {
        pending = nil
    }

    /// Perform the staged action, and only the staged action.
    ///
    /// Returns without calling anything when nothing is staged, so a stray
    /// invocation cannot mutate the estate.
    func commitPending() async {
        guard let action = pending, !isPerforming else { return }
        isPerforming = true
        // Cleared before the await: the prompt dismisses as the work starts, and
        // a second commit cannot pick the same action up again mid-flight.
        pending = nil
        let outcome = await performer.perform(action)
        lastOutcome = outcome
        if !outcome.isError {
            settledSubjectIDs.insert(action.subjectID)
        }
        isPerforming = false
    }

    /// Whether this item still has an open decision. False once one of its
    /// actions has succeeded — the estate row has moved on, and the report in
    /// hand is a snapshot taken before that.
    func isSettled(_ item: ReviewItem) -> Bool {
        guard let subjectID = item.subjectID else { return false }
        return settledSubjectIDs.contains(subjectID)
    }

    /// The receipt to show under a row: the substrate's own words about what
    /// happened, or nil when this row is not the one that was acted on.
    func outcomeMessage(for item: ReviewItem) -> String? {
        guard let outcome = lastOutcome,
              outcome.action.subjectID == item.subjectID else { return nil }
        return outcome.message
    }
}
