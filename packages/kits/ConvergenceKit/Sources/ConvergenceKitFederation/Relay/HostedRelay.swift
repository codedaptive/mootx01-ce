// HostedRelay.swift — ConvergenceKitFederation
//
// HTTPS Relay conformer for the Federation SyncServer wire protocol (CVK-WC7).
//
// Implements the client side of the three v1 endpoints:
//   POST /v1/register        — register this estate's public key with the server
//   POST /v1/send/{hex}      — deliver a SignedEnvelope to a recipient's inbox
//   GET  /v1/inbox/{hex}     — poll the local estate's inbox (cursor-based)
//
// The spec is docs/reference/FEDERATION_SYNCSERVER_WIRE_PROTOCOL.md v0.1.
// INTERFACE §4 is the Relay protocol contract.
//
// DESIGN: HostedRelay conforms to the synchronous Relay protocol. Network I/O
// is injected via RelayHTTPTransport (sync seam). Tests supply
// FakeRelayHTTPTransport (in-memory); production uses URLSessionRelayHTTPTransport
// (DispatchSemaphore bridge over URLSession.dataTask).
//
// CURSOR MANAGEMENT: drain(for:) advances a per-recipient cursor (the highest
// seqno seen). A fresh HostedRelay instance starts at cursor 0 for all
// recipients. The cursor is in-memory only — it is NOT persisted. On engine
// restart the cursor resets to 0, re-fetching all envelopes in the retention
// window (at-least-once delivery; LWW gate at the engine layer handles
// re-application idempotently).

import Foundation
import ConvergenceKit
import os

private let logger = Logger(
    subsystem: "com.mootx01.synckit.federation",
    category: "HostedRelay"
)

// MARK: - Wire types (private, internal to HostedRelay)

/// POST /v1/register request body.
private struct RegisterBody: Encodable {
    /// 32-byte Ed25519 public key, base64url per §1.2. Swift Data encodes as
    /// standard base64 (RFC 4648 §4); the server spec accepts both variants.
    let publicKey: Data
}

/// POST /v1/register 200 response.
private struct RegisterResponse: Decodable {
    let registered: Bool
}

/// POST /v1/send/{hex} 202 response.
private struct SendResponse: Decodable {
    let accepted: Bool
    let seqno: UInt64
}

/// One item in the GET /v1/inbox/{hex} response envelope array.
/// Includes a server-assigned seqno wrapping the SignedEnvelope fields.
private struct InboxItem: Decodable {
    let seqno: UInt64
    // SignedEnvelope fields inline (not nested) per spec §1.2 inbox response.
    let senderPublicKey: Data
    let payloadKind: PayloadKind
    let payload: Data
    let signature: Data
    let hlc: PackedHLC

    /// Reconstitute the SignedEnvelope (drops the server-assigned seqno).
    var envelope: SignedEnvelope {
        SignedEnvelope(
            senderPublicKey: senderPublicKey,
            payloadKind: payloadKind,
            payload: payload,
            signature: signature,
            hlc: hlc
        )
    }
}

/// GET /v1/inbox/{hex} 200 response.
private struct InboxResponse: Decodable {
    let envelopes: [InboxItem]
    /// Highest seqno in this response. The caller stores this as the next
    /// `after` cursor. Null when `envelopes` is empty and no prior cursor exists.
    let nextAfter: UInt64?
}

/// Error body returned for 4xx/5xx responses.
private struct RelayErrorBody: Decodable {
    let error: String
    let detail: String?
}

// MARK: - HTTP status → SyncError mapping (spec §4)

/// Map an HTTP status code from the relay server to the appropriate `SyncError`.
///
/// - 401, 403 → `authenticationFailed`
/// - 404      → `peerUnreachable` (recipient not registered)
/// - 409      → nil (duplicate envelope; treat as success per §3.2)
/// - 4xx/5xx  → `transportFailure`
private func mapStatusToError(
    _ status: Int,
    body: Data,
    recipientIdentity: String
) -> SyncError? {
    switch status {
    case 200, 202:
        return nil  // success
    case 409:
        return nil  // duplicate envelope — at-most-once dedup; treat as 202 (§3.2)
    case 401, 403:
        let detail = (try? JSONDecoder().decode(RelayErrorBody.self, from: body))?.detail
            ?? "HTTP \(status)"
        return .authenticationFailed(detail: detail)
    case 404:
        return .peerUnreachable(identity: recipientIdentity)
    default:
        let detail = (try? JSONDecoder().decode(RelayErrorBody.self, from: body))?.detail
            ?? "HTTP \(status)"
        return .transportFailure(detail: detail)
    }
}

// MARK: - HostedRelay

