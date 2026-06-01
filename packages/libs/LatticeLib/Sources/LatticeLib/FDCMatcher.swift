// FDCMatcher.swift
//
// FDC runtime encoder, Steps 4–5 (cookbook §5–§6): match an input text's
// concept bag against the code signatures, then descend the decimal frame to
// the most specific well-supported code.
//
//   Step 4 (§5.2/§5.3): score[code] += bag[term] for every term shared with
//                       the code's signature (inverted-index single-pass scan,
//                       the deterministic equivalent of the spec's Aho-Corasick
//                       scan over concept-id keys). Empty score -> UNRESOLVED.
//   Step 5 (§6):        start at argmax(score) (ties -> lowest code), then walk
//                       down children while a child's bag overlap meets
//                       STOP_THRESHOLD; return the deepest such code.
//
// `encode` is a pure function of the input text and the pinned artifacts
// (lexicon, signatures, frame) — the agreement property.

import Foundation

public struct FDCMatcher: Sendable {

    /// Pinned descent cutoff (§6.1). v1.0 value is TBD against real signatures;
    /// `1` (any overlap continues) is the testing default and MUST NOT ship.
    public let stopThreshold: Int

    private let lexicon: CanonicalizationLexicon
    private let frame: FDCFrame
    private let sigTerms: [String: Set<String>]    // code -> signature term set
    private let index: [String: [String]]          // term -> codes (sorted)

    public init(
        lexicon: CanonicalizationLexicon,
        frame: FDCFrame,
        signatures: [String: Set<String>],
        stopThreshold: Int = 1
    ) {
        self.lexicon = lexicon
        self.frame = frame
        self.sigTerms = signatures
        self.stopThreshold = stopThreshold
        var idx: [String: [String]] = [:]
        for (code, terms) in signatures { for t in terms { idx[t, default: []].append(code) } }
        for k in idx.keys { idx[k]!.sort() }       // deterministic order
        self.index = idx
    }

    /// Encode `text` to an FDC code, or `nil` for UNRESOLVED. Never guesses.
    public func encode(_ text: String) -> String? {
        encodeAnchor(text).code
    }

    /// Encode `text` and also surface the dominant concept of the input.
    /// `code` is the FDC code (`nil` = UNRESOLVED). `conceptQID` is the
    /// highest-weighted Wikidata Q-ID in the concept bag — "what the text is
    /// most about" — or `nil` if the bag carries no Q-ID concept. One pass,
    /// so EideticLib fills an Anchor's code + wikidataQID without re-bagging.
    public func encodeAnchor(_ text: String) -> (code: String?, conceptQID: String?) {
        let bag = BagBuilder.bag(text, lexicon: lexicon)
        let qid = dominantQID(bag)              // independent of whether a code matches
        guard !bag.isEmpty else { return (nil, qid) }

        // Step 4 — match + score (§5.2/§5.3).
        var score: [String: Int] = [:]
        for (term, n) in bag {
            guard let codes = index[term] else { continue }
            for code in codes { score[code, default: 0] += n }
        }
        guard !score.isEmpty else { return (nil, qid) }   // §5.2.3 — UNRESOLVED, no guess

        // argmax: highest score, ties broken by lowest code lexicographically.
        var node = ""
        var nodeScore = Int.min
        for (code, s) in score where s > nodeScore || (s == nodeScore && code < node) {
            node = code; nodeScore = s
        }

        // Step 5 — frame descent (§6.1).
        while true {
            var best: String?
            var bestOverlap = 0
            for child in frame.children(of: node) {
                guard let terms = sigTerms[child.code] else { continue }
                var overlap = 0
                for (term, n) in bag where terms.contains(term) { overlap += n }
                guard overlap >= stopThreshold else { continue }
                if overlap > bestOverlap || (overlap == bestOverlap && (best == nil || child.code < best!)) {
                    best = child.code; bestOverlap = overlap
                }
            }
            guard let next = best else { break }
            node = next
        }
        return (node, qid)
    }

    /// The highest-count Wikidata Q-ID in `bag` (ties broken by lowest Q-ID
    /// lexicographically, so the result is deterministic regardless of the
    /// bag's dictionary iteration order). `nil` if the bag holds no Q-ID key.
    private func dominantQID(_ bag: ConceptBag) -> String? {
        var best: String?
        var bestN = 0
        for (k, n) in bag where k.hasPrefix("Q") {
            if n > bestN || (n == bestN && (best == nil || k < best!)) {
                best = k; bestN = n
            }
        }
        return best
    }
}
