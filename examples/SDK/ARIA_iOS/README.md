# ARIA_iOS

**Status:** 🔲 Not yet built — iOS app target (Rev 3.0, after macOS stable)

The iOS application target for Nexus. A native iOS app built in SwiftUI,
complementing the macOS-primary experience.

## What this target is

ARIA_iOS is the iOS application shell. It:
- Provides the iOS SwiftUI scene and app lifecycle
- Exposes the GeniusLocus estate through an iOS-appropriate UI
- Handles iOS-specific platform integration (Share Extension, Shortcuts,
  Widgets, Background Tasks, push notifications)
- Adapts the Mac-primary product design to iPhone/iPad interaction patterns

Per `docs/specs/LOCI_MODE_SPEC_v0.1.md`: iOS ships in Rev 3.0, after iCloud
sync (Rev 2.x) is stable. Do not start iOS missions until:
- macOS app (ARIA_MacOS) is shipping
- iCloud sync via CKSyncEngine is implemented and stable
- The decision to proceed with iOS is explicitly made

## Platform

- iOS 18+ (iPhone and iPad)
- Apple Silicon only (no Intel-era iPad support)
- SwiftUI
- Swift 6 strict concurrency

## Key specs to read before any mission

1. `docs/canon/MOOTX01_SPEC.md` — the Nexus product specification
2. `docs/specs/LOCI_MODE_SPEC_v0.1.md` — Rev 3.0 scope definition
3. `docs/specs/ARIA_MCP_SPEC_v0.1.md` — the kit this target calls into
4. `.claude/skills/swiftui-patterns/SKILL.md`
5. `.claude/skills/swiftui-platform-strategy/SKILL.md`

## Mission placement rules

**Belongs in ARIA_iOS** if it:
- Implements a SwiftUI view for iOS/iPadOS
- Handles iOS app lifecycle
- Integrates iOS-specific APIs (Share Extension, Shortcuts, WidgetKit)
- Adapts an existing feature to the iOS interaction paradigm

**Does not belong in ARIA_iOS** if it:
- Should also exist on macOS → implement in ARIA_MacOS first, then adapt
- Implements business logic → kit stack
- Changes any kit API → the relevant kit directory

## Build gate

**Do not open iOS missions until ARIA_MacOS is shipping and iCloud sync
is stable.** This directory exists to document intent and reserve the
namespace. The README is the only thing that belongs here until Rev 3.0.
