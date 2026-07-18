---
title: CVK-WC0 — Wave C Federation Program Charter
version: v0.1
status: complete
date: 2026-07-17
worker: Kong
---

# CVK-WC0 — Wave C Federation Program Charter

## Status: COMPLETE

Charter mission. Read all required source documents. Produced architecture assessment
and mission sequence.

## Merge baseline

SHA merged into develop/1.1.x before this mission began: `389a480f`
Sentinel verified: `packages/kits/ConvergenceKit/rust/tests/field_lww_engine_tests.rs` present.

## Output

Charter document: `docs/analysis/CVK_WAVEC_FEDERATION_CHARTER.md`

## Key findings

1. **Identity is ephemeral.** LocalIdentity() generates a fresh keypair on every init.
   No persistence code exists in FederationIdentity.swift or FederationSyncEngine.swift.
   Every process restart invalidates all peers. This is the hard gate for WC1.

2. **Outbound changes are lost on process death.** `pendingOutbound: [TableChange]` is an
   in-memory array. The _fed_outbox durable side table does not exist. Echo suppression
   survives the shape change with no additional work — records are filtered at observe time.

3. **Three Rust drift rows found.** _fed_pending_skew table absent (Rust schema at v2 vs.
   Swift v3); gcIfDue not called in Rust pull(); Rust side-schema at v2.

4. **Hosted relay seam is clean.** Relay protocol already abstracts transport. Client
   conformer is additive; SyncServer wire protocol spec must precede WC7.

5. **DECISION_FEDERATION_SHARING_MODEL_2026-05-21.md correctly out of scope.**
   SPEC I-9 is unambiguous. Wave C ships row-sync transport only.

## Missions opened

| ID | Title | Tier | Status |
|---|---|---|---|
| WC0 | Federation program charter | review | COMPLETE |
| WC1 | Identity persistence | 1 | OPEN |
| WC2 | Durable outbox | 1 | OPEN |
| WC3 | Rust skew-queue parity | 1 | OPEN |
| WC4 | Rust TombstoneGC parity | 2 | OPEN |
| WC5 | SyncValueBox depth cap | 3 | OPEN |
| WC6 | Pairing lifecycle persistence | 1 | OPEN |
| WC7 | Hosted relay client conformer | 3 | OPEN — requires server spec first |

## TRACKED_FOLLOWUPS closure

Rows 10 and 11 remain open. They close as follows:
- Row 10 closes when WC2 merges.
- Row 11 closes when WC5 merges.
