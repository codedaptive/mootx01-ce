# FDC Encoder — Canonical Specification

**Version 1.0 · 2026-05-25**

---

## 1. Thesis

Any block of text can be deterministically assigned a single location code on a shared, public-domain classification frame without a learned model, without coordination between parties, and without a network call at runtime. Two independent devices encoding the same or similarly-worded content will land on the same code because every step of the process is a pure function of the input and a set of pinned, shared reference tables. This is what makes the encoder suitable as the filing backbone for federated data exchange: agreement is a mathematical property of the function, not a product of consensus.

The function is:

    encode(text) -> code

One entry point. One exit. No branches except an explicit guard for unmatched input.

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

**Step 1 tagger — platform implementations.** Step 1 identifies nouns and verbs. The implementation differs by platform but the contract is identical on all: same input yields same noun/verb counts. Two tiers operate at runtime:

- **Static word-class table (fast path, all platforms).** A pinned, versioned lookup table mapping known tokens to NOUN, VERB, or neither. Built at build time from the platform reference taggers described below. A token in the table is resolved in constant time with no tagger invoked. This is the primary path for the vast majority of tokens.
- **Tagger fallback (novel tokens only).** When a token is not in the static table, the platform tagger is invoked. The result is added to a local accumulation cache. When the cache reaches 50 entries it is submitted to the shared pool and purged. Entries below 50 are kept indefinitely at negligible storage cost and are not aged or cleaned up.

**Apple platforms:** NLTagger with .lexicalClass (ships with the OS, on-device, no additional dependency). The minimum OS version is a pinned parameter. NLTagger is the reference implementation: the static table for all platforms is seeded from NLTagger output over a large Wikipedia corpus. On table update, the device purges all local accumulation predating the new table snapshot date; those tokens will be retagged by NLTagger on next encounter.

**Non-Apple platforms:** a classical HMM/Viterbi tagger trained on the Penn Treebank tag set. Open source, self-contained, no license concern. Slower than NLTagger for novel tokens but produces the same output for tokens already in the static table. Non-Apple devices participate in the pool on the same 50-token submit-and-purge cycle. The pool receives two streams — NLTagger tags and HMM/Viterbi tags — and the reduction step treats agreement between the two as a strong quality signal before a token graduates to the shipping table.

**Table distribution via EideticLib.** EideticLib polls the project repository for updated word-class tables. Poll frequency is a user preference in GUI applications and a config JSON key in headless installations. On download, EideticLib ingests the new table and purges local accumulation older than the table snapshot date. Apple App Store disclosure requirements apply to the pool submission behavior.

**EW integration point (not shipped, toggle ready).** An integration seam for Essential AI's EW classifier exists in the codebase as an optional replacement for the HMM/Viterbi fallback on non-Apple platforms. The toggle is off. EW is not shipped. See CONTRIBUTING for the formal invitation to Essential AI regarding a license.

**Aho-Corasick automaton** (Aho and Corasick, 1975). A multi-pattern finite-state matcher built once from all code signatures. Because each FDC code's signature is enriched with LexRanked Wikipedia article terms, the combined signature vocabulary across all codes is large. Aho-Corasick scans the runtime bag against that full vocabulary in a single pass with no backtracking. This is its correct use: matching one input against a large fixed vocabulary, not matching a small fixed list.

**SimHash / LSH** (Charikar, 2002). Used as a pre-filter when the inbound text is long. A long document is hashed to a fixed-width fingerprint using a deterministic feature hash with a fixed accumulation order — never a learned embedding. Fingerprints that are far apart in Hamming distance are eliminated before full overlap scoring runs. This is its correct use: reducing the comparison space when runtime input is large, not replacing the scoring step. Bit-identical across platforms and language ports.

Nothing in this list includes a learned model, a proprietary dataset, or a runtime network dependency. Every algorithm is published and decades old. Every data source is CC0 or used only at build time.

---

## 3. Logic

The encoder runs the same five-step pipeline in two contexts:

**Build time:** steps 1–3 are run over each FDC code's reference text drawn from three sources: its FDC label, its subject-heading title, and its Wikipedia article. The three sources vary enormously in size. To prevent the article from drowning the label, LexRank is applied to the article first, reducing it to its most central terms before it enters the pipeline. The three resulting bags are then merged with source-type weights applied: label terms carry the highest weight, title terms medium, article terms lowest. These weights are part of the pinned contract. A code inherits its ancestors' merged signature terms down the decimal tree, so a child code carries the union of its own terms and every ancestor's terms.

**Runtime:** steps 1–5 are run over the inbound text block to produce a code.

Because both sides use identical steps on comparable inputs, the runtime bag is directly comparable to the build-time signatures. That comparability is the foundation of the agreement property.

