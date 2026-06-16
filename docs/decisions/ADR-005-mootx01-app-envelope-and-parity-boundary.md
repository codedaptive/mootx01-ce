---
status: decided
question: How does the Apple presentation layer (Mootx01 app) relate to the clean Rust-mirrored mootx01 server without breaking parity?
authors: MOOTx01 maintainers
date: 2026-06-07
relates_to:
  - docs/decisions/ADR-004-event-time-two-clock-ingest-primitive.md
supersedes: none
context:
  - Refines the architecture mandate (mootx01 = headless daemon; moot-mgr = its GUI)
  - The Swift↔Rust engine mirror must stay clean; Apple-only surfaces cannot live in it
---

# ADR-005 — The Mootx01 App as Envelope; the Engine/App Parity Boundary

| | |
|---|---|
| **Status** | Decided (2026-06-07) |
| **Deciders** | MOOTx01 maintainers |
| **Supersedes** | nothing; refines the architecture mandate (mootx01 = headless daemon, moot-mgr = GUI) |
| **Related** | ADR-004 (event-time), the Swift↔Rust engine mirror, the aria-mcp server (always the server) |

## Context

We are building an Apple-ecosystem presentation layer for MOOTx01 (App Intents,
Shortcuts, Siri, EventKit, SwiftUI) across macOS, iOS, and iPadOS, plus developer
example apps. The question is how that Apple layer relates to the **standalone
`mootx01` server**, which is a *clean, headless, platform-neutral binary that
mirrors a Rust implementation on Windows/Linux* — a mirror that must stay exact, so
the two ports never drift apart.

The naive move — fuse the GUI + Apple surfaces *into* the server for "one codebase"
— is wrong: SwiftUI / App Intents / EventKit cannot exist on Windows/Linux, so the
Swift server would stop being a clean mirror of the Rust server. Parity breaks.

## Decision

**The parity boundary is the architectural seam. The Apple app *envelopes* the
server; it never absorbs it.**

### Two layers, one sacred line between them

1. **Engine / clean server** — headless, platform-neutral, **Swift ↔ Rust mirrored**.
   Owns estate hosting, serving, and sourcing. **Zero Apple types.** Deployable
   independently. Unchanged by any of this work. (This is today's `mootx01` /
   `aria-mcp` server + the substrate kits.)
