---
status: active
authors: MOOTx01 maintainers
date: 2026-07-16
version: 1.5.1
description: Public API surface for QueueKit in both the Swift and Rust ports.
spec_type: kit
package: QueueKit
languages: [swift, rust, python]
relates_to:
  - QUEUEKIT_SPEC.md  (the contract this interface implements)
purpose: |
  Public API surface of QueueKit: the QueueKit Interface and its four
  operations (send/drain/watch/reply) plus inFlight/completed, the
  QueueBackend protocol and its three conformances (Filesystem,
  PersistenceKit-backed, InMemory), the Job model and its supporting
  types, and the QueueError enum. Swift and Rust signatures are given;
  the Python parity port (Filesystem backend only) is noted in prose.
  The companion SPEC carries the behavioral contracts (invariants
  I-1…I-10, conformance C-1…C-7).
---

# QueueKit Interface

## § 1 — Package layout

**Swift:** `packages/kits/QueueKit/`

- `Sources/QueueKit/QueueKit.swift` — the `QueueKit` Interface
  (send/drain/watch/reply, inFlight/completed), maildir management,
  `staleTmpThreshold`
- `Sources/QueueKit/QueueBackend.swift` — the `QueueBackend` protocol
- `Sources/QueueKit/FilesystemBackend.swift` — POSIX maildir backend
- `Sources/QueueKit/PersistenceKitBackend.swift` —
  `PersistenceKitBackend`, `QueueKitSchema`, `queueKitTableName`
- `Sources/QueueKit/Job.swift` — `Job`, `JobID`, `StreamID`,
  `SessionID`, `ToolName`, `ArtifactRef`, `CodableValue`,
  `MissionContext`, `WireFormat`, `SignalFile`
- `Sources/QueueKit/ObservationStatus.swift` — `ObservationStatus`
- `Sources/QueueKit/QueueError.swift` — `QueueError`
- `Sources/QueueKit/Watcher.swift` — internal kqueue/poll wake source
- `Tests/QueueKitTests/` (incl. `Fixtures/`), `Package.swift`

Depends on `SubstrateLib` (HLC) and `PersistenceKit` (Storage); not
ConvergenceKit (SPEC § 3, § 8).

**Rust:** `packages/kits/QueueKit/rust/` (crate `queuekit`)

- `src/job.rs` — wire types: `Job`, `JobId`, `StreamId`, `SessionId`,
  `HLC` (consumed from substrate-lib), `ObservationStatus`, `ArtifactRef`, `CodableValue`,
  `SignalFile`, and the encoding free functions
