---
title: <PackageName> Interface
version: MAJOR.MINOR.PATCH
status: draft | review | active | deprecated | superseded
date: <YYYY-MM-DD>
description: Public API surface of <PackageName> — the signatures that satisfy <PACKAGE>_SPEC.md.
spec_type: kit | protocol | encoder
authors: MOOTx01 maintainers
languages: [swift]   # add "rust" once the Rust port lands
relates_to:
  - docs/reference/<PACKAGE>_SPEC.md   # the contract this interface implements
---

# <PackageName> Interface

<!--
TEMPLATE INSTRUCTIONS (delete this block when filling in):

This is the API surface. It says what the package exposes and in
what shape. Every type, function, and error this package
publishes appears here with its actual signature, per language.
Behavioral promises do NOT live here — those live in SPEC and are
cited by section number.

Filling this stub:
1. Replace placeholders:
   - <PackageName> → CamelCase identifier (e.g., LocusKit)
   - <PACKAGE>     → UPPERCASE filename stem (e.g., LOCUSKIT)
   - <kits|libs>   → kits or libs (matches the Packages/ subdir)
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
  Swift:  packages/<kits|libs>/<PackageName>/Sources/<PackageName>/
  Rust:   <crate-path>/src/
  Tests:  packages/<kits|libs>/<PackageName>/Tests/<PackageName>Tests/
-->

## § 1 — Package layout

<!-- Where this package lives in the source tree, per language. -->

**Swift:** `packages/<kits|libs>/<PackageName>/`

- `Sources/<PackageName>/` — public API + implementation
- `Tests/<PackageName>Tests/` — conformance tests
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
    // TODO: fill in from Sources/<PackageName>/<TypeName>.swift
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
public enum <PackageName>Error: Error, Sendable {
    case <case>(<associatedValues>)
    // TODO: fill in remaining cases from Sources/<PackageName>/Errors.swift
}
```

**Rust:**

```rust
#[derive(Debug, thiserror::Error)]
pub enum <PackageName>Error {
    // TODO: fill in from <crate-path>/src/error.rs
}
```

## § 5 — Conformance test entry points

<!-- How to run the conformance harness for this package, per
language. -->

**Swift:**

```
swift test --package-path packages/<kits|libs>/<PackageName>
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

*End of <PackageName> Interface.*
