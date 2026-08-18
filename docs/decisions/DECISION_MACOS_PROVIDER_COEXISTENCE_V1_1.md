---
title: One Resident Provider Across MOOTx01 macOS Installations
status: accepted-roadmap-design
target: 1.1
date: 2026-08-18
audience: community
---

# One Resident Provider Across MOOTx01 macOS Installations

MOOTx01 1.1 will allow the command-line distribution and a signed native
MOOTx01 edition, including Pro or Enterprise editions, to coexist on the same
Mac without creating separate default estates or competing background servers.

This is the public cross-edition contract. Native-edition implementation,
private capabilities, signing topology, and internal migration mechanics are
owned by their edition and are deliberately outside this document.

## Stable behavior

- There is one logical resident service and one writable default estate.
- If only the command-line distribution is installed, its resident provider
  serves the estate.
- If an approved, compatible native-app provider is installed, the machine may
  hand ownership to that provider without moving clients to another estate.
- Installing or updating `mootx01` while a healthy native-app provider is
  active installs the CLI and client configuration but does not start a second
  daemon.
- The CLI remains a client and management surface regardless of which signed
  provider currently owns the service.
- Install order never authorizes a downgrade, a second writer, or a new default
  estate.

## Version mismatch

Compatibility is not inferred from the product version printed in About or
`mootx01 --version`. Providers negotiate an authenticated management-protocol
range and separately evaluate the normal service contract, estate schema, and
required capability revisions.

Provider builds also carry an authenticated monotonic release generation
shared by the command-line and native packaging forms. It prevents an older
provider from replacing a newer one even when their display-version strings or
outer app versions differ.

- A newer compatible provider may replace an older provider through an
  attended, crash-recoverable handoff.
- An older candidate never displaces a newer running provider.
- If the providers share no safe management revision, the running provider
  remains and the older component must be updated.
- If the candidate cannot read the estate schema, it does not start.
- A mismatch never falls back to an unauthenticated port, direct database
  access, or an empty estate.

The CLI reports which component needs updating without exposing another
edition's private capability inventory.

## Handoff contract

A provider swap is cooperative:

1. authenticate the running source and proposed target;
2. prepare the target without starting it;
3. stop new writes, drain, checkpoint, and close the source estate;
4. issue a signed, expiring, one-use handoff authorization;
5. prove the source exited and released the estate lock;
6. open the same estate with the target and verify its identity;
7. publish target readiness before retiring stale activation state.

If the sequence cannot finish safely, the system rolls back to the source or
enters an explicit recovery-required state. It never guesses.

## Installer responsibilities

The Community installer and CLI need awareness of this contract even though
they do not contain another edition's implementation:

- authenticate an existing resident provider before deciding what to start;
- treat a compatible native-app provider as the service owner and install the
  CLI in client-only mode;
- stage any standalone recovery provider disabled while another owner is live;
- expose truthful status: active owner class, compatibility disposition, and
  required update direction;
- provide an explicit repair path after an app is removed, but activate a
  standalone provider only after proving no owner or handoff remains;
- preserve the estate, receipts, backups, and credentials on uninstall.

An explicit future command may let a user switch back to standalone ownership.
Ordinary `install` and `upgrade` do not imply that switch.

## Edition boundary

This document is SHARED behavioral awareness and may flow to Community Edition.
It intentionally does not specify native-app bundle identifiers, private
capabilities, credentials, provider preference encoding, or edition-owned UI.
Those remain in the owning edition's documentation and implementation.
