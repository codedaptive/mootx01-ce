// FakeRelayHTTPTransport.swift — ConvergenceKitFederationTests
//
// In-memory scripted HTTP transport for HostedRelay conformance tests.
// Implements the Federation SyncServer wire protocol server-side semantics
// in a single-process, synchronous fake.
//
// State:
//   registeredKeys — set of hex-encoded public keys that have called /register
//   inboxes        — per-recipient list of (seqno, envelope JSON item)
//   dedupSet       — (senderPublicKeyHex, hlcPacked) pairs already stored
//   seqCounter     — monotonically increasing UInt64 for seqno assignment
//
// The fake is intentionally NOT thread-safe beyond NSLock because tests
// drive it from a single async Task and the synchronous transport contract
// means no concurrent access can occur within a single relay call.

import Foundation
@testable import ConvergenceKitFederation

// MARK: - Wire types (mirrors HostedRelay private types for the server side)

/// The JSON representation of a SignedEnvelope as it arrives in POST /v1/send/{hex}.
/// Matches the spec §1.2 request body.
struct WireSendBody: Decodable {
    let senderPublicKey: Data
    let payloadKind: UInt8
    let payload: Data
    let signature: Data
    let hlc: WireHLC
}

struct WireHLC: Codable {
    let physicalTime: Int64
    let logicalCount: Int32
    let nodeID: Int32
}

/// One item in the inbox response (seqno + envelope fields).
struct WireInboxItem: Encodable {
    let seqno: UInt64
    let senderPublicKey: Data
    let payloadKind: UInt8
    let payload: Data
    let signature: Data
    let hlc: WireHLC
}

struct WireInboxResponse: Encodable {
    let envelopes: [WireInboxItem]
    let nextAfter: UInt64?
}

// MARK: - FakeRelayHTTPTransport

