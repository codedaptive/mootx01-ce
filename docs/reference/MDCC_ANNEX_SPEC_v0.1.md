# MDCC Annex System

## Status

Design spec, v0.1, draft. Targets the v1.2 contribution and conversion layer. Depends on the reserved ranges shipped in MDCC v1 (LatticeKit, mission LAUNCH-03A), which are in place. Not yet a build mission.

## Purpose

MDCC ships as a fixed quarterly canon so the codes everyone shares are stable. But people will classify things the canon does not yet name, and whole communities will arrive with their own sets. The annex system is how a set that is not yet canon can exist, be used, be federated, and earn its way in, without forcing a renumbering of the canon and without a central registrar standing in the way.

The keystone constraint from the contribution model holds: a private scheme is brain-dark. The brains tunnel and associate over published structure, so storage and retrieval work on a private scheme but association does not. To be MOOT-compatible a scheme is published free to the community so the brains can ingest its structure. The annex system is the on-ramp for that publication.

## Two layers

The word annex covers two distinct mechanisms. This spec names them so they are not conflated, because MDCC v1 already shipped one of them under that word.

### Layer 1: the in-spine provisional range

MDCC v1 reserves, in every class, a community range from NN80 through NN99 and a nested annex range from NN90 through NN99. The assembler never assigns into reserved ranges; it fills only NN00 through NN79. The nested NN90 through NN99 range is the in-spine provisional range: a small, class-bound set may stage codes there, expressed directly in the main-sequence numbering of its target class, while its meaning is still held by its creator rather than the canon. On ratification those codes are promoted into the community range NN80 through NN89 and become canon.

This layer is for the simple case: a set that clearly belongs under one existing class and is headed for promotion into it. In the shipped code this range is ReservedRange.Kind.annex. In this spec it is the in-spine provisional range, to free the word annex for the richer concept below.

### Layer 2: the separate-address-space annex

A standalone scheme, a set that spans many classes, or a large external corpus does not fit inside one class's provisional range. It lives in its own address space. Its codes are addressed as an annex identifier plus a local code, and that pair is globally distinct without coordinating with anyone. An annex in this sense is federatable while unratified, and it is the unit that can be blessed.

## The annex address

An annex address is two parts: an annex identifier that names the annex, and a local code that the annex assigns inside itself. The local code grammar is the annex's own business. The annex identifier is what has to be unique across everyone, so it carries the collision-proofing.

### Self-allocation without a registrar (proposal)

Annex identifiers are namespaced by something the contributor already owns, the way software package names are. A reverse-domain identifier such as com.example.taxonomy, or a public-key fingerprint, serves as the root. Ownership of the namespace root, a domain or a key, is what prevents collision, so no central registrar issues identifiers and no one waits for approval to start. Two contributors cannot mint the same identifier because neither controls the other's root. This keeps the on-ramp permissionless, which is the point of an annex.

The recommendation is reverse-domain identifiers for human-legible annexes and key-fingerprint identifiers where the contributor prefers not to anchor to a domain. Both resolve the open question of self-allocation without a registrar. This is a proposal to confirm.

## Three placement outcomes

A submitted set reaches one of three outcomes. Submission is required for any outcome, because the brains have to ingest the structure regardless.

### Provisional

The default. The set lives as an annex, addressed by annex identifier plus local code, federatable within the circle that has adopted it, brain-dark to the wider fabric until submitted and at least provisionally recognized. Most sets stay here until they prove out.

### Ratified and promoted

A small, high-value set is ratified and promoted into the reserved community ranges of the main sequence. It stops being addressed by its annex identifier and becomes canon, addressed by ordinary MDCC codes that everyone pulls. This is the path the in-spine provisional range stages for, and the community ranges reserved in v1 are where it lands.

### Blessed as a standing annex

A large external set is too big to fold into the canon, but leaving it provisional understates it. It is blessed: recognized as authoritative in its own space, keeping its own annex identifier and address, never merged into the main sequence. A blessed annex is permanent and trusted. An unblessed annex is provisional. Blessing a large set and ratifying a small set are both the community conferring authority; the difference is that a small set earns a place inside the canon and a large set earns a permanent identity beside it.

## Ratification and blessing transitions

Promotion of a small set rewrites its addresses from an annex identifier plus local code into main-sequence codes in a community range. References to the old annex addresses must keep resolving, so the transition produces an alias rather than a deletion (see the open question below).

Blessing of a large set changes its standing, not its address. The annex identifier and local codes stay exactly as they were; what changes is that the fabric now treats the set as authoritative and the brains rely on its structure for tunneling. Because the address does not move, blessing has no alias problem.

### The retire-versus-alias question, narrowed (proposal)

For a blessed annex the address is permanent by definition, so the question does not arise. It arises only for a small set promoted into the main sequence: does its annex identifier retire, or does it persist as an alias to the new canonical code?

The recommendation is a permanent, read-only alias. Retiring the annex identifier would break every reference already made under it and would defeat the round-trip guarantee the rest of the system depends on. A permanent alias resolves old addresses to the canonical code indefinitely, at the cost of carrying a small alias table. This is a proposal to confirm.

## Relationship to the valid-but-unknown-code state

MDCC v1 already accepts a well-formed code it does not recognize, stores it, round-trips it intact, and resolves it later when the canon catches up. The annex system is that same tolerance one level up. Where valid-but-unknown handles a single unrecognized code, an annex handles a whole unrecognized set, with an address space and a path to recognition. The two are the same posture at different scales: accept structure you do not yet own, preserve it exactly, and let recognition arrive later.

## Federation and conversion

Federation runs over shared structure. Within MDCC and its blessed annexes federation is direct, because they share the scheme. A set on a foreign scheme is not federated directly; it is converted first. The contribution model provides the two transform tools for this: a cold conversion that is full-fidelity and loses nothing, so committing to a scheme is never a trap, and a hot conversion that migrates a database live in production with no downtime. EideticLib gains custom-scheme import at v1.2 to feed these.

## Dependencies and the build

The reserved ranges this system promotes into are in MDCC v1 and cannot be retrofitted, so the timing constraint is already met. What remains for the v1.2 contribution and conversion mission:

- The annex address type: an annex identifier plus a local code, with the namespaced self-allocation above.
- The provisional, ratified, and blessed states, and the transitions between them, including the permanent alias on promotion.
- The federation boundary check: same scheme direct, foreign scheme through conversion.
- The cold and hot transform tools, and EideticLib custom-scheme import.
- A naming pass on LatticeKit so ReservedRange.Kind.annex reads as the in-spine provisional range, to match this spec. This is the only change to shipped code, and it is cosmetic.

## Open questions carried forward

- Self-allocation mechanism: reverse-domain or key-fingerprint namespacing is the proposal above. Confirm before the v1.2 mission.
- Promotion alias: a permanent read-only alias is the proposal above. Confirm before the v1.2 mission.
