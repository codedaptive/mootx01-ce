---
title: ContextDistillLib Interface
status: active
authors: MOOTx01 maintainers
date: 2026-09-15
version: 1.2.0
description: "Interface contract for CONTEXTDISTILLLIB."
spec_type: kit
package: ContextDistillLib
languages: [swift, rust]
relates_to:
  - CONTEXTDISTILLLIB_SPEC.md  (the contract this interface implements)
purpose: |
  Public API surface of ContextDistillLib: the input type, the output type,
  the converter identity enum, the distiller entry point, and the supporting
  scanner and utility functions — in both the Swift and Rust ports.
---

# ContextDistillLib Interface

Product hydration calls this library at read time. The output is returned to
the caller without storing a second text representation.

## § 1 — Package layout

**Swift:** `packages/libs/ContextDistillLib/`

- `Sources/ContextDistillLib/` — public API
  - `ContextDistiller.swift` — `DistilledRepresentation`, `ContextDistiller`,
    `combine()`
  - `ContextDistillConverter.swift` — `ContextDistillConverter`
  - `DistillationInput.swift` — `DistillationInput`
  - `ShapeDecision.swift` — `ShapeDecision`
  - `ContextShape.swift` — `ContextShape` namespace
  - `IntentAtomLayer.swift` — `IntentAtom`, `SpeakerTurn`, `IntentAtomsResult`,
    and atom/turn extraction functions
  - `SelectionLayer.swift` — `IntentSpanResult` and selection functions
  - `Scanners.swift` — `MatchResult` and all `*REFinditer`/`*RESearch` functions
  - `PythonText.swift` — Unicode utility functions mirroring Python str semantics
  - `Digest.swift` — `sourceDigest()`, `estimateTokens()`, `splitEnrichment()`
- `Sources/ContextDistillLib/CompleteContentReducer.swift` — pure complete API
- `Sources/ContextDistillLib/CompleteJSON.swift` — internal JSON grammar
- `Sources/ContextDistillLib/PassageViews.swift` — ordering and Skim APIs
- `Tests/ContextDistillLibTests/` — conformance harness
- `Package.swift` — manifest (swift-tools-version 6.2, macOS 26 / iOS 26)

**Rust:** `packages/libs/ContextDistillLib/rust/`

- `src/complete_content.rs` — complete API
- `src/complete_content_json.rs` — internal JSON grammar
- `src/passage_views.rs` — ordering and Skim APIs
- `src/lib.rs` — module declarations (crate `context-distill-lib`)
- `src/shape.rs` — `ShapeDecision`, `classify_record()`,
  `nuextract_method_order()`, `qwen3_method_order()`
- `src/converter.rs` — `ContextDistillConverter`
- `src/input.rs` — `DistillationInput`
- `src/distiller.rs` — `DistilledRepresentation`, `ContextDistiller`,
  `combine()`, `project_intent_trailer()`
- `src/atoms.rs` — `IntentAtom`, `SpeakerTurn`, `speaker_turns()`,
  `physical_lines()`, `known_speaker()`, `heading_level()`, `is_list_line()`
- `src/selection.rs` — `IntentSpanResult`, `SpanInfo`, `intent_span_selection()`,
  `render_exact()`, `portable_span_offsets()`, `selection_bytes()`,
  `overlap_permille()`, `sentence_initial()`
- `src/scanners.rs` — `MatchResult` and all `*_re_finditer`/`*_re_search`
  functions
- `src/python_text.rs` — Unicode utility functions mirroring Python str semantics
- `src/digest.rs` — `source_digest()`, `estimate_tokens()`, `split_enrichment()`,
  `find_trailer_pub()`
- `src/terms.rs` — term normalization utilities
- `Cargo.toml` — manifest (crate name `context-distill-lib`)

Naming follows port conventions: Swift uses camelCase, Rust uses snake_case.
The semantic contract (SPEC §§ 4–7) is identical in both ports.

## § 2 — Entry point

### `ContextDistiller`

The primary entry point. Takes a `DistillationInput` and a
`ContextDistillConverter`, returns a `DistilledRepresentation`.

**Swift:**

```swift
public struct ContextDistiller: Sendable {
    public init()
    public func distill(
        _ input: DistillationInput,
        converter: ContextDistillConverter,
        boundedSelection: Bool = false
    ) -> DistilledRepresentation
}
```

