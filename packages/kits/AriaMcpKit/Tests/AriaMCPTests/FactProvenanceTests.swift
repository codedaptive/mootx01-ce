// FactProvenanceTests.swift
//
// Tests for two fact-surface fixes:
//
//   Bug C — Host identity injected into ToolDispatcher so rows filed via
//            `moot_file_fact` carry the correct source stamp for whichever
//            binary is hosting the dispatcher (aria-mcp-server, mootx01, etc.)
//            rather than the hardcoded "aria-mcp-server" constant.
//
//   Bug D — `moot_fact_search` surfaces a `recall_provenance:` hint when the
//            dense lane is unavailable so AI callers can distinguish "no lexical
//            match" from "semantic search was not consulted".

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
    let handle = try await kit.open(storage: storage, owner: owner)
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
    /// filed via moot_file_fact with source="mootx01" when no explicit
    /// source_id is supplied by the caller.
    @Test func factFiledWithMootx01IdentityGetsMootx01Source() async throws {
        let (dispatcher, kit, handle) = try await openBareEstate(identity: "mootx01")
        defer { Task { try? await kit.close(handle) } }

        let fileResult = try await dispatcher.runFileFact([
            "subject": .string("Paris"),
            "predicate": .string("is_capital_of"),
            "object": .string("France"),
        ], now: Date())
        let body = factText(of: fileResult)
        #expect(body.hasPrefix("filed fact"), "runFileFact must succeed; got: \(body)")

        // Retrieve the fact and verify the source stamp.
        let searchResult = try await dispatcher.runFactSearch(["query": .string("Paris")])
        let searchBody = factText(of: searchResult)
        #expect(
            searchBody.contains("source=mootx01"),
            "fact filed via identity 'mootx01' must carry source=mootx01; got: \(searchBody)"
        )
        #expect(
            !searchBody.contains("source=aria-mcp-server"),
            "mootx01-hosted dispatcher must NOT stamp 'aria-mcp-server'; got: \(searchBody)"
        )
    }

    /// A dispatcher constructed with identity "aria-mcp-server" must stamp
    /// facts with source="aria-mcp-server".
    @Test func factFiledWithAriaMcpIdentityGetsAriaMcpSource() async throws {
        let (dispatcher, kit, handle) = try await openBareEstate(identity: "aria-mcp-server")
        defer { Task { try? await kit.close(handle) } }

        _ = try await dispatcher.runFileFact([
            "subject": .string("Berlin"),
            "predicate": .string("is_capital_of"),
            "object": .string("Germany"),
        ], now: Date())

        let searchResult = try await dispatcher.runFactSearch(["query": .string("Berlin")])
        let body = factText(of: searchResult)
        #expect(
            body.contains("source=aria-mcp-server"),
            "fact filed via identity 'aria-mcp-server' must carry source=aria-mcp-server; got: \(body)"
        )
    }

    /// When the caller explicitly supplies a source_id, that value wins over
    /// the injected server identity — the explicit source is honoured.
    @Test func explicitSourceIdOverridesServerIdentity() async throws {
        let (dispatcher, kit, handle) = try await openBareEstate(identity: "mootx01")
        defer { Task { try? await kit.close(handle) } }

        _ = try await dispatcher.runFileFact([
            "subject": .string("Tokyo"),
            "predicate": .string("is_capital_of"),
            "object": .string("Japan"),
            "source_id": .string("external-agent"),
        ], now: Date())

        let searchResult = try await dispatcher.runFactSearch(["query": .string("Tokyo")])
        let body = factText(of: searchResult)
        #expect(
            body.contains("source=external-agent"),
            "explicit source_id must override server identity; got: \(body)"
        )
        #expect(
            !body.contains("source=mootx01"),
            "server identity must NOT appear when explicit source_id is supplied; got: \(body)"
        )
    }
}

// ---------------------------------------------------------------------------
// MARK: - Bug D: Dark-lane hint in moot_fact_search
// ---------------------------------------------------------------------------

@Suite("Bug D — Fact search dark-lane hint", .serialized)
struct FactSearchDarkLaneHintTests {

    /// When the dense lane is dark (no corpus registered) and a query is
    /// supplied, moot_fact_search must append a recall_provenance line so the
    /// caller knows the match was lexical-only.
    @Test func factSearchAppendsProvenance_whenQueryAndDenseLaneDark() async throws {
        let (dispatcher, kit, handle) = try await openBareEstate()
        defer { Task { try? await kit.close(handle) } }

        // File a fact so the estate is non-empty (proves the hint is about
        // lane state, not about the estate being empty).
        _ = try await dispatcher.runFileFact([
            "subject": .string("Swift"),
            "predicate": .string("created_by"),
            "object": .string("Apple"),
        ], now: Date())

        // Search with a query — dense lane is dark (no corpus), so a
        // recall_provenance line must appear.
        let result = try await dispatcher.runFactSearch(["query": .string("Swift")])
        let body = factText(of: result)
        #expect(
            body.contains("recall_provenance:"),
            "moot_fact_search with a query on a dark-dense-lane estate must emit recall_provenance:; got: \(body)"
        )
        #expect(
            body.contains("dense_lane:"),
            "recall_provenance line must include a dense_lane: token; got: \(body)"
        )
    }

    /// When no query is supplied (returns all facts), no recall_provenance
    /// hint is emitted — there is no semantic query to misinterpret.
    @Test func factSearchNoProvenanceHint_whenNoQuery() async throws {
        let (dispatcher, kit, handle) = try await openBareEstate()
        defer { Task { try? await kit.close(handle) } }

        _ = try await dispatcher.runFileFact([
            "subject": .string("Rust"),
            "predicate": .string("created_by"),
            "object": .string("Graydon Hoare"),
        ], now: Date())

        // No query → list-all path → no provenance hint needed.
        let result = try await dispatcher.runFactSearch([:])
        let body = factText(of: result)
        #expect(
            !body.contains("recall_provenance:"),
            "moot_fact_search without a query must NOT emit recall_provenance:; got: \(body)"
        )
    }
}
