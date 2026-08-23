import Foundation
import AriaMCPWire   // JSONRPCRequest, JSONRPCResponse, JSONValue

// MARK: - GatewayTransport  (A2 — transport seam)
//
// Every adapter in this app drives the dispatcher in-process. A real LAN
// surface (Siri reaching the MOOT over the network, Claude Desktop via
// mcp-remote) needs a transport between the client and the dispatcher. This
// file defines:
//   - GatewayTransport: the one-send protocol both transports conform to.
//   - InProcessTransport: the embedded path (no wire, direct dispatcher call).
//   - HTTPTransport: the real loopback-HTTP transport to a running resident daemon
//     (ARIA_MCP_SPEC §5): URLSession POST of a JSON-RPC 2.0 frame to the daemon's
//     127.0.0.1 endpoint, decode the JSON-RPC response from the body.
//
// The server half (HTTPServer in ARIA_MCP) and this client half speak
// byte-identical JSON-RPC frames — only the framing differs (HTTP body vs
// newline-delimited stdio). The wire contract is:
//   - POST to the configured loopback endpoint (default path "/")
//   - Body: JSON-RPC 2.0 object {"jsonrpc":"2.0","id":<id>,"method":<m>,"params":<p>}
//   - Content-Type: application/json
//   - No Origin header (native MCP clients send none; the server allows absent origins)
//   - Response: HTTP 200 with a JSON-RPC response body for tool calls;
//               HTTP 202 with empty body for notifications (no id → no reply)
//   - Error responses (non-2xx) name the transport condition, not a JSON-RPC one

/// A transport carries one JSON-RPC request to a dispatcher and returns the
/// response. The dispatcher is identical across transports (ARIA_MCP_SPEC §5:
/// "only JSON-RPC crosses the wire … the handlers do not change with the
/// transport").
public protocol GatewayTransport: Sendable {
    func send(_ request: JSONRPCRequest) async throws -> JSONRPCResponse?
}

/// Stamps a per-request authorization onto an outbound HTTP frame.
///
/// The resident daemon authenticates first-party clients
/// (`DaemonCapability.authenticatedFirstParty`). How it does so — a session
/// header, a per-request signature — is the daemon provider's business, not the
/// transport's, so the transport takes a closure and asks it to return the
/// request it should actually send.
///
/// It is `async` because a real credential is not sitting in memory: it comes
/// from the Keychain, or from a session that may need refreshing, and both are
/// awaits. It is `throws` because a client that cannot authorize a request must
/// fail the request rather than send it bare.
///
/// The closure receives the fully-built request (URL, method, body, and
/// Content-Type already set) and returns the request to send. Returning the
/// input unchanged is a valid no-op.
///
/// It may add or change HEADERS ONLY. The destination, the HTTP method, and the
/// body are fixed by the caller, and `HTTPTransport` re-checks all three after
/// the closure returns. An authorizer able to rewrite them could redirect an
/// estate call to another host or silently swap its payload — a
/// credential-shaped hook is not a request-rewriting hook.
public typealias GatewayRequestAuthorization = @Sendable (URLRequest) async throws -> URLRequest

/// Verifies an authenticated response BEFORE its body is parsed.
///
/// Handed the request AS SENT, the raw HTTP status, the exact `Content-Type` the
/// server sent (empty when it sent none), the response headers (lowercased names
/// — this is where the presented MAC lives), and the exact body bytes. Those are
/// precisely what a response MAC covers, plus the credential presenting it. It
/// throws to reject.
///
/// The sent request is passed so the verifier can bind the answer to THIS
/// question without consulting shared state. A verifier that instead asked a
/// sequencer for "the current sequence" would read whichever request most
/// recently started — so with two requests in flight, the response to the first
/// would be checked against the second's sequence and rejected despite being
/// authentic. Reading the sequence back off the request that carried it makes
/// the binding structural rather than a matter of timing.
///
/// Ordering is the whole point. `JSONValue.parse` on an unverified body means a
/// parser has already consumed attacker-controlled input before anything
/// established that the peer holds the session key. The verification therefore
/// runs on raw bytes, and the parse happens only after it returns.
public typealias GatewayResponseVerification = @Sendable (
    _ sentRequest: URLRequest, _ status: Int, _ contentType: String,
    _ headers: [String: String], _ body: Data
) async throws -> Void

