---
title: FDC Encoder Engineering Cookbook
version: 1.0
status: implementation-grade specification
author: MOOTx01 maintainers
date: 2026-05-25
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

**One function. One path.**

    encode(text: String) -> (FDCCode | UNRESOLVED, trail: [(FDCCode, Weight)])

Pure function. No I/O. No clock. No RNG. No network. No learned model.
Same input and same pinned artifacts yield bit-identical output on every
platform and in both the Swift and Rust ports.

---

## §1. Pinned Artifacts

Three static JSON artifacts ship in `Sources/EideticLib/Resources/`. All
three are produced by the Seed Generator (`tools/seed-generator/`) and
committed to the repository. EideticLib parses all three once on first
use and caches the parsed result for the process lifetime.

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

The weighted concept bag per FDC code. Schema:

```json
{
  "signatures_version": "1.0.0",
  "source_weights": { "label": 3, "title": 2, "article": 1 },
  "signatures": {
    "006.6": { "Q80006": 9, "Q7397": 6, "programming": 3, ... },
    ...
  }
}
```

Keys are concept IDs (Wikidata Q-IDs) or unresolved surface forms.
Values are accumulated weights after source-type scaling and ancestor
inheritance. A code's signature already includes its ancestors' terms;
the descent step does not re-accumulate ancestors at runtime.

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
sources merged into one pinned snapshot (see §6.2 for the build
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

### §3.2. Algorithm

For each `(surface, n)` in `counts`:

1. `lemma = lemmatize(surface)` — apply Porter2 stemming (same Snowball
   implementation already in EideticLib's `Stemmer.swift`).
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
   `SubstrateLib.FloatSimHash` with a fixed seed (`FDC_ENCODER_SEED =
   0xFDC_EN_C0DE_2026`). The feature vector is the sorted concept IDs
   mapped to floats by a stable bijection (e.g., index in the sorted
   concept vocabulary).
2. Compute the SimHash fingerprint: a 256-bit value from
   `SubstrateLib.Fingerprint256`.
3. Filter `signatures` to the subset whose pre-computed fingerprints are
   within `SIMHASH_HAMMING_THRESHOLD` (default: 64) bits of the input
   fingerprint.
4. Pass only the filtered candidate set to §5.2.

For short input, pass all signatures to §5.2 directly. The pre-filter
is a speed optimization only; it must not change which code is returned
for any input. If in doubt, skip the pre-filter.

Pre-computed signature fingerprints are stored in `FDCSignatures.json`
alongside the concept bags (added field `fingerprint: String` per code,
hex-encoded 256-bit value).

### §5.2. Aho-Corasick Single-Pass Match

Build the Aho-Corasick automaton once from all concept IDs and surface
forms that appear in any code signature. Cache it for the process
lifetime alongside the parsed artifacts (§1).

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

`score` is a dictionary `FDCCode -> Int`. Ties are broken by lowest code
value string-lexicographically (e.g., `"100"` beats `"200"`). The trail
returned with the result is `score` sorted descending by weight.

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

`STOP_THRESHOLD` is a pinned parameter. Its value is unspecified in v1.0
and must be determined empirically once the Seed Generator produces real
signatures. It is committed as a named constant in both ports and
documented in `FDC_ENCODER_CANONICAL_v1.0.md` §5 when resolved. Until
resolved, implementations may default to `1` (any overlap continues
descent) for testing purposes only; this default must not ship.

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

5. Compute the SimHash fingerprint of `sig[c]` (§5.1) and store it
   alongside the bag.

### §7.2. LexRank Article Reduction

LexRank reduces a Wikipedia article to its N most central sentences
before Steps 1–3 run over the article. N defaults to 10 sentences.
The LexRank implementation may be Python (`sumy` library, LexRank
summarizer) or a Swift reimplementation; both produce the same
algorithm. The output is a concatenation of the N selected sentences,
passed as a single string to Steps 1–3.

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

The Swift and Rust ports must produce bit-identical `encode` output for
identical input and identical pinned artifacts. Conformance is enforced
by shared test vectors in `Tests/SharedVectors/encode_vectors.json`:

```json
[
  {
    "input": "Dinner with my wife at Guidos",
    "expected_code": "642",
    "expected_trail_top": { "code": "642", "weight": 3 }
  },
  ...
]
```

Any divergence between ports is a hard conformance failure and blocks
release. The test harness runs both ports against every vector and
diffs the output.

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
| `LONG_INPUT_THRESHOLD` | 500 words | SimHash pre-filter gate |
| `SIMHASH_HAMMING_THRESHOLD` | 64 bits | Pre-filter candidate distance |
| `FDC_ENCODER_SEED` | `0xFDC_EN_C0DE_2026` | SimHash projection seed |
| `LEXRANK_SENTENCE_COUNT` | 10 | Sentences retained per article |
| `POOL_SUBMIT_THRESHOLD` | 50 entries | Novel-token cache flush trigger |
| `STOP_THRESHOLD` | TBD | Empirical; blocks v1.0 ship |

`STOP_THRESHOLD` is the one unresolved constant. All others are fixed
and must not be changed without a new version of `FDCSignatures.json`
and a full conformance vector regeneration.

---

## §10. Kit Assignments Quick Reference

| Component | Kit | Shipped |
|---|---|---|
| `encode()` runtime | EideticLib | Yes |
| Static word-class table | EideticLib (resource) | Yes |
| FDC frame | EideticLib (resource) | Yes |
| Code signatures | EideticLib (resource) | Yes |
| Aho-Corasick automaton | EideticLib (built at startup) | Yes |
| Canonicalization lexicon | EideticLib (resource) | Yes |
| SimHash pre-filter | SubstrateLib + EideticLib | Yes |
| Seed Generator | `tools/seed-generator/` | No (maintainer only) |
| Pool reducer | `tools/pool-reducer/` | No (maintainer only) |
| HMM/Viterbi tagger | EideticLib (bundled binary) | Yes (non-Apple) |
| EW integration seam | EideticLib (toggle off) | No (pending license) |

Full rationale for each assignment is in
`DECISION_FDC_ENCODER_KIT_PROVENANCE_2026-05-25.md`.
