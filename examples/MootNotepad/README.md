# MootNotepad

A minimal, universal (iOS + macOS) notes app whose **entire backing store is a
MOOT estate** — no Core Data, no SwiftData, no files. Each note is a MOOT drawer
filed via `moot_file_memory` into the room `notes`; the list is rebuilt by
recalling drawer ids with `moot_memory_search` and fetching their bodies with
one batched `moot_memory_get`; deleting a note withdraws its drawer with
`moot_withdraw_memory`. It demonstrates building a brand-new app on top of MOOT
as the database, the structured-result contract of the ARIA tool surface, and
first-launch sample seeding.

## Open in Xcode

```sh
xcodegen generate
```

Then open `MootNotepad.xcodeproj`. See `GUIDE.md` for a plain-language tour and
`SPEC.md` for the technical details (the exact MOOT calls and intents).
