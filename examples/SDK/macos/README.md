# ARIA_MacOS

**Status:** Planned — not yet built. The shipping Apple app already lives at `apps/Mootx01-App/`; this is a future SDK-demonstration shell. For working SDK usage today, see `docs/start-here/SDK_QUICKSTART.md` and `examples/MootNotepad` / `examples/MootTodo`.

The macOS application target for MOOTx01. A native macOS app built in SwiftUI,
Mac-primary, that exposes the GeniusLocus estate to the user through the
MOOTx01 product experience.

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

## Key specs to read before contributing

1. `docs/concepts/MOOTX01_AND_ARIA_CANON.md` — the MOOTx01 product specification; defines the
   user-facing product this target delivers
2. `docs/reference/ARIA_MCP_SPEC.md` — the kit this target calls into

## Scope

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
