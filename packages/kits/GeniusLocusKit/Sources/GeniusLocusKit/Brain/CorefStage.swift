import Foundation
import EideticLib
import LatticeLib

/// Pipeline-p2.3 coreference stage (W2.2 Stage A, accepted design A1):
/// resolves THIRD-PERSON pronouns in the DISTILLED rendering against a
/// session antecedent pool — the anchored entities of up to K preceding
/// same-room items within the G-minute session window. The verbatim body
/// is never touched (dense-lane doctrine); a pronoun-free payload serves
/// both retrieval (the anaphora miss class: "I bought it a year ago" —
/// the referent lives in a neighboring turn) and the reasoning LLM.
///
/// CONSERVATIVE BY DESIGN: a pronoun is substituted ONLY when the pool
/// holds exactly ONE distinct candidate of compatible class (thing-pronoun
/// → non-person entity, person-pronoun → person entity). An ambiguous
/// window leaves the pronoun untouched — a wrong referent poisons recall
/// worse than an unresolved one. Deterministic end to end: HMM word
/// classes, bundled FDC canon, vendored QID tables; no clock, no locale.
public enum CorefStage {

    /// Session-window constants (accepted A1 shape): antecedents come from
    /// at most `windowItems` preceding same-room items whose eventTime is
    /// within `windowMinutes` of the item being distilled. Changing either
    /// bumps the pipeline version.
    public static let windowItems = 5
    public static let windowMinutes = 30

    /// One antecedent candidate: the entity phrase (lowercased, as the
    /// categorizer emits it) and whether the pinned taxonomy marks it a
    /// person (Q5 "human" in its QIDClosure ancestor set).
    public struct Antecedent: Equatable, Sendable {
        public let value: String
        public let isPerson: Bool
        /// Memberwise initializer.
        public init(value: String, isPerson: Bool) {
            self.value = value
            self.isPerson = isPerson
        }
    }

    /// The Wikidata class for "human"; an entity whose ancestor closure
    /// contains it resolves person-pronouns, everything else resolves
    /// thing-pronouns.
    private static let humanQID = "Q5"

    /// Pronoun tables. "her" is EXCLUDED on purpose: it is both the object
    /// and the possessive form, and the two need different substitutions —
    /// unresolvable deterministically without parsing, so the conservative
    /// stage leaves it alone. Subject/object forms substitute the entity
    /// itself; possessive forms substitute `<entity>'s`.
    private static let personPlain: Set<String> = ["he", "him", "she", "they", "them"]
    private static let personPossessive: Set<String> = ["his", "hers", "their", "theirs"]
    private static let thingPlain: Set<String> = ["it"]
    private static let thingPossessive: Set<String> = ["its"]

    /// Extract the antecedent pool an item CONTRIBUTES: its anchored
    /// entities in first-seen order — the same selection the categorizer
    /// makes (multi-word phrase pre-pass, then anchoring nouns), reusing
    /// the pinned stopword/length/root-class rules so the coref pool and
    /// the trailer facts never disagree about what an item is about.
    public static func contributedEntities(from content: String) -> [Antecedent] {
        var result: [Antecedent] = []
        var seen = Set<String>()

        let tokens = content.split(whereSeparator: { !$0.isLetter })
            .map { $0.lowercased() }

        // Multi-word phrase pass (mirrors EnrichmentStage's pre-pass).
        var consumed = Set<Int>()
        var i = 0
        while i < tokens.count {
            var matched = false
            var n = min(EnrichmentStage.maxPhraseWords, tokens.count - i)
            while n >= 2 {
                let phrase = tokens[i..<(i + n)].joined(separator: " ")
                if let qid = QIDFacts.qid(forPhrase: phrase) {
                    for k in i..<(i + n) { consumed.insert(k) }
                    if seen.insert(phrase).inserted {
                        result.append(Antecedent(
                            value: phrase, isPerson: isPersonQID(qid)))
                    }
                    i += n
                    matched = true
                    break
                }
                n -= 1
            }
            if !matched { i += 1 }
        }

        // Single-token pass (mirrors EnrichmentStage's noun pass).
        for (index, token) in tokens.enumerated() {
            if consumed.contains(index) { continue }
            guard token.count >= EnrichmentStage.minNounLength,
                  !EnrichmentStage.stopwords.contains(token),
                  LatticeLib.wordClass(token, recordNovel: false) == .noun else { continue }
            let anchor = EideticLib.lookup(token)
            guard !anchor.code.isEmpty, anchor.code != "000" else { continue }
            if seen.insert(token).inserted {
                result.append(Antecedent(
                    value: token,
                    isPerson: (anchor.wikidataQID).map(isPersonQID) ?? false))
            }
        }
        return result
    }

    /// True when the pinned taxonomy derives `qid` from Q5 (human).
    private static func isPersonQID(_ qid: String) -> Bool {
        guard !qid.isEmpty else { return false }
        return QIDClosure.ancestors(of: qid).contains(humanQID)
    }

    /// Resolve third-person pronouns in `rendering` against `pool`
    /// (the accumulated session antecedents, oldest first). Substitution
    /// fires per pronoun CLASS only when the pool holds exactly one
    /// distinct candidate of that class; otherwise the token is left
    /// untouched. Token-boundary replacement over letter runs — never
    /// regex (house rule); non-letter characters (punctuation, digits,
    /// whitespace) pass through unchanged.
    public static func resolve(rendering: String, pool: [Antecedent]) -> String {
        guard !pool.isEmpty else { return rendering }
        let persons = uniqueValues(pool.filter(\.isPerson))
        let things = uniqueValues(pool.filter { !$0.isPerson })
        let person = persons.count == 1 ? persons[0] : nil
        let thing = things.count == 1 ? things[0] : nil
        guard person != nil || thing != nil else { return rendering }

        var out = String()
        out.reserveCapacity(rendering.count)
        var word = String()
        for ch in rendering {
            if ch.isLetter {
                word.append(ch)
            } else {
                out += substituted(word, person: person, thing: thing)
                word.removeAll(keepingCapacity: true)
                out.append(ch)
            }
        }
        out += substituted(word, person: person, thing: thing)
        return out
    }

    /// Distinct candidate values in first-seen order.
    private static func uniqueValues(_ antecedents: [Antecedent]) -> [String] {
        var seen = Set<String>()
        return antecedents.compactMap { seen.insert($0.value).inserted ? $0.value : nil }
    }

    /// The replacement for one word token, or the token unchanged.
    private static func substituted(_ word: String, person: String?, thing: String?) -> String {
        guard !word.isEmpty else { return word }
        let lower = word.lowercased()
        if let thing {
            if thingPlain.contains(lower) { return thing }
            if thingPossessive.contains(lower) { return thing + "'s" }
        }
        if let person {
            if personPlain.contains(lower) { return person }
            if personPossessive.contains(lower) { return person + "'s" }
        }
        return word
    }
}