2. **Apple presentation layer** — `apps/Mootx01-App` (SwiftUI + App Intents + Shortcuts +
   EventKit). Swift-only, Apple-only, **explicitly not in the parity mirror** (it
   *can't* be — there is no Rust SwiftUI). A **superset and technology demonstration**:
   the envelope around the server *plus* the advanced Siri-facing work. Whatever of
   that is portable is pushed down to the iOS/iPadOS builds; the macOS-only frontier
   stays on the Mac.

The line between (1) and (2) is the parity boundary. We layer over it; we never
blend across it.

### One estate, one host (operating discipline — currently UNENFORCED)

An estate should have exactly **one** owning host process. Everyone else reaches it
through a transport — never by co-opening the database file. The owner — and only the
owner — runs the autonomic governor for its estates. (The SQLite-file-sharing used in early
demos violates this and is a demo trick, not a topology.)

**This is a discipline, not a mechanical invariant — there is no enforcement primitive
today.** Nothing prevents a second process from opening the same SQLite file; in fact
`MootBridge.databasePath` exists precisely so an operator *can* point an external
`aria-mcp` at the estate. Two writers with WAL + the autonomic governor on both is a real
hazard. Before any live handoff ships, the engine needs an **estate owner-lease /
lockfile** (or the handoff must be a strict close-then-spawn with positive
acknowledgment — described in the handoff section below). Until one of those lands, treat
"one host" as an operator responsibility, not a guarantee.

### Two kinds of host

- **Server-in-app (embedded, in-process)** — alive only while the app runs. This is
  the **cross-platform analog**: iOS, iPadOS, and the macOS app all do exactly this.
  The shared, portable core. The app links the *same clean Swift engine* the headless
  server links; embedding adds no Apple types *downward*, so parity stays intact.
- **Standalone daemon** — the headless Rust-mirrored binary, persistent, independently
  deployable (run it yourself, or…).

### The macOS-only extra: the handoff

The macOS app can **spawn a daemon and hand it a database to take over**: ownership
**transfers** app → daemon (the app releases its handle; the daemon opens the file and
runs headless from then on). The estate outlives the app and can serve other clients.
iOS/iPadOS cannot do this (no persistent subprocess), so it is the macOS superpower.
The handoff must be a *transfer, not a share* — and to be safe it must be a strict
**close-then-spawn with positive acknowledgment**: the app fully closes and checkpoints
the estate, confirms the close, *then* spawns the daemon on that file. A bare
release-and-launch leaves a WAL race (uncheckpointed frames + two openers). The return
trip (the app re-attaching to that now-standalone daemon as a *client*) lands when the
loopback-HTTP transport ships.

A clean in-app estate `close()` is **not** a missing
engine feature — the capability already exists at the kit layer (`EstateCoordinator.close`
→ `Estate.close` → `SQLiteStorage.close`/`sqlite3_close_v2`). The follow-up is **exposing**
it through `MootBridge` (and making `GeniusLocusKit.close` public, currently
package-internal) — wiring, not new substrate. The `DaemonController` panel today spawns a
daemon on its *own* separate estate (safe, unblocked); the live-estate handoff is gated on
the close-then-spawn sequence above.

### The transport seam — three modes, one API

| Mode | How the app reaches the engine | Status |
|---|---|---|
| **Embedded** | links the clean engine in-process | live (iOS path + a macOS option) |
| **Managed subprocess (stdio)** | app spawns the real server binary, speaks stdio JSON-RPC, supervises it | live now (the stdio server exists) — this is "app-managed daemon" |
| **Client → standalone (loopback HTTP)** | connect to an independently-running daemon | future (the loopback-HTTP transport, planned) — seamed, not built here |

The server binary is untouched in all three modes.

### Orthogonal axes (one engine, varied around it)

- **A — Presentation:** headless | GUI. *(The Apple-only, non-mirrored layer.)*
- **B — Estates hosted:** 1..N per process (already in `ToolDispatcher`'s registry).
- **C — Serving:** none | loopback | LAN.
- **D — Sourcing:** local-only | + remote client.

A is the Apple layer; B/C/D live in the mirrored engine. The **A | BCD** line is the
parity boundary.

## Consequences

- The clean server stays clean and Rust-mirrored. We do not touch it. No Apple-flavored
  daemon is forked.
- `apps/Mootx01-App` is Swift-only Apple presentation over the existing engine: embedded
  server-in-app (all platforms) + managed-subprocess + handoff (macOS only) + the App
  Intents / Shortcuts / Siri superset + an enumerate-what-we-publish surface.
- Examples demonstrate the SDK on the same seam (build-on-MOOT, sidecar-your-own-app,
  leverage-a-legacy-app-unchanged).
- `Mootx01` is positioned as the convergence point for the **Apple-native console**.
  *Plane distinction:* `moot-mgr` does **not** embed the MCP dispatcher —
  it is an observer/admin plane (ObserverSink + EstateAdmin) and cannot serve the live tool
  surface. So what converges into `Mootx01` is the *console* (the Apple-native control GUI),
  **not** moot-mgr's admin engine, which stays below the parity seam and is consumed, not
  absorbed. The **headless-daemon + web-console remains the cross-platform (PC/Linux) path** —
  this convergence does not deprecate moot-mgr.
- Multi-instance and multi-DB are *engine* features the app *exposes*, not features the
  app *implements*.

## Out of scope (here)

The loopback-HTTP transport (a separate transport workstream); a Rust GUI app (no Rust SwiftUI; and
no Rust server binary is present in this product to control); iCloud sync; device code-signing.

## Boundary discipline

Engine-shaped logic — estate-lifecycle policy, autonomic-governor decisions — must not
appear **above** the dispatcher seam in `apps/Mootx01-App`. The boundary is enforced by
convention. The `HTTPTransportSeam` must keep *throwing* until the transport is built, never
silently no-op; a no-op would let the seam compile while masking that the capability is not
yet present.
