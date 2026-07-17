---
title: Wave C Federation Program Charter
version: v0.1
status: active
date: 2026-07-17
mission: CVK-WC0
reviewer: Kong
relates_to:
  - docs/decisions/DECISION_SYNCKIT_DESIGN_2026-05-19.md
  - docs/decisions/DECISION_FEDERATION_SHARING_MODEL_2026-05-21.md
  - docs/reference/CONVERGENCEKIT_SPEC.md (v1.2)
  - docs/reference/CONVERGENCEKIT_INTERFACE.md (v1.6)
  - docs/status/CVK_ICLOUD/TRACKED_FOLLOWUPS.md (rows 10, 11)
  - docs/analysis/CVK_ICLOUD_PERKINS_REVIEW.md
---

# Wave C Federation Program Charter

## Assessment

Wave C is the estate-to-estate sync program. Wave A/B (CVK-ICLOUD, 30 missions) completed
the CloudKit arm: device-to-device sync for one user's Apple devices. Wave C finishes the
other half of the founding architecture: Federation — substrate-native CRDT exchange between
distinct estates, across machines, across users, and across perimeter boundaries.

The Relay abstraction is already in place (INTERFACE §4, B-7). The engine signs and verifies
envelopes with Ed25519. The core CRDT behaviors (fieldLevelLWW, tombstone LWW, column
projection, echo suppression) shipped with full Rust parity in Wave B. The path to a working
multi-machine federation is shorter than the path was to CloudKit, because most of the hard
infrastructure is already deployed. But three gaps block production use: identity is ephemeral
(process restart destroys it), outbound changes are lost on process death, and no hosted relay
exists. Those three gaps are Wave C's primary payload.

The DECISION_FEDERATION_SHARING_MODEL_2026-05-21.md (grants, content axis, tell record,
risk-level chooser) is **explicitly out of scope for Wave C.** SPEC I-9 is unambiguous:
"Multi-estate access policy is mediated by the access surface (aria-mcp), per architecture
invariant I-13." That document is an aspirational design for a future program. Wave C ships
the row-sync transport only.

---

## Verdicts

1. **Founding promises vs. shipped — LARGE GAP.** The founding decision committed to a
   durable per-estate Ed25519 identity surviving restarts and an out-of-band QR pairing flow.
   Neither exists. LocalIdentity() generates a fresh keypair on each init. PairingProposal and
   PairingAcceptance types are defined but not wired into pair(). Every process restart
   invalidates all peers. This is the single highest-priority gap: identity persistence gates
   everything else.

2. **Durability parity — STRAIGHTFORWARD.** The in-memory `pendingOutbound: [TableChange]`
   can be replaced by a `_fed_outbox` SQLite-backed OutboxStore without architecture rework.
   The shape is the same as `_ck_outbox`. The Relay call (relay.send) replaces
   CKModifyRecordsOperation. Echo suppression is preserved: records enter the outbox from
   `recordOutbound`, which already guards `change.origin != .syncApply`. The main decision
   to take: store TableChange or SyncRecord in the outbox. Store SyncRecord (post-encoding),
   mirroring CloudKit exactly, so the drain path reads the final wire unit and the outbox
   entries are self-contained. The debouncer (B-11 note says "not symmetrically applicable")
   is deferred until the hosted relay is async.

3. **Hosted Relay production needs — THIS REPO vs. SERVER REPO split is clean.** The Relay
   protocol already defines the seam (§4, INTERFACE). This repo delivers the hosted relay
   client conformer (HTTPS/gRPC `Relay` conformer, auth credential at init, retry via the
   durable outbox). The SyncServer lives in a separate repo. Auth beyond Ed25519 message
   signing: the relay server needs bearer-token or API-key client auth to prevent envelope
   spam from unknown callers. Ed25519 signing is content integrity; relay auth is admission
   control — two distinct layers, do not conflate. The wire relay protocol needs a spec
   (endpoint shape, envelope submit/poll, routing by public key).

