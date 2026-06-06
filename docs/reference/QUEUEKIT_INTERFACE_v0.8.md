---
status: draft
authors: Bob Pankratz (via/ claude)
date: 2026-05-27
version: v0.8
package: QueueKit
languages: [swift, rust, python]
relates_to:
  - QUEUEKIT_SPEC_v0.8.md  (the contract this interface implements)
  - QUEUE_PROTOCOL_SPEC_v0.8.md  (the wire/on-disk format these types serialize to)
purpose: |
  Public API surface of QueueKit: the QueueKit facade and its four
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

- `Sources/QueueKit/QueueKit.swift` — the `QueueKit` facade
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

### `QueueKit` (facade)

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
`PersistenceKitBackend`); there is no separate facade wrapper. Callers
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
minted by the backend at claim time per claimed job; `StreamID` is
URL-safe, ≤ 64 chars; `ToolName` names a tool for allowlist validation
(SPEC § 9 open question).

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
`pub struct SessionId(pub String);` (no `ToolName` in the Rust version —
allowlist validation is unimplemented, SPEC § 9).

### `ObservationStatus`

The job outcome; raw values match the signal-file `status` field
exactly (SPEC § 4, I-7; `QUEUE_PROTOCOL_SPEC_v0.8.md`).

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
for byte-identity (SPEC § 7, C-7; format canon in
`QUEUE_PROTOCOL_SPEC_v0.8.md`).

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

An optional caller-side payload type (Forge's mission descriptor)
encoded into `Job.payload`; QueueKit treats it as opaque bytes (SPEC
§ 4, I-5). General callers define their own payload type instead.

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
}
```

**Rust:**

```rust
pub struct FilesystemBackend { /* ... */ }
impl FilesystemBackend { pub fn new(root: impl Into<PathBuf>, node_id: i32) -> Result<Self, QueueError>; }
// feature = "persistencekit": pub struct PersistenceKitBackend; (behaviour-conformant)
```

## § 3 — Public functions

### The four operations + inspection reads (`QueueKit` facade)

Behavioral contracts: SPEC § 5, B-1…B-5.

**Swift:**

```swift
extension QueueKit {
    public func send(_ job: Job) async throws                       // SPEC B-1
    public func drain() async throws -> [(job: Job, sessionID: SessionID)]   // SPEC B-2
    public func watch(handler: @escaping @Sendable (Job, SessionID) async throws -> Void) async throws  // SPEC B-3
    public func reply(to jobID: JobID, status: ObservationStatus, artifacts: [ArtifactRef]) async throws // SPEC B-4
    public func inFlight() async throws -> [Job]                    // SPEC B-5
    public func completed(streamID: StreamID? = nil) async throws -> [Job]   // SPEC B-5
}
```

`reply` rejects a non-terminal status with `invalidTerminalStatus`
before any storage mutation (SPEC § 4, I-7).

### `QueueBackend` protocol methods

The contract the facade delegates to (SPEC § 4). Backend method names
are `write`/`drainAvailable`/`watch`/`complete` (the facade renames the
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
    // Default impl returns BackendUnavailable; conforming backends override.
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
}
```

**Rust:**

```rust
pub enum QueueError {
    DirectoryCreationFailed(String),
    WriteFailed(String),
    RenameFailed { from: String, to: String, msg: String },
    DecodingFailed(String),
    JobNotFound(String),
    WatcherFailed(String),
    BackendUnavailable(String),
    InvalidTerminalStatus(String),
}
```

