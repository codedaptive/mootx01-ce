---
status: decided
question: Should SubstrateLib be refactored and reframed pre-ship — combinator layer, algorithm corrections, layout localization, and a package split — and documented as a structured ML/representation substrate rather than "math primitives"?
authors: MOOTx01 maintainers
date: 2026-05-29
relates_to:
  - docs/reference/GENIUSLOCUS_ARCHITECTURE_SPEC.md
  - docs/engineering/GENIUSLOCUS_ENGINEERING_COOKBOOK.md
supersedes: none
context:
  - Scope is packages/libs/SubstrateLib/ and its direct consumers, plus a documentation reframe across the kit graph.
  - A four-lens architectural review (Clojure + APL + Cursor + ML-training) was conducted on unshipped SubstrateLib code, while the change set is internal-only and no downstream consumer commitments exist.
  - Decided 2026-05-29 — see the Addendum and Implementation Record at the end.
---

# DECISION: SubstrateLib Pre-Ship Refactor and Reframe

---

## 1. Context

SubstrateLib is the value-type, algebra, and ML-primitive foundation of MOOTx01. Pre-ship review surfaced two complementary findings:

1. **A coherent refactor set** that lands while blast radius is internal — combinators, algorithm corrections, layout localization, package split.
2. **A reframe** of what SubstrateLib actually is. The data model already encodes the shape of an ideal ML training corpus and an ideal AI-editor memory system. The current documentation undersells this as "math primitives."

Both findings are pre-ship. Both go through the same conformance harness. They are one decision, captured here as one document.

Four analytical lenses were applied to the same code:

