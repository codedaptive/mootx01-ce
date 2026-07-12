<!-- Storage.transaction isolation — root-cause investigation (Rust inert; Swift low-severity)
     Produced by the Kinsta root-cause agent for SUBSTRATE_ROBUSTNESS_FEATURES Part 3, 2026-07-11.
     Recovered from the agent transcript and committed 2026-07-11 — the agent
     returned this inline and the file was never landed. -->

INVESTIGATION: TXN_ISOLATION_STORAGE — Part 3 of SUBSTRATE_ROBUSTNESS_FEATURES.md

---

**Mission as given:** "Codex finding 'Transactions allow concurrent write rollback races' (mission `docs/missions/drafts/SUBSTRATE_ROBUSTNESS_FEATURES.md`, Part 3). THE DECISIVE QUESTION: Is this a LIVE race in the shipping product, or is it inert because the layer ABOVE the Rust/Swift Storage already serializes access so no two callers share a Storage concurrently?"

---

**Facts gathered (in order of discovery):**

1. `packages/kits/PersistenceKit/Sources/PersistenceKitSQLite/SQLiteStorage.swift`: `SQLiteStorage` delegates `transaction()` to `actor SQLiteBackend`. The backend uses `private var inTransaction: Bool`. `runTransaction` implements: `while inTransaction { await Task.sleep(25ms) }` with **no `await` between the check passing and `inTransaction = true` being set**. The actor's serial executor makes that check-and-set atomic.

2. `SQLiteBackend.runTransaction`: issues `connection.exec("BEGIN IMMEDIATE")`, then `inTransaction = true`, then `let result = try await block(txn)`. The actor is **suspended** at `await block(txn)`. Other callers can enter the actor during that suspension — but any caller that calls `runTransaction` will hit `while inTransaction` and wait. Callers that issue **non-transactional** writes (e.g., `insertRow`, `upsert`) do NOT check `inTransaction` and can enter the actor between calls within the block. Source: `SQLiteStores.swift` — all calls route through `await backend.insertRow(...)`, `await backend.upsert(...)`, etc.

3. `packages/kits/PersistenceKit/Sources/PersistenceKitInMemory/InMemoryStorage.swift`: `transaction()` takes a snapshot, then runs the block **mutating live state** (not a staging copy). On error: `await stateActor.rollback(to: snapshot)` — restores the full snapshot, reverting any concurrent non-transactional writes that occurred during the block's execution. Code comment explicitly documents this: "a detached copy + blind replace silently DROPS any non-transactional write." There is **no** `inTransaction` guard preventing concurrent `transaction()` calls.

4. `packages/kits/LocusKit/Sources/LocusKit/DrawerStore.swift` header comment (line 13): "storage.transaction, which acquires the write lock for the..." — confirms the DrawerStore is `public actor DrawerStore`. All DrawerStore operations are actor-isolated.

5. `packages/kits/LocusKit/Sources/LocusKit/Estate.swift`: `public actor Estate` holding `internal let store: DrawerStore` and `internal let containerFP: ContainerFingerprintStore` and `public let nodeStore: NodeStore`. All three share the **same** injected `storage` instance.

6. `packages/kits/LocusKit/Sources/LocusKit/EstateVerbs.swift`, `addDrawerCovered` (line 436):
   ```swift
   private func addDrawerCovered(_ drawer: Drawer, now: Date) async throws {
       try await store.addDrawer(drawer, now: now)         // TRANSACTION (commits)
       let names = try await store.resolveNodeNames(...)   // read
       try await containerFP.orIn(...)                     // NON-TRANSACTIONAL write
   }
   ```
   The doc comment at line 419 states verbatim: "two awaits, no shared transaction." `store.addDrawer` wraps its own transaction; `containerFP.orIn` is a separate direct `storage.rowStore.upsert(...)` — confirmed at `ContainerFingerprintStore.swift` line 223.

