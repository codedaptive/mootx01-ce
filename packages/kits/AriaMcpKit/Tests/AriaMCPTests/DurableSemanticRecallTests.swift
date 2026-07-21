// DurableSemanticRecallTests.swift
//
// The aria-mcp entry point (AriaMCPMain) lights up semantic recall for the
// durable, explicit-path estate (ARIA_MCP_SQLITE_PATH given) by registering a
// Corpus + VectorStore on the opened handle — mirroring EstateLifecycle.provision's
// .glk wiring while keeping the idempotent `Estate.create + open` path. These
// tests pin two guarantees:
//
//   1. SEMANTIC RECALL LIT — a durable SQLite estate wired the way AriaMCPMain
//      wires it makes impatiently-filed content immediately searchable via the
//      CorpusBm25/vector lane (a bare `open` leaves those lanes dark).
//   2. RESTART IDEMPOTENT — re-opening the SAME on-disk path in a fresh kit
//      (a second server init) still opens and still recalls the persisted
//      content, proving the wiring does not regress durable restarts.
//
// The tests replicate AriaMCPMain.run()'s durable-branch sequence verbatim
// (Estate.create + kit.open, then build + register Corpus + VectorStore) rather
// than spawning the @main entry point, which reads stdin and never returns.

import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import CorpusKit
import VectorKit
import PersistenceKit
import PersistenceKitSQLite
@testable import AriaMCP

@Suite("Durable SQLite estate — semantic recall wiring (aria-mcp entry point)")
struct DurableSemanticRecallTests {

    /// Open a durable SQLite estate exactly the way AriaMCPMain's
    /// ARIA_MCP_SQLITE_PATH branch does: Estate.create + kit.open (idempotent),
    /// then build a Corpus + standalone VectorStore on the same storage and
    /// register both. Returns the wired kit + handle + a dispatcher over them.
    private func openDurableEstate(at path: String)
        async throws -> (ToolDispatcher, GeniusLocusKit, EstateHandle)
    {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "aria-mcp-owner")
        let storage = try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: URL(fileURLWithPath: path), busyTimeout: 5.0)))

        // Idempotent across restarts: Estate.create re-stamps the manifest in
        // place, kit.open re-issues a handle against the existing schema.
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner, identityKeyStore: InMemoryEstateIdentityKeyStore())

        // Mirror AriaMCPMain's semantic-recall wiring: the shared
        // `wireGLKSubstores` seam — the single canonical post-open wiring path
        // `provision` and `mootx01 serve` also use. Shared-content 1.1: it
        // constructs the ATTACHED-mode CorpusContentEngine over the
        // LocusKit-backed adapter (Drawer-ID keyed, no copy lane), registers
        // the engine + its shared VectorStore, and mounts the encode queue.
        // Idempotent, so this re-runs cleanly on an existing on-disk estate.
        try await kit.wireGLKSubstores(for: handle, backingStorage: storage)

        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        return (dispatcher, kit, handle)
    }

    /// Extract the text payload from a `textResult` JSONValue.
    private func text(of result: JSONValue) -> String {
        guard case let .object(obj) = result,
              case let .array(content)? = obj["content"],
              case let .object(first)? = content.first,
              case let .string(s)? = first["text"]
        else { return "" }
        return s
    }

    /// A fresh temp SQLite path under the system temp dir. The caller removes it.
    private func tempEstatePath() -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aria-mcp-durable-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("estate.sqlite3").path
    }

    // MARK: - 1. Semantic recall is lit on the durable estate

    @Test func durableEstateLightsSemanticRecall() async throws {
        let path = tempEstatePath()
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }

        let (dispatcher, kit, handle) = try await openDurableEstate(at: path)
        defer { Task { try? await kit.close(handle) } }

        let content = "peregrine falcon stooping dive raptor velocity record"
        _ = try await dispatcher.runFileMemory([
            "content": .string(content),
            "location": .string("birds"),
            "impatient": .bool(true),
        ])

        // Impatient ingest is inline — the CorpusBm25/vector lane must surface it
        // immediately. On a bare `open` (no Corpus registered) this returns no hit.
        let result = try await dispatcher.runMemorySearch([
            "query": .string("peregrine falcon raptor"),
        ])
        #expect(text(of: result).contains("peregrine falcon"),
            "durable estate must light semantic recall; got: \(text(of: result))")
    }

    // MARK: - 2. Restart idempotency — re-open the same on-disk path

    @Test func durableEstateSurvivesRestartAndStillRecalls() async throws {
        let path = tempEstatePath()
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }

        // First server init: open + wire + file content, then close everything.
        do {
            let (dispatcher, kit, handle) = try await openDurableEstate(at: path)
            let content = "basalt obsidian rhyolite volcanic rock classification notes"
            _ = try await dispatcher.runFileMemory([
                "content": .string(content),
                "location": .string("geology"),
                "impatient": .bool(true),
            ])
            try await kit.close(handle)
        }

        // Second server init over the SAME path: a fresh kit and fresh storage
        // handle re-open the existing on-disk estate. This is the restart case —
        // it must still open and the persisted content must still recall.
        let (dispatcher2, kit2, handle2) = try await openDurableEstate(at: path)
        defer { Task { try? await kit2.close(handle2) } }

        let result = try await dispatcher2.runMemorySearch([
            "query": .string("volcanic rock basalt"),
        ])
        #expect(text(of: result).contains("basalt obsidian"),
            "re-opened durable estate must still recall persisted content; got: \(text(of: result))")
    }
}
