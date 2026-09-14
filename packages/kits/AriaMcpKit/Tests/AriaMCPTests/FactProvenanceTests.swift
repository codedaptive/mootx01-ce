// FactProvenanceTests.swift
//
// Tests for two fact-surface fixes:
//
//   Bug C — Host identity injected into ToolDispatcher so rows filed via
//            `moot_file_fact` record which binary hosted the dispatcher
//            (aria-mcp-server, mootx01, etc.). The identity lands in the
//            fact's `addedBy` field and renders as `addedBy=`; `sourceDrawerID`
//            holds a local drawer id or nothing and never a host name.
//
//   Bug D — `moot_fact_search` runs a dark-lane probe when a query is supplied.
//            The probe result is log-side only (recall_provenance removed from
//            payload per COMPOSER-02B). Fact search is purely lexical and
//            returns results regardless of dense-lane availability.

import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

// ---------------------------------------------------------------------------
// MARK: - Shared helpers
// ---------------------------------------------------------------------------

/// Extract the text payload from a `textResult` JSONValue.
private func factText(of result: JSONValue) -> String {
    guard case let .object(obj) = result,
          case let .array(content)? = obj["content"],
          case let .object(first)? = content.first,
          case let .string(s)? = first["text"]
    else { return "" }
    return s
}

/// Exercise the public selected-v2 door, not an internal helper.
private func fileFact(
    _ dispatcher: ToolDispatcher, _ arguments: [String: JSONValue]
) async throws -> JSONValue {
    try await dispatcher.dispatch(name: "moot_file_fact", arguments: .object(arguments))
}

private func searchFacts(
    _ dispatcher: ToolDispatcher, _ arguments: [String: JSONValue]
) async throws -> JSONValue {
    try await dispatcher.dispatch(name: "moot_fact_search", arguments: .object(arguments))
}

private func factRows(_ result: JSONValue) -> [[String: JSONValue]] {
    result.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue?["facts"]?
        .arrayValue?.compactMap(\.objectValue) ?? []
}

/// Open a bare in-memory estate (no corpus, no vector store).
/// The dense lane is dark — this is the default mootx01 serve state when
/// no semantic wiring has been applied to the estate.
private func openBareEstate(identity: String = "aria-mcp-server")
    async throws -> (ToolDispatcher, GeniusLocusKit, EstateHandle)
{
    let kit = GeniusLocusKit()
    let owner = OwnerCredentials(ownerIdentifier: "fact-provenance-tests")
    let storage = InMemoryStorage(
        configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
    _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
    let handle = try await kit.open(storage: storage, owner: owner, identityKeyStore: InMemoryEstateIdentityKeyStore())
    // No corpus or vector store registered — dense lane dark.
    let dispatcher = ToolDispatcher(kit: kit, handle: handle, serverIdentity: identity)
    return (dispatcher, kit, handle)
}

// ---------------------------------------------------------------------------
// MARK: - Bug C: Host identity stamped on facts
// ---------------------------------------------------------------------------

@Suite("Bug C — Fact provenance identity injection", .serialized)
struct FactProvenanceIdentityTests {

    /// A dispatcher constructed with identity "mootx01" must stamp facts
    /// filed via moot_file_fact with addedBy="mootx01". With no explicit
    /// source_memory_id the fact is sourceless, so the source column is absent.
    ///
    /// Note: the S4 fact row (COMPOSER-02B §11.7) does not surface `addedBy`
    /// at the MCP layer — the field is stored in LocusKit's KGFact row and
    /// is verifiable at the storage layer, but it is not a rendered column.
    /// This test verifies: the fact is filed and retrievable, and the host
    /// identity does NOT appear as a source drawer ID in the row.
    @Test func factFiledWithMootx01IdentityGetsMootx01AddedBy() async throws {
        let (dispatcher, kit, handle) = try await openBareEstate(identity: "mootx01")
        defer { Task { try? await kit.close(handle) } }

        let fileResult = try await fileFact(dispatcher, [
            "subject": .string("Paris"),
            "predicate": .string("is_capital_of"),
            "object": .string("France"),
        ])
        let body = factText(of: fileResult)
        #expect(!body.isEmpty, "v2 file_fact must succeed; got: \(body)")

        // Retrieve the fact and verify it is in the S4 surface.
        let searchResult = try await searchFacts(dispatcher, ["query": .string("Paris")])
        let rows = factRows(searchResult)
        #expect(
            rows.contains { $0["subject"] == .string("Paris") },
            "fact filed via 'mootx01' identity must be retrievable; got: \(rows)"
        )
        // The host identity is never a source drawer ID; the sourceless fact
        // renders '-' in the source column. Verify identity contamination is absent.
        #expect(
            !rows.contains { $0["source_memory_id"] == .string("mootx01") },
            "host identity must not appear as a source memory id; got: \(rows)"
        )
    }

    /// A dispatcher constructed with identity "aria-mcp-server" must file facts
    /// that are retrievable via moot_fact_search. The S4 row (COMPOSER-02B §11.7)
    /// does not surface `addedBy` at the MCP layer (stored in LocusKit's KGFact
    /// row; not a rendered column). This test verifies the fact is filed and
    /// the identity does not contaminate the source column.
    @Test func factFiledWithAriaMcpIdentityGetsAriaMcpAddedBy() async throws {
        let (dispatcher, kit, handle) = try await openBareEstate(identity: "aria-mcp-server")
        defer { Task { try? await kit.close(handle) } }

        _ = try await fileFact(dispatcher, [
            "subject": .string("Berlin"),
            "predicate": .string("is_capital_of"),
            "object": .string("Germany"),
        ])

        let searchResult = try await searchFacts(dispatcher, ["query": .string("Berlin")])
        let rows = factRows(searchResult)
        #expect(
            rows.contains { $0["subject"] == .string("Berlin") },
            "fact filed via identity 'aria-mcp-server' must be retrievable; got: \(rows)"
        )
        // Host identity must not appear as a source drawer ID.
        #expect(
            !rows.contains { $0["source_memory_id"] == .string("aria-mcp-server") },
            "host identity must not appear as a source memory id; got: \(rows)"
        )
    }

    /// An explicit source_memory_id must name a drawer that exists in this estate.
    /// A fact inherits its source drawer's sensitivity, so an anchor that
    /// resolves to nothing is rejected rather than filed at the Normal
    /// default — filing it would disclose at a tier no drawer authorised.
    @Test func explicitSourceIdNamingNoDrawerFailsTheWrite() async throws {
        let (dispatcher, kit, handle) = try await openBareEstate(identity: "mootx01")
        defer { Task { try? await kit.close(handle) } }

        await #expect(throws: JSONRPCError.self) {
            _ = try await fileFact(dispatcher, [
                "subject": .string("Tokyo"),
                "predicate": .string("is_capital_of"),
                "object": .string("Japan"),
                "source_memory_id": .string("external-agent"),
            ])
        }

        // Nothing was filed, so the fact surface stays empty.
        let searchResult = try await searchFacts(dispatcher, ["query": .string("Tokyo")])
        let rows = factRows(searchResult)
        #expect(
            !rows.contains { $0["predicate"] == .string("is_capital_of") },
            "a rejected write must leave no fact behind; got: \(rows)"
        )
    }
}

