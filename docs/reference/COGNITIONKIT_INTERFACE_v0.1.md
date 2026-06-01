---
status: stub
authors: Bob Pankratz (via/ claude)
date: 2026-05-26
version: v0.1
package: CognitionKit
languages: [swift]  # add "rust" once the Rust version lands
relates_to:
  - COGNITIONKIT_SPEC_v0.1.md  (the contract this interface implements)
purpose: |
  Public API surface of CognitionKit. Type signatures, method
  shapes, error enums. The companion SPEC document carries the
  behavioral contracts that these signatures must satisfy.
---

# CognitionKit Interface

<!--
TEMPLATE INSTRUCTIONS (delete this block when filling in):

This is the API surface. It says what the package exposes and in
what shape. Every type, function, and error this package
publishes appears here with its actual signature, per language.
Behavioral promises do NOT live here — those live in SPEC and are
cited by section number.

Filling this stub:
1. Replace placeholders:
   - CognitionKit → CamelCase identifier (e.g., LocusKit)
   - COGNITIONKIT     → UPPERCASE filename stem (e.g., LOCUSKIT)
   - kits   → kits or libs (matches the Packages/ subdir)
   Leave the in-section <placeholders> (<TypeName>, <functionName>,
   <crate-path>, etc.) for the code-walking pass to fill in.
2. For each public type, function, and error: paste the actual
   signature from the source tree. Strip implementation; keep
   only the public surface.
3. For every section: list every public member. Missing members
   indicate either an INTERFACE gap or an unwanted-public-API
   leak — both are findings worth raising.
4. Cross-reference SPEC by section ("see SPEC § 4.2 for ordering
   guarantees").
5. Bilingual: if Rust version exists, paste Rust signatures alongside
   Swift. If not, omit the rust block but keep `languages: [swift]`
   in frontmatter so the gap is visible.

Source of truth at fill time:
  Swift:  Packages/kits/CognitionKit/Sources/CognitionKit/
  Rust:   <crate-path>/src/
  Tests:  Packages/kits/CognitionKit/Tests/CognitionKitTests/
-->

## § 1 — Package layout

<!-- Where this package lives in the source tree, per language. -->

**Swift:** `Packages/kits/CognitionKit/`

- `Sources/CognitionKit/` — public API + implementation
- `Tests/CognitionKitTests/` — conformance tests
- `Package.swift` — manifest

**Rust:** `<crate-path>/`

- `src/` — public API + implementation
- `tests/` — conformance tests
- `Cargo.toml` — manifest

## § 2 — Public types

<!-- One subsection per public type. For each: a one-line prose
description, then bilingual code blocks. -->

### `<TypeName>`

<One-line description. Cite SPEC if relevant.>

**Swift:**

```swift
public struct <TypeName>: Sendable, Codable {
    // TODO: fill in from Sources/CognitionKit/<TypeName>.swift
}
```

**Rust:**

```rust
pub struct <TypeName> {
    // TODO: fill in from <crate-path>/src/<type_name>.rs
}
```

## § 3 — Public functions

<!-- One subsection per public function or method group. -->

### `<functionName>`

<One-line description. Cite SPEC § N for the behavioral contract.>

**Swift:**

```swift
public func <functionName>(...) async throws -> <ReturnType>
```

**Rust:**

```rust
pub async fn <function_name>(...) -> Result<<ReturnType>, <ErrorType>>
```

## § 4 — Errors

<!-- The error enum cases, per language. The behavioral meaning
of each category lives in SPEC § 6; this section is the shape. -->

**Swift:**

```swift
public enum CognitionKitError: Error, Sendable {
    case <case>(<associatedValues>)
    // TODO: fill in remaining cases from Sources/CognitionKit/Errors.swift
}
```

**Rust:**

```rust
#[derive(Debug, thiserror::Error)]
pub enum CognitionKitError {
    // TODO: fill in from <crate-path>/src/error.rs
}
```

## § 5 — Conformance test entry points

<!-- How to run the conformance harness for this package, per
language. -->

**Swift:**

```
swift test --package-path Packages/kits/CognitionKit
```

**Rust:**

```
cargo test -p <crate-name>
```

## § 6 — Examples (optional)

<!-- One or two minimal usage examples that exercise the most
common path. Delete this section if examples live elsewhere
(e.g., in package README). -->

```swift
// TODO: minimal usage example
```

---

*End of CognitionKit Interface v0.1.*
