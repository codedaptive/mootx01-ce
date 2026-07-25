# MOOTx01-App

MOOTx01-App is the native Apple presentation layer for MOOTx01 on macOS,
iOS, and iPadOS. It hosts a local estate, projects ARIA onto Apple system
surfaces, and gives developers a working integration shell for capture,
recall, on-device intelligence, sync, local-network serving, and federation.

This directory is the development app on `develop/1.1.x`. It is distinct from
[`moot-mgr`](../moot-mgr/README.md), which operates and observes the resident
headless daemon.

Start with this guide for building and using the app. Use the
[`MOOTx01-App specification`](../../docs/reference/MOOTX01_APP_SPEC.md) for
the complete behavioral contract and the
[`ARIA-to-Apple mapping`](LEXICON_TO_APPLE_MAPPING.md) for every verb and
system surface.

## What the app provides

| Surface | Current development behavior |
|---|---|
| Capture and recall | Files and searches the app's durable local estate through the ARIA tool surface. Capture includes sensitivity and exportability. |
| Intelligence | Uses Apple Foundation Models through `MootFoundationModelsKit`. Recall is treated as untrusted data. Capture requires one-shot authorization. |
| Siri, Shortcuts, and App Intents | Six caller-driven verbs are implemented and tested. System registration occurs when the generated Xcode app bundle is built and installed. |
| Share Sheet | The extension writes to a durable app-group spool. The host app drains it into the estate at launch and foreground activation. |
| Spotlight and recall widget | Derived, public-only projections. Neither surface is canonical storage, and the widget never opens the estate. |
| Calendar and birthday miners | Disabled by default. Consent can be requested only from an attended Mine Now operation. |
| CloudKit sync | User opt-in and disabled by default. Normal and elevated rows may sync; restricted and secret rows are blocked by the storage wrapper. |
| Portable LAN MCP | Owner-presence credential, read-only tool allowlist, and public/exportable recall. Serving is on-power by default and foreground-bound on iOS. |
| On-demand federation | Off by default. The F1 surface includes Bonjour discovery, QR/SAS pairing, hardware-gated UWB proximity, a Balanced session posture, and explicit session teardown. |
| macOS host controls | Embedded hosting, menu-bar headless mode, and supervision of a separate `aria-mcp` process over stdio. |

## How it fits together

```text
Siri / Shortcuts / App Intents / SwiftUI / callback URLs
Share Sheet spool / Spotlight projection / recall widget
                         |
                    MootGateway
                         |
                     MootBridge
                         |
             in-process ARIA dispatcher
                         |
               GeniusLocusKit estate
                         |
       LocusKit + CorpusKit + supporting kits
```

The app is an envelope around the platform-neutral engine:

- `MootGateway` owns Apple-side orchestration, host selection, sync controls,
  LAN serving, miners, and federation UI coordination.
- `MootBridge` is the one gateway into the ARIA dispatcher. Apple code does
  not bypass it to write estate tables directly.
- `AriaMcpKit`, GeniusLocusKit, and the substrate kits remain the
  Swift/Rust-parity engine.
- App extensions exchange bounded projections or queued capture requests
  through the app group. They do not become additional estate hosts.

## Estate and host ownership

The application follows one rule: **one estate, one host**.

- **Embedded host:** the app opens the estate in-process. This is the normal
  path on macOS, iOS, and iPadOS.
- **Managed daemon:** on macOS the app can spawn and supervise the separate
  `aria-mcp` binary over stdio. The current panel proves process supervision
  and `tools/list` against the daemon's own estate.
- **Direct handoff:** transferring the app's already-open estate to that
  daemon still requires an app-side estate close operation. The current UI
  names this boundary and does not claim that the handoff is complete.

With no test override, the app opens:

```text
<Application Support>/mootx01/mootx01.sqlite
```

The GUI, cold-launched App Intents, callback URLs, miners, share-inbox drain,
and sync driver all resolve through the same process-wide `GatewayRuntime`.

## The application tabs

| Tab | Purpose |
|---|---|
| Capture | File content with location, sensitivity, and exportability. |
| Recall | Search the estate, with an optional public/exportable-only filter. |
| Intelligence | Ask the on-device model to use estate recall, with explicit one-shot capture permission. |
| The Top | Inspect the ARIA tool surface grouped by memory, graph, vault, estate, and reasoning roles. |
| Apple Surfaces | Exercise the six App Intent verbs in-process and inspect their run log. |
| Edges | See which adapters are live, registered, seamed, or deliberately unavailable. |
| Engine | Inspect the embedded host, sync control, LAN serving, daemon supervision, and discovery. |
| Federation | Control visibility, pair estates, choose the available posture, start a timed session, and end it. |
| Miners | Enable Calendar or Birthday mining, select cadence, and run an attended ingest. |

On macOS, menu-bar mode is enabled by default so the embedded engine can stay
alive after the last window closes.

## Build and run

