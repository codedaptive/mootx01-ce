---
title: Federation SyncServer Wire Protocol
version: v0.1
status: accepted
date: 2026-07-17
mission: CVK-WC7a
reviewer: Bob
relates_to:
  - docs/reference/CONVERGENCEKIT_INTERFACE.md (§ 4 Relay abstraction)
  - docs/reference/CONVERGENCEKIT_SPEC.md (I-7, I-8, I-9, B-7, B-10, B-11)
  - docs/analysis/CVK_WAVEC_FEDERATION_CHARTER.md (WC7 verdict)
---

# Federation SyncServer Wire Protocol

This document specifies the HTTPS wire protocol that the WC7 hosted-relay
`Relay` conformer implements client-side, and that a SyncServer implementation
must satisfy server-side. The SyncServer is a dumb store-and-forward relay:
it accepts signed envelopes from senders and delivers them to recipients. It
does not inspect payloads, does not re-sign, and does not make trust decisions.
All content integrity and trust derives from Ed25519 signatures end-to-end (I-7).

This document is the design contract referenced by SPEC B-7.

**Not covered here:** server implementation, multi-tenant policy, capacity
planning, billing, or aria-mcp access mediation (that boundary is I-9; see
§ 7 Out of Scope).

---

## § 1 — Transport

### 1.1 Base URL and versioning

All endpoints are under a versioned path prefix:

```
https://{host}/v1/
```

The protocol version is also communicated via a request header (§ 5).
The path prefix version is structural: a v2 server must serve both
`/v1/` and `/v2/` during transition periods (§ 5).

TLS is mandatory. Plain HTTP must be rejected at the server (HTTP 400 or
connection refusal). The client conformer must not connect without TLS.

### 1.2 Endpoints

Three endpoints constitute the v1 protocol surface.

---

#### POST /v1/register

Register an estate's public key with the relay. The server records that
envelopes addressed to this public key should be retained. Registration is
idempotent: re-registering the same key has no effect.

**Request headers:**

```
Authorization: Bearer {token}
Content-Type: application/json
X-Sync-Protocol: 1
```

**Request body:**

```json
{
  "publicKey": "<base64url — 32-byte Ed25519 public key>"
}
```

`publicKey` is the raw 32-byte Ed25519 public key, base64url-encoded
(RFC 4648 § 5, no padding). The same encoding as `senderPublicKey` in
`SignedEnvelope` (below).

**Response (200 OK):**

```json
{
  "registered": true
}
```

**Error responses:** see § 4.

**Notes:**

- The bearer token in the `Authorization` header authorizes the transport
  call (admission control). It does not grant any trust over the key's
  content — that derives from Ed25519 signatures at the record level.
- The server must not allow a caller to register a key it does not own;
  however, the v1 protocol does not enforce this at the wire layer —
  the token grants transport admission, and the client conformer only
  registers its own estate key. Multi-tenant key isolation is a
  server-side enforcement concern (§ 7).
- Registration is called once at conformer init or on first use.
  The hosted relay client conformer (WC7) calls register on the first
  `enable()` after the estate identity is loaded (I-8, WC1).

---

#### POST /v1/send/{recipientKey}

Deliver a `SignedEnvelope` to a recipient's inbox.

`{recipientKey}` is the recipient's 32-byte Ed25519 public key,
lowercase hex-encoded (64 hex characters).

**Request headers:**

```
Authorization: Bearer {token}
Content-Type: application/json
X-Sync-Protocol: 1
```

**Request body — `SignedEnvelope` JSON object:**

```json
{
  "senderPublicKey": "<base64 — 32 bytes>",
  "payloadKind":     1,
  "payload":         "<base64 — opaque batch bytes>",
  "signature":       "<base64 — 64-byte Ed25519 signature>",
  "hlc": {
    "physicalTime":  <int64>,
    "logicalCount":  <int32>,
    "nodeID":        <int32>
  }
}
```

Field semantics match `SignedEnvelope` as defined in
`CONVERGENCEKIT_INTERFACE.md § 4` and implemented in
`Sources/ConvergenceKitFederation/FederationSyncEngine.swift`:

