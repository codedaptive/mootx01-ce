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

**Estate selection** (the estate catalog, the same as every `mootx01` command;
no environment value names a database):

```
aria-mcp                     the catalog's active estate
aria-mcp --db <name>         a registered estate by name
aria-mcp --db <dir>/<name>   a transient estate at that directory, this process only
aria-mcp --in-memory         a fresh empty estate on the in-memory backend (record resolved for validation only)
                             transient: no federation, no charters, gone at exit
aria-mcp --help              print the usage line and exit 0
```

The catalog record decides the backend: SQLite (`estate.sqlite` in the record's
directory, opened under the posture its file requires) or PostgreSQL (the record's
connection string).

`--in-memory` still opens the catalog and resolves the record first, so a `--db`
that names no estate is refused before the backend is chosen. What it serves is
then a TRANSIENT estate whatever the record says: nothing survives the process,
so no federation identity is minted and no charter drawers are seeded. The same
rule holds in the Rust port and in both ports of `mootx01 serve`.

A refused command line prints the reason and the usage line to stderr and exits
**1**, in both ports. Three shapes are refused so a mistyped line never serves
the wrong estate: `--db` with no value, `--db` followed by a flag, and a
repeated `--db`. Any other argument is a usage error.

## Build / run

```sh
swift build -c release --package-path apps/aria-mcp-server      # macOS
cargo build --release --manifest-path apps/aria-mcp-server/rust # PC/Linux
```
