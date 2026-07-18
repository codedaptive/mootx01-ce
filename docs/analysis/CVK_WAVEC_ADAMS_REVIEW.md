---
title: CVK Wave C Post-Flight Review
reviewer: Adams
date: 2026-07-17
range: 4d9e4549..08f1649f
status: CLEAN-WITH-FOLLOWUPS
---

# POST-FLIGHT: CVK Wave C (Batch 2 + Conformer)

**Final Status: CLEAN-WITH-FOLLOWUPS**

Range reviewed: `4d9e4549..08f1649f`
Missions in scope: WC2 (durable outbox), WC6 (signed pairing + peer persistence),
WC7a (wire protocol spec), WC7 (HostedRelay conformer).
End-state verification also covers batch 1 (WC1/WC3/WC4/WC5) schema composition.

---

## First Pass Findings

| # | Severity | Finding | File:Line | Resolution |
|---|---|---|---|---|
| 1 | WARNING | INTERFACE.md not updated for WC6 API changes: `pair()` signature still shows removed `via relay: any Relay` param; `Relay.send` still shows non-throwing; `PayloadKind` missing `pairingProposal = 0x10` and `pairingAcceptance = 0x11`; `acceptPairingProposal` public method absent; `init()` wrong (should be `init(relay: any Relay = FederationRelay())`). 5+ divergences. | `docs/reference/CONVERGENCEKIT_INTERFACE.md:538–562` | Update §4 FederationSyncEngine block to match shipped WC6 API. Bump INTERFACE version v1.6 → v1.7. |
| 2 | WARNING | Charter parity matrix is stale on 5 rows: "Schema-skew pending queue / Rust: NO (rejects as conflict)" — WC3 fixed; "TombstoneGC / Rust: NO" — WC4 fixed; "Peer persistence: NO / NO" — WC6 implemented; "Signed pairing handshake: TYPED NOT WIRED" — WC6 wired; "Side-schema version: v4 / v4" — now v6. Mission list also missing done markers for WC3, WC4, WC5, WC6. | `docs/analysis/CVK_WAVEC_FEDERATION_CHARTER.md:96–109, 229–344` | Update parity matrix rows and mission list strikethroughs to reflect as-shipped state. |
| 3 | WARNING | Missing WC7 completion report. Charter marks WC7 done (strikethrough) but `docs/status/CVK_WC7_COMPLETION.md` does not exist. WC2 and WC6 both have completion records; WC7 does not. Code and tests are present and verified passing. | `docs/status/` (absent) | Author `docs/status/CVK_WC7_COMPLETION.md` covering HostedRelay, RelayConformanceTests, test counts at merge point. |
| 4 | WARNING | `familyMismatchRejected` test validates a boolean condition, not the code path. The test constructs a `PairingAcceptance` with wrong family then asserts `tamperedAcceptance.acceptedFamily != intendedFamily` — a manual check. `pair()` is never called with the tampered acceptance, so the `guard acceptance.acceptedFamily == family` branch in `FederationStateActor.pair()` is unexercised by any test. The guard is correct in code; the test gap is real. | `Tests/ConvergenceKitFederationTests/FederationPairingTests.swift:355–399` | Refactor test to inject a tampered acceptance through the real `pair()` execution path. One approach: expose a test-only hook on the peer actor that returns a misbehaving acceptance, or call the proposer-guard check directly by constructing a minimal scenario where `acceptProposal` is mocked to return the wrong family. |
| 5 | INFO | WC2 completion report states "88 federation tests" under `swift test --filter ConvergenceKitFederation`. At final merged HEAD that count is 104 (WC6 +3, WC7 +13 relay conformance). The 235 full-kit claim in the report matches HEAD; the 88 is accurate for the WC2 worktree state but misleads a reader comparing it against the current count. Not a code issue. | `docs/status/CVK_WC2_COMPLETION.md:57–58` | No action required. Noted for context. |

---

## Blast Radius Verification

**CVK-WC2 BRR** (`docs/blast_radius/CVK-WC2_BLAST_RADIUS.md`): exists, baseline 83 recorded.

