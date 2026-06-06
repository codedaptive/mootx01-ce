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
  publish the stateful substrate verb driver (`Substrate`), the
  row-state automaton (`RowStateAutomaton`), and the AuditGate
  write-gate (`AuditGate.admit`). The Rust mirror exposes the same shapes with
  Rust-idiomatic names. The companion SPEC carries the behavioral
  contracts (I-22, I-25, I-26, I-30, O-1 through O-4).
---

# SubstrateLib Interface

## § 1 — Package layout

**Swift:** `packages/libs/SubstrateLib/`

- `Sources/SubstrateLib/` — 4 files:
  - `Verbs.swift` — the stateful `Substrate` verb driver +
    `SubstrateError` + nested `MutationKind`. Verb methods carry
    `ts: Double = 0.0` for telemetry; default `0.0` preserves
    backward compatibility.
  - `RowStateAutomaton.swift` — transition table, `validate`,
    `BitmapFields`, `ForbiddenCombinations`, `TransitionKey`.
  - `AuditGate.swift` — `AuditGate.admit`, `FieldSlot` (+ nested
    `Column`), `FieldWrite`, `Vocabulary`, `VocabularyValidator`,
    `VocabularyError`, `GateViolation`.
  - `SubstrateLibTelemetry.swift` — `SubstrateLibMetric` constants
    and `@inline(__always)` emit helpers. Added in P2 self-report
    mission (2026-06-06).
- `Tests/SubstrateLibTests/` — unit + conformance + telemetry tests
  (`SubstrateLibTelemetryTests.swift`). 148 tests total.
- `Tests/SubstrateLibConformanceTests/` — bilingual conformance gate.
- `Package.swift` — depends on `SubstrateTypes`, `SubstrateKernel`,
  `SubstrateML`, `IntellectusLib` (telemetry floor; added per
  `DECISION_LIFT_PACKAGE_SWIFT_RULE_2026-05-28`).

**Rust:** `packages/libs/SubstrateLib/rust/`

- `src/lib.rs` — crate root.
- `src/verbs.rs` — verbs module (stateful `Substrate` driver). All
  verb methods carry `ts: f64`; callers pass `0.0` for non-telemetry.
- `src/row_state.rs` — automaton logic (`transition`/`validate`,
  `TransitionKey`, `BitmapFields`, `check_forbidden_combinations`;
  the value-type enums live in `substrate-types/rust/src/row_state.rs`).
- `src/audit_gate.rs` — `admit`, `FieldSlot`, `FieldWrite`,
  `Vocabulary`, `Column`, `GateViolation`, `freeze`.
- `src/substrate_lib_telemetry.rs` — `metric` module (10 `&str`
  metric name constants) and `#[inline(always)]` emit helpers.
  Added in P2 self-report mission (2026-06-06).
- `tests/` — conformance vectors + telemetry integration tests
  (`substrate_lib_telemetry_tests.rs`). 61 tests total.
- `Cargo.toml` — depends on `substrate-types`, `substrate-kernel`,
  `substrate-ml`, `intellectus-lib` (added per
  `DECISION_LIFT_PACKAGE_SWIFT_RULE_2026-05-28`).

Naming differs by port convention; behavior is bit-identical
(SPEC § 7).

## § 2 — Public types

### `Substrate`, `SubstrateError`

The verb namespace + verb-driver error surface. SPEC § 5.1.

**Swift:**

`Substrate` is a STATEFUL reference verb-driver struct (an in-memory
estate: rows, audit events, the F/O/T matrices, and the HLC). Verb
methods are `mutating` and return `Result<_, SubstrateError>`; they
take raw `Int64` bitmaps, not `BitmapFields`.

