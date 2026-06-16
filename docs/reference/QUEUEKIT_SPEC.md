---
title: QueueKit Specification
version: 1.0.0
status: active
date: 2026-06-14
description: "Behavioral specification for QueueKit: invariants, conformance requirements, and the contract it guarantees."
spec_type: kit
authors: MOOTx01 maintainers
relates_to:
  - docs/reference/QUEUEKIT_INTERFACE.md
  - docs/reference/SUBSTRATELIB_SPEC.md
  - docs/reference/PERSISTENCEKIT_SPEC.md
  - docs/reference/GENIUSLOCUS_ARCHITECTURE_SPEC.md
purpose: |
  QueueKit is a general-purpose fill-and-drain serial job queue. A
  sender submits a Job without knowing who processes it or when; a
  receiver watches, drains the claimable jobs in causal order, and
  replies with a terminal observation. The same four operations
  (send/drain/watch/reply) sit over three interchangeable backends —
  Filesystem (POSIX maildir), PersistenceKit-backed, and InMemory —
  that callers cannot distinguish by observable behaviour. The
  companion INTERFACE document carries the signatures; this
  specification defines the wire/on-disk format the backends share.
---

# QueueKit Specification

## § 1 — What this package is

QueueKit is a general-purpose, durable, serial job queue. It is not
specific to any one product. The core promise is that **a sender does
not need to know who processes a job or when**: a device queues a Job
it cannot or will not execute itself, and some watcher — the same
device, another machine, a server — claims it, runs it, and records a
terminal observation. The protocol is the contract; the backend
decides where the bits live.

A caller interacts through one facade type (`QueueKit`) and four
permanent operations — `send`, `drain`, `watch`, `reply` — plus two
inspection reads, `inFlight()` and `completed(streamID:)`. Behind the
facade sits one of three interchangeable backends: a Filesystem
backend (POSIX maildir with atomic `rename(2)` transitions), a
PersistenceKit-backed backend (jobs as rows in a `Storage` table), and
an InMemory backend (the PersistenceKit backend mounted on
in-process storage, used for tests and the in-tree serial-lane
consumer). All three conform to a single `QueueBackend` protocol and
are indistinguishable to the caller by observable behaviour.

This package is a **Kit**: it manages durable state (files on disk or
rows in a table) and a job lifecycle (`new → cur → done`). It is not a
pure-function Lib. Determinism is preserved by sourcing all time from
SubstrateLib's `HLCGenerator` (the caller supplies `now`), never from
a wall clock read inside the engine.

## § 2 — Scope

This specification defines:

- The four public operations (`send`, `drain`, `watch`, `reply`) and
  the two inspection reads, and their lifecycle and ordering promises.
- The `QueueBackend` protocol contract every backend satisfies, and
  the three conforming backends (Filesystem, PersistenceKit-backed,
  InMemory).
- The job lifecycle state machine (`new → cur → done`) and the
  atomicity, durability, and no-double-claim guarantees that govern
  each transition.
- The supporting type model: `Job`, the identifier types (`JobID`,
  `StreamID`, `SessionID`, `ToolName`), `ArtifactRef`, `CodableValue`,
  `ObservationStatus`, `SignalFile`, and `MissionContext`.
- The conceptual error model and recovery posture.
- The three-way conformance obligation (Swift, Rust, Python) and the
  bit-identity requirement on the Filesystem backend.

This specification does NOT define:

- API signatures — those live in `QUEUEKIT_INTERFACE.md`.
- The byte-level wire format and on-disk filename/JSON encoding is
  pinned by this specification (§ 4, § 7) and the shared
  encoder/decoder in `QUEUEKIT_INTERFACE.md`; all three backends
  serialize to it byte-identically.
- `HLC` / `HLCGenerator` semantics — owned by SubstrateLib
  (`SUBSTRATELIB_SPEC.md`); QueueKit imports them and never
  redefines them.
