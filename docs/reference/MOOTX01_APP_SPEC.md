---
title: MOOTx01-App — Specification
version: v0.3
status: draft
date: 2026-08-04
relates_to:
  - docs/engineering/SYSTEM_ENGINEERING_REFERENCE.md#11-edition-and-application-boundary
  - apps/Mootx01-App/LEXICON_TO_APPLE_MAPPING.md
  - docs/decisions/DECISION_MOOTX01_APP_PORTABLE_LAN_SERVER_2026-07-11.md
  - docs/decisions/DECISION_FEDERATION_ONDEMAND_LAN_PROXIMITY_2026-07-18.md
---

# MOOTx01-App — Specification

The Apple presentation layer for MOOTx01: macOS, iOS, and iPadOS. It projects
the estate onto Apple's intelligence and automation surfaces — Siri, Spotlight,
Shortcuts, App Intents, Foundation Models, Widgets — and can serve the estate
to other devices over the LAN. It is a **superset and technology demonstration**
of the estate, not the estate itself.

Status legend used throughout: **live** (works today), **pending registration**
(implemented + tested; activates when the Xcode app bundle is built and
installed), **seam** (a typed boundary; the far side lands later), **inert**
(wired and correct; activates when an external prerequisite — signing, an
iCloud container — is provided), and **guarded** (the type and local path
exist, but the unavailable operation rejects instead of returning fabricated
data).

---

## 1. What the app is

The clean, Rust-mirrored `mootx01` / `aria-mcp` server is a separate program.
This app **envelopes** it — it never absorbs it, because absorbing it would
break Swift↔Rust parity. The seam between them is the **parity boundary**:

- **Engine** (estate hosting, serving, sourcing) — platform-neutral, Swift and
  Rust mirrored. The app does not modify it.
- **This app** (SwiftUI + App Intents + Shortcuts + Apple intelligence) —
  Swift-only, Apple-only, *not* mirrored. A superset over the engine.

**One estate, one host.** Two host kinds:

- **Server-in-app (embedded)** — the engine runs in-process, alive only while
  the app runs. The cross-platform path; iOS, iPadOS, and macOS all use it.
  (Adapter A1, **live**.)
- **App-managed daemon (macOS only)** — the app spawns and supervises the real
  server binary over stdio and can hand it a database to take over (ownership
  transfers app→daemon). iOS cannot host a persistent subprocess.

Every Apple surface reaches the estate through one seam: `MootBridge`, which
drives the in-process ARIA dispatcher (`ARIA_MCPDispatcher.handle`). No Apple
code opens estate storage directly; extensions (Share, Widget) never open the
estate at all.

---

## 2. The lexicon: noun, verbs, adjectives

The estate's vocabulary is fixed. The app projects it onto Apple surfaces; it
never invents new verbs.

**Noun — Drawer.** A memory. Projected as `DrawerEntity` (an App Intents
`AppEntity`) so Siri, Spotlight, and Shortcuts can carry a memory between steps
and index it. `DrawerEntity` is `SyncableEntity` (its `id` is a stable estate
UUID, identical on every device).

**Verbs.** Six are caller-invokable and map to App Intents:

| Verb | Direction | App Intent | Reach |
|---|---|---|---|
| capture | write | `CaptureDrawerIntent` | Share Sheet · Shortcuts · Siri · Action Button |
| recall | read | `RecallDrawerIntent` | Siri · Spotlight · Shortcuts · Action Button |
| reanchor | structural | `ReanchorDrawerIntent` | Shortcuts |
| mutate | write | `MutateDrawerIntent` | Shortcuts |
| withdraw | write | `WithdrawDrawerIntent` | Shortcuts |
| expunge | write (guarded) | `ExpungeDrawerIntent` | Shortcuts, confirmation-gated |

Two further verbs — **propose** and **associate** — are Brain-emitted, not
caller-invokable, and have no Apple surface (their natural home is App Intents
elicitation, a later mapping). **learn** is grounding, fed internally.

**Adjectives** (read-only context except where noted):
- **state** — active, pending, contested, superseded, decayed, withdrawn,
  expired, rejected, accepted, tombstoned.
- **trust** — verbatim, observed, imported, proposed, derived, canonical.
- **sensitivity** — normal, elevated, restricted, secret. A **capture
  parameter** and a recall ceiling.
- **exportability** — private / public. The **serve-out gate**: only public
  drawers leave the device (Spotlight, the LAN server, `filter:exportable`
  recall). Set at capture or promoted later via `mutate`.