| Field | Type | Description |
|---|---|---|
| `senderPublicKey` | base64 string | 32-byte Ed25519 public key of the sender. Swift `Codable` encodes `Data` as standard base64 (RFC 4648 § 4, with padding). |
| `payloadKind` | uint8 (JSON number) | Discriminator for the opaque payload. `1` = `syncRecordBatch` (the only v1.0 variant). `2` is reserved for `fieldWriteEventBatch` (C1 extension point). Receivers must reject unknown values. |
| `payload` | base64 string | Opaque batch bytes. When `payloadKind == 1`, the bytes are a JSON-encoded `[SyncRecord]` array. The server must not interpret this field. |
| `signature` | base64 string | 64-byte Ed25519 signature. Covers the canonical signing bytes (not raw `payload`) — see § 1.3. |
| `hlc.physicalTime` | int64 | Batch-level HLC physical timestamp (milliseconds since Unix epoch). Strictly ordered after the per-record HLCs in the batch. |
| `hlc.logicalCount` | int32 | HLC logical counter. |
| `hlc.nodeID` | int32 | HLC node ID. For Federation, a random value in `[1, 15]` chosen at engine init (not a registry-assigned slot — Federation does not replicate the CloudKit 15-slot registry). |

**Response (202 Accepted):**

```json
{
  "accepted": true,
  "seqno":    <uint64>
}
```

`seqno` is the server-assigned monotonic sequence number for this
envelope in the recipient's inbox. The client may ignore this field at v1;
it is included for future acknowledgement flows.

**Idempotency:** the server deduplicates on `(senderPublicKey, hlc)`.
A second POST of the same `(senderPublicKey, hlc)` tuple returns 202
with the original `seqno` and does not create a duplicate inbox entry.
This is the server's at-most-once guard. The client's at-least-once
guarantee is the durable outbox (WC2): the outbox retains records until
`send` returns 202, re-sending on transport failure. Together these
guarantee at-least-once delivery with server-side dedup.

**Error responses:** see § 4.

---

#### GET /v1/inbox/{recipientKey}?after={seqno}

Poll the recipient's inbox for pending envelopes.

`{recipientKey}` is the same 64-char lowercase hex key as in `/send`.
`after` is optional; when omitted the server returns all retained envelopes
from the start of the retention window. The client passes the highest `seqno`
it has successfully processed to retrieve only newer envelopes.

**Request headers:**

```
Authorization: Bearer {token}
X-Sync-Protocol: 1
```

**Response (200 OK):**

```json
{
  "envelopes": [
    {
      "seqno":           <uint64>,
      "senderPublicKey": "<base64>",
      "payloadKind":     1,
      "payload":         "<base64>",
      "signature":       "<base64>",
      "hlc": {
        "physicalTime":  <int64>,
        "logicalCount":  <int32>,
        "nodeID":        <int32>
      }
    }
  ],
  "nextAfter": <uint64 | null>
}
```

`envelopes` is ordered by `seqno` ascending. An empty array means no new
envelopes since `after`. `nextAfter` is the highest `seqno` in this
response; the client stores it as the cursor for the next poll. When
`envelopes` is empty, `nextAfter` equals the `after` query parameter
(or `0` when `after` was omitted and the inbox is empty).

The hosted relay `Relay` conformer maps `drain(for:)` to this endpoint:
one GET call per `pull()` cycle, using the stored cursor. The response
envelopes are returned as `[SignedEnvelope]` to the caller.

**Delivery semantics:** the server retains envelopes for the inbox
retention window (§ 3.3) regardless of how many times they are polled.
The cursor advances only when the client explicitly passes a higher `after`
value. This gives at-least-once delivery: the client can re-poll the same
window after a crash without losing envelopes.

**Poll cadence guidance:**

The client conformer should poll on a tiered schedule:

| Tier | Interval | When |
|---|---|---|
| Active | 30 s | Within 5 min of receiving at least one envelope on the last poll |
| Idle | 5 min | Otherwise |