- The `Storage`, `RowStore`, `StorageObserver`, and isolation-level
  semantics the PersistenceKit backend builds on — those are
  PersistenceKit's (`PERSISTENCEKIT_SPEC.md`).
- Cross-device distribution — an application-layer composition over
  ConvergenceKit, never a QueueKit dependency (§ 8).

## § 3 — Position in the kit family

```
SubstrateLib (HLC, HLCGenerator)      PersistenceKit (Storage, RowStore, Observer)
        ▲                                          ▲
        └───────────────┬──────────────────────────┘
                     QueueKit
                        ▲
            GeniusLocusKit  (Brain / StandingSignalScheduler)
```

**Depends on:** SubstrateLib (for `HLC` and `HLCGenerator`) and
PersistenceKit (for the `Storage` surface the PersistenceKit and
InMemory backends use). It depends on nothing else; in particular it
does **not** import ConvergenceKit (§ 8).

**Consumed by:** GeniusLocusKit only. The Brain's
`StandingSignalScheduler` owns a single `QueueKit` instance backed by
the PersistenceKit backend over in-memory storage, and uses it as the
serial emission lane for one estate (it imports `QueueKit`, `Job`,
`JobID`, `StreamID`, `WireFormat`, and `PersistenceKitBackend`). Per
the composition rule, NeuronKit and CognitionKit never import QueueKit
directly; the queue is reached only through GeniusLocusKit's Brain
layer.

## § 4 — Invariants

**I-1 (sender ignorance):** a successful `send(_:)` makes the job
durably committed and claimable, without the sender knowing which
process, machine, or session will claim it, or when. Submission and
processing are fully decoupled.

**I-2 (single occupancy):** a job occupies exactly one lifecycle state
at a time — `new` (claimable), `cur` (in-flight), or `done`
(terminal). No job exists in two states simultaneously. On the
Filesystem backend the directory is the authoritative state; there is
no separate in-memory authority.

**I-3 (no double-claim):** two concurrent drainers against the same
queue never both receive the same job. On the Filesystem backend this
rests on POSIX `rename(2)` atomicity (exactly one caller gets return
value `0` for a given source path); on the PersistenceKit backend it
rests on a `.serializable` transaction whose claim update is guarded
by a `status = "new"` predicate.

**I-4 (causal ordering):** claimed jobs are returned in HLC
(`submittedAt`) order — `(physicalTime, logicalCount, nodeID)`
ascending. On the Filesystem backend the filename encoding is
lexicographically sortable so that filename order equals causal order.

**I-5 (opaque payload):** `Job.payload` is opaque bytes; QueueKit
never inspects, parses, or depends on them. The caller encodes its
domain type before `send()` and decodes after `drain()`.

**I-6 (extension fidelity):** `Job.extensions` — an arbitrary tree of
strings, ints, doubles, booleans, nulls, arrays, and nested objects —
survives a `send()`/`drain()`/`reply()` round-trip verbatim, with no
loss, reordering of meaning, or coercion.

**I-7 (terminal-only signals):** a `reply(...)` carries a terminal
`ObservationStatus` (`.done`, `.doneWithConcerns`, `.needsContext`,
`.blocked`). `.running` is never a terminal status and never appears
in a signal; passing it is rejected before any storage mutation.

**I-8 (deterministic time):** every HLC stamp originates from the
injected `HLCGenerator`; engines never read a wall clock for ordering
decisions. (The Filesystem backend's stale-`tmp/` sweep reads
modification time as a crash-cleanup heuristic only, not for
ordering.)

**I-9 (backend opacity):** the three backends are observably
indistinguishable through the public facade. Adding a fourth backend
is additive — it conforms to `QueueBackend` without changing the
public API or existing conformances.

**I-10 (no sync dependency):** QueueKit never imports ConvergenceKit
and is unaware that cross-device sync exists. Distribution is an
application-layer concern (§ 8). This mirrors substrate invariant
I-13: federation is an access-surface concern, not a substrate one.

## § 5 — Behavioral contracts

