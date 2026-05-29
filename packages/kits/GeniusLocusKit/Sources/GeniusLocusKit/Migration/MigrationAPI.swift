// MigrationAPI.swift
//
// The three migration verbs on GeniusLocusKit (GLK-MIG-02):
//   - importFromMemPalace: batch-import an ExternalCorpus into a new estate
//   - runParallel: open a dual-estate parallel capture window
//   - verifyMigration: verify every corpus entry is recallable from the estate
//
// All three verbs take an explicit `now: Date` parameter per the fleet
// determinism rule (CLAUDE.md): never call `Date()` inside an engine.
// Callers supply the observation timestamp so the operation is fully
// deterministic and testable.

import Foundation
import LocusKit
import PersistenceKit
import OSLog

public extension GeniusLocusKit {

    /// Logger reused across migration verb dispatch.
    private static var migrationLog: Logger {
        Logger(subsystem: "com.mootx01.kit", category: "GeniusLocusKit")
    }

    // MARK: - importFromMemPalace

    /// Import a MemPalace export into a new GeniusLocus estate.
    ///
    /// Opens a fresh estate against `targetStorage`, then iterates over
    /// every entry in `corpus`. Each entry with non-empty content is
    /// filed as a `Drawer` via the `capture` verb. Entries with empty
    /// content are recorded in `MigrationReport.unmappedConcepts` rather
    /// than silently dropped — satisfying spec conformance C-13
    /// (zero-loss invariant).
    ///
    /// The `CaptureFrame` for each entry uses `entry.content` as the
    /// content, `.typed` as the capture channel, `"migration"` as the
    /// room, and `LatticeAnchor.udc("000")` as the lattice anchor.
    /// These are reasonable defaults for imported MemPalace content;
    /// the caller may adjust the estate's drawers after import via
    /// the `mutate` and `reanchor` verbs.
    ///
    /// - Parameters:
    ///   - corpus: The MemPalace export to import.
    ///   - targetStorage: The storage backend for the new estate. The
    ///     caller supplies an already-constructed storage instance; the
    ///     kit opens the estate and the caller is responsible for the
    ///     storage's lifecycle.
    ///   - owner: Credentials for the estate's owner. Forwarded to
    ///     `open(storage:owner:)` unchanged.
    ///   - now: The observation timestamp. Passed as `eventTime` on
    ///     each `CaptureFrame` so all imported drawers carry the same
    ///     import instant — deterministic and testable per fleet rule.
    ///
    /// - Returns: A tuple of the opened `EstateHandle` and a
    ///   `MigrationReport` summarising what was written and what was
    ///   unmappable.
    ///
    /// - Throws: `GeniusLocusKitError` if `open` fails; `VerbError` if
    ///   any individual `capture` fails. Partial success is not possible:
    ///   if a capture throws, the operation propagates the error and the
    ///   partially-populated estate remains open (the caller decides
    ///   whether to close it or retry).
    func importFromMemPalace(
        _ corpus: ExternalCorpus,
        targetStorage: any Storage,
        owner: OwnerCredentials,
        now: Date
    ) async throws -> (EstateHandle, MigrationReport) {
        let handle = try await open(storage: targetStorage, owner: owner)
        var rowsByNoun: [String: Int] = [:]
        var unmappedConcepts: [UnmappedConcept] = []

        for entry in corpus.entries {
            // The zero-loss invariant (C-13) requires that every entry
            // ends up either as a captured drawer or as an unmapped
            // concept — no silent drops. Empty content is the only
            // condition we classify as unmappable in v1; future
            // validators may add size or format checks.
            guard !entry.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                unmappedConcepts.append(UnmappedConcept(
                    entryID: entry.id,
                    reason: "empty content"
                ))
                continue
            }
            let frame = CaptureFrame(
                content: entry.content,
                channel: .typed,
                room: "migration",
                latticeAnchor: .udc("000"),
                addedBy: "migration-import",
                embeddingModelID: "migration-v1",
                // eventTime carries `now` so every imported drawer has a
                // deterministic capture timestamp matching the import
                // instant — satisfies the fleet determinism rule and
                // ensures consistent ordering in recall results.
                eventTime: now
            )
            _ = try await capture(handle, frame)
            rowsByNoun["drawer", default: 0] += 1
        }

