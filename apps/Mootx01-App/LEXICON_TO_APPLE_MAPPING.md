# ARIA Lexicon → Apple Surfaces — Mapping

**Status:** built with the GatewaySpike (2026-06-07), grounded against the substrate
codebase. The lexicon side is fixed (AriaLexiconLib: one noun, nine verbs, four adjectives,
invariants I-7/I-8). The Apple adapter implementations live in two places: substrate-facing
seam code in `Sources/MootGateway/` (MootBridge, GatewayTransport, MootEstateClient,
AdapterStatus, LexiconMap) and the Apple-framework-dependent intents in
`packages/apple/MootIntentKit/Sources/MootIntentKit/` (verb intents, MootURLRouter,
MootShortcutsProvider). WWDC landed 2026-06-08; §5 tracks what changed. When a surface
changes, the delta lands in one of three mirrored places — this table, the matching adapter
file, and `Sources/MootGateway/LexiconMap.swift` — and §5 below says exactly which.

This document is the prose mirror of `LexiconMap.swift`; that file is the executable source of
truth. If they drift, the code wins and this doc is wrong.

---

## 0. Grounded facts (what the prototype proved)

- ARIA is reached **in-process** (A1): `GeniusLocusKit` opened directly, driven through the
  ARIA_MCP dispatcher with **no transport** (`MootBridge`). Every adapter talks to the substrate
  the way a remote MCP client will — just without a wire.
- The tool surface is the **53 `moot_*` interface** (decision MCP-INT-01), *not* the
  `drawer_recall`/`capture_drawer` lexicon-projected names. The 53 tools span five tiers
  (Tier 1–5: 19 core tools) plus Federation (1), Recipe (7), Lens (21), and Vault (5).
  Internally `moot_file_memory → kit.capture`, `moot_memory_search → kit.recall`, etc.
  Source of truth: `packages/kits/AriaMcpKit/Sources/AriaMCP/ToolProjection.swift` (Tiers 1–5 + Federation)
  plus `LensTools.swift`, `RecipeTools.swift`, `VaultTools.swift`; Rust mirror in
  `packages/kits/AriaMcpKit/rust/src/tool_list.rs` (header comment confirms 53).
- **ARIA is always the server** (ARIA_MCP_SPEC §5). The consume-other-estate leg (A3) is a
  *separate client component* (`MootEstateClient`), never ARIA_MCP acting as a client.
- The native adapters (App Intents/Shortcuts/callback-URL) are **implemented and tested** in
  `packages/apple/MootIntentKit/`. They are not yet *system-registered* — that requires an Xcode
  app bundle (`AppIntentsPackage` declaration + `CFBundleURLTypes` in Info.plist). The
  Share-Sheet `NSExtension` target is not yet built (see §6). System registration is the
  remaining graduation step; capability is not the gap.

---

## 1. Master verb table

Noun is always **Drawer**. Flow: who may invoke (caller-driven / Brain-emitted / grounding).

| Verb | Flow | Dir | `moot_*` tool | App Intent shell | Apple reach | x-callback | Caller? |
|---|---|---|---|---|---|---|---|
| **capture** | caller | WRITE | `moot_file_memory` | `CaptureDrawerIntent` | Share Sheet · Shortcuts · Siri · Action Button | `…/capture?content=&location=&sensitivity=` | ✅ |
| **recall** | caller | READ | `moot_memory_search` | `RecallDrawerIntent` | Siri · Spotlight · Shortcuts · Action Button | `…/recall?query=&filter=` | ✅ |
| **reanchor** | caller | STRUCT | `moot_move_memory` | `ReanchorDrawerIntent` | Shortcuts | `…/reanchor?id=&destination=` | ✅ |
| **mutate** | caller | WRITE | `moot_update_memory` | `MutateDrawerIntent` | Shortcuts | `…/mutate?id=&mutation=` | ✅ |
| **withdraw** | caller | WRITE | `moot_withdraw_memory` | `WithdrawDrawerIntent` | Shortcuts | `…/withdraw?id=` | ✅ |
| **expunge** | caller | WRITE | `moot_erase_memory` | `ExpungeDrawerIntent` | Shortcuts (guarded) | `…/expunge?id=&reason=&confirmed=` | ✅ |
| **propose** | **Brain** | — | — | — (elicitation, later) | — | — | ❌ |
| **associate** | **Brain** | — | — | — | — | — | ❌ |
| **learn** | grounding | WRITE | — | — (fed by A3) | — | — | ❌ |

**Submit-in (A4b)** = `capture`. It is a caller-driven *core* verb — no dreaming/propose gate —
so it works the moment a bundle registers it. **Serve-out (A4a/A5)** = `recall`, filtered by the
export policy (§3). The two Brain-emitted verbs are not tools and not Apple-invokable; their
natural Apple home is **App Intents elicitation** (confirm a proposal), a post-WWDC mapping.

