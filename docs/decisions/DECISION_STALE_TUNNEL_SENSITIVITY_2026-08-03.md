---
status: proposed
question: Should CorrectSensitivity reclassify a drawer's incident tunnels, or does gating at each disclosure boundary suffice?
authors: Bilby, Perkins
date: 2026-08-03
relates_to:
  - docs/reference/ARIA_MCP_INTERFACE.md
  - docs/reference/LOCUSKIT_SPEC.md
supersedes: none
context:
  - Raised while closing Codex finding 9352f983dea081919f83885bdbf77d40 (MXE-DM)
  - That finding is closed at the render boundary; this record covers the underlying data condition, which is not
  - Perkins found three surfaces emitting stale-edge metadata today — this is live, not hypothetical
---

# Stale tunnel sensitivity — reclassify at correction, or gate at every boundary?

## Context

A tunnel inherits its endpoints' adjective sensitivity **once**, at capture
time (`estate_verbs.rs:767-785`): the edge takes the maximum of its two
endpoints' tiers, so filtering an endpoint also hides the edge.

`CorrectSensitivity` rewrites only the drawer's adjective bitmap
(`estate_verbs.rs:2670-2692`). It does not reclassify incident tunnels. So
after a correction the invariant that motivated the inheritance no longer
holds: **a Normal edge can point at a Restricted drawer.**

MXE-DM closed the disclosure this caused at the ARIA reply surface — graph
lens arms hydrated tunnel-derived ids and rendered their subjects. The fix
gates at one hydration boundary per port. The **data condition itself is
unchanged and out of that mission's scope by explicit instruction.**

This record exists because the condition is load-bearing on boundary gating
alone, and because Perkins's post-flight review found the exposure is wider
than the closed finding.

## What is actually exposed today

Perkins enumerated three **live** surfaces that emit metadata of a stale-Normal
edge pointing into a since-restricted drawer. This is the material fact; an
earlier draft of this question framed the risk as future-only, which was wrong.

| Surface | What it emits | Assessment |
|---|---|---|
| `moot_connection_search` / `moot_connection_map` (`interface_tools.rs:1726, 1795`) | tunnel id, **tunnel label**, wing/room | Endpoint dense rows ARE gated; the **edge itself** is not. The label is link-time-authored relationship text — content-adjacent, though not a subject. |
| `moot_lens_contradiction` (`lens_tools.rs:594-604`) | gated endpoints emit `<hidden>` | Gates on the tunnel's own bits plus an endpoint check; see the parity item below |
| VaultKit tunnel export (`drawer_mapping.rs:346`) | serialised edge | `recall_tunnels_with_ceiling` gates the tunnel's OWN bits only, so a stale-Normal edge into a restricted drawer serialises into the **lower tier** |

The third is the most consequential: export crosses a trust boundary that a
reply surface does not.

Severity, stated plainly: **advisory, not blocking.** No subject or body
content escapes through any of these. What escapes is relationship metadata —
that a link exists, its label, and its coordinates.

## The question

Two coherent postures:

**A — Gate at every disclosure boundary.** Each surface that discloses
anything about an endpoint checks that endpoint's *current* sensitivity. This
is what MXE-DM did for dense-row hydration.

**B — Reclassify at correction.** `CorrectSensitivity` walks incident tunnels
and re-derives each edge's tier from its endpoints' current values, restoring
the capture-time invariant globally.

## Trade-offs

| | A — gate at boundaries | B — reclassify at correction |
|---|---|---|
| Blast radius | Per surface; grows with every new surface | One verb, but touches the tunnel write path |
| Failure mode | A new surface silently inherits the hole — this is exactly how the Codex finding arose | A missed edge case leaves a stale edge, but the invariant is testable in one place |
| Cost | Paid repeatedly, forever | Paid once, plus per-correction write amplification |
| Open questions | none | **What happens when sensitivity is LOWERED?** Does an edge recover its old tier, or stay at the high-water mark? Re-deriving from current endpoints means a Restricted→Normal correction un-hides edges — which may be correct, or may be a disclosure event in itself. |

The lowering case is the substantive unresolved question and the reason this
is a decision record rather than a patch.

## Recommendation

**B, with A retained as defence in depth** — but not as a drive-by. B is the
durable fix: it restores an invariant the schema already assumes rather than
asking every future surface to remember. It is the same class as the MXE-CJ
settle-time recheck already on record.

It should be its own mission, because it must answer the lowering question,
touch the tunnel write path, and cover all three surfaces above with tests.
Doing it inside a boundary-gating mission would be exactly the partial
migration the blast-radius standing order forbids.

Boundary gates already shipped (MXE-DM) should stay regardless of the outcome.
They are cheap, they are tested, and they hold even if a reclassification pass
misses an edge.

## Also unresolved — Rust/Swift parity on the contradiction arm

`lens_tools.rs:594-604` is now the last raw-read render site in the Rust lens
surface, and it diverges from its Swift twin:

- Rust hides only adjective non-exportable endpoints. Swift computes
  `hidden = loadedIDs − admissible` from a default frame, so it **also** hides
  withdrawn, untrustworthy, and absorbed endpoints. Rust renders subjects Swift
  hides. Belief/trust axes, not sensitivity — but every other surface in both
  ports hides those rows by default.
- Rust inserts hidden endpoints into `keystone_endpoint_ids`, so a restricted
  drawer's `isKeystone` bit influences sort order. Swift computes keystones
  from admissible rows only.
- Rust gates via a `from_raw`-decoded `is_bulk_exportable`, which is
  **fail-open** for a beyond-spec raw value (decodes to Normal). The frame path
  compares raw bits and fails closed. Reachable only via a corrupt bitmap the
  typed write path prevents; a recurrence of the documented MXE-CJ
  decode-upstream pattern.

Fix shape (one change, all three): convert the Rust arm to the same
default-frame fetch Swift uses, computing hidden as `loaded − admissible` and
keystones from admissible.

Left alone by MXE-DM deliberately — pre-existing, and its gate emits `<hidden>`
rather than an unhydrated row, so converting it changes an output format as
well as an admission rule. Parity drift on a security surface also pollutes the
training corpus, so it should not sit indefinitely.

## Disposition

**Proposed — awaiting Bob.** Nothing here blocks the MXE-DM merge; Perkins
returned no blocking findings and the Codex finding is closed.

Three things want a ruling:

1. Posture A or B for the stale edge, and if B, the lowering semantics.
2. Whether the VaultKit export path (crossing a trust boundary) warrants
   moving ahead of the reply surfaces.
3. Whether the Rust contradiction arm converges onto the frame path now or
   waits for B.
