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
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "memory-tool-sensitivity-tests")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory)
        )
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner, identityKeyStore: InMemoryEstateIdentityKeyStore())
        return (kit, handle, ToolDispatcher(kit: kit, handle: handle))
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
        try await seed("private restricted secret-value", path: "/memories/private.txt", sensitivity: .restricted, kit: kit, handle: handle)
        try await seed("top secret secret-value", path: "/memories/secret.txt", sensitivity: .secret, kit: kit, handle: handle)

        let listing = text(of: try await dispatcher.dispatch(
            name: "memory",
            arguments: .object(["command": .string("view"), "path": .string("/memories")])
        ))
        #expect(listing.contains("/memories/normal.txt"))
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

        let estate = try await kit.estate(for: handle)
        let drawers = try await estate.allDrawers(hydrationLevel: .full, limit: nil)
        let active = drawers.first { $0.content == "elevated new text" && $0.tombstonedAt == nil }
        let sensitivityRaw = active.map { Int(($0.adjectiveBitmap >> 6) & 0x3F) }
        #expect(sensitivityRaw == AdjectiveSensitivity.elevated.rawValue)
    }
}