`RecallDrawerIntent` returns a typed `[DrawerEntity]` value plus spoken dialog,
so a Shortcut can recall memories in one step and act on them in the next.

---

## 3. Apple surfaces (adapters A1–A6)

The authoritative runtime state is `AdapterStatus.swift` (surfaced in the app's
Edges tab).

| Code | Adapter | State |
|---|---|---|
| A1 | Embedded server-in-app | **live** |
| A2 | ARIA server on this device (loopback HTTP + LAN) | **seam** (see §6) |
| A3 | Consume arbitrary remote MCP estates | **guarded** — local fold-in exists; `MootEstateClient.fetch` throws |
| A4 | App Intents (Siri / Spotlight / Shortcuts) | **pending registration** |
| A5 | Callback URL (`mootx01://x-callback-url/<verb>`) | **pending registration** |
| A6 | Shortcuts catalog donation | **pending registration** |

A4–A6 are implemented and tested; they become system-active once the Xcode app
bundle is built and installed (the App Intents metadata extractor registers the
intents, `CFBundleURLTypes` registers the URL scheme, and
`updateAppShortcutParameters()` donates the phrases at launch).

**App Shortcuts phrases** (donated by the app target):
- Capture: "Capture this in MOOTx01", "Remember this with MOOTx01"
- Recall: "Recall from MOOTx01", "Search my memories in MOOTx01"

**Callback URLs** (A5): `mootx01://x-callback-url/<verb>?…` with an x-callback
success/error return. The URL surface is read-only: the verb allowlist admits
`recall` only. Verbs that mutate persistent estate state — capture and
reanchor as much as expunge, withdraw, and mutate — are rejected, because an
inbound URL carries no trustworthy caller identity and this path has no
per-invocation consent surface; mutations go through the device-authenticated
App Intents path instead. Open-redirect is blocked (return URL is dropped
unless its scheme is allowlisted), and URL-routed recall is forced to the
exportable filter.

**Heavy verbs** (macOS/iOS 27 gated): reindex, import-palace, import-vault,
and dream are `LongRunningIntent` + `CancellableIntent` — the system shows a
Live Activity with progress and a stop button; progress is read from the drain
queues.

**Batch curation:** `BatchMutateIntent` / `BatchWithdrawIntent` operate over
`EntityCollection` (IDs only, no full resolution), with a single-slot undo
(`UndoLastBatchWithdrawIntent`).

**Ingestion targeting:** capture accepts an optional `wing` and `eventTime` so
imported content lands in the right place and time.

---

## 4. Apple intelligence

**Foundation Models** (`MootFoundationModelsKit`). `MootMemoryAssistant` builds
a provider-neutral `LanguageModelSession` (defaulting to `SystemLanguageModel`;
any OS-27 `LanguageModel` — PCC, Core AI — can be injected) with two tools:

- `recall_moot_memory` — reads the estate. The returned text is wrapped in an
  explicit untrusted-data boundary, and any occurrence of the boundary sentinel
  inside recalled content is defanged so a poisoned drawer cannot break out of
  the block and inject instructions.
- `capture_moot_memory` — append-only write, permitted only under a one-shot
  authorization the host arms for a single capture.

The assistant instructions bind recalled content as *data, never instructions*,
forbid claiming a memory exists unless recall returned it, and forbid exposing
restricted/secret content. A deterministic eval suite covers the injection
boundary, the sensitivity ceiling (secret content never crosses the model
boundary), and the capture→recall grounding loop.

**Core Spotlight donation** is a derived projection, never canonical storage.
Only explicitly public, normal/elevated drawers are indexed; private,
restricted, and secret content is excluded. `SpotlightSearchTool` is enabled on
Apple Silicon.

**The embedding lane** is the estate's own `VectorKit.EmbeddingProvider` (with a
Rust parity twin); a real on-device Apple provider belongs there as a conformer
authored in the substrate lane, not as an app-side type.

---

## 5. Passive ingestion (miners)

Native miners file facts from on-device sources into the estate's fact lane,
idempotently (`MinerEngine`). Two ship: **Calendar** and **Birthday** (Contacts).

- **Disabled by default.** Constructing a miner performs no reads.
- **Attended consent.** Only an explicit Set Up / Mine Now obtains permission;
  the first system consent prompt can only follow a user enable. Unattended
  ticks (macOS hourly, iOS opportunistic `BGTaskScheduler`) use existing grants
  only and never prompt.