- `src/backend.rs` — `QueueBackend` trait and `WatchHandler` type alias
- `src/facade.rs` — `QueueKit<B>` facade (mirrors Swift's `QueueKit` class)
  and `QueueLatencyWindow`
- `src/drain_lease.rs` — `DrainLease`, `DRAIN_LEASE_TTL_SECS`,
  `DRAIN_LEASE_HEARTBEAT_SECS`, `wall_now_secs`
- `src/filesystem.rs` — `FilesystemBackend`
- `src/persistencekit.rs` — `PersistenceKitBackend` (behaviour-conformant,
  feature `persistencekit`)
- `src/error.rs` — `QueueError`; `src/lib.rs` — re-exports
- `tests/conformance.rs`, `Cargo.toml`

**Python:** `packages/kits/QueueKit/python/` (package `queuekit`)

- `queuekit/queue.py` (`QueueKit`), `queuekit/filesystem_backend.py`
  (`FilesystemBackend`, `QueueError`), `queuekit/job.py` (`Job`,
  `SignalFile`, `ObservationStatus`, `ArtifactRef`, `HLC`, encoding
  functions). The Python port is the third conformance leg: it
  implements the Filesystem backend **only** and must produce
  byte-identical files to Swift/Rust (SPEC § 7, C-7). It has no
  PersistenceKit backend by design.

## § 2 — Public types

### `QueueKit` (Interface)

The public entry point; mounts one backend and delegates to it
(SPEC § 1, § 3).

**Swift:**

```swift
public final class QueueKit: Sendable {
    public let backend: any QueueBackend
    public let root: URL?
    /// Estate tag for queue.* telemetry metrics. Set at mount time by the
    /// composition layer (e.g. GeniusLocusKit) before any drain calls.
    nonisolated(unsafe) public var estateTag: String   // default "unknown"

    /// Mount the Filesystem backend at `root`: creates the four
    /// maildir subdirectories and sweeps stale tmp/ files (SPEC § 4 I-2, B-7).
    public init(root: URL, hlcGenerator: HLCGenerator) throws
    /// Mount an explicit backend (PersistenceKit / InMemory / tests).
    public init(backend: any QueueBackend, root: URL? = nil)

    // Maildir management (Filesystem)
    public static let maildirSubdirs: [String]    // ["tmp","new","cur","done"]
    public static func ensureMaildir(root: URL) throws
    public static func cleanStaleTmpFiles(root: URL) throws
}

/// Files in tmp/ older than this on init are swept (SPEC § 5, B-7).
public let staleTmpThreshold: TimeInterval   // 5 * 60
```

**Rust:** `pub struct QueueKit<B: QueueBackend>` in `src/facade.rs`
(re-exported from `lib.rs` as `queuekit::QueueKit`). It mirrors the Swift
facade: same four permanent method names (`send`/`drain`/`watch`/`reply`),
same drain telemetry via IntellectusLib, and same `estate_tag` field. The
generic parameter `B` is required because the `watch` method carries a
generic handler through the `QueueKit` surface — the trait itself uses a
boxed `WatchHandler` to stay `dyn`-compatible, but the facade's `watch`
re-introduces the generic so callers do not need to box manually. For the
common case use `QueueKit<FilesystemBackend>`.

```rust
pub struct QueueKit<B: QueueBackend> {
    // fields private; accessed through methods below
}
impl<B: QueueBackend> QueueKit<B> {
    pub fn new(backend: B) -> Self
    /// Set the estate tag used in queue.* telemetry metrics. Mirrors Swift `estateTag`.
    pub fn set_estate_tag(&self, tag: &str)
    /// Access the underlying backend directly (for tests or advanced use).
    pub fn backend(&self) -> &B
}
```

### `QueueBackend` (protocol)

The contract every backend conforms to (SPEC § 4, I-9). Listed under
§ 3 with the four operations it carries.

### `Job`

A queued unit of work; `payload` is opaque, `extensions` survives
verbatim (SPEC § 4, I-5, I-6).

**Swift:**

```swift
public struct Job: Sendable, Codable, Identifiable, Hashable {
    public let id: JobID
    public let streamID: StreamID
    public let submittedAt: HLC          // imported from SubstrateLib
    public let priority: Int             // default 50; lower = higher priority
    public let payload: Data             // opaque; never inspected
    public var extensions: [String: CodableValue]   // preserved verbatim
    public init(id: JobID, streamID: StreamID, submittedAt: HLC,
                priority: Int = 50, payload: Data,
                extensions: [String: CodableValue] = [:])
}
```

**Rust:**

```rust
// HLC is consumed from substrate-lib (the canonical home per M1);
// re-exported as `queuekit::HLC` for ergonomic call-site use.
pub struct Job {
    pub id: JobId,
    pub stream_id: StreamId,
    pub submitted_at: HLC,
    pub priority: i32,
    pub payload: Vec<u8>,
    pub extensions: Map<String, CodableValue>,
}
```

### Identifier types: `JobID`, `StreamID`, `SessionID`, `ToolName`

String-wrapping value types (SPEC § 4). `JobID.generate()` mints a
UUID as 32 lowercase hex chars (no hyphens); `SessionID.mint()` is
minted by the backend at claim time. Session granularity is
backend-specific: the **PersistenceKit** backend mints ONE session per
`drainAvailable()` pass — every job claimed in that pass shares it as a
claim-group handle, which `completeSession(_:status:)` retires in one
update (SPEC I-3 / B-4a). The **Filesystem** backend mints one session
per claimed file (its claim is a per-file `rename`, with no batch group),
and offers no `completeSession`. `StreamID` is URL-safe, ≤ 64 chars;
`ToolName` names a tool for allowlist validation (SPEC § 9).

**Swift:**

```swift
public struct JobID: Sendable, Hashable, Codable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String)
    public static func generate() -> JobID    // 32 hex chars, no hyphens
}
public struct StreamID: Sendable, Hashable, Codable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String)
}
public struct SessionID: Sendable, Hashable, Codable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String)
    public static func mint() -> SessionID
}
public struct ToolName: Sendable, Hashable, Codable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String)
}
```

**Rust:** `pub struct JobId(pub String);`, `pub struct StreamId(pub String);`,
`pub struct SessionId(pub String);`, `pub struct ToolName(pub String);`. The
Rust `ToolName` exposes `new(impl Into<String>)`, `raw_value() -> &str`, and
`validate(&self, allowlist: &[ToolName]) -> Result<(), QueueError>` (yields
`QueueError::UnknownTool` on mismatch). `SessionId` is minted by the backend
at claim time.

### `ObservationStatus`

The job outcome; raw values match the signal-file `status` field
exactly (SPEC § 4, I-7).

**Swift:**

```swift
public enum ObservationStatus: String, Sendable, Codable {
    case running          = "running"
    case done             = "done"
    case doneWithConcerns = "done_with_concerns"
    case needsContext     = "needs_context"
    case blocked          = "blocked"
    public var isTerminal: Bool    // false only for .running
}
```

**Rust:**

```rust
pub enum ObservationStatus { Running, Done, DoneWithConcerns, NeedsContext, Blocked }
impl ObservationStatus {
    pub fn raw(&self) -> &'static str;            // matches Swift rawValue
    pub fn from_raw(s: &str) -> Option<Self>;
    pub fn is_terminal(&self) -> bool;
}
```

### `ArtifactRef`

A typed reference recorded in a reply (SPEC § 5, B-4). Serialized as
`{"type": "...", "value": "..."}`.

**Swift:**

```swift
public enum ArtifactRef: Sendable, Hashable, Codable {
    case filePath(String)          // "file_path"
    case commitHash(String)        // "commit_hash"
    case signalFile(String)        // "signal_file"
    case trajectoryStepID(String)  // "trajectory_step_id"
}
```

**Rust:**

```rust
pub enum ArtifactRef { FilePath(String), CommitHash(String),
                       SignalFile(String), TrajectoryStepId(String) }
impl ArtifactRef { pub fn type_tag(&self) -> &'static str; pub fn value(&self) -> &str; }
```

### `CodableValue`

The recursive value type carried in `Job.extensions`; round-trips
verbatim (SPEC § 4, I-6).

**Swift:**

```swift
public indirect enum CodableValue: Sendable, Codable, Hashable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([CodableValue])
    case object([String: CodableValue])
}
```

**Rust:** `pub type CodableValue = serde_json::Value;` (Python: native
`dict`/`list`/scalars).

### `SignalFile`

The durable terminal observation written by `reply()` before a job
reaches `done` (SPEC § 5, B-4).

**Swift:**

```swift
public struct SignalFile: Sendable, Codable {
    public let jobID: JobID
    public let status: ObservationStatus
    public let artifacts: [ArtifactRef]
    public let completedAt: HLC
    public init(jobID: JobID, status: ObservationStatus,
                artifacts: [ArtifactRef], completedAt: HLC)
}
```

**Rust:**

```rust
pub struct SignalFile {
    pub job_id: JobId, pub status: ObservationStatus,
    pub artifacts: Vec<ArtifactRef>, pub completed_at: HLC,
}
```

### `WireFormat`

The canonical encoder/decoder and filename builder shared by all ports
for byte-identity (SPEC § 7, C-7).

**Swift:**

```swift
public enum WireFormat {
    public static func filename(for job: Job) -> String
    public static func sortableHLC(_ hlc: HLC) -> String   // 016d-08d-010u, causal-sortable
    public static let encoder: JSONEncoder   // .sortedKeys, .withoutEscapingSlashes
    public static let decoder: JSONDecoder
}
```

**Rust:** free functions on the crate root — `filename_for_job(&Job) -> String`,
`sortable_hlc(&HLC) -> String`, `encode_job(&Job) -> Vec<u8>`,
`encode_signal(&SignalFile) -> Vec<u8>`, `decode_job(&[u8]) -> Result<Job, serde_json::Error>`,
`base64url_encode(&[u8]) -> String`, `base64url_decode(&str) -> Option<Vec<u8>>`.

### `MissionContext`

An optional caller-side payload type encoded into `Job.payload`;
QueueKit treats it as opaque bytes (SPEC § 4, I-5). It is one example
of a caller-domain payload struct — general callers define their own
payload type instead.

**Swift:**

```swift
public struct MissionContext: Sendable, Codable, Hashable {
    public let missionPath: String
    public let worktree: String
    public let branch: String
    public let autonomyProfile: String
    public let riskClass: String
    public let baseCommit: String
    public let priorTrajectoryID: String?
    public let inheritedSkills: [String]
    public init(missionPath: String, worktree: String, branch: String,
                autonomyProfile: String, riskClass: String, baseCommit: String,
                priorTrajectoryID: String? = nil, inheritedSkills: [String] = [])
}
```

(No Rust/Python equivalent; it is a caller-domain convenience.)

### `DrainLease`

A stream-keyed heartbeat-TTL drain lease (SPEC I-3, T2).
Guarantees exactly one drainer per `(estate, stream)` pair. Each stream has an
independent lease file (`<dir>/<stream>.drain.lease`), so two streams can be
held concurrently. TTL 15 s; heartbeat cadence 5 s; write-then-re-read race
resolution; atomic temp+rename write. Filesystem form only (Postgres-estate
DB-backed lease is deferred).

**Swift:**

```swift
public struct DrainLease: Sendable {
    public let leaseURL: URL
    public let owner: String       // "pid-<PID>-<instanceToken>"
    public let ttl: TimeInterval
    public static let heartbeatInterval: TimeInterval   // 5 s

    public init(directory: URL, stream: String, instanceToken: String,
                ttl: TimeInterval = 15)

    /// Acquire iff absent or expired. Returns true iff this drainer holds it.
    public func tryAcquire(now: Date) -> Bool
    /// Refresh the heartbeat while holding the lease.
    public func heartbeat(now: Date)
    /// True iff another drainer holds a fresh (non-expired) lease.
    public func isHeldByOther(now: Date) -> Bool
    /// Release on clean teardown (removes the lease file immediately).
    public func release()
}
```

**Rust:** `pub struct DrainLease` in `src/drain_lease.rs`; re-exported from
`lib.rs`. Methods: `new(dir, stream, owner)`, `with_ttl(dir, stream, owner, ttl)`,
`try_acquire(now_secs: f64) -> bool`, `heartbeat(now_secs: f64)`,
`is_held_by_other(now_secs: f64) -> bool`, `release()`. Constants:
`DRAIN_LEASE_TTL_SECS: f64 = 15.0`, `DRAIN_LEASE_HEARTBEAT_SECS: f64 = 5.0`,
`wall_now_secs() -> f64` (wall-clock helper for the heartbeat loop).

### `QueueLatencyWindow` and `QueueLatencyWindowBox`

Two related types that feed the `reportQueueStats` telemetry function (§ 3).
`QueueLatencyWindow` accumulates raw drain-latency samples for percentile
computation; `QueueLatencyWindowBox` wraps it in a `Mutex` so concurrent
drain calls on the same `QueueKit` instance share one box per estate stream
without corrupting the sample array.

**Swift:**

```swift
/// Rolling window of drain-latency samples. NOT synchronised itself —
/// access goes through QueueLatencyWindowBox.
public struct QueueLatencyWindow: Sendable {
    public init(capacity: Int = 100)
    /// Append a sample (ms), evicting the oldest when over capacity.
    public mutating func append(_ ms: Double)
    /// p-th percentile (0–100) of the current window.
    /// Returns 0 when empty or when `p` is out-of-range / non-finite.
    public func percentile(_ p: Double) -> Double
}

/// Thread-safe holder combining the latency window and emission throttle
/// under a single Mutex. The combined lock makes sample-and-check-throttle
/// one atomic operation, preventing a concurrent drain from racing between
/// shouldEmit == true and the subsequent gate update.
public final class QueueLatencyWindowBox: Sendable {
    public init(capacity: Int = 100)

    /// Append a latency sample and check the emission throttle atomically.
    ///
    /// The sample is ALWAYS appended so the rolling window accumulates every
    /// drain tick — aggregate p50/p95 reflects all ticks, not only the ones
    /// that fire an emission.
    ///
    /// - Parameters:
    ///   - ms: Drain latency in milliseconds.
    ///   - now: Caller-supplied epoch-seconds (never calls Date() internally).
    ///   - interval: Minimum seconds between Intellectus.report emissions.
    /// - Returns: `(p50, p95, shouldEmit)` — percentiles from the current
    ///   window plus a flag that is `true` at most once per `interval`.
    ///   When `shouldEmit` is `true`, `lastEmissionEpoch` is updated inside
    ///   the lock.
    public func sample(_ ms: Double, now: Double, interval: Double)
        -> (p50: Double, p95: Double, shouldEmit: Bool)
}
```

**Rust:** `QueueLatencyWindow` is `pub` in `src/facade.rs` (re-exported from
`lib.rs`). The Rust `QueueKit<B>` facade holds it as `Mutex<QueueLatencyWindow>`
directly — there is no separate `QueueLatencyWindowBox` type; thread safety is
internal to the facade. The `QueueLatencyWindowBox` is a **Swift-only** public
type (see § 7). Callers do not interact with either type directly on the Rust
side; telemetry is emitted inline by the Rust `drain` / `drain_for_stream`
methods.

### Backends: `FilesystemBackend`, `PersistenceKitBackend`

The two concrete backends (plus InMemory, which is
`PersistenceKitBackend` over in-memory `Storage`) (SPEC § 1, § 4, I-9).

**Swift:**

```swift
public final class FilesystemBackend: QueueBackend, @unchecked Sendable {
    public let root: URL
    public init(root: URL, hlcGenerator: HLCGenerator) throws
    // All-streams reclaim: resets every "cur/" file to "new/" on mount after a
    // crash. Not stream-scoped (maildir has one shared cur/). Called internally
    // by QueueKit.init(root:) to recover orphaned in-flight jobs.
    @discardableResult
    public func reclaimInFlight() async throws -> Int
}

public let queueKitTableName: String   // "queuekit_jobs"
public enum QueueKitSchema {
    public static let kitID: String
    public static let version: Int
    public static func declaration() -> SchemaDeclaration   // mutable table; never appendOnly
}
public final class PersistenceKitBackend: QueueBackend, @unchecked Sendable {
    public let storage: any Storage
    public init(storage: any Storage)
    public static func openSchema(on storage: any Storage) async throws
    // Inherent (not on QueueBackend): single-pass batch completion — retire every
    // cur job of one batch session in one update. SPEC B-4a. Interface: reply(session:).
    @discardableResult
    public func completeSession(_ session: SessionID, status: ObservationStatus) async throws -> Int
    // Stream-scoped reclaim: resets every "cur" row for stream back to "new".
    // Called via QueueKit.reclaimInFlight(stream:). Gate: DrainLease.tryAcquire
    // must have succeeded for stream before this is called.
    @discardableResult
    public func reclaimInFlight(stream: StreamID) async throws -> Int
}
```

**Rust:**

```rust
pub struct FilesystemBackend { /* ... */ }
impl FilesystemBackend { pub fn new(root: impl Into<PathBuf>, node_id: i32) -> Result<Self, QueueError>; }
// feature = "persistencekit": pub struct PersistenceKitBackend; (behaviour-conformant)
impl PersistenceKitBackend {
    // Inherent single-pass batch completion (SPEC B-4a) — O(N), not N×O(N).
    pub fn complete_session(&self, session: &SessionId, status: ObservationStatus)
        -> Result<usize, QueueError>;
}
```

## § 3 — Public functions

### The four operations + inspection reads (`QueueKit` Interface)

Behavioral contracts: SPEC § 5, B-1…B-5.

**Swift:**

```swift
extension QueueKit {
    public func send(_ job: Job) async throws                       // SPEC B-1
    /// Bulk twin of `send`: enqueues all jobs and fsyncs `new/` ONCE. Returns
    /// the count written. FilesystemBackend overrides for a single durability
    /// barrier; the default loops `send`. Rust twin: `QueueKit::send_batch`.
    @discardableResult
    public func send(batch jobs: [Job]) async throws -> Int
    public func drain() async throws -> [(job: Job, sessionID: SessionID)]   // SPEC B-2 (all streams)
    public func drain(stream: StreamID) async throws -> [(job: Job, sessionID: SessionID)]  // the recall-driven dreaming contract D7 — stream-scoped claim
    public func watch(handler: @escaping @Sendable (Job, SessionID) async throws -> Void) async throws  // SPEC B-3
    // watch() (FilesystemBackend + PersistenceKitBackend, both ports): drains
    // pre-existing jobs FIRST (before awaiting events), then on each wake drains
    // UNTIL EMPTY — not once per event. Draining-until-empty is load-robust: under
    // a burst the observer may coalesce inserts (fewer events than rows) or a wake
    // may be dropped while a serializable claim contends with concurrent inserts;
    // a once-per-event drain would strand the rows whose wake was coalesced away.
    public func reply(to jobID: JobID, status: ObservationStatus, artifacts: [ArtifactRef]) async throws // SPEC B-4
    @discardableResult
    public func reply(session: SessionID, status: ObservationStatus) async throws -> Int  // SPEC B-4a (single-pass batch completion)
    /// Batch twin of `reply(to:status:artifacts:)`: retires a list of jobs by id
    /// in one pass. FilesystemBackend overrides with one `cur/` scan and a single
    /// batched durability barrier. Returns the count completed. Used by corpus
    /// drain workers on backends without a session fast path. Rust twin:
    /// `QueueKit::reply_batch`.
    @discardableResult
    public func reply(batch completions: [(jobID: JobID, status: ObservationStatus)]) async throws -> Int
    public func inFlight() async throws -> [Job]                    // SPEC B-5
    public func pendingCount() async throws -> Int                  // depth probe (new/ frontier, all streams)
    public func pendingCount(stream: StreamID) async throws -> Int  // the recall-driven dreaming contract D7 — per-stream depth probe
    public func completed(streamID: StreamID? = nil) async throws -> [Job]   // SPEC B-5
    public func awaitDrain(pollInterval: Duration = .milliseconds(20),
                           timeout: Duration = .seconds(30)) async throws    // await-empty latch
    public func awaitDrain(stream: StreamID,
                           pollInterval: Duration = .milliseconds(20),
                           timeout: Duration = .seconds(30)) async throws    // stream-scoped twin
    /// Reset every stale in-flight ("cur") job for `stream` back to "new" so
    /// the next drain(stream:) re-claims them. Returns the count reclaimed.
    /// Gate: call ONLY immediately after DrainLease.tryAcquire succeeds for
    /// `stream` — the lease guarantees the prior drainer is dead. Delegates to
    /// PersistenceKitBackend.reclaimInFlight(stream:); returns 0 on other backends.
    /// Rust twin: `QueueKit::reclaim_in_flight_for_stream`.
    @discardableResult
    public func reclaimInFlight(stream: StreamID) async throws -> Int
}
```

`reply` rejects a non-terminal status with `invalidTerminalStatus`
before any storage mutation (SPEC § 4, I-7).

`reply(session:status:)` is the single-pass batch-completion twin of the
single-pass claim (SPEC I-3 / B-4a): it retires every still-`cur` job stamped
with one batch session in ONE update and returns the count completed — O(N)
instead of the O(N²) of N per-job `reply()` calls. It delegates to the
PersistenceKit backend's inherent `completeSession(_:status:)` (Rust
`complete_session`); on a backend without that fast path it returns `0`, and
the caller falls back to per-job `reply()`. It is the completion half of the
bulk-import path (the claim half is `drainAvailable`, which tags a whole drained
batch with one session). Non-terminal status is rejected as in `reply`.

