# ARIA_iOS

**Status:** 🟡 In progress — iOS gateway app. There is **no sequencing gate**
on iOS work. (A prior version of this README asserted iOS could not start
until "macOS ships + iCloud sync is stable"; that mandate was not a real constraint,
and has been removed.)

The iOS application target. A native iOS app built in SwiftUI, projecting the
ARIA surface onto iPhone/iPad — peer to, not downstream of, the macOS app.

## What this target is

ARIA_iOS is the iOS application shell. It:
- Provides the iOS SwiftUI scene and app lifecycle
- Exposes the GeniusLocus estate through an iOS-appropriate UI
- Handles iOS-specific platform integration (Share Extension, Shortcuts,
  Widgets, Background Tasks, push notifications)
- Adapts the Mac-primary product design to iPhone/iPad interaction patterns

## Platform

- iOS 26+ (iPhone and iPad), matching the kit stack floor
- Apple Silicon only
- SwiftUI
- Swift 6 strict concurrency

## Key specs to read before contributing

1. `docs/canon/MOOTX01_SPEC.md` — the MOOTx01 product specification
2. `docs/specs/ARIA_MCP_SPEC.md` — the kit this target calls into

## Scope

**Belongs in ARIA_iOS** if it:
- Implements a SwiftUI view for iOS/iPadOS
- Handles iOS app lifecycle
- Integrates iOS-specific APIs (Share Extension, Shortcuts, WidgetKit)
- Adapts an existing feature to the iOS interaction paradigm

**Does not belong in ARIA_iOS** if it:
- Should also exist on macOS → implement in ARIA_MacOS first, then adapt
- Implements business logic → kit stack
- Changes any kit API → the relevant kit directory

## Related

The MOOTx01 ecosystem app — universal macOS + iOS + iPadOS, the Apple
presentation layer (App Intents, Shortcuts, Siri) over the clean engine —
lives at `apps/Mootx01-App/` (architecture: `docs/decisions/ADR-005`), with its
lexicon→Apple mapping. Developer examples that build on the same `MootGateway`
SDK live in `examples/Moot{Notepad,Todo,CalendarIngest}/`.