Requirements:

- Xcode with the macOS 27 and iOS 27 SDKs
- Swift 6.2
- `xcodegen`
- Apple signing and entitlements for device-only capabilities

Run the Swift package tests from the repository root:

```sh
swift test --package-path apps/Mootx01-App
```

Generate the app project:

```sh
cd apps/Mootx01-App
xcodegen generate
```

`project.yml` generates `Mootx01-App.xcodeproj`. Build either application
target:

```sh
xcodebuild \
  -project Mootx01-App.xcodeproj \
  -scheme Mootx01-macOS \
  -destination 'platform=macOS' \
  build

xcodebuild \
  -project Mootx01-App.xcodeproj \
  -scheme Mootx01-iOS \
  -destination 'generic/platform=iOS Simulator' \
  build
```

The Swift package contains the reusable `MootGateway` and `GatewayUI`
libraries. The runnable applications are Xcode targets because App Intents,
extensions, entitlements, and system registration require a real app bundle.

### Build the managed server

The macOS Engine panel can supervise the reference `aria-mcp` executable:

```sh
swift build \
  --package-path apps/aria-mcp-server \
  -c release \
  --product aria-mcp
```

Point the panel at:

```text
apps/aria-mcp-server/.build/release/aria-mcp
```

## Configuration and external prerequisites

Several development surfaces are intentionally default-closed:

- **CloudKit:** the user must enable sync. The iCloud container
  `iCloud.com.codedaptive.mootx01` and an available iCloud account are also
  required.
- **Federation discovery:** visibility defaults to Off. Always-visible is
  meaningful only for a resident Mac host.
- **LAN MCP:** starting or revealing the bearer token requires device-owner
  presence. The remote surface is read-only and public-only.
- **Miners:** every source ships disabled. Merely opening the Miners tab does
  not read Calendar or Contacts and does not trigger consent.
- **Siri and Shortcuts:** implementations can run in-process under tests, but
  system registration needs the generated app to be installed.

Provisioning identifiers, signing, app groups, CloudKit, and TestFlight gates
are covered by the
[`Apple provisioning runbook`](../../docs/status/APPLE_PROVISIONING_RUNBOOK.md).

## Security and privacy boundaries

- The estate is SQLCipher encrypted at rest.
- Exportability is the serve-out gate for Spotlight, widgets, LAN recall, and
  other outbound projections.
- CloudKit and federation apply a sensitivity ceiling. Restricted and secret
  rows are not placed on those transports.
- Recalled content sent to a language model is bounded as untrusted data and
  cannot authorize its own capture.
- Callback URLs use a verb allowlist and do not auto-open unapproved return
  schemes.
- Share and widget extensions never open the estate database.
- The privacy manifest declares required-reason APIs and no tracking.

## Current boundaries

- Generic outbound MCP federation through `MootEstateClient.fetch` is still
  guarded and throws. Its local fold-in half exists. This is separate from
  the implemented ConvergenceKit F1 on-demand federation session.
- The standalone daemon does not yet advertise the `_mootx01._tcp` service,
  so app-side daemon discovery remains a seam.
- iOS cannot host a persistent subprocess. Its embedded estate and LAN
  listener exist only while the app receives execution time.
- CloudKit code remains inert until its container and account prerequisites
  are satisfied.
- The F1 federation UI exposes the Balanced posture. Unbuilt postures remain
  visibly locked.

## Source map

| Path | Responsibility |
|---|---|
| `App/` | Application entry point, delegates, App Shortcuts provider, entitlements, and privacy manifest. |
| `Sources/GatewayUI/` | Shared SwiftUI views and application model. |
| `Sources/MootGateway/` | Estate bridge, runtime, host controls, transports, sync, miners, LAN server, and federation. |
| `ShareExtension/` | UI-less capture handoff into the app-group spool. |
| `RecallWidget/` | Public-only derived recall snapshot presentation. |
| `Tests/` | Gateway and UI policy tests, including negative security boundaries. |
| `UITests/` | App Intents metadata and cold-launch integration tests. |
| `project.yml` | Regenerable macOS, iOS, widget, share-extension, and UI-test project definition. |

## Further documentation

- [`MOOTx01-App specification`](../../docs/reference/MOOTX01_APP_SPEC.md)
- [`ARIA lexicon to Apple mapping`](LEXICON_TO_APPLE_MAPPING.md)
- [`Portable LAN server decision`](../../docs/decisions/DECISION_MOOTX01_APP_PORTABLE_LAN_SERVER_2026-07-11.md)
- [`On-demand federation decision`](../../docs/decisions/DECISION_FEDERATION_ONDEMAND_LAN_PROXIMITY_2026-07-18.md)
- [`Apple provisioning runbook`](../../docs/status/APPLE_PROVISIONING_RUNBOOK.md)
- [`System engineering reference`](../../docs/engineering/SYSTEM_ENGINEERING_REFERENCE.md)
