---
title: MOOTx01 — User Guide
version: v0.1
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
**private iCloud**. It syncs your memories, their links, knowledge-graph facts,
and diary entries; derived/rebuildable data isn't synced. Conflicts resolve
automatically (most-recent-edit wins for memories; facts and diary only add).

Sync stays off until the app is set up with an iCloud container and you're
signed into iCloud. Until then the app works fully on a single device; it simply
doesn't replicate.

---

## Your privacy

- Your estate is **encrypted on disk**.
- **Only public memories ever leave the device** — through Spotlight, the LAN
  server, or the assistant. Private, Restricted, and Secret memories don't.
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
