import AriaMCPWire
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import Testing
@testable import AriaMCP

@Suite("ARIA v2 typed memory mutations")
struct AriaV2MemoryMutationsTests {
    @Test("strict requests reject unknown keys, self-links, and unsupported lower mutations")
    func rejectsInvalidRequests() throws {
        #expect(throws: JSONRPCError.self) {
            _ = try AriaV2WithdrawMemoryRequest(arguments: .object(["memory_id": .string(UUID().uuidString), "extra": .bool(true)]))
        }
        #expect(throws: JSONRPCError.self) {
            _ = try AriaV2LinkMemoriesRequest(arguments: .object([
                "from_id": .string(UUID().uuidString), "to_id": .string(UUID().uuidString), "relationship": .string("unknown"),
            ]))
        }
        #expect(throws: JSONRPCError.self) {
            _ = try AriaV2ReviewTunnelRequest(arguments: .object([
                "tunnel_id": .string(UUID().uuidString), "decision": .string("unknown"),
            ]))
        }
        #expect(throws: JSONRPCError.self) {
            _ = try AriaV2UpdateMemoryRequest(arguments: .object([
                "memory_id": .string(UUID().uuidString), "mutation": .string("confirm"), "content": .string("unsupported"),
            ]))
        }
    }

    @Test("update mutation payloads are finite, applicable, and lower-faithful")
    func updateMutationPayloadsMapOnlyToSupportedLowerKinds() throws {
        let memoryID = UUID().uuidString
        let cases: [([String: JSONValue], String)] = [
            (["memory_id": .string(memoryID), "mutation": .string("confirm")], "confirm"),
            (["memory_id": .string(memoryID), "mutation": .string("reject")], "reject"),
            (["memory_id": .string(memoryID), "mutation": .string("contest"), "note": .string("audit note")], "contest"),
            (["memory_id": .string(memoryID), "mutation": .string("resolve")], "resolve"),
            (["memory_id": .string(memoryID), "mutation": .string("supersede")], "supersede"),
            (["memory_id": .string(memoryID), "mutation": .string("revive")], "revive"),
            (["memory_id": .string(memoryID), "mutation": .string("accept")], "accept"),
            (["memory_id": .string(memoryID), "mutation": .string("set_subject"), "subject": .string("  Typed subject  ")], "set_subject"),
            (["memory_id": .string(memoryID), "mutation": .string("correct_sensitivity"), "sensitivity": .string("restricted")], "correct_sensitivity"),
            (["memory_id": .string(memoryID), "mutation": .string("correct_exportability"), "exportability": .string("public")], "correct_exportability"),
        ]

        for (arguments, expectedLowerKind) in cases {
            let request = try AriaV2UpdateMemoryRequest(arguments: .object(arguments))
            #expect(lowerName(try request.lowerKind()) == expectedLowerKind)
            if case .setSubject(let subject) = try request.lowerKind() {
                #expect(subject == "Typed subject")
            }
        }

        let note = try AriaV2UpdateMemoryRequest(arguments: .object([
            "memory_id": .string(memoryID), "mutation": .string("contest"), "note": .string("audit note"),
        ]))
        #expect(note.note == "audit note")

        let invalidArguments: [[String: JSONValue]] = [
            ["memory_id": .string(memoryID), "mutation": .string(" confirm ")],
            ["memory_id": .string(memoryID), "mutation": .string("confirm"), "subject": .string("inapplicable")],
            ["memory_id": .string(memoryID), "mutation": .string("confirm"), "sensitivity": .string("normal")],
            ["memory_id": .string(memoryID), "mutation": .string("confirm"), "exportability": .string("private")],
            ["memory_id": .string(memoryID), "mutation": .string("confirm"), "note": .string("ignored")],
            ["memory_id": .string(memoryID), "mutation": .string("set_subject")],
            ["memory_id": .string(memoryID), "mutation": .string("set_subject"), "subject": .string(String(repeating: "x", count: DrawerStore.subjectLengthContract + 1))],
            ["memory_id": .string(memoryID), "mutation": .string("set_subject"), "subject": .string(String(repeating: "e\u{301}", count: 120))],
            ["memory_id": .string(memoryID), "mutation": .string("set_subject"), "subject": .string(" " + String(repeating: "x", count: 120))],
            ["memory_id": .string(memoryID), "mutation": .string("correct_sensitivity")],
            ["memory_id": .string(memoryID), "mutation": .string("correct_exportability")],
            ["memory_id": .string(memoryID), "mutation": .string("set_sensitivity"), "sensitivity": .string("normal")],
            ["memory_id": .string(memoryID), "mutation": .string("confirm"), "content": .string("unsupported")],
            ["memory_id": .string(memoryID), "mutation": .string("confirm"), "location": .string("unsupported")],
            ["memory_id": .string(memoryID), "mutation": .string("confirm"), "wing": .string("unsupported")],
            ["memory_id": .string(memoryID), "mutation": .string("confirm"), "event_time": .string("2026-09-08T00:00:00Z")],
        ]
        for arguments in invalidArguments {
            #expect(throws: JSONRPCError.self) {
                _ = try AriaV2UpdateMemoryRequest(arguments: .object(arguments))
            }
        }
    }

    @Test("erase requires boolean true before the lower expunge")
    func eraseRejectsInvalidConfirmationWithoutExpunging() async throws {
        let fixture = try await makeFixture()
        let target = try await fixture.estate.capture(frame(content: "must survive rejected erase"))
        let memoryID = try #require(UUID(uuidString: target.id))
        let invalidArguments: [JSONValue] = [
            .object(["memory_id": .string(memoryID.uuidString)]),
            .object(["memory_id": .string(memoryID.uuidString), "confirmation": .bool(false)]),
            .object(["memory_id": .string(memoryID.uuidString), "confirmation": .string("no")]),
            .object(["memory_id": .string(memoryID.uuidString), "confirmation": .array([])]),
        ]

        for arguments in invalidArguments {
            do {
                _ = try await fixture.service.erase(arguments: arguments)
                Issue.record("erase accepted invalid confirmation: \(arguments)")
            } catch let error as JSONRPCError {
                #expect(error.code == JSONRPCErrorCode.invalidParams)
            }

            let surviving = (try await fixture.estate.allDrawers()).first { $0.id == target.id }
            #expect(surviving?.tombstonedAt == nil, "invalid confirmation must not reach expunge")
        }
    }

    @Test("direct lower calls produce canonical mutation and link outcomes")
    func directlyMutatesAndLinks() async throws {
        let fixture = try await makeFixture()
        let first = try await fixture.estate.capture(frame(content: "first"))
        let second = try await fixture.estate.capture(frame(content: "second"))
        let firstID = try #require(UUID(uuidString: first.id))
        let secondID = try #require(UUID(uuidString: second.id))

        let confirm = try await fixture.service.confirm(arguments: .object(["memory_id": .string(firstID.uuidString.uppercased())]))
        #expect(data(confirm)?["memory_id"] == .string(firstID.uuidString.lowercased()), "\(confirm)")
        #expect(data(confirm)?["mutation"] == .string("confirm"), "\(confirm)")

        let link = try await fixture.service.link(arguments: .object([
            "from_id": .string(firstID.uuidString), "to_id": .string(secondID.uuidString), "relationship": .string("contradicts"),
        ]))
        #expect(data(link)?["from_id"] == .string(firstID.uuidString.lowercased()))
        #expect(data(link)?["to_id"] == .string(secondID.uuidString.lowercased()))
        #expect(data(link)?["kind"] == .string("contradicts"))
        #expect(data(link)?["tunnel_id"]?.stringValue != nil)
    }

    @Test("mutation lookup preserves either physical UUID spelling")
    func mutationLookupAcceptsSwiftAndRustStorageSpellings() {
        let memoryID = UUID(uuidString: "a0b1c2d3-e4f5-4678-9012-3456789abcde")!
        #expect(AriaV2ArgumentDecoder.matchingStorageIdentity(
            memoryID, among: [memoryID.uuidString]) == memoryID.uuidString)
        #expect(AriaV2ArgumentDecoder.matchingStorageIdentity(
            memoryID, among: [memoryID.uuidString.lowercased()]) == memoryID.uuidString.lowercased())
    }

    private func makeFixture() async throws -> (estate: Estate, service: AriaV2MemoryMutations) {
        let storage = InMemoryStorage(configuration: .init(estateID: UUID(), backend: .inMemory))
        let kit = GeniusLocusKit()
        let handle = try await kit.open(storage: storage, owner: .init(ownerIdentifier: "mutation-test"))
        let estate = try await kit.estate(for: handle)
        let context = AriaV2MemoryOperationContext(
            estateID: handle.estateUUID, callerID: "test-reviewer", serverIdentity: "test-server",
            now: { Date(timeIntervalSince1970: 1_700_000_000) })
        return (estate, .init(kit: kit, handle: handle, context: context))
    }

    private func frame(content: String) -> CaptureFrame {
        .init(content: content, channel: .typed, room: "Inbox", latticeAnchor: .udc("004"),
              addedBy: "test", embeddingModelID: "test-model", exportability: .public_, wing: "Memory")
    }

    private func data(_ result: JSONValue) -> [String: JSONValue]? {
        result.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue
    }

    private func lowerName(_ kind: MutationKind) -> String {
        switch kind {
        case .confirm: "confirm"
        case .reject: "reject"
        case .contest: "contest"
        case .resolve: "resolve"
        case .supersede: "supersede"
        case .revive: "revive"
        case .accept: "accept"
        case .setSubject: "set_subject"
        case .correctSensitivity: "correct_sensitivity"
        case .correctExportability: "correct_exportability"
        case .correctTrust: "correct_trust"
        }
    }
}