`awaitDrain(pollInterval:timeout:)` is an await-empty latch: it blocks
until BOTH frontiers are clear — `pendingCount() == 0` (nothing waiting
in `new/`) AND `inFlight().isEmpty` (nothing claimed-but-unreplied in
`cur/`) — then returns. A job leaves both frontiers only after a consumer
has drained it and called `reply(...)` (moving it to `done/`), so the
latch releases only after every enqueued job has been fully processed.
It returns PROMPTLY on an already-empty queue (first poll returns without
sleeping) and never hangs. The `timeout` is a PROGRESS-BASED deadline,
not a total wall-clock cap: it resets each time the outstanding count
(pending + in-flight) drops below its lowest observed value, and
`QueueError.drainTimeout(pending:inFlight:)` is thrown only when no
progress is observed for `timeout`. A slow-but-progressing drain (e.g.
CPU-bound encode workers starved by a fully parallel test suite) never
false-times-out; a genuinely stuck worker still fails within `timeout`.
Tracking the lowest observed count — not the last — means concurrent
enqueues cannot extend the deadline; only real completions do. The
maildir backend has no native completion event, so the latch polls the
two depth probes on `pollInterval`; a concurrent drain worker's progress
is observed on the next poll. This is the signal bulk callers (importer,
gauntlet) use to know a batch of enqueued work has finished.

