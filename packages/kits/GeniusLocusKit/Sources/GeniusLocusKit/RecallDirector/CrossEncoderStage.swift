// CrossEncoderStage.swift — GeniusLocusKit
//
// The retrieval-time cross-encoder stage: after every lane, fusion and the
// §11.18 admission gate have produced the authorized final list, a pair
// classifier scores (query, span) pairs for the HEAD of that list, takes the
// best logit per candidate, and fuses the cross order back into the incoming
// order with reciprocal-rank fusion. The tail beyond the head is never
// touched; membership never changes. The stage runs only when the request
// carries `RerankDirective(action: .apply)`; an absent directive is bypass.
//
// An apply with a packaged profile widens the lanes' presentation cut to the
// stage's pool before they run (the director raises the lane request's
// limit; frontierK is unchanged). The incoming order the stage sees, and the
// order a degraded apply hands back, is therefore the head of that pool-wide
// page, re-cut to the caller's limit. A bypass or an unknown profile never
// widens and is byte-identical to a request without a directive.
//
// This file holds the pure parts (the fusion rule, the span selection and the
// report) so the shared parity fixture
// (`SynapseKit/Tests/Fixtures/encoder/cross_encoder_parity.json`) exercises
// exactly the code the director runs. The lifecycle (lazy scorer load, the
// manifest limits) is in CrossEncoderActivation.swift; the insertion into
// `RecallDirector.recall` is in RecallDirector.swift.
//
// Mirror: rust/src/cross_encoder_stage.rs.

import Foundation
import CorpusKit

/// The three adjustable maxima the stage runs under, resolved from the estate
/// manifest and clamped to the packaged profile (never above it).
public struct CrossEncoderLimits: Sendable, Equatable {
    /// Candidates handed to the stage from the front of the final list.
    public let pool: Int
    /// Candidates, from the front of the pool, that are scored.
    public let head: Int
    /// Spans per scored candidate paired with the query.
    public let spans: Int

    public init(pool: Int, head: Int, spans: Int) {
        self.pool = max(0, pool)
        self.head = max(0, min(head, self.pool))
        self.spans = max(0, spans)
    }

    /// The profile's own maxima.
    public init(profile: CrossEncoderProfile) {
        self.init(pool: profile.pool, head: profile.head, spans: profile.spans)
    }
}

/// What the stage did for one recall. Rides `GLKRecallResult.crossEncoder`;
/// nil there means the request carried no directive.
public struct CrossEncoderReport: Sendable, Equatable {
    public enum Status: String, Sendable, Equatable {
        /// The scorer ran and the head was fused.
        case applied
        /// The directive said bypass (or there was nothing to do).
        case bypassed
        /// `apply` was requested and could not run; `reason` says why and the
        /// incoming order stands. `recall.cross_encoder_degraded` is also on
        /// `degradedStages`.
        case degraded
    }

    public let status: Status
    /// Whether the directive asked for `apply`.
    public let requested: Bool
    /// The degrade reason (`CrossEncoderStage.Reason`), or for `bypassed`
    /// and `applied` the directive's own diagnostic code echoed back.
    public let reason: String?
    /// The directive's profile id, whether or not it is packaged.
    public let profileID: String
    /// `CrossEncoderProfile.modelVersion` of the profile that ran, when known.
    public let modelVersion: String?
    /// `PairScorer.backend` of the scorer that ran (`coreml`, `candle`, …).
    public let backend: String?
    /// The limits the stage ran under (zero for bypass).
    public let pool: Int
    public let head: Int
    public let spans: Int
    /// Head candidates that received at least one logit.
    public let scored: Int
    /// Whether this recall loaded the model (first apply on the estate).
    public let coldLoad: Bool
    /// Wall-clock milliseconds of the stage (scorer load excluded), when it ran.
    public let stageMillis: Int?

    public init(
        status: Status, requested: Bool, reason: String?, profileID: String,
        modelVersion: String?, backend: String?, pool: Int, head: Int, spans: Int,
        scored: Int, coldLoad: Bool, stageMillis: Int?
    ) {
        self.status = status
        self.requested = requested
        self.reason = reason
        self.profileID = profileID
        self.modelVersion = modelVersion
        self.backend = backend
        self.pool = pool
        self.head = head
        self.spans = spans
        self.scored = scored
        self.coldLoad = coldLoad
        self.stageMillis = stageMillis
    }

