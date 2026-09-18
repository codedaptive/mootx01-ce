---
status: superseded
question: Should the minter row's single is_active flag keep gating both minting and result surfacing, or be split into capability, mint policy, and a write-free read selector?
authors: MOOTx01 maintainers
date: 2026-09-06
version: 1.0.0
relates_to:
  - docs/reference/GENIUSLOCUSKIT_SPEC.md (§16.2 result composition, §16.3 pins)
  - docs/reference/LOCUSKIT_SPEC.md (ADORNMENT_STORE)
  - docs/reference/ARIA_MCP_INTERFACE.md (read tools, estate status)
context:
  - one flag today means both "mint under X" and "show what X produced"
  - a device that cannot run X would hide every X adornment synced to it
  - adornment sync is deliberately unbuilt until offline judging proves adornments help
  - disposition is PARKED until that judging rules; not a mission request now
superseded_by: ../decisions/DECISION_RETIRED_TECHNIQUES_LEDGER.md
description: Historical proposal for separate adornment minting and surfacing policies.
---

> Superseded on 2026-09-06. See [the retirement ledger](../decisions/DECISION_RETIRED_TECHNIQUES_LEDGER.md).
> This document is preserved as history.

# Decision: adornment minting and adornment surfacing are separate decisions

## The problem

GENIUSLOCUSKIT_SPEC §16.2 keys result composition to the minter table: the composer
shows only adornments whose minter row has `is_active = 1` at the time of the call, and
AdornmentPass mints for exactly the same set. One flag, two meanings: "mint with this"
and "show what this produced".

That fails as soon as adornments travel. A Mac mints with NuExtract and Apple FM. An
iPhone can run Apple FM only. When adornment rows sync from the Mac to the iPhone (the
stated intent in the benchmark master plan's post-judging branch), the iPhone's minter
table either carries NuExtract as inactive, or lacks the row, and every NuExtract
adornment on the iPhone is stored but never surfaced. Dead weight that cannot be reached
on the device that received it. The same flag also makes the iPhone pass try to mint
NuExtract pairs it cannot serve, which today shows up as debt fetched and skipped every
pass (OPEN_ITEMS: stale active identities).

Today neither adornment rows nor the minter table sync (ConvergenceKit declares no
adornment record type). That is deliberate: adornment sync is not built until judging
proves adornments help (benchmark master plan F-2 and F-4). That judging happens
offline in the harness, which attaches stored adornment text to captured results at
judge-input time, so it needs nothing from the product. The split below is a prerequisite
of the sync that would follow a positive result, and is parked until then.

## The decision

Three decisions, three places. None of them is the other.

1. **Capability** — can this process mint under minter X? Derived from the installed
   engines at launch (Apple FM on Apple platforms, NuExtract where its asset is present,
   Candle where compiled). Never stored in the estate. A pass mints only pairs whose
   minter it can serve; a minter it cannot serve is not debt, it is simply not this
   device's job.

2. **Mint policy** — should minting under minter X happen for this estate at all? The
   existing minter row and its `is_active` bit keep this meaning and only this meaning.
   It is estate state and syncs with the estate. Deactivating a minter stops new minting
   everywhere; it does not hide what was already minted.

3. **Surfacing** — which stored adornments does a read return? Default: every stored
   adornment on the drawer, regardless of whether the local process could have minted it
   or whether its minter is still active for minting. Two narrowing controls, both
   read-side and write-free:
   - an estate-level *hidden minters* set, for an operator who wants a minter's past
     output suppressed without deleting it (the case the single flag was serving);
   - a call-scoped selector on the read (the MCP search, get and synthesis calls), naming
     zero, one, or many minter ids to surface for that call only. Absent selector means
     the default above. This is the benchmark's arm mechanism: mint once, vary what the
     judge sees per call, never write.

The composer stays free of family knowledge: it renders whatever the read returns.

## Consequences

- LocusKit: `activeAdornments(drawerIDs:)` becomes `surfacedAdornments(drawerIDs:
  selector:)`; the join on `adornment_minters.is_active` is replaced by the hidden set
  and the selector. Sensitivity gating is unchanged. Both ports.
- GeniusLocusKit: AdornmentPass filters its pair set by capability before by policy.
  `ensureDefaultAdornmentMinter` registers only minters the process can serve. §16.2 and
  §16.3 conformance pins are rewritten: "deactivating one of two minters changes the
  next composition result" becomes "hiding one of two minters changes the next
  composition result; deactivating one stops its minting and changes nothing shown".
- ARIA_MCP: the read tools accept the selector argument; `moot_estate_status` reports
  the three sets (can mint / mints / hidden). Frozen posture treats the selector as a
  read, which it is.
- Sync, when it is built: adornment rows and the minter table are estate state and
  travel; capability does not.
- Benchmark harness: PAY-ARM's copy-and-flip fallback stays valid and becomes
  unnecessary once the selector ships; the harness passes the selector per arm instead.
- Index composition policies that fold adornment text into the index (lex or dense
  "PlusAdornments") are a separate question: the index is built from the stored rows
  under the policy in force; the selector affects what is shown, not how rows rank.

## Alternatives considered

- Keep one flag and add the selector as a benchmark-only override. Rejected: the
  synced-device case is a product case, not a benchmark case.
- Sync the minter table and let each device flip its own flags. Rejected: the flag would
  then mean different things on different devices, and a device's flip would sync back.

## Status

Parked (2026-09-04). Adornment value is proved offline first: mine into cloned
databases, capture frozen search results once, and judge with and without the stored
adornment text attached at judge-input time. No adornment surfacing or sync work enters
the product until that judging shows a gain. This record is revisited then; it is not a
mission request now. When revisited: Kong review, then one mission across LocusKit,
GeniusLocusKit and AriaMcpKit in both ports, with SPEC and INTERFACE bumps for all three.

## Changelog

- 0.1.0 (2026-09-04): proposed, then parked the same day pending offline judging.

## Supersession changelog

### 1.0.0 -- 2026-09-06

Archived the retired contract. The retirement ledger records its disposition.
