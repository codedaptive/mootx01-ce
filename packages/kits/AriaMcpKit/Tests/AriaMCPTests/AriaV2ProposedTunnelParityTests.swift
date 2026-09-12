// AriaV2ProposedTunnelParityTests.swift
//
// Gate tests for the proposed-tunnel lifecycle path through the v2 surface.
// Three assertions driven through ToolDispatcher.dispatch (the entry point
// the shipped server reaches):
//   1. Link with proposed=true → data.lifecycle == "proposed".
//   2. moot_review_tunnel accept → Settled, withdrawn=false; connection_search
//      now returns 1 (active tunnel is visible to search).
//   3. moot_review_tunnel reject → Settled, withdrawn=true; the row persists,
//      marked withdrawn, and invisible to search.
//
// These exact literals must match the Rust gate in
// aria_v2_wire_parity_tests.rs (B6 block). Change both or neither.

import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

@Suite("ARIA v2 proposed tunnel parity", .serialized)
struct AriaV2ProposedTunnelParityTests {

    // MARK: - Harness

    /// Build a ToolDispatcher wired to a clean in-memory estate.
    private func makeDispatcher() async throws -> ToolDispatcher {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "proposed-tunnel-tests")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory)
        )
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(
            storage: storage, owner: owner,
            identityKeyStore: InMemoryEstateIdentityKeyStore())
        return ToolDispatcher(kit: kit, handle: handle)
    }

    /// File a memory and return its row ID, parsed from the "filed memory <id>" line.
    private func fileMemory(_ dispatcher: ToolDispatcher, content: String) async throws -> String {
        let result = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: .object([
                "content": .string(content),
                "subject": .string(String(content.prefix(120))),
                "location": .string("proposed-tunnel-tests"),
            ])
        )
        guard let obj = result.objectValue, obj["isError"]?.boolValue != true else {
            let msg = result.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue ?? "unknown"
            throw JSONRPCError(code: JSONRPCErrorCode.internalError, message: "moot_file_memory failed: \(msg)")
        }
        let firstLine = obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue?
            .split(separator: "\n").first.map(String.init) ?? ""
        let id = firstLine.replacingOccurrences(of: "filed memory ", with: "")
        guard !id.isEmpty, id != firstLine else {
            throw JSONRPCError(code: JSONRPCErrorCode.internalError, message: "could not parse memory ID from: \(firstLine)")
        }
        return id
    }

    /// Extract `structuredContent.data` from a dispatch result.
    private func data(_ result: JSONValue) -> [String: JSONValue]? {
        result.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue
    }

    /// Extract the envelope text from content[0].text.
    private func contentText(_ result: JSONValue) -> String? {
        result.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue
    }

    /// Count outgoing connections for a memory via moot_connection_search.
    private func connectionCount(_ dispatcher: ToolDispatcher, memoryID: String) async throws -> Int {
        let result = try await dispatcher.dispatch(
            name: "moot_connection_search",
            arguments: .object(["memory_id": .string(memoryID), "direction": .string("outgoing")])
        )
        return data(result)?["edges"]?.arrayValue?.count ?? 0
    }

    // MARK: - B6 gate tests

    /// Gate: moot_link_memories proposed=true writes a proposed tunnel and
    /// the response envelope carries lifecycle="proposed".
    ///
    /// Entry point: ToolDispatcher.dispatch → v2 surface.
    /// These exact literals must match the Rust gate in
    /// aria_v2_wire_parity_tests.rs (B6). Change both or neither.
    @Test("proposed link envelope carries lifecycle=proposed")
    func proposedLinkEnvelopeCarriesLifecycleProposed() async throws {
        let dispatcher = try await makeDispatcher()
        let fromID = try await fileMemory(dispatcher, content: "source drawer for proposed link")
        let toID   = try await fileMemory(dispatcher, content: "target drawer for proposed link")

        let result = try await dispatcher.dispatch(
            name: "moot_link_memories",
            arguments: .object([
                "from_id": .string(fromID), "to_id": .string(toID),
                "relationship": .string("relates"), "proposed": .bool(true),
            ])
        )
        let isError = result.objectValue?["isError"]?.boolValue ?? true
        #expect(!isError, "proposed link must succeed; got: \(result)")

        // These exact literals must match the Rust gate in
        // aria_v2_wire_parity_tests.rs (B6). Change both or neither.
        #expect(
            data(result)?["lifecycle"] == .string("proposed"),
            "link envelope lifecycle must be \"proposed\" when proposed=true; got: \(String(describing: data(result)?["lifecycle"]))"
        )
        #expect(
            data(result)?["tunnel_id"]?.stringValue?.isEmpty == false,
            "link envelope must carry a non-empty tunnel_id"
        )
        // Envelope text: proposed link names both memories and points user to moot_review_tunnel.
        #expect(
            contentText(result) == "Proposed a link between memories \(fromID) and \(toID); review it with moot_review_tunnel.",
            "proposed link envelope text must match; got: \(String(describing: contentText(result)))"
        )
    }

    /// Gate: moot_review_tunnel accept flips the proposed tunnel to active.
    ///
    /// Proof: a proposed tunnel is invisible to connection_search (lifecycle
    /// guard filters it). After accept, connection_search returns 1 — the
    /// tunnel is now active.  The Settled result carries withdrawn=false.
    ///
    /// Entry point: ToolDispatcher.dispatch → v2 surface.
    /// These exact literals must match the Rust gate in
    /// aria_v2_wire_parity_tests.rs (B6). Change both or neither.
    @Test("review_tunnel accept flips proposed to active")
    func reviewTunnelAcceptFlipsProposedToActive() async throws {
        let dispatcher = try await makeDispatcher()
        let fromID = try await fileMemory(dispatcher, content: "accept-test source")
        let toID   = try await fileMemory(dispatcher, content: "accept-test target")

        // File the proposed link and extract the tunnel_id.
        let linkResult = try await dispatcher.dispatch(
            name: "moot_link_memories",
            arguments: .object([
                "from_id": .string(fromID), "to_id": .string(toID),
                "relationship": .string("supports"), "proposed": .bool(true),
            ])
        )
        let linkError = linkResult.objectValue?["isError"]?.boolValue ?? true
        #expect(!linkError, "proposed link must succeed: \(linkResult)")
        let tunnelID = try #require(
            data(linkResult)?["tunnel_id"]?.stringValue,
            "link must carry tunnel_id"
        )

        // Before accept: proposed tunnel is invisible to connection_search.
        let beforeCount = try await connectionCount(dispatcher, memoryID: fromID)
        #expect(beforeCount == 0, "proposed tunnel must be invisible before accept; got \(beforeCount)")

        // Accept: the user settles the proposed link.
        let accept = try await dispatcher.dispatch(
            name: "moot_review_tunnel",
            arguments: .object(["tunnel_id": .string(tunnelID), "decision": .string("accept")])
        )
        let acceptError = accept.objectValue?["isError"]?.boolValue ?? true
        #expect(!acceptError, "accept must succeed: \(accept)")

        // Settled receipt: withdrawn=false. These exact literals must match the
        // Rust gate in aria_v2_wire_parity_tests.rs (B6). Change both or neither.
        #expect(
            data(accept)?["withdrawn"] == .bool(false),
            "accept receipt must carry withdrawn=false; got: \(String(describing: data(accept)?["withdrawn"]))"
        )
        #expect(
            data(accept)?["contested"] == .bool(false),
            "accept receipt must carry contested=false; got: \(String(describing: data(accept)?["contested"]))"
        )
        // Envelope text: user-verdict path emits "Reviewed tunnel <id>." (is_objection=false).
        #expect(
            contentText(accept) == "Reviewed tunnel \(tunnelID).",
            "accept envelope text must be 'Reviewed tunnel <id>.'; got: \(String(describing: contentText(accept)))"
        )

        // After accept: active tunnel is visible to connection_search.
        let afterCount = try await connectionCount(dispatcher, memoryID: fromID)
        #expect(afterCount == 1, "active tunnel must be visible after accept; got \(afterCount)")
    }

    /// Gate: moot_review_tunnel reject marks the proposed tunnel withdrawn.
    ///
    /// The row persists in storage, is marked withdrawn, and is invisible to
    /// search. Proof: after reject, connection_search returns 0 — the withdrawn
    /// tunnel is invisible to search.  The Settled result carries withdrawn=true.
    ///
    /// Entry point: ToolDispatcher.dispatch → v2 surface.
    /// These exact literals must match the Rust gate in
    /// aria_v2_wire_parity_tests.rs (B6). Change both or neither.
    @Test("review_tunnel reject withdraws proposed tunnel")
    func reviewTunnelRejectWithdrawsProposedTunnel() async throws {
        let dispatcher = try await makeDispatcher()
        let fromID = try await fileMemory(dispatcher, content: "reject-test source")
        let toID   = try await fileMemory(dispatcher, content: "reject-test target")

        // File the proposed link and extract the tunnel_id.
        let linkResult = try await dispatcher.dispatch(
            name: "moot_link_memories",
            arguments: .object([
                "from_id": .string(fromID), "to_id": .string(toID),
                "relationship": .string("contradicts"), "proposed": .bool(true),
            ])
        )
        let linkError = linkResult.objectValue?["isError"]?.boolValue ?? true
        #expect(!linkError, "proposed link must succeed: \(linkResult)")
        let tunnelID = try #require(
            data(linkResult)?["tunnel_id"]?.stringValue,
            "link must carry tunnel_id"
        )

        // Before reject: proposed tunnel is invisible to connection_search.
        // This assertion goes red on the stored lifecycle directly — if the proposed
        // lifecycle is not carried, the tunnel lands as active and this count is 1,
        // failing here before the test ever reaches the precondition.
        let beforeCount = try await connectionCount(dispatcher, memoryID: fromID)
        #expect(beforeCount == 0, "proposed tunnel must be invisible before reject; got \(beforeCount)")

        // Reject: the user withdraws the proposed link.
        let reject = try await dispatcher.dispatch(
            name: "moot_review_tunnel",
            arguments: .object(["tunnel_id": .string(tunnelID), "decision": .string("reject")])
        )
        let rejectError = reject.objectValue?["isError"]?.boolValue ?? true
        #expect(!rejectError, "reject must succeed: \(reject)")

        // Settled receipt: withdrawn=true. These exact literals must match the
        // Rust gate in aria_v2_wire_parity_tests.rs (B6). Change both or neither.
        #expect(
            data(reject)?["withdrawn"] == .bool(true),
            "reject receipt must carry withdrawn=true; got: \(String(describing: data(reject)?["withdrawn"]))"
        )
        #expect(
            data(reject)?["contested"] == .bool(false),
            "reject receipt must carry contested=false; got: \(String(describing: data(reject)?["contested"]))"
        )
        // Envelope text: user-verdict path emits "Reviewed tunnel <id>." (is_objection=false).
        #expect(
            contentText(reject) == "Reviewed tunnel \(tunnelID).",
            "reject envelope text must be 'Reviewed tunnel <id>.'; got: \(String(describing: contentText(reject)))"
        )

        // After reject: withdrawn tunnel is invisible to connection_search.
        let afterCount = try await connectionCount(dispatcher, memoryID: fromID)
        #expect(afterCount == 0, "withdrawn tunnel must be invisible after reject; got \(afterCount)")
    }

    /// Gate: moot_review_tunnel reject with reviewed_by != "user" routes to the
    /// model-objection branch (object_to_tunnel), not the user-verdict branch
    /// (respond_to_tunnel).
    ///
    /// When a standing model endorsement exists, object_to_tunnel returns
    /// withdrawn=false, contested=true — keeping the tunnel proposed so a human
    /// sees the dispute. respond_to_tunnel (the user branch) would return
    /// withdrawn=true regardless of standing endorsements.
    ///
    /// This test: model-1 endorses, then model-2 objects. Since model-1's
    /// endorsement stands, the result is withdrawn=false, contested=true.
    ///
    /// Entry point: ToolDispatcher.dispatch → v2 surface.
    /// These exact literals must match the Rust gate in
    /// aria_v2_wire_parity_tests.rs. Change both or neither.
    @Test("review_tunnel model reject routes to object_to_tunnel")
    func reviewTunnelModelRejectRoutesToObjectToTunnel() async throws {
        let dispatcher = try await makeDispatcher()
        let fromID = try await fileMemory(dispatcher, content: "model-reject source")
        let toID   = try await fileMemory(dispatcher, content: "model-reject target")

        // File proposed link.
        let linkResult = try await dispatcher.dispatch(
            name: "moot_link_memories",
            arguments: .object([
                "from_id": .string(fromID), "to_id": .string(toID),
                "relationship": .string("relates"), "proposed": .bool(true),
            ])
        )
        let linkError = linkResult.objectValue?["isError"]?.boolValue ?? true
        #expect(!linkError, "proposed link must succeed: \(linkResult)")
        let tunnelID = try #require(
            data(linkResult)?["tunnel_id"]?.stringValue,
            "link must carry tunnel_id"
        )

        // model-1 endorses. This creates a standing endorsement that object_to_tunnel
        // will preserve when model-2 objects.
        let endorse = try await dispatcher.dispatch(
            name: "moot_review_tunnel",
            arguments: .object([
                "tunnel_id": .string(tunnelID),
                "decision": .string("endorse"),
                "reviewed_by": .string("model-1"),
            ])
        )
        let endorseError = endorse.objectValue?["isError"]?.boolValue ?? true
        #expect(!endorseError, "model-1 endorse must succeed: \(endorse)")
        // Envelope text: endorse path produces "Endorsed tunnel <id>."
        #expect(
            contentText(endorse) == "Endorsed tunnel \(tunnelID).",
            "endorse envelope text must be 'Endorsed tunnel <id>.'; got: \(String(describing: contentText(endorse)))"
        )

        // model-2 objects (reject with reviewed_by != "user") → model-objection branch.
        let reject = try await dispatcher.dispatch(
            name: "moot_review_tunnel",
            arguments: .object([
                "tunnel_id": .string(tunnelID),
                "decision": .string("reject"),
                "reviewed_by": .string("model-2"),
            ])
        )
        let rejectError = reject.objectValue?["isError"]?.boolValue ?? true
        #expect(!rejectError, "model reject must succeed: \(reject)")
        // Envelope text: model-objection path (is_objection=true) emits "Recorded an objection to tunnel <id>."
        // This is the neuter-proof discriminant: the generic literal "Applied the selected typed memory mutation."
        // must NOT appear here — is_objection drives a distinct string for the model-rejection path.
        #expect(
            contentText(reject) == "Recorded an objection to tunnel \(tunnelID).",
            "model-reject envelope text must be 'Recorded an objection to tunnel <id>.'; got: \(String(describing: contentText(reject)))"
        )

        // object_to_tunnel with standing model-1 endorsement: withdrawn=false, contested=true.
        // These exact literals must match the Rust gate in
        // aria_v2_wire_parity_tests.rs. Change both or neither.
        #expect(
            data(reject)?["withdrawn"] == .bool(false),
            "model reject with standing endorsement: withdrawn must be false; got: \(String(describing: data(reject)?["withdrawn"]))"
        )
        #expect(
            data(reject)?["contested"] == .bool(true),
            "model reject with standing endorsement: contested must be true; got: \(String(describing: data(reject)?["contested"]))"
        )

        // The tunnel is still proposed (not active, not withdrawn) — invisible to search.
        let afterCount = try await connectionCount(dispatcher, memoryID: fromID)
        #expect(afterCount == 0,
            "contested tunnel must remain invisible to connection_search; got \(afterCount)")
    }
}
