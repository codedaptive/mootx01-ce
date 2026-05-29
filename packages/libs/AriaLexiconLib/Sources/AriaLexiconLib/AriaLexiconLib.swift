// AriaLexiconLib.swift
//
// The ARIA grammar in one sentence: every call is one verb applied to
// a noun, optionally constrained by adjectives. This module reifies
// that grammar so it can be conformance-checked across ports. It
// carries the words and their relationships, nothing else.
//
// Provenance: the grammar was set in the action-vocabulary design
// session of 2026-05-09 (architecture v0.20, Part 10) and restored to
// first-class status here. The verb count is fixed at nine and the
// adjective category count at four (spec invariants I-7, I-8).

public enum AriaLexiconLib {
    /// The grammar, stated. The contract every consumer composes.
    public static let grammar =
        "Every call is one verb applied to a noun, optionally constrained by adjectives."
}