`awaitDrain(stream:pollInterval:timeout:)` is the stream-scoped twin
(the recall-driven dreaming contract Decision 7 / T1): on a shared per-estate queue a single drainer
processes only its own stream, so the barrier counts
`pendingCount(stream:)` plus the stream's slice of `inFlight()` and never
blocks on other streams' jobs (the post-T4/T6 encode-stall). Same
progress-based deadline, scoped to the stream's outstanding count.

Rust parity: the Rust `QueueKit<B>` facade exposes an identical method set:

```rust
impl<B: QueueBackend> QueueKit<B> {
    pub fn send(&self, job: &Job) -> Result<(), QueueError>
    pub fn send_batch(&self, jobs: &[Job]) -> Result<usize, QueueError>
    pub fn drain(&self, now_epoch_secs: f64) -> Result<Vec<(Job, SessionId)>, QueueError>
    pub fn drain_for_stream(&self, stream: &StreamId, now_epoch_secs: f64)
        -> Result<Vec<(Job, SessionId)>, QueueError>
    pub fn watch<F>(&self, handler: F) -> Result<(), QueueError>
        where F: Fn(Job, SessionId) -> Result<(), QueueError> + Send + Sync + 'static
    pub fn reply(&self, job_id: &JobId, status: ObservationStatus,
                 artifacts: Vec<ArtifactRef>) -> Result<(), QueueError>
    #[must_use = "a return of 0 means the caller must fall back to per-job reply"]
    pub fn reply_session(&self, session: &SessionId, status: ObservationStatus)
        -> Result<usize, QueueError>
    pub fn reply_batch(&self, completions: &[(JobId, ObservationStatus)])
        -> Result<usize, QueueError>
    pub fn in_flight(&self) -> Result<Vec<Job>, QueueError>
    pub fn pending_count(&self) -> Result<usize, QueueError>
    pub fn pending_count_for_stream(&self, stream: &StreamId) -> Result<usize, QueueError>
    pub fn completed(&self, stream_id: Option<&StreamId>) -> Result<Vec<Job>, QueueError>
    pub fn reclaim_in_flight_for_stream(&self, stream: &StreamId) -> Result<usize, QueueError>
    pub fn await_drain(&self, poll_interval: Duration, timeout: Duration) -> Result<(), QueueError>
    pub fn await_drain_for_stream(&self, stream: &StreamId,
        poll_interval: Duration, timeout: Duration) -> Result<(), QueueError>
}
```

The Rust `drain` and `drain_for_stream` take an explicit `now_epoch_secs: f64`
(wall-clock epoch seconds) for telemetry emission throttling; the Swift twin
reads `Date().timeIntervalSince1970` internally. This is a sanctioned signature
difference: in Rust the caller owns the clock value; in Swift the facade reads
it internally. The difference is noted in § 7.

`reclaim_in_flight_for_stream` delegates to `PersistenceKitBackend::reclaim_in_flight_for_stream`
when that backend is compiled in; returns `Ok(0)` for all other backends.
Gate requirement identical to Swift: call only after `DrainLease::try_acquire` succeeds.

### `QueueBackend` protocol methods

The contract the Interface delegates to (SPEC § 4). Backend method names
are `write`/`drainAvailable`/`watch`/`complete` (the Interface renames the
public verbs to send/drain/watch/reply).

**Swift:**

```swift
public protocol QueueBackend: Sendable {
    func write(_ job: Job) async throws
    // Default loops write; FilesystemBackend overrides with single-fsync bulk path.
    func writeBatch(_ jobs: [Job]) async throws -> Int
    func drainAvailable() async throws -> [(job: Job, sessionID: SessionID)]
    // Default delegates to drainAvailable() and filters; backends override for
    // true per-stream isolation (avoids cross-stream claiming in shared queues).
    func drainAvailable(stream: StreamID) async throws -> [(job: Job, sessionID: SessionID)]
    func pendingCount() async throws -> Int
    // Default delegates to pendingCount(); PK and Filesystem backends override.
    func pendingCount(stream: StreamID) async throws -> Int
    func watch(handler: @escaping @Sendable (Job, SessionID) async throws -> Void) async throws
    func complete(_ jobID: JobID, status: ObservationStatus, artifacts: [ArtifactRef]) async throws
    // Default loops complete; FilesystemBackend overrides with one-scan/one-fsync.
    func completeBatch(_ completions: [(jobID: JobID, status: ObservationStatus)]) async throws -> Int
    func inFlight() async throws -> [Job]
    func completed(streamID: StreamID?) async throws -> [Job]
}
```

