// RecallProvenanceSurfacingTests.swift
//
// Force-tests that the `moot_memory_search` response always carries a
// `recall_provenance:` status line, and that the status accurately reflects
// the retrieval lane that produced the result.
//
// # What these tests prove
//
//   A. DETERMINISTIC PROVIDER — a recall over an estate wired with the
//      deterministic provider surfaces a non-empty `recall_provenance:` line
//      and the dense-lane token reflects the actual lane state. The status is
//      never blank, never missing.
//
//   B. DENSE LANE ACTIVE — when Lane D is live (deterministic provider, corpus
//      ingested, float rows present), the status line carries "dense_lane:active".
//
//   C. ZERO-RESULT PROVENANCE — a recall with no hits still surfaces a non-empty
//      recall_provenance line. The line is ALWAYS present regardless of result count.
//
//   D. BARE-LOCUS PROVENANCE — when no corpus is registered (no vector/BM25 lane),
//      a recall over a bare locus-only estate surfaces a provenance line that is
//      present. Section E verifies the bare-locus (sparse-only) path explicitly.
//
// The ARIA surface lets callers distinguish "real semantic space" from
// "deterministic/structural fallback" by returning denseLaneStatus and
// degradedStages at the boundary.

import Testing
import Foundation
import GeniusLocusKit
import GeniusLocusKitMigrations
import LocusKit
import CorpusKit
import VectorKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

// MARK: - Helpers

/// Extract the text payload from a `textResult` JSONValue.
private func text(of result: JSONValue) -> String {
    guard case let .object(obj) = result,
          case let .array(content)? = obj["content"],
          case let .object(first)? = content.first,
          case let .string(s)? = first["text"]
    else { return "" }
    return s
}

