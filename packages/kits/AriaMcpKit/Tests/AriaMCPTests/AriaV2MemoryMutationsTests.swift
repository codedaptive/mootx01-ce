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
            // 121 grapheme clusters (each e + combining accent = one cluster) is over the limit.
            ["memory_id": .string(memoryID), "mutation": .string("set_subject"), "subject": .string(String(repeating: "e\u{301}", count: 121))],
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

    @Test("typed mutation service links and reviews through the GLK tunnel boundary")
    func directlyMutatesLinksAndReviews() async throws {
        let fixture = try await makeFixture()
        let first = try await fixture.estate.capture(frame(content: "first"))
        let second = try await fixture.estate.capture(frame(content: "second"))
        let firstID = try #require(UUID(uuidString: first.id))
        let secondID = try #require(UUID(uuidString: second.id))

        let confirm = try await fixture.service.confirm(arguments: .object(["memory_id": .string(firstID.uuidString.uppercased())]))
        #expect(data(confirm)?["memory_id"] == .string(firstID.uuidString.lowercased()), "\(confirm)")
        #expect(data(confirm)?["mutation"] == .string("confirm"), "\(confirm)")
        // content[0].text parity: must match Swift:398.  Twin: Rust mutation_envelope_text_confirm.
        #expect(contentText(confirm) == "Confirmed memory \(firstID.uuidString.lowercased()).",
            "moot_confirm_memory content[0].text; got: \(String(describing: contentText(confirm)))")

        let link = try await fixture.service.link(arguments: .object([
            "from_id": .string(firstID.uuidString), "to_id": .string(secondID.uuidString), "relationship": .string("contradicts"),
        ]))
        #expect(data(link)?["from_id"] == .string(firstID.uuidString.lowercased()))
        #expect(data(link)?["to_id"] == .string(secondID.uuidString.lowercased()))
        #expect(data(link)?["kind"] == .string("contradicts"))
        #expect(data(link)?["tunnel_id"]?.stringValue != nil)
        // content[0].text parity: must match Swift:463.  Twin: Rust mutation_envelope_text_link_active.
        #expect(contentText(link) == "Linked memories \(firstID.uuidString.lowercased()) and \(secondID.uuidString.lowercased()).",
            "moot_link_memories content[0].text (active); got: \(String(describing: contentText(link)))")

        let proposed = try await fixture.kit.captureTunnel(fixture.handle, TunnelCaptureFrame(
            sourceWing: "Inbox", sourceRoom: "Inbox",
            targetWing: "Inbox", targetRoom: "Inbox",
            label: "reviewable typed service proposal", addedBy: "test",
            sourceDrawerId: first.id, targetDrawerId: second.id,
            kind: .contradicts, originClass: .derived, lifecycle: .proposed))

        let review = try await fixture.service.review(arguments: .object([
            "tunnel_id": .string(proposed.id), "decision": .string("accept"),
            "note": .string("approved by typed service"),
        ]))
        #expect(data(review)?["withdrawn"] == .bool(false), "\(review)")
        let settled = try #require(try await fixture.estate.getTunnel(id: proposed.id))
        #expect(settled.lifecycle == .active)
        #expect(settled.ext == "{\"reviewedBy\":\"user\"}")

        // moot_update_memory content[0].text parity: "Updated memory <id>."  (Swift:320)
        // Twin: Rust mutation_envelope_text_update.
        let updateTarget = try await fixture.estate.capture(frame(content: "update-target"))
        let updateTargetID = try #require(UUID(uuidString: updateTarget.id))
        let update = try await fixture.service.update(arguments: .object([
            "memory_id": .string(updateTargetID.uuidString), "mutation": .string("confirm"),
        ]))
        #expect(contentText(update) == "Updated memory \(updateTargetID.uuidString.lowercased()).",
            "moot_update_memory content[0].text; got: \(String(describing: contentText(update)))")

        // moot_withdraw_memory content[0].text parity: "Withdrew memory <id>."  (Swift:344)
        // Twin: Rust mutation_envelope_text_withdraw.
        let withdrawTarget = try await fixture.estate.capture(frame(content: "withdraw-target"))
        let withdrawTargetID = try #require(UUID(uuidString: withdrawTarget.id))
        let withdraw = try await fixture.service.withdraw(arguments: .object([
            "memory_id": .string(withdrawTargetID.uuidString),
        ]))
        #expect(contentText(withdraw) == "Withdrew memory \(withdrawTargetID.uuidString.lowercased()).",
            "moot_withdraw_memory content[0].text; got: \(String(describing: contentText(withdraw)))")

        // moot_erase_memory content[0].text parity (full): "Erased memory <id>."  (Swift:365)
        // Twin: Rust mutation_envelope_text_erase_full.
        let eraseTarget = try await fixture.estate.capture(frame(content: "erase-target"))
        let eraseTargetID = try #require(UUID(uuidString: eraseTarget.id))
        let erase = try await fixture.service.erase(arguments: .object([
            "memory_id": .string(eraseTargetID.uuidString), "confirmation": .bool(true),
        ]))
        #expect(contentText(erase) == "Erased memory \(eraseTargetID.uuidString.lowercased()).",
            "moot_erase_memory content[0].text (full); got: \(String(describing: contentText(erase)))")

        // moot_move_memory content[0].text parity: "Moved memory <id>."  (Swift:425)
        // Twin: Rust mutation_envelope_text_move.
        let moveTarget = try await fixture.estate.capture(frame(content: "move-target"))
        let moveTargetID = try #require(UUID(uuidString: moveTarget.id))
        let move = try await fixture.service.move(arguments: .object([
            "memory_id": .string(moveTargetID.uuidString), "wing": .string("Archive"), "room": .string("Moved"),
        ]))
        #expect(contentText(move) == "Moved memory \(moveTargetID.uuidString.lowercased()).",
            "moot_move_memory content[0].text; got: \(String(describing: contentText(move)))")
    }

    /// Parity gate: moot_erase_memory content[0].text for the partial erase path.
    ///
    /// "Partially erased memory <id>; 1 sibling(s) refused by the audit gate."
    /// (AriaV2MemoryMutations.swift:364)
    ///
    /// Twin: Rust mutation_envelope_text_erase_partial.
    ///
    /// Setup: an accepted (audit-gate-blocked) ancestor D1 and an active sibling D2
    /// in the same lineage.  Erasing D2 yields ErasedPartially with one refused sibling.
    @Test("partial erase envelope text matches Swift")
    func partialEraseEnvelopeTextMatchesSwift() async throws {
        let fixture = try await makeFixture()
        // D1: accepted (audit gate will refuse its tombstone).
        let d1 = try await fixture.estate.capture(frame(content: "partial-erase-anchor"))
        try await fixture.estate.mutate(rowID: d1.id, kind: .correctTrust(.canonical))
        try await fixture.estate.mutate(rowID: d1.id, kind: .accept)
        // D2: active sibling in the same lineage.
        var d2Frame = frame(content: "partial-erase-sibling")
        d2Frame.lineageID = d1.lineageID
        let d2 = try await fixture.estate.capture(d2Frame)
        let d2ID = try #require(UUID(uuidString: d2.id))

        let result = try await fixture.service.erase(arguments: .object([
            "memory_id": .string(d2ID.uuidString), "confirmation": .bool(true),
        ]))
        // content[0].text: partial text with exactly 1 refused sibling.
        #expect(
            contentText(result) == "Partially erased memory \(d2ID.uuidString.lowercased()); 1 sibling(s) refused by the audit gate.",
            "moot_erase_memory partial content[0].text; got: \(String(describing: contentText(result)))"
        )
    }

    @Test("mutation lookup preserves either physical UUID spelling")
    func mutationLookupAcceptsSwiftAndRustStorageSpellings() {
        let memoryID = UUID(uuidString: "a0b1c2d3-e4f5-4678-9012-3456789abcde")!
        #expect(AriaV2ArgumentDecoder.matchingStorageIdentity(
            memoryID, among: [memoryID.uuidString]) == memoryID.uuidString)
        #expect(AriaV2ArgumentDecoder.matchingStorageIdentity(
            memoryID, among: [memoryID.uuidString.lowercased()]) == memoryID.uuidString.lowercased())
    }

    private func makeFixture() async throws -> (kit: GeniusLocusKit, handle: EstateHandle, estate: Estate, service: AriaV2MemoryMutations) {
        let storage = InMemoryStorage(configuration: .init(estateID: UUID(), backend: .inMemory))
        let kit = GeniusLocusKit()
        let handle = try await kit.open(storage: storage, owner: .init(ownerIdentifier: "mutation-test"))
        let estate = try await kit.estate(for: handle)
        let context = AriaV2MemoryOperationContext(
            estateID: handle.estateUUID, callerID: "test-reviewer", serverIdentity: "test-server",
            now: { Date(timeIntervalSince1970: 1_700_000_000) })
        return (kit, handle, estate, .init(kit: kit, handle: handle, context: context))
    }

    private func frame(content: String) -> CaptureFrame {
        .init(content: content, channel: .typed, room: "Inbox", latticeAnchor: .udc("004"),
              addedBy: "test", embeddingModelID: "test-model", exportability: .public_, wing: "Memory")
    }

    private func data(_ result: JSONValue) -> [String: JSONValue]? {
        result.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue
    }

    /// Extract content[0].text from a dispatch result.
    private func contentText(_ result: JSONValue) -> String? {
        result.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue
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