### Assistant-schema candidacy

No Apple **assistant schema** has a "memory"/"knowledge" domain today, so every ARIA op is a
**custom** App Intent. If WWDC introduces a memory/notes/knowledge schema, `recall` (a retrieval
intent) and `capture` (a create intent) are the first candidates to conform — see §5.

---

## 2. Noun mapping — Drawer → `DrawerEntity`

`Drawer` (LocusKit) → `DrawerEntity` (`AppEntity`), so Siri/Spotlight/Shortcuts can carry a
memory between steps and index it.

| Drawer field | DrawerEntity | Notes |
|---|---|---|
| `id` | `id` (`AppEntity.ID`) | Stable across recall / Spotlight / chaining — the contract that lets a Shortcut recall then act. |
| `content` | `content` (`@Property`) + `DisplayRepresentation.title` | Verbatim; immutable at the core. |
| `room` | `room` (`@Property`) + subtitle | Structural coordinate; recall can group by it. |
| `adjectiveBitmap` → state/trust/sensitivity/exportability | read-only context | Set by capture; surfaced, not user-edited on the entity. |

**DrawerEntity recall is now wired via gateway-layer text parse.** `moot_memory_search`
response lines carry the format `<uuid>  [<room>]  <content preview>`.
`MootToolCalling.parseDrawerLines` (in MootIntentKit) extracts typed `DrawerEntity` values from
those lines at the gateway layer — no new ARIA tool needed.

- `DrawerEntityQuery.entities(for:)` resolves by running a recall with the UUID as the query
  and exact-id filtering; best-effort but no fabrication.
- `DrawerEntityQuery.suggestedEntities()` returns the 20 most-recent drawers.
- `RecallDrawerIntent` returns a typed `[DrawerEntity]` value plus the full response text as
  dialog — Shortcuts chains the entities into a next step; Siri reads the dialog. One
  `moot_memory_search` call feeds both (composition: `RecallDrawerIntent.entities(from:)`).

Content in `DrawerEntity` is a 120-char preview from the search response; full-body content is
not returned in the search path.

---

## 3. Adjective mapping (invariant I-8)

| Adjective | Values | Apple role |
|---|---|---|
| `state` | active · pending · contested · superseded · decayed · withdrawn · expired · rejected · accepted · tombstoned | Recall context; not a capture parameter. |
| `trust` | verbatim · observed · imported · proposed · derived · canonical | Set by capture channel; read-only on the entity. |
| `sensitivity` | normal · elevated · restricted · secret | **Capture parameter** (`SensitivityAppEnum`) + recall ceiling. Raw values match the tool's `decodeSensitivity` exactly — straight through, no mapping. |
| `exportability` | private · public | **Serve-out gate (§6.2):** recall `filter:exportable` exposes only public rows. |

**Edge — export policy write side is now live.** The bitmap has `exportability` (private=0/public=32)
and both the write path and read path are wired:

- **At capture:** `moot_file_memory` accepts an optional `exportability` argument (`"private"` |
  `"public"`). Default is private. Drawers born public are immediately returned by
  `filter:exportable` recall. Wired in `ToolDispatch.decodeExportability` and applied to the
  `CaptureFrame` before the write.
- **Post-capture promotion:** `moot_update_memory` accepts `mutation=correctExportability(public)`
  or `mutation=correctExportability(private)`. Decoded by `ToolDispatch.decodeMutationKind` as
  `MutationKind.correctExportability(.public_)` / `.correctExportability(.private_)`.

**All three write surfaces are now live:**

- **CaptureView:** exposes a private / public Picker that passes `exportability` to
  `moot_file_memory` at capture time. The status in `AdapterStatus.findings` reflects this.
- **Tool path:** `moot_file_memory` with `exportability:"public"` (unchanged).
- **Post-capture promotion:** `moot_update_memory correctExportability(public)` (unchanged).

A4a serve-out via `filter:exportable` returns correctly populated results from all three
write paths.

---

## 4. Adapter inventory (A1–A6) and where each lives