- **User-configurable cadence** per source; **Mine Now** ignores cadence.
- `DailyIngestIntent` exposes one unattended tick as a Shortcuts automation
  (same consent posture — never prompts).

Cadence on iOS is an honest *request* to the system, not a promise of exact
execution. Local mining without sync is labeled local-only.

---

## 6. Portable LAN MCP server (A2)

The app can serve its own estate to MCP clients on the local network — e.g. a
desktop client connecting to the estate hosted on the phone. Decision record:
`DECISION_MOOTX01_APP_PORTABLE_LAN_SERVER_2026-07-11`.

- **Transport.** `MootLANServer` runs an `NWListener`, parses HTTP, and bridges
  authorized JSON-RPC to the same in-process dispatcher (`ARIA_MCPDispatcher`).
  It advertises `_mootx01._tcp` (Bonjour); `LANDaemonBrowser` discovers peers.
- **Credentialed by owner presence.** A bearer token lives behind a
  `.userPresence` Keychain item — starting the server or revealing the token
  triggers the device unlock system (Face ID / Touch ID / passcode). The token
  authenticates *the owner enabling serving*; it is not a shared password.
- **Read-only, public-only.** Remote callers are restricted to a read-only tool
  allowlist (no writes, no heavy verbs) and their recall is forced to
  `filter:exportable`, so only public memory ever leaves the device.
- **On power.** By default the server serves only while charging/full; an
  ambiguous power state fails closed. On iOS it lives only while the app is
  active — "on power" narrows *when* it serves, not *how long*.

The wire types and dispatcher are reused from the engine (`LoopbackHTTP`,
`AriaMCP`); only the LAN bind, Bonjour, power gate, and owner credential are
app-specific. A2 stays a **seam** because the standalone daemon does not yet
advertise itself (an engine-lane mirrored mission); the app-hosted path above
is live.

The parity-bound `AriaMCP.HTTPServer` is loopback-only and unauthenticated in
CE by design; this app's authenticated LAN server is a personal, single-owner
extension of that transport, distinct from the enterprise OAuth work deferred
to EE.

---

## 7. Multi-device sync (CloudKit)

Sync is **ConvergenceKit**'s `CloudKitSyncEngine` — operational, row-level,
HLC-conflict-resolved replication through the user's **private** CloudKit
database. The app orchestrates; the engine reconciles. This stays above the
parity boundary (the engine merges; no CloudKit in parity-bound storage).
The user-facing toggle is disabled by default. The persisted opt-in is applied
at launch before the first sync beat.

- `MootEstateSyncManifest` declares which tables sync, verified against
  `LocusKitSchema`: **drawers** and **tunnels** (last-writer-wins by HLC),
  **kg_facts** and **diary** (append-only). Its `schemaVersion` tracks
  `LocusKitSchema.version` so the cross-device contract cannot silently drift.
- Derived/projection tables (node bundles, matrix snapshot, container
  fingerprints) are **not** synced — they rebuild locally.
- `MootSyncDriver` applies the user's persisted setting against the estate's
  live Storage and push/pulls on the app's ambient beats (launch, foreground,
  iOS background refresh, macOS hourly tick).
- `SensitivityFilteredStorage` is the only Storage handle passed into the
  engine. Normal and elevated rows may cross; restricted and secret rows are
  suppressed on outbound writes and rejected on inbound application.
- If a row rises above the ceiling, the wrapper retracts its previously
  synchronized representation instead of leaving stale lower-tier content in
  the transport.

**Inert until provisioned and enabled.** Without an available iCloud account
the driver logs, stays disabled, and retries — it never fabricates a sync. It
activates only when the user enables it and the iCloud container
`iCloud.com.codedaptive.mootx01` is provisioned.

---

## 8. Capture from anywhere (Share Sheet)

UI-less Share extensions (iOS + macOS) capture shared text and URLs. The
extension process never opens the estate: it spools the item into an
app-group inbox backed by QueueKit's durable maildir (atomic write, crash
recovery), and the **host app** drains the spool through `CaptureSink` on its
ambient beats. A capture that fails is retried on the next drain; an undecodable
item is retired, not lost.

The **recall widget** (WidgetKit, iOS + macOS) renders a derived projection the
app refreshes from a public-only recall — the widget process reads the
app-group snapshot, never the estate.

---

## 8.1 On-demand federation

