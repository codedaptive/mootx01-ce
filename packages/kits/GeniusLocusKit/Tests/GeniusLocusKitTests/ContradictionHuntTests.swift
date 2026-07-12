// ContradictionHuntTests.swift
//
// The contradiction hunter's core pass (Brain/ContradictionHunt.swift):
// kNN candidate mining over the estate's VectorStore, ConflictCue
// screening, proposed-tunnel emission, durable dedup against settled
// pairs, and the borderline agent-adjudication feed.

import Testing
import Foundation
import LocusKit
import VectorKit
import SubstrateTypes
import PersistenceKit
import PersistenceKitInMemory
@testable import GeniusLocusKit

@Suite("ContradictionHunt")
struct ContradictionHuntTests {

    private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private static let modelID = "minilm-v6"

    private func makeKit() async throws -> (GeniusLocusKit, EstateHandle, VectorStore) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "hunt-tests")
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)

        let vectorStorage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        try await vectorStorage.open(schema: VectorStore.schemaDeclaration)
        let vectorStore = VectorStore(storage: vectorStorage)
        await kit.registerVectorStore(vectorStore, for: handle)
        return (kit, handle, vectorStore)
    }

    private func captureFrame(content: String, room: String) -> CaptureFrame {
        CaptureFrame(
            content: content,
            channel: .typed,
            room: room,
            latticeAnchor: LatticeAnchor(udcCode: "004"),
            addedBy: "hunt-tests",
            embeddingModelID: Self.modelID
        )
    }

    /// Capture a drawer and file a vector for it. `engram` controls the
    /// kNN neighbourhood: identical engrams are distance-0 pairs.
    @discardableResult
    private func plant(
        _ content: String,
        engram: Fingerprint256,
        kit: GeniusLocusKit,
        handle: EstateHandle,
        vectorStore: VectorStore
    ) async throws -> Drawer {
        let drawer = try await kit.capture(handle, captureFrame(content: content, room: "study"))
        try await vectorStore.addVector(
            itemID: drawer.id, engram: engram, modelID: Self.modelID,
            modelVersion: "1.0", filedAt: Self.t0)
        return drawer
    }

    /// Near engram pair (distance 0) plus a far filler engram.
    private let near = Fingerprint256(block0: 0xAAAA, block1: 0xBBBB, block2: 0xCCCC, block3: 0xDDDD)
    private let far = Fingerprint256(
        block0: 0xFFFF_FFFF_FFFF_FFFF, block1: 0xFFFF_FFFF_FFFF_FFFF,
        block2: 0x1234_5678_9ABC_DEF0, block3: 0x0FED_CBA9_8765_4321)

    @Test("strong cue proposes a contradicts tunnel with proposed/derived state")
    func strongCueProposesTunnel() async throws {
        let (kit, handle, vectorStore) = try await makeKit()
        let a = try await plant(
            "the api timeout is 30 seconds",
            engram: near, kit: kit, handle: handle, vectorStore: vectorStore)
        let b = try await plant(
            "the api timeout is 90 seconds",
            engram: near, kit: kit, handle: handle, vectorStore: vectorStore)
        try await plant(
            "grocery list apples and oranges",
            engram: far, kit: kit, handle: handle, vectorStore: vectorStore)

        let report = try await kit.huntContradictions(in: handle, now: Self.t0)

        #expect(report.vectorStoreAvailable)
        #expect(report.proposed.count == 1)
        let proposal = try #require(report.proposed.first)
        #expect(proposal.cueKind == "value_divergence")
        #expect(Set([proposal.sourceDrawerID, proposal.targetDrawerID]) == Set([a.id, b.id]))

        // The tunnel persisted with the hunter's review state.
        let estate = try await kit.estate(for: handle)
        let tunnel = try #require(
            try await estate.allTunnels().first { $0.id == proposal.tunnelID })
        #expect(tunnel.kind == .contradicts)
        #expect(tunnel.lifecycle == .proposed)
        #expect(tunnel.originClass == .derived)
        #expect(tunnel.addedBy == "contradiction-hunter")
    }

    @Test("second pass deduplicates; rejection is durable")
    func dedupIsDurable() async throws {
        let (kit, handle, vectorStore) = try await makeKit()
        try await plant(
            "the api timeout is 30 seconds",
            engram: near, kit: kit, handle: handle, vectorStore: vectorStore)
        try await plant(
            "the api timeout is 90 seconds",
            engram: near, kit: kit, handle: handle, vectorStore: vectorStore)

        let first = try await kit.huntContradictions(in: handle, now: Self.t0)
        #expect(first.proposed.count == 1)

        // Re-run: the pair is settled by the existing proposed tunnel.
        let second = try await kit.huntContradictions(in: handle, now: Self.t0)
        #expect(second.proposed.isEmpty)
        #expect(second.deduplicated == 1)

        // Reject the proposal — the withdrawn tunnel still settles the pair.
        let estate = try await kit.estate(for: handle)
        try await estate.respondToTunnel(
            id: first.proposed[0].tunnelID, accept: false,
            changedBy: "hunt-tests", now: Self.t0)
        let third = try await kit.huntContradictions(in: handle, now: Self.t0)
        #expect(third.proposed.isEmpty)
        #expect(third.deduplicated == 1)
    }

    @Test("borderline cue is returned for adjudication, never persisted")
    func borderlineIsReturnedNotPersisted() async throws {
        let (kit, handle, vectorStore) = try await makeKit()
        // Negation asymmetry over a short claim: similarity lands in the
        // borderline band (see ConflictCueTests pinned vectors).
        try await plant(
            "Bob lives in Paris",
            engram: near, kit: kit, handle: handle, vectorStore: vectorStore)
        try await plant(
            "Bob does not live in Paris",
            engram: near, kit: kit, handle: handle, vectorStore: vectorStore)

        let report = try await kit.huntContradictions(in: handle, now: Self.t0)

        #expect(report.proposed.isEmpty)
        #expect(report.borderline.count == 1)
        let candidate = try #require(report.borderline.first)
        #expect(candidate.cueKind == "negation_asymmetry")
        #expect(!candidate.sourceSnippet.isEmpty)

        // Nothing persisted for borderline findings.
        let estate = try await kit.estate(for: handle)
        let contradicts = try await estate.allTunnels().filter { $0.kind == .contradicts }
        #expect(contradicts.isEmpty)
    }

    @Test("unrelated content proposes nothing; missing vector store is reported")
    func guards() async throws {
        let (kit, handle, vectorStore) = try await makeKit()
        try await plant(
            "the deploy pipeline is green",
            engram: near, kit: kit, handle: handle, vectorStore: vectorStore)
        try await plant(
            "quarterly budget review notes",
            engram: near, kit: kit, handle: handle, vectorStore: vectorStore)

        let report = try await kit.huntContradictions(in: handle, now: Self.t0)
        #expect(report.proposed.isEmpty)
        #expect(report.borderline.isEmpty)
        #expect(report.pairsScreened == 1)

        // A kit with no registered VectorStore reports the gap honestly.
        let bare = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "hunt-tests-bare")
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let bareHandle = try await bare.open(storage: storage, owner: owner)
        let bareReport = try await bare.huntContradictions(in: bareHandle, now: Self.t0)
        #expect(!bareReport.vectorStoreAvailable)
    }

    @Test("watermark skips pairs where both sides predate filedAfter")
    func watermarkSkipsOldPairs() async throws {
        let (kit, handle, vectorStore) = try await makeKit()
        try await plant(
            "the api timeout is 30 seconds",
            engram: near, kit: kit, handle: handle, vectorStore: vectorStore)
        try await plant(
            "the api timeout is 90 seconds",
            engram: near, kit: kit, handle: handle, vectorStore: vectorStore)

        // Watermark in the future of both captures: nothing is new enough.
        let report = try await kit.huntContradictions(
            in: handle,
            filedAfter: Date(timeIntervalSinceNow: 3600),
            now: Self.t0)
        #expect(report.proposed.isEmpty)
        #expect(report.pairsScreened == 0)
    }
}
