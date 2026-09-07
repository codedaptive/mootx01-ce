// ExpungeEncoderLaneTests.swift
//
// The encoder span lane is part of the expunge destruction contract
// (GENIUSLOCUSKIT_SPEC §B-2a step 2, §B-2b step 3a). The spanEncode duty
// stores up to maxSpans int8 span vectors per drawer under the ENCODER's
// model id (`<model>-w<window>`), which is neither the distillation lane nor
// the corpus model id. Expunge and the integrity sweep must delete those rows
// for the erased drawer and leave every other drawer's rows alone.
//
// Tests (twin of Rust `expunge_encoder_lane.rs`):
//   L1 — expunge scrubs the span rows under an `encoder_models` registry id
//        (no encoder registered for the session).
//   L2 — expunge scrubs the span rows under the session's registered encoder
//        when the registry holds no row for it.
//   L3 — the integrity sweep scrubs the span rows of a crash-window row.
//
// Every test also pins the scope: a sibling drawer's span rows under the
// same model id survive the erase.

import Testing
import Foundation
import CorpusKit
import SynapseKit
import PersistenceKit
import PersistenceKitInMemory
@testable import LocusKit     // Estate.expungeReturningUnsealedEvent (crash-window seed)
@testable import GeniusLocusKit

@Suite("Expunge — encoder span lane is scrubbed by expunge and the integrity sweep")
struct ExpungeEncoderLaneTests {

    /// The encoder lane under test. Same literal as the Rust twin.
    private static let encoderModelID = "fake-encoder-w3"
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Helpers

