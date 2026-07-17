---
status: decided
question: May the Mootx01-App expose an owner-authenticated, off-loopback personal LAN MCP server in CE?
authors: MOOTx01 maintainers
date: 2026-07-11
relates_to:
  - docs/decisions/ADR-LOOPBACKHTTP-001.md
  - docs/decisions/ADR-005-mootx01-app-envelope-and-parity-boundary.md
supersedes: none
---

# DECISION — Mootx01-App portable LAN MCP server (CE)

## Context

`ADR-LOOPBACKHTTP-001` established `LoopbackHTTP` as the CE HTTP transport
for the resident daemons, and `AriaMCP.HTTPServer`'s security disposition
(`HTTPServer.swift:379`) pins that transport to **loopback only, no
authentication** in CE, deferring *off-localhost hosting* and an
*authentication scheme* to EE v1.1 — where the concern is **enterprise OAuth**
and **client-verifies-server identity** for non-local, multi-party hosting.

Bob's direction (2026-07-11): the Mootx01-App should also be a **portable LAN
MCP server** so a desktop MCP client can reach the estate hosted on the
owner's phone, gated by **on-phone owner authentication** (Face ID / Touch ID /
passcode) and served only while on power.

## Decision

The Mootx01-App MAY host an owner-authenticated, off-loopback personal LAN
MCP server in CE. This is **not** the EE concern ADR-LOOPBACKHTTP-001 defers:

- The EE deferral is **enterprise OAuth** and **server-identity verification**
  for multi-party off-localhost hosting. This feature is **single-owner,
  local-first** — the same trust model the CE transport already assumes,
  extended from loopback to the owner's own LAN.
- Authentication here is **server-side owner presence** (the human unlocks the
  credential on their own phone), not a client→server enterprise credential.
  The bearer token is bound to the device unlock system via a `.userPresence`
  Keychain item; it authenticates *the owner enabling serving*, not a tenant.

## Constraints (how it stays consistent)

1. **Apple layer only (ADR-005).** NWListener, Bonjour, Face ID, and battery
   state are Apple-only, so the server lives in the app / `MootGateway`, never
   in the parity-bound `AriaMcpKit` (the Rust leg cannot mirror it).
2. **Reuse the transport-neutral kit pieces.** It drives
   `ARIA_MCPDispatcher.handle` and uses `JSONRPCRequest`/`JSONRPCResponse`.
   It does **not** reuse `LoopbackHTTP.POSIXSocket`/`HTTPRequest.read`: those
   are loopback-pinned (`INADDR_LOOPBACK`, by security design) and fd-coupled,
   which cannot compose with an off-loopback NWListener/NWConnection server.
3. **Remote posture is read-only, public-only.** Remote callers are bearer-
   authed, restricted to a read-only tool allowlist, and see only exportable
   memory (`LANRequestGate`) — the §6.2 serve-out gate.
4. **On power, foreground-bounded.** Serves only while charging/full by
   default; on iOS only while the app is alive.

## Consequence

CE now includes a personal device-to-device LAN server as an Apple-layer
extension of the loopback transport. EE's OAuth / server-identity work
(ADR-LOOPBACKHTTP-001 → EE v1.1) composes above this and is unaffected.
