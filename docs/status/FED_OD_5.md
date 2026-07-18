---
mission: FED-OD-5
status: COMPLETE
commit: d3139cf0
---

# COMPLETION: FED-OD-5

**Status:** COMPLETE

## What Was Done

- **Part 1: UWB protocol layer** — `d3139cf0`
  - New file: `apps/Mootx01-App/Sources/MootGateway/Federation/UWBProximityPairing.swift`
  - `UWBCapabilityChecking` protocol + `LiveUWBCapabilityChecker`: iOS uses
    `NISession.deviceCapabilities.supportsDeviceInitiation`; macOS always returns false
  - `UWBPairingTransporting` protocol with `UWBPairingRole` (`.proposer`/`.acceptor`)
    and `UWBPairingEvent` (`.proximityReady`, `.proposerPayloadArrived`, `.acceptorPayloadArrived`,
    `.proximityLost`, `.failed`)
  - `LiveUWBPairingTransport` (iOS-only, `#if os(iOS)` guarded): full MPC +
    NearbyInteraction implementation, NSLock-guarded state, background notification
    observer, `kUWBProximityThresholdMetres = 0.10`

- **Part 2: QRPairingView enhancement** — `d3139cf0`
  - Modified: `apps/Mootx01-App/Sources/GatewayUI/Federation/QRPairingView.swift`
  - Strictly additive: new optional init params (`uwbCapabilityChecker`, `uwbTransport`),
    new `@State var uwbProximityReady`, new `.task(id: "uwb-proposer/acceptor")` blocks
  - `runUWBTransport()`: AsyncStream bridge over sync `eventHandler`; proposer sends
    `qrImageData` via UWB; acceptor decodes via `QRPairingCodec.decode` and calls
    existing `coordinator.startAsAcceptor`; SAS confirm gate UNCHANGED
  - `UWBProximityAffordanceView`: "Or hold the devices together" / "Devices are close —
    exchanging…" with VoiceOver labels (Nert advisory honored)
  - Cancel button calls `uwbTransport?.stop()` before `onCancel()`
  - All existing QR ceremony logic (`handleAcceptorResponse`, `handleScannedPayload`,
    `handleSASConfirmed`, etc.) UNCHANGED — no regression risk

- **Part 3: Info.plist key** — `d3139cf0`
  - Modified: `apps/Mootx01-App/project.yml`
  - Added `NSNearbyInteractionUsageDescription` to `Mootx01-iOS` info block
  - macOS target untouched (NI is iOS-only)

- **Part 4: Tests** — `d3139cf0`
  - New file: `apps/Mootx01-App/Tests/MootGatewayTests/Federation/UWBProximityPairingTests.swift`
  - `FakeUWBCapabilityChecker` + `FakeUWBPairingTransport` (NSLock-guarded, records all calls)
  - `EventCollector` (`@unchecked Sendable`, NSLock) — Swift 6-safe event accumulator for
    `@Sendable eventHandler` closures
  - UWB-1: non-UWB capability gate — `startCallCount == 0`, `uwbEnabled == false`
  - UWB-2: UWB-transported proposer payload reaches acceptor's SAS gate
  - UWB-3: UWB round-trip, matching SAS on both sides
  - UWB-4: no crypto fork — SAS derivation identical for QR and UWB transport
  - UWB-5: FakeUWBPairingTransport lifecycle validates the fake itself

## Test Verification Log

```
swift build: exit 0 (verified 2026-07-18)
swift test:  exit 0, 139 tests in 26 suites, all passing (verified 2026-07-18)
Baseline:    134 tests before FED-OD-5 merge; 139 after — delta +5 (5 new UWB tests)
```

## Architecture Notes

- **No crypto fork.** `QRPairingCodec.encode/decode` and `QRPairingCoordinator` methods
  are identical for both transports. UWB is purely a transport substitution for the
  QR-scan step.
- **SAS gate always fires.** Proximity does NOT short-circuit `confirmSAS()`. The
  user sees the SAS screen regardless of transport.
- **Foreground-only.** `LiveUWBPairingTransport` observes `UIApplication.didEnterBackgroundNotification`
  and calls `stop()` + fires `.proximityLost` on background entry.
- **Protocol seam pattern.** `UWBCapabilityChecking` and `UWBPairingTransporting` allow
  full macOS test coverage without UWB hardware — the fakes inject events synchronously.
- **AsyncStream bridge.** The sync `eventHandler` closure on the transport is bridged
  to async via `AsyncStream<UWBPairingEvent>` in `runUWBTransport()`.
- **Swift 6 concurrency.** `@Sendable` closures cannot capture mutable `var` arrays.
  `EventCollector` (NSLock-backed `@unchecked Sendable`) is the pattern for test
  event collection in this codebase.

## Discoveries

- `NISession.deviceCapabilities` is a static computed property (not an instance
  property), so the hardware gate fires before any `NISession()` creation — exactly
  as the mission requires.
- `LiveUWBPairingTransport.fireEvent()` dispatches to `@MainActor` via
  `Task { @MainActor in }`. This is the right pattern for bridging sync MPC/NI
  delegate callbacks to the SwiftUI main thread.
- The baseline test count (134 before merge) was higher than the 25-test snapshot
  recorded during mission briefing — the full package includes kits under test, not
  just the app-layer tests. The FED-OD-5 delta is exactly +5.

## Outstanding

- `NSNearbyInteractionUsageDescription` is in `project.yml`; `xcodegen generate`
  must be run to propagate it into the `.xcodeproj` before App Store submission.
  This is the standard workflow for this repo — not a FED-OD-5 gap.
- Nert (a11y) full review is advisory. `UWBProximityAffordanceView` ships with
  VoiceOver labels and traits per the Nert advisory in the mission spec.
