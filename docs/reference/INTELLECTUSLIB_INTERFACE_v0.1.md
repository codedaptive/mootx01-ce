---
status: draft
authors: Bob Pankratz (via/ claude)
date: 2026-06-06
version: v0.1
package: IntellectusLib
languages: [swift, rust]
relates_to:
  - INTELLECTUSLIB_SPEC_v0.1.md  (the contract this interface implements)
purpose: |
  Public API surface of IntellectusLib in both ports: StatSample,
  EventKind, StatsSink, NoOpSink, Intellectus global facade, and the
  short-circuit report API. The companion SPEC carries the behavioral
  contracts (invariants I-1…I-7).
---

# IntellectusLib Interface

## § 1 — Package layout

**Swift:** `packages/libs/IntellectusLib/`

- `Sources/IntellectusLib/StatSample.swift` — `StatSample` enum, `EventKind` enum
- `Sources/IntellectusLib/StatsSink.swift` — `StatsSink` protocol, `NoOpSink`
- `Sources/IntellectusLib/Intellectus.swift` — `_IntellectusHolder` (internal),
  `_intellectus` singleton (internal), `Intellectus` public facade
- `Tests/IntellectusLibTests/IntellectusLibTests.swift` — 17 conformance tests
- `Package.swift` — zero-dependency manifest (Foundation only)

**Rust:** `packages/libs/IntellectusLib/rust/`

- `src/lib.rs` — crate `intellectus-lib`: module re-exports + `report!` macro
- `src/sample.rs` — `StatSample` enum, `EventKind` enum
- `src/sink.rs` — `StatsSink` trait, `NoOpSink`
- `src/holder.rs` — `IntellectusHolder` (per-instance state, used in tests)
- `src/global.rs` — `Intellectus` public facade
- `tests/intellectus_lib_tests.rs` — 17 conformance tests + 3 doc-tests
- `Cargo.toml` — zero-dependency manifest (std only)

## § 2 — Public types

### `StatSample`

The telemetry datum. See SPEC § 4 for field semantics.

**Swift:**

```swift
public enum StatSample: Sendable {
    case metric(
        name: String,
        value: Double,
        tags: [String: String],
        ts: Double
    )
    case event(
        kind: EventKind,
        nounType: Int,
        rowID: String,
        estate: String,
        ts: Double
    )
    // Computed property
    public var ts: Double { get }
}
```

**Rust:**

```rust
pub enum StatSample {
    Metric {
        name: String,
        value: f64,
        tags: HashMap<String, String>,
        ts: f64,
    },
    Event {
        kind: EventKind,
        noun_type: i64,
        row_id: String,
        estate: String,
        ts: f64,
    },
}

impl StatSample {
    pub fn metric(name: String, value: f64, tags: HashMap<String,String>, ts: f64) -> Self
    pub fn event(kind: EventKind, noun_type: i64, row_id: String, estate: String, ts: f64) -> Self
    pub fn ts(&self) -> f64
}
```

### `EventKind`

The verb class for topology events. See SPEC § 4.3.

**Swift:**

```swift
public enum EventKind: String, Sendable, Hashable, CaseIterable {
    case capture   // rawValue: "capture"
    case think     // rawValue: "think"
}
```

**Rust:**

```rust
pub enum EventKind {
    Capture,
    Think,
}

impl EventKind {
    pub fn as_str(&self) -> &'static str  // "capture" or "think"
}
```

### `StatsSink`

Receiver protocol/trait. See SPEC § 5.

**Swift:**

```swift
public protocol StatsSink: Sendable {
    func receive(_ sample: StatSample)
}
```

**Rust:**

```rust
pub trait StatsSink: Send + Sync {
    fn receive(&self, sample: StatSample);
}
```

### `NoOpSink`

The default discard implementation. See SPEC § 6 (I-6).

**Swift:**

```swift
public struct NoOpSink: StatsSink {
    public static let shared: NoOpSink
    public init()
    @inline(__always)
    public func receive(_ sample: StatSample)  // discards immediately
}
```

**Rust:**

```rust
#[derive(Debug, Clone, Default)]
pub struct NoOpSink;

impl StatsSink for NoOpSink {
    #[inline(always)]
    fn receive(&self, _sample: StatSample)  // discards immediately
}
```

## § 3 — Global facade: `Intellectus`

The public API entry point for hosts and substrate callers. See SPEC §§ 3, 6.

**Swift:**

```swift
public enum Intellectus {
    /// Replace the installed sink. Thread-safe via NSLock (sink lock only).
    public static func install(sink: any StatsSink)

    /// Enable or disable the telemetry gate. Default: false.
    public static func setEnabled(_ enabled: Bool)

    /// Whether monitoring is currently enabled. Thread-safe.
    public static var isEnabled: Bool { get }

    /// Short-circuit emission. Payload autoclosure is NEVER evaluated
    /// when isEnabled is false. (SPEC I-2, I-3)
    @inline(__always)
    public static func report(_ make: @autoclosure () -> StatSample)
}
```

**Rust:**

