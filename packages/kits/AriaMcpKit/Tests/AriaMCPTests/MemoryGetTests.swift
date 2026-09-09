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

    // MARK: - 2. Not-found: genuinely absent id

    // MARK: - 3. Containment gate: exists but must never leak through the by-id door

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

    /// The other half of the provenance gate: it must be a gate, not a wall.
    /// Provenance `.normal` and `.elevated` are BELOW the redaction boundary and
    /// must still return verbatim content, or the fix would have closed the
    /// by-id door on ordinary rows.

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

    // MARK: - near: anchor pivot — the same provenance boundary

    // The by-id door (above) and the pivot door (`near:<uuid>`) must agree.
    // `moot_memory_search` deliberately surfaces a gated row's id with a
    // redacted body, so the UUID needed to pivot is obtainable in ordinary
    // use; without a gate the caller could hand that UUID back as `near:` and
    // receive the protected body's content-derived neighbors — the redaction
    // boundary crossed by a different door. These cases cover both tools that
    // accept `near:`: moot_memory_search and moot_recall_shaped.
    //
    // Every case asserts the SAME message an absent id produces. A distinct
    // message or error code would turn the gate into an existence oracle for
    // redacted rows, which is the same defect class it closes.

    /// Dispatch `near:` against both tools that accept it, returning each
    /// tool's error message (or `nil` if it did not throw). One helper is what
    /// makes "both doors agree" checkable in a single assertion per property.
    private func nearPivotMessages(
        anchorID: String,
        dispatcher: ToolDispatcher
    ) async -> [(tool: String, message: String?)] {
        var out: [(tool: String, message: String?)] = []
        for (tool, args) in [
            ("moot_memory_search", JSONValue.object(["near": .string(anchorID)])),
            ("moot_recall_shaped", JSONValue.object([
                "near": .string(anchorID), "preset": .string("balanced")
            ]))
        ] {
            do {
                _ = try await dispatcher.dispatch(name: tool, arguments: args)
                out.append((tool, nil))
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

    /// Regression for Codex finding `3a1cf92490a481918c3a2837effe341f`: before
    /// the gate, a provenance-Secret anchor's body became the recall query
    /// verbatim through both `near:` doors.

    /// Indistinguishability — the property the gate exists to protect. If a
    /// gated anchor produced any different message than a wholly absent UUID,
    /// `near:` would become an existence oracle for redacted rows.

    /// The other half: a gate, not a wall. Provenance `.normal` and
    /// `.elevated` are BELOW the redaction boundary and must still pivot, or
    /// the fix would have closed `near:` on ordinary rows. Mirrors the intent
    /// of `provenanceNormalAndElevatedDrawersAreReturnedInFull`.

    /// The adjective axis (bits 6-11) was already gated by the default
    /// RecallFrame before this mission and stays gated the same way after it.
    /// Pinning it here proves the provenance check was added ALONGSIDE the
    /// frame gate rather than replacing it.

    // MARK: - 4. estateID routing (Item 3 hardening, same gate moot_memory_search honors)

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