`boundedSelection: true` is the recall read path. It declines compression and
returns the complete source as the core when the selector's source-byte
(32768), atom (256) or work (100 000 comparison units) ceiling is exceeded,
recording `selectionDetails["compression_skipped"] == true` and
`mode == "resource-budget"`. Offline distillation leaves it `false` and keeps
the frozen recipe.

**Rust:**

```rust
pub struct ContextDistiller;

impl ContextDistiller {
    pub fn new() -> Self;
    pub fn distill(
        &self,
        input: &DistillationInput,
        converter: ContextDistillConverter,
    ) -> DistilledRepresentation;
    /// `bounded: true` is the twin of Swift `boundedSelection: true`.
    pub fn distill_with_selection_budget(
        &self,
        input: &DistillationInput,
        converter: ContextDistillConverter,
        bounded: bool,
    ) -> DistilledRepresentation;
}
```

## § 3 — Input type

### `DistillationInput`

**Swift:**

```swift
public struct DistillationInput: Sendable, Equatable {
    /// The raw source content to distill.
    public var original: String
    /// Structured enrichment data. May be empty.
    public var enrichmentTrailer: String
    public init(original: String, enrichmentTrailer: String = "")
}
```

**Rust:**

```rust
pub struct DistillationInput {
    /// The raw source content to distill.
    pub original: String,
    /// Structured enrichment data. May be empty.
    pub enrichment_trailer: String,
}
impl DistillationInput {
    pub fn new(original: impl Into<String>, enrichment_trailer: impl Into<String>) -> Self;
}
```

## § 4 — Converter identity

### `ContextDistillConverter`

Identifies which converter ruleset produced an output row. Every output
row carries a `converterID` derived from this enum.

**Swift:**

```swift
public enum ContextDistillConverter: String, Sendable, Equatable, CaseIterable {
    case completeFormV6
    case intentSpanV23Attributed

    /// Complete: `"complete-form@complete-form-visible-v6"`.
    /// v23.2: `"intent-span-v23-attributed@intent-span-v23.2-attributed-prose"`.
    public var id: String { get }
    /// `"distill-plus-v1"`
    public var converterVersion: String { get }
    /// `1`
    public var schemaVersion: Int { get }
}
```

Both entry points require an explicit converter argument. Product hydration selects
`completeFormV6` / `CompleteFormV6`. The retained attributed variant's behavior
and recipe identities are defined in SPEC § 5.2.

**Rust:**

```rust
pub enum ContextDistillConverter {
    CompleteFormV6,
    /// v23.2 attributed peer-dialogue converter.
    /// Wire ID: `"intent-span-v23-attributed@intent-span-v23.2-attributed-prose"`.
    IntentSpanV23Attributed,
}
impl ContextDistillConverter {
    /// Wire ID for the converter.
    /// Complete: `"complete-form@complete-form-visible-v6"`.
    /// v23.2: `"intent-span-v23-attributed@intent-span-v23.2-attributed-prose"`.
    pub fn id(&self) -> &'static str;
    /// `"distill-plus-v1"` for all variants.
    pub fn converter_version(&self) -> &'static str;
    /// Complete: `"complete-form-visible-v6"`.
    /// v23.2: `"intent-span-v23.2-attributed-prose"`.
    pub fn ruleset_version(&self) -> &'static str;
    /// `1` for all variants.
    pub fn schema_version(&self) -> u32;
}
```

## § 5 — Output type

### `DistilledRepresentation`

**Swift:** `@unchecked Sendable, Equatable` (uses `[String: Any]` for
heterogeneous dicts; Equatable implemented by field-by-field comparison).

```swift
public struct DistilledRepresentation: @unchecked Sendable, Equatable {
    public let schemaVersion: Int
    public let converterVersion: String
    public let rulesetVersion: String
    public let converterID: String
    public let sourceSHA256: String
    public let shape: [String: Any]
    public let spanOffsetUnit: String         // always "unicode-code-point"
    public let spanUTF8OffsetUnit: String     // always "byte"
    public let selectedSourceSpans: [[String: Any]]
    public let compactCore: String
    public let appliedEnrichmentTrailer: String
    public let aiText: String
    public let miningBody: String
    public let metrics: [String: Any]
    public let selectionDetails: [String: Any]

    /// Serializes to a JSON-compatible dict (Foundation types only).
    public func asDict() -> [String: Any]
}
```

