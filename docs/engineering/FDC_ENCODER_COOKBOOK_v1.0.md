---
title: FDC Encoder Engineering Cookbook
version: 1.0
status: implementation-grade specification
author: MOOTx01 maintainers
date: 2026-06-01
revision_note: revised to shipped reality (idf scoring, encode/encodeAnchor, inert STOP_THRESHOLD, Swift↔Rust scalar conformance)
relates_to:
  - docs/reference/FDC_ENCODER_CANONICAL_v1.0.md (canonical spec; the contract)
  - docs/decisions/DECISION_FDC_ENCODER_KIT_PROVENANCE_2026-05-25.md (kit ownership)
  - CONTRIBUTING.md (language extension and pool contribution guide)
---

# FDC Encoder Engineering Cookbook — v1.0

## §0. Frame

This document specifies the FDC encoder at implementation grade. It is
a contract plus the algorithms that satisfy the contract. An implementer
reads this and ships code. The canonical spec (`FDC_ENCODER_CANONICAL_v1.0.md`)
states what the encoder does and why. This cookbook states how to build it.

Where this document is silent, the canonical spec applies. Where they
conflict, this document is wrong and the canonical spec governs — file
a bug.

**One bagging pass. Two entry points.**

    FDC.encode(text: String)       -> FDCCode?                    // nil == UNRESOLVED
    FDC.encodeAnchor(text: String) -> (code: FDCCode?, conceptQID: String?)

`encode` is the thin form (`encodeAnchor(text).code`). `encodeAnchor` also
surfaces the dominant concept Q-ID — the highest-weighted Wikidata Q-ID in the
concept bag (ties → lowest Q-ID), or `nil` — which `EideticLib.lookup` carries
as the Anchor's `wikidataQID`. There is no "trail" return.

Pure function. No I/O. No clock. No RNG. No network. No learned model.
Same input and same pinned artifacts yield bit-identical output on every
platform and in both the Swift and Rust ports.

---

## §1. Pinned Artifacts

The pinned JSON artifacts ship in `Sources/LatticeLib/Resources/`:
`FDCFrame.json`, `FDCSignatures.json`, `WordClassTable.json`, and the
canonicalization `Lexicon.json` (§3.1). All are produced by the Seed
Generator (`tools/seed-generator/`) and committed to the repository.
LatticeLib's FDC runtime (`FDC`, `WordClassTableCache`) parses them once on
first use and caches the parsed result for the process lifetime.

### §1.1. FDCFrame.json

The FDC code list. Schema:

```json
{
  "frame_version": "1.0.0",
  "codes": [
    { "code": "006.6", "label": "Computer programming" },
    ...
  ]
}
```

Ancestry is derived from the decimal string at runtime. The parent of
`006.6` is `006`; the parent of `006` is `000`. No explicit parent
field is stored. `fdc_frame.children(node)` returns all codes whose
decimal prefix equals `node` plus one additional segment.

### §1.2. FDCSignatures.json

The per-code signature. The runtime matcher (§5.2/§6) tests term
*membership* only, never the source weights, so the **bundled** artifact is
the compact membership form — a sorted term list per code:

```json
{
  "version": "1.0.0",
  "source_weights": { "label": 3, "title": 2, "article": 1 },
  "codes": [
    { "code": "006.6", "terms": ["Q7397", "Q80006", "graphics", ...] },
    ...
  ]
}
```

Terms are concept IDs (Wikidata Q-IDs) or unresolved surface forms. Each
code's term set already includes its ancestors' terms (build-time
inheritance, §7.1); the descent step does not re-accumulate ancestors at
runtime.

The Seed Generator's intermediate `Data/FDCSignatures.json` is the *weighted*
form (`{ "signatures": { code: { term: weight } } }`); `Data/_compact.sh`
reduces it to the bundled membership form above. The SimHash fingerprint
(§5.1) is not yet produced and is absent from both forms.

### §1.3. WordClassTable.json

The static noun/verb lookup table. Schema:

```json
{
  "table_version": "1.0.0",
  "min_os_version": "17.0",
  "snapshot_date": "2026-05-25",
  "nouns": ["dinner", "wife", "carburetor", ...],
  "verbs": ["run", "compile", "encode", ...]
}
```

`snapshot_date` is the cutoff for pool-cache purge on table update.
`min_os_version` is the NLTagger version that produced this table; it
is a pinned parameter of the encoder contract.

