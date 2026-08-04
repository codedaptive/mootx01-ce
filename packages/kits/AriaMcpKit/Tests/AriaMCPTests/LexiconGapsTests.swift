import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

/// Dispatch tests for Tier 3 (Knowledge Graph) and Tier 4 (Journal) tools.
///
/// These tests replace the SWIFT_LEXICON_GAPS_001 lexicon-based tests
/// (MCP-INT-01 surface replacement). The old lexicon surface tools this
/// file covered — `moot_capture_tunnel`, `moot_kgFact_recall`,
/// `moot_diaryEntry_recall`, `moot_proposal_recall`, `moot_association_recall`,
/// `moot_learnedReference_recall` — no longer exist on the AI-client surface.
///
/// Tier 3 KG tools: `moot_file_fact`, `moot_fact_search`, `moot_retire_fact`,
/// `moot_fact_timeline`.
/// Tier 4 Journal tools: `moot_write_journal`, `moot_read_journal`.
///
/// `.serialized`: each live-estate test opens an in-memory estate; preserve
/// one-at-a-time execution to prevent GeniusLocusKit actor contention.
@Suite("KG and Journal dispatch", .serialized)
struct LexiconGapsTests {

    // MARK: - Harness

    private func makeDispatcher() async throws -> ARIA_MCPDispatcher {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "kg-journal-tests")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory)
        )
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner, identityKeyStore: InMemoryEstateIdentityKeyStore())
        let info = ARIA_MCPDispatcher.ServerInfo(name: "ARIA_MCP", version: "test")
        let tooling = ToolDispatcher(kit: kit, handle: handle)
        return ARIA_MCPDispatcher(info: info, tooling: tooling)
    }

    // MARK: - Tier 3: moot_file_fact

    @Test("moot_file_fact happy path returns success result with fact id")
    func fileFactHappyPath() async throws {
        let dispatcher = try await makeDispatcher()
        let request = JSONRPCRequest(
            id: .integer(1),
            method: "tools/call",
            params: .object([
                "name": .string("moot_file_fact"),
                "arguments": .object([
                    "subject": .string("carbon"),
                    "predicate": .string("is_a"),
                    "object": .string("element"),
                ]),
            ])
        )
        let rawResponse = await dispatcher.handle(request)
        let response = try #require(rawResponse)
        guard case .result(let result) = response.payload else {
            Issue.record("moot_file_fact returned JSON-RPC error: \(response.payload)")
            return
        }
        let obj = try #require(result.objectValue)
        #expect(obj["isError"] == .bool(false), "file_fact must return isError=false")
        let text = try #require(
            obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue,
            "content[0].text must be present"
        )
        #expect(text.hasPrefix("filed fact "), "result must start with 'filed fact'; got: \(text)")
    }

    @Test("moot_file_fact without required subject returns invalidParams")
    func fileFactMissingSubjectReturnsInvalidParams() async throws {
        let dispatcher = try await makeDispatcher()
        let request = JSONRPCRequest(
            id: .integer(2),
            method: "tools/call",
            params: .object([
                "name": .string("moot_file_fact"),
                "arguments": .object([
                    // subject intentionally omitted
                    "predicate": .string("is_a"),
                    "object": .string("element"),
                ]),
            ])
        )
        let rawResponse = await dispatcher.handle(request)
        let response = try #require(rawResponse)
        guard case .error(let error) = response.payload else {
            Issue.record("missing subject must produce JSON-RPC error, got: \(response.payload)")
            return
        }
        #expect(error.code == JSONRPCErrorCode.invalidParams)
    }

    // MARK: - Tier 3: moot_fact_search

    @Test("moot_fact_search on empty estate returns success with zero facts")
    func factSearchEmptyEstateReturnsZero() async throws {
        let dispatcher = try await makeDispatcher()
        let request = JSONRPCRequest(
            id: .integer(3),
            method: "tools/call",
            params: .object([
                "name": .string("moot_fact_search"),
                "arguments": .object([:]),
            ])
        )
        let rawResponse = await dispatcher.handle(request)
        let response = try #require(rawResponse)
        guard case .result(let result) = response.payload else {
            Issue.record("moot_fact_search returned JSON-RPC error: \(response.payload)")
            return
        }
        let obj = try #require(result.objectValue)
        #expect(obj["isError"] == .bool(false), "fact_search must return isError=false on empty estate")
        let text = try #require(
            obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue
        )
        #expect(text.contains("0"), "empty estate must report zero facts; got: \(text)")
    }

    @Test("moot_fact_search returns filed facts")
    func factSearchReturnsFacts() async throws {
        let dispatcher = try await makeDispatcher()

        // File a fact first.
        _ = await dispatcher.handle(JSONRPCRequest(
            id: .integer(0),
            method: "tools/call",
            params: .object([
                "name": .string("moot_file_fact"),
                "arguments": .object([
                    "subject": .string("iron"),
                    "predicate": .string("has_property"),
                    "object": .string("magnetic"),
                ]),
            ])
        ))

        let request = JSONRPCRequest(
            id: .integer(4),
            method: "tools/call",
            params: .object([
                "name": .string("moot_fact_search"),
                "arguments": .object([:]),
            ])
        )
        let rawResponse = await dispatcher.handle(request)
        let response = try #require(rawResponse)
        guard case .result(let result) = response.payload else {
            Issue.record("moot_fact_search returned JSON-RPC error: \(response.payload)")
            return
        }
        let obj = try #require(result.objectValue)
        #expect(obj["isError"] == .bool(false))
        let text = try #require(
            obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue
        )
        #expect(text.contains("iron"), "fact_search must return filed facts; got: \(text)")
        // Part 6: evaluation fields — filed= and source= must appear in each fact line.
        #expect(text.contains("filed="), "fact_search must include filed= timestamp; got: \(text)")
        #expect(text.contains("source="), "fact_search must include source= drawer ID; got: \(text)")
    }

    @Test("moot_fact_search exact fields do not accept substring or provenance collisions")
    func factSearchExactFields() async throws {
        let dispatcher = try await makeDispatcher()
        // source_id must name a drawer that exists in this estate — a fact
        // inherits its source drawer's sensitivity, so an unresolvable anchor
        // fails the write. Two real drawers stand in for what used to be two
        // synthetic "miner:*" tags; the substring-collision case the test
        // guards lives on subject_exact ("ev-1" vs "ev-10"), which is
        // unaffected.
        var sourceIDs: [String] = []
        for label in ["calendar-source", "other-source"] {
            let filed = await dispatcher.handle(JSONRPCRequest(
                id: .integer(0), method: "tools/call", params: .object([
                    "name": .string("moot_file_memory"),
                    "arguments": .object([
                        "content": .string("fixture drawer \(label)"),
                        "location": .string("fixtures/\(label)"),
                        "subject": .string("fixture anchor drawer \(label)"),
                    ]),
                ])
            ))
            let response = try #require(filed)
            guard case .result(let result) = response.payload else {
                Issue.record("moot_file_memory failed: \(response.payload)")
                return
            }
            let text = try #require(
                result.objectValue?["content"]?.arrayValue?.first?
                    .objectValue?["text"]?.stringValue
            )
            // The body opens with "filed memory <drawer-id>" and may carry
            // further advisory lines, so read the id from the marker line
            // rather than taking the last token in the whole payload.
            let firstLine = String(text.split(separator: "\n").first ?? "")
            let id = firstLine
                .replacingOccurrences(of: "filed memory ", with: "")
                .trimmingCharacters(in: .whitespaces)
            #expect(!id.isEmpty, "could not read drawer id from: \(text)")
            sourceIDs.append(id)
        }
        for (subject, source) in [("calendar.event.ev-1", sourceIDs[0]),
                                  ("calendar.event.ev-10", sourceIDs[1])] {
            _ = await dispatcher.handle(JSONRPCRequest(
                id: .integer(0), method: "tools/call", params: .object([
                    "name": .string("moot_file_fact"),
                    "arguments": .object([
                        "subject": .string(subject),
                        "predicate": .string("scheduled"),
                        "object": .string("fixture"),
                        "source_id": .string(source),
                    ]),
                ])
            ))
        }
        let raw = await dispatcher.handle(JSONRPCRequest(
            id: .integer(1), method: "tools/call", params: .object([
                "name": .string("moot_fact_search"),
                "arguments": .object([
                    "subject_exact": .string("calendar.event.ev-1"),
                    "predicate_exact": .string("scheduled"),
                    "source_id_exact": .string(sourceIDs[0]),
                ]),
            ])
        ))
        let response = try #require(raw)
        guard case .result(let result) = response.payload else {
            Issue.record("exact fact search failed: \(response.payload)")
            return
        }
        let text = try #require(
            result.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue
        )
        #expect(text.contains("calendar.event.ev-1"))
        #expect(!text.contains("calendar.event.ev-10"))
        #expect(text.hasPrefix("facts: 1"))
    }

    // MARK: - Tier 3: moot_retire_fact

    @Test("moot_retire_fact for nonexistent id returns isError result")
    func retireFactNonexistentIDReturnsError() async throws {
        let dispatcher = try await makeDispatcher()
        let request = JSONRPCRequest(
            id: .integer(5),
            method: "tools/call",
            params: .object([
                "name": .string("moot_retire_fact"),
                "arguments": .object(["id": .string("nonexistent-fact-id")]),
            ])
        )
        let rawResponse = await dispatcher.handle(request)
        let response = try #require(rawResponse)
        guard case .result(let result) = response.payload else {
            Issue.record("moot_retire_fact returned JSON-RPC error: \(response.payload)")
            return
        }
        let obj = try #require(result.objectValue)
        // Not found = substrate refusal → isError=true tool result, not JSON-RPC error.
        #expect(obj["isError"] == .bool(true), "retiring nonexistent fact must return isError=true")
    }

    // MARK: - Tier 3: moot_fact_timeline

    @Test("moot_fact_timeline on empty estate returns success result")
    func factTimelineEmptyEstateReturnsSuccess() async throws {
        let dispatcher = try await makeDispatcher()
        let request = JSONRPCRequest(
            id: .integer(6),
            method: "tools/call",
            params: .object([
                "name": .string("moot_fact_timeline"),
                "arguments": .object([:]),
            ])
        )
        let rawResponse = await dispatcher.handle(request)
        let response = try #require(rawResponse)
        guard case .result(let result) = response.payload else {
            Issue.record("moot_fact_timeline returned JSON-RPC error: \(response.payload)")
            return
        }
        let obj = try #require(result.objectValue)
        #expect(obj["isError"] == .bool(false), "fact_timeline must return isError=false")
    }

    @Test("moot_fact_timeline includes sourceDrawerID evaluation field")
    func factTimelineIncludesSourceField() async throws {
        let dispatcher = try await makeDispatcher()
        // File a fact to have something in the timeline.
        _ = await dispatcher.handle(JSONRPCRequest(
            id: .integer(0),
            method: "tools/call",
            params: .object([
                "name": .string("moot_file_fact"),
                "arguments": .object([
                    "subject": .string("copper"),
                    "predicate": .string("is_a"),
                    "object": .string("metal"),
                ]),
            ])
        ))
        let request = JSONRPCRequest(
            id: .integer(6),
            method: "tools/call",
            params: .object([
                "name": .string("moot_fact_timeline"),
                "arguments": .object([:]),
            ])
        )
        let rawResponse = await dispatcher.handle(request)
        let response = try #require(rawResponse)
        guard case .result(let result) = response.payload else {
            Issue.record("moot_fact_timeline returned JSON-RPC error: \(response.payload)")
            return
        }
        let obj = try #require(result.objectValue)
        #expect(obj["isError"] == .bool(false))
        let text = try #require(
            obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue
        )
        // Part 6: source= evaluation field must appear on every fact line.
        #expect(text.contains("source="), "fact_timeline must include source= field; got: \(text)")
        #expect(text.contains("copper"), "fact_timeline must include filed facts; got: \(text)")
    }

    // MARK: - Tier 4: moot_write_journal

    @Test("moot_write_journal happy path returns success result")
    func writeJournalHappyPath() async throws {
        let dispatcher = try await makeDispatcher()
        let request = JSONRPCRequest(
            id: .integer(7),
            method: "tools/call",
            params: .object([
                "name": .string("moot_write_journal"),
                "arguments": .object([
                    "entry": .string("decided to approach the problem using BFS over DFS"),
                    "agent": .string("test-agent"),
                ]),
            ])
        )
        let rawResponse = await dispatcher.handle(request)
        let response = try #require(rawResponse)
        guard case .result(let result) = response.payload else {
            Issue.record("moot_write_journal returned JSON-RPC error: \(response.payload)")
            return
        }
        let obj = try #require(result.objectValue)
        #expect(obj["isError"] == .bool(false), "write_journal must return isError=false")
        let text = try #require(
            obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue
        )
        #expect(text.contains("test-agent"), "result must mention the agent name; got: \(text)")
    }

    @Test("moot_write_journal without content returns invalidParams")
    func writeJournalMissingContentReturnsInvalidParams() async throws {
        let dispatcher = try await makeDispatcher()
        let request = JSONRPCRequest(
            id: .integer(8),
            method: "tools/call",
            params: .object([
                "name": .string("moot_write_journal"),
                "arguments": .object([:]),  // entry intentionally omitted
            ])
        )
        let rawResponse = await dispatcher.handle(request)
        let response = try #require(rawResponse)
        guard case .error(let error) = response.payload else {
            Issue.record("missing content must produce JSON-RPC error, got: \(response.payload)")
            return
        }
        #expect(error.code == JSONRPCErrorCode.invalidParams)
    }

    // MARK: - Tier 4: moot_read_journal

    @Test("moot_read_journal on empty estate returns success result")
    func readJournalEmptyEstateReturnsSuccess() async throws {
        let dispatcher = try await makeDispatcher()
        let request = JSONRPCRequest(
            id: .integer(9),
            method: "tools/call",
            params: .object([
                "name": .string("moot_read_journal"),
                "arguments": .object(["agent": .string("nobody")]),
            ])
        )
        let rawResponse = await dispatcher.handle(request)
        let response = try #require(rawResponse)
        guard case .result(let result) = response.payload else {
            Issue.record("moot_read_journal returned JSON-RPC error: \(response.payload)")
            return
        }
        let obj = try #require(result.objectValue)
        #expect(obj["isError"] == .bool(false), "read_journal must return isError=false")
    }

    @Test("moot_write_journal then moot_read_journal round-trips the entry")
    func writeJournalThenReadReturnsEntry() async throws {
        let dispatcher = try await makeDispatcher()

        // Write an entry.
        _ = await dispatcher.handle(JSONRPCRequest(
            id: .integer(0),
            method: "tools/call",
            params: .object([
                "name": .string("moot_write_journal"),
                "arguments": .object([
                    "entry": .string("journal round-trip test entry"),
                    "agent": .string("rt-agent"),
                ]),
            ])
        ))

        // Read it back.
        let request = JSONRPCRequest(
            id: .integer(10),
            method: "tools/call",
            params: .object([
                "name": .string("moot_read_journal"),
                "arguments": .object(["agent": .string("rt-agent"), "last_n": .integer(5)]),
            ])
        )
        let rawResponse = await dispatcher.handle(request)
        let response = try #require(rawResponse)
        guard case .result(let result) = response.payload else {
            Issue.record("moot_read_journal returned JSON-RPC error: \(response.payload)")
            return
        }
        let obj = try #require(result.objectValue)
        #expect(obj["isError"] == .bool(false))
        let text = try #require(
            obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue
        )
        #expect(text.contains("journal round-trip test entry"),
            "read_journal must return the entry written; got: \(text)")
    }
}