On-demand federation is separate from A3's generic outbound MCP client. It
uses ConvergenceKit's federation transport and the app's explicit session UI.
The F1 development surface includes:

- Bonjour discovery on `_mootx01-fed._tcp`, with visibility Off by default.
  Discovery publishes a short identity fingerprint, display name, protocol
  version, and relay port. It publishes no estate content.
- QR pairing with a signed proposal/acceptance exchange and a
  short-authentication-string confirmation on both devices.
- A hardware-gated UWB proximity enhancement on supported iPhones. QR remains
  the portable ceremony.
- One time-boxed federation session. The available F1 posture is Balanced;
  later postures remain visibly locked.
- A sensitivity ceiling that keeps restricted and secret content off the
  session transport.
- Explicit End Session behavior that closes the channel before expiring the
  peer grant and keys.

The UI never treats discovery as trust. A peer must complete the pairing
ceremony before a session can start. Generic `MootEstateClient.fetch` remains
guarded on this branch; its local fold-in path is not the federation transport.

---

## 9. Security & privacy posture

- **At rest:** the estate is SQLCipher whole-file encrypted (engine-side); on
  macOS the app-group container adds SIP defense.
- **Serve-out gate:** only public/exportable memory leaves the device, on every
  outbound surface (Spotlight, LAN server, callback recall, FM tools honor the
  sensitivity ceiling).
- **Untrusted data:** content recalled into a language model is bounded as data,
  with sentinel defanging against prompt-injection break-out.
- **Owner presence:** serving the estate on the LAN requires the device unlock
  system.
- **Federation default:** peer visibility is off by default, pairing requires
  transcript confirmation, and session end expires the peer's access.
- **Privacy manifest:** declares the required-reason APIs the app uses
  (FileTimestamp, DiskSpace, UserDefaults); no developer data collection, no
  tracking. Calendar and Contacts reads are on-device and disclosed.
- **Export compliance:** only exempt encryption (SQLCipher, CryptoKit, OS TLS);
  declared `ITSAppUsesNonExemptEncryption: false`.

---

## 10. Platforms & distribution

- **iOS / iPadOS:** embedded host; App Store path. Deployment floor iOS 27.
- **macOS:** embedded host + optional managed daemon; App Sandbox is off (it
  spawns the daemon), so it distributes via Developer ID + notarization rather
  than the Mac App Store. Floor macOS 27.
- Provisioning (App IDs, app group, iCloud container, keychain group, signing)
  is documented in `docs/status/APPLE_PROVISIONING_RUNBOOK.md`. TestFlight is
  gated on iOS 27 reaching GA (beta-SDK builds are rejected at upload).

---

## 11. What is live vs. pending

- **Live:** embedded host; the six verb intents and heavy verbs (exercised via
  AppIntentsTesting); typed recall; batch curation; miners (ship disabled);
  Foundation Models tools + evals; the portable LAN server logic; the Share
  spool and widget projection; the opt-in sync wiring; the F1 federation
  discovery, pairing, and Balanced-session lifecycle.
- **Pending registration (needs the Xcode app bundle built/installed):** system
  activation of Siri phrases, Spotlight, Shortcuts, and the URL scheme (A4–A6).
- **Inert (needs an external prerequisite):** the CloudKit transport after
  user opt-in (available iCloud account and provisioned container); code
  signing for device/TestFlight; the standalone-daemon Bonjour leg (A2,
  engine-lane).
- **Guarded:** arbitrary remote MCP fetch through `MootEstateClient`. The
  method throws and returns no fabricated remote data.

---

## 12. Development changelog

### v0.3 — 2026-08-04

- A5 callback-URL surface narrowed to read-only (MXE-UT, Codex finding
  `fd15875dc75c8191a86cfb6225371359`): the verb allowlist admits `recall`
  only; capture and reanchor are rejected alongside the destructive verbs.
  Mutations require the consented App Intents path. URL-path logging no
  longer emits inbound URLs or routing reasons at public privacy.

### v0.2 — 2026-07-23

- Documented the user-facing CloudKit toggle, its default-off posture, the
  sensitivity-filtered Storage boundary, and tier-rise retraction.
- Added the F1 on-demand federation surface: default-off discovery, QR/SAS and
  UWB-assisted pairing, Balanced sessions, and deterministic teardown.
- Distinguished ConvergenceKit federation from the still-guarded generic A3
  MCP client.
- Aligned the live/pending/inert summary with the current development source.