    /// A bypass report for `directive`.
    static func bypassed(_ directive: RerankDirective) -> CrossEncoderReport {
        CrossEncoderReport(
            status: .bypassed, requested: false, reason: directive.reason,
            profileID: directive.profileID, modelVersion: nil, backend: nil,
            pool: 0, head: 0, spans: 0, scored: 0, coldLoad: false, stageMillis: nil)
    }

    /// A degraded report for an `apply` that could not run.
    static func degraded(_ directive: RerankDirective, reason: String, limits: CrossEncoderLimits?) -> CrossEncoderReport {
        CrossEncoderReport(
            status: .degraded, requested: true, reason: reason,
            profileID: directive.profileID, modelVersion: nil, backend: nil,
            pool: limits?.pool ?? 0, head: limits?.head ?? 0, spans: limits?.spans ?? 0,
            scored: 0, coldLoad: false, stageMillis: nil)
    }

    /// The one line the ARIA composer prints for this report.
    public var summaryLine: String {
        var parts = ["cross_encoder: \(status.rawValue)", "profile=\(profileID)"]
        if let reason { parts.append("reason=\(reason)") }
        if let backend { parts.append("backend=\(backend)") }
        if status == .applied {
            parts.append("pool=\(pool)")
            parts.append("head=\(head)")
            parts.append("scored=\(scored)")
            if coldLoad { parts.append("cold_load") }
            if let stageMillis { parts.append("ms=\(stageMillis)") }
        }
        return parts.joined(separator: " ")
    }
}

/// The stage's constants and pure functions.
public enum CrossEncoderStage {

    /// Degrade reasons (`CrossEncoderReport.reason` on `.degraded`).
    public enum Reason {
        /// This build carries no cross-encoder runtime (trait `CrossEncoder` off).
        public static let capabilityOff = "capability_off"
        /// The directive names a profile this build does not package.
        public static let profileUnknown = "profile_unknown"
        /// No model directory, or the factory refused it; the reason detail
        /// is in the one log line the activation wrote.
        public static let modelUnavailable = "model_unavailable"
        /// The request carries no query text to pair spans with.
        public static let noQueryText = "no_query_text"
        /// The scorer threw while scoring; the incoming order stands.
        public static let scorerFailed = "scorer_failed"
    }

    /// The `degradedStages` entry every degraded apply appends.
    public static let degradedStage = "recall.cross_encoder_degraded"

    /// Fuse the incoming order with the cross-encoder logits (the lab's
    /// `fuse`, reproduced exactly):
    ///
    /// 1. `head` = the first `head` of `incoming`; the rest is the tail and is
    ///    returned unchanged after the fused head.
    /// 2. Every head candidate with at least one logit takes its MAX logit;
    ///    the cross order sorts those by logit descending, ties by incoming
    ///    rank ascending, then id; candidates without a logit follow in
    ///    incoming order. Cross rank is 1-based over that list.
    /// 3. `score(c) = 1/(k + incoming) + 1/(k + cross)`; the head is sorted by
    ///    score descending, ties by incoming rank, then id.
    ///
    /// `logits` keys outside the head are ignored; a head id absent from
    /// `logits` (or with an empty array) is unscored.
    public static func fuse(incoming: [String], head: Int, logits: [String: [Float]], rrfK: Int) -> [String] {
        let headCount = max(0, min(head, incoming.count))
        let headIDs = Array(incoming.prefix(headCount))
        let tail = Array(incoming.dropFirst(headCount))
        guard !headIDs.isEmpty else { return incoming }
        var incomingRank: [String: Int] = [:]
        for (index, id) in headIDs.enumerated() where incomingRank[id] == nil {
            incomingRank[id] = index + 1
        }
        var maxima: [(id: String, logit: Float)] = []
        var unscored: [String] = []
        for id in headIDs {
            if let values = logits[id], let best = values.max() {
                maxima.append((id: id, logit: best))
            } else {
                unscored.append(id)
            }
        }
        maxima.sort { a, b in
            if a.logit != b.logit { return a.logit > b.logit }
            let ra = incomingRank[a.id]!, rb = incomingRank[b.id]!
            if ra != rb { return ra < rb }
            return a.id < b.id
        }
        var crossRank: [String: Int] = [:]
        for (index, entry) in maxima.enumerated() { crossRank[entry.id] = index + 1 }
        for (offset, id) in unscored.enumerated() { crossRank[id] = maxima.count + offset + 1 }
        let k = Double(rrfK)
        func score(_ id: String) -> Double {
            1 / (k + Double(incomingRank[id]!)) + 1 / (k + Double(crossRank[id]!))
        }
        let fusedHead = headIDs.sorted { a, b in
            let sa = score(a), sb = score(b)
            if sa != sb { return sa > sb }
            let ra = incomingRank[a]!, rb = incomingRank[b]!
            if ra != rb { return ra < rb }
            return a < b
        }
        return fusedHead + tail
    }

