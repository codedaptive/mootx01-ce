---
status: superseded
authors: MOOTx01 maintainers
date: 2026-06-14
version: 1.0.0
description: Public API surface for LatticeKit in both the Swift and Rust ports.
package: LatticeKit
languages: [swift]   # Rust version pending; canon + grammar is the cross-port target
relates_to:
  - docs/reference/LATTICEKIT_SPEC.md  (the contract this interface implements)
purpose: |
  Public API surface of LatticeKit (Swift; Rust version pending). § 2
  Tier 1 documents the consumed contract — canon lookup and the code
  grammar — in full. The Tier 2 subsection of § 2 is a table of contents
  for the editorial / assembly tooling (the `mdcc-build` machinery),
  present in the package but not consumed by other packages. The
  companion SPEC carries the behavioral contracts (I-1…I-5, C-1…C-4).
superseded_by: ../reference/FDC_ENCODER_CANONICAL.md
---

> **SUPERSEDED (MDCC→FDC migration).** The MDCC machinery this document describes was removed; the shipped classifier is the FDC encoder — see `docs/reference/FDC_ENCODER_CANONICAL.md` and `docs/engineering/FDC_ENCODER_COOKBOOK.md`. Retained for history only.

# LatticeKit Interface

## § 1 — Package layout

**Swift:** `packages/kits/LatticeKit/`

- `Sources/LatticeKit/` — canon, code grammar, assembler, editorial pins,
  Wikidata source, stable-key registry
- `Sources/LatticeKit/Resources/LatticeCanonV1.json` — the bundled canon
- `Sources/mdcc-build/` — the `mdcc-build` editorial CLI executable
- `Tests/LatticeKitTests/`, `Package.swift`

**Rust:** pending. The canon format + code grammar (Tier 1) are the
cross-port conformance target when the port lands.

## § 2 — Public types

### Tier 1 — consumed contract

#### `LatticeKit`

The package namespace: bundled-canon load and code lookup.

```swift
public enum LatticeKit {
    public static let version: String        // "0.1.0"
    public static let canonVersion: String   // "v1"
    public static func entry(for code: String) -> LatticeEntry?
    public static func bundledCanon() -> LatticeCanon?   // loads Resources/LatticeCanonV1.json
}
```

#### `LatticeCanon` / `LatticeEntry`

The loaded classification canon and its rows (SPEC § 4, I-1).

```swift
public struct LatticeEntry: Sendable, Hashable, Codable {
    public let code: String
    public let sourceIdentity: String
    public let label: String
    public let classBase: Int
    public init(code: String, sourceIdentity: String, label: String, classBase: Int)
}

public struct LatticeCanon: Sendable, Codable {
    public let canonVersion: String
    public let entries: [LatticeEntry]
    public init(canonVersion: String, entries: [LatticeEntry])
    public func entry(for code: String) -> LatticeEntry?
    public func entry(forSourceIdentity identity: String) -> LatticeEntry?
}
```

#### `Code`

The MDCC code grammar (SPEC § 5, B-3).

```swift
public enum Code {
    public static let maxExtensionDigits: Int        // 8
    public static func isWellFormed(_ code: String) -> Bool
    public static func integerBase(of code: String) -> Int?
}
```

#### `MOOTx01Error`

The module-owned error (build-time fetch failure).

```swift
public enum MOOTx01Error: Error, Sendable, Equatable {
    case edgeFetchFailed(statusCode: Int)
}
```

### Tier 2 — editorial / assembly tooling (table of contents)

Present in the package but **not consumed by other packages** — the
`mdcc-build` machinery that builds the canon from CC0 Wikidata source
plus human-authored pins. Recorded for future builders; full signatures
in the cited files.

- **Assembler:** `Assembler`, `AssemblerInput`, `AssemblerOutput`,
  `AssemblerDiagnostic`, `BuildProvenance`, `SourceConcept`, `SourceEdge` —
  `Assembler.swift`.
- **Stable keys:** `StableKeyRegistry`, `StableKeyEntry`,
  `PersistedRegistry` — `StableKey.swift`.
- **Editorial pins:** `EditorialPins`, `ClassPin`, `ClassPinFile`,
  `ParentPin`, `ParentPinFile`, `PinnedParents`, `ClassResolver` —
  `EditorialPins.swift`.
- **Wikidata source:** `WikidataCC0Source`, `WikidataEdgeSource`,
  `EdgeSource` (protocol), `EdgeFetcher`, `FixtureEdgeSource` —
  `WikidataCC0Source.swift`, `EdgeFetcher.swift`.
- **Canon writing / channels:** `CanonWriter` (`canonFilename`,
  `codesFilename`), `Channels`, `FastCodesPayload` — `CanonWriter.swift`,
  `Channels.swift`.
- **Notation / structure:** `NotationSpine`, `ReservedRange`,
  `ReservedRanges`, `CollapseRule`, `MDCCClass`, `Kind` —
  `NotationSpine.swift`, `ReservedRanges.swift`, `CollapseRule.swift`.

## § 3 — Public functions

Tier-1 entry points (types in § 2):

```swift
LatticeKit.bundledCanon() -> LatticeCanon?
LatticeKit.entry(for: String) -> LatticeEntry?
LatticeCanon.entry(for: String) -> LatticeEntry?
LatticeCanon.entry(forSourceIdentity: String) -> LatticeEntry?
Code.isWellFormed(_: String) -> Bool
Code.integerBase(of: String) -> Int?
```

The Tier-2 tooling exposes `Assembler.assemble(_:)` and the `mdcc-build`
CLI entry point; see `Sources/mdcc-build/` and `Assembler.swift`.

## § 4 — Errors

```swift
public enum MOOTx01Error: Error, Sendable, Equatable {
    case edgeFetchFailed(statusCode: Int)   // Wikidata fetch during assembly
}
```
Behavioral meaning: SPEC § 6. The runtime lookup surface does not throw.

## § 5 — Conformance test entry points

**Swift:**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path packages/kits/LatticeKit
```

(Target: `LatticeKitTests` — canon load, code grammar, channels,
decimal-extension allocation, editorial review.)

**Rust:** pending.

## § 6 — Examples

```swift
import LatticeKit

guard let canon = LatticeKit.bundledCanon() else { /* resource missing */ return }
let entry = canon.entry(for: "004.42")          // LatticeEntry?
let ok = Code.isWellFormed("004.42")            // true
let base = Code.integerBase(of: "004.42")       // 4
```

---

*End of LatticeKit Interface.*

## Changelog

### 1.0.0 -- 2026-06-14
Established under VERSIONING.md: version number removed from the filename; front matter normalized; baselined at 1.0.0.
