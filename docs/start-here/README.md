---
title: "Start Here"
subtitle: "Orientation guides for getting into MOOTx01"
author: "MOOTx01 maintainers"
date: "2026-06-14"
---

# Start Here

Three orientation guides at three depths. Pick the one that matches
why you arrived.

## The guides

**[`INSTALLING_MOOTX01.md`](INSTALLING_MOOTX01.md)** — installation
guide. What `mootx01 install` sets up, how the resident background daemon
works, how your AI clients connect (shared HTTP daemon vs per-client stdio),
install flags, how to turn monitoring on, and the edge cases you'll hit.
Start here if you're setting MOOTx01 up for the first time or troubleshooting
a client connection.

**[`SUBSTRATE_FOR_USERS.md`](SUBSTRATE_FOR_USERS.md)** — plain
language. What MOOTx01 is, what the machinery does under the floor,
and what you can trust. Names a couple of techniques (locality-
sensitive hashing, CRDT) so you know they are not made up, leaves
the rest to the technical docs. No prerequisites; written for a
non-technical reader who wants to know what they are trusting.

**[`SUBSTRATE_FOR_DEVELOPERS.md`](SUBSTRATE_FOR_DEVELOPERS.md)** —
for developers evaluating MOOTx01, embedding it in an application,
or integrating with ARIA. Thirteen short sections, one per layer.
Names the technique and points at the kit. Roughly two minutes per
section. Reading this is enough to build on top of MOOTx01 with
confidence; it is not enough to maintain the substrate itself.

**[`SDK_QUICKSTART.md`](SDK_QUICKSTART.md)** — the hands-on companion to the
developer guide: add the substrate to a project and run the core write→read
loop (open an estate, capture a memory, recall it), in Swift and Rust, with the
modular module map. The example is lifted from the kit tests, so it works as
written. Read this when you're ready to integrate, not just evaluate.

**[`SUBSTRATE_FOR_MAINTAINERS.md`](SUBSTRATE_FOR_MAINTAINERS.md)** —
for port maintainers, contributors, and engineers reading the kit
code. Same thirteen layers as the developer guide, but each section
answers three questions: what it is, why we chose it, where it
lives in the code. Adds failure modes, performance numbers, and
conformance notes the developer guide omits.

## Quick onboarding & AI-assisted install

**[`END_USER_EXPLAINER.md`](END_USER_EXPLAINER.md)** — the shortest
plain-language explanation for a non-technical end user: what MOOTx01 is
(local memory for AI), what gets installed, and what the ports and
dashboard are. Read this first if you just want to understand it.

**[`INSTALL_SURFACE.md`](INSTALL_SURFACE.md)** — the install fact sheet for
humans and AI assistants: default addresses, the product-install flow, the
platform matrix, expected commands, environment variables, verification,
and uninstall. The source of truth for what a product install does.

**[`OBSIDIAN_VAULT.md`](OBSIDIAN_VAULT.md)** — the operational guide for a
normal Markdown/Obsidian vault: export scopes, background import jobs, the
hidden drift manifest, dry-run reconciliation, explicit resync, deletion
behavior, and the filesystem security boundary.

**[`AI_START_HERE.md`](../../AI_START_HERE.md)** — at the repo root, for an
AI assistant a user asks to "explain and install this." Mission, safety
rules, a platform-aware install flow, verification, and troubleshooting, so
an assistant gives a good first experience without improvising.

**[`AI_INSTALL_MANIFEST.json`](AI_INSTALL_MANIFEST.json)** — the machine-readable companion to the
install fact sheet: install commands, ports, verification, adapter locations, and the files an
install may touch, as structured JSON for an AI agent to parse before acting.

## Reading order

Pick one. They are not a series; each is complete on its own.
The developer and maintainer guides derive from the same shared
substance — the maintainer version is more detailed, not different
in shape.

After reading the guide that matches your role, the next step
depends on what you came for:

- **Build on top of MOOTx01** → [`SDK_QUICKSTART.md`](SDK_QUICKSTART.md) for the
  hands-on open→capture→recall loop, then [`../reference/`](../reference/) for the
  kit-level specs you integrate against.
- **Operate the installed product** → [`INSTALLING_MOOTX01.md`](INSTALLING_MOOTX01.md),
  [`OBSIDIAN_VAULT.md`](OBSIDIAN_VAULT.md), and
  [`../../apps/moot-mgr/README.md`](../../apps/moot-mgr/README.md).
- **Maintain or port the substrate** → [`../engineering/`](../engineering/)
  for the cookbook and methodology, then the
  [`develop/1.1.x` decision records](https://github.com/codedaptive/mootx01-ce/tree/develop/1.1.x/docs/decisions)
  for the evolving record of kernel and architecture selections.
- **Understand the design rationale** → [`../concepts/`](../concepts/)
  for the topology, the canon, the case studies, and the paper.

## Conventions

These files are evergreen. They do not carry version stamps or
date suffixes because the substance is meant to stay correct as
the substrate evolves. Material changes happen by rewriting in
place, not by versioning.
