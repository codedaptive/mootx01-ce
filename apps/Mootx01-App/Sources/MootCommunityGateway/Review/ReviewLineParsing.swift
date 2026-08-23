import Foundation
import AriaMCPWire

private struct CommunityRecalledDrawer: Sendable, Equatable {
    let id: String
    let content: String
    let room: String
}

private enum CommunityStructuredRecallResults {
    static func drawers(from structured: JSONValue?) -> [CommunityRecalledDrawer] {
        guard let results = structured?.objectValue?["results"]?.arrayValue else {
            return []
        }
        return results.compactMap { row in
            guard let object = row.objectValue,
                  let id = object["id"]?.stringValue,
                  let room = object["room"]?.stringValue,
                  let content = object["content"]?.stringValue else {
                return nil
            }
            return CommunityRecalledDrawer(id: id, content: content, room: room)
        }
    }
}

// MARK: - ReviewLineParsing  (FAB5-G1 — ARIA text responses → ReviewItem)
//
// The ARIA tool surface answers in text, so aggregation starts with a parse.
// Every format below is transcribed from the code that PRODUCES it and was
// confirmed against live responses from a local estate on 2026-07-24:
//
//   LensTools.list(_:_:)            "<heading>: N result(s)" then "  - <item>"
//   moot_lens_theme_weather         "  - <room id> momentum=<f64>"
//   moot_lens_keystones             "  - <drawer id> centrality=<f64>"
//   moot_lens_cohesion              "cohesion_outliers (considered N): M result(s)"
//                                   then "  - <drawer id>"
//   moot_lens_drift                 "drift: before=N after=M" / "jensenShannon: <f64>"
//                                   / "klDivergence: <f64>"
//   moot_lens_contradiction         "contradicts_tunnels: N" | "…: none", then
//                                   "  <src> contradicts <tgt> (tunnel <id>)[ …]";
//                                   "conflicting_facts: N subject+predicate pair(s)"
//                                   | "…: none", then "  [<subject>] <predicate>"
//                                   and "    <fact id>  object=[<o>]  source=<s>  filed=<iso>"
//   moot_fact_search                "<id>  [<subject>] <predicate> [<object>]  filed=<iso>  source=<s>"
//   moot_read_journal               "journal for <agent>: N entry(s)" then "[<iso>]  <entry>"
//   moot_memory_search              NOT text-parsed: the reply's structuredContent
//                                   rows ({id, room, content, subject}) are decoded
//                                   by StructuredRecallResults (MootIntentKit) —
//                                   drawer content is caller-controlled, so the
//                                   display text is never a source of drawer data.
//
// Parsing rules that hold everywhere here:
//  - Unrecognized lines are SKIPPED, never guessed at. Headers, `hint:` lines
//    (theme_weather appends one on thin estates), and provenance footers all
//    fall through harmlessly.
//  - A malformed numeric field yields `magnitude: nil`, not 0. A zero score and
//    an unreadable score are different facts.
//  - Nothing is fabricated: no item exists that no response line produced.

enum ReviewLineParsing {

    // MARK: Shared helpers

    /// The `  - ` bullet `LensTools.list` emits.
    private static let bulletPrefix = "  - "