| Check | Result |
|---|---|
| BRR exists | PASS |
| Baseline test count recorded | PASS — 83 federation tests at mission start |
| MUST_UPDATE files in diff | PASS — FederationSyncEngine.swift, federation.rs, FedOutboxStore.swift (new), FederationDurableOutboxTests.swift (new), federation_durable_outbox_tests.rs (new), CVKWaveB4PrecisionTests.swift, FederationPairingTests.swift all present |
| INTENTIONALLY_LEFT justifications | PASS — no INTENTIONALLY_LEFT entries in BRR |
| Prohibited patterns (bridge, shim, orphan deprecated, TODO) | PASS — none found |
| Stale "sibling worktree" / "root reconciles" comments in merged code | PASS — none found in packages/kits/ConvergenceKit/ at HEAD |

No CVK-WC6 BRR was filed. WC6 touched existing `pair()` and `enable()` call sites across 8 test files (per completion report). The BRR protocol is mandatory for missions touching existing code. This was noted but not treated as CRITICAL here because the completion report enumerates the touched sites explicitly and all 8 test files are in the diff.

---

## Schema Chain Verification

**Both legs — VERIFIED CLEAN.**

| Item | Swift | Rust | Match |
|---|---|---|---|
| SchemaDeclaration version | 6 | 6 | PARITY |
| Table count | 6 | 6 | PARITY |
| Tables (in declaration order) | meta, cols, skew, identity, outbox, peers | meta, cols, skew, identity, outbox, peers | PARITY |
| v1→2 migration | CreateTable(cols) | CreateTable(cols_table) | PARITY |
| v2→3 migration | CreateTable(skew) | CreateTable(skew_table) | PARITY |
| v3→4 migration | CreateTable(identity) | CreateTable(identity_table) | PARITY |
| v4→5 migration | CreateTable(outbox) | CreateTable(outbox_table) | PARITY |
| v5→6 migration | CreateTable(peers) | CreateTable(peers_table) | PARITY |
| Column sets for all tables | 6 matching sets | 6 matching sets | PARITY |
| PK structures | All match (composite where spec'd) | All match | PARITY |
| Date storage invariant (TEXT, not REAL) | `enqueued_at TEXT`, `paired_at TEXT`, `received_at TEXT`, `created_at TEXT` | Same column names, TEXT type | PARITY |
| Stale placeholder comments | None found | None found | CLEAN |

---

## Pairing Security Verification

**PASS on all gates.**

1. **Signature gate — accepter side**: `FederationStateActor.acceptProposal` verifies proposer's signature against `proposal.proposerPublicKey` before any registration. Tampered-proposal test (`tamperedProposalRejected`) exercises this path via `acceptPairingProposal()`. Verified: throws `SyncError.authenticationFailed` on wrong key.

2. **Signature gate — proposer side**: `FederationStateActor.pair()` verifies accepter's signature against `acceptance.accepterPublicKey` and checks `acceptance.acceptedFamily == family`. Guard is in code; family-mismatch test gap noted in Finding #4.

3. **pull() registry gate — Swift**: `peers.first(where: { $0.publicKey == envelope.senderPublicKey })` — registry lookup. Verification uses `peer.publicKey` (registered), not `envelope.senderPublicKey` (claimed). Advisory equality check present. F-3 class protection documented inline (`FederationSyncEngine.swift:821–874`).

4. **pull() registry gate — Rust**: `paired_peers.iter().find(|p| p.public_key == envelope.sender_public_key)` → `registered_key`. Signing bytes and `verify_signature` both use `&registered_key`. Matches Swift exactly (`federation.rs:942–998`).

5. **No half-registered peer**: Both `pair()` and `acceptProposal()` only call `persistPeer` and `peers.append` AFTER signature verification succeeds. Failure throws before registration.

6. **Revoke deferred**: `CONVERGENCEKIT_SPEC.md §B-7` explicitly states "NOT a TODO — it is a deliberate v1.0 scope boundary." Code comment at `FederationSyncEngine.swift:1230` cites §B-7. Clean.

---

## Relay Honesty Verification

**PASS.**

1. **Parameterized conformance**: `runCoreConformance()` is a shared function called from both `FederationRelayConformanceTests.coreConformance()` and `HostedRelayConformanceTests.coreConformance()`. Same 6 rows, same assertions, same expectations for both relay implementations.

2. **Dumb-relay invariant**: Row 6 in `runCoreConformance` explicitly tests that a relay accepts an envelope from an unregistered sender (`unknownSender`) and delivers it to the inbox. The relay does not authenticate senders. The engine's `pull()` registry gate handles rejection.

3. **HostedRelay does not re-sign or interpret**: `HostedRelay.send()` POSTs the `SignedEnvelope` as-is (JSON-encoded). `HostedRelay.drain()` returns the server-stored bytes decoded back to `SignedEnvelope`. No re-signing. `FakeRelayHTTPTransport` stores and returns the identical bytes with no mutation. Envelope fidelity row (Row 4) asserts byte-identity of `senderPublicKey`, `payloadKind`, `payload`, `signature`, and HLC fields after round-trip.

4. **409-as-dedup**: `mapStatusToError` returns `nil` for 409 (success). `FakeRelayHTTPTransport` generates 409 on `(senderPublicKey, hlcPacked)` collision. `duplicateSend409TreatedAsSuccess` test exercises the full path.

5. **Error mapping per §4**: 401/403 → `authenticationFailed`, 404 → `peerUnreachable`, network error → `transportFailure`. Tests: `authFailureMaps401`, `notFoundMapsPeerUnreachable`, `networkErrorMapsTranportFailure`.

---

## Durable Outbox Composition Verification

**PASS — no path where send succeeds but confirm is skipped.**

- `push()` sets `anyPeerFailed = true` in the catch block. `FedOutboxStore.confirm` is called only if `!anyPeerFailed`. If any peer fails, all entries are retained (conservative at-least-once). No silent discard.

- `enable()` order is coherent: `ensureFedSyncMetaTable` → `loadOrMintIdentity` → `FedOutboxStore.count` (drain-log) → `reloadPeers` → `SkewReplay.drainReady` → start observers. Each step depends on the previous (schema must exist before identity; identity before peers; peers before observers). Verified at `FederationSyncEngine.swift:338–419`.

- `disable()` is complete: `isEnabled = false` → `relay = nil` → cancel+await observer tasks → clear subscribers → `peers.removeAll()` → `manifest = nil` → `storage = nil`. Observer tasks are awaited (not just cancelled) to prevent buffered changes landing in the outbox after disable. Storage is nilled but not deleted; outbox entries persist on disk.

- Storage capture in `push()`: local `let storage = self.storage` binding before any await points. Concurrent `disable()` cannot null the captured reference mid-push.

---

## Test Execution Verification

Method: **Option B (re-run)**. Range touches engine code, schema, and pairing.

**Swift:**
```
swift test (full kit, all bundles)
Test run with 235 tests in 45 suites passed after 2.051 seconds.
EXIT: 0
```
Bilby's claim: exit 0, 235 tests. **MATCH.**

**Rust:**
```
cargo test (ConvergenceKit/rust)
16 + 5 + 5 + 4 + 5 + 6 + 25 + 5 + 4 + 16 + 8 + 27 + 0 = 126 tests
All binaries: ok. 0 failed.
EXIT: 0
```
WC2 claimed 123 Rust tests; WC6 added 3 = 126. **VERIFIED at 126, exit 0.**

Status: **PASS**

---

## Verification Pass

Findings #1, #2, #3, #4 are open WARNINGs; none are blocking.
Finding #5 is INFO; no action needed.

| # | Severity | Status | Notes |
|---|---|---|---|
| 1 | WARNING | open | INTERFACE.md §4 FederationSyncEngine block needs WC6 update |
| 2 | WARNING | open | Charter parity matrix + mission list needs batch-2 updates |
| 3 | WARNING | open | Author `docs/status/CVK_WC7_COMPLETION.md` |
| 4 | WARNING | open | `familyMismatchRejected` test gap — proposer guard untested via real `pair()` |
| 5 | INFO | — | No action; completion report count accurate for worktree state |

---

## Verdict

Zero CRITICAL findings. Four WARNINGs, all documentation or test-gap class.
Code is correct. Schema chain is clean and byte-parallel. Security gates verified
on both legs. Tests pass, exit 0, counts verified by re-run. No bridges, shims,
orphan deprecations, or conflict markers.

**CLEAN-WITH-FOLLOWUPS. WARNINGs 1–4 must be addressed before Wave D.**
