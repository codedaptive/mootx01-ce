# ARIA_MCP

**Status:** Live — full tool surface operational: 53 Swift tools across five tiers
(core memory, connection, knowledge-graph, journal, estate), plus federation
fan-out, 18 CognitionKit recipe tools, reasoning lens tools, vault tools
(export/import/reconcile/status), and SSE transport. Both Swift and Rust servers
support in-memory, SQLite, and PostgreSQL backends.  
**Standalone:** Yes — wrap any kit in an MCP server

An MCP server for GeniusLocusKit. ARIA_MCP exposes any GeniusLocusKit estate — or any kit in the stack — to Claude, Claude Code, OB1, or any MCP client. It handles authentication, schema versioning, write policy enforcement, and multi-tenant estate serving so application code does not have to.

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
- Storage → **LocusKit / SynapseKit / CorpusKit**

## Platform

- **Swift** — Apple Silicon, macOS 15+, iOS 18+
- **Rust** — PC/Linux x86_64, Linux aarch64 (built in parallel; conformance-gated against shared test vectors)
- MCP server via stdio or SSE transport
- Swift 6 strict concurrency

## Persistence

The server selects its estate through the estate catalog (GeniusLocusKit
`EstateCatalog`), the same way every `mootx01` command does. No environment
value names a database.

### Estate selection

| Command line | Estate | Backend |
|---|---|---|
| `aria-mcp` | the catalog's active estate | the record's backend |
| `aria-mcp --db <name>` | a registered estate by name | the record's backend |
| `aria-mcp --db <dir>/<name>` | a transient estate at that directory, this process only | SQLite, plaintext |
| `aria-mcp --in-memory` | record resolved for validation; estate starts empty | In-memory; no federation, no charters; gone at exit |
| `aria-mcp --help` / `-h` | none opened | prints the usage line, exit 0 |

`--in-memory` opens the catalog and resolves the record before the backend is
chosen, so a `--db` that names no estate is refused rather than ignored. What
it then serves is a **fresh empty estate** — the record's content is NOT
loaded; the estate starts with zero drawers. The same rule holds in both ports
and in `mootx01 serve`.

A record's backend is SQLite (the default: `estate.sqlite` in the record's
directory, opened under the posture its file requires; an encrypted estate whose
key is missing fails closed) or PostgreSQL (the record's connection string;
pooled, lazy; defaults poolSize=10, connectionTimeout=5s, idleTimeout=300s).

**Unusable estate** (a file that will not open, an unreachable server at startup,
an unregistered name without a path): exit 1 with a clear stderr message. No
half-open state.

**Refused command line** (an unrecognised argument, `--db` with no value,
`--db` followed by a flag, a repeated `--db`): the reason and the usage line
on stderr, exit 1. Both ports, same four shapes, same code.

**Lazy-vs-probe (PostgreSQL):** `PostgreSQLStorage` uses a lazy connection pool —
no TCP connection is opened at construction time. The first real connection attempt
happens at `Estate.create`, which runs at startup before any tool call. An
unreachable server therefore surfaces as a startup failure (exit 1), not a runtime
error during a tool call. No explicit probe is needed.

**SQLite:** the record's directory is created on first open.

Persistence is **server-internal only** — the JSON-RPC wire surface (tools,
schemas, methods) is completely unchanged for all backends. Clients do not need to
know or care which backend is active.

CloudKit sync and cross-machine federation wire transport (HTTPS relay) are v1.x
decisions per the ruling recorded in the ConvergenceKit FederationSyncEngine.
In-process federation pairing and CloudKit local sync are both built and tested
in ConvergenceKit; the server-internal storage backends (in-memory, SQLite,
PostgreSQL) are the scope of ARIA_MCP's persistence layer.

Both the Swift and Rust servers support all three backends (in-memory, SQLite,
PostgreSQL) with identical wire behavior. The Rust server opens PostgreSQL estates
via `locus_kit::PostgresDrawerStore` (ARIA_MCP_POSTGRES_001-COMPLETE).

### Example

```sh
# The active estate
aria-mcp

# A registered estate by name (its record decides SQLite or PostgreSQL)
aria-mcp --db research

# A scratch estate at a directory, this process only
aria-mcp --db /tmp/scratch/bench

# The in-memory backend for an accuracy sweep
aria-mcp --db /tmp/scratch/bench --in-memory
```

## Build order

ARIA_MCP builds in **Phase 4**, last. It sits on top of GeniusLocusKit and wraps it. Build GeniusLocusKit first.

## Key specs

- `docs/reference/ARIA_MCP_SPEC.md` — full spec
- `docs/reference/GENIUSLOCUS_ARCHITECTURE_SPEC.md` — Appendix A.3 (schema versioning), § 9 (access), I-13 (federation)

## Scope

**Belongs here** if it: defines MCP tool schemas, implements schema versioning validation, implements authentication token validation, implements cross-estate mediation, implements webhook registration or delivery, implements write policy enforcement.

**Does not belong here** if it: changes estate verb semantics → GeniusLocusKit · implements algorithms → NeuronKit · defines recipes → CognitionKit · changes storage → substrate kits.
