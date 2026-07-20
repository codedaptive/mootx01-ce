---
task_id: CVK-WC7
stream: worktree-agent-cvk-wc7
status: COMPLETE
date: 2026-07-17
merge_sha: 08f1649f
---

# COMPLETION: CVK-WC7

Status: COMPLETE

## What Was Done

**New file: `Sources/ConvergenceKitFederation/Relay/HostedRelay.swift`**

HTTPS `Relay` conformer that implements the client side of the three
Federation SyncServer v1 endpoints defined in
`docs/reference/FEDERATION_SYNCSERVER_WIRE_PROTOCOL.md` v0.1:

- `POST /v1/register` — register the estate's Ed25519 public key.
- `POST /v1/send/{hex}` — deliver a `SignedEnvelope` to a recipient.
- `GET  /v1/inbox/{hex}?after={cursor}` — poll the local inbox.

Key design choices:
- HTTP I/O injected via `RelayHTTPTransport` protocol; production uses
  `URLSessionRelayHTTPTransport` (DispatchSemaphore bridge over
  URLSession.dataTask). Tests use `FakeRelayHTTPTransport`.
- In-memory cursor management: `drain(for:)` tracks the highest seqno
  seen per recipient and passes `after={cursor}` on each poll. Cursor
  is not persisted — resets on restart, at-least-once via 7-day retention.
- HTTP status mapping (spec §4): 401/403 → `authenticationFailed`,
  404 → `peerUnreachable`, 409 → nil (dedup success), other 4xx/5xx
  → `transportFailure`.
- `@unchecked Sendable` + `NSLock` for cursor dictionary access.

**New file: `Sources/ConvergenceKitFederation/Relay/RelayHTTPTransport.swift`**

`RelayHTTPTransport` protocol (`RelayHTTPRequest` / `RelayHTTPResponse`
value types) providing the sync seam between `HostedRelay` and the
network layer.

**New file: `Sources/ConvergenceKitFederation/Relay/URLSessionRelayHTTPTransport.swift`**

Production `RelayHTTPTransport` conformer. Bridges synchronous
`RelayHTTPTransport.execute(_:)` to async `URLSession.dataTask` via
`DispatchSemaphore`.

**New file: `Tests/ConvergenceKitFederationTests/Relay/RelayConformanceTests.swift`**

Shared relay conformance fixture (spec §6). Runs the 6-row core
conformance checklist against both relay implementations via a shared
`runCoreConformance(relay:inboxKey:senderIdentity:)` function. Also
includes HostedRelay-specific rows (HTTP status mapping, bearer token,
409 dedup, cursor advancement).

## Conformance Fixture — Both-Relay Pass Table

| Row | Assertion | FederationRelay | HostedRelay | Result |
|---|---|---|---|---|
| 1 | Empty inbox before any send | PASS | PASS | PASS |
| 2 | Send routes to recipient inbox | PASS | PASS | PASS |
| 3 | Drain delivers envelope | PASS | PASS | PASS |
| 4 | Envelope fidelity (senderPublicKey, payloadKind, payload, signature, HLC fields byte-identical) | PASS | PASS | PASS |
| 5 | Second drain is empty (cursor/cleared) | PASS | PASS | PASS |
| 6 | Unregistered sender accepted by relay (dumb relay) | PASS | PASS | PASS |

HostedRelay-only rows:

| Row | Assertion | HostedRelay | Result |
|---|---|---|---|
| 7 | register POST succeeds | PASS | PASS |
| 8 | Bearer token on every request (Authorization + X-Sync-Protocol: 1) | PASS | PASS |
| 9 | 401 → authenticationFailed | PASS | PASS |
| 10 | 404 → peerUnreachable | PASS | PASS |
| 11 | 409 treated as success (server-side dedup) | PASS | PASS |
| 12 | Cursor advances: second drain sees only newer envelopes | PASS | PASS |
| 13 | Network error on send → transportFailure | PASS | PASS |

Total conformance tests: 13 (4 FederationRelay suite + 9 HostedRelay suite).

## Test Verification Log

- `swift build` (ConvergenceKit): exit 0, no warnings (2026-07-17)
- `swift test` (full kit, all bundles): exit 0, 235 tests, all passing
  (2026-07-17, at merge point 08f1649f — Adams re-run verified)
- Baseline Swift before WC7: 222 tests (post-WC6, pre-WC7); WC7 added
  +13 relay conformance tests → 235 at merge.

## Dependency Satisfied

WC7 depended on WC1 (identity persistence), WC2 (durable outbox for
retry path on `Relay.send throws`), WC6 (signed pairing + peer
persistence), and the SyncServer wire protocol spec (WC7a). All
dependencies shipped before this mission was admitted to the queue.

## Discoveries

- `HostedRelay.send` encodes `SignedEnvelope` via `JSONEncoder`. The
  `SignedEnvelope` JSON uses `Data` fields which encode as base64 per
  Swift's default. The server spec (§1.2) accepts both standard base64
  and base64url. `FakeRelayHTTPTransport` stores the encoded bytes
  directly (no JSON parse), so fidelity tests pass without a real
  JSON round-trip. A future conformance test with a real JSON round-trip
  through `FakeRelayHTTPTransport`'s decode path would close the gap.
- `drain(for:)` is non-throwing per `Relay` protocol. Network errors log
  and return `[]`, relying on the at-least-once guarantee from the 7-day
  server retention window. This is correct per spec §3.3.
- `URLSessionRelayHTTPTransport` uses `DispatchSemaphore` to bridge
  sync/async. This is intentional: `Relay.send` and `Relay.drain` are
  synchronous (the `SyncEngine.push/pull` caller is already async). The
  bridge is the minimal seam for production use.

## Outstanding

- Hosted relay pairing flow (QR-code, async out-of-band) is deferred.
  WC7 scope was the HTTPS `Relay` conformer and its conformance tests.
  The relay-based pairing path (`pairingProposal`/`pairingAcceptance`
  payload kinds, WC7 extension points) will be addressed in a future
  wave when cross-machine pairing is scoped.