/// What a transport does when the peer answers with a redirect.
public enum GatewayRedirectPolicy: Sendable, Equatable {

    /// Follow redirects, the URLSession default. Correct for the third-party
    /// lane, which has no endpoint pin to defeat.
    case follow

    /// Never follow a redirect; treat a 3xx as a transport failure.
    ///
    /// Required on the first-party lane. `URLSession` follows redirects by
    /// default, so without this a peer could answer the one contracted endpoint
    /// with a 3xx and have the request re-issued somewhere else — after the URL
    /// check has already passed, which is the one moment the endpoint pin is
    /// supposed to matter.
    case refuse
}

/// One raw response from the exact authenticated loopback endpoint.
private struct BoundedLoopbackResponse: Sendable {
    let status: Int
    let contentType: String
    let headers: [String: String]
    let body: Data
}

/// Private read failures are translated into the transport's public, redacted
/// error surface at the call site.
private enum BoundedResponseReadError: Error, Sendable {
    case redirect(Int)
    case unexpectedStatus(Int)
    case malformed
    case wrongMediaType
    case tooLarge
    case timeout
    case connection
}

/// The HTTP transport to a running MOOT resident daemon (ARIA_MCP_SPEC §5).
///
/// Sends one JSON-RPC 2.0 frame as an HTTP POST body to the daemon's loopback
/// endpoint, decodes the JSON-RPC response from the HTTP body. The server
/// (HTTPServer in ARIA_MCP) speaks byte-identical JSON-RPC; the dispatcher is
/// transport-neutral and does not change when the transport changes.
///
/// Wire contract:
///   - POST to `endpoint` (127.0.0.1:<port>, default path "/")
///   - Body: compact JSON-RPC 2.0 object, Content-Type: application/json
///   - No Origin header (native MCP clients send none; the server allows absent origins)
///   - HTTP 200 → JSON-RPC response in the body (tool calls and errors both 200)
///   - HTTP 202 → notification (no `id`); returns nil per JSON-RPC 2.0 spec
///   - Non-2xx → GatewayTransportError.unexpectedHTTPStatus
///   - Connection refused or unreachable → GatewayTransportError.connectionRefused
///   - Request timeout → GatewayTransportError.timeout
///   - Malformed JSON or missing JSON-RPC fields → GatewayTransportError.malformedResponse
///
/// Security: loopback-only (CE). The daemon binds 127.0.0.1 and enforces a
/// DNS-rebinding guard on the server side (absent/loopback Origin allowed, any
/// other Origin rejected 403). This client sends no Origin, which is the correct
/// native-client posture. Enterprise OAuth (EE) composes above this transport
/// in v2 — this type does not handle tokens.
///
/// Bonjour advertisement and LAN/Local Network entitlement (NSBonjourServices,
/// NSLocalNetworkUsageDescription) are not part of this transport. This type is
/// loopback-only: it connects to 127.0.0.1 and does not discover or contact
/// remote hosts. LAN discovery is a future surface beyond loopback CE.
public struct HTTPTransport: GatewayTransport, Sendable {

    /// The largest authenticated response admitted into memory. This matches
    /// the daemon's request ceiling and bounds both fixed-length and streamed
    /// replies before the response MAC verifier receives them.
    static let authenticatedResponseMaxBodyBytes = 4 * 1024 * 1024

    /// The loopback endpoint of the resident daemon (e.g. `http://127.0.0.1:4242`).
    public let endpoint: URL

    /// Request timeout. The daemon is local — 30 s covers any plausible tool call
    /// including expensive search and dreaming operations.
    public let timeout: TimeInterval

    /// The optional per-request authorization seam. `nil` — the default, and
    /// what every existing caller gets — sends the request exactly as built,
    /// with no credential of any kind. Loopback CE has no authentication to
    /// perform, so an unauthorized transport is the correct posture there.
    private let authorize: GatewayRequestAuthorization?

    /// Verifies the raw response before it is parsed. `nil` — the default —
    /// leaves the unauthenticated path exactly as it was.
    private let verifyResponse: GatewayResponseVerification?

    /// Redirect behaviour. `.follow` is the default and the pre-existing
    /// behaviour; the first-party lane passes `.refuse`.
    private let redirectPolicy: GatewayRedirectPolicy

