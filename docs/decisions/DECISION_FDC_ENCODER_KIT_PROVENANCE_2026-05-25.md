---
status: decided
question: Which kit owns the FDC encoder, and does it require a new kit?
authors: MOOTx01 maintainers
date: 2026-05-25
relates_to:
  - docs/reference/FDC_ENCODER_CANONICAL.md
supersedes: none
context:
  - The FDC encoder spans word-class lookup, canonicalization, concept-bag
    assembly, signature scoring, and frame descent.
  - The question is whether these functions justify a new kit or fit the
    existing kit boundary.
---

# FDC Encoder — Kit Provenance

**References:** FDC_ENCODER_CANONICAL.md

---

## 1. Summary

The FDC encoder (`encode(text) -> code`) is not owned by one kit. Its
functions are distributed across the existing kit boundary exactly as
those boundaries were designed. No new kit is needed. The Seed Generator
is a standalone maintainer utility, not a shipped kit.

---

## 2. Kit Ownership by Encoder Function

| Encoder function | Owning kit | Rationale |
|---|---|---|
| Static word-class table (Step 1 fast path) | EideticLib (bundled resource) | EideticLib already bundles static reference data and resolves against it offline. The word-class table is the same pattern as the existing WikidataSubset.json. |
| NLTagger fallback + HMM/Viterbi fallback (Step 1 novel tokens) | EideticLib (runtime) | EideticLib owns the runtime lookup pipeline. The tagger fallback is an extension of that pipeline for tokens the static table does not cover. |
| Local accumulation cache + pool submission (Step 1 novel token reporting) | EideticLib (runtime) | Same kit as the fallback. The 50-entry threshold, submit-and-purge, and EideticLib update ingestion are all runtime behaviors EideticLib owns. |
| Canonicalization lexicon lookup (Step 2) | EideticLib (bundled resource) | The pinned Wikidata alias + WordNet snapshot is a static artifact EideticLib bundles, matching the existing WikidataSubset.json pattern. The `LatticeResolver` type already performs this kind of lookup. |
| Weighted concept bag assembly (Step 3) | EideticLib (runtime) | Frequency accumulation is part of the runtime pipeline, same kit as Steps 1 and 2. |
| Aho-Corasick scan + scoring (Step 4) | EideticLib (runtime) | The match step operates against the code signatures, which EideticLib bundles. The automaton is built from those signatures at startup, same as the existing canon parse-and-cache pattern. |
| SimHash pre-filter for long input (Step 4) | SubstrateLib + EideticLib | SubstrateLib already owns FloatSimHash and the fingerprint primitives. EideticLib calls into SubstrateLib for this step, consistent with SubstrateLib's role as the math foundation. |
| Frame descent (Step 5) | EideticLib (runtime) | Tree traversal over the FDC frame, which EideticLib bundles. Same runtime kit. |
| FDC frame (the decimal code tree) | EideticLib (bundled resource) | Replaces the current LatticeCanonV1.json bundle. The FDC frame is a static versioned artifact; EideticLib bundles it and the Seed Generator produces it. |
| Code signatures (weighted concept bags per code) | EideticLib (bundled resource) | Same pattern as the FDC frame. Produced by the Seed Generator at maintainer build time, bundled as a static versioned artifact, ingested by EideticLib. |
| Aho-Corasick automaton (built from signatures) | EideticLib (built at startup) | Constructed in-memory from the bundled signatures on first use, cached for process lifetime. Same pattern as the existing canon parse-and-cache. |

---

## 3. LatticeLib — Existing Role and Transition

LatticeLib today owns:
- The MDCC notation spec and assembler (`mdcc-build` executable)
- The bundled LatticeCanonV1.json
- The Canon, Assembler, StableKey, CollapseRule, and CanonWriter types

Under the FDC encoder, LatticeLib's role narrows. The FDC frame replaces
the MDCC-derived canon as the classification spine EideticLib resolves
against. LatticeLib's assembler machinery (`mdcc-build`, Assembler,
StableKey, CollapseRule) is superseded for the classification function
by the Seed Generator (see §4).

LatticeLib continues to own the MDCC notation and the prior canon for any
consumer that still resolves against MDCC codes. It is not deleted. Its
`mdcc-build` executable becomes a legacy maintainer tool alongside the
new Seed Generator.