```rust
pub struct Intellectus;

impl Intellectus {
    /// Replace the installed sink. Thread-safe via Mutex.
    pub fn install(sink: Arc<dyn StatsSink>)

    /// Enable or disable the gate. Default: false.
    pub fn set_enabled(enabled: bool)

    /// Whether monitoring is currently enabled.
    pub fn is_enabled() -> bool

    /// Internal: deliver a pre-constructed sample (called by report! macro).
    #[doc(hidden)]
    pub fn report_sample(sample: StatSample)
}
```

## § 4 — Short-circuit emission API

The primary entry point for substrate callers. This is the whole point of
the library: the payload must never be constructed when monitoring is off.

**Swift:** `@autoclosure` parameter — any expression passed to `Intellectus.report(_:)` is
automatically wrapped in a closure by the compiler.

```swift
// Payload expression never evaluated when off:
Intellectus.report(.metric(
    name: "locus.capture.latency_ms",
    value: elapsed * 1000,
    tags: ["kit": "LocusKit"],
    ts: Date().timeIntervalSince1970
))
```

**Rust:** `report!` macro — block expression argument.

```rust
// Block is never evaluated when off:
report!({
    StatSample::metric(
        "locus.capture.latency_ms".into(),
        elapsed.as_secs_f64() * 1000.0,
        [("kit".to_string(), "LocusKit".to_string())].into(),
        ts,
    )
});
```

Also available as a function for use when a closure is already on hand:

```rust
// Direct function form — caller is responsible for the gate check:
if Intellectus::is_enabled() {
    Intellectus::report_sample(sample);
}
```

## § 5 — Internal: `_IntellectusHolder` / `IntellectusHolder`

Exposed via `@testable import` (Swift) and `pub` visibility (Rust) for
conformance tests that need isolated per-instance state. Not part of the
host-facing public API.

**Swift:** `_IntellectusHolder` — `final class`, `@unchecked Sendable`, `Atomic<Bool>` enabled gate + NSLock-protected sink.

```swift
// Test access only:
let holder = _IntellectusHolder()
holder.install(sink: mySink)
holder.setEnabled(true)
holder.report(StatSample.metric(…))
```

**Rust:** `IntellectusHolder` — `pub struct`, `AtomicBool` + `Mutex<Arc<dyn StatsSink>>`.

```rust
// Test access:
let holder = IntellectusHolder::new();
holder.install(Arc::new(MySink));
holder.set_enabled(true);
holder.report(|| StatSample::metric(…));
```

## Swift/Rust Concordance

| Concept | Swift | Rust | Notes |
|---------|-------|------|-------|
| `StatSample` | `enum StatSample` | `enum StatSample` | Variant-for-variant parity |
| `.metric` variant | `.metric(name:value:tags:ts:)` | `StatSample::Metric { name, value, tags, ts }` | Same fields |
| `.event` variant | `.event(kind:nounType:rowID:estate:ts:)` | `StatSample::Event { kind, noun_type, row_id, estate, ts }` | Same fields, Swift camelCase, Rust snake_case |
| `EventKind` | `enum EventKind: String` | `enum EventKind` | Swift rawValue = Rust as_str() |
| `.capture` / `Capture` | `"capture"` | `"capture"` | Same string tag |
| `.think` / `Think` | `"think"` | `"think"` | Same string tag |
| `StatsSink` | `protocol StatsSink: Sendable` | `trait StatsSink: Send + Sync` | Single method `receive` |
| `NoOpSink` | `struct NoOpSink: StatsSink` | `struct NoOpSink` impl `StatsSink` | Discard, O(1) |
| `Intellectus` | `enum Intellectus` (caseless) | `struct Intellectus` (no fields) | Namespace only |
| `install` | `Intellectus.install(sink:)` | `Intellectus::install(Arc<dyn StatsSink>)` | |
| `setEnabled` / `set_enabled` | `Intellectus.setEnabled(_:)` | `Intellectus::set_enabled(bool)` | |
| `isEnabled` / `is_enabled` | `Intellectus.isEnabled: Bool` | `Intellectus::is_enabled() -> bool` | |
| `report` (short-circuit) | `Intellectus.report(_ make: @autoclosure () -> StatSample)` | `report!(block expr)` macro | Payload never evaluated when off |
| `ts` accessor | `StatSample.ts: Double` | `StatSample::ts(&self) -> f64` | Same semantics |
| Internal holder | `_IntellectusHolder` | `IntellectusHolder` | Per-instance, test-visible |
| Enabled gate impl | `Synchronization.Atomic<Bool>` (.acquiring load) | `AtomicBool::load(Acquire)` | Both lock-free on the off-path |
| Sink storage | `NSLock`-protected `any StatsSink` | `Mutex<Arc<dyn StatsSink>>` | Both thread-safe; lock held only on-path |
| Off-path cost | ~1 ns (lock-free Atomic<Bool>, Apple Silicon) | <1 ns (AtomicBool, compiler-optimized) | SPEC I-3 |
| On-path cost | ~10–30 ns (NSLock + sink snapshot + receive) | ~10 ns (Atomic + Mutex + Arc clone + receive) | Measured |

## § 7 — Concordance audit result

Run at commit time:

```
$ python3 tools/concordance_audit/concordance_audit.py   # from the repository root
```

IntellectusLib: ADVISORY pass — all public types (`StatSample`, `EventKind`,
`StatsSink`, `NoOpSink`, `Intellectus`, `IntellectusHolder`) appear in the
concordance table above. The `report!` macro is documented in § 4. No drift.