    /// Build a transport to a loopback daemon endpoint.
    ///
    /// Every parameter after `endpoint` is defaulted, and that is load-bearing
    /// rather than convenient: nine call sites across the LAN surface, the
    /// estate client, and the test suites construct this type, all of them on
    /// the unauthenticated third-party path. Defaults keep every one of them
    /// compiling untouched AND behaving byte-for-byte as before.
    ///
    /// - Parameters:
    ///   - endpoint: The daemon's loopback endpoint.
    ///   - timeout: Request timeout. 30 s covers any plausible local tool call.
    ///   - authorize: Stamps a credential onto each outbound request. Omit it
    ///     — the default — for the unauthenticated loopback path; the request
    ///     is then sent byte-for-byte as it was before this seam existed.
    ///   - verifyResponse: Verifies the raw status, content type, and body
    ///     before any parsing. Omit for the unauthenticated path.
    ///   - redirectPolicy: `.refuse` on an endpoint-pinned lane.
    public init(
        endpoint: URL,
        timeout: TimeInterval = 30.0,
        authorize: GatewayRequestAuthorization? = nil,
        verifyResponse: GatewayResponseVerification? = nil,
        redirectPolicy: GatewayRedirectPolicy = .follow
    ) {
        self.endpoint = endpoint
        self.timeout = timeout
        self.authorize = authorize
        self.verifyResponse = verifyResponse
        self.redirectPolicy = redirectPolicy
    }

