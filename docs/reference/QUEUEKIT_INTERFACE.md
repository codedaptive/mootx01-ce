---
status: active
authors: MOOTx01 maintainers
date: 2026-07-03
version: 1.4.0
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
- `src/backend.rs` — `QueueBackend` trait
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

**Rust:** the crate exposes the backends directly (`FilesystemBackend`,
`PersistenceKitBackend`); there is no separate Interface wrapper. Callers
hold a `Box<dyn QueueBackend>` and call the trait methods of § 3.

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

### Backends: `FilesystemBackend`, `PersistenceKitBackend`

The two concrete backends (plus InMemory, which is
`PersistenceKitBackend` over in-memory `Storage`) (SPEC § 1, § 4, I-9).

**Swift:**

```swift
public final class FilesystemBackend: QueueBackend, @unchecked Sendable {
    public let root: URL
    public init(root: URL, hlcGenerator: HLCGenerator) throws
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
    public func drain() async throws -> [(job: Job, sessionID: SessionID)]   // SPEC B-2 (all streams)
    public func drain(stream: StreamID) async throws -> [(job: Job, sessionID: SessionID)]  // ADR-021 D7 — stream-scoped claim
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
    public func inFlight() async throws -> [Job]                    // SPEC B-5
    public func pendingCount() async throws -> Int                  // depth probe (new/ frontier, all streams)
    public func pendingCount(stream: StreamID) async throws -> Int  // ADR-021 D7 — per-stream depth probe
    public func completed(streamID: StreamID? = nil) async throws -> [Job]   // SPEC B-5
    public func awaitDrain(pollInterval: Duration = .milliseconds(20),
                           timeout: Duration = .seconds(30)) async throws    // await-empty latch
    public func awaitDrain(stream: StreamID,
                           pollInterval: Duration = .milliseconds(20),
                           timeout: Duration = .seconds(30)) async throws    // stream-scoped twin (ADR-021 D7)
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
(ADR-021 Decision 7 / T1): on a shared per-estate queue a single drainer
processes only its own stream, so the barrier counts
`pendingCount(stream:)` plus the stream's slice of `inFlight()` and never
blocks on other streams' jobs (the post-T4/T6 encode-stall). Same
progress-based deadline, scoped to the stream's outstanding count.

Rust parity: `QueueBackend::await_drain` / `await_drain_for_stream`
(trait default impls surfaced on the `QueueKit` facade) implement the
identical contract, including the progress-based deadline.

### `QueueBackend` protocol methods

The contract the Interface delegates to (SPEC § 4). Backend method names
are `write`/`drainAvailable`/`watch`/`complete` (the Interface renames the
public verbs to send/drain/watch/reply).

**Swift:**

```swift
public protocol QueueBackend: Sendable {
    func write(_ job: Job) async throws
    func drainAvailable() async throws -> [(job: Job, sessionID: SessionID)]
    func watch(handler: @escaping @Sendable (Job, SessionID) async throws -> Void) async throws
    func complete(_ jobID: JobID, status: ObservationStatus, artifacts: [ArtifactRef]) async throws
    func inFlight() async throws -> [Job]
    func completed(streamID: StreamID?) async throws -> [Job]
}
```

**Rust:**

```rust
pub trait QueueBackend: Send + Sync {
    fn write(&self, job: &Job) -> Result<(), QueueError>;
    fn drain_available(&self) -> Result<Vec<(Job, SessionId)>, QueueError>;
    fn complete(&self, job_id: &JobId, status: ObservationStatus,
                artifacts: Vec<ArtifactRef>) -> Result<(), QueueError>;
    fn in_flight(&self) -> Result<Vec<Job>, QueueError>;
    fn completed(&self, stream_id: Option<&StreamId>) -> Result<Vec<Job>, QueueError>;
    // Required, no default: a backend that forgets pending_count / watch must
    // fail to COMPILE, not at runtime (SDK compile-enforcement ruling). Mirrors
    // the Swift protocol, where both are bare requirements.
    fn pending_count(&self) -> Result<usize, QueueError>;
    fn watch<F>(&self, handler: F) -> Result<(), QueueError>
    where F: Fn(Job, SessionId) -> Result<(), QueueError> + Send + Sync;
}
```

**Python:** the same surface duck-typed and synchronous — `write(job)`,
`drain_available() -> list[tuple[Job, str]]`, `watch(handler)`,
`complete(job_id, status, artifacts)`, `in_flight()`,
`completed(stream_id)` — on the Filesystem backend only.

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
}
```

The Rust enum carries all eleven categories one-to-one with the Swift
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
| `QueueLatencyWindow` | `Sources/QueueKit/QueueKitTelemetry.swift` / `rust/src/facade.rs` | Rolling latency-sample window for percentile telemetry, in both ports. Concurrent drainers on one queue are legitimate, so access is lock-guarded: Swift wraps it in `QueueLatencyWindowBox` (a `Mutex`-guarded box passed to `reportQueueStats`), Rust holds `Mutex<QueueLatencyWindow>` on the facade. |

---

*End of QueueKit Interface.*

## Changelog

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
Additive `DrainLease` (ADR-021 Decision 7, T2): a stream-keyed heartbeat-TTL
drain lease (Swift `DrainLease` / Rust `drain_lease::DrainLease`) so multiple
consumers sharing one per-estate queue each hold an independent
per-(estate, stream) lease (`<dir>/<stream>.drain.lease`) — exactly one drainer
per stream, while different streams hold leases concurrently. TTL 15 s,
heartbeat 5 s; `now` injected for deterministic tests; atomic temp+rename write
with write-then-re-read race resolution. Filesystem form (SQLite-first); the
Postgres-estate DB-backed lease is deferred. Consumers rewire onto it in T4/T5.

### 1.3.0 -- 2026-06-25
Additive stream-scoped drain (ADR-021 Decision 7, T1). Interface gains
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
