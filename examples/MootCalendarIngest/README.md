# MootCalendarIngest

A MOOTx01 SDK example showing how to give a **legacy app you cannot change**
(Apple Calendar) a memory: the app reads this week's events with EventKit and
files each one into the MOOT via `moot_file_memory` — with **zero changes** to
Calendar (we only ever read it). A search box then proves the ingested events are
real, searchable MOOT drawers, and an `AppShortcutsProvider` exposes the SDK's
`CaptureDrawerIntent` / `RecallDrawerIntent` to Siri and Shortcuts against the
same shared estate. Read `GUIDE.md` for the plain-English tour and `SPEC.md` for
the technical detail. iOS only.

## Open in Xcode

```sh
xcodegen generate
```

Then open `MootCalendarIngest.xcodeproj`. On the simulator, tap **Grant calendar
access → Seed sample events → Load this week's events → Sync this week to MOOT**,
then search for `standup` or `lunch`.
