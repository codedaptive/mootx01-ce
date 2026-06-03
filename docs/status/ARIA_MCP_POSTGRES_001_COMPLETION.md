# Completion Report — ARIA_MCP_POSTGRES_001

**Status:** PARTIAL (Swift leg COMPLETE; Rust leg RESCOPE_REQUIRED)

**Task:** ARIA_MCP_POSTGRES_001  
**Stream:** worktree-agent-a7684bb9602da5cd8  
**Commit:** f50499c

---

## Step-Zero Output (verbatim)

```
merge-base HEAD main: e82817c9ececef943a9f90d8dd91e868c7d60c1a
git log --oneline -1 main: e82817c merge: PERSISTENCEKIT_RUST_PG_POOL_001
```

No rebase needed — worktree was current with main.

### Baseline test counts

**Swift (apps/ARIA_MCP):**
- Command: `swift test` (from apps/ARIA_MCP/)
- Exit code: 0
- Pass count: **68 tests, 11 suites** (mission estimated 68/11 — exact match)

**Rust (apps/ARIA_MCP/rust):**
- Command: `cargo test` 
- Exit code: 0
- Pass count: **76 tests** (mission estimated 76 — exact match; initial tail read showed only last 2 suites, not total)
- Breakdown: 3 (lib unit) + 53 (dispatch) + 8 (jsonrpc) + 5 (persistence) + 7 (stdio_framing)

---

## Precedence Table As Implemented

Both legs implement this identical four-state ladder (no trimming on either var):

| `ARIA_MCP_POSTGRES_URL` | `ARIA_MCP_SQLITE_PATH` | Backend | Exit |
|---|---|---|---|
| Non-empty | Non-empty | — | 1 — "ambiguous config" message naming both vars |
| Non-empty | Absent or empty | PostgreSQL (Swift) / pending (Rust) | 0 (Swift) / 1 (Rust) |
| Absent or empty | Non-empty | SQLite at path | 0 |
| Absent or empty | Absent or empty | In-memory | 0 |

Swift and Rust both detect the ambiguous case and exit 1 with a clear message.
Swift opens the PostgreSQL estate. Rust exits 1 with a clear message naming the kit gap.

---

## Lazy-vs-Probe Decision (same both legs)

**Decision: lazy pool; no explicit probe. Same on both legs.**

Both `PostgreSQLStorage` (Swift) and `PostgresStorage` (Rust) use a lazy
connection pool — no TCP connection is opened in the constructor. The first real
I/O happens at `Estate.create` / `storage.open`, which runs at startup before
any tool call is dispatched. An unreachable server therefore surfaces at startup
as a fatal error (exit 1), not a runtime error mid-tool-call.

This is structurally identical to SQLite's fail-fast behavior: `SQLiteStorage.init`
/ `SqliteDrawerStore::from_path` may open the file eagerly, but the pool is the
Postgres analogue. The startup lifecycle (constructor → Estate.create → kit.open)
is the fail-fast sequence for all backends.

No explicit connectivity probe is needed — and implementing one would require a
separate pool checkout purely for diagnostics, adding startup latency with no
behavioral benefit over what the estate-open call already provides.

---

## Kit-Default Delta Finding

**Swift `BackendConfiguration.postgresql` defaults:**
- `poolSize: Int = 10`
- `connectionTimeout: TimeInterval = 5.0`
- `idleTimeout: TimeInterval = 300.0`

**Rust `BackendConfiguration::Postgresql` defaults:**
- No defaults — all fields are required when constructing the enum variant.

The Swift server uses `EstateConfiguration(estateID:, backend: .postgresql(connectionString: url))`
which picks up the Swift defaults (10, 5.0, 300.0). The Rust server (once PostgresDrawerStore
exists) will need to specify these values explicitly when constructing the backend config.
These values were chosen to match Swift's defaults for parity; they are documented in the
pending rescope.

---

## RESCOPE_REQUIRED — Rust PostgreSQL Backend

**Why:** `EstateCoordinator::open` requires `Arc<dyn DrawerStore>`. The
`DrawerStoreCore::new` constructor that could accept `Arc<dyn Storage>` (and
therefore `PostgresStorage`) is `pub(crate)` within `locus-kit` — inaccessible
from external crates. `locus-kit` currently provides `InMemoryDrawerStore` and
`SqliteDrawerStore` newtypes over `DrawerStoreCore`, but no `PostgresDrawerStore`.

**What is needed:** Add `drawer_store_postgres.rs` to `locus-kit` (analogous
to `drawer_store_sqlite.rs`) exposing a `PostgresDrawerStore` newtype that wraps
`DrawerStoreCore` backed by `PostgresStorage`. This is a `packages/` change and
is outside this mission's scope.

**Impact of deferral:** The Rust server correctly detects `ARIA_MCP_POSTGRES_URL`
and exits with a clear diagnostic message pointing at this gap. No silent fallback.
No bridge. The operator's intent is respected.

**Recommended rescope:** A follow-up mission to add `PostgresDrawerStore` to
`locus-kit` (packages/kits/LocusKit/rust/src/drawer_store_postgres.rs) + wire it
into `estate_registry.rs` `new_postgres` / `register_postgres` + update
`server.rs` `from_env()` to use it.

---

## What Was Done

