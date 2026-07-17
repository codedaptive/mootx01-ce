---
title: MOOTx01 — User Guide
version: v0.2
status: draft
---

# MOOTx01 — User Guide

MOOTx01 is your personal memory, on your Apple devices. You capture things worth
remembering — notes, links, facts — and recall them later by asking, searching,
or letting an on-device assistant answer from them. Everything lives on your
device, encrypted; nothing goes to a server you don't control.

This guide covers what the app does and how to use each part of it. Where a
feature needs a one-time setup step (a permission, signing into iCloud), that's
called out.

---

## The idea in one minute

- A **memory** is called a **Drawer** — a piece of text you filed, with a
  location and a privacy level.
- You **capture** memories and **recall** them. You can also reorganize, edit,
  withdraw, or permanently erase them.
- Each memory has a **privacy level** (Normal, Elevated, Restricted, Secret) and
  is either **private** (default) or **public**. Only memories you mark *public*
  ever leave your device — through Spotlight, a shared connection, or the
  assistant. Everything else stays put.

---

## The app at a glance

The app has these tabs:

- **Capture** — file a new memory, and choose whether it's private or public.
- **Recall** — search your memories.
- **Intelligence** — ask an on-device assistant that answers from your estate.
- **The Top** — your most relevant / recent memories.
- **Apple Surfaces** — see how MOOTx01 shows up in Siri, Spotlight, and
  Shortcuts.
- **Edges** — an honest status board of what's connected and what isn't.
- **Engine** — how the app hosts your estate, plus the portable LAN server.
- **Miners** — optional automatic capture from Calendar and Contacts.

---

## Capturing a memory

**In the app:** open **Capture**, type your note, pick a location (a "room"),
choose Private or Public, and save.

**By voice (Siri):** say **"Capture this in MOOTx01"** or **"Remember this with
MOOTx01."**

**From any app (Share Sheet):** highlight text or a link, tap Share, and choose
**MOOTx01**. The share sheet hands the content to MOOTx01 and it's filed the next
time the app runs — so sharing works even if the app is closed. Shared links are
saved as the link itself.

**From the Action Button / Shortcuts:** add the "Capture Memory" shortcut and
trigger it however you like.

**Privacy at capture:** the Private/Public choice matters. Private is the
default and never leaves the device. Public means the memory can appear in
Spotlight, be served to your other devices' clients, and be used by the
assistant. You can promote a private memory to public later by editing it.

---

## Recalling a memory

**In the app:** open **Recall** and search.

**By voice:** say **"Recall from MOOTx01"** or **"Search my memories in
MOOTx01."**

**In Spotlight:** memories you marked *public* appear in system search
(Apple Silicon). Private, restricted, and secret memories never do.

**In a Shortcut:** the Recall action returns the actual memories, so you can
recall in one step and act on them in the next (open a link, share the text,
feed them to another action).

---

## Curating memories

- **Reanchor** — move a memory to a different location/room.
- **Mutate** — edit a memory (including changing it from private to public).
- **Withdraw** — retire a memory; its history is preserved, not destroyed.
- **Expunge** — permanently erase a memory. This is guarded: it always asks for
  confirmation, and it's deliberately blocked from the URL/link surface.
- **Batch actions** — mutate or withdraw many memories at once, with a single
  **Undo** for the last batch withdrawal.

---

## The Intelligence tab (ask your memory)

Open **Intelligence** and ask a question. An on-device language model answers
using two abilities: it can **recall** from your estate, and — only when you
explicitly allow one save — **capture** a new memory.

Two things are true by design and worth knowing:

- The assistant treats everything it recalls as **information, not
  instructions.** A memory can't hijack the assistant, even if someone
  deliberately wrote it to try.
- It **cannot see** your Restricted or Secret memories, and it won't claim a
  memory exists unless it actually found one.

The assistant runs on your device. It doesn't need an internet connection or a
cloud account to answer from your memories.

---

## Automatic capture (Miners)

MOOTx01 can quietly file facts from **Calendar** (upcoming events) and
**Contacts** (birthdays) so they're in your memory without manual entry.