```swift
public enum SubstrateError: Error, Equatable {
    case invalidStateTransition(from: RowState, to: RowState, verb: String)
    case missingLatticeAnchor
    case invalidNounType
    case rowNotFound(UUID)
    case forbiddenStateCombination(String)
    case alreadyTombstoned(UUID)
    case proposalRequired
    case nonProposalCannotUseProposalVerb
}

public struct Substrate {
    public let estateUuid: UUID
    public var rows: [UUID: Row]
    public var auditEvents: [AuditEvent]   // appended; treat as G-Set
    public var matrixF: MatrixF
    public var matrixO: MatrixO
    public var matrixT: MatrixT
    public var hlc: HLC
    public var rowCountActive: Int64
    public init(estateUuid: UUID, hlc: HLC)

    @discardableResult
    public mutating func capture(
        nounType: NounType,
        adjectiveBitmap: Int64, operationalBitmap: Int64, provenanceBitmap: Int64,
        latticeAnchor: LatticeAnchor,
        fingerprint: Fingerprint256,
        lineageId: UUID? = nil, content: Data? = nil,
        actor: String = "capture"
    ) -> Result<UUID, SubstrateError>

    @discardableResult
    public mutating func reanchor(
        rowId: UUID, newLatticeAnchor: LatticeAnchor, actor: String = "reanchor"
    ) -> Result<(), SubstrateError>

    public mutating func mutate(/* rowId, MutationKind, writes, actor … */)
        -> Result<(), SubstrateError>

    // withdraw, expunge, propose, associate, learn — analogous mutating
    // methods; recall is a non-mutating query:
    public func recall(matching predicate: (Row) -> Bool, /* … */) -> [Row]

    /// The named mutation operations the `mutate` verb dispatches on
    /// (nested enum). Raw values are the wire tokens.
    public enum MutationKind: String {
        case confirm, reject, contest, supersede
        case automatedConfirm = "automated_confirm"
        case decay, expire
        case lineageAdvance = "lineage_advance"
        case actuatorConfirm = "actuator_confirm"
    }
}
```

**Rust:** `Substrate` is likewise a stateful `struct` with `&mut self`
verb methods (capture/reanchor/mutate/withdraw/expunge/recall/propose/
associate/learn) and a flat `MutationKind` enum (`token()` for the wire
string). `SubstrateError` carries the same shared cases (the Swift
reference driver adds `proposalRequired` /
`nonProposalCannotUseProposalVerb`).

```rust
pub enum SubstrateError { /* shared cases incl. RowNotFound, MissingLatticeAnchor, … */ }
pub struct Substrate { /* estate_uuid, rows, audit_events, matrices, hlc, … */ }
impl Substrate {
    pub fn new(estate_uuid: u128, hlc: HLC) -> Self;
    pub fn capture(&mut self, /* … */) -> Result<RowId, SubstrateError>;
    pub fn reanchor(&mut self, /* … */) -> Result<(), SubstrateError>;
    pub fn mutate(&mut self, /* … */) -> Result<(), SubstrateError>;
    // withdraw / expunge / propose / associate / learn ; recall(&self, …)
}
pub enum MutationKind { Confirm, Reject, Contest, Supersede, AutomatedConfirm, Decay, Expire, LineageAdvance, ActuatorConfirm }
```

### `RowStateAutomaton`, `BitmapFields`, `TransitionKey`, `ForbiddenCombinations`

Row-state automaton. SPEC § 5.2.

**Swift:**

```swift
public enum RowStateAutomaton {
    public static let transitions: [TransitionKey: RowState]
    public static func canTransition(from: RowState, on: RowVerb) -> Bool
    public static func transition(from: RowState, on: RowVerb) -> RowState?
    public static func validate(
        from state: RowState,
        on verb: RowVerb,
        targetingFields fields: BitmapFields
    ) throws -> RowState
}

public struct TransitionKey: Hashable, Sendable {
    public let from: RowState
    public let verb: RowVerb
    public init(_ from: RowState, _ verb: RowVerb)
}

public struct BitmapFields: Sendable {
    public let adjective: UInt64
    public let operational: UInt64
    public let provenance: UInt64
    public init(adjective: UInt64, operational: UInt64, provenance: UInt64)
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

### `AuditGate`, `FieldSlot`, `FieldWrite`, `Vocabulary`, `VocabularyValidator`, `Column`, `GateViolation`

Write gate. SPEC § 5.3.

**Swift:**

There is no `AuditGateError` type. `AuditGate.admit` returns
`Result<AuditEvent, GateViolation>` on both ports. `Column` is nested
inside `FieldSlot`. A frozen `Vocabulary` is produced only by
`VocabularyValidator.freeze(union:)`.

```swift
public struct FieldSlot: Hashable, Sendable {
    public enum Column: UInt8, Sendable, Hashable {
        case adjective, operational, provenance
    }
    public let column: Column
    public let shift: Int
    public let width: Int
    public let label: String
    public let legalValues: Set<Int64>          // empty = any value within width
    public init(column: Column, shift: Int, width: Int, label: String,
                legalValues: Set<Int64> = [])
    public var capacity: Int64 { get }          // 1 << width
    public var bitMask: UInt64 { get }
    public func admits(value: Int64) -> Bool
}

public struct FieldWrite: Sendable {
    public let slot: FieldSlot
    public let value: Int64
    public init(slot: FieldSlot, value: Int64)
}

