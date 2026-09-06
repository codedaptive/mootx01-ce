import Foundation

/// SSC (Semantic Search Candle) fact supplement for the BM25 lexical lane.
///
/// Schema 19 replaces the Wave-2 grammar-v1 `(*[ … ]*)` trailer approach:
/// facts are now stored in `drawers.ssc_facts` as a bare comma-separated pair
/// list without delimiters (e.g. `"kind: hobby, entity: painting, place: brazil"`).
/// The supplement appends these tokens to the verbatim BM25 document at index
/// time — the verbatim content is never modified; facts participate in keyword
/// scoring only.
///
/// Old content may contain literal `(*[ … ]*)` blocks in verbatim text (written
/// before this migration). The supplement reads ONLY from `ssc_facts` and never
/// scans content or dense text, so those blocks are indexed exactly once as part
/// of the verbatim body and never double-indexed.
///
/// Rust twin: `corpus_kit::ssc_facts`.
public enum SSCFacts {

    /// Returns the lexical supplement for BM25 indexing: the `ssc_facts` column
    /// value prefixed with one separating space, or `""` when `facts` is nil or
    /// empty (fail-quiet — absent facts contribute nothing to keyword scoring).
    ///
    /// Input is the stored column value — a comma-separated pair list with no
    /// grammar-v1 delimiters, e.g. `"entity: snake, place: paris"`. The function
    /// scans nothing; it prefixes the value with a space so the BM25 tokeniser
    /// sees the terms as additional body tokens.
    public static func lexicalSupplement(_ facts: String?) -> String {
        guard let facts, !facts.isEmpty else { return "" }
        return " " + facts
    }
}
