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
            // Per-corpus attestations: one per source document.
            let sourceIDs = try await corpus.indexedSourceIDs()
            for sourceID in sourceIDs.sorted() {
                let root = try await corpus.corpusMerkleRoot(for: sourceID)
                corpusAttestations.append(SnapshotAttestation(
                    snapshotId: dummyId,
                    subjectKind: "corpus",
                    subjectId: sourceID,
                    merkleRoot: root.hexString
                ))
            }

            // Global corpus attestation: interior hash over all corpus roots.
            let globalRoot = try await corpus.globalCorpusMerkleRoot()
            corpusAttestations.append(SnapshotAttestation(
                snapshotId: dummyId,
                subjectKind: "corpus_global",
                subjectId: handle.estateUUID.uuidString,
                merkleRoot: globalRoot.hexString
            ))

            compositionLog.info("MerkleComposition: \(corpusAttestations.count) corpus attestations for estate \(handle.estateUUID)")
        }

        return try await estate.createSnapshot(
            label: label,
            now: now,
            additionalAttestations: corpusAttestations
        )
    }
}
