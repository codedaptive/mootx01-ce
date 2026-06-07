---
status: draft
authors: Bob Pankratz (via/ claude)
date: 2026-06-06
version: v0.1
package: IntellectusLib
kind: Lib
relates_to:
  - INTELLECTUSLIB_INTERFACE_v0.1.md  (the API surface this spec contracts)
purpose: |
  Behavioral contract for IntellectusLib: the substrate's self-report
  telemetry faculty. Specifies what the package promises to callers,
  what invariants it enforces, and what an implementation must do to
  be conforming. Companion interface document carries API signatures.
---

# IntellectusLib Specification

## § 1 — What this package is

IntellectusLib is a **Lib**: a zero-dependency, stateless-except-for-the-global-
holder library. It has no actors and no managed lifecycle. The global holder
is a singleton initialized lazily on first use.

IntellectusLib is the **telemetry floor** of the MOOTx01 substrate. It sits
below every other package in the dependency graph so that any package —
including the lowest substrate primitives (SubstrateTypes, SubstrateKernel,
SubstrateLib) — can emit telemetry without a layering cycle. In Mission 2
those packages will declare a dependency on IntellectusLib; this mission
(Mission 1) delivers the leaf itself.

## § 2 — Scope

This specification defines:

- The `StatSample` data model: the metric variant and the event variant
- The `StatsSink` protocol/trait and the `NoOpSink` default implementation
- The global holder's state machine: installed sink + enabled flag
- The short-circuit reporting API (`report(_:)` / `report!`)
- The threading model for both Swift and Rust implementations
- The off-path performance invariant (I-3)

This specification does NOT define:

- Any transport or serialization (later missions)
- Any observer or consumer of telemetry (later missions)
- Any clock reads — timestamps are always caller-supplied
- Batching, buffering, or back-pressure (responsibility of the installed sink)

## § 3 — Invariants

### I-1: Zero dependencies

IntellectusLib depends on NOTHING in the repo. Swift depends on Foundation
only; Rust depends on `std` only. No substrate crate (`substrate-types`,
`substrate-kernel`, etc.) may be imported.

This invariant is what allows the lowest substrate packages to depend on
IntellectusLib in Mission 2 without a cycle.

### I-2: Short-circuit evaluation

When `Intellectus.isEnabled` / `Intellectus::is_enabled()` is `false` (the
default), the payload expression passed to `report(_:)` / `report!` is
**never evaluated**. No closure body runs. No allocation occurs. No sink
is called.

An implementation that evaluates the payload even once when disabled fails
this invariant. The conformance tests verify this with a side-effect counter:
the counter must stay zero across 1 000 disabled reports.

### I-3: Off-path cost

The disabled `report` call must cost no more than:

- **Swift**: one `Atomic<Bool>.load(.acquiring)` + conditional branch.
  Measured: ~1 ns on Apple Silicon (lock-free, no mutex on the off-path).
- **Rust**: one `AtomicBool::load(Acquire)` + conditional branch.
  Measured: <1 ns on Apple Silicon (compiler-optimized in release mode).

No lock acquisition on the off-path, no memory allocation, no heap access
beyond the atomic load itself. Both ports are lock-free on the disabled path.

### I-4: Caller-supplied timestamps

`StatSample` carries a `ts` field (epoch seconds as `Double`/`f64`).
IntellectusLib **never reads a clock**. The caller supplies `ts`. This
maintains determinism and testability — a test can pass any `ts` value
without mocking a clock.

### I-5: Thread safety

The global holder is safe to call from any thread. Concurrent calls to
`install`, `setEnabled`, and `report` must not corrupt state, deadlock,
or crash. Both implementations use `Atomic<Bool>` / `AtomicBool` for the
enabled gate (lock-free reads) and a mutex (`NSLock` in Swift,
`Mutex<Arc<dyn StatsSink>>` in Rust) for the sink — a brief critical
section during installation and during sink snapshot in `report`.

### I-6: Default state

On first use, before any host calls:
- Monitoring is **disabled** (`isEnabled == false`).
- The installed sink is `NoOpSink` — a safe discard.

No telemetry is emitted until the host explicitly calls
`setEnabled(true)` after installing a real sink.

### I-7: Sink called outside the lock

In both ports, the installed sink's `receive` / `recv` method is called
**outside** the internal lock. The lock is acquired only to snapshot the
`Arc<dyn StatsSink>` / `any StatsSink` reference. This prevents a lock
inversion if the sink implementation itself acquires any lock.

## § 4 — StatSample model