**Rust:** uses `serde_json::Value` for heterogeneous dicts; derives
`Serialize` / `Deserialize`.

```rust
pub struct DistilledRepresentation {
    pub schema_version: u32,
    pub converter_version: String,
    pub ruleset_version: String,
    pub converter_id: String,
    pub source_sha256: String,
    pub shape: Value,
    pub span_offset_unit: String,         // always "unicode-code-point"
    pub span_utf8_offset_unit: String,    // always "byte"
    pub selected_source_spans: Value,
    pub compact_core: String,
    pub applied_enrichment_trailer: String,
    pub ai_text: String,
    pub mining_body: String,
    pub metrics: Value,
    pub selection_details: Value,
}
```

## § 6 — Shape classification

### `ShapeDecision`

Output of the record-shape classifier. Mirrors the dict returned by
the Python `record_shape_classifier.classify()`.

**Swift:**

```swift
public struct ShapeDecision: Sendable, Equatable {
    public let primary: String
    public let labels: [String]
    public let scores: [String: Int]
    public let features: [String: Int]
    public let confidenceMargin: Int
    public func has(_ label: String) -> Bool
    public func asDict() -> [String: Any]
    public func canonicalJSON() throws -> String
}
```

**Rust:**

```rust
pub struct ShapeDecision {
    pub primary: String,
    pub labels: Vec<String>,
    pub scores: HashMap<String, i32>,
    pub features: HashMap<String, i64>,
    pub confidence_margin: i32,
}
```

### `ContextShape` namespace (Swift) / free functions (Rust)

```swift
// Swift
public enum ContextShape {
    public static func classify(_ content: String) -> ShapeDecision
    public static func nuextractMethodOrder(_ decision: ShapeDecision) -> [String]
    public static func qwen3MethodOrder(_ decision: ShapeDecision) -> [String]
}
```

```rust
// Rust — src/shape.rs
pub fn classify_record(content: &str) -> ShapeDecision;
pub fn nuextract_method_order(decision: &ShapeDecision) -> Vec<&'static str>;
pub fn qwen3_method_order(decision: &ShapeDecision) -> Vec<&'static str>;
```

## § 7 — Intent atom layer

### `IntentAtom`

**Swift:**

```swift
public struct IntentAtom: Sendable, Equatable {
    public let atomID: Int
    public let start: Int        // code-point offset in source
    public let end: Int          // code-point offset in source
    public let text: String
    public let kind: String
    public let speaker: String?
    public let dependencies: [Int]
    public let hardRequired: Bool
}
```

**Rust:**

```rust
pub struct IntentAtom {
    pub atom_id: usize,
    pub start: usize,      // code-point (char) offset in source
    pub end: usize,        // code-point (char) offset in source
    pub text: String,
    pub kind: String,
    pub speaker: Option<String>,
    pub dependencies: Vec<usize>,
    pub hard_required: bool,
}
```

### `SpeakerTurn`

**Swift:**

```swift
public struct SpeakerTurn: Sendable, Equatable {
    public let start: Int         // code-point offset
    public let end: Int
    public let firstLineEnd: Int
    public let bodyStart: Int
    public let speaker: String
}
```

**Rust:**

```rust
pub struct SpeakerTurn {
    pub start: usize,
    pub end: usize,
    pub first_line_end: usize,
    pub body_start: usize,
    pub speaker: String,
}
```

### `IntentAtomsResult`

**Swift:** `@unchecked Sendable`

```swift
public struct IntentAtomsResult: @unchecked Sendable {
    public let atoms: [IntentAtom]
    public let hardIDs: Set<Int>
    public let coverageIDs: Set<Int>
    public let unsupported: [String]
    public let mode: String
    public let modeExtras: [String: Any]
}
```

**Rust:** (returned inline from `intent_atoms()` as fields of
`IntentAtomsResult` equivalent; see `distiller.rs` selection path)

### Atom-layer functions

**Swift:**

