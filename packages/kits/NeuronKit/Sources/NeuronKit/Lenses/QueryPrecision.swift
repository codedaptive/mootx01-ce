import Foundation

// Query precision — the discriminative re-rank signal (the precision step
// of PreciseRecall, CognitionKit). A coarse hybrid grab (BM25 + vector)
// keeps recall high but cannot tell near-duplicates apart: "the indemnity
// was 46 million marks" and "the indemnity was 11 million marks" share
// almost every shingle, so character-shingle similarity ranks them
// interchangeably. The piece that separates them is the DISTINCTIVE
// token — the number, the proper noun — that the query names and only one
// candidate contains.
//
// `queryPrecision` composes two pure, deterministic signals into one
// score in [0, 1]:
//   1. word-token Jaccard of query vs candidate — coarse lexical overlap,
//      the "are we even talking about the same thing" floor.
//   2. a discriminative exact-match rate — of the query's DISTINCTIVE
//      tokens (numbers and capitalised / mixed-case proper nouns), what
//      fraction appear verbatim in the candidate. This is the signal that
//      lifts found@1: among look-alikes, the candidate that actually
//      contains the queried "46" / "Versailles" / "Q3" scores strictly
//      higher than the one that contains "11" / "Vienna" / "Q4".
//
// Owns no SubstrateML gate — this is pure text math, like
// `shingleSimilarity`. Total: every input yields a finite score; empty
// query or empty candidate yields 0. Deterministic: no locale-sensitive
// transform beyond `lowercased()` (ASCII-folded, matches the Rust port's
// `to_lowercase()` on the ASCII conformance vectors), no clock, no RNG.
// CognitionKit sequences it (recall the pool, then rank by this).

extension NeuronKit {

    /// Precision of `candidate` as an answer to `query`, in `[0, 1]`.
    ///
    /// The discrimination problem the coarse hybrid grab cannot solve: a
    /// query names an ENTITY and an ATTRIBUTE ("the reserve value of Mirelle
    /// Station"); the near-duplicate distractors all share the entity and
    /// differ only in the attribute they report ("Mirelle Station operates a
    /// fleet…", "…was chartered…"). The proper noun is therefore NOT the
    /// discriminator — it is present in every look-alike. The discriminator
    /// is the ATTRIBUTE content word ("reserve", "value") that the true
    /// answer carries and the distractors do not.
    ///
    /// So the lead signal is `contentMatch`: the fraction of the query's
    /// CONTENT words (non-stopword, non-question-word) that appear in the
    /// candidate. On top of that, matched DISTINCTIVE tokens (numbers and
    /// proper nouns the query actually names) add a bounded BONUS — this is
    /// the tie-breaker for the case where the query DOES carry the figure
    /// ("…was 46 million marks") and two candidates otherwise tie. The
    /// distinctive term is a bonus, never the lead weight, precisely because
    /// in entity/attribute queries the proper noun does not discriminate.
    ///
    /// score = clamp(contentMatch + `distinctiveBonus` · distinctiveRate).
    /// Pure, total, deterministic; returns 0 when either side is empty.
    ///
    /// - Parameters:
    ///   - query: the search query text.
    ///   - candidate: the candidate memory's content.
    ///   - distinctiveBonus: the maximum additive bonus a full
    ///     distinctive-token match contributes (default 0.25). Clamped to
    ///     `[0, 1]`; the final score is clamped to `[0, 1]`.
    /// - Returns: a precision score in `[0, 1]`; higher is a better, more
    ///   specific match. Returns 0 when either side is empty.
    public static func queryPrecision(
        query: String,
        candidate: String,
        distinctiveBonus: Float = 0.25
    ) -> Float {
        let bonus = min(max(distinctiveBonus, 0), 1)
        let candidateTokens = Set(wordTokens(candidate))
        let queryTokens = wordTokens(query)
        guard !queryTokens.isEmpty, !candidateTokens.isEmpty else { return 0 }

        // 1. LEAD SIGNAL — content-word match rate. Drop stopwords and
        //    question words from the query so the entity + attribute words
        //    drive the score; the fraction of those present in the candidate
        //    is the discriminator (the true answer carries the attribute
        //    word, the distractors do not). If the query is all stopwords
        //    (degenerate), fall back to the full token set so the signal is
        //    never undefined.
        let contentQuery = queryTokens.filter { !Self.stopwords.contains($0) }
        let effectiveQuery = contentQuery.isEmpty ? queryTokens : contentQuery
        let matchedContent = Set(effectiveQuery).filter { candidateTokens.contains($0) }.count
        let contentMatch = Float(matchedContent) / Float(Set(effectiveQuery).count)

        // 2. BONUS — distinctive-token match rate. Of the query's numbers and
        //    proper nouns, the fraction present in the candidate, scaled by
        //    `bonus`. When the query names no distinctive token, the bonus is
        //    0 (not undefined) and the score is the content match alone.
        let distinctive = distinctiveTokens(query)
        let distinctiveRate: Float
        if distinctive.isEmpty {
            distinctiveRate = 0
        } else {
            let matched = distinctive.filter { candidateTokens.contains($0) }.count
            distinctiveRate = Float(matched) / Float(distinctive.count)
        }

        return min(contentMatch + bonus * distinctiveRate, 1)
    }

