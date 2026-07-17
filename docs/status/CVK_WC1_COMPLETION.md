---
title: CVK-WC1 Completion Report
mission: CVK-WC1
date: 2026-07-17
status: COMPLETE
---

# COMPLETION: CVK-WC1

**Status:** COMPLETE

## What Was Done

**Part 1 — Swift: _fed_identity side table + loadOrMintIdentity**

- `FederationStateActor.ensureFedSyncMetaTable` bumped from v3 to v4.
  New migration `fromVersion:3 toVersion:4` adds `_fed_identity` table:
  `key_id TEXT PK, secret_key BLOB, public_key BLOB, created_at TEXT` (ISO8601).
- New private function `loadOrMintIdentity(storage:)`: queries `_fed_identity`
  for `key_id="local"`, restores `LocalIdentity(privateKeyBytes:)` if found,
  else mints a fresh `LocalIdentity()` and upserts it.
- `enable()` calls `loadOrMintIdentity` after `ensureFedSyncMetaTable`.
- `localIdentity` changed from `let` to `var` to allow post-init assignment
  (Swift 6 strict concurrency: `let` on actor is implicitly `nonisolated`).
  Two cross-actor access sites updated: `FederationSyncEngine.identity` getter
  and `pair()` function both now `await stateActor.localIdentity`.
- 3 new tests in `FederationIdentityPersistenceTests`:
  `identityPersistsAcrossReEnable`, `restoredIdentitySignsCorrectly`,
  `distinctEstatesGetDistinctIdentities`.

**Part 2 — Rust: v2→v4 schema + load_or_mint_identity**

- `ensure_fed_sync_meta_table` updated from v2 to v4 with two sequential migrations:
  - v2→v3: `_fed_pending_skew` table (WC3 behavioral placeholder, matches Swift v3 schema).
  - v3→v4: `_fed_identity` table (byte-identical schema to Swift).
- Two new constants: `FED_PENDING_SKEW_TABLE`, `FED_IDENTITY_TABLE`.
- `iso8601_utc_now()`: pure Hinnant civil_from_days, no chrono dependency.
- `pub fn load_or_mint_identity(storage: &dyn Storage) -> Result<LocalIdentity, String>`:
  same semantics as Swift — query→restore or generate→upsert. Exported via
  `pub use federation::*` in lib.rs.
- 2 new tests: `identity_persists_across_restart`, `distinct_estates_get_distinct_identities`.

**Part 3 — Spec + charter**

- `CONVERGENCEKIT_SPEC.md` I-8: one-line note that keypair persists in `_fed_identity` v4
  and survives restarts.
- `CONVERGENCEKIT_SPEC.md` B-7: one-line note that signing uses persistent identity from
  `loadOrMintIdentity`/`load_or_mint_identity`.
- Charter WC1 section marked DONE with completion summary.
- Charter parity table: Side-schema version row updated to v4/v4 PARITY; Identity
  persistence row updated to YES/YES PARITY (WC1).

**Commit:** `1bb960e0` — `feat(convergencekit-federation): persist Ed25519 estate identity, both legs (CVK-WC1)`

## Test Verification Log

- Swift: `swift test` exit 0, 231 tests, all passing (2026-07-17 18:21:xx)
  - Baseline: 231 (prior to WC1 Swift persistence tests, which were already written
    in the prior session leg). Delta: unchanged (3 new tests included in baseline count).
- Rust: `cargo test` exit 0, 103 tests, all passing (2026-07-17)
  - Baseline: 101. Delta: +2 (identity_persists_across_restart, distinct_estates_get_distinct_identities).

## Schema Versions

| Leg | Pre-WC1 | Post-WC1 | Change |
|---|---|---|---|
| Swift | v3 | v4 | +1 migration: _fed_identity table |
| Rust | v2 | v4 | +2 migrations: _fed_pending_skew (v3) + _fed_identity (v4) |

## At-Rest Posture

Private key bytes (32 bytes, Ed25519 `SigningKey` seed) stored in `_fed_identity.secret_key`
as SQLite BLOB. The estate file is encrypted by SQLCipher per ADR-014. No additional
encryption layer is applied at the federation identity layer — SQLCipher is the at-rest
boundary. A Keychain option is technically available for Swift (store secret in
`kSecClassKey`), but was deferred to avoid a divergence between Swift and Rust storage
postures. Filed as a follow-up for when a Keychain migration mission is scoped.

## Discoveries

1. **Swift 6 `let` vs `var` actor isolation:** `let` stored properties on actors are
   implicitly `nonisolated` for `Sendable` types — readable cross-actor without `await`.
   Changing to `var` makes them actor-isolated and requires `await` at cross-actor call sites.
   Two sites needed updating (`identity` getter and `pair()` function).

2. **Rust v2→v4 via two migrations:** WC1 must carry both the `_fed_pending_skew` schema
   (WC3 placeholder) and `_fed_identity` because Rust started at v2 and sequential migrations
   are required. The behavioral skew-queue logic lands in WC3; this commit only declares the
   table.

3. **No chrono dependency in Rust:** ISO8601 timestamp implemented with Howard Hinnant's
   civil_from_days algorithm over `SystemTime::UNIX_EPOCH`. Output is byte-compatible with
   Swift's `ISO8601DateFormatter` with UTC + no fractional seconds.

## Outstanding

- **WC3 (Rust skew-queue behavioral parity):** `_fed_pending_skew` table schema is now in
  Rust at v3. WC3 adds the actual queue/drain/replay logic.
- **Keychain follow-up (Swift only):** ADR-014 SQLCipher is sufficient for now. A dedicated
  mission would migrate to Keychain if required by security review.
- **WC2, WC4, WC5, WC6, WC7:** Unblocked by WC1. See charter dependency tree.