**Rust:**

```rust
/// Boxed handler type for `watch` — keeps `QueueBackend` dyn-compatible.
pub type WatchHandler = Box<dyn Fn(Job, SessionId) -> Result<(), QueueError> + Send + Sync>;

pub trait QueueBackend: Send + Sync {
    fn write(&self, job: &Job) -> Result<(), QueueError>;
    // Default loops write; FilesystemBackend overrides with single-fsync bulk path.
    fn write_batch(&self, jobs: &[Job]) -> Result<usize, QueueError> { /* default */ }
    fn drain_available(&self) -> Result<Vec<(Job, SessionId)>, QueueError>;
    // Default delegates to drain_available() then filters; backends override.
    fn drain_available_for_stream(&self, stream: &StreamId)
        -> Result<Vec<(Job, SessionId)>, QueueError> { /* default */ }
    fn complete(&self, job_id: &JobId, status: ObservationStatus,
                artifacts: Vec<ArtifactRef>) -> Result<(), QueueError>;
    // Default loops complete; FilesystemBackend overrides with one-scan/one-fsync.
    fn complete_batch(&self, completions: &[(JobId, ObservationStatus)])
        -> Result<usize, QueueError> { /* default */ }
    fn in_flight(&self) -> Result<Vec<Job>, QueueError>;
    fn completed(&self, stream_id: Option<&StreamId>) -> Result<Vec<Job>, QueueError>;
    // Required, no default: a backend that forgets these must fail to COMPILE.
    fn pending_count(&self) -> Result<usize, QueueError>;
    fn pending_count_for_stream(&self, stream: &StreamId)
        -> Result<usize, QueueError> { /* default delegates to pending_count */ }
    fn watch(&self, handler: WatchHandler) -> Result<(), QueueError>;
    // Default impls: progress-based deadline poll loop (see § 3 QueueKit docs).
    fn await_drain(&self, poll_interval: Duration, timeout: Duration)
        -> Result<(), QueueError> { /* default */ }
    fn await_drain_for_stream(&self, stream: &StreamId,
        poll_interval: Duration, timeout: Duration) -> Result<(), QueueError> { /* default */ }
    // Downcast hook: lets the facade specialise on PersistenceKitBackend for the
    // session batch-completion fast path (mirrors Swift `backend as? PKBackend`).
    fn as_any(&self) -> &dyn Any;
}
```

**Python:** the same surface duck-typed and synchronous — `write(job)`,
`drain_available() -> list[tuple[Job, str]]`, `watch(handler)`,
`complete(job_id, status, artifacts)`, `in_flight()`,
`completed(stream_id)` — on the Filesystem backend only.

### `reportQueueStats` (telemetry free function)

A public top-level async function that emits `queue.*` metrics after each
drain call. Callers (e.g. GeniusLocusKit `StandingSignalScheduler`) call it
after every `drain(stream:)` invocation, passing the per-stream
`QueueLatencyWindowBox` maintained across drain calls.

**Swift:**

```swift
public func reportQueueStats(
    backend: any QueueBackend,
    drained: [(job: Job, sessionID: SessionID)],
    drainStart: Double,
    now: Double,
    estateTag: String,
    window: QueueLatencyWindowBox
) async
```

Off-path cost is a single `Atomic<Bool>` load + branch when monitoring is
disabled — effectively zero overhead. When enabled, `window.sample` is called
on every drain tick (always accumulating the latency window) but all
`Intellectus.report` calls are rate-limited to at most once per 30 seconds
per estate stream (`EMISSION_INTERVAL_S`), preventing the metric-table flood
observed in production (~6 M rows / 3 h at 100+ drains/sec).

Metrics emitted (namespace `queue.*`; tags `estate` and `kit = "QueueKit"`):

| Metric | Value |
|---|---|
| `queue.depth` | Pending count at emission time; omitted if `pendingCount()` fails — `queue.depth_unavailable` (value `1`) emitted instead to keep the failure observable without fabricating a false-zero depth |
| `queue.drain_count` | `drained.count` |
| `queue.idle_nonempty` | `1.0` when `depth > 0` and `drained.isEmpty`; `0.0` otherwise; omitted when depth is unknown |
| `queue.latency_p50_ms` | Median drain latency (ms) over the rolling window since last emission |
| `queue.latency_p95_ms` | 95th-percentile drain latency (ms) over the rolling window since last emission |
| `queue.head_of_line_age_s` | Age of the oldest drained job (seconds); `0.0` sentinel when `depth > 0` and drain returned nothing (job age is unknown without reading job records); omitted when depth is unknown and drain is also empty |

**Rust:** telemetry is emitted inline by the Rust `QueueKit<B>::drain` and
`drain_for_stream` methods — there is no separate `report_queue_stats` free
function in the Rust port. The emitted metrics and rate-limiting semantics are
equivalent; the factoring into a free function is Swift-only.

## § 4 — Errors

The error categories' meanings are in SPEC § 6; this is the shape.

**Swift:**

```swift
public enum QueueError: Error, Sendable {
    case directoryCreationFailed(path: String, underlying: Error)
    case writeFailed(underlying: Error)
    case renameFailed(from: String, to: String, underlying: Error)
    case decodingFailed(jobID: JobID, underlying: Error)
    case unknownTool(ToolName)
    case jobNotFound(JobID)
    case watcherFailed(underlying: Error)
    case staleTmpFile(path: String, age: TimeInterval)
    case backendUnavailable(detail: String)
    case invalidTerminalStatus(ObservationStatus)
    case drainTimeout(pending: Int, inFlight: Int)   // awaitDrain made no progress within its timeout
    /// A stream_id, job id, or other caller-supplied identifier contains a path
    /// separator (`/`, `\`), equals `.` or `..`, or contains an ASCII control
    /// character. Such identifiers can escape the queue root when used as
    /// filename components.
    case invalidIdentifier(id: String, reason: String)
}
```

`drainTimeout` is thrown by `awaitDrain(...)` when the outstanding count
has neither cleared nor decreased within the timeout (the progress-based
deadline, § 3); it carries the last-observed depths (a non-zero
`inFlight` points at a stalled drain worker, a non-zero `pending` at a
worker that never claimed). Rust carries the matching
`DrainTimeout { pending, in_flight }` variant.

**Rust:**

```rust
pub enum QueueError {
    DirectoryCreationFailed(String),
    WriteFailed(String),
    RenameFailed { from: String, to: String, msg: String },
    DecodingFailed(String),
    UnknownTool(String),
    JobNotFound(String),
    WatcherFailed(String),
    StaleTmpFile { path: String, age_secs: f64 },
    BackendUnavailable(String),
    InvalidTerminalStatus(String),
    DrainTimeout { pending: usize, in_flight: usize },
    /// Identifier contains a path separator, `.`, `..`, or an ASCII control
    /// character. Swift parity: `QueueError.invalidIdentifier(id:reason:)`.
    InvalidIdentifier(String),
}
```

