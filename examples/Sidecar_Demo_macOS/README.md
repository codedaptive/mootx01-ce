# Sidecar_Demo_macOS

A small demonstration: a macOS application attaches a MOOT beside
itself and opens that knowledge to an organization through the
ARIA_MCP server. This is the headline pattern named in
`docs/canon/MOOTX01_AND_ARIA_CANON.md` §"The sidecar pattern".

The demo is intentionally small. The point is the pattern, not a
polished product. Two files carry all of the wiring; an agent reading
those two files can replicate the sidecar in any existing macOS
application.

## What it does

`sidecar-demo` is a CLI executable that:

1. Opens an in-memory MOOT — a `LocusKit.Estate` with the
   `GeniusLocusKit` coordinator on top.
2. Constructs an `ARIA_MCP` dispatcher pointed at that MOOT.
3. Runs the ARIA_MCP JSON-RPC over stdio.

Any MCP client — Claude Desktop, Claude Code, MemPalace's own MCP
client, the `mcp` CLI — can launch `sidecar-demo` and reach the
attached MOOT over the standard ARIA_MCP tool surface.

## The two files an agent reads

- `Sources/SidecarDemoApp/MootSidecar.swift` — the attachment object.
  ~50 lines of glue. A host application creates one of these, hands it
  a backend, and reads back the `dispatcher` it will serve. The file's
  header comment names the three steps of the wiring (backend →
  estate-then-coordinator → dispatcher) in order.
- `Sources/sidecar-demo/SidecarDemoMain.swift` — the driver. ~30 lines
  showing how the attachment object plugs into the ARIA_MCP stdio loop.

Read those two files, in that order. They are the demo.

## Build and run

```sh
cd Sidecar_Demo_macOS
swift build
swift run sidecar-demo
```

`swift run sidecar-demo` starts the JSON-RPC loop on stdin/stdout.
Pipe an MCP `initialize` request in, or wire it into any MCP client's
local server configuration.

## Run from an MCP client

Most MCP clients accept a local-executable server entry. The shape is
the same across Claude Desktop, Claude Code, and Cline:

```json
{
  "mcpServers": {
    "sidecar-demo": {
      "command": "/absolute/path/to/Sidecar_Demo_macOS/.build/debug/sidecar-demo"
    }
  }
}
```

The bundled installer (see `Installer/`) already ships an `aria-mcp`
template; copy that template and point the command at this demo
binary if you want to register the demo alongside the production
ARIA_MCP server.

## Test

```sh
cd Sidecar_Demo_macOS
swift test
```

The test target builds `MootSidecar` in-process and verifies the
dispatcher carries the projected verb-noun tool surface and answers
the MCP `initialize` handshake with the sidecar's announced identity.

## Adapt to your own app

A real host application substitutes step 1 of the wiring. Instead of
calling `MootSidecar.attachInMemory()`, call
`MootSidecar.attach(storage:owner:)` with your own backend:

- For a durable estate beside the app: any `Storage` from the
  `PersistenceKit` package (the SQLite backend is the production choice).
- For an ephemeral estate (testing, transient demos): `InMemoryStorage`
  from `PersistenceKitInMemory`, exactly as this demo does.

Everything past step 1 is identical to what this demo does. Read
`MootSidecar.swift` for the three-step pattern; read
`SidecarDemoMain.swift` for the stdio attachment; copy both into your
host application and replace step 1.

## Why a CLI, not an app bundle

The canon directs that demonstration apps stay small. A SwiftPM
executable is the smallest possible delivery: no Xcode project, no
entitlements, no app bundle. The sidecar pattern does not require any
of those — a host application could equally well construct
`MootSidecar` from inside its existing scene and run the stdio loop in
a background task, or attach the dispatcher to a different transport
(SSE, in-process, custom). The CLI executable is the smallest possible
demonstration of the pattern, not a constraint on where the pattern
can live.

## Dependencies

This package links four kits and one MCP target from the surrounding
repository:

- `AriaMCP` (from `../ARIA_MCP`) — the JSON-RPC dispatcher and stdio
  loop.
- `GeniusLocusKit` (from `../GeniusLocusKit`) — the composition layer
  and verb surface.
- `LocusKit` (from `../LocusKit`) — the estate primitive.
- `PersistenceKit` and `PersistenceKitInMemory` (from `../PersistenceKit`) — the
  backend protocol and the in-memory backend the demo uses.

QueueKit, VectorKit, and CorpusKit are transitive through
GeniusLocusKit; they are intentionally not listed in `Package.swift`.

## Platform

macOS 15+ / iOS 18+. The "macOS" in the package name reflects the
demo's home; nothing in the source is macOS-only.
