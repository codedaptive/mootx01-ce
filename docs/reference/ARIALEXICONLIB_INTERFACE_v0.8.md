---
status: draft
authors: Bob Pankratz (via/ claude)
date: 2026-05-27
version: v0.8
package: AriaLexiconLib
languages: [swift, rust]
relates_to:
  - ARIALEXICONLIB_SPEC_v0.8.md  (the contract this interface implements)
purpose: |
  Public API surface of AriaLexiconLib: the noun, verb, adjective, and
  flow enumerations, the verb-noun acceptance matrix, and the grammar
  constant — in both the Swift and Rust ports. The companion SPEC
  document carries the behavioral contracts (invariants I-1…I-5,
  conformance C-1…C-5) these signatures satisfy.
---

# AriaLexiconLib Interface

## § 1 — Package layout

**Swift:** `packages/libs/AriaLexiconLib/`

- `Sources/AriaLexiconLib/` — public API (Noun, Verb, Adjective, Flow,
  NounRole, Acceptance, the `AriaLexiconLib` grammar namespace)
- `Tests/AriaLexiconLibTests/` — conformance tests
- `Package.swift` — manifest (module + product name `AriaLexiconLib`)

**Rust:** `packages/libs/AriaLexiconLib/rust/`

- `src/lib.rs` — public API (crate `aria_lexicon_lib`)
- `src/lib.rs` `#[cfg(test)] mod tests` — conformance tests
- `Cargo.toml` — manifest (crate `aria-lexicon-lib`)

Naming differs by port convention: Swift `Verb.capture`, Rust
`Verb::Capture`; Swift `CaseIterable.allCases`, Rust `Verb::ALL`. The
case *set* and order are identical (SPEC § 7, C-5).

## § 2 — Public types

### `Noun`

The eight storage shapes the substrate persists. `Drawer` is the one
noun of the language; the rest carry a `role` relative to it
(SPEC § 5, B-2).

**Swift:**

```swift
public enum Noun: String, CaseIterable, Sendable, Codable {
    case drawer, tunnel, kgFact, vector, diaryEntry, proposal, association, learnedReference

    /// The one noun of the language.
    public static let primary: Noun  // == .drawer

    /// How this shape relates to the drawer.
    public var role: NounRole { get }
}
```

**Rust:**

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Noun { Drawer, Tunnel, KgFact, Vector, DiaryEntry, Proposal, Association, LearnedReference }

impl Noun {
    pub const ALL: [Noun; 8];        // declaration order
    pub const PRIMARY: Noun;         // == Noun::Drawer
    pub fn role(self) -> NounRole;
}
```

### `NounRole`

A storage shape's relationship to the drawer.

**Swift:**

```swift
public enum NounRole: String, CaseIterable, Sendable, Codable {
    case primary   // the drawer itself
    case rung      // a representation of the drawer's content
    case structure // an edge or event about drawers
    case product   // what a verb leaves behind
}
```

**Rust:**

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum NounRole { Primary, Rung, Structure, Product }
```

### `Verb`

The nine actions, fixed at nine (SPEC § 4, I-1).

**Swift:**

```swift
public enum Verb: String, CaseIterable, Sendable, Codable {
    case capture, reanchor, mutate, withdraw, expunge, recall, propose, associate, learn

    /// Who initiates the verb.
    public var flow: Flow { get }
}
```

**Rust:**

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Verb { Capture, Reanchor, Mutate, Withdraw, Expunge, Recall, Propose, Associate, Learn }

impl Verb {
    pub const ALL: [Verb; 9];     // declaration order
    pub fn flow(self) -> Flow;
}
```

### `Flow`

Who initiates a verb (SPEC § 5, B-3).

**Swift:**

```swift
public enum Flow: String, CaseIterable, Sendable, Codable {
    case callerDriven    // invoked synchronously by the application
    case substrateDriven // emitted by the Brain layer's standing signals
    case groundingDriven // brings authoritative external reference in
}
```

**Rust:**

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Flow { CallerDriven, SubstrateDriven, GroundingDriven }
```

### `Adjective`

The four cross-noun adjective categories, fixed at four (SPEC § 4,
I-2). This type names the categories; the values within each are a
LocusKit bitmap-layout concern (SPEC § 8).

**Swift:**

```swift
public enum Adjective: String, CaseIterable, Sendable, Codable {
    case state          // epistemic timeline position
    case trust          // how the content was established
    case sensitivity    // how exposed the content may be
    case exportability  // whether content may leave the perimeter
}
```

**Rust:**

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Adjective { State, Trust, Sensitivity, Exportability }