    /// Provision a full `.glk` estate (LocusKit + Corpus + VectorStore wired).
    private func provisionGLKEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-encoder-lane-tests")
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        let params = EstateProvisionParams(
            estateName: "Encoder Lane Expunge Test Estate",
            kind: .glk,
            zoomWindowLow: 1,
            zoomWindowHigh: 10,
            frameworkProfile: "KnowledgeWork",
            syncMode: .none
        )
        let handle = try await kit.provision(
            storage: storage, owner: owner, params: params,
            embeddingModels: [.deterministic])
        return (kit, handle)
    }

    private func captureFrame(content: String) -> CaptureFrame {
        CaptureFrame(
            content: content,
            channel: .typed,
            room: "encoder-lane-tests",
            latticeAnchor: .udc("000"),
            addedBy: "encoder-lane-tests",
            embeddingModelID: "test-model-v1"
        )
    }

    /// One `encoder_models` registry row for `encoderModelID`.
    private func registryRow() -> EncoderModelRow {
        EncoderModelRow(
            modelID: Self.encoderModelID, modelVersion: "v1", dim: 4,
            queryPrefix: "Q:", docPrefix: "D:", pooling: .mean,
            tokenizerHash: "abc123", windowWords: 3, overlapDivisor: 2,
            maxSpans: 4, maxSequence: 512, isActive: true)
    }

    /// A session encoder whose spec names `encoderModelID`; never invoked
    /// (the tests write span rows directly), it only supplies the model id.
    private struct FakeEncoder: SpanEncoder {
        let spec = EncoderModelSpec(
            modelID: ExpungeEncoderLaneTests.encoderModelID,
            modelVersion: "v1",
            dim: 4,
            queryPrefix: "Q:",
            docPrefix: "D:",
            pooling: .mean,
            tokenizerHash: "abc123",
            windowWords: 3,
            overlapDivisor: 2,
            maxSpans: 4,
            maxSequence: 512)

        func encodeQuery(_ text: String) async throws -> [Float] {
            [0.5, -0.5, 0.25, -0.25]
        }

        func encodeSpans(_ spans: [String]) async throws -> [[Float]] {
            spans.map { _ in [0.5, -0.5, 0.25, -0.25] }
        }
    }

    /// Two int8 spans, the shape the spanEncode duty writes. Same literals
    /// as the Rust twin.
    private func spanRows() -> [SpanVectorInput] {
        [
            SpanVectorInput(index: 0, int8: [127, -127, 64, -64], scale: 0.0039,
                            startWord: 0, endWord: 3, contentVersion: "cv-erase"),
            SpanVectorInput(index: 1, int8: [1, -1, 2, -2], scale: 0.5,
                            startWord: 1, endWord: 4, contentVersion: "cv-erase"),
        ]
    }

    private func spanCount(_ vectorStore: VectorStore, _ id: String) async throws -> Int {
        try await vectorStore.spanVectors(itemIDs: [id], modelID: Self.encoderModelID)[id]?.count ?? 0
    }

    /// Capture two drawers, write two span rows for each under the encoder
    /// lane, and confirm both sets are present. Returns `(eraseID, keepID)`.
    private func seedTwoDrawersWithSpanRows(
        kit: GeniusLocusKit, handle: EstateHandle, vectorStore: VectorStore
    ) async throws -> (erase: String, keep: String) {
        let erase = try await kit.capture(
            handle, captureFrame(content: "erase me: span rows must not outlive the erase"))
        let keep = try await kit.capture(
            handle, captureFrame(content: "keep me: span rows must survive a sibling erase"))
        for id in [erase.id, keep.id] {
            try await vectorStore.writeSpanVectors(
                itemID: id, modelID: Self.encoderModelID, modelVersion: "v1",
                spans: spanRows(), filedAt: Self.now)
        }
        #expect(try await spanCount(vectorStore, erase.id) == 2, "seed: erase drawer carries two span rows")
        #expect(try await spanCount(vectorStore, keep.id) == 2, "seed: keep drawer carries two span rows")
        return (erase.id, keep.id)
    }

    // MARK: - L1: expunge scrubs the span rows under an encoder_models registry id

    /// Pre-fix the two span rows survived the expunge (only the distillation
    /// and corpus-model lanes were deleted). Twin of Rust
    /// `l1_expunge_scrubs_registry_encoder_lane_span_rows`.
    @Test
    func expungeScrubsRegistryEncoderLaneSpanRows() async throws {
        let (kit, handle) = try await provisionGLKEstate()
        defer { Task { try? await kit.close(handle) } }
        let vectorStore = try #require(await kit.vectorStores[handle])
        let storage = try #require(await kit.storages[handle])
        try await EncoderModelStore(storage: storage).upsert(registryRow())
        #expect(await kit.registeredSpanEncoder(for: handle) == nil,
                "L1 runs on the registry path alone")

        let ids = try await seedTwoDrawersWithSpanRows(kit: kit, handle: handle, vectorStore: vectorStore)

        let outcome = try await kit.expunge(handle, ExpungeFrame(
            rowID: ids.erase, reason: "encoder lane test", confirmation: true))
        #expect(outcome.refusedSiblingIDs.isEmpty)

        #expect(try await spanCount(vectorStore, ids.erase) == 0,
                "expunge must delete the erased drawer's span rows under the encoder lane")
        #expect(try await spanCount(vectorStore, ids.keep) == 2,
                "a sibling's span rows survive the erase")
    }

    // MARK: - L2: expunge scrubs the span rows under the registered session encoder

    /// The registry holds no row; the registered encoder's spec is the only
    /// source of the model id. Twin of Rust
    /// `l2_expunge_scrubs_registered_encoder_lane_without_registry_row`.
    @Test
    func expungeScrubsRegisteredEncoderLaneWithoutRegistryRow() async throws {
        let (kit, handle) = try await provisionGLKEstate()
        defer { Task { try? await kit.close(handle) } }
        let vectorStore = try #require(await kit.vectorStores[handle])
        let storage = try #require(await kit.storages[handle])
        await kit.registerSpanEncoder(FakeEncoder(), for: handle)
        let registryIDs = try await EncoderModelStore(storage: storage).all().map(\.modelID)
        #expect(!registryIDs.contains(Self.encoderModelID),
                "L2 precondition: the registry holds no row for the session encoder; got \(registryIDs)")

        let ids = try await seedTwoDrawersWithSpanRows(kit: kit, handle: handle, vectorStore: vectorStore)

        _ = try await kit.expunge(handle, ExpungeFrame(
            rowID: ids.erase, reason: "encoder lane test", confirmation: true))

        #expect(try await spanCount(vectorStore, ids.erase) == 0,
                "expunge must delete the span rows under the registered encoder's model id")
        #expect(try await spanCount(vectorStore, ids.keep) == 2,
                "a sibling's span rows survive the erase")
    }

    // MARK: - L3: the integrity sweep scrubs the span rows of a crash-window row

    /// Crash-window (step 1 ran, steps 2 and 3 never did) leaves the span
    /// rows in place; the sweep's re-delete must remove them. Twin of Rust
    /// `l3_sweep_scrubs_encoder_lane_span_rows`.
    @Test
    func sweepScrubsEncoderLaneSpanRows() async throws {
        let (kit, handle) = try await provisionGLKEstate()
        defer { Task { try? await kit.close(handle) } }
        let vectorStore = try #require(await kit.vectorStores[handle])
        let storage = try #require(await kit.storages[handle])
        try await EncoderModelStore(storage: storage).upsert(registryRow())

        let ids = try await seedTwoDrawersWithSpanRows(kit: kit, handle: handle, vectorStore: vectorStore)

        // Crash-window: tombstone WITHOUT sealing; step 2 never runs.
        let estate = try await kit.estate(for: handle)
        _ = try await estate.expungeReturningUnsealedEvent(
            rowID: ids.erase, reason: "crash-window-sim-l3", confirmation: true, now: Self.now)
        #expect(try await spanCount(vectorStore, ids.erase) == 2, "span rows survive the crash window")

        let result = try await kit.runExpungeIntegritySweep(handle, now: Self.now.addingTimeInterval(1))
        #expect(result.remediatedCount == 1, "sweep remediates the crash-window row; got \(result)")
        #expect(result.orphanedCount == 0, "got \(result)")
        #expect(result.perRowErrors.isEmpty, "got \(result.perRowErrors)")

        #expect(try await spanCount(vectorStore, ids.erase) == 0,
                "the sweep must delete the crash-window row's span rows under the encoder lane")
        #expect(try await spanCount(vectorStore, ids.keep) == 2,
                "a sibling's span rows survive the sweep")
    }
}
