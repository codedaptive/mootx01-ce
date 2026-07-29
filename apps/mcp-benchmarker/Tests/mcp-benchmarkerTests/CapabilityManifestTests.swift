import Testing
import Foundation
@testable import mcp_benchmarker

// CapabilityManifestTests.swift — RED tests for the capability-manifest layer
// (SPEC §13). These are conformance-vector seeds: the same inputs must produce
// the same outputs in the Rust leg (BENCHMARKER_OPTIMIZER_CONTRACT.md §4).
//
// Tests cover:
//   - Required-field validation (write+query, provenance enum, technique list).
//   - Unrecognized major schema_version ⇒ refuse the manifest.
//   - Manifest → dispatch-table resolution maps onto verbMap shape.
//   - Performance-neutrality structure: technique tag is on the dispatch entry
//     (attached after timer stops), NOT computed inside the timed window.

// MARK: - Inline fixture helpers

/// Builds a minimal valid manifest JSON string for testing.
/// All required fields are present and correct; individual tests override
/// specific fields to probe validation.
private func minimalManifest(
    schemaVersion: Int = 1,
    productId: String = "test-product",
    provenance: String = "ground-truth-ours",
    transport: String = #"{ "stdio": { "command": "test-server" } }"#,
    role: String = "both",
    writeEntry: String = """
        "write": {
          "tool": "store_memory",
          "args": { "content": "text" },
          "constantArgs": {},
          "result": { "kind": "jsonObjects", "idKey": "id", "contentKey": "text" },
          "technique": ["embedding"]
        }
    """,
    queryEntry: String = """
        "query": {
          "tool": "search_memory",
          "args": { "query": "q" },
          "constantArgs": {},
          "result": { "kind": "jsonObjects", "idKey": "id", "contentKey": "text" },
          "technique": ["bm25", "vector_cosine", "rrf"]
        }
    """
) -> String {
    """
    {
      "schema_version": \(schemaVersion),
      "product": {
        "id": "\(productId)",
        "displayName": "Test Product",
        "provenance": "\(provenance)"
      },
      "transport": \(transport),
      "role": "\(role)",
      "calls": {
        \(writeEntry),
        \(queryEntry)
      }
    }
    """
}

private func decode(_ json: String) throws -> CapabilityManifest {
    guard let data = json.data(using: .utf8) else {
        throw ManifestValidationError.requiredFieldMissing("(invalid UTF-8)")
    }
    return try CapabilityManifest.decode(from: data)
}

// MARK: - Schema-version gating

@Suite struct CapabilityManifestSchemaVersionTests {

    // Known major version (1) decodes cleanly.
    @Test("Known schema_version 1 decodes successfully")
    func knownVersionDecodes() throws {
        let manifest = try decode(minimalManifest(schemaVersion: 1))
        #expect(manifest.schemaVersion == 1)
    }

    // Unrecognized major version MUST refuse (do not guess). SPEC §13.7.
    @Test("Unrecognized major schema_version refuses the manifest")
    func unknownMajorVersionRefuses() {
        #expect(throws: (any Error).self) {
            try decode(minimalManifest(schemaVersion: 99))
        }
    }
}

// MARK: - Required-field validation

@Suite struct CapabilityManifestValidationTests {

    // Full valid manifest decodes without error.
    @Test("Valid minimal manifest decodes without error")
    func validManifestDecodes() throws {
        let manifest = try decode(minimalManifest())
        #expect(manifest.product.id == "test-product")
        #expect(manifest.product.provenance == .groundTruthOurs)
        #expect(manifest.calls["write"] != nil)
        #expect(manifest.calls["query"] != nil)
    }

