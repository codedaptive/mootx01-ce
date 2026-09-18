---
status: proposed
question: Should drawer writes land provisional and require an explicit logged review step before becoming system-returnable?
authors: MOOTx01 maintainers
date: 2026-05-24
relates_to:
  - docs/decisions/DECISION_FEDERATION_SHARING_MODEL_2026-05-21.md (Appendix A.2 provisional soft-encryption)
  - docs/reference/NEURONKIT_SPEC.md (§4.8 enforceWritePolicy, the first automated reviewer)
  - GeniusLocusKit/Sources/GeniusLocusKit/Verbs/VerbSurface.swift (capture and expunge verbs)
  - GeniusLocusKit/Sources/GeniusLocusKit/Audit/UnifiedAuditLog.swift (the chain provisional events land in)
supersedes: none
context:
  - A write can be untrusted at the moment it arrives; the substrate needs to accept it without making it real.
  - The substrate is event-sourced, so quarantine must live in the audit chain, not a side table.
  - Write-policy enforcement, human compliance review, and third-party audit all want an addressable review point.
---

# Decision: Provisional Drawer Lifecycle

## 1. Summary

This document defines a commit lifecycle for drawers. A write does not become real the moment it lands. It lands provisional, an explicit logged review step approves or rejects it, and only an approved write is system-returnable. A rejected write is expunged. The lifecycle is `provisional -> committed | rejected(expunged)`, every transition is an entry in the audit chain, and the dwell time between landing and resolution is provable from the chain.

This is a substrate capability, not a feature of any one consumer. Write-policy enforcement is its first automated reviewer. A human compliance officer, or a third-party auditor, is another. The branch and copy-on-write work has the same shape and may rest on the same primitive.

The motivation is honesty under audit. A synchronous in-process gate that decides yes or no is a black box: it ran, it said yes, trust us. A provisional stage is an addressable point in a logged pipeline. An auditor can be inserted at it without touching the write path, and the record afterward answers what was attempted, when, who approved or rejected it, and how long anything questionable persisted, from the log rather than from assurance.

These are proposed positions, not ratified canon. Open items are in section 9.

## 2. The problem it solves

A write can be untrusted at the moment it arrives. An agent may try to capture a secret. A migration may import a malformed row. A federation peer may push content that has to be checked before it counts. The substrate needs a way to accept the write without making it real, hold it where it cannot leak or propagate, and resolve it by an explicit decision that is itself recorded.

The naive alternatives both fail. A synchronous gate that blocks capture until a check passes couples the caller to the checker and is unauditable after the fact. A side table that holds unreviewed writes off to one side creates a second, unaudited store and a write path that bypasses event sourcing, which is the property the substrate is built to guarantee. Provisional lifecycle is the third option: the write enters the event-sourced chain immediately, flagged, and a later logged step resolves it.

## 3. The model

A drawer is in one of three lifecycle states.

Provisional. The write has landed. It exists in the substrate and its arrival is recorded in the audit chain as a provisional entry. It is not system-returnable: no recall, no bitmap evaluation, no sync, no index surfaces it. It occupies the chain but not the readable estate.

Committed. A logged approval step has promoted the provisional drawer. From this point it is an ordinary drawer, system-returnable, indistinguishable in behavior from any drawer written before this lifecycle existed.

Rejected. A logged rejection step has resolved the provisional drawer by expunging it, using the existing expunge verb. The drawer never became returnable. The chain retains the provisional entry, the rejection decision, and the expunge, so the attempt and its refusal are both permanent facts.

The lifecycle is one-directional: `provisional -> committed` or `provisional -> rejected(expunged)`. There is no path back to provisional from either terminal state. This mirrors the one-way shape the automaton already uses for the secret latch and the tombstone terminal state.

## 4. Why it lands in the chain, not a side table

The substrate is event-sourced. Every write is an append to an ordered, hash-linked audit chain, and that chain is what makes the system tamper-evident and mergeable. Provisional lifecycle preserves this by putting the provisional write, the review decision, and the resolution all in the chain as a sequence of entries.

The alternative, a temp table holding unreviewed writes off to the side, was rejected. It creates a write path the audit chain does not see, which is a hole in the guarantee that nothing happens without an audit row. It also means rejected writes vanish without a trace, when a security review may want exactly the opposite: a record that an agent attempted to write a secret forty times. In the chain-based model that record exists by construction.

The cost of the chain-based model is the one real engineering expense of this whole design, named plainly in section 6: every reader must learn to exclude provisional rows.

## 5. The audit story

Three entries tell the complete story of a provisional write.

At T0, the provisional entry: the write landed, marked provisional. At T1, the review entry: a reviewer approved or rejected, named in the entry. At T2, the resolution entry: a promotion to committed, or an expunge on rejection. The three are ordered and tamper-evident in the chain.

This yields a measured dwell time, T0 to T2, not an estimate. For a secret that slipped in and was rejected, the substrate can state precisely: present in provisional state for some interval, never system-returnable, expunged, with the chain proving each claim. That is a stronger story than a gate that merely says it blocked the write, because it is auditable after the fact by a party that does not trust the gate.