    /// POST one JSON-RPC 2.0 frame to the daemon and return the decoded response.
    ///
    /// Returns `nil` for HTTP 202 (the server's notification path: the request
    /// carried no `id`, so the JSON-RPC spec forbids a reply and the server sends
    /// an empty 202). All other outcomes either return a `JSONRPCResponse` or
    /// throw a named `GatewayTransportError`.
    public func send(_ request: JSONRPCRequest) async throws -> JSONRPCResponse? {
        // Build the JSON-RPC request body. JSONValue.encoded() matches the server's
        // serializer exactly (same Foundation JSONSerialization path), so the bytes
        // are round-trip identical to what StdioServer and HTTPServer produce.
        let requestValue = buildRequestValue(request)
        let body: Data
        do {
            body = try requestValue.encoded()
        } catch {
            throw GatewayTransportError.malformedResponse("Failed to encode outbound JSON-RPC request: \(error)")
        }

        // Held for the response-id check below. A notification carries no id and
        // gets no reply, so that guard is only reached when one was sent.
        let requestID = request.id

        var urlRequest = URLRequest(url: endpoint, timeoutInterval: timeout)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = body
        // Content-Type: application/json — the server requires this for POST routing.
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // No Origin header: native MCP clients (Claude Code, Claude Desktop, this app)
        // do not set Origin. The server's CSRF guard allows absent Origins. Sending a
        // synthetic Origin would require it to be loopback or the server would 403.

        // Authorization, when a client supplied one. Fail closed: a request the
        // client could not authorize is never sent bare, because a daemon that
        // happens to accept it would have been reached without proof of who was
        // asking — the exact condition the authenticated-first-party capability
        // exists to prevent.
        if let authorize {
            let authorized: URLRequest
            do {
                authorized = try await authorize(urlRequest)
            } catch {
                // The raw error is deliberately NOT interpolated. An authorizer
                // fails while holding a credential, and its error description is
                // the likeliest place for that credential — or a token fragment,
                // or a Keychain item path — to end up. This value reaches UI and
                // logs, so it carries only a bounded, opaque code.
                throw GatewayTransportError.authorizationFailed(
                    endpoint: endpoint,
                    code: Self.authorizationCode(for: error)
                )
            }
            // Header-only seam, enforced rather than documented.
            if authorized.url != urlRequest.url {
                throw GatewayTransportError.authorizationAlteredRequest(endpoint: endpoint, field: "url")
            }
            if authorized.httpMethod != urlRequest.httpMethod {
                throw GatewayTransportError.authorizationAlteredRequest(endpoint: endpoint, field: "httpMethod")
            }
            if authorized.httpBody != urlRequest.httpBody {
                throw GatewayTransportError.authorizationAlteredRequest(endpoint: endpoint, field: "httpBody")
            }
            // A streamed body would bypass the httpBody comparison entirely, so
            // it is refused outright rather than trusted.
            if authorized.httpBodyStream != nil {
                throw GatewayTransportError.authorizationAlteredRequest(endpoint: endpoint, field: "httpBodyStream")
            }
            urlRequest = authorized
        }

        let data: Data
        let status: Int
        let contentType: String
        let responseHeaders: [String: String]
        do {
            if verifyResponse != nil || redirectPolicy == .refuse {
                // URLSession drains paced redirect bodies before any callback
                // can reject the response. The pinned lane therefore performs
                // one raw loopback exchange: judge the head first, then admit a
                // bounded body under one absolute deadline.
                let bounded = try await Self.boundedAuthenticatedResponse(
                    for: urlRequest, timeout: timeout
                )
                data = bounded.body
                status = bounded.status
                contentType = bounded.contentType
                responseHeaders = bounded.headers
            } else {
                // The pre-existing path, unchanged: the shared session, which
                // follows redirects. Only the authenticated first-party lane
                // needs the stricter bounded reader.
                let (received, response) = try await URLSession.shared.data(for: urlRequest)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw BoundedResponseReadError.malformed
                }
                data = received
                status = httpResponse.statusCode
                contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""
                responseHeaders = httpResponse.allHeaderFields.reduce(into: [:]) { result, field in
                    guard let name = field.key as? String, let value = field.value as? String else { return }
                    result[name.lowercased()] = value
                }
            }
        } catch BoundedResponseReadError.redirect(let status) {
            throw GatewayTransportError.redirectRefused(endpoint: endpoint, status: status)
        } catch BoundedResponseReadError.unexpectedStatus(let status) {
            throw GatewayTransportError.unexpectedHTTPStatus(endpoint: endpoint, status: status)
        } catch BoundedResponseReadError.tooLarge {
            throw GatewayTransportError.responseTooLarge(
                endpoint: endpoint, limit: Self.authenticatedResponseMaxBodyBytes
            )
        } catch BoundedResponseReadError.timeout {
            throw GatewayTransportError.timeout(endpoint: endpoint, after: timeout)
        } catch BoundedResponseReadError.malformed,
                BoundedResponseReadError.wrongMediaType {
            throw GatewayTransportError.malformedResponse(
                "Invalid authenticated HTTP response from loopback endpoint \(endpoint)"
            )
        } catch BoundedResponseReadError.connection {
            throw GatewayTransportError.connectionRefused(endpoint: endpoint)
        } catch let urlError as URLError {
            // Map URLError codes to named GatewayTransportError cases.
            switch urlError.code {
            case .cannotConnectToHost, .networkConnectionLost,
                 .notConnectedToInternet:
                throw GatewayTransportError.connectionRefused(endpoint: endpoint)
            case .timedOut:
                throw GatewayTransportError.timeout(endpoint: endpoint, after: timeout)
            default:
                throw GatewayTransportError.connectionRefused(endpoint: endpoint)
            }
        } catch {
            // Any other transport-level failure (DNS, TLS, etc.) maps to connection refused
            // because this is a loopback endpoint — the only expected failure is the daemon
            // not running. TLS is not used on loopback CE.
            throw GatewayTransportError.connectionRefused(endpoint: endpoint)
        }

        // AUTHENTICATED LANE: verify the raw response before ANYTHING
        // interprets it — before the status is branched on and long before the
        // body reaches a parser. The verifier is handed exactly what the
        // response MAC covers: the status, the content type as sent, and the
        // body bytes as received.
        if let verifyResponse {
            do {
                try await verifyResponse(urlRequest, status, contentType, responseHeaders, data)
            } catch {
                // Same redaction discipline as the authorization seam: a
                // verifier fails while holding session material, so only a
                // bounded opaque code crosses this boundary.
                throw GatewayTransportError.responseVerificationFailed(
                    endpoint: endpoint, code: Self.authorizationCode(for: error)
                )
            }
        }

        // HTTP 204: the authenticated lane's notification acknowledgement. The
        // body is empty by definition and has already been MAC-verified above,
        // so there is nothing to parse and no reply to return.
        if status == 204 {
            return nil
        }