4. **Wire hardening (SyncValueBox depth cap, row 11) — SIMPLE.** `maxDepth: Int = 3` cap on
   Swift decode; depth counter on Rust serde deserializer. Both legs, one small mission.
   No architecture consequences.

5. **Pairing lifecycle — PARTIAL. V1-necessary scope is contained.** V1 requires: identity
   persistence (WC1), peer persistence (WC6), and the signed PairingProposal/PairingAcceptance
   exchange wired into the engine. V1-deferred: AirDrop pairing (named v1.x in the decision),
   key rotation, re-pair UI flows (engine-external, out of scope).

6. **Cross-leg parity — THREE DRIFTS, all fixable.** Rust skew-queue missing (B-10/C-15),
   Rust TombstoneGC missing (CVK-WB7 analogue), Rust side-schema at v2 when Swift is at v3.
   All three are simple Rust additions, no design decisions required. They should ship before
   the hosted relay lands, so both legs are ready for the same test vector.

---

## Parity Matrix

Wave A/B behaviors and their current Federation parity. "FED" means "Federation backend
(both Swift and Rust unless otherwise noted)."

| Behavior | SPEC ref | Swift FED | Rust FED | Status |
|---|---|---|---|---|
| Echo suppression | C-9, I-10 | YES (origin guard) | YES (pulling AtomicBool) | PARITY |
| fieldLevelLWW merge | B-8, C-10 | YES | YES (CVK-WB9) | PARITY |
| Column projection | B-14, C-11 | YES | YES | PARITY |
| Tombstone LWW + A6 footprint | B-9, C-12 | YES | YES | PARITY |
| postApplyIntegrityHook (R3) | B-7 note | YES | YES (code present) | PARITY |
| Parked outbox purge on tombstone | B-9 note | YES (P5-M1b) | N/A (no outbox yet) | N/A |
| Schema-skew pending queue | B-10, C-15 | YES (_fed_pending_skew v3) | NO (rejects as conflict) | **DRIFT** |
| TombstoneGC | B-9 note | YES (gcIfDue after pull) | NO | **DRIFT** |
| Side-schema version | B-12 | v4 | v4 | **PARITY (WC1)** |
| Durable outbox | I-12, B-11 | NO (in-memory) | NO (in-memory) | PARITY (both missing) |
| Identity persistence | I-8 | YES (_fed_identity v4) | YES (_fed_identity v4) | **PARITY (WC1)** |
| Peer persistence | I-8 | NO | NO | PARITY (both missing) |
| Signed pairing handshake | B-7 | TYPED NOT WIRED | TYPED NOT WIRED | PARITY (both missing) |
| SyncValueBox depth cap | row 11 | NO | NO | PARITY (both missing) |
| Adaptive poll scheduler | B-11 | NO (deferred) | NO (deferred) | PARITY (both deferred) |

---

## Risks

| Risk | Severity | Mitigation |
|---|---|---|
| Identity ephemeral → re-pair on every restart | HIGH | WC1 fixes this. Gate all subsequent missions on WC1 complete. |
| Rust skew-queue drift → cross-leg skew behavior diverges | MED | WC3 adds _fed_pending_skew to Rust. Simple port of Swift v3 schema. |
| Durable outbox → echo suppression invariant needs care on restart | MED | On restart, outbox entries are already SyncRecord (post-encoding). They carry no origin field — they are by definition local writes (the suppression happened at observe time). Document this explicitly in WC2 spec. |
| Hosted relay bearer-token auth not in Relay protocol | MED | Keep auth internal to the conformer. Relay protocol stays clean. Spec the SyncServer wire protocol explicitly before WC7. |
| PairingProposal/PairingAcceptance not wired → signatures bypassed | MED | WC6 wires the signed handshake. Until WC6 ships, pairing is caller-supplied family spec — acceptable for in-process tests, not acceptable for hosted relay. WC7 should gate on WC6. |
| SyncValueBox recursive decode → potential stack exhaustion on hostile input | LOW | WC5 caps at depth 3. Perkins confirmed this is advisory (no current exploit path on closed-channel relay). |
| DECISION_FEDERATION_SHARING_MODEL_2026-05-21.md not implemented | ACCEPT | Correctly deferred to aria-mcp layer. Not Wave C scope. Wave C does not create a gap — it creates the row-sync transport the access layer will sit on top of. |

