import Foundation

/// Grammar-v1 trailer extraction for the LEXICAL lane
/// (DECISION_DENSE_LANE_ENRICHMENT, Wave 2 delivery ruling 2026-08-20).
///
/// The dense-lane text may end with an enrichment trailer:
/// `(*[ kind: hobby, entity: painting, country: brazil ]*)` — category and
/// entity facts welded on by the enrichment pipeline (or an oracle build).
/// The oracle gate measured that these facts only pay when the KEYWORD lane
/// can see them (the anarrow arm: temporal MRR 0.4154 → 0.4487, 3/11
/// never-rescued misses recovered), and Bob's ruling — BM25 is <1% of
/// estate storage — approved indexing them lexically.
///
/// This type SCANS (never regex) the trailer out of the dense text so the
/// index engine can append its tokens to the BM25 document. The verbatim
/// canonical text is never modified and remains the returned payload; the
/// trailer tokens participate in keyword scoring only.
public enum TrailerGrammar {
    /// Opening delimiter. The pair cannot occur in natural prose — chosen
    /// for exactly that property in the decision record.
    public static let open = "(*["
    /// Closing delimiter.
    public static let close = "]*)"

    /// Returns the lexical supplement for a dense-composition text: the
    /// inner text of the LAST well-formed trailer block, prefixed with a
    /// single separating space — or `""` when the text is nil, carries no
    /// trailer, or the delimiters are malformed (fail-quiet: a broken
    /// trailer simply contributes nothing to the keyword lane).
    public static func lexicalSupplement(fromDenseText denseText: String?) -> String {
        guard let denseText, !denseText.isEmpty else { return "" }
        // Scan from the end: the trailer is appended to the distillate, so
        // the last well-formed block is the enrichment contract's block.
        guard let openRange = denseText.range(of: open, options: .backwards),
              let closeRange = denseText.range(of: close, options: .backwards),
              openRange.upperBound <= closeRange.lowerBound
        else { return "" }
        let inner = denseText[openRange.upperBound..<closeRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !inner.isEmpty else { return "" }
        return " " + inner
    }
}