```swift
public func speakerTurns(_ scalars: [Unicode.Scalar]) -> [SpeakerTurn]
public func speakerTurns(_ source: String) -> [SpeakerTurn]           // convenience
public func structuredAtoms(_ scalars: [Unicode.Scalar]) -> ([IntentAtom], [String])
public func structuredAtoms(_ source: String) -> ([IntentAtom], [String])  // convenience
public func intentAtoms(_ scalars: [Unicode.Scalar]) -> IntentAtomsResult
public func intentAtoms(_ source: String) -> IntentAtomsResult        // convenience
public func reindexAtoms(_ atoms: [IntentAtom]) -> [IntentAtom]
public func normalizedTerms(_ text: String) -> [String]
```

**Rust (src/atoms.rs):**

```rust
pub fn speaker_turns(source_chars: &[char]) -> Vec<SpeakerTurn>;
pub fn physical_lines(source_chars: &[char], start: usize, stop: usize)
    -> Vec<(usize, usize, String)>;
pub fn known_speaker(line: &str) -> Option<(String, usize)>;
pub fn heading_level(line: &str) -> Option<usize>;
pub fn is_list_line(line: &str) -> bool;
```

## § 8 — Selection layer

### `IntentSpanResult`

**Swift:** `@unchecked Sendable`

```swift
public struct IntentSpanResult: @unchecked Sendable {
    public let core: String
    public let selectedSpans: [[String: Any]]
    public let selectionDetails: [String: Any]
    public let projectedTrailer: String
}
```

**Rust:**

```rust
pub struct IntentSpanResult {
    pub compact_core: String,
    pub selected_source_spans: Vec<Value>,
    pub selection_details: Map<String, Value>,
}
```

### `SpanInfo` (Rust only)

```rust
pub struct SpanInfo {
    pub atom_id: usize,
    pub start: usize,
    pub end: usize,
    pub kind: String,
    pub speaker: Option<String>,
    pub dependencies: Vec<usize>,
    pub hard_required: bool,
}
```

### Selection functions

**Swift:**

```swift
public func intentSpan(
    _ source: String,
    trailer: String,
    peerDialogue: Bool = false,
    bounded: Bool = false
) -> IntentSpanResult
public func dependencyClosure(
    atoms: [IntentAtom],
    seedIDs: Set<Int>,
    hardIDs: Set<Int>
) -> Set<Int>
public func selectionBytes(
    scalars: [Unicode.Scalar],
    atoms: [IntentAtom],
    selected: Set<Int>
) -> Int
public func renderExact(
    scalars: [Unicode.Scalar],
    atoms: [IntentAtom],
    selected: Set<Int>
) -> String
public func portableSpanOffsets(
    scalars: [Unicode.Scalar],
    atoms: [IntentAtom],
    selected: Set<Int>
) -> [[String: Any]]
public func sourceOccurrences(
    needle: String,
    haystack: [Unicode.Scalar]
) -> [Int]
public func sentenceInitial(scalars: [Unicode.Scalar], start: Int) -> Bool
public func projectIntentTrailer(
    trailer: String,
    selectedAtoms: [IntentAtom]
) -> String
```

**Rust (src/selection.rs):**

```rust
pub fn intent_span_selection(source: &str, applied_trailer_bytes: usize) -> IntentSpanResult;
pub fn sentence_initial(source_chars: &[char], start: usize) -> bool;
pub fn selection_bytes(source_chars: &[char], atoms: &[IntentAtom], selected: &HashSet<usize>) -> usize;
pub fn overlap_permille(left: &HashSet<String>, right: &HashSet<String>) -> i64;
pub fn render_exact(source_chars: &[char], atoms: &[IntentAtom], selected: &HashSet<usize>) -> String;
pub fn portable_span_offsets(source_chars: &[char], spans: &[SpanInfo]) -> Vec<Value>;
```

## § 9 — Scanner layer

### `MatchResult`

**Swift:**

```swift
public struct MatchResult: Sendable, Equatable {
    public let start: Int      // code-point start offset
    public let end: Int        // code-point end offset (exclusive)
    public let groups: [String?]
    public init(start: Int, end: Int, groups: [String?])
}
```

**Rust:**

```rust
pub struct MatchResult {
    pub start: usize,
    pub end: usize,
    pub groups: Vec<Option<String>>,
}
```

### Scanner dispatch

**Swift:** `public func finditer(pattern name: String, in scalars: [Unicode.Scalar]) -> [MatchResult]`

**Rust:** (dispatch via pattern enum in `scanners.rs`)

### Scanner functions (both ports)

