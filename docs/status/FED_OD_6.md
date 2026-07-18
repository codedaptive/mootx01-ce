---
task: FED-OD-6
status: COMPLETE
stream: worktree-agent-a2133a104aafdd2c2
date: 2026-07-18
---

# COMPLETION: FED-OD-6 — Federation UI Panel

**Status:** COMPLETE

## What Was Done

### Part 0: Merge + stale base check
- Merged SHA `5dbe509b` (FED-OD-3 base) via fast-forward into worktree branch.
- Verified `EngineView.swift` contains `SyncTileView` ✓
- Verified `QRPairingView.swift` exists ✓
- moot-mgr does NOT use GatewayUI — Federation panel is Mootx01-App only.

### Part 1: Protocol seam + types
**File:** `apps/Mootx01-App/Sources/GatewayUI/Federation/FederationSessionManagerProtocol.swift`
- `FederationPosture` enum (5 cases: Open/Convenient/Balanced/Locked/In-person).
  Sealed absent by construction — data class = secret; no key is ever minted.
- `KnownPeer` struct for the panel (F1 stub; FED-OD-4 replaces with `_fed_peers`).
- `FederationSession` struct: peer, posture, startedAt, expiresAt, whatsCrossing.
- `FederationSessionManaging` `@MainActor` protocol seam.
- `FederationSessionError` enum (postureNotFunctionalInF1, sessionAlreadyActive).

### Part 2: Observable controller
**File:** `apps/Mootx01-App/Sources/GatewayUI/Federation/FederationController.swift`
- `@MainActor @Observable FederationController` conforming to `FederationSessionManaging`.
- Manages `DiscoveryVisibility` via `DiscoveryVisibilityPolicy` (persisted; mirrors SyncPolicy).
- Drives `LANDiscovery` from ConvergenceKitFederation for browse + advertise.
- F1 RECONCILIATION: advertising uses placeholder public key (zero bytes) pending
  FED-OD-4's identity wiring. Browsing works correctly.
- Session start/end with 30-minute auto-expiry for Balanced in F1.
- `addKnownPeerForTesting` / `removeKnownPeerForTesting` for `@testable` test access.
- UserDefaults-backed KnownPeer persistence (key: `federation.knownPeers.f1`).

### Part 3: Federation panel view
**File:** `apps/Mootx01-App/Sources/GatewayUI/Federation/FederationPanelView.swift`

Four GroupBox regions:
1. **VISIBILITY**: Off/While Open/Always segmented control + discovery status indicator.
2. **NEARBY**: `DiscoveredPeer` list from `LANDiscovery`; verified badge (green checkmark)
   for known fingerprints; Pair button for unknown peers launching pairing sheet.
3. **PEERS**: `KnownPeer` list; display name + last-session relative date; Unpair button.
4. **START SESSION**: Peer picker + posture cards + Start button.

Session banner (when active): peer name, what's crossing, `SessionCountdown`,
prominent End Session button with confirmation dialog.

**Posture cards:**
- `PostureCard` view: title, what-crosses sentence, lifetime, at-end.
- Balanced: selectable, accent-colored border when selected, full opacity.
- Open/Convenient/Locked/In-person: lock icon, 50% opacity, "coming soon" italic line.
  Tapping a locked card does nothing (and the user sees the lock — never a silent stub).
- F1 HARD RULE: `isFunctionalInF1` is the structural gate — no posture bypasses it.

**Pairing sheet (F1):** Placeholder explaining that the full QR ceremony (FED-OD-3)
requires identity wiring from FED-OD-4. Includes "Add as Test Peer" path for F1 testing.

**A11y compliance (Nert lens):**
- `.accessibilityLabel` + `.accessibilityHint` on every interactive element.
- `SessionCountdown` uses `.accessibilityValue` for VoiceOver announcements.
- `NearbyPeerRow` / `KnownPeerRow` use `.accessibilityElement(children: .combine)`.
- All buttons: `minHeight: 44` (44pt touch target floor).
- `.accessibilityAddTraits(.isHeader)` on the panel title.
- Posture cards: `.isSelected` trait when selected and functional.

**Visual compliance (Friedlander lens):**
- Semantic colors only: `.primary`, `.secondary`, `.accentColor` (via `Color.accentColor`),
  `.red` (on End Session tint). No hex literals, no raw system colors.
