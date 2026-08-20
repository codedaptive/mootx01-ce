import Foundation
import CorpusKit
import EideticLib
import LatticeLib

/// Pipeline-p2 categorizer stage (DECISION_DENSE_LANE_ENRICHMENT, Wave 2):
/// welds a grammar-v1 trailer of category/entity facts onto the distilled
/// rendering so the trailer lexical supplement (CorpusKit.TrailerGrammar)
/// can admit them to the keyword lane. Measured basis: the anarrow oracle
/// arm (temporal MRR 0.4154 → 0.4487; 3/11 never-rescued misses recovered).
///
/// Deterministic end to end: token classification uses the HMM word-class
/// baseline (bit-identical across ports), anchoring uses the bundled FDC
/// canon, labels come from the shipped FDCFrame. No clock, no locale, no
/// network. The enrichment TEXT is dense-lane data (doctrine: parity covers
/// this capability's SHAPE, not its output), but this deterministic engine
/// happens to be twin-able and IS twinned for the benchmarkable default.
enum EnrichmentStage {

    /// At most this many facts per trailer — the oracle transforms averaged
    /// 2-3; six is the grammar's stated typical ceiling. Order of appearance
    /// in the content decides which nouns make the cut (deterministic).
    static let maxFacts = 6

    /// Nouns shorter than this never anchor (single letters and "ok"-class
    /// tokens produce junk FDC hits).
    private static let minNounLength = 3

    /// Function words and conversational fillers that the word-class
    /// baseline sometimes admits as nouns ("the" was observed anchoring to
    /// a junk category on the first native build). Pinned identically in
    /// both ports; extending it bumps the pipeline version.
    private static let stopwords: Set<String> = [
        "the", "and", "but", "for", "nor", "not", "you", "your", "our", "their", "his", "her", "its", "they", "them", "this", "that", "these", "those", "was", "were", "are", "been", "being", "have", "has", "had", "with", "from", "into", "about", "some", "any", "all", "each", "what", "which", "who", "how", "when", "where", "why", "yeah", "yes", "okay", "hey", "wow", "guess",
    ]