**Non-obvious risk:** The durable outbox interacts with the per-machine HLC node identity. If identity is not yet persisted (pre-WC1) and a process restarts, the new identity has a different node ID. Outbox entries minted under the old node ID will be pushed under the new node ID in the batch HLC. Since Federation uses random node IDs in [1,15] without the CloudKit slot registry, there is no `reenrollRequired` fence for Federation. The HLC ordering is soft: node collision is possible but the probability is low (1/15 per pair). This matches the founding decision's design choice — Federation does not replicate CloudKit's 15-slot registry. Accept. Document this asymmetry in the Federation engine comment block.

---

## Dependencies

**Depends on (already shipped):**
- ConvergenceKit v1.2 (SPEC + INTERFACE at current versions)
- PersistenceKit OutboxStore (reusable for _fed_outbox)
- PendingSkewQueue / SkewReplay (reusable for Rust port)
- TombstoneGC (reusable for Rust port)
- FederationRelay (in-process; stays for tests)
- SubstrateTypes HLC, Ed25519 via CryptoKit (Swift) / ed25519-dalek (Rust)

**Affects:**
- CONVERGENCEKIT_SPEC.md: B-11 note (Federation debouncer deferred) will need a sentence when durable outbox ships; I-12 currently says "CloudKit backend specific" — update when _fed_outbox lands
- CONVERGENCEKIT_INTERFACE.md: FederationSyncEngine Swift init signature may grow (identity storage path); FederationSyncEngine Rust new() will need identity arg if Rust adds persistence
- docs/status/CVK_ICLOUD/TRACKED_FOLLOWUPS.md rows 10 and 11 — both close with Wave C missions

**Conflicts with:** None. The Relay abstraction was designed for this exact extension. No competing open ADRs identified.

---

## Mission List

Seven missions, two can run in parallel after WC1.

---

### ~~WC1 — Federation identity persistence (FOUNDATION GATE)~~ DONE (CVK-WC1, 2026-07-17)

**Completed:** `_fed_identity` side table added (Swift v3→v4, Rust v2→v4 via sequential
migrations). `loadOrMintIdentity` / `load_or_mint_identity` persist the Ed25519 keypair at
`enable()`. Identity survives disable/enable and process restart. Rust v2→v3 carries
`_fed_pending_skew` table schema (behavioral logic in WC3). 231 Swift / 103 Rust tests, both
exit 0. SPEC I-8 and B-7 updated.

**Scope:** LocalIdentity must survive process restarts. Both legs.

Swift: store the Ed25519 private key in PersistenceKit's blob store at a well-known key
(`"federation.local_identity.v1"`). On init, attempt to load; generate and persist if absent.
The init() constructor cannot be async — add a `FederationSyncEngine.load(from: any Storage)`
async factory or defer load to `enable()`. The enable-time load is cleaner (Storage is already
required at that point). Rust: same pattern via `LocalIdentity::from_secret` + store into
the _fed_sync_meta table (or a dedicated row in _fed_identity side table).

Decision required before WC1 starts: store identity in _fed_sync_meta (reuses existing
infrastructure) or add a dedicated `_fed_identity` side table (cleaner separation). Recommend
`_fed_identity` side table: one row, two columns (key_id TEXT PK, secret_key BLOB). Schema
version 4 for the Federation schema (currently at v3 on Swift, v2 on Rust — WC1 ships v4 on
both after WC3 brings Rust to v3).

