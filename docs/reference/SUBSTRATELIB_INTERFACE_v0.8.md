---
status: draft
authors: Bob Pankratz (via Skippy)
date: 2026-05-29
version: v0.8
package: SubstrateLib
languages: [swift, rust]
relates_to:
  - SUBSTRATELIB_SPEC_v0.8.md  (the contract this interface implements)
  - SUBSTRATETYPES_INTERFACE_v0.8.md  (Layer 1 types consumed)
  - SUBSTRATEKERNEL_INTERFACE_v0.8.md  (Layer 2 primitives consumed)
  - SUBSTRATEML_INTERFACE_v0.8.md     (Layer 3 algorithms consumed)
purpose: |
  Public API surface of SubstrateLib in both legs. Three Swift files
  publish the nine substrate verbs (`Verbs.Substrate`), the row-state
  automaton (`RowStateAutomaton`), and the AuditGate write-gate
  (`AuditGate.admit`). The Rust mirror exposes the same shapes with
  Rust-idiomatic names. The companion SPEC carries the behavioral
  contracts (I-22, I-25, I-26, I-30, O-1 through O-4).
---

# SubstrateLib Interface

## § 1 — Package layout

**Swift:** `packages/libs/SubstrateLib/`

- `Sources/SubstrateLib/` — 3 files:
  - `Verbs.swift` — the nine substrate verbs + `Substrate` namespace
    + `SubstrateError`.
  - `RowStateAutomaton.swift` — transition table, `validate`,
    `BitmapFields`, `ForbiddenCombinations`, `TransitionKey`.
  - `AuditGate.swift` — `AuditGate.admit`, `FieldSlot`, `FieldWrite`,
    `Vocabulary`, `Column`, `AuditGateError`.
- `Tests/SubstrateLibTests/` — unit + conformance.
- `Tests/SubstrateLibConformanceTests/` — bilingual conformance gate.
- `Package.swift` — depends on `SubstrateTypes`, `SubstrateKernel`,
  `SubstrateML`.

**Rust:** `packages/libs/SubstrateLib/rust/`

- `lib.rs` — crate root.
- `glref-rust-verbs.rs` — verbs module.
- `glref-rust-row_state.rs` — automaton logic (BitmapFields and the
  value-type enums live in `substrate-types/rust/src/row_state.rs`).
- `glref-rust-audit_gate.rs` — AuditGate.admit, FieldSlot, FieldWrite,
  Vocabulary, Column.
- Plus six kit-cookbook reference files (`actuator.rs`,
  `cognition_bundle.rs`, `cognition_kit.rs`, `dreaming.rs`,
  `sqlite_tail.rs`, `working_set.rs`) — these are the Rust scalar
  oracle for cookbook §§ 4.2, 4.3, 11, 13, 14, 15 and stay in this
  crate by design until the kits they reference get their own Rust
  crates.
- `tests/` — conformance vectors.
- `Cargo.toml` — depends on `substrate-types`, `substrate-kernel`,
  `substrate-ml`.

Naming differs by port convention; behavior is bit-identical
(SPEC § 7).

## § 2 — Public types

### `Substrate`, `SubstrateError`

The verb namespace + verb-driver error surface. SPEC § 5.1.

**Swift:**