    // Missing write entry → validation error.
    @Test("Missing calls.write → validation error")
    func missingWriteEntryFails() {
        let json = minimalManifest(
            writeEntry: "",  // no write key
            queryEntry: #""query": { "tool": "s", "args": {}, "constantArgs": {}, "result": { "kind": "jsonObjects", "contentKey": "c" }, "technique": ["bm25"] }"#
        )
        #expect(throws: (any Error).self) {
            try decode(json)
        }
    }

    // Missing query entry → validation error.
    @Test("Missing calls.query → validation error")
    func missingQueryEntryFails() {
        let json = minimalManifest(
            writeEntry: #""write": { "tool": "w", "args": {}, "constantArgs": {}, "result": { "kind": "jsonObjects", "contentKey": "c" }, "technique": ["none"] }"#,
            queryEntry: ""  // no query key
        )
        #expect(throws: (any Error).self) {
            try decode(json)
        }
    }

    // Invalid provenance value → validation error.
    @Test("Unknown provenance value → validation error")
    func invalidProvenanceFails() {
        #expect(throws: (any Error).self) {
            try decode(minimalManifest(provenance: "made-up-value"))
        }
    }

    // All three valid provenance values decode correctly.
    @Test("All three provenance values decode correctly")
    func allProvenanceValuesValid() throws {
        let ours = try decode(minimalManifest(provenance: "ground-truth-ours"))
        #expect(ours.product.provenance == .groundTruthOurs)

        let vendor = try decode(minimalManifest(provenance: "vendor-declared"))
        #expect(vendor.product.provenance == .vendorDeclared)

        let docs = try decode(minimalManifest(provenance: "authored-from-public-docs"))
        #expect(docs.product.provenance == .authoredFromPublicDocs)
    }

    // technique list is empty → validation error. SPEC §13.7.
    @Test("Empty technique list → validation error")
    func emptyTechniqueFails() {
        let json = minimalManifest(
            queryEntry: #""query": { "tool": "s", "args": {}, "constantArgs": {}, "result": { "kind": "jsonObjects", "contentKey": "c" }, "technique": [] }"#
        )
        #expect(throws: (any Error).self) {
            try decode(json)
        }
    }

    // technique token not in the controlled vocabulary → validation error.
    @Test("Unknown technique token → validation error")
    func unknownTechniqueFails() {
        let json = minimalManifest(
            queryEntry: #""query": { "tool": "s", "args": {}, "constantArgs": {}, "result": { "kind": "jsonObjects", "contentKey": "c" }, "technique": ["made-up-technique"] }"#
        )
        #expect(throws: (any Error).self) {
            try decode(json)
        }
    }
}

// MARK: - Dispatch-table resolution (maps onto verbMap shape)

@Suite struct CapabilityManifestResolutionTests {

    // The resolved dispatch table has entries for write and query.
    @Test("Resolved dispatch table has write and query entries")
    func dispatchTableHasWriteAndQuery() throws {
        let manifest = try decode(minimalManifest())
        let table = manifest.resolveDispatchTable()
        #expect(table["write"] != nil)
        #expect(table["query"] != nil)
    }

    // The dispatch entry carries the tool name and technique.
    @Test("Dispatch entry carries the tool name, args, result format, and technique")
    func dispatchEntryContents() throws {
        let manifest = try decode(minimalManifest())
        let table = manifest.resolveDispatchTable()
        let writeEntry = try #require(table["write"])
        #expect(writeEntry.toolName == "store_memory")
        #expect(writeEntry.technique == ["embedding"])
        // Result format must be present (non-nil).
        switch writeEntry.resultFormat {
        case .jsonObjects(let idKey, let contentKey):
            #expect(idKey == "id")
            #expect(contentKey == "text")
        case .mootText:
            Issue.record("expected jsonObjects, got mootText")
        }
    }

    // The query entry carries multiple technique tokens.
    @Test("Query dispatch entry carries multi-technique list")
    func queryDispatchMultiTechnique() throws {
        let manifest = try decode(minimalManifest())
        let table = manifest.resolveDispatchTable()
        let queryEntry = try #require(table["query"])
        #expect(queryEntry.technique == ["bm25", "vector_cosine", "rrf"])
    }

    // unmatched defaults to false when absent.
    @Test("unmatched defaults to false when absent from the manifest")
    func unmatchedDefaultsFalse() throws {
        let manifest = try decode(minimalManifest())
        let table = manifest.resolveDispatchTable()
        let writeEntry = try #require(table["write"])
        #expect(writeEntry.unmatched == false)
    }

    // A custom call type with unmatched:true decodes and resolves correctly.
    @Test("Custom call type with unmatched:true resolves in the dispatch table")
    func customCallTypeUnmatched() throws {
        let json = minimalManifest(
            queryEntry: """
                "query": {
                  "tool": "search_memory",
                  "args": { "query": "q" },
                  "constantArgs": {},
                  "result": { "kind": "jsonObjects", "contentKey": "text" },
                  "technique": ["bm25"]
                },
                "think": {
                  "tool": "think",
                  "args": { "query": "q" },
                  "constantArgs": {},
                  "result": { "kind": "jsonObjects", "contentKey": "text" },
                  "technique": ["graph_traversal", "rrf"],
                  "unmatched": true
                }
            """
        )
        let manifest = try decode(json)
        let table = manifest.resolveDispatchTable()
        let thinkEntry = try #require(table["think"])
        #expect(thinkEntry.unmatched == true)
        #expect(thinkEntry.technique.contains("graph_traversal"))
    }

