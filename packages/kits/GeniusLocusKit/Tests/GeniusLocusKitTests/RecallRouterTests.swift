// RecallRouterTests.swift
//
// Two gates for the recall router (RecallRouter.swift), driven from the shared
// fixture at Tests/Fixtures/recall_router_vectors.json:
//
//   router-on   — preference on, dialogue question: route fires, result.route
//                 is "cross_encoder_routing" and the cross-encoder stage ran
//                 (result.crossEncoder is non-nil, degraded because no scorer
//                 is registered in this in-memory test estate).
//   router-off  — preference off, same question: route does not fire,
//                 result.route is nil and result.crossEncoder is nil.

import Foundation
import Testing
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import GeniusLocusKit

// MARK: - Fixture

private struct RouterVectors: Decodable {
    let dialogue: String
    let prose: String
}

/// packages/kits/GeniusLocusKit/Tests/GeniusLocusKitTests/<file> →
/// packages/kits/GeniusLocusKit/Tests/Fixtures/ (two components up from file).
private func fixtureURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // GeniusLocusKitTests/
        .deletingLastPathComponent()   // Tests/
        .appendingPathComponent("Fixtures/recall_router_vectors.json")
}

private func loadVectors() throws -> RouterVectors {
    let data = try Data(contentsOf: fixtureURL())
    return try JSONDecoder().decode(RouterVectors.self, from: data)
}

// MARK: - Helpers

private func openEstate(owner ownerID: String) async throws
    -> (kit: GeniusLocusKit, handle: EstateHandle) {
    let kit = GeniusLocusKit()
    let owner = OwnerCredentials(ownerIdentifier: ownerID)
    let storage = InMemoryStorage(
        configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
    _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
    let handle = try await kit.open(storage: storage, owner: owner)
    return (kit: kit, handle: handle)
}

/// A minimal GLKRecallRequest carrying `queryText`. Uses locusOnly so no corpus
/// is needed; origin is .internal so no trace writes occur.
private func request(queryText: String) -> GLKRecallRequest {
    GLKRecallRequest(
        frame: RecallFrame(filterChain: [], hydrationLevel: .full, ordering: .byCaptureTimeDesc),
        mode: .locusOnly, scoring: .raw, limit: 20,
        fallback: .failClosed, queryText: queryText, origin: .internal)
}

// MARK: - Tests

@Suite("Recall router gates")
struct RecallRouterTests {
    /// Gate: preference on + dialogue query → route fires.
    ///
    /// The cross-encoder stage degrades because no pair scorer is registered in
    /// this in-memory estate, but a degraded report is non-nil — the stage ran
    /// and applied the directive. The route key in the result is the proof that
    /// the router transformed the request.
    @Test("router-on: dialogue query with default preference fires route 1")
    func routerOn() async throws {
        let vectors = try loadVectors()
        let (kit, handle) = try await openEstate(owner: "router-on-\(UUID())")
        defer { Task { try? await kit.close(handle) } }

        let result = try await kit.recall(handle, request(queryText: vectors.dialogue))

        // Route 1 fired: preference key carried in the result.
        #expect(result.route == "cross_encoder_routing")
        // The cross-encoder stage ran (degraded — no scorer registered — but ran).
        #expect(result.crossEncoder != nil)
        // The routed directive is the degradable `apply`, never the transcript
        // operation's fail-closed `.strictTranscript()`: a routed ordinary
        // question must keep its lane order when the stage cannot run, so no
        // strict-transcript evidence is produced for it.
        #expect(result.strictTranscriptRerank == nil)
    }

    /// Gate: preference off + dialogue query → route does not fire.
    ///
    /// "Off means off": the router returns the original request unchanged, the
    /// directive is nil, the cross-encoder stage is skipped, and the result
    /// carries no route or cross-encoder report.
    @Test("router-off: same query with preference off produces no route")
    func routerOff() async throws {
        let vectors = try loadVectors()
        let (kit, handle) = try await openEstate(owner: "router-off-\(UUID())")
        defer { Task { try? await kit.close(handle) } }

        // Write the "off" preference directly to the estate manifest.
        let estate = try await kit.estate(for: handle)
        try await estate.setMeta(
            key: GeniusLocusKit.crossEncoderRoutingMetaKey, value: "off")

        let result = try await kit.recall(handle, request(queryText: vectors.dialogue))

        // Route suppressed by preference.
        #expect(result.route == nil)
        // No directive → no cross-encoder stage.
        #expect(result.crossEncoder == nil)
    }
}
