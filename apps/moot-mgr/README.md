# moot-mgr

`moot-mgr` is the local operator console for a resident MOOTx01 installation.
It reads the manager statistics store, serves the loopback dashboard and read
API, runs retention, and exposes a separately gated estate-control plane.

It does not serve MCP memory tools and it does not replace `mootx01 serve`.
The resident MOOTx01 daemon owns the memory estate; `moot-mgr` makes that
resident installation observable and operable.

## What it provides

| Surface | Purpose | Default |
|---|---|---|
| CLI | Status, monitoring switch, and retention | `moot-mgr <command>` |
| Dashboard | Estate state, write activity, topology, and manager health | `http://127.0.0.1:4200/` |
| Read API | Loopback, read-only operational metadata | `http://127.0.0.1:4200/api/*` |
| Control API | Token- and Origin-gated lifecycle operations | `POST /api/control/*` |
| Local control channel | Gated local IPC for administrative commands | Unix domain socket |

The read API reports operational metadata, counts, state, and topology. It
does not return memory bodies.

## Install and start

The normal product installer includes the manager:

```sh
mootx01 install
moot-mgr status
```

Open the dashboard at:

```text
http://127.0.0.1:4200/
```

To omit the manager:

```sh
mootx01 install --no-manager
```

For a source build or foreground diagnostic run:

```sh
cd apps/moot-mgr
swift run moot-mgr serve
```

The Rust twin is under `apps/moot-mgr/rust/`.

## CLI reference

| Command | Result |
|---|---|
| `moot-mgr status` | Print manager/store health, totals, estates, and recent activity |
| `moot-mgr monitoring on` | Enable monitoring for consumers of the shared manager store |
| `moot-mgr monitoring off` | Disable monitoring |
| `moot-mgr monitoring status` | Print `ON` or `OFF` |
| `moot-mgr retention run` | Run one retention pass immediately |
| `moot-mgr serve` | Start the dashboard, read API, control plane, and retention loop |
| `moot-mgr help` | Print the live command and environment reference |

## Read API

These endpoints are loopback-only and read-only:

| Endpoint | Contents |
|---|---|
| `GET /api/server` | Process and uptime information |
| `GET /api/estates` | Per-estate operational summaries |
| `GET /api/config` | Effective manager configuration |
| `GET /api/events` | Recent activity; supports the dashboard event stream |
| `GET /api/graph` | Node-link topology data |
| `GET /api/lexicon` | ARIA grammar and lattice metadata |
| `GET /api/lattice` | Lattice-address snapshot |
| `GET /api/review` | Recent estate activity summary (estate count, capture count, event feed) |
| `GET /api/packets` | Exportable work packets — list, metadata only |
| `GET /api/packets/:id` | Single exportable work packet detail |
| `GET /api/packets/:id/lineage` | Lineage links for an exportable work packet |

Work-packet endpoints surface only drawers marked `AdjectiveExportability.public_`
in the LocusKit adjective bitmap. Non-exportable drawers (the LocusKit default)
are silently excluded from all `/api/packets*` responses.

Unknown non-API `GET` paths are handled by the embedded dashboard assets.
The server validates loopback `Host` values to resist DNS rebinding.

## Administrative control

Administrative writes are not exposed through the unauthenticated read plane.
HTTP control requests require both an accepted Origin and the configured bearer
token. Supported operations include:

- monitoring on/off;
- retention-window updates;
- estate provision, quiesce, drain, and destroy.

Destructive estate operations carry their own confirmation requirements. Do
not publish the control token, control socket, or dashboard port outside the
local machine.

## Configuration

| Environment variable | Meaning | Default |
|---|---|---|
| `MOOT_MGR_STORE` | Manager statistics SQLite file | Platform app-data directory |
| `MOOT_MGR_RETENTION_SECONDS` | Retention window | `604800` (7 days) |
| `MOOT_MGR_RETENTION_CADENCE_SECONDS` | Resident retention cadence | `3600` (1 hour) |
| `MOOT_MGR_HTTP_PORT` | Dashboard/read API port | `4200` |
| `MOOT_MGR_HTTP_MAX_CONNECTIONS` | Concurrent loopback connection cap | `16` |
| `MOOT_MGR_CONTROL_TOKEN` | HTTP control bearer token | Installer-managed when installed |
| `MOOT_MGR_CONTROL_SOCKET` | Local control-channel path | Platform data directory |
| `MOOT_MGR_ESTATES_DIR` | Estate administration root | MOOTx01 data directory |

Invalid non-positive retention values fall back to the documented defaults.
Use `moot-mgr help` as the executable truth for the installed version.

## Resident daemon and direct stdio

`moot-mgr` is most useful with the shared resident daemon because all clients
then contribute to one continuously observable installation. A direct-stdio
client launches a private `mootx01 serve` subprocess; that process does not
automatically provide the same central telemetry or manager lifecycle.

If a direct-stdio process detects an existing resident daemon for the same
estate, MOOTx01 may forward to the resident over localhost. Stop the resident
service when genuinely socket-free operation is required.

## Troubleshooting

| Symptom | Check |
|---|---|
| Dashboard does not open | Run `moot-mgr status`; confirm port `4200` or `MOOT_MGR_HTTP_PORT` |
| No estates appear | Confirm `MOOT_MGR_STORE` and `MOOT_MGR_ESTATES_DIR` resolve to the same product data root |
| Monitoring is empty | Run `moot-mgr monitoring status`, then enable it if desired |
| Old samples remain | Run `moot-mgr retention run` and inspect the retention variables |
| Control request is rejected | Confirm loopback Origin and bearer token; do not weaken the read/control separation |
| Repeated HTTP 503 | Inspect connection pressure and `MOOT_MGR_HTTP_MAX_CONNECTIONS` |

## Implementation and contract

- Swift implementation: `Sources/MootManager`
- Swift executable: `Sources/moot-mgr`
- Rust twin: `rust/`
- Dashboard sources: `Sources/MootManager/DashboardAssets/`
- Generated assets: `Sources/MootManager/StaticAssets.swift`
- Detailed contract: [`../../docs/reference/MOOT_MGR_SPEC.md`](../../docs/reference/MOOT_MGR_SPEC.md)

The dashboard asset generator and Swift/Rust behavior are covered by the
package tests.

## Security notes

The loopback HTTP server caps simultaneous connections and sheds excess work
with HTTP 503 before request parsing. Accepted connections release their slot
on normal completion, timeout, disconnect, and worker-spawn failure. The
read/control separation, Host validation, Origin validation, bearer token, and
local IPC gate are independent controls; keep all of them intact.
