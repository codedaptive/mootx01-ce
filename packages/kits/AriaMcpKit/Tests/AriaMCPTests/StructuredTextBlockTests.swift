// StructuredTextBlockTests.swift
//
// The serialized structured payload rides as the LAST text block of every v2
// result, so a client that reads only `content` (Claude Desktop) receives
// the whole answer. Pins the envelope function and the production egress
// chain end to end on a real dispatcher.

import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import AriaMCPWire
@testable import AriaMCP

@Suite("v2 results carry the serialized structured payload as the last text block")
struct StructuredTextBlockTests {

    private func blocks(of result: JSONValue) -> [String] {
        guard case let .array(content)? = result.objectValue?["content"] else { return [] }
        return content.compactMap { $0.objectValue?["text"]?.stringValue }
    }

    private func parsed(_ text: String) throws -> JSONValue {
        try JSONValue.from(JSONSerialization.jsonObject(with: Data(text.utf8)))
    }

    @Test("the trailing block parses back to structuredContent, and the compact line stays first")
    func trailingBlockIsTheStructuredPayload() throws {
        let result = AriaV2Envelope.success(
            tool: "moot_estate_ping", effect: .read,
            data: .object(["estate_id": .string("abc"), "wings": .array([.string("Personal")])]),
            meta: ["completeness": .string("incomplete")],
            compactText: "moot_estate_ping completed for estate abc.")
        let out = AriaV2Envelope.appendStructuredText(result)
        let texts = blocks(of: out)
        #expect(texts.count == 2)
        #expect(texts.first == "moot_estate_ping completed for estate abc.")
        let structured = try #require(out.objectValue?["structuredContent"])
        #expect(try parsed(texts[1]) == structured)
        // Sorted keys, no escaped slashes: the byte shape the Rust twin produces.
        #expect(texts[1].hasPrefix("{\"data\":{\"estate_id\":\"abc\""))
    }

    @Test("appending twice adds nothing, and a hint applied earlier is inside the block")
    func idempotentAndCarriesTheHint() throws {
        let base = AriaV2Envelope.success(
            tool: "moot_memory_search", effect: .read, data: .object(["results": .array([])]),
            compactText: "found 0 candidate memories")
        let hinted = AriaV2Envelope.applyHint("narrow the query", to: base)
        let once = AriaV2Envelope.appendStructuredText(hinted)
        let twice = AriaV2Envelope.appendStructuredText(once)
        #expect(once == twice)
        let texts = blocks(of: once)
        #expect(texts.count == 2)
        #expect(texts[1].contains("\"hint\":\"narrow the query\""))
    }

    @Test("a refusal carries its structured error as the trailing block; a bare text result is untouched")
    func refusalsAndBareResults() throws {
        let refusal = AriaV2Envelope.refusal(
            tool: "moot_memory_get",
            error: AriaV2OperationalRefusal(code: "not_found", message: "no such memory", retryable: false))
        let texts = blocks(of: AriaV2Envelope.appendStructuredText(refusal))
        #expect(texts.count == 2)
        #expect(texts[1].contains("\"code\":\"not_found\""))
        let bare = ToolDispatcher.textResultBlocks(["plain"])
        #expect(AriaV2Envelope.appendStructuredText(bare) == bare)
    }

    @Test("the production dispatcher emits the block for a diagnostic read")
    func dispatcherEmitsTheBlock() async throws {
        let kit = GeniusLocusKit()
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(
            storage: storage, owner: OwnerCredentials(ownerIdentifier: "structured-text"))
        let handle = try await kit.open(
            storage: storage,
            owner: OwnerCredentials(ownerIdentifier: "structured-text"),
            identityKeyStore: InMemoryEstateIdentityKeyStore())
        defer { Task { try? await kit.close(handle) } }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        let result = try await dispatcher.dispatch(name: "moot_estate_status", arguments: .object([:]))
        let texts = blocks(of: result)
        let structured = try #require(result.objectValue?["structuredContent"])
        let last = try #require(texts.last)
        #expect(try parsed(last) == structured)
        #expect(last.contains("\"memory_count\""))
    }
}
