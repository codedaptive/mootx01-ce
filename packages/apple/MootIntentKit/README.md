# MootIntentKit

Apple-only intent surface for MOOTx01. Placement: `packages/apple/` — above the platform-neutral kit stack (parity line), Apple-only, no Rust twin required.

## Placement rationale

The engine kits (`GeniusLocusKit`, `LocusKit`, etc.) are platform-neutral and have Rust mirrors. This package sits above that parity line. It is the iOS/iPadOS-native equivalent of the MCP server surface — the six caller-driven ARIA verbs exposed through App Intents, Shortcuts, callback-URL routing, and the Share Sheet capture sink. It belongs in `packages/apple/` rather than `apps/Mootx01-App/Sources/` so other Apple host apps (examples, a future CE app) can consume the intent logic without pulling in `MootBridge`'s substrate imports.

## What lives here

| Component | File | ARIA verb |
|-----------|------|-----------|
| `CaptureDrawerIntent` | `CaptureDrawerIntent.swift` | capture |
| `RecallDrawerIntent` | `RecallDrawerIntent.swift` | recall |
| `ReanchorDrawerIntent` | `CallerVerbIntents.swift` | reanchor |
| `MutateDrawerIntent` | `CallerVerbIntents.swift` | mutate |
| `WithdrawDrawerIntent` | `CallerVerbIntents.swift` | withdraw |
| `ExpungeDrawerIntent` | `CallerVerbIntents.swift` | expunge |
| `DrawerEntity` | `DrawerEntity.swift` | noun |
| `MootURLRouter` | `MootURLRouter.swift` | read-only recall via x-callback-url (mutating verbs rejected — App Intents is the consented path) |
| `CaptureSink` | `CaptureSink.swift` | capture via Share Sheet |
| `MootShortcutsProvider` | `MootShortcutsProvider.swift` | Shortcuts catalog donation |

## Dependency seam

`MootIntentKit` imports only `AriaMCP` (for `JSONValue`). It never imports substrate kits. The seam is the `MootToolCalling` protocol — `MootBridge` (in `apps/Mootx01-App`) conforms to it, so the kit never reaches substrate internals directly.

## System registration

These intents are live iOS-native capabilities. They are not yet registered with the system Shortcuts catalog because that requires an Xcode app bundle to declare this package's `AppIntentsPackage` — a packaging step, not a capability gap. All six `perform()` implementations route through `MootToolCalling` against a real estate today.
