# apps/

Applications and runnable surfaces built on the MOOTx01 substrate (`packages/`).
Each app is a downstream consumer of the kits and libs — apps depend on packages,
never the reverse.

| App | What it is |
|---|---|
| [`mootx01`](mootx01/) | The unified **`mootx01` CLI** — the product binary. Subcommands: `serve` (run the resident MCP server/daemon), `install`, `uninstall`, `upgrade`, `query`, `status`, `db`, `proxy`. Links the AriaMcpKit engine for `serve`. |
| [`aria-mcp-server`](aria-mcp-server/) | The standalone **reference MCP server** (the `aria-mcp` binary) — a thin wrapper over `AriaMcpKit`. The same runtime `mootx01 serve` runs; used as the managed external server in demos/tests. |
| [`moot-mgr`](moot-mgr/) | The **manager/admin control surface** — the observer/manager process: admin-plane engine, gated control channel (Unix socket), loopback HTTP read-API, and dashboard. |
| [`Mootx01-App`](Mootx01-App/) | The **Apple presentation-layer app** (macOS · iOS · iPadOS). Projects the ARIA surface onto Siri, Spotlight, Shortcuts, and App Intents. |
| [`moot-agent-skills`](moot-agent-skills/) | A **harness support kit** — starter integrations (Claude, Cline, Codex, Cursor, …) teaching AI harnesses to use MOOTx01 as an automatic memory/reasoning substrate. |
| [`moot-math-benchmark`](moot-math-benchmark/) | Cross-platform **performance benchmarks** for the substrate math primitives (Swift in `swift-bench/`, Rust in `rust-bench/`). |

The engine that the `mootx01` CLI and the Apple app build on — `AriaMcpKit` (the
ARIA-over-MCP server library) — lives in `packages/kits/AriaMcpKit`, not here.
