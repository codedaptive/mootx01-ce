import Testing
import Foundation
import CorpusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import SubstrateLib
import SubstrateTypes
@testable import GeniusLocusKit

/// Tests for GeniusLocusKit's composed Merkle snapshot, which writes
/// both LocusKit (node-tree) and CorpusKit (content-hash) attestations
/// into a single atomic snapshot.
@Suite("Merkle composition")
struct MerkleCompositionTests {

    private func makeStorage() -> InMemoryStorage {
        let config = EstateConfiguration(
            estateID: UUID(),
            backend: .inMemory
        )
        return InMemoryStorage(configuration: config)
    }

    /// Composed snapshot without a registered Corpus falls back to
    /// LocusKit-only attestations — same as calling Estate.createSnapshot
    /// directly. No corpus attestations appear.
    @Test
    func composedSnapshotWithoutCorpusMatchesLocusOnly() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-A")
        let storage = makeStorage()

        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = try await kit.createComposedSnapshot(
            for: handle,
            label: "locus-only",
            now: now
        )

        #expect(snapshot.label == "locus-only")
        // LocusKit attestations: estate root + default wings (3).
        // No corpus attestations should be present.
        let attestations = try await SnapshotRegistryOps.attestations(
            rowStore: storage.rowStore,
            snapshotId: snapshot.snapshotId
        )
        let corpusKinds = attestations.filter {
            $0.subjectKind == "corpus_index" || $0.subjectKind == "corpus_index_global"
        }
        #expect(corpusKinds.isEmpty)

        // Verify LocusKit attestations are present.
        let estateAtts = attestations.filter { $0.subjectKind == "estate" }
        #expect(estateAtts.count == 1)
    }

    /// With a registered Corpus containing ingested content, the composed
    /// snapshot includes per-corpus and global corpus attestations alongside
    /// the LocusKit node-tree attestations.
    @Test
    func composedSnapshotWithCorpusIncludesBothKits() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-B")
        let estateStorage = makeStorage()
        let corpusStorage = makeStorage()

        _ = try await LocusKit.Estate.create(storage: estateStorage, owner: owner)
        let handle = try await kit.open(storage: estateStorage, owner: owner)

        // Stand up a Corpus and ingest a document.
        let corpus = try await CorpusContentEngine(standaloneOn: corpusStorage)
        let ingestNow = Date(timeIntervalSince1970: 1_700_000_000)
        try await corpus.ingest("Hello world corpus content", contentID: "doc-1", now: ingestNow)
        await kit.registerCorpus(corpus, for: handle)

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = try await kit.createComposedSnapshot(
            for: handle,
            label: "composed",
            now: now
        )

        let attestations = try await SnapshotRegistryOps.attestations(
            rowStore: estateStorage.rowStore,
            snapshotId: snapshot.snapshotId
        )

        // LocusKit attestations present.
        let estateAtts = attestations.filter { $0.subjectKind == "estate" }
        #expect(estateAtts.count == 1)

        // Shared-content 1.1: the engine attests derived-index COVERAGE —
        // the canonical (revision, digest) each ID's derived rows reflect —
        // and never builds a second content Merkle hierarchy.
        let corpusAtts = attestations.filter { $0.subjectKind == "corpus_index" }
        #expect(corpusAtts.count == 1)
        #expect(corpusAtts.first?.subjectId == "doc-1")
        #expect(corpusAtts.first?.merkleRoot
            == CorpusContentDigest.digest("Hello world corpus content"))

        // Global coverage attestation over the sorted per-content rows.
        let globalAtts = attestations.filter { $0.subjectKind == "corpus_index_global" }
        #expect(globalAtts.count == 1)
        #expect(globalAtts.first?.merkleRoot != MerkleRoot.empty.hexString)
    }
}
