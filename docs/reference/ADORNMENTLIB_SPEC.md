---
title: AdornmentLib Specification
version: 0.7.0
status: active
date: 2026-08-26
description: "Behavioral specification for AdornmentLib: minter recipes (composed model-pN-sN identities, cross-port digests, text|json output normalizer), adornment validators (mint-path excluded), generator seam with silent mechanical truncation and map-reduce chunking, minter identity and activation values, stored-adornment values, and the ADORNMENT_MAX_LENGTH constant."
spec_type: library
authors: MOOTx01 maintainers
package: AdornmentLib
languages: [swift, rust]
relates_to:
  - docs/reference/ADORNMENTLIB_INTERFACE.md
  - docs/reference/LOCUSKIT_SPEC.md
  - docs/reference/GENIUSLOCUSKIT_SPEC.md
  - benchmark-ee/benchmarks/payload-economics.md
---

# AdornmentLib Specification

## 1. Purpose

AdornmentLib is a standalone library package containing:

1. **AdornmentValidators** — the AV-1..AV-8 validation gate for adornment
   candidates (moved from NeuronKit `MarkerValidators`, renamed).
2. **AdornmentGenerator** — the MOOT_MINT_CMD command seam that invokes an
   external binary (stdin prompt → stdout text).
3. **`ADORNMENT_MAX_LENGTH`** — the canonical character-count ceiling constant
   (280; provisional pending the judging-density study).
4. **Adornment identity values:** pure values for one registered minter and
   one stored adornment. The values let the product store minter configuration
   once and reference it from every adornment the minter produces.

The library has no kit dependencies — both NeuronKit-level and GLK-level
code import it without layer inversion. Its external crates carry C-1
per-crate approval (the candle stack, tokenizers, libc, and serde_json
for the Rust quantized engine and JSON normalizer; Bob 2026-08-26).

## 2. AdornmentValidators (AV-1..AV-8)

Moved from `NeuronKit.MarkerValidators` (MV-1..MV-8). Validation logic
is unchanged; only the names and module location changed.

### 2.1 Golden pins (both ports, same vectors)

| Pin | Input | Expected result |
|---|---|---|
| AV-1 | entity in source text | `containsWordBoundary` → true |
| AV-2 | entity NOT in source | `containsWordBoundary` → false |
| AV-3 | partial word match | `containsWordBoundary` → false |
| AV-4 | count matches source | `validateCount` → true |
| AV-5 | count NOT in source | `validateCount` → false |
| AV-6 | year in claim in source | `validateDate` → true |
| AV-7 | year in claim NOT in source | `validateDate` → false |
| AV-8 | no year in claim | `validateDate` → true (no date = no gate) |

### 2.2 Invariants

- Each validator function is pure (no I/O, no side effects).
- All three functions are `@Sendable` closures in Swift; free functions in Rust.
- **Mint-path exclusion (SPEC_ADORNMENT § 8, rulings 2026-08-24/25):** the
  validators are NOT called on the adornment mint path. The production
  AdornmentPass constrains the minting model by INSTRUCTION, never by
  post-hoc mechanical rejection. The library remains available to other
  consumers.

## 3. AdornmentGenerator (seam)

### 3.1 Command seam

`invokeAdornmentCommand(prompt:maxLength:) async -> String?`

Reads `MOOT_MINT_CMD` from the environment. When unset or empty, returns nil
immediately (no subprocess). When set, invokes the binary as a subprocess with
the prompt as stdin and captures stdout as the candidate text.

Output handling: nil when the command is absent, exits non-zero, or emits
non-UTF-8 or empty output (the (drawer, minter) pair stays missing).
Non-empty output is SILENTLY MECHANICALLY TRUNCATED to `maxLength`
characters — the prompt never mentions truncation; the ceiling is enforced
in code. Over-length rejection does not exist.

### 3.2 Prompt template (SPEC_ADORNMENT §§ 2b + 8)

`buildAdornmentPrompt(drawerContent:eventDate:maxLength:) -> String`

