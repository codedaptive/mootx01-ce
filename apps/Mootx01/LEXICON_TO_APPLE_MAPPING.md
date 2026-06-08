# ARIA Lexicon → Apple Surfaces — Mapping

**Status:** built with the GatewaySpike (2026-06-07), grounded against the substrate
codebase. The lexicon side is fixed (AriaLexiconLib: one noun, nine verbs, four adjectives,
invariants I-7/I-8); the Apple side is pre-staged as compiling shells in
`Sources/MootGateway/`. When Apple's WWDC drop (Mon 2026-06-08) changes a surface, the delta
lands in one of three mirrored places — this table, the matching shell file, and
`Sources/MootGateway/LexiconMap.swift` — and §5 below says exactly which.

This document is the prose mirror of `LexiconMap.swift`; that file is the executable source of
truth. If they drift, the code wins and this doc is wrong.

---

## 0. Grounded facts (what the prototype proved)

- ARIA is reached **in-process** (A1): `GeniusLocusKit` opened directly, driven through the
  ARIA_MCP dispatcher with **no transport** (`MootBridge`). Every adapter talks to the substrate
  the way a remote MCP client will — just without a wire.
- The tool surface is the **44 `moot_*` 5-tier interface** (decision MCP-INT-01), *not* the
  `drawer_recall`/`capture_drawer` lexicon-projected names. Internally `moot_file_memory →
  kit.capture`, `moot_memory_search → kit.recall`, etc.
- **ARIA is always the server** (ARIA_MCP_SPEC §5). The consume-other-estate leg (A3) is a
  *separate client component* (`MootEstateClient`), never ARIA_MCP acting as a client.
- The native adapters (App Intents/Shortcuts/callback-URL/Share-Sheet) **did not exist**; they
  are net-new and need an Xcode app bundle to be *system-registered*. The shells here compile and
  run in-process today; registration is the post-WWDC graduation step.

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

**Edge — results are text, not nouns.** `moot_file_memory`/`moot_memory_search` return MCP **text
content blocks**, not structured drawers. `RecallDrawerIntent` therefore returns text today; a
typed `[DrawerEntity]` result needs a structured recall-by-id/list tool. `DrawerEntityQuery` is a
shell returning `[]` until that exists — the slot is wired, the structured source isn't.

---

## 3. Adjective mapping (invariant I-8)

| Adjective | Values | Apple role |
|---|---|---|
| `state` | active · pending · contested · superseded · decayed · withdrawn · expired · rejected · accepted · tombstoned | Recall context; not a capture parameter. |
| `trust` | verbatim · observed · imported · proposed · derived · canonical | Set by capture channel; read-only on the entity. |
| `sensitivity` | normal · elevated · restricted · secret | **Capture parameter** (`SensitivityAppEnum`) + recall ceiling. Raw values match the tool's `decodeSensitivity` exactly — straight through, no mapping. |
| `exportability` | private · public | **Serve-out gate (§6.2):** recall `filter:exportable` exposes only public rows. |

**Edge — export policy is half-wired.** The bitmap has `exportability` (private=0/public=32) and
recall exposes `filter:exportable`, **but** `CaptureFrame` has no exportability slot and
`MutationKind` has no set-public case. So nothing can be marked public through the tool surface:
an exportable recall returns empty (pinned by `AdapterShellTests.exportPolicyEdgeHolds`). The
serve-out gate exists on the read side with **no write side to feed it**. To finish A4a as a real
public-sharing surface, the substrate needs a caller path to set exportability — a substrate
mission, not a gateway one.

---

## 4. Adapter inventory (A1–A6) and where each lives

| Code | Adapter | State | File |
|---|---|---|---|
| A1 | Embedded (in-process) | **live** | `MootBridge.swift` |
| A2 | ARIA_MCP server on device | **seam** | `Transport/GatewayTransport.swift` (`HTTPTransportSeam`) → loopback-HTTP transport (planned) |
| A3 | Consume other estates (client) | **shell** | `MCPClient/MootEstateClient.swift` |
| A4 | App Intents | **shell** | `AppIntents/*.swift` |
| A5 | Callback URL | **shell** | `CallbackURL/MootURLRouter.swift` |
| A6 | Shortcuts library | **shell** | `AppIntents/MootShortcuts.swift` |

A2's real transport (loopback HTTP + SSE, Bonjour, Local-Network permission; auth = loopback-owner
for CE, OAuth/scoped-tokens EE-only) is the loopback-HTTP transport workstream's build per ARIA_MCP_SPEC §5
— not duplicated here. The seam names the hand-off and throws rather than no-op'ing.

---

## 5. WWDC reaction deltas (the small-finish map)

Keynote Mon 2026-06-08. For each branch, the *exact* file(s) the delta lands in. This is what
turns "Apple dropped a change" into "complete the slot."

| If Apple announces… | Land the delta in… | Size |
|---|---|---|
| **Apple Intelligence dials out as an MCP client** | `Transport/GatewayTransport.swift` — point `HTTPTransportSeam` at Apple's transport/auth; the resident daemon supplies the listener. No verb/tool change. | Small |
| **App Intents exported outward as MCP** | Nothing new to author — the A4 shells *are* the on-ramp; register them in an Xcode bundle (`AppIntentsPackage`). | Medium (bundle) |
| **FM v2 / on-device "Core AI" tool-calling** | New `FMToolAdapter` beside `AppIntents/` exposing `recall`/`capture` as a model `Tool`; reuse `MootBridge`. | Small |
| **App Intents 2.0 (richer entities / streaming)** | `AppIntents/DrawerEntity.swift` — adopt the new entity/result types; wire the typed `[DrawerEntity]` result that the text-result edge blocks today. | Enhance |
| **A memory/knowledge assistant schema** | `AppIntents/CaptureDrawerIntent.swift` + `RecallDrawerIntent.swift` — conform to the schema for the deep treatment; update §1 candidacy. | Opportunistic |
| **Personal Context APIs open** | New scope doc + an `A3` reader in `MCPClient/` consuming Personal Context; fold in via `capture`/`learn`. | Investigate |

Each row touches one shell file plus, where relevant, this table and `LexiconMap.swift`. The
verb set never changes — the lexicon is fixed; only its Apple projection moves.

---

## 6. Out of scope (made visible, not filled)

`NSExtension` Share-Sheet target + the Xcode app bundle (App Intents system-registration); the
real HTTP/Streamable-HTTP transport (loopback-HTTP transport, planned); iCloud sync; graduating
`MootGateway` into `ARIA_MacOS`/`ARIA_iOS`. This work's job is to make these gaps concrete and
slotted, not to close them.