These are guidance values for the v1 client. The adaptive poll scheduler
(B-11 spirit) is deferred to post-WC7 iteration; the WC7 conformer uses
a fixed interval configurable at init. The server must tolerate any client
cadence within reason; rate-limiting is a server-side enforcement concern.

**Error responses:** see § 4.

### 1.3 Canonical signing bytes layout

The `signature` field in `SignedEnvelope` covers a canonical deterministic
byte sequence. The server must not re-verify signatures (it is a dumb
store-and-forward relay), but a conformance test must verify this layout
matches the Swift and Rust implementations.

Layout (all integers little-endian):

```
sender_public_key  (32 bytes, Ed25519 pubkey raw)
payload_kind       (1 byte: PayloadKind raw uint8 value)
payload_len        (4 bytes: LE uint32 count of payload bytes)
payload            (payload_len bytes: opaque batch bytes)
hlc.physicalTime   (8 bytes: LE int64)
hlc.logicalCount   (4 bytes: LE int32)
hlc.nodeID         (4 bytes: LE int32)
```

Total overhead: 53 bytes + payload length.

This byte sequence is produced by `envelopeSigningBytes(...)` in
`Sources/ConvergenceKitFederation/FederationSyncEngine.swift` and by
`envelope_signing_bytes` in `packages/kits/ConvergenceKit/rust/src/federation.rs`.
Both are byte-identical; the cross-port golden vector lives in both test suites.

**The signature covers canonical bytes, not raw JSON.** This closes the
relabel/replay seam: an attacker cannot change `senderPublicKey` or
`payloadKind` in the JSON body without invalidating the signature.

---

## § 2 — Authentication

### 2.1 Bearer token per estate

Every request carries an `Authorization: Bearer {token}` header. The token:

- Authorizes the transport call (admission control — prevents envelope spam
  from unknown callers).
- Is per-estate, provisioned out-of-band (see § 2.2).
- Grants transport access only. It never grants trust over envelope content;
  all content trust derives from Ed25519 signatures (I-7). The server must
  not conflate transport authorization with content trust.

The hosted relay client conformer holds the bearer token at init:

```swift
// Conceptual init signature for the WC7 hosted relay conformer.
// The token is an opaque string; its format is a server concern.
HostedRelay(baseURL: url, bearerToken: token)
```

The token is not part of the `Relay` protocol — it is internal to the
conformer. The `Relay` protocol remains clean.

### 2.2 Token provisioning

Token provisioning is a server-side concern and is out of scope for this
protocol document. The server decides how tokens are issued (API key, OAuth
client credentials, signed JWT, etc.). This document does not prescribe or
constrain that mechanism. The only constraint is the wire format:
`Authorization: Bearer {token}` per RFC 6750.

### 2.3 Authentication failure

A missing or invalid token returns HTTP 401 with the error body defined in
§ 4. The client conformer maps a 401 response to `SyncError.authenticationFailed`.

---

## § 3 — Delivery Semantics

### 3.1 At-least-once delivery

The protocol provides at-least-once delivery. Senders must tolerate
re-delivery of envelopes they have already sent; receivers must apply
envelopes idempotently.

The mechanism has two layers:

**Sender side (WC2 durable outbox):** `FederationSyncEngine.push()` appends
outbox entries to `_fed_outbox` before calling `relay.send()`. The outbox
entry clears only after `send` returns without error (202). On transport
failure, the entry remains and is retried on the next `push()` cycle. This
ensures no envelope is silently dropped on process death or network failure.

**Receiver side (LWW gate):** applying the same `SyncRecord` twice is
idempotent under the LWW conflict policy. The `_fed_sync_meta` side table
records the winning HLC per `(kitID, table, rowKey)`. A re-delivered record
with an equal or lower HLC is silently dropped by the LWW gate (SPEC B-4);
it does not produce duplicate rows or spurious events.

### 3.2 Envelope idempotency key

The server-side dedup key is `(senderPublicKey, hlc)`:

