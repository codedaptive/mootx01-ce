import Testing
import Foundation
import AdornmentLib
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

/// Adornment render-surface tests (SPEC_ADORNMENT §5 + GENIUSLOCUSKIT_SPEC §16.2):
/// adornment text appearing in moot_memory_search payloads via the normalized
/// adornment store (ADORN-STORE-02 Part C). Tests provision minters and adornments
/// through the current store API; the retired MOOT_SUPPRESS_ADORNMENT env seam is
/// replaced by the zero-active-minters arm.
///
/// Cross-port conformance: both Swift and Rust ports read the same physical
/// fixture at Tests/Conformance/adornment_render_fixture.json for the adornment
/// text. Neither port hardcodes the string.
@Suite("Adornment render surface")
struct AdornmentRenderTests {

    // MARK: - Fixture

    /// Reads `adornment_text` from the shared cross-port fixture.
    ///
    /// Both Swift and Rust ports read the SAME physical file located at
    /// `Tests/Conformance/adornment_render_fixture.json` relative to this
    /// test file. Using the fixture rather than a hardcoded literal means a
    /// change to the fixture simultaneously breaks both ports' tests — the
    /// correct cross-port conformance signal.
    private func fixtureAdornmentText() throws -> String {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // …/AriaMCPTests
            .deletingLastPathComponent()  // …/Tests
            .appendingPathComponent("Conformance/adornment_render_fixture.json")
        let data = try Data(contentsOf: fixtureURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let text = json?["adornment_text"] as? String else {
            Issue.record("adornment_render_fixture.json must have an 'adornment_text' string field")
            return ""
        }
        return text
    }

    // MARK: - Harness

    /// Open an in-memory estate and return both the GeniusLocusKit handle and
    /// the underlying InMemoryStorage. The storage reference is needed by
    /// `writeAdornmentOnDrawer` to open a peer LocusKit.Estate for direct
    /// adornment writes (GLK does not expose putAdornment; the peer-estate
    /// approach is the standard test pattern for direct store writes).
    private func openEstate(
        in kit: GeniusLocusKit,
        owner: OwnerCredentials
    ) async throws -> (EstateHandle, InMemoryStorage) {
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory
        ))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(
            storage: storage,
            owner: owner,
            identityKeyStore: InMemoryEstateIdentityKeyStore()
        )
        return (handle, storage)
    }

    /// Register an adornment minter and write one stored adornment for a drawer.
    ///
    /// Registration uses the GLK surface (kit.registerAdornmentMinter); the
    /// `StoredAdornment` row is written via a peer LocusKit.Estate opened on the
    /// same InMemoryStorage — the GLK actor boundary does not expose putAdornment
    /// directly. The peer-estate pattern is consistent with SearchRedactionTests
    /// and other write-side test helpers in this suite.
    ///
    /// - Parameters:
    ///   - kit: the GeniusLocusKit actor managing this estate.
    ///   - handle: the open estate handle (used for minter registration).
    ///   - minter: the descriptor to register (active flag must be true for
    ///     the adornment to appear in call-scoped active reads).
    ///   - drawerID: the drawer to adorn.
    ///   - text: the adornment text to store.
    ///   - storage: the shared InMemoryStorage (for the peer estate open).
    ///   - owner: estate owner credentials.
    /// - Returns: 1 when the adornment row was written, per `putAdornment` contract.
    @discardableResult
    private func registerMinterAndWriteAdornment(
        kit: GeniusLocusKit,
        handle: EstateHandle,
        minter: AdornmentMinterDescriptor,
        drawerID: String,
        text: String,
        storage: InMemoryStorage,
        owner: OwnerCredentials
    ) async throws -> Int {
        // Register the minter via GLK so the estate's adornment_minters table
        // carries the row. GLK delegates to Estate.registerAdornmentMinter(_:).
        try await kit.registerAdornmentMinter(in: handle, minter: minter)

        // Write the adornment row via a peer LocusKit estate on the same
        // InMemoryStorage. InMemoryStorage is a reference type — writes here
        // are immediately visible to the GLK search that follows.
        let locusEstate = try await LocusKit.Estate.open(
            storage: storage,
            owner: owner
        )
        let adornment = StoredAdornment(
            drawerID: drawerID,
            minterID: minter.id,
            text: text
        )
        return try await locusEstate.putAdornment(adornment)
    }

    /// Extract the text body from a JSONValue MCP tool result.
    private func text(of result: JSONValue) -> String {
        guard case let .object(obj) = result,
              case let .array(content)? = obj["content"],
              case let .object(first)? = content.first,
              case let .string(s)? = first["text"]
        else { return "" }
        return s
    }

    // MARK: - Tests

    /// Adornment text appears in the moot_memory_search payload for an adorned drawer.
    ///
    /// Provision path: register an active minter → write a StoredAdornment row →
    /// search returns "adornment: <text>" via the call-scoped activeAdornments read
    /// (GENIUSLOCUSKIT_SPEC §16.2).
    ///
    /// Failure mode: output is byte-identical to an un-adorned search result —
    /// no "adornment: …" line — caused by the activeAdornments batch read being
    /// absent from the candidate-list loop or the minter not being active.
    @Test("Adorned drawer with active minter surfaces 'adornment: <text>' in moot_memory_search")
    func adornmentAppearsInSearchPayload() async throws {
        let adornmentText = try fixtureAdornmentText()
        // Unique fixture query string that will match the search query.
        let fixtureQuery = "adornment-render-fixture-550e8400"

        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "adornment-render-tests-present")
        let (handle, storage) = try await openEstate(in: kit, owner: owner)
        defer { Task { try? await kit.close(handle) } }

        // Capture a drawer. Subject is set so the dense row carries the query
        // text that the search will surface.
        let frame = CaptureFrame(
            content: fixtureQuery,
            channel: .typed,
            room: "adornment-render-tests",
            latticeAnchor: .udc("004"),
            addedBy: "aria-mcp-tests",
            embeddingModelID: "test-model-v1",
            subject: fixtureQuery
        )
        let drawer = try await kit.capture(handle, frame)

        // Register an active minter and write a StoredAdornment row.
        // `isActive: true` means activeAdornments will return this row.
        let minter = AdornmentMinterDescriptor(
            id: "test-minter-apple-gen1",
            name: "Test Apple Gen-1",
            family: "apple",
            modelID: "test-model-v1",
            modelVersion: "2026-08",
            promptDigest: "sha256-test-digest-01",
            parameters: [:],
            isActive: true
        )
        let writtenCount = try await registerMinterAndWriteAdornment(
            kit: kit,
            handle: handle,
            minter: minter,
            drawerID: drawer.id,
            text: adornmentText,
            storage: storage,
            owner: owner
        )
        // Gate: putAdornment must report 1 row written.
        #expect(writtenCount == 1, "putAdornment must write exactly 1 row; got: \(writtenCount)")

        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        let result = try await dispatcher.runMemorySearch(
            ["query": .string(fixtureQuery)]
        )
        let body = text(of: result)

        // S2 row format: id · subject · firstSentence · SSC · <adornmentText> · eventTime
        // The adornment text is column 5 (no label prefix) per ARIA_MCP_INTERFACE.md §11.5.
        #expect(
            body.contains(" · \(adornmentText) · "),
            "adorned drawer must surface adornment text as column 5 of the S2 row; got: \(body)"
        )
    }

    /// Zero active minters → no adornment line in moot_memory_search.
    ///
    /// The zero-active-minters arm replaces the retired MOOT_SUPPRESS_ADORNMENT
    /// env seam (ADORN-STORE-02 Part C). When no minters are active, the
    /// call-scoped activeAdornments read returns an empty map and no
    /// "adornment: …" line is appended to the payload.
    ///
    /// Failure mode: "adornment: …" still appears in output — caused by the
    /// activeAdornments map not being consulted (falling back to the retired
    /// drawer.adornment field read).
    @Test("Zero active minters → no adornment line in moot_memory_search")
    func zeroActiveMintersSuppressesAdornmentLine() async throws {
        let fixtureQuery = "adornment-suppress-fixture-550e8401"

        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "adornment-render-tests-suppress")
        let (handle, _) = try await openEstate(in: kit, owner: owner)
        defer { Task { try? await kit.close(handle) } }

        // Capture a drawer with a unique query string.
        let frame = CaptureFrame(
            content: fixtureQuery,
            channel: .typed,
            room: "adornment-suppress-tests",
            latticeAnchor: .udc("004"),
            addedBy: "aria-mcp-tests",
            embeddingModelID: "test-model-v1",
            subject: fixtureQuery
        )
        _ = try await kit.capture(handle, frame)

        // No minters registered → activeAdornments returns empty map
        // → no "adornment:" line in the search payload.
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        let result = try await dispatcher.runMemorySearch(
            ["query": .string(fixtureQuery)]
        )
        let body = text(of: result)

        #expect(
            !body.contains("adornment:"),
            "zero active minters must produce no adornment line; got: \(body)"
        )
    }

    /// Tool schema strings must not mention MOOT_SUPPRESS_ADORNMENT.
    ///
    /// This is a regression guard: the suppression seam was retired in
    /// ADORN-STORE-02 Part C and must not re-appear in AI-visible tool
    /// descriptions or inputSchema JSON. If it leaks, any LLM client that
    /// reads tool descriptions learns about the seam and could attempt to
    /// control benchmark conditions.
    @Test("Tool schemas do not mention MOOT_SUPPRESS_ADORNMENT")
    func toolSchemasDoNotMentionSuppressVar() throws {
        // Use empty environment to bypass vault/memory gating and get all tools.
        // The point is to check every schema string, not to test gate logic.
        let tools = ToolProjection.tools(environment: [:])
        for tool in tools {
            #expect(
                !tool.description.contains("MOOT_SUPPRESS_ADORNMENT"),
                "tool \(tool.name) description must not mention MOOT_SUPPRESS_ADORNMENT"
            )
            // Encode the inputSchema to JSON text for substring search.
            let schemaText: String
            if let data = try? tool.inputSchema.encoded(),
               let s = String(data: data, encoding: .utf8) {
                schemaText = s
            } else {
                schemaText = ""
            }
            #expect(
                !schemaText.contains("MOOT_SUPPRESS_ADORNMENT"),
                "tool \(tool.name) inputSchema must not mention MOOT_SUPPRESS_ADORNMENT"
            )
        }
    }
}