---

## §2. Step 1 — Extract Nouns and Verbs with Counts

**Contract:** `step1(text) -> {surfaceForm: Int}`

Returns the surface forms that are nouns or verbs, each with its
occurrence count. Deterministic: identical text yields identical counts.

### §2.1. Fast Path — Static Table Lookup

For each token produced by Unicode word-boundary segmentation (UAX 29):

1. Lowercase the token.
2. Look it up in `WordClassTable.nouns` and `WordClassTable.verbs`.
3. If found as noun or verb, increment `counts[token]`.
4. If not found, fall to §2.2.

The fast path covers the vast majority of tokens. It requires no OS
framework and runs identically on all platforms.

### §2.2. Fallback — Platform Tagger

For tokens not in the static table:

**Apple platforms:** invoke `NLTagger` with `.lexicalClass`. The tagger
version is pinned by `WordClassTable.min_os_version`; builds targeting
a lower OS version must use the static table only and mark the token
unresolved rather than invoke an older tagger.

**Non-Apple platforms:** invoke the HMM/Viterbi tagger trained on the
Penn Treebank tag set. The tagger is bundled as a small compiled
artifact; it is not a runtime dependency. Tag the token, record the
result.

**After tagging (both platforms):**

1. Add `(token, tag)` to the local `novel_cache`.
2. If `novel_cache.count >= 50`: submit the cache to the pool endpoint
   and drain it. The pool endpoint is a config value; submission is
   fire-and-forget with no retry obligation.
3. If the tag is `NOUN` or `VERB`, increment `counts[token]`.

### §2.3. Pool Submission Wire Format

```json
{
  "table_version": "1.0.0",
  "platform": "apple" | "other",
  "tagger_version": "<NLTagger OS version or HMM/Viterbi version string>",
  "entries": [
    { "token": "carburetor", "tag": "NOUN" },
    ...
  ]
}
```

The server validates `table_version` matches the current shipping table.
Submissions against a stale table version are discarded.

---

## §3. Step 2 — Canonicalize to Concept IDs

**Contract:** `step2(counts) -> {key: Int}` where `key` is a concept ID
or an unresolved surface form.

### §3.1. Canonicalization Lexicon

The lexicon is a flat map: `lemma -> conceptID`. It is built from two
sources merged into one pinned snapshot (see §3.1.1 for the build
procedure):

- **Wikidata alias table (CC0).** Aliases from Wikidata's `skos:altLabel`
  and `rdfs:label` properties for the relevant concept set. Maps surface
  forms and their lemmas to Wikidata Q-IDs.
- **WordNet (Princeton, public domain).** Synonym sets (synsets) and
  lemma forms. Maps WordNet synset members to the Wikidata Q-ID of the
  corresponding concept where a Wikidata mapping exists; where no mapping
  exists, maps to the WordNet synset ID as a stable internal concept ID.

The lexicon is language-scoped. The English lexicon ships by default.
Additional language lexicons follow the same format; see CONTRIBUTING.

### §3.1.1. Lexicon Build Procedure

Produced by `LexiconBuilder` (LatticeLib), wrapped by the `lexicon-builder`
maintainer CLI (`tools/seed-generator`). Inputs: the WordNet `dict/` index
files and a Wikidata P8814 extraction TSV (columns: item, wn, label, alias).
The build is pure and deterministic — same inputs yield a byte-identical
artifact across runs and machines.

1. **Parse Wikidata.** From each row take the Q-ID, the WordNet synset ID
   (`<offset>-<pos>`, the value of property P8814), and the surface forms
   (`rdfs:label` + `skos:altLabel`). Build `synset -> Q-ID` and the
   `surface -> Q-ID` candidate list.
2. **Parse WordNet.** From each `index.*` line take the lemma and its synset
   offsets in frequency order (sense 0 = primary). Skip multi-word lemmas
   (underscore). Each `(lemma, synsetID, senseIndex)` maps to the synset's
   Q-ID where one exists (via P8814), else to `wn:<synsetID>`.
3. **Derive keys.** For each surface form, key =
   `Stemmer.stem(Normalizer.normalize(token))` — identical to the runtime
   Step 2, so build-time and runtime keys agree bit-for-bit. Only single-token
   surfaces are indexed (the runtime looks up one stemmed token at a time);
   multi-word forms are skipped.
