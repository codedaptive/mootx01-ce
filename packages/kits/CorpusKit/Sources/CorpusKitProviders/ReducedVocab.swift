// ReducedVocab.swift — shared IDF-reduced vocabulary selection for the dense
// distributional-factorization provider (LSA).
//
// ## Why this exists
//
// LSA builds a DENSE `docs × vocab` matrix and factors it (fixed-sweep Jacobi
// SVD). On a real corpus the vocabulary is tens of thousands of distinct
// terms, so the factorization is ~10^15 ops — computationally infeasible, and it
// hangs the encode drain. This picks a deterministic top-K informative
// sub-vocabulary so the factored matrix is `docs × K` (feasible in seconds).
//
// ## Why it is a corpus property (not a provider property)
//
// Term informativeness is a property of the corpus, not of the factorization
// method — "which terms carry signal" is answered once per corpus, so any
// dense factorization provider consumes the ONE reduced vocab. The cap `K`
// and the band are optimizer knobs (default here).
//
// ## Determinism (cross-port bit-identity)
//
// The kept set and its column order depend ONLY on `(df, term)` — Swift
// Dictionary iteration order is irrelevant because the candidates are fully
// sorted by a total order (df descending, then UTF-8 byte order of the term,
// matching Rust's `&str` Ord). Mirror: rust-providers/src/reduced_vocab.rs.

import Foundation

/// Default reduced-vocabulary cap. Dense Jacobi SVD cost scales as
/// ~K²·numDocs, so K trades reindex latency against how many terms feed the
/// latent factors. 512 keeps a large-corpus reindex in the seconds range while
/// still giving far more input columns than the provider's rank (LSA 64).
/// Parameterized so the quality optimizer can tune it.
public let defaultReducedVocabCap: Int = 512

/// A frozen reduced vocabulary: the ordered kept terms plus the maps needed to
/// (a) remap full-vocab TF rows to reduced columns at train time, and
/// (b) map query terms to reduced columns at projection time.
public struct ReducedVocabulary: Sendable {
    /// Kept terms in reduced-column order (column i == `keptTerms[i]`).
    public let keptTerms: [String]
    /// term → reduced column — the projection / serialization map.
    public let termToColumn: [String: Int]
    /// full-vocab index → reduced column — remaps TF rows at train time.
    public let fullIndexToColumn: [Int: Int]
    /// Number of reduced columns.
    public var size: Int { keptTerms.count }
}

/// Select the shared reduced vocabulary from maintained term-document counts.
///
/// No-op when the full vocab already fits `cap` (small estates and every
/// conformance fixture train an unchanged basis). Above `cap`: drop hapax
/// (`df < 2`, pure noise) and rank the remainder by document frequency
/// DESCENDING (terms that co-occur across many documents carry the latent
/// structure a factorization can find), tie-broken by UTF-8 byte order of the
/// term for cross-port determinism; keep the top `cap`.
///
/// - Parameters:
///   - vocab: term → full-vocab index (from `TermDocumentCounts.vocab`).
///   - dfCounts: full-vocab index → document frequency.
///   - documentCount: N, the number of training documents.
///   - cap: reduced-column ceiling K.
public func selectReducedVocabulary(
    vocab: [String: Int],
    dfCounts: [Int: Int],
    documentCount N: Int,
    cap: Int = defaultReducedVocabCap
) -> ReducedVocabulary {
    let fullSize = vocab.count

    // No-op below the cap: keep the FULL vocabulary in its existing column
    // order. Estates whose vocab already fits K (including every small
    // conformance fixture) train a byte-identical basis to the pre-shared reduced embedding vocabulary
    // behavior — the reduction engages ONLY when the dense factorization would
    // otherwise be infeasible.
    if fullSize <= max(1, cap) {
        var keptTerms = [String](repeating: "", count: fullSize)
        for (term, idx) in vocab where idx >= 0 && idx < fullSize {
            keptTerms[idx] = term
        }
        var identity: [Int: Int] = [:]
        identity.reserveCapacity(fullSize)
        for i in 0..<fullSize { identity[i] = i }
        return ReducedVocabulary(
            keptTerms: keptTerms,
            termToColumn: vocab,
            fullIndexToColumn: identity
        )
    }

    // Above the cap: drop hapax (df < 2, pure noise), then rank the remaining
    // terms by document frequency DESCENDING (terms that co-occur across many
    // documents carry the latent structure a factorization can find), tie-broken
    // by UTF-8 byte order of the term (matches Rust `&str` Ord) for cross-port
    // determinism — a strict total order independent of Dictionary iteration.
    _ = N  // reserved for an informativeness weighting the optimizer may add
    var candidates: [(term: String, fullIndex: Int, df: Int)] = []
    candidates.reserveCapacity(fullSize)
    for (term, fullIndex) in vocab {
        let df = dfCounts[fullIndex] ?? 0
        if df >= 2 { candidates.append((term, fullIndex, df)) }
    }
    candidates.sort { a, b in
        if a.df != b.df { return a.df > b.df }
        return Array(a.term.utf8).lexicographicallyPrecedes(Array(b.term.utf8))
    }

    let keptCount = min(max(0, cap), candidates.count)
    var keptTerms: [String] = []
    var termToColumn: [String: Int] = [:]
    var fullIndexToColumn: [Int: Int] = [:]
    keptTerms.reserveCapacity(keptCount)
    termToColumn.reserveCapacity(keptCount)
    fullIndexToColumn.reserveCapacity(keptCount)
    for col in 0..<keptCount {
        let c = candidates[col]
        keptTerms.append(c.term)
        termToColumn[c.term] = col
        fullIndexToColumn[c.fullIndex] = col
    }
    return ReducedVocabulary(
        keptTerms: keptTerms,
        termToColumn: termToColumn,
        fullIndexToColumn: fullIndexToColumn
    )
}
