<!-- Audit coverage for tunnels & KG-facts — architecture decision memo (B3 chosen)
     Produced by the Kong (architecture) review agent for SUBSTRATE_ROBUSTNESS_FEATURES Part 1, 2026-07-10/11.
     Recovered from the agent transcript and committed 2026-07-11 — the agent
     returned this inline and the file was never landed. -->

# Kong Architecture Review: SUBSTRATE_ROBUSTNESS_FEATURES Part 1

## Assessment

Part 1 proposes closing a correctness gap where tunnel and KG-fact captures bypass the audit pipeline, leaving the NeuronKit AutonomicGovernor's `hasAuditGrown` watermark blind to topology-affecting writes. Three duties — `graphCentralityScan`, `topologySnapshotDuty`, and `preferenceScan` — all use `SELECT COUNT(*) FROM _storagekit_audit` as their skip gate. Because tunnel and fact writes produce no audit events, a tunnel/fact-only change leaves stale centrality scores and a stale topology snapshot until an unrelated drawer write occurs.

## Verification of Bob's Stated Claims

**Claim 1 (AuditGate.admit is drawer-state-semantic):** CONFIRMED. `AuditGate.swift` line 371-378: the `prior==nil` capture branch requires `verb == .capture`, written state (adjective bits 0-5) to be `.active` or `.pending`, and runs `ForbiddenCombinations.check`. The vocabulary basis (`Vocabulary.basis`, lines 145-185) declares five adjective slots (state 0-5, sensitivity 6-11, exportability 12-17, trust 18-23, flags 24-26) — these are DRAWER-semantic axes.

**Claim 2 (DrawerStore.gatedCaptureBody uses drawer slots):** CONFIRMED. `DrawerStore.swift` lines 913-937: `gatedCaptureBody` calls `Self.declaredSlots(for:)` (line 929), which at line 1899-1910 returns `Vocabulary.basis` for `.adjective` and `LocusKitVocabulary.unionSlots` for `.operational`/`.provenance`. These are DRAWER slot definitions.

**Claim 3 (Tunnel/KGFact have different bitmap layouts):** CONFIRMED. Tunnel operational uses bits 6-8 for `originClass` (EstateVerbs.swift lines 517-526). DrawerStore's `declaredSlots(for: .operational)` returns LocusKitVocabulary.unionSlots which are drawer-specific. The bit semantics differ.

**Claim 4 (NounType has .tunnel(1)/.kgFact(2); no tunnel/kgFact audit events exist):** CONFIRMED. `NounType.swift` lines 13-15. `AuditGate.admit` takes `nounType: NounType` as a parameter (line 322) but the `AuditEvent` struct (AuditEvent.swift lines 15-56) carries NO nounType field — the parameter is accepted but not stored. No code path calls `AuditGate.admit` or `auditLog.append` for tunnel or fact rows. `AuditLogFold.projectAll` (line 102-125) resolves nounType externally via a `nounTypeFor: (UUID) -> NounType` closure.

**Claim 5 (VERB-CAP-01 deliberately made standalone tunnel capture byte-identical to cascade):** CONFIRMED. EstateVerbs.swift lines 457-486 and Rust estate_verbs.rs lines 620-646 carry explicit, detailed comments documenting this decision. The mission text notes doc/source drift — cascade-born tunnels carry no genesis event, so mirroring drawer capture would CREATE the divergence the mission forbade.

## Critical Finding: Swift-Rust Governor Parity Gap

The Rust governor ALREADY uses a correct watermark for centrality. `autonomic_governor.rs` line 516: `last_centrality_counts: Option<(usize, usize, usize)>` — a tuple of (drawer_count, tunnel_count, fact_count) loaded from direct `all_drawers()`, `all_tunnels()`, `all_kg_facts()` calls (lines 1482-1489). This catches tunnel/fact changes WITHOUT relying on audit events.

The Rust topology duty (lines 1992-2025) loads all three entity types and computes a `TopologyInputsToken` fingerprint directly — no outer audit-count watermark. It is already correct.

The Swift governor, by contrast, uses `hasAuditGrown` (AuditProbe.swift lines 59-70) for all three duties. This is a COUNT(*) on `_storagekit_audit` only. The Swift TopologyInputsToken (lines 1166-1268) exists as an INNER fingerprint that correctly includes drawers, tunnels, and facts — but the OUTER `hasAuditGrown` gate (added as a "DoS fix" at lines 945-957) prevents reaching it when the audit count is unchanged.

