# ARIA_MCP Rust Server

The Rust vertical's MCP server. Wire-contract peer of the Swift `ARIA_MCP`
server at `apps/ARIA_MCP/Sources/AriaMCP/`.

## The No-FFI Law

This server exists because the no-FFI law is absolute: Rust never calls Swift
binaries; Swift never calls Rust. No bindings, no shared libraries, in either
direction, ever. The corollary, per
`docs/engineering/LENS_DISCOVERABILITY_DECISION_v2.0_2026-06-02.md` consequence
4, is that each language stack must be a **complete vertical**: kits, catalog,
and its own MCP server. The Swift vertical is whole (apps/ARIA_MCP). Until this
server shipped, the Rust vertical's kits executed only under `cargo test` — a
tracked shortfall, not doctrine.

## Running

```sh
cargo run --manifest-path apps/ARIA_MCP/rust/Cargo.toml
```

Or from this directory:

```sh
cargo run
```

The binary reads newline-delimited JSON from stdin and writes newline-delimited
JSON to stdout — the de-facto MCP stdio convention every MCP host (Claude Desktop,
Claude Code) expects. Diagnostics go to stderr; stdout is reserved for JSON-RPC
frames.

## Wire Contract

The server implements JSON-RPC 2.0 over newline-delimited stdio:

| Method | Description |
|---|---|
| `initialize` | Echo client protocol version, advertise `tools` capability |
| `ping` | Return empty object `{}` |
| `tools/list` | Return all tool descriptors |
| `tools/call` | Dispatch a named tool |

Tool names and descriptions are **byte-identical** to the Swift server for
every tool. Input schemas are byte-identical for every tool with a live Swift
handler; where Swift still projects an empty default schema (the non-drawer
recall tools — a known Swift-side reconciliation item), this server grounds
the schema in the actual coordinator interface, the precedent set by
moot_tunnel_recall. Internal architecture is idiomatic Rust; this is not a
transliteration of the Swift code.

## Tool Surface (49 tools after v2b-p2)

### Recipe tools (moot_list_recipes + 3 foundational)

| Tool | Description |
|---|---|
| `moot_list_recipes` | Enumerate catalog: name, version, description, required capabilities |
| `moot_grounded_synthesis` | Hybrid-recall + synthesize into a grounded context document |
| `moot_run_migration_benchmark` | Derive COW branches per plan, benchmark, rank survivors |
| `moot_confirm_migration_promotion` | Promote a winning branch by id; discard losers (human-confirmed write) |

### 14 reasoning-lens tools

All 14 lens recipes cataloged in `CognitionKit/catalog.rs` ship with hard-bound
tool dispatch. One tool per recipe; tool names are `moot_<catalog_name>`:

`moot_keystones`, `moot_constellation`, `moot_free_association`,
`moot_theme_weather`, `moot_latent_themes`, `moot_bias`, `moot_drift`,
`moot_contradiction`, `moot_trust_grounded_synthesis`, `moot_partial_cue_recall`,
`moot_anticipate`, `moot_tunnel_successor`, `moot_mind_overlap`,
`moot_estate_divergence`.

Tool descriptions are sourced directly from `recipe_catalog()` — byte-identical
to the Swift server's catalog strings, guaranteed by the conformance anchor in
`catalog.rs`.

### v1 lexicon minimum

Three tools for putting real data in front of the lenses:

| Tool | Description |
|---|---|
| `moot_capture_drawer` | File a new drawer into the estate |
| `moot_drawer_recall` | Read drawers back by filter |
| `moot_capture_tunnel` | File a tunnel (graph edge) into the estate |

Argument names are wire-identical to the Swift server (content, room, udcCode,
addedBy, embeddingModelID, filter, limit, ordering, hydrationLevel).

### v2b-p1 drawer lifecycle verbs and tunnel recall

Five tools completing the drawer lifecycle surface and exposing the tunnel graph
read-out:

| Tool | Description | Required args |
|---|---|---|
| `moot_mutate_drawer` | Apply a named mutation (confirm, reject, contest, …) | `rowID`, `kind` |
| `moot_withdraw_drawer` | Move a drawer to withdrawn state | `rowID` |
| `moot_expunge_drawer` | Hard-erase a drawer (irreversible) | `rowID`, `reason`, `confirmation: true` |
| `moot_reanchor_drawer` | Move room and/or UDC anchor | `rowID` (+ at least one of `toRoom`, `toUDC`) |
| `moot_tunnel_recall` | Read outgoing tunnels from a wing | `wing` |