public struct Vocabulary: Sendable {
    public static let basis: [FieldSlot]        // substrate-owned slots
    public let union: Set<FieldSlot>            // frozen consumer slots
    // No public init — construct only via VocabularyValidator.freeze.
    public func slot(for target: FieldSlot) -> FieldSlot?
}

public enum VocabularyError: Error, Sendable, Equatable {
    case overlap(String, String)
    case basisCollision(String)
    case malformedWidth(String)
    case valueExceedsWidth(String, Int64)
}

/// Validates a proposed consumer union and freezes it into a
/// `Vocabulary`, or rejects it. Run once at instantiation.
public enum VocabularyValidator {
    public static func freeze(union proposed: Set<FieldSlot>) -> Result<Vocabulary, VocabularyError>
}

/// The gate's violation surface (the `admit` error return on both ports).
public enum GateViolation: Error, Sendable {
    case undeclaredField(label: String)
    case illegalValue(label: String, value: Int64)
    case basisViolation(Error)                  // wraps RowStateAutomaton error
    case stateInconsistentWithVerb(verb: String)
}

public enum AuditGate {
    /// Single legal substrate write. Validates vocabulary + value,
    /// merges into `prior`, validates the basis, assigns a deterministic
    /// content-ID, emits one canonical AuditEvent.
    public static func admit(
        estateUuid: UUID,
        rowId: UUID,
        nounType: NounType,
        verb: RowVerb,
        prior: BitmapFields?,                   // nil for capture
        priorLatticeAnchor: LatticeAnchor?,
        writes: [FieldWrite],
        afterLatticeAnchor: LatticeAnchor,      // non-optional
        vocabulary: Vocabulary,
        hlc: HLC,
        actor: String
    ) -> Result<AuditEvent, GateViolation>
}
```

**Rust** (`audit_gate` module; `Column` flat, `freeze`/`admit` free fns):

```rust
pub mod audit_gate {
    pub enum Column { Adjective, Operational, Provenance }

    pub struct FieldSlot { pub column: Column, pub shift: u32, pub width: u32,
                           pub label: &'static str, pub legal_values: HashSet<i64> }

    pub struct FieldWrite { pub slot: FieldSlot, pub value: i64 }

    pub struct Vocabulary { /* basis() + frozen union */ }

    pub enum VocabularyError { Overlap(String, String), BasisCollision(String),
                               MalformedWidth(String), ValueExceedsWidth(String, i64) }
    pub fn freeze(proposed: HashSet<FieldSlot>) -> Result<Vocabulary, VocabularyError>;

