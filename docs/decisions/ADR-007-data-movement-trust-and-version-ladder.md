---
status: decided
question: How does mass data movement, entity privacy, the open-core split, and release sequencing get structured?
authors: MOOTx01 maintainers
date: 2026-06-09
relates_to:
  - docs/reference/GENIUSLOCUS_ARCHITECTURE_SPEC.md
  - docs/reference/VAULTKIT_INTERFACE.md
supersedes: none
context:
  - Scope spans VaultKit, the GeniusLocusKit migration surface, access-surface transport, the edition split, and release sequencing.
  - Consolidates four linked decisions into a single roadmap-bearing record.
---

# ADR-007 — Data Movement, Privacy Tiers, and the Version-Gated Commitment Ladder

## Summary

Consolidates four linked decisions: (1) all product-side mass data movement
lives in VaultKit behind a single adapter + intermediate-representation
pattern; (2) entity privacy is a three-tier model whose controls scale with
volume × sensitivity, not absolute secrecy; (3) the open-core split never
paywalls trust or exit; (4) releases follow a version-gated commitment
ladder — named deliverables gate the next paid version's launch.

## Decision 1 — Data movement consolidates in VaultKit

VaultKit is the home of mass import ("arrive faithfully") and mass export
("leave freely"), for both human-freeform vaults (Markdown trees) and
programmatic external memory tools that speak MCP.

- **Adapters are pure transforms**: `tool format ⇄ NoteIR`. No process
  spawning, no network I/O inside the kit. One adapter type per external
  tool. The adapter protocol is public so third parties can contribute
  adapters.
- **NoteIR is the single interchange representation**, extended to full
  fidelity: facts, hierarchy, and link relations as first-class. Its
  serialized form is a versioned canonical JSON document — the JSON is the
  payload, never a per-tool mapping DSL.
- **Transport lives at the access surface** (resident daemon), consistent
  with spec invariant I-13 (cross-boundary access is an access-surface
  concern, not a substrate concern). The Community Edition transport is
  loopback-only (stdio + local HTTP); remote transports are Enterprise
  Edition territory.
- The legacy flat-corpus import verb on the composition kit is **retired**,
  superseded by the adapter → bridge path, which provides idempotent
  re-import, link reconstruction, and per-entry provenance that the flat
  capture loop lacked. The substrate keeps only orchestration (parallel-run
  routing) and recall-based migration verification. The in-product migration
  fidelity benchmark keeps its reference-corpus type, now fed by a
  projection from NoteIR.
- Measurement tooling (timing, divergence, proxy/mirror instrumentation)
  remains a separate standalone tool sharing no code with the product
  pipeline and shipping in no product binary.

## Decision 2 — Privacy tiers and the proportional-friction security model

Three tiers, stored as entity bitmap bits (per the no-Bool-fields rule):

| Tier | AI recall | Bulk operations (mass export, mirror) |
|---|---|---|
| **Normal** | Free | Free; audit receipt written |
| **Private** | Free | Requires owner-held key at execution time |
| **Secret** | Excluded by default; explicit per-item request only | Never rides bulk channels |

Threat-model rationale:

- The AI read path is unclosable by design — a knowledge engine's content
  is readable by the AI serving it, so trickle egress through the token
  layer cannot be prevented, only **metered and observed**. The protected
  asset is the *fidelity, speed, and silence* of bulk egress.
- Therefore: **friction proportional to volume × sensitivity.** Trickle is
  free; the firehose has a gate.
- The owner key is a **human-presence check**, not encryption theater: an
  agent session cannot know a passphrase or press a biometric prompt, so
  the gate cleanly separates "the AI may read my estate to serve me" from
  "only the human may bulk-move the estate." This neutralizes the
  agent-driven mass-exfiltration class (including prompt injection) without
  adding friction to normal use.
- **Every bulk operation writes an audit receipt** (what left, where, when,
  how many) into the existing substrate audit trail. Leaving is easy;
  leaving is also attributable.
- Application-level gates defend the *legitimate install* against the
  confused deputy (injected agent, bad config, careless automation). They
  do not — and no application control can — defend against an attacker who
  executes code on the machine. That boundary is honest in the docs:
  OS file permissions and full-disk encryption are the floor.