    /// Whether `query` contains at least one distinctive token (a number or
    /// a word with an uppercase letter). When true, the exact-token gate in
    /// `moot_recall_precise` applies: any result set where NO candidate
    /// contains any of those tokens should be suppressed (not_found) rather
    /// than returned as a confident ranked list.
    ///
    /// Public so the access surface (`RecipeTools`) can inspect the gate
    /// without re-implementing the tokenisation rule.
    public static func hasDistinctiveTokens(_ query: String) -> Bool {
        !distinctiveTokens(query).isEmpty
    }

    /// Whether at least one of `candidateContents` satisfies the distinctive-
    /// token containment gate for `query`. Returns `true` when:
    ///   - the query has no distinctive tokens (gate does not apply), OR
    ///   - at least one candidate's content contains every distinctive token
    ///     in the query (i.e. `tokenExactRate` for that candidate > 0).
    ///
    /// When this returns `false`, the recall set is a confident non-match and
    /// the caller should suppress results with `not_found` discrimination rather
    /// than returning the ranked list.
    ///
    /// Public so the access surface (`RecipeTools`) can apply the gate after
    /// receiving the `PreciseMatch` list without re-implementing tokenisation.
    public static func containmentSatisfied(query: String, candidateContents: [String]) -> Bool {
        let distinctive = distinctiveTokens(query)
        guard !distinctive.isEmpty else { return true }
        for content in candidateContents {
            let tokens = Set(wordTokens(content))
            // Any match where at least one distinctive token is present passes
            // the gate — the rate > 0 condition from tokenExactRate.
            if !distinctive.isDisjoint(with: tokens) { return true }
        }
        return false
    }

    /// Stopwords and question words dropped from the query before the
    /// content-word match, so the entity + attribute words carry the signal.
    /// A small closed ASCII list — locale-free, identical in the Rust port —
    /// covering the function words and interrogatives that appear in every
    /// near-duplicate and so cannot discriminate among them.
    static let stopwords: Set<String> = [
        "what", "which", "who", "whom", "whose", "where", "when", "why",
        "how", "is", "are", "was", "were", "be", "been", "the", "a", "an",
        "of", "in", "on", "at", "to", "for", "and", "or", "its", "it",
        "this", "that", "these", "those",
    ]

    /// Lowercased word tokens of `s`: maximal runs of alphanumerics,
    /// case-folded. Punctuation and whitespace are separators. Used for
    /// the coarse Jaccard floor and as the candidate membership set.
    static func wordTokens(_ s: String) -> [String] {
        s.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    /// The query's DISTINCTIVE tokens, case-folded: the tokens a precise
    /// answer must contain to be the right one among look-alikes. A token
    /// is distinctive when it carries a digit (a number — "46", "1871",
    /// "q3") or is a proper noun (its original casing has an interior or
    /// leading uppercase letter — "Versailles", "iPhone"). Common
    /// lowercase words are NOT distinctive: they appear in every
    /// near-duplicate and so cannot tell them apart. Returned case-folded
    /// to match against the candidate's folded token set.
    static func distinctiveTokens(_ s: String) -> Set<String> {
        // Split the ORIGINAL string (casing preserved) so proper-noun
        // detection can see the uppercase letters.
        let rawTokens = s.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        var out = Set<String>()
        for token in rawTokens {
            let hasDigit = token.contains { $0.isNumber }
            let hasUpper = token.contains { $0.isUppercase }
            if hasDigit || hasUpper {
                out.insert(token.lowercased())
            }
        }
        return out
    }
}
