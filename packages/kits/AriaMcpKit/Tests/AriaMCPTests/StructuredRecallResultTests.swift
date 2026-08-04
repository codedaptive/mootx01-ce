// StructuredRecallResultTests.swift
//
// MXE-SS: the recall family (moot_memory_search, moot_memory_get,
// moot_recall_shaped, moot_recall_precise) declares an outputSchema and
// returns structuredContent — a typed twin of the text block carrying
// id / room / content / subject per rendered row.
//
// Four contracts under test, in the mission's priority order:
//   1. COMPATIBILITY — the text block keeps its exact pre-change bytes:
//      the structured envelope's content array is identical to
//      textResult's, and the end-to-end reply pins the pre-change line
//      format (header, dense rows, advisory) byte-for-byte.
//   2. PARITY — structuredContent carries id/room/content/subject and
//      they match the text block's values for the same fixture.
//   3. REDACTION (the security test) — a provenance-gated drawer is
//      redacted identically in both blocks: no structured field ever
//      carries what the text withheld. This test FAILS against a naive
//      implementation that populates structured fields from unredacted
//      values (PreciseMatch.content and Drawer.content are both
//      pre-redaction at the emission sites).
//   4. SCHEMA — all four tools declare the SAME outputSchema with the
//      same field names; the Rust twin pins the identical shape
//      (structured_recall_tests.rs), so the two ports cannot drift.
//
// `.serialized`: every case opens live in-memory estates and captures
// directly via `kit.capture`, matching the discipline in
// MemoryGetTests / SearchRedactionTests.

import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

@Suite("Structured recall results (MXE-SS)", .serialized)
struct StructuredRecallResultTests {

    // MARK: - Harness