- `senderPublicKey` uniquely identifies the sender estate.
- `hlc` (`physicalTime`, `logicalCount`, `nodeID`) is minted per-envelope
  by `HLCGenerator.send(now:)` at the end of each `push()` call — it is
  strictly ordered after all per-record HLCs in the batch (see source at
  `FederationSyncEngine.swift`, push path).

Together these form a compound key that uniquely identifies one push batch.
A server may additionally index on `signature` (64 bytes) as a cheaper
equality check before verifying the full key.

### 3.3 Inbox retention window

The server retains envelopes for a recipient inbox for **7 days** from the
time of acceptance. Envelopes older than the retention window may be evicted.

Rationale: 7 days covers a device that has been offline for a week without
losing federation history. Longer retention requires server-side storage
budget negotiation and is a server concern.

Clients must not assume envelopes remain after the retention window. Senders
hold the ground truth in `_fed_outbox`; they must re-send if the recipient
missed an envelope within the window.

### 3.4 Record-level idempotency (existing convergence guarantee)

Even without server-side dedup, the existing convergence guarantee applies:
the receiver's `_fed_sync_meta` compound key `(kitID, table, rowKey)` tracks
the winning HLC per row. Applying the same SyncRecord repeatedly converges
to the same state (the LWW gate is monotone). This guarantee holds across
process restarts because `_fed_sync_meta` is a durable SQLite side table.

The SPEC B-10 schema-skew pending queue (`_fed_pending_skew`) uses
`upsertSync` (echo-suppressed origin) when enqueuing held records, so
re-enqueueing the same record is also safe.

---

## § 4 — Error Taxonomy

HTTP status codes and their mapping to `SyncError` categories.

| HTTP | Condition | `SyncError` mapping | Retry |
|---|---|---|---|
| 202 | Send accepted | (success) | |
| 200 | Poll response | (success) | |
| 400 | Malformed JSON body, missing required field, unknown payloadKind, publicKey not 32 bytes | `transportFailure(detail:)` | No (fix the request) |
| 401 | Missing or invalid bearer token | `authenticationFailed(detail:)` | No (re-provision token) |
| 403 | Token valid but not authorized for this operation | `authenticationFailed(detail:)` | No (server policy) |
| 404 | Recipient public key not registered | `peerUnreachable(identity:)` | Retry after recipient registers |
| 409 | Conflict (duplicate envelope, server dedup triggered) | Treat as 202 (idempotent) | |
| 429 | Rate limit exceeded | `transportFailure(detail:)` | Yes, after Retry-After header |
| 500, 502, 503, 504 | Server error or unavailable | `peerUnreachable(identity:)` | Yes (durable outbox retry) |
| Network error (no response) | Connection refused, timeout, TLS failure | `transportFailure(detail:)` | Yes (durable outbox retry) |

**Error body (all 4xx and 5xx responses):**

```json
{
  "error": "<machine-readable code string>",
  "detail": "<human-readable description>"
}
```

`error` is a stable lowercase-underscore code (e.g. `"token_invalid"`,
`"recipient_not_found"`). Clients may switch on `error` for programmatic
recovery; `detail` is for logs only.

**Client behavior on transport failure:**

The hosted relay conformer's `send(to:message:)` method returns normally
on transport failure (consistent with the in-process `FederationRelay`
contract — `Relay.send` has no throwing signature). The caller
(`push()`) must tolerate relay send failure and leave records in
`_fed_outbox` for retry. The durable outbox (WC2) is the retry substrate.

---

## § 5 — Versioning

### 5.1 Protocol version header

Every request carries:

```
X-Sync-Protocol: 1
```

The server must reject requests with an unrecognized version with HTTP 400
and `{"error": "unsupported_protocol_version", "detail": "..."}`.

### 5.2 Skew posture (B-10 spirit)

The protocol version header mirrors the schema-skew posture of the SPEC
(B-10) applied at the transport layer:

- A client sending `X-Sync-Protocol: 1` to a v2-only server receives 400.
  The client must be updated to continue. It does not lose data — envelopes
  remain in `_fed_outbox` until a compatible client version is deployed.
