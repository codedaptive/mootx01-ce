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
  Public API surface of SubstrateLib in both ports. Three Swift files
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

## Swift/Rust Concordance

Read-anchored from source (Swift `Sources/SubstrateLib/**`, Rust
`rust/src/**`). One row per public concept. Every Swift and Rust
symbol below is a real declaration cited by file:line. Behavior
parity is proven by the per-port unit tests (same scenarios both
sides) plus the two cross-port wire/constant conformance suites.

Shape-difference convention used in this table: SubstrateLib is a
pure, stateless kernel-layer lib — no async, no Apple frameworks —
so there are **no platform-exempt types here**. The recurring
sanctioned shape difference is *namespacing*: Swift groups stateless
operations under a caseless `enum` namespace (`AuditGate`,
`RowStateAutomaton`, `ForbiddenCombinations`, `VocabularyValidator`),
whereas the Rust port expresses the same operations as free functions
in the corresponding module (`audit_gate::admit`,
`row_state::transition`/`validate`, `row_state::check_forbidden_combinations`,
`audit_gate::freeze`). The *concept* is present in both ports; only
the host construct differs. Likewise, types Swift nests inside a
parent (`FieldSlot.Column`, `Substrate.MutationKind`) are flat
top-level types in Rust (`Column`, `MutationKind`).

Shared value-type enums (`RowState`, `RowVerb`, `RowStateError`,
`NounType`, `LatticeAnchor`, `HLC`, `AuditEvent`, `Fingerprint256`)
live in the Layer-1 `SubstrateTypes` / `substrate-types` package and
are documented in `SUBSTRATETYPES_INTERFACE_v0.8.md`; SubstrateLib
consumes them by import/`pub use`, so they are not re-rowed here.