// ---------------------------------------------------------------------------
// MARK: - Bug D: Dark-lane probe in moot_fact_search (COMPOSER-02B update)
// ---------------------------------------------------------------------------
// recall_provenance was removed from the payload per COMPOSER-02B (moved to
// log-side only). The dark-lane probe still runs when a query is supplied, but
// its result is not emitted into the text body. These tests verify the new
// contract: fact search completes without error on a dark estate, and no
// recall_provenance token appears in the payload in either the query or no-query
// path.

@Suite("Bug D — Fact search dark-lane probe (log-only)", .serialized)
struct FactSearchDarkLaneHintTests {

    /// When the dense lane is dark and a query is supplied, moot_fact_search
    /// must still return the matching facts successfully. The dark-lane probe
    /// runs internally but its output goes to the log, not the payload
    /// (recall_provenance removed from payload per COMPOSER-02B).
    @Test func factSearchSucceeds_whenQueryAndDenseLaneDark() async throws {
        let (dispatcher, kit, handle) = try await openBareEstate()
        defer { Task { try? await kit.close(handle) } }

        // File a fact so the estate is non-empty.
        _ = try await fileFact(dispatcher, [
            "subject": .string("Swift"),
            "predicate": .string("created_by"),
            "object": .string("Apple"),
        ])

        // Search with a query — dense lane is dark (no corpus), but the
        // probe is log-side only; the payload must still contain the fact.
        let result = try await searchFacts(dispatcher, ["query": .string("Swift")])
        let rows = factRows(result)
        #expect(
            rows.contains { $0["predicate"] == .string("created_by") },
            "moot_fact_search with a query must return matching facts; got: \(rows)"
        )
        // recall_provenance is log-side only — must NOT appear in the payload.
        let body = factText(of: result)
        #expect(
            !body.contains("recall_provenance:"),
            "recall_provenance must not appear in payload (log-side only); got: \(body)"
        )
    }

    /// When no query is supplied (returns all facts), no recall_provenance
    /// token is emitted — the dark-lane probe skips entirely.
    @Test func factSearchNoProvenanceHint_whenNoQuery() async throws {
        let (dispatcher, kit, handle) = try await openBareEstate()
        defer { Task { try? await kit.close(handle) } }

        _ = try await fileFact(dispatcher, [
            "subject": .string("Rust"),
            "predicate": .string("created_by"),
            "object": .string("Graydon Hoare"),
        ])

        // No query → list-all path → probe does not run → no recall_provenance.
        let result = try await searchFacts(dispatcher, [:])
        let body = factText(of: result)
        #expect(
            !body.contains("recall_provenance:"),
            "moot_fact_search without a query must NOT emit recall_provenance:; got: \(body)"
        )
    }
}