```swift
public enum SubstrateError: Error, Equatable {
    case rowNotFound(rowId: UUID)
    case illegalTransition(prior: RowState, verb: RowVerb)
    case forbiddenCombination(reason: String)
    case vocabularyViolation(slot: String, reason: String)
    case stateInconsistentWithVerb(verb: String)
    case contentIDCollision
}

public struct Substrate {
    public static func capture(
        rowId: UUID,
        nounType: NounType,
        initialFields: BitmapFields,
        latticeAnchor: LatticeAnchor?,
        hlc: HLC,
        actor: String,
        vocabulary: Vocabulary
    ) -> Result<AuditEvent, SubstrateError>

    public static func reanchor(
        rowId: UUID,
        prior: BitmapFields,
        newAnchor: LatticeAnchor,
        priorAnchor: LatticeAnchor?,
        hlc: HLC,
        actor: String,
        vocabulary: Vocabulary
    ) -> Result<AuditEvent, SubstrateError>

    public static func mutate(
        rowId: UUID,
        prior: BitmapFields,
        priorAnchor: LatticeAnchor?,
        writes: [FieldWrite],
        hlc: HLC,
        actor: String,
        vocabulary: Vocabulary
    ) -> Result<AuditEvent, SubstrateError>

    // withdraw, expunge, recall, propose, associate, learn —
    // analogous signatures, each taking prior bitmaps + writes + HLC
    // + actor + vocabulary.

    /// The named mutation operations the `mutate` verb dispatches on
    /// (member enum of the verb driver). Raw values are the wire tokens.
    public enum MutationKind: String {
        case confirm, reject, contest, supersede
        case automatedConfirm = "automated_confirm"
        case decay, expire
        case lineageAdvance = "lineage_advance"
        case actuatorConfirm = "actuator_confirm"
    }
}
```

**Rust:**

```rust
pub enum SubstrateError {
    RowNotFound(RowId),
    IllegalTransition { prior: RowState, verb: RowVerb },
    ForbiddenCombination(String),
    VocabularyViolation { slot: String, reason: String },
    StateInconsistentWithVerb(String),
    ContentIdCollision,
}

pub mod substrate {
    pub fn capture(/* … */) -> Result<AuditEvent, SubstrateError>;
    pub fn reanchor(/* … */) -> Result<AuditEvent, SubstrateError>;
    pub fn mutate(/* … */) -> Result<AuditEvent, SubstrateError>;
    // withdraw, expunge, recall, propose, associate, learn
}
```

### `RowStateAutomaton`, `BitmapFields`, `TransitionKey`, `ForbiddenCombinations`

Row-state automaton. SPEC § 5.2.

**Swift:**

```swift
public enum RowStateAutomaton {
    public static let transitions: [TransitionKey: RowState]
    public static func transition(from: RowState, on: RowVerb) -> RowState?
    public static func validate(
        from: RowState?,
        on: RowVerb,
        targetingFields: BitmapFields
    ) throws -> RowState
}

public struct TransitionKey: Hashable, Sendable {
    public let from: RowState
    public let on: RowVerb
}

public struct BitmapFields: Sendable {
    public let adjective: UInt64
    public let operational: UInt64
    public let provenance: UInt64
}

public enum ForbiddenCombinations {
    public static func check(state: RowState, fields: BitmapFields) throws
}
```

**Rust:**

```rust
pub mod row_state {
    pub static TRANSITIONS: LazyLock<HashMap<TransitionKey, RowState>>;
    pub fn transition(from: RowState, on: RowVerb) -> Option<RowState>;
    pub fn validate(
        from: Option<RowState>,
        on: RowVerb,
        fields: BitmapFields,
    ) -> Result<RowState, RowStateError>;

    pub struct TransitionKey { pub from: RowState, pub on: RowVerb }
    pub struct BitmapFields { pub adjective: u64, pub operational: u64, pub provenance: u64 }

    pub fn check_forbidden_combinations(state: RowState, fields: BitmapFields) -> Result<(), RowStateError>;
}
```

### `AuditGate`, `FieldSlot`, `FieldWrite`, `Vocabulary`, `Column`, `AuditGateError`

Write gate. SPEC § 5.3.

**Swift:**

