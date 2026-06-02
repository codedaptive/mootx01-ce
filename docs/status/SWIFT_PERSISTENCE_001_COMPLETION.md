# COMPLETION: SWIFT_PERSISTENCE_001

**Status:** COMPLETE

---

## What Was Done

### Part 1: Package.swift dep addition
Added `PersistenceKitSQLite` product dependency to the `aria-mcp` executable
target and the `AriaMCPTests` test target. The package-level dependency on
`PersistenceKit` already existed; only the per-target product references were
missing. Confirmed the product name by reading the existing
`PersistenceKitInMemory` pattern.

### Part 2: AriaMCPMain.swift — env-configured backend selection
Rewrote the entry point to read `ARIA_MCP_SQLITE_PATH` from `ProcessInfo`.
Behavior table matches the Rust v2a-server exactly:

| `ARIA_MCP_SQLITE_PATH` state | Backend | Notes |
|---|---|---|
| Absent or empty | In-memory (default) | Byte-identical to prior behavior |
| Present, non-empty | SQLite at that path | WAL-mode, durable across restarts |
| Present, path unusable | — | `fputs` to stderr + `exit(1)`, no half-open state |

Parent directories auto-created via `FileManager.createDirectory(withIntermediateDirectories: true)`.
`SQLiteStorage(configuration:)` throws on unusable path; caught, written to
stderr via `fputs`, then `exit(1)`. No half-open estate state left behind.
Startup banner updated to reflect the active backend.