Each function mirrors a named Python `re` pattern. Swift names are camelCase
with `REFinditer`/`RESearch` suffix; Rust names are snake_case with
`_re_finditer`/`_re_search` suffix.

| Purpose | Swift name | Rust name |
|---|---|---|
| Trailer presence | `trailerRESearch` | `trailer_re_search` |
| Trailer iteration | `trailerREFinditer` | `trailer_re_finditer` |
| Pipe-split items | `pipeSplitREFinditer` | `pipe_split_re_finditer` |
| Inline numbered lists | `inlineNumberedREFinditer` | `inline_numbered_re_finditer` |
| List markers | `listMarkerREFinditer` | `list_marker_re_finditer` |
| Word tokens | `wordREFinditer` | `word_re_finditer` |
| Number tokens | `numberREFinditer` | `number_re_finditer` |
| Date patterns | `dateREFinditer` | `date_re_finditer` |
| Capitalized words | `capitalizedREFinditer` | `capitalized_re_finditer` |
| Greeting prefixes | `greetingPrefixREFinditer` | `greeting_prefix_re_finditer` |
| Greeting-only lines | `greetingOnlyREFinditer` | `greeting_only_re_finditer` |
| Dialogue fillers | `dialogueFillerOnlyREFinditer` | `dialogue_filler_only_re_finditer` |
| Revision markers | `revisionMarkerREFinditer` | `revision_marker_re_finditer` |
| Initial-draft markers | `initialDraftMarkerREFinditer` | `initial_draft_marker_re_finditer` |
| Operative verbs | `operativeREFinditer` | `operative_re_finditer` |
| Turn fillers | `turnFillerREFinditer` | `turn_filler_re_finditer` |
| Assistant boilerplate | `assistantBoilerplateREFinditer` | `assistant_boilerplate_re_finditer` |
| Embedded user facts | `embeddedUserFactREFinditer` | `embedded_user_fact_re_finditer` |
| Fence opens | `fenceOpenREFinditer` | `fence_open_re_finditer` |
| Markdown headings | `markdownHeadingREFinditer` | `markdown_heading_re_finditer` |
| Bold headings | `boldHeadingREFinditer` | `bold_heading_re_finditer` |
| Field lines | `fieldLineREFinditer` | `field_line_re_finditer` |
| Table separators | `tableSeparatorREFinditer` | `table_separator_re_finditer` |
| Diagrams | `diagramREFinditer` | `diagram_re_finditer` |
| Polarity-only | `polarityOnlyREFinditer` | `polarity_only_re_finditer` |
| Transform followup | `transformFollowupREFinditer` | `transform_followup_re_finditer` |
| Quantity values | `quantityValueREFinditer` | `quantity_value_re_finditer` |

## § 10 — Text utilities (PythonText)

Functions that mirror Python `str` and Unicode behavior. Both ports expose
the same semantics; the names below are the Swift forms; Rust equivalents
use snake_case.

**Swift:**

```swift
public func isPythonWhitespace(_ s: Unicode.Scalar) -> Bool
public func isPythonWordChar(_ s: Unicode.Scalar) -> Bool
public func pyWordBoundary(at index: Int, in scalars: [Unicode.Scalar]) -> Bool
public func pyIsAlnum(_ s: Unicode.Scalar) -> Bool
public func pyIsAlpha(_ s: Unicode.Scalar) -> Bool
public func pyIsDigit(_ s: Unicode.Scalar) -> Bool
public func pyIsUpper(_ s: Unicode.Scalar) -> Bool
public func pyLower(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar]
public func pySplit(_ scalars: [Unicode.Scalar]) -> [[Unicode.Scalar]]
public func pyStrip(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar]
public func pyLstrip(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar]
public func pyRstrip(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar]
public func utf8ByteOffset(forCodePoint cpIndex: Int, in scalars: [Unicode.Scalar]) -> Int
```

## § 11 — Digest utilities

**Swift:**

```swift
/// SHA-256 (lowercase hex) of `content` encoded as UTF-8.
/// Mirrors `hashlib.sha256(content.encode()).hexdigest()`.
public func sourceDigest(_ content: String) -> String

/// Approximate token count: len(content.split()) * 4 // 3.
/// Mirrors Python `estimate_tokens()`.
public func estimateTokens(_ text: String) -> Int

/// Splits a combined string into (body, trailer) at the enrichment boundary.
/// Mirrors Python `split_enrichment()`.
public func splitEnrichment(_ text: String) -> (body: String, trailer: String)
```

