/// Canonical identifier for the intent-span converter.
///
/// Mirrors the Python constants in distill_plus_converter.py:
///   CONVERTER_VERSION = "distill-plus-v1"
///   INTENT_SPAN_VERSION = "intent-span-v22-authority-closure"
///   schema_version: 1
public enum ContextDistillConverter: String, Sendable, Equatable, CaseIterable {

    /// The intent-span@v22 authority-closure candidate.
    ///
    /// Selects complete, exact source atoms around operative intent and
    /// dependency-closed document structure without rewriting their contents.
    case intentSpanV22

    /// Stable identifier that appears in converter_id fields of output rows.
    /// Mirrors ``f"{candidate}@{INTENT_SPAN_VERSION}"`` from the converter.
    public var id: String { "intent-span@intent-span-v22-authority-closure" }

    /// Version string for the converter ruleset.
    /// Mirrors ``CONVERTER_VERSION = "distill-plus-v1"`` in distill_plus_converter.py.
    public var converterVersion: String { "distill-plus-v1" }

    /// Schema version integer for the output overlay format.
    /// Mirrors the ``schema_version: 1`` field written to each output row.
    public var schemaVersion: Int { 1 }
}
