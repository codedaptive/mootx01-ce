import EngramLib
import LocusKit

/// A compiled query sketch derived from a `GLKRecallRequest`.
///
/// The sketch extracts `queryText` from the request and — when a `Corpus`
/// instance is available for the estate — pre-embeds it into `queryEngram`
/// for the vector lane. `queryTokens` are derived from `queryText` and
/// compiled into the sketch, but the current recall lanes call
/// `Corpus.bm25TopKBySource(query:queryText, ...)` directly; `queryTokens`
/// are not consumed by `RecallDirector` (an earlier design passed tokens into
/// the BM25 call; that path was replaced by passing `queryText`).
///
/// `queryTokens` uses the same keyword-split vocabulary as `BM25Index.topK` —
/// ASCII-lowercased whitespace+punctuation splits, min length 2. This matches
/// what `CorpusDefaultTokenizer.keywordTokens` produces, which is the tokeniser
/// `Corpus` uses internally, so BM25 token lookups are compatible.
///
/// `queryEngram` is nil when no query text is present or when embedding fails;
/// the vector lane treats a nil engram as an empty candidate set and continues
/// without throwing.
struct RecallQuerySketch: Sendable {
    /// The LocusKit filter chain from the original request.
    let frame: LocusKit.RecallFrame
    /// Convenience alias for `frame.filterChain`.
    let bitmapPredicates: [LocusKit.Filter]
    /// Free-text query string, or nil if the request has no text component.
    let queryText: String?
    /// BM25 keyword tokens derived from `queryText`.
    ///
    /// Uses the same ASCII-lowercased word-split tokenisation as
    /// `Corpus.bm25TopKBySource` so token lookup keys are compatible with
    /// the BM25Index posting lists. Empty when `queryText` is nil or blank.
    let queryTokens: [String]
    /// Pre-embedded `Engram` for Hamming nearest-neighbour search, or nil.
    let queryEngram: Engram?
    /// Lattice anchor from the request's frame, if present.
    let latticeAnchor: LocusKit.LatticeAnchor?
}