impl Adjective { pub const ALL: [Adjective; 4]; }
```

### `AriaLexiconLib` (Swift) / `GRAMMAR` (Rust)

The grammar contract string (SPEC § 1).

**Swift:**

```swift
public enum AriaLexiconLib {
    /// "Every call is one verb applied to a noun, optionally constrained by adjectives."
    public static let grammar: String
}
```

**Rust:**

```rust
pub const GRAMMAR: &str;
```

## § 3 — Public functions

### `Acceptance` (Swift) / `accepted_verbs` + `accepts` (Rust)

The verb-noun acceptance matrix (SPEC § 5 B-1, § 7 C-3). Total over
`Noun`; `Vector` accepts the empty set.

**Swift:**

```swift
public enum Acceptance {
    /// The verbs a shape accepts.
    public static func verbs(for noun: Noun) -> Set<Verb>

    /// Whether a shape accepts a verb.
    public static func accepts(_ noun: Noun, _ verb: Verb) -> Bool
}
```

**Rust:**

```rust
/// The verbs a shape accepts, in canonical verb order.
pub fn accepted_verbs(noun: Noun) -> Vec<Verb>;

/// Whether a shape accepts a verb.
pub fn accepts(noun: Noun, verb: Verb) -> bool;
```

Note the return-type difference: Swift returns an unordered `Set<Verb>`;
Rust returns an order-preserving `Vec<Verb>` (canonical verb order). The
*membership* is identical across ports (C-3); only Rust additionally
pins order.

## § 4 — Errors

Not applicable. AriaLexiconLib exposes no failable operations — there is
no error enum in either port. See SPEC § 6.

## § 5 — Conformance test entry points

**Swift:**

```
swift test --package-path packages/libs/AriaLexiconLib
```

(Run with the Xcode toolchain: prefix
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` so XCTest /
swift-testing resolve. Suite: `AriaLexiconLibTests`.)

**Rust:**

```
cargo test -p aria-lexicon-lib
```

(Tests live in `src/lib.rs` under `#[cfg(test)] mod tests`: verb count,
adjective count, primary noun, role partition, flow partition,
acceptance matrix, applicability, grammar.)

## § 6 — Examples

```swift
import AriaLexiconLib

// Project the legal (noun, verb) surface — the same enumeration
// ARIA_MCP uses to build its tool list.
for noun in Noun.allCases {
    for verb in Verb.allCases where Acceptance.accepts(noun, verb) {
        print("\(noun.rawValue) accepts \(verb.rawValue)")
    }
}

// Filter to caller-driven verbs.
let caller = Verb.allCases.filter { $0.flow == .callerDriven }
```

## § 7 — Concordance: Acceptance matrix membership

The verb-noun acceptance matrix is pure vocabulary with zero platform
binding. The membership must be identical between the Swift and Rust
ports (SPEC § 7, C-3). Swift is the reference; the Rust `accepted_verbs`
function must return exactly the same verb set for every noun.

Canonical matrix (verified 2026-06-05 against Swift `Acceptance.swift`):

| Noun | Accepted verbs |
|---|---|
| `Drawer` | capture, reanchor, mutate, withdraw, expunge, recall |
| `Tunnel` | capture, mutate, withdraw, expunge, recall |
| `KgFact` | mutate, withdraw, expunge, recall |
| `Vector` | *(empty — substrate-managed, not directly verb-addressable)* |
| `DiaryEntry` | recall |
| `Proposal` | **propose**, mutate, withdraw, expunge, recall |
| `Association` | **associate**, mutate, expunge, recall |
| `LearnedReference` | learn, mutate, withdraw, expunge, recall |

The `Proposal` row accepts `propose` because the substrate-driven `propose`
verb is what creates a Proposal — the shape must accept the verb that
produces it. The `Association` row accepts `associate` for the same reason:
the substrate-driven `associate` verb accumulates connective weight into an
Association.

Conformance gate note: the Rust `acceptance_matrix` test pins the full
verb set for every noun-row including `Propose` and `Associate`. Any
regression in these rows will cause the test to fail immediately.

## Swift/Rust Concordance

One row per public concept. Each Swift and Rust symbol below was read from
source (file:line cited). AriaLexiconLib is pure vocabulary with zero
platform binding, so the bar is identical content across ports: same case
sets, same role/flow partitions, same acceptance matrix. There are no Apple
platform-bound types here, so nothing is Exempt; everything is force-mirrored.

Two concepts differ in *shape* by sanctioned idiom, not in content:

- Swift uses a caseless `enum` as a namespace for static members
  (`Acceptance`, `AriaLexiconLib`); Rust has no caseless-enum-namespace idiom,
  so the same surface is reified as free functions (`accepted_verbs`/`accepts`)
  and a module-level `const` (`GRAMMAR`). The contract — the matrix membership
  and the grammar sentence — is byte-for-byte identical and conformance-gated.
  This is the same Swift-namespace / Rust-free-function seam sanctioned
  elsewhere in the parity surface; it is not Swift-only contract surface.
