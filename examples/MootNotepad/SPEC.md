# MootNotepad — Technical Spec

A minimal notes app whose **entire backing store is a MOOT estate**. No Core
Data, no SwiftData, no files — every note is a MOOT *drawer*, and the note list
is rebuilt by recalling those drawers from the substrate.

## What it demonstrates

- **Building a brand-new app on top of MOOT as the database.** The app keeps no
  authoritative state of its own; `NotepadModel.notes` is a cache of what the
  MOOT holds. Every write re-reads from the substrate to stay honest.
- **The four-tool CRUD surface** over the ARIA tool API.
- **The text-result parsing edge** — turning `moot_memory_search` text lines
  into structured note rows.
- **Real, system-registered App Intents** sharing one estate with the UI.
- **Sample-data seeding** on first launch.

## The MOOT calls used

All calls go through one `MootBridge`, acquired from `GatewayRuntime.shared`.

| App action | Tool | Arguments | Result handling |
|---|---|---|---|
| List / search notes | `moot_memory_search` | `query` (`"*"` or term), `limit` | **Parse** text lines `"<id>  [room]  <preview>"` into `Note` rows; filter to room `notes` |
| New note | `moot_file_memory` | `content`, `location: "notes"` | Ignore returned text; `refresh()` to re-read |
| Delete note | `moot_withdraw_memory` | `id` (drawer id from parse) | `refresh()` to re-read |
| Toolbar summary | `moot_estate_status` | — | Show first line |

Arguments are `JSONValue` (`import AriaMCP`): `.string(…)`, `.double(…)`.

## The text-result edge (known SDK edge)

The ARIA tool surface returns **text**, not structured drawers.
`moot_memory_search` answers with:

```
found N memory(s)
<id>  [room]  <preview>
<id>  [room]  <preview>
```

`Note.parse(line:)` peels each row apart on the bracketed room token to recover
`id`, `room`, and `preview`. Consequences for this example:

- The list shows the **preview**, not the verbatim full body. A production app
  would call a structured "get drawer by id" tool for the full content; that
  tool does not exist on the current surface, so the preview is what we show and
  treat as the note text. Flagged in code with `// NOTE(integrate):`.
- The header line (`found N memory(s)`) parses to `nil` and is dropped.

A production app would prefer a **structured recall tool** returning real drawer
objects. Until then, text parsing is the documented integration path.

## App Intents

The intent **types** are public in `MootGateway`. The app target ships an
`AppShortcutsProvider` (`MootNotepadShortcuts`) — required for the metadata
extractor to register them with the system.

| Intent | Verb | Tool | Note |
|---|---|---|---|
| `CaptureDrawerIntent` | capture | `moot_file_memory` | Constructed with `location: "notes"` so voice captures land in the app's room |
| `RecallDrawerIntent` | recall | `moot_memory_search` | Searches notes by query |

Both reach the estate via `GatewayRuntime.shared.bridge()` — the same singleton
the app configures at launch — so voice-captured notes appear in the UI list and
vice versa. **One estate, two entry points.**

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
| `App/MootNotepadShortcuts.swift` | `AppShortcutsProvider`; the room constant |
| `App/NotepadView.swift` | `Note` + parser, `NotepadModel` (all MOOT calls), `NotepadView` UI |
| `project.yml` | xcodegen spec; universal iOS + macOS app target |

## Concurrency

Strict Swift 6. `NotepadModel` and `NotepadView` are `@MainActor`. `MootBridge`
and `GatewayRuntime` are actors; all tool calls are `await`ed.