        // HTTP 202: notification path. The request had no `id`; the server sent an
        // empty 202 Accepted body. Return nil per JSON-RPC 2.0 (no reply for notifications).
        if status == 202 {
            return nil
        }

        guard (200..<300).contains(status) else {
            throw GatewayTransportError.unexpectedHTTPStatus(
                endpoint: endpoint,
                status: status
            )
        }

        // Parse the response body as a JSON-RPC frame using the server's own
        // decoding path (JSONValue.parse → JSONRPCResponse.decode).
        let parsed: JSONValue
        do {
            parsed = try JSONValue.parse(data)
        } catch {
            throw GatewayTransportError.malformedResponse(
                "Response body from \(endpoint) is not valid JSON: \(error)"
            )
        }

        guard let rpcResponse = JSONRPCResponse.decode(parsed) else {
            throw GatewayTransportError.malformedResponse(
                "Response body from \(endpoint) is not a valid JSON-RPC 2.0 response"
            )
        }

        // Bind the answer to the question. A response carrying a different id
        // — or none — is not an answer to this request, and accepting it would
        // let a confused or hostile peer pair any result with any call.
        guard rpcResponse.id == requestID else {
            throw GatewayTransportError.responseIdentifierMismatch(endpoint: endpoint)
        }

        return rpcResponse
    }

    /// Perform one exact, bounded HTTP/1.1 exchange with the loopback daemon.
    ///
    /// This deliberately does not use URLSession. Foundation drains a paced 3xx
    /// body before either its redirect delegate or response-disposition callback
    /// can cancel. A raw socket is the only repository-native primitive that can
    /// prove a redirect, bad status, or wrong media type is rejected before one
    /// body byte is read.
    private static func boundedAuthenticatedResponse(
        for request: URLRequest, timeout: TimeInterval
    ) async throws -> BoundedLoopbackResponse {
        guard timeout.isFinite, timeout > 0 else { throw BoundedResponseReadError.timeout }
        guard let url = request.url,
              url.scheme == "http", url.host == "127.0.0.1", let port = url.port,
              url.user == nil, url.password == nil, url.fragment == nil,
              request.httpMethod == "POST", request.httpBodyStream == nil,
              let requestBody = request.httpBody else {
            throw BoundedResponseReadError.connection
        }
        let target: String
        if let query = url.query {
            target = (url.path.isEmpty ? "/" : url.path) + "?" + query
        } else {
            target = url.path.isEmpty ? "/" : url.path
        }

        let budget = UInt64(min(timeout, 3_600) * 1_000_000_000)
        let now = DispatchTime.now().uptimeNanoseconds
        let (deadline, overflow) = now.addingReportingOverflow(budget)
        guard !overflow else { throw BoundedResponseReadError.timeout }

        let owner = LoopbackSocketOwner()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<BoundedLoopbackResponse, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        continuation.resume(returning: try performAuthenticatedExchange(
                            port: port, target: target, request: request,
                            body: requestBody, deadline: deadline, owner: owner
                        ))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            owner.shutdownNow()
        }
    }

    /// Blocking half of `boundedAuthenticatedResponse`.
    private static func performAuthenticatedExchange(
        port: Int,
        target: String,
        request: URLRequest,
        body: Data,
        deadline: UInt64,
        owner: LoopbackSocketOwner
    ) throws -> BoundedLoopbackResponse {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BoundedResponseReadError.connection }
        guard owner.register(fd) else {
            close(fd)
            throw BoundedResponseReadError.connection
        }
        defer {
            owner.unregister()
            close(fd)
        }

        func armTimeouts() throws {
            let current = DispatchTime.now().uptimeNanoseconds
            guard current < deadline else { throw BoundedResponseReadError.timeout }
            let remaining = deadline - current
            guard remaining >= 1_000 else { throw BoundedResponseReadError.timeout }
            let seconds = Int(remaining / 1_000_000_000)
            let microseconds = max(
                Int32((remaining % 1_000_000_000) / 1_000), seconds == 0 ? 1 : 0
            )
            var tv = timeval(tv_sec: seconds, tv_usec: microseconds)
            let receiveArmed = setsockopt(
                fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size)
            )
            let sendArmed = setsockopt(
                fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size)
            )
            guard receiveArmed == 0, sendArmed == 0 else {
                throw BoundedResponseReadError.connection
            }
        }

        try armTimeouts()
        var noSigPipe: Int32 = 1
        guard setsockopt(
            fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else { throw BoundedResponseReadError.connection }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0, owner.connectionEstablished(fd) else {
            throw BoundedResponseReadError.connection
        }

        let controlled = Set(["host", "content-length", "connection"])
        var headerLines = [String]()
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            let lower = name.lowercased()
            if controlled.contains(lower) { continue }
            guard lower != "transfer-encoding",
                  !name.isEmpty,
                  name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "!#$%&'*+-.^_`|~".contains($0)) }),
                  value.allSatisfy({ $0.isASCII && $0 != "\r" && $0 != "\n" }) else {
                throw BoundedResponseReadError.malformed
            }
            headerLines.append("\(name): \(value)\r\n")
        }
        // Sorting is not a protocol requirement, but deterministic emission
        // makes the exact bytes inspectable without changing any MAC input.
        headerLines.sort()
        var requestHead = "POST \(target) HTTP/1.1\r\n"
        requestHead += "Host: 127.0.0.1:\(port)\r\n"
        requestHead += headerLines.joined()
        requestHead += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        try writeAllBeforeDeadline(fd: fd, data: Data(requestHead.utf8), deadline: deadline, arm: armTimeouts)
        try writeAllBeforeDeadline(fd: fd, data: body, deadline: deadline, arm: armTimeouts)

        // One-byte reads make the head/body boundary exact. A wide recv can
        // consume body bytes from the same TCP segment before the head gate.
        let terminator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
        var head = [UInt8]()
        while true {
            guard head.count < 64 * 1024 else { throw BoundedResponseReadError.malformed }
            try armTimeouts()
            var byte: UInt8 = 0
            guard read(fd, &byte, 1) == 1 else { throw BoundedResponseReadError.connection }
            guard DispatchTime.now().uptimeNanoseconds <= deadline else {
                throw BoundedResponseReadError.timeout
            }
            head.append(byte)
            if head.count >= 4, Array(head.suffix(4)) == terminator { break }
        }
        guard let text = String(bytes: head.dropLast(4), encoding: .utf8),
              text.allSatisfy(\.isASCII) else { throw BoundedResponseReadError.malformed }
        let lines = text.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { throw BoundedResponseReadError.malformed }
        let statusTokens = statusLine.split(separator: " ", omittingEmptySubsequences: false)
        guard statusTokens.count >= 2, statusTokens[0] == "HTTP/1.1",
              statusTokens[1].count == 3,
              statusTokens[1].allSatisfy({ $0.isASCII && $0.isNumber }),
              let status = Int(statusTokens[1]) else { throw BoundedResponseReadError.malformed }

        var fields: [(String, String)] = []
        for line in lines.dropFirst() where !line.isEmpty {
            guard let first = line.first, first != " ", first != "\t",
                  let colon = line.firstIndex(of: ":") else {
                throw BoundedResponseReadError.malformed
            }
            let rawName = String(line[..<colon])
            guard !rawName.isEmpty,
                  rawName.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "!#$%&'*+-.^_`|~".contains($0)) }) else {
                throw BoundedResponseReadError.malformed
            }
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            fields.append((rawName.lowercased(), value))
        }
        var headers: [String: String] = [:]
        for (name, value) in fields {
            guard headers.updateValue(value, forKey: name) == nil else {
                throw BoundedResponseReadError.malformed
            }
        }
        guard headers["transfer-encoding"] == nil else {
            throw BoundedResponseReadError.malformed
        }

        // HEAD GATE: none of the response body has been read at this point.
        if (300..<400).contains(status) { throw BoundedResponseReadError.redirect(status) }
        guard status == 200 || status == 204 else {
            throw BoundedResponseReadError.unexpectedStatus(status)
        }
        let contentType = headers["content-type"] ?? ""
        if status == 200, !FirstPartyAuthProtocol.isExactContentType(contentType) {
            throw BoundedResponseReadError.wrongMediaType
        }
        if status == 204, !contentType.isEmpty {
            throw BoundedResponseReadError.wrongMediaType
        }
        guard let rawLength = headers["content-length"],
              !rawLength.isEmpty,
              rawLength.allSatisfy({ $0.isASCII && $0.isNumber }),
              rawLength.count == 1 || rawLength.first != "0",
              let declared = Int(rawLength) else { throw BoundedResponseReadError.malformed }
        guard declared <= authenticatedResponseMaxBodyBytes else {
            throw BoundedResponseReadError.tooLarge
        }
        guard status != 204 || declared == 0 else { throw BoundedResponseReadError.malformed }

        var responseBody = Data()
        responseBody.reserveCapacity(declared)
        while responseBody.count < declared {
            try armTimeouts()
            var chunk = [UInt8](repeating: 0, count: min(16 * 1024, declared - responseBody.count))
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else { throw BoundedResponseReadError.connection }
            guard DispatchTime.now().uptimeNanoseconds <= deadline else {
                throw BoundedResponseReadError.timeout
            }
            responseBody.append(contentsOf: chunk[0..<count])
        }
        return BoundedLoopbackResponse(
            status: status, contentType: contentType, headers: headers, body: responseBody
        )
    }

    /// Write all bytes while continually reducing the socket timeout against
    /// the exchange's one absolute deadline.
    private static func writeAllBeforeDeadline(
        fd: Int32,
        data: Data,
        deadline: UInt64,
        arm: () throws -> Void
    ) throws {
        var sent = 0
        try data.withUnsafeBytes { raw in
            while sent < raw.count {
                try arm()
                let count = write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                guard count > 0 else { throw BoundedResponseReadError.connection }
                guard DispatchTime.now().uptimeNanoseconds <= deadline else {
                    throw BoundedResponseReadError.timeout
                }
                sent += count
            }
        }
    }

    /// A bounded, opaque token naming only the KIND of authorization failure.
    ///
    /// Derived from the error's type name, never its description: a type name
    /// cannot contain a credential, and capping the length keeps a pathological
    /// generic type from turning a log line into a payload.
    private static func authorizationCode(for error: any Error) -> String {
        let typeName = String(describing: type(of: error))
        let allowed = typeName.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }
        guard !allowed.isEmpty else { return "unknown" }
        return String(allowed.prefix(64))
    }

    /// Build the JSON-RPC 2.0 request as a JSONValue so `encoded()` serializes it
    /// with the same path the server uses for responses — keeping round-trip
    /// byte-identity between the two JSON-RPC directions.
    private func buildRequestValue(_ request: JSONRPCRequest) -> JSONValue {
        var obj: [String: JSONValue] = [
            "jsonrpc": .string(request.jsonrpc),
            "method":  .string(request.method),
        ]
        if let id = request.id {
            obj["id"] = id
        }
        if let params = request.params {
            obj["params"] = params
        }
        return .object(obj)
    }
}