7. **The Swift reentrancy window**: `addDrawerCovered` is called on `actor Estate`. When the Estate actor suspends at `await store.addDrawer(...)` (which internally suspends at `await block(txn)` inside SQLiteBackend), another incoming call to the Estate actor may proceed. That second call's DrawerStore transaction blocks on `while inTransaction`. When the first call's transaction commits and `inTransaction = false`, the second call's transaction opens. The first caller then resumes from `await store.addDrawer` and proceeds to `await containerFP.orIn(...)`. That upsert is queued against `SQLiteBackend`. The second caller's transaction block is simultaneously executing actor calls. Between calls within the second block, the SQLiteBackend actor can process the first caller's upsert — **the upsert executes on the second caller's open transaction**. If the second caller's transaction then fails → ROLLBACK wipes the first caller's `containerFP.orIn()` update.

8. **Severity of the Swift race**: Mitigated by two factors. First, DrawerStore transactions rarely fail in normal operation (they require constraint violation, DB corruption, or 60-second timeout). Second, `containerFP` bits are a harmless over-approximation — stale bits self-heal at the next `containerFP.rebuildAll` at estate open (documented at EstateVerbs.swift line 434-435). The consequence is a **temporarily stale ContainerFingerprint** after a rare concurrent-capture race with a failing transaction.

9. **Swift InMemory**: `actor DrawerStore` and `actor Estate` process calls serially. No concurrent caller can reach `transaction()` on the same `InMemoryStorage` while another is in-flight, because the actor queue serializes them. The only reentrancy risk is as in Fact 7, but since InMemory does not use SQLite's connection-wide transaction scope — it uses `actor InMemoryStateActor` for every call — the upsert would go through `InMemoryStateActor` and be held in the actor's queue until the block's actor calls complete. The rollback restores state including that upsert. Same logical race, same low severity.

10. **Rust SQLite**: `packages/kits/PersistenceKit/rust/src/sqlite.rs`, lines 950–982. `SqliteStorage.transaction()` is **synchronous**. It issues `BEGIN IMMEDIATE` (via `inner.lock().unwrap().conn.execute_batch(...)`), then **releases** the `inner` Mutex before calling `block(self)`. Code comment: "The lock on `inner` is taken only to issue each bracket statement and released before the block runs." During block execution, the `inner` Mutex is free. Sub-store calls re-lock per operation. A concurrent caller holding the same `Arc<SqliteStorage>` can acquire the `inner` lock between block calls and issue DML — that DML lands in the open transaction.

11. **Rust InMemory**: `packages/kits/PersistenceKit/rust/src/inmemory.rs`. `transaction()` takes a snapshot, sets `in_transaction = true`, runs block. On error: `*self.state.lock().unwrap() = snapshot` — full state restore including reverting concurrent non-transactional writes. Two concurrent callers can both take snapshots concurrently (no guard prevents this), and the second rollback wipes the first's committed writes.

12. **`packages/kits/AriaMcpKit/rust/src/estate_registry.rs`**, lines 83-99:
    ```rust
    pub struct OpenEstate {
        pub coord: Arc<std::sync::Mutex<EstateCoordinator>>,
        pub store: Arc<dyn DrawerStore>,   // ← bypasses coordinator lock
        ...
    }
    ```
    The registry holds `Arc<std::sync::Mutex<EstateCoordinator>>` AND a separate `Arc<dyn DrawerStore>` clone. Line 91-92 doc: "retained here so the AutonomicGovernor can construct its sinks against the live estate **without needing the coordinator lock for write access**." The DrawerStore is the same instance the coordinator uses internally.

13. **`packages/kits/AriaMcpKit/rust/src/runtime.rs`**, lines 164-181: The AutonomicGovernor is spawned on a separate `std::thread::spawn`. It receives `gov_coord = Arc::clone(&config.registry.coord)` AND `gov_store = Arc::clone(&config.registry.default.store)`. It runs concurrently with the HTTP transport loop (`run_http_loop`).

14. **`packages/kits/NeuronKit/rust/src/autonomic_governor.rs`**, `tick()` method. Lines 1087-1094, 1338: "The coordinator lock is held for the **entire** pump cycle — both EstateDreamingReader and EstateMaintenanceReader borrow coordinator by reference and cannot outlive the MutexGuard." The module-level comment (line 31) stated the original intent was to release the lock before pumping — the actual code does NOT do this. `dreaming.pump(...)` and `maintenance.pump(...)` both execute INSIDE the `coord.lock()` block (lines 1094–1339). HTTP tool calls also require `coord.lock()`. Therefore: **governor pump and HTTP tool calls are mutually serialized**.

