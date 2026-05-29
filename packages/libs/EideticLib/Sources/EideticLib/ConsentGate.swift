// ConsentGate.swift
//
// The activation consent gate for foreign-data schemes. From
// docs/canon/LAUNCH_PLAN.md §EideticLib:
//
//   "At activation the user is shown the licenses, agrees, and
//    only then does the app download the sources from the internet
//    and assemble them on the user's own machine. ... The consent
//    gate is small code carrying real weight, so it is built
//    deliberately, logged, and unskippable."
//
// Three invariants live in this file:
//
//   1. Unskippable. There is no API to fetch foreign data without
//      first recording a ConsentRecord. ForeignSourcePipeline
//      refuses to run without one.
//
//   2. Logged. Every acceptance produces a ConsentRecord in the
//      in-memory ledger keyed by the foreign-scheme identifier
//      and the licenses shown. Records are timestamped with the
//      Date the caller passes — engines remain deterministic per
//      the determinism rule in CLAUDE.md.
//
//   3. Per-scheme. Consent is granted per foreign scheme, not
//      globally. Granting Wikidata does not grant LCSH.

import Foundation

/// One recorded acceptance of an activation consent. Carries the
/// scheme identifier, the exact license-text fingerprint the user
/// saw, and the timestamp the caller supplied. Codable so callers
/// can persist the ledger across runs.
public struct ConsentRecord: Sendable, Hashable, Codable {

    /// Stable identifier of the foreign scheme accepted, e.g.
    /// "wikidata", "ddc", "lcsh". Must match the `schemeID` on
    /// the PinnedSource the pipeline will fetch.
    public let schemeID: String

    /// SHA-256 hex digest of the exact license text(s) shown at
    /// activation. Storing the digest rather than the full text
    /// keeps the ledger compact and lets the gate verify that the
    /// text shown has not drifted between sessions.
    public let licenseTextDigest: String

    /// Time the user accepted, in caller's frame of reference.
    /// Passed as a parameter to keep the gate deterministic for
    /// tests.
    public let acceptedAt: Date

    public init(
        schemeID: String,
        licenseTextDigest: String,
        acceptedAt: Date
    ) {
        self.schemeID = schemeID
        self.licenseTextDigest = licenseTextDigest
        self.acceptedAt = acceptedAt
    }
}

/// The in-memory consent ledger. Indexed by schemeID so the gate
/// can ask "has this scheme been activated?" in constant time.
/// An actor because consent acceptance is serialized across
/// concurrent activation requests.
public actor ConsentLedger {

    private var byScheme: [String: ConsentRecord] = [:]

    public init() {}

    /// All recorded acceptances. Order is not guaranteed.
    public var records: [ConsentRecord] {
        Array(byScheme.values)
    }

    /// Records a consent acceptance. Overwrites any prior record
    /// for the same scheme — re-acceptance updates the timestamp
    /// and the license digest, so a re-prompt after a license
    /// change is captured cleanly.
    public func record(_ record: ConsentRecord) {
        byScheme[record.schemeID] = record
    }

    /// True when a consent record exists for this scheme.
    public func hasConsent(forScheme id: String) -> Bool {
        byScheme[id] != nil
    }

    /// The recorded acceptance for a scheme, or nil if none.
    public func consent(forScheme id: String) -> ConsentRecord? {
        byScheme[id]
    }
}

/// The activation consent gate. The single surface a foreign-data
/// fetch must pass through. The pipeline holds a reference to one
/// of these and asks `verifyConsent(forScheme:)` before any
/// network call. There is no path from the public API to a fetch
/// that does not consult the gate — that is the "unskippable"
/// invariant in code form.
public actor ActivationConsent {

    /// The shared ledger this gate writes to and reads from.
    public let ledger: ConsentLedger

    public init(ledger: ConsentLedger = ConsentLedger()) {
        self.ledger = ledger
    }

    /// Records the user's acceptance for a foreign scheme. The
    /// caller is responsible for having shown the license text
    /// whose digest is recorded here; the gate has no opinion on
    /// presentation. Returns the recorded value so the caller can
    /// confirm the digest landed.
    public func accept(
        schemeID: String,
        licenseTextDigest: String,
        now: Date
    ) async -> ConsentRecord {
        let record = ConsentRecord(
            schemeID: schemeID,
            licenseTextDigest: licenseTextDigest,
            acceptedAt: now
        )
        await ledger.record(record)
        return record
    }

    /// True iff consent has been recorded for the named scheme.
    /// The pipeline calls this immediately before a fetch — a
    /// false return aborts the run before any network I/O.
    public func verifyConsent(forScheme id: String) async -> Bool {
        await ledger.hasConsent(forScheme: id)
    }
}
