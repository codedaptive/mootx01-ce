// LensToolsTests.swift
//
// Coverage for the reasoning-lens tool surface on ARIA_MCP
// (LENS_DISCOVERABILITY_DECISION v2.0): every cataloged lens recipe has
// a hard-bound tool, dispatched by name end-to-end against a real
// in-memory GeniusLocusKit estate (no mocks). Representative dispatch
// coverage: a graph lens (keystones / tunnel_successor), a recall lens
// (trust_grounded_synthesis), the lens-refusal face
// (partial_cue_recall with an unknown anchor), and a two-estate
// federated lens (estate_divergence via estateIDB routing).

import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit
import CognitionKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

/// `.serialized`: every dispatch case opens live in-memory estates —
/// same discipline as RecipeToolsTests.
@Suite("Lens tools", .serialized)
struct LensToolsTests {

    // MARK: - Harness

    private func openEstate(
        in kit: GeniusLocusKit, owner: OwnerCredentials
    ) async throws -> EstateHandle {
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        return try await kit.open(storage: storage, owner: owner)
    }

    private func capture(
        _ kit: GeniusLocusKit, _ handle: EstateHandle,
        content: String, room: String
    ) async throws -> String {
        let frame = CaptureFrame(
            content: content,
            channel: .typed,
            room: room,
            latticeAnchor: .udc("004"),
            addedBy: "lens-tests",
            embeddingModelID: "test-model-v1")
        return try await kit.capture(handle, frame).id
    }

    private func addTunnel(
        _ kit: GeniusLocusKit, _ handle: EstateHandle,
        wing: String, src: String, tgt: String
    ) async throws {
        let estate = try await kit.estate(for: handle)
        let frame = TunnelCaptureFrame(
            sourceWing: wing, sourceRoom: "r",
            targetWing: wing, targetRoom: "r",
            label: "relates", addedBy: "lens-tests",
            sourceDrawerId: src, targetDrawerId: tgt, kind: .references)
        _ = try await estate.capture(frame)
    }

    private func text(_ result: JSONValue) throws -> String {
        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == false)
        return try #require(
            obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
    }

    // MARK: - Projection

    @Test func everyCatalogedLensHasATool() {
        // The catalog and the tool surface stay in lockstep: every lens
        // recipe's catalog name has a moot_ tool, and no lens tool
        // exists without a catalog entry.
        let lensNames = Set(RecipeCatalog.names)
            .subtracting(["grounded_synthesis", "migration_benchmark"])
        let toolStems = Set(LensTools.lensToolNames.map { String($0.dropFirst("moot_".count)) })
        #expect(toolStems == lensNames)
    }

    // MARK: - Graph lenses

    @Test func keystonesDispatchRanksTheHub() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "ks"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        for spoke in ["s1", "s2", "s3"] {
            try await addTunnel(kit, handle, wing: "study", src: "hub", tgt: spoke)
        }

        let result = try await dispatcher.dispatch(
            name: "moot_keystones",
            arguments: .object(["wing": .string("study")]))

        let body = try text(result)
        #expect(body.contains("keystones:"))
        #expect(body.split(separator: "\n").dropFirst().first?.contains("hub") == true,
                "the hub ranks first")
    }

    @Test func tunnelSuccessorDispatchRanksByFrequency() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "ts"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        try await addTunnel(kit, handle, wing: "study", src: "anchor", tgt: "X")
        try await addTunnel(kit, handle, wing: "study", src: "anchor", tgt: "X")
        try await addTunnel(kit, handle, wing: "study", src: "anchor", tgt: "Y")

        let result = try await dispatcher.dispatch(
            name: "moot_tunnel_successor",
            arguments: .object([
                "wing": .string("study"), "anchorID": .string("anchor"),
            ]))

        let body = try text(result)
        #expect(body.contains("tunnel_successor: 2 result(s)"))
        #expect(body.contains("X weight=2"))
    }

    // MARK: - Recall lens

    @Test func trustGroundedSynthesisDispatchReturnsRanking() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "tr"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        _ = try await capture(kit, handle, content: "first memory", room: "study")
        _ = try await capture(kit, handle, content: "second memory", room: "study")

        let result = try await dispatcher.dispatch(
            name: "moot_trust_grounded_synthesis",
            arguments: .object(["filter": .string("unconfirmed")]))

        let body = try text(result)
        #expect(body.contains("trust_grounded_synthesis: 2 drawer(s)"))
        #expect(body.contains("summary:"))
    }

    // MARK: - Lens refusal face

    @Test func partialCueRecallUnknownAnchorIsToolError() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "pc"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        _ = try await capture(kit, handle, content: "only memory", room: "study")

        let result = try await dispatcher.dispatch(
            name: "moot_partial_cue_recall",
            arguments: .object(["anchorID": .string("no-such-id")]))

        // A lens-level refusal: isError true, call id preserved.
        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == true)
    }

    // MARK: - Federated lens (two estates via estateIDB)

    @Test func estateDivergenceDispatchRoutesSecondEstate() async throws {
        let kit = GeniusLocusKit()
        let handleA = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "eda"))
        let handleB = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "edb"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handleA)
            .registering(handleB)
        _ = try await capture(kit, handleA, content: "alpha", room: "philosophy")
        _ = try await capture(kit, handleB, content: "beta", room: "cooking")

        let result = try await dispatcher.dispatch(
            name: "moot_estate_divergence",
            arguments: .object([
                "estateIDB": .string(handleB.estateUUID.uuidString),
            ]))

        let body = try text(result)
        #expect(body.contains("estate_divergence:"))
        #expect(body.contains("a=1 drawer(s), b=1 drawer(s)"))
    }
}
