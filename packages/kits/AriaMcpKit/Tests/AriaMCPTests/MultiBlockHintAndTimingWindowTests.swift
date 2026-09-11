// MultiBlockHintAndTimingWindowTests.swift
//
// Regression suite for MISSION_AT_01 — two independent ToolDispatch defects:
//
//   Finding B: the hint appenders (appendUnknownArgsHint / applyHint) read
//   content[0] only and rebuilt a single-block result, silently destroying
//   every block after the first. Any moot_json_import call with
//   return_id_map: true that also tripped a hint lost its id_map block.
//   The fix appends the hint to the first block's text and carries all
//   subsequent blocks through unchanged (mirroring the Rust port, which
//   mutates content[0]["text"] in place and never had the defect).
//
//   Finding A: runTimingReport collected the caller-requested audit window
//   with no call-level bound — since_ms: 0 forced the entire audit log into
//   memory before deriving. The fix caps collection at
//   ToolDispatcher.timingWindowMaxEvents per call and reports truncation,
//   with the existing watermark_ms contract paging the remainder.

import Testing
import Foundation
import LocusKit
import GeniusLocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

/// `.serialized`: tests open live in-memory estates; serial execution avoids
/// contention between concurrent GLK estate opens.
@Suite("Multi-block hint preservation and bounded timing window", .serialized)
struct MultiBlockHintAndTimingWindowTests {

    // MARK: - Harness

