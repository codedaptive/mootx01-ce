import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

/// Input-validation coverage for `moot_file_memory` at the ARIA_MCP
/// boundary (MCP-INT-01 replacement for the old scheme-discriminator tests).
///
/// The old classification-scheme discriminator (`classificationScheme`
/// on `moot_capture_drawer`) is no longer surfaced — the server owns
/// infrastructure fields. This suite covers the equivalent boundary:
/// optional parameters that the AI client MAY supply (sensitivity, kind)
/// must be accepted when valid and must fail out-of-band when the
/// required fields are missing.
///
/// `.serialized`: each case opens a live in-memory estate; preserve
/// one-at-a-time execution to prevent GeniusLocusKit actor contention.
@Suite("File memory input validation", .serialized)
struct SchemeDiscriminatorTests {

    /// Build a dispatcher wired to a fresh in-memory estate.
    private func makeDispatcher() async throws -> ARIA_MCPDispatcher {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "file-memory-validation-tests")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory)
        )
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner, identityKeyStore: InMemoryEstateIdentityKeyStore())
        let info = ARIA_MCPDispatcher.ServerInfo(name: "ARIA_MCP", version: "test")
        let tooling = ToolDispatcher(kit: kit, handle: handle)
        return ARIA_MCPDispatcher(info: info, tooling: tooling)
    }

    /// Issue a `moot_file_memory` tools/call with the given argument object.
    private func fileMemory(
        _ dispatcher: ARIA_MCPDispatcher,
        arguments: [String: JSONValue],
        id: Int64
    ) async throws -> JSONRPCResponse {
        let request = JSONRPCRequest(
            id: .integer(id),
            method: "tools/call",
            params: .object([
                "name": .string("moot_file_memory"),
                "arguments": .object(arguments),
            ])
        )
        let raw = await dispatcher.handle(request)
        return try #require(raw)
    }

    // MARK: - Sensitivity parameter is accepted

    @Test func testElevatedSensitivityIsAccepted() async throws {
        let dispatcher = try await makeDispatcher()
        let response = try await fileMemory(dispatcher, arguments: [
            "content": .string("sensitive content row"),
            "subject": .string("sensitive content row"),
            "location": .string("validation-tests"),
            "sensitivity": .string("elevated"),
        ], id: 100)

        guard case .result(let result) = response.payload else {
            Issue.record("elevated sensitivity returned error: \(response.payload)")
            return
        }
        let object = try #require(result.objectValue)
        #expect(object["isError"] == .bool(false),
            "elevated sensitivity must be accepted by the server")
    }

    // MARK: - kind parameter is accepted

    @Test func testCodeKindIsAccepted() async throws {
        let dispatcher = try await makeDispatcher()
        let response = try await fileMemory(dispatcher, arguments: [
            "content": .string("func main() { }"),
            "subject": .string("func main() { }"),
            "location": .string("validation-tests"),
            "kind": .string("code"),
        ], id: 101)

        guard case .result(let result) = response.payload else {
            Issue.record("code kind returned error: \(response.payload)")
            return
        }
        let object = try #require(result.objectValue)
        #expect(object["isError"] == .bool(false),
            "kind=code must be accepted by the server")
    }

    // MARK: - Base case: minimal required args succeed

    @Test func testMinimalArgsSucceed() async throws {
        let dispatcher = try await makeDispatcher()
        let response = try await fileMemory(dispatcher, arguments: [
            "content": .string("minimal required args row"),
            "subject": .string("minimal required args row"),
            "location": .string("validation-tests"),
        ], id: 102)

        guard case .result(let result) = response.payload else {
            Issue.record("minimal capture returned error: \(response.payload)")
            return
        }
        let object = try #require(result.objectValue)
        #expect(object["isError"] == .bool(false))
        let text = try #require(
            object["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue
        )
        // Response must begin with the "filed memory <id>" confirmation.
        #expect(text.hasPrefix("filed memory "), "expected filed memory confirmation, got: \(text)")
    }

    // MARK: - Missing required `content` is invalidParams

    @Test func testMissingContentReturnsInvalidParams() async throws {
        let dispatcher = try await makeDispatcher()
        let response = try await fileMemory(dispatcher, arguments: [
            "location": .string("validation-tests"),
            // content intentionally omitted
        ], id: 103)

        guard case .error(let error) = response.payload else {
            Issue.record("missing content did not produce JSON-RPC error: \(response.payload)")
            return
        }
        #expect(error.code == JSONRPCErrorCode.invalidParams,
            "missing content must map to invalidParams; got code \(error.code)")
    }

    // MARK: - Missing required `location` is invalidParams

    @Test func testMissingLocationReturnsInvalidParams() async throws {
        let dispatcher = try await makeDispatcher()
        let response = try await fileMemory(dispatcher, arguments: [
            "content": .string("some content without location"),
            "subject": .string("some content without location"),
            // location intentionally omitted
        ], id: 104)

        guard case .error(let error) = response.payload else {
            Issue.record("missing location did not produce JSON-RPC error: \(response.payload)")
            return
        }
        #expect(error.code == JSONRPCErrorCode.invalidParams,
            "missing location must map to invalidParams; got code \(error.code)")
    }
}