    pub enum GateViolation { UndeclaredField { label: String },
                             IllegalValue { label: String, value: i64 },
                             BasisViolation(/* row-state error */),
                             StateInconsistentWithVerb { verb: String } }

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
    ) -> Result<AuditEvent, GateViolation>;
}
```

### `SubstrateLibMetric` / `metric` — telemetry name constants + emit helpers

Self-report telemetry. SPEC § 8.

**Swift:** `Sources/SubstrateLib/SubstrateLibTelemetry.swift`

```swift
/// Metric name constants for the `substratelib.*` namespace.
public enum SubstrateLibMetric {
    public static let auditGateAdmitCount    = "substratelib.audit_gate.admit_count"
    public static let auditGateRejectCount   = "substratelib.audit_gate.reject_count"
    public static let verbCaptureCount       = "substratelib.verb.capture_count"
    public static let verbMutateCount        = "substratelib.verb.mutate_count"
    public static let verbWithdrawCount      = "substratelib.verb.withdraw_count"
    public static let verbExpungeCount       = "substratelib.verb.expunge_count"
    public static let verbRecallCount        = "substratelib.verb.recall_count"
    public static let verbReanchorCount      = "substratelib.verb.reanchor_count"
    public static let writeGateAdmittedCount = "substratelib.write_gate.admitted_count"
    public static let writeGateRejectedCount = "substratelib.write_gate.rejected_count"
}
// @inline(__always) package-internal emit helpers (one per metric above).
// All take a `ts: Double` caller-supplied epoch-seconds parameter.
// SubstrateLib never reads a clock internally.
```

**Rust:** `rust/src/substrate_lib_telemetry.rs`

```rust
/// Metric name constants for the `substratelib.*` namespace.
pub mod metric {
    pub const AUDIT_GATE_ADMIT_COUNT: &str    = "substratelib.audit_gate.admit_count";
    pub const AUDIT_GATE_REJECT_COUNT: &str   = "substratelib.audit_gate.reject_count";
    pub const VERB_CAPTURE_COUNT: &str        = "substratelib.verb.capture_count";
    pub const VERB_MUTATE_COUNT: &str         = "substratelib.verb.mutate_count";
    pub const VERB_WITHDRAW_COUNT: &str       = "substratelib.verb.withdraw_count";
    pub const VERB_EXPUNGE_COUNT: &str        = "substratelib.verb.expunge_count";
    pub const VERB_RECALL_COUNT: &str         = "substratelib.verb.recall_count";
    pub const VERB_REANCHOR_COUNT: &str       = "substratelib.verb.reanchor_count";
    pub const WRITE_GATE_ADMITTED_COUNT: &str = "substratelib.write_gate.admitted_count";
    pub const WRITE_GATE_REJECTED_COUNT: &str = "substratelib.write_gate.rejected_count";
}
// #[inline(always)] pub emit helpers (one per metric above).
// All take ts: f64 caller-supplied epoch seconds.
```

Off-path cost when monitoring disabled: one `Atomic<Bool>.load(.acquiring)` /
`AtomicBool::load(Acquire)` + branch. No `StatSample` constructed, no lock,
no allocation.

## § 3 — Public functions

All operations on this package are members of the four top-level
namespaces (`Substrate`, `RowStateAutomaton`, `AuditGate`,
`SubstrateLibMetric`) or their helper types. No free top-level
functions (Swift); the Rust port exposes verb emit helpers as free
functions in `substrate_lib_telemetry`.

## § 4 — Errors

| Error | Raised by | Cause |
|---|---|---|
| `GateViolation.undeclaredField(label:)` | `AuditGate.admit` | FieldWrite's slot is not declared in basis ∪ union |
| `GateViolation.illegalValue(label:value:)` | `AuditGate.admit` | value out of the field's legal set or exceeds its width |
| `GateViolation.basisViolation(Error)` | `AuditGate.admit` | RowStateAutomaton refused the transition or the I-22 combination check failed (wraps the underlying `RowStateError`) |
| `GateViolation.stateInconsistentWithVerb(verb:)` | `AuditGate.admit` | verb arg and written state mismatch (or capture used a non-capture verb / illegal initial state) |
| `VocabularyError.*` (`overlap`/`basisCollision`/`malformedWidth`/`valueExceedsWidth`) | `VocabularyValidator.freeze` | proposed slot union is overlapping, basis-colliding, width-malformed, or has an out-of-width legal value |
| `RowStateError.illegalTransition(RowState, RowVerb)` | `RowStateAutomaton.validate` | (state, verb) not in transition table |
| `RowStateError.violatesInvariant(String)` | `ForbiddenCombinations.check` (via `RowStateAutomaton.validate`) | merged bitmap violates I-22 |
| `SubstrateError.*` | `Substrate.<verb>` | verb-driver surface (e.g. `missingLatticeAnchor`, `rowNotFound`, `alreadyTombstoned`, `invalidStateTransition`) |

## § 5 — Conformance test entry points

- **Swift:** `Tests/SubstrateLibTests/`
  - `VerbsTests.swift`
  - `RowStateAutomatonTests.swift`
  - `AuditGateTests.swift`
  - `VocabularyTests.swift`
  - `SubstrateLibTelemetryTests.swift` — telemetry on/off gate,
    per-verb emit, `TsFilteredSink` isolation pattern. 148 tests total.
- **Swift conformance gate:** `Tests/SubstrateLibConformanceTests/`
  - `AuditGateConformanceTests.swift`
  - `RowStateAutomatonConformanceTests.swift`
  - `VerbConformanceTests.swift`
- **Rust:** per-module `#[cfg(test)] mod tests` plus integration tests:
  - `tests/wire_format_conformance.rs`
  - `tests/bitmap_field_constants_conformance.rs`
  - `tests/audit_log_fold_integration.rs`
  - `tests/float_simhash_swift_conformance.rs`
  - `tests/substrate_lib_telemetry_tests.rs` — telemetry on/off gate,
    per-verb emit, `TsFilteredSink` + `GLOBAL_LOCK` isolation. 61 tests total.

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
| Telemetry metric-name constants | `SubstrateLibMetric` (caseless enum, 10 `static let` strings) — `Sources/SubstrateLib/SubstrateLibTelemetry.swift` | `metric` submodule (10 `pub const &str` values) — `rust/src/substrate_lib_telemetry.rs` | public both | Swift enum-namespace / Rust `pub mod metric` (sanctioned namespacing diff); string values bit-identical across ports | `SubstrateLibTelemetryTests.swift::§7 metric name constants` ↔ `tests/substrate_lib_telemetry_tests.rs::metric_names_are_correct` | Confirmed |
| Telemetry emit helpers | 10 `@inline(__always)` package-internal functions — `Sources/SubstrateLib/SubstrateLibTelemetry.swift` | 10 `#[inline(always)]` `pub fn` — `rust/src/substrate_lib_telemetry.rs` | internal both | identical tag keys and semantics; off-path cost one atomic load + branch when monitoring disabled | `SubstrateLibTelemetryTests.swift §1–§6` ↔ `tests/substrate_lib_telemetry_tests.rs §1–§6` | Confirmed |
| `ts` parameter on verb methods | `ts: Double = 0.0` added to `capture`, `reanchor`, `mutate`, `withdraw`, `expunge`, `recall` — `Sources/SubstrateLib/Verbs.swift` | `ts: f64` (required, no default) added to same methods — `rust/src/verbs.rs` | public both | Swift default `0.0` preserves existing callers; Rust callers explicit (idiomatic). Both: caller-supplied epoch seconds, SubstrateLib never reads a clock | `SubstrateLibTelemetryTests.swift::§2 enabled gate` ↔ `tests/substrate_lib_telemetry_tests.rs::enabled_gate_capture_emits_one_sample` | Confirmed |