- Swift enum case spelling is camelCase raw-value-backed (`kgFact`,
  `learnedReference`, `callerDriven`); Rust uses PascalCase variants
  (`KgFact`, `LearnedReference`, `CallerDriven`). Idiomatic per-language
  casing of the same case set.

| Concept | Swift symbol | Rust symbol | Visibility | Shape rule | Test/vector binding | Status |
|---|---|---|---|---|---|---|
| Storage shape (the 8 nouns) | `Noun` enum (`Noun.swift:14`) | `Noun` enum (`lib.rs:37`) | public / pub | identical case set; Swift camelCase raw values / Rust PascalCase variants (idiom) | Swift `NounTests.swift` "eight storage shapes, drawer first"; Rust `lib.rs::drawer_is_primary` + `non_drawer_shapes_have_roles` | Confirmed |
| Noun-to-drawer relationship | `NounRole` enum (`Noun.swift:45`) | `NounRole` enum (`lib.rs:22`) | public / pub | identical case set (primary/rung/structure/product) | Swift `NounTests.swift` "four roles partition the eight shapes 1/2/3/2"; Rust `lib.rs::non_drawer_shapes_have_roles` | Confirmed |
| Primary noun marker + role map | `Noun.primary` / `Noun.role` (`Noun.swift:27`,`:30`) | `Noun::PRIMARY` / `Noun::role` (`lib.rs:56`,`:59`) | public / pub | Swift static `let` + computed property / Rust associated `const` + method (idiom) | Swift `NounTests.swift` "drawer is the one noun"; Rust `lib.rs::drawer_is_primary` | Confirmed |
| Action vocabulary (the 9 verbs) | `Verb` enum (`Verb.swift:9`) | `Verb` enum (`lib.rs:79`) | public / pub | identical case set; Swift camelCase / Rust PascalCase (idiom) | Swift `VerbTests.swift` "nine verbs in canonical declaration order"; Rust `lib.rs::verb_count_is_nine` | Confirmed |
| Verb initiator class | `Flow` enum (`Verb.swift:37`) | `Flow` enum (`lib.rs:71`) | public / pub | identical case set (callerDriven/substrateDriven/groundingDriven) | Swift `VerbTests.swift` "three flows partition the nine verbs 6/2/1"; Rust `lib.rs::verb_flows_partition` | Confirmed |
| Flow map per verb | `Verb.flow` (`Verb.swift:21`) | `Verb::flow` (`lib.rs:99`) | public / pub | Swift computed property / Rust method (idiom) | Swift `VerbTests.swift` "Verb flows partition…"; Rust `lib.rs::verb_flows_partition` | Confirmed |
| Adjective categories (the 4) | `Adjective` enum (`Adjective.swift:13`) | `Adjective` enum (`lib.rs:114`) | public / pub | identical case set (state/trust/sensitivity/exportability) | Swift `AdjectiveTests.swift` "category count fixed at four (I-8)" + "four categories are…"; Rust `lib.rs::adjective_count_is_four` | Confirmed |
| The grammar sentence | `AriaLexiconLib.grammar` (`AriaLexiconLib.swift:13`,`:15`) | `GRAMMAR` const (`lib.rs:17`) | public / pub | Swift caseless-enum namespace static `let` / Rust module-level `const` (sanctioned namespace-vs-free seam) — content identical | Swift `LexiconTests.swift` "grammar sentence is stated"; Rust `lib.rs::grammar_stated` | Confirmed |
| Verb-noun acceptance matrix | `Acceptance` enum: `verbs(for:)` / `accepts(_:_:)` (`Acceptance.swift:10`,`:14`,`:36`) | free fns `accepted_verbs` / `accepts` (`lib.rs:131`,`:151`) | public / pub | Swift caseless-enum namespace with statics / Rust free functions (sanctioned namespace-vs-free seam); Swift returns `Set<Verb>` (unordered) / Rust returns ordered `Vec<Verb>` — membership is the contract, not order | Swift `AcceptanceTests.swift::matrixMatchesSpec` + `acceptsIsMembershipEverywhere`; Rust `lib.rs::acceptance_matrix` + `accepts_agrees` (conformance gate, C-3) | Confirmed |

All rows Status=Confirmed: every concept is present in both ports and
behavior-bound by a conformance test. No DRIFT, no Exempt rows — there are no
Apple platform bindings in this lib.

---

*End of AriaLexiconLib Interface v0.8.*