- A client sending `X-Sync-Protocol: 2` to a v1-only server receives 400.
  The server must be updated to continue.
- A server supporting both v1 and v2 serves both `/v1/` and `/v2/` paths
  concurrently during the transition window.

This posture matches B-10: future-protocol requests are held (in `_fed_outbox`),
not dropped. No data is silently discarded on version mismatch.

### 5.3 PayloadKind extension point

`payloadKind` is the C1 extension point within the envelope:

- `1` (`syncRecordBatch`) — v1.0, stable.
- `2` (`fieldWriteEventBatch`) — reserved; not assigned in v1.

A receiver encountering an unknown `payloadKind` must count the envelope
as a conflict and continue to the next envelope (matching the in-process
engine behavior at `FederationSyncEngine.swift`, pull path: `guard
envelope.payloadKind == .syncRecordBatch`). The server must not reject
unknown `payloadKind` values at the transport layer — it is a dumb relay
and must not inspect or validate payload content.

---

## § 6 — Conformance Checklist

The same conformance requirements apply to both:

- The **in-process `FederationRelay`** (reference implementation).
- The future **HTTPS `HostedRelay` conformer** (WC7 implementation).

Contract tests must pass against both implementations.

### 6.1 In-process FederationRelay (reference)

The `FederationRelay` in
`Sources/ConvergenceKitFederation/FederationSyncEngine.swift` satisfies
the same logical contract via in-memory maps, providing a fast,
deterministic test implementation.

| Requirement | In-process behavior | Test coverage |
|---|---|---|
| send delivers envelope to recipient inbox | `inboxes[recipient].append(message)` | `ConvergenceKitFederationTests` |
| drain clears and returns all pending envelopes for recipient | `inboxes[recipient]` consumed, reset to `[]` | `ConvergenceKitFederationTests` |
| drain of unknown recipient returns empty array | `inboxes[recipient] ?? []` | `ConvergenceKitFederationTests` |
| send is thread-safe | `NSLock` guarded | `ConvergenceKitFederationTests` |
| Signatures verified at pull before any record is applied | `FederationSignature.verify(...)` using registered peer key | `ConvergenceKitFederationTests` |
| Unknown payloadKind counted as conflict | guard in pull() | `ConvergenceKitFederationTests` |
| senderPublicKey mismatch vs registered peer key — rejection | guard in pull() | `ConvergenceKitFederationTests` |

### 6.2 HTTPS HostedRelay conformer (WC7)

The `HostedRelay` Swift conformer must satisfy all items in § 6.1 by
driving them through HTTPS against a stub server. Additionally:

| Requirement | Wire behavior |
|---|---|
| `register(publicKey:)` — POST /v1/register succeeds (200) | Verified in conformer tests against stub |
| `send(to: recipient, message:)` — POST /v1/send/{recipientHex} carries correct JSON body | Field-by-field JSON schema check in conformer tests |
| `drain(for: recipient)` — GET /v1/inbox/{recipientHex}?after={cursor} | Returns `[SignedEnvelope]`; cursor advances |
| Signature canonical bytes match: `envelopeSigningBytes(...)` byte-identical to `envelope_signing_bytes` | Cross-port golden vector test (existing in both test suites) |
| Bearer token present in every request `Authorization: Bearer {token}` | Verified in stub request handler |
| 401 response — `authenticationFailed` | Conformer maps HTTP 401 |
| 404 response — `peerUnreachable` | Conformer maps HTTP 404 |
| Transport failure — `send` returns normally, records stay in outbox | Conformer does not throw; push() retries from outbox |
| Protocol version header `X-Sync-Protocol: 1` present on every request | Verified in stub request handler |
| At-least-once: duplicate POST of same `(senderPublicKey, hlc)` — 202 or 409, no duplicate inbox entry | Stub verifies dedup; client handles 409 as success |
| Envelope retention: poll with `after={seqno}` returns only newer envelopes | Cursor-based test against stub with pre-seeded inbox |

### 6.3 Contract test framing (WC7 gate)

