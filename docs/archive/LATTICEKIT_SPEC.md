---
status: superseded
authors: MOOTx01 maintainers
date: 2026-06-14
version: 1.0.0
description: "Behavioral specification for LatticeKit: invariants, conformance requirements, and the contract it guarantees."
package: LatticeKit
kind: Kit
relates_to:
  - docs/reference/LATTICEKIT_INTERFACE.md  (the API surface this spec contracts)
  - docs/reference/GENIUSLOCUS_ARCHITECTURE_SPEC.md  (the lattice as coordinate spine)
  - docs/reference/MDCC_ANNEX_SPEC.md  (community classification federation)
  - docs/decisions/DECISION_LATTICE_CITATION_UDC_WIKIDATA_2026-05-07.md  (lattice citation decision)
purpose: |
  LatticeKit owns the Moot Decimal Classification Codes (MDCC) and
  maintains the Eidetic Label Lattice — the universal coordinate spine
  the substrate files content against. It provides the loaded
  classification canon, the code-grammar validator, the stable-key
  registry that keeps code assignments stable across canon rebuilds,
  and the assembler / editorial tooling (the `mdcc-build` CLI) that
  builds the canon from CC0 Wikidata source plus human-authored pins.
  The companion INTERFACE document carries the signatures.
superseded_by: ../reference/FDC_ENCODER_CANONICAL.md
---

> **SUPERSEDED (MDCC→FDC migration).** The MDCC machinery this document describes was removed; the shipped classifier is the FDC encoder — see `docs/reference/FDC_ENCODER_CANONICAL.md` and `docs/engineering/FDC_ENCODER_COOKBOOK.md`. Retained for history only.

# LatticeKit Specification

## § 1 — What this package is

LatticeKit defines and maintains the label space the whole substrate
files against: the Eidetic Label Lattice, addressed by Moot Decimal
Classification Codes (MDCC). The consumed surface is small — a loaded
`LatticeCanon` (code → concept), a `LatticeKit` namespace that loads the
bundled canon and looks codes up, and the `Code` grammar that validates
code syntax. Behind that sits the editorial machinery: a
`StableKeyRegistry` that keeps a code stable for a given source identity
across rebuilds, an `Assembler` that builds the canon from CC0 Wikidata
edges and human-authored pin files, and the `mdcc-build` executable that
runs it.

This package is a **Kit**, not a Lib: it actively manages maintained
state. `StableKeyRegistry` persists code assignments across canon
builds, the `Assembler` runs editorial tooling, and human editors author
pin files — there is a management interface and durable state across
time, not just pure functions.

## § 2 — Scope

This specification defines:

- The loaded classification canon and lookup by code / source identity.
- The bundled-canon loader and its versioning.
- The MDCC code grammar (well-formedness, integer base, extension digits).
- The stable-key registry contract (code stability across rebuilds).
- The assembler / editorial-pin / Wikidata-source tooling that builds
  the canon (the `mdcc-build` path).

This specification does NOT define:

- API signatures — those live in `LATTICEKIT_INTERFACE.md`.
- Term → code *lookup* (text resolution) — that is EideticLib's job
  (`EIDETICLIB_SPEC.md`); LatticeKit defines the space, EideticLib
  resolves into it.
- Community federation / ratification of classification sets — see
  `MDCC_ANNEX_SPEC.md`.

## § 3 — Position in the kit family

```
LatticeKit  ← (no dependencies)
     ▲
     │  consumed by
     └── EideticLib   (uses the canon + the Code grammar to resolve terms)
```

**Depends on:** nothing.

**Consumed by:** EideticLib (canon + code grammar). The assembler tooling
fetches from the Wikidata Query Service at build time but takes no
package dependency.

## § 4 — Invariants

**I-1 (canon immutability):** a loaded `LatticeCanon` is an immutable
value (`Codable` struct of `LatticeEntry` rows); lookups never mutate it.

**I-2 (code well-formedness):** every code in a canon satisfies the
`Code` grammar — decimal notation with at most `maxExtensionDigits` (8)
extension digits past the integer base.

**I-3 (stable keys):** once `StableKeyRegistry` assigns a code to a
source identity, that assignment persists across subsequent canon
builds; rebuilding never silently renumbers an existing concept.

**I-4 (deterministic assembly):** given the same CC0 Wikidata source
edges and the same editorial pin files, the `Assembler` produces an
identical canon (deterministic build, no wall-clock or network ordering
dependence in the output).

**I-5 (CC0 provenance):** the bundled canon derives from CC0 /
public-domain Wikidata data, so it ships in the default build with no
license encumbrance.

## § 5 — Behavioral contracts

**B-1 (lookup):** `LatticeKit.entry(for:)` and
`LatticeCanon.entry(for:)` return the `LatticeEntry` for a code or `nil`
if absent; `entry(forSourceIdentity:)` looks up by stable source
identity.

**B-2 (bundled load):** `LatticeKit.bundledCanon()` loads
`LatticeCanonV1.json` from `Bundle.module` and returns the decoded
`LatticeCanon`, or `nil` if the resource is missing or undecodable.

**B-3 (grammar):** `Code.isWellFormed(_:)` is true exactly for codes
that satisfy the MDCC notation; `Code.integerBase(of:)` returns the
integer base or `nil` for a malformed code.

**B-4 (canon round-trip):** `LatticeCanon` encodes and decodes through
`Codable` losslessly (the on-disk and bundled forms are the same shape).

## § 6 — Error model (conceptual)

| Category | Trigger | Recovery posture |
|---|---|---|
| `MOOTx01Error.edgeFetchFailed(statusCode:)` | the Wikidata Query Service returned a non-success status during assembly | surface to the build operator; retry the `mdcc-build` fetch |

This is a build-time tooling error; the consumed runtime surface
(canon lookup, grammar) is non-failing — missing/invalid input returns
`nil` (B-1, B-2, B-3).

## § 7 — Conformance requirements

**C-1:** `Code.isWellFormed` accepts exactly the codes the MDCC grammar
permits and rejects all others, across the shared grammar vectors
(I-2, B-3).

**C-2:** rebuilding the canon with an unchanged source + pin set leaves
every existing `(sourceIdentity → code)` assignment unchanged (I-3).

**C-3:** `LatticeCanon` Codable round-trips; `bundledCanon()` loads the
shipped `LatticeCanonV1.json` and every entry's code is well-formed
(I-1, I-2, B-4).

**C-4 (deterministic assembly):** two `Assembler` runs over identical
inputs produce byte-identical canon output (I-4).

**C-5 (cross-version parity):** the canon-lookup and code-grammar surface
(Tier 1 of the INTERFACE) produces identical results across the Swift and
Rust versions on the shared grammar and lookup vectors. The editorial
tooling (`Assembler`, `StableKeyRegistry`, `mdcc-build`) is build-time
machinery, exercised through its own conformance vectors.

## Changelog

### 1.0.0 -- 2026-06-14
Established under VERSIONING.md: version number removed from the filename; front matter normalized; baselined at 1.0.0.