**B-1 (send durability):** `send(_:)` does not return until the job is
durably committed and visible to a concurrent `watch()` / `drain()` on
any backend instance pointing at the same root or `Storage`. It either
commits the job or throws; it never returns having done neither. On
the Filesystem backend durability is `O_CREAT|O_EXCL` → write → fsync →
close → `rename(tmp→new)` → fsync(new dir); the job becomes claimable
only after the rename succeeds. On the PersistenceKit backend it is a
single bare `rowStore.insert` with `status = "new"` (deliberately not
transaction-wrapped, so the observer wake window stays minimal).

**B-2 (drain claim + ordering):** `drain()` atomically claims every
currently-claimable job, transitions each to in-flight before
returning, mints a fresh unique `SessionID` per claimed job, and
returns the `(Job, SessionID)` pairs in HLC order (I-4). If nothing is
claimable it returns an empty array without blocking.

**B-3 (watch liveness):** `watch(handler:)` invokes `handler` for each
newly-claimable `(Job, SessionID)` pair as jobs arrive, in HLC order
within each batch, and does not return until cancelled. The underlying
wake source depends on the port and build configuration — Swift Filesystem
uses kqueue (Darwin) or poll (non-Darwin); Rust Filesystem uses a 200 ms
poll loop by default (no external dependency, matching Swift's
non-Darwin poll cadence) or OS filesystem events via the `notify` crate
when built with `--features watch` (an optimization over the default,
not a requirement); PersistenceKit uses a `StorageObserver` in both ports.
In all cases the wake is a signal only: spurious, early, or coalesced
wakes are permitted, and the authority on what is actually claimable
is `drain()`, which a watch wake always re-reads through. A wake that
finds nothing drains to empty harmlessly. **Fail-closed drain:**
a `drainAvailable()`/claim **error** during the drain loop PROPAGATES —
it must NOT be collapsed to an empty batch. A swallowed claim error would
make a backend fault look identical to "queue empty" and end the drain
pass silently, stranding committed jobs. Both ports propagate (Swift
`drainUntilEmpty` uses `try await backend.drainAvailable()`; Rust
`drain_until_empty` uses `self.drain_available()?`); the pass ends loudly
and the next wake retries against a live backend.

**B-4 (reply terminality + signal-before-move):** `reply(...)` rejects
a non-terminal status with `invalidTerminalStatus` before touching
storage (I-7), then records the terminal observation durably and moves
the job to `done`. On the Filesystem backend the signal file is
written and fsynced **before** the job file is renamed into `done/`,
so a crash between the two leaves the signal present and the job still
in `cur/` — recovery is deterministic. On the PersistenceKit backend
the single `.serializable` update sets `status`, `signal_status`, and
`artifacts` together. `reply()` on a job that is not in-flight throws
`jobNotFound`.

**B-5 (inspection reads):** `inFlight()` returns the jobs currently in
`cur` state; `completed(streamID:)` returns the jobs in `done` state,
optionally narrowed to one `StreamID`, in HLC order. Both are plain
reads with no lifecycle side effects.

**B-6 (decode-failure isolation):** on the Filesystem backend a claimed
job file that fails to decode does not abort the drain: it is moved to
`done/` (treated as `.blocked`) and the remaining claimed files are
still processed. One malformed file never strands a whole batch.

**B-7 (crash recovery posture):** a job stranded in `cur` / `cur/`
(claimed but never replied to, e.g. a processor crash) is **not**
auto-requeued — re-running a job whose side effects may be
half-applied is unsafe without application knowledge. Stranded jobs
are surfaced through `inFlight()` for the application to resolve. On
the Filesystem backend, files stranded in `tmp/` (a crash between open
and rename, never visible in `new/`) older than the stale threshold
are swept on init, because they were never claimable.

**B-8 (cross-backend equivalence):** for any sequence of operations,
the three backends produce the same observable lifecycle outcomes
(B-1…B-7). They differ only in the durability substrate, not in the
contract.

## § 6 — Error model (conceptual)