The Rust enum collapses the Swift `unknownTool` and `staleTmpFile`
cases (neither is raised by the shipped Rust Filesystem backend);
otherwise the categories correspond one-to-one. Python raises a single
`QueueError` exception class carrying a message. The behavioural
contract (SPEC § 6) is identical across ports.

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
cargo test -p queuekit
cargo test -p queuekit --features persistencekit   # behaviour-conformant backend
```

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

### Python port follow-up

The Python port (`packages/kits/QueueKit/python/`) currently has no
`ToolName` type and no allowlist validation. This is a known gap; the
Python port covers the Filesystem backend only (SPEC § 7) and `ToolName`
is a caller-validation concern that falls outside the Filesystem
byte-identity contract. A follow-up mission should add `ToolName` to the
Python port for completeness, but it is out of scope for PAR-4-QK /
PAR-6-QK which targets Swift↔Rust parity only.

### Concordance table — full public surface

One row per public concept. Swift and Rust symbols are each a real
declaration cited by `file:line`. "Shape rule" states how the two ports
are allowed to differ; "Test/vector binding" names the actual
conformance/parity test that proves Swift==Rust; "Status" is Confirmed
(both present + test-bound), Exempt (Apple platform binding, no Rust
counterpart by design), or DRIFT (public type with no sanctioned
counterpart).

| Concept | Swift symbol | Rust symbol | Visibility | Shape rule | Test/vector binding | Status |
|---|---|---|---|---|---|---|
| `Job` | `Job` (`Sources/QueueKit/Job.swift:167`) | `Job` (`rust/src/job.rs:130`) | both `public`/`pub` | identical (field-for-field; `priority` Int↔i32, `payload` Data↔Vec<u8>, `extensions` map of `CodableValue`) | Rust `conformance.rs::job_byte_identical`; Swift `SupportingTypeTests.swift::jobJSONRoundTrip` (shared Fixtures vectors) | Confirmed |
| `JobID` / `JobId` | `JobID` (`Sources/QueueKit/Job.swift:22`) | `JobId` (`rust/src/job.rs:18`) | both public/pub | `ID`/`Id` sanctioned idiom; Swift RawRepresentable struct / Rust newtype | Swift `IdentifierTypeTests.swift::jobIDIs32LowercaseHex`; Rust `conformance.rs::job_byte_identical` (id round-trips in wire fixture) | Confirmed |
| `StreamID` / `StreamId` | `StreamID` (`Sources/QueueKit/Job.swift:51`) | `StreamId` (`rust/src/job.rs:22`) | both public/pub | `ID`/`Id` sanctioned idiom | Rust `parity.rs::completed_filter_by_stream_id`; Swift `ConformanceTests.swift::area1Schema` | Confirmed |
| `SessionID` / `SessionId` | `SessionID` (`Sources/QueueKit/Job.swift:68`) | `SessionId` (`rust/src/job.rs:26`) | both public/pub | `ID`/`Id` sanctioned idiom; `mint()` minted at claim time both ports | Rust `parity.rs::write_and_drain` (session minted on claim); Swift `ConformanceTests.swift::area1Schema` | Confirmed |
| `ToolName` | `ToolName` (`Sources/QueueKit/Job.swift:80`) | `ToolName` (`rust/src/job.rs:35`) | both public/pub | Swift RawRepresentable struct, validation at call sites / Rust newtype with `validate(&[ToolName])` method (idiom placement of allowlist check) | Rust `parity.rs::tool_name_round_trip`, `tool_name_validate_found`, `tool_name_validate_not_found_returns_unknown_tool` | Confirmed |
| `ObservationStatus` | `ObservationStatus` (`Sources/QueueKit/ObservationStatus.swift:9`) | `ObservationStatus` (`rust/src/job.rs:63`) | both public/pub | identical; Swift String-raw enum / Rust enum + `raw()`/`from_raw()`/`is_terminal()` (raw values match exactly) | Swift `SupportingTypeTests.swift::observationStatusRawValues`, `observationStatusTerminalDiscrimination`; Rust `conformance.rs::signal_byte_identical` | Confirmed |
| `ArtifactRef` | `ArtifactRef` (`Sources/QueueKit/Job.swift:85`) | `ArtifactRef` (`rust/src/job.rs:99`) | both public/pub | identical; Swift assoc-value enum / Rust enum + `type_tag()`/`value()`; serialized `{type,value}` byte-identical | Swift `SupportingTypeTests.swift::artifactRefRoundTrip`; Rust `conformance.rs::signal_byte_identical` (artifact array in fixture) | Confirmed |
| `SignalFile` | `SignalFile` (`Sources/QueueKit/Job.swift:321`) | `SignalFile` (`rust/src/job.rs:140`) | both public/pub | identical (`jobID`/`job_id`, `completedAt`/`completed_at` snake-case idiom) | Rust `conformance.rs::signal_byte_identical`; Swift `SupportingTypeTests.swift::signalFileJSONShape` / `ConformanceTests.swift::area3SignalCorrectness` | Confirmed |
| `CodableValue` | `CodableValue` (`Sources/QueueKit/Job.swift:131`) | `CodableValue` (`rust/src/job.rs:127`) | both public/pub | Swift `indirect enum` (null/bool/int/double/string/array/object) / Rust `type CodableValue = serde_json::Value` (type alias) — sanctioned representation difference; both round-trip `Job.extensions` verbatim and byte-identically | Swift `ConformanceTests.swift::area5Extensions`; Rust `parity.rs::extensions_round_trip` | Confirmed |
| `WireFormat` | `WireFormat` (`Sources/QueueKit/Job.swift:287`) | none — free functions `filename_for_job`/`sortable_hlc`/`encode_job`/`encode_signal`/`decode_job` (`rust/src/job.rs:237,229,288,302,318`) | Swift `public` caseless-enum namespace / Rust `pub fn` crate-root free functions | sanctioned: Swift groups the canonical encoder under a namespace enum; Rust exposes the identical operations as free functions (no namespace type). Byte-identity contract is the same. | Rust `conformance.rs::filename_byte_identical`, `job_byte_identical`; Swift `SupportingTypeTests.swift::filenameMatchesSpecExample`, `sortableHLCFormat`, `jobJSONRoundTrip` | Confirmed |
| `QueueKit` (facade) | `QueueKit` (`Sources/QueueKit/QueueKit.swift:31`) | none — Rust callers hold `Box<dyn QueueBackend>` directly (`rust/src/backend.rs:6`) | Swift `public final class` / Rust: no facade type | sanctioned: Swift adds a facade that mounts one backend and renames verbs (send/drain/watch/reply); Rust calls the `QueueBackend` trait methods directly. Behaviour identical; the facade is a Swift-side ergonomic shell over the same backend contract. | Rust `parity.rs::write_and_drain`, `complete_moves_to_done` (exercise the backend the facade wraps); Swift `ConformanceTests.swift::area2Transitions` | Confirmed |
| `QueueBackend` | `QueueBackend` (`Sources/QueueKit/QueueBackend.swift:9`) | `QueueBackend` (`rust/src/backend.rs:6`) | Swift `public protocol` / Rust `pub trait` | Swift `async throws` / Rust sync `Result` (no async runtime — sanctioned, cf. NeuronKit policy-store seam); method verbs `write`/`drainAvailable`/`complete`/`inFlight`/`completed`/`watch` identical | Rust `parity.rs::write_and_drain`, `drain_hlc_order`, `complete_rejects_non_terminal_status`; Swift `ConformanceTests.swift::area2Transitions` | Confirmed |
| `FilesystemBackend` | `FilesystemBackend` (`Sources/QueueKit/FilesystemBackend.swift:44`) | `FilesystemBackend` (`rust/src/filesystem.rs:22`) | both public/pub | identical contract; Swift `init(root:hlcGenerator:)` / Rust `new(root, node_id)`; both produce byte-identical maildir files | Rust `conformance.rs::area4_concurrent_claim_filesystem`; Swift `FilesystemBackendTests.swift`, `ConformanceTests.swift::area4ConcurrentClaimFilesystem` | Confirmed |
| `PersistenceKitBackend` | `PersistenceKitBackend` (`Sources/QueueKit/PersistenceKitBackend.swift:85`) | `PersistenceKitBackend` (`rust/src/persistencekit.rs:151`) | both public/pub | identical behaviour; Swift `async throws` / Rust sync `Result` (Storage trait is sync — sanctioned async/sync seam); serializable atomic claim both ports | Rust `parity.rs::write_and_drain`, `drain_is_empty_after_claiming`, `in_flight_returns_cur_jobs`; Swift `PersistenceKitBackendTests.swift` | Confirmed |
| `QueueKitSchema` | `QueueKitSchema` (`Sources/QueueKit/PersistenceKitBackend.swift:37`) | `QueueKitSchema` (`rust/src/persistencekit.rs:63`) | both public/pub | Swift caseless-enum namespace / Rust unit struct namespace; same `kitID`/`version`/`declaration()`, same `queueKitTableName` constant, 12 columns, 3 indices, `append_only=false` | Rust `parity.rs::schema_kit_id_and_version`, `schema_table_name_constant`, `schema_declaration_has_required_columns`, `schema_declaration_has_three_indices`; Swift `ConformanceTests.swift::area1Schema` | Confirmed |
| `QueueError` | `QueueError` (`Sources/QueueKit/QueueError.swift:7`) | `QueueError` (`rust/src/error.rs:14`) | both public/pub | category-equivalent; Rust collapses associated `Error`/path into a `String` message and folds `unknownTool`/`staleTmpFile` (not raised by the shipped Rust Filesystem backend); behavioural categories one-to-one | Rust `parity.rs::stale_tmp_file_error_carries_path_and_age`, `complete_rejects_non_terminal_status`, `complete_job_not_found`; Swift `ConformanceTests.swift::area2Transitions`, `area6StaleTmpRecovery` | Confirmed |
| `MissionContext` | `MissionContext` (`Sources/QueueKit/Job.swift:254`) | none (no Rust or Python counterpart) | Swift `public struct` / no Rust symbol | NOT a platform binding — caller-domain convenience (Forge mission descriptor) encoded into the opaque `Job.payload`; QueueKit treats payload as opaque bytes (SPEC § 4, I-5). Per the force-mirror standard, "Swift-only by design" is not a waiver for a plain domain struct. | none (no parity test — no Rust counterpart to bind against) | DRIFT |

---

*End of QueueKit Interface v0.8.*
