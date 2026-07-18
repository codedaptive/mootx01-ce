# Mootx01-App — Apple Developer provisioning runbook

Everything the code already declares; these are the account-side steps only
you can do. Exact identifiers are taken from `apps/Mootx01-App/project.yml`.

**App IDs (bundle identifiers):**
- `com.codedaptive.mootx01.ios` — iOS app
- `com.codedaptive.mootx01.ios.share` — iOS Share extension
- `com.codedaptive.mootx01.ios.widget` — iOS Widget extension
- `com.codedaptive.mootx01.macos` — macOS app
- `com.codedaptive.mootx01.macos.share` — macOS Share extension
- `com.codedaptive.mootx01.macos.widget` — macOS Widget extension

**Shared identifiers:** App Group `group.com.codedaptive.mootx01` · iCloud
container `iCloud.com.codedaptive.mootx01` · macOS keychain access group
`com.codedaptive.mootx01.shared`.

---

## Step 1 — Confirm the Team

Everything below is scoped to one Apple Developer Program team. Signing,
App IDs, the app group, and the iCloud container all live under that team's
account, so this has to be settled before anything else.

```
Sign in at https://developer.apple.com/account
→ note the Team Name + 10-char Team ID (top-right, Membership details)
→ confirm the membership is active (not expired)
```

Xcode needs that same team account added so it can sign against it. Adding
it here lets automatic signing create profiles later without re-entering
credentials each build.

```
Xcode ▸ Settings ▸ Accounts ▸ + ▸ Apple ID ▸ sign in with the team's Apple ID
```

## Step 2 — Register the six App IDs

Each app and extension is a distinct bundle and needs its own App ID before
capabilities can be attached. Automatic signing can create these on first
build, but registering them by hand first guarantees the identifiers match
`project.yml` exactly and lets you attach the group/container deliberately.

```
https://developer.apple.com/account ▸ Certificates, IDs & Profiles ▸ Identifiers ▸ +
→ App IDs ▸ App ▸ for EACH of the six bundle IDs above:
     Description: "Mootx01 <target>"
     Bundle ID: Explicit ▸ paste the exact identifier
     (leave capabilities for Step 3–5) ▸ Continue ▸ Register
```

With all six registered, the capability toggles in the next steps have
somewhere to land. The two extensions on each platform share the app's group
and (on macOS) keychain, so they must exist before the group is assigned.

## Step 3 — Create and assign the App Group

The Share extension writes the share-inbox spool and the widget projection
into an app-group container, and the host app drains/reads them; without a
registered group the OS denies that shared container. One group is shared by
the app and both extensions on each platform.

```
Identifiers ▸ + ▸ App Groups ▸ Continue
     Description: "Mootx01 shared"
     Identifier: group.com.codedaptive.mootx01 ▸ Register
```

Now bind that group to every non-test App ID so each target may open it.
This must be done on the app AND both extensions, per platform.

```
For each of the 6 App IDs: Identifiers ▸ <the App ID> ▸ App Groups ▸ ☑ Edit
     ▸ check group.com.codedaptive.mootx01 ▸ Save
```

## Step 4 — Create and assign the iCloud/CloudKit container

Sync (`CloudKitSyncEngine`) replicates the estate's canonical tables through
a private CloudKit database; the driver stays inert until this container
exists and the device is signed into iCloud. Only the two app targets need
it (extensions don't sync).

```
Identifiers ▸ + ▸ iCloud Containers ▸ Continue
     Description: "Mootx01 estate"
     Identifier: iCloud.com.codedaptive.mootx01 ▸ Register
```

Enable iCloud with CloudKit on the two app App IDs and attach the container.
Push Notifications are NOT required — the engine polls (`pull()` on the
lifecycle), it registers no `CKSubscription` — so leave that capability off.

```
For com.codedaptive.mootx01.ios AND .macos:
     Identifiers ▸ <App ID> ▸ iCloud ▸ ☑ ▸ Include CloudKit support
     ▸ Edit ▸ check iCloud.com.codedaptive.mootx01 ▸ Save
```

## Step 5 — Enable Keychain Sharing (macOS app)

On macOS the app can hand its SQLCipher estate key to a spawned managed
server through a shared keychain access group; the LAN-server owner
credential also lives in the keychain. This needs the Keychain Sharing
capability with the app's access group.

```
Identifiers ▸ com.codedaptive.mootx01.macos ▸ Keychain Sharing ▸ ☑
     ▸ Edit ▸ add access group: com.codedaptive.mootx01.shared ▸ Save
```

The iOS app uses its default keychain access group (no shared-daemon peer on
iOS), so no keychain step is needed there. Local Network and Face ID need no
portal capability — they are Info.plist usage strings, already in the build.

## Step 6 — Set the Team in Xcode and verify signing

The generated Xcode project has no team baked in (it builds here with signing
off). Set your team on every target and let automatic signing mint the
development profiles that carry the capabilities from Steps 3–5.

```
cd apps/Mootx01-App && xcodegen generate && open Mootx01-App.xcodeproj
For EACH target (both apps, both share, both widget):
     Signing & Capabilities ▸ Team: <your team> ▸ ☑ Automatically manage signing
Build to a real device once (⌘B) to confirm each profile resolves without a
capability/entitlement error.
```

A clean build to device proves the App IDs, group, container, and keychain
group all line up with `project.yml`. If Xcode reports a missing capability,
it names the App ID — return to the matching step above and enable it.

## Step 7 — App Store Connect record + App Privacy

TestFlight/App Store distribution needs an app record with metadata and the
App Privacy disclosure. The app reads Calendar and Contacts (the miners) and
stores personal memory locally, so those must be declared even though nothing
is collected by the developer.

```
https://appstoreconnect.apple.com ▸ Apps ▸ + ▸ New App
     Platform: iOS · Bundle ID: com.codedaptive.mootx01.ios · SKU: mootx01-ios
App Privacy ▸ Get Started:
     Data collection: declare Calendar + Contacts as "used, not linked, not
     tracked" (on-device); Data NOT collected by developer otherwise
     Privacy policy URL: <your policy URL>
```

Export compliance is already answered in the build
(`ITSAppUsesNonExemptEncryption: false`), so uploads won't stall on the
encryption prompt. Fill the remaining store metadata (description,
screenshots, age rating) at your pace — none blocks the build.

## Step 8 — Archive and upload (GATED: iOS 27 must be GA)

App Store Connect rejects builds compiled against a **beta** SDK. The app
targets iOS/macOS 27, so until 27 ships GA and you're on the release Xcode,
you can dev-sign to a device (Step 6) but cannot upload to TestFlight.

```
# Only once iOS 27 is GA and you are on the release Xcode:
Xcode ▸ scheme Mootx01-iOS ▸ Any iOS Device ▸ Product ▸ Archive
     ▸ Distribute App ▸ TestFlight & App Store ▸ Upload
```

Once uploaded, the build appears in App Store Connect ▸ TestFlight for
internal testers after processing. External testing needs a Beta App Review
pass, which the App Privacy + metadata above satisfy.

## Step 9 — macOS distribution (separate path)

The macOS target ships with App Sandbox OFF (it spawns the managed daemon),
which is a hard Mac App Store blocker. macOS therefore distributes via
Developer ID + notarization — the CE pipeline you already run — not the App
Store, and is independent of the iOS 27 GA gate.

```
Xcode ▸ scheme Mootx01-macOS ▸ Archive ▸ Distribute App ▸ Developer ID
     ▸ Upload (notarize) ▸ staple the ticket
# or route through the existing CE notarization pipeline
```