15. **After the coordinator lock is released** (line 1340+): `self.store.all_drawers()` / `all_tunnels()` / `all_kg_facts()` are **reads** — no write race. `graph_centrality_duty(&self.coord, ...)` and `preference_duty(&self.coord, ...)` re-acquire `coord.lock()` — serialized. `scheduler.tick(now_nanos)` dispatches through `CoordinatorDispatcher` which holds `Arc<Mutex<EstateCoordinator>>` — serialized. Policy persistence (`dreaming_policy_store.save_*(...)`) writes through DrawerStore — but for in-memory estates the policy store is a no-op; for SQLite estates it uses `storage.transaction()` (BEGIN IMMEDIATE), and SQLite's busy-timeout correctly serializes this with any concurrent transaction.

16. **`packages/kits/LocusKit/rust/src/drawer_store_inmemory.rs`** comment: "The underlying InMemoryStorage backend serialises access via an internal Mutex, which gives every multi-step path the atomicity the Swift storage.transaction(isolation:) provides." **This claim is incorrect for rollback.** The per-operation Mutex provides per-operation atomicity, NOT transaction-rollback isolation. A rollback can wipe concurrent writes that individually completed successfully. This is a stale-comment violation.

17. **Rust SQLite, concurrent transaction protection**: Despite the `inner` Mutex being released during the block (Fact 10), SQLite's `BEGIN IMMEDIATE` holds the SQLite write-lock for the duration of the transaction. Any concurrent writer on the **same connection** would try to issue DML and either block (non-transactional write) or get `SQLITE_BUSY` (second BEGIN IMMEDIATE). The Rust `SqliteStorage` uses **one connection per instance** (`Inner { conn: Connection }`). If two callers share the same `SqliteStorage` Arc and both call `transaction()`, the second `BEGIN IMMEDIATE` returns `SQLITE_BUSY` and the busy-timeout serializes them. Non-transactional writes (without BEGIN) on the same connection also block behind the write-lock. So **SQLite's own locking prevents the race at the SQLite level** — the concern raised by the code comment ("released before the block runs") is about Rust-side Mutex contention, not about SQLite transactional integrity.

---

**Hypotheses considered:**

1. **LIVE race, Rust SQLite** (inner Mutex released during transaction block) — weight: WEAK. Ruled out by Fact 17: SQLite's `BEGIN IMMEDIATE` prevents concurrent writes on the same connection from slipping into the transaction, regardless of whether the Rust `inner` Mutex is held.

2. **LIVE race, Rust InMemory (snapshot-restore wipes concurrent writes)** — weight: WEAK. Ruled out by Facts 13–15: governor pump runs while holding `coord.lock()`; all other writes also acquire `coord.lock()`; policy persistence is a no-op for in-memory estates. No code path writes to InMemoryStorage concurrently with the coordinator's transaction.