Constructs the prompt string passed to the adornment binary. Contract:
- Output shape is WORD BLOBS, not sentences: one dense line of 2–3-word
  chunks separated by `; `, densest knowledge first, decreasing importance.
- All named entities spelled in full (no pronouns, no relative references).
- Dates ONLY when available in the prompt data: stated in the record, or
  calculable from a natural-language reference plus the supplied record
  date (`Record date:` line, emitted only when `eventDate` is provided).
  Never invent a date.
- Counts as numbers only when the record states them.
- No opinion, narrative, or commentary.
- Length is a SOFT ask ("Results should be under N characters, less is
  better") — the ceiling is enforced by § 3.1's mechanical truncation.

### 3.3 Map-reduce chunking

`mintAdornmentMapReduce(...)` / `mint_adornment_map_reduce(...)` with
`ADORNMENT_CHUNK_THRESHOLD = 16_000` characters: a record exceeding the
threshold is split into deterministic line-boundary pieces, each piece is
minted, the piece results are concatenated and re-summarized through the
model for the final blob line. The threshold derives from the tightest
miner window (apple-mint 8192-token context at a 4-bytes-per-token floor).

The template is declared in SPEC_ADORNMENT §2b as amended by §8.

## 4. Minter identity and stored adornments

Adornment text is model-generated and is not assumed deterministic. A model
family is therefore not a sufficient benchmark identity: model revision,
prompt, parameters, and generation run can each change the produced text.

### 4.1 Two values

**AdornmentMinterDescriptor** represents one row in the minter master table:

- opaque descriptor identifier assigned by the persistence owner;
- stable human-readable minter name;
- minter family;
- model identifier;
- model version or revision;
- prompt-template digest; and
- every generation-affecting parameter, represented as a string-to-string
  map and canonically ordered by key when serialized; and
- runtime-active state.

**StoredAdornment** is one persistent output. It contains exactly the existing
Drawer identifier, the producing minter identifier, and the adornment text.
Drawer content, subject, SSC (Semantic Search Candle) facts, timestamps,
location, retrieval state, and
minter metadata are references to their owning records and MUST NOT be copied
into this value.

### 4.2 Identity and storage invariants

- A minter descriptor includes every generation input that can intentionally
  change output. A configuration change creates a new descriptor identity;
  activation is the only mutable field on an existing descriptor.
- The descriptor identifier references that complete configuration record; it
  is not derived from or repeated inside the adornment text.
- Within one estate there is at most one stored adornment for a given
  `(Drawer identifier, minter identifier)` pair.
- The exact generated text is the only per-Drawer model output that must be
  stored; shared provenance is stored once and referenced.
- Every production adornment lives in the normalized adornment table. The
  Drawer row carries no adornment text and no minter-selection state.
- Zero, one, or many minter descriptors MAY be active. Neither Apple nor
  Candle seats are hard-coded into this value contract.
- AdornmentLib owns the cross-port value semantics only. LocusKit owns the
  minter-master and adornment tables. GeniusLocusKit owns dreaming and result
  composition over the active set.

## 5. ADORNMENT_MAX_LENGTH

`public let ADORNMENT_MAX_LENGTH: Int = 280`

Provisional length ceiling (both ports). Comment in both files:
"provisional pending the judging-density study, SPEC §2". When the study
concludes, a single constant update propagates to all call sites.

## 6. Language invariants

- Swift: all functions in `AdornmentLib` module are `public`.
- Rust: all functions in `adornment_lib` crate are `pub`.
- Both ports produce byte-identical outcomes on the AV-1..AV-8 golden pins.
- Swift and Rust expose value-equivalent minter and stored-adornment values.
  Identifier fields are opaque strings so this library
  does not import a storage or estate package.

## 7. Ownership boundary

AdornmentLib can construct prompts, invoke a configured command, validate
candidates, and carry minter and adornment values. It opens no database and
does not choose active minters.

LocusKit normatively owns the permanent normalized tables and runtime-active
state. GeniusLocusKit reads that state for both dreaming and result composition.
Payload Economics changes the active rows or reads named minter rows through
those production contracts; it owns no alternative-adornment sidecar.

## Gold miner (0.5.0)

The gold miner is the resident, engine-pluggable mint surface. Its
requirements are contractual (Bob, 2026-08-26):

1. EVERY record in the database must be adorned — coverage is a MUST,
   enforced by the debt model: a missing (drawer, active-minter) pair
   stays in debt until minted.
2. Sustained single-record ingest (hundreds of writes/hour) and bulk
   import both feed the miner.
3. The miner is RESIDENT at all times — never load-on-demand — and must
   not consume gigabytes.
4. One residency serves BOTH one-off mining (impatient writes) and batch
   mining (dreaming passes; imports may defer to dreaming).
5. Swift uses Apple's on-device model — the ONLY engine on iOS, the
   DEFAULT on macOS. The Rust port carries its own equivalent small
   local engine.

The ENGINE is a plug (`GoldMinerEngine`): everything above it — resident
owner, mint entry points, the adornment pass, map-reduce, mechanical
truncation — is engine-agnostic. Swapping models is implementing one
protocol/trait, never a rewrite.

Engines shipped:

- **Apple on-device** (Swift): FoundationModels, weights OS-resident —
  effectively zero added footprint. iOS-only engine; macOS default.
- **Quantized local LLM** (Rust): GGUF Q4 Qwen2-family model in-process
  through candle's quantized kernels (vendored lean model file holds the
  embedding table at F16). Measured on Qwen2-0.5B-Instruct Q4_K_M:
  **705 MB resident after load, 722 MB after minting**, enforced by a
  budget test that fails above a 1 GiB delta. The hosting process must
  launch with `MallocLargeCache=0` on macOS (the allocator's large-chunk
  cache otherwise retains ~830 MB of freed load transients). Model files
  load from `<data>/goldminer/{model.gguf, tokenizer.json}`; any
  Qwen2-family GGUF runs without engine-code changes, and the artifact
  choice is governed by the recipe constants (§ Minter recipes) — an
  artifact swap changes the recipe's model token in the same commit.