/// HTTPS `Relay` conformer that speaks the Federation SyncServer wire protocol.
///
/// Instantiate with a base URL and bearer token. The transport is injected for
/// testability; production callers use the default `URLSessionRelayHTTPTransport`.
///
/// ```swift
/// let relay = HostedRelay(baseURL: serverURL, bearerToken: myToken)
/// try relay.register(publicKey: identity.publicKey)
/// let engine = FederationSyncEngine(relay: relay)
/// ```
///
/// For tests, inject a `FakeRelayHTTPTransport` so no real network calls are made.
public final class HostedRelay: Relay, @unchecked Sendable {

    // MARK: Configuration

    /// Base URL for the relay server (e.g. `https://relay.example.com`).
    /// Endpoint paths are appended: `/v1/register`, `/v1/send/{hex}`, `/v1/inbox/{hex}`.
    public let baseURL: URL

    /// Bearer token included in every request's `Authorization` header.
    /// Authorizes transport admission; does not grant content trust (spec §2.1).
    public let bearerToken: String

    /// Injected HTTP transport. Use `URLSessionRelayHTTPTransport` (default) in
    /// production and `FakeRelayHTTPTransport` in tests.
    public let transport: any RelayHTTPTransport

    // MARK: Cursor state (in-memory, not persisted — at-least-once on restart)

    /// NSLock guarding mutable state (cursors). @unchecked Sendable because
    /// Data keys in a Dictionary are value types and access is lock-guarded.
    private let lock = NSLock()
    /// In-memory inbox cursor per recipient public key. Stores the highest
    /// `seqno` seen from the server. Starts at 0 (fetch all retained envelopes).
    /// NOT persisted — resets on engine restart; the LWW gate handles re-delivery.
    private var cursors: [Data: UInt64] = [:]

    // MARK: Init

    /// Create a hosted relay client.
    ///
    /// - Parameters:
    ///   - baseURL: Base URL of the SyncServer (no trailing slash).
    ///   - bearerToken: Bearer token for `Authorization` header (spec §2.1).
    ///   - transport: HTTP transport. Defaults to `URLSessionRelayHTTPTransport`.
    public init(
        baseURL: URL,
        bearerToken: String,
        transport: any RelayHTTPTransport = URLSessionRelayHTTPTransport()
    ) {
        self.baseURL = baseURL
        self.bearerToken = bearerToken
        self.transport = transport
    }

    // MARK: Standard headers (spec §1.2 and §5.1)

    /// Headers required on every request: bearer auth and protocol version.
    /// Content-Type is added separately for POST requests with a body.
    private var baseHeaders: [String: String] {
        [
            "Authorization": "Bearer \(bearerToken)",
            // X-Sync-Protocol: 1 — protocol version header (spec §5.1).
            // The server rejects unrecognized versions with HTTP 400.
            "X-Sync-Protocol": "1",
        ]
    }

    // MARK: Registration (spec §1.2 POST /v1/register)

    /// Register this estate's public key with the relay server.
    ///
    /// Call once at engine enable time after the estate identity is loaded
    /// (I-8, WC1). Registration is idempotent — re-registering the same key
    /// has no effect on the server (spec §1.2).
    ///
    /// - Parameter publicKey: 32-byte Ed25519 verifying key of this estate.
    /// - Throws: `SyncError.authenticationFailed` on 401/403.
    ///           `SyncError.transportFailure` on network error or 4xx/5xx.
    public func register(publicKey: Data) throws {
        let url = baseURL.appendingPathComponent("v1/register")
        let body = try JSONEncoder().encode(RegisterBody(publicKey: publicKey))

        var headers = baseHeaders
        headers["Content-Type"] = "application/json"

        let req = RelayHTTPRequest(method: "POST", url: url, headers: headers, body: body)
        let resp = try transport.execute(req)

        if let error = mapStatusToError(resp.statusCode, body: resp.body, recipientIdentity: "") {
            throw error
        }
        // Decode register response for a conformance sanity check.
        if let decoded = try? JSONDecoder().decode(RegisterResponse.self, from: resp.body),
           !decoded.registered {
            logger.warning("hosted-relay register: server returned registered=false for \(publicKey.prefix(4).hex, privacy: .public)…")
        }
        logger.debug("hosted-relay: registered public key \(publicKey.prefix(4).hex, privacy: .public)…")
    }

    // MARK: Relay.send (spec §1.2 POST /v1/send/{recipientHex})

