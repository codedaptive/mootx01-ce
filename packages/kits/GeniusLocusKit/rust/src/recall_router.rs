use std::collections::BTreeMap;

use corpus_kit::encoder::RerankDirective;
use crate::recall::GLKRecallRequest;

// MARK: — Recall router

/// One entry in the recall route list: a preference key, a predicate over the
/// question text, and a transform over the request.
///
/// The router is a pure function over the request. It never reads the estate:
/// the coordinator resolves every route's preference (one manifest read per
/// route, `"off"` → false, anything else or absent → true) and hands the
/// resolved map to `apply_recall_routes`.
///
/// Mirrors Swift `RecallRoute` (RecallRouter.swift).
pub struct RecallRoute {
    /// Estate-manifest key that turns this route on or off. Also the value
    /// reported in `GLKRecallResult.route` when the route fires, so the key
    /// read and the key reported are one string by construction.
    pub preference_key: &'static str,
    /// True when the question's text should take this route.
    pub predicate: fn(&str) -> bool,
    /// The request as it leaves the router when this route fires.
    pub transform: fn(GLKRecallRequest) -> GLKRecallRequest,
}

/// Route 1 — cross-encoder conversation routing.
///
/// - Preference: `cross_encoder_routing` estate-manifest key, absent = on.
/// - Predicate: `is_conversation_question` — the question carries a quoted
///   phrase, a speaker cue or a conversation reference.
/// - Transform: set `rerank_directive =
///   RerankDirective::apply(Some(CROSS_ENCODER_ROUTE_REASON))` — the
///   degradable directive, never the transcript operation's fail-closed
///   `strict_transcript`.
///
/// Mirrors Swift `crossEncoderRoute` (RecallRouter.swift).
pub const CROSS_ENCODER_ROUTE: RecallRoute = RecallRoute {
    preference_key: "cross_encoder_routing",
    predicate: is_conversation_question,
    transform: apply_cross_encoder_rerank,
};

/// Diagnostic code Route 1 writes into its directive; the stage echoes it in
/// the recall report so a reader can tell a routed rerank from one an operation
/// asked for. Shared with the Swift twin (`crossEncoderRouteReason`).
pub const CROSS_ENCODER_ROUTE_REASON: &str = "route:cross_encoder_routing";

/// The ordered route list the coordinator applies once per scored recall.
/// `apply_recall_routes` fires the first entry whose preference is on and
/// whose predicate is true, then stops. Adding a route is appending an entry
/// here (with its own preference key, predicate and transform); the apply
/// function does not change. Day one: one route.
///
/// Mirrors Swift `recallRoutes` (RecallRouter.swift); same order, same keys.
pub const RECALL_ROUTES: &[RecallRoute] = &[CROSS_ENCODER_ROUTE];

/// Cue substrings shared with the Swift twin (`conversationCues`), kept as one
/// list so both ports route the same questions. Leading spaces on the verb
/// cues keep "unsaid" and "unasked" from matching.
pub const CONVERSATION_CUES: &[&str] = &[
    " said", " says", " told", " asked", " replied", " mentioned",
    "what did", "who said", "conversation", "transcript", "chat",
    "session", "meeting", "call with", "discussed",
];

/// Route 1 predicate: the question is about a conversation. It fires on
/// quoted speech, a speaker cue ("said", "told", "asked", "replied",
/// "mentioned"), the "what did X say" form, or a reference to a session,
/// conversation, chat, call, meeting or transcript. Ordinary questions about
/// documents or facts do not fire. Case-insensitive.
///
/// Mirrors Swift `isConversationQuestion` (RecallRouter.swift).
pub fn is_conversation_question(query: &str) -> bool {
    let text = query.to_lowercase();
    if text.contains('"') || text.contains('\u{201C}') || text.contains('\u{201D}') {
        return true;
    }
    CONVERSATION_CUES.iter().any(|cue| text.contains(cue))
}

/// Route 1 transform: the request leaves carrying the degradable `apply`
/// directive, so the cross-encoder stage reranks the head when it can run and
/// otherwise reports its degrade reason and leaves the lane order standing.
///
/// Not `strict_transcript`: that directive fails closed (an empty strict pool
/// returns zero rows) and belongs to the `moot_memory_recall_transcript`
/// operation alone. A routed ordinary question — one that merely trips a cue
/// such as "meeting" — must never lose results to it.
fn apply_cross_encoder_rerank(request: GLKRecallRequest) -> GLKRecallRequest {
    request.with_rerank_directive(RerankDirective::apply(Some(CROSS_ENCODER_ROUTE_REASON)))
}

/// Walks `RECALL_ROUTES` in order and applies the first route whose preference
/// is on and whose predicate matches the question text, then stops. A request
/// that already carries a `rerank_directive` is never re-routed: the
/// strict-transcript operation builds its own directive and must keep it. A
/// request with no question text takes no route.
///
/// `preferences` is the coordinator's resolved on/off map keyed by preference
/// key (see `EstateCoordinator::provisioned_recall_route_preferences`). A
/// route whose key is missing from the map is treated as off: the coordinator
/// resolves every key in `RECALL_ROUTES`, so a miss is a wiring fault and the
/// safe reading is not to fire.
///
/// Returns the (possibly-transformed) request and the preference key of the
/// route that fired, or `None` when no route fired.
///
/// Mirrors Swift `applyRecallRoutes(_:preferences:)` (RecallRouter.swift).
pub fn apply_recall_routes(
    request: GLKRecallRequest,
    preferences: &BTreeMap<String, bool>,
) -> (GLKRecallRequest, Option<String>) {
    // A request that already carries a directive is never re-routed.
    // The strict-transcript operation builds its own directive and must keep it.
    if request.rerank_directive.is_some() {
        return (request, None);
    }
    // Every predicate is over the question text; no text, no route.
    let Some(query) = request.query_text.as_deref().filter(|q| !q.is_empty()) else {
        return (request, None);
    };

    for route in RECALL_ROUTES {
        // Preference first: an off route never runs its predicate.
        if preferences.get(route.preference_key).copied() != Some(true) {
            continue;
        }
        if (route.predicate)(query) {
            let key = route.preference_key.to_string();
            return ((route.transform)(request), Some(key));
        }
    }

    (request, None)
}