        let report = MigrationReport(
            rowsByNoun: rowsByNoun,
            unmappedConcepts: unmappedConcepts,
            warnings: []
        )
        Self.migrationLog.info(
            "importFromMemPalace: \(rowsByNoun["drawer"] ?? 0) drawers, \(unmappedConcepts.count) unmapped"
        )
        return (handle, report)
    }

    // MARK: - runParallel

    /// Open a dual-estate parallel capture run.
    ///
    /// Returns a `ParallelRunHandle` that routes new `capture` calls
    /// to the target, source, or both estates according to `mode`. Call
    /// `handle.stop()` when the parallel window closes.
    ///
    /// The parallel run handle does not automatically close the estates;
    /// lifecycle management (including closing both estates when done)
    /// remains the caller's responsibility.
    ///
    /// - Parameters:
    ///   - source: The source estate (the estate being migrated away
    ///     from). Must be open in this kit.
    ///   - target: The target estate (the estate being migrated into).
    ///     Must be open in this kit.
    ///   - mode: How captures are routed during the run.
    ///
    /// - Returns: A `ParallelRunHandle` the caller uses to issue
    ///   `capture` calls during the parallel window.
    ///
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if either handle
    ///   is stale (validates both before issuing the run handle).
    func runParallel(
        source: EstateHandle,
        target: EstateHandle,
        mode: ParallelCaptureMode
    ) async throws -> ParallelRunHandle {
        // Validate both estates are open before issuing the handle.
        // Fail fast here rather than failing on the first capture call
        // — a stale handle passed to runParallel is a programming error,
        // not a runtime condition that should surface mid-capture.
        _ = try estate(for: source)
        _ = try estate(for: target)
        Self.migrationLog.debug(
            "runParallel: source=\(source.estateUUID, privacy: .public) target=\(target.estateUUID, privacy: .public) mode=\(String(describing: mode), privacy: .public)"
        )
        return ParallelRunHandle(source: source, target: target, mode: mode, kit: self)
    }

    // MARK: - verifyMigration

    /// Verify migration fidelity by recalling each corpus entry from
    /// the estate.
    ///
    /// Issues one `recall` per corpus entry using the frames produced
    /// by `corpus.asRecallFrames()`. Returns `.identical` when every
    /// entry appears in its frame's recall results; returns `.diverged`
    /// with a list of missing entries otherwise.
    ///
    /// The verification uses content-match recall (`.contentMatches`)
    /// filtered to `.unconfirmed` rows. This matches the state of
    /// drawers produced by `importFromMemPalace` — they are captured
    /// (unconfirmed by default) and queryable by content substring.
    /// See the `ExternalCorpus.asRecallFrames()` doc-comment for the
    /// full rationale including the `.unconfirmed` requirement and the
    /// vector-tier deferral.
    ///
    /// - Parameters:
    ///   - estate: The estate to verify. Must be open in this kit.
    ///   - corpus: The reference corpus every entry of which should be
    ///     recallable from the estate.
    ///   - now: The observation timestamp. Unused by the current
    ///     verification logic (which is read-only) but present for
    ///     consistency with `importFromMemPalace` and to give future
    ///     time-bounded verification a slot without a signature change.
    ///
    /// - Returns: `.identical` if all entries are found; `.diverged`
    ///   with one `MigrationDivergence` per missing entry otherwise.
    ///
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if `estate` is
    ///   stale; any `VerbError` from recall dispatch.
    func verifyMigration(
        estate estateHandle: EstateHandle,
        against corpus: ExternalCorpus,
        now: Date
    ) async throws -> MigrationVerification {
        // Validate the handle up front. An empty corpus on a stale
        // handle should surface .estateNotOpen, not .identical.
        _ = try estate(for: estateHandle)

        var divergences: [MigrationDivergence] = []
        let frames = corpus.asRecallFrames()

        for (entry, frame) in zip(corpus.entries, frames) {
            let results = try await recall(estateHandle, frame)
            // A content-match recall returns any drawer whose content
            // contains the entry's text. The migration is faithful if
            // at least one result comes back — the exact rank position
            // is not checked here (MRR scoring is NeuronKit's domain).
            let found = !results.isEmpty
            if !found {
                divergences.append(MigrationDivergence(
                    entryID: entry.id,
                    reason: "not found in recall results"
                ))
            }
        }

        if divergences.isEmpty {
            Self.migrationLog.info("verifyMigration: .identical — all \(corpus.entries.count) entries recalled")
            return .identical
        } else {
            Self.migrationLog.warning(
                "verifyMigration: .diverged — \(divergences.count) of \(corpus.entries.count) entries not recalled"
            )
            return .diverged(divergences)
        }
    }
}
