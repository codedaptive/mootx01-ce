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
