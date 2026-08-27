// EmbeddingProviderManifestTests.swift
//
// Tests for the optimizer-owned "embedding_provider" manifest key:
// the provision/provisioned verb pair on GeniusLocusKit and the meta-key
// constant in RecallDirector.
//
// ## Coverage
//
//   (a) Meta key constant — embeddingProviderMetaKey == "embedding_provider"
//       (confirms the wire key is stable and matches the Rust twin).
//   (b) Absent key — provisionedEmbeddingProvider returns nil when the estate
//       has no embedding_provider key (the deterministic-default sentinel).
//   (c) Provision + read-back — provision a model ID, read it back unchanged.
//   (d) Overwrite — provision twice, second write wins.
//   (e) Empty-string round-trip — empty string stores and reads back as "".
//       Callers treat "" the same as nil (both mean: use deterministic default).

import Testing
import Foundation
import PersistenceKit
import PersistenceKitInMemory
import LocusKit
@testable import GeniusLocusKit

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Unit tests (no estate needed)
// ─────────────────────────────────────────────────────────────────────────────

@Suite("EmbeddingProvider manifest key — constant")
struct EmbeddingProviderMetaKeyTests {

    // (a) The constant must be the string "embedding_provider" — this is the
    //     wire key stored in the estate manifest table. Matches Rust twin
    //     `EstateCoordinator::EMBEDDING_PROVIDER_META_KEY`.
    @Test("embeddingProviderMetaKey is embedding_provider")
    func metaKeyValue() {
        #expect(GeniusLocusKit.embeddingProviderMetaKey == "embedding_provider")
    }

    // The three optimizer-owned manifest keys must all be distinct so they
    // key to separate manifest rows.
    @Test("embeddingProviderMetaKey is distinct from laneWeightsMetaKey")
    func distinctFromLaneWeights() {
        #expect(GeniusLocusKit.embeddingProviderMetaKey != GeniusLocusKit.laneWeightsMetaKey)
    }

    @Test("embeddingProviderMetaKey is distinct from recallTuningMetaKey")
    func distinctFromRecallTuning() {
        #expect(GeniusLocusKit.embeddingProviderMetaKey != GeniusLocusKit.recallTuningMetaKey)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Estate verb round-trip tests (in-memory estate)
// ─────────────────────────────────────────────────────────────────────────────

@Suite("EmbeddingProvider manifest key — estate verb round-trip", .serialized)
struct EmbeddingProviderManifestEstateTests {

    /// Open an empty in-memory estate. Pattern mirrors RecallTuningManifestTests
    /// and LaneWeights tests so the test patterns are consistent fleet-wide.
    private func openEmptyEstate(owner ownerID: String = "embed-prov-test") async throws
        -> (kit: GeniusLocusKit, handle: EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: ownerID)
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        return (kit, handle)
    }

    // (b) Absent key → nil
    // An estate that has never had embedding_provider written must return nil,
    // which is the sentinel for "use the deterministic default ensemble."
    // If this returns a non-nil value, the estate is pre-provisioned by some
    // migration path that did not exist when this test was written.
    @Test("absent embedding_provider key returns nil")
    func absentKeyReturnsNil() async throws {
        let (kit, handle) = try await openEmptyEstate(owner: "absent-embed-prov")
        let result = try await kit.provisionedEmbeddingProvider(for: handle)
        #expect(result == nil,
                "expected nil when no embedding_provider key has been provisioned")
    }

    // (c) Provision + read-back: golden pin with "apple-nl-v1"
    // The optimizer would write this after determining that the Apple NL
    // unnormalized provider improves recall on this estate. The product
    // reads it back to select the provider at open time.
    @Test("provisioned apple-nl-v1 reads back unchanged")
    func provisionAppleNLReadsBack() async throws {
        let (kit, handle) = try await openEmptyEstate(owner: "apple-nl-readback")
        try await kit.provisionEmbeddingProvider("apple-nl-v1", for: handle)
        let result = try await kit.provisionedEmbeddingProvider(for: handle)
        #expect(result == "apple-nl-v1",
                "expected provisioned model_id to survive a round-trip through the manifest")
    }

    // (c) Provision + read-back: a different model ID
    @Test("provisioned apple-nlembedding-v1 reads back unchanged")
    func provisionNLEmbeddingReadsBack() async throws {
        let (kit, handle) = try await openEmptyEstate(owner: "nlembedding-readback")
        try await kit.provisionEmbeddingProvider("apple-nlembedding-v1", for: handle)
        let result = try await kit.provisionedEmbeddingProvider(for: handle)
        #expect(result == "apple-nlembedding-v1")
    }

    // (d) Overwrite: the second provision wins
    // The optimizer may update the provider selection as the estate grows
    // or as new benchmark results arrive.
    @Test("second provision overwrites first")
    func provisionOverwrite() async throws {
        let (kit, handle) = try await openEmptyEstate(owner: "embed-prov-overwrite")
        try await kit.provisionEmbeddingProvider("apple-nlembedding-v1", for: handle)
        try await kit.provisionEmbeddingProvider("apple-nl-v1", for: handle)
        let result = try await kit.provisionedEmbeddingProvider(for: handle)
        #expect(result == "apple-nl-v1",
                "expected the second provision to win; got: \(result as Any)")
    }

    // (e) Empty-string round-trip
    // An empty string is a valid write (the verb does not reject it). Callers
    // that read "" treat it the same as nil (unknown model_id → deterministic
    // default). Storing "" must not crash or corrupt the manifest.
    @Test("empty string model_id stores and reads back as empty string")
    func emptyStringRoundTrip() async throws {
        let (kit, handle) = try await openEmptyEstate(owner: "empty-model-id")
        try await kit.provisionEmbeddingProvider("", for: handle)
        // After writing "", the meta key is present but empty. meta(key:) returns
        // Some("") rather than nil — the key exists. Callers normalize "" → absent.
        let result = try await kit.provisionedEmbeddingProvider(for: handle)
        // The result may be nil or "" depending on how meta(key:) handles an empty
        // value. Both are acceptable — the contract is "nil or empty → deterministic
        // default." We assert that the call does NOT throw and the result is either
        // nil or "".
        if let value = result {
            #expect(value == "",
                    "expected empty string or nil for empty model_id write; got \(value)")
        }
        // If result is nil, the empty write was coalesced to absent — also correct.
    }

    // Selection round-trip for a hypothetical unknown future provider.
    // Documents that the verb is model-ID-agnostic: it stores and returns any
    // String without validation. Consumers reject unknown IDs at resolution time.
    @Test("arbitrary model_id string is preserved verbatim")
    func arbitraryModelIDPreserved() async throws {
        let (kit, handle) = try await openEmptyEstate(owner: "arbitrary-model-id")
        let modelID = "hypothetical-provider-v99"
        try await kit.provisionEmbeddingProvider(modelID, for: handle)
        let result = try await kit.provisionedEmbeddingProvider(for: handle)
        #expect(result == modelID)
    }
}