This is also why provisional lifecycle is a foundation for deeper audit rather than a feature of it. The review step is an addressable point. A third-party auditor reads provisional entries and records approve or reject; that decision lands in the chain. The substrate does not need to know whether the approver is the write-policy function, a human compliance officer, or an external auditing service. They share one promote-or-reject interface.

## 6. The one real cost: read-boundary exclusion

While a drawer is provisional it must not be system-returnable, and that is a cross-cutting change. Every path that surfaces drawers has to exclude provisional rows: recall, the bitmap evaluator, sync, any index, any fingerprint aggregation. The exclusion is a single predicate, committed-only, applied at the read boundary, but it has to be applied everywhere a read happens.

This is the load-bearing cost and it should not be understated. It is the reason provisional lifecycle is a substrate capability with substrate-wide reach, not a small addition. The design is worth the cost because the exclusion is uniform, one predicate, not scattered special-case logic, and because it buys the entire model: quarantine before trust, auditable review, and provable dwell time.

## 7. Soft encryption of provisional data

Provisional rows are soft-encrypted under a system-generated ephemeral key, regardless of the estate's encryption mode, because provisional means not yet trusted. This is the Mode 1.5 behavior named in the federation decision (Appendix A.2). On approval the row is decrypted and written to the committed tables in whatever the estate's encryption mode is. On rejection it is expunged while still encrypted, so a rejected secret is never readable in raw form, even during its provisional dwell.

This should be the default for the provisional tray even in an unencrypted (encryption mode 1) estate, because the point of provisional is that the data has not yet earned trust. The threat model is stated honestly: the ephemeral key is system-held and auto-applied, so this is hygiene, not hardened custody. It protects against the provisional data leaking through the normal read, sync, and index paths before review. It does not protect against an attacker who already owns the machine and the system key. Hardened custody is the threshold and decay territory of the federation document's custody modes, not this.

A provisional row can be flushed only on the hardware that ingested it, because the ephemeral key is device-local. An unreviewed write therefore cannot be read or promoted on another device. Unreviewed data is pinned to its origin machine until resolved.

## 8. Consumers

Write-policy is the first automated reviewer. The NEURONKIT_SPEC §4.8 enforceWritePolicy function decides whether a write is allowed (rejecting raw transcripts over threshold, reasoning dumps, detected secrets, oversized code). Rather than a synchronous gate before the row is written, write-policy becomes the reviewer that resolves a provisional write: the capture lands provisional, write-policy evaluates it, and the result is a logged promote or reject. This removes the coupling between the caller and the checker and makes every policy decision an audit fact.

Human and third-party review is the second consumer. The same promote-or-reject interface accepts a human compliance officer or an external auditing service. This is the FedRAMP-relevant payoff: the regulated edition can insert deeper review at the provisional stage and report on the provisional tray, built on the open-core primitive.

Branch and copy-on-write derivation has the same shape. Exploratory writes that are not real until promoted are conceptually provisional drawers. The branch work (NEURONKIT_SPEC §4.3) may rest on this primitive rather than introducing a second provisional mechanism. This is noted as a relationship, not yet a commitment; see open items.

## 9. Open items

Capture return contract. The capture verb today returns a Drawer (VerbSurface.swift). A provisional write cannot return a committed Drawer, because it is not yet real. The verb must return a provisional handle or a receipt instead, which is a change to the most-used verb in the substrate. Whether capture always goes provisional, or only when a reviewer is registered, is the key sequencing decision and is not yet made.

Relationship to branching. Whether branch and copy-on-write derivation actually shares this primitive, or merely resembles it, needs a design pass against NEURONKIT_SPEC §4.3 before either commits to the other.

Reviewer registration. How a reviewer (write-policy, human, third-party) is registered against an estate or a write class, and what happens to a provisional write with no registered reviewer, default-commit or default-hold, is undecided.

Dependency on the unified audit log. Provisional, review, and resolution entries are audit-chain entries. The unified audit log they land in is not yet built. The audit-verify verb that walks the chain must understand provisional-state entries, so it is parked until the unified audit log lands and re-scoped to include these entry kinds. This document defines what those entries mean; the unified audit log defines where they live.

## 10. Relationship to the current specification

New in this document. The three-state drawer commit lifecycle. The rule that provisional rows are not system-returnable. The read-boundary exclusion predicate. The provisional, review, and resolution audit entry kinds. Soft-encryption of provisional data as a mode-independent default (cross-referenced from the federation decision Appendix A.2). The promote-or-reject reviewer interface as the seam for write-policy, human review, and third-party audit.

Reuses existing mechanism. Rejection uses the existing expunge verb (VerbSurface.swift), not a new deletion path. Provisional, review, and resolution entries are ordinary entries in the existing audit chain (UnifiedAuditLog), not a new store. The one-way lifecycle reuses the latch shape the automaton already applies to secret and tombstone.

Changes existing mechanism. The capture verb return contract changes from Drawer to a provisional handle or receipt, subject to the sequencing decision in section 9. Every read path gains a committed-only filter at its boundary.