```swift
public enum AuditGateError: Error, Equatable {
    case vocabularyViolation(slot: String, reason: String)
    case basisViolation(RowStateError)
    case stateInconsistentWithVerb(verb: String)
}

public enum Column: String, Sendable, Hashable {
    case adjective, operational, provenance
}

public struct FieldSlot: Hashable, Sendable {
    public let column: Column
    public let shift: Int
    public let width: Int
    public let label: String
    public let legalValues: Set<Int64>?         // nil = any value within width
    public init(column: Column, shift: Int, width: Int, label: String, legalValues: Set<Int64>? = nil)
}

public struct FieldWrite: Sendable {
    public let slot: FieldSlot
    public let value: Int64
}

public struct Vocabulary: Sendable {
    public let slots: [FieldSlot]
    /// `freeze()` validates the slot set (no overlapping ranges,
    /// no width mismatches, no value-set inconsistencies) at
    /// construction time. A frozen vocabulary cannot produce a
    /// corrupt write later.
    public static func freeze(basis: [FieldSlot], extensions: [FieldSlot]) -> Result<Vocabulary, VocabularyError>
    public func slot(for column: Column, shift: Int) -> FieldSlot?
}

public enum AuditGate {
    /// Single legal substrate write. Validates, merges, hashes,
    /// emits one canonical AuditEvent.
    public static func admit(
        estateUuid: UUID,
        rowId: UUID,
        nounType: NounType,
        verb: RowVerb,
        prior: BitmapFields?,                   // nil for capture
        priorLatticeAnchor: LatticeAnchor?,
        writes: [FieldWrite],
        afterLatticeAnchor: LatticeAnchor?,
        vocabulary: Vocabulary,
        hlc: HLC,
        actor: String
    ) -> Result<AuditEvent, AuditGateError>
}

/// The structured violation surface the gate's internal checks raise
/// (distinct from `AuditGateError`, which is the public `admit` return).
/// SPEC § 5.3.
public enum GateViolation: Error, Sendable {
    case undeclaredField(label: String)
    case illegalValue(label: String, value: Int64)
    case basisViolation(Error)
    case stateInconsistentWithVerb(verb: String)
}

/// Vocabulary freeze/validation namespace. `freeze(union:)` validates a
/// proposed slot set (no overlapping ranges, width/value consistency)
/// and returns a frozen `Vocabulary` or a `VocabularyError`. SPEC § 5.3.
public enum VocabularyValidator {
    public static func freeze(union proposed: Set<FieldSlot>) -> Result<Vocabulary, VocabularyError>
}
```

**Rust:**

```rust
pub mod audit_gate {
    pub enum AuditGateError {
        VocabularyViolation { slot: String, reason: String },
        BasisViolation(RowStateError),
        StateInconsistentWithVerb(String),
    }

    pub enum Column { Adjective, Operational, Provenance }

    pub struct FieldSlot { pub column: Column, pub shift: u32, pub width: u32, pub label: &'static str, pub legal_values: Option<HashSet<i64>> }
    impl FieldSlot {
        pub fn new(column: Column, shift: u32, width: u32, label: &'static str) -> Self;
        pub fn with_values(column: Column, shift: u32, width: u32, label: &'static str, legal: &[i64]) -> Self;
    }

    pub struct FieldWrite { pub slot: FieldSlot, pub value: i64 }

    pub struct Vocabulary { pub slots: Vec<FieldSlot> }
    impl Vocabulary {
        pub fn freeze(basis: Vec<FieldSlot>, extensions: Vec<FieldSlot>) -> Result<Self, VocabularyError>;
        pub fn slot(&self, column: Column, shift: u32) -> Option<&FieldSlot>;
    }

    pub fn admit(
        estate_uuid: u128,
        row_id: RowId,
        noun_type: NounType,
        verb: RowVerb,
        prior: Option<BitmapFields>,
        prior_anchor: Option<LatticeAnchor>,
        writes: &[FieldWrite],
        after_anchor: LatticeAnchor,
        vocabulary: &Vocabulary,
        hlc: HLC,
        actor: &str,
    ) -> Result<AuditEvent, AuditGateError>;
}
```

## § 3 — Public functions

All operations on this package are members of the three top-level
namespaces (`Substrate`, `RowStateAutomaton`, `AuditGate`) or their
helper types. No free top-level functions.

## § 4 — Errors