    /// Lowercases a frame label and truncates at the first comma: the
    /// trailer grammar separates PAIRS with commas, so a label-internal
    /// comma ("general works, books and libraries, …") would forge extra
    /// pairs. The first segment is the head term and the best token anyway.
    private static func grammarSafe(_ label: String) -> String {
        label.lowercased()
            .split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: .whitespaces)
    }

    /// Builds the grammar-v1 trailer for an item's verbatim content, or ""
    /// when no noun anchors. The trailer is appended to the DISTILLED
    /// rendering only — the verbatim body is never touched.
    ///
    /// Fact shape per anchored noun: `entity: <noun>` plus `fdc: <label>`
    /// for the noun's own frame label and `kind: <parent label>` for its
    /// FDC ancestor — the hypernym chain the register-gap misses need
    /// ("painting" → arts). Labels are deduplicated across nouns; the
    /// first-seen order is preserved.
    /// Longest phrase length attempted by the multi-word pre-pass. The
    /// vendored label table tops out at ~5-word labels.
    private static let maxPhraseWords = 5

    static func trailer(forContent content: String) -> String {
        var facts: [(label: String, value: String)] = []
        var seenValues = Set<String>()
        var seenNouns = Set<String>()

        // MULTI-WORD ENTITY PRE-PASS (p2.2): greedy longest-match of content
        // n-grams (5..2 words, lowercased, letter tokens) against the
        // vendored multi-word labels. "rio de janeiro" anchors as a phrase
        // where the single-token pass sees only "rio" (measured miss cause,
        // ENRICHMENT_ORACLE study). Matched tokens are consumed so the
        // single-token pass below never re-anchors fragments of a phrase.
        let tokens = content.split(whereSeparator: { !$0.isLetter })
            .map { $0.lowercased() }
        var consumed = Set<Int>()
        var i = 0
        while i < tokens.count && facts.count < maxFacts {
            var matched = false
            var n = min(maxPhraseWords, tokens.count - i)
            while n >= 2 {
                let phrase = tokens[i..<(i + n)].joined(separator: " ")
                if let qid = QIDFacts.qid(forPhrase: phrase) {
                    for k in i..<(i + n) { consumed.insert(k) }
                    if seenValues.insert("entity:\(phrase)").inserted {
                        facts.append((label: "entity", value: phrase))
                    }
                    if facts.count < maxFacts,
                       let country = QIDFacts.countryLabel(for: qid).map(Self.grammarSafe) {
                        if seenValues.insert("place:\(phrase)").inserted,
                           facts.count < maxFacts {
                            facts.append((label: "place", value: phrase))
                        }
                        if facts.count < maxFacts,
                           seenValues.insert("country:\(country)").inserted {
                            facts.append((label: "country", value: country))
                        }
                    }
                    if facts.count < maxFacts,
                       let parent = QIDClosure.ancestors(of: qid).first,
                       let kind = QIDFacts.label(for: parent).map(Self.grammarSafe),
                       seenValues.insert("kind:\(kind)").inserted {
                        facts.append((label: "kind", value: kind))
                    }
                    i += n
                    matched = true
                    break
                }
                n -= 1
            }
            if !matched { i += 1 }
        }

        for (tokenIndex, rawToken) in content.split(whereSeparator: { !$0.isLetter }).enumerated() {
            if consumed.contains(tokenIndex) { continue }
            if facts.count >= maxFacts { break }
            let token = rawToken.lowercased()
            guard token.count >= minNounLength,
                  !stopwords.contains(token),
                  !seenNouns.contains(token),
                  LatticeLib.wordClass(token) == .noun else { continue }
            seenNouns.insert(token)

            let anchor = EideticLib.lookup(token)
            // Root-class anchors ("000" — general works) are junk facts:
            // filler tokens like "yeah" resolve there. Skip them.
            guard !anchor.code.isEmpty, anchor.code != "000" else { continue }

            if seenValues.insert("entity:\(token)").inserted {
                facts.append((label: "entity", value: token))
            }
            // Wikidata property subset (DECISION v0.2): when the anchor
            // carries a Q-ID, the vendored facts beat the FDC frame —
            // `kind` from the first taxonomic ancestor's label, `place` +
            // `country` from P17. The FDC frame label remains the `fdc`
            // fact and the kind fallback.
            var kindEmitted = false
            if let qid = anchor.wikidataQID, !qid.isEmpty {
                if facts.count < maxFacts,
                   let country = QIDFacts.countryLabel(for: qid).map(Self.grammarSafe) {
                    if seenValues.insert("place:\(token)").inserted {
                        facts.append((label: "place", value: token))
                    }
                    if facts.count < maxFacts,
                       seenValues.insert("country:\(country)").inserted {
                        facts.append((label: "country", value: country))
                    }
                }
                if facts.count < maxFacts,
                   let parent = QIDClosure.ancestors(of: qid).first,
                   let kind = QIDFacts.label(for: parent).map(Self.grammarSafe),
                   seenValues.insert("kind:\(kind)").inserted {
                    facts.append((label: "kind", value: kind))
                    kindEmitted = true
                }
            }
            if facts.count < maxFacts,
               let label = FDC.label(for: anchor.code).map(Self.grammarSafe),
               seenValues.insert("fdc:\(label)").inserted {
                facts.append((label: "fdc", value: label))
            }
            if !kindEmitted,
               facts.count < maxFacts,
               let parent = FDC.ancestors(of: anchor.code).first,
               let kind = FDC.label(for: parent).map(Self.grammarSafe),
               seenValues.insert("kind:\(kind)").inserted {
                facts.append((label: "kind", value: kind))
            }
        }

        guard !facts.isEmpty else { return "" }
        let body = facts.map { "\($0.label): \($0.value)" }.joined(separator: ", ")
        return " \(TrailerGrammar.open) \(body) \(TrailerGrammar.close)"
    }
}