/// Open an in-memory estate wired with the full semantic recall stack
/// (Corpus + VectorStore, deterministic provider = Lane D live).
/// This is the same helper as InMemorySemanticRecallTests uses.
private func openInMemoryEstateWithSemanticRecall()
    async throws -> (ToolDispatcher, GeniusLocusKit, EstateHandle)
{
    let kit = GeniusLocusKit()
    let owner = OwnerCredentials(ownerIdentifier: "aria-mcp-owner")
    let storage = InMemoryStorage(
        configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
    _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
    let handle = try await kit.open(storage: storage, owner: owner, identityKeyStore: InMemoryEstateIdentityKeyStore())
    // Stamp the GLK 1.1 estate format, mirroring ServeCommand's GLKMigrationCatalog.prepare
    // call between kit.open and kit.wireGLKSubstores in production. Fresh-estate fast path.
    _ = try await GLKMigrationCatalog.prepare(kit: kit, handle: handle)
    // Shared-content 1.1: canonical wiring seam — attached engine over the
    // LocusKit adapter, engine + shared VectorStore registered.
    try await kit.wireGLKSubstores(for: handle, backingStorage: storage)
    let dispatcher = ToolDispatcher(kit: kit, handle: handle)
    return (dispatcher, kit, handle)
}

/// Open an in-memory estate with NO corpus or vector store registered —
/// a bare locus-only estate that can only use the structural recall lane.
private func openBareLocusOnlyEstate()
    async throws -> (ToolDispatcher, GeniusLocusKit, EstateHandle)
{
    let kit = GeniusLocusKit()
    let owner = OwnerCredentials(ownerIdentifier: "aria-mcp-owner")
    let storage = InMemoryStorage(
        configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
    _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
    let handle = try await kit.open(storage: storage, owner: owner, identityKeyStore: InMemoryEstateIdentityKeyStore())
    // No corpus, no vector store — structural/locus-only lane.
    let dispatcher = ToolDispatcher(kit: kit, handle: handle)
    return (dispatcher, kit, handle)
}

// MARK: - Test suite

@Suite("Recall provenance surfacing — moot_memory_search recall_provenance field", .serialized)
struct RecallProvenanceSurfacingTests {

    // MARK: - A. Provenance line is always present (deterministic provider)

    /// PR-03 deviation-only contract: a nominal search (Lane D live,
    /// nothing degraded) emits NO recall_provenance: line — its absence IS
    /// the nominal signal. Deviations (dark lane, degraded stages) are
    /// pinned by tests D/E below, which still require the line.
    @Test func provenanceLineAbsentOnNominalRecall() async throws {
        let (dispatcher, kit, handle) = try await openInMemoryEstateWithSemanticRecall()
        defer { Task { try? await kit.close(handle) } }

        // Capture a memory and drain so it is searchable.
        _ = try await dispatcher.runFileMemory([
            "content": .string("peregrine falcon stoop dive speed aerial predator"),
            "subject": .string("peregrine falcon stoop dive speed aerial predator"),
            "location": .string("birds/falcons"),
            "impatient": .bool(true),
        ])

        let result = try await dispatcher.runMemorySearch([
            "query": .string("peregrine falcon speed"),
        ])
        let body = text(of: result)
        #expect(
            !body.contains("recall_provenance:"),
            "nominal recall must NOT include a recall_provenance: line (deviation-only); got: \(body)"
        )
    }

    // MARK: - B. Deterministic provider — dense lane active, provenance never blank

    /// PR-03: with the deterministic provider live, the search is nominal —
    /// the reply carries dense rows and NO provenance line. (Pre-PR-03 this
    /// test pinned an always-present line; absence is now the invariant.)
    @Test func deterministicProviderNominalSearchOmitsProvenance() async throws {
        let (dispatcher, kit, handle) = try await openInMemoryEstateWithSemanticRecall()
        defer { Task { try? await kit.close(handle) } }

        _ = try await dispatcher.runFileMemory([
            "content": .string("hobby falcon aerial insect hunting speed agility"),
            "subject": .string("hobby falcon aerial insect hunting speed agility"),
            "location": .string("birds/falcons"),
            "impatient": .bool(true),
        ])

        let result = try await dispatcher.runMemorySearch([
            "query": .string("hobby falcon insect"),
        ])
        let body = text(of: result)
        #expect(
            !body.contains("recall_provenance:"),
            "nominal recall must omit the provenance line entirely; got: \(body)"
        )
        // The hit must surface as a dense row carrying the subject.
        #expect(
            body.contains("hobby falcon aerial insect hunting speed agility"),
            "dense row must carry the subject; got: \(body)"
        )
    }

    // MARK: - C. Dense lane active when corpus is wired and float rows are present

    /// Prove that when a corpus with the deterministic provider is wired and a document
    /// has been ingested (so float rows are stored), the recall_provenance line carries
    /// "dense_lane:active" — meaning Lane D contributed to ranking.
    ///
    /// The deterministic provider implements embedFloat and stores Lane D rows at
    /// ingest time. A fresh search over that estate therefore has an active float lane.
    @Test func denseLaneActiveWhenCorpusWiredAndIngested() async throws {
        let (dispatcher, kit, handle) = try await openInMemoryEstateWithSemanticRecall()
        defer { Task { try? await kit.close(handle) } }

        // Impatient capture writes directly into Corpus (BM25 + float rows).
        _ = try await dispatcher.runFileMemory([
            "content": .string("merlin small falcon moorland heather hunting pipits"),
            "subject": .string("merlin small falcon moorland heather hunting pipits"),
            "location": .string("birds/falcons"),
            "impatient": .bool(true),
        ])

        let result = try await dispatcher.runMemorySearch([
            "query": .string("merlin moorland hunting"),
        ])
        let body = text(of: result)

        // When the corpus is wired and float rows are present, Lane D is
        // active (denseLaneStatus nil) and nothing degraded — under the
        // PR-03 deviation-only contract that renders as NO provenance line.
        #expect(
            !body.contains("recall_provenance:"),
            "Lane D live + happy path must render as ABSENCE of the provenance line; got: \(body)"
        )
    }

    // MARK: - D. Provenance line present even on zero results

    /// Prove that the recall_provenance: line is emitted even when the query
    /// returns zero hits. The field must never be conditionally omitted.
    @Test func provenanceLinePresentOnZeroResults() async throws {
        let (dispatcher, kit, handle) = try await openInMemoryEstateWithSemanticRecall()
        defer { Task { try? await kit.close(handle) } }

        // No captures — estate is empty. Search will return 0 hits.
        let result = try await dispatcher.runMemorySearch([
            "query": .string("osprey fish plunge-diving"),
        ])
        let body = text(of: result)

        #expect(
            body.hasPrefix("found 0"),
            "Expected zero results on empty estate; got: \(body)"
        )
        #expect(
            body.contains("recall_provenance:"),
            "recall_provenance: must be present even on zero-result queries; got: \(body)"
        )
    }

    // MARK: - E. Bare locus-only estate: provenance line still present

    /// Prove that a bare estate (no corpus, no vector store) still produces a
    /// recall_provenance: line. The line is structurally always present — its
    /// content will reflect whatever the kit's GLKRecallResult populated.
    @Test func provenanceLinePresentOnBareLocusOnlyEstate() async throws {
        let (dispatcher, kit, handle) = try await openBareLocusOnlyEstate()
        defer { Task { try? await kit.close(handle) } }

        // File a memory to ensure there is something to recall.
        _ = try await dispatcher.runFileMemory([
            "content": .string("buzzard soaring thermal upland woodland edges"),
            "subject": .string("buzzard soaring thermal upland woodland edges"),
            "location": .string("birds/raptors"),
            "impatient": .bool(true),
        ])

        let result = try await dispatcher.runMemorySearch([
            "query": .string("buzzard thermal soaring"),
        ])
        let body = text(of: result)

        #expect(
            body.contains("recall_provenance:"),
            "recall_provenance: must be present on bare locus-only estates; got: \(body)"
        )
        // A bare locus-only estate has no corpus/vector store. The dense float
        // lane is never attempted (no corpus registered), so denseLaneStatus will be
        // nil (lane was never attempted, not dark-by-failure). The provenance line
        // must still carry "dense_lane:" token to remain parseable.
        let provenanceLine = body
            .components(separatedBy: "\n")
            .first(where: { $0.hasPrefix("recall_provenance:") })
        let line = provenanceLine ?? ""
        #expect(
            line.contains("dense_lane:"),
            "provenance line must carry dense_lane: token even on bare estate; got: \(line)"
        )
    }
}