All failures surface as `QueueError` (the `MOOTx01Error`-convention
enum owned by this module). Concrete cases and per-language shapes
live in INTERFACE § 4.

| Category | Trigger | Recovery posture |
|---|---|---|
| Directory setup | A maildir subdirectory (`tmp/new/cur/done`) cannot be created on init. | Abort init; surface to caller. |
| Durable write | Encode, `open`/`write`/`fsync`, or the bare `insert` fails; or `new/` and `tmp/` straddle filesystems (`EXDEV`, not retried). | Abort the `send`; job not committed. Caller may retry. |
| Rename | A lifecycle `rename(2)` fails for a reason other than the benign `ENOENT` race (which is skipped silently). | Abort the operation; surface. |
| Decode | A job file or row cannot be parsed back into a `Job`. | On drain, isolate the bad job (B-6), do not throw; on inspection reads, skip it. |
| Not found | `reply()` targets a job that is not in the in-flight state. | Surface `jobNotFound`; caller reconciles. |
| Bad terminal status | `reply()` is called with `.running`. | Reject before any storage mutation (I-7). |
| Backend unavailable | The underlying `Storage` is unreachable, or an operation is unsupported by the mounted backend. | Surface; caller decides retry vs abort. |
| Stale tmp file | A file lingers in `tmp/` past the stale threshold. | Cleanup heuristic; swept on init, not a fatal error in normal flow. |

**Telemetry depth honesty:** the self-report path
(`QueueKitTelemetry.reportQueueStats`, Swift-only — telemetry is the
Apple-only IntellectusLib sink) must NOT report `queue.depth = 0` when the
`pendingCount()` read fails. A fabricated zero is indistinguishable from a
genuinely empty queue and would signal "all drained" when the truth is "could
not read the depth". On a `pendingCount` read failure no `queue.depth` metric
is emitted; instead a `queue.depth_unavailable` error counter is emitted, and
the depth-derived metrics (`queue.idle_nonempty`, the idle branch of
`queue.head_of_line_age_s`) are suppressed for that cycle. The Rust port has no
QueueKit telemetry module, so there is no Rust counterpart to keep in parity.

## § 7 — Conformance requirements

The conformance suite runs across Swift (Filesystem + PersistenceKit),
Rust (Filesystem + PersistenceKit), and Python (Filesystem only — per
the daemon-parity doctrine, Python ships the Filesystem backend only).

**C-1 (schema round-trip):** construct a `Job`, `send()`, `drain()`;
the returned `Job` is field-identical to the original, including every
nested value in `extensions` (I-6, B-2).

**C-2 (transition correctness):** after `send()` the job is in `new`
only; after `drain()` it is in `cur` only; after `reply()` it is in
`done` only with the signal recorded. No job is ever observable in two
states at once (I-2, B-4).

**C-3 (signal-before-move):** `reply()` records the signal before the
job reaches `done`; a simulated crash between the two leaves the
signal present and the job in `cur` (B-4).

**C-4 (no double-claim):** N concurrent drainers against M queued jobs
return exactly M jobs in aggregate with zero duplicates, for every
backend. Any duplicate claim is a blocking failure (I-3).

**C-5 (extension preservation):** `Job.extensions` with nested values
survives `send → drain → reply` with no loss or modification (I-6).

**C-6 (failure modes):** Filesystem — a stale `tmp/` file is removed on
reinit with no job lost or duplicated. PersistenceKit — a row stranded
in `cur` is visible through `inFlight()` and is never silently
re-claimed by a later `drain()` (B-7).

**C-7 (bit-identity, Filesystem):** the Swift, Rust, and Python
Filesystem backends produce byte-identical filenames, job-file JSON,
and signal-file JSON for identical inputs. Fixtures are generated from
the Swift version and consumed by the Rust and Python suites. (The
PersistenceKit backend is behaviour-conformant, not byte-identical,
since it stores rows rather than files.)

## Changelog

### 1.0.0 -- 2026-06-14
Established under VERSIONING.md: version number removed from the filename; front matter normalized; baselined at 1.0.0.
