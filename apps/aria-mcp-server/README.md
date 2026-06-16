# aria-mcp-server

The standalone **reference MCP server** — the `aria-mcp` binary.

It is a thin entry point over `AriaMcpKit` (`packages/kits/AriaMcpKit`): it opens
an estate, selects a storage backend from the environment, and runs the JSON-RPC
MCP transport over stdio (default) or loopback HTTP (when `MOOTX01_HTTP_PORT` is
set). All server logic lives in the kit; this package is just the runnable wrapper.

It runs the **same runtime** as `mootx01 serve` (the product CLI links the same
`AriaResident` library). The Apple app (`apps/Mootx01-App`) launches this binary as
a managed external server to prove the substrate is shared across clients.

- Swift executable: `Sources/aria-mcp` → product `aria-mcp`.
- Rust binary: `rust/` → the Rust vertical's `aria-mcp` binary (over the `aria_mcp` lib).

**Backend selection** (env, fail-fast — no silent fallback):
`ARIA_MCP_POSTGRES_URL` → PostgreSQL · `ARIA_MCP_SQLITE_PATH` → SQLite (durable) ·
neither → InMemory (ephemeral). Both set → exit 1.

## Build / run

```sh
swift build -c release --package-path apps/aria-mcp-server      # macOS
cargo build --release --manifest-path apps/aria-mcp-server/rust # PC/Linux
```
