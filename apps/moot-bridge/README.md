# moot-bridge

A **bridging MCP memory server**. An AI client launches `moot-bridge` as its single
memory MCP server; the bridge fans the client's MCP traffic out across one or more
backend memory servers (the primary plus secondaries) so a client gets the union of
several memory backends behind one endpoint, with per-backend stats.

It is a transport-level multiplexer — it parses and rebuilds JSON-RPC envelopes whose
shapes aren't known at compile time and forwards them, without modelling the
substrate itself.

- Swift: `Sources/moot-bridge` → product `moot-bridge` (`BridgeServer`, `BridgeConfig`,
  `RawMCPBackend`, `BridgeStats`).
- Rust: `rust/` → the Rust twin (`moot-bridge` binary over the `moot_bridge` lib).

The AI flips the active primary mid-session via the `bridge_set_primary` tool.

> **Advanced / optional tool.** moot-bridge is not part of the standard install — it is
> not built by the installers (`install.sh` / `install.ps1`) or shipped as a release
> asset; those provide `mootx01` (and, on macOS, `moot-mgr`). moot-bridge is for users who
> run more than one memory MCP backend and want them unified behind one endpoint. Build it
> from source as shown below.

## Build

```sh
# Swift (macOS) → .build/release/moot-bridge
swift build -c release
# the binary:
./.build/release/moot-bridge --config bridge-config.json

# Rust (Linux / Windows / macOS) → target/release/moot-bridge
cd rust && cargo build --release
./target/release/moot-bridge --config ../bridge-config.json
```

## Configure

Configuration is a JSON file describing two backends and which one starts as primary.
Each backend names its launch `command` (a stdio MCP server; an env-var prefix is
honored) and a `verbMap` that tells the bridge which of *that* server's tools mean
"write" and "query" — so the bridge is not hardcoded to any one engine's tool names.

`verbMap.write` and `verbMap.query` are required; `contentArg` (default `content`),
`queryArg` (default `query`), `constantArgs`, and `resultFormat` (default `mootText`)
default when omitted, so a terse config still runs.

Example `bridge-config.json` (MemPalace as primary, mootx01 as secondary):

```json
{
  "backendA": {
    "name": "mempalace",
    "command": "mempalace-mcp --palace /path/to/palace",
    "verbMap": {
      "write": "mempalace_add_drawer",
      "query": "mempalace_search",
      "constantArgs": { "wing": "scratch", "room": "notes" },
      "resultFormat": { "kind": "jsonObjects", "contentKey": "text" }
    }
  },
  "backendB": {
    "name": "mootx01",
    "command": "MOOTX01_DATA_DIR=/path/to/data mootx01 serve",
    "verbMap": {
      "write": "moot_file_memory",
      "query": "moot_memory_search",
      "constantArgs": { "location": "scratch/notes" },
      "resultFormat": { "kind": "mootText" }
    }
  },
  "primary": "mempalace"
}
```

`primary` must equal one backend's `name`, or the config fails to load. Point your AI
client's MCP config at the `moot-bridge --config bridge-config.json` command in place of
a single memory server.
