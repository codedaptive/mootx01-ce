// ErasePartialResponseTests.swift
//
// `moot_erase_memory` response honesty for a PARTIAL lineage expunge
// (MXE-FA). A caller acting on the response text is making a privacy
// decision on that sentence, so the message must match what happened:
//
//   R1 — A lineage expunge that the audit gate refused for an accepted
//        sibling must NOT respond `erased memory <id>`. The response
//        names the partial outcome, the refused count, and the ids.
//   R2 — A full expunge (no accepted members) responds exactly
//        `erased memory <id>`, byte-identical to the historical shape.

import Testing
import Foundation
import PersistenceKit
import PersistenceKitInMemory
import LocusKit
import GeniusLocusKit
@testable import AriaMCP

@Suite("moot_erase_memory — partial expunge is reported as partial", .serialized)
struct ErasePartialResponseTests {

    /// Dispatcher harness that also returns the kit and handle so tests can
    /// seed lineage state directly (the ARIA surface has no tool for
    /// constructing same-lineage siblings).
    private func makeDispatcherWithKit() async throws
        -> (ARIA_MCPDispatcher, GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "aria-erase-partial-tests")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory)
        )
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(
            storage: storage, owner: owner,
            identityKeyStore: InMemoryEstateIdentityKeyStore())
        let info = ARIA_MCPDispatcher.ServerInfo(name: "ARIA_MCP", version: "test")
        let tooling = ToolDispatcher(kit: kit, handle: handle)
        return (ARIA_MCPDispatcher(info: info, tooling: tooling), kit, handle)
    }

    private func captureFrame(content: String) -> CaptureFrame {
        CaptureFrame(
            content: content,
            channel: .typed,
            room: "aria-erase-partial-tests",
            latticeAnchor: .udc("000"),
            addedBy: "aria-erase-partial-tests",
            embeddingModelID: "test-model-v1"
        )
    }

    /// Call `moot_erase_memory` for `rowID` and return the response text.
    private func eraseText(
        _ dispatcher: ARIA_MCPDispatcher, rowID: String, requestID: Int64
    ) async throws -> (text: String, isError: Bool) {
        let request = JSONRPCRequest(
            id: .integer(requestID),
            method: "tools/call",
            params: .object([
                "name": .string("moot_erase_memory"),
                "arguments": .object([
                    "id": .string(rowID),
                    "reason": .string("erase-partial response shape test"),
                    "confirmed": .bool(true),
                ]),
            ])
        )
        let raw = await dispatcher.handle(request)
        let response = try #require(raw)
        guard case .result(let result) = response.payload else {
            Issue.record("moot_erase_memory returned JSON-RPC error: \(response.payload)")
            return ("", true)
        }
        let object = try #require(result.objectValue)
        let isError = object["isError"] == .bool(true)
        let content = try #require(object["content"]?.arrayValue)
        let first = try #require(content.first?.objectValue)
        let text = try #require(first["text"]?.stringValue)
        return (text, isError)
    }

    // MARK: - R1: partial expunge names the partial outcome and the count

    @Test
    func partialLineageExpungeResponseNamesRefusedCount() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcherWithKit()

        // D1: captured, promoted to accepted (S-1 requires trust ≥ canonical).
        let d1 = try await kit.capture(
            handle, captureFrame(content: "accepted iridium fact held for audit"))
        try await kit.mutate(handle, MutateFrame(rowID: d1.id, kind: .correctTrust(.canonical)))
        try await kit.mutate(handle, MutateFrame(rowID: d1.id, kind: .accept))

        // D2: same lineage, still active — the expunge target.
        var d2Frame = captureFrame(content: "active iridium draft in the same lineage")
        d2Frame.lineageID = d1.lineageID
        let d2 = try await kit.capture(handle, d2Frame)

        let (text, isError) = try await eraseText(dispatcher, rowID: d2.id, requestID: 40)
        #expect(!isError, "a partial expunge is a completed operation with a partial outcome, not a tool error")
        #expect(text != "erased memory \(d2.id)",
                "a partial lineage expunge must NOT claim a plain success: '\(text)'")
        #expect(text.contains("partial"),
                "the response must say the expunge was partial: '\(text)'")
        #expect(text.contains("1 "), "the response must name the refused count: '\(text)'")
        #expect(text.contains(d1.id),
                "the response must name the refused sibling id so the caller can act on it: '\(text)'")
    }

    // MARK: - R2: full expunge keeps the historical response byte-identical

    @Test
    func fullExpungeResponseUnchanged() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcherWithKit()
        let drawer = try await kit.capture(
            handle, captureFrame(content: "plain tellurium note with no lineage protection"))

        let (text, isError) = try await eraseText(dispatcher, rowID: drawer.id, requestID: 41)
        #expect(!isError)
        #expect(text == "erased memory \(drawer.id)",
                "a full expunge must keep the exact historical response shape; got '\(text)'")
    }
}
