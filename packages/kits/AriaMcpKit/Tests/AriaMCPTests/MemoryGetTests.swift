import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

/// `moot_memory_get` — fetch one memory drawer by id, in full.
///
/// Closes the "fetch-drawer-by-ID" MCP API gap — build-now per Bob's
/// ruling. Reifies the ARIA
/// `recall` verb constrained by an exact identifier.
///
/// Four axes under test, per the mission's TDD ask:
///   1. Found — full content verbatim, matches captured text exactly.
///   2. Not-found — a genuinely absent id gets the tool-family's standard
///      structured error (JSONRPCError.invalidParams, "Memory not found: …").
///   3. Containment gate — a drawer that EXISTS but fails the same default
///      gate moot_memory_search applies (restricted/secret sensitivity,
///      untrustworthy trust, non-currentlyBelieve state, or tombstoned) is
///      reported not-found, identical to a genuinely absent id — the by-id
///      door must never become a way to confirm such content exists.
///   4. estateID routing — omitted routes to the default estate; the
///      default estate's own UUID is accepted; a non-default estate UUID is
///      refused (Item 3 hardening, same gate `moot_memory_search` honors).
///
/// `.serialized`: every case opens live in-memory estates and touches
/// content directly via `kit.capture`, matching the discipline in
/// `MultiEstateRoutingTests`/`VaultToolsTests`.
@Suite("moot_memory_get", .serialized)
struct MemoryGetTests {

    // MARK: - Harness

