import XCTest
import Foundation
import AriaLexiconLib
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

/// Coverage for the `capture_drawer` `classificationScheme` discriminator
/// (FUP-F / AUDIT-01 Zone C-1). A caller may declare whether a
/// lattice-anchor code is UDC or MDCC; the boundary validates and
/// accepts the declared scheme, echoing it in the capture confirmation.
/// Omitting the arg preserves the prior default (UDC) behavior so no
/// existing caller breaks.
///
/// The substrate's `LatticeAnchor` stores a bare classification code
/// with no scheme tag (tagging the storage column is a separate
/// migration, out of scope here), so both schemes construct the same
/// anchor; the discriminator's present job is declaration + validation
/// at the ARIA boundary, expressing the dual-scheme model in spec §5.8.
final class SchemeDiscriminatorTests: XCTestCase {

    /// Build a dispatcher wired to a fresh in-memory estate. Mirrors the
    /// harness in `ServerTests` so each case gets isolated state.
    private func makeDispatcher() async throws -> ARIA_MCPDispatcher {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "scheme-discriminator-tests")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory)
        )
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        let info = ARIA_MCPDispatcher.ServerInfo(name: "ARIA_MCP", version: "test")
        let tooling = ToolDispatcher(kit: kit, handle: handle)
        return ARIA_MCPDispatcher(info: info, tooling: tooling)
    }

    /// Issue a `capture_drawer` tools/call with the given argument object.
    private func capture(
        _ dispatcher: ARIA_MCPDispatcher,
        arguments: [String: JSONValue],
        id: Int64
    ) async throws -> JSONRPCResponse {
        let request = JSONRPCRequest(
            id: .integer(id),
            method: "tools/call",
            params: .object([
                "name": .string("moot_capture_drawer"),
                "arguments": .object(arguments),
            ])
        )
        let raw = await dispatcher.handle(request)
        return try XCTUnwrap(raw)
    }

    // MARK: - mdcc scheme routes correctly

    func testCaptureWithMdccSchemeIsAcceptedAndEchoed() async throws {
        let dispatcher = try await makeDispatcher()
        let response = try await capture(dispatcher, arguments: [
            "content": .string("mdcc-tagged anchor row"),
            "room": .string("scheme-tests"),
            "udcCode": .string("500.000"),
            "addedBy": .string("scheme-tests"),
            "embeddingModelID": .string("test-model-v1"),
            "classificationScheme": .string("mdcc"),
        ], id: 100)

        guard case .result(let result) = response.payload else {
            XCTFail("mdcc capture returned error: \(response.payload)")
            return
        }
        let object = try XCTUnwrap(result.objectValue)
        XCTAssertEqual(object["isError"], .bool(false))
        let text = try XCTUnwrap(
            object["content"]?.arrayValue.flatMap { $0.first?.objectValue?["text"]?.stringValue }
        )
        // The validated scheme is echoed so the caller can confirm how
        // its code was interpreted.
        XCTAssertTrue(text.contains("scheme: mdcc"), "expected mdcc scheme echoed, got: \(text)")
    }

    // MARK: - omitting the arg preserves the default (udc) behavior

    func testOmittedSchemeDefaultsToUdcAndRoundTrips() async throws {
        let dispatcher = try await makeDispatcher()

        // Capture without the scheme arg — must behave as today.
        let captureResponse = try await capture(dispatcher, arguments: [
            "content": .string("default-scheme anchor row"),
            "room": .string("scheme-tests"),
            "udcCode": .string("000.000"),
            "addedBy": .string("scheme-tests"),
            "embeddingModelID": .string("test-model-v1"),
        ], id: 101)
        guard case .result(let captureResult) = captureResponse.payload else {
            XCTFail("default capture returned error: \(captureResponse.payload)")
            return
        }
        let captureObject = try XCTUnwrap(captureResult.objectValue)
        XCTAssertEqual(captureObject["isError"], .bool(false))
        let captureText = try XCTUnwrap(
            captureObject["content"]?.arrayValue.flatMap { $0.first?.objectValue?["text"]?.stringValue }
        )
        // Default path resolves to udc.
        XCTAssertTrue(captureText.contains("scheme: udc"), "expected udc default echoed, got: \(captureText)")

        // Recall still returns the row — substrate behavior unchanged.
        let recallRequest = JSONRPCRequest(
            id: .integer(102),
            method: "tools/call",
            params: .object([
                "name": .string("moot_drawer_recall"),
                "arguments": .object([
                    "filter": .string("unconfirmed"),
                    "ordering": .string("byCaptureTimeDesc"),
                ]),
            ])
        )
        let recallRaw = await dispatcher.handle(recallRequest)
        let recallResponse = try XCTUnwrap(recallRaw)
        guard case .result(let recallResult) = recallResponse.payload else {
            XCTFail("recall returned error: \(recallResponse.payload)")
            return
        }
        let recallObject = try XCTUnwrap(recallResult.objectValue)
        let content = try XCTUnwrap(
            recallObject["content"]?.arrayValue.flatMap { $0.first?.objectValue?["text"]?.stringValue }
        )
        XCTAssertTrue(content.contains("default-scheme anchor row"))
    }

    // MARK: - explicit "udc" is accepted

    func testExplicitUdcSchemeIsAccepted() async throws {
        let dispatcher = try await makeDispatcher()
        let response = try await capture(dispatcher, arguments: [
            "content": .string("explicit-udc anchor row"),
            "room": .string("scheme-tests"),
            "udcCode": .string("547"),
            "addedBy": .string("scheme-tests"),
            "embeddingModelID": .string("test-model-v1"),
            "classificationScheme": .string("udc"),
        ], id: 103)
        guard case .result(let result) = response.payload else {
            XCTFail("explicit udc capture returned error: \(response.payload)")
            return
        }
        let object = try XCTUnwrap(result.objectValue)
        XCTAssertEqual(object["isError"], .bool(false))
        let text = try XCTUnwrap(
            object["content"]?.arrayValue.flatMap { $0.first?.objectValue?["text"]?.stringValue }
        )
        XCTAssertTrue(text.contains("scheme: udc"), "expected udc scheme echoed, got: \(text)")
    }

    // MARK: - unknown scheme is rejected

    func testUnknownSchemeReturnsInvalidParams() async throws {
        let dispatcher = try await makeDispatcher()
        let response = try await capture(dispatcher, arguments: [
            "content": .string("bad-scheme anchor row"),
            "room": .string("scheme-tests"),
            "udcCode": .string("000.000"),
            "addedBy": .string("scheme-tests"),
            "embeddingModelID": .string("test-model-v1"),
            "classificationScheme": .string("dewey"),
        ], id: 104)
        guard case .error(let error) = response.payload else {
            XCTFail("unknown scheme did not produce a JSON-RPC error: \(response.payload)")
            return
        }
        XCTAssertEqual(error.code, JSONRPCErrorCode.invalidParams)
    }
}
