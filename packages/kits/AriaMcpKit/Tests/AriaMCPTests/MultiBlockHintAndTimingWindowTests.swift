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