/// In-memory relay server fake. Speaks the exact wire protocol so HostedRelay
/// can be exercised against it without any real network I/O.
///
/// All tests that instantiate HostedRelay must supply this transport:
/// ```swift
/// let transport = FakeRelayHTTPTransport()
/// let relay = HostedRelay(baseURL: URL(string:"https://relay.test")!, bearerToken:"tok", transport: transport)
/// ```
final class FakeRelayHTTPTransport: RelayHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()

    /// Hex-encoded public keys that completed /register.
    private var registeredKeys: Set<String> = []
    /// Inbox per recipient hex key: ordered list of (seqno, WireInboxItem).
    private var inboxes: [String: [WireInboxItem]] = [:]
    /// Server-side dedup set: (senderPublicKeyHex + "_" + hlcPacked) → seqno.
    private var dedupSet: [String: UInt64] = [:]
    /// Monotonically increasing sequence number.
    private var seqCounter: UInt64 = 0

    // MARK: - RelayHTTPTransport

    func execute(_ request: RelayHTTPRequest) throws -> RelayHTTPResponse {
        lock.lock()
        defer { lock.unlock() }

        let path = request.url.path

        // Route by method + path prefix.
        if request.method == "POST" && path.hasSuffix("/v1/register") {
            return handleRegister(body: request.body ?? Data())
        }
        if request.method == "POST", let hex = extractHex(from: path, prefix: "/v1/send/") {
            return handleSend(recipientHex: hex, body: request.body ?? Data())
        }
        if request.method == "GET", let hex = extractHex(from: path, prefix: "/v1/inbox/") {
            let afterParam = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "after" })?.value
            let after = afterParam.flatMap { UInt64($0) } ?? 0
            return handleInbox(recipientHex: hex, after: after)
        }

        return jsonResponse(statusCode: 404, body: ["error": "not_found", "detail": "unknown endpoint"])
    }

    // MARK: - Handler: POST /v1/register

    private func handleRegister(body: Data) -> RelayHTTPResponse {
        struct Req: Decodable { let publicKey: Data }
        guard let req = try? JSONDecoder().decode(Req.self, from: body) else {
            return jsonResponse(statusCode: 400, body: ["error": "bad_request", "detail": "invalid JSON"])
        }
        // Registration is idempotent — adding to a set is safe for duplicates.
        registeredKeys.insert(req.publicKey.hex)
        return jsonResponse(statusCode: 200, body: ["registered": true])
    }

    // MARK: - Handler: POST /v1/send/{hex}

    private func handleSend(recipientHex: String, body: Data) -> RelayHTTPResponse {
        guard registeredKeys.contains(recipientHex) else {
            // 404 — recipient key not registered (spec §4).
            return jsonResponse(statusCode: 404, body: [
                "error": "recipient_not_found",
                "detail": "recipient public key not registered",
            ])
        }
        guard let wireBody = try? JSONDecoder().decode(WireSendBody.self, from: body) else {
            return jsonResponse(statusCode: 400, body: ["error": "bad_request", "detail": "invalid envelope JSON"])
        }

        // Dedup on (senderPublicKey, hlcPacked) — spec §3.2.
        // Pack the HLC into a single Int64 for a compact dedup key.
        let dedupKey = "\(wireBody.senderPublicKey.hex)_\(wireBody.hlc.physicalTime)_\(wireBody.hlc.logicalCount)_\(wireBody.hlc.nodeID)"
        if let existingSeqno = dedupSet[dedupKey] {
            // Duplicate: return 409 with original seqno.
            return jsonResponse(statusCode: 409, body: ["error": "duplicate_envelope", "seqno": existingSeqno])
        }

        // Assign a new sequence number and store.
        seqCounter += 1
        let seqno = seqCounter
        dedupSet[dedupKey] = seqno

        let item = WireInboxItem(
            seqno: seqno,
            senderPublicKey: wireBody.senderPublicKey,
            payloadKind: wireBody.payloadKind,
            payload: wireBody.payload,
            signature: wireBody.signature,
            hlc: wireBody.hlc
        )
        inboxes[recipientHex, default: []].append(item)

        return jsonResponse(statusCode: 202, body: ["accepted": true, "seqno": seqno])
    }

    // MARK: - Handler: GET /v1/inbox/{hex}?after={seqno}

    private func handleInbox(recipientHex: String, after: UInt64) -> RelayHTTPResponse {
        guard registeredKeys.contains(recipientHex) else {
            return jsonResponse(statusCode: 404, body: [
                "error": "recipient_not_found",
                "detail": "recipient public key not registered",
            ])
        }

        // Return envelopes with seqno > after (all of them when after == 0).
        let all = inboxes[recipientHex] ?? []
        let filtered = all.filter { $0.seqno > after }

        let nextAfter: UInt64?
        if filtered.isEmpty {
            // No new envelopes: echo the after cursor (spec: nextAfter == after when empty).
            nextAfter = after > 0 ? after : nil
        } else {
            nextAfter = filtered.map(\.seqno).max()
        }

        // Encode using WireInboxResponse (must be Encodable).
        let wireResponse = WireInboxResponse(envelopes: filtered, nextAfter: nextAfter)
        guard let data = try? JSONEncoder().encode(wireResponse) else {
            return RelayHTTPResponse(statusCode: 500, body: Data())
        }
        return RelayHTTPResponse(statusCode: 200, body: data)
    }

    // MARK: - Helpers

    /// Encode a dictionary as a JSON body.
    private func jsonResponse(statusCode: Int, body: [String: Any]) -> RelayHTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        return RelayHTTPResponse(statusCode: statusCode, body: data)
    }

    /// Extract a hex path component from a URL path matching prefix/{hex}.
    private func extractHex(from path: String, prefix: String) -> String? {
        guard path.hasPrefix(prefix) else { return nil }
        let hex = String(path.dropFirst(prefix.count))
        // Validate: 64 lowercase hex chars for a 32-byte Ed25519 key.
        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        return hex
    }

    // MARK: - Test inspection helpers

    /// Number of envelopes currently in the given recipient's inbox (for assertions).
    func inboxCount(forRecipientHex hex: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return inboxes[hex]?.count ?? 0
    }

    /// Reset all server state (useful between test cases that share an instance).
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        registeredKeys.removeAll()
        inboxes.removeAll()
        dedupSet.removeAll()
        seqCounter = 0
    }
}

// Data.hex is defined in HostedRelay.swift and is internal. @testable import
// above grants access to it within this test target.