/// Decode a JSON-RPC 2.0 response from the server's serialized JSONValue format.
///
/// The server serializes responses as
/// `{"jsonrpc":"2.0","id":<id>,"result":<v>}` or
/// `{"jsonrpc":"2.0","id":<id>,"error":{"code":<n>,"message":<s>}}`.
/// This mirrors `JSONRPCRequest.decode` — the same structural guard that the
/// server uses on inbound requests, applied to inbound responses on the client.
private extension JSONRPCResponse {
    static func decode(_ value: JSONValue) -> JSONRPCResponse? {
        guard let object = value.objectValue else { return nil }
        guard let jsonrpc = object["jsonrpc"]?.stringValue, jsonrpc == "2.0" else { return nil }
        guard let id = object["id"] else { return nil }
        if let result = object["result"] {
            return .ok(id, result)
        }
        if let errObj = object["error"]?.objectValue,
           let code = errObj["code"]?.intValue,
           let message = errObj["message"]?.stringValue {
            return .failure(id, JSONRPCError(code: Int(code), message: message, data: errObj["data"]))
        }
        return nil
    }
}

private extension JSONValue {
    /// Convenience: integer value from .integer case (Int64 → Int).
    var intValue: Int64? {
        if case .integer(let n) = self { return n }
        return nil
    }
}

