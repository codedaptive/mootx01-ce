// MigrationAPI.swift
//
// The two migration verbs on GeniusLocusKit (VK-ADAPT-01):
//   - runParallel: open a dual-estate parallel capture window
//   - verifyMigration: verify every corpus entry is recallable from the estate
//
// Mass data ingestion (decoding an external tool export and capturing
// its content into an estate) lives in VaultKit behind the adapter →
// bridge path per ADR-007 Decision 1: ExchangeAdapter → VaultBridge.importVault
// with CaptureChannel.importedFile and SourceType.imported provenance.
//
// All verbs take an explicit `now: Date` parameter per the fleet
// determinism rule (CLAUDE.md): never call `Date()` inside an engine.
// Callers supply the observation timestamp so the operation is fully
// deterministic and testable.

import Foundation
import SubstrateTypes
import LocusKit
import PersistenceKit
import OSLog

public extension GeniusLocusKit {

    /// Logger reused across migration verb dispatch.
    private static var migrationLog: Logger {
        Logger(subsystem: "com.mootx01.kit", category: "GeniusLocusKit")
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
    /// drawers that entered the estate through the capture verb (via
    /// VaultKit's adapter → bridge path): imported drawers are
    /// unconfirmed by default and queryable by content substring.
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
    ///     deterministic-time consistency and to give future
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