**Rust (src/digest.rs):**

```rust
pub fn source_digest(content: &str) -> String;
pub fn estimate_tokens(text: &str) -> u64;
pub fn split_enrichment(distilled: &str) -> (String, String);
pub fn find_trailer_pub(text: &str) -> Option<(usize, String)>;
```

## § 12 — Combination utility

**Swift:**

```swift
/// Combines `core` and `trailer` into a single AI-readable string.
/// When `trailer` is empty, returns `core` unchanged.
public func combine(_ core: String, trailer: String) -> String
```

**Rust (src/distiller.rs):**

```rust
pub fn combine(core: &str, trailer: &str) -> String;
```


## § 13 — Complete-content API

See SPEC §§ 5.1–5.2 and § 6. Module: `complete_content` in Rust.
This is the pure counter-injection seam, distinct from standard envelope dispatch.

```swift
public struct CompleteContentResult: Sendable {
    public let version: String
    public let text: String
    public let sourceSHA256: String
    public let representationSHA256: String
    public let visibleRefs: Bool
    public let originalTokens: Int
    public let outputTokens: Int
    public let referenceExpansionError: ReferenceExpansionError?
    public let qualityQualified = false
    public let modelAssistance = false
}
public struct ReferenceExpansionError: Codable, Equatable, Sendable {
    public let code: String
    public let message: String
    public let attemptedBytes: Int
    public let maxBytes: Int
    public let maxRatio: Int
}
public enum CompleteContentError: Error {
    case invalidRepresentation(String)
}
public enum CompleteContentReducer {
    public static let version = "complete-form-visible-v6"
    public static func distill(
        _ source: String,
        count: (String) -> Int = estimateTokens
    ) throws -> CompleteContentResult
}
```

```rust
pub struct CompleteContentResult {
    pub version: String,
    pub text: String,
    pub source_sha256: String,
    pub representation_sha256: String,
    pub visible_refs: bool,
    pub original_tokens: u64,
    pub output_tokens: u64,
    pub quality_qualified: bool,
    pub model_assistance: bool,
    pub reference_expansion_error: Option<ReferenceExpansionError>,
}
pub struct ReferenceExpansionError {
    pub code: String,
    pub message: String,
    pub attempted_bytes: usize,
    pub max_bytes: usize,
    pub max_ratio: usize,
}
pub struct CompleteContentReducer;
impl CompleteContentReducer {
    pub fn distill(source: &str, count: impl Fn(&str) -> u64)
        -> Result<CompleteContentResult, String>;
}
```

Rust result and reference-expansion error derive Debug, Clone, PartialEq, Eq,
Serialize and Deserialize. The optional error is omitted during serialization
when no limit fired and defaults to `None` when decoding older vectors.
Rust errors are strings, not a typed error enum. Pass
`context_distill_lib::digest::estimate_tokens` for the advisory default equivalent.

Rust also publishes the grammar constants in `complete_content`:

```rust
pub const VERSION: &str = "complete-form-visible-v6";
pub const REPEAT_LEGEND: &str = "Repeated-text notation: [[TSREF:n DEFINE]] introduces one exact line; [[TSREF:n REPEAT]] repeats that complete line at its current position.\n";
pub const VISIBLE_NOTICE: &str = "Linked repeats show their original numeric link prefix before the reference; the reference still denotes the whole original entry.\n";
```

## § 14 — Prototype orderReducer and Skim

See SPEC §§ 5.3–5.4 and § 6. Rust module: `passage_views`.

```swift
public struct PassageViewResult: Codable, Equatable, Sendable {
    public let version: String
    public let text: String
    public let continuation: String
    public let fullText: String
    public let complete: Bool
    public let budgetHonored: Bool
    public let budget: Int
    public let returnedBytes: Int
    public let spans: [[Int]]
    public let groupOrder: [Int]
}
public struct PassageViewPair: Codable, Equatable, Sendable {
    public let plain: PassageViewResult
    public let ordered: PassageViewResult
}
public enum PassageViewError: Error, Equatable { case invalidBudget }
public enum PassageViews {
    public static let version = "dependency-groups-utf8-v1"
    public static func build(body: String, query: String, budget: Int)
        throws -> PassageViewPair
    public static func orderReducer(body: String, query: String = "") -> String
    public static func skim(body: String, query: String = "", budget: Int,
                            ordered: Bool = true) throws -> PassageViewResult
}
```

