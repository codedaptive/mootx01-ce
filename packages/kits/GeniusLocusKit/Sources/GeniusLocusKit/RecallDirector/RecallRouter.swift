import CorpusKit

// MARK: — Recall router

/// One entry in the recall route list: a preference key, a predicate over the
/// question text, and a transform over the request.
///
/// The router is a pure function over the request. It never reads the estate:
/// the director resolves every route's preference (one manifest read per
/// route, `"off"` → false, anything else or absent → true) and hands the
/// resolved map to `applyRecallRoutes(_:preferences:)`.
struct RecallRoute: Sendable {
    /// Estate-manifest key that turns this route on or off. Also the value
    /// reported in `GLKRecallResult.route` when the route fires, so the key
    /// read and the key reported are one string by construction.
    let preferenceKey: String
    /// True when the question's text should take this route.
    let predicate: @Sendable (String) -> Bool
    /// The request as it leaves the router when this route fires.
    let transform: @Sendable (GLKRecallRequest) -> GLKRecallRequest
}

/// Route 1 — cross-encoder conversation routing.
///
/// - Preference: `cross_encoder_routing` estate-manifest key, absent = on.
/// - Predicate: `isConversationQuestion` — the question carries a quoted
///   phrase, a speaker cue or a conversation reference.
/// - Transform: set `rerankDirective = .apply(reason: crossEncoderRouteReason)`
///   — the degradable directive, never the transcript operation's fail-closed
///   `.strictTranscript()`.
///
/// The degradable directive reranks the head when the stage can run and, when
/// it cannot, reports the degrade reason and leaves the ordinary lane order
/// standing. `.strictTranscript()` fails closed (an empty strict pool returns
/// zero rows) and belongs to the `moot_memory_recall_transcript` operation
/// alone: a routed ordinary question — one that merely trips a cue such as
/// "meeting" — must never lose results to it.
///
/// Mirrors Rust `CROSS_ENCODER_ROUTE` (recall_router.rs).
let crossEncoderRoute = RecallRoute(
    preferenceKey: "cross_encoder_routing",
    predicate: isConversationQuestion,
    transform: { $0.replacing(rerankDirective: .apply(reason: crossEncoderRouteReason)) }
)

/// Diagnostic code Route 1 writes into its directive; the stage echoes it in
/// the recall report so a reader can tell a routed rerank from one an operation
/// asked for. Shared with the Rust twin (`CROSS_ENCODER_ROUTE_REASON`).
let crossEncoderRouteReason = "route:cross_encoder_routing"

/// The ordered route list the director applies once per scored recall.
/// `applyRecallRoutes` fires the first entry whose preference is on and whose
/// predicate is true, then stops. Adding a route is appending an entry here
/// (with its own preference key, predicate and transform); the apply function
/// does not change. Day one: one route.
///
/// Mirrors Rust `RECALL_ROUTES` (recall_router.rs); same order, same keys.
let recallRoutes: [RecallRoute] = [crossEncoderRoute]

/// Route 1 predicate: the question is about a conversation. It fires on
/// quoted speech, a speaker cue ("said", "told", "asked", "replied",
/// "mentioned"), the "what did X say" form, or a reference to a session,
/// conversation, chat, call, meeting or transcript. Ordinary questions about
/// documents or facts do not fire. Case-insensitive. The cue list is the
/// cross-port contract and matches Rust `CONVERSATION_CUES` exactly.
@Sendable
func isConversationQuestion(_ queryText: String) -> Bool {
    let text = queryText.lowercased()
    if text.contains("\"") || text.contains("\u{201C}") || text.contains("\u{201D}") { return true }
    return conversationCues.contains { text.contains($0) }
}

/// Cue substrings shared with the Rust twin (`CONVERSATION_CUES`), kept as one
/// list so both ports route the same questions. Leading spaces on the verb
/// cues keep "unsaid" and "unasked" from matching.
let conversationCues: [String] = [
    " said", " says", " told", " asked", " replied", " mentioned",
    "what did", "who said", "conversation", "transcript", "chat",
    "session", "meeting", "call with", "discussed",
]

/// Walks `recallRoutes` in order and applies the first route whose preference
/// is on and whose predicate matches the question text, then stops. A request
/// that already carries a `rerankDirective` is never re-routed: the
/// strict-transcript operation builds its own directive and must keep it. A
/// request with no question text takes no route.
///
/// `preferences` is the director's resolved on/off map keyed by preference
/// key (see `provisionedRecallRoutePreferences(estate:)`). A route whose key is
/// missing from the map is treated as off: the director resolves every key in
/// `recallRoutes`, so a miss is a wiring fault and the safe reading is not to
/// fire.
///
/// Returns the (possibly-transformed) request and the preference key of the
/// route that fired, or `nil` when no route fired.
///
/// Mirrors Rust `apply_recall_routes` (recall_router.rs).
func applyRecallRoutes(
    _ request: GLKRecallRequest,
    preferences: [String: Bool]
) -> (request: GLKRecallRequest, firedRouteKey: String?) {
    // A request that already carries a directive is never re-routed.
    // The strict-transcript operation builds its own directive and must keep it.
    guard request.rerankDirective == nil else { return (request, nil) }
    // Every predicate is over the question text; no text, no route.
    guard let queryText = request.queryText, !queryText.isEmpty else {
        return (request, nil)
    }

    for route in recallRoutes {
        // Preference first: an off route never runs its predicate.
        guard preferences[route.preferenceKey] == true else { continue }
        if route.predicate(queryText) {
            return (route.transform(request), route.preferenceKey)
        }
    }

    return (request, nil)
}
