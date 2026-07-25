---
title: MOOTx01 — User Guide
version: v0.5
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

## First launch — what to expect

The first time you open MOOTx01, a short guided walkthrough helps you save
your first memory and retrieve it. It takes under a minute. You can also tap
**Skip** to jump straight into the app.

Once the walkthrough is complete it never appears again.

---

## The app at a glance

MOOTx01 uses two tab profiles:

**Standard profile (default)** — everything a new user needs:

- **Capture** — save a thought, note, or idea to your memory.
- **Recall** — search your memories.
- **Review** — the Review Center: what your estate remembers now, what matters
  today, what changed, and what may be ready to retire.
- **Intelligence** — ask an on-device assistant that answers from your memories.
- **Settings** — iCloud Sync switch and the Advanced Mode toggle (see below).

**Advanced Mode** — adds engineering and power-user tabs. Turn it on in
**Settings → Advanced Mode**:

- **The Top** — your most relevant / recent memories.
- **Apple Surfaces** — see how MOOTx01 shows up in Siri, Spotlight, and
  Shortcuts.
- **Edges** — an honest status board of what's connected and what isn't.
- **Engine** — how the app hosts your estate, plus the portable LAN server.
- **Miners** — optional automatic capture from Calendar and Contacts.
- **Federation** — share selected memories with another Mootx01 estate on your
  local network, on demand, for a limited time.

Advanced Mode persists across launches. You can switch back to Standard any
time from **Settings**.

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

## The Review Center (ask what MOOT remembers)

As an estate grows, "search it" stops being enough — you also want to know what
it holds now, what it surfaced today, and what has gone stale. That is the
**Review** tab.

Open **Review** and pick one of four reviews from the selector at the top:

- **Dashboard** — what your estate remembers now. Which rooms are gaining
  attention, which memories hold the graph together, and what currently
  conflicts.
- **Morning** — the context and open work that matter today: yesterday's
  journal, a recall of recent work, and the findings still waiting on you.
- **End of Day** — what changed, what was decided, and what still wants
  attention.
- **Weekly** — memories that may be fading, contradicted, or ready to retire.

Each review builds when you first open it, and the result is held while you
switch between them. **Refresh** rebuilds the one you are looking at. A review
reads your estate; opening one never changes anything.

### Where every line comes from

Every row has a **Where this came from** disclosure. Open it and you see the
exact MOOT tool that produced the row, the arguments it was called with, and the
raw line the row was read out of. Nothing in a review is generated prose — if a
number is on screen, some part of MOOT computed it and the row will show you
which.

Numbers are shown as MOOT reported them. A momentum or centrality score is a
raw score, not a percentage.

### When a section is empty

An empty section always says why, in MOOT's own words — "0 result(s)", a
refusal, or a note that nothing in the window qualified. A blank area would
leave you guessing whether the review ran.

One section says something stronger. Weekly's **Duplicates** explains that MOOT
has no way to find duplicate memories yet, so nothing can be reported there. It
is a missing capability, named rather than hidden, and it will stay that way
until MOOT can answer the question.

### Suggestions, and staying in control

Some rows offer a suggestion. Nothing acts on its own:

- **Retire** — on a Weekly row where two or more facts claim the same thing
  about the same subject. Retiring makes one of them inactive.
- **Accept** / **Reject** — on a proposed contradiction between two memories,
  which MOOT found but has not settled. Accept records the link; Reject
  withdraws it.
- **Confirm** — on a memory row. Marks it as verified by you.

Tapping a suggestion **never changes anything by itself.** It asks first, and
tells you what the change does before you agree. Only the confirm button in
that prompt changes your estate. Rows whose decision is already made show no
buttons.

### What can and cannot be undone

Two of these are permanent, and the app says so plainly in the prompt rather
than letting you find out afterwards:

| Suggestion | Afterwards |
|---|---|
| **Confirm** | Reversible — you can contest a confirmed memory later. |
| **Accept** | The link is recorded. Nothing is destroyed, and both memories stay fully editable. |
| **Reject** | **Permanent.** The proposed link is withdrawn and that pair is never suggested again. |
| **Retire** | **Permanent.** The fact stops being active. There is no un-retire; filing the same fact again later creates a *new* fact rather than restoring this one. |

There is no Undo button in the Review Center, because for Retire and Reject
there is nothing an Undo could do. Retired facts are not erased — they remain
in your estate's history, and MOOT can still show you the timeline of how a
fact changed.

### If the review says it is not attached

Reviews read through your running estate. If the app has not attached yet, the
Review tab says so instead of showing an empty review, and fills in once the
estate is up.

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
   Sync is off by default — the app does nothing with iCloud until you
   enable the master switch in Settings.

Once both conditions are met, open the **Settings** tab and turn on the
**iCloud Sync** switch. The setting persists across launches.

- **Mac:** Settings also opens from the app menu (⌘,).
- **iPhone / iPad (Standard profile):** tap the **Settings** tab.
- **iPhone / iPad (Advanced profile):** tap the **Settings** tab or the gear
  icon in the Engine tab toolbar — both control the same switch.

### What syncs — and what never leaves the machine

**Synced:**

- Memories (drawers) whose privacy level is **Normal** or **Elevated**
- Memory links (tunnels) between those memories
- Knowledge-graph facts
- Diary entries