    // Performance-neutrality: the dispatch entry carries the pre-resolved
    // technique tag — the manifest JSON is NOT re-parsed at call time.
    // This is a structural check: `DispatchEntry.technique` must be a [String],
    // not a lazy closure or a reference back into the manifest JSON.
    @Test("DispatchEntry.technique is a pre-compiled [String], not computed lazily")
    func techniqueIsPrecompiled() throws {
        let manifest = try decode(minimalManifest())
        let table = manifest.resolveDispatchTable()
        let entry = try #require(table["query"])
        // The technique is already a concrete array — we can read it without
        // touching the manifest JSON. This verifies the performance-neutrality
        // contract (SPEC §13.5): no parsing inside the timed window.
        let tech: [String] = entry.technique
        #expect(!tech.isEmpty)
    }
}

// MARK: - Shipped reference manifest (ground-truth)

// Guards the shipped reference manifest at manifests/contender.json: it must
// decode through the real loader and carry the ground-truth technique map we
// authored. This is the conformance reference the Rust leg must also decode identically.
@Suite struct ShippedManifestTests {

    /// Resolves a path relative to the package root from this test file's
    /// location (mirrors main.swift's #filePath-based fixture resolution):
    /// .../Tests/mcp-benchmarkerTests/CapabilityManifestTests.swift → package root.
    private func packageRootURL(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()   // mcp-benchmarkerTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // package root
    }

    @Test("Shipped contender.json decodes and carries its ground-truth technique map")
    func contenderManifestDecodes() throws {
        let url = packageRootURL().appendingPathComponent("manifests/contender.json")
        let data = try Data(contentsOf: url)
        let manifest = try CapabilityManifest.decode(from: data)

        #expect(manifest.schemaVersion == 1)
        #expect(manifest.product.id == "contender")
        #expect(manifest.product.provenance == .groundTruthOurs)

        // All four standard call types are declared.
        #expect(manifest.calls["write"] != nil)
        #expect(manifest.calls["query"] != nil)
        #expect(manifest.calls["list"] != nil)
        #expect(manifest.calls["fetch"] != nil)

        // The hybrid query path is bm25 + vector_cosine (ground truth).
        let query = try #require(manifest.calls["query"])
        #expect(query.tool == "contender_search")
        #expect(query.technique.contains("bm25"))
        #expect(query.technique.contains("vector_cosine"))

        // Write embeds on ingest.
        let write = try #require(manifest.calls["write"])
        #expect(write.tool == "contender_add_drawer")
        #expect(write.technique.contains("embedding"))

        // Resolves into a dispatch table with the pre-compiled tool name.
        let table = manifest.resolveDispatchTable()
        #expect(table["query"]?.toolName == "contender_search")
        #expect(table["query"]?.provenance == .groundTruthOurs)
    }

    @Test("Shipped mem0.json + gbrain.json drafts decode and are tagged authored-from-public-docs")
    func draftManifestsDecode() throws {
        let root = packageRootURL()

        let mem0 = try CapabilityManifest.decode(
            from: try Data(contentsOf: root.appendingPathComponent("manifests/mem0.json")))
        #expect(mem0.product.id == "mem0")
        #expect(mem0.product.provenance == .authoredFromPublicDocs)
        #expect(mem0.calls["write"]?.technique.contains("llm_extraction") == true)
        #expect(mem0.calls["query"]?.tool == "search_memories")

        let gbrain = try CapabilityManifest.decode(
            from: try Data(contentsOf: root.appendingPathComponent("manifests/gbrain.json")))
        #expect(gbrain.product.id == "gbrain")
        #expect(gbrain.product.provenance == .authoredFromPublicDocs)
        #expect(gbrain.calls["query"]?.technique.contains("vector_hnsw") == true)
        // gbrain's `think` is the mode-2 example: a different method, marked unmatched.
        #expect(gbrain.calls["think"]?.unmatched == true)
    }
}