/// Transport-level errors for `HTTPTransport`. Each case names the real condition
/// (connection refused, timeout, non-2xx, malformed response) so callers can react
/// to the specific failure mode without inspecting raw error strings.
public enum GatewayTransportError: Error, CustomStringConvertible {

    /// The daemon is not running or the port is wrong. Loopback-only: if the
    /// process is local, ECONNREFUSED means the daemon is not listening.
    case connectionRefused(endpoint: URL)

    /// The request timed out waiting for the daemon to respond. `after` is the
    /// configured `URLRequest.timeoutInterval`.
    case timeout(endpoint: URL, after: TimeInterval)

    /// The server responded with an HTTP status code outside 2xx. The status
    /// is included so the caller can distinguish 403 (CSRF guard fired, wrong
    /// Origin) from 503 (gate shed the connection) from 4xx/5xx tool routing
    /// errors. JSON-RPC-level failures (method errors, invalid params) always
    /// return HTTP 200 with a JSON-RPC error payload — they never reach here.
    case unexpectedHTTPStatus(endpoint: URL, status: Int)

    /// The response body could not be decoded as a valid JSON-RPC 2.0 frame.
    /// Includes a diagnostic reason string naming which structural check failed.
    case malformedResponse(_ reason: String)

    /// The client could not authorize the request, so it was never sent. Only
    /// reachable when a `GatewayRequestAuthorization` was supplied; the
    /// unauthenticated loopback path cannot produce this case.
    ///
    /// `code` is a bounded, opaque token naming the kind of failure. It never
    /// carries the authorizer's own error text, which is where a credential
    /// would leak into UI and logs.
    case authorizationFailed(endpoint: URL, code: String)