    private func openEstate(
        in kit: GeniusLocusKit,
        owner: OwnerCredentials
    ) async throws -> EstateHandle {
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory
        ))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        return try await kit.open(
            storage: storage, owner: owner,
            identityKeyStore: InMemoryEstateIdentityKeyStore())
    }

    /// Seed via `kit.capture` with control over the PROVENANCE sensitivity
    /// axis (bits 30-35) — the axis the redaction markers key on. The
    /// adjective axis stays `.normal` so every seeded row is gate-admitted
    /// and reaches the rendering code. Mirrors SearchRedactionTests.seed.
    @discardableResult
    private func seed(
        _ content: String,
        room: String = "structured-recall-tests",
        provenanceSensitivity: LocusKit.Sensitivity = .normal,
        subject: String? = nil,
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
            subject: subject ?? String(content.prefix(120))
        )
        return try await kit.capture(handle, frame)
    }

    private func text(of result: JSONValue) -> String {
        result.objectValue?["content"]?.arrayValue?
            .first?.objectValue?["text"]?.stringValue ?? ""
    }

    /// The structured results array, decoded to per-row dictionaries.
    private func structuredResults(of result: JSONValue) -> [[String: String]] {
        guard let rows = result.objectValue?["structuredContent"]?
            .objectValue?["results"]?.arrayValue else { return [] }
        return rows.map { row in
            var fields: [String: String] = [:]
            for (key, value) in row.objectValue ?? [:] {
                if case .string(let s) = value { fields[key] = s }
            }
            return fields
        }
    }

    /// JSON-encode a full tools/call result for whole-envelope leak checks.
    private func encoded(_ result: JSONValue) throws -> String {
        String(data: try result.encoded(), encoding: .utf8) ?? ""
    }

    // MARK: - 1. Compatibility: the text block keeps its pre-change bytes

    /// The structured envelope's `content` array is byte-identical to the
    /// text-only envelope's for the same text — the ONLY differences are the
    /// added `structuredContent` key and nothing else.
    @Test func structuredEnvelopeKeepsTextBlockIdentical() throws {
        let sample = "found 2 memory(s)\nrow one\nrow two"
        let plain = ToolDispatcher.textResult(sample)
        let structured = ToolDispatcher.structuredTextResult(sample, results: [])
        #expect(plain.objectValue?["content"] == structured.objectValue?["content"],
                "the content block must be byte-identical between the two envelopes")
        #expect(plain.objectValue?["isError"] == structured.objectValue?["isError"])
        #expect(structured.objectValue?["structuredContent"] != nil)
    }

    /// End-to-end: a search over a fixture spanning several drawers renders
    /// the exact pre-change reply — `found N memory(s)` header, one
    /// `DenseRow.render` line per hit, the sensitivity advisory last. The
    /// expected text is reconstructed independently from the same drawers,
    /// so any byte drift in the reply format fails here.
    @Test func searchTextBlockIsByteIdenticalToPreChangeFormat() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "ss-compat")
        let handle = try await openEstate(in: kit, owner: owner)
        defer { Task { try? await kit.close(handle) } }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        var byID: [String: Drawer] = [:]
        for content in [
            "ss-compat-fixture alpha memory body",
            "ss-compat-fixture beta memory body",
            "ss-compat-fixture gamma memory body",
        ] {
            let d = try await seed(content, in: handle, kit: kit)
            byID[d.id] = d
        }

        let result = try await dispatcher.runMemorySearch(
            ["query": .string("ss-compat-fixture")])
        let body = text(of: result)
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        // Header: exact pre-change spelling.
        #expect(lines.first == "found \(byID.count) memory(s)",
                "header must keep the pre-change byte format; got: \(lines.first ?? "")")
        // Every hit line between header and trailer lines is byte-identical
        // to DenseRow.render for that drawer — the pre-change row format.
        let rowLines = lines.dropFirst().filter { $0.contains(" · ") }
        #expect(rowLines.count == byID.count, "one dense row per seeded drawer")
        for line in rowLines {
            let id = String(line.split(separator: " ").first ?? "")
            let drawer = try #require(byID[id], "row id must be a seeded drawer")
            #expect(line == DenseRow.render(drawer),
                    "dense row must be byte-identical to DenseRow.render")
        }
        // The advisory keeps its pre-change spelling and position (last).
        #expect(lines.last == "sensitivity_advisory: a sensitivity tier gate is in effect — "
                + "run `mootx01 unlock private` to include restricted memories, "
                + "`mootx01 unlock secret` for secret memories.")
    }

    // MARK: - 2. Parity: structured fields match the text block's values

    @Test func searchStructuredRowsMatchTextRows() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "ss-parity-search")
        let handle = try await openEstate(in: kit, owner: owner)
        defer { Task { try? await kit.close(handle) } }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let drawer = try await seed(
            "ss-parity-search unique fixture body",
            subject: "parity search subject", in: handle, kit: kit)

        let result = try await dispatcher.runMemorySearch(
            ["query": .string("ss-parity-search")])
        let rows = structuredResults(of: result)
        let row = try #require(rows.first { $0["id"] == drawer.id },
                               "the seeded drawer must have a structured row")
        #expect(row["subject"] == "parity search subject",
                "structured subject must equal the dense row's subject slot")
        #expect(row["room"] == "structured-recall-tests",
                "structured room must be the resolved room display name")
        #expect(row["content"] == "ss-parity-search unique fixture body",
                "search rows carry the full-hydration content")
        // Text and structured cover the same rows.
        let body = text(of: result)
        for r in rows {
            #expect(body.contains(try #require(r["id"])),
                    "every structured row id must appear in the text block")
        }
    }

    @Test func memoryGetFullStructuredRowMatchesRecord() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "ss-parity-get")
        let handle = try await openEstate(in: kit, owner: owner)
        defer { Task { try? await kit.close(handle) } }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let drawer = try await seed(
            "ss-parity-get verbatim body, byte for byte",
            subject: "parity get subject", in: handle, kit: kit)

        let result = try await dispatcher.dispatch(
            name: "moot_memory_get", arguments: .object(["id": .string(drawer.id)]))
        let rows = structuredResults(of: result)
        #expect(rows.count == 1, "single-id get returns exactly one structured row")
        let row = try #require(rows.first)
        #expect(row["id"] == drawer.id)
        #expect(row["room"] == "structured-recall-tests")
        #expect(row["content"] == "ss-parity-get verbatim body, byte for byte",
                "depth:full carries the verbatim body — same as the text's content: block")
        #expect(row["subject"] == "parity get subject")
        // The text block still carries the same values (parity, not replacement).
        let body = text(of: result)
        #expect(body.contains("ss-parity-get verbatim body, byte for byte"))
        #expect(body.contains("subject: parity get subject"))
    }

    /// depth:subject is the travel tier: the text carries no body, so the
    /// structured row must not carry one either — a content field here would
    /// defeat the depth knob's token economy AND disagree with the text.
    @Test func memoryGetDepthSubjectOmitsContent() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "ss-depth-subject")
        let handle = try await openEstate(in: kit, owner: owner)
        defer { Task { try? await kit.close(handle) } }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        // Distinct subject: the default seed subject is the content prefix,
        // which would legitimately surface in the dense row and defeat the
        // leak assertion below.
        let drawer = try await seed(
            "ss-depth-subject body must not travel",
            subject: "travel-tier subject", in: handle, kit: kit)

        let result = try await dispatcher.dispatch(
            name: "moot_memory_get",
            arguments: .object([
                "id": .string(drawer.id), "depth": .string("subject"),
            ]))
        let row = try #require(structuredResults(of: result).first)
        #expect(row["content"] == nil,
                "depth:subject must omit content — the text carries no body at this tier")
        #expect(row["id"] == drawer.id)
        #expect(row["subject"] != nil)
        #expect(!(try encoded(result)).contains("ss-depth-subject body must not travel"),
                "the body must not appear anywhere in the depth:subject envelope")
    }

    /// Batch mode: a missing id gets a "not found:" text line and NO
    /// structured row — the structured block must not differ from the text
    /// on which rows exist.
    @Test func memoryGetBatchOmitsNotFoundRowsFromStructured() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "ss-batch")
        let handle = try await openEstate(in: kit, owner: owner)
        defer { Task { try? await kit.close(handle) } }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let drawer = try await seed("ss-batch present row", in: handle, kit: kit)
        let absent = UUID().uuidString

        let result = try await dispatcher.dispatch(
            name: "moot_memory_get",
            arguments: .object([
                "ids": .array([.string(drawer.id), .string(absent)]),
                "depth": .string("subject"),
            ]))
        let body = text(of: result)
        #expect(body.contains("not found: \(absent)"))
        let rows = structuredResults(of: result)
        #expect(rows.count == 1, "only the found row is in the structured block")
        #expect(rows.first?["id"] == drawer.id)
    }

    @Test func shapedAndPreciseStructuredRowsMatchText() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "ss-recipes")
        let handle = try await openEstate(in: kit, owner: owner)
        defer { Task { try? await kit.close(handle) } }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        _ = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: .object([
                "content": .string("the indemnity was 46 million marks"),
                "subject": .string("indemnity figure"),
                "location": .string("structured-recall-tests"),
            ]))

        for (tool, extraArgs) in [
            ("moot_recall_precise", [String: JSONValue]()),
            ("moot_recall_shaped", ["preset": JSONValue.string("balanced")]),
        ] {
            var args: [String: JSONValue] = [
                "query": .string("the indemnity was 46 million marks"),
                "filter": .string("unconfirmed"),
            ]
            for (k, v) in extraArgs { args[k] = v }
            let result = try await dispatcher.dispatch(
                name: tool, arguments: .object(args))
            let obj = try #require(result.objectValue)
            #expect(obj["isError"]?.boolValue == false, "\(tool) must succeed")
            let rows = structuredResults(of: result)
            #expect(!rows.isEmpty, "\(tool) must carry structured rows")
            let row = try #require(
                rows.first { $0["content"] == "the indemnity was 46 million marks" },
                "\(tool): the seeded row must appear with its content")
            #expect(row["subject"] == "indemnity figure")
            #expect(row["room"] == "structured-recall-tests")
            // The text block renders the same row (by id).
            #expect(text(of: result).contains(try #require(row["id"])))
        }
    }

    // MARK: - 3. Redaction parity (THE security test)

    /// A provenance-RESTRICTED drawer surfaces in search (its adjective axis
    /// is normal) with the redaction marker in place of its subject — and
    /// the structured block must withhold exactly what the text withholds:
    /// subject AND content carry the marker; the body appears NOWHERE in
    /// the whole encoded envelope.
    ///
    /// This test fails against a naive implementation that populates
    /// structured fields from unredacted values: Drawer.content is in hand
    /// (full hydration) at the search emission site, so a naive
    /// `content: drawer.content` emission leaks the body straight into
    /// structuredContent. Confirmed by building exactly that naive variant
    /// (redaction switch bypassed) and watching this test fail — see the
    /// completion report §Part 3 verify.
    @Test func searchRedactsStructuredBlockIdenticallyToText() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "ss-redact-search")
        let handle = try await openEstate(in: kit, owner: owner)
        defer { Task { try? await kit.close(handle) } }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let secretBody = "ss-redact-search classified payload details"
        let drawer = try await seed(
            secretBody,
            provenanceSensitivity: .restricted,
            subject: "classified subject line",
            in: handle, kit: kit)

        let result = try await dispatcher.runMemorySearch(
            ["query": .string("ss-redact-search")])

        // Text: marker in the subject slot (pre-existing behavior).
        #expect(text(of: result).contains(DenseRow.restrictedMarker))
        // Structured: SAME marker in subject and content; never the body.
        let row = try #require(
            structuredResults(of: result).first { $0["id"] == drawer.id })
        #expect(row["subject"] == DenseRow.restrictedMarker,
                "structured subject must carry the text's redaction marker")
        #expect(row["content"] == DenseRow.restrictedMarker,
                "structured content must carry the marker, never the body")
        // The strongest form: the body appears nowhere in the envelope.
        let envelope = try encoded(result)
        #expect(!envelope.contains("classified payload details"),
                "the redacted body must not appear anywhere in the reply")
        #expect(!envelope.contains("classified subject line"),
                "the redacted subject must not appear anywhere in the reply")
    }

    /// Same contract for secret, via the recipe path (moot_recall_precise),
    /// whose PreciseMatch.content is PRE-redaction — the exact leak a naive
    /// implementation ships (Smythe pre-flight WARNING-1).
    @Test func preciseRecallRedactsStructuredBlockForSecretRows() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "ss-redact-precise")
        let handle = try await openEstate(in: kit, owner: owner)
        defer { Task { try? await kit.close(handle) } }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let body = "the launch code is 46 million"
        let drawer = try await seed(
            body,
            provenanceSensitivity: .secret,
            subject: "launch code memo",
            in: handle, kit: kit)

        let result = try await dispatcher.dispatch(
            name: "moot_recall_precise",
            arguments: .object([
                "query": .string("the launch code is 46 million"),
                "filter": .string("unconfirmed"),
            ]))
        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == false)
        let rows = structuredResults(of: result)
        let row = try #require(rows.first { $0["id"] == drawer.id },
                               "the secret row is admissible (adjective normal) and must appear")
        #expect(row["subject"] == DenseRow.secretMarker)
        #expect(row["content"] == DenseRow.secretMarker,
                "PreciseMatch.content is pre-redaction — the marker switch must fire")
        let envelope = try encoded(result)
        #expect(!envelope.contains("launch code"),
                "neither body nor subject of a secret row may appear in the reply")
    }

    /// moot_memory_get: a provenance-gated row is NOT-FOUND — in both
    /// blocks. Single-id throws; batch mode has a "not found:" line and no
    /// structured row.
    @Test func memoryGetKeepsProvenanceGateInBothBlocks() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "ss-redact-get")
        let handle = try await openEstate(in: kit, owner: owner)
        defer { Task { try? await kit.close(handle) } }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let gated = try await seed(
            "ss-redact-get gated body",
            provenanceSensitivity: .secret, in: handle, kit: kit)
        let visible = try await seed("ss-redact-get visible body", in: handle, kit: kit)

        // Single id: thrown not-found, no result envelope at all.
        await #expect(throws: JSONRPCError.self) {
            _ = try await dispatcher.dispatch(
                name: "moot_memory_get",
                arguments: .object(["id": .string(gated.id)]))
        }

        // Batch: text says "not found:", structured omits the row.
        let result = try await dispatcher.dispatch(
            name: "moot_memory_get",
            arguments: .object([
                "ids": .array([.string(gated.id), .string(visible.id)]),
                "depth": .string("distilled"),
            ]))
        #expect(text(of: result).contains("not found: \(gated.id)"))
        let rows = structuredResults(of: result)
        #expect(rows.count == 1)
        #expect(rows.first?["id"] == visible.id)
        #expect(!(try encoded(result)).contains("ss-redact-get gated body"),
                "the gated body must not appear anywhere in the reply")
    }

    // MARK: - 4. Schema: one schema, four tools, both ports

    /// All four in-scope tools declare the identical outputSchema, no other
    /// tool declares one, and the field names are pinned. The Rust twin
    /// (structured_recall_tests.rs::output_schema_shape_is_pinned) pins the
    /// same names, which is what keeps the ports from drifting.
    @Test func recallFamilyDeclaresOneSharedOutputSchema() throws {
        let tools = ToolProjection.tools(environment: [:])
        let family = [
            "moot_memory_search", "moot_memory_get",
            "moot_recall_shaped", "moot_recall_precise",
        ]
        let expected = ToolProjection.recallResultsOutputSchema()
        for name in family {
            let tool = try #require(tools.first { $0.name == name })
            #expect(tool.outputSchema == expected,
                    "\(name) must declare the shared recall-results schema")
        }
        for tool in tools where !family.contains(tool.name) {
            #expect(tool.outputSchema == nil,
                    "\(tool.name) must not declare an output schema (out of scope)")
        }
        // Field-name pin (cross-port fixture): the Rust test asserts these
        // same names against tool_list.rs::recall_results_output_schema.
        let items = expected.objectValue?["properties"]?
            .objectValue?["results"]?
            .objectValue?["items"]?.objectValue
        let fields = items?["properties"]?.objectValue?.keys.sorted()
        #expect(fields == ["content", "id", "room", "subject"])
        #expect(items?["required"]?.arrayValue == [.string("id")])
    }
}