    /// Up to `limit` span texts of one candidate, in the order the scorer
    /// should see them.
    ///
    /// With stored span rows and a query vector (the registered span
    /// encoder's), the rows are ranked by their int8 cosine against the
    /// query (`SpanRerankStage.dotQuery`, ties by span index) and the best
    /// `limit` are rebuilt from the content's word list by `[startWord,
    /// endWord)`. Without rows or a vector the content is windowed with the
    /// Spanner (`windowWords` / `overlapDivisor`, at most `limit` spans), so a
    /// record whose span rows have not drained yet is still scored. Empty
    /// spans are dropped; an empty content yields no spans (unscored).
    public static func selectSpans(
        content: String,
        rows: [SpanRerankVector]?,
        queryVector: [Float]?,
        limit: Int,
        windowWords: Int,
        overlapDivisor: Int
    ) -> [String] {
        guard limit > 0 else { return [] }
        let words = Spanner.words(content)
        guard !words.isEmpty else { return [] }
        func text(_ start: Int, _ end: Int) -> String? {
            let lo = max(0, min(start, words.count)), hi = max(lo, min(end, words.count))
            guard hi > lo else { return nil }
            return words[lo..<hi].joined(separator: " ")
        }
        if let rows, !rows.isEmpty, let queryVector, !queryVector.isEmpty {
            let ranked = rows
                .filter { $0.int8.count == queryVector.count }
                .map { (row: $0, cosine: SpanRerankStage.dotQuery(queryVector, q: $0.int8, scale: $0.scale)) }
                .sorted { a, b in
                    if a.cosine != b.cosine { return a.cosine > b.cosine }
                    return a.row.index < b.row.index
                }
            let texts = ranked.prefix(limit).compactMap { text($0.row.startWord, $0.row.endWord) }
            if !texts.isEmpty { return texts }
        }
        return Spanner.spans(wordCount: words.count, windowWords: windowWords,
                             overlapDivisor: overlapDivisor, maxSpans: limit)
            .prefix(limit)
            .compactMap { text($0.start, $0.end) }
    }

    /// Reorder `hits` so its first `pool` entries follow `order` (a
    /// permutation of their ids); entries beyond the pool keep their place.
    /// An id in `order` that is not in the pool is ignored, and pool hits
    /// absent from `order` keep their relative order after the ordered ones,
    /// so membership can never change.
    static func reorder(hits: [RecallHit], pool: Int, order: [String]) -> [RecallHit] {
        let poolCount = max(0, min(pool, hits.count))
        let poolHits = Array(hits.prefix(poolCount))
        let tail = Array(hits.dropFirst(poolCount))
        var byID: [String: RecallHit] = [:]
        for hit in poolHits where byID[hit.id] == nil { byID[hit.id] = hit }
        var placed = Set<String>()
        var out: [RecallHit] = []
        out.reserveCapacity(hits.count)
        for id in order {
            guard let hit = byID[id], !placed.contains(id) else { continue }
            out.append(hit)
            placed.insert(id)
        }
        for hit in poolHits where !placed.contains(hit.id) {
            out.append(hit)
            placed.insert(hit.id)
        }
        return out + tail
    }
}