| Error | Raised by | Cause |
|---|---|---|
| `AuditGateError.vocabularyViolation(slot:reason:)` | `AuditGate.admit` | FieldWrite's slot undeclared, value out-of-range, or value exceeds width |
| `AuditGateError.basisViolation(RowStateError)` | `AuditGate.admit` | RowStateAutomaton refused transition or forbidden-combination check failed |
| `AuditGateError.stateInconsistentWithVerb(verb:)` | `AuditGate.admit` | verb arg and written state mismatch |
| `RowStateError.illegalTransition(RowState, RowVerb)` | `RowStateAutomaton.validate` | (state, verb) not in transition table |
| `RowStateError.forbiddenCombination(state:, fields:)` | `RowStateAutomaton.validate` / `ForbiddenCombinations.check` | merged bitmap violates I-22 |
| `SubstrateError.*` | `Substrate.<verb>` | verb-driver surface; wraps gate-level errors with verb context |

## § 5 — Conformance test entry points

- **Swift:** `Tests/SubstrateLibTests/`
  - `VerbsTests.swift`
  - `RowStateAutomatonTests.swift`
  - `AuditGateTests.swift`
  - `VocabularyTests.swift`
- **Swift conformance gate:** `Tests/SubstrateLibConformanceTests/`
  - `AuditGateConformanceTests.swift`
  - `RowStateAutomatonConformanceTests.swift`
  - `VerbConformanceTests.swift`
- **Rust:** per-module `#[cfg(test)] mod tests` plus
  `tests/wire_format_conformance.rs` and
  `tests/bitmap_field_constants_conformance.rs`.

## § 6 — Examples

```swift
import SubstrateTypes
import SubstrateLib

// Define a vocabulary (subset of LocusKit's adjective basis).
let stateSlot = FieldSlot(
    column: .adjective, shift: 0, width: 6, label: "state",
    legalValues: [0, 1, 2, 3, 16, 17, 18, 19, 32, 33]
)
let flagsSlot = FieldSlot(
    column: .adjective, shift: 24, width: 3, label: "flags"
)

let vocab = try Vocabulary.freeze(basis: [stateSlot, flagsSlot], extensions: []).get()

// Capture a brand-new row.
let captureResult = AuditGate.admit(
    estateUuid: estateUUID,
    rowId: UUID(),
    nounType: .drawer,
    verb: .capture,
    prior: nil,
    priorLatticeAnchor: nil,
    writes: [FieldWrite(slot: stateSlot, value: 0)],   // active
    afterLatticeAnchor: LatticeAnchor.unknown,
    vocabulary: vocab,
    hlc: hlcGen.send(now: nowMillis),
    actor: "alice"
)
let captureEvent = try captureResult.get()
// captureEvent.verb == .capture
// captureEvent.afterBitmaps.adjective & 0x3F == 0

// Mutate the row's flags (set bit 26 = dreaming_recalc_required).
let mutateResult = AuditGate.admit(
    estateUuid: estateUUID,
    rowId: captureEvent.rowId,
    nounType: .drawer,
    verb: .mutate,
    prior: captureEvent.afterBitmaps,
    priorLatticeAnchor: captureEvent.afterLatticeAnchor,
    writes: [FieldWrite(slot: flagsSlot, value: 0b100)],  // bit 26
    afterLatticeAnchor: captureEvent.afterLatticeAnchor,
    vocabulary: vocab,
    hlc: hlcGen.send(now: nowMillis + 100),
    actor: "alice"
)
let mutateEvent = try mutateResult.get()
// mutateEvent.afterBitmaps.adjective & (1 << 26) != 0
```

```rust
use substrate_types::*;
use substrate_lib::audit_gate::{self, FieldSlot, FieldWrite, Column, Vocabulary};

let state_slot = FieldSlot::with_values(Column::Adjective, 0, 6, "state",
    &[0, 1, 2, 3, 16, 17, 18, 19, 32, 33]);
let flags_slot = FieldSlot::new(Column::Adjective, 24, 3, "flags");
let vocab = Vocabulary::freeze(vec![state_slot, flags_slot], vec![]).unwrap();

let capture_event = audit_gate::admit(
    estate_uuid, row_id, NounType::Drawer, RowVerb::Capture,
    None, None,
    &[FieldWrite { slot: state_slot, value: 0 }],
    LatticeAnchor::unknown(),
    &vocab,
    hlc_gen.send(now_millis),
    "alice",
)?;
```
