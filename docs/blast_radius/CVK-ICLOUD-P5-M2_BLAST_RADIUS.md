# Blast Radius Report — CVK-ICLOUD-P5-M2

**Baseline:** swift test (apps/Mootx01-App) pass count at mission start: 9 (exit 0)
**Mission:** P5-M2 moot-mgr APNs push accelerator nudging estate sync

**Symbols being changed / symbols being ADDED:**

This mission is **purely additive** — no existing symbol signatures are altered.
New methods are added to MootSyncDriver and the app lifecycle. The only
behavioral addition is a `registerZoneSubscription()` call inside
`MootSyncDriver.syncNow()` after the engine enables successfully; it is
guarded by a do-catch so the existing sync beat is unaffected if it throws.

## Additive symbols (all new, no callers to chase)

| Symbol | File | Kind | Note |
|---|---|---|---|
| `MootSyncDriver.handleRemoteNotification(userInfo:)` | MootSyncDriver.swift | new public func | APNs forwarding seam |
| `MootSyncDriver.cloudKitEngine` | MootSyncDriver.swift | new private var | stored ref for APNs delegation |
| `MacAppDelegate.application(_:didReceiveRemoteNotification:)` | Mootx01App.swift | new macOS delegate method | push handler |
| `IOSAppDelegate` | Mootx01App.swift | new class | iOS push delegate adaptor |
| `SyncTileView` | EngineView.swift | new private View | sync status tile |

## Behavioral change in existing function

| Function | File | Change |
|---|---|---|
| `MootSyncDriver.syncNow()` | MootSyncDriver.swift | Stores `CloudKitSyncEngine` ref; calls `registerZoneSubscription()` after successful enable (do-catch, non-throwing on failure) |
| `Mootx01App.init()` | Mootx01App.swift | No change (iOS delegate adaptor registered declaratively via `@UIApplicationDelegateAdaptor`) |
| `MacAppDelegate.applicationDidFinishLaunching(_:)` | Mootx01App.swift | Adds `NSApplication.shared.registerForRemoteNotifications()` call |

## `project.yml` change

| Key | Platform | Before | After |
|---|---|---|---|
| `UIBackgroundModes` | iOS | `[fetch]` | `[fetch, remote-notification]` |

## Call site classification

N/A — purely additive mission. No MUST_UPDATE sites. No RESCOPE_REQUIRED.

## Summary

- MUST_UPDATE: 0 sites (additive)
- INTENTIONALLY_LEFT: 0 (no false positives)
- RESCOPE_REQUIRED: 0