    /// Bullet payloads from a `LensTools.list` response, header and trailing
    /// hint lines dropped.
    static func bulletPayloads(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.hasPrefix(bulletPrefix) }
            .map { String($0.dropFirst(bulletPrefix.count)) }
    }

    /// Split `<token> <key>=<value>` into its token and numeric value. Returns a
    /// nil value when the payload has no `key=` field or the number is
    /// unreadable — the token is still usable.
    static func tokenAndScore(_ payload: String, key: String) -> (token: String, score: Double?) {
        let marker = " \(key)="
        guard let range = payload.range(of: marker) else {
            return (payload.trimmingCharacters(in: .whitespaces), nil)
        }
        let token = String(payload[payload.startIndex..<range.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        let raw = String(payload[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        return (token, Double(raw))
    }

    /// Value of a `key=value` field in a whitespace-delimited line.
    static func field(_ line: String, key: String) -> String? {
        guard let range = line.range(of: "\(key)=") else { return nil }
        let rest = line[range.upperBound...]
        let value = rest.prefix { !$0.isWhitespace }
        return value.isEmpty ? nil : String(value)
    }

    /// Parse an ISO8601 instant the ARIA surfaces emit (`filed=`, `[<iso>]`).
    /// Both are written with a plain `ISO8601DateFormatter`, no fractional seconds.
    static func instant(_ raw: String) -> Date? {
        ISO8601DateFormatter().date(from: raw)
    }

    /// Text between the first `[` and the following `]`, and the remainder after
    /// it.
    ///
    /// Sole caller: the SUBJECT field in `facts(_:_:)`. First-`]` matching, which
    /// is correct for subjects — every subject the KG surfaces emit is a short
    /// slug (`ce-release`, `forge_v10`, `aria`). It would TRUNCATE a subject
    /// containing a literal `]`; no such subject has been observed on a real
    /// estate. Object values are different — they are free text and do carry
    /// brackets — which is why `facts(_:_:)` reads the object with its own
    /// last-`]` span instead of calling this. The asymmetry is deliberate; if a
    /// bracket-bearing subject ever appears, this helper is the place to fix.
    private static func bracketed(_ line: Substring) -> (inner: String, rest: Substring)? {
        guard let open = line.firstIndex(of: "["),
              let close = line[open...].firstIndex(of: "]") else { return nil }
        return (String(line[line.index(after: open)..<close]),
                line[line.index(after: close)...])
    }

    // MARK: theme_weather

    /// Per-room momentum. Positive = rising attention, negative = fading.
    /// Items keep the surface's own ordering (momentum descending).
    static func themeWeather(_ text: String, _ context: ReviewProvenanceContext) -> [ReviewItem] {
        bulletPayloads(text).enumerated().compactMap { ordinal, payload in
            let (room, momentum) = tokenAndScore(payload, key: "momentum")
            guard !room.isEmpty else { return nil }
            return ReviewItem(
                id: ReviewItem.makeID(surface: context.surface, subjectID: room, ordinal: ordinal),
                title: room,
                detail: payload,
                subjectID: room,
                magnitude: momentum,
                provenance: context.provenance(line: bulletPrefix + payload))
        }
    }

    // MARK: keystones

    /// Load-bearing memories, centrality descending.
    static func keystones(_ text: String, _ context: ReviewProvenanceContext) -> [ReviewItem] {
        bulletPayloads(text).enumerated().compactMap { ordinal, payload in
            let (drawerID, centrality) = tokenAndScore(payload, key: "centrality")
            guard !drawerID.isEmpty else { return nil }
            return ReviewItem(
                id: ReviewItem.makeID(surface: context.surface, subjectID: drawerID, ordinal: ordinal),
                title: drawerID,
                detail: payload,
                subjectID: drawerID,
                magnitude: centrality,
                provenance: context.provenance(line: bulletPrefix + payload))
        }
    }

    // MARK: cohesion

    /// Lexical odd-ones-out: bare drawer ids, no score in the response.
    static func cohesionOutliers(_ text: String, _ context: ReviewProvenanceContext) -> [ReviewItem] {
        bulletPayloads(text).enumerated().compactMap { ordinal, payload in
            let drawerID = payload.trimmingCharacters(in: .whitespaces)
            guard !drawerID.isEmpty else { return nil }
            return ReviewItem(
                id: ReviewItem.makeID(surface: context.surface, subjectID: drawerID, ordinal: ordinal),
                title: drawerID,
                detail: drawerID,
                subjectID: drawerID,
                provenance: context.provenance(line: bulletPrefix + payload))
        }
    }

    // MARK: drift

    /// Localization keys for the two divergence measures the drift lens reports.
    static let jensenShannonTitle = "review.item.jensenShannon"
    static let klDivergenceTitle = "review.item.klDivergence"

    /// Room-distribution divergence across the split instant.
    ///
    /// Returns no items when both sides of the split are empty: the lens still
    /// answers `0.0 / 0.0`, but a divergence between two empty distributions is
    /// not a finding, and emitting it would read as "no drift detected" on an
    /// estate where nothing could have drifted. The caller's section then carries
    /// the response's own `drift: before=0 after=0` line as its notice.
    static func drift(_ text: String, _ context: ReviewProvenanceContext) -> [ReviewItem] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let headline = lines.first(where: { $0.hasPrefix("drift:") }) else { return [] }
        let before = field(headline, key: "before").flatMap(Int.init)
        let after = field(headline, key: "after").flatMap(Int.init)
        guard (before ?? 0) > 0 || (after ?? 0) > 0 else { return [] }

        func measure(prefix: String, title: String, ordinal: Int) -> ReviewItem? {
            guard let line = lines.first(where: { $0.hasPrefix(prefix) }) else { return nil }
            let raw = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            return ReviewItem(
                id: ReviewItem.makeID(surface: context.surface, subjectID: nil, ordinal: ordinal),
                title: title,
                detail: headline,
                subjectID: nil,
                magnitude: Double(raw),
                provenance: context.provenance(line: line))
        }

        return [
            measure(prefix: "jensenShannon:", title: jensenShannonTitle, ordinal: 0),
            measure(prefix: "klDivergence:", title: klDivergenceTitle, ordinal: 1),
        ].compactMap { $0 }
    }

    // MARK: contradiction — tunnels

    /// `contradicts` tunnel pairs. Lines flagged `[proposed …]` are the
    /// contradiction hunter's agent-derived findings and carry `.proposed`, which
    /// is what makes them "open work" for the morning review.
    ///
    /// Endpoints the substrate redacted arrive as `<hidden>` (a Restricted or
    /// Secret drawer beyond the MCP disclosure ceiling). Those items are kept —
    /// the tunnel itself is disclosable and actionable via `moot_review_tunnel` —
    /// and the redaction is preserved verbatim in `detail`.
    static func contradictionTunnels(_ text: String, _ context: ReviewProvenanceContext) -> [ReviewItem] {
        var items: [ReviewItem] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            // Two-space indent, and BOTH markers the lens writes on every tunnel
            // row: the ` contradicts ` infix and the `(tunnel <id>)` annotation.
            // Requiring the annotation matters — the conflicting-facts block uses
            // the same two-space indent for its group headers, and a fact
            // predicate or subject containing the word "contradicts" would
            // otherwise be misread as a tunnel row.
            guard line.hasPrefix("  "), !line.hasPrefix("    "),
                  line.contains(" contradicts "), line.contains("(tunnel ") else { continue }
            let body = line.trimmingCharacters(in: .whitespaces)
            let tunnelID = tunnelIdentifier(in: body)
            let isProposed = body.contains("[proposed")
            // Drop the trailing "(tunnel …)" and the proposed annotation from the
            // human-facing detail; both are carried in subjectID/status already.
            let pairDescription = body.components(separatedBy: " (tunnel ").first ?? body
            items.append(ReviewItem(
                id: ReviewItem.makeID(
                    surface: context.surface, subjectID: tunnelID, ordinal: items.count),
                title: pairDescription,
                detail: body,
                subjectID: tunnelID,
                status: isProposed ? .proposed : .recorded,
                provenance: context.provenance(line: String(line))))
        }
        return items
    }

    /// The id inside `(tunnel <uuid>)`, or nil when the annotation is absent.
    private static func tunnelIdentifier(in body: String) -> String? {
        guard let start = body.range(of: "(tunnel ") else { return nil }
        let rest = body[start.upperBound...]
        guard let close = rest.firstIndex(of: ")") else { return nil }
        let id = rest[rest.startIndex..<close].trimmingCharacters(in: .whitespaces)
        return id.isEmpty ? nil : id
    }

    // MARK: contradiction — conflicting facts

    /// KG facts whose subject+predicate has more than one active object — the
    /// retire-ready candidates (settled with `moot_retire_fact`).
    ///
    /// The response nests: a two-space `  [<subject>] <predicate>` group header
    /// followed by four-space fact rows. Each fact row becomes one item titled
    /// with its group, so a consumer can show "these three objects all claim the
    /// same subject+predicate" without re-querying.
    static func conflictingFacts(_ text: String, _ context: ReviewProvenanceContext) -> [ReviewItem] {
        var items: [ReviewItem] = []
        var currentGroup = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("    ") {
                guard !currentGroup.isEmpty else { continue }
                let body = line.trimmingCharacters(in: .whitespaces)
                // The fact id is the first whitespace-delimited token.
                let factID = body.prefix { !$0.isWhitespace }
                guard !factID.isEmpty else { continue }
                items.append(ReviewItem(
                    id: ReviewItem.makeID(
                        surface: context.surface, subjectID: String(factID), ordinal: items.count),
                    title: currentGroup,
                    detail: body,
                    subjectID: String(factID),
                    occurredAt: field(body, key: "filed").flatMap(instant),
                    provenance: context.provenance(line: String(line))))
            } else if line.hasPrefix("  "), !line.contains("(tunnel "),
                      line.trimmingCharacters(in: .whitespaces).hasPrefix("[") {
                // Group header: "  [<subject>] <predicate>". Keyed on the leading
                // bracket and the ABSENCE of a tunnel annotation, so the two
                // two-space-indented block formats can never be confused.
                currentGroup = line.trimmingCharacters(in: .whitespaces)
            }
        }
        return items
    }

    // MARK: fact_search

    /// Active KG facts. `<id>  [<subject>] <predicate> [<object>]  filed=<iso>  source=<s>`.
    static func facts(_ text: String, _ context: ReviewProvenanceContext) -> [ReviewItem] {
        var items: [ReviewItem] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            // Skip the "facts: N" / "facts matching …" header and the optional
            // recall_provenance footer: only fact rows carry a bracketed subject.
            guard line.contains("  ["), let (subject, rest) = bracketed(line) else { continue }
            let factID = String(line.prefix { !$0.isWhitespace })
            guard !factID.isEmpty else { continue }
            // Remainder is " <predicate> [<object>]  filed=…  source=…". Cut the
            // trailing metadata off first, then read the object from its first `[`
            // to the LAST `]` in what remains — object values are free text and do
            // contain brackets (estate rows carry values like
            // "[a_verb_applied_to_a_noun]"), which a first-`]` scan would truncate.
            let head = rest.range(of: "  filed=")
                .map { String(rest[rest.startIndex..<$0.lowerBound]) } ?? String(rest)
            let predicate = head
                .prefix { $0 != "[" }
                .trimmingCharacters(in: .whitespaces)
            var object = ""
            if let open = head.firstIndex(of: "["), let close = head.lastIndex(of: "]"),
               open < close {
                object = String(head[head.index(after: open)..<close])
            }
            let body = line.trimmingCharacters(in: .whitespaces)
            items.append(ReviewItem(
                id: ReviewItem.makeID(
                    surface: context.surface, subjectID: factID, ordinal: items.count),
                title: subject,
                detail: object.isEmpty ? predicate : "\(predicate) \(object)",
                subjectID: factID,
                occurredAt: field(body, key: "filed").flatMap(instant),
                provenance: context.provenance(line: String(line))))
        }
        return items
    }

    // MARK: read_journal

    /// Journal entries. `[<iso>]  <entry text truncated to 200 chars>`.
    static func journal(_ text: String, _ context: ReviewProvenanceContext) -> [ReviewItem] {
        var items: [ReviewItem] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { continue }
            let stamp = String(line[line.index(after: line.startIndex)..<close])
            guard let filedAt = instant(stamp) else { continue }
            let entry = String(line[line.index(after: close)...])
                .trimmingCharacters(in: .whitespaces)
            items.append(ReviewItem(
                id: ReviewItem.makeID(surface: context.surface, subjectID: nil, ordinal: items.count),
                title: stamp,
                detail: entry,
                subjectID: nil,
                occurredAt: filedAt,
                provenance: context.provenance(line: String(line))))
        }
        return items
    }

    // MARK: memory_search

    /// Recalled drawers. Decoded from the response's `structuredContent` rows
    /// by `StructuredRecallResults` (MootIntentKit) — the one place drawer
    /// rows become typed values. This parse alone receives the whole
    /// `ReviewToolResponse`: drawer content is caller-controlled, so the
    /// display text is never a source of drawer data (see the
    /// StructuredRecallResults header for the forgery argument).
    static func drawers(_ response: ReviewToolResponse, _ context: ReviewProvenanceContext) -> [ReviewItem] {
        CommunityStructuredRecallResults.drawers(from: response.structured).enumerated().map { ordinal, drawer in
            ReviewItem(
                id: ReviewItem.makeID(
                    surface: context.surface, subjectID: drawer.id, ordinal: ordinal),
                title: drawer.room,
                detail: drawer.content,
                subjectID: drawer.id,
                // The structured recall row carries no filed instant.
                occurredAt: nil,
                // The audit record names the structured row the item came
                // from — there is no response "line" for this surface.
                provenance: context.provenance(
                    line: "structured row: id=\(drawer.id) room=\(drawer.room) content=\(drawer.content)"))
        }
    }
}