The Rust enum carries all twelve categories one-to-one with the Swift
cases; it collapses each Swift associated `Error`/path value into a
single `String` message (and `ToolName`/`JobID`/`ObservationStatus`
payloads into their raw `String`), and renames the stale-tmp age field
to `age_secs` for clarity. Python raises a single `QueueError`
exception class carrying a message. The behavioural contract (SPEC § 6)
is identical across ports.

## § 5 — Conformance test entry points

**Swift:**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path packages/kits/QueueKit
```

(Targets: `QueueKitTests` — `ConformanceTests`, `FilesystemBackendTests`,
`PersistenceKitBackendTests`, `SupportingTypeTests`; fixtures under
`Tests/QueueKitTests/Fixtures/` are the byte-identity vectors of
SPEC C-7, generated by `FixtureGenerator`.)

**Rust:**

```
cargo test -p queuekit                             # default: filesystem + polling watch()
cargo test -p queuekit --features watch            # event-driven watch() via notify (optimization)
cargo test -p queuekit --features persistencekit   # behaviour-conformant backend
```

`--features watch` enables the event-driven `notify`-backed watch() on the Filesystem
backend. The default build's `watch()` uses a 200 ms polling loop (no external
dependency). Both feature states satisfy the same SPEC §5 B-3 contract; `--features watch`
is a latency optimization, not a correctness requirement.

**Python:**

```
python -m pytest packages/kits/QueueKit/python/tests
```

(`test_conformance.py` consumes the Swift-generated fixtures;
`test_filesystem_backend.py` exercises the lifecycle.)

## § 6 — Examples

```swift
import QueueKit
import SubstrateLib

// Filesystem backend at a queue root.
let q = try QueueKit(root: queueRoot, hlcGenerator: gen)

// Sender: encode a domain payload, submit, forget who runs it (SPEC I-1).
let job = Job(id: .generate(), streamID: StreamID(rawValue: "estate-7"),
              submittedAt: hlc, payload: encodedPayload)
try await q.send(job)

// Receiver: drain claims all available jobs in HLC order (SPEC B-2),
// then replies with a terminal observation (SPEC B-4).
for (job, _session) in try await q.drain() {
    let artifacts: [ArtifactRef] = [.commitHash(sha)]
    try await q.reply(to: job.id, status: .done, artifacts: artifacts)
}

// Long-running watcher (SPEC B-3): wakes, re-drains, handles in order.
try await q.watch { job, session in
    try await process(job, session)
    try await q.reply(to: job.id, status: .done, artifacts: [])
}
```

```swift
// PersistenceKit / InMemory backend (the GeniusLocusKit serial-lane shape).
try await PersistenceKitBackend.openSchema(on: storage)
let q2 = QueueKit(backend: PersistenceKitBackend(storage: storage))
```

---

## § 7 — Swift/Rust Concordance

Records the deliberate differences and sanctioned equivalences between the
Swift and Rust ports. The parity gate is functional behaviour, not syntax.

### `ToolName`

| Swift | Rust |
|---|---|
| `public struct ToolName: Sendable, Hashable, Codable, RawRepresentable { public let rawValue: String }` | `pub struct ToolName(pub String);` |
| `init(rawValue:)` | `ToolName::new(impl Into<String>)` |
| `rawValue` property | `raw_value() -> &str` method |
| Allowlist validation: not on the struct; callers validate at call sites | `validate(&[ToolName]) -> Result<(), QueueError>` method on the struct |

Both ports carry the same semantics: `ToolName` is a string wrapper for a
tool identifier; validation against a caller-supplied allowlist yields
`unknownTool` / `UnknownTool` on mismatch.

### `QueueKitSchema`

| Swift | Rust |
|---|---|
| `public enum QueueKitSchema` (caseless enum as namespace) | `pub struct QueueKitSchema` (unit struct as namespace) |
| `static let kitID = "QueueKit"` | `const KIT_ID: &'static str = "QueueKit"` |
| `static let version = 1` | `const VERSION: i32 = 1` |
| `static func declaration() -> SchemaDeclaration` | `fn declaration() -> SchemaDeclaration` |
| `public let queueKitTableName = "queuekit_jobs"` (module-level) | `pub const QUEUE_KIT_TABLE_NAME: &str = "queuekit_jobs"` (module-level) |

Schema shape is identical: same table name, same 12-column set, same 3
indices, `append_only = false` enforced in both ports.

### `PersistenceKitBackend`

| Swift | Rust |
|---|---|
| `public final class PersistenceKitBackend: QueueBackend, @unchecked Sendable` | `pub struct PersistenceKitBackend` implementing `QueueBackend` trait |
| `init(storage: any Storage)` | `new(storage: Arc<dyn Storage>)` |
| `static func openSchema(on storage: any Storage) async throws` | `fn open_schema(storage: &dyn Storage) -> Result<(), QueueError>` |
| All methods `async throws` (Swift actor concurrency) | All methods synchronous `Result` (Rust Storage trait is sync) |
| `storage.transaction(isolation: .serializable) { txn -> T in ... }` returns generic T | `storage.transaction(IsolationLevel::Serializable, &mut \|txn\| { ... })` captures results via environment |
| `storage.observer.observe(table:events:)` returns `AsyncStream<TableChange>` | `storage.observer().observe(table, events)` returns `mpsc::Receiver<TableChange>` |

Behavioural invariants are identical in both ports: write is a bare insert
(no enclosing transaction), drain uses a serializable atomic claim with a
`status="new"` guard, watch uses the observer as a wake signal and
re-reads through `drainAvailable()`, complete guards on `status="cur"`.

### `QueueError` variants

| Swift | Rust | Notes |
|---|---|---|
| `directoryCreationFailed(path:, underlying:)` | `DirectoryCreationFailed(String)` | Rust collapses path+error into one message |
| `writeFailed(underlying:)` | `WriteFailed(String)` | |
| `renameFailed(from:, to:, underlying:)` | `RenameFailed { from, to, msg }` | Struct variant matches Swift's associated-value shape |
| `decodingFailed(jobID:, underlying:)` | `DecodingFailed(String)` | |
| `unknownTool(ToolName)` | `UnknownTool(String)` | Rust carries the raw name string instead of a ToolName wrapper |
| `jobNotFound(JobID)` | `JobNotFound(String)` | Rust carries the raw ID string |
| `watcherFailed(underlying:)` | `WatcherFailed(String)` | |
| `staleTmpFile(path:, age:)` | `StaleTmpFile { path: String, age_secs: f64 }` | Swift's `age: TimeInterval` = f64 seconds; Rust field named `age_secs` for clarity |
| `backendUnavailable(detail:)` | `BackendUnavailable(String)` | |
| `invalidTerminalStatus(ObservationStatus)` | `InvalidTerminalStatus(String)` | Rust carries the raw status string |
| `invalidIdentifier(id:, reason:)` | `InvalidIdentifier(String)` | Rust collapses id+reason into one message |

### Identifier types: `JobId`/`JobID`, `StreamId`/`StreamID`, `SessionId`/`SessionID`

The `Id` vs `ID` suffix difference is a **sanctioned Rust-idiom non-gap**.
Swift uses `ID` (the conventional Apple/Swift uppercase acronym form);
Rust uses `Id` (the conventional Rust CamelCase form). No rename is
required or intended. This is recorded here as the canonical reference so
future agents do not re-open the question.

| Swift | Rust | Status |
|---|---|---|
| `JobID` | `JobId` | Sanctioned idiom difference — no rename |
| `StreamID` | `StreamId` | Sanctioned idiom difference — no rename |
| `SessionID` | `SessionId` | Sanctioned idiom difference — no rename |