| Concept | Swift symbol | Rust symbol | Visibility | Shape rule | Test/vector binding | Status |
|---|---|---|---|---|---|---|
| Row identifier alias | `RowId` (typealias = UUID) — `Sources/SubstrateLib/Verbs.swift:49` | `RowId` (newtype `RowId(u128)`, re-exported from `substrate-types`; used at `rust/src/verbs.rs:42`, `rust/src/audit_gate.rs:194`) | public both | Swift `typealias UUID` / Rust `RowId(u128)` newtype — wire-compatible (128-bit), idiom diff | `WireFormatConformanceTests.swift::testAuditEntryRowIDIsUUIDString` ↔ `tests/wire_format_conformance.rs::audit_entry_row_id_is_uppercase_uuid_string` | Confirmed |
| Verb-driver error surface | `SubstrateError` (enum) — `Sources/SubstrateLib/Verbs.swift:56` | `SubstrateError` (enum) — `rust/src/verbs.rs:38` | public both | identical (case set differs only by Swift extras `proposalRequired`/`nonProposalCannotUseProposalVerb` carried by the Swift reference driver; shared cases align) | `VerbsTests.swift::testMutateRejectsInvalidTransition` ↔ `rust/src/verbs.rs::tests` (mutate transition rejection) | Confirmed |
| In-memory verb driver | `Substrate` (struct) — `Sources/SubstrateLib/Verbs.swift:77` | `Substrate` (struct) — `rust/src/verbs.rs:171` | public both | identical: stateful reference struct; Swift `mutating func` ↔ Rust `&mut self` methods (capture/reanchor/mutate/withdraw/expunge/recall/propose/associate/learn) | `VerbsTests.swift::testCaptureCreatesActiveRow` ↔ `rust/src/verbs.rs::tests` (capture creates active row) | Confirmed |
| Named mutation operations | `Substrate.MutationKind` (nested enum, raw `String`) — `Sources/SubstrateLib/Verbs.swift:198` | `MutationKind` (flat enum, `token()` wire string) — `rust/src/verbs.rs:79` | public both | Swift nested `Substrate.MutationKind` / Rust flat `MutationKind`; Swift `rawValue` ↔ Rust `token()` for the wire token | `VerbsTests.swift::testMutateConfirmPendingToAccepted` ↔ `rust/src/verbs.rs::tests` (mutate confirm) | Confirmed |
| Row-state automaton namespace | `RowStateAutomaton` (caseless enum: `transitions`, `transition(from:on:)`, `validate`, `canTransition`) — `Sources/SubstrateLib/RowStateAutomaton.swift:50` | `row_state` module free fns: `transition`, `validate` — `rust/src/row_state.rs:114,132` | public both | Swift enum-namespace / Rust module free fns (sanctioned namespacing diff — no async runtime, pure stateless ops) | `RowStateAutomatonTests.swift::testPendingToActiveViaObserve` ↔ `rust/src/row_state.rs::tests` (transition table) | Confirmed |
| Transition-table key | `TransitionKey` (struct) — `Sources/SubstrateLib/RowStateAutomaton.swift:201` | `TransitionKey` (struct) — `rust/src/row_state.rs:36` | public both | identical `(from, on/verb)` composite key | `RowStateAutomatonTests.swift::testValidateRejectsIllegalTransitions` ↔ `rust/src/row_state.rs::tests` (illegal transition) | Confirmed |
| Three-column bitmap snapshot | `BitmapFields` (struct: adjective/operational/provenance `UInt64`) — `Sources/SubstrateLib/RowStateAutomaton.swift:214` | `BitmapFields` (struct: adjective/operational/provenance `u64`) — `rust/src/row_state.rs:122` | public both | identical | `BitmapFieldConstantsConformanceTests.swift` ↔ `tests/bitmap_field_constants_conformance.rs` | Confirmed |
| Forbidden-combination check (I-22) | `ForbiddenCombinations` (caseless enum: `check(state:fields:)`) — `Sources/SubstrateLib/RowStateAutomaton.swift:234` | `check_forbidden_combinations` (free fn) — `rust/src/row_state.rs:156` | public both | Swift enum-namespace / Rust free fn (sanctioned namespacing diff) | `RowStateAutomatonTests.swift::testI22SecretCannotBeExportable` ↔ `rust/src/row_state.rs::tests` (I-22 secret/public) | Confirmed |
| Bitmap column tag | `FieldSlot.Column` (nested enum, raw `UInt8`) — `Sources/SubstrateLib/AuditGate.swift:52` | `Column` (flat enum) — `rust/src/audit_gate.rs:49` | public both | Swift nested `FieldSlot.Column` / Rust flat `Column` | `AuditGateTests.swift::testNoClobber` ↔ `rust/src/audit_gate.rs::tests` (read-modify-write preserves bits) | Confirmed |
| Declared field-slot | `FieldSlot` (struct) — `Sources/SubstrateLib/AuditGate.swift:51` | `FieldSlot` (struct) — `rust/src/audit_gate.rs:52` | public both | identical layout (column/shift/width/label/legalValues); Swift `Int` shift/width ↔ Rust `u32`, idiom diff | `AuditGateTests.swift::testOverWidthValueRejectedNotTruncated` ↔ `rust/src/audit_gate.rs::tests` (over-width value rejected) | Confirmed |
| Admitted vocabulary | `Vocabulary` (struct, `static basis`, `slot(for:)`) — `Sources/SubstrateLib/AuditGate.swift:134` | `Vocabulary` (struct, `basis()` free fn, `slot_for`) — `rust/src/audit_gate.rs:120` | public both | identical concept; Swift `static let basis` ↔ Rust `basis()` fn; union constructed only via freeze both sides | `AuditGateTests.swift::testFreezeRejectsBasisCollision` ↔ `rust/src/audit_gate.rs::tests` (basis collision) | Confirmed |
| Vocabulary-freeze errors | `VocabularyError` (enum) — `Sources/SubstrateLib/AuditGate.swift:205` | `VocabularyError` (enum) — `rust/src/audit_gate.rs:132` | public both | identical case set (overlap / basisCollision / malformedWidth / valueExceedsWidth) | `AuditGateTests.swift::testFreezeRejectsOverlap` / `testFreezeRejectsMalformedWidth` / `testFreezeRejectsValueExceedingWidth` ↔ `rust/src/audit_gate.rs::tests` (freeze rejections) | Confirmed |
| Vocabulary freeze/validate | `VocabularyValidator` (caseless enum: `freeze(union:)`) — `Sources/SubstrateLib/AuditGate.swift:221` | `freeze` (free fn) — `rust/src/audit_gate.rs:141` | public both | Swift enum-namespace / Rust free fn (sanctioned namespacing diff) | `AuditGateTests.swift::testFreezeRejectsOverlap` ↔ `tests/audit_gate.rs::tests` `freeze` rejections (`rust/src/audit_gate.rs::tests`) | Confirmed |
| Single field write request | `FieldWrite` (struct: slot + value) — `Sources/SubstrateLib/AuditGate.swift:257` | `FieldWrite` (struct: slot + value) — `rust/src/audit_gate.rs:175` | public both | identical; Swift `Int64` value ↔ Rust `i64` | `AuditGateTests.swift::testUndeclaredFieldRejected` ↔ `rust/src/audit_gate.rs::tests` (undeclared field) | Confirmed |
| Gate violation surface | `GateViolation` (enum) — `Sources/SubstrateLib/AuditGate.swift:268` | `GateViolation` (enum) — `rust/src/audit_gate.rs:178` | public both | identical case set (undeclaredField / illegalValue / basisViolation / stateInconsistentWithVerb); **this is the actual `admit` error return on both ports** | `AuditGateTests.swift::testIllegalValueRejected` ↔ `rust/src/audit_gate.rs::tests` (illegal value) | Confirmed |
| The write gate | `AuditGate` (caseless enum: `admit(...) -> Result<AuditEvent, GateViolation>`) — `Sources/SubstrateLib/AuditGate.swift:284` | `audit_gate::admit(...) -> Result<AuditEvent, GateViolation>` (free fn) — `rust/src/audit_gate.rs:191` | public both | Swift enum-namespace / Rust free fn (sanctioned namespacing diff); deterministic content-ID + canonical snapshot event both sides | `AuditGateTests.swift::testContentIDDeterministicAndStable` ↔ `rust/src/audit_gate.rs::tests` (content-id determinism) + `WireFormatConformanceTests.swift` ↔ `tests/wire_format_conformance.rs` (canonical event wire) | Confirmed |

### Correction note (read-anchored)

The prose in § 2 above predates this concordance pass and is wrong on
two points the audit-anchored table above corrects:

1. **`AuditGateError` does not exist.** `AuditGate.admit` returns
   `Result<AuditEvent, GateViolation>` on **both** ports
   (`Sources/SubstrateLib/AuditGate.swift:302`,
   `rust/src/audit_gate.rs:203`). The `GateViolation` row is the
   authoritative gate-error surface; the § 2 `AuditGateError` block,
   the § 4 `AuditGateError.*` rows, and the `BasisViolation(RowStateError)`
   variant are stale and not present in source.
2. **The Rust port is stateful for verbs and free-function for gates.**
   § 2 sketches Rust `substrate` as a function-only module and shows a
   `RowStateAutomaton`/`audit_gate` type-namespace shape; in source
   `Substrate` is a real `struct` with `&mut self` verb methods, and
   the gate/automaton/freeze operations are module free functions
   (no Rust namespace type). The Shape-rule column records these as
   the sanctioned namespacing difference, not drift.

These are documentation-only corrections to a draft interface doc; no
code parity gap is implied (the table rows are all `Confirmed`).

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
