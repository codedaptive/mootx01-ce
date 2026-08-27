import AriaMCPWire
import Foundation
import MootCommunityGateway

// MARK: - Community recall presentation (census com.recall.result R-C6,
// com.recall.empty R-C7)
//
// The Recall pane's human rendering of a `moot_memory_search` reply. The
// reply's `structuredContent` block — {id, subject?, firstSentence?,
// content?, room?, eventTime} per row, declared by the tool's outputSchema —
// is the one truthful source of per-record data: the display text
// interpolates caller-authored drawer content, so it is never parsed for
// structure here (same forgery argument as ReviewLineParsing's memory_search
// rule). The verbatim reply is preserved in every outcome for the labeled
// secondary disclosure; it is never the primary rendering.
//
// Decoding fails CLOSED: a reply whose structured block is missing, has the
// wrong shape, or contains a row without an id is presented as
// `.unstructured` — the honestly labeled verbatim reply — never as a
// partially decoded list. Silently dropping rows would misstate how many
// records matched.

/// One recalled record, decoded from a `moot_memory_search`
/// structuredContent row.
struct CommunityRecallResult: Equatable, Identifiable, Sendable {
    /// The drawer identifier — technical; required by the wire contract but
    /// never rendered as the record's primary name.
    let id: String
    /// The drawer subject, when the record carries one.
    let subject: String?
    /// The drawer's first sentence; the wire omits it when it duplicates the
    /// subject.
    let firstSentence: String?
    /// The drawer body (restricted rows carry the server's redaction marker
    /// verbatim — presenting it unchanged is the truthful rendering).
    let content: String?
    /// The room the record lives in, when the row names one.
    let room: String?
    /// The row's `eventTime` instant; nil when absent or unparseable — an
    /// unreadable date is absent, never guessed.
    let recordedAt: Date?

    /// The record's primary human name: subject, then first sentence, then an
    /// honest absence marker. Never the identifier.
    var displayTitle: String {
        subject ?? firstSentence ?? String(localized: "recall.result.no.subject")
    }
}

/// The Recall pane's decoded state, in the order the pane distinguishes them.
enum CommunityRecallOutcome: Equatable, Sendable {
    /// Nothing has been searched yet; the pane shows only the query controls.
    case idle
    /// Matching records, plus the verbatim reply for the labeled disclosure.
    case results([CommunityRecallResult], reply: String)
    /// The estate answered and zero records matched (R-C7's explicit state).
    case empty(reply: String)
    /// The reply carried no decodable structured block; the pane shows an
    /// honest explanation with the labeled verbatim reply.
    case unstructured(reply: String)
    /// The call failed; the pane states that and shows the labeled reply.
    case failed(reply: String)
}

/// Decodes a `moot_memory_search` call record into the pane's outcome.
enum CommunityRecallPresentation {

    /// The human outcome for one completed recall call.
    static func outcome(of call: GatewayCall) -> CommunityRecallOutcome {
        if call.isError {
            return .failed(reply: call.text)
        }
        guard let rows = call.structured?.objectValue?["results"]?.arrayValue else {
            return .unstructured(reply: call.text)
        }
        var items: [CommunityRecallResult] = []
        for row in rows {
            // A row without an object shape or an id fails the WHOLE decode
            // closed: presenting the remaining rows would misstate the match
            // count, so the labeled verbatim reply stands in instead.
            guard let object = row.objectValue,
                  let id = object["id"]?.stringValue else {
                return .unstructured(reply: call.text)
            }
            items.append(CommunityRecallResult(
                id: id,
                subject: object["subject"]?.stringValue,
                firstSentence: object["firstSentence"]?.stringValue,
                content: object["content"]?.stringValue,
                room: object["room"]?.stringValue,
                recordedAt: object["eventTime"]?.stringValue
                    .flatMap { ISO8601DateFormatter().date(from: $0) }
            ))
        }
        return items.isEmpty ? .empty(reply: call.text)
                             : .results(items, reply: call.text)
    }
}