    /// The authorization seam returned a request differing from the one this
    /// transport built, in a field it may not touch. `field` names the first
    /// violation found. The request is never sent.
    case authorizationAlteredRequest(endpoint: URL, field: String)

    /// The daemon answered with a JSON-RPC id that is not the one sent. The
    /// response is discarded: an unpaired result cannot be attributed to any
    /// request this client made.
    case responseIdentifierMismatch(endpoint: URL)

    /// The response failed authentication — a bad or missing response MAC, or a
    /// mismatched status, content type, sequence, or body. The body was never
    /// parsed. `code` is bounded and opaque for the same reason as
    /// `authorizationFailed`: the verifier fails while holding session material.
    case responseVerificationFailed(endpoint: URL, code: String)

    /// An authenticated peer declared or streamed a response beyond the hard
    /// in-memory ceiling. It is discarded before MAC verification or parsing.
    case responseTooLarge(endpoint: URL, limit: Int)

    /// The daemon answered an endpoint-pinned request with a redirect. Never
    /// followed: the whole premise of the first-party lane is one exact
    /// endpoint, and a followed redirect leaves it.
    case redirectRefused(endpoint: URL, status: Int)

    public var description: String {
        switch self {
        case .connectionRefused(let endpoint):
            return "Cannot connect to resident daemon at \(endpoint) — is mootx01 running on that port?"
        case .timeout(let endpoint, let after):
            return "Request to resident daemon at \(endpoint) timed out after \(after) s"
        case .unexpectedHTTPStatus(let endpoint, let status):
            return "Resident daemon at \(endpoint) returned HTTP \(status) (expected 200 or 202)"
        case .malformedResponse(let reason):
            return "Malformed JSON-RPC response from resident daemon: \(reason)"
        case .authorizationFailed(let endpoint, let code):
            return "Cannot authorize a request to resident daemon at \(endpoint) (\(code))"
        case .authorizationAlteredRequest(let endpoint, let field):
            return "Authorization altered the \(field) of a request to resident daemon at "
                + "\(endpoint); the seam may add headers only"
        case .responseIdentifierMismatch(let endpoint):
            return "Resident daemon at \(endpoint) answered with a JSON-RPC id that does not "
                + "match the request"
        case .responseVerificationFailed(let endpoint, let code):
            return "Cannot authenticate the response from resident daemon at \(endpoint) (\(code)); "
                + "the body was not parsed"
        case .responseTooLarge(let endpoint, let limit):
            return "Resident daemon at \(endpoint) exceeded the authenticated response limit "
                + "of \(limit) bytes"
        case .redirectRefused(let endpoint, let status):
            return "Resident daemon at \(endpoint) answered with HTTP \(status); redirects are "
                + "never followed on the authenticated first-party lane"
        }
    }
}