- **Clojure** (Hickey's identity/value/time decomposition; data over functions over macros; protocols and pure functions)
- **APL** (Iverson's array-oriented operations; whole-array primitives; named algebraic properties; scalar-reference-as-oracle)
- **Cursor** (AI code editor consuming the substrate as memory and retrieval backend)
- **ML training** (the substrate as a structured corpus for supervised, prototype-based, and federated learning)

The first two lenses converged on architectural friction: **the shape is right, the Swift surface is fighting it.** The second two lenses converged on use-case fit: **the data model is already shaped exactly the way these consumers need.** All four lenses together converge on the refactor and reframe in §5–§6.

---

## 2. The Data Model

Before the lens-by-lens review, a direct reading of what SubstrateLib encodes. Every substrate row simultaneously carries:

- **Identity** — UUID per row, eventID per audit event, content-hashed for dedupe.
- **Semantic position** — `Fingerprint256` via SimHash. A 256-bit locality-sensitive code where Hamming distance is meaningful similarity.
- **Classification** — `LatticeAnchor` (MDCC code + Wikidata Q-ID). A Dewey-decimal-like coordinate in a global taxonomy.
- **Typed state** — 216 bits of categorical fields across 36 fields × 6 bits, packed into three Int64 bitmaps (adjective, operational, provenance).
- **Lineage** — `lineage_id` chains derivation history; capture-week bucket and behavioral-recency vector encode temporal context.
- **Provenance** — channel, source_type, capture_channel, sensitivity, estate-uuid hash, stream-source bitset.
- **Trust / sensitivity / exportability** — the four ARIA adjective categories, fixed by invariant I-8.
- **Relations** — KGFact triples (subject, predicate, object) with temporal validity; tunnels for cross-references.
- **Temporal ordering** — HLC for deterministic distributed time.
- **Population statistics** — F-matrix tracks per-(field, bit) row count; O-matrix tracks pairwise feature co-occurrence; CountVector256 tracks per-bit population over arbitrary cohorts.

The four fingerprint blocks are a deliberate factorization of similarity into orthogonal aspects:

| Block | Aspect | Use |
|---|---|---|
| 0 (Bitmap-LSH) | Structural | Rows with similar adjective/operational/provenance configurations |
| 1 (Lattice-LSH) | Classification | Rows anchored near each other in MDCC space |
| 2 (Lineage + Temporal) | Derivation + recency | Rows in same refactor chain or captured in same week |
| 3 (Channel + Source) | Provenance | Rows from same source channel |

Hamming distance over the full 256 bits is a multi-modal similarity score. Hamming distance restricted to a block subset is a single-aspect score. The block-mask in `Hamming.distance(blocks:)` is the operator that selects which aspects matter for a given query.

**This factorization is the keystone observation of the reframe.** `Fingerprint256` is not just a hash — it is a learned representation with interpretable block structure. Downstream consumers can query it as a multi-modal embedding, selecting which aspects to weight per query. No other substrate I know of ships this property.

Everything above this layer — verbs, matrices, audit log, federation — is operations on top of this multi-aspect feature representation.

---

## 3. Four-Lens Review

### 3.1 Clojure (Hickey)

The Clojure lens recognized SubstrateLib as Datomic-shaped:

- **Audit log as authoritative truth.** `GSetAuditLog` is the source; current state is a projection. F/O/T matrices are delta-maintained caches over the log. `Substrate.recall(asOf: hlc:)` is `(d/as-of db t)`. Event-sourcing as a first-class architectural commitment.
- **Value semantics by construction.** `Fingerprint256`, `HLC`, `AuditEvent`, `LatticeAnchor` all `Hashable`, `Sendable`, `Codable` structs/enums with no reference semantics. Wire format documented, deterministic, byte-exact. Swift and Rust serdes converge on the same JSON shape.
- **Algebraic properties named in code.** `ORReduce` declares commutative + associative + idempotent in a comment block. `GSetAuditLog` has a literal proof sketch. Monoid-thinking made explicit.
- **Identity vs. value, cleanly separated.** `HLC` is a pure value; `HLCGenerator` is the identity. `Fingerprint256` is a value; `Substrate` is the identity that aggregates them.
- **Protocol-first abstraction.** `SubstrateKernel` protocol with default extension methods is the Clojure protocol pattern done right — minimal surface, default impls in terms of primitives, conformance-gated specialization.

**Friction the lens calls out:**

- Mutating-verb names disguise value semantics. `setBit`, `bitwiseOR`, `ORReduce.merge(into:)`, `mutate` — the names fight the read.
- Two audit shapes coexist undocumented (`AuditEvent` row-level in Verbs.swift, `AuditEntry` field-level in GSetAuditLog.swift).
- 36×6 bit-packing layout is implicit (literals `12`, `6` appear inline in `Substrate.rowHasBit`).
- `MatrixT` declared in `Substrate` but never updated by any verb in `Verbs.swift`.
- `Substrate.auditEvents: [AuditEvent]` annotated `// appended; treat as G-Set` — manual discipline rather than using the actual `GSetAuditLog` type.

### 3.2 APL (Iverson)

The APL lens recognized SubstrateLib as already trying to be APL:

- **Vocabulary alignment.** `NounType`, the nine "verbs," `Fingerprint256` as fixed-shape 4×64 array, `ORReduce`, `CountVector256.fold`, "scalar reference is the oracle, backends are bit-identical specializations." J's terminology, used unironically.
- **Algebraic discipline.** Properties stated in code — the K programmer's reflex: characterize the algebra, the implementation falls out.
- **Lossless aggregate stored, derived view on read.** `CountVector256` composes losslessly up a node tree; majority-vote is the read-time threshold. OR-reduce is recognized as the degenerate saturating case.
- **Flat storage in MatrixF.** `[Int64]` of length 216 with explicit `cellIndex(field:bit:)` accessor — the K choice.
- **Scalar reference as oracle.** Kernel conformance mirrors Dyalog APL's CPU/GPU backend approach.

**Friction the lens calls out:**

- Four-block unroll repeated in 7+ files: `ORReduce.reduce`, `ORReduce.merge`, `BitwiseArithmetic.intersect/difference`, `Hamming.distance`, `ScalarKernel.hammingDistance256`, `ScalarKernel.orReduce256`. In APL this is one expression. **Missing combinators:** `zip4`, `reduce4`, `map4` on `Fingerprint256`.
- `BitwiseArithmetic.prototype` open-codes per-bit counting that `CountVector256.fold` already does better.
- `MatrixF.applyRow` takes a `(Int, Int) -> Bool` predicate over 216 cells. APL form: treat the row as a length-216 bit vector and do `F += row`.
- `Hamming.distance(blocks: Set<Int>)` is a footgun. Set allocation per call.
- `hammingTopK` full-sort is `O(N log N)` when min-heap gives `O(N log K)`.
- `extractFieldValues` builds `[(UInt8, UInt8)]` tuple-by-tuple on every capture/mutate/expunge.

### 3.3 Cursor (AI code editor)

Cursor today has shallow context: open tabs, recent files, codebase index (opaque vector embeddings + BM25), rule files at `.cursor/rules/`. The model loses everything between sessions except what the user re-explains.

MOOTx01's data model maps almost one-for-one onto what an AI code editor needs:

- **Code as captured noun.** A drawer can be a code file, a function, a decision, a chat transcript with the AI. Verbatim immutability is *more* important for code than for prose — the exact form is the artifact. `mutate` produces revisions with lineage pointers; the substrate makes that lineage queryable as first-class data instead of git's append-only DAG that requires `git log --follow` gymnastics.

- **The four-block fingerprint fits code retrieval better than pure vector similarity.** Today's "ask codebase" queries use one signal: vector cosine. The substrate offers four orthogonal aspects:
  - Block 0 (structural): "find code with similar control flow / token patterns"
  - Block 1 (classification): "find auth-related code" via the MDCC anchor
  - Block 2 (lineage): "find the predecessor of this refactor" or "show me what I was working on last week"
  - Block 3 (provenance): "find code I wrote vs. code the AI generated vs. code from this dependency"

  The block-mask in `recall_partial_match` is the API. Cursor's "ask codebase" becomes "ask codebase, with this aspect mask." Order of magnitude richer than today's flat vector search.

- **MDCC for software engineering.** A code-specific MDCC subspace would classify functions, modules, decisions: `software-engineering / web-services / authentication / oauth / token-validation`. Hierarchical, cross-codebase comparable, interpretable. Today's vector embeddings give "similar" without telling you *why*.

- **The dreaming daemon is the missing layer in Cursor.** Cursor today is all conscious mind, no subconscious. The "while you sleep, consolidate yesterday's work" model — capture today's edits as drawers, run overnight to surface themes, strengthen connections, prepare answers — is exactly the gap ABOUT.md identifies for AI memory generally. Code editing is one of the strongest use cases because the rate-of-edit per developer per day is enormous and 95% is forgotten by morning.

- **Trust/sensitivity/exportability adjectives are the AI-privacy controls Cursor doesn't have.** Today the entire codebase either goes to the cloud or it doesn't (privacy mode). MOOTx01's per-drawer sensitivity: "this drawer can go to Claude, this one is local-only, this one is secret and the AI cannot see it at all." Right granularity.

- **The AmbientSample noun type — already in the data model — is the keystroke/edit stream.** Capture every save as ambient samples, summarize into drawers periodically, capture explicit decisions into KG facts. IDE telemetry → memory pipeline.

- **The B-1 invariant translates directly.** A Cursor integration goes through GeniusLocusKit's estate verb surface, never below. aria-mcp is already the right shape — a Cursor extension consumes ARIA over MCP and gets the full substrate.

### 3.4 ML training

The data model itself encodes the shape you'd design if your job were "produce the ideal ML training corpus structure."

**Verb-to-ML-operation mapping:**

| Verb | ML operation |
|---|---|
| capture | add labeled training example |
| reanchor | relabel example |
| mutate | update with corrected info |
| withdraw | mark stale (soft-delete; re-train without it) |
| expunge | hard delete (GDPR / right-to-be-forgotten) |
| recall | inference query / nearest-neighbor lookup |
| propose | active-learning candidate |
| associate | label co-occurrence relation |
| learn | accepted knowledge / committed model output |

The ARIA grammar IS the ML data-lifecycle vocabulary. The convergence wasn't designed explicitly but it's exact, because both are about durable management of structured observations over time, with mutation discipline.

**Data-model-to-ML-primitive mapping:**

- **Every row is a training example.** Content = input. Fingerprint = feature vector. Adjective bitmaps = labels. Trust field = example weight. Sensitivity = privacy gate for federated learning.
- **`Fingerprint256` IS an embedding.** SimHash with hyperplane families is a fixed projection (no learned weights yet) but the 256-bit code is a learned representation in the LSH sense. Downstream models train on these as input features. The hyperplane family is the projection layer; rotating it produces different views (data augmentation at the feature level).
- **MDCC is your label hierarchy.** Hierarchical classification labels are exactly what tree-structured loss functions, prototype networks, and few-shot learning want.
- **The audit log is your replay buffer.** Off-policy RL, behavior cloning, imitation learning — all want exactly this structure: every state-action-outcome tuple in temporal order, replayable, indexed by HLC.
- **KG facts are knowledge-distillation targets.** Subject-predicate-object with temporal validity is the standard knowledge-base format for training KG-completion models.
- **F and O matrices are sufficient statistics.** Naive Bayes, log-linear models, any factorized model wants exactly the marginals (F) and pairwise joints (O) the matrix tier already maintains. They're delta-updated on every verb, so they're always current.
- **`CountVector256` + `majorityVote` is the cohort prototype.** Mean engram per class, computed losslessly via tree-fold. The prototype network primitive.
- **The dreaming daemon is the nightly batch training job.** The ABOUT.md framing ("subconscious consolidates while you sleep") is the same shape as "batch over yesterday's data overnight." Different vocabulary, identical operation.
- **CRDT-merge-safety + DP-OR-reduction = federated learning ready.** Multiple estates contribute aggregate statistics without centralization. Differential privacy is already in `DPORReduction.swift`. The substrate's federation primitives ARE federated learning primitives.
- **Hyperplane family per pairing scope = transfer learning.** Different feature spaces per estate-pair scope; rotation between them is structured domain adaptation.
- **`BradleyTerry`, `NMFAlternatingLeastSquares`, `FFT`, `CommunityDetection`, `RandomWalks`, `AnomalyDetection`, `LLMCalibrationCurve`, `InformationTheory`** — already shipping in SubstrateLib. Not ancillary. They are the ML algorithm library.

The substrate is *already* a structured ML training environment. It hasn't been framed that way in the docs, but the data model and the math primitives both say so.

### 3.5 Convergent findings across all four lenses

**Three Clojure↔APL convergences** (architectural friction; load-bearing):

| Convergence | Clojure framing | APL framing | One fix |
|---|---|---|---|
| A | Mutating-verb names disguise value semantics | Missing combinator layer | `zip4` / `reduce4` / `map4` on `Fingerprint256` |
| B | Implicit 36×6 bitmap layout in literals | Closure-driven matrix update over 216 cells | `RowBitmaps` type + `BitVector216` view; `MatrixF.applyRow` takes the view |
| C | Two audit shapes coexist undocumented | `prototype` duplicates `CountVector256.fold` | Same pattern at different scales: canonicalize one, delegate the other |

**Two Cursor↔ML convergences** (use-case fit; reframe-driving):

| Convergence | Cursor framing | ML framing | Implication |
|---|---|---|---|
| D | Batch retrieval over codebase | Batch inference + batch training | Combinator layer must include batch siblings |
| E | Different consumers want different parts of SubstrateLib (editors want types + algebra; trainers want types + algebra + ML primitives; performance backends want kernels) | Same finding | Three-package split, not two |

**One cross-cutting convergence** (all four lenses):

| Convergence | Framing | Implication |
|---|---|---|
| F | The verbs + types + algebra + matrices are the public surface; the kernel layer is implementation; the ML primitives are a separate concern | Document reframe — README, package map, public-API tier markings |

### 3.6 Meta-lesson: the four-lens pattern

The original two-lens review (Clojure + APL) found *architectural friction* in the existing code. Adding two more lenses (Cursor + ML training) found *use-case fit* that the existing code already supports but doesn't advertise.

Two-lens pattern surfaces: what's wrong with the implementation.
Four-lens pattern surfaces: what the implementation is actually *for*.

For future pre-ship reviews:

- Run two lenses from different language traditions over the structure (architectural friction).
- Run two lenses from different use-case traditions over the same structure (use-case fit).
- Convergent findings across all four are the ones to act on.
- Convergent findings within a pair (architectural or use-case) are second-tier action items.
- Single-lens findings need to be weighed against blast radius.

Candidate lens pairs:
- *Architectural:* Clojure + APL/J/K, Erlang + Smalltalk, Haskell + Forth, Prolog + Datalog.
- *Use-case:* AI code editor + ML training, agentic memory + customer support search, scientific notebook + analytics dashboard.

The choice of pairs should match what the code is reaching for. SubstrateLib reached for value-and-fold; Clojure + APL were the right architectural pair. SubstrateLib's data model reaches toward structured embedding-plus-classification; Cursor + ML training were the right use-case pair.

---

## 4. Decision

Land the pre-ship refactor and the documentation reframe together as one decision, before any user CloudKit zone contains durable records.

**Refactor:** six phases over approximately two weeks. Each phase is bit-identical at the conformance harness level (with one spec-pinned tie-check test for the heap-based `hammingTopK`).

**Reframe:** README, the package map, and the substrate spec are updated to describe SubstrateLib as the universal type and algebra foundation, with the kernel layer and ML-primitive layer split into separate packages.

**One explicit non-decision:** the substrate-level verb token `mutate` stays. Despite the Clojure naming critique, that string is the only SubstrateLib symbol that crosses into permanent cloud wire format (via `AuditEvent.verb` strings synced through `CKRecordMapping`). Pre-ship, no records exist. Post-ship, any rename requires a CloudKit migration plan. Method-level mutating names (`setBit`, `bitwiseOR`, `ORReduce.merge`) rename freely — CloudKit never sees them.

---

## 5. Scope

**In scope:**

- All work bit-identical at the conformance harness level.
- All Swift API surface changes (Rust mirror follows mechanically).
- Three-package split: `SubstrateTypes` + `SubstrateKernel` + `SubstrateML`.
- Documentation reframe: README, package map, spec opening.
- Explicit documentation of `Fingerprint256` as a multi-modal learned representation.

**Out of scope:**

- Rename of the substrate verb token `mutate` (CloudKit wire-locked).
- Cookbook §10 verb-name edits (depends on above).
- `MatrixT` wiring investigation (Clojure lens flagged; treat as separate issue).
- ConvergenceKit `PackedHLC`/`FingerprintWire` deduplication (Federation path; not strictly SubstrateLib).
- Building the actual Cursor extension or ML training pipeline (this decision establishes the substrate; consuming applications are separate work).

---

## 6. Plan

Six phases, ordered so each makes the next cleaner. Estimated two weeks of focused work by one developer.

### Phase 1: Combinator layer with batch siblings

Add to `Fingerprint256`:

```swift
extension Fingerprint256 {
    // Element-wise — single-pair operations
    func zip4(_ other: Self, _ op: (UInt64, UInt64) -> UInt64) -> Self
    static func reduce4<S: Sequence>(_ xs: S, _ op: (UInt64, UInt64) -> UInt64) -> Self
        where S.Element == Self
    func map4(_ op: (UInt64) -> UInt64) -> Self
    func popcount() -> Int

    // Batch — vectorize across rows; the grain ML inference and Cursor retrieval need
    static func zip4Batch(_ a: [Self], _ b: [Self],
                          _ op: (UInt64, UInt64) -> UInt64) -> [Self]
    static func map4Batch(_ xs: [Self], _ op: (UInt64) -> UInt64) -> [Self]
}
```

Rust mirror: trait methods on `Fingerprint256` plus the batch free functions.

**Conformance impact:** none. Internal implementations remain in place during Phase 1.

**Lens citations:** APL convergent A (eliminate four-block unroll); Clojure convergent A (value-semantic naming); Cursor convergent D (batch retrieval); ML convergent D (batch inference and training).

### Phase 2: Migrate reductions onto combinators

Rewrite using the new combinators:

- `ORReduce.reduce` → `Fingerprint256.reduce4(xs, |)`
- `ORReduce.merge(into:_:)` → delete; callers use `reduce4(|)` or assign
- `BitwiseArithmetic.intersect` → `a.zip4(b, &)`
- `BitwiseArithmetic.difference` → `a.zip4(b, ^)`
- `Hamming.distance(_:_:)` → `a.zip4(b, ^).popcount()`
- `ScalarKernel.hammingDistance256` → same one-liner
- `ScalarKernel.orReduce256` → same one-liner

Each kernel backend (NEON, BNNS, Metal, SIMD, scalar) revisits its overrides. Most simplify — the combinator gives one specialization point rather than four parallel ones.

**Conformance impact:** none. Bit-identical output.

**Lens citations:** APL convergent A; Clojure convergent A.

### Phase 3: Algorithm corrections

3.1. **`BitwiseArithmetic.prototype`:** delete the open-coded per-bit loop. Delegate to `CountVector256.fold(cohort).majorityVote()`. Net code deletion.

3.2. **`ScalarKernel.hammingTopK`:** replace full sort with min-heap (max-heap of size k, evicting on insert when full). Tie-breaking pinned to row-index ascending per existing spec.

**Conformance impact:** `prototype` output unchanged. `hammingTopK` requires a spec-pinned tie-check test (tie-break order unchanged; algorithm changes).

**Lens citations:** APL (asymptotic correctness in reference); Clojure/APL convergent C (canonicalize one, delegate the other).

### Phase 4: API hygiene

4.1. **`Hamming.distance(blocks:)`:** replace `Set<Int>` parameter with `BlockMask: OptionSet<UInt8>`. Zero-allocation, branchless. Update callers.

4.2. **Method-level mutating renames** (CloudKit-safe; verified §7):

- `Fingerprint256.setBit(at:to:)` → `with(bit:at:set:)` returning new value
- `Fingerprint256.bitwiseOR(_:)` → `union(_:)` for parity with `EngramLib.union`
- `ORReduce.merge(into:_:)` → deleted in Phase 2

4.3. **`EngramLib` static API:** cache `kernelForCurrentPlatform()` result at module scope (kernel is stateless and `Sendable`) rather than calling per invocation. Static API retains convenience without per-call dispatch cost.

**Conformance impact:** none. API surface changes; output unchanged.

**Lens citations:** Clojure (value-semantic naming); APL (`BlockMask` matches mask-and-AND idiom); consumer-side analysis (EngramLib hot-path footgun).

### Phase 5: Layout constants

Publish `RowBitmaps` and `BitVector216` as public types:

```swift
public struct RowBitmaps: Sendable, Hashable {
    public static let fieldCount = 36
    public static let bitsPerField = 6
    public static let bitmapsCount = 3   // adjective, operational, provenance

    public let adjective: Int64
    public let operational: Int64
    public let provenance: Int64

    public func field(_ idx: Int) -> UInt8              // 0..<36
    public func bitVector() -> BitVector216             // dense bit view
}

public struct BitVector216: Sendable, Hashable {
    // 216-bit packed view; indexable, iterable, supports + - for matrix update
}
```

Updates:

- `MatrixF.applyRow` takes `BitVector216` instead of `(Int, Int) -> Bool` closure.
- `Verbs.swift`'s `extractFieldValues` and `rowHasBit` become thin wrappers around `RowBitmaps` accessors.
- The `12` and `6` literals appear in exactly one type.

**Conformance impact:** none. Three-Int64 storage layout unchanged. CloudKit wire format unchanged (`TypedValue.bitmap(Int64)` still flows through CKRecord as `NSNumber`).

**Lens citations:** Clojure/APL convergent B; ML training (layout constants matter for tooling that wants to introspect the schema).

### Phase 6: Three-package split

Split `SubstrateLib` into three packages reflecting actual consumption:

**`SubstrateTypes`** — everyone depends:

- `Fingerprint256`, `HLC`, `AuditEvent`, `LatticeAnchor`, `CountVector256`, `RowBitmaps`, `BitVector216`
- `ORReduce`, `BitwiseArithmetic`, `Hamming`, `SimHash`, `HyperplaneFamily`
- All algebra and value types
- Conformance harness for type and algebra correctness

**`SubstrateKernel`** — only EngramLib depends:

- `PortableKernel`, `SubstrateKernel` protocol
- `ScalarKernel`, `SimdKernel`, `NeonKernel`, `BnnsKernel`, `MetalKernel`
- All hardware-dispatched fast paths
- Conformance harness for bit-identical backend output

**`SubstrateML`** — only NeuronKit depends:

- `BradleyTerry`, `NMFAlternatingLeastSquares`, `FFT`, `CommunityDetection`, `RandomWalks`, `AnomalyDetection`, `LLMCalibrationCurve`, `InformationTheory`, `MomentSummary`, `EigenvalueCentrality`, `TemporalCompression`, `FeatureExtractors`, `LatticeDistance`, `CompositeDistance`, `FloatSimHash`
- ML-flavored math primitives consumed exclusively by reasoning-layer code
- Conformance harness for algorithm correctness

Updates required:

- Every `Package.swift` in `packages/kits/` and `packages/libs/`.
- The package dep graph (also correct LocusKit's PersistenceKit-only listing → PersistenceKit + SubstrateTypes).
- Rust Cargo workspace organization (three crates instead of one).
- `README.md` opening: update SubstrateLib description (see §9).

**Why three, not two:** the consumer-side analysis showed `BradleyTerry`, `NMF`, `FFT`, `CommunityDetection`, and the rest of the ML algorithm library are consumed by NeuronKit and nothing else. PersistenceKit-PostgreSQL, ConvergenceKit-Federation, and QueueKit do not need FFT in their dependency closure. Three-way split keeps each kit's compile-time dependency surface honest to actual usage.

**Conformance impact:** organizational only. All harnesses continue to fire; they migrate to the package where their tested code lives.

**Lens citations:** consumer-side analysis (kernel layer is consumed by one client); ML convergent E (different consumers want different parts).

---

## 7. CloudKit Compatibility

`ConvergenceKitCloudKit`'s `CKRecordMapping` was audited against the proposed refactor. CloudKit is well-insulated: `CKRecordMapping` has its own HLC packing (physical 48b | logical 12b | node 4b, per CONVERGENCEKIT_SPEC.md B-6) and its own `Fingerprint256` byte layout (4 × UInt64 little-endian), both distinct from SubstrateLib's internal Codable forms.

CloudKit depends on three things from SubstrateLib:

1. **`Fingerprint256.block0/block1/block2/block3: UInt64`** as accessible properties. Preserved by the refactor (combinators are built on these).
2. **`HLC.physicalTime: Int64`, `logicalCount: Int32`, `nodeID: Int32`** as accessible properties. Preserved.
3. **`AuditEvent.verb` string tokens** ("capture", "mutate", "withdraw", etc.) become wire-locked once any user's audit log syncs. Pre-ship, no records exist; post-ship, these strings are permanent. Refactor leaves all verb tokens unchanged.

All six refactor phases are CloudKit-safe. The one rule: do not rename the substrate-level verb token `mutate`. See §4.

**Pre-existing CloudKit constraints worth documenting elsewhere (not part of this refactor):**

- `CKRecordMapping` HLC pack uses 4-bit nodeID. That's 16 replicas per estate, hard-coded in the wire format. Workable for personal estates, tight for fleet/MSP scenarios. Add a note to `ConvergenceKitCloudKit/README.md` or the sync spec.
- `SyncValueBox` (Federation path) and `CKRecordMapping` (CloudKit path) are independent serializers. Cleanup of `SyncValueBox` duplication does not affect CloudKit.

---

## 8. Verification

Every phase's deliverable validates against:

1. Existing test vectors in `Tests/SubstrateLibConformanceTests/` pass bit-for-bit. No regeneration required (one tie-check test added for `hammingTopK`).
2. Swift + Rust conformance harness fires green on every PR.
3. Every consumer kit builds and tests pass: EngramLib, PersistenceKit, VectorKit, QueueKit, ConvergenceKit, LocusKit, CorpusKit, GeniusLocusKit.
4. CloudKit round-trip integration test serializes a row through `CKRecordMapping`, decodes it, asserts byte-equivalence. Add this test as part of Phase 1 if it does not exist.

---

## 9. Documentation Updates

**`README.md`:** update the SubstrateLib paragraph and the kit-stack diagram. Old framing was "math primitives." New framing:

> **SubstrateTypes** — universal value types (Fingerprint256, HLC, AuditEvent, LatticeAnchor) and the algebra over them (OR-reduce, Hamming, SimHash, bitwise composition). Everything in MOOTx01 depends on this layer.
>
> **SubstrateKernel** — hardware-dispatched fast paths (NEON, BNNS, Metal, SIMD, scalar reference). Conformance-gated bit-identical output. Consumed by EngramLib.
>
> **SubstrateML** — ML-flavored math primitives (Bradley-Terry ranking, NMF, FFT, community detection, random walks, anomaly detection, calibration curves, information theory). Consumed by NeuronKit.

**The package map:** correct LocusKit dependency line; reflect the three-way split; update the dep graph diagram; add a new section "What SubstrateTypes actually encodes" linking to the data model description below.

**New section in the substrate spec:** explicit documentation that `Fingerprint256` is a multi-modal LSH embedding with four block-factored aspects (structural, classification, lineage+temporal, provenance). Document that downstream consumers can use it as a 256-bit input feature vector with semantic factorization. State that the block-mask in `Hamming.distance(blocks:)` is the operator that selects which aspects matter for a given query.

**New section in the substrate spec:** document the verb-to-ML-operation mapping (§3.4 table) and the data-model-to-ML-primitive mapping. State that the substrate is a structured ML training environment, that the audit log is a replay buffer, that the F/O matrices are sufficient statistics, that the dreaming daemon is the batch trainer, and that the federation primitives are federated learning primitives.

**`docs/decisions/`:** this file.

**`docs/engineering/GENIUSLOCUS_ENGINEERING_COOKBOOK.md`:** no algorithmic changes. Add a forward reference to the new "Fingerprint256 as representation" and "Substrate as ML corpus" substrate-spec sections.

---

## 10. Use-Case Implications

This section is non-binding — it captures what the refactor and reframe *enable* for downstream consumers. Building these consumers is separate work.

### 10.1 Cursor (and AI code editors generally)

- A Cursor extension consuming ARIA over MCP gets the full substrate surface: capture, recall, propose, associate.
- Code-as-drawer, verbatim-immutable, with lineage tracked structurally.
- Block-masked recall lets users query "find similar control flow" or "find code in the same MDCC subspace" or "find code I wrote in this lineage."
- Per-drawer sensitivity gates AI access at the right granularity.
- Dreaming daemon consolidates yesterday's edits overnight; tomorrow's answers prepared before the user sits down.

### 10.2 ML training pipelines

- The substrate is a queryable, replayable, federated training corpus.
- Audit log replay supports off-policy RL, behavior cloning, imitation learning.
- F/O matrices are pre-computed sufficient statistics; consumers don't need to recompute them.
- KG facts are KG-completion training data.
- Federation primitives plus DP-OR-reduction support privacy-preserving federated learning across estates.
- Hyperplane family per pairing scope supports transfer learning across estate boundaries.

### 10.3 Agentic memory generally

- Any agent that speaks ARIA gets the substrate's structured memory.
- The nine verbs are the agent's data lifecycle: capture observations, propose hypotheses, associate evidence, learn what works, withdraw or expunge what doesn't.
- The matrix tier gives the agent population statistics over its own history.
- The audit log gives the agent a coherent timeline of its own past.

### 10.4 Standalone kit composition

A developer can adopt any kit independently and compose upward as needs grow. The kit-family promise from ABOUT.md ("you focus on what your application does, the substrate is already done") depends on this property holding at every tier. The refactor strengthens it: most standalone kits get smaller, not larger, in their transitive dependency closure.

**Standalone tiers, post-refactor:**

| Adoption tier | Dependencies | What you get |
|---|---|---|
| `SubstrateTypes` alone | none | Universal value types (HLC, Fingerprint256, AuditEvent, LatticeAnchor), the algebra over them, ready as building blocks for any app |
| `SubstrateML` alone | SubstrateTypes | Bradley-Terry ranking, NMF, FFT, community detection, anomaly detection — usable as a standalone math library |
| `AriaLexiconLib` alone | none | The reified ARIA grammar — the vocabulary every MOOTx01 consumer uses |
| `LatticeLib` alone | none | Moot Decimal Classification Codes with editorial tooling |
| `PersistenceKit` alone | SubstrateTypes | Typed durable storage with SQLite, PostgreSQL, or InMemory backends |
| `ConvergenceKit` alone | SubstrateTypes, PersistenceKit | Sync abstraction with CloudKit, Federation, or None backends |
| `QueueKit` alone | SubstrateTypes, PersistenceKit | Fill-and-drain job queue with HLC-ordered claims |
| `EideticLib` alone | LatticeLib | Deterministic text-to-anchor lookup |
| `EngramLib` alone | SubstrateTypes, SubstrateKernel | 256-bit similarity, top-K search, hardware-dispatched fast paths |
| `LocusKit` alone | SubstrateTypes, PersistenceKit | Spatial memory + KG facts + audit trail (no vectors, no RAG, no Brain) |
| `VectorKit` alone | SubstrateTypes, SubstrateKernel, EngramLib, PersistenceKit | On-device embeddings + ANN search |
| `CorpusKit` alone | SubstrateTypes, SubstrateKernel, EngramLib, PersistenceKit, ConvergenceKit, VectorKit | Private RAG bundles, hybrid retrieval, no cloud dependency |
| `GeniusLocusKit` | All of the above (except SubstrateML and EideticLib) plus AriaLexiconLib, QueueKit | The unified estate verb surface, Brain layer, N estates |
| `NeuronKit` | GeniusLocusKit, EideticLib, SubstrateML | AI algorithms, dreaming/maintenance/training daemons |
| `CognitionKit` *(planned)* | NeuronKit, GeniusLocusKit | Named composable workflow recipes |

**Upgrade properties:**

- **Wire-format stable across upgrades.** `Fingerprint256`'s 4×UInt64 LE byte layout, `HLC`'s field set, `AuditEvent`'s struct shape, `TypedValue`'s cases — none change in the refactor. A developer who ships LocusKit alone at v1.0 and later upgrades to GeniusLocusKit at v1.5 does not face a data migration. SQLite, PostgreSQL, and CloudKit zones all stay readable.
- **Additive composition.** Adding a kit to an existing deployment only adds dependencies; it never requires editing the existing kit's call sites. The one exception is the B-1 invariant — adopters who upgrade past CorpusKit into GeniusLocusKit route through the estate verb surface rather than reaching into LocusKit/VectorKit/CorpusKit directly. This is documented architectural intent, not refactor breakage.
- **Independent SemVer per concern.** `SubstrateTypes`, `SubstrateKernel`, and `SubstrateML` each ship their own major version. A PersistenceKit consumer pinning `SubstrateTypes ^1.0` is unaffected by `SubstrateKernel` going to v2.0 with a new GPU backend. Today's monolithic `SubstrateLib` couples all three concerns to one major version, propagating SemVer bumps to consumers that don't use the changing surface.
- **Lower CI cost per consumer.** The conformance harness is partitioned. PersistenceKit-PostgreSQL's CI run no longer includes the Metal kernel conformance gate it doesn't exercise.

**One developer-visible change.** External SDK consumers update one import line: `import SubstrateLib` becomes `import SubstrateTypes` (and optionally `SubstrateKernel` or `SubstrateML` for the rare consumer that reaches into those layers directly). Pre-ship, this is a free refactor; post-ship at v1.0, it would be a v2.0 breaking change affecting every embedder. Doing it now preserves the SemVer commitment before the commitment exists.

**Zero-infrastructure tier still works.** `PersistenceKitInMemory`, `ConvergenceKitNone`, and QueueKit's RAM backend remain the "no provisioning required" tier for developers evaluating any kit. The refactor doesn't touch these backends.

---

## 11. Open Questions

1. Should `EngramLib.union(_:)` and `EngramLib.union(_:_:)` be renamed for parity with the Phase 4 `Fingerprint256.union` rename? Bikeshed, not architectural.
2. Should ConvergenceKit's `PackedHLC`/`FingerprintWire` duplication be resolved at the same time as the SubstrateTypes split? Would localize cleanup but isn't required for the refactor itself.
3. `MatrixT` is declared in `Substrate` but never updated by any verb in `Verbs.swift`. Out of scope for this refactor; investigate independently.
4. Should the `SubstrateML` package have its own conformance harness for the algorithm-level primitives (Bradley-Terry convergence properties, NMF reconstruction bounds, FFT round-trip), or do the existing tests in `SubstrateLibTests` suffice? Likely yes for harness parity with the other two packages.
5. Should the data-model documentation include sample queries showing block-masked recall in action (Cursor use case) and matrix-as-sufficient-statistics use (ML use case)? Strongly recommend yes; the framing is concrete only with examples.

---

## 12. Sign-off

Proposed by the architectural review, 2026-05-28. Adopted by the maintainers, 2026-05-29.

**Conformance gate:** every phase passes the Swift + Rust conformance harness with zero test-vector regeneration. CloudKit round-trip integration test passes byte-equivalence assertion. The `hammingTopK` tie-check test is the only new test added.

**Lens citations indexed in this document:**

- **APL:** §3.2, §3.5 (A, B, C), §6.1, §6.2, §6.3, §6.4, §6.5
- **Clojure:** §3.1, §3.5 (A, B, C), §6.4, §6.5, §6.6
- **Cursor:** §3.3, §3.5 (D, F), §6.1, §6.6, §10.1
- **ML training:** §3.4, §3.5 (D, E, F), §6.1, §6.5, §6.6, §9, §10.2
- **Standalone kit composition (pressure test):** §10.4
- **Four-lens meta-pattern:** §3.6

---

## Addendum — 2026-05-29: Four packages, not three (approved)

Supersedes the "atomic swap removes SubstrateLib" disposition implied by
§6 Phase 6. SubstrateLib is **retained** as the orchestration package; the
substrate ships as **four** packages, not three:

- **SubstrateTypes** — pure data, zero compute.
- **SubstrateKernel** — bandwidth-bound bit operations (the §17.6 hot path).
- **SubstrateML** — cold-path and dreaming-driven algorithms.
- **SubstrateLib** — the orchestration control surface: the nine-verb
  mechanics (`Verbs`), the row-state automaton (`RowStateAutomaton`), and
  the `AuditGate` write-gate. Depends on the other three.

**Amendment (2026-05-29): AuditGate is RETAINED in SubstrateLib.**
This reverses the original draft addendum's "remaining-symbol disposition"
row that assigned `AuditGate → SubstrateKernel`. AuditGate calls
`RowStateAutomaton.validate()`; RowStateAutomaton is retained in
SubstrateLib, so moving AuditGate to SubstrateKernel would invert the
layering (Kernel→Lib cycle). AuditGate is the write-path control surface,
not a hot-path primitive — it composes SubstrateKernel's `BitField` +
`SHA256` and SubstrateLib's `RowStateAutomaton`. The retained-symbol list
is therefore **three** — `Verbs`, `RowStateAutomaton`, `AuditGate` — not
two. (`HLCGenerator`, also a draft "→Kernel" row, was likewise already in
SubstrateTypes alongside `HLC`.)

Rationale: the verb mechanics + row-state automaton fit none of the three
sub-packages (they are not pure data, not hot-path bit ops, not cold-path
algorithms). They are the control surface that composes the three. Pushing
them up into consumers would scatter the single-hard-port control surface
and break I-25. Invariant I-30 is restated: the substrate ships as four
packages.

The blanket `@_exported` re-export in `SubstrateLibExports.swift` (Swift)
and the `pub use` bridges in `substrate-lib/lib.rs` (Rust) existed only to
keep consumers compiling mid-migration. They are removed once the symbol
tail relocates; consumers re-point precisely to the sub-package(s) they use.

## Implementation Record — 2026-05-29

The migration landed in seven commits, Swift and Rust legs together per
parallel-leg discipline, building and testing green at each step.

Two corrections to the §6 / addendum symbol disposition, discovered against
the shipped code:

1. **HLCGenerator is in SubstrateTypes, not SubstrateKernel.** It had
   already moved to SubstrateTypes (`HLC.swift`) in an earlier phase; the
   proposed-disposition row was stale. Final: HLC + HLCGenerator both in
   SubstrateTypes.
2. **AuditGate stays in SubstrateLib, not SubstrateKernel.** AuditGate calls
   `RowStateAutomaton.validate(...)`; RowStateAutomaton is the orchestration
   automaton that stays in SubstrateLib. Moving AuditGate to SubstrateKernel
   would invert the layering (Kernel must not depend on Lib). AuditGate is a
   control-surface write-gate and belongs with the verbs. Its hot-path leaves
   (`BitField`, `SHA256`) did move to SubstrateKernel; AuditGate imports them.

Final symbol homes:
- **SubstrateTypes:** Fingerprint256, HLC, HLCGenerator, AuditEvent,
  LatticeAnchor, SimHash, Hamming, ORReduce, BitwiseArithmetic, RowBitmaps,
  BlockMask, CountVector256, HyperplaneFamily, FNV, MatrixF/C/O/T, NounType,
  Row, RowState, TimeRange, GSetAuditLog, RecallTypes, ThreeDBitTensor.
- **SubstrateKernel:** PortableKernel + ScalarKernel/SimdKernel/NEON/BNNS/
  Metal, SHA256, HammingNN, BitField.
- **SubstrateML:** BradleyTerry, NMF, FFT, CommunityDetection, RandomWalks,
  AnomalyDetection, LLMCalibrationCurve, InformationTheory,
  EigenvalueCentrality, MatrixDecay, MomentSummary, TemporalCompression,
  LatticeDistance, CompositeDistance, FeatureExtractors, FloatSimHash,
  AuditLogFold, PartialStateRecall, PairingHandshake,
  TierContributionFingerprint, TierAscendingQuery, ActionOutcomeMatrix,
  DPORReduction.
- **SubstrateLib (retained):** Verbs, RowStateAutomaton, AuditGate.

Consumer end-state: only LocusKit keeps a direct SubstrateLib dependency
(verb-driver). All others depend on the precise sub-package(s) they use;
both re-export shims are deleted.

Open follow-up (not part of this migration): HARNESS_REFERENCE §2's
per-primitive path index still describes the pre-split mono layout (e.g.
`packages/libs/SubstrateLib/swift/Sources/...`) and needs a separate
path-accuracy audit.

## Math-Integrity Validation Harness (added 2026-06-01)

The project maintains a testing harness that validates the integrity of the
implemented math whenever an affected module is modified. The harness compiles
both language implementations (Swift and Rust) into an app and asserts they
produce identical output against the cookbook's reference algorithms; a
divergence fails the gate and points back to the cookbook section in question.

This harness is a **developer tool**, not part of the shipping product. The
reference/oracle implementations it exercises live **inside the harness** —
never inside a shipping crate. (Earlier the Rust `substrate-lib` crate carried
six such reference modules — `working_set`, `sqlite_tail`, `cognition_kit`,
`cognition_bundle`, `actuator`, `dreaming` — as dead, unconsumed code; they
were removed 2026-06-01 because their integrity-checking role belongs to this
harness, not to the product build.)

Rule for future work: the cross-language math reference is owned by the
validation harness. Shipping crates carry the *implementation* of an algorithm
with an inline comment citing its cookbook section number; they do **not**
carry a second, named reference copy of it. If a shipping crate accumulates
uncalled "reference" modules (a crate-level `#![allow(dead_code)]` is the
tell), that is the error this note exists to prevent — the reference belongs
in the harness.