**Files (Swift):** `FederationIdentity.swift`, `FederationSyncEngine.swift` (enable path),
`FederationStateActor` (ensureFedSyncMetaTable → add _fed_identity table at v4)

**Files (Rust):** `src/federation.rs` (ensure_fed_sync_meta_table → v4, identity load/store),
`src/federation.rs` (LocalIdentity persistence helpers)

**Verify:** `LocalIdentity` generated on first enable; reloaded identical on second enable of a
new engine against same storage. Public key matches across both enables.

**Worker:** sonnet-4-6. **Tier:** 1 (primitive-touching).

---

### WC2 — Federation durable outbox (DURABILITY)

**Scope:** Replace `pendingOutbound: [TableChange]` with a SQLite-backed `_fed_outbox` table
using the existing OutboxStore infrastructure. Swift only (Rust in-memory outbox is lower
priority; Rust parity can follow in a subsequent wave when the Rust leg needs cross-machine
production use). Schema version 5.

Store SyncRecord (post-encoding) in `_fed_outbox`, mirroring CloudKit's `_ck_outbox` layout.
At `recordOutbound()`, convert TableChange to SyncRecord immediately and append to OutboxStore
via `OutboxStore.append`. The push() drain reads `OutboxStore.readBatch`, encodes to payload,
signs, relays. Per-record confirmation on relay success (clear from outbox after relay.send
returns without error). For the in-process relay, relay.send is synchronous and never fails,
so the clear is always immediate. For the hosted relay (WC7), relay.send may fail; the parked
outbox logic handles retry.

Echo suppression: records enter the outbox from recordOutbound, which already guards
`change.origin != .syncApply`. Records loaded from the durable outbox on restart are SyncRecord
(they were already origin-filtered at observe time). No echo suppression change needed.

Note on spec B-11: the spec note says "Federation does not apply a symmetric debouncer."
This remains true — WC2 adds durability, not debounce. Add a spec note: "The _fed_outbox
durable side table was added in Wave C (WC2); debounce is still deferred until the hosted
relay introduces meaningful async latency."

**Files (Swift):** `FederationSyncEngine.swift` (recordOutbound, push), `FederationStateActor`
(ensureFedSyncMetaTable → add _fed_outbox at v5). SPEC B-11 note update.

**Verify:** Enable engine, write 3 rows, kill the actor before push, re-enable: 3 outbox
entries survive. Push delivers all 3 to relay inbox.

**Worker:** sonnet-4-6. **Tier:** 1 (primitive-touching). **Depends on:** WC1 (schema v4 → v5).

---

### WC3 — Rust skew-queue parity (PARITY)

**Scope:** Bring the Rust FederationSyncEngine to schema v3 parity with Swift: add
`_fed_pending_skew` table (schema v3), port the skew-queue hold-and-replay logic from Swift's
`enable()` and `pull()` paths. Closes TRACKED_FOLLOWUPS row 10 (partially) and the B-10/C-15
DRIFT row.

Swift has: `PendingSkewQueue.swift`, `SkewReplay.swift`, enable-time replay in
`FederationStateActor.enable()`, pull-time enqueue in `FederationStateActor.pull()`.

Rust needs: `_fed_pending_skew` schema (v3 in `ensure_fed_sync_meta_table`); pull() replaces
the current `if record.schema_version != manifest.schema_version { conflicts += 1; continue }`
with the schema-skew split (future-schema → enqueue; downgrade-schema → conflict); enable()
runs drain-and-replay from the queue.

No new Rust crate dependencies required — PendingSkewQueue logic is pure SQL on PersistenceKit
RowStore, which Rust already has.

**Files (Rust):** `src/federation.rs` (ensure_fed_sync_meta_table → v3, pull schema-skew
split, enable replay). Optionally new helper functions `rust_pending_skew_enqueue` /
`rust_pending_skew_drain_ready` mirroring Swift.

