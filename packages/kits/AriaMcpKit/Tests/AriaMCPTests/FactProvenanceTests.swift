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
    /// source_id the fact is sourceless, so source= renders empty.
    @Test func factFiledWithMootx01IdentityGetsMootx01AddedBy() async throws {
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
            searchBody.contains("addedBy=mootx01"),
            "fact filed via identity 'mootx01' must carry addedBy=mootx01; got: \(searchBody)"
        )
        #expect(
            !searchBody.contains("addedBy=aria-mcp-server"),
            "mootx01-hosted dispatcher must NOT stamp 'aria-mcp-server'; got: \(searchBody)"
        )
        // The host identity is never a drawer id, so it must not appear in the
        // source slot. No source_id was supplied, so the fact is sourceless.
        #expect(
            !searchBody.contains("source=mootx01"),
            "host identity must not land in sourceDrawerID; got: \(searchBody)"
        )
    }

    /// A dispatcher constructed with identity "aria-mcp-server" must stamp
    /// facts with addedBy="aria-mcp-server".
    @Test func factFiledWithAriaMcpIdentityGetsAriaMcpAddedBy() async throws {
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
            body.contains("addedBy=aria-mcp-server"),
            "fact filed via identity 'aria-mcp-server' must carry addedBy=aria-mcp-server; got: \(body)"
        )
    }

    /// An explicit source_id must name a drawer that exists in this estate.
    /// A fact inherits its source drawer's sensitivity, so an anchor that
    /// resolves to nothing is rejected rather than filed at the Normal
    /// default — filing it would disclose at a tier no drawer authorised.
    @Test func explicitSourceIdNamingNoDrawerFailsTheWrite() async throws {
        let (dispatcher, kit, handle) = try await openBareEstate(identity: "mootx01")
        defer { Task { try? await kit.close(handle) } }

        await #expect(throws: GeniusLocusKitError.sourceDrawerNotFound(
            drawerID: "external-agent")) {
            _ = try await dispatcher.runFileFact([
                "subject": .string("Tokyo"),
                "predicate": .string("is_capital_of"),
                "object": .string("Japan"),
                "source_id": .string("external-agent"),
            ], now: Date())
        }

        // Nothing was filed, so the fact surface stays empty.
        let searchResult = try await dispatcher.runFactSearch(["query": .string("Tokyo")])
        let body = factText(of: searchResult)
        #expect(
            !body.contains("Tokyo"),
            "a rejected write must leave no fact behind; got: \(body)"
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