3. **LIVE race, Swift SQLite (actor reentrancy — non-transactional write in second caller's transaction window)** — weight: MODERATE. Supported by Facts 6–8. Mitigated by Facts 8 (transactions rarely fail; stale FP is self-healing). NOT ruled out.

4. **Fully inert everywhere** — weight: WEAK. Ruled out by Hypothesis 3.

---

**Hypotheses ruled out:**

- **"AutonomicGovernor writes to storage concurrently without coordinator lock"** — ruled out by Fact 14. The pump runs inside `coord.lock()`. The original module comment was aspirational, not descriptive of the current implementation.
- **"Any caller holds `Arc<dyn Storage>` and writes during a coordinator transaction without coord lock"** — ruled out by Facts 12–15 for Rust. No code path after the coord lock is released both (a) writes to the estate's Storage and (b) is not re-serialized through `coord.lock()` or SQLite's own locking.
- **"Swift InMemory rollback wipes concurrent non-transactional writes"** — not reachable in the current implementation because all InMemoryStorage writes route through either (a) a DrawerStore actor call (serialized in the actor queue) or (b) non-concurrent paths. The actor reentrancy risk exists logically but InMemoryStateActor serializes the actual state mutations.

**Hypotheses not yet ruled out:**

- The policy persistence path in SQLite after the coordinator lock is released uses `storage.transaction()`. I traced this to `DrawerStore` but did not read `EstateManifestDreamingPolicyStore`'s implementation. It is possible that it performs multiple separate non-transactional writes rather than one `storage.transaction()`. If so, those writes could interleave into a concurrent transaction. **Would be ruled out by reading `EstateManifestDreamingPolicyStore.save_daemon_state` implementation in LocusKit Rust.**

---

**Conclusion:**

- **Proximate cause**: `DrawerStore.addDrawerCovered` (Swift) performs `store.addDrawer` (in its own transaction) and `containerFP.orIn` (a separate non-transactional write) as two sequential awaits with no shared transaction, documented verbatim in the code. This creates a window where the non-transactional write can execute on another actor caller's open transaction connection and be rolled back with it.

- **Root cause**: The `Storage.transaction()` API contract relies entirely on external serialization — it does not enforce exclusive access during the block. The Swift actor hierarchy enforces this for nested-transaction cases (`while inTransaction` in SQLiteBackend) but does not prevent non-transactional writes from other concurrent actor callers from entering the open transaction's connection scope. The Rust coordinator Mutex enforces serialization for all writes in the production execution model, but that invariant is nowhere documented at the PersistenceKit boundary.

- **Confidence: MODERATE.**

  The Rust race (the primary concern in the Codex finding) is **INERT** in the shipping product. Confidence there is STRONG.

  The Swift race is **PARTIALLY LIVE** — a real structural gap exists, but it is low-severity (requires a failing DrawerStore transaction, which is rare in normal operation; the outcome is a temporarily stale ContainerFingerprint that self-heals at estate open). Confidence in the structural finding is STRONG; confidence in the assertion "this has never triggered a user-visible bug" is only MODERATE.

---

**Recommendation:**

1. **Mark as defense-in-depth, not critical — but address the stale comment.** The incorrect comment in `packages/kits/LocusKit/rust/src/drawer_store_inmemory.rs` — "The underlying InMemoryStorage backend serialises access via an internal Mutex, which gives every multi-step path the atomicity the Swift storage.transaction(isolation:) provides" — is a stale comment violation (rules/comment-fidelity.md). The Mutex gives per-operation atomicity, not transaction-rollback isolation. This comment will mislead the next implementer. Fix it: state what the Mutex actually does (per-operation locking) and that transaction-rollback isolation is guaranteed by the outer coordinator Mutex, not the storage's internal Mutex.

2. **Document the invariant at the PersistenceKit boundary.** In both `sqlite.rs` and `inmemory.rs` `transaction()` implementations, add a doc comment: "This function does not self-serialize against concurrent calls. Callers must guarantee that no other caller holds the same Storage instance concurrently during a transaction block. The production caller (AriaMcpKit's `Arc<Mutex<EstateCoordinator>>`) provides this guarantee." This is the invariant the investigation confirmed.

3. **The Swift structural gap** — non-transactional `containerFP.orIn()` following a committed DrawerStore transaction — is low-severity today but violates the intent of transactional atomicity. If the mission proceeds to Part 3 implementation, the Bilby-scoped fix is to move `containerFP.orIn()` inside the `addDrawer` transaction block. That requires passing resolved names into the transaction, or resolving them inside it. Check that `resolveNodeNames` is read-only (it is — confirmed at DrawerStore.swift line 901) and safe to call inside a `storage.transaction` block.

4. **If the mission scope is confirmed LIVE**: the Part 3 mission's prescribed SQLite fix (hold the inner lock for the whole block) is unnecessary for Rust — SQLite's own locking already prevents the structural race. The actual actionable fix for Rust is documentation only (Facts 12–15 confirm inertness). The Swift fix is the `containerFP.orIn()` atomicity gap described in Item 3 above.