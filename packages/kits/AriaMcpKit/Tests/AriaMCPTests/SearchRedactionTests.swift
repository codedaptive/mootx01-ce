import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

/// Search-redaction parity fix (Wave 6): `moot_memory_search` must apply the
/// same sensitivity-aware content-preview redaction on BOTH ports. Before
/// this fix, Rust's `run_memory_search` redacted the preview for a
/// PROVENANCE `Sensitivity` (bits 30-35) of Restricted/Secret, while Swift's
/// `runMemorySearch` always showed the raw 120-char preview regardless of
/// provenance sensitivity — a pre-existing port divergence flagged during
/// Wave 4's moot_memory_get work.
///
/// This is deliberately a DIFFERENT axis from `moot_memory_get`'s
/// containment gate (`AdjectiveSensitivity`, bits 6-11, admits/excludes a
/// row from results at all). Here every seeded drawer keeps its adjective
/// sensitivity at the gate-admitting default (`.normal`) so it reliably
/// surfaces in `result.hits` — the test is isolated to the PREVIEW
/// redaction, not the containment gate.
///
/// `.serialized`: opens live in-memory estates and captures directly via
/// `kit.capture`, matching MemoryGetTests'/MultiEstateRoutingTests' discipline.
@Suite("moot_memory_search sensitivity-aware preview redaction", .serialized)
struct SearchRedactionTests {

    // MARK: - Harness

    private func openEstate(
        in kit: GeniusLocusKit,
        owner: OwnerCredentials
    ) async throws -> EstateHandle {
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory
        ))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        return try await kit.open(storage: storage, owner: owner, identityKeyStore: InMemoryEstateIdentityKeyStore())
    }

    /// Seed content directly via `kit.capture`, with full control over the
    /// PROVENANCE sensitivity axis (bits 30-35) the preview redaction reads —
    /// distinct from the adjective-axis `sensitivity` param `moot_memory_get`'s
    /// containment gate checks, which stays `.normal` here (the default) so
    /// every seeded row is gate-admitted and reaches the preview-formatting code.
    @discardableResult
    private func seed(
        _ content: String,
        room: String = "search-redaction-tests",
        provenanceSensitivity: LocusKit.Sensitivity,
        in handle: EstateHandle,
        kit: GeniusLocusKit
    ) async throws -> Drawer {
        let frame = CaptureFrame(
            content: content,
            channel: .typed,
            room: room,
            latticeAnchor: .udc("004"),
            addedBy: "aria-mcp-tests",
            embeddingModelID: "test-model-v1",
            provenanceSensitivity: provenanceSensitivity
        )
        return try await kit.capture(handle, frame)
    }

    private func text(of result: JSONValue) -> String {
        guard case let .object(obj) = result,
              case let .array(content)? = obj["content"],
              case let .object(first)? = content.first,
              case let .string(s)? = first["text"]
        else { return "" }
        return s
    }

    private func searchArgs(_ query: String) -> [String: JSONValue] {
        ["query": .string(query)]
    }

    // MARK: - Tests

    @Test("Restricted provenance sensitivity redacts the preview")
    func restrictedSensitivityRedactsPreview() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "search-redaction-owner")
        let handle = try await openEstate(in: kit, owner: owner)
        defer { Task { try? await kit.close(handle) } }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        try await seed(
            "search-redaction-restricted-marker classified payload details",
            provenanceSensitivity: .restricted, in: handle, kit: kit
        )

        let result = try await dispatcher.runMemorySearch(searchArgs("search-redaction-restricted-marker"))
        let body = text(of: result)
        #expect(body.contains("[sensitivity: restricted — content redacted]"),
                "restricted provenance sensitivity must redact the preview; got: \(body)")
        #expect(!body.contains("classified payload details"),
                "raw content must never leak through a restricted preview; got: \(body)")
    }

    @Test("Secret provenance sensitivity redacts the preview")
    func secretSensitivityRedactsPreview() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "search-redaction-owner")
        let handle = try await openEstate(in: kit, owner: owner)
        defer { Task { try? await kit.close(handle) } }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        try await seed(
            "search-redaction-secret-marker top secret payload details",
            provenanceSensitivity: .secret, in: handle, kit: kit
        )

        let result = try await dispatcher.runMemorySearch(searchArgs("search-redaction-secret-marker"))
        let body = text(of: result)
        #expect(body.contains("[sensitivity: secret — content access requires explicit grant]"),
                "secret provenance sensitivity must redact the preview; got: \(body)")
        #expect(!body.contains("top secret payload details"),
                "raw content must never leak through a secret preview; got: \(body)")
    }

    @Test("Normal provenance sensitivity shows the raw preview (unchanged)")
    func normalSensitivityShowsRawPreview() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "search-redaction-owner")
        let handle = try await openEstate(in: kit, owner: owner)
        defer { Task { try? await kit.close(handle) } }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        try await seed(
            "search-redaction-normal-marker ordinary unclassified content",
            provenanceSensitivity: .normal, in: handle, kit: kit
        )

        let result = try await dispatcher.runMemorySearch(searchArgs("search-redaction-normal-marker"))
        let body = text(of: result)
        #expect(body.contains("ordinary unclassified content"),
                "normal sensitivity must show the raw preview, unchanged; got: \(body)")
        #expect(!body.contains("[sensitivity:"), "normal sensitivity must never show a redaction placeholder")
    }

    @Test("Elevated provenance sensitivity shows the raw preview (unchanged)")
    func elevatedSensitivityShowsRawPreview() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "search-redaction-owner")
        let handle = try await openEstate(in: kit, owner: owner)
        defer { Task { try? await kit.close(handle) } }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        try await seed(
            "search-redaction-elevated-marker bulk export tier content",
            provenanceSensitivity: .elevated, in: handle, kit: kit
        )

        let result = try await dispatcher.runMemorySearch(searchArgs("search-redaction-elevated-marker"))
        let body = text(of: result)
        #expect(body.contains("bulk export tier content"),
                "elevated sensitivity must show the raw preview, unchanged; got: \(body)")
        #expect(!body.contains("[sensitivity:"), "elevated sensitivity must never show a redaction placeholder")
    }
}
