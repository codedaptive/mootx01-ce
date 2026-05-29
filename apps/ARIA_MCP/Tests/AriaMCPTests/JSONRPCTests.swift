import XCTest
@testable import AriaMCP

/// Round-trip tests for the JSON-RPC envelope decoding and encoding.
///
/// Cover the shapes Part 1 must accept: a normal request with an id,
/// a notification (no id), a malformed envelope. These tests do not
/// reach the dispatcher; they pin the wire types alone.
final class JSONRPCTests: XCTestCase {

    func testDecodeRequestWithStringID() throws {
        let frame: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "id": .string("req-1"),
            "method": .string("ping"),
        ])
        let request = try XCTUnwrap(JSONRPCRequest.decode(frame))
        XCTAssertEqual(request.method, "ping")
        XCTAssertEqual(request.id, .string("req-1"))
        XCTAssertFalse(request.isNotification)
    }

    func testDecodeNotificationHasNoID() throws {
        let frame: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "method": .string("notifications/initialized"),
        ])
        let request = try XCTUnwrap(JSONRPCRequest.decode(frame))
        XCTAssertTrue(request.isNotification)
        XCTAssertNil(request.id)
    }

    func testDecodeRejectsWrongVersion() {
        let frame: JSONValue = .object([
            "jsonrpc": .string("1.0"),
            "id": .integer(1),
            "method": .string("ping"),
        ])
        XCTAssertNil(JSONRPCRequest.decode(frame))
    }

    func testResponseEncodingPreservesIDShape() throws {
        let response = JSONRPCResponse.ok(.integer(42), .object(["ok": .bool(true)]))
        let encoded = response.asJSONValue
        let object = try XCTUnwrap(encoded.objectValue)
        XCTAssertEqual(object["id"], .integer(42))
        XCTAssertEqual(object["jsonrpc"], .string("2.0"))
        XCTAssertEqual(object["result"], .object(["ok": .bool(true)]))
    }

    func testErrorResponseCarriesCodeAndMessage() throws {
        let response = JSONRPCResponse.failure(
            .null,
            JSONRPCError(code: JSONRPCErrorCode.methodNotFound, message: "no such method")
        )
        let object = try XCTUnwrap(response.asJSONValue.objectValue)
        XCTAssertEqual(object["id"], .null)
        let errorObject = try XCTUnwrap(object["error"]?.objectValue)
        XCTAssertEqual(errorObject["code"], .integer(Int64(JSONRPCErrorCode.methodNotFound)))
        XCTAssertEqual(errorObject["message"], .string("no such method"))
    }

    func testJSONValueRoundTrip() throws {
        let value: JSONValue = .object([
            "name": .string("aria-mcp"),
            "count": .integer(7),
            "ratio": .double(0.5),
            "flag": .bool(true),
            "absent": .null,
            "items": .array([.string("a"), .string("b")]),
        ])
        let encoded = try value.encoded()
        let decoded = try JSONValue.parse(encoded)
        XCTAssertEqual(decoded, value)
    }
}
