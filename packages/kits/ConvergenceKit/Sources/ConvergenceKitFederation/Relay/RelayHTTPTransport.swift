// RelayHTTPTransport.swift — ConvergenceKitFederation
//
// Synchronous HTTP transport seam for HostedRelay. The synchronous contract
// lets HostedRelay.send and HostedRelay.drain satisfy the non-async Relay
// protocol while keeping the network path fully injectable for tests.
//
// Production implementation: URLSessionRelayHTTPTransport (DispatchSemaphore
// bridge over URLSession.dataTask).
// Test implementation: FakeRelayHTTPTransport (in-memory scripted responses,
// lives in the test target).

import Foundation

// MARK: - RelayHTTPRequest

/// A single synchronous HTTP request for the hosted relay wire protocol.
public struct RelayHTTPRequest: Sendable {
    /// HTTP method: "GET" or "POST".
    public let method: String
    /// Fully-qualified endpoint URL including path and query parameters.
    public let url: URL
    /// HTTP headers to include on the request.
    public let headers: [String: String]
    /// Body bytes for POST requests; nil for GET.
    public let body: Data?

    public init(method: String, url: URL, headers: [String: String], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

// MARK: - RelayHTTPResponse

/// A synchronous HTTP response from the relay server.
public struct RelayHTTPResponse: Sendable {
    /// HTTP status code (e.g. 200, 202, 404).
    public let statusCode: Int
    /// Response body bytes. Empty when the server returned no body.
    public let body: Data

    public init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }
}

// MARK: - RelayHTTPTransport protocol

/// Injectable transport seam for HostedRelay.
///
/// Callers map HTTP-level errors (4xx, 5xx) to domain `SyncError` values.
/// The transport only throws on connection failure, timeout, or TLS error —
/// it never throws based on HTTP status codes.
///
/// Conformers:
/// - `URLSessionRelayHTTPTransport` (production): DispatchSemaphore bridge.
/// - `FakeRelayHTTPTransport` (tests): in-memory scripted responses.
public protocol RelayHTTPTransport: Sendable {
    /// Execute the request synchronously and return the response.
    /// Throws on network error (no response received).
    func execute(_ request: RelayHTTPRequest) throws -> RelayHTTPResponse
}
