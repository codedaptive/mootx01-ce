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

Tool names, descriptions, and input schemas are **byte-identical** to the Swift
server for every tool that exists in both. Internal architecture is idiomatic
Rust; this is not a transliteration of the Swift code.

## v1 Surface

### Recipe tools (moot_list_recipes + 2 foundational)

| Tool | Description |
|---|---|
| `moot_list_recipes` | Enumerate catalog: name, version, description, required capabilities |
| `moot_grounded_synthesis` | Hybrid-recall + synthesize into a grounded context document |
| `moot_run_migration_benchmark` | Derive COW branches per plan, benchmark, rank survivors |
| `moot_confirm_migration_promotion` | v1 boundary — see below |

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

Three tools so an agent can put real data in front of the lenses:

| Tool | Description |
|---|---|
| `moot_capture_drawer` | File a new drawer into the estate |
| `moot_drawer_recall` | Read drawers back by filter |
| `moot_capture_tunnel` | File a tunnel (graph edge) into the estate |

Argument names are wire-identical to the Swift server (content, room, udcCode,
addedBy, embeddingModelID, filter, limit, ordering, hydrationLevel).

## v1 Boundaries (Behavioral Facts, Not Deferrals)

**In-memory estates only.** v1 opens one in-memory estate at startup as the
default. Additional in-memory estates can be registered; all are ephemeral and
discarded when the server exits. Persistent storage backends (SQLite, CloudKit)
require wiring the `DrawerStore` trait to a persistence backend — that is v2 work.

**moot_confirm_migration_promotion is advertised but returns an informational
error.** The confirm step requires the `CoreReport` produced by
`moot_run_migration_benchmark`. The server is stateless across tool calls; without
session state it cannot retain the report between the run and confirm calls.
Persistent session state is a v2 feature. The tool is listed in `tools/list` so
agents can discover it; calling it returns a clear explanation of the v1 boundary.

**Full lexicon projection is out of scope for v1.** The Swift server projects the
full AriaLexicon acceptance matrix (mutate, withdraw, expunge, reanchor, learn,
cross_estate_recall, federation). v1 ships the minimum three tools an agent needs
to put data in front of the lenses. The full lexicon is the v2 surface; it follows
the same pattern as the three v1 tools.

**Federation tool (moot_cross_estate_recall) is out of scope for v1.** The
federated recall surface requires the grant model and the federation authorization
layer — v2.

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
                          └─► lexicon_tools (moot_capture_drawer, moot_drawer_recall, moot_capture_tunnel)

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
