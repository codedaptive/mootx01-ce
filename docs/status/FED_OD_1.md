---
title: FED-OD-1 Completion Report
task_id: FED-OD-1
status: COMPLETE
date: 2026-07-18
worker: Bilby
stream: agent-a59ffd5fd9a48d15b
---

# COMPLETION: FED-OD-1

**Status:** COMPLETE

## What Was Done

**Part 1: Blast Radius Report**
Committed BRR to `docs/analysis/blast_radius/FED_OD_1_BLAST_RADIUS.md`.
Predominantly net-new mission. MUST_UPDATE: 4 sites in project.yml.

**Part 2: LANDiscovery implementation + tests + project.yml**
- NEW: `packages/kits/ConvergenceKit/Sources/ConvergenceKitFederation/LAN/LANDiscovery.swift`
- NEW: `packages/kits/ConvergenceKit/Tests/ConvergenceKitFederationTests/LAN/LANDiscoveryTests.swift`
- EDIT: `apps/Mootx01-App/project.yml` — updated NSLocalNetworkUsageDescription (both targets), added `_mootx01-fed._tcp` to NSBonjourServices (both targets)

## Module Location and Why

`packages/kits/ConvergenceKit/Sources/ConvergenceKitFederation/LAN/LANDiscovery.swift`

Discovery belongs in ConvergenceKitFederation — it is the kit that owns the Federation transport spine (identity, relay, pairing, outbox). The app's MootGateway layer is the runtime orchestrator; it will call into LANDiscovery.startDiscovery() when the user's visibility setting is non-off. Keeping discovery in the kit (not in the app target) makes it testable without the app's UIKit/SwiftUI stack and reusable by moot-mgr (the Mac resident) without code duplication.

## Seam Shape for Testability

Protocol: `LANDiscoverySession` (AnyObject, Sendable)
- `startAdvertising(txtRecord: [String: String], port: UInt16) throws`
- `stopAdvertising()`
- `startBrowsing(onPeerFound: @escaping @Sendable (String, LANFederationTXTRecord, String?) -> Void)`
- `stopBrowsing()`

Production conformer: `NWLANDiscoverySession` (class, Network.framework NWBrowser + NWListener).
Test conformer: `FakeLANDiscoverySession` (class, in-process, records call counts, exposes `simulatePeerFound`).

`LANDiscovery.init` accepts `session: any LANDiscoverySession`. Tests inject `FakeLANDiscoverySession` — no NW stack ever starts. Pattern mirrors `HostedRelay` / `FakeRelayHTTPTransport`.

The peer-found callback is passed directly into `startBrowsing(onPeerFound:)`, avoiding the awkward property-based wiring that value-type existentials make difficult. The callback is `@Sendable` throughout the chain.

## Info.plist Change

`apps/Mootx01-App/project.yml` (two targets: macOS and iOS):
- `NSLocalNetworkUsageDescription` updated to mention federation discovery
- `NSBonjourServices` array extended with `_mootx01-fed._tcp` (alongside existing `_mootx01._tcp`)

This satisfies the App Store landmine identified in FED_OD_CHARTER.md V3 and the Kong charter §Risks.

## Test Names

Suite: "LANDiscovery — TXT record round-trip"
- "encode then decode preserves fingerprint, name, version, port"
- "decode without mandatory fp field returns nil"
- "decode with partial fields uses defaults for n, v, p"

Suite: "LANDiscovery — TXT record NEGATIVE invariant (no content bytes)"
- "TXT encode produces exactly four keys: fp, n, v, p — no others"  ← NEGATIVE invariant
- "fingerprint in TXT record equals key-derived value, not content-derived"  ← content-byte prohibition
- "fingerprint is 16 lowercase hex characters"

Suite: "LANDiscovery — DiscoveryVisibilityPolicy"
- "default visibility is .off when no key is stored"
- "visibility-off default means callers must not call startDiscovery"
- "setVisibility / visibility round-trips all three values"

Suite: "LANDiscovery — lifecycle"
- "startDiscovery calls startAdvertising and startBrowsing exactly once each"
- "stopDiscovery calls stopAdvertising and stopBrowsing and clears peers"
- "startDiscovery is idempotent — second call is a no-op"
- "startDiscovery advertises the correct TXT record keys"

Suite: "LANDiscovery — peer verification classification"
- "discovered peer with known fingerprint is classified isVerified = true"
- "discovered peer with unknown fingerprint is classified isVerified = false"
- "updateKnownFingerprints reclassifies already-discovered peers"
- "updateKnownFingerprints with empty set un-verifies previously-verified peers"

Suite: "LANDiscovery — fingerprint derivation"
- "different public keys produce different fingerprints"
- "same public key always produces the same fingerprint"
- "LANDiscovery.localTXTRecord.fingerprint uses the supplied public key"

## Test Verification Log

### Baseline
- Pass count at mission start: 104 (ConvergenceKitFederationTests, exit 0)
- Command: `swift test --package-path packages/kits/ConvergenceKit --filter ConvergenceKitFederationTests`

### Final
- Command: `swift test --package-path packages/kits/ConvergenceKit --filter ConvergenceKitFederationTests`
- Exit code: 0
- Pass count: 124 (+20 new LANDiscovery tests)
- Fail count: 0

```
Test run with 124 tests in 31 suites passed after 0.514 seconds.
```

## Self-Review

### Step 0 — Blast Radius Scope Check
- Blast Radius Report: docs/analysis/blast_radius/FED_OD_1_BLAST_RADIUS.md
- MUST_UPDATE files in report: project.yml (4 sites)
- MUST_UPDATE files in diff: project.yml ✅
- Diff files not in report: LANDiscovery.swift (net-new), LANDiscoveryTests.swift (net-new), FED_OD_1.md (status doc) — all expected and accounted for

### Standard Checks
- Scope: all within mission scope ✅
- No secrets in diff ✅
- No system colors (no UI code) ✅
- Prohibited blast-radius patterns: none ✅
- No bridges, shims, or orphan deprecations ✅

## Discoveries

1. `NWTXTRecord.setEntry` does not exist in macOS 27 SDK. NWTXTRecord uses a subscript `r[key] = String?` and iteration yields `(String, NWTXTRecord.Entry)` where the Entry type is opaque — use `r[key]` (subscript) to read string values in loops.

2. `lock.withLock { guard !flag else { return } }` — the `return` exits the closure, not the outer function. All guard-style early returns in a `withLock` closure must use a `didActivate` flag pattern returned outside the lock.

3. `@Sendable` on a closure in a `{ [weak self] @Sendable ... }` capture list must be written `{ @Sendable [weak self] ... }` (attribute before capture list in Swift 6).

4. NWTXTRecord iteration element type is `(String, NWTXTRecord.Entry)` where Entry is non-Optional. Use the subscript `txt[key] -> String?` to extract string values in the extractTXTRecord helper.

## Outstanding

- FED-OD-2 (LANRelay Swift conformer) is the immediate dependency for the relay port field (`relayPort` in the TXT record). Currently defaults to 0 (undeclared). FED-OD-2 must be completed before the relay port advertises a real value.
- Peer removal handling in NWLANDiscoverySession is not wired (NWBrowser `.removed` change is not forwarded to `handlePeerLost`). Sufficient for FED-OD-1 scope; FED-OD-6 (Federation UI) will need peer removal for the "Nearby" list to update cleanly.
- Perkins flagged this surface (TXT content-byte prohibition). The NEGATIVE invariant test covers the prohibition. Perkins should review in the FED-OD-7 conformance review.