**Swift leg (COMPLETE):**
- `Package.swift`: `PersistenceKitPostgreSQL` added to `aria-mcp` executable target and `AriaMCPTests` test target.
- `AriaMCPMain.swift`: Four-state precedence ladder implemented. `ARIA_MCP_POSTGRES_URL` support wired. `PostgreSQLStorage` uses lazy pool with PersistenceKit defaults (poolSize=10, connectionTimeout=5s, idleTimeout=300s). Fail-fast at `Estate.create` / `kit.open`. Full comment documentation of the lazy-vs-probe decision.
- `PostgresPrecedenceTests.swift` (new): 10 tests covering precedence ladder logic, `PostgreSQLStorage` non-throwing construction, default parameter verification, no-trimming invariants, and storage type verification.

**Rust leg (PARTIAL):**
- `server.rs`: `from_env()` extended with four-state precedence logic. `ARIA_MCP_POSTGRES_URL` detected; ambiguous-config exits 1 with clear message; postgres branch exits 1 with clear message naming the kit gap.
- `persistence_tests.rs`: 7 new precedence-ladder predicate tests matching Swift coverage.
- `estate_registry.rs`: Module doc updated to document the kit gap with a clear explanation.
- `main.rs`: Module doc updated to reference four-state precedence and pending kit gap.

**Both legs:**
- `README.md` (Swift): Persistence section replaced with four-state precedence table, lazy-vs-probe documentation, and Rust parity note.
- `README.md` (Rust): Persistence section replaced with four-state precedence table, PostgreSQL-pending note, and clear explanation of the kit gap.

---

## Files Modified

| File | LOC change |
|---|---|
| `apps/ARIA_MCP/Package.swift` | +6 |
| `apps/ARIA_MCP/README.md` | +49 / -22 |
| `apps/ARIA_MCP/Sources/aria-mcp/AriaMCPMain.swift` | +93 / -32 |
| `apps/ARIA_MCP/Tests/AriaMCPTests/PostgresPrecedenceTests.swift` | +170 (new) |
| `apps/ARIA_MCP/rust/README.md` | +37 / -13 |
| `apps/ARIA_MCP/rust/src/estate_registry.rs` | +10 / -8 |
| `apps/ARIA_MCP/rust/src/main.rs` | +14 / -11 |
| `apps/ARIA_MCP/rust/src/server.rs` | +88 / -26 |
| `apps/ARIA_MCP/rust/tests/persistence_tests.rs` | +85 |

Total: 9 files changed, ~552 insertions, ~112 deletions.

---

## Test Verification Log

### Swift

- Command: `swift test` (from `apps/ARIA_MCP/`)
- Baseline: 68 tests, 11 suites
- Final: **78 tests, 12 suites, exit 0**
- Delta: +10 tests (PostgresPrecedenceTests.swift, new "PostgreSQL precedence ladder" suite)

### Rust

- Command: `cargo test` (from `apps/ARIA_MCP/rust/`)
- Baseline: 76 tests (3 lib + 53 dispatch + 8 jsonrpc + 5 persistence + 7 stdio_framing)
- Final: **83 tests, exit 0** (3 + 53 + 8 + 12 persistence + 7 stdio_framing)
- Delta: +7 tests (precedence-ladder predicate tests in persistence_tests.rs)

- `cargo clippy -- -D warnings`: clean
- `cargo fmt --check`: clean

---

## What Is Live-Gated / Untested Without A Server

**Swift:**
- PostgreSQLStorage construction and lazy pool initialization (tested — non-throwing)
- Precedence-ladder decision logic (tested — predicate-level)
- NOT tested without live server: `Estate.create` / `kit.open` over PostgreSQL, full GLK round-trip, WAL flush, estate UUID round-trip from manifest

**Rust:**
- Precedence-ladder predicate logic (tested — pure functions)
- NOT tested: anything beyond detection and exit — the Rust server cannot open PostgreSQL estates at all pending the kit gap

**Live-gated gate variable (matching existing convention):** `PERSISTENCEKIT_PG_URL`

---

## Discoveries

1. **Rust kit gap (RESCOPE_REQUIRED):** `DrawerStoreCore::new` is `pub(crate)` in locus-kit. No `PostgresDrawerStore` exists. This is a structural gap, not a configuration issue.

2. **Rust baseline test count was 76 (not 12 as initial tail showed):** The `cargo test` tail output I captured initially only showed the last two test suites. Full count: 3 + 53 + 8 + 5 + 7 = 76. The mission's estimate of 76 was correct.

3. **Kit-default delta:** Swift has language-level defaults on `BackendConfiguration.postgresql` (poolSize=10, connectionTimeout=5.0s, idleTimeout=300.0s); Rust `BackendConfiguration::Postgresql` has no defaults — values must be specified explicitly. For the pending rescope, use Swift's defaults for parity.

4. **`PostgreSQLStorage.init` is non-throwing:** Confirmed. The lazy pool makes construction always succeed; failure surfaces at `storage.open`. This simplifies the Swift server code — no `try` on construction.

---

## Self-Review

### Step 0 — Blast Radius Scope Check
N/A — purely additive mission. No existing symbols changed; new env-var branch added.

### Standard Checks
- Files changed: 9
- Scope: all within `apps/ARIA_MCP/{Sources,Tests,rust,README.md,Package.swift}` — all in mission scope
- Secrets: none
- Orphan code: none
- Prohibited blast-radius patterns: none (no bridges, no shims, no deprecated annotations, no TODO on changed symbols)
- Wire surface (tools/schemas/JSON-RPC): unchanged — verified by existing test suites passing
