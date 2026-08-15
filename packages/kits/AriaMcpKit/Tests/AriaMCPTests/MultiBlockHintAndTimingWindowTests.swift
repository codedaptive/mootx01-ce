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

    @Test("an import with return_id_map that trips a hint keeps BOTH blocks, and the id_map still parses")
    func multiBlockResultSurvivesHint() async throws {
        let (dispatcher, kit, handle) = try await makeVaultDispatcher()
        defer { Task { try? await kit.close(handle) } }
        let url = try tempSeedFile("""
            {"format_version": 1, "name": "hint-survival", "records": [
              {"id": "h1", "content": "hint survival sentinel one", "event_time": "2026-02-01T10:00:00Z", "room": "mcp/hint"},
              {"id": "h2", "content": "hint survival sentinel two", "event_time": "2026-02-01T11:00:00Z", "room": "mcp/hint"}]}
            """)
        defer { try? FileManager.default.removeItem(at: url) }

        // The unrecognized key trips appendUnknownArgsHint on a TWO-block
        // result — exactly the scenario that destroyed the id_map block.
        let result = try await dispatcher.dispatch(
            name: "moot_json_import",
            arguments: .object([
                "path": .string(url.path),
                "return_id_map": .bool(true),
                "totally_fake_arg": .string("should be flagged, not fatal"),
            ]))

        #expect(!isError(of: result), "import with a bogus arg must still succeed")
        let b = blocks(of: result)
        #expect(b.count == 2, "receipt block AND id_map block must both survive the hint; got \(b.count) block(s)")

        let receipt = try #require(b.first)
        #expect(receipt.contains("json import complete"), "block 0 is the prose receipt")
        #expect(receipt.contains("hint: unrecognized argument(s) ignored: totally_fake_arg"),
                "the hint lands on the prose block")

        // The trailing block must still be one whole parseable JSON object —
        // no hint text may leak into it.
        let mapText = try #require(b.last)
        #expect(!mapText.contains("hint:"), "no hint line may be appended to the JSON block")
        let parsed = try JSONSerialization.jsonObject(with: Data(mapText.utf8))
        let map = try #require((parsed as? [String: Any])?["id_map"] as? [String: Any],
                               "id_map block must parse as a JSON object")
        #expect(map.count == 2, "one id_map entry per seeded record")
        #expect(map["h1"] != nil && map["h2"] != nil)
    }

    // MARK: - Finding B guard: error results stay untouched by the hint path

    @Test("an error result with an unrecognized arg is returned unchanged — no hint appended")
    func errorResultWithUnknownArgUnchanged() async throws {
        let (dispatcher, kit, handle) = try await makeVaultDispatcher()
        defer { Task { try? await kit.close(handle) } }

        // Nonexistent seed path → tool-level errorResult (isError: true).
        // The bogus arg would trip the hint on a success result; on an error
        // result the hint machinery must leave the message alone.
        let result = try await dispatcher.dispatch(
            name: "moot_json_import",
            arguments: .object([
                "path": .string("/nonexistent/at01-no-such-seed.json"),
                "totally_fake_arg": .string("must not be appended"),
            ]))

        #expect(isError(of: result), "a missing seed file is a tool-level error result")
        let b = blocks(of: result)
        #expect(b.count == 1, "error results are single-block")
        #expect(!(b.first ?? "").contains("hint:"),
                "error results must not be augmented with hint lines")
    }

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

    @Test("moot_timing_report on a small estate stays under the cap: usable watermark, no truncation line")
    func timingReportSmallEstateShapeUnchanged() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher()
        defer { Task { try? await kit.close(handle) } }

        _ = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: .object([
                "content": .string("timing report shape seed"),
                "subject": .string("timing report shape seed"),
                "location": .string("timing/shape"),
                "impatient": .bool(true),
            ]))

        let result = try await dispatcher.dispatch(
            name: "moot_timing_report",
            arguments: .object(["since_ms": .integer(0)]))

        #expect(!isError(of: result))
        let text = blocks(of: result).first ?? ""
        #expect(text.contains("watermark_ms:"), "the paging watermark line must be present")
        #expect(!text.contains("window: truncated"),
                "an under-cap window must keep the pre-cap report shape byte-identical")
    }
}