### § 4.1 Metric variant

A named floating-point measurement:

| Field  | Type              | Semantics                                         |
|--------|-------------------|---------------------------------------------------|
| `name` | String            | Dot-separated metric name, e.g. `"locus.capture.latency_ms"` |
| `value`| Double / f64      | The measured quantity (count, duration, rate, …)  |
| `tags` | [String: String]  | Arbitrary key-value context                       |
| `ts`   | Double / f64      | Caller-supplied epoch seconds (never clock-read)  |

### § 4.2 Event variant

A topology-worker lifecycle event for the future estate-event stream:

| Field       | Type      | Semantics                                              |
|-------------|-----------|--------------------------------------------------------|
| `kind`      | EventKind | The verb class: `capture` or `think`                   |
| `nounType`  | Int / i64 | The NounType ordinal (cast from SubstrateTypes.NounType at call site) |
| `rowID`     | String    | The row UUID string from the estate                    |
| `estate`    | String    | The estate identifier string                           |
| `ts`        | Double / f64 | Caller-supplied epoch seconds                       |

### § 4.3 EventKind

Two cases only, pinned by the conformance test:

| Case      | Swift rawValue | Rust as_str() |
|-----------|---------------|---------------|
| `capture` | `"capture"`   | `"capture"`   |
| `think`   | `"think"`     | `"think"`     |

The conformance test pins the count to exactly 2 cases. Adding a third
case requires a spec update.

## § 5 — StatsSink contract

A `StatsSink` conformer:

1. Must be `Sendable` (Swift) / `Send + Sync` (Rust).
2. Must implement a single method: `receive(_ sample: StatSample)` / `fn receive(&self, sample: StatSample)`.
3. Should be non-blocking in `receive`. Long work belongs in the sink's own
   queue, not in the `receive` body.
4. Must tolerate concurrent calls to `receive` from multiple threads
   (because the host may have multiple substrate kits emitting concurrently).

## § 6 — Global holder state machine

```
Initial state:  { enabled: false, sink: NoOpSink }

Transitions:
  install(sink)   →  { enabled: unchanged, sink: new_sink }
  setEnabled(true)  →  { enabled: true,  sink: unchanged }
  setEnabled(false) →  { enabled: false, sink: unchanged }

Emission:
  report(make):
    if enabled: evaluate make(), call sink.receive()
    if disabled: return immediately (make NOT evaluated)
```

The state machine is intentionally minimal. There is no "uninstalled" state
and no error path — the holder is always valid.

## § 7 — Conformance requirements

An implementation of IntellectusLib must pass all tests in the reference
test suite:

| Test | Requirement |
|------|-------------|
| `closure_not_evaluated_when_disabled` | I-2 gating — disabled |
| `side_effect_counter_stays_zero_after_many_disabled_reports` | I-2 gating at scale |
| `report_macro_does_not_evaluate_closure_when_disabled` | I-2 on public API |
| `sink_receives_exact_metric_when_enabled` | I-2 enabled + field fidelity |
| `sink_receives_exact_event_when_enabled` | I-2 enabled + event field fidelity |
| `closure_is_evaluated_when_enabled` | I-2 enabled path — closure runs once |
| `toggle_disabled_after_enabled_stops_emission` | I-2 toggling |
| `noop_sink_is_callable` | § 5 safe discard |
| `default_installed_sink_is_noop` | I-6 default state |
| `concurrent_install_and_set_enabled_do_not_crash_or_race` | I-5 thread safety |
| `metric_ts_accessor_returns_correct_value` | I-4 caller-supplied ts |
| `event_ts_accessor_returns_correct_value` | I-4 caller-supplied ts |
| `metric_with_empty_tags_is_valid` | § 4.1 edge case |
| `metric_with_populated_tags_is_valid` | § 4.1 tag map fidelity |
| `event_kind_as_str_matches_swift_raw_values` | § 4.3 parity |
| `event_kind_equality` | § 4.3 identity |
| `disabled_report_throughput` | I-3 off-path cost gate |

## § 8 — Placement rationale

IntellectusLib is placed in `packages/libs/` (not `packages/kits/`) because:

- It produces values back to callers (samples forwarded to a sink).
- It has no actors, no lifecycle management, no ongoing autonomous work.
- The global holder is a singleton but contains no domain logic — it is a
  routing table with one entry and one flag.

The telemetry MATH layer sits below the substrate MATH layer in the
dependency graph because telemetry emission is simpler than substrate math:
it needs no types from SubstrateTypes and no kernels from SubstrateKernel.
