import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

/// `moot_memory_search` provenance gate: a drawer whose PROVENANCE
/// `Sensitivity` (bits 30-35) is Restricted or Secret is excluded from
/// `structuredContent.data.results` entirely. The verdict is computed by
/// `AriaV2GeniusLocusMemoryBackend.provenanceVisible` (normal and elevated
/// only) and applied by `AriaV2MemoryOperations.search(_:)`, which filters on
/// `isAuthorized` before building `results`. Normal and elevated rows pass
/// through with subject and excerpt intact.
///
/// This is deliberately a DIFFERENT axis from the adjective-sensitivity
/// containment gate (`AdjectiveSensitivity`, bits 6-11, applied in the recall
/// filter chain). Every seeded drawer keeps its adjective sensitivity at the
/// gate-admitting default (`.normal`) so it reliably reaches the backend hit
/// list — the test is isolated to provenance exclusion, not the containment
/// gate.
///
/// `.serialized`: opens live in-memory estates and captures directly via
/// `kit.capture`, matching MemoryGetTests'/MultiEstateRoutingTests' discipline.
@Suite("moot_memory_search provenance exclusion", .serialized)
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
    /// PROVENANCE sensitivity axis (bits 30-35) the provenance gate reads —
    /// distinct from the adjective axis the recall filter chain checks, which
    /// stays `.normal` here (the default) so every seeded row is admitted by
    /// recall and reaches the provenance verdict.
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
            provenanceSensitivity: provenanceSensitivity,
            // Subject = capped content: normal/elevated rows surface it in
            // results; restricted/secret rows are excluded from results
            // altogether — exactly what this suite pins.
            subject: String(content.prefix(120))
        )
        return try await kit.capture(handle, frame)
    }

    private func text(of result: JSONValue) -> String {
        guard case let .object(obj) = result,
              case let .array(content)? = obj["content"],
              case let .object(first)? = content.first,
              case let .string(s)? = first["text"]
        else { return "" }
        // v2 compact text is "found N candidate memories"; include subjects and
        // excerpts from structuredContent.data.results so existing assertions work.
        var parts = [s]
        if case let .object(structured)? = obj["structuredContent"],
           case let .object(data)? = structured["data"],
           case let .array(results)? = data["results"] {
            for row in results {
                if case let .object(r) = row {
                    if case let .string(subject)? = r["subject"] { parts.append(subject) }
                    if case let .string(excerpt)? = r["excerpt"] { parts.append(excerpt) }
                }
            }
        }
        return parts.joined(separator: "\n")
    }

    /// Rows in `structuredContent.data.results`; empty when the key is absent.
    private func resultRows(of result: JSONValue) -> [JSONValue] {
        guard case let .object(obj) = result,
              case let .object(structured)? = obj["structuredContent"],
              case let .object(data)? = structured["data"],
              case let .array(results)? = data["results"]
        else { return [] }
        return results
    }

    private func searchArgs(_ query: String) -> [String: JSONValue] {
        ["query": .string(query)]
    }

    // MARK: - Tests

    @Test("Restricted provenance sensitivity excludes the row from results")
    func restrictedProvenanceIsExcludedFromResults() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "search-redaction-owner")
        let handle = try await openEstate(in: kit, owner: owner)
        defer { Task { try? await kit.close(handle) } }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        try await seed(
            "search-redaction-restricted-marker classified payload details",
            provenanceSensitivity: .restricted, in: handle, kit: kit
        )

        let result = try await dispatcher.dispatch(name: "moot_memory_search", arguments: .object(searchArgs("search-redaction-restricted-marker")))
        let body = text(of: result)
        // provenanceVisible admits normal and elevated only, so the restricted
        // row is dropped from `results` by the isAuthorized filter in
        // AriaV2MemoryOperations.search(_:). Positive half: results is empty.
        // Negative half: the raw content is absent from every field returned.
        #expect(resultRows(of: result).isEmpty,
                "a restricted-provenance row must be excluded from results; got: \(body)")
        #expect(!body.contains("classified payload details"),
                "raw content must never appear in results for a restricted-provenance row; got: \(body)")
        // The count is taken after the exclusion, as in the Rust port, so the
        // header cannot reveal that a hidden row matched.
        #expect(body.contains("found 0 candidate memories"),
                "the count must not include the excluded row; got: \(body)")
    }

    @Test("Secret provenance sensitivity excludes the row from results")
    func secretProvenanceIsExcludedFromResults() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "search-redaction-owner")
        let handle = try await openEstate(in: kit, owner: owner)
        defer { Task { try? await kit.close(handle) } }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        try await seed(
            "search-redaction-secret-marker top secret payload details",
            provenanceSensitivity: .secret, in: handle, kit: kit
        )

        let result = try await dispatcher.dispatch(name: "moot_memory_search", arguments: .object(searchArgs("search-redaction-secret-marker")))
        let body = text(of: result)
        // Same provenanceVisible verdict as the restricted case: secret is
        // outside the admitted set, so the row never reaches `results`.
        #expect(resultRows(of: result).isEmpty,
                "a secret-provenance row must be excluded from results; got: \(body)")
        #expect(!body.contains("top secret payload details"),
                "raw content must never appear in results for a secret-provenance row; got: \(body)")
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

        let result = try await dispatcher.dispatch(name: "moot_memory_search", arguments: .object(searchArgs("search-redaction-normal-marker")))
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

        let result = try await dispatcher.dispatch(name: "moot_memory_search", arguments: .object(searchArgs("search-redaction-elevated-marker")))
        let body = text(of: result)
        #expect(body.contains("bulk export tier content"),
                "elevated sensitivity must show the raw preview, unchanged; got: \(body)")
        #expect(!body.contains("[sensitivity:"), "elevated sensitivity must never show a redaction placeholder")
    }
}