- **Off by default.** Nothing is read until you turn a source on.
- **You're asked first.** The first time you enable a source and tap **Set Up**
  or **Mine Now**, the system asks for Calendar/Contacts permission. If you
  decline, nothing happens and the status says so.
- **You set the pace.** Choose how often each source runs, or use **Mine Now** on
  demand.

On iPhone/iPad, background runs are "when the system allows" — a request, not a
guarantee of exact timing. You can always run **Mine Now** yourself.

There's also a "Run Daily Ingest" Shortcut, if you'd rather trigger a daily pass
from your own automation. It uses the same rule: it never asks for new
permissions on its own.

---

## Long jobs (import, reindex, dream)

Some actions take a while — importing a vault or palace, rebuilding indexes, or
"dreaming" (a background consolidation pass). When you start one, the system
shows a **Live Activity** with progress and a **stop** button, so you can watch
it and cancel if needed.

---

## The recall widget

Add the **MOOTx01 recall widget** to your Home Screen or desktop to see your
most recent **public** memories at a glance. The widget only ever shows public
memories — nothing private appears there.

---

## The Engine tab: hosting and the portable server

The **Engine** tab shows how MOOTx01 hosts your estate (it runs inside the app
on every platform; on Mac it can also supervise a separate server process).

It also has the **portable LAN server** — this lets another device on your local
network (say, your Mac) connect to the estate on your phone.

- **You authenticate to turn it on.** Starting the server asks for Face ID /
  Touch ID / your passcode — it's your device confirming *you* are the one
  exposing your memory.
- **Read-only, public-only.** A connected device can only *read*, and only your
  **public** memories. It can't change anything, and it never sees private
  content.
- **On power.** By default the server runs only while your device is charging,
  and only while the app is open.
- **Pairing.** Reveal the connection token (again behind Face ID) and give it to
  the client. You can regenerate it any time, which disconnects everyone.

---

## Keeping devices in sync (iCloud)

MOOTx01 can keep your memories in sync across your Apple devices through your
**private iCloud**. This section covers what syncs, what stays local no matter
what, how fast changes travel, and what to do when something isn't working.

### Before you begin

Sync requires two things:

1. You are **signed into iCloud** on every device.
2. You are running a build of MOOTx01 that has the iCloud container enabled.
   Sync is off by default — the app does nothing with iCloud until it is
   explicitly configured at launch. A build that has not been set up for sync
   works fully on a single device and makes no iCloud calls.

If both conditions are met, sync starts automatically. There is no in-app
toggle to turn it on or off in this release.

### What syncs — and what never leaves the machine

**Synced:**

- Memories (drawers) whose privacy level is **Normal** or **Elevated**
- Memory links (tunnels) between those memories
- Knowledge-graph facts
- Diary entries

**Never synced — stays on this device only:**

- Memories marked **Restricted** or **Secret**. This is a hard boundary at the
  sync layer, not a preference you can override in the app. A Restricted or
  Secret memory is never placed in the sync outbox, and inbound records at
  those tiers are rejected if they arrive. The boundary holds regardless of
  whether iCloud sync is enabled.
- Computed data (scores, rankings, index data). These are rebuilt locally on
  every device from the underlying memories — sending them would waste space
  and risk stale values overwriting fresh ones.

**In plain terms:** your sensitive memories stay on the machine they were
created on. The sync ceiling is fixed at Elevated — the two highest tiers do
not cross any device boundary.

### What two devices at once actually looks like

When you save a memory on one device, the change reaches your other devices
within roughly:

- **~12 seconds typical / ~24 seconds worst case** when both devices are
  active (screens on, apps in foreground or recent background)
- **~4–9 seconds** when the Mac app is running — it holds an APNs entitlement
  that wakes the sync engine immediately on a push notification
- **Up to ~90 seconds** when one device is idle (app backgrounded, screen off)
- **Up to ~5 minutes** when a device has been truly idle for an extended period

These are the measured numbers from the performance review. They assume a
normal working internet connection. Offline, changes queue locally and sync
the next time the device reaches iCloud.

**Simultaneous edits to the same memory:** if you edit a memory on both
devices at roughly the same time, the version with the later timestamp wins —
per memory, not per field. The earlier edit is replaced, not merged. This is
by design and matches how iCloud sync behaves across Apple apps.

