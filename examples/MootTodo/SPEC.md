# MootTodo — Technical Spec

## What it demonstrates

The **sidecar pattern**: an app keeps its own primary store and runs a
**parallel MOOT** beside it that accumulates a searchable memory — with about
five lines of glue. The app gains full-text search "for free" by mirroring
each write into the MOOT.

Universal (iOS + macOS), Swift 6 strict concurrency.

## The two stores

| Store | Backing | Source file | Role |
|---|---|---|---|
| Primary | Codable JSON file in Application Support (`todos.json`) | `TodoModel` (Layer 1) | The app's source of truth: `[Todo]`, each `{ title, done }`. No MOOTx01 dependency. |
| Sidecar (MOOT) | Durable SQLite estate (`moot.sqlite`) | `TodoModel` (Layer 2) | Parallel searchable memory. Mirrors every todo write. |

Deliberately **no SwiftData** — the primary store is hand-rolled Codable so the
contrast with the MOOT sidecar stays crystal clear.

## The MOOT calls used

All through `MootBridge.callTool(...)`, the public ARIA tool surface (the app
never reaches around it into the substrate):

- `moot_file_memory { content, location }` — the **mirror**. Called on every
  add and every toggle. `content` is `"TODO: <title> [open|done]"`; `location`
  is the room `"todos"`. This is the ~5-line sidecar (`TodoModel.mirrorToMoot`).
- `moot_memory_search { query, limit }` — the **search** the app gained for
  free (`TodoModel.search`), and the **emptiness probe** used to decide whether
  to seed sample data (`TodoModel.seedSampleDataIfEmpty`).

- `moot_memory_get { ids, depth: "full" }` — the **hydration** step. Search
  rows are travel rows (id, subject, room) with no body; one batched call
  returns the verbatim content of every hit.

### The result contract (documented in code)

Every recall tool answers with text for people and a `structuredContent`
block, `{ "results": [ { "id", "room", "subject", "content" }, … ] }`, exposed
as `IntentCallResult.structured`. `TodoModel.search` reads the search rows
for ids, fetches the bodies with `moot_memory_get`, and renders one
`MemoryHit` per drawer. The app never parses the text block.

## Wiring

1. `MootTodoApp.bootstrapMoot()` (runs in `.task` at launch):
   - `GatewayRuntime.shared.configure(databaseURL:)` → durable SQLite at
     `Application Support/MootTodo/moot.sqlite`.
   - `GatewayRuntime.shared.bridge()` → handed to `TodoModel.attach(bridge:)`.
   - `seedSampleDataIfEmpty()` seeds three todos on a fresh estate.
2. The UI gets its bridge from the **same** `GatewayRuntime.shared`, so every
   part of the app writes to one estate.

## Files

```
examples/MootTodo/
  App/MootTodoApp.swift        @main; launch-time MOOT wiring + seeding
  App/TodoModel.swift          primary store (Layer 1) + MOOT sidecar (Layer 2)
  App/ContentView.swift        SwiftUI UI: list (primary) + search (MOOT)
  App/Localizable.xcstrings    string catalog (no literals in views)
  project.yml                  xcodegen project (universal app)
  SPEC.md / GUIDE.md / README.md
```
