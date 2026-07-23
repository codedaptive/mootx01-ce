---
version: v0.1
created: 2026-07-23
mission: FAB5-CP
---

# App Store Reviewer Notes — Mootx01 iOS App

These notes are for pasting into the **App Review Information → Notes** field
in App Store Connect. They preempt the questions reviewers most commonly ask
about apps that use local network access and an on-device LAN server.

---

## Local Network Usage — Four-Point Posture

The app exposes a local-network MCP (AI tool) server. Reviewers sometimes flag
this as a network-data-collection surface. The four points below describe the
design posture and should address the concern in full.

### 1. Owner-presence credential (Face ID gate)

Before the LAN server accepts any connection, the user must authenticate with
Face ID (or device passcode as fallback). The server does not begin listening
until the credential prompt is satisfied and the user is in the foreground. A
remote client that connects before authentication is complete receives no
response.

Implementation reference: `LanSessionManager` in `GatewayUI`
(`apps/Mootx01-App/Sources/MootGateway/LanSessionManager.swift`).

### 2. Read-only tool allowlist

The MCP server exposes a fixed allowlist of recall and status tools — it does
not expose write tools to LAN clients. Tools that mutate the estate
(capture, delete, reorganize) are not available over the LAN endpoint.
The allowlist is compiled into the binary and cannot be extended at runtime.

Implementation reference: `LanToolRegistry` in `GatewayUI`.

### 3. Foreground-bound

The LAN server runs only while the app is in the foreground (active scene
state). It stops when the app is backgrounded or suspended. There is no
background entitlement that keeps the server alive when the app is not
running. The app uses `remote-notification` background mode only for
CloudKit zone-change notifications (iCloud sync), not for serving LAN
traffic.

### 4. Off by default

The LAN server is disabled in factory state. The user must explicitly enable
it in Settings → LAN Server. The default configuration does not listen on
any network interface.

---

## App Intents / Siri Usage

The app registers two Siri Shortcuts via `AppShortcutsProvider`:

- **"Capture this in MOOTx01"** — spools the current share content into
  the on-device memory estate.
- **"Recall from MOOTx01"** — returns a top memory matching the spoken query.

All intent processing is local. No data leaves the device as a result of Siri
invocation. `NSSiriUsageDescription` is set in Info.plist.

---

## Calendar and Contacts Access

The app requests **NSCalendarsFullAccessUsageDescription** and
**NSContactsUsageDescription**. Access is used exclusively by on-device
miners that file events and contact birthdays into the local memory estate.

- Data is never uploaded to a developer server.
- Mining runs only from attended sessions (the user taps "Mine Now" or enables
  a cadence in Settings).
- Contacts access reads **names and birthdays only** — it does not read email
  addresses, phone numbers, or notes.
- Calendar access reads **event titles and dates** — it does not read
  event notes, attendees, or conference links.

A full cadence tick can be triggered via Siri Shortcuts (DailyIngestIntent)
but that intent also never requests a TCC permission prompt — it silently skips
any source the user has not already granted.

---

## Encryption Export Compliance

`ITSAppUsesNonExemptEncryption` is set to `false` in Info.plist.

The app uses only Apple-approved exempt encryption:

| Component | Encryption | Exempt reason |
|---|---|---|
| SQLCipher estate | AES-256 | Data-protection exemption (ECCN 5D002, EAR §740.17(b)(3)) |
| CryptoKit (owner credential) | SHA-256 hashing | One-way hash, not encryption |
| CloudKit sync | TLS via OS | OS-provided standard protocol |
| Local network transport | TLS via NWConnection | OS-provided standard protocol |

No proprietary, non-standard, or non-exempt cryptography is used.

---

## France Export Compliance Declaration

France requires a separate declaration for cryptography that falls under French
domestic regulation (CSTA Annex 2 to Article R. 711-22 of the French
Cryptographic Regulation). Because the app uses only **standard SSL/TLS and
symmetric data-at-rest encryption provided by the OS and Apple frameworks**,
it qualifies for the **simplified declaration procedure (déclaration
simplifiée)**.

**Action required before first French distribution:**

1. File the simplified declaration with ANSSI (Agence nationale de la sécurité
   des systèmes d'information) at https://www.ssi.gouv.fr/declaration.
2. Note the declaration reference number for your records.
3. App Store Connect does not require this reference to be entered, but it must
   be available for compliance inspection.

This step is documented in the provisioning runbook (Step 10).

---

## TestFlight / Submission Gate

App Store Connect accepts iOS 27 beta SDK builds as of beta 4. **Full
submission to the App Store is gated on iOS 27 going GA** (expected ~Sept 8
release cycle). TestFlight internal distribution can proceed before GA.
