# FDC Encoder — Canonical Specification

**Version 1.1 · 2026-06-02** (revised to shipped reality; v1.1 folds in
the two-tier gap fill, the membership-only runtime artifact, the
shipped label-hygiene behavior, and version language — each claim
re-verified against the code and build artifacts on this date)

---

## 1. Thesis

Any block of text can be deterministically assigned a single location code on a shared, public-domain classification frame without a learned model, without coordination between parties, and without a network call at runtime. Two independent devices encoding the same or similarly-worded content will land on the same code because every step of the process is a pure function of the input and a set of pinned, shared reference tables. This is what makes the encoder suitable as the filing backbone for federated data exchange: agreement is a mathematical property of the function, not a product of consensus.

The engine lives in **LatticeLib** (`FDC`, `FDCMatcher`). It is what consumers call to classify text; `EideticLib.lookup` is the first such consumer (it calls `FDC.encodeAnchor` and carries the result onto an `Anchor`). There is one engine home and one frame.

The function has two shipped entry points, one a thin wrapper over the other:

    FDC.encode(text)       -> code?                       # nil == UNRESOLVED
    FDC.encodeAnchor(text) -> (code?, conceptQID?)

`encode` returns the FDC code or `nil` for unmatched input — the encoder never guesses. `encodeAnchor` returns the same code plus the **dominant concept Q-ID**: the highest-weighted Wikidata Q-ID in the input's concept bag (ties broken by lowest Q-ID, so it is deterministic), or `nil` if the bag carries no Q-ID concept. The dominant Q-ID is "what the text is most about"; `EideticLib.lookup` carries it as the Anchor's `wikidataQID`. Both are computed in a single bagging pass.

One bagging pass. One exit. No branches except an explicit guard for unmatched input. (There is no separate "trail" return — an earlier draft surfaced a score-sorted trail; the shipped extra is the dominant concept Q-ID described above.)

---

## 2. Tools and Data We Are Actually Using

**FDC frame** (`fdc.txt`, CC0 public domain, github.com/JohnMarkOckerbloom/fdc). The Free Decimal Correspondence is the classification frame. Each code is a decimal string; the decimal string itself encodes the ancestry — the parent of `006.6` is `006`. No separate tree structure is stored or needed. This is the only frame. No other classification system is referenced.

**Canonicalization lexicon** (pinned, versioned). The table that maps surface word forms to concept IDs in Step 2. It is built from two public domain sources combined into one snapshot:

- **Wikidata alias table** (CC0). Wikidata's multilingual alias properties. "wife," "spouse," "Ehefrau," and "moglie" all resolve to the same concept ID because they are aliases of the same Wikidata entity. Strong on named entities and multilingual coverage.
- **WordNet** (Princeton, public domain). A lexical database of English grouping words into synonym sets with lemmatization and sense disambiguation data. Strong on common English vocabulary, synonyms, and word senses that Wikidata aliases do not cover.

The two sources are merged into one pinned English lexicon snapshot. Wikidata provides the concept IDs; WordNet fills the coverage gaps for everyday English vocabulary. English is the language of science and covers the broadest technical vocabulary, making it the logical first language to ship.

Two encoders must use the same pinned lexicon version or their bags can diverge. Additional language lexicons follow the same pattern — a language-specific WordNet combined with the Wikidata alias table for that language — and are documented in CONTRIBUTING.

**Wikipedia articles** (CC BY-SA, used at build time only). Each FDC code is backed by a reference article. The article is processed at build time to contribute to that code's signature. It is never fetched at runtime.

**LexRank** (Erkan and Radev, 2004). A deterministic graph-based algorithm — PageRank applied to a term-similarity graph — used at build time to reduce a full Wikipedia article to its key terms before those terms are incorporated into a code's signature. No model, no weights.

**Step 1 tagger — platform implementations.** The tagger's job is to identify nouns and verbs (Step 1 additionally keeps Q-ID concepts via the §3 relaxation, decided from the lexicon rather than the tagger). The implementation differs by platform but the contract is identical on all: same input yields same noun/verb counts. Two tiers operate at runtime:

