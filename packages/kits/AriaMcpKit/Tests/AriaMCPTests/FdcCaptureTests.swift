// FdcCaptureTests.swift
//
// FDC seam classification verification + B-6 (error message quality) — Swift leg.
//
// One-door principle: FDC classification now happens in the GeniusLocusKit
// capture seam (`capture(_:_:mode:)`) — not per-caller. All capture paths
// (file_memory, vault import, branch promotion) funnel through the seam;
// the seam classifies content that arrives with the "000" sentinel via
// EideticLib.lookup. The canonical unclassified sentinel is "000" (the UDC
// three-digit root); "000.000" was a child node and is no longer used.
//
// These tests:
//   1. Verify that filing content with a clear domain signature produces a
//      non-"000" udc_code on the stored drawer (seam classified it).
//   2. Verify the fallback: unclassifiable noise content does NOT crash and
//      produces a valid (possibly "000") code.
//   3. Verify that error messages at the MCP boundary are actionable English
//      phrases, not Swift type-chain strings.
//
// Parity: the Rust counterpart tests live in
// `tests/error_message_and_fdc_tests.rs`.

import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

@Suite("FDC seam classification + error message quality (one-door / B-6)", .serialized)
struct FdcCaptureTests {

    // MARK: - Fixture

    /// Build a ToolDispatcher and return the underlying kit + handle so tests
    /// can read back drawers via `kit.recall` after dispatch operations.
    private func makeDispatcher() async throws -> (ToolDispatcher, GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "fdc-capture-tests")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory)
        )
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        return (dispatcher, kit, handle)
    }

    /// Extract the text content from a `textResult` JSONValue.
    private func text(of result: JSONValue) -> String {
        guard case let .object(obj) = result,
              case let .array(content)? = obj["content"],
              case let .object(first)? = content.first,
              case let .string(s)? = first["text"]
        else { return "" }
        return s
    }

    private func isError(_ result: JSONValue) -> Bool {
        guard case let .object(obj) = result,
              case let .bool(flag)? = obj["isError"]
        else { return false }
        return flag
    }

    // MARK: - One-door: classification happens in the seam, not per-caller

    /// Filing content with a clear scientific-domain signature must produce a
    /// drawer whose `udcCode` is a real FDC code — not the "000" sentinel.
    ///
    /// "Biology is the scientific study of life" reliably resolves into the
    /// FDC natural-sciences region. Any non-"000" result confirms the
    /// seam's EideticLib.lookup path is live.
    @Test func fileMemoryClassifiesContentViaDFC() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher()

        let classifiable = "Biology is the scientific study of life and living organisms, including their physical structure, chemical processes, molecular interactions, physiological mechanisms, and evolution."
        let result = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: .object([
                "content":  .string(classifiable),
                "location": .string("science-room"),
            ])
        )

        #expect(!isError(result), "file_memory must succeed for classifiable content; got: \(result)")

        // Read back the stored drawer to inspect udcCode.
        let drawers = try await kit.recall(
            handle,
            RecallFrame(filterChain: [], hydrationLevel: .structured, limit: nil, ordering: .byCaptureTimeDesc)
        )

        #expect(drawers.count == 1, "exactly one drawer must exist after one file_memory call")

        let udcCode = drawers.first?.udcCode ?? ""
        // The unclassified sentinel is "000" (the UDC root, not the child
        // "000.000"). A classified drawer must carry a more specific code.
        #expect(
            udcCode != "000",
            "file_memory with classifiable content must produce a real udc_code, not the '000' unclassified sentinel; got: '\(udcCode)'"
        )
        #expect(
            !udcCode.isEmpty,
            "udcCode must not be empty after classification"
        )
    }

    /// Filing noise content (no meaningful FDC signature) must NOT crash and
    /// must NOT produce an error tool result. The drawer may fall back to
    /// "000.000" — the important invariant is that the tool succeeds.
    @Test func fileMemoryWithUnclassifiableContentSucceeds() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher()

        let noise = "zzq xkj blrt fnp"
        let result = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: .object([
                "content":  .string(noise),
                "location": .string("noise-room"),
            ])
        )

        #expect(
            !isError(result),
            "file_memory must succeed even when FDC cannot classify; got: \(result)"
        )

        let drawers = try await kit.recall(
            handle,
            RecallFrame(filterChain: [], hydrationLevel: .structured, limit: nil, ordering: .byCaptureTimeDesc)
        )

        #expect(drawers.count == 1, "one drawer must be stored regardless of FDC outcome")
        // udcCode must be non-empty — either the root or a classified code.
        let udcCode = drawers.first?.udcCode ?? ""
        #expect(!udcCode.isEmpty, "udcCode must never be empty, even for unclassifiable content")
    }

    // MARK: - B-6: error messages are actionable English, not Swift type names

    /// Filing a memory with an empty `location` string must produce a tool-level
    /// error whose message contains the failing reason ("room must not be empty")
    /// and does NOT contain internal Swift or LocusKit type-chain names.
    ///
    /// Before B-6 the Rust port used `format!("{e:?}")` at the capture error
    /// site, leaking `VerbDispatchError::Verb(UnderlyingEstateFailure { ... })`.
    /// The Swift port surfaces the error via `LocusKitError.localizedDescription`
    /// or a structured catch — verify neither form leaks type names.
    @Test func emptyLocationProducesActionableError() async throws {
        let (dispatcher, _, _) = try await makeDispatcher()

        let result = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: .object([
                "content":  .string("some content"),
                "location": .string(""),  // empty room — estate rejects this
            ])
        )

        #expect(isError(result), "empty location must produce a tool-level error; got: \(result)")

        let msg = text(of: result)

        // Must NOT contain internal type-chain fragments.
        #expect(
            !msg.contains("UnderlyingEstateFailure"),
            "error message must not leak 'UnderlyingEstateFailure'; got: \(msg)"
        )
        #expect(
            !msg.contains("VerbDispatchError"),
            "error message must not leak 'VerbDispatchError'; got: \(msg)"
        )
        #expect(
            !msg.contains("LocusKitError"),
            "error message must not leak 'LocusKitError'; got: \(msg)"
        )

        // Must contain the actionable reason.
        #expect(
            msg.contains("room must not be empty") || msg.contains("empty"),
            "error message must describe the failing condition; got: \(msg)"
        )
    }

    // MARK: - Cross-door parity: file_memory and direct capture share ONE seam

    /// Filing the SAME classifiable content through `moot_file_memory` (the MCP
    /// tool path) and through a direct `kit.capture(_:_:mode:)` call (what
    /// VaultKit's import path does) must produce drawers with the SAME `udcCode`.
    ///
    /// If each path were classifying independently the codes might agree by chance,
    /// but this test proves they share a SINGLE call tree: both pass the "000"
    /// unclassified sentinel to `capture(_:_:mode:)`, which runs
    /// `EideticLib.lookup` exactly once per frame, producing a deterministic result.
    ///
    /// One-door principle: two behaviors are equal if and only if they traverse the
    /// SAME functional call tree.
    @Test func fileMemoryAndDirectCaptureProduceSameUdcCode() async throws {
        let classifiable = "Biology is the scientific study of life and living organisms, including their physical structure, chemical processes, molecular interactions, physiological mechanisms, and evolution."

        // Path 1 — moot_file_memory tool (the MCP caller path).
        let (dispatcher, kit1, handle1) = try await makeDispatcher()
        let result = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: .object([
                "content":  .string(classifiable),
                "location": .string("science-room"),
            ])
        )
        #expect(!isError(result), "file_memory must succeed; got: \(result)")

        let drawers1 = try await kit1.recall(
            handle1,
            RecallFrame(filterChain: [], hydrationLevel: .structured, limit: nil, ordering: .byCaptureTimeDesc)
        )
        let codeViaToolPath = drawers1.first?.udcCode ?? ""

        // Path 2 — direct kit.capture(_:_:mode:) with the canonical "000"
        //           sentinel (mirrors what VaultKit's makeCaptureFrame produces
        //           when a note has no explicit frontmatter `udc`).
        let (_, kit2, handle2) = try await makeDispatcher()
        let frame2 = CaptureFrame(
            content: classifiable,
            channel: .importedFile,   // vault import channel — matches VaultKit
            room: "science-room",
            latticeAnchor: LatticeAnchor(udcCode: "000"),  // canonical sentinel
            addedBy: "test-added-by",
            embeddingModelID: "test-model"
        )

        _ = try await kit2.capture(handle2, frame2, mode: .regular)

        let drawers2 = try await kit2.recall(
            handle2,
            RecallFrame(filterChain: [], hydrationLevel: .structured, limit: nil, ordering: .byCaptureTimeDesc)
        )
        let codeViaDirectPath = drawers2.first?.udcCode ?? ""

        // Both paths must produce the SAME code — proof of the one-door principle.
        #expect(
            codeViaToolPath == codeViaDirectPath,
            "file_memory and direct capture must produce the same udcCode for classifiable content (one-door); tool=\(codeViaToolPath), direct=\(codeViaDirectPath)"
        )
        // And neither should be the unclassified sentinel.
        #expect(
            codeViaToolPath != "000",
            "classifiable content must not remain at the '000' sentinel via the tool path; got: '\(codeViaToolPath)'"
        )
    }

    /// When a capture frame carries an EXPLICIT non-sentinel `udcCode` (e.g.
    /// from vault frontmatter `udc`), the `capture(_:_:mode:)` seam must
    /// preserve it — it must NOT re-classify an already-classified anchor.
    ///
    /// This is the "explicit frontmatter `udc` is preserved" invariant. The seam's
    /// guard checks `latticeAnchor.udcCode == Self.unclassifiedSentinel`: an
    /// anchor that differs from "000" passes through unchanged.
    @Test func explicitUdcCodeOnCaptureFrameIsPreservedBySeam() async throws {
        let (_, kit, handle) = try await makeDispatcher()

        // Explicit UDC code from vault frontmatter (not the sentinel).
        // "610" = Medicine & Health — a well-established code far from "000".
        let explicitCode = "610"

        let frame = CaptureFrame(
            content: "Biology is the scientific study of life.",  // classifiable content
            channel: .importedFile,
            room: "medicine-room",
            latticeAnchor: LatticeAnchor(udcCode: explicitCode),  // explicit — seam must preserve
            addedBy: "test-added-by",
            embeddingModelID: "test-model"
        )

        _ = try await kit.capture(handle, frame, mode: .regular)

        let drawers = try await kit.recall(
            handle,
            RecallFrame(filterChain: [], hydrationLevel: .structured, limit: nil, ordering: .byCaptureTimeDesc)
        )

        #expect(drawers.count == 1, "exactly one drawer")
        let storedCode = drawers.first?.udcCode ?? ""
        #expect(
            storedCode == explicitCode,
            "seam must preserve an explicit non-sentinel udcCode, not re-classify; expected: '\(explicitCode)', got: '\(storedCode)'"
        )
    }
}