**Verify:** `cargo test -p convergence-kit` green. New test: future-schema record enqueued
in _fed_pending_skew during pull; replayed on re-enable with matching schema version.

**Worker:** sonnet-4-6. **Tier:** 1 (primitive-touching). **Can run in parallel with WC2.**

---

### WC4 — Rust TombstoneGC parity (PARITY)

**Scope:** Port `gcIfDue` (CVK-WB7 pattern) to the Rust FederationSyncEngine.pull() path.
Closes the TombstoneGC DRIFT row.

Swift has `FederationStateActor.gcIfDue(nowMs:)`, which reads a sentinel row from
`_fed_sync_meta`, calls `TombstoneGC.compact`, writes the sentinel back. Called after each
successful pull.

Rust needs: equivalent `gc_if_due` free function called from `pull()` after the apply loop.
TombstoneGC.compact is already ported to Rust (CVK-WB7 covered both backends). If not: port
it. Sentinel row convention is identical to Swift.

**Files (Rust):** `src/federation.rs` (gc_if_due helper, pull() call site).

**Verify:** `cargo test -p convergence-kit` green. New test: tombstone entries older than
retention window are compacted; entries inside retention window survive.

**Worker:** sonnet-4-6. **Tier:** 2 (UI-bounded equivalent — additive to existing pull path,
no primitive changes). **Can run in parallel with WC2 and WC3.**

---

### WC5 — SyncValueBox depth cap (WIRE HARDENING)

**Scope:** Closes TRACKED_FOLLOWUPS row 11. Add `maxDepth: Int = 3` parameter to
`SyncValueBox.fromJSON` (or the recursive Codable init) in Swift; add a recursive depth
counter to the Rust serde deserializer for `SyncValueBox`. Both legs. Additive, no wire
format change.

Test: a 4-level `SyncValueBox.array` payload returns `.decodingFailure` (Swift) / `Err`
(Rust) instead of succeeding.

Perkins rated this advisory. Fix is warranted as defense-in-depth before any hosted relay
is wired (hosted relay surfaces to an external network vs. the current closed-channel).

**Files (Swift):** `packages/kits/ConvergenceKit/Sources/ConvergenceKit/SyncRecord.swift`
(SyncValueBox Codable init).

**Files (Rust):** `packages/kits/ConvergenceKit/rust/src/record.rs` (SyncValueBox
Deserialize implementation).

**Verify:** Test that a 4-level array decode returns error on both legs.

**Worker:** sonnet-4-6. **Tier:** 3 (net-new guard, no edits to existing call sites).
**Can run in parallel with WC2, WC3, WC4.**

---

### WC6 — Pairing lifecycle persistence (PAIRING)

**Scope:** Two sub-tasks in one atomic mission:

(a) Peer persistence: add `_fed_peers` side table (schema v6 after WC1's v4 and WC2's v5).
Schema: (peer_id UUID PK, public_key BLOB, family_seed INT, family_dimension INT). On
`pair(with:via:family:)`, write the peer to `_fed_peers`. On `enable()`, reload peers from
`_fed_peers` and register them with the relay. On `disable()`, leave `_fed_peers` intact
(peers survive disable/enable cycle). Add a `removePeer(publicKey: Data)` method for
revocation.

(b) Signed pairing handshake: wire `PairingProposal` and `PairingAcceptance` into
`pair(with:via:family:)`. The proposer sends a `PairingProposal` (proposerPublicKey,
proposedFamily, nonce) via the relay; the accepter verifies the proposer's key, sends back
a `PairingAcceptance` (accepterPublicKey, acceptedFamily, signatureOfProposal). Both engines
verify before recording the peer. The in-process relay already passes SignedEnvelope; use
a new `PayloadKind` value for pairing messages (e.g., `pairingProposal = 0x10`,
`pairingAcceptance = 0x11`). The engine must handle unknown PayloadKind gracefully (count as
conflict, not crash — already enforced in pull()).

