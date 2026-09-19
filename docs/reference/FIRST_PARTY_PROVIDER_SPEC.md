---
title: FirstPartyProvider Specification
version: 1.1.0
status: accepted-1.1-target
date: 2026-09-11
description: Behavioral contract for the independently versioned authenticated native ARIA provider.
spec_type: protocol
authors: MOOTx01 maintainers
relates_to:
  - ARIA_MCP_SPEC.md
  - FIRST_PARTY_PROVIDER_INTERFACE.md
  - ../decisions/DECISION_MOOTX01_FIRST_PARTY_AUTHENTICATED_WIRE_2026-08-16.md
---

# FirstPartyProvider Specification

## 1. Authority and scope

`FirstPartyProvider` is the fixed, authenticated native-application ARIA
surface. It is a peer of public MCP discovery, not a forwarding alias for the
public catalog. This document owns its operation meaning and admission
invariants. [FIRST_PARTY_PROVIDER_INTERFACE.md](FIRST_PARTY_PROVIDER_INTERFACE.md)
owns names, JSON shapes, vectors, and package symbols.

The provider is independently versioned at `1.1.0` and supports ARIA semantic
version `v2`. Public MCP catalog selection, including build capability flags,
must not alter its operation names, schemas, discovery record, or capability
digest.

## 2. Admission and authority

Only a request admitted on the existing authenticated first-party lane may use
this provider. Its exact request endpoint is `POST /mcp/first-party`.
Authentication, descriptor binding, message MACs, replay
protection, and endpoint pinning remain governed by
[DECISION_MOOTX01_FIRST_PARTY_AUTHENTICATED_WIRE_2026-08-16.md](../decisions/DECISION_MOOTX01_FIRST_PARTY_AUTHENTICATED_WIRE_2026-08-16.md).
This contract neither changes those rules nor grants Apple-family admission to
a generic HTTP caller.

The authenticated composition root supplies the caller, selected estate, and
policy context. The catalog accepts no caller or `estate_id` argument. A
request therefore cannot substitute a public selected-v2 session or direct a
call at another estate through the stable operation schema.

## 3. Operations

The 1.1.0 operation set retains the same fixed 26-operation snapshot of the native app's
semantic needs. Capture followed by read is a required discriminator, but not
the roster boundary.

| Capability | Operations |
|---|---|
| `memory.capture` / `memory.read` | `moot_file_memory`, `moot_memory_get`, `moot_memory_list`, `moot_memory_search` |
| `memory.mutate` / `memory.connect` | `moot_update_memory`, `moot_withdraw_memory`, `moot_erase_memory`, `moot_confirm_memory`, `moot_move_memory`, `moot_link_memories`, `moot_review_tunnel` |
| `fact.capture` / `fact.read` / `fact.retire` | `moot_file_fact`, `moot_fact_search`, `moot_retire_fact` |
| `journal.read` / `recall.precise` | `moot_read_journal`, `moot_recall_precise` |
| `cognition.review` | `moot_list_lenses`, `moot_lens_keystones`, `moot_lens_theme_weather`, `moot_lens_cohesion`, `moot_lens_contradiction`, `moot_lens_drift` |
| `estate.inspect` | `moot_estate_status`, `moot_drain_status`, `moot_rebuild_status`, `moot_timing_report` |

Every operation reuses typed ARIA semantics; the provider does not define a
second privacy, storage, or authorization model.

`moot_fact_search` accepts `source_id_exact` and `subject_exact` as optional,
case-sensitive equality filters. They compose conjunctively with the existing
search fields. Source and subject equality are applied by the estate query,
before authorization and result limiting. `source_id_exact: ""` deliberately
selects active sourceless facts; omission leaves source ownership unconstrained.
This distinction lets a miner inventory only facts under its own source-anchor
drawer, or narrowly inspect sourceless facts for adoption, without selecting a
different miner's rows for retirement.

`moot_memory_search` and `moot_recall_precise` accept only one caller-selected
filter value: `exportable`. It narrows the effective server policy. The provider
keeps the server-supplied sensitivity ceiling and applies exportable-only recall
when either the server policy or the caller requests it. A caller therefore
cannot use the argument to widen sensitivity or export authority.

The 1.1 mutation contract accepts the native app's established field names:
`id` for memory update, withdrawal, erasure, confirmation, move, and fact
retirement; `confirmed` for erasure; `location` for a move's destination room;
and `verdict` for tunnel review. The original stable names remain accepted as
mutually exclusive aliases. Translation occurs once in the authenticated
provider executor, before the typed lower service. It does not alter caller,
estate, sensitivity, or exportability context. An omitted move `wing` retains
the authorized target's stored wing; a default or client-side lookup is not an
acceptable substitute.

## 4. Compatibility invariants

The provider advertises a `contract_version`, `aria_supported_version`, ordered
capability list, and SHA-256 capability digest. The digest is over its fixed
operation definitions, using the shared canonical v2 digest algorithm. A
compatibility mismatch must be detected before estate mutation.

The exact `1.0.0` compatibility tuple remains admitted for the original 1.0
argument grammar. A call that claims 1.0 while supplying a 1.1-only field is
rejected before provider dispatch. Initialization advertises only the current
1.1 discovery record and digest.

Adding an operation or optional surface field is a minor contract version
change. Changing or removing an operation name, required argument, schema
meaning, or result guarantee is a major version change. Internal runner
refactoring that preserves the catalog and result contract is a patch change.

## 5. Boundaries and limitations

The provider retains the existing JSON-RPC `tools/list` and `tools/call`
envelopes. Its fixed 26-operation catalog does not include Community tools;
the authenticated endpoint composes the frozen Community namespace beside it
under the separate Community contract. ProductDock routing, vault and licensed
features, WorkPacket replacement, a direct-method transport, a universal
broker, and a custom-app enrollment provider remain outside this provider.
ProductDock remains a separate licensed and stateful connection.

This Swift contract and its vectors prepare the later Rust runtime work; they
do not claim a Rust runtime implementation or runtime parity. Native UI and
biometric protected-preference changes are also outside this contract.

## Changelog

### 1.1.0 -- 2026-09-11

Retained the 26-operation roster while adding exact source/subject fact
inventory and caller-requested exportable narrowing for memory search and
precise recall. Added deterministic provider-boundary acceptance of the native
mutation grammar, including stored-wing retention for room-only moves. The
provider intersects the new recall request with its server-owned policy and
retains 1.0 admission for the original grammar.

### 1.0.1 -- 2026-09-10

Corrected the changelog to describe the complete 26-operation stable peer and
named the existing authenticated endpoint.

### 1.0.0 -- 2026-09-10

Established the fixed 26-operation `FirstPartyProvider` peer, independent
version discovery, digest rule, authority boundary, and compatibility policy.
