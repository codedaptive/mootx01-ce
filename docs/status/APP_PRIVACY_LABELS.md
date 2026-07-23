---
version: v0.1
created: 2026-07-23
mission: FAB5-CP
---

# App Privacy Labels — Mootx01 iOS App

Nutrition-label worksheet for the **App Privacy** section of the App Store
Connect record (`com.codedaptive.mootx01.ios`). Each row maps to one
App Store data type. Fill this worksheet into ASC at
**App Store Connect → Your App → App Privacy → Get Started**.

The four surfaces this app touches: **local on-device storage, iCloud,
Calendar/Contacts mining, and local network.**

---

## Guiding principle

All personally identifiable data written by this app is stored **locally on
the user's device** and optionally synced to the user's **private iCloud
account**. The developer never receives or has access to the data. No data is
used for tracking, advertising, or developer analytics.

---

## Data-type declarations

### Calendar data

| Field | Value |
|---|---|
| **Data type** | Other Data → Calendar Information |
| **Collected** | Yes |
| **Linked to identity** | No |
| **Used for tracking** | No |
| **Data use** | App functionality (on-device memory estate) |
| **Notes** | Event titles and dates only; event notes, attendees, and conference links are not read. Mining runs only from attended sessions; data never leaves the device except via the user's own iCloud account (see iCloud section below). |

### Contacts data

| Field | Value |
|---|---|
| **Data type** | Contacts |
| **Collected** | Yes |
| **Linked to identity** | No |
| **Used for tracking** | No |
| **Data use** | App functionality (on-device memory estate) |
| **Notes** | Contact names and birthdays only; email addresses, phone numbers, and notes are not read. Mining runs only from attended sessions; data never leaves the device except via the user's own iCloud account. |

### Identifiers

| Field | Value |
|---|---|
| **Data type** | Identifiers → Device ID |
| **Collected** | No |

No device identifiers are collected or transmitted.

### Location

| Field | Value |
|---|---|
| **Data type** | Location |
| **Collected** | No |

The app does not access location services.

### Health and fitness

| Field | Value |
|---|---|
| **Data type** | Health & Fitness |
| **Collected** | No |

### Financial info

| Field | Value |
|---|---|
| **Data type** | Financial Info |
| **Collected** | No |

### Usage data

| Field | Value |
|---|---|
| **Data type** | Usage Data → App Activity |
| **Collected** | No |

No usage analytics, crash reports, or telemetry are transmitted to the developer.

### Diagnostics

| Field | Value |
|---|---|
| **Data type** | Diagnostics → Crash Data |
| **Collected** | No |

No crash reports are transmitted.

---

## iCloud / CloudKit surface

The user's memory estate is optionally synced through the user's **private
CloudKit database** (`iCloud.com.codedaptive.mootx01`). From App Store Connect's
perspective this is not developer data collection — the data is stored in the
user's own iCloud account, not accessible to the developer. Apple's App Privacy
guidance confirms this: data stored solely in the user's own iCloud account does
not need to be declared as "collected."

**No declaration required** for iCloud sync data under current Apple guidelines.

---

## Local network surface

The app may serve recall queries to AI tools on the user's LAN via a local MCP
server. This is an on-device-to-device data path entirely under user control
(off by default, Face ID gated, foreground-only, read-only allowlist). No data
transits through developer infrastructure.

**No declaration required** for the local network server surface under current
Apple guidelines.

---

## Permission cross-reference

Every permission declared in Info.plist must have a matching privacy-label row,
and every label row must map to a real permission or feature.

| Permission / Info.plist key | Label row declared above | Status |
|---|---|---|
| NSCalendarsFullAccessUsageDescription | Calendar data | ✅ |
| NSContactsUsageDescription | Contacts data | ✅ |
| NSLocalNetworkUsageDescription | Local network surface (no label required) | ✅ |
| NSFaceIDUsageDescription | No personal data collected via Face ID | ✅ |
| NSSiriUsageDescription | No data collected by Siri intents | ✅ |
| NSNearbyInteractionUsageDescription | No personal data — proximity pairing only | ✅ |
| ITSAppUsesNonExemptEncryption = false | Export compliance declared | ✅ |

No permission is missing a privacy-label row; no label row is missing a
corresponding permission.