The unsoundness is Swift-only. Rust is already correct.

## Answers to Questions

### A. Is it SOUND to admit a tunnel/fact capture through AuditGate as-is?

Partially. I traced `AuditGate.admit` with `prior=nil, writes=[], afterBitmaps=(0,0,0)`:

- Step 1 (vocabulary gate): empty writes array → loop body never executes. **Passes.**
- Step 2 (read-modify-write): base = all-zero, no writes applied. All bitmaps remain 0.
- Step 3 (basis gate): `writtenState = RowState(rawValue: 0) = .active`, `verb = .capture`. The `.active || .pending` check passes. `ForbiddenCombinations.check(.active, all-zero-fields)`: I-22 (sensitivity=0=normal, exportability=0=private, not secret+public) passes; S-1 (not .accepted) skips; S-2 (not .withdrawn/.rejected) skips; S-4 (not .accepted) skips. **Passes.**
- Step 4 (contentID): deterministic from (estateUuid, rowId, hlc, "capture", (0,0,0), afterAnchor). **Works.**

So `AuditGate.admit` cleanly accepts an empty-writes genesis event with all-zero bitmaps.

However, passing tunnel/fact bitmaps through `declaredSlots(for:)` is NOT sound. The drawer vocabulary would decompose tunnel operational bits (e.g., `originClass` at bits 6-8) through drawer-semantic slot definitions, potentially extracting values that fail the legal-values check or producing nonsense audit content. Do not route actual tunnel/fact bitmaps through the drawer vocabulary.

### B. Option Evaluation

**B1 (FULL — noun-specific vocabulary):**

Pros: Audit events carry semantically correct bitmap decompositions. Federation consumers see meaningful field-level diffs.

Cons: Requires defining FieldSlots for tunnel (operational bits 6-8 = originClass, plus any other tunnel-specific bits) and KGFact. Both legs. Conformance vectors. AuditEvent still does not carry nounType, so the fold consumer must resolve it externally — unchanged but worth noting. The vocabulary union would need per-noun vocabularies or a noun-parameterized slot resolution, which is a design expansion beyond what `VocabularyValidator.freeze` currently supports.

Verdict: Correct but oversized for a patch. This is a minor-version feature.

**B2 (GENESIS-MARKER — empty writes, all-zero bitmaps):**

Invariants verified:
- `AuditGate.admit(writes: [], prior: nil)` passes cleanly (traced above).
- `AuditLogFold.foldOrdered` projects stateRaw=0=.active, all bitmaps zero, tombstoned=false. Correct for a tunnel/fact initial state.
- ContentID is deterministic and unique per (rowId, hlc). G-Set dedup works.
- Merkle rollup: append-only log, no nounType dependency. Works.
- Federation: event carries (estateUuid, rowId, hlc, verb, bitmaps, anchor). A peer can resolve nounType via the existing `nounTypeFor` closure. Works.

Open issues:
- **LatticeAnchor:** Tunnels and facts have no UDC code or Wikidata Q-ID. The drawer path uses `LatticeAnchor.udcQid(d.udcCode, qid: d.wikidataQID ?? "")`. A tunnel/fact genesis would need a stable anchor value — `LatticeAnchor.udcQid("", qid: "")` or equivalent. This needs verification that the contentID computation and any anchor-dependent consumers tolerate an empty anchor.
- **HLC access:** Tunnel capture (`EstateVerbs.swift` line 496) and KGFact capture (`VerbSurface.swift` line 439) currently have no HLC access. `DrawerStore.gatedCaptureBody` reads `self.hlc` (an actor-isolated property). The tunnel verb is on `Estate` (which has `DrawerStore` access), but `captureKGFact` is on `VerbSurface` (which holds a `DrawerStore` reference). Both can access the HLC, but the threading needs care.
- **FOUR-WAY conformance cost:** Swift AuditGate (already works unchanged), Rust audit_gate (already works unchanged), Swift audit test, Rust audit test. The gate code itself needs no changes. New conformance vectors asserting that a tunnel/fact genesis event is admitted and appended correctly — moderate cost.
- **Test-contract updates:** No existing tests assert audit counts for tunnel/fact rows (they have zero today). Tests asserting global audit counts after capture sequences would need updating to account for new tunnel/fact events.