**Never synced by default — requires explicit authorization:**

- Memories marked **Restricted**. You can opt in to syncing Restricted memories
  across your devices from **Settings → Sensitive Tier Sync**. Enabling requires
  biometric authentication (Face ID, Touch ID, or passcode). Once authorized,
  Restricted memories sync like Normal and Elevated ones. You can revoke at any
  time — revocation removes the authorization without a second challenge and
  immediately retracts above-ceiling memories from the local sync view.
  If iCloud sync is off, this setting has no effect.

- Memories marked **Secret**. The Secret tier sync option is visible in Settings
  but is not yet available. It is reserved for a future release pending an
  additional security review.

- Computed data (scores, rankings, index data). These are rebuilt locally on
  every device from the underlying memories — sending them would waste space
  and risk stale values overwriting fresh ones.

**In plain terms:** Normal and Elevated memories sync whenever iCloud sync is
on. Restricted memories sync only if you explicitly authorize it on each device.
Secret memories never sync in this release.

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
above, and confirm the **iCloud Sync** toggle in the Settings tab is turned on.
The app makes no iCloud calls — and shows no sync status — until both the
build supports sync and the toggle is on.

### Turning iCloud Sync on or off

Open the **Settings** tab and find the **iCloud Sync** switch:

- **Mac:** Settings tab, or the app menu (⌘,).
- **iPhone / iPad (Standard profile):** Settings tab.
- **iPhone / iPad (Advanced profile):** Settings tab or the gear icon in the
  Engine tab toolbar — both toggle the same switch.

The change takes effect immediately — turning it off stops the sync engine and
stops the app from forwarding push notifications to CloudKit; turning it on
fires an immediate sync beat.

The **Engine** tab also shows the current sync state in its iCloud Sync tile.
The tile mirrors the same switch as Settings — changing either one changes both.

The setting is saved and respected on every future launch. A device that has
never enabled sync makes no iCloud calls and requires no iCloud container
entitlement.

### Recent behavior notes

**Tier-rise retraction is automatic.** If you raise a memory's privacy
level from Normal or Elevated to Restricted or Secret after it has already
synced to another device, the app automatically sends a retraction signal to
your other devices. They will remove their snapshot of that memory. You do not
need to delete it on the peer explicitly.

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

---

## Federation — sharing on demand with a nearby estate

Federation lets you share a slice of your memories with another Mootx01 estate
for a fixed window of time. When the session ends, the other person's key
expires. This is the first release of Federation; only one sharing mode
("Balanced") is available now. More modes — and tighter controls — arrive in
future releases.

### The short version

Discover a nearby estate, pair with it once, then start a Balanced session to
share facts and fields for up to 30 minutes. End the session when you're done;
the key expires and nothing more crosses.

### Step 1 — Enable discoverability

Open the **Federation** tab. Under **Discoverability**, choose:

- **Off** — your device is invisible on the local network (default).
- **While Open** — your device is discoverable while this app is in the
  foreground. Best for phones and tablets.
- **Always** — your device is discoverable even when the app is in the
  background. Best for a resident Mac.

When you enable a non-Off setting, MOOTx01 starts looking for other estates on
your Wi-Fi network. No data crosses at this stage — discovery is reachability
only.

### Step 2 — Pair with a nearby estate

When another Mootx01 device appears in **Nearby**, tap **Pair**. You will
complete a short pairing ceremony to confirm you are connecting to the estate
you think you are. Once paired, the device appears in **Paired Peers** and shows
a verification badge in Nearby.

You only need to pair once per estate. The pairing survives app restarts.

To remove a pairing, tap **Unpair** next to the peer. They will need to pair
again before starting a future session.

### Step 3 — Start a session

Under **Start Session**, choose the paired peer and the sharing mode. In this
release, only **Balanced** is available:

- **Balanced** — private memories are shared as facts and fields (not full text),
  the key lasts only for this session, and at the end the peer's access expires.
  What crosses: private memories at fact-and-field granularity; the scope is your
  room or row.

Other modes (Open, Convenient, Locked, In-person) are shown with a lock icon.
They require the grant system, which arrives in a future release. Tapping a
locked mode shows what it will do when it ships; it does not start anything.

Tap **Start Session**. The banner appears showing:

- Who you are sharing with.
- What is crossing (one plain-language sentence).
- A countdown to when the session expires.

### Step 4 — End the session

Tap **End Session** and confirm. The peer's key expires immediately. After the
session ends, nothing more crosses — even if the peer's app is still open.

If you do nothing, the session expires on its own after 30 minutes.

### What this release does not include

- Private-share prompt (coming in F2): deliberately sharing a single memory
  with a specific person, with a required expiry date.
- Tell-record viewer (coming in F2): a log of what you have disclosed and when.
- The Open, Convenient, Locked, and In-person postures: these require the
  grant system, coming in F2.
- Your own estate is never listed as a peer; you cannot share with yourself.

### A word on privacy

MOOTx01 is built around the principle that a secret told is not a secret.
Federation does not change that. It decides *who counts as told* and *for how
long*, and it keeps a faithful record. It cannot prevent a person from
remembering what they saw. Balanced is the right first mode because it limits
both what crosses (facts and fields, not full text) and for how long (one
session). Choose the tightest posture that meets your need.
