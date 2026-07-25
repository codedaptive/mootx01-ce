---
title: The Road Ahead for MOOTx01
status: active-roadmap
audience: public
updated: 2026-07-24
---

# The Road Ahead for MOOTx01

AI keeps getting smarter. It still forgets.

Close a conversation, change models, or move to another device, and too much
useful context disappears. You repeat the decisions, rebuild the plan, and pay
another powerful model to rediscover work that was already done.

MOOTx01 is building the layer that changes that.

> **The frontier intelligence is rented. The memory is yours.**

Our goal is not to trap you inside one assistant. It is to give Claude,
ChatGPT, Codex, Apple Intelligence, local models, and the tools still to come a
durable memory they can use—with you in control of what is remembered, what is
shared, and what stays private.

This roadmap is the journey from one local memory estate to personal agentic
memory, controlled collaboration, and optional server scale.

Roadmap items are direction, not shipped promises. A feature is shipped when it
appears in a tagged release and its guide documents what actually works.

## Today — memory that outlives the conversation

MOOTx01 already gives supported AI tools a local memory estate through ARIA and
the Model Context Protocol.

It can remember decisions, connect related ideas, preserve history, search
across sessions, and help a new conversation pick up where the last one ended.
The model can change. Your memory does not have to.

And because MOOTx01 is more than a chat transcript, you can inspect its facts,
links, journals, trust state, topology, and audit history instead of accepting a
black box.

## Version 1.0.x — move your knowledge today

MOOTx01 1.0.x already ships an agent-directed, on-demand round-trip between
your estate and normal Markdown vaults:

- export eligible memories into a vault that Obsidian can open;
- import an existing Obsidian or Markdown vault into MOOTx01;
- inspect drift and apply added or modified notes through reconciliation;
- preserve stable identity, links, tags, sensitivity, exportability, and
  provenance across the round-trip;
- use default vault output that is also a superset of Google's Open Knowledge
  Format (OKF) v0.1.

You do not need to learn an internal command language. Ask a connected AI agent
to export your eligible memories, import an existing vault, or reconcile the
changes in a vault you have edited.

This workflow is bidirectional when you or your agent initiates it; it is not
yet a continuously running synchronization service. Vault deletions are
reported and never automatically erase estate memories.

## Version 1.1 — your Apple devices become memory assistants

The next chapter is MOOTx01-App: one native product across iOS, iPadOS, and
macOS.

### Ask what MOOT remembers

The new Review Center will turn a growing memory estate into something you can
understand at a glance:

- **MOOT Dashboard** — what your estate remembers now.
- **Morning Review** — the context, open work, and reminders that matter today.
- **End-of-Day Review** — what changed, what was decided, and what still needs
  attention.
- **Weekly Memory Review** — memories that may be stale, duplicated,
  contradicted, or ready to retire.

MOOTx01 will suggest. You remain in control. Memory changes stay inspectable
and reversible.

### Put Apple Intelligence to work

On supported devices, Apple Intelligence gives MOOTx01 a private,
low-marginal-cost worker for everyday tasks:

- summarize recent work;
- extract facts and people;
- classify and connect memories;
- prepare your daily review;
- compare bounded research results;
- draft the handoff to a more powerful model.

That means routine agentic work does not need to become another frontier-model
API transaction. Exact MOOT computation handles what should be exact. Apple
Intelligence handles suitable everyday language work on device. Frontier models
remain available for deep research and difficult reasoning.

Apple Intelligence availability depends on supported hardware, software,
language, region, and user settings. MOOTx01 will provide a useful fallback
when the on-device model is unavailable.

### Make Obsidian continuous

Version 1.1 will build on the shipped, on-demand vault workflow with an
optional resident mode that automatically maintains eligible memories between
MOOTx01 and an Obsidian vault.

It will watch both sides, resynchronize after missed changes, surface conflicts
and blocked items, and keep the estate—not the vault—as the authority. Private,
restricted, secret, and non-exportable material will remain outside automatic
exchange.