### `Job` and `SignalFile`

| Swift | Rust | Notes |
|---|---|---|
| `public struct Job: Sendable, Codable, Identifiable, Hashable` | `pub struct Job` | Wire model for a queued unit of work. Fields: `id`/`id` (JobID/JobId), `streamID`/`stream_id` (StreamID/StreamId), `submittedAt`/`submitted_at` (HLC), `priority`/`priority` (Int/i32), `payload`/`payload` (Data/Vec<u8>), `extensions`/`extensions` ([String:CodableValue]/Map<String,CodableValue>). Serializes to canonical JSON (sorted keys, no whitespace). |
| `public struct SignalFile: Sendable, Codable` | `pub struct SignalFile` | Completion signal written to `done/`. Fields: `jobID`/`job_id`, `status`/`status` (ObservationStatus), `artifacts`/`artifacts` ([ArtifactRef]/Vec<ArtifactRef>), `completedAt`/`completed_at` (HLC). |

### `ArtifactRef`

| Swift | Rust | Notes |
|---|---|---|
| `public enum ArtifactRef: Sendable, Hashable, Codable` | `pub enum ArtifactRef` | Four cases: `filePath`/`FilePath`, `commitHash`/`CommitHash`, `signalFile`/`SignalFile`, `trajectoryStepID`/`TrajectoryStepId` (Swift `ID` / Rust `Id` — sanctioned idiom difference). Each wraps a single `String`. Wire encoding: `{"type": "...", "value": "..."}`. |

### `CodableValue`

| Swift | Rust | Notes |
|---|---|---|
| `public indirect enum CodableValue: Sendable, Codable, Hashable` | `pub type CodableValue = serde_json::Value` | Recursive JSON-compatible value type. Swift: closed enum cases `null`, `bool(Bool)`, `int(Int)`, `double(Double)`, `string(String)`, `array([CodableValue])`, `object([String:CodableValue])`. Rust: type alias for `serde_json::Value` (same structural shape; isomorphic). Both survive `send()`/`drain()` round-trip verbatim (SPEC § 6). The Swift declaration uses `indirect` because the enum is recursive; the audit regex does not match `public indirect enum` — this is an audit regex limitation, not a parity gap. |

### `QueueKit` facade

| Swift | Rust | Notes |
|---|---|---|
| `public final class QueueKit: Sendable` | `pub struct QueueKit<B: QueueBackend>` | Both wrap a backend behind the four permanent method names. |
| `drain() async throws -> [...]` | `drain(&self, now_epoch_secs: f64) -> Result<[...], QueueError>` | Rust takes `now_epoch_secs` explicitly for telemetry throttling; Swift reads `Date().timeIntervalSince1970` internally. Sanctioned difference. |
| `drain(stream:) async throws -> [...]` | `drain_for_stream(&self, stream, now_epoch_secs)` | Same `now_epoch_secs` difference as `drain`. |
| `estateTag: String` (stored property) | `set_estate_tag(&self, tag: &str)` | Swift: read-write stored property; Rust: mutating method (interior mutability via `Mutex<String>`). |
| `reply(session:status:) -> Int` | `reply_session(&self, session, status) -> Result<usize, QueueError>` annotated `#[must_use]` | Semantics identical; Rust marks it `must_use` to enforce the fallback check. |
| `reply(batch:) -> Int` | `reply_batch(&self, completions) -> Result<usize, QueueError>` | Job-list batch completion. Same semantics. |
| `reclaimInFlight(stream:) -> Int` | `reclaim_in_flight_for_stream(&self, stream) -> Result<usize, QueueError>` | Snake-case per Rust idiom. Same gate requirement (DrainLease). |

### `FilesystemBackend`

| Swift | Rust | Notes |
|---|---|---|
| `public final class FilesystemBackend: QueueBackend, @unchecked Sendable` | `pub struct FilesystemBackend` implementing `QueueBackend` trait | POSIX maildir backend. Swift: `init(root: URL, hlcGenerator: HLCGenerator) throws`. Rust: `new(root: impl Into<PathBuf>, node_id: i32) -> Result<Self, QueueError>`. Both implement the full `QueueBackend` surface (write/drain/watch/complete/pendingCount/cleanStaleTmp). Maildir structure (`tmp/`, `new/`, `cur/`, `done/`) is identical. |

### Python port `ToolName` coverage

The Python port (`packages/kits/QueueKit/python/`) has no `ToolName`
type and no allowlist validation. The Python port covers the Filesystem
backend only (SPEC § 7), and `ToolName` is a caller-validation concern
that falls outside the Filesystem byte-identity contract.

### Swift-only types (no Rust counterpart)

These types are present in the Swift port only. They are legitimately one-language: they depend on Apple-platform or orchestration-layer concepts that have no Rust equivalent in the current scope.

| Swift type | Source file | Reason for Swift-only |
|---|---|---|
| `MissionContext` | `Sources/QueueKit/Job.swift` | Carries Apple/CI worktree orchestration metadata (missionPath, worktree, branch, autonomyProfile, riskClass, baseCommit, priorTrajectoryID, inheritedSkills). This is a CI/dispatch layer concern embedded in the job extension field; the Rust port has no dispatch-layer concept and does not need to parse it. |
| `WireFormat` | `Sources/QueueKit/Job.swift` | Caseless-enum namespace for filename construction (`filename(for:)`, `sortableHLC(_:)`) and canonical JSON encoder/decoder. Rust provides equivalent free functions (`filename_for_job`, `sortable_hlc`, `encode_job`, `decode_job`) not as a namespace type; the audit regex does not match free functions by default. |
| `QueueLatencyWindowBox` | `Sources/QueueKit/QueueKitTelemetry.swift` | Thread-safe holder combining `QueueLatencyWindow` and the emission throttle under a single `Mutex`, preventing sample-array corruption from concurrent drain calls. The Rust `QueueKit<B>` facade achieves the same thread safety by holding `Mutex<QueueLatencyWindow>` directly — there is no equivalent public box type. See § 2 for the full type entry and `sample(_:now:interval:)` signature. |

### Types present in both Swift and Rust

These types have peers in both ports; they are listed here to record the concordance.

| Swift type | Rust type | Notes |
|---|---|---|
| `QueueLatencyWindow` | `pub struct QueueLatencyWindow` (`rust/src/facade.rs`) | Rolling latency-sample window for drain percentile telemetry. Concurrent drainers are legitimate, so access is lock-guarded: Swift wraps it in a `QueueLatencyWindowBox`; Rust holds `Mutex<QueueLatencyWindow>` on the facade. Both are `pub` re-exports. |
| `DrainLease` | `pub struct DrainLease` (`rust/src/drain_lease.rs`) | Stream-keyed heartbeat-TTL drain lease. TTL, heartbeat interval, and file format are identical across ports (byte-compatible lease file). Swift uses `Date` for `now`; Rust takes `now_secs: f64` directly from the caller. |

---

*End of QueueKit Interface.*

## Changelog

### 1.5.1 -- 2026-07-16
Closed two critical INTERFACE gaps identified by the post-1.5.0 verifier pass:

