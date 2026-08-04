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

private func factSearchText(
    _ dispatcher: ToolDispatcher, query: String
) async throws -> String {
    let result = try await dispatcher.runFactSearch(["query": .string(query)])
    return result.objectValue?["content"]?.arrayValue?.first?
        .objectValue?["text"]?.stringValue ?? ""
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

        _ = try await dispatcher.runFileFact([
            "subject": .string("Ceres"),
            "predicate": .string("classified_as"),
            "object": .string("dwarf planet"),
            "source_id": .string(source.id),
        ], now: Date())

        // The search header echoes the query verbatim, so the fact row itself
        // is what must be absent — match on the predicate, which appears only
        // in a rendered row.
        let body = try await factSearchText(dispatcher, query: "Ceres")
        #expect(!body.contains("classified_as"),
                "a fact drawn from a Secret drawer must be withheld; got: \(body)")
        #expect(!body.contains(source.id),
                "the Secret source drawer id must not leak; got: \(body)")
    }

    /// Same rule one tier down: Restricted is also outside the default
    /// disclosure ceiling.
    @Test func restrictedSourceWithholdsDerivedFact() async throws {
        let (dispatcher, kit, handle) = try await openEstateForSensitivity()
        defer { Task { try? await kit.close(handle) } }
        let source = try await captureSource(kit, handle, sensitivity: .restricted)

        _ = try await dispatcher.runFileFact([
            "subject": .string("Vesta"),
            "predicate": .string("classified_as"),
            "object": .string("asteroid"),
            "source_id": .string(source.id),
        ], now: Date())

        let body = try await factSearchText(dispatcher, query: "Vesta")
        #expect(!body.contains("classified_as"),
                "a fact drawn from a Restricted drawer must be withheld; got: \(body)")
    }

    /// Inheritance must not over-withhold: Normal and Elevated sources are
    /// inside the ceiling and their derived facts still surface.
    @Test func normalAndElevatedSourcesStillSurface() async throws {
        let (dispatcher, kit, handle) = try await openEstateForSensitivity()
        defer { Task { try? await kit.close(handle) } }
        let normal = try await captureSource(kit, handle, sensitivity: .normal)
        let elevated = try await captureSource(kit, handle, sensitivity: .elevated)

        _ = try await dispatcher.runFileFact([
            "subject": .string("Pallas"),
            "predicate": .string("classified_as"),
            "object": .string("asteroid"),
            "source_id": .string(normal.id),
        ], now: Date())
        _ = try await dispatcher.runFileFact([
            "subject": .string("Juno"),
            "predicate": .string("classified_as"),
            "object": .string("asteroid"),
            "source_id": .string(elevated.id),
        ], now: Date())

        // Match on the rendered row (predicate + source anchor), not on the
        // query term, which the header echoes whether or not a row matched.
        let normalBody = try await factSearchText(dispatcher, query: "Pallas")
        #expect(normalBody.contains("classified_as") && normalBody.contains(normal.id),
                "a Normal-source fact must still surface; got: \(normalBody)")
        let elevatedBody = try await factSearchText(dispatcher, query: "Juno")
        #expect(elevatedBody.contains("classified_as") && elevatedBody.contains(elevated.id),
                "an Elevated-source fact must still surface; got: \(elevatedBody)")
    }

    /// A fact filed with no source_id is sourceless: it keeps the zero-bitmap
    /// defaults, renders an empty source=, and surfaces normally.
    @Test func sourcelessFactFilesWithDefaults() async throws {
        let (dispatcher, kit, handle) = try await openEstateForSensitivity()
        defer { Task { try? await kit.close(handle) } }

        _ = try await dispatcher.runFileFact([
            "subject": .string("Eris"),
            "predicate": .string("classified_as"),
            "object": .string("dwarf planet"),
        ], now: Date())

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

        let body = try await factSearchText(dispatcher, query: "Eris")
        #expect(body.contains("classified_as"),
                "a sourceless fact must surface; got: \(body)")
    }

    /// The inheritance is literal: the filed fact's bitmaps equal the source
    /// drawer's, asserted field-for-field rather than inferred from
    /// disclosure behaviour.
    @Test func filedBitmapsEqualTheSourceDrawers() async throws {
        let (dispatcher, kit, handle) = try await openEstateForSensitivity()
        defer { Task { try? await kit.close(handle) } }
        let source = try await captureSource(kit, handle, sensitivity: .restricted)

        _ = try await dispatcher.runFileFact([
            "subject": .string("Hygiea"),
            "predicate": .string("classified_as"),
            "object": .string("asteroid"),
            "source_id": .string(source.id),
        ], now: Date())

        // recallKGFacts returns the unfiltered set — the disclosure ceiling is
        // applied at the ARIA tool boundary, not here — so the Restricted fact
        // is visible for direct inspection.
        let facts = try await kit.recallKGFacts(handle)
        let filed = try #require(facts.first { $0.subject == "Hygiea" })
        #expect(filed.adjectiveBitmap == source.adjectiveBitmap,
                "adjective bitmap must be carried verbatim from the source drawer")
        #expect(filed.provenanceBitmap == source.provenance,
                "provenance bitmap must be carried verbatim from the source drawer")
        #expect(filed.adjectiveSensitivity == .restricted,
                "the inherited sensitivity must decode back to the source's tier")
        #expect(filed.sourceDrawerID == source.id,
                "an anchored fact records the local drawer id it came from")
    }
}
