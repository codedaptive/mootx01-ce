import Foundation
import CorpusKit
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif
import EideticLib
import LatticeLib

/// Pipeline-p2 categorizer stage.
///
/// Schema 19 role: computes the `ssc_facts` column value written at ingest.
/// The value is a bare comma-separated pair list (e.g. `"entity: louvre, place: paris"`)
/// stored in `drawers.ssc_facts`. The BM25 supplement reads from that column via
/// `SSCFacts.lexicalSupplement(_:)` — not by scanning the distilled text.
///
/// Swift primary path uses NLTagger `.nameType` NER (people, places, organisations)
/// when NaturalLanguage is available, with the HMM word-class baseline as the
/// cross-port fallback (`#if canImport(NaturalLanguage)` guards the NLTagger path).
/// Parity between ports covers SHAPE, not output (doctrine — the NER engines differ).
///
/// Deterministic end to end on the HMM path (both ports): token classification uses
/// the HMM word-class baseline (bit-identical across ports), anchoring uses the bundled
/// FDC canon, labels come from the shipped FDCFrame. No clock, no locale, no network
/// on the HMM path. Measured basis: the anarrow oracle arm (temporal MRR 0.4154 →
/// 0.4487; 3/11 never-rescued misses recovered).
///
/// The grammar-v1 `(*[ … ]*)` format is produced by `trailer(forContent:)` for
/// `ContextDistillLib` (inline distillation in the depth:distilled recall path).
/// `facts(forContent:)` returns the BARE pair list used for `ssc_facts`.
enum EnrichmentStage {

    // Grammar-v1 trailer delimiters — used by `trailer(forContent:)` only.
    // The BM25 supplement path no longer depends on these.
    fileprivate static let trailerOpen = "(*["
    fileprivate static let trailerClose = "]*)"

    /// At most this many facts per trailer — the oracle transforms averaged
    /// 2-3; six is the grammar's stated typical ceiling. Order of appearance
    /// in the content decides which nouns make the cut (deterministic).
    static let maxFacts = 6

    /// Nouns shorter than this never anchor (single letters and "ok"-class
    /// tokens produce junk FDC hits).
    static let minNounLength = 3

    /// Function words, conversational fillers, and evaluative adjectives that
    /// the word-class baseline sometimes admits as nouns. Pinned identically in
    /// both ports (see `Tests/Fixtures/ssc_stoplist.json`); extending it bumps
    /// the pipeline version. Evaluative adjectives added (schema 19): good, great,
    /// nice — the measurement found `entity: good` ×1,077 as the most common
    /// wing fact before this stoplist existed.
    static let stopwords: Set<String> = [
        // function words
        "the", "and", "but", "for", "nor", "not", "you", "your", "our", "their",
        "his", "her", "its", "they", "them", "this", "that", "these", "those",
        "was", "were", "are", "been", "being", "have", "has", "had", "with",
        "from", "into", "about", "some", "any", "all", "each", "what", "which",
        "who", "how", "when", "where", "why",
        // conversational fillers
        "yeah", "yes", "okay", "hey", "wow", "guess",
        // evaluative adjectives / generic nouns (schema 19, measured corpus junk)
        "good", "great", "nice", "sounds", "plan", "time", "new",
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
    static let maxPhraseWords = 5

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
                  LatticeLib.wordClass(token, recordNovel: false) == .noun else { continue }
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
        return " \(trailerOpen) \(body) \(trailerClose)"
    }

    // MARK: - Schema 19: ssc_facts column writer

    /// Returns a bare comma-separated pair list suitable for the `drawers.ssc_facts`
    /// column (schema 19), or `nil` when no facts could be derived.
    ///
    /// Output format: `"entity: louvre, place: paris"` — no grammar-v1 delimiters
    /// (`(*[ ]*)` are NOT written here; those belong to `trailer(forContent:)` only).
    ///
    /// Swift primary path: NLTagger `.nameType` NER (people, places, organisations)
    /// supplies entities when NaturalLanguage is available; the HMM word-class path
    /// (cross-port compatible) is the fallback. Proper-noun preference (capital first
    /// letter in source text) is honoured by both paths — capitalised tokens rank
    /// before lowercase nouns of equal derivation order.
    ///
    /// Stop list applied: `stopwords` blocks function words and evaluative adjectives
    /// (`good`, `great`, `nice`, `sounds`, `plan`, `time`, `new`).
    public static func facts(forContent content: String) -> String? {
        var pairs: [(label: String, value: String)] = []
        var seenValues = Set<String>()

        #if canImport(NaturalLanguage)
        // NLTagger NER primary path (Swift only). Maps NL tag schemes to fact labels.
        // This path runs on macOS 15+ / iOS 18+ where NaturalLanguage is always available.
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = content
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]
        tagger.enumerateTags(in: content.startIndex..<content.endIndex, unit: .word,
                             scheme: .nameType, options: options) { tag, range in
            guard let tag else { return true }
            let token = String(content[range]).trimmingCharacters(in: .whitespaces)
            guard token.count >= minNounLength else { return true }
            let lower = token.lowercased()
            guard !stopwords.contains(lower) else { return true }
            let label: String
            switch tag {
            case .personalName:  label = "entity"
            case .placeName:     label = "place"
            case .organizationName: label = "entity"
            default: return true
            }
            if seenValues.insert("\(label):\(lower)").inserted {
                pairs.append((label: label, value: lower))
            }
            return pairs.count < maxFacts
        }
        #endif