Verdict: Sound and moderate in scope. Reverses the VERB-CAP-01 decision deliberately. Acceptable for a patch IF the LatticeAnchor and HLC threading are handled cleanly.

**B3 (NARROWER — fix the watermark, don't expand audit):**

The fix: replace the audit-count-only `hasAuditGrown` with a composite check that also includes tunnel and KG-fact counts, aligning Swift with the Rust governor's existing approach.

Specific changes:
1. Add `tunnelCount()` and `kgFactCount()` O(1) methods to `DrawerStore` (SELECT COUNT(*) on `tunnels` and `kg_facts` tables).
2. Expose via `GeniusLocusKit` for the governor to reach (B-1 compliance).
3. Enhance `hasAuditGrown` → `hasEstateChanged` to include all three counts as a persisted tuple in estate.meta. Three O(1) queries instead of one.
4. For topology: either use the enhanced watermark, or remove the outer audit-count gate and rely solely on the inner `TopologyInputsToken` fingerprint (which is already correct).
5. Rust governor: NO CHANGE NEEDED — already correct via tuple counts.

Blast radius:
- `AuditProbe.swift` (or new file) — enhance/create composite watermark
- `DrawerStore.swift` — add 2 count methods (trivial SQL)
- `GeniusLocusKit.swift` — expose count methods
- `AutonomicGovernor.swift` — 3 watermark call sites (graphCentralityScan, preferenceScan, topologySnapshotDuty)
- `EstateManifestPolicyStore.swift` — persist composite watermark
- Rust: NO CHANGES
- Tests: add tests verifying watermark detects tunnel/fact-only changes

Note on `preferenceScan`: This duty depends on recall traces, which are drawer-driven. A tunnel/fact-only change does not generate new recall traces. The audit-only watermark is arguably correct for preferences. The composite watermark would cause a spurious preference recompute on a tunnel/fact-only change — harmless (produces identical scores) but wasteful. Accept this as a minor inefficiency or keep the audit-only watermark for preferences specifically.

Verdict: Smallest sound fix. Aligns Swift with existing Rust approach. Does not expand the audit stream. Does not reverse the VERB-CAP-01 decision.

### Recommendation: B3 for the 1.0.28 patch, B2 deferred to its own mission.

Rationale in order of weight:

1. **B3 fixes the immediate bug with the smallest semantic change.** The governor's centrality and topology are correct after this fix. No audit stream contract changes.

2. **The Rust governor is already correct via tuple counts.** B3 aligns Swift with the existing Rust approach, closing a cross-leg parity gap rather than creating a new approach.

3. **B2 changes the audit stream's contract.** Every downstream consumer of the audit log — federation sync, AuditLogFold, disaster-recovery rebuild, any code that iterates `_storagekit_audit` — would now see tunnel/fact events they have never seen before. The AuditEvent struct does not carry nounType, so consumers that need to distinguish drawer events from tunnel/fact events have no field to filter on (they must resolve via the `nounTypeFor` closure). This deserves its own mission with explicit consumer-impact analysis, not a side effect of a watermark fix.

4. **The VERB-CAP-01 decision was deliberate.** Reversing it (B2) should be a deliberate decision with its own ADR, not a patch-level change. The decision was motivated by byte-identical parity between standalone and cascade tunnel creation — B2 would break that contract.

5. **B1 is a minor-version feature** — vocabulary expansion for non-drawer nouns. Not patch territory.

### C. Supersession-Cascade Tunnel Insert

Under B3: the cascade tunnel insert is already covered. The triggering drawer capture emits a genesis event that bumps the audit count, and the cascade also changes the drawer count (new successor drawer). Under the composite watermark, both the audit count and the drawer/tunnel counts change — the watermark fires.

Under B2: same answer — the triggering drawer's genesis event bumps the audit count. The cascade tunnel doesn't need its own event for watermark purposes. If B2 ships, auditing the cascade tunnel is a SEPARATE design question (audit-log reconstruction completeness for tunnels), not required for the watermark fix.

### D. Is Part 1 Safe for a 1.0.28 Patch?

Under B3: yes. The blast radius is bounded to the governor watermark layer (Swift only; Rust is a no-op). No audit stream changes, no vocabulary changes, no conformance-vector changes. Five files edited (AuditProbe, DrawerStore, GeniusLocusKit, AutonomicGovernor, EstateManifestPolicyStore). Within Tier-1 cap.

Under B2: borderline. The audit stream expansion is a cross-cutting change that affects federation, fold, and any consumer of the audit table. It reverses a prior deliberate decision. I would defer B2 to a 1.1 minor or a dedicated mission with its own ADR.

## Risks

| Risk | Severity | Mitigation |
|---|---|---|
| B3 watermark adds 2 extra O(1) SQL queries per cadence tick (3 duties × topology/centrality cadence) | Low | O(1) COUNT(*) on indexed tables; negligible cost at 5-10 min cadences |
| B3 preferenceScan sees spurious dirty signal on tunnel/fact-only changes | Low | Accept: recompute is idempotent; or keep audit-only watermark for preferences specifically |
| B2 (if chosen) audit stream consumers not prepared for non-drawer events | Med | Defer B2; ship with consumer-impact analysis |
| TopologyInputsToken loads all rows to compute fingerprint when outer watermark removed | Med | Keep the composite watermark as the outer gate; only fall through to full load when counts change |
| B3 DrawerStore count methods bypass DrawerStore trait in Rust (methods don't exist there) | Low | Rust governor already uses `.all_tunnels().len()` — no new Rust method needed |

Non-obvious risk: **The AuditEvent struct does not carry nounType.** If B2 ships later, every consumer that needs to distinguish tunnel/fact events from drawer events must resolve nounType externally. This is fine for the fold path (which already takes a `nounTypeFor` closure) but is a hazard for any new consumer that iterates the audit table directly (e.g., a federation export path that filters by nounType). This should be surfaced in the B2 mission's blast radius report.

## Dependencies

- **Depends on:** `DrawerStore` SQL schema (tunnels and kg_facts tables already exist with id columns), `GeniusLocusKit` estate storage access pattern (B-1 compliance for governor → kit → store), `EstateManifestPolicyStore` meta key conventions.
- **Affects:** NeuronKit governor watermark accuracy (the fix), Rust governor (NO CHANGE — already correct), topology snapshot freshness, graph-centrality freshness.
- **Conflicts with:** VERB-CAP-01's byte-identical tunnel creation contract (only if B2 is chosen; B3 does not conflict).

## Recommendation

**ACCEPT WITH CONDITIONS:**

1. Ship B3 (composite watermark) for the 1.0.28 patch. The Rust governor is the reference implementation — align Swift to match.
2. File a separate mission for B2 (genesis-marker audit events for tunnels/facts). That mission should carry its own ADR documenting the VERB-CAP-01 reversal and the audit stream contract expansion. It should enumerate every consumer of `_storagekit_audit` and verify each handles non-drawer events.
3. The topology duty's outer audit-count watermark should be replaced by the composite watermark, NOT removed entirely — removing it would force a full estate load every 5 minutes regardless of change, which the "DoS fix" comment at line 945 was specifically guarding against.
4. Document in a comment that `preferenceScan`'s audit-only watermark is technically correct (preferences depend on recall traces, not tunnels/facts) but uses the composite watermark for simplicity, accepting a harmless spurious recompute.

## Notes for the Audit Trail

The Rust and Swift governors diverged on watermark strategy:
- Rust: direct entity-type count tuple `(drawer, tunnel, fact)` — correct from the start (commit `70831548` per mission draft).
- Swift: audit-event-count proxy — correct only if every topology-affecting write emits an audit event, which tunnels and facts do not.

This divergence was not caught during the centrality watermark implementation because the Rust leg was developed independently and the approaches were considered equivalent. They are not — the Swift approach has a coverage gap. B3 closes the gap by aligning Swift with Rust. B2 would close it differently (making the audit count a complete sentinel) but at higher cost and broader blast radius.

The memory entry `topology-audit-watermark-unsound` correctly identified this issue. The root fix proposed there (audit tunnels/facts at the gate) is B2; the alternative (fingerprint-based gate) is B3. This review recommends B3 for the patch and B2 as a planned improvement.