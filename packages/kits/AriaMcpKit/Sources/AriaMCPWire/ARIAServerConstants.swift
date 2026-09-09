// ARIAServerConstants.swift
//
// Server-side string constants that both ARIA MCP producers (AriaMCP) and
// consumers (AriaMCPWire-only targets) need to share.  Defined here so that
// a consumer that links only AriaMCPWire can reference the same value that
// ResultComposer emits, with no risk of silent divergence through a duplicated
// literal.

/// Constants emitted by the ARIA MCP result composer that consumers must match
/// exactly to implement the correct admissibility rules.
public enum ARIAServerConstants {
    /// The subject value the server places on an opaque (gated or unhydrated)
    /// search row — one whose content the caller is not permitted to read.
    /// A row carrying this subject must be filtered at the consumer before it
    /// reaches any UI, so a gated memory never surfaces as an unexplained
    /// "(no subject)" entry in search results.
    ///
    /// This is the single stored declaration. `ResultComposer.noSubjectMarker`
    /// (in AriaMCP) forwards to this constant, so there is one value and the
    /// compiler enforces parity between the producer and all consumers.
    public static let noSubjectMarker = "(no subject)"
}
