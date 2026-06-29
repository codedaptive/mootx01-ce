import Testing
@testable import NeuronKit

// Query-precision signal — the discriminative re-rank used by the
// PreciseRecall recipe (CognitionKit). Tests assert the behavioral claim:
// among near-duplicate candidates, the one that contains the query's
// DISTINCTIVE token (the number, the proper noun) scores strictly higher
// than the look-alike that does not. Pure, deterministic, total.

@Suite("Query-precision signal")
struct QueryPrecisionTests {

    // QP-1: the discriminating number. Two candidates that share almost
    // every word — only the figure differs — must NOT score equally: the
    // candidate carrying the queried "46" beats the one carrying "11".
    @Test("the candidate with the queried number scores higher")
    func numberDiscriminates() {
        let query = "the war indemnity was 46 million marks"
        let right = "the war indemnity imposed was 46 million gold marks"
        let wrong = "the war indemnity imposed was 11 million gold marks"

        let rightScore = NeuronKit.queryPrecision(query: query, candidate: right)
        let wrongScore = NeuronKit.queryPrecision(query: query, candidate: wrong)

        #expect(rightScore > wrongScore,
                "the candidate containing the queried figure must rank higher")
    }

    // QP-2: the discriminating proper noun. Same structure, only the named
    // entity differs — the candidate naming "Versailles" beats "Vienna".
    @Test("the candidate with the queried proper noun scores higher")
    func properNounDiscriminates() {
        let query = "the treaty signed at Versailles ended the war"
        let right = "the treaty was signed at Versailles in the hall of mirrors"
        let wrong = "the treaty was signed at Vienna in the hall of mirrors"

        let rightScore = NeuronKit.queryPrecision(query: query, candidate: right)
        let wrongScore = NeuronKit.queryPrecision(query: query, candidate: wrong)

        #expect(rightScore > wrongScore)
    }

    // QP-3: scores are bounded in [0, 1].
    @Test("scores are bounded in [0, 1]")
    func bounded() {
        let s = NeuronKit.queryPrecision(
            query: "46 Versailles marks", candidate: "46 Versailles marks")
        #expect(s >= 0 && s <= 1)
    }

    // QP-4: total over empty input — an empty query or candidate is 0.
    @Test("empty query or candidate is zero")
    func emptyIsZero() {
        #expect(NeuronKit.queryPrecision(query: "", candidate: "anything") == 0)
        #expect(NeuronKit.queryPrecision(query: "anything", candidate: "") == 0)
    }

    // QP-5: when no distinctive token (number or proper noun) is present
    // the score is driven by content-token overlap — a candidate sharing
    // more query tokens outscores a disjoint one.
    @Test("no distinctive token falls back to coarse overlap")
    func noDistinctiveFallsBack() {
        let query = "the quick brown fox"
        let overlap = NeuronKit.queryPrecision(query: query, candidate: "the quick brown fox runs")
        let disjoint = NeuronKit.queryPrecision(query: query, candidate: "entirely unrelated words here")
        #expect(overlap > disjoint)
    }

    // QP-6: determinism — same inputs, same score, every call.
    @Test("deterministic across repeated calls")
    func deterministic() {
        let a = NeuronKit.queryPrecision(query: "46 marks at Versailles", candidate: "the 46 marks at Versailles")
        let b = NeuronKit.queryPrecision(query: "46 marks at Versailles", candidate: "the 46 marks at Versailles")
        #expect(a == b)
    }

    // QP-7: sentence-initial stopwords must NOT be treated as distinctive proper
    // nouns. Before this fix, "What", "Who", "The" at sentence start were flagged
    // as distinctive (they have uppercase letters), causing the containment gate
    // in moot_recall_precise to suppress all results for ordinary sentence queries.
    @Test("sentence-initial stopwords are not distinctive")
    func sentenceInitialStopwordsAreNotDistinctive() {
        // "What" is a stopword with a capital letter — not distinctive.
        let whatDistinctive = NeuronKit.hasDistinctiveTokens("What is the indemnity")
        #expect(!whatDistinctive,
            "'What' is a stopword: must not be flagged as a distinctive proper noun")

        // "Who" is a stopword but "Versailles" is not — the query IS distinctive.
        #expect(NeuronKit.hasDistinctiveTokens("Who signed the Versailles treaty"),
            "query WITH non-stopword proper noun 'Versailles' IS distinctive even though 'Who' is a stopword")
        #expect(!NeuronKit.hasDistinctiveTokens("The reserve value of the fund"),
            "'The' is a stopword: must not be classified as distinctive")

        // The proper noun in the same sentence still makes the query distinctive.
        #expect(NeuronKit.hasDistinctiveTokens("What happened at Versailles"),
            "'Versailles' is not a stopword: query IS distinctive")

        // Numeric token is always distinctive regardless of sentence-initial stopword.
        #expect(NeuronKit.hasDistinctiveTokens("What is the 46 million marks indemnity"),
            "'46' is a number: query IS distinctive even with leading stopword")
    }

    // QP-8: containment gate passes for sentence-form queries with no distinctive
    // tokens (the indemnity recall case — no number, no proper noun after stopword filter).
    @Test("sentence query without distinctive tokens yields candidates not suppressed")
    func sentenceQueryDoesNotSuppressCandidates() {
        // After fix: "What is the indemnity" has no distinctive tokens → gate passes.
        let satisfied = NeuronKit.containmentSatisfied(
            query: "What is the indemnity",
            candidateContents: [
                "the indemnity was 46 million marks",
                "indemnity clause three"
            ])
        #expect(satisfied,
            "sentence query with no distinctive tokens must pass the gate (candidates not suppressed)")
    }
}
