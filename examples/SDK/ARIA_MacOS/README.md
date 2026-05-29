# ARIA_MacOS

**Status:** 🔲 Not yet built — macOS app target

The macOS application target for Nexus. A native macOS app built in SwiftUI,
Mac-primary, that exposes the GeniusLocus estate to the user through the
Nexus product experience.

## What this target is

ARIA_MacOS is the macOS application shell. It:
- Provides the macOS SwiftUI scene, window groups, and app lifecycle
- Wires ARIA_MCP (MCP surface) and NeuronKit into the user interface
- Owns macOS-specific UI (menu bar, keyboard shortcuts, window management)
- Handles macOS-specific platform integration (Spotlight, Quick Look,
  Share Sheet, Notification Centre)

ARIA_MacOS does **not** implement business logic. All reasoning, storage,
and retrieval goes through the kit stack below it.

## Platform

- macOS 15+ only
- Apple Silicon optimised (not universal)
- SwiftUI with AppKit interop where needed
- Swift 6 strict concurrency

## Key specs to read before any mission

1. `docs/canon/MOOTX01_SPEC.md` — the Nexus product specification; defines the
   user-facing product this target delivers
2. `docs/specs/ARIA_MCP_SPEC_v0.1.md` — the kit this target calls into
3. `.claude/skills/swiftui-patterns/SKILL.md` — SwiftUI patterns for this fleet
4. `.claude/skills/swiftui-platform-strategy/SKILL.md` — platform strategy

## Mission placement rules

**Belongs in ARIA_MacOS** if it:
- Implements a SwiftUI view, scene, or window group for macOS
- Handles macOS app lifecycle (AppDelegate, scene phases)
- Integrates macOS-specific system APIs (Spotlight, menu bar, etc.)
- Implements macOS-specific navigation or window management

**Does not belong in ARIA_MacOS** if it:
- Implements business logic or algorithms → kit stack
- Shares UI with iOS → consider a shared module in ARIA_MCP
- Changes any kit API → the relevant kit directory

## Relationship to ARIA_iOS

ARIA_MacOS and ARIA_iOS are separate targets with distinct UI paradigms.
Mac-primary means the macOS experience is the reference design. Shared
non-UI code lives in ARIA_MCP.
