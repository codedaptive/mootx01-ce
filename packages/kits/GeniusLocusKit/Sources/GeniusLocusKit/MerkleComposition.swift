// MerkleComposition.swift
//
// Composes Merkle attestations from LocusKit and CorpusKit into a
// single snapshot. LocusKit provides per-wing and estate-root
// attestations from the node tree; CorpusKit provides per-corpus
// and global-corpus attestations from the BundleStore. Both sets
// are written atomically via Estate.createSnapshot's
// additionalAttestations parameter.

import CorpusKit
import Foundation
import LocusKit
import OSLog
import PersistenceKit
import SubstrateLib

private let compositionLog = Logger(subsystem: "com.mootx01.kit", category: "GeniusLocusKit.MerkleComposition")

public extension GeniusLocusKit {

    /// Create a snapshot with composed Merkle attestations from both
    /// LocusKit (node-tree integrity) and CorpusKit (content-hash
    /// integrity). All attestations land in one atomic snapshot row.
    ///
    /// When no Corpus is registered for the handle, falls back to
    /// LocusKit-only attestations (identical to calling
    /// `Estate.createSnapshot` directly).
    ///
    /// - Parameters:
    ///   - handle: The estate to snapshot.
    ///   - label: Optional human-readable label.
    ///   - now: Deterministic wall-clock for timestamps.
    /// - Returns: The created SnapshotRecord.
    @discardableResult
    func createComposedSnapshot(
        for handle: EstateHandle,
        label: String?,
        now: Date
    ) async throws -> SnapshotRecord {
        let estate = try estate(for: handle)
        var corpusAttestations: [SnapshotAttestation] = []
        let dummyId = SnapshotId("")

        if let corpus = corpusKits[handle] {
            // Shared-content 1.1: canonical-content integrity is the LocusKit
            // Drawer content root — CorpusKit builds NO second content Merkle
            // hierarchy. The engine attests derived-index COVERAGE instead:
            // per content ID, the canonical (revision, digest) its derived
            // rows reflect (the digest IS the drawer content digest, so the
            // attestation binds derived rows to canonical content without
            // duplicating the hierarchy).
            let coverage = try await corpus.indexCoverageAttestations()
            for entry in coverage.sorted(by: { $0.contentID < $1.contentID }) {
                corpusAttestations.append(SnapshotAttestation(
                    snapshotId: dummyId,
                    subjectKind: "corpus_index",
                    subjectId: entry.contentID,
                    merkleRoot: entry.digest
                ))
            }
            // Global coverage attestation: one digest over the sorted
            // per-content coverage rows.
            let folded = coverage
                .sorted(by: { $0.contentID < $1.contentID })
                .map { "\($0.contentID):\($0.revision):\($0.digest)" }
                .joined(separator: "\n")
            corpusAttestations.append(SnapshotAttestation(
                snapshotId: dummyId,
                subjectKind: "corpus_index_global",
                subjectId: handle.estateUUID.uuidString,
                merkleRoot: CorpusContentDigest.digest(folded)
            ))

            compositionLog.info("MerkleComposition: \(corpusAttestations.count) corpus coverage attestations for estate \(handle.estateUUID)")
        }

        return try await estate.createSnapshot(
            label: label,
            now: now,
            additionalAttestations: corpusAttestations
        )
    }
}