- **Static word-class table (fast path, all platforms).** A pinned, versioned lookup table mapping known tokens to NOUN, VERB, or neither. Built at build time from the platform reference taggers described below. A token in the table is resolved in constant time with no tagger invoked. This is the primary path for the vast majority of tokens.
- **Tagger fallback (novel tokens only).** When a token is not in the static table, the platform tagger is invoked. The result is added to a local accumulation cache. When the cache reaches 50 entries it is submitted to the shared pool and purged. Entries below 50 are kept indefinitely at negligible storage cost and are not aged or cleaned up.

**Apple platforms:** NLTagger with .lexicalClass (ships with the OS, on-device, no additional dependency). The minimum OS version is a pinned parameter. NLTagger is the reference implementation: the static table for all platforms is seeded from NLTagger output over a large Wikipedia corpus. On table update, the device purges all local accumulation predating the new table snapshot date; those tokens will be retagged by NLTagger on next encounter.

**Non-Apple platforms:** a classical HMM/Viterbi tagger trained on the Penn Treebank tag set. Open source, self-contained, no license concern. Slower than NLTagger for novel tokens but produces the same output for tokens already in the static table. Non-Apple devices participate in the pool on the same 50-token submit-and-purge cycle. The pool receives two streams — NLTagger tags and HMM/Viterbi tags — and the reduction step treats agreement between the two as a strong quality signal before a token graduates to the shipping table.

**Table distribution via EideticLib.** EideticLib polls the project repository for updated word-class tables. Poll frequency is a user preference in GUI applications and a config JSON key in headless installations. On download, EideticLib ingests the new table and purges local accumulation older than the table snapshot date. Apple App Store disclosure requirements apply to the pool submission behavior.

**EW integration point (not shipped, toggle ready).** An integration seam for Essential AI's EW classifier exists in the codebase as an optional replacement for the HMM/Viterbi fallback on non-Apple platforms. The toggle is off. EW is not shipped. See CONTRIBUTING for the formal invitation to Essential AI regarding a license.

**Single-pass inverted-index match** (the Aho-Corasick role, as shipped). The matcher needs to find, for a runtime bag of concept IDs, every code signature that shares any term. The shipped `FDCMatcher` builds a `term -> codes` inverted index once from all signatures, then for each bag term looks up the codes carrying it and scores them. This is the deterministic equivalent of an Aho-Corasick scan over concept-ID keys: both report exactly the signature terms present in the bag and the codes they belong to, in a single pass over the bag with no backtracking. (Aho-Corasick proper is the natural choice when matching against substring patterns; over discrete concept-ID keys the inverted index is the simpler, equivalent realization, and is what ships.)

**SimHash / LSH** (Charikar, 2002) — *deferred, forward-looking*. The design reserves a SimHash pre-filter for long input: hash a long document to a fixed-width fingerprint with a deterministic feature hash and fixed accumulation order, then eliminate signatures far apart in Hamming distance before full overlap scoring. It is a speed optimization only and must never change which code is returned. **It is not implemented:** no fingerprints are produced at build time and the runtime scores against all signatures. The §6 scoring is exact without it. See cookbook §5.1.

Nothing in this list includes a learned model, a proprietary dataset, or a runtime network dependency. Every algorithm is published and decades old. Every data source is CC0 or used only at build time.

---

## 3. Logic

The encoder runs the same five-step pipeline in two contexts:

**Build time:** steps 1–3 are run over each FDC code's reference text drawn from three sources: its FDC label, its subject-heading title, and its Wikipedia article. The three sources vary enormously in size. To prevent the article from drowning the label, LexRank is applied to the article first, reducing it to its most central terms before it enters the pipeline. The three resulting bags are then merged with source-type weights applied: label terms carry the highest weight, title terms medium, article terms lowest. The weights shape the build-time intermediate only: the SHIPPED runtime artifact is compacted to term MEMBERSHIP (each code -> its sorted term-key list) and the matcher never reads a source weight — the weights ride in the artifact header as build provenance. A code inherits its ancestors' merged signature terms down the decimal tree, so a child code carries the union of its own terms and every ancestor's terms. (Artifact contract pinned by `FDCSignaturesArtifactTests` and `rust/tests/fdc_artifact_test.rs`: 1071 codes, sorted, non-empty, membership-only.)

All 1071 signature-bearing codes of the v1.0 frame carry Wikipedia-sourced article signatures (up from 793). Codes whose heading did not auto-resolve to a Wikipedia title were filled by a **two-tier LLM gap fill**, of which only the first tier ever fired:

- **Tier 1 — resolver (shipped, fired).** An LLM proposed the single best real Wikipedia article title per gap code, frozen in a committed, auditable input (`_gap_titles.tsv`, code -> title) and validated by actually fetching the article. The model only *chose which article to pull*. One proposal missed (012 -> "Biobibliography", no such article) and was re-resolved to a real article ("Bibliography") rather than falling through.
- **Tier 2 — generated description (designed, NOT implemented, never fired).** The design reserved a fallback where a title with no fetchable article would receive a model-written description as its article text. The shipped signature builder contains no such code path, and the build artifacts show zero codes took it. It is named here so the guarantee below is checkable, not rhetorical.

The guarantee is therefore structural: every signature term in the shipped artifact is sourced from the FDC label, the Wikipedia title, or the Wikipedia article body — **no model-generated text enters a signature**, and the builder has no path by which it could. This build-time tooling ships in the maintainer Seed Generator (see cookbook §7.1.1).

**Runtime:** steps 1–5 are run over the inbound text block to produce a code.

Because both sides use identical steps on comparable inputs, the runtime bag is directly comparable to the build-time signatures. That comparability is the foundation of the agreement property.

**Step 1 — Extract the keepable tokens with counts.** Look each token up in the static word-class table. Tokens tagged NOUN or VERB are kept with their count. Tokens not in the table fall to the platform tagger (NLTagger on Apple, HMM/Viterbi elsewhere); the result is cached locally toward the 50-entry pool submission threshold. **In addition to nouns and verbs, Step 1 keeps any token whose lemma resolves to a Wikidata Q-ID in the pinned lexicon, regardless of its word class.** Named entities (place names, organizations, works) are highly discriminative but proper-noun POS tagging is unreliable and diverges across platforms; deciding admission from the pinned lexicon recovers entity coverage deterministically — identical at build and runtime, and off the platform-dependent tagger path entirely — so it strengthens rather than weakens the agreement property. (Only Q-ID hits are admitted this way, not `wn:` fallback hits.) Discard everything else: articles, prepositions, times, adjectives, punctuation that is neither a noun/verb nor a Q-ID concept.

**Step 2 — Canonicalize each surface form to a concept ID.** Lemmatize each kept term, then look it up in the pinned canonicalization lexicon to obtain a concept ID. Synonyms in any language collapse to the same concept ID. This is the load-bearing step: it is what makes "Dinner with my wife" and "Cena con mia moglie" produce the same bag and therefore land the same code. A term the lexicon does not resolve keeps its surface form and can only match a signature that contains that exact form.

**Step 3 — Weight by frequency.** Accumulate concept IDs into a weighted bag. Weight equals frequency. A concept mentioned five times weighs five times one mentioned once. The bag is the complete, language-neutral representation of the text's subject matter.

**Step 4 — Match the bag against all code signatures, IDF-weighted.** Run the bag's concept IDs through the single-pass inverted-index scan. Every code whose signature shares any bag term is a candidate. Score each candidate by the **IDF-weighted overlap** — for each shared term, the bag count times that term's inverse document frequency:

    score[code] = Σ_{t ∈ bag ∩ sig(code)}  bag[t] · idf(t)
    idf(t)      = ln( N / df(t) )    # N = total code signatures, df(t) = # signatures containing t