- **`QueueLatencyWindow` and `QueueLatencyWindowBox`** (§ 2): added full type
  entries for both public types in `QueueKitTelemetry.swift`. `QueueLatencyWindow`
  was previously visible only in the § 7 concordance table footnote.
  `QueueLatencyWindowBox` was mentioned only parenthetically ("Swift wraps it
  in a `QueueLatencyWindowBox`") with no type entry and no documentation of its
  public `sample(_:now:interval:)` method. Both entries now include Swift
  signatures and Rust parity notes. `QueueLatencyWindowBox` added to the
  Swift-only types table in § 7.
- **`reportQueueStats`** (§ 3): added the full public top-level async function
  entry, including its parameter list, the 30-second emission rate-limit
  rationale, the complete `queue.*` metric table with depth-unavailable sentinel
  semantics, and the note that Rust emits equivalent telemetry inline in
  `drain`/`drain_for_stream` with no separate free function.

### 1.5.0 -- 2026-07-16
Full audit against shipped source. Corrections and additions:

- **Rust has a `QueueKit<B>` facade** (§ 2, § 3, § 7): corrected the wrong claim
  that "there is no separate Interface wrapper"; the Rust leg has `pub struct
  QueueKit<B: QueueBackend>` in `src/facade.rs`, mirroring the Swift class.
  Added Rust facade method signatures and the `drain`/`drain_for_stream`
  `now_epoch_secs` parameter difference to § 7.
- **New Swift methods** (§ 3): `send(batch:)`, `reply(batch:)`,
  `reclaimInFlight(stream:)`, and `estateTag` stored property were missing.
- **New `DrainLease` type block** (§ 2): `DrainLease` (both ports) was documented
  only in the changelog; added a full type entry.
- **Backend methods** (§ 2): `FilesystemBackend.reclaimInFlight()` and
  `PersistenceKitBackend.reclaimInFlight(stream:)` were missing.
- **`QueueBackend` protocol/trait** (§ 3): added missing `writeBatch`/
  `write_batch`, `completeBatch`/`complete_batch`, `drainAvailable(stream:)`/
  `drain_available_for_stream`, `pendingCount(stream:)`/`pending_count_for_stream`,
  `await_drain`/`await_drain_for_stream` (Rust trait defaults), `as_any` (Rust
  required). Fixed the Rust `watch` signature (`WatchHandler` boxed closure, not
  a generic type parameter — the boxed form keeps the trait `dyn`-compatible).
- **`QueueError`** (§ 4, § 7): added `invalidIdentifier(id:reason:)` / `InvalidIdentifier`
  (twelfth category, both ports); corrected "eleven" to "twelve".
- **§ 1 Rust layout**: added `src/facade.rs` and `src/drain_lease.rs`.
- **§ 7 concordance**: removed `QueueLatencyWindow` from the "Swift-only" table
  (it is `pub` in both ports); added a "Types present in both ports" table covering
  `QueueLatencyWindow` and `DrainLease`; added the `QueueKit` facade concordance
  table.

### 1.4.0 -- 2026-07-03
`awaitDrain` / `await_drain` (global and stream-scoped, both ports) now use a
PROGRESS-BASED deadline: `timeout` bounds the wait without observed progress
(the outstanding pending + in-flight count dropping below its lowest observed
value resets the deadline), not the total wall-clock wait. Fixes the GLK
full-suite drainTimeout fragility — CPU-starved encode workers draining slowly
but steadily blew the 30 s wall-clock cap under suite-wide core saturation
while the same drain finished in seconds isolated; a genuinely stuck worker
still fails within `timeout`. Also brought the doc up to shipped reality:
listed `awaitDrain(stream:pollInterval:timeout:)` in the Interface surface,
and corrected the stale Rust-parity notes (Rust has carried
`await_drain`/`await_drain_for_stream` and the `DrainTimeout` error variant
since the Dual-Path Intake wiring; the enum is eleven categories).
Also fixed a Swift-only telemetry data race: the drain-latency window was an
unguarded `nonisolated(unsafe) var` on `QueueKit` under a stale
single-drainer assumption; concurrent stream drainers (encode + import on
the shared per-estate queue) corrupted its sample array (SIGSEGV in
`Array.append`). Now lock-guarded via `QueueLatencyWindowBox`
(`reportQueueStats`'s `window` parameter changed from
`inout QueueLatencyWindow` to the box), matching the Rust facade's
always-guarded `Mutex<QueueLatencyWindow>`.

### 1.3.1 -- 2026-06-25
Additive `DrainLease` (the recall-driven dreaming contract Decision 7, T2): a stream-keyed heartbeat-TTL
drain lease (Swift `DrainLease` / Rust `drain_lease::DrainLease`) so multiple
consumers sharing one per-estate queue each hold an independent
per-(estate, stream) lease (`<dir>/<stream>.drain.lease`) — exactly one drainer
per stream, while different streams hold leases concurrently. TTL 15 s,
heartbeat 5 s; `now` injected for deterministic tests; atomic temp+rename write
with write-then-re-read race resolution. Filesystem form (SQLite-first); the
Postgres-estate DB-backed lease is deferred. Consumers rewire onto it in T4/T5.

### 1.3.0 -- 2026-06-25
Additive stream-scoped drain (the recall-driven dreaming contract Decision 7, T1). Interface gains
`drain(stream:)` and `pendingCount(stream:)`; the `QueueBackend` protocol/trait
gains `drainAvailable(stream:)`/`pendingCount(stream:)` (Rust:
`drain_available_for_stream`/`pending_count_for_stream`) with defaults that
delegate to the all-streams versions (single-stream back-compat). PK overrides
use the `(stream_id, status)` index; Filesystem overrides decode each `new/`
file in place and claim only matching-stream files (never touching other
streams, so concurrent per-stream drainers don't collide). Lets many consumers
share one per-estate queue. No byte-identity change.

### 1.2.0 -- 2026-06-25
Additive (T6 — drain status): `QueueKit.pendingCount() -> Int` (Swift) /
`pending_count() -> usize` (Rust) — a public passthrough to the backend's
`pendingCount`, mirroring the existing public `inFlight()` probe. Lets a status
reader observe queue depth (`pendingCount() + inFlight().count` = total
outstanding work) without claiming or draining. No change to the `QueueBackend`
protocol/trait (which already carried `pendingCount`), the backends, or
byte-identity.

### 1.1.0 -- 2026-06-23
Added the single-pass batch-completion surface (SPEC B-4a): `QueueKit.reply(session:status:) -> Int` on the Interface and the inherent `PersistenceKitBackend.completeSession(_:status:)` / `complete_session` it delegates to. Documented that `drainAvailable` now claims single-pass (one bulk update under one batch session; SPEC I-3) so a drained batch shares one session and can be completed in one update. PersistenceKit-backend optimization; no change to the `QueueBackend` protocol/trait, the Filesystem backend, or byte-identity.

### 1.0.2 -- 2026-06-17
Rust `QueueBackend` brought to Swift parity on compile-enforcement: `pending_count` and `watch` are now required trait methods with NO default (a backend that forgets either fails to COMPILE, not at runtime). Replaced the stale "Default impl returns BackendUnavailable" trait-excerpt comment and listed `pending_count` in the excerpt. No behaviour change for either production backend (FilesystemBackend, PersistenceKitBackend already implement both); no signature change.

### 1.0.1 -- 2026-06-15
Completed Swift/Rust concordance table: added rows for `Job`, `SignalFile`, `ArtifactRef`, `CodableValue`, `FilesystemBackend`; documented `MissionContext`, `WireFormat`, and `QueueLatencyWindow` as Swift-only with justification.

### 1.0.0 -- 2026-06-14
Established under VERSIONING.md: version number removed from the filename; front matter normalized; baselined at 1.0.0.
