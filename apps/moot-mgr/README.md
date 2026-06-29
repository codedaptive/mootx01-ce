# moot-mgr

The standalone **observer / manager** process for MOOTx01 — the management and
admin control surface for a running resident daemon.

It provides two planes:
- **Read plane** — a read-only loopback **HTTP API** and dashboard (health,
  per-estate state, the write pipeline, an activity log, and a live node-link
  topology view).
- **Admin plane** — a gated **control channel** over a Unix domain socket for
  estate provisioning and lifecycle operations.

The dashboard's static assets are generated from `DashboardAssets/` into
`Sources/MootManager/StaticAssets.swift` (kept in sync by a `make test` gate).

- Swift: `Sources/MootManager` → the `moot-mgr` binary; `Plugins/` for asset gen.
- Rust: `rust/` → the Rust vertical.

Installed alongside the CLI by default (`mootx01 install`); opt out with
`mootx01 install --no-manager`. Reach it at `moot-mgr serve` /
`http://127.0.0.1:4200`.

## Security hardening

### Bounded loopback connection cap (CAND-011)

The loopback HTTP server enforces a maximum of **16 simultaneous connections**
(configurable via `MOOT_MGR_HTTP_MAX_CONNECTIONS`). Connections beyond the cap
are shed immediately with HTTP 503 + `Retry-After: 1` before any request
parsing runs. This bounds the availability impact of a caller that opens many
blocking connections before authentication/control checks complete.

The cap is enforced at the accept loop (non-blocking depth check) so the
accept thread itself never stalls. Each accepted connection releases its slot
on all exit paths — normal completion, read timeout, or connection drop — via
RAII (Rust `OnDrop` guard / Swift `defer`).

Both the Swift and Rust ports enforce the same cap (parity).

### Slot-leak-on-spawn-failure fix (secfix/c-mootmgr-slotleak)

A regression from the connection-cap commit (5670f17) was found and fixed:
in the Rust port, the slot-release RAII guard was created inside the worker
closure passed to `std::thread::Builder::spawn`. If `spawn` failed (OS thread
or resource limit), the closure — and its guard — was discarded with the `Err`
return, so the gate slot reserved by `try_enqueue` was never released.
Repeating up to `max_concurrent` times would permanently exhaust the gate,
causing HTTP 503 for all new connections until restart (a persistent DoS from
a transient OS failure).

Fixed by binding the release guard on the **accept thread** immediately after
`try_enqueue` succeeds, then moving it into the spawn closure. If spawn fails,
the `Err` destructor drops the closure and guard, calling `release()` atomically
— no manual cleanup, no leak. If spawn succeeds, the guard lives in the worker
and releases on all exit paths (normal, panic, read-timeout) as before.

The Swift port is unaffected: Swift `Task {}` dispatch never fails to enqueue
the work item, so the `defer { gate.release() }` inside the Task is guaranteed
to run.