- **Command seam** (macOS only): the MOOT_MINT_CMD subprocess contract,
  retained as the benchmark-harness vehicle, never the product default.

## Minter recipes (0.6.0)

A RECIPE is the complete generation contract of one product minter:
model artifact + prompt template + generation settings + output payload
kind. Recipes are COMPILE-TIME constants in source (`MinterRecipe.swift`
/ `minter_recipe.rs`), under a version-ledger comment header; model
choice is a developer build-time decision (Bob, 2026-08-26) — no runtime
model discovery, no user-facing swap surface in this edition.

Rules:

1. **Composed identity.** The minter identity is
   `<model>-p<promptVersion>-s<settingsVersion>` (e.g.
   `qwen2-0.5b-q4km-p1-s1`, `apple-fm-p1-s1`). This exact string is the
   engine identity, the `adornment_minters` master `name`, and the
   identity every adornment row is attributed to. The identity names the
   generation CONTRACT, never the executing port: Swift and Rust minting
   the same recipe are ONE minter — rows are interchangeable across
   ports and sync freely (adornment output is non-deterministic data,
   minted once per pair, never recomputed for comparison).
2. **Version discipline** (mirror of the bitmap-bit doctrine): any
   prompt-template change bumps pN; any generation-affecting setting
   change bumps sN; a different model artifact is a different model
   token. Bump in the same commit as the change. NEVER reuse a version
   number — estates may carry rows minted under a retired version.
   Git is the recipe-content history; the estate's master rows (with
   digests) are the identity history.
3. **Digests.** `promptDigest` is FNV-1a-64 hex over the chat template
   with `{system}` resolved (covering instruction text AND wrapper
   shape); `parametersDigest` covers the canonical settings serialization
   (lexical key order, `key=value` lines). Both ports produce identical
   digests (golden-pinned). Registration compares live digests against
   the stored master row, making an un-bumped recipe edit mechanically
   detectable. The digests are fingerprints for mismatch detection, not
   cryptographic commitments.
