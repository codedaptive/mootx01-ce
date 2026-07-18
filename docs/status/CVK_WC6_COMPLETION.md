---
task_id: CVK-WC6
stream: worktree-agent-aca0dda28d1994d8d
status: COMPLETE
date: 2026-07-17
---

# COMPLETION: CVK-WC6

Status: COMPLETE

## What Was Done

**Part 1: Swift — signed pairing handshake + persistence (prior session)**
- `pair(with:family:)` now executes the full Ed25519 signed handshake:
  creates `PairingProposal` with nonce, signs with local identity, calls
  `peer.acceptPairingProposal(_:proposerSignature:)`, verifies accepter
  signature + family agreement, registers peer, persists to `_fed_peers`.
- `acceptPairingProposal(_:proposerSignature:)` public method: verifies
  proposer sig, returns `PairingAcceptance` signed with local key.
- `_fed_peers` schema v6 side table declared; `SchemaDeclaration` bumped
  to v6 with v5→v6 migration (comment: v4→v5 = WC2 _fed_outbox, root
  reconciles at merge).
- Three persistence helpers: `peerUUID(from:)`, `persistPeer(publicKey:family:storage:)`,
  `reloadPeers(storage:)`.
- `enable()` calls `reloadPeers` so pairing survives disable/re-enable.
- `proposalSigningBytes(_:)` public top-level function added to
  `HyperplaneFamilyExchange.swift`.
- All 8 test files updated from old `pair(with:via:relay:family:)` API
  to new relay-first pattern + `pair(with:family:)`.
- Three new Swift tests: `pairingPersistenceAcrossReopen`,
  `tamperedProposalRejected`, `familyMismatchRejected`.

**Part 2: Rust — federation.rs complete WC6 implementation (this session)**
- `PayloadKind` enum: added `PairingProposal = 0x10` and `PairingAcceptance = 0x11`
  (WC7 extension points, silently ignored by `pull()` in v1.0).
- `pull()`: added silent-skip for PairingProposal/PairingAcceptance kinds
  (before the "reject unknown" gate — these must not count as conflicts).
- `FED_PEERS_TABLE` constant added with full doc comment.
- `ensure_fed_sync_meta_table`: bumped schema version 4 → 6; added `peers_table`
  declaration; added v5→v6 migration with WC2/root-reconcile comment.
- `pair()`: replaced stub with full signed handshake (nonce via OsRng,
  proposal signing bytes, call to `peer.accept_pairing_proposal`, three
  verification gates, `write_peer` on success).
- `accept_pairing_proposal()`: new public method, verifies proposer sig,
  returns `PairingAcceptance` signed with accepter's key.
- `enable()`: added `reload_peers()` call after `start_observers()`.
- Helpers: `peer_uuid_from_pubkey`, `write_peer`, `reload_peers`.
- Three new Rust tests: `pairing_persistence_across_reopen`,
  `tampered_proposal_rejected`, `family_mismatch_rejected`.

**Part 3: SPEC B-7 firmed**
- `docs/reference/CONVERGENCEKIT_SPEC.md` §B-7 rewritten from one-paragraph
  placeholder to full three-step handshake description, `_fed_peers`
  persistence contract, and deferred-scope note (revoke/key-rotation NOT
  a TODO — deliberate v1.0 boundary, documented for consumer awareness).
- Version bumped 1.2 → 1.3.

## Test Verification Log

- `cargo test` (Rust): exit 0, 25 federation_tests (was 22) + all other
  suites green (total: 121 tests across 12 test binaries). Verified
  2026-07-17.
- `swift test --filter ConvergenceKitFederationTests`: exit 0, 86 tests
  in 22 suites. Verified 2026-07-17.
- `swift build`: exit 0, no warnings. Verified 2026-07-17.
- Baseline Rust: 22 federation tests before mission; 25 after (+3).
- Baseline Swift: 83 federation tests before mission; 86 after (+3).

## Schema Numbering Note

WC6 takes schema v6 (_fed_peers). WC2 (sibling worktree, parallel) takes
v5 (_fed_outbox). This worktree's migration list includes a v5→v6 step
with a comment that v4→v5 (WC2 _fed_outbox) lands in a sibling worktree.
Root reconciles both the tables-array and the full v4→v5→v6 migration
chain at merge. Fresh installs bypass migrations and land at v6 with all
tables created.

## Discoveries

- `SyncError::AuthenticationFailed` in Rust takes `detail: String` — not
  a unit variant. The hazmat docstring doesn't mention this; it's visible
  only by reading types.rs.
- `RowStore::upsert` returns `SyncResult<RowHandle>` not `SyncResult<()>`
  — must `.map(|_| ())` when returning `Result<(), String>`.
- The `disjoint_columns_both_survive_after_sync` test in
  `field_lww_engine_tests.rs` shows intermittent failure under parallel
  test execution (pre-existing, confirmed by running with baseline stash).
  Runs clean in isolation and on serial runs.

## Outstanding

- v4→v5 migration (_fed_outbox, WC2) must be reconciled by root at merge.
  The WC2 worktree (adf74103) adds the outbox table; root adds the
  CreateTable(_fed_outbox) operation to the v4→v5 Migration struct that
  WC6 left as a placeholder.
- Peer revocation and key rotation are deferred per charter. Documented
  in B-7 as a v1.0 boundary, not a TODO.
