// MigrationTypes.swift
//
// Value types and error enum for the GeniusLocusKit migration API
// (GLK-MIG-02). These are the data-transfer objects the three
// migration verbs produce and consume — no estate logic here.

import Foundation

// MARK: - MigrationReport

/// A summary of a completed MemPalace import operation.
///
/// Produced by `GeniusLocusKit.importFromMemPalace(_:targetStorage:owner:now:)`.
/// Every corpus entry is accounted for: entries that landed in the estate
/// appear in `rowsByNoun`; entries that could not be mapped appear in
/// `unmappedConcepts`. The two counts must sum to `corpus.entries.count`
/// (spec conformance C-13 zero-loss invariant).
public struct MigrationReport: Sendable, Codable {
    /// How many rows of each noun were written into the target estate.
    /// The primary key today is `"drawer"`. Future migration missions
    /// may add `"kgFact"`, `"diaryEntry"`, etc. as the schema expands.
    public let rowsByNoun: [String: Int]

    /// Corpus entries that could not be mapped to any estate noun.
    /// Non-empty only when the importer encounters content it cannot
    /// classify — for example, an empty content field. These entries
    /// are not silently dropped; they appear here so the caller can
    /// inspect, triage, and re-import if needed.
    public let unmappedConcepts: [UnmappedConcept]

    /// Non-fatal warnings produced during the import. May include
    /// advisory notes about schema shape, tag normalisation, or
    /// encoding ambiguity. Warnings do not stop the import.
    public let warnings: [MigrationWarning]

    public init(
        rowsByNoun: [String: Int],
        unmappedConcepts: [UnmappedConcept],
        warnings: [MigrationWarning]
    ) {
        self.rowsByNoun = rowsByNoun
        self.unmappedConcepts = unmappedConcepts
        self.warnings = warnings
    }
}

// MARK: - UnmappedConcept

/// A corpus entry that could not be mapped to any estate noun during import.
///
/// Returned in `MigrationReport.unmappedConcepts`. Carries the entry's
/// stable ID and a human-readable reason so the caller can inspect and
/// optionally re-import the entry with corrected content.
public struct UnmappedConcept: Sendable, Codable {
    /// The `ExternalEntry.id` of the entry that could not be mapped.
    public let entryID: String
    /// A human-readable description of why the entry was not mapped.
    /// Examples: "empty content", "content exceeds maximum blob size".
    public let reason: String

    public init(entryID: String, reason: String) {
        self.entryID = entryID
        self.reason = reason
    }
}

// MARK: - MigrationWarning

/// A non-fatal advisory produced during a migration import.
///
/// Warnings are purely informational. The import continues when a warning
/// is emitted; the caller can inspect the warning list after the operation
/// completes. A warning is not a sign of data loss — unmappable entries
/// go to `MigrationReport.unmappedConcepts`, not to warnings.
public struct MigrationWarning: Sendable, Codable {
    /// A human-readable description of the advisory condition.
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

// MARK: - ParallelCaptureMode

/// Controls how captures are routed during a dual-estate parallel run.
///
/// A parallel run keeps a source (the old estate) and a target (the new
/// estate) open simultaneously. The mode decides which estate receives
/// new captures and which estate serves reads. Typically migration
/// operators start in `.writeToTarget`, optionally advance to
/// `.mirrorBoth` for a verification window, then promote the target to
/// primary.
public enum ParallelCaptureMode: Sendable, Codable {
    /// All new captures go to the target estate only. The source is
    /// kept open for reads but receives no new writes. This is the
    /// typical mode at the start of a migration: new content builds up
    /// in the target while the source is being verified.
    case writeToTarget

    /// New captures go to the target; reads that miss the target fall
    /// through to the source. Models a "shadow read" window where the
    /// target is becoming the authority but the source is still the
    /// safety net.
    case readFromSource

    /// New captures go to both estates simultaneously. Useful for
    /// short-lived dual-write verification windows where both estates
    /// must stay in sync before the source is decommissioned.
    case mirrorBoth
}

// MARK: - MigrationVerification

/// The result of `GeniusLocusKit.verifyMigration(estate:against:now:)`.
///
/// `.identical` means every corpus entry was found in the estate's
/// recall results. `.diverged` carries a list of entries that could
/// not be recalled, indicating content loss or recall-configuration
/// mismatch.
public enum MigrationVerification: Sendable {
    /// Every corpus entry was recalled from the estate. The migration
    /// is complete and content-faithful.
    case identical

    /// One or more corpus entries could not be recalled. Each entry in
    /// the associated array describes what was missing and why.
    case diverged([MigrationDivergence])
}

// MARK: - MigrationDivergence

/// A single entry from an `ExternalCorpus` that could not be recalled
/// from the estate during `verifyMigration`.
///
/// Returned inside `MigrationVerification.diverged`. The caller can
/// inspect the list to determine which entries need to be re-imported or
/// manually reconciled.
public struct MigrationDivergence: Sendable {
    /// The `ExternalEntry.id` of the entry that could not be recalled.
    public let entryID: String
    /// A human-readable description of the failure. Typically "not found
    /// in recall results"; future implementations may include "content
    /// hash mismatch" when content-level verification is added.
    public let reason: String

    public init(entryID: String, reason: String) {
        self.entryID = entryID
        self.reason = reason
    }
}

// MARK: - MigrationError

/// Errors produced by the migration API surface on `GeniusLocusKit`.
///
/// Declared as a standalone enum (not an extension on `GeniusLocusKitError`)
/// because Swift does not permit adding enum cases via extension. The
/// migration surface is additive and isolated; mixing its errors into
/// `GeniusLocusKitError` would widen the estate-level error space for
/// all callers, not only migration callers.
public enum MigrationError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The `ExternalCorpus` could not be read or decoded. The associated
    /// `reason` carries the underlying failure description.
    case corpusUnreadable(reason: String)

    /// A capture was attempted on a `ParallelRunHandle` after `stop()`
    /// was called. The handle is permanently stopped; a new parallel run
    /// must be started.
    case parallelRunStopped

    /// The target estate referenced by a migration verb is not open in
    /// the kit. Typically indicates a lifecycle mismatch — the estate
    /// was closed before the migration completed.
    case targetEstateNotOpen

    public var description: String {
        switch self {
        case .corpusUnreadable(let reason):
            return "MigrationError.corpusUnreadable: \(reason)"
        case .parallelRunStopped:
            return "MigrationError.parallelRunStopped: capture attempted on a stopped parallel run handle"
        case .targetEstateNotOpen:
            return "MigrationError.targetEstateNotOpen: target estate is not open in this kit"
        }
    }
}