A term that appears in many signatures contributes little; a distinctive term dominates. This is the scoring the runtime ships. The plain raw-overlap sum (`Σ bag[t]`, no IDF) lets codes with large, broad signatures win on breadth alone, which is why IDF — rewarding distinctive terms — was chosen over it; cosine and IDF-cosine variants were measured and rejected (cosine worse, IDF-cosine behind IDF). `idf(t)` is precomputed once from the pinned signatures at load (no additional shipped artifact). **Determinism:** the IDF-weighted sums are floating-point and float addition is non-associative, so every per-code sum is accumulated in sorted term order, making the result bit-identical across runs and across the Swift and Rust versions. If no candidate shares a term, return UNRESOLVED. The encoder never guesses. (The raw-overlap sum is the matcher's `.raw` mode and is what the direct unit tests use; the runtime is constructed in `.idf` mode.)

**Step 5 — Descend the frame to the deepest passing code.** Take the highest-scoring top-level region under the same IDF scoring (tie-break: lowest code value). Check its children: a child is a descent candidate only if its **raw integer overlap** (`Σ bag[t]`, mode-independent) clears `STOP_THRESHOLD`; among the candidates that clear it, the highest IDF score wins (tie-break: lowest code value). Move to that child and repeat. Stop when no child clears the threshold. The descent cutoff gates on the raw overlap so its meaning is independent of the scoring mode; the IDF score only ranks the candidates that pass the gate. Coarse agreement is guaranteed; fine depth is best-effort and depends on whether the text is specific enough to light up a child signature.

---

## 4. Pseudo-code

```
# INGREDIENTS (pinned, versioned — same versions on both parties)
#   fdc_frame         : decimal codes + labels, ancestry from decimal string
#   lexicon           : lemma -> conceptID  (Wikidata + WordNet, pinned snapshot)
#   signatures        : FDCCode -> {conceptID}  (membership set, ancestor-inherited)
#   index             : conceptID -> [FDCCode]  (inverted index over signatures)
#   idf               : conceptID -> ln(N / df)  (precomputed once from signatures)
#   word_class_table  : token -> {NOUN, VERB, OTHER}  (pinned, versioned)
#   STOP_THRESHOLD    : minimum RAW overlap to continue descent (pinned = 1, inert)

# The shipped surface is encodeAnchor; encode(text) == encodeAnchor(text).code.
encodeAnchor(text) -> (code | UNRESOLVED, conceptQID | None):

    # STEP 1+2+3 — one bagging pass: keep nouns/verbs OR Q-ID concepts,
    # canonicalize to concept IDs, weight by frequency.
    bag = {}
    for token in tokenize(text):
        key     = stem(normalize(token))          # identical at build and runtime
        concept = lexicon.lookup(key)             # nil if not in the pinned lexicon
        is_qid  = concept is not None and concept.startswith("Q")
        pos     = word_class(token)               # static table; tagger fallback for novel
        if pos not in {NOUN, VERB} and not is_qid:
            continue                              # drop: not a noun/verb and not a Q-ID concept
        bag[concept if concept else key] += 1     # hit -> conceptID; miss -> stemmed surface

    # The dominant concept Q-ID: highest-count Q-ID in the bag (ties -> lowest
    # Q-ID). Surfaced by encodeAnchor even when no code matches.
    conceptQID = argmax_count({k: v for k, v in bag if k.startswith("Q")},
                              tiebreak=lowest_qid) or None
    if bag is empty:
        return (UNRESOLVED, conceptQID)

    # STEP 4 — single-pass inverted-index match, IDF-weighted score.
    # (SimHash pre-filter for long input is deferred — not implemented; the
    # runtime always scores against every candidate signature. See §2 / cookbook §5.1.)
    candidates = { code for term in bag for code in index.get(term, []) }
    if candidates is empty:
        return (UNRESOLVED, conceptQID)           # never guess

    def score(code):                              # SHIPPED scoring (.idf mode)
        overlap = sorted(t for t in signatures[code] if t in bag)   # SORTED for float determinism
        return sum(bag[t] * idf[t] for t in overlap)
        # .raw mode (matcher default, used by direct unit tests): sum(bag[t] for t in overlap)

    node = argmax(candidates, by=score, tiebreak=lowest_code_value)

    # STEP 5 — Descend the frame; deepest passing code wins.
    while true:
        best, best_score = None, 0
        for child in fdc_frame.children(node):    # children from decimal string
            raw = sum(bag[t] for t in signatures[child] if t in bag)   # RAW overlap
            if raw < STOP_THRESHOLD:              # cutoff is mode-independent (raw)
                continue
            s = score(child)                      # rank survivors under the same .idf score
            if best is None or s > best_score or (s == best_score and child < best):
                best, best_score = child, s
        if best is None:
            break
        node = best

    return (node, conceptQID)


# BUILD-TIME: produce each code's signature using steps 1–3
# Source weights are pinned — label highest, title medium, article lowest.
SOURCE_WEIGHTS = { label: 3, title: 2, article: 1 }

build_signature(fdc_code) -> {conceptID: weight}:

    sources = [
        (fdc_frame.label(fdc_code),              SOURCE_WEIGHTS.label),   # source 1: FDC label
        (wikiword(fdc_code),                     SOURCE_WEIGHTS.title),   # source 2: subject-heading title
        (lexrank(wikipedia_article(fdc_code)),   SOURCE_WEIGHTS.article)  # source 3: LexRanked article
    ]
    # LexRank reduces the article to its most central terms before the pipeline
    # runs, so the article bag is comparable in size to the label and title bags.

    bag = {}
    for source_text, source_weight in sources:
        partial = steps_1_to_3(source_text)       # same pipeline as runtime
        for key, weight in partial:
            bag[key] += weight * source_weight    # scale by source type

    # inherit ancestors' terms down the decimal tree
    for ancestor in fdc_frame.ancestors(fdc_code):
        for key, weight in signatures[ancestor]:
            bag[key] += weight

    return bag
```

---

## 5. STOP_THRESHOLD — Resolved

`STOP_THRESHOLD` (Step 5) is **pinned at 1** and is **empirically inert** on the v1.0 frame. A sweep over 1…200 against the shipped signatures produced identical results: the v1.0 frame is shallow — most codes are integer-head and the average encoded depth is about 1.3 — so the Step-5 descent rarely fires, and where it does, the cutoff value does not change the outcome. Classification accuracy is therefore governed by the within-region IDF scoring of §4, not by this cutoff. The constant ships at 1 (any raw overlap continues descent) in both the Swift and Rust versions. This closes the open item carried in the v1.0 draft and recorded in `DECISION_FDC_ENCODER_KIT_PROVENANCE_2026-05-25.md` §8.

---

## 6. Cross-Platform Conformance

The encoder ships as two co-authored versions — Swift (`LatticeLib`) and Rust (`LatticeLib/rust`). The shipped agreement property is **Swift-scalar == Rust-scalar**: both versions produce identical `encode` / `encodeAnchor` output for identical input and identical pinned artifacts, proven against the committed conformance fixture (`rust/tests/fixtures/fdc_conformance.json`, 52/52 passing) and the artifact-contract tests both versions run over the SAME bundled `FDCSignatures.json`. This is a pure string/concept-ID algorithm: there is no Metal or BLAS dimension and no SIMD kernel to conform — the only cross-version determinism concern is float summation order in the IDF scoring (§4), which both versions pin by summing in sorted term order.

The cross-platform-*guaranteed* surface is the static word-class table plus the pinned lexicon and signatures: any token resolved through them is bit-identical on every platform. Novel-token tagging is platform-divergent **by design** — Apple uses `NLTagger`, non-Apple uses the (currently stubbed) Penn-Treebank HMM/Viterbi tagger — and is deliberately kept off the agreement-bearing path. The Step-1 Q-ID relaxation (§3) further moves named entities onto the deterministic lexicon path and off the divergent tagger path.

---

## 7. Deferred (forward-looking, not shipped)

These are designed-but-unshipped surfaces. They are named here so a reader does not mistake them for current behavior:

- **SimHash long-input pre-filter** (§2, cookbook §5.1) — no fingerprints produced, no pre-filter applied at runtime.
- **LexRank and the weighted CodeSignature** — build-time only (Seed Generator); never invoked at runtime.
- **Multilingual lexicons** — only the English lexicon ships; additional languages follow the same format (CONTRIBUTING).
- **FDCFrame label normalization pass** — frame labels are stored verbatim
  (including LCSH quotation and `+` / `|` subject markers); no dedicated
  normalization pass ships. The hygiene that DOES ship is narrower and
  lives elsewhere: at build, the signature builder extracts the quoted
  LCSH headings from a label and strips ` -- ` subdivisions and trailing
  parentheticals when resolving a heading to its Wikipedia title; at both
  build and runtime, the tokenizer drops the markers naturally when a
  label is bagged. A future verbatim-label consumer should not mistake
  the raw label for clean text.
- **A labeled-path export helper** (an `FDC.classify`-style human-readable directory export) — not shipped.
- **HMM/Viterbi non-Apple tagger** — a deterministic `.other` stub ships; the real compiled artifact is pending.
- **Novel-token pool reducer / submit endpoint** — the cache accumulates against a no-op submitter; the pool reducer is not yet built.