    /// Deliver a `SignedEnvelope` to a recipient's inbox on the relay server.
    ///
    /// `recipientKey` is hex-encoded (64 lowercase hex chars) as the URL path
    /// component per spec §1.2. The envelope is JSON-encoded in the request body.
    ///
    /// HTTP 409 (duplicate envelope, server-side dedup key (senderPublicKey, hlc))
    /// is treated as success — the envelope is already in the inbox (spec §3.2).
    ///
    /// - Throws: `SyncError.peerUnreachable` on 404 (recipient not registered).
    ///           `SyncError.authenticationFailed` on 401/403.
    ///           `SyncError.transportFailure` on network error or other 4xx/5xx.
    public func send(to recipient: Data, message: SignedEnvelope) throws {
        let hex = recipient.hex  // 64 lowercase hex chars (spec §1.2)
        let url = baseURL.appendingPathComponent("v1/send/\(hex)")

        let body = try {
            do {
                return try JSONEncoder().encode(message)
            } catch {
                throw SyncError.transportFailure(detail: "encode envelope: \(error)")
            }
        }()

        var headers = baseHeaders
        headers["Content-Type"] = "application/json"

        let req = RelayHTTPRequest(method: "POST", url: url, headers: headers, body: body)
        let resp: RelayHTTPResponse
        do {
            resp = try transport.execute(req)
        } catch {
            // Network-level failure (no response received). The durable outbox
            // (WC2) retains the record for the next push() cycle.
            throw SyncError.transportFailure(detail: "network error: \(error.localizedDescription)")
        }

        if let syncError = mapStatusToError(resp.statusCode, body: resp.body, recipientIdentity: hex) {
            throw syncError
        }
        logger.debug("hosted-relay send: 202 accepted for recipient …\(hex.suffix(8), privacy: .public)")
    }

    // MARK: Relay.drain (spec §1.2 GET /v1/inbox/{recipientHex})

    /// Poll the local estate's inbox from the relay server.
    ///
    /// Each call GETs `/v1/inbox/{recipientHex}?after={cursor}` where
    /// `cursor` is the highest `seqno` seen in the previous poll (starts at 0).
    /// The server returns only envelopes with `seqno > cursor` (spec §1.2).
    ///
    /// On any error (network failure, HTTP error), logs and returns `[]` so
    /// the engine's pull cycle degrades gracefully. The at-least-once guarantee
    /// is preserved because the server retains envelopes in the retention window
    /// and the client will retry on the next poll cycle (spec §3.3).
    ///
    /// The `Relay` protocol contract defines `drain` as non-throwing. A real
    /// production engine drives polling via a separate `poll() async throws`
    /// method or the engine's loop; this conformance implementation satisfies
    /// the in-process contract by making the HTTP call synchronously via the
    /// injected transport.
    public func drain(for recipient: Data) -> [SignedEnvelope] {
        let hex = recipient.hex
        let cursor: UInt64
        lock.lock()
        cursor = cursors[recipient] ?? 0
        lock.unlock()

        // Build URL: /v1/inbox/{hex}?after={cursor}
        // When cursor == 0, spec says "after=0" is equivalent to omitting after
        // (returns all retained envelopes). We always include it for consistency.
        var components = URLComponents(
            url: baseURL.appendingPathComponent("v1/inbox/\(hex)"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "after", value: String(cursor))]
        guard let url = components?.url else {
            logger.error("hosted-relay drain: could not construct inbox URL for \(hex.suffix(8), privacy: .public)")
            return []
        }

        let req = RelayHTTPRequest(method: "GET", url: url, headers: baseHeaders)
        let resp: RelayHTTPResponse
        do {
            resp = try transport.execute(req)
        } catch {
            logger.warning("hosted-relay drain: network error for \(hex.suffix(8), privacy: .public): \(error.localizedDescription, privacy: .public)")
            return []
        }

        guard resp.statusCode == 200 else {
            logger.warning("hosted-relay drain: HTTP \(resp.statusCode) for inbox \(hex.suffix(8), privacy: .public)")
            return []
        }

        let decoded: InboxResponse
        do {
            decoded = try JSONDecoder().decode(InboxResponse.self, from: resp.body)
        } catch {
            logger.error("hosted-relay drain: decode inbox response failed: \(error.localizedDescription, privacy: .public)")
            return []
        }

        // Advance the cursor to the highest seqno we received.
        // nextAfter == nil when the inbox is empty and cursor was 0.
        if let nextAfter = decoded.nextAfter {
            lock.lock()
            cursors[recipient] = nextAfter
            lock.unlock()
        }

        let envelopes = decoded.envelopes.map(\.envelope)
        if !envelopes.isEmpty {
            logger.debug("hosted-relay drain: \(envelopes.count) envelope(s) for …\(hex.suffix(8), privacy: .public), cursor now \(decoded.nextAfter ?? cursor)")
        }
        return envelopes
    }
}

// MARK: - Data hex helpers

extension Data {
    /// Lowercase hex string (2 chars per byte). Used for URL path segments per spec §1.2.
    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