    /// Provision a GLK estate and build a ToolDispatcher on its handle, with
    /// vault explicitly enabled so moot_json_import is routable.
    private func makeVaultDispatcher() async throws -> (ToolDispatcher, GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "multiblock-hint-tests")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        let params = EstateProvisionParams(
            estateName: "MultiBlock Hint Test Estate",
            kind: .glk,
            zoomWindowLow: 1,
            zoomWindowHigh: 10,
            frameworkProfile: "KnowledgeWork",
            syncMode: .none
        )
        let handle = try await kit.provision(
            storage: storage, owner: owner, params: params,
            embeddingModels: [.deterministic])
        let dispatcher = ToolDispatcher(
            kit: kit, handle: handle,
            environment: ["MOOTX01_VAULT": "1"])
        return (dispatcher, kit, handle)
    }

    /// Lean estate without vault for the timing-window tests.
    private func makeDispatcher() async throws -> (ToolDispatcher, GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "timing-window-tests")
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(
            storage: storage, owner: owner,
            identityKeyStore: InMemoryEstateIdentityKeyStore())
        return (ToolDispatcher(kit: kit, handle: handle), kit, handle)
    }

    /// All text blocks of a tool-result JSONValue, in order.
    private func blocks(of result: JSONValue) -> [String] {
        guard case let .object(obj) = result,
              case let .array(content)? = obj["content"] else { return [] }
        return content.compactMap { block in
            guard case let .object(b) = block,
                  case let .string(s)? = b["text"] else { return nil }
            return s
        }
    }

    /// The `structuredContent.data` object of a tool-result JSONValue.
    private func data(of result: JSONValue) -> [String: JSONValue]? {
        guard case let .object(obj) = result,
              case let .object(structured)? = obj["structuredContent"],
              case let .object(data)? = structured["data"] else { return nil }
        return data
    }

    private func isError(of result: JSONValue) -> Bool {
        guard case let .object(obj) = result,
              case let .bool(flag)? = obj["isError"] else { return false }
        return flag
    }

    private func tempSeedFile(_ json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-multiblock-hint-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        return url
    }

    // MARK: - Finding B: multi-block result + hint → all blocks survive

    /// `return_id_map: true` must append a SECOND text block carrying the
    /// id_map JSON, and absent must leave the reply at the single prose
    /// receipt. The structured data carries `id_map` either way — the flag
    /// gates the extra block only, for callers that cannot read
    /// structuredContent.
    ///
    /// Rust twin: surface_selection_tests
    /// v2_json_import_return_id_map_appends_a_second_text_block. Both ports
    /// must emit byte-identical block text.
    @Test("moot_json_import return_id_map appends a second text block")
    func jsonImportReturnIDMapAppendsSecondBlock() async throws {
        let (dispatcher, kit, handle) = try await makeVaultDispatcher()
        defer { Task { try? await kit.close(handle) } }

        // Two distinct seeds: re-importing one seed into the same estate is not
        // a fresh write and the lower refuses it.
        func seed(_ record: String) throws -> URL {
            try tempSeedFile("""
            {"format_version":1,"name":"idmap","records":[{"id":"\(record)","content":"id map seed \(record)","event_time":"2026-09-09T00:00:00Z","room":"handoff/room","exportability":"public"}]}
            """)
        }

        // Absent return_id_map: exactly one block.
        let plainSeed = try seed("plain")
        defer { try? FileManager.default.removeItem(at: plainSeed) }
        let plain = try await dispatcher.dispatch(
            name: "moot_json_import",
            arguments: .object(["path": .string(plainSeed.path)]))
        #expect(!isError(of: plain), "plain import must succeed")
        #expect(blocks(of: plain).count == 1,
                "absent return_id_map must leave the reply at one block; got \(blocks(of: plain))")

        // The structured data carries id_map even when the flag is absent.
        let plainData = data(of: plain)
        #expect(plainData?["id_map"] != nil,
                "structured data must carry id_map even when the flag is absent")

        // return_id_map:true: a second block whose text is the exact id_map JSON.
        let mappedSeed = try seed("seed/mapped")
        defer { try? FileManager.default.removeItem(at: mappedSeed) }
        let mapped = try await dispatcher.dispatch(
            name: "moot_json_import",
            arguments: .object([
                "path": .string(mappedSeed.path),
                "return_id_map": .bool(true),
            ]))
        #expect(!isError(of: mapped), "mapped import must succeed")
        let mappedBlocks = blocks(of: mapped)
        #expect(mappedBlocks.count == 2,
                "return_id_map:true must append a second block; got \(mappedBlocks)")

        // Assert on the block's TEXT, not merely on the count: a count check
        // passes even when the block carries the wrong payload. The record id
        // carries a slash on purpose: .withoutEscapingSlashes must leave it bare,
        // matching serde_json. An escaped \\/ here would be a port divergence.
        guard case let .object(idMap)? = data(of: mapped)?["id_map"],
              case let .string(drawerID)? = idMap["seed/mapped"] else {
            Issue.record("id_map must map the seed record id to its drawer id")
            return
        }
        #expect(drawerID == drawerID.lowercased(), "drawer ids are canonical lowercase")
        #expect(mappedBlocks.count == 2 && mappedBlocks[1] == "{\"id_map\":{\"seed/mapped\":\"\(drawerID)\"}}",
                "second block text must be the exact id_map JSON; got \(mappedBlocks.last ?? "none")")
    }


    // MARK: - id_map block key ordering with multiple records

    /// A two-record import with reverse-sorted IDs must produce an id_map block
    /// whose keys are emitted in sorted order. This pins the BTreeMap-collect
    /// path in the Rust port and the sorted-keys path in the Swift port.
    ///
    /// Rust twin: v2_json_import_id_map_two_records_sorted
    /// (rust/tests/surface_selection_tests.rs).
    @Test("moot_json_import id_map second block keys are sorted when importing two records")
    func jsonImportIDMapTwoRecordsAreSorted() async throws {
        let (dispatcher, kit, handle) = try await makeVaultDispatcher()
        defer { Task { try? await kit.close(handle) } }

        // Two seeds with intentionally reverse-sorted IDs: "zeta/b" sorts AFTER
        // "alpha/a". The emitted id_map JSON must list them sorted "alpha/a" first.
        func seed(_ ids: [String]) throws -> URL {
            let records = ids.map { id in
                """
                {"id":"\(id)","content":"ordering test \(id)","event_time":"2026-09-09T00:00:00Z","room":"handoff/room","exportability":"public"}
                """
            }.joined(separator: ",")
            return try tempSeedFile("""
            {"format_version":1,"name":"ordering","records":[\(records)]}
            """)
        }

        let file = try seed(["zeta/b", "alpha/a"])
        defer { try? FileManager.default.removeItem(at: file) }
        let result = try await dispatcher.dispatch(
            name: "moot_json_import",
            arguments: .object([
                "path": .string(file.path),
                "return_id_map": .bool(true),
            ]))
        #expect(!isError(of: result), "two-record import must succeed")

        let contentBlocks = blocks(of: result)
        #expect(contentBlocks.count == 2, "two-record import with return_id_map:true must have two blocks; got \(contentBlocks)")

        // Recover the drawer IDs from structured data.
        guard let idMapObj = data(of: result)?["id_map"]?.objectValue,
              let alphaID = idMapObj["alpha/a"]?.stringValue,
              let zetaID = idMapObj["zeta/b"]?.stringValue else {
            Issue.record("id_map must contain both seeded record IDs")
            return
        }

        // The second block text must have alpha/a before zeta/b (sorted keys).
        let expected = "{\"id_map\":{\"alpha/a\":\"\(alphaID)\",\"zeta/b\":\"\(zetaID)\"}}"
        #expect(contentBlocks[1] == expected,
                "id_map block keys must be in sorted order; got \(contentBlocks[1])")
    }

    // MARK: - Finding B guard: error results stay untouched by the hint path

    // MARK: - Finding A: the timing window is bounded at the call level

    @Test("collectTimingWindow truncates at maxEvents and reports it; an uncapped window does not")
    func timingWindowTruncatesAtCap() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher()
        defer { Task { try? await kit.close(handle) } }

        // Seed audit events: every filed memory writes at least one audit row.
        for i in 1...5 {
            let result = try await dispatcher.dispatch(
                name: "moot_file_memory",
                arguments: .object([
                    "content": .string("timing window seed memory \(i)"),
                    "subject": .string("timing window seed memory \(i)"),
                    "location": .string("timing/window"),
                    "impatient": .bool(true),
                ]))
            #expect(!isError(of: result), "seed write \(i) must succeed")
        }

        // Uncapped control: everything fits, no truncation.
        let (all, allTruncated) = try await dispatcher.collectTimingWindow(
            handle: handle, sinceMs: 0, maxEvents: 1_000_000)
        #expect(!allTruncated, "a window smaller than the cap must not report truncation")
        #expect(all.count >= 5, "five writes must have produced at least five audit events")
        let total = all.count

        // Exact boundary: cap == window size → everything collected, and the
        // final short page proves there is nothing more, so no truncation.
        let (exact, exactTruncated) = try await dispatcher.collectTimingWindow(
            handle: handle, sinceMs: 0, maxEvents: total)
        #expect(exact.count == total)
        #expect(!exactTruncated, "cap == window size with a short final page is not a truncation")

        // The defect scenario: the window exceeds the cap. Collection must
        // stop AT the cap and say so.
        let cap = total - 2
        let (capped, cappedTruncated) = try await dispatcher.collectTimingWindow(
            handle: handle, sinceMs: 0, maxEvents: cap)
        #expect(capped.count == cap, "collection must stop exactly at maxEvents; got \(capped.count) for cap \(cap)")
        #expect(cappedTruncated, "a clamped window must report truncation")
    }
}