**Delete vs. concurrent edit:** if one device deletes a memory while another
device edits it at roughly the same time, the edit wins. The memory survives
on both devices with the edited content. If you intended the delete, delete
again.

**Facts and diary entries:** these are append-only. A concurrent add from two
devices means both entries survive. You will never lose a fact because another
device added one at the same time.

### The 15-device ceiling

One iCloud account can hold up to 15 devices syncing the same estate
simultaneously. This is a CloudKit constraint, not a MOOTx01 limit.

If you exceed 15 devices, or a slot is reclaimed from a device that went
inactive for 30 days, the affected device re-registers automatically at the
next sync beat. You may briefly see a **"Re-enrolling with sync"** message in
the estate status — this is normal and self-resolves. It means the device is
claiming a new slot and will be current after one sync cycle.

### Version skew — older app on one device

If one of your devices is running an older version of MOOTx01 and a newer
device sends records in a format the older version doesn't recognize, the older
device holds those records. It does not apply them and does not corrupt the
local estate. After you update the app, the held records apply automatically.
You will see the held count in the estate status as **"Held for migration."**

The newer device continues syncing normally. The older device simply lags
until it updates.

### Troubleshooting

**iCloud signed out:** sync pauses immediately. The app retries automatically
when you sign back in. Memories you captured while signed out queue locally
and sync on reconnect.

**iCloud storage quota full:** sync pauses. Free space in iCloud (or upgrade
your storage plan) and sync resumes on the next beat.

**"Held for migration" count in estate status:** records from a device running
a newer app version are waiting for the local schema to catch up. Update
MOOTx01 to the current version. The count clears after the update and a sync
cycle.

**"Parked entries" in estate status:** records that failed to push are queued
for retry. The engine retries automatically on every sync beat. Parked entries
that persist across multiple beats are usually caused by a temporary CloudKit
error — check iCloud status and your connection.

**Sync not starting at all:** verify both conditions in "Before you begin"
above. The app makes no iCloud calls — and shows no sync status — until the
build is configured for sync.

### What is not ready yet

**No in-app toggle.** Sync is enabled or disabled at the build level. There is
no in-app settings screen to turn sync on or off or to choose which devices
participate. This is a tracked gap.

**Tier-rise retraction.** If you raise a memory's privacy level from Normal or
Elevated to Restricted or Secret after it has already synced to another
device, the peer device keeps the snapshot it received. It will not receive an
automatic retraction. The memory on the peer device remains at the privacy
level it had when it synced. Until retraction ships, the practical guidance is:
if you want a previously-synced memory gone from a peer, delete it on the peer
explicitly. This behavior is documented in the engineering notes as a tracked
follow-up.

---

## Your privacy

- Your estate is **encrypted on disk**.
- **Restricted and Secret memories never leave the device** — not via iCloud,
  Spotlight, the LAN server, or the assistant. This is a hard ceiling enforced
  at the sync layer.
- **Normal and Elevated memories sync via iCloud** (if iCloud sync is enabled)
  across your own devices. They remain in your private iCloud database and are
  not shared with anyone else.
- **Only public memories appear in Spotlight, the LAN server, and the
  assistant.** The Public/Private toggle is separate from privacy level — a
  private Normal memory syncs across your own devices but does not appear in
  Spotlight or serve to a connected client.
- Calendar and Contacts are read **only on your device** and only after you
  enable a miner; nothing is sent to the developer, and nothing is used to track
  you.
- Serving your estate on the network requires your device unlock.

---

## Platform notes

- **iPhone / iPad:** everything runs inside the app. Background tasks (mining,
  sync) run when the system allows.
- **Mac:** everything the phone does, plus a menu-bar mode so the app can keep
  hosting/mining after you close its window, and the option to run a separate
  server process.

---

## Setup you may need to do once

- **Turn on a miner** (and grant Calendar/Contacts) if you want automatic
  capture.
- **Sign into iCloud** (and the app must be built with its iCloud container) for
  multi-device sync.
- **Start the portable server** (and approve Local Network access) if you want
  another device to connect.

Everything else works out of the box, on one device, with no account required.
