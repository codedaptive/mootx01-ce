// FactSourceSensitivityTests.swift
//
// A KG fact is exactly as sensitive as the drawer it was drawn from.
// `captureKGFact` copies the source drawer's adjective and provenance
// bitmaps onto the fact, so the fact-search disclosure ceiling — which
// already drops Restricted/Secret rows — withholds derived facts without
// needing to join back to the drawer at read time.
//
// These tests fail against pre-MXE-KH code, where every fact filed through
// `moot_file_fact` carried the zero bitmap (sensitivity Normal) regardless
// of its source, so a fact extracted from a Secret drawer was returned in
// full by `moot_fact_search`.

import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

private func openEstateForSensitivity()
    async throws -> (ToolDispatcher, GeniusLocusKit, EstateHandle)
{
    let kit = GeniusLocusKit()
    let owner = OwnerCredentials(ownerIdentifier: "fact-source-sensitivity-tests")
    let storage = InMemoryStorage(
        configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
    _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
    let handle = try await kit.open(
        storage: storage, owner: owner,
        identityKeyStore: InMemoryEstateIdentityKeyStore())
    let dispatcher = ToolDispatcher(kit: kit, handle: handle, serverIdentity: "mootx01")
    return (dispatcher, kit, handle)
}

private func captureSource(
    _ kit: GeniusLocusKit, _ handle: EstateHandle,
    sensitivity: AdjectiveSensitivity
) async throws -> Drawer {
    let estate = try await kit.estate(for: handle)
    return try await estate.capture(CaptureFrame(
        content: "source drawer at \(sensitivity)",
        channel: .typed,
        room: "fact-source-sensitivity",
        latticeAnchor: .udc("004"),
        addedBy: "fact-source-sensitivity-tests",
        embeddingModelID: "test-model-v1",
        sensitivity: sensitivity))
}

private func factRows(
    _ dispatcher: ToolDispatcher, query: String
) async throws -> [[String: JSONValue]] {
    let result = try await dispatcher.dispatch(
        name: "moot_fact_search", arguments: .object(["query": .string(query)]))
    return result.objectValue?["structuredContent"]?.objectValue?["data"]?
        .objectValue?["facts"]?.arrayValue?.compactMap(\.objectValue) ?? []
}

private func fileFact(
    _ dispatcher: ToolDispatcher, _ arguments: [String: JSONValue]
) async throws -> JSONValue {
    try await dispatcher.dispatch(name: "moot_file_fact", arguments: .object(arguments))
}

@Suite("KG facts inherit their source drawer's sensitivity", .serialized)
struct FactSourceSensitivityTests {

    /// A fact filed from a Secret source drawer must not be returned by
    /// `moot_fact_search`. The read-side ceiling drops it because the fact
    /// itself is Secret, not because the tool inspects the source drawer.
    @Test func secretSourceWithholdsDerivedFact() async throws {
        let (dispatcher, kit, handle) = try await openEstateForSensitivity()
        defer { Task { try? await kit.close(handle) } }
        let source = try await captureSource(kit, handle, sensitivity: .secret)

        let filed = try await fileFact(dispatcher, [
            "subject": .string("Ceres"),
            "predicate": .string("classified_as"),
            "object": .string("dwarf planet"),
            "source_memory_id": .string(source.id),
        ])
        #expect(filed.objectValue?["isError"] == .bool(true),
                "v2 must refuse a Secret source at the public door; got: \(filed)")

        // The search header echoes the query verbatim, so the fact row itself
        // is what must be absent — match on the predicate, which appears only
        // in a rendered row.
        let rows = try await factRows(dispatcher, query: "Ceres")
        #expect(!rows.contains { $0["predicate"] == .string("classified_as") },
                "a fact drawn from a Secret drawer must be withheld; got: \(rows)")
        #expect(!rows.contains { $0["source_memory_id"] == .string(source.id) },
                "the Secret source drawer id must not leak; got: \(rows)")
    }

    /// Same rule one tier down: Restricted is also outside the default
    /// disclosure ceiling.
    @Test func restrictedSourceWithholdsDerivedFact() async throws {
        let (dispatcher, kit, handle) = try await openEstateForSensitivity()
        defer { Task { try? await kit.close(handle) } }
        let source = try await captureSource(kit, handle, sensitivity: .restricted)

        let filed = try await fileFact(dispatcher, [
            "subject": .string("Vesta"),
            "predicate": .string("classified_as"),
            "object": .string("asteroid"),
            "source_memory_id": .string(source.id),
        ])
        #expect(filed.objectValue?["isError"] == .bool(true),
                "v2 must refuse a Restricted source at the public door; got: \(filed)")

        let rows = try await factRows(dispatcher, query: "Vesta")
        #expect(!rows.contains { $0["predicate"] == .string("classified_as") },
                "a fact drawn from a Restricted drawer must be withheld; got: \(rows)")
    }

    /// Inheritance must not over-withhold: Normal and Elevated sources are
    /// inside the ceiling and their derived facts still surface.
    @Test func normalAndElevatedSourcesStillSurface() async throws {
        let (dispatcher, kit, handle) = try await openEstateForSensitivity()
        defer { Task { try? await kit.close(handle) } }
        let normal = try await captureSource(kit, handle, sensitivity: .normal)
        let elevated = try await captureSource(kit, handle, sensitivity: .elevated)

        _ = try await fileFact(dispatcher, [
            "subject": .string("Pallas"),
            "predicate": .string("classified_as"),
            "object": .string("asteroid"),
            "source_memory_id": .string(normal.id),
        ])
        _ = try await fileFact(dispatcher, [
            "subject": .string("Juno"),
            "predicate": .string("classified_as"),
            "object": .string("asteroid"),
            "source_memory_id": .string(elevated.id),
        ])

        // Match on the rendered row (predicate + source anchor), not on the
        // query term, which the header echoes whether or not a row matched.
        let normalRows = try await factRows(dispatcher, query: "Pallas")
        #expect(normalRows.contains { $0["predicate"] == .string("classified_as") && $0["source_memory_id"] == .string(UUID(uuidString: normal.id)!.uuidString.lowercased()) },
                "a Normal-source fact must still surface; got: \(normalRows)")
        let elevatedRows = try await factRows(dispatcher, query: "Juno")
        #expect(elevatedRows.contains { $0["predicate"] == .string("classified_as") && $0["source_memory_id"] == .string(UUID(uuidString: elevated.id)!.uuidString.lowercased()) },
                "an Elevated-source fact must still surface; got: \(elevatedRows)")
    }

    /// A fact filed with no source_memory_id is sourceless: it keeps the zero-bitmap
    /// defaults, renders an empty source=, and surfaces normally.
    @Test func sourcelessFactFilesWithDefaults() async throws {
        let (dispatcher, kit, handle) = try await openEstateForSensitivity()
        defer { Task { try? await kit.close(handle) } }

        _ = try await fileFact(dispatcher, [
            "subject": .string("Eris"),
            "predicate": .string("classified_as"),
            "object": .string("dwarf planet"),
        ])

        let facts = try await kit.recallKGFacts(handle)
        let filed = try #require(facts.first { $0.subject == "Eris" })
        #expect(filed.sourceDrawerID == "",
                "a sourceless fact must carry an empty sourceDrawerID")
        #expect(filed.adjectiveBitmap == 0,
                "a sourceless fact keeps the zero-bitmap default")
        #expect(filed.provenanceBitmap == 0,
                "a sourceless fact keeps the zero-bitmap default")
        #expect(filed.addedBy == "mootx01",
                "the filing host identity is recorded in addedBy")

        let rows = try await factRows(dispatcher, query: "Eris")
        #expect(rows.contains { $0["predicate"] == .string("classified_as") },
                "a sourceless fact must surface; got: \(rows)")
    }

    /// The selected-v2 door must reject a Restricted source before filing a
    /// fact, rather than allowing a high-sensitivity anchor to escape through
    /// a lower-sensitivity fact row.
    @Test func restrictedSourceIsRefusedBeforeFactIsFiled() async throws {
        let (dispatcher, kit, handle) = try await openEstateForSensitivity()
        defer { Task { try? await kit.close(handle) } }
        let source = try await captureSource(kit, handle, sensitivity: .restricted)

        let result = try await fileFact(dispatcher, [
            "subject": .string("Hygiea"),
            "predicate": .string("classified_as"),
            "object": .string("asteroid"),
            "source_memory_id": .string(source.id),
        ])

        #expect(result.objectValue?["isError"] == .bool(true),
                "restricted source must be refused by selected-v2; got: \(result)")
        let facts = try await kit.recallKGFacts(handle)
        #expect(!facts.contains { $0.subject == "Hygiea" },
                "a refused v2 filing must not create a fact")
    }
}