        // HMM word-class fallback (cross-port path, also fills gaps when NER found nothing).
        // Multi-word phrase pre-pass (identical to trailer(forContent:)).
        if pairs.isEmpty {
            let tokens = content.split(whereSeparator: { !$0.isLetter })
            var indexedTokens: [(lower: String, isCapital: Bool)] = tokens.map {
                (lower: $0.lowercased(), isCapital: $0.first?.isUppercase == true)
            }
            // Proper-noun preference: re-order so capitalised tokens are visited first
            // within the single-token pass below (multi-word phrases are already greedy).
            let capitalised = indexedTokens.filter(\.isCapital)
            let remaining = indexedTokens.filter { !$0.isCapital }
            indexedTokens = capitalised + remaining

            for indexed in indexedTokens {
                if pairs.count >= maxFacts { break }
                let token = indexed.lower
                guard token.count >= minNounLength,
                      !stopwords.contains(token),
                      !seenValues.contains("entity:\(token)"),
                      LatticeLib.wordClass(token, recordNovel: false) == .noun else { continue }
                let anchor = EideticLib.lookup(token)
                guard !anchor.code.isEmpty, anchor.code != "000" else { continue }
                if seenValues.insert("entity:\(token)").inserted {
                    pairs.append((label: "entity", value: token))
                }
                if pairs.count < maxFacts,
                   let qid = anchor.wikidataQID, !qid.isEmpty {
                    if let country = QIDFacts.countryLabel(for: qid).map(Self.grammarSafe) {
                        if seenValues.insert("place:\(token)").inserted {
                            pairs.append((label: "place", value: token))
                        }
                        if pairs.count < maxFacts,
                           seenValues.insert("country:\(country)").inserted {
                            pairs.append((label: "country", value: country))
                        }
                    }
                }
            }
        }

        guard !pairs.isEmpty else { return nil }
        return pairs.map { "\($0.label): \($0.value)" }.joined(separator: ", ")
    }
}

/// Query-side lattice anchoring (W2.5 Track S): derives the ONE §8.3 lattice
/// anchor a recall query is "about", using the SAME selection rules as the
/// categorizer above (multi-word phrase pre-pass, then the first anchoring
/// noun) so the query and the drawer sides anchor in the same code space.
/// Consumers (the CognitionKit precise/temporal doors) put the result on
/// `ReductionQuery` so the `lattice` reduction signal can fire; an
/// unanchorable query returns the empty anchor and the signal stays neutral.
/// Deterministic: HMM word classes, bundled FDC canon, vendored QID tables —
/// no clock, no locale, no network.
public enum QueryLatticeAnchor {

    /// The derived anchor: the drawer-side `udcCode` space (FDC code, `""`
    /// for phrase anchors, which carry no FDC code) plus the Wikidata Q-ID
    /// (`""` when the anchoring term has none).
    public struct Anchor: Sendable, Equatable {
        public let udcCode: String
        public let qid: String
        public init(udcCode: String, qid: String) {
            self.udcCode = udcCode
            self.qid = qid
        }
    }

    /// Derive the query's lattice anchor, or the empty anchor when nothing
    /// anchors. Selection mirrors `EnrichmentStage.trailer(forContent:)`:
    /// a greedy multi-word phrase match (5..2 words) wins at each position;
    /// otherwise the FIRST noun (≥ 3 letters, not a pinned stopword) whose
    /// EideticLib anchor is non-empty and non-root ("000") wins.
    public static func derive(from text: String) -> Anchor {
        let tokens = text.split(whereSeparator: { !$0.isLetter })
            .map { $0.lowercased() }

        // Multi-word phrase pass — the first phrase hit anchors the query.
        var i = 0
        while i < tokens.count {
            var n = min(EnrichmentStage.maxPhraseWords, tokens.count - i)
            while n >= 2 {
                let phrase = tokens[i..<(i + n)].joined(separator: " ")
                if let qid = QIDFacts.qid(forPhrase: phrase) {
                    return Anchor(udcCode: "", qid: qid)
                }
                n -= 1
            }
            i += 1
        }

        // Single-token pass — the first anchoring noun wins.
        for token in tokens {
            guard token.count >= EnrichmentStage.minNounLength,
                  !EnrichmentStage.stopwords.contains(token),
                  LatticeLib.wordClass(token, recordNovel: false) == .noun else { continue }
            let anchor = EideticLib.lookup(token)
            guard !anchor.code.isEmpty, anchor.code != "000" else { continue }
            return Anchor(udcCode: anchor.code, qid: anchor.wikidataQID ?? "")
        }
        return Anchor(udcCode: "", qid: "")
    }
}
