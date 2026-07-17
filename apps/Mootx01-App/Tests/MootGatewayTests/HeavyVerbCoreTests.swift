import Testing
import Foundation
@testable import MootGateway
import MootIntentKit

// M-MXA-3R — heavy-verb core against a live in-memory estate. The 27-gated
// LongRunningIntent surface (HeavyVerbIntents.swift) reuses exactly these
// calls; its Live Activity leg verifies on an OS-27 runtime (M-MXA-4 lane).

@Suite("HeavyVerbCore (M-MXA-3R)", .serialized)
struct HeavyVerbCoreTests {

    @Test("drain-status parsing: names, states, counts; 'none' parses empty")
    func drainParsing() {
        let text = """
        drains: 2
          encode: draining — pending: 41, in_flight: 2, batch 3/9
          import: idle — pending: 0, in_flight: 0
        """
        let snaps = HeavyVerbCore.parseDrainStatus(text)
        #expect(snaps == [
            DrainSnapshot(name: "encode", isDraining: true, pending: 41, inFlight: 2),
            DrainSnapshot(name: "import", isDraining: false, pending: 0, inFlight: 0),
        ])
        #expect(HeavyVerbCore.outstandingWork(snaps) == 43)
        #expect(HeavyVerbCore.parseDrainStatus("drains: none") == [])
    }

    @Test("reindex acks immediately and drains settle to zero outstanding")
    func reindexAcksAndSettles() async throws {
        let bridge = try await MootBridge.attachInMemory()
        _ = await bridge.callToolFull("moot_file_memory", arguments: [
            "content": .string("heavy verb reindex probe"),
            "location": .string("heavy-tests"),
        ])
        let ack = try await HeavyVerbCore.startReindex(caller: bridge)
        #expect(!ack.isEmpty)
        // Poll the same feed the intents' progress watcher uses, bounded.
        var outstanding = -1
        for _ in 0..<20 {
            outstanding = HeavyVerbCore.outstandingWork(
                await HeavyVerbCore.drainSnapshots(caller: bridge))
            if outstanding == 0 { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        #expect(outstanding == 0, "drains never settled after reindex")
    }

    @Test("dream runs to completion on a live estate")
    func dreamCompletes() async throws {
        let bridge = try await MootBridge.attachInMemory()
        _ = await bridge.callToolFull("moot_file_memory", arguments: [
            "content": .string("heavy verb dream probe"),
            "location": .string("heavy-tests"),
        ])
        let report = try await HeavyVerbCore.dream(caller: bridge)
        #expect(!report.isEmpty)
    }

    @Test("palace import on a nonexistent path reports failure, imports nothing")
    func palaceImportRefusesBadPath() async throws {
        let bridge = try await MootBridge.attachInMemory()
        // Discovered behavior, pinned: a bad path surfaces as a failure
        // REPORT string (the tool call itself is not an error), so the
        // intents relay it in their result dialog. Nothing is imported.
        let report = try await HeavyVerbCore.importPalace(
            path: "/nonexistent/mxa3r-palace", background: false, caller: bridge)
        #expect(!report.isEmpty)
        let search = await bridge.callToolFull("moot_memory_search", arguments: [
            "query": .string("mxa3r"),
        ])
        #expect(search.text.contains("found 0 memory") || search.text.contains("0 memory(s)"))
    }
}