- `.leading` / `.trailing` alignment throughout — no `.left` / `.right`.
- Consistent GroupBox structure with `.padding(6)` inner padding (matches SyncTileView).

### Part 4: ContentView update
**File:** `apps/Mootx01-App/Sources/GatewayUI/ContentView.swift`
Added `Tab("Federation", systemImage: "person.2.wave.2")` after the Engine tab.

### Part 5: Tests
**File:** `apps/Mootx01-App/Tests/GatewayUITests/FederationPanelTests.swift`
`@Suite @MainActor .serialized` — 12 new tests:

| Test name | What it covers |
|---|---|
| visibilityDefaultsToOff | discovery off on first launch |
| visibilityRoundTrips | UserDefaults round-trip |
| balancedIsFunctionalInF1 | Balanced is the only working posture |
| nonBalancedPosturesAreLockedInF1 | exactly 4 locked postures |
| sealedAbsentFromPostureEnumeration | no-secret invariant, count == 5 |
| noPostureDescriptionMentionsSecret | belt-and-suspenders secret scan |
| startSessionThrowsForLockedPostures | locked postures throw, never no-op |
| startSessionSucceedsWithBalanced | happy path |
| startSessionThrowsWhenAlreadyActive | sessionAlreadyActive guard |
| postureCardTextFieldsNonEmpty | localized-string presence |
| postureRawValuesStable | no key drift |
| endSessionUpdatesLastSessionTimestamp | session lifecycle |

### Part 6: Simms guide section
**File:** `docs/guide/MOOTX01_APP_USER_GUIDE.md` (v0.2 → v0.3)
Added Federation tab to app-at-a-glance list and full Federation section:
- Discover → Pair → Session flow in plain language.
- Honest about F1 (Balanced only, own+paired peers).
- Explains locked modes are coming.
- What-this-release-does-not-include section.
- Privacy statement.

## Test Verification Log

### Baseline (before mission)
- MootGatewayTests: 126 tests in 23 suites, exit 0
- GatewayUITests: 13 tests in 4 suites, exit 0
- Total: 139 tests

### Final (post-implementation)
```
swift build: Build complete! (exit 0)
swift test:
  Test run with 126 tests in 23 suites passed  (MootGatewayTests — unchanged)
  Test run with 25 tests in 5 suites passed    (GatewayUITests — +12 new)
```
Delta: +12 new tests, all passing. Zero regressions.

## Discoveries

1. **moot-mgr does not share GatewayUI**: Federation panel is iOS/macOS app only. moot-mgr is a standalone Swift package without GatewayUI dependency.

2. **F1 advertising limitation**: `LANDiscovery` requires a local Ed25519 public key for advertising. GatewayUI does not have access to the estate identity key at F1 — the engine layer exposes it through MootGateway, but GatewayUI's interface into MootGateway doesn't include it. RECONCILIATION site is marked in `FederationController.swift`.

3. **SessionCountdown `mutating` hazard**: Initial draft used `mutating func updateDisplay()` on a SwiftUI struct. SwiftUI `@State` properties do not require `mutating` — removed.

4. **Protocol isolation conflict**: `FederationSessionManaging` initially declared as `Sendable` without `@MainActor`. `FederationController` is `@MainActor @Observable`; Swift 6 strict concurrency rejected the conformance. Fixed by annotating the protocol `@MainActor`.

5. **Nested quotes in string literals**: `"Add as Test Peer"` inside a `defaultValue:` string terminated the Swift string literal. Rewrote to avoid nested quotes.

## Outstanding (out of scope, noted for reconciliation)

- **FED-OD-4 identity wiring**: When FED-OD-4 delivers `FederationSessionManager`, wire the estate's real Ed25519 public key into `FederationController.startDiscovery()` via dependency injection.
- **Real QRPairingView wiring in pairing sheet**: The `pairingSheet` in `FederationPanelView` currently shows a placeholder pending FED-OD-4's identity surface. Replace with the full `QRPairingView` from FED-OD-3 once the identity is injectable.
- **_fed_peers real store**: Replace the UserDefaults-backed `KnownPeer` list with FED-OD-4's `_fed_peers` store when it ships.