Note: the current `pair(with:via:family:)` takes a peer engine reference directly (in-process
only). The production pairing path will need an async flow where A sends a proposal over the
relay and waits for B's acceptance — this is the cross-machine pairing entry point. For WC6,
implement this for the in-process relay (both sides available in the same process). The hosted
relay pairing flow (out-of-band QR code, async) is WC7 scope.

**Files (Swift):** `FederationSyncEngine.swift`, `FederationStateActor` (peer persistence,
pair method, removePeer), `FederationIdentity.swift` (no change), `HyperplaneFamilyExchange.swift`
(PairingProposal/PairingAcceptance wired), `PayloadKind` (new cases).

**Verify:** Two engines pair in-process; kill and re-init engine A; re-enable against same
storage; engine A reloads the peer from _fed_peers and can push to engine B without re-pairing.
Signed proposal verified; unsigned proposal rejected as conflict.

**Worker:** sonnet-4-6. **Tier:** 1 (primitive-touching — modifies pair(), enable(), FederationStateActor).
**Depends on:** WC1 (identity persistence), WC2 (schema v5 base for v6).

---

### ~~WC7a — SyncServer wire protocol spec (DESIGN GATE)~~ DONE (CVK-WC7a, 2026-07-17)

**Completed:** `docs/reference/FEDERATION_SYNCSERVER_WIRE_PROTOCOL.md` v0.1 authored.
Three endpoints specified (register, send, inbox-poll). SignedEnvelope JSON schema
exact (base64 fields, hlc struct, payloadKind uint8). Bearer-token auth documented.
At-least-once delivery + idempotency via `(senderPublicKey, hlc)` dedup key.
Poll-first (30 s active / 5 min idle cadence guidance). 7-day retention window.
SyncError taxonomy mapped. Conformance checklist covers both FederationRelay (reference)
and future HostedRelay (contract-test framing). I-9 boundary cited. WC7 is unblocked.

---

### WC7 — Hosted relay client conformer (TRANSPORT)

**Scope:** Deliver a production `Relay` conformer that speaks HTTPS (or gRPC). Requires a
SyncServer wire protocol spec (authored first as a design doc, not a code mission — route
through Skippy before opening WC7). The client conformer:

- Implements `Relay.send(to:message:)` as an HTTP POST of the serialized `SignedEnvelope`
  to the relay server, authenticated with a bearer token held by the conformer.
- Implements `Relay.drain(for:)` as an HTTP GET (long-poll or SSE for low latency, or
  polling for simplicity at v1).
- Routing: by recipient public key (32 bytes, hex-encoded in the URL path or as a query
  parameter).
- Error handling: relay unavailable → relay.send returns normally (best-effort for in-process
  seam compatibility); caller (push()) must tolerate relay send failure and leave records in
  outbox for retry. The durable outbox (WC2) provides the retry substrate.
- Auth credential: bearer token passed to the hosted relay conformer at init. Not part of
  the `Relay` protocol — internal to the conformer.
- Swift only at v1 (Rust can follow when the Rust leg is deployed cross-machine).

Also: update SPEC B-7 to document the hosted relay conformer as shipped and name the wire
protocol spec document.

**Files (Swift):** New file `Sources/ConvergenceKitFederation/HostedRelay.swift` (the
HTTPS conformer). SPEC B-7 addendum.

**Verify:** Unit test against a local stub server. End-to-end test: two estates on different
machines (or two simulator processes) sync a row via hosted relay.

**Worker:** sonnet-4-6. **Tier:** 3 (net-new file, no edits to existing engine code).
**Depends on:** WC1 (identity must survive restarts), WC2 (durable outbox for retry),
WC6 (signed pairing, peer persistence). Requires SyncServer wire protocol design doc to exist
before this mission is admitted to the queue.