The import edge `EideticLib → LatticeLib` is removed as part of the FDC
migration. EideticLib transitions from importing LatticeLib at runtime to
reading a static bundled snapshot produced by the Seed Generator. The
two kits decouple and communicate only through versioned JSON artifacts.

---

## 4. The Seed Generator — Standalone Maintainer Utility

**Placement:** `tools/seed-generator/` in the repository root, not
inside any kit directory. It is not a shipped library target. It is not
imported by any kit at runtime.

**What it does:** produces the three static artifacts EideticLib bundles:

1. The FDC frame JSON (parsed from `fdc.txt`, CC0).
2. The code signatures JSON (weighted concept bags per FDC code,
   built by running Steps 1–3 over each code's three reference sources:
   FDC label, Wikiword title, LexRank-reduced Wikipedia article, merged
   with pinned source-type weights).
3. The word-class table JSON (built by running NLTagger over a
   Wikipedia corpus and recording noun/verb assignments; the reference
   table all platforms use as the Step 1 fast path).

**Why not a kit:** no shipped kit calls the Seed Generator at runtime.
It runs once per release cycle to produce new versioned artifacts, which
are then committed to the repository and bundled into EideticLib. The
same pattern as `mdcc-build` today: a maintainer executable, not a
library dependency.

**Build-time only dependencies the Seed Generator may use:**
- LexRank implementation (Python or Swift; runs offline)
- NLTagger (Apple platforms only; the generator runs on macOS)
- Wikidata SPARQL endpoint (optional; fixture mode runs fully offline)
- Wikipedia article fetcher (build-time only; never ships)

**Output artifacts (committed to the repository, versioned):**

| Artifact | Path in EideticLib | Version field |
|---|---|---|
| FDC frame | `Sources/EideticLib/Resources/FDCFrame.json` | `frame_version` |
| Code signatures | `Sources/EideticLib/Resources/FDCSignatures.json` | `signatures_version` |
| Word-class table | `Sources/EideticLib/Resources/WordClassTable.json` | `table_version` |

Each artifact carries an explicit version string. EideticLib reads all
three at startup, caches them for the process lifetime, and records
their versions in every `Anchor` it returns for audit traceability.

**Pool reduction tool:** a second maintainer utility, `tools/pool-reducer/`,
periodically processes crowd-sourced novel-token submissions from the
pool, runs the NLTagger/HMM-Viterbi agreement check, and produces an
updated WordClassTable.json for maintainers to review and commit.
This is also a standalone tool, not a kit.

---

## 5. SubstrateLib — Shared Primitives

SubstrateLib contributes `FloatSimHash` and `Fingerprint256` to the
encoder's Step 4 pre-filter. EideticLib already sits downstream of
SubstrateLib in the dependency graph (SubstrateLib has no local
dependencies; everything else can depend on it). No dependency graph
change is needed for this function.

---

## 6. Dependency Graph — Before and After

**Before (current):**
```
EideticLib → LatticeLib
NeuronKit → EideticLib
SubstrateLib (no local deps)
```

**After (FDC encoder):**
```
EideticLib → SubstrateLib  (for FloatSimHash in Step 4)
NeuronKit → EideticLib
LatticeLib    (standalone, no longer imported by EideticLib)
SubstrateLib (no local deps)
tools/seed-generator  (maintainer only, not in the shipped graph)
tools/pool-reducer    (maintainer only, not in the shipped graph)
```

The import cycle risk (EideticLib ↔ LatticeLib) is eliminated by
construction. EideticLib reads static JSON files it bundles; it does not
import LatticeLib's types.

---

## 7. What Does Not Change

- EideticLib's public API (`lookup(_ term: String) -> Anchor`) is
  unchanged. The `Anchor` type is unchanged. Callers see no difference.
- SubstrateLib's public API is unchanged.
- NeuronKit's dependency on EideticLib is unchanged.
- LatticeLib remains in the repository for consumers of MDCC codes.
- The cross-language conformance discipline (shared test vectors between
  Swift and Rust ports) continues to apply to EideticLib.

---

## 8. Open Item — STOP_THRESHOLD

Step 5's descent halts when no child signature overlap meets
`STOP_THRESHOLD`. This value is a pinned parameter: two parties using
different values can diverge at depth. The value is not yet specified.
It must be determined empirically against the real signatures once the
Seed Generator produces them, committed as a named constant in
`FDC_ENCODER_CANONICAL.md` §4, and documented here. This is the
one remaining open item before the encoder specification is complete.
