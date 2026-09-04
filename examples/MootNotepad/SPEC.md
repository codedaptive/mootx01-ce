# MootNotepad — Technical Spec

A minimal notes app whose **entire backing store is a MOOT estate**. No Core
Data, no SwiftData, no files — every note is a MOOT *drawer*, and the note list
is rebuilt by recalling those drawers from the substrate.

## What it demonstrates

- **Building a brand-new app on top of MOOT as the database.** The app keeps no
  authoritative state of its own; `NotepadModel.notes` is a cache of what the
  MOOT holds. Every write re-reads from the substrate to stay in step with it.
- **The five-tool CRUD surface** over the ARIA tool API.
- **The structured-result contract** — reading `structuredContent.results`
  rows instead of the human-readable text, and hydrating bodies by id.
- **Sample-data seeding** on first launch.

## The MOOT calls used

All calls go through one `MootBridge`, acquired from `GatewayRuntime.shared`.

| App action | Tool | Arguments | Result handling |
|---|---|---|---|
| List / search notes | `moot_memory_search` | `query` (`"*"` or term), `limit` | Collect the `id` of every structured result row |
| Load note bodies | `moot_memory_get` | `ids` (from the search), `depth: "full"` | Build `Note` rows from `id`, `room`, `content`; filter to room `notes` |
| New note | `moot_file_memory` | `content`, `location: "notes"` | Ignore returned text; `refresh()` to re-read |
| Delete note | `moot_withdraw_memory` | `id` (drawer id from the result row) | `refresh()` to re-read |
| Toolbar summary | `moot_estate_status` | — | Show first line |

Arguments are `JSONValue` (`import AriaMCP`): `.string(…)`, `.double(…)`.

## The structured-result contract

Every recall-family tool answers twice: a text block for people, and a
`structuredContent` block the app reads. `IntentCallResult.structured` is
that block, verbatim:

```
{ "results": [ { "id": "…", "room": "…", "subject": "…", "content": "…" }, … ] }
```

Optional fields are absent, never null, when the tool has nothing to say.
Consequences for this example:

- `moot_memory_search` rows are travel rows: `id`, `subject`, `room`, no
  body. The list needs the body, so `refresh()` collects the ids and calls
  `moot_memory_get` once with `ids:[…]` and `depth:"full"`, whose rows carry
  `content` and `room`.
- `Note.from(row:)` accepts only rows with a UUID `id` and a `content`; a
  gated or opaque drawer has neither and is dropped.
- The app never parses the text block.

## Estate location

Durable SQLite at:

```
<App Support>/MootNotepad/notepad.sqlite
```

`MootBridge.attachSQLite(at:)` auto-creates parent folders. Delete the file to
reset and re-seed.

## Files

| File | Role |
|---|---|
| `App/MootNotepadApp.swift` | `@main`; launch wiring (configure runtime, attach bridge, seed, refresh) |
| `App/NotepadView.swift` | `Note` + row decoder, `NotepadModel` (all MOOT calls), `NotepadView` UI |
| `project.yml` | xcodegen spec; universal iOS + macOS app target |

## Concurrency

Strict Swift 6. `NotepadModel` and `NotepadView` are `@MainActor`. `MootBridge`
and `GatewayRuntime` are actors; all tool calls are `await`ed.