### Read-anchored notes

Two points worth restating, both now reflected in § 2 above and in this
table:

1. **`AuditGateError` does not exist.** `AuditGate.admit` returns
   `Result<AuditEvent, GateViolation>` on **both** ports
   (`Sources/SubstrateLib/AuditGate.swift:302`,
   `rust/src/audit_gate.rs:203`). `GateViolation` is the authoritative
   gate-error surface; its `basisViolation` case wraps the underlying
   `RowStateError`.
2. **`Substrate` is stateful; gate/automaton ops are free functions in
   Rust.** `Substrate` is a real `struct` with `mutating`/`&mut self`
   verb methods, while the gate, automaton, and freeze operations are a
   Swift caseless-`enum` namespace vs Rust module free functions — the
   sanctioned namespacing difference, not drift.

All table rows are `Confirmed`; no code parity gap is implied.

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

// Only the consumer-contributed union is frozen; the substrate basis
// is built in. (Here flagsSlot is the union; stateSlot overlaps the
// basis state field and is shown for illustration of admit writes.)
let vocab = try VocabularyValidator.freeze(union: [flagsSlot]).get()

// Capture a brand-new row.
let captureResult = AuditGate.admit(
    estateUuid: estateUUID,
    rowId: UUID(),
    nounType: .drawer,
    verb: .capture,
    prior: nil,
    priorLatticeAnchor: nil,
    writes: [FieldWrite(slot: stateSlot, value: 0)],   // active
    afterLatticeAnchor: LatticeAnchor.udc("0"),
    vocabulary: vocab,
    hlc: hlcGen.send(now: nowMillis),
    actor: "alice"
)
let captureEvent = try captureResult.get()
// captureEvent.verb == "capture"
// captureEvent.afterBitmaps.adjective & 0x3F == 0

// Mutate the row's flags (set bit 26).
let mutateResult = AuditGate.admit(
    estateUuid: estateUUID,
    rowId: captureEvent.rowId,
    nounType: .drawer,
    verb: .mutate,
    prior: BitmapFields(adjective: UInt64(bitPattern: captureEvent.afterBitmaps.adjective),
                        operational: UInt64(bitPattern: captureEvent.afterBitmaps.operational),
                        provenance: UInt64(bitPattern: captureEvent.afterBitmaps.provenance)),
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
use substrate_lib::audit_gate::{self, FieldSlot, FieldWrite, Column};
use std::collections::HashSet;

let flags_slot = FieldSlot::new(Column::Adjective, 24, 3, "flags");
let state_slot = FieldSlot::with_values(Column::Adjective, 0, 6, "state",
    &[0, 1, 2, 3, 16, 17, 18, 19, 32, 33]);
let vocab = audit_gate::freeze(HashSet::from([flags_slot.clone()])).unwrap();

let capture_event = audit_gate::admit(
    estate_uuid, row_id, NounType::Drawer, RowVerb::Capture,
    None, None,
    &[FieldWrite { slot: state_slot, value: 0 }],
    LatticeAnchor::udc("0"),
    &vocab,
    hlc_gen.send(now_millis),
    "alice",
)?;
```