- **Secret tier must additionally survive a hostile local process**: its
  content is encrypted at rest under a user-held key (enclave- or
  passphrase-derived, never on disk). This is the only layer that survives
  binary substitution or direct database reads, and it is what makes the
  tier's name honest in an open-source codebase anyone can fork.
- Genuineness is checkable, not enforced: signed and notarized releases,
  published SHA-256 checksums, and (roadmap) reproducible builds and build
  attestations. A fork can strip every gate; it cannot sign as us. External
  tool binaries registered as import/export endpoints are identified at
  registration (path, version, hash shown to the user, then pinned) with
  verification tiers deepening over time.
- Imported content is an injection channel into future AI context. All
  migrated entries carry **source provenance** so downstream consumers can
  treat externally-originated content at a lower trust tier than
  user-confirmed content.

## Decision 3 — Open-core split: never paywall trust, never paywall the exit

The dividing line: **anything that protects the individual owner or lets
them arrive/leave is open core; anything that protects an organization or
crosses machine boundaries is commercial.**

Open core (Community Edition): privacy tiers and their enforcement, mass
import, export-my-data in both human and programmatic form, the owner-key
gate, audit receipts, secret-tier encryption at rest, binary
identity-pinning, recall-volume metering, the adapter protocol and shipped
adapters, loopback transport.

Commercial (Enterprise Edition): remote transports and authenticated
remote endpoints, federation and cross-estate access, standing mirror /
shadow channels to external systems, organization policy enforcement
(centrally administered export approval), compliance-grade audit export
and retention, team estates and SSO.

The on-ramp (import) and the exit (export) are deliberately free: an
open-core memory product's most credible trust claim is that leaving is
easy.

## Decision 4 — The version-gated commitment ladder

Releases carry **named deliverable commitments, version-gated**: "by v2"
means *delivered before v2 launches*, not "scheduled for v2." The rationale
is commercial integrity: **the paid upgrade event is v2** — customers are
asked to pay again at v2, and the v2 launch is therefore gated on a clean
v1 ledger. Features promised under the v1 purchase ship as free v1.x
updates and are never withheld as v2 selling points.

**v0.9 beta — shapes frozen** (everything user data accumulates against):
1. Privacy tier bits in entity bitmaps, settable via the ARIA surface
2. NoteIR full-fidelity extension + versioned canonical JSON serialization
3. Adapter protocol final; first programmatic import adapter working
   end-to-end through the bridge; legacy flat import verb retired
4. Bulk-operation receipt format, written from day one
5. Mapping/transport split in place; CE loopback-only transport

**v1.0 gold — trust behavior delivered:**
6. Owner-key gate on private-tier bulk operations
7. Programmatic export-my-data (exit promise real in both forms)
8. External-tool registration consent surface (identity shown, then pinned)
9. Tier enforcement complete (secret excluded from default recall and all
   bulk channels; receipts on everything)
10. Documentation states the security floor honestly, with release
    signature-verification instructions

**v1.x — committed deliverables, free to v1 owners, ALL complete before
any v2 launch:**
11. Secret-tier encryption at rest under a user-held key, including the
    recovery story and the search-over-encrypted-content decision
12. Binary verification tiers (silent code-signature verification for
    signed tools; trust-on-first-use hash pinning with change notices for
    unsigned tools)
13. Recall-volume metering surfaced on the daemon status/dashboard surface
14. Second programmatic adapter (proves the adapter protocol generalizes —
    a schema claim made at beta)

**v2 — the paid upgrade:** new commercial territory (remote, federation,
org policy) on a clean ledger. The launch gate is checkable: four named
deliverables, not a judgment call.

## Consequences

- v0.9 planning reduces to three schema-and-plumbing waves:
  tier bits + IR extension; adapter/bridge consolidation + verb
  retirement; receipts.
- The composition-kit public API loses the legacy import verb — tracked
  through specs, interface docs, and the MCP tool surface as a single
  change set.
- New security-sensitive surfaces (registration consent, key gate,
  transport) receive security review at design time, not post-hoc.
- The roadmap document, when built, sources its v1.x and v2 sections from
  this ADR's ladder.
