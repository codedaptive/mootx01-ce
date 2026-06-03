# ARIA_MCP

**Status:** 🟡 Partial — transactional scaffold + scheme discriminator built; lexicon tool-gen, recall lensing, and client smoke-test pending  
**Standalone:** Yes — wrap any kit in an MCP server

An MCP server for GeniusLocusKit. ARIA_MCP exposes any GeniusLocusKit estate — or any kit in the stack — to Claude, Claude Code, OB1, or any MCP client. It is built to handle authentication, schema versioning, write policy enforcement, and multi-tenant estate serving so application code does not have to — see **Status** above for what is live today versus designed.

## Standalone value

Use ARIA_MCP to:
- **Give AI agents access to a GeniusLocusKit estate** — any MCP client can capture, recall, mutate, and withdraw content via standardised MCP tools
- **Serve multiple estates to multiple agents** — multi-tenant with per-tenant authentication and capability gating
- **Enforce write policy at the boundary** — exportability gates, sensitivity filtering, and audit are handled by ARIA_MCP before any data leaves the estate

ARIA_MCP is a boundary, not a processing layer. It does not implement algorithms, storage, or recipes — it routes calls to the right kit.

## What this kit provides

- **MCP server** implementing the Model Context Protocol per the v1 MCP spec
- **Three call modes:**
  - ① Transactional — ARIA_MCP → GeniusLocusKit estate verbs (capture, recall, withdraw, etc.)
  - ② Algorithm — ARIA_MCP → NeuronKit reasoning calls (diversity ranking, recall, synthesis)
  - ③ Trigger + webhook — ARIA_MCP → CognitionKit recipe trigger; webhook confirmation back to the registered endpoint
- **Schema versioning** — every tool call carries `geniuslocus.<verb>.<major>`; mismatches are rejected with a structured error
- **Authentication** — `OwnerToken` (full estate access) and `ScopedToken` (wing/room limited, read or read-write)
- **Write policy enforcement** — exportability gate before any cross-perimeter data transmission
- **Cross-estate mediation** — multi-tenant operation per spec invariant I-13
- **Webhook registration and delivery**

## What this kit does NOT provide

- Estate verb semantics → **GeniusLocusKit**
- Algorithms → **NeuronKit**
- Recipes → **CognitionKit**
- Storage → **LocusKit / VectorKit / CorpusKit**

## Platform

- **Swift** — Apple Silicon, macOS 15+, iOS 18+
- **Rust** — PC/Linux x86_64, Linux aarch64 (built in parallel; conformance-gated against shared test vectors)
- MCP server via stdio or SSE transport
- Swift 6 strict concurrency

## Persistence

The server selects its storage backend from two environment variables at startup.
Both are read without trimming — a whitespace-only value is treated as non-empty
and fails fast as a config error, not a silent fallback.

### Backend precedence table

| `ARIA_MCP_POSTGRES_URL` | `ARIA_MCP_SQLITE_PATH` | Backend | Notes |
|---|---|---|---|
| Non-empty | Non-empty | — | Ambiguous config: exit 1, stderr names both vars |
| Non-empty | Absent or empty | PostgreSQL at the URL | Pooled, lazy; defaults poolSize=10, connectionTimeout=5s, idleTimeout=300s |
| Absent or empty | Non-empty | SQLite at that path | WAL-mode, durable across restarts |
| Absent or empty | Absent or empty | In-memory (default) | Ephemeral; discarded on exit |

**Unusable config** (path unwritable, malformed connection string, or unreachable
server at startup): exit 1 with a clear stderr message. No half-open state.

**Lazy-vs-probe (PostgreSQL):** `PostgreSQLStorage` uses a lazy connection pool —
no TCP connection is opened at construction time. The first real connection attempt
happens at `Estate.create`, which runs at startup before any tool call. An
unreachable server therefore surfaces as a startup failure (exit 1), not a runtime
error during a tool call. No explicit probe is needed.

**SQLite:** parent directories of the SQLite path are created automatically if
missing. A bare filename (no directory component) skips creation and resolves
against the working directory.

Persistence is **server-internal only** — the JSON-RPC wire surface (tools,
schemas, methods) is completely unchanged for all backends. Clients do not need to
know or care which backend is active.

CloudKit and live federation fan-out remain future work.

Both the Swift and Rust servers support all three backends (in-memory, SQLite,
PostgreSQL) with identical wire behavior. The Rust server opens PostgreSQL estates
via `locus_kit::PostgresDrawerStore` (ARIA_MCP_POSTGRES_001-COMPLETE).

### Example

```sh
# Ephemeral (default — no env var needed)
aria-mcp

# Durable SQLite at a specific path
ARIA_MCP_SQLITE_PATH=/var/lib/aria-mcp/estate.sqlite aria-mcp

# PostgreSQL-backed (requires a running PostgreSQL server)
ARIA_MCP_POSTGRES_URL=postgresql://user:pass@localhost:5432/aria_mcp aria-mcp
```

## Build order

ARIA_MCP builds in **Phase 4**, last. It sits on top of GeniusLocusKit and wraps it. Build GeniusLocusKit first.

## Key specs

- `docs/reference/ARIA_MCP_SPEC_v0.2.md` — full spec
- `docs/reference/GENIUSLOCUS_ARCHITECTURE_SPEC_v0.8.md` — Appendix A.3 (schema versioning), § 9 (access), I-13 (federation)

## Mission placement rules

**Belongs here** if it: defines MCP tool schemas, implements schema versioning validation, implements authentication token validation, implements cross-estate mediation, implements webhook registration or delivery, implements write policy enforcement.

**Does not belong here** if it: changes estate verb semantics → GeniusLocusKit · implements algorithms → NeuronKit · defines recipes → CognitionKit · changes storage → substrate kits.
