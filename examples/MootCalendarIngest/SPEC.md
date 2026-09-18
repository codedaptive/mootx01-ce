# MootCalendarIngest — Technical Spec

## What it demonstrates

Giving a **legacy app you cannot change** (Apple Calendar) a **memory** by
reading its data and writing that data into the MOOT — with **zero changes** to
Calendar. The app only ever *reads* real calendar events; the MOOT is where the
memory lives.

This is the canonical pattern for "I have an app I don't own, but I want its data
in the MOOT": read it through whatever API the OS exposes (here, EventKit), then
file it via the MootGateway SDK.

Platform: **iOS only** (EventKit full-access flow + iPhone/iPad UX).

## The five-step demo flow

1. **Grant calendar access** — `EKEventStore.requestFullAccessToEvents()`.
2. **Seed sample events** (simulator only) — create 3 `EKEvent`s this week so
   there is data to read. The *only* writes this app makes to Calendar.
3. **Load this week's events** — `predicateForEvents(withStart:end:calendars:nil)`
   over the current `weekOfYear` interval, across all calendars. Read-only.
4. **Sync to MOOT** — for each event, one `moot_file_memory` call.
5. **Search memory** — `moot_memory_search` proves the events are now searchable
   MOOT drawers.

## MOOT calls used (via `MootBridge` over the ARIA tool surface)

| Tool | When | Arguments | Returns |
|---|---|---|---|
| `moot_memory_search` | seed probe + Search box | `query`, `limit?` | structured rows: `id`, `subject`, `room` |
| `moot_memory_get` | Search box, after the search | `ids`, `depth: "full"` | structured rows: `id`, `room`, `content` |
| `moot_file_memory` | seed + each event sync | `content`, `location` | text: `filed memory <id>\nroom: …\nlineage: …` |

All arguments are `JSONValue` (`import AriaMCP`). `location` is the drawer's
**room** — every ingested event files into room `"calendar"`.

## Wiring

- `MootCalendarIngestApp` calls `GatewayRuntime.shared.configure(databaseURL:)`
  at launch, pointing at a durable SQLite file in Application Support, then
  triggers `model.attach()` and `seedSampleMemoriesIfEmpty()`.
- `CalendarIngestModel` gets its bridge from `GatewayRuntime.shared.bridge()`.

## The result contract (called out in code)

Every recall tool answers with text for people and a `structuredContent`
block, `{ "results": [ { "id", "room", "subject", "content" }, … ] }`, exposed
as `IntentCallResult.structured`. `searchMemory()` reads the search rows for
ids, fetches the bodies with one batched `moot_memory_get` at depth:full, and
renders one line per drawer. The app never parses the text block.

## Permissions

`INFOPLIST_KEY_NSCalendarsUsageDescription` (set in `project.yml`):
"MootCalendarIngest reads this week's events to file them into your MOOT."
