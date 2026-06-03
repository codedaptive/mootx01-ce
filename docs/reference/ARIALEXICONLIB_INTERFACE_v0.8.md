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
  constant — in both the Swift and Rust versions. The companion SPEC
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
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` so
swift-testing resolves. Suite: `AriaLexiconLibTests`.)

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

---

*End of AriaLexiconLib Interface v0.8.*
