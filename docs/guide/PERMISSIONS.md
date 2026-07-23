---
version: v0.1
created: 2026-07-23
mission: FAB5-CP
---

# Permissions — What MOOTx01 Asks For and Why

MOOTx01 asks for a small set of device permissions the first time you use
features that need them. This page explains each one, what it does, and what
happens if you decline.

---

## Calendar Access

**When you see it:** the first time you tap **Mine Now** with the Calendar
miner enabled, or when you set up a Calendar mining cadence in Settings.

**What MOOTx01 does with it:** reads event titles and dates from your
Calendar and files them into your private, on-device memory estate. The
miner does not read event notes, attendees, video-call links, or location.

**What stays on your device:** everything. Calendar data is written to your
local estate and, if iCloud Sync is enabled, to your own iCloud account.
It is never sent to any developer server.

**If you decline:** Calendar mining is silently skipped. The rest of the app
works normally.

**To change it later:** Settings → Privacy & Security → Calendars → MOOTx01.

---

## Contacts Access

**When you see it:** the first time you tap **Mine Now** with the Contacts
miner enabled, or when you set up a Contacts mining cadence.

**What MOOTx01 does with it:** reads contact names and birthdays, then files
them into your private, on-device memory estate. The miner does not read
email addresses, phone numbers, addresses, notes, or photos.

**What stays on your device:** everything. Same as Calendar — local estate
only, optionally synced to your own iCloud account.

**If you decline:** Contacts mining is silently skipped.

**To change it later:** Settings → Privacy & Security → Contacts → MOOTx01.

---

## Local Network

**When you see it:** the first time the LAN server starts. This only happens
if you have enabled the LAN server in Settings → LAN Server.

**What MOOTx01 does with it:** allows the app to listen on your local network
so that AI tools on the same Wi-Fi (Claude Code, Cursor, etc.) can query your
memory estate. The server is foreground-only, Face ID gated, and read-only —
AI tools on your LAN can retrieve memories but cannot write or delete them.

**What stays on your network:** local network traffic never leaves your home
or office network and does not touch any external server.

**If you decline:** the LAN server cannot start. Local MCP clients on your
network will not be able to reach the estate, but the app works normally for
direct device use.

**To change it later:** Settings → Privacy & Security → Local Network → MOOTx01.

---

## Face ID

**When you see it:** the first time you start the LAN server (if enabled in
Settings → LAN Server).

**What MOOTx01 does with it:** verifies that you are the estate owner before
the LAN server begins accepting connections. The app does not store a biometric
template — Face ID authentication is handled entirely by the OS.

**If you decline:** the LAN server does not start. All other features work
normally.

**To change it later:** Settings → Privacy & Security → Face ID & Passcode.

---

## Siri and Shortcuts

**When you see it:** if you add a MOOTx01 shortcut from the Shortcuts app,
or if you invoke a MOOTx01 Shortcut phrase with Siri for the first time.

**What MOOTx01 does with it:** registers two voice phrases so you can say
things like "Capture this in MOOTx01" or "Search my memories in MOOTx01"
to Siri. All processing is local — Siri hands control to the app, which runs
the intent on-device.

**If you decline:** Siri phrases for MOOTx01 do not work. The app itself
still works normally.

**To change it later:** Settings → Siri & Search → MOOTx01.

---

## Ultra Wideband (Nearby Interaction)

**When you see it:** when you initiate estate pairing by holding two
iPhones together (proximity pairing).

**What MOOTx01 does with it:** uses UWB distance sensing to confirm that
two Mootx01 devices are physically close before starting a pairing handshake.
This replaces QR-code scanning for estate federation setup. No location data
is collected.

**If you decline:** proximity (UWB) pairing is not available. You can still
pair estates using the QR-code or manual entry flow.

**To change it later:** Settings → Privacy & Security → Nearby Interactions → MOOTx01.

---

## Permissions summary table

| Permission | Trigger | Off by default? | Decline impact |
|---|---|---|---|
| Calendar | Calendar miner first run | Yes | Calendar mining skipped |
| Contacts | Contacts miner first run | Yes | Contacts mining skipped |
| Local Network | LAN server enable | Yes (LAN server is off by default) | LAN server unavailable |
| Face ID | LAN server enable | Yes | LAN server unavailable |
| Siri & Shortcuts | First Siri invocation | Yes | Siri phrases unavailable |
| Nearby Interaction | Proximity pairing | Yes | UWB pairing unavailable; QR still works |
