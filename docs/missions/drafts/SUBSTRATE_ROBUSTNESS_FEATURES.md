---
title: Substrate Robustness & Fidelity Features
version: v0.1
status: draft
author: SARC-1
created: 2026-07-10
model: fable (per Bob — switch before implementing)
framing: FEATURE IMPROVEMENT, not security remediation. Each part is written
  as a capability/fidelity/correctness improvement so it reads as feature work
  to the pre/post-flight gates (Smythe/Adams/perkins), not a "security hack."
---

# Substrate Robustness & Fidelity Features

Five independently-implementable parts, each closing a correctness/fidelity gap
surfaced during the 2026-07-10 low-priority findings review. Fixed findings
already landed on `develop/1.0.x` (16 findings, commits `9e6e8929`..`c27afd5f`).
These five were deliberately NOT patched mid-sweep because each either (a)
crosses a real boundary needing its own scope, or (b) needs an investigation
before the fix. Implement each as a discrete commit, both legs where parity
applies (Swift LEADS). Run the kit's Rust tests + targeted Swift tests per part.

Origin findings are referenced by their Codex finding subject for the security
log; the WORK is framed as features below.

---

## Part 1 — Complete audit coverage for graph edges & knowledge facts
**(root fix for: "Tunnel capture bypasses audit-gated writes" + "Audit
watermark skips unaudited topology changes")**

**Feature:** every topology-affecting write produces an immutable, HLC-stamped,
actor-bound audit event — so audit reconstruction, federation/audit-history
consumers, and the resident governor's change-detection all see a COMPLETE
picture of estate mutations, not just drawer captures.

**Today:** drawer capture routes through `AuditGate.admit` + a sealed genesis
`AuditEvent` in the same transaction. Standalone tunnel capture
(`Estate.capture(TunnelCaptureFrame)` / `addTunnel` / Rust `add_tunnel`) and
KG-fact capture (`DrawerStore.addKGFact`) do a bare `rowStore.insert` with NO
audit event. Both are reachable via MCP `moot_link_memories` / `moot_file_fact`.

**Consequence this closes:** the NeuronKit `AutonomicGovernor` topology-snapshot
and graph-centrality duties skip recompute via `hasAuditGrown` (a
`SELECT COUNT(*)` on `_storagekit_audit`). Because tunnel/fact writes don't bump
that count, a tunnel/fact-only change leaves stale centrality scores and a stale
topology snapshot until an unrelated audited drawer write occurs. Auditing the
writes makes `hasAuditGrown` a COMPLETE change sentinel — the governor needs NO
change, and the cheap O(1) watermark my last batch added becomes SOUND rather
than being reverted. (See memory `topology-audit-watermark-unsound`.)

**Scope:**
- LocusKit Swift `EstateVerbs.swift` (`Estate.capture(TunnelCaptureFrame)`) +
  `VerbSurface.swift` (`captureKGFact`) and Rust `estate_verbs.rs` — route both
  through the same gated genesis-audit path drawer capture uses, in the SAME
  transaction as the row insert. HLC stamp + actor-bound gate admission.
- Decide the internal supersession-cascade tunnel insert: keep internal
  (unaudited) or audit it too. Recommend auditing standalone-verb captures;
  leave the internal cascade as-is unless the audit stream needs it — DOCUMENT
  the decision in a comment.
- Add audit-contract tests (both legs): a tunnel/fact capture appends exactly
  one audit event; `hasAuditGrown` returns true after a tunnel/fact-only change;
  topology snapshot refreshes on the next cadence after such a change.
- Rust governor parity: once tunnel/fact writes audit, the Rust centrality
  watermark (already tuple-compared, commit `70831548`) and Swift `hasAuditGrown`
  are both sound; no further governor change needed.

**Boundary caution:** this expands the audit stream. Federation/audit-history
consumers will now see tunnel/fact events — verify that is desired (it is, for
completeness) and update any test asserting exact audit contents/counts.

---

## Part 2 — PostgreSQL backend type fidelity
**(finding: "PostgreSQL backend mishandles NULL and JSON values")**

**Feature:** the PersistenceKit PostgreSQL backend round-trips every
`TypedValue` with full native-type fidelity, so estates authored on SQLite open
byte-faithfully on a Postgres deployment.

**Today (dormant in CE — no code path instantiates `PostgresStorage`, only the
env-gated conformance test):** three fidelity gaps in `packages/kits/
PersistenceKit/rust/src/postgres.rs`:
1. `TypedValue::Null` binds as `Option::<i64>::None` — a typed BIGINT NULL,
   rejected when inserted into nullable TEXT/TIMESTAMPTZ/BOOLEAN/JSONB columns.
2. `TypedValue::Json` binds as `Vec<u8>` → PG treats it as BYTEA, but the DDL
   maps `ColumnType::Json` to JSONB — a type mismatch.
3. JSON columns read back through the Blob path → returned as `TypedValue::Blob`
   / `Null`, never `TypedValue::Json`.

**Scope:**
- Thread the destination `ColumnType` into `to_param` so NULL binds with the
  correct native type per column (e.g. `Option::<String>::None` for TEXT,
  `Option::<serde_json::Value>::None` for JSONB).
- Bind `TypedValue::Json` as `serde_json::Value` (JSONB), not `Vec<u8>`; add the
  `serde_json` dep.
- Decode `ColumnType::Json` back to `TypedValue::Json` (re-serialize the JSONB
  value to bytes at the boundary to match the Swift/`PostgresNIO` round-trip).
- Untestable without a PG server in CI — validate against the env-gated
  `postgres_conformance.rs` locally if a server is available; otherwise document
  the manual verification steps. LOW urgency (backend dormant), but a clean bug.

---

## Part 3 — Transaction isolation for concurrent Storage access
**(finding: "Transactions allow concurrent write rollback races")**

**Feature:** a `Storage.transaction(...)` block is isolated — concurrent
operations on the same shared `Storage` cannot be swept into another
transaction's commit/rollback.

**Today:** SQLite and InMemory backends issue `BEGIN`/snapshot then run the
caller block WITHOUT a transaction-wide guard, passing the original storage as
the `StorageTransaction`. A concurrent thread holding the same `Storage` (which
is `Send + Sync`) executes on the same open transaction; on the owner's rollback
those unrelated successful writes are lost. InMemory snapshots then restores,
deleting concurrent writes. PostgreSQL is already correct (dedicated
per-transaction connection).

**INVESTIGATE FIRST:** determine whether the Swift actor / DispatchQueue layer
above the Rust `Storage` already serializes access so no two callers share a
`Storage` concurrently. If it does, this is defense-in-depth (document the
invariant); if not, it's a live race.

**Scope (if live):**
- SQLite: hold the storage guard for the whole block (serialize transactions —
  correct for a single-connection DB), or pass a dedicated
  `SqliteTransactionContext` that does NOT re-expose `transaction()` (blocks
  re-entrant BEGIN).
- InMemory: apply block writes to a staging copy, merge into shared state on
  commit; concurrent writes to live state survive rollback.
- Add a concurrent-access test (two threads, one in a failing transaction, one
  doing a successful write — the write must survive the rollback).

---

## Part 4 — MindOverlap differential-privacy completeness
**(finding: "MindOverlap leaks deterministic DP summaries" — residual parts)**

**Feature:** MindOverlap's federated summary honours its stated
privacy-preserving contract end to end.

**Already done / by design:** k-anonymity is `k=3` (was 1); the deterministic
UUID-derived seed is BY DESIGN (both federation sides must derive an identical
seed to compare comparably-noised spaces); the sub-k-estate false-1.0 case is
fixed (commit `6f5271d6`).

**Residual scope:**
- Exact per-estate drawer counts are returned OUTSIDE the DP mechanism
  (`aCount`/`bCount` raw). Noise them (Laplace calibrated to ε, or round to a
  multiple of k) or drop them from the result type if callers only need the
  `overlap` score. Both legs, same decision.
- No privacy ledger / budget: repeated `run_mind_overlap` calls aren't accounted
  against any budget. Add a grant/ledger parameter and consume budget per call.
  This is infrastructure — may warrant its own sub-mission; scope it before
  implementing.

---

## Part 5 — Rust GLK zoom-window from manifest (scaffold completion)
**(finding: "Rust GLK trusts spoofable estate zoom windows" — parity tail)**

**Feature:** the Rust `EstateCoordinator` derives an estate's lattice zoom
window from its manifest, exactly like the Swift leg — so fan-out routing
reflects the estate's own configuration, not a caller-supplied open-time value.

**Already done:** duplicate detection now keys on estate UUID alone (commit
`26a0d9ec`), so the same estate can no longer be registered twice under
different windows. Swift already reads zoom from the manifest
(`EstateHandle(manifest:)`).

**Residual scope:**
- Add `zoom_window_low`/`high` to the Rust estate manifest surface (currently
  only in test fixtures, not a real manifest field).
- Change `EstateCoordinator::open` to read zoom from the opened estate's
  manifest and drop the two caller params (blast radius: all `open` call sites +
  tests, both the coordinator and any verb dispatch).
- Parity-test that a Rust estate's fan-out window matches its manifest, matching
  the Swift conformance expectation.

---

## Deferred — NOT in this mission (Bob's call, 2026-07-10)

- **SQLite DDL identifier escaping** ("Rust SQLite identifiers allow SQL
  injection", DDL half). Compiled Rust callers only ever pass constant
  identifiers, so it's inert today. Bob: **leave it** — but it WILL matter if/
  when a Python port passes dynamic identifiers through this backend. Track as a
  prerequisite for the future Python port, NOT as current work. The DML half is
  already fixed (SECFIX-WS2-PK).
