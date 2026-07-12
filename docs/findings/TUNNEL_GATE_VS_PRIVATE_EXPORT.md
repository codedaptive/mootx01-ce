<!-- Tunnel sensitivity gate vs private-scope vault export — conflict finding
     from the 2026-07-12 fast-lane stabilization session. One VaultKit test
     (PrivacyTierAndReceiptTests CAND-EXP-PROV private-scope case) is
     intentionally left red as the tripwire for this finding. -->

FINDING: TUNNEL_GATE_VS_PRIVATE_EXPORT — the unconditional tunnel sensitivity gate breaks the private-scope export's documented opt-in

---

**Symptom (deterministic):** `VaultKitTests.PrivacyTierAndReceiptTests`
"CAND-EXP-PROV: provenance tunnel to restricted drawer excluded by default,
included under private scope" fails on its second half: an export with
`scope: .believedIncludingPrivate` no longer carries the restricted source's
location in the provenance frontmatter. The first half (default scope
excludes it) passes — the default-scope behavior is correct.

---

**Root cause:** d0116347 "fix(security): gate tunnel graph reads by
sensitivity (both legs)" added an unconditional filter to
`Estate.tunnelsFromWing` (Swift `Estate.swift`; Rust
`estate_verbs.rs::tunnels_from_wing`):
restricted/secret tunnel edges are excluded "enforced at the source so
every caller is covered."

The vault export's provenance-frontmatter builder reads tunnels through
`kit.recallTunnels(handle, wing:)` (VaultBridge.swift, DrawerMapping.swift,
PalaceBridge.swift), which routes to that gated read. There is no scope
parameter on the seam, so the export cannot see the provenance tunnel to a
restricted drawer even when the operator explicitly opted into
`.believedIncludingPrivate` — the CAND-EXP-PROV contract this test pins.

Two correct requirements are colliding:
- Security: reasoning lenses and default recall must never see edges above
  the no-claims ceiling (the gate's purpose — keep).
- Export: `.believedIncludingPrivate` is a deliberate, owner-initiated
  opt-in that MUST include restricted material, including provenance
  tunnels, or the exported vault silently loses lineage.

---

**Fix direction (needs its own mission — security-sensitive seam, both
legs):** a scope-aware tunnel read — e.g.
`tunnelsFromWing(sensitivityCeiling:)` defaulting to the current gated
ceiling, with the vault export passing an elevated ceiling ONLY on the
`.believedIncludingPrivate` path. Tier precision matters: decide whether
the private scope includes secret-tier edges or only restricted (mirror
whatever the drawer-side private-scope export does today). Perkins should
review the seam: it is a deliberate bypass parameter on a security gate,
both legs (LocusKit Swift + Rust), plus the GLK `recallTunnels` forwarding
and the three VaultKit call sites.

**Tripwire:** the CAND-EXP-PROV private-scope test is left failing on
purpose — it asserts the documented opt-in contract. Do not weaken the
test; add the scope-aware seam.
