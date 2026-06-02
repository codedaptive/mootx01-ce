# Completion Report — PERSISTENCEKIT_PG_POOL_001 + FIX

**Mission:** PERSISTENCEKIT_RUST_PG_POOL_001-FIX  
**Stream branch:** worktree-agent-a6f2393e46187af49  
**Commit:** 84d5450

---

## What was fixed

Adams Finding #3: `transaction()` in `postgres.rs` was structurally broken.
It issued `BEGIN` on `bracket_conn`, then called `block(self)`. Every
sub-store method inside the block called `self.pool.checkout()` internally,
obtaining separate pool connections outside the transaction. `COMMIT` then
committed nothing because it ran on `bracket_conn` while all DML ran
elsewhere. `ROLLBACK` had the same problem.

The false comment claimed this was "consistent with how the single-connection
backend worked." It was not. The single-connection backend (SQLite) is
transactional precisely because all sub-store calls lock the same
`Mutex<Inner>::conn`. The postgres pool did the opposite: each call checked
out a fresh connection.

---

## Design: PgTransactionContext

One `PooledClient` is checked out for the entire bracket. It is wrapped in
`Arc<Mutex<PooledClient>>` (type alias `TxConn`) and passed to a
`PgTransactionContext`. The context implements `StorageTransaction` by
returning four sub-store types:

| Sub-store | Connection source |
|-----------|-------------------|
| `TxRowStore` | `conn.clone()` (same Arc) |
| `TxBlobStore` | `conn.clone()` (same Arc) |
| `TxAuditLog` | `conn.clone()` (same Arc) |
| `TxVectorIndex` | `conn.clone()` (same Arc) |

Each sub-store locks the Mutex per SQL call. BEGIN was issued before the
context is constructed; COMMIT or ROLLBACK follows after the block returns.
All DML in the block participates in the same PostgreSQL transaction.

This mirrors Swift's `PostgreSQLTransactionContext`: one connection acquired
up front, all sub-store calls routed through it.

---

## Rollback-failure disposition

If ROLLBACK fails (e.g. network error mid-transaction), the connection is in
an unknown state. It must not be returned to the pool. A new
`Pool::discard()` method decrements `in_use` and notifies waiting checkouts
without pushing the connection back to `available`. `PooledClient::discard()`
calls `Pool::discard()` then drops the broken client.

On rollback failure: `Arc::try_unwrap(shared)` extracts the `PooledClient`
and calls `discard()`. The block's original error is surfaced regardless of
rollback outcome. This matches Swift: a rollback-failed connection is released
without being put back into the pool.

---

## False comment — fixed

Removed the paragraph at lines 851-860 claiming the per-connection design
was "consistent with the single-connection backend" and "with the Swift async
actor model." Replaced with an accurate description of the one-connection
contract and its Swift reference.

---

## Tests

Three new tests in `transaction_context_tests` (all non-live, no server required):

1. **`transaction_context_constructs_without_server`** — verifies
   `PgTransactionContext` can be constructed without connecting.

2. **`transaction_context_sub_stores_share_bracket_connection`** — constructs
   `TxRowStore`, `TxBlobStore`, `TxAuditLog`, `TxVectorIndex` directly and
   asserts `Arc::ptr_eq(&store.conn, &bracket_conn)` for each. Proves all
   four sub-stores hold the same connection Arc.

3. **`transaction_context_accessors_route_through_bracket_connection`** —
   calls the `StorageTransaction` trait accessors on a live `PgTransactionContext`
   and asserts `Arc::strong_count` is 6 (original + ctx + 4 sub-store clones).
   If any sub-store checked out from the pool instead of cloning conn, the
   count would differ.

**What is NOT live-verified:** the transactional round-trip (BEGIN → DML →
COMMIT in a single PG transaction) requires `PERSISTENCEKIT_PG_URL` to be
set. The environment-gated conformance test in `tests/postgres_conformance.rs`
exercises this when a server is available. No live PostgreSQL was available
during this mission; these tests are marked as skipped (not failed) in the
test output.

---

## SQLite and InMemory transaction-path audit

**SQLite:** `transaction()` calls `block(self)`. Sub-stores each lock
`self.inner` (a `Mutex<Inner>`), which contains a single `rusqlite::Connection`.
Because there is only one connection and it's behind the same Mutex, all DML
goes through the same connection — the transaction IS real. The comment at
lines 473-476 accurately describes this. **Not broken. No change needed.**

**InMemory:** `transaction()` snapshots `self.state`, calls `block(self)`,
restores the snapshot on error. Sub-stores lock the same `self.state` Mutex.
Correct snapshot/restore semantics. **Not broken. No change needed.**

---

## Test Verification Log

### Baseline (pre-fix)
```
running 6 tests   (lib — pool_tests)
test result: ok. 6 passed; 0 failed

running 1 test    (inmemory_conformance)
test result: ok. 1 passed; 0 failed

running 22 tests  (inmemory_tests)
test result: ok. 22 passed; 0 failed

running 1 test    (postgres_conformance — skipped, no server)
test result: ok. 1 passed; 0 failed

running 1 test    (sqlite_conformance)
test result: ok. 1 passed; 0 failed

TOTAL: 31 passed, 0 failed
```

### Final (post-commit)
Command: `cd packages/kits/PersistenceKit/rust && cargo test`

```
running 9 tests
test transaction_context_tests::transaction_context_accessors_route_through_bracket_connection ... ok
test transaction_context_tests::transaction_context_constructs_without_server ... ok
test transaction_context_tests::transaction_context_sub_stores_share_bracket_connection ... ok
test pool_tests::idle_timeout_accepted_in_config ... ok
test pool_tests::pool_checkout_fails_fast_without_server ... ok
test pool_tests::pool_close_refuses_checkouts ... ok
test pool_tests::pool_close_wakes_blocked_checkouts ... ok
test pool_tests::pool_construction_is_lazy ... ok
test pool_tests::pool_exhaustion_returns_pool_exhausted_error ... ok
test result: ok. 9 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.06s

running 1 test
test inmemory_conformance ... ok
test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s

running 22 tests
test result: ok. 22 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s

running 1 test
test postgres_conformance ... ok
test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s

running 1 test
test sqlite_conformance ... ok
test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.03s

running 0 tests
test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s

TOTAL: 34 passed, 0 failed (3 new tests added)
```

Exit code: 0. Pass count: 34 (baseline 31 + 3 new). Zero failures.

---

## Clippy

Command: `cargo clippy --all-targets -- -D warnings`  
postgres.rs: zero errors, zero warnings.  
Pre-existing errors in `generated_column.rs`, `inmemory.rs`, `sqlite.rs`,
`lib.rs` (worktree predates main fixes) — not in scope per mission.

---

## cargo fmt

Command: `cargo fmt --check`  
postgres.rs: clean (no diff).

---

## Self-Review

- Files changed: 1 (`postgres.rs` only)
- Lines added: 748, removed: 21
- Scope: entirely within `packages/kits/PersistenceKit/rust/` as required
- No bool stored properties, no Date() in engine, no unlocalized strings
- Comment fidelity: false comment removed; all new comments describe what
  the code currently does
- No prohibited blast-radius patterns (no bridge helpers, no deprecated
  annotations, no TODO on changed symbols)
