import XCTest
import Foundation
import AriaLexiconLib
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

/// End-to-end coverage for the server: initialize, tools/list, and
/// tools/call against a live in-memory GeniusLocusKit estate. The
/// tests construct the dispatcher directly (no stdio loop) and pass
/// JSON-RPC requests through `ARIA_MCPDispatcher.handle(_:)`.
final class ServerTests: XCTestCase {

    /// Build a dispatcher wired to a fresh in-memory estate. Each test
    /// gets its own kit so state does not leak between cases.
    private func makeDispatcher() async throws -> ARIA_MCPDispatcher {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "aria-mcp-tests")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory)
        )
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        let info = ARIA_MCPDispatcher.ServerInfo(name: "ARIA_MCP", version: "test")
        let tooling = ToolDispatcher(kit: kit, handle: handle)
        return ARIA_MCPDispatcher(info: info, tooling: tooling)
    }

    // MARK: - initialize

    func testInitializeReturnsServerInfo() async throws {
        let dispatcher = try await makeDispatcher()
        let request = JSONRPCRequest(
            id: .integer(1),
            method: "initialize",
            params: .object(["protocolVersion": .string("2024-11-05")])
        )
        let rawResponse = await dispatcher.handle(request)
        let response = try XCTUnwrap(rawResponse)
        guard case .result(let result) = response.payload else {
            XCTFail("initialize returned error: \(response.payload)")
            return
        }
        let object = try XCTUnwrap(result.objectValue)
        XCTAssertEqual(object["protocolVersion"], .string("2024-11-05"))
        let info = try XCTUnwrap(object["serverInfo"]?.objectValue)
        XCTAssertEqual(info["name"], .string("ARIA_MCP"))
        let capabilities = try XCTUnwrap(object["capabilities"]?.objectValue)
        XCTAssertNotNil(capabilities["tools"])
    }

    // MARK: - ping

    func testPingReturnsEmptyObject() async throws {
        let dispatcher = try await makeDispatcher()
        let request = JSONRPCRequest(
            id: .integer(2),
            method: "ping",
            params: nil
        )
        let rawResponse = await dispatcher.handle(request)
        let response = try XCTUnwrap(rawResponse)
        guard case .result(let result) = response.payload else {
            XCTFail("ping returned error")
            return
        }
        XCTAssertEqual(result, .object([:]))
    }

    // MARK: - notifications

    func testNotificationProducesNoResponse() async throws {
        let dispatcher = try await makeDispatcher()
        let notification = JSONRPCRequest(
            id: nil,
            method: "notifications/initialized",
            params: nil
        )
        let response = await dispatcher.handle(notification)
        XCTAssertNil(response)
    }

    // MARK: - tools/list

    func testToolsListReturnsProjectedSurface() async throws {
        let dispatcher = try await makeDispatcher()
        let request = JSONRPCRequest(id: .integer(3), method: "tools/list", params: nil)
        let rawResponse = await dispatcher.handle(request)
        let response = try XCTUnwrap(rawResponse)
        guard case .result(let result) = response.payload else {
            XCTFail("tools/list returned error")
            return
        }
        let object = try XCTUnwrap(result.objectValue)
        let tools = try XCTUnwrap(object["tools"]?.arrayValue)
        XCTAssertFalse(tools.isEmpty)
        let names = tools.compactMap { $0.objectValue?["name"]?.stringValue }
        XCTAssertTrue(names.contains("moot_capture_drawer"))
        XCTAssertTrue(names.contains("moot_drawer_recall"))
        // No substrate-driven verbs on the surface.
        XCTAssertFalse(names.contains(where: { $0.hasPrefix("propose_") }))
        XCTAssertFalse(names.contains(where: { $0.hasPrefix("associate_") }))
    }

    // MARK: - tools/call: capture then recall

    func testCaptureThenRecallRoundTripsThroughTheServer() async throws {
        let dispatcher = try await makeDispatcher()

        // Capture
        let captureRequest = JSONRPCRequest(
            id: .integer(10),
            method: "tools/call",
            params: .object([
                "name": .string("moot_capture_drawer"),
                "arguments": .object([
                    "content": .string("aria-mcp end-to-end test row"),
                    "room": .string("aria-mcp-tests"),
                    "udcCode": .string("000.000"),
                    "addedBy": .string("aria-mcp-tests"),
                    "embeddingModelID": .string("test-model-v1"),
                ]),
            ])
        )
        let captureRaw = await dispatcher.handle(captureRequest)
        let captureResponse = try XCTUnwrap(captureRaw)
        guard case .result(let captureResult) = captureResponse.payload else {
            XCTFail("capture_drawer returned error: \(captureResponse.payload)")
            return
        }
        let captureObject = try XCTUnwrap(captureResult.objectValue)
        XCTAssertEqual(captureObject["isError"], .bool(false))

        // Recall
        let recallRequest = JSONRPCRequest(
            id: .integer(11),
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
            XCTFail("drawer_recall returned error: \(recallResponse.payload)")
            return
        }
        let recallObject = try XCTUnwrap(recallResult.objectValue)
        XCTAssertEqual(recallObject["isError"], .bool(false))
        let content = try XCTUnwrap(recallObject["content"]?.arrayValue.flatMap { $0.first?.objectValue?["text"]?.stringValue })
        XCTAssertTrue(content.contains("aria-mcp end-to-end test row"))
    }

    // MARK: - tools/call: stubbed verb surfaces as result-isError

    func testStubbedVerbReturnsIsErrorResult() async throws {
        let dispatcher = try await makeDispatcher()
        // expunge_drawer reaches the GLK boundary, the boundary
        // checks confirmation, dispatches to LocusKit's stub, and
        // the stub raises notSupportedByEstate. The server must
        // surface that as a tool-call result with isError=true rather
        // than crashing.
        let request = JSONRPCRequest(
            id: .integer(20),
            method: "tools/call",
            params: .object([
                "name": .string("moot_expunge_drawer"),
                "arguments": .object([
                    "rowID": .string("nonexistent"),
                    "reason": .string("test"),
                    "confirmation": .bool(true),
                ]),
            ])
        )
        let rawResponse = await dispatcher.handle(request)
        let response = try XCTUnwrap(rawResponse)
        guard case .result(let result) = response.payload else {
            XCTFail("stubbed expunge returned JSON-RPC error: \(response.payload)")
            return
        }
        let object = try XCTUnwrap(result.objectValue)
        XCTAssertEqual(object["isError"], .bool(true))
    }

    // MARK: - tools/call: unknown tool

    func testUnknownToolReturnsMethodNotFoundError() async throws {
        let dispatcher = try await makeDispatcher()
        let request = JSONRPCRequest(
            id: .integer(30),
            method: "tools/call",
            params: .object([
                "name": .string("imaginary_tool"),
                "arguments": .object([:]),
            ])
        )
        let rawResponse = await dispatcher.handle(request)
        let response = try XCTUnwrap(rawResponse)
        guard case .error(let error) = response.payload else {
            XCTFail("unknown tool did not produce JSON-RPC error")
            return
        }
        XCTAssertEqual(error.code, JSONRPCErrorCode.methodNotFound)
    }

    // MARK: - tools/call: malformed parameters

    func testToolsCallWithoutNameReturnsInvalidParams() async throws {
        let dispatcher = try await makeDispatcher()
        let request = JSONRPCRequest(
            id: .integer(40),
            method: "tools/call",
            params: .object([:])
        )
        let rawResponse = await dispatcher.handle(request)
        let response = try XCTUnwrap(rawResponse)
        guard case .error(let error) = response.payload else {
            XCTFail("missing name did not produce JSON-RPC error")
            return
        }
        XCTAssertEqual(error.code, JSONRPCErrorCode.invalidParams)
    }

    // MARK: - method not found

    func testUnknownMethodReturnsMethodNotFound() async throws {
        let dispatcher = try await makeDispatcher()
        let request = JSONRPCRequest(id: .integer(50), method: "nope/nope", params: nil)
        let rawResponse = await dispatcher.handle(request)
        let response = try XCTUnwrap(rawResponse)
        guard case .error(let error) = response.payload else {
            XCTFail("unknown method did not produce JSON-RPC error")
            return
        }
        XCTAssertEqual(error.code, JSONRPCErrorCode.methodNotFound)
    }
}