4. **Resolve conflicts** — Wikidata-primary, WordNet-disambiguated (§2:
   "Wikidata provides the concept IDs; WordNet fills the coverage gaps").
   Deterministic and order-independent. A Q-ID is the concept identity whenever
   one exists; the `wn:<synset>` fallback is used only when no sense of the word
   maps to any Q-ID. Tiers, lowest wins:
   1. A Q-ID reached via a **WordNet sense of the word** — frequency-ranked, so
      WordNet disambiguates which Q-ID a common word means (`dog` → Q144, the
      animal at sense 0, not the sausage sense). Ties: lowest sense rank, then
      surface support, then lowest Q-number.
   2. A Q-ID from a **Wikidata alias only** (no WordNet sense for the key —
      named entities, multilingual). Ties: most support, then lowest Q-number.
   3. A `wn:<synset>` fallback — only when no Q-ID exists for the concept.
      Ties: lowest sense rank, then lowest synset ID.

The pinned lexicon version is part of the agreement protocol (§3.2): two
encoders must share it or their bags can diverge.

### §3.2. Algorithm

For each `(surface, n)` in `counts`:

1. `lemma = lemmatize(surface)` — apply Porter2 stemming (the Snowball
   implementation in LatticeLib's `Stemmer.swift`).
2. `concept = lexicon[lemma]` — exact lookup against the pinned lexicon.
3. If `concept` is non-nil: `bag[concept] += n`.
4. If `concept` is nil: `bag[surface] += n`. The surface form is kept as
   a string key. It will contribute to scoring only if a code signature
   contains the exact same string.

**Why load-bearing.** Step 2 is where two devices running independently
converge or diverge. If both use the same pinned lexicon, synonyms
collapse identically and the bags match. If lexicon versions differ, the
bags can diverge. The lexicon version must be part of any shared
agreement protocol.

**Step 1 relaxation — entity recovery.** Step 1 normally keeps only nouns and
verbs. Named entities (place names, organizations, specific works) are highly
discriminative, but proper-noun POS tagging is unreliable and *diverges across
platforms* (Apple `NLTagger` vs the non-Apple HMM/Viterbi tagger). So Step 1
additionally keeps any token whose lemma resolves to a Wikidata **Q-ID** in the
pinned lexicon. Crucially, that admission is decided from the pinned lexicon —
deterministic and identical build-and-runtime — so it recovers entity coverage
*without* weakening the agreement property; it actually removes those tokens
from the platform-dependent tagger path. Tokens that are neither noun/verb nor a
Q-ID concept are still dropped. (`wn:` fallback hits are not admitted by this
rule — only Q-IDs, the named-entity identities.)

---

## §4. Step 3 — Weighted Concept Bag

Step 3 is the accumulation already performed in Step 2. It is named
separately because the bag is the product passed to Step 4, and its
shape is the contract:

    bag: { conceptID | surfaceForm -> Int }

Frequency is signal. A concept appearing five times in the text carries
five times the weight of one appearing once. Do not normalize. Do not
cap. Pass the raw accumulated counts to Step 4.

---

## §5. Step 4 — Match and Score

**Contract:** `step4(bag) -> {FDCCode: Weight}` or `UNRESOLVED`.

### §5.1. SimHash Pre-filter (Long Input Only)

If `text.wordCount > LONG_INPUT_THRESHOLD` (default: 500 words):

1. Compute a deterministic feature hash of `bag.keys()` using
   `SubstrateML.FloatSimHash` with a fixed seed (`FDC_ENCODER_SEED =
   0xFDC_EN_C0DE_2026`). The feature vector is the sorted concept IDs
   mapped to floats by a stable bijection (e.g., index in the sorted
   concept vocabulary).
2. Compute the SimHash fingerprint: a 256-bit value from
   `SubstrateML.Fingerprint256`.
3. Filter `signatures` to the subset whose pre-computed fingerprints are
   within `SIMHASH_HAMMING_THRESHOLD` (default: 64) bits of the input
   fingerprint.
4. Pass only the filtered candidate set to §5.2.

For short input, pass all signatures to §5.2 directly. The pre-filter
is a speed optimization only; it must not change which code is returned
for any input. If in doubt, skip the pre-filter.

The SimHash pre-filter is **not yet implemented**: no fingerprints are
computed at build time and the runtime applies no pre-filter (it scores
against all signatures, §5.2). When added, per-code fingerprints
(hex-encoded 256-bit) ship alongside the term sets; until then this section
is forward-looking.

### §5.2. Aho-Corasick Single-Pass Match

Build the Aho-Corasick automaton once from all concept IDs and surface
forms that appear in any code signature. Cache it for the process
lifetime alongside the parsed artifacts (§1).

LatticeLib (`FDCMatcher`) implements this as a single-pass inverted-index
scan — a `term -> codes` index built once from the signatures, then for each
bag term the codes carrying it are scored. This is the deterministic
equivalent of the Aho-Corasick scan over concept-ID keys: both report exactly
the signature terms present in the bag and the codes they belong to.

For each call to `step4`:

1. Run `ac_automaton.scan(bag.keys())`. The automaton reports every
   signature term that appears in the bag, along with which codes that
   term belongs to.
2. For each code reported, accumulate:

   ```
   score[code] += bag[term] for each term in (bag ∩ signatures[code])
   ```

3. If `score` is empty after the scan: return `UNRESOLVED`. The encoder
   never assigns a code by guessing.

### §5.3. Score Representation

Ties are broken by lowest code value string-lexicographically (e.g., `"100"`
beats `"200"`). The argmax winner is the returned code; there is no score-sorted
"trail" in the shipped surface (the extra `encodeAnchor` returns is the dominant
concept Q-ID, §0).

**Shipped scoring — IDF-weighted (Mission #4).** The raw-overlap sum above
(`score[code] += bag[term]`) lets codes with large signatures win on breadth.
The shipped runtime (`FDC`, via `FDCMatcher(scoreMode: .idf)`) weights each
shared term by its inverse document frequency:

```
score[code] = Σ_{t ∈ bag ∩ sig(code)} bag[t] · idf(t)
idf(t)      = ln(N / df(t))     # N = total code signatures, df(t) = # signatures containing t
```

so a concept term present in many signatures contributes little and a
distinctive one dominates. `idf` is precomputed once from the pinned signatures
at load (deterministic, no new artifact). It was the best of the measured
variants (raw / idf / cosine / idf-cosine), lifting within-region selection on
the v1.0 frame (exact 31→36%, wrong-branch 63→58%). `score` is therefore
`FDCCode -> Double`, and the **same scheme is applied to the §6 descent
ranking** (the §6.1 cutoff still gates on the raw integer overlap, so its
meaning is mode-independent). The matcher *default* stays `.raw` (the literal
sum above). **Determinism:** the IDF-weighted sums are accumulated in sorted
term order (float addition is non-associative), keeping the result bit-identical
across runs and across the Swift/Rust ports. The full scoring spec is in
`FDC_ENCODER_CANONICAL_v1.0.md` §5.

---

## §6. Step 5 — Frame Descent

**Contract:** `step5(score, bag) -> FDCCode`

### §6.1. Algorithm

```
node = argmax(score)                     # highest-scoring code; tie → lowest code value
loop:
    children = fdc_frame.children(node)  # codes whose decimal prefix = node + one segment
    best = None
    best_overlap = 0
    for child in children:
        overlap = sum(bag[k] for k in bag if k in signatures[child])
        if overlap >= STOP_THRESHOLD:
            if overlap > best_overlap or (overlap == best_overlap and child < best):
                best = child
                best_overlap = overlap
    if best is None: break
    node = best
return node
```

`STOP_THRESHOLD` is **pinned at 1** and is **empirically inert** on the v1.0
frame: a sweep over 1…200 against the shipped signatures produced identical
results. The frame is shallow — most codes are integer-head, average encoded
depth ~1.3 — so the Step-5 descent rarely fires and the cutoff value does not
change the outcome. Accuracy is governed by the within-region IDF scoring
(§5.3), not this cutoff. It is committed as the named constant `1` in both ports
(`FDC.stopThreshold` / `STOP_THRESHOLD`) and the resolution is recorded in
`FDC_ENCODER_CANONICAL_v1.0.md` §5. The cutoff compares against the **raw integer
overlap** (`Σ bag[t]`), so its meaning is independent of the §5.3 score mode.

### §6.2. Children Derivation

`fdc_frame.children(node)` returns all codes `c` in `FDCFrame.json`
such that:

- `c` starts with `node` as a prefix.
- After removing the prefix, `c` contains exactly one additional
  decimal segment (digits optionally followed by one period and more
  digits, but no further period).

Examples: children of `"006"` include `"006.6"` but not `"006.6.1"`.
Children of `"000"` include `"001"`, `"002"`, `"003"` etc. but not
`"006.6"`.

---

## §7. Build-Time: Producing the Signatures

The Seed Generator (`tools/seed-generator/`) produces `FDCSignatures.json`.
This section specifies what it must compute.

### §7.1. Per-Code Signature

For each FDC code `c`:

1. Collect three source texts:
   - `label_text`: the code's label string from `fdc.txt`.
   - `title_text`: the Wikipedia article title for the code's LCSH
     heading (resolved via the LCSH→Wikipedia title mapping).
   - `article_text`: the LexRank-reduced Wikipedia article body (§7.2).

2. Run Steps 1–3 over each source text independently, producing three
   partial bags: `label_bag`, `title_bag`, `article_bag`.

3. Merge with source-type weights (pinned in `FDCSignatures.json` under
   `source_weights`):

   ```
   sig[c] = {}
   for key, w in label_bag:   sig[c][key] += w * source_weights.label
   for key, w in title_bag:   sig[c][key] += w * source_weights.title
   for key, w in article_bag: sig[c][key] += w * source_weights.article
   ```

4. Inherit ancestors' terms:

   ```
   for ancestor in ancestors(c):        # ancestors = all prefixes, root first
       for key, w in sig[ancestor]:
           sig[c][key] += w
   ```

   Ancestors are processed root-first so the most specific code carries
   the full accumulated weight of its lineage.

5. *(Deferred)* The SimHash fingerprint of `sig[c]` (§5.1) is not yet
   computed; the current Seed Generator stops after ancestor inheritance.
   When the pre-filter is implemented, the fingerprint is computed here and
   stored alongside the bag.

### §7.1.1. Resolve-First Article Fill (gap codes)

Some codes' LCSH headings do not auto-resolve to a Wikipedia title via the
heading→title mapping (often because the FDC label carries no quoted LCSH
heading at all). Without a title these codes get no `title_text` /
`article_text`, leaving the signature as the label alone — too thin to be
reachable at runtime.

These gap codes are filled **resolve-first**: for each, an LLM proposes the
single best-matching real Wikipedia article title, recorded in
`Data/_gap_titles.tsv` (`code \t title`, committed as a frozen, auditable
input). Each proposed title is validated by fetching its article extract
(`Data/_pull_gap.sh`); only a title that returns no article would fall through
to a generated description. The signature builder applies the map via a
`code → title` override (`--gaptitles`), keyed by FDC code so it works
regardless of the label's quoted-heading extraction.

The model's role is limited to *selecting which Wikipedia article to pull* — no
model-generated text enters a signature. Every shipped signature term remains
sourced from the FDC label, the Wikipedia title, or the Wikipedia article body.
This fill brought article-source coverage to all 1071 codes (from 793).
Whether a now-reachable code is *selected accurately* is governed by
`STOP_THRESHOLD` and score normalization (§5–§6), which remain pinned tuning
items.

### §7.2. LexRank Article Reduction

LexRank reduces a Wikipedia article to its N most central sentences
before Steps 1–3 run over the article. N defaults to 10 sentences.
LexRank is implemented in Swift (`LatticeLib.LexRank`): NLTokenizer
sentence segmentation → per-sentence TF vectors → cosine-similarity
adjacency → `SubstrateML.EigenvalueCentrality` (the PageRank eigenvector)
→ the top-N most central sentences in original order. No external
summarizer and no Python. The output is the N selected sentences
concatenated into a single string, passed to Steps 1–3.

LexRank is run at Seed Generator time only. It is never invoked at
runtime.

### §7.3. Word-Class Table Production

The Seed Generator also produces `WordClassTable.json`:

1. Download a large Wikipedia article corpus (the same corpus used for
   article reduction, or a separate random sample of at least 100,000
   articles).
2. Run Apple's `NLTagger` with `.lexicalClass` over every sentence in
   the corpus.
3. Record every token tagged `Noun` or `Verb`. Deduplicate. Lowercase.
4. Write the deduped sets to `WordClassTable.nouns` and
   `WordClassTable.verbs`.
5. Record the `min_os_version` (the macOS/iOS version the NLTagger was
   running on) and the `snapshot_date`.

The HMM/Viterbi tagger on non-Apple platforms is trained on the Penn
Treebank corpus and is not produced by the Seed Generator. It is a
bundled compiled artifact versioned separately.

---

## §8. Cross-Platform Conformance

The shipped conformance property is **Swift-scalar == Rust-scalar**: both ports
produce identical `encode` / `encodeAnchor` output for identical input and
identical pinned artifacts. This is a pure string/concept-ID algorithm — there
is no Metal or BLAS dimension and no SIMD kernel to conform; the only cross-port
determinism concern is float-summation order in the IDF scoring (§5.3), which
both ports pin by summing in sorted term order.

Conformance is enforced by a committed fixture
(`rust/tests/fixtures/fdc_conformance.json`, **52/52 passing**), each entry an
input with its expected code:

```json
[
  { "input": "Dinner with my wife at Guidos", "expected_code": "642" },
  ...
]
```

Any divergence between ports is a hard conformance failure and blocks release.

The cross-platform-*guaranteed* surface is the static word-class table plus the
pinned lexicon and signatures: any token resolved through them is bit-identical
everywhere. Novel-token tagging is platform-divergent **by design** (Apple
`NLTagger` vs the non-Apple HMM/Viterbi stub) and is deliberately kept off the
agreement-bearing path; the §3.2 Q-ID relaxation further moves named entities
onto the deterministic lexicon path.

Conformance also applies across lexicon versions: a vector produced
against lexicon v1.0 must continue to pass against lexicon v1.0
indefinitely. A lexicon version bump generates new vectors; old vectors
are retained.

---

## §9. Pinned Constants

| Constant | Value | Notes |
|---|---|---|
| `SOURCE_WEIGHTS.label` | 3 | Highest; FDC label is most precise |
| `SOURCE_WEIGHTS.title` | 2 | Medium; article title is authoritative |
| `SOURCE_WEIGHTS.article` | 1 | Lowest; article is broad |
| `LONG_INPUT_THRESHOLD` | 500 words | SimHash pre-filter gate (deferred, §5.1) |
| `SIMHASH_HAMMING_THRESHOLD` | 64 bits | Pre-filter candidate distance (deferred, §5.1) |
| `FDC_ENCODER_SEED` | `0xFDC_EN_C0DE_2026` | SimHash projection seed (deferred, §5.1) |
| `LEXRANK_SENTENCE_COUNT` | 10 | Sentences retained per article |
| `POOL_SUBMIT_THRESHOLD` | 50 entries | Novel-token cache flush trigger |
| `STOP_THRESHOLD` | 1 | Pinned; empirically inert on the v1.0 frame (§6.1) |

`STOP_THRESHOLD` is resolved (pinned at `1`, §6.1). The three SimHash constants
back a deferred pre-filter (§5.1) and are not yet load-bearing. All values are
fixed and must not be changed without a new version of `FDCSignatures.json`
and a full conformance vector regeneration.

---

## §10. Kit Assignments Quick Reference

| Component | Kit | Shipped |
|---|---|---|
| `encode()` runtime (`FDC` / `FDCMatcher`) | LatticeLib | Yes |
| Static word-class table | LatticeLib (resource) | Yes |
| FDC frame | LatticeLib (resource) | Yes |
| Code signatures | LatticeLib (resource) | Yes |
| Match index (inverted-index, §5.2) | LatticeLib (built at init) | Yes |
| Canonicalization lexicon | LatticeLib (resource) | Yes |
| Platform tagger fallback | LatticeLib (`NLTagger`, Apple) | Yes (Apple) |
| Novel-token pool cache | LatticeLib | Yes (submit endpoint is a no-op stub) |
| SimHash pre-filter | SubstrateML + LatticeLib | No (deferred, §5.1) |
| Seed Generator | `tools/seed-generator/` | No (maintainer only) |
| Pool reducer | (not yet built) | No |
| HMM/Viterbi tagger | LatticeLib | Stub (`.other`); real artifact pending (non-Apple) |
| EW integration seam | LatticeLib (toggle off) | No (pending license) |

Full rationale for each assignment is in
`DECISION_FDC_ENCODER_KIT_PROVENANCE_2026-05-25.md`.