    private func openEstate(
        in kit: GeniusLocusKit,
        owner: OwnerCredentials
    ) async throws -> EstateHandle {
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory
        ))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        return try await kit.open(storage: storage, owner: owner, identityKeyStore: InMemoryEstateIdentityKeyStore())
    }

    /// Seed content directly into an estate via `kit.capture`, with full
    /// control over the adjective axes the containment gate reads.
    @discardableResult
    private func seed(
        _ content: String,
        room: String = "mg-tests",
        sensitivity: AdjectiveSensitivity = .normal,
        in handle: EstateHandle,
        kit: GeniusLocusKit
    ) async throws -> Drawer {
        let frame = CaptureFrame(
            content: content,
            channel: .typed,
            room: room,
            latticeAnchor: .udc("004"),
            addedBy: "aria-mcp-tests",
            embeddingModelID: "test-model-v1",
            sensitivity: sensitivity
        )
        return try await kit.capture(handle, frame)
    }

    /// Seed content with a chosen PROVENANCE sensitivity (bits 30-35,
    /// `Drawer.sensitivity`) — a different axis from the adjective sensitivity
    /// the `seed` helper above sets. The adjective axis stays `.normal` so the
    /// RecallFrame chain admits the row and it reaches the provenance gate,
    /// which is the boundary under test. Mirrors `SearchRedactionTests.seed`.
    @discardableResult
    private func seedProvenance(
        _ content: String,
        room: String = "mg-tests",
        provenanceSensitivity: LocusKit.Sensitivity,
        in handle: EstateHandle,
        kit: GeniusLocusKit
    ) async throws -> Drawer {
        let frame = CaptureFrame(
            content: content,
            channel: .typed,
            room: room,
            latticeAnchor: .udc("004"),
            addedBy: "aria-mcp-tests",
            embeddingModelID: "test-model-v1",
            provenanceSensitivity: provenanceSensitivity
        )
        return try await kit.capture(handle, frame)
    }

    private func getArgs(id: String, estateID: UUID? = nil) -> JSONValue {
        var args: [String: JSONValue] = ["id": .string(id)]
        if let estateID { args["estateID"] = .string(estateID.uuidString) }
        return .object(args)
    }

    private func text(of result: JSONValue) -> String? {
        result.objectValue?["content"]?.arrayValue?
            .first?.objectValue?["text"]?.stringValue
    }

    private func isError(_ result: JSONValue) -> Bool {
        result.objectValue?["isError"]?.boolValue ?? false
    }

    // MARK: - 1. Found: full content verbatim

    @Test func foundReturnsFullContentVerbatim() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "mg-found")
        let handle = try await openEstate(in: kit, owner: owner)
        let verbatim = "The exact captured text, byte for byte — not a 120-char preview."
        let drawer = try await seed(verbatim, in: handle, kit: kit)

        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        let result = try await dispatcher.dispatch(
            name: "moot_memory_get", arguments: getArgs(id: drawer.id))

        #expect(!isError(result), "a found drawer must not be an error result")
        let body = try #require(text(of: result))
        #expect(body.contains("memory \(drawer.id)"))
        #expect(body.contains("content:"))
        // The verbatim block appears whole and untruncated — not a preview.
        #expect(body.contains(verbatim), "response must contain the exact captured text")
        // The sensitivity-gate advisory is appended after the content block
        // whenever no grant is live, which is this dispatcher's state — it
        // depends on grant state alone, never on estate contents, so it is
        // present on every reply here. Strip that one trailing line before
        // asserting the content is the final block; what is under test is
        // that the content itself is not truncated.
        let advisoryPrefix = "sensitivity_advisory: "
        var lines = body.components(separatedBy: "\n")
        let advisory = try #require(lines.last, "reply must not be empty")
        #expect(advisory.hasPrefix(advisoryPrefix),
                "with no grant live the reply must end with the sensitivity-gate advisory")
        lines.removeLast()
        #expect(lines.joined(separator: "\n").hasSuffix(verbatim),
                "content must be the trailing verbatim block, not truncated")
    }

    @Test func foundIncludesMetadataAndLinkedTunnelSummary() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "mg-metadata")
        let handle = try await openEstate(in: kit, owner: owner)
        let source = try await seed("source memory", room: "mg-tests", in: handle, kit: kit)
        let target = try await seed("target memory", room: "mg-tests", in: handle, kit: kit)

        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        // Link the two so the by-id fetch on `source` has a tunnel to summarize.
        let link = try await dispatcher.dispatch(
            name: "moot_link_memories",
            arguments: .object([
                "from_id": .string(source.id),
                "to_id": .string(target.id),
                "kind": .string("relates"),
            ])
        )
        #expect(!isError(link))

        let result = try await dispatcher.dispatch(
            name: "moot_memory_get", arguments: getArgs(id: source.id))
        let body = try #require(text(of: result))

        // Metadata fields — room/wing, capture time, adjective axes.
        #expect(body.contains("room: mg-tests"))
        #expect(body.contains("filed_at:"))
        #expect(body.contains("event_time:"))
        #expect(body.contains("state:"))
        #expect(body.contains("trust:"))
        #expect(body.contains("sensitivity:"))
        #expect(body.contains("exportability:"))
        #expect(body.contains("confirmation:"))
        #expect(body.contains("lineage:"))
        // Linked tunnel summary, same shape as moot_connection_search/map.
        #expect(body.contains("tunnels: 1"))
        #expect(body.contains(target.id), "the linked tunnel's target id must appear in the summary")
    }

    // MARK: - 2. Not-found: genuinely absent id

    @Test func notFoundThrowsStandardStructuredError() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "mg-absent")
        let handle = try await openEstate(in: kit, owner: owner)
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let fakeID = UUID().uuidString
        do {
            _ = try await dispatcher.dispatch(
                name: "moot_memory_get", arguments: getArgs(id: fakeID))
            Issue.record("a genuinely absent id must throw, not return a fabricated row")
        } catch let error as JSONRPCError {
            #expect(error.code == JSONRPCErrorCode.invalidParams,
                "not-found must use the tool-family's standard structured error (invalidParams)")
            #expect(error.message.contains("Memory not found"))
            #expect(error.message.contains(fakeID))
        }
    }

    // MARK: - 3. Containment gate: exists but must never leak through the by-id door

    @Test func restrictedSensitivityDrawerIsReportedNotFound() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "mg-restricted")
        let handle = try await openEstate(in: kit, owner: owner)
        let secret = try await seed(
            "a restricted secret that must never leak through the by-id door",
            sensitivity: .restricted, in: handle, kit: kit)

        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        do {
            _ = try await dispatcher.dispatch(
                name: "moot_memory_get", arguments: getArgs(id: secret.id))
            Issue.record("a restricted-sensitivity drawer must not be returned by the by-id door")
        } catch let error as JSONRPCError {
            // Identical shape to a genuinely absent id — the caller cannot
            // distinguish "exists but gated" from "never existed."
            #expect(error.code == JSONRPCErrorCode.invalidParams)
            #expect(error.message.contains("Memory not found: \(secret.id)"))
        }
    }

    @Test func secretSensitivityDrawerIsReportedNotFound() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "mg-secret")
        let handle = try await openEstate(in: kit, owner: owner)
        let secret = try await seed(
            "top secret content", sensitivity: .secret, in: handle, kit: kit)

        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        await #expect(throws: JSONRPCError.self) {
            _ = try await dispatcher.dispatch(
                name: "moot_memory_get", arguments: getArgs(id: secret.id))
        }
    }

    // Regression pair (Swift/Rust conformance parity with Rust
    // `memory_get_provenance_secret_drawer_is_reported_not_found`): the two
    // cases above exercise the ADJECTIVE sensitivity axis, which the
    // RecallFrame chain already gated — so they passed while the PROVENANCE
    // axis (bits 30-35) went unchecked and returned verbatim content.
    // moot_memory_search redacts provenance Restricted/Secret previews while
    // still surfacing the row id, so by-id must not become a second door to
    // the body the redaction withheld.

    @Test func provenanceRestrictedDrawerIsReportedNotFound() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "mg-prov-restricted")
        let handle = try await openEstate(in: kit, owner: owner)
        let body = "provenance-restricted body must not leak through memory-get"
        let drawer = try await seedProvenance(
            body, provenanceSensitivity: .restricted, in: handle, kit: kit)

        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        do {
            let result = try await dispatcher.dispatch(
                name: "moot_memory_get", arguments: getArgs(id: drawer.id))
            Issue.record("provenance-restricted drawer must be reported not-found; got: \(result)")
        } catch let error as JSONRPCError {
            #expect(error.code == JSONRPCErrorCode.invalidParams)
            #expect(error.message.contains("Memory not found: \(drawer.id)"))
            #expect(!error.message.contains(body),
                "the not-found shape must not leak the withheld content")
        }
    }

    @Test func provenanceSecretDrawerIsReportedNotFound() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "mg-prov-secret")
        let handle = try await openEstate(in: kit, owner: owner)
        let body = "provenance-secret body must not leak through memory-get"
        let drawer = try await seedProvenance(
            body, provenanceSensitivity: .secret, in: handle, kit: kit)

        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        do {
            let result = try await dispatcher.dispatch(
                name: "moot_memory_get", arguments: getArgs(id: drawer.id))
            Issue.record("provenance-secret drawer must be reported not-found; got: \(result)")
        } catch let error as JSONRPCError {
            #expect(error.code == JSONRPCErrorCode.invalidParams)
            #expect(error.message.contains("Memory not found: \(drawer.id)"))
            #expect(!error.message.contains(body),
                "the not-found shape must not leak the withheld content")
        }
    }

    /// The other half of the provenance gate: it must be a gate, not a wall.
    /// Provenance `.normal` and `.elevated` are BELOW the redaction boundary and
    /// must still return verbatim content, or the fix would have closed the
    /// by-id door on ordinary rows.
    @Test func provenanceNormalAndElevatedDrawersAreReturnedInFull() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "mg-prov-open")
        let handle = try await openEstate(in: kit, owner: owner)
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        for tier: LocusKit.Sensitivity in [.normal, .elevated] {
            let body = "provenance-\(tier) body must be returned verbatim by memory-get"
            let drawer = try await seedProvenance(
                body, provenanceSensitivity: tier, in: handle, kit: kit)

            let result = try await dispatcher.dispatch(
                name: "moot_memory_get", arguments: getArgs(id: drawer.id))
            #expect("\(result)".contains(body),
                "provenance \(tier) is below the redaction boundary and must return full content")
        }
    }

    /// Indistinguishability, the property the gate exists to protect: a gated
    /// row and an absent id must produce the SAME message text, so by-id lookup
    /// cannot be used as an existence oracle for redacted content.
    @Test func provenanceGatedMessageIsByteIdenticalToAbsentIDMessage() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "mg-prov-oracle")
        let handle = try await openEstate(in: kit, owner: owner)
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        func message(forID id: String) async -> String? {
            do {
                _ = try await dispatcher.dispatch(
                    name: "moot_memory_get", arguments: getArgs(id: id))
                return nil
            } catch let error as JSONRPCError {
                return error.message
            } catch {
                return nil
            }
        }

        for tier: LocusKit.Sensitivity in [.restricted, .secret] {
            let drawer = try await seedProvenance(
                "gated body for \(tier)", provenanceSensitivity: tier, in: handle, kit: kit)

            guard let gated = await message(forID: drawer.id) else {
                Issue.record("provenance \(tier) drawer must be reported not-found")
                continue
            }
            // Compare against the absent-id message for the SAME id, so the
            // only possible difference would be the shape, not the id text.
            let absentID = UUID().uuidString
            guard let absent = await message(forID: absentID) else {
                Issue.record("absent id must be reported not-found")
                continue
            }
            #expect(gated == absent.replacingOccurrences(of: absentID, with: drawer.id),
                "provenance \(tier) message must be byte-identical to the absent-id message")
        }
    }

    @Test func withdrawnDrawerIsReportedNotFound() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "mg-withdrawn")
        let handle = try await openEstate(in: kit, owner: owner)
        let drawer = try await seed("will be withdrawn", in: handle, kit: kit)

        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        let withdrawResult = try await dispatcher.dispatch(
            name: "moot_withdraw_memory",
            arguments: .object(["id": .string(drawer.id), "reason": .string("test")])
        )
        #expect(!isError(withdrawResult))

        // Withdrawn (usedToBelieve cluster) fails the currentlyBelieve default
        // gate — same posture moot_memory_search applies.
        await #expect(throws: JSONRPCError.self) {
            _ = try await dispatcher.dispatch(
                name: "moot_memory_get", arguments: getArgs(id: drawer.id))
        }
    }

    @Test func foundGateMatchesSearchDefaultExactly() async throws {
        // Cross-check: whatever moot_memory_search's default gate admits, so
        // must moot_memory_get — same drawer, same estate, both tools.
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "mg-parity")
        let handle = try await openEstate(in: kit, owner: owner)
        let visible = try await seed("visible to both tools", in: handle, kit: kit)
        let hidden = try await seed(
            "hidden from both tools", sensitivity: .restricted, in: handle, kit: kit)

        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let searchResult = try await dispatcher.dispatch(
            name: "moot_memory_search", arguments: .object(["query": .string("both tools")]))
        let searchBody = try #require(text(of: searchResult))
        #expect(searchBody.contains(visible.id))
        #expect(!searchBody.contains(hidden.id))

        let getVisible = try await dispatcher.dispatch(
            name: "moot_memory_get", arguments: getArgs(id: visible.id))
        #expect(!isError(getVisible))

        await #expect(throws: JSONRPCError.self) {
            _ = try await dispatcher.dispatch(
                name: "moot_memory_get", arguments: getArgs(id: hidden.id))
        }
    }

    // MARK: - 4. estateID routing (Item 3 hardening, same gate moot_memory_search honors)

    @Test func omittedEstateIDHitsDefaultEstate() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "mg-routing-default")
        let hA = try await openEstate(in: kit, owner: owner)   // default
        let hB = try await openEstate(in: kit, owner: owner)
        let drawer = try await seed("row-in-default", in: hA, kit: kit)
        let dispatcher = ToolDispatcher(kit: kit, handle: hA).registering(hB)

        let result = try await dispatcher.dispatch(
            name: "moot_memory_get", arguments: getArgs(id: drawer.id))
        #expect(!isError(result), "omitted estateID must route to the default estate")
    }

    @Test func explicitDefaultEstateIDIsAccepted() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "mg-routing-explicit")
        let hA = try await openEstate(in: kit, owner: owner)   // default
        let drawer = try await seed("row-in-A", in: hA, kit: kit)
        let dispatcher = ToolDispatcher(kit: kit, handle: hA)

        let result = try await dispatcher.dispatch(
            name: "moot_memory_get", arguments: getArgs(id: drawer.id, estateID: hA.estateUUID))
        #expect(!isError(result), "the default estate's own UUID must be accepted")
    }

    @Test func nonDefaultEstateIDIsRefused() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "mg-routing-refused")
        let hA = try await openEstate(in: kit, owner: owner)   // default
        let hB = try await openEstate(in: kit, owner: owner)
        let drawerInB = try await seed("row-in-B", in: hB, kit: kit)
        let dispatcher = ToolDispatcher(kit: kit, handle: hA).registering(hB)

        do {
            _ = try await dispatcher.dispatch(
                name: "moot_memory_get",
                arguments: getArgs(id: drawerInB.id, estateID: hB.estateUUID)
            )
            Issue.record("direct routing to a non-default estate must throw invalidParams")
        } catch let error as JSONRPCError {
            #expect(error.code == JSONRPCErrorCode.invalidParams,
                "non-default estate routing must throw invalidParams (Item 3 hardening)")
        }
    }
}