**Step 1 — Extract nouns and verbs with counts.** Look each token up in the static word-class table. Tokens tagged NOUN or VERB are kept with their count. Tokens not in the table fall to the platform tagger (NLTagger on Apple, HMM/Viterbi elsewhere); the result is cached locally toward the 50-entry pool submission threshold. Discard everything else: articles, prepositions, times, adjectives, punctuation.

**Step 2 — Canonicalize each surface form to a concept ID.** Lemmatize each kept term, then look it up in the pinned canonicalization lexicon to obtain a concept ID. Synonyms in any language collapse to the same concept ID. This is the load-bearing step: it is what makes "Dinner with my wife" and "Cena con mia moglie" produce the same bag and therefore land the same code. A term the lexicon does not resolve keeps its surface form and can only match a signature that contains that exact form.

**Step 3 — Weight by frequency.** Accumulate concept IDs into a weighted bag. Weight equals frequency. A concept mentioned five times weighs five times one mentioned once. The bag is the complete, language-neutral representation of the text's subject matter.

**Step 4 — Match the bag against all code signatures.** Run the bag's concept IDs through the Aho-Corasick automaton in a single pass. Every code whose signature contains any bag term lights up. Score each lit code by summing the weights of the overlapping terms. If no code lights up, return UNRESOLVED. The encoder never guesses.

**Step 5 — Descend the frame to the deepest passing code.** Take the highest-scoring top-level region (tie-break: lowest code value). Check its children: if any child's signature overlaps the bag above the stop threshold, move to that child (tie-break: lowest code value) and repeat. Stop when no child clears the threshold. Return the deepest code reached. Coarse agreement is guaranteed; fine depth is best-effort and depends on whether the text is specific enough to light up a child signature.

---

## 4. Pseudo-code

```
# INGREDIENTS (pinned, versioned — same versions on both parties)
#   fdc_frame         : decimal codes + labels, ancestry from decimal string
#   lexicon           : lemma -> conceptID  (Wikidata + WordNet, pinned snapshot)
#   signatures        : FDCCode -> {conceptID: weight}  (ancestor-inherited)
#   ac_automaton      : Aho-Corasick automaton over all signature terms
#   word_class_table  : token -> {NOUN, VERB, OTHER}  (pinned, versioned)
#   STOP_THRESHOLD    : minimum overlap weight to continue descent

encode(text) -> (code | UNRESOLVED, trail):

    # STEP 1 — static table lookup; tagger fallback for novel tokens
    counts = {}
    for token in tokenize(text):
        pos = word_class_table.lookup(token)      # static pinned table, fast path
        if pos is None:
            pos = platform_tagger.tag(token)      # NLTagger (Apple) or HMM/Viterbi
            novel_cache.add(token, pos)           # accumulate toward pool submission
            if novel_cache.size() >= 50:
                pool.submit(novel_cache.drain())  # submit and purge
        if pos in {NOUN, VERB}:
            counts[token] += 1

    # STEP 2 + 3 — Canonicalize to concept IDs; weight by frequency
    bag = {}
    for surface, n in counts:
        lemma   = lemmatize(surface)
        concept = lexicon.lookup(lemma)           # pinned Wikidata + WordNet lexicon
        key     = concept if concept else surface # unresolved keeps surface form
        bag[key] += n

    # STEP 4 — SimHash pre-filter for long input, then single-pass match
    if text is long:
        fingerprint = simhash(bag)                # deterministic feature hash
        candidates  = signatures.filter_by_hamming(fingerprint)
    else:
        candidates  = signatures.all()

    lit   = ac_automaton.scan(bag.keys(), against=candidates)
    score = {}
    for code in lit:
        score[code] = sum(bag[k] for k in bag if k in signatures[code])

    if score is empty:
        return (UNRESOLVED, trail=[])             # never guess

    # STEP 5 — Descend the frame; deepest passing code wins
    node = argmax(score, tiebreak=lowest_code_value)
    while true:
        best_child = None
        best_score = 0
        for child in fdc_frame.children(node):   # children from decimal string
            overlap = sum(bag[k] for k in bag if k in signatures[child])
            if overlap >= STOP_THRESHOLD and overlap > best_score:
                best_child = child
                best_score = overlap
            elif overlap == best_score and child < best_child:
                best_child = child                # tie-break: lowest code value
        if best_child is None:
            break
        node = best_child

    return (node, trail=sorted(score.items(), by=score desc))


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

## 5. Open Item

`STOP_THRESHOLD` in Step 5 is a pinned parameter with no value yet assigned. It must be determined empirically against the real signatures once the Seed Generator produces them. See `DECISION_FDC_ENCODER_KIT_PROVENANCE_2026-05-25.md` §8.