Stale launch-spike comments removed ("in-memory for the launch spike",
"persistent SQLite backend lights up at v1.0 once the installer landed in
MISSION_LAUNCH_05 is wired through").

### Part 3: PersistenceTests.swift (new, 4 tests)
Written at `Tests/AriaMCPTests/PersistenceTests.swift`. Tests:

1. `testInMemoryEstateAcceptsCapture` — absent-env-var path (in-memory) still
   accepts a capture; verifies the existing code path is intact.
2. `testSQLiteStorageConstructsAtValidPath` — SQLiteStorage construction
   succeeds at a valid temp path; tests the constructor leg.
3. `testSQLiteEstateRoundTrip` — full GLK-layer round-trip: open SQLite estate,
   capture drawer, close kit, open fresh kit at same path, recall finds drawer.
   Matches the Rust v2a persistence_tests.rs pattern.
4. `testParentDirectoryCreationPattern` — validates the FileManager.createDirectory
   + SQLiteStorage pattern used in production startup.

**Seam note (DISCOVERY):** The ToolDispatcher/ARIA_MCPDispatcher construction
seam prevents a full dispatcher-layer round-trip without refactoring beyond
mission scope. The dispatcher takes a pre-opened EstateHandle; there is no
"open dispatcher from path" factory in the library target. The round-trip test
is therefore at the GLK layer, which is the actual persistence seam. The
dispatcher layer is already exercised by the existing ServerTests suite. This
gap is flagged per mission instructions — no refactoring was done.

### Part 4: README.md — Persistence section
Added a Persistence section with the same three-state behavior table as the
Rust v2a README, plus an example shell invocation, and a note on the
Swift/Rust convergence model (same env var, same behavior, no cross-language
calls). No other README sections were modified.

**Commit:** `0431fb8` — `feat(aria-mcp): env-configured SQLite persistence (Swift parity with Rust v2a)`

---

## Merge-Base Verification

```
git merge-base HEAD main
8052f8e04f4e242b06509fba474e79ff305a3041
```

Matches required `8052f8e`. Clean.

---

## Test Verification Log

### Baseline (worktree)
- Worktree baseline: 50 tests in 8 suites (before this mission's additions)
- Note: worktree branch cut from `8052f8e`; `LexiconGapsTests` and
  `TunnelRecallTests` in this branch have fewer test cases than main.
  The "63/10" figure in the mission spec was measured from the main repo
  checkout. All pre-existing tests pass in the worktree.

### Final (post-commit)
- Command: `cd apps/ARIA_MCP && swift test`
- Exit code: 0
- Pass count: 54 (50 pre-existing + 4 new persistence tests)
- Fail count: 0
- Suites: 9 (8 pre-existing + 1 new Persistence suite)

Final test output tail:

```
Test testSQLiteEstateRoundTrip() passed after 0.019 seconds.
Test testParentDirectoryCreationPattern() passed after 0.001 seconds.
Suite "Persistence" passed after 0.028 seconds.
Test run with 54 tests in 9 suites passed after 0.028 seconds.
```

---

## Discoveries

### SEAM GAP (flagged, not acted on)
The `aria-mcp` executable target's `AriaMCPMain.swift` constructs a
`ToolDispatcher` and `ARIA_MCPDispatcher` around a pre-opened `EstateHandle`.
There is no factory on the library side that takes a path and returns a
ready-to-use dispatcher. This means:

- Integration tests that exercise the full "startup config → dispatcher → tool
  call → result" chain must either (a) inline the startup logic or (b)
  extract the startup logic into a library helper.
- The persistence round-trip test covers the substrate seam (GLK layer)
  which is where actual persistence happens.

If a future mission wants dispatcher-level persistence tests, it should extract
`AriaMCPMain.makeStorage(from:)` or similar into the `AriaMCP` library target
so tests can call it directly. That refactor is out of scope for this mission.

### Discovery Item 5: Backend-parity delta (report-only, no action taken)

**Swift `BackendConfiguration` (PersistenceKit/EstateConfiguration.swift):**
```swift
public enum BackendConfiguration: Sendable {
    case sqlite(url: URL, busyTimeout: TimeInterval = 5.0)
    case postgresql(
        connectionString: String,
        poolSize: Int = 10,
        connectionTimeout: TimeInterval = 5.0,
        idleTimeout: TimeInterval = 300.0
    )
    case inMemory
}
```

**Rust `BackendConfiguration` (PersistenceKit/rust/src/storage.rs):**
```rust
pub enum BackendConfiguration {
    InMemory,
    Sqlite { path: String, busy_timeout_secs: f64 },
    Postgresql {
        connection_string: String,
        pool_size: usize,
        connection_timeout_secs: f64,
        idle_timeout_secs: f64,
    },
}
```

**Parity delta:**
- Case names match semantically (InMemory / Sqlite / Postgresql).
- Swift SQLite case uses `URL` for path; Rust uses `String` — idomatic
  per-language, functionally equivalent.
- Swift uses `TimeInterval` (Double seconds); Rust uses `f64` — same.
- Field names differ by convention (Swift camelCase, Rust snake_case) but
  semantics are identical.
- The Rust `Sqlite` variant is documented as "deferred to a follow-on
  R-mission" in the source comment — but the Rust v2a-server has now
  shipped SQLite support (this mission's Rust counterpart). That comment
  in `storage.rs` is stale and should be updated in a doc-cleanup mission.
- No structural parity gap. Both sides have InMemory, SQLite, PostgreSQL.
  PostgreSQL is reserved/unimplemented in both legs.

Recommended queue item: update the stale "deferred" comment in
`packages/kits/PersistenceKit/rust/src/storage.rs` line 27-30.

---

## Self-Review Summary

### Step 0 — Blast Radius Scope Check
N/A — purely additive mission. No existing symbols changed.

### Standard Checks
- Files changed: 4
- Lines added: ~309, removed: ~16
- Scope: all within mission "Files You May Modify" list
- ToolDispatch.swift, ToolProjection.swift, tool descriptors: untouched
- Wire surface: unchanged
- packages/: not modified
- apps/ARIA_MCP/rust/: not modified (read-only reference only)
- Secrets: none
- Orphan code: none
- Prohibited blast radius patterns: none
- Stale comments updated: yes (launch-spike claim removed from AriaMCPMain.swift)
