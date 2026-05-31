# Blast Radius Report — VERB-CAP-01

**Stream:** cap · **Branch:** stream/cap-capture-tunnel
**Baseline:** 816dbe2 (merge: NOUN-ASC-01)
**Mission:** docs/missions/inflight/MISSION_VERB_CAP_01.md
**Date:** 2026-05-30

## Mission
Add a standalone `capture` path for the `tunnel` noun (drawer capture already
works), in both legs (Swift + Rust). The new path must produce a tunnel row
byte-identical to the one the drawer supersession cascade writes — same all-zero
bitmaps, same bare-insert persistence, same (absent) genesis-event treatment.
"One tunnel shape, two entry points."

## Baseline test counts (at 816dbe2, verified)
- Swift `swift test`: **441** passed, exit 0.
- Rust `cargo test --lib`: **390** passed, exit 0.

## Symbols introduced (all additive — no existing symbol changed)
- `TunnelCaptureFrame` (Swift `Frames.swift`, Rust `frames.rs`) — new value type.
- `Estate.capture(_:TunnelCaptureFrame) -> Tunnel` (Swift overload) /
  `Estate::capture_tunnel(TunnelCaptureFrame, i64) -> Result<Tunnel,…>` (Rust;
  no overloading in Rust, hence the distinct name).
- Internal Swift test peeks `_peekTunnel`, `_tunnelsFrom`, `_tunnelsTo`.

## Files — classification
| File | Class | Note |
|---|---|---|
| `Sources/LocusKit/Frames.swift` | MUST_UPDATE | add `TunnelCaptureFrame` (additive) |
| `Sources/LocusKit/EstateVerbs.swift` | MUST_UPDATE | add `capture` overload + test peeks (additive) |
| `rust/src/frames.rs` | MUST_UPDATE | add `TunnelCaptureFrame` + `TunnelKind` import |
| `rust/src/estate_verbs.rs` | MUST_UPDATE | add `capture_tunnel` + imports |
| `rust/src/lib.rs` | MUST_UPDATE | register `mod capture_tunnel_tests` |
| `Tests/LocusKitTests/CaptureTunnelTests.swift` | NEW | Swift conformance |
| `rust/src/capture_tunnel_tests.rs` | NEW | Rust conformance (mirror) |

## Reuse / grep results (no stale call sites)
- `capture(_:TunnelCaptureFrame)` is a NEW overload; `capture_tunnel` is a NEW
  method. No existing call sites become stale (grep: no callers pre-existed).
- The standalone path REUSES the existing tunnel writer `DrawerStore.addTunnel`
  / `InMemoryDrawerStore::add_tunnel` — the same bare-insert the cascade uses.
  It does NOT fork a second tunnel-creation path.

## INTENTIONALLY_LEFT (verified, with justification)
- `Tunnel.swift` / `tunnel.rs` / the `tunnels` table — NOT modified. capture
  writes rows; it does not change the type or schema. (Mission MUST-NOT-MODIFY.)
- The supersession cascade (`addDrawerWithCascade` / `add_drawer_with_cascade`)
  — NOT modified. Standalone capture matches its behavior by reuse, not by
  editing it. (Mission MUST-NOT-MODIFY.)
- `SubstrateLib` bitmap primitives — used, not changed.
- `docs/validation/**` — out of scope, untouched.

## RESCOPE_REQUIRED
None.

## Genesis-event decision (doc/source drift, recorded)
Mission text says "mirror drawer capture's genesis event." Source shows the
cascade emits NO genesis `AuditEvent` for the tunnel it files (bare
`rowStore.insert`). Byte-identity with the cascade is the load-bearing
requirement, so standalone capture also emits no tunnel genesis event. Source
is ground truth per the mission's "Read First." (Smythe option b.)
