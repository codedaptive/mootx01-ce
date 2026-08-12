---
status: decided
question: "Should the proxy bridge add a per-frame timeout or a concurrency cap?"
authors: MOOTx01 maintainers
date: 2026-08-11
relates_to:
  - docs/reference/ARIA_MCP_SPEC.md (§5 transport and bridge failure policy)
  - apps/mootx01/Sources/mootx01/Commands/ProxyCommand.swift
  - apps/mootx01/rust/src/commands/proxy.rs
supersedes: none
context:
  - Long tool calls (lens/synthesis on large estates) legitimately run for minutes
  - The proxy bridge already uses a 3600s URLSession timeout to avoid killing in-flight calls
  - Multiple frames can be in flight simultaneously (task-per-frame concurrency)
  - The px stream fixed the dropped-response bug but did not add per-frame timeouts or concurrency caps
---

# Decision: Proxy Timeout vs Concurrency Cap Interaction

## Context

The `mootx01 proxy` command bridges Claude Desktop (stdio) to the resident daemon (HTTP). After the px stream:

- Every failed request produces a synthesized -32603 error instead of being silently dropped
- Frames are forwarded concurrently (one Task/thread per frame)
- URLSession timeout is 3600s — chosen because long lens/synthesis calls legitimately run for minutes and the client (Claude Desktop) owns the timeout policy via `notifications/cancelled`

Two open design questions surfaced during the px stream:

1. **Should the bridge impose a per-frame timeout shorter than 3600s?**
2. **Should the bridge cap the number of concurrent in-flight frames?**

## Axis 1 — Per-frame timeout

**Case for a timeout:** A stuck daemon (not crashed, but blocking) would tie up a URLSession task indefinitely. Without a timeout, Claude Desktop must cancel the call and the bridge would only clean up when the cancel notification arrives (or never, if the client disconnects without sending one).

**Case against:** The timeout window must accommodate the longest legitimate call. Lens/synthesis calls on large estates regularly exceed 5 minutes. Any timeout shorter than ~600s risks killing legitimate in-flight calls. A 600s timeout is effectively no timeout for interactive use — the user or Claude Desktop will have long since moved on.

**The correct owner of timeout policy is the client.** Claude Desktop sends `notifications/cancelled` when it gives up on a call. The proxy receives this notification, forwards it to the daemon, and the daemon cancels the in-flight tool invocation. This is the correct cancellation path — it is already wired.

## Axis 2 — Concurrency cap

**Case for a cap:** Unbounded concurrency could exhaust URLSession resources or daemon connection capacity under pathological client behavior. A `withTaskGroup` or semaphore-based cap would bound the number of simultaneous in-flight HTTP requests.

**Case against:** The practical concurrency from Claude Desktop is low (typically 1–3 concurrent tool calls at any time). The existing `withDiscardingTaskGroup` is already a natural bound (tasks are created at the frame-read rate, which is bounded by the client). Adding a cap introduces head-of-line blocking: a slow call holds the semaphore, blocking fast calls (like pings and cancellation notifications) that must get through. For the cancellation path to work, `notifications/cancelled` must reach the daemon promptly — a concurrency cap can delay it.

## Disposition

**No per-frame timeout, no concurrency cap at this time.**

Rationale:
- The client owns the timeout policy via `notifications/cancelled`; the proxy must not impose a shorter timeout
- The concurrency from Claude Desktop is low enough that unbounded `withDiscardingTaskGroup` is safe
- A concurrency cap introduces head-of-line blocking that would break the cancellation path
- Both points are candidates for re-evaluation if observability data (§17) reveals resource pressure in production

**If a session-ID header is ever added** to the bridge, session recovery (clear + re-initialize + one-shot retry on connection failure) must be added at the same time. A restart without recovery becomes a permanent outage for the session — this is already noted as a guard comment in both `ProxyCommand.swift` and `proxy.rs`.

## Open questions

- **Observability hook:** The bridge currently logs failures to stderr but has no telemetry counter. If the daemon is frequently restarting under load, the synthesized errors are invisible to monitoring. A future observability mission should wire a counter through the daemon's self-report endpoint (§17 side-channel GET).
- **Session-ID path:** The MCP spec allows an optional session ID for stateful sessions. If this bridge ever adopts that header, the recovery logic outlined above becomes mandatory scope for that mission.

## Status

Decided 2026-08-11. No timeout, no cap. Revisit when observability data is available.