Error discipline for lifecycle verbs: domain refusals (NotSupportedByEstate,
ExpungeNotConfirmed, EmptyReanchor) surface as `isError: true` tool results, NOT
JSONRPCError transport faults — matching the Swift ToolDispatcher's VerbError
discipline. Out-of-band faults (missing required args, unknown estate) remain
JSONRPCError INVALID_PARAMS.

Note on `moot_tunnel_recall`: the Swift server advertises this tool (via the
AriaLexicon acceptance matrix) but has no live handler — calling it returns
methodNotFound on the Swift side. The Rust server is ahead here: the coordinator's
`recall_tunnels(handle, wing)` executes against the live estate.

## Persistence

The server selects its storage backend from environment variables at startup.
Both vars are read without trimming — a whitespace-only value is non-empty and
fails fast, not a silent fallback.

### Backend precedence table

| `ARIA_MCP_POSTGRES_URL` | `ARIA_MCP_SQLITE_PATH` | Backend | Notes |
|---|---|---|---|
| Non-empty | Non-empty | — | Ambiguous config: exit 1, stderr names both vars |
| Non-empty | Absent or empty | PostgreSQL estate | Pooled, lazy-connect, Swift-parity defaults |
| Absent or empty | Non-empty | SQLite at that path | WAL-mode, durable across restarts |
| Absent or empty | Absent or empty | In-memory (default) | Ephemeral; discarded on exit |

**PostgreSQL:** the Rust server opens a pooled PostgreSQL estate via
`locus_kit::PostgresDrawerStore` backed by persistence-kit's `PostgresStorage`.
Pool defaults match the Swift leg exactly: `pool_size=10`,
`connection_timeout_secs=5.0`, `idle_timeout_secs=300.0`. The pool acquires
connections on first use (lazy), so construction succeeds even when the
database is temporarily unreachable; the first tool call that touches the
estate surfaces any connection error.

**SQLite:** parent directories of the SQLite path are created automatically if
missing.

Persistence is **server-internal only** — the JSON-RPC wire surface (tools,
schemas, methods) is completely unchanged for all backends. Clients do not need
to know or care which backend is in use.

CloudKit and live federation fan-out remain future work.

## Behavioral Facts

**moot_confirm_migration_promotion is fully wired.** The confirm step dispatches
`confirm_migration_promotion_by_id`, the id-addressed overload that works across
the stateless run→confirm boundary. The server's in-memory coordinator retains all
minted branches; the run result text carries the branch ids the caller needs.
Required: `winnerBranchID` (UUID). Optional: `discardBranchIDs`,
`disqualifiedBranchIDs` (arrays of UUID strings).

**Federation tool (moot_cross_estate_recall) is out of scope.** The federated
recall surface requires the grant model and the federation authorization layer.

## Architecture

```
stdin (newline-delimited JSON)
  └─► server::run_stdio_loop
        └─► dispatcher::Dispatcher::handle
              ├─► initialize / ping / tools/list
              └─► tools/call
                    └─► dispatch::dispatch_tool
                          ├─► recipe_tools  (moot_list_recipes, moot_grounded_synthesis, …)
                          ├─► lens_tools    (moot_keystones … moot_estate_divergence)
                          └─► lexicon_tools (moot_capture_drawer, moot_drawer_recall,
                                             moot_capture_tunnel, moot_mutate_drawer,
                                             moot_withdraw_drawer, moot_expunge_drawer,
                                             moot_reanchor_drawer, moot_tunnel_recall)

stdout (newline-delimited JSON responses)
```

The estate registry (`estate_registry::EstateRegistry`) holds the set of open
in-memory estates the tools dispatch against. All estates share one
`EstateCoordinator` so the federated lenses (mind_overlap, estate_divergence)
can cross-address them without crossing a process boundary.

## Testing

```sh
cargo test                     # run all tests
cargo clippy -- -D warnings    # lint clean
cargo fmt --check              # format check
```

Tests cover:
- JSON-RPC wire types (mirrors `JSONRPCTests.swift`)
- Stdio framing (mirrors `StdioFramingTests.swift`)
- The full lib unit tests in the constituent modules

All tests run in `cargo test`; the kit tests (CognitionKit, NeuronKit) are not
re-run from here — run `cargo test` in their respective crate directories to
verify the kits are untouched.
