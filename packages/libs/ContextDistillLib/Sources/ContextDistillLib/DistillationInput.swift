/// The two source fields that every converter variant receives.
///
/// Mirrors the ``original`` and ``enrichment_trailer`` fields extracted from
/// each estate record before conversion begins.  The ``original`` field is
/// the raw source text passed to ``ContextShape.classify``.  The
/// ``enrichment_trailer`` is the grammar-v1 enrichment suffix (may be empty).
public struct DistillationInput: Sendable, Equatable {

    /// Raw source text of the estate record.  This is the string that
    /// ``ContextShape.classify(_:)`` receives as its argument.
    public var original: String

    /// Exact grammar-v1 enrichment trailer stripped from the stored p2.3
    /// rendering, or an empty string when no trailer is present.
    ///
    /// Mirrors the ``enrichment_trailer`` field written to JSONL output rows.
    public var enrichmentTrailer: String

    /// Creates a new distillation input.
    ///
    /// - Parameters:
    ///   - original: The raw source text.
    ///   - enrichmentTrailer: The grammar-v1 trailer, or `""` if absent.
    public init(original: String, enrichmentTrailer: String = "") {
        self.original = original
        self.enrichmentTrailer = enrichmentTrailer
    }
}
