# Mootx01 — the MOOTx01 ecosystem app

The Apple presentation layer for MOOTx01 (macOS · iOS · iPadOS). It projects the ARIA
surface onto Siri, Spotlight, Shortcuts, and App Intents, and demonstrates MOOTx01 as a
bridge into the Apple ecosystem. Architecture of record: **`docs/decisions/ADR-005`**.

## The model (ADR-005, in one breath)

The clean, **Rust-mirrored** `mootx01`/`aria-mcp` server is a separate binary. This app
**envelopes** it — it never absorbs it (that would break Swift↔Rust parity). The parity
boundary is the seam:

- **Engine** (estate hosting / serving / sourcing) — platform-neutral, Swift↔Rust mirrored. Untouched here.
- **This app** (SwiftUI + App Intents + Shortcuts) — Swift-only, Apple-only, *not* mirrored. A superset + tech demo.

**One estate, one host.** Two host kinds:
- **Server-in-app (embedded)** — in-process, alive only while the app runs. The cross-platform analog (iOS/iPadOS/macOS all do this).
- **App-managed daemon (macOS only)** — the app spawns and supervises the real server binary over stdio, and can hand it a database to *take over* (ownership transfers app→daemon). iOS can't (no persistent subprocess).

## Build & run

```sh
cd apps/Mootx01-App
swift test                      # libraries + the managed-daemon integration test
xcodegen generate               # produces Mootx01.xcodeproj (regenerable from project.yml)
# macOS:
xcodebuild -scheme Mootx01-macOS -destination 'platform=macOS' build
# iOS simulator:
xcodebuild -scheme Mootx01-iOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

The managed-daemon panel (Engine tab, macOS) needs the real server binary; build it once:
`swift build --package-path ../ARIA_MCP -c release --product aria-mcp`, then point the panel at
`../ARIA_MCP/.build/release/aria-mcp`.

## Layout

- `Sources/MootGateway/` — the substrate-facing bridge: `MootBridge` (drives the ARIA tool
  surface), the transport modes (`Engine/ManagedServerProcess` = app-managed daemon; the HTTP
  seam), the App Intent / callback-URL / share-sink shells, and the lexicon→Apple mapping.
- `Sources/GatewayUI/` — the shared SwiftUI surface (model + tabs: Capture, Recall, The Top,
  Intelligence, Apple Surfaces, Edges, Engine, and Miners) used by both app targets.
- `App/` — the app targets' `@main` + the app-target `AppShortcutsProvider` (what registers the
  App Intents with the system).
- `project.yml` — xcodegen spec (macOS + iOS targets). `LEXICON_TO_APPLE_MAPPING.md` — the
  complete ARIA-lexicon → Apple-surface mapping + WWDC reaction-delta map.

## Apple intelligence

- Cold-launched App Intents attach the same durable estate as the GUI; DEBUG XCUITests use a
  persisted, disposable estate selector and clear it after each test.
- `packages/apple/MootFoundationModelsKit` provides provider-neutral Foundation Models recall
  and one-shot-authorized capture tools. Recalled text is explicitly bounded as untrusted data.
- The Intelligence tab uses `SystemLanguageModel` today; the session factory accepts any
  OS-27 `LanguageModel`, including compatible PCC or Core AI providers.
- Core Spotlight donation is a derived projection, never canonical storage. Only explicitly
  public, normal/elevated memories are indexed; private, restricted, and secret content is
  excluded. `SpotlightSearchTool` is enabled on Apple Silicon.
- Calendar and birthday miners are disabled by default. Only Mine Now may request consent;
  unattended macOS ticks and opportunistic iOS background refreshes use existing grants only.

## Status

Embedded server-in-app + the macOS app-managed-daemon (proven by an integration test
that spawns the real `aria-mcp` and round-trips `tools/list`). App Intents are system-registered
(real, in the app bundle) and exercised through AppIntentsTesting on an iOS 27 simulator.
Developer examples that build on this live in `examples/Moot*`.
The loopback-HTTP client mode (connect to a standalone daemon) is seamed, not built (it belongs to
the loopback-HTTP transport workstream).