### One memory, many models

We are building a vendor-neutral Work Packet: a durable record of an objective,
the sources used, the claims produced, what remains uncertain, and what should
happen next.

That unlocks our flagship demonstration:

1. Claude researches a topic and files its findings in MOOTx01.
2. ChatGPT or Codex researches independently and files another result.
3. Apple Intelligence or another local model finds both.
4. It compares the evidence, preserves the disagreements, and writes a linked
   synthesis.
5. Either frontier model can return later and continue from that work.

No copied chat transcript. No vendor-owned memory silo. No pretending that two
models agreed when they did not.

We call it **Three Minds, One Memory**.

### Take your estate with you

Optional iCloud Sync will keep eligible memories available across supported
Apple devices while every device retains its own local estate.

Sync will be off by default. Restricted and Secret memories stay on device
**by default**; keychain-authorized per-tier opt-in available.
You choose when continuity is worth crossing the device boundary.

### A home on every other platform

Windows and Linux users will not be left watching through an Apple-shaped
window.

The `moot-mgr` web app will provide the Review Center, Work Packet lineage,
estate health, and approved memory-management actions through the local
resident host. The native MOOTx01-App is the Apple experience. The `moot-mgr`
web app is the cross-platform experience. Both speak the same memory language.

## Version 1.2 — your MOOT can meet another MOOT

Personal memory is only the beginning.

Federation will let explicitly paired estates exchange eligible memories and
Work Packets during bounded, time-limited sessions.

You will be able to see:

- who you paired with;
- what is allowed to cross;
- how long the session lasts;
- where a finding came from;
- when sharing has ended.

Federation is not a central cloud that takes ownership. It is a controlled
meeting between estates that remain independently owned.

Version 1.2 also extends the local-agent idea beyond supported Apple devices:

- local-model workers for Windows, Linux, Mac, and servers;
- scheduled memory reviews and housekeeping;
- private research-result comparison;
- no automatic destructive memory cleanup.

## Version 1.3 — PGlite, pgMOOT, and Postgres anywhere

MOOTx01 is local first. Version 1.3 brings that idea to two very different
Postgres environments.

**PGlite** will explore a portable Postgres runtime in WebAssembly: a path to
zero-install MOOTx01 demonstrations, richer offline web experiences, and
private Work Packet exploration directly in the browser.

**pgMOOT** is our working name for an optional PostgreSQL deployment and
computation layer for larger estates, teams, resident jobs, backup and
recovery, and workloads that earn the cost of server-side execution.

PGlite is not a multi-user server. pgMOOT is not a replacement for the local
product. Neither will become a requirement for MOOTx01-App, Apple
Intelligence, iCloud Sync, or peer Federation.

The contract remains the same:

> More scale does not create a new owner of your memory.

## The path in one view

| Release | What changes for you |
|---|---|
| **1.0.x today** | Your AI can remember beyond one conversation and move eligible knowledge through Obsidian, Markdown, and OKF-compatible vaults |
| **1.1** | MOOTx01-App brings native agentic memory to iPhone, iPad, and Mac; `moot-mgr` carries it to other platforms; optional automatic Obsidian synchronization builds on the shipped vault workflow |
| **1.2** | Local agents and explicitly paired estates can collaborate safely |
| **1.3** | PGlite brings portable Postgres to the web; pgMOOT adds optional PostgreSQL server scale |

## Follow the build

MOOTx01 is being built in public because durable AI memory needs more than a
good demo. It needs inspectable code, negative tests, privacy boundaries,
repeatable benchmarks, honest release notes, and people willing to challenge
the design.

You can:

- watch or star the repository;
- try the current release;
- test the 1.1 beta on a disposable or backed-up estate;
- report what breaks;
- build with the SDK packages;
- challenge a claim with evidence;
- help us make model-independent memory ordinary.

The AI market will keep changing. That is the point.

**Your memory should survive the change.**