```rust
pub struct PassageViewResult {
    pub version: String,
    pub text: String,
    pub continuation: String,
    pub full_text: String,
    pub complete: bool,
    pub budget_honored: bool,
    pub budget: usize,
    pub returned_bytes: usize,
    pub spans: Vec<[usize; 2]>,
    pub group_order: Vec<usize>,
}
pub struct PassageViewPair {
    pub plain: PassageViewResult,
    pub ordered: PassageViewResult,
}
pub fn build_views(body: &str, query: &str, budget: usize)
    -> Result<PassageViewPair, &'static str>;
pub fn order_reducer(body: &str, query: &str) -> String;
pub fn skim(body: &str, query: &str, budget: usize, ordered: bool)
    -> Result<PassageViewResult, &'static str>;
```

Rust view structs derive Debug, Clone, PartialEq, Eq, Serialize and Deserialize.
The module exports `pub const VERSION: &str = "dependency-groups-utf8-v1";`.
Swift Codable keys match Rust snake_case keys, including `full_text`,
`budget_honored`, `returned_bytes` and `group_order`.
Rust invalid-budget error: `budget must be a positive integer UTF-8 byte count`.

## § 15 — Invocation and conformance entry points

ARIA exposes source-order Skim through `moot_memory_get(depth: "skim")`, with a
fixed 512 UTF-8 byte target. Only preview text, completeness/budget flags, and
savings leave that boundary; `continuation` and `fullText` remain internal.

Normal distillation (Skim and ordering are explicit optional calls):

```swift
let result = ContextDistiller().distill(
    DistillationInput(original: body), converter: .completeFormV6)
let distilled = result.aiText
let ordered = PassageViews.orderReducer(body: distilled, query: question)
let preview = try PassageViews.skim(
    body: distilled, query: question, budget: 512)
```

```rust
use context_distill_lib::{converter::ContextDistillConverter,
    distiller::ContextDistiller, input::DistillationInput,
    passage_views::{order_reducer, skim}};
let result = ContextDistiller::new().distill(
    &DistillationInput::new(body, ""), ContextDistillConverter::CompleteFormV6);
let ordered = order_reducer(&result.ai_text, question);
let preview = skim(&result.ai_text, question, 512, true)?;
```

Use a task-owned build directory for native tests:

```sh
swift test --package-path packages/libs/ContextDistillLib --scratch-path .build-native/context-swift
CARGO_TARGET_DIR="$PWD/.build-native/rust" cargo test --manifest-path packages/libs/ContextDistillLib/rust/Cargo.toml
```

CompleteContentReducer/CompleteDispatch/PassageViews tests (Swift) and
complete_content_conformance/complete_dispatch/passage_views tests (Rust)
exercise SPEC § 7. Existing v23.2 golden tests remain.
The benchmark-only TokenSaver lab supplies semantic evaluation machinery;
it is not a runtime dependency.

## Changelog

### 1.2.0 — 2026-09-15

Add the structured reference-expansion limit result shared by Swift and Rust;
document exact-input fallback and settings-governed UTF-8 byte limits.

### 1.1.0 — 2026-09-15

Add `boundedSelection` / `distill_with_selection_budget` and the `bounded`
argument of `intentSpan`: the recall read path declines compression above the
source-byte, atom and selector-work ceilings and returns the complete source.
Record the existing `peerDialogue` argument. Paired with SPEC 1.1.0.

### 1.0.0 — 2026-09-08

Add native complete reducer and separate prototype orderReducer/Skim signatures,
errors, examples and tests; remove v22 selection. Correct explicit converter
argument and source offset units. Paired with SPEC 1.0.0.


### v0.1 -- 2026-09-02

Initial interface document. Authored from CDL-01 conformance implementation.

### v0.2 -- 2026-09-02

Add IntentSpanV23Attributed to the Swift and Rust converter enums, document ContextDistillConverter for both ports, and document the selection_details.rendering key.

### 0.2.1 -- 2026-09-06

Documented inline hydration as the product consumer.