4. **Output normalizer.** Model emissions come in exactly two shapes —
   a prose line (`text`) or JSON (`json`) — and ONE normalizer handles
   both: text takes the first meaningful line (fences, list markers,
   control tokens stripped); JSON is flattened deterministically
   (lexical key order, nested values recursed, fragments joined with
   `"; "`; unparseable JSON falls back to the text path). Adding a model
   of either shape is a recipe entry, never new normalizer code.
5. **Apple wrinkle.** Apple's weights are OS-resident and move with OS
   updates, so `apple-fm`'s model token is coarser than GGUF families by
   platform necessity; the OS/framework version is registration-time
   provenance, not identity.

## Resident batch minting (0.4.0)

The generation seam runs in two modes. One-shot (default): one spawn per
prompt — correct for the resident daemon's small hourly fires, where
process isolation is worth a model load. Resident batch
(capability-probe selected): the seam runs `CMD --mint-capabilities`
once per command — a minter listing "batch" is spawned once with
`--batch` and
serves NUL-framed prompts for the life of the batch, amortizing the
model load across every pair a pass mints. Failure isolation is
per-prompt (bare-NUL marker → pair retried); a torn session or a changed
`MOOT_MINT_CMD` tears the child down and the next call respawns. The
Swift session reaps an idle child after 120 s so model residency is
released between dream-time fires. Both minters (candle-mint,
apple-mint) implement `--batch`; the one-shot contract is unchanged and
remains the minimum a third-party minter must implement.

## Changelog

- 0.7.0 (2026-08-26): Recipes carry the full prompt wrapper —
  `chat_template` with `{system}`/`{input}` placeholders (chatml for the
  Qwen2 family; NuExtract's plain format is a recipe entry; session
  engines carry the trivial wrapper). `prompt_digest` now covers the
  wrapper. Engine loads accept an explicit recipe
  (`load_with_recipe`) for comparison builds; the judge-off bakes one
  recipe per binary at build time.

- 0.6.0 (2026-08-26): Minter recipes — compile-time recipe constants,
  composed `<model>-pN-sN` identities (cross-port, port-agnostic),
  FNV-1a-64 recipe digests, generic text|json output normalizer (see
  § Minter recipes). Engine identities are now recipe IDs.

- 0.5.0 (2026-08-26): Gold miner — resident engine-pluggable mint
  surface, both ports (see section above).

- 0.4.1 (2026-08-26): Batch selection via capability probe; env seam
  removed pre-release (env vars are not viable for end users — Bob).
- 0.4.0 (2026-08-26): Resident batch minting mode (see section above).

### 0.3.1 -- 2026-08-26

Vocabulary (mission SSC-RENAME): SSC defined at its use in the
stored-adornment reference list — Semantic Search Candle. Terminology
only; no value-contract change.


### 0.3.0 -- 2026-08-25

Aligned §§ 2–3 with the SPEC_ADORNMENT § 8 rulings (which supersede any
conflicting text): validators carry a mint-path exclusion (instruction,
never post-hoc rejection); over-length rejection replaced by silent
mechanical truncation at the generator; prompt contract updated to the
shipped template (word blobs, record-date line, dates only from prompt
data, soft length ask); documented the shipped map-reduce chunking
surface (mintAdornmentMapReduce, ADORNMENT_CHUNK_THRESHOLD = 16_000).
Matches slice-C code (b87b6a859); no behavioral change.

### 0.2.0 -- 2026-08-25

Added pure minter and stored-adornment value contracts. Minter configuration
and activation are referenced from a permanent normalized adornment store;
there is no benchmark-only variant store and no canonical adornment column on
the Drawer.

### 0.1.0 -- 2026-08-23

Initial release. AdornmentValidators AV-1..AV-8 (moved from NeuronKit
MarkerValidators MV-1..MV-8), AdornmentGenerator MOOT_MINT_CMD seam,
ADORNMENT_MAX_LENGTH = 280 (provisional).
