// AuditChainReport.swift
//
// Result of a unified-audit-log integrity check (mission GLK-03).
//
// Shape is fixed by NEURONKIT_SPEC_v0.1.md §3.5 and invariant C-12:
// the audit-chain monitor — callable as the `verifyAuditChain`
// reasoning function — returns exactly these five fields. The type
// lives in GeniusLocusKit (not NeuronKit) because the verifier that
// produces it (`AuditChainVerifier`) operates on the unified log this
// kit owns; NeuronKit's §3.5 monitor wraps this verb in a later
// mission and re-exports the same shape.
//
// C-12: on a chain gap (a stored id that does not match the content
// hash recomputed from the entry's fields, or an HLC reversal), the
// report carries `valid == false` with `firstBrokenAt` set to the
// timestamp of the first offending entry. A clean chain has
// `valid == true` and `firstBrokenAt == nil`.

import Foundation

/// Integrity report for a unified audit log. Per NEURONKIT_SPEC §3.5.
public struct AuditChainReport: Sendable, Equatable {

    /// True when every entry's stored id matches its recomputed content
    /// hash and HLC ordering is monotonic. False on the first violation.
    public let valid: Bool

    /// Number of entries the verifier walked.
    public let entryCount: Int

    /// Timestamp of the earliest entry (by HLC). For an empty log this
    /// is the epoch sentinel `Date(timeIntervalSince1970: 0)` — there is
    /// no entry to date, and the spec's field is non-optional.
    public let firstEntryAt: Date

    /// Timestamp of the latest entry (by HLC). Epoch sentinel for an
    /// empty log, as with `firstEntryAt`.
    public let lastEntryAt: Date

    /// Timestamp of the first entry that failed integrity, or nil when
    /// the chain is intact. Set together with `valid == false` (C-12).
    public let firstBrokenAt: Date?

    public init(valid: Bool,
                entryCount: Int,
                firstEntryAt: Date,
                lastEntryAt: Date,
                firstBrokenAt: Date?) {
        self.valid = valid
        self.entryCount = entryCount
        self.firstEntryAt = firstEntryAt
        self.lastEntryAt = lastEntryAt
        self.firstBrokenAt = firstBrokenAt
    }
}
