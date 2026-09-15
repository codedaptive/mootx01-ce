// MemoryToolAdapterSensitivityTests.swift
//
// The `memory` tool's sensitivity gate: the adapter is a bulk,
// path-addressed surface with no grant ceremony, so it must match
// BitmapEvaluator's default no-claims recall posture — Normal-tier
// drawers (adjective sensitivity normal/elevated) are visible, restricted
// and secret drawers neither list nor resolve. Edits must carry the source
// drawer's tier forward (a re-capture hardcoding .normal used to DOWNGRADE
// elevated drawers). Adapted from PR #13 with the canonical
// `Drawer.adjectiveSensitivity` accessor instead of a hand-rolled decode.

import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

@Suite("Anthropic memory tool sensitivity gate", .serialized)
struct MemoryToolAdapterSensitivityTests {
    private func makeHarness() async throws -> (GeniusLocusKit, EstateHandle, ToolDispatcher) {
        // The memory tool is opt-in; enable it for these dispatch-behavior
        // tests through the dispatcher's injected environment. Never setenv:
        // the process environment is shared with concurrently running suites
        // (the tool-count contract gates), so a process-global toggle races them.
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "memory-tool-sensitivity-tests")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory)
        )
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner, identityKeyStore: InMemoryEstateIdentityKeyStore())
        return (kit, handle, ToolDispatcher(kit: kit, handle: handle,
                                            environment: ["MOOTX01_MEMORY_TOOL": "1"]))
    }

    @discardableResult
    private func seed(
        _ content: String,
        path: String,
        sensitivity: AdjectiveSensitivity,
        kit: GeniusLocusKit,
        handle: EstateHandle
    ) async throws -> Drawer {
        let room = String(path.dropFirst("/memories/".count))
        let frame = CaptureFrame(
            content: content,
            channel: .actuator,
            room: room,
            latticeAnchor: .udc("000"),
            addedBy: "aria-mcp-tests",
            embeddingModelID: "test-model-v1",
            sensitivity: sensitivity,
            provenanceChannel: .mcpAgent,
            sourceType: .imported,
            wing: "memories"
        )
        return try await kit.capture(handle, frame, mode: .regular)
    }

    private func text(of result: JSONValue) -> String {
        result.objectValue?["content"]?.arrayValue?
            .first?.objectValue?["text"]?.stringValue ?? ""
    }

    @Test("memory view excludes restricted and secret drawers")
    func viewExcludesRestrictedAndSecretDrawers() async throws {
        let (kit, handle, dispatcher) = try await makeHarness()
        try await seed("visible normal", path: "/memories/normal.txt", sensitivity: .normal, kit: kit, handle: handle)
        try await seed("visible elevated", path: "/memories/elevated.txt", sensitivity: .elevated, kit: kit, handle: handle)
        try await seed("private restricted secret-value", path: "/memories/private.txt", sensitivity: .restricted, kit: kit, handle: handle)
        try await seed("top secret secret-value", path: "/memories/secret.txt", sensitivity: .secret, kit: kit, handle: handle)

        let listing = text(of: try await dispatcher.dispatch(
            name: "memory",
            arguments: .object(["command": .string("view"), "path": .string("/memories")])
        ))
        #expect(listing.contains("/memories/normal.txt"))
        #expect(listing.contains("/memories/elevated.txt"),
                "elevated is Normal-tier and must stay visible (no-claims ceiling)")
        #expect(!listing.contains("/memories/private.txt"))
        #expect(!listing.contains("/memories/secret.txt"))

        let restrictedView = text(of: try await dispatcher.dispatch(
            name: "memory",
            arguments: .object(["command": .string("view"), "path": .string("/memories/private.txt")])
        ))
        #expect(restrictedView.contains("does not exist"))
        #expect(!restrictedView.contains("private restricted secret-value"))
    }

    @Test("memory edits preserve elevated sensitivity")
    func editsPreserveElevatedSensitivity() async throws {
        let (kit, handle, dispatcher) = try await makeHarness()
        try await seed("elevated old text", path: "/memories/elevated.txt", sensitivity: .elevated, kit: kit, handle: handle)

        let edit = text(of: try await dispatcher.dispatch(
            name: "memory",
            arguments: .object([
                "command": .string("str_replace"),
                "path": .string("/memories/elevated.txt"),
                "old_str": .string("old"),
                "new_str": .string("new"),
            ])
        ))
        #expect(edit.contains("edited"))

        let drawers = try await kit.allDrawers(
            in: handle, hydrationLevel: .full, limit: nil)
        let active = drawers.first { $0.content == "elevated new text" && $0.tombstonedAt == nil }
        #expect(active?.adjectiveSensitivity == .elevated,
                "str_replace re-capture must carry the source tier, not downgrade to .normal")
    }

    /// Security (Codex b5716d8): the memory tool is opt-in. With the flag
    /// disabled, a hard-coded tools/call to `memory` must be REFUSED at
    /// dispatch — not merely hidden from tools/list — mirroring the vault
    /// disabled-refusal.
    @Test("disabled memory tool refuses dispatch")
    func disabledMemoryToolRefusesDispatch() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "memory-tool-disabled-test")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(
            storage: storage, owner: owner, identityKeyStore: InMemoryEstateIdentityKeyStore())
        let dispatcher = ToolDispatcher(kit: kit, handle: handle,
                                        environment: ["MOOTX01_MEMORY_TOOL": "0"])

        let result = text(of: try await dispatcher.dispatch(
            name: "memory",
            arguments: .object(["command": .string("view"), "path": .string("/memories")])))
        #expect(result.contains("disabled"),
                "a disabled memory tool must refuse a direct tools/call")
    }

    // MARK: - Write side floors at the live grant ceiling

    /// Read the drawer in the `memories` wing whose content contains
    /// `marker` through an explicit sensitivity filter, which suppresses the
    /// default `.elevated` ceiling that hides a restricted or secret row.
    private func filedTier(
        of marker: String, at tier: AdjectiveSensitivity, kit: GeniusLocusKit, handle: EstateHandle
    ) async throws -> AdjectiveSensitivity? {
        let drawers = try await kit.recall(
            handle,
            RecallFrame(filterChain: [.sensitivity(tier)], hydrationLevel: .full, limit: 50))
        return drawers.first { $0.tombstonedAt == nil && $0.content.contains(marker) }?.adjectiveSensitivity
    }

    @Test("memory create under a restricted grant files restricted and names it")
    func createUnderRestrictedGrantFilesRestricted() async throws {
        let (kit, handle, dispatcher) = try await makeHarness()
        await dispatcher.sensitivityUnlockLedger.grantRestricted(now: Date())
        let reply = text(of: try await dispatcher.dispatch(
            name: "memory",
            arguments: .object([
                "command": .string("create"),
                "path": .string("/memories/ceiling-restricted.txt"),
                "file_text": .string("ceiling-restricted body"),
            ])
        ))
        #expect(reply.contains("File created successfully at: /memories/ceiling-restricted.txt"), "got: \(reply)")
        #expect(reply.contains("sensitivity: restricted"), "the reply must name the tier applied; got: \(reply)")
        #expect(try await filedTier(of: "ceiling-restricted body", at: .restricted, kit: kit, handle: handle) == .restricted)
    }

    @Test("memory create under a secret grant files secret and names it")
    func createUnderSecretGrantFilesSecret() async throws {
        let (kit, handle, dispatcher) = try await makeHarness()
        await dispatcher.sensitivityUnlockLedger.grantSecret(now: Date())
        let reply = text(of: try await dispatcher.dispatch(
            name: "memory",
            arguments: .object([
                "command": .string("create"),
                "path": .string("/memories/ceiling-secret.txt"),
                "file_text": .string("ceiling-secret body"),
            ])
        ))
        #expect(reply.contains("sensitivity: secret"), "got: \(reply)")
        #expect(try await filedTier(of: "ceiling-secret body", at: .secret, kit: kit, handle: handle) == .secret)
    }

    @Test("memory create with no grant files normal and the reply is unchanged")
    func createWithNoGrantFilesNormal() async throws {
        let (kit, handle, dispatcher) = try await makeHarness()
        let reply = text(of: try await dispatcher.dispatch(
            name: "memory",
            arguments: .object([
                "command": .string("create"),
                "path": .string("/memories/ceiling-none.txt"),
                "file_text": .string("ceiling-none body"),
            ])
        ))
        #expect(reply == "File created successfully at: /memories/ceiling-none.txt")
        #expect(try await filedTier(of: "ceiling-none body", at: .normal, kit: kit, handle: handle) == .normal)
    }

    @Test("memory str_replace under a restricted grant lifts the edit to restricted")
    func strReplaceUnderRestrictedGrantLiftsToRestricted() async throws {
        let (kit, handle, dispatcher) = try await makeHarness()
        try await seed("old ceiling-edit body", path: "/memories/ceiling-edit.txt", sensitivity: .normal, kit: kit, handle: handle)
        await dispatcher.sensitivityUnlockLedger.grantRestricted(now: Date())
        let reply = text(of: try await dispatcher.dispatch(
            name: "memory",
            arguments: .object([
                "command": .string("str_replace"),
                "path": .string("/memories/ceiling-edit.txt"),
                "old_str": .string("old"),
                "new_str": .string("new"),
            ])
        ))
        #expect(reply.contains("The memory file has been edited."), "got: \(reply)")
        #expect(reply.contains("sensitivity: restricted"), "got: \(reply)")
        #expect(try await filedTier(of: "new ceiling-edit body", at: .restricted, kit: kit, handle: handle) == .restricted)
        // The superseded normal row is withdrawn, so the old body is gone at normal.
        #expect(try await filedTier(of: "old ceiling-edit body", at: .normal, kit: kit, handle: handle) == nil)
    }

    @Test("memory insert under a secret grant lifts the edit to secret")
    func insertUnderSecretGrantLiftsToSecret() async throws {
        let (kit, handle, dispatcher) = try await makeHarness()
        try await seed("line one\nline two", path: "/memories/ceiling-insert.txt", sensitivity: .elevated, kit: kit, handle: handle)
        await dispatcher.sensitivityUnlockLedger.grantSecret(now: Date())
        let reply = text(of: try await dispatcher.dispatch(
            name: "memory",
            arguments: .object([
                "command": .string("insert"),
                "path": .string("/memories/ceiling-insert.txt"),
                "insert_line": .integer(1),
                "insert_text": .string("ceiling-insert middle"),
            ])
        ))
        #expect(reply.contains("sensitivity: secret"), "got: \(reply)")
        #expect(try await filedTier(of: "ceiling-insert middle", at: .secret, kit: kit, handle: handle) == .secret)
    }
}