| Code | Adapter | State | File |
|---|---|---|---|
| A1 | Embedded (in-process) | **live** | `Sources/MootGateway/MootBridge.swift` |
| A2 | ARIA_MCP server on device | **seam** | `Sources/MootGateway/Transport/GatewayTransport.swift` — `HTTPTransport` (URLSession POST to loopback daemon) is implemented; `InProcessTransport` is live. Seam because LAN/Bonjour discovery and Local Network entitlement are not yet built; loopback CE is the working path. |
| A3 | Consume other estates (client) | **v1.1** | `Sources/MootGateway/MCPClient/MootEstateClient.swift` — fold-in via capture is real (`foldIn`); outbound federation deferred to v1.1 by Bob's ruling; `fetch` throws `outboundFederationNotInThisVersion` as an explicit guard. |
| A4 | App Intents | **pending registration** | `packages/apple/MootIntentKit/Sources/MootIntentKit/CaptureDrawerIntent.swift` + `RecallDrawerIntent.swift` + other verb intents — implementation is live and tested; `Mootx01Shortcuts.updateAppShortcutParameters()` called at every app launch (App/Mootx01App.swift). System Siri/Spotlight activation requires the Xcode app bundle build (xcodegen → xcodebuild). |
| A5 | Callback URL | **pending registration** | `packages/apple/MootIntentKit/Sources/MootIntentKit/MootURLRouter.swift` — routing logic and security hardening are complete and tested; `CFBundleURLTypes` for `mootx01://` is declared in `project.yml` (the xcodegen spec). URL-scheme registration activates when xcodegen regenerates the project and the app bundle is built. |
| A6 | Shortcuts library | **pending registration** | `packages/apple/MootIntentKit/Sources/MootIntentKit/MootShortcutsProvider.swift` (all six intents) + `App/Mootx01Shortcuts.swift` (the app-target `AppShortcutsProvider`, capture + recall). Both donate via `updateAppShortcutParameters()` at launch. Phrases appear in the Shortcuts app once the xcodegen-derived app bundle is built and installed. |

The authoritative adapter state is `Sources/MootGateway/AdapterStatus.swift` (`GatewayEdges.adapters`),
which the Edges tab reads at runtime. If this table and AdapterStatus.swift ever diverge, AdapterStatus wins.

A2's loopback-HTTP transport (`HTTPTransport`) is implemented (URLSession POST, full error taxonomy,
JSON-RPC 2.0 decode). The capability gap is LAN/Bonjour discovery and `NSLocalNetworkUsageDescription`
— not the HTTP wire itself. Seam status reflects that `HTTPTransport` is not yet wired as the default
path. Enterprise OAuth (EE) composes above this transport in v2.

---

## 5. WWDC reaction deltas (the small-finish map)

Keynote Mon 2026-06-08. For each branch, the *exact* file(s) the delta lands in. This is what
turns "Apple dropped a change" into "complete the slot."

| If Apple announces… | Land the delta in… | Size |
|---|---|---|
| **Apple Intelligence dials out as an MCP client** | `Sources/MootGateway/Transport/GatewayTransport.swift` — adapt `HTTPTransport` to Apple's transport/auth; the resident daemon supplies the listener. No verb/tool change. | Small |
| **App Intents exported outward as MCP** | Nothing new to author — the A4 intents in `packages/apple/MootIntentKit/` are the on-ramp; register them in an Xcode bundle (`AppIntentsPackage`). | Medium (bundle) |
| **FM v2 / on-device "Core AI" tool-calling** | New `FMToolAdapter` beside MootIntentKit exposing `recall`/`capture` as a model `Tool`; reuse `MootBridge`. | Small |
| **App Intents 2.0 (richer entities / streaming)** | `packages/apple/MootIntentKit/Sources/MootIntentKit/DrawerEntity.swift` — adopt the new entity/result types. The typed `[DrawerEntity]` recall result is wired (RecallDrawerIntent returns entities + dialog); remaining upgrades are streaming results and richer entity properties. | Enhance |
| **A memory/knowledge assistant schema** | `packages/apple/MootIntentKit/Sources/MootIntentKit/CaptureDrawerIntent.swift` + `RecallDrawerIntent.swift` — conform to the schema for the deep treatment; update §1 candidacy. | Opportunistic |
| **Personal Context APIs open** | New scope doc + an `A3` reader in `MCPClient/` consuming Personal Context; fold in via `capture`/`learn`. | Investigate |

Each row touches one shell file plus, where relevant, this table and `LexiconMap.swift`. The
verb set never changes — the lexicon is fixed; only its Apple projection moves.

---

## 6. Out of scope (made visible, not filled)

**Closed since last audit (2026-06-13):** CaptureView exportability Picker (A), DrawerEntity
structured recall via gateway-layer text parse (B), `updateAppShortcutParameters()` at launch
and `CFBundleURLTypes` declared in `project.yml` (C), typed `[DrawerEntity]` recall results (D),
and the `NSExtension` Share-Sheet capture targets (E — `Mootx01-Share-iOS`/`-macOS`, UI-less:
the extension spools to the app-group `ShareInbox`, the host app drains via `ShareInboxDrain`
at launch/foreground/tick; the extension process never opens the estate).

**Remaining:** Bonjour/LAN discovery and Local Network
entitlement (the remaining A2 gap; loopback `HTTPTransport` is implemented); iCloud sync;
graduating `MootGateway` into `ARIA_MacOS`/`ARIA_iOS`. System activation of A4/A5/A6 requires
running `xcodegen generate` then building the Xcode project — that Xcode build step is outside
SPM and is the final activation gate.
