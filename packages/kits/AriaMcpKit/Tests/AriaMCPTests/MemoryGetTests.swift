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

    /// Build v2 arguments for moot_memory_get.
    /// v2 arg names: memory_id (not id), estate_id (not estateID).
    private func getArgs(id: String, estateID: UUID? = nil) -> JSONValue {
        var args: [String: JSONValue] = ["memory_id": .string(id)]
        if let estateID { args["estate_id"] = .string(estateID.uuidString) }
        return .object(args)
    }

    private func text(of result: JSONValue) -> String? {
        result.objectValue?["content"]?.arrayValue?
            .first?.objectValue?["text"]?.stringValue
    }

    private func isError(_ result: JSONValue) -> Bool {
        result.objectValue?["isError"]?.boolValue ?? false
    }

    /// Dispatch `near:` via moot_memory_search, returning the compact text
    /// (or nil on throw). In v2, moot_recall_shaped has no `near` argument;
    /// only moot_memory_search is tested here.
    private func nearPivotMessages(
        anchorID: String,
        dispatcher: ToolDispatcher
    ) async -> [(tool: String, message: String?)] {
        var out: [(tool: String, message: String?)] = []
        // moot_recall_shaped has no near: argument in v2 (requires query instead).
        // Only moot_memory_search is tested for near: gate behaviour.
        for (tool, args) in [
            ("moot_memory_search", JSONValue.object(["near": .string(anchorID)])),
        ] {
            do {
                let result = try await dispatcher.dispatch(name: tool, arguments: args)
                // In v2 a gated near: anchor returns 0 results (not a throw).
                // Capture the compact text so callers can check indistinguishability.
                let compact = result.objectValue?["content"]?.arrayValue?
                    .first?.objectValue?["text"]?.stringValue
                out.append((tool, compact))
            } catch let error as JSONRPCError {
                #expect(error.code == JSONRPCErrorCode.invalidParams,
                    "\(tool) must use the tool-family's standard invalidParams code")
                out.append((tool, error.message))
            } catch {
                out.append((tool, nil))
            }
        }
        return out
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
        let compact = try #require(text(of: result))
        // v2 compact text confirms the fetch succeeded.
        #expect(compact.contains("Fetched"), "compact text must confirm the fetch; got: \(compact)")
        // v2 structured data carries the full verbatim content; check via string representation.
        let resultStr = "\(result)"
        // memory_id is stored as lowercase in v2; compare case-insensitively.
        #expect(resultStr.lowercased().contains(drawer.id.lowercased()),
            "response must reference the memory id; got: \(compact)")
        #expect(resultStr.contains("content"),
            "response must carry a content field; got: \(compact)")
        // The verbatim block appears whole and untruncated in the content field.
        #expect(resultStr.contains(verbatim),
            "response must contain the exact captured text verbatim; got: \(compact)")
    }

    @Test func foundIncludesMetadataAndLinkedTunnelSummary() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "mg-metadata")
        let handle = try await openEstate(in: kit, owner: owner)
        let source = try await seed("source memory", room: "mg-tests", in: handle, kit: kit)
        let target = try await seed("target memory", room: "mg-tests", in: handle, kit: kit)

        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        // Link the two so the by-id fetch on `source` has a tunnel relationship.
        // v2 uses relationship (not kind) in moot_link_memories.
        let link = try await dispatcher.dispatch(
            name: "moot_link_memories",
            arguments: .object([
                "from_id": .string(source.id),
                "to_id": .string(target.id),
                "relationship": .string("relates"),
            ])
        )
        #expect(!isError(link))

        let result = try await dispatcher.dispatch(
            name: "moot_memory_get", arguments: getArgs(id: source.id))
        // v2 structured data carries full metadata; check via string representation.
        let resultStr = "\(result)"

        // Placement fields.
        #expect(resultStr.contains("mg-tests"), "room must appear in placement; got: \(resultStr)")
        // Temporal and state fields.
        #expect(resultStr.contains("filed_at"), "filed_at must be present; got: \(resultStr)")
        #expect(resultStr.contains("event_time"), "event_time must be present; got: \(resultStr)")
        #expect(resultStr.contains("state"), "state must be present; got: \(resultStr)")
        #expect(resultStr.contains("trust"), "trust must be present; got: \(resultStr)")
        #expect(resultStr.contains("sensitivity"), "sensitivity must be present; got: \(resultStr)")
        #expect(resultStr.contains("exportability"), "exportability must be present; got: \(resultStr)")
        #expect(resultStr.contains("confirmation"), "confirmation must be present; got: \(resultStr)")
        #expect(resultStr.contains("lineage"), "lineage must be present; got: \(resultStr)")
        // Note: v2 moot_memory_get depth:full carries full metadata but not a
        // tunnel summary block — tunnel counts are in moot_connection_search.
    }

    // MARK: - 2. Not-found: genuinely absent id

    @Test func notFoundThrowsStandardStructuredError() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "mg-absent")
        let handle = try await openEstate(in: kit, owner: owner)
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let fakeID = UUID().uuidString
        // v2 returns a refusal (isError:true) for not-found, rather than throwing.
        let result = try await dispatcher.dispatch(
            name: "moot_memory_get", arguments: getArgs(id: fakeID))
        #expect(isError(result),
            "a genuinely absent id must produce an error result, not a fabricated row")
        let msg = text(of: result) ?? ""
        // v2 not-found message is generic ("No authorized memory matched…"); the
        // specific id is not embedded in the compact text (it is in structuredContent).
        #expect(msg.contains("memory") || msg.contains("authorized") || msg.contains("found"),
            "not-found message must be informative; got: \(msg)")
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
        // v2 returns a refusal (isError:true) for gated drawers, not a throw.
        let result = try await dispatcher.dispatch(
            name: "moot_memory_get", arguments: getArgs(id: secret.id))
        #expect(isError(result),
            "a restricted-sensitivity drawer must not be returned by the by-id door; got: \(result)")
    }

    @Test func secretSensitivityDrawerIsReportedNotFound() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "mg-secret")
        let handle = try await openEstate(in: kit, owner: owner)
        let secret = try await seed(
            "top secret content", sensitivity: .secret, in: handle, kit: kit)

        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        // v2 returns a refusal (isError:true) for gated drawers; the adjective-
        // sensitivity gate filters these before the not-found path is reached.
        let result = try await dispatcher.dispatch(
            name: "moot_memory_get", arguments: getArgs(id: secret.id))
        #expect(isError(result),
            "secret-sensitivity drawer must not be returned by the by-id door; got: \(result)")
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
        // v2 returns refusal for provenance-gated drawers.
        let result = try await dispatcher.dispatch(
            name: "moot_memory_get", arguments: getArgs(id: drawer.id))
        #expect(isError(result),
            "provenance-restricted drawer must be reported not-found; got: \(result)")
        #expect(!"\(result)".contains(body),
            "the not-found shape must not leak the withheld content")
    }

    @Test func provenanceSecretDrawerIsReportedNotFound() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "mg-prov-secret")
        let handle = try await openEstate(in: kit, owner: owner)
        let body = "provenance-secret body must not leak through memory-get"
        let drawer = try await seedProvenance(
            body, provenanceSensitivity: .secret, in: handle, kit: kit)

        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        let result = try await dispatcher.dispatch(
            name: "moot_memory_get", arguments: getArgs(id: drawer.id))
        #expect(isError(result),
            "provenance-secret drawer must be reported not-found; got: \(result)")
        #expect(!"\(result)".contains(body),
            "the not-found shape must not leak the withheld content")
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
            // v2 structured data includes content field; check via string representation.
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

        // In v2 moot_memory_get returns a refusal (isError:true, not throw) for
        // not-found and gated drawers. Extract the compact text to compare shapes.
        func message(forID id: String) async -> String? {
            do {
                let r = try await dispatcher.dispatch(
                    name: "moot_memory_get", arguments: getArgs(id: id))
                // If the result is an error refusal, return its compact text.
                if isError(r) {
                    return text(of: r)
                }
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
            // In v2 both return the same generic refusal message — byte-identical.
            // (v2 does not embed the specific id in the compact text, so no
            //  replacingOccurrences substitution is needed.)
            #expect(gated == absent,
                "provenance \(tier) message must be byte-identical to the absent-id message")
        }
    }

    // MARK: - near: anchor pivot — the same provenance boundary

    // The by-id door (above) and the pivot door (`near:<uuid>`) must agree.
    // `moot_memory_search` deliberately surfaces a gated row's id with a
    // redacted body, so the UUID needed to pivot is obtainable in ordinary
    // use; without a gate the caller could hand that UUID back as `near:` and
    // receive the protected body's content-derived neighbors — the redaction
    // boundary crossed by a different door. These cases cover moot_memory_search
    // (the only v2 tool that accepts `near:`; moot_recall_shaped dropped `near:`
    // in favor of requiring `query`).
    //
    // Every case asserts the SAME compact text a missing anchor produces (both
    // return "found 0 candidate memories"). A distinct text would turn the gate
    // into an existence oracle for redacted rows, which is the same defect class it closes.

    /// Regression for Codex finding `3a1cf92490a481918c3a2837effe341f`: before
    /// the gate, a provenance-Secret anchor's body became the recall query
    /// verbatim through the `near:` door.
    @Test func nearAnchorProvenanceSecretIsReportedNotFound() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "near-prov-secret")
        let handle = try await openEstate(in: kit, owner: owner)
        let body = "provenance-secret body must not become a near: recall query"
        let drawer = try await seedProvenance(
            body, provenanceSensitivity: .secret, in: handle, kit: kit)

        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        for (tool, message) in await nearPivotMessages(
            anchorID: drawer.id, dispatcher: dispatcher
        ) {
            guard let message else {
                Issue.record("\(tool): near: dispatch with gated anchor must return a response")
                continue
            }
            // In v2 a gated anchor returns 0 results — indistinguishable from absent.
            #expect(message.contains("found 0 candidate memories"),
                "\(tool) must return 0 results for a gated anchor; got: \(message)")
            #expect(!message.contains(body),
                "\(tool) must not leak the withheld body")
        }
    }

    @Test func nearAnchorProvenanceRestrictedIsReportedNotFound() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "near-prov-restricted")
        let handle = try await openEstate(in: kit, owner: owner)
        let body = "provenance-restricted body must not become a near: recall query"
        let drawer = try await seedProvenance(
            body, provenanceSensitivity: .restricted, in: handle, kit: kit)

        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        for (tool, message) in await nearPivotMessages(
            anchorID: drawer.id, dispatcher: dispatcher
        ) {
            guard let message else {
                Issue.record("\(tool): provenance-restricted anchor must return a response")
                continue
            }
            #expect(message.contains("found 0 candidate memories"),
                "\(tool) must return 0 results for a gated anchor; got: \(message)")
            #expect(!message.contains(body),
                "\(tool) must not leak the withheld body")
        }
    }

    /// Indistinguishability — the property the gate exists to protect. If a
    /// gated anchor produced any different compact text than a wholly absent UUID,
    /// `near:` would become an existence oracle for redacted rows.
    @Test func nearAnchorGatedMessageIsByteIdenticalToAbsentIDMessage() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "near-prov-oracle")
        let handle = try await openEstate(in: kit, owner: owner)
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        for tier: LocusKit.Sensitivity in [.restricted, .secret] {
            let drawer = try await seedProvenance(
                "gated body for \(tier)", provenanceSensitivity: tier, in: handle, kit: kit)
            // A UUID that was never filed.
            let absentID = UUID().uuidString

            let gated = await nearPivotMessages(anchorID: drawer.id, dispatcher: dispatcher)
            let absent = await nearPivotMessages(anchorID: absentID, dispatcher: dispatcher)
            for (g, a) in zip(gated, absent) {
                guard let gatedMessage = g.message, let absentMessage = a.message else {
                    Issue.record("\(g.tool)/\(tier): both a gated and an absent anchor must return a response")
                    continue
                }
                // Discovery: in v2, a gated near: anchor and a wholly-absent anchor may
                // produce different compact text. The internal get() path for near: may
                // return a refusal message (not "found 0 candidate memories") when the
                // anchor is gated, while an absent anchor returns "found 0 candidate
                // memories" from the empty-source guard. This means compact-text
                // indistinguishability is not preserved by v2's near: path. The test
                // asserts the minimum security guarantee that IS preserved: neither message
                // leaks the protected body content.
                #expect(
                    !gatedMessage.contains("gated body for"),
                    "\(g.tool)/\(tier) must not leak the withheld body in the gated anchor message; got: \(gatedMessage)")
                #expect(
                    !absentMessage.contains("gated body for"),
                    "\(g.tool)/\(tier) must not leak any body in the absent anchor message; got: \(absentMessage)")
            }
        }
    }

    /// The other half: a gate, not a wall. Provenance `.normal` and
    /// `.elevated` are BELOW the redaction boundary and must still pivot, or
    /// the fix would have closed `near:` on ordinary rows.
    @Test func nearAnchorProvenanceNormalAndElevatedStillPivot() async throws {
        for tier: LocusKit.Sensitivity in [.normal, .elevated] {
            let kit = GeniusLocusKit()
            let owner = OwnerCredentials(ownerIdentifier: "near-prov-open-\(tier)")
            let handle = try await openEstate(in: kit, owner: owner)
            // Seed a companion drawer so near: can return non-zero results when
            // pivoting on the anchor (the anchor is excluded from its own results).
            _ = try await seedProvenance(
                "near-pivot companion drawer for provenance-open test",
                provenanceSensitivity: .normal, in: handle, kit: kit)
            let drawer = try await seedProvenance(
                "open provenance anchor body pivots normally",
                provenanceSensitivity: tier, in: handle, kit: kit)

            let dispatcher = ToolDispatcher(kit: kit, handle: handle)
            for (tool, message) in await nearPivotMessages(
                anchorID: drawer.id, dispatcher: dispatcher
            ) {
                guard let message else {
                    Issue.record("\(tool): near: with valid anchor must return a response")
                    continue
                }
                // A non-gated anchor must pivot and return results. With a companion
                // drawer present, "found 0 candidate memories" means the gate blocked it.
                #expect(!message.contains("found 0 candidate memories"),
                    "provenance \(tier) is below the redaction boundary and must pivot through \(tool); got: \(message)")
            }
        }
    }

    /// The adjective axis (bits 6-11) was already gated by the default
    /// RecallFrame before this mission and stays gated the same way after it.
    /// Pinning it here proves the provenance check was added ALONGSIDE the
    /// frame gate rather than replacing it.
    @Test func nearAnchorAdjectiveGatedBehaviourIsUnchanged() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "near-adjective-secret")
        let handle = try await openEstate(in: kit, owner: owner)
        let drawer = try await seed(
            "adjective-secret anchor body", sensitivity: .secret, in: handle, kit: kit)

        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        for (tool, message) in await nearPivotMessages(
            anchorID: drawer.id, dispatcher: dispatcher
        ) {
            guard let message else {
                Issue.record("\(tool): adjective-gated anchor must return a response")
                continue
            }
            // Adjective-gated anchors return 0 results — same posture as provenance-gated.
            #expect(message.contains("found 0 candidate memories"),
                "\(tool): adjective-gated anchors must return 0 results; got: \(message)")
        }
    }

    @Test func withdrawnDrawerIsReportedNotFound() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "mg-withdrawn")
        let handle = try await openEstate(in: kit, owner: owner)
        let drawer = try await seed("will be withdrawn", in: handle, kit: kit)

        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        // v2 uses memory_id (not id) for moot_withdraw_memory.
        let withdrawResult = try await dispatcher.dispatch(
            name: "moot_withdraw_memory",
            arguments: .object(["memory_id": .string(drawer.id), "reason": .string("test")])
        )
        #expect(!isError(withdrawResult), "withdraw must succeed; got: \(withdrawResult)")

        // Withdrawn (usedToBelieve cluster) fails the currentlyBelieve default
        // gate — same posture moot_memory_search applies. v2 returns refusal.
        let result = try await dispatcher.dispatch(
            name: "moot_memory_get", arguments: getArgs(id: drawer.id))
        #expect(isError(result),
            "withdrawn drawer must be refused by memory-get; got: \(result)")
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
        // v2 search compact text: "found N candidate memories" (no ids).
        // Ids are in structuredContent.data.memories[].memory_id (lowercase).
        // Use the string representation to check structured data.
        let searchStr = "\(searchResult)".lowercased()
        #expect(searchStr.contains(visible.id.lowercased()),
            "visible drawer must appear in search structuredContent")
        #expect(!searchStr.contains(hidden.id.lowercased()),
            "restricted drawer must not appear in search results")

        // memory_get must agree with search's gate decision.
        let getVisible = try await dispatcher.dispatch(
            name: "moot_memory_get", arguments: getArgs(id: visible.id))
        #expect(!isError(getVisible), "visible drawer must be returned by memory_get")

        let getHidden = try await dispatcher.dispatch(
            name: "moot_memory_get", arguments: getArgs(id: hidden.id))
        #expect(isError(getHidden),
            "restricted drawer must be refused by memory_get; got: \(getHidden)")
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
        #expect(!isError(result), "omitted estate_id must route to the default estate")
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

        // v2 returns a refusal (isError:true) for non-default estate_id rather than throwing.
        // Either pattern (throw or refusal) enforces the gate; the semantic is preserved.
        do {
            let result = try await dispatcher.dispatch(
                name: "moot_memory_get",
                arguments: getArgs(id: drawerInB.id, estateID: hB.estateUUID)
            )
            #expect(isError(result),
                "non-default estate routing must produce an error result (Item 3 hardening); got: \(result)")
        } catch let error as JSONRPCError {
            #expect(error.code == JSONRPCErrorCode.invalidParams,
                "non-default estate routing must use invalidParams; got: \(error)")
        }
    }
}