WC7 is gated on the existence of this spec (CVK-WC7a). The contract tests
in `ConvergenceKitFederationTests` must expand to cover both the
`FederationRelay` and the `HostedRelay` via a shared test protocol.

Concretely: a `RelayConformanceTests<R: Relay>` generic test suite or a
shared fixture that runs against both relay implementations. The same test
body exercises send/drain/idempotency/auth-failure behavior. Both
implementations must pass. This is the contract-test framing that makes
the `Relay` abstraction verifiably fulfilled by the HTTPS conformer.

---

## § 7 — Out of Scope

The following are explicitly not covered by this protocol document.

**Server implementation:** The SyncServer lives in a separate repository.
This document describes what the server must implement; it does not
prescribe the server's technology stack, persistence layer, scalability
posture, or operational model.

**Multi-tenant policy:** Token issuance, per-tenant storage quotas,
namespace isolation, and rate-limit enforcement are server-side concerns.
This protocol specifies only the wire format that any conforming server
must serve.

**aria-mcp access mediation (I-9 boundary):** ConvergenceKit replicates
rows; it does not decide cross-estate access. Multi-estate access policy
is mediated by the access surface (aria-mcp), per architecture invariant
I-9. The hosted relay is a transport layer: it forwards envelopes without
inspecting their content and without enforcing row-level or estate-level
access policy. Any access control above the transport layer is an I-9
concern and belongs to a future aria-mcp program.

**Pairing out-of-band (QR code / AirDrop):** The async cross-machine
pairing flow (B-7 note, named v1.x in the founding decision) is not
part of this protocol. WC6 wires the signed `PairingProposal` /
`PairingAcceptance` handshake for in-process use; the hosted relay
pairing flow (QR code exchange, async channel) is post-WC7 scope.

**Adaptive poll scheduler:** The B-11 adaptive polling for Federation is
deferred to post-WC7 iteration. The WC7 conformer uses a fixed poll
interval configurable at init (§ 1.2 cadence guidance).

**gRPC / WebSocket transport:** v1 is HTTPS-only. gRPC or WebSocket
variants may be introduced in a future protocol version with a new
`X-Sync-Protocol` value and a `/v2/` path prefix.

---

## § 8 — Changelog

| Version | Date | Author | Notes |
|---|---|---|---|
| v0.1 | 2026-07-17 | CVK-WC7a | Initial draft — proposed, awaiting Bob's review |

## Implementation notes (CVK-WC7)

Ambiguities surfaced during implementation of the Swift `HostedRelay` conformer and
`RelayConformanceFixture`. Noted here for spec clarification on next revision.

**§4 "send returns normally on transport failure":** The spec states the conformer's
`send` method returns normally on transport failure, citing compatibility with the
in-process `FederationRelay` contract. However, the Swift `Relay` protocol signature
is `func send(...) throws`, and `FederationSyncEngine.push()` explicitly catches throws
from `relay.send` to implement the "retain on failure" contract via the durable outbox
(WC2). The WC7 implementation throws `SyncError.transportFailure` on network error and
`SyncError.authenticationFailed` on 401/403, consistent with what `push()` expects.
The spec phrase "returns normally" appears to describe the push() behavior (outbox
retains), not the relay.send behavior. Recommend clarifying in next spec revision.

**§1.2 `Relay.drain` / `poll` cadence:** The spec's cadence guidance (30s active /
5min idle) is noted as guidance. The WC7 `HostedRelay.drain` method drives one GET
per call; the caller (FederationSyncEngine.pull()) controls poll frequency. No
scheduler is built into HostedRelay.

**`Data.hex` encoding:** The spec uses lowercase hex for recipient public key in URL
paths (`/v1/send/{64-char-hex}`). The WC7 implementation uses a local `Data.hex`
extension that produces lowercase hex via `String(format: "%02x", byte)`, matching
the spec's 64-char lowercase constraint.

## Status update

Accepted 2026-07-18 (Bob): authoritative Federation relay contract; future SyncServer implementations build to this spec and must pass RelayConformanceTests.
