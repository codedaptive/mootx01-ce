// FdcCaptureTests.swift
//
// BUG-2 (FDC-on-capture) verification + B-6 (error message quality) — Swift leg.
//
// BUG-2: `moot_file_memory` was filing every drawer at UDC "000.000" (the
// general-knowledge root) because `runFileMemory` hardcoded `defaultLatticeAnchor`.
// The fix calls `FDC.encodeAnchor(content)` from LatticeLib before constructing the
// CaptureFrame so classifiable content gets a real UDC code.
//
// These tests:
//   1. Verify that filing content with a clear domain signature produces a
//      non-"000.000" udc_code on the stored drawer.
//   2. Verify the fallback: unclassifiable noise content does NOT crash and
//      produces a valid (possibly "000.000") code.
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

@Suite("FDC-on-capture + error message quality (B-6 / BUG-2)", .serialized)
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

    // MARK: - BUG-2: FDC classification path fires on moot_file_memory

    /// Filing content with a clear scientific-domain signature must produce a
    /// drawer whose `udcCode` is a real FDC code — not the "000.000" root.
    ///
    /// "Biology is the scientific study of life" reliably resolves into the
    /// FDC natural-sciences region. Any non-"000.000" result confirms the
    /// `FDC.encodeAnchor` path is live in `runFileMemory`.
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
        #expect(
            udcCode != "000.000",
            "file_memory with classifiable content must produce a real udc_code, not '000.000'; got: '\(udcCode)'"
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
}