---

## Sequencing

```
WC1 (identity persistence)
 ├── WC2 (durable outbox)        depends on WC1
 │    └── WC6 (pairing lifecycle) depends on WC1, WC2
 │         └── WC7 (hosted relay)  depends on WC1, WC2, WC6 + server spec
 ├── WC3 (Rust skew parity)      parallel with WC2
 ├── WC4 (Rust GC parity)        parallel with WC2, WC3
 └── WC5 (depth cap)             parallel with all above
```

WC3, WC4, WC5 can start immediately in parallel. WC1 gates WC2. WC2 gates WC6. WC6 gates WC7.
The server spec for WC7 should be authored (by Skippy) in parallel with WC5 and WC6.

---

## Recommendation

**PROCEED.** The program is well-founded. The Relay abstraction is clean and proven. The Wave
A/B substrate is solid enough to build on. The three missing primitives (identity persistence,
durable outbox, signed pairing) are well-understood engineering tasks, not design decisions.

Accept with conditions:

1. WC1 is not optional and gates WC2 and WC6. Do not open WC7 until WC1, WC2, and WC6 are
   green-tested and merged.

2. The SyncServer wire protocol spec must be authored by Skippy and reviewed before WC7 is
   dispatched. WC7 is an implementation mission that requires the server contract to exist
   first. Opening WC7 without the spec will produce a client built against a guess.

3. DECISION_FEDERATION_SHARING_MODEL_2026-05-21.md remains out of scope for Wave C.
   The disclosure model, grants, and tell record belong to a future aria-mcp program. Do not
   let Wave C scope creep in that direction.

4. After WC5 ships (depth cap), route a Perkins re-review of the hosted relay conformer (WC7)
   before that mission's code merges. The hosted relay is the first time Federation is exposed
   to a network surface that is not in-process.

---

## Notes for the Audit Trail

- `FederationSyncEngine.swift` line 253: `var pendingOutbound: [TableChange] = []` —
  this is the in-memory array replaced by WC2. Do not confuse with CloudKit's outbox pattern;
  the Federation array stores pre-encoding TableChange, while CloudKit stores post-encoding
  SyncRecord. WC2 changes this to store SyncRecord for consistency.

- `FederationIdentity.swift`: `LocalIdentity()` calls `Curve25519.Signing.PrivateKey()` —
  generates fresh on every init. No persistence logic exists anywhere in the file or in
  FederationSyncEngine.swift. WC1 adds load/store against PersistenceKit blob store or a
  dedicated side table.

- `HyperplaneFamilyExchange.swift` line 10 comment: "The current FederationSyncEngine.pair
  path receives a HyperplaneFamilySpec from the caller and stores it in memory; it does not
  sign or negotiate these proposal/acceptance structs." This is the explicit acknowledgment
  that PairingProposal/PairingAcceptance are typed but not wired. WC6 wires them.

- Rust `ensure_fed_sync_meta_table` is at schema v2 (adds `_fed_sync_meta_cols`). Swift is
  at v3 (adds `_fed_pending_skew`). WC3 brings Rust to v3. WC1 then brings both to v4.
  WC2 brings Swift to v5. Schema version sequencing across missions must be coordinated;
  each mission spec must name the version it owns.

- The `post_apply_integrity_hook` field on Rust SyncManifest: concordance note says
  "deferred" but `federation.rs:784` references `manifest.post_apply_integrity_hook` in the
  pull() loop. This should be verified at mission time — the concordance table in
  INTERFACE.md may be stale. If the Rust carries the hook, update the concordance note.

- ADR-013 (2026-06-17): CE uses Ed25519 (Curve25519/Signing), EE uses ECDSA P-256 for FIPS
  compliance. Wave C is CE-scope. Ed25519 is correct for CE. Do not introduce P-256 in any
  Wave C mission.
