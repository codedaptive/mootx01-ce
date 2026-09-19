import AriaMCPWire

import Foundation
import CognitionKit
import ContextDistillLib
import EideticLib
import GeniusLocusKit
import GeniusLocusKitMigrations
import LatticeLib
import LocusKit
import SubstrateML
import VaultKit
// Scoped imports: pull ONLY the lifecycle-cluster classifier from
// SubstrateTypes. A blanket `import SubstrateTypes` collides with LocusKit
// on `LatticeAnchor.udc` (both modules export `LatticeAnchor`), so we import
// just the two enums the fact-timeline tag needs.
import enum SubstrateTypes.RowState
import enum SubstrateTypes.RowStateCluster
// C3/A6 timing derivation: scoped imports for the same LatticeAnchor-collision
// reason as above — the tool needs only the pure engine and its input tuple,
// plus the HLC cursor type for audit paging.
import struct SubstrateTypes.HLC
import struct NeuronKit.TimingAuditEvent
import func NeuronKit.deriveTimings

private struct DispatcherV2MemoryUsageLedger: AriaV2MemoryUsageLedger {
    let surfaced: SurfacedRecallLedger
    let kit: GeniusLocusKit
    let handle: EstateHandle
    let posture: EstatePosture

    func recordSurfaced(_ memoryIDs: [UUID], estateID: UUID, callerID: String, at: Date) async {
        _ = (estateID, callerID)
        await surfaced.recordSurfaced(
            memoryIDs.map(AriaV2ArgumentDecoder.canonicalUUID),
            at: at
        )
    }

    /// Mark a surfaced row as USED, so the dreaming daemon's reward sweep
    /// assigns reward 1.0 to that drawer's trace rows
    /// (DESIGN_TRACE_REWARD_2026-06-12).
    ///
    /// GeniusLocusKit supplies `markRecallUsed`; it does not call it. The
    /// caller has always been this layer — a search records what it surfaced,
    /// and a later dereference verb reports that the caller acted on it.
    /// Without this call the reward signal is permanently zero and every
    /// consumer of it — the dreaming reward sweep, Bradley-Terry, the solver
    /// bandit — learns from an empty channel.
    ///
    /// Four conditions, each load-bearing and each inherited from the v1 path:
    ///
    ///   1. LIVE POSTURE ONLY. The ledger still records what a search surfaced,
    ///      because that is session memory rather than estate state, but the
    ///      reward mark is a persistent write and a frozen estate takes none.
    ///   2. SURFACED IN THIS SESSION. An id the caller already knew is not a
    ///      recall the estate helped with, so it earns no reward.
    ///   3. BOTH STORAGE SPELLINGS. `markRecallUsed` matches trace rows by the
    ///      stored drawer id, and the two portable estate writers disagree on
    ///      UUID case. The ledger holds canonical lowercase; the estate may
    ///      hold either.
    ///   4. A FRESH WALL CLOCK, deliberately later than the dispatch instant.
    ///      The retention window is [now - 30 days, now], and the RecallDirector
    ///      stamps its trace rows from its own clock inside `kit.recall`, which
    ///      runs AFTER this dispatch's instant was captured. Under load that
    ///      recall can finish late enough that a trace row is newer than the
    ///      dispatch instant, which would push it past the window's upper bound
    ///      and match zero rows.
    ///
    /// Failures are silent: a reward-marking failure must never break the verb
    /// the caller actually asked for.
    func recordDereferenced(_ memoryIDs: [UUID], estateID: UUID, callerID: String, at: Date) async {
        _ = (estateID, callerID, at)
        guard posture == .live else { return }
        // Condition 4: current wall time, NOT the `at` instant threaded from
        // dispatch. See the note above — this is not an oversight.
        let rewardInstant = Date()
        for memoryID in memoryIDs {
            guard await surfaced.entry(
                for: AriaV2ArgumentDecoder.canonicalUUID(memoryID)) != nil else { continue }
            for spelling in AriaV2ArgumentDecoder.storageIdentitySpellings(memoryID) {
                if let marked = try? await kit.markRecallUsed(
                    handle, target: spelling, now: rewardInstant), marked > 0 {
                    break
                }
            }
        }
    }
}

private struct DispatcherV2DreamAuthority: AriaV2Dream.Authority {
    let handle: EstateHandle
    let callerBinding: String
    /// Authority-owned wall clock.  A caller-proposed `now` is admitted only if
    /// it falls within a 24-hour window ahead of this instant; out-of-range
    /// values are refused as -32602 before destructive paths are reached.
    let now: Date

    func admit(
        requestedEstateID: UUID?,
        requestedNow: Date?
    ) async -> Result<AriaV2Dream.Admission, AriaV2Dream.Failure> {
        guard requestedEstateID == nil || requestedEstateID == handle.estateUUID else {
            return .failure(.refusal(.init(
                code: "estate_unavailable",
                message: "The requested estate is not available to this caller.",
                retryable: false)))
        }
        // Resolve the effective cycle clock.  A caller-proposed instant is
        // accepted when it is at most 24 hours ahead of the authority clock;
        // a further-future value would advance pruneRecallTraces(olderThan:)
        // beyond the 30-day horizon and silently erase recall traces.
        let effectiveNow: Date
        if let proposed = requestedNow {
            let ceiling = now.addingTimeInterval(24 * 3600)
            guard proposed <= ceiling else {
                return .failure(.invalidArgument(
                    "Argument 'now' must not be more than 24 hours in the future."))
            }
            effectiveNow = proposed
        } else {
            effectiveNow = now
        }
        return .success(.init(
            estateID: handle.estateUUID,
            handle: handle,
            callerBinding: callerBinding,
            authorizationGeneration: "selected-v2-public",
            now: effectiveNow))
    }

    func revalidate(_ admission: AriaV2Dream.Admission) async -> Result<Void, AriaV2Dream.Failure> {
        guard admission.estateID == handle.estateUUID else {
            return .failure(.refusal(.init(
                code: "estate_unavailable",
                message: "The selected estate is no longer available to this caller.",
                retryable: true)))
        }
        return .success(())
    }
}

/// The selected public v2 lane has one immutable caller, policy, and default
/// estate for the lifetime of a dispatcher session.  The authorization
/// generation is derived only from those immutable fields, so grants, clocks,
/// and pagination calls cannot change it under an active cursor.
private struct DispatcherV2MemoryListAuthorizationAuthority: AriaV2MemoryListAuthorizationAuthority {
    let state: AriaV2MemoryListAuthorizationState

    init(estateID: UUID, callerID: String) {
        let canonicalEstateID = AriaV2ArgumentDecoder.canonicalUUID(estateID)
        let contextID = "selected-v2-public"
        let policyVersion = "aria-v2-memory-list-public-v1"
        self.state = .init(
            estateID: estateID,
            callerID: callerID,
            contextID: contextID,
            policyVersion: policyVersion,
            generation: "v1:\(canonicalEstateID):\(callerID.utf8.count):\(callerID)"
        )
    }

    func authorizeMemoryList(
        estateID: UUID,
        authorization: AriaV2MemoryListAuthorization
    ) async throws -> AriaV2MemoryListAuthorizationState {
        guard estateID == state.estateID,
              authorization.callerID == state.callerID,
              authorization.contextID == state.contextID,
              authorization.policyVersion == state.policyVersion else {
            throw AriaV2MemoryListProductionSnapshotError.authorizationMismatch
        }
        return state
    }
}

/// Dispatch a parsed `tools/call` against one or more GeniusLocusKit
/// estates opened in the same kit instance.
///
/// The dispatcher carries one `GeniusLocusKit` reference and a map of
/// the estates it can address, keyed by `estateUUID`. One of those is
/// the default estate. Each tool call is routed by name through the
/// five-tier AI-client interface, the federation tool, recipe tools,
/// lens tools, and vault tools. Outcomes — success payloads or substrate
/// refusals — map to MCP `tools/call` result shapes; out-of-band failures
/// (unknown tool, malformed arguments, unknown `estateID`) surface as
/// JSON-RPC error responses instead.
///
/// ## Multi-estate addressing and the I-13 boundary
///
/// Every estate this dispatcher addresses is already `open` in the one
/// `GeniusLocusKit` actor on this device — entries in the kit's
/// in-process registry. Routing by `estateID` selects among *locally*
/// open estates; it never crosses a device or process boundary. This
/// is the ARIA access surface where federation is *mediated* (spec
/// invariant I-13); the substrate-to-substrate mechanism does not live
/// here. The single-estate v1.0 path is preserved exactly: a caller
/// that omits `estateID` targets the default estate, byte-for-byte as
/// before multi-estate addressing existed.
///
/// The estate map and kit are captured immutably; the dispatcher is not
/// an actor because all mutable state lives inside `GeniusLocusKit`,
/// which is itself an actor and serializes its per-estate work. Adding
/// an estate produces a new dispatcher (`registering(_:)`) rather than
/// mutating in place, keeping the value semantics of a `Sendable`
/// struct. The dispatcher's methods are async because every downstream
/// call into the kit is async.
public struct ToolDispatcher: Sendable {
    public let kit: GeniusLocusKit

    /// The default estate's handle — the target when a tool call omits
    /// `estateID`. Retained as a stored property so the v1.0
    /// single-estate construction and any reader of `.handle` are
    /// unchanged.
    public let handle: EstateHandle

    /// Every estate this dispatcher can address, keyed by `estateUUID`.
    /// Seeded with the default estate by `init(kit:handle:)`; grown by
    /// `registering(_:)`.
    private let estates: [UUID: EstateHandle]

    /// In-process registry tracking async vault import and export jobs.
    /// Shared across all dispatchers derived from this one via
    /// `registering(_:)` so job polling works regardless of which estate
    /// is the dispatch target. Actor-isolated (Sendable) — safe in the
    /// immutable Sendable struct.
    let jobRegistry: VaultJobRegistry

    /// Session-scoped ledger of drawer ids surfaced by `moot_memory_search`.
    /// Consulted by dereference verbs to trigger reward-trace marking (B-10a).
    /// Actor-isolated (Sendable) — safe in the immutable Sendable struct.
    /// Shared across dispatchers derived via `registering(_:)` so a search
    /// in one estate and a dereference in another within the same session
    /// are still correlated.
    let recallLedger: SurfacedRecallLedger

    /// sensitivity unlock: daemon-RAM-only grant ledger for the
    /// restricted/secret sensitivity tiers. Actor-isolated (Sendable) — safe
    /// in the immutable Sendable struct. Shared across dispatchers derived
    /// via `registering(_:)` for the same reason `recallLedger` is: exactly
    /// one instance lives for the lifetime of one `mootx01 serve` process,
    /// so "daemon restart = everything locked" falls out of
    /// `ToolDispatcher` construction rather than needing special-cased
    /// reset logic. See `SensitivityGrantLedger`'s own doc comment.
    let sensitivityUnlockLedger: SensitivityGrantLedger

    /// Live or frozen. A frozen dispatcher refuses every tool in
    /// `ToolMutationInventory.frozenRefusedTools`, runs `moot_memory_search`
    /// with internal origin (no recall-trace rows, no dreaming enqueue), and
    /// skips the reward mark in `noteUsage`. Resolved once at construction:
    /// from the explicit `posture:` argument when the host passes one
    /// (`mootx01 serve --frozen`), else from `MOOTX01_FROZEN` in the injected
    /// environment. Forwarded unchanged by `registering(_:)` and
    /// `withMonitoringControl(_:)`, so one serve process has one posture.
    public let posture: EstatePosture

    /// Injection seam for daemon telemetry monitoring state.
    ///
    /// Nil when the host has no stats store wired (stdio mode, test harnesses,
    /// provision-less contexts). The concrete implementation (AriaResident's
    /// `StatsStoreMonitoringControl`) wraps the `StatsStore` actor — AriaMcpKit
    /// never imports ObserverSink or IntellectusLib directly. Sendable because
    /// `MonitoringControl` requires `Sendable`.
    let monitoringControl: (any MonitoringControl)?

    /// The build serial for this running executable, surfaced by
    /// `moot_estate_ping` so drivers can confirm they are talking to the
    /// most recently compiled build.
    ///
    /// Computed once at dispatcher construction and stored here — not
    /// recomputed on every ping call.
    public let buildSerial: String

    /// The host identity written into rows this dispatcher files (memories,
    /// tunnels, facts). Injected at construction rather than hardcoded so the
    /// shared `ToolDispatcher` implementation correctly stamps provenance for
    /// whichever binary is hosting it — "aria-mcp-server" for the standalone
    /// reference server, "mootx01" for `mootx01 serve`, etc. Callers that do
    /// not pass an explicit value receive the default "aria-mcp-server".
    public let serverIdentity: String

    /// advisory message when the host has detected a version
    /// mismatch between an installed plugin (e.g. Claude Code's
    /// `mootx01@mootx01`) and this running binary — `nil` when no plugin is
    /// detected or its version matches. Computed once by the host at
    /// construction time (see `MootInstallerCore.VersionSkewAdvisory` in the
    /// `mootx01` app layer — kits do not read `~/.claude/plugins/` or know a
    /// product version themselves; the host injects the precomputed string)
    /// and surfaced verbatim in `moot_estate_ping` / `moot_estate_status` so
    /// a stale plugin or stale binary is visible without a separate check.
    public let versionSkewAdvisory: String?

    /// Upstream-release advisory provider: returns a one-line "a newer
    /// release exists" message (e.g. "v1.0.34 is available (installed
    /// 1.0.33) — upgrade with `mootx01 upgrade`"), or nil when there is
    /// nothing to say. Unlike `versionSkewAdvisory` this is a CLOSURE,
    /// not a startup-computed string: the daemon is long-lived and
    /// releases ship while it is resident, so freshness requires
    /// evaluation at call time. The host owns rate limiting and the
    /// network boundary (see `MootInstallerCore.UpdateAdvisor` — kits
    /// never touch the network themselves); the kit only renders the
    /// returned line. Evaluated in `moot_estate_ping` /
    /// `moot_estate_status` ONLY — the two session-orientation tools —
    /// so every other tool response is untouched and clients are
    /// informed once at orientation time, not nagged per call.
    public let updateAdvisoryProvider: (@Sendable () async -> String?)?

    /// Environment the dispatch-time feature-flag guards read
    /// (`MOOTX01_MEMORY_TOOL`, `MOOTX01_VAULT`). Injected at construction —
    /// defaulting to the process environment — so tests can enable or disable
    /// opt-in surfaces per dispatcher instance instead of mutating the
    /// process-global environment with `setenv`, which races concurrently
    /// running suites under swift-testing's parallel executor.
    public let environment: [String: String]

    /// Pinnable clock for the benchmark replay seam.
    ///
    /// When `MOOT_BENCH_EPOCH_NOW` is set in the process environment (or in the
    /// injected `environment` dict), the clock returns a deterministic sequence
    /// (`base + N seconds`, N incremented per tool call) instead of `Date()`.
    /// Without the env var the behavior is byte-identical to calling `Date()`.
    ///
    /// Every request-path runner calls `benchClock.now()` once at the top of
    /// the `dispatch()` call, then threads the result through to kit entry points.
    /// Daemon and background clocks (dreaming, governor, HLC self-advance) do NOT
    /// route through `benchClock` — they must remain wall-clock for correctness.
    ///
    /// See `BenchClock` for the full contract and `MOOT_BENCH_EPOCH_NOW` for the
    /// env var specification.
    let benchClock: BenchClock

    /// Per-session mode sticky state and call counters for the modes coaching system.
    ///
    /// Actor-isolated (Sendable) — safe in the immutable Sendable struct.
    /// Shared across dispatchers derived via `registering(_:)` and
    /// `withMonitoringControl(_:)` so mode declarations and call counts
    /// accumulate correctly across the full session regardless of which
    /// derived dispatcher a call reaches.
    ///
    /// One instance per `ToolDispatcher` root: stdio = one per process lifetime,
    /// HTTP = one per `mootx01 serve` process (shared across HTTP clients). For
    /// per-client-id stickiness on HTTP, wrap the dispatcher per request with a
    /// fresh `ModeSessionState` keyed by the client's session ID (see
    /// `ModeSessionState` doc comment for the extension point description).
    let modeSessionState: ModeSessionState

    /// Retained current-state cursors for the selected v2 memory inventory.
    /// Shared by every value-semantic dispatcher derived from this session.
    let v2MemoryListCursorSession: AriaV2MemoryListCursorSession

    /// Transform-phase registrations run before argument decode.
    ///
    /// In production this is populated by `ariaV2PreDecodeRegistrations` with the
    /// mode concern's transform hook (strips `mode` global modifier, injects sticky
    /// recall `answer` for `moot_memory_search`). Test code may replace this field
    /// entirely to exercise the transform phase with a custom hook.
    internal var preDecodeRegistrations: [AriaV2ChainRegistration] = []

    /// Construct a single-estate dispatcher. `handle` is registered as
    /// the sole addressable estate and is the default target for calls
    /// that omit `estateID`. This is the v1.0 path; every existing
    /// construction site uses exactly this initializer.
    ///
    /// `buildSerial` defaults to `Self.deriveBuildSerial()` so callers do
    /// not need to know the derivation — pass an explicit value only in
    /// tests or when `MOOTX01_BUILD_SERIAL` is already resolved at a
    /// higher level.
    ///
    /// `serverIdentity` defaults to "aria-mcp-server" so existing call sites
    /// that do not supply an identity are unaffected. Production hosts should
    /// pass their own identity string so rows are stamped with the correct
    /// source (e.g. "mootx01" for `mootx01 serve`).
    public init(kit: GeniusLocusKit, handle: EstateHandle,
                buildSerial: String = Self.deriveBuildSerial(),
                serverIdentity: String = "aria-mcp-server",
                versionSkewAdvisory: String? = nil,
                updateAdvisoryProvider: (@Sendable () async -> String?)? = nil,
                monitoringControl: (any MonitoringControl)? = nil,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                modeSessionState: ModeSessionState = ModeSessionState(),
                posture: EstatePosture? = nil) {
        self.kit = kit
        self.handle = handle
        self.estates = [handle.estateUUID: handle]
        self.jobRegistry = VaultJobRegistry()
        self.recallLedger = SurfacedRecallLedger()
        self.sensitivityUnlockLedger = SensitivityGrantLedger()
        self.buildSerial = buildSerial
        self.serverIdentity = serverIdentity
        self.versionSkewAdvisory = versionSkewAdvisory
        self.updateAdvisoryProvider = updateAdvisoryProvider
        self.monitoringControl = monitoringControl
        self.environment = environment
        // Bench clock reads MOOT_BENCH_EPOCH_NOW from the injected environment dict.
        // In production this is ProcessInfo.processInfo.environment; tests inject
        // a custom dict with or without the pin key as needed.
        self.benchClock = BenchClock(environment: environment)
        self.modeSessionState = modeSessionState
        self.v2MemoryListCursorSession = AriaV2MemoryListCursorSession()
        // Hosts that parse `--frozen` pass the posture explicitly; everyone
        // else (the aria-mcp dev server, tests) gets the environment twin.
        self.posture = posture ?? EstatePosture.resolve(frozenFlag: false, environment: environment)
        // Wire the mode concern's pre-decode transform hook: strips the `mode`
        // global modifier before AriaSurfaceDecoder sees the arguments, and injects
        // the sticky recall `answer` for moot_memory_search when absent.
        self.preDecodeRegistrations = ariaV2PreDecodeRegistrations(
            environment: environment,
            modeSessionState: modeSessionState
        )
    }

    /// Return a dispatcher that also addresses `additional`, with the
    /// same default estate. Value-semantic (returns a new dispatcher)
    /// because `ToolDispatcher` is an immutable `Sendable` struct; the
    /// kit reference and default `handle` are carried over unchanged.
    /// Re-registering an estate already present replaces its entry,
    /// which is harmless because handles are keyed by a stable UUID.
    /// The existing `jobRegistry` is forwarded so polling still works
    /// on dispatchers produced by `registering(_:)`.
    public func registering(_ additional: EstateHandle) -> ToolDispatcher {
        var next = estates
        next[additional.estateUUID] = additional
        return ToolDispatcher(kit: kit, handle: handle, estates: next,
                              jobRegistry: jobRegistry, recallLedger: recallLedger,
                              sensitivityUnlockLedger: sensitivityUnlockLedger,
                              monitoringControl: monitoringControl,
                              buildSerial: buildSerial, serverIdentity: serverIdentity,
                              versionSkewAdvisory: versionSkewAdvisory,
                              updateAdvisoryProvider: updateAdvisoryProvider,
                              environment: environment,
                              benchClock: benchClock,
                              modeSessionState: modeSessionState,
                              v2MemoryListCursorSession: v2MemoryListCursorSession,
                              posture: posture)
    }

    /// Return a copy of this dispatcher with `control` wired as the monitoring
    /// seam. Used by `AriaResident.runResidentDaemon` to inject the stats-store
    /// control AFTER the stats store is opened (the store is opened inside
    /// `runResidentDaemon`, after the dispatcher is first constructed). All
    /// other state — kit, handle, ledgers, estate map — is forwarded unchanged.
    public func withMonitoringControl(_ control: (any MonitoringControl)?) -> ToolDispatcher {
        ToolDispatcher(kit: kit, handle: handle, estates: estates,
                       jobRegistry: jobRegistry, recallLedger: recallLedger,
                       sensitivityUnlockLedger: sensitivityUnlockLedger,
                       monitoringControl: control,
                       buildSerial: buildSerial, serverIdentity: serverIdentity,
                       versionSkewAdvisory: versionSkewAdvisory,
                       updateAdvisoryProvider: updateAdvisoryProvider,
                       environment: environment,
                       benchClock: benchClock,
                       modeSessionState: modeSessionState,
                       v2MemoryListCursorSession: v2MemoryListCursorSession,
                       posture: posture)
    }

    /// Private designated initializer carrying an explicit estate map,
    /// a shared job registry, a shared recall ledger, the build serial,
    /// the server identity, and the version-skew advisory. Used by
    /// `registering(_:)` and `withMonitoringControl(_:)`; the public
    /// `init(kit:handle:buildSerial:serverIdentity:versionSkewAdvisory:)` is
    /// the only construction path external callers use.
    private init(
        kit: GeniusLocusKit, handle: EstateHandle,
        estates: [UUID: EstateHandle], jobRegistry: VaultJobRegistry,
        recallLedger: SurfacedRecallLedger,
        sensitivityUnlockLedger: SensitivityGrantLedger,
        monitoringControl: (any MonitoringControl)?,
        buildSerial: String, serverIdentity: String, versionSkewAdvisory: String?,
        updateAdvisoryProvider: (@Sendable () async -> String?)?,
        environment: [String: String],
        benchClock: BenchClock,
        modeSessionState: ModeSessionState,
        v2MemoryListCursorSession: AriaV2MemoryListCursorSession,
        posture: EstatePosture
    ) {
        self.kit = kit
        self.handle = handle
        self.estates = estates
        self.jobRegistry = jobRegistry
        self.recallLedger = recallLedger
        self.sensitivityUnlockLedger = sensitivityUnlockLedger
        self.monitoringControl = monitoringControl
        self.buildSerial = buildSerial
        self.serverIdentity = serverIdentity
        self.versionSkewAdvisory = versionSkewAdvisory
        self.updateAdvisoryProvider = updateAdvisoryProvider
        self.environment = environment
        self.benchClock = benchClock
        self.modeSessionState = modeSessionState
        self.v2MemoryListCursorSession = v2MemoryListCursorSession
        self.posture = posture
        // Re-wire the mode concern's pre-decode transform hook using the forwarded
        // environment and modeSessionState. This preserves the production hook on
        // dispatchers produced by registering(_:) and withMonitoringControl(_:).
        self.preDecodeRegistrations = ariaV2PreDecodeRegistrations(
            environment: environment,
            modeSessionState: modeSessionState
        )
    }

    // MARK: - Build serial derivation

    /// Derive a build serial from the running executable.
    ///
    /// ## Override
    ///
    /// If `MOOTX01_BUILD_SERIAL` is set and non-empty, it is returned
    /// verbatim. This lets test harnesses and CI inject a known serial
    /// without recompiling.
    ///
    /// ## Derived value
    ///
    /// When the env override is absent, the serial is computed from the
    /// executable file's modification time and byte count:
    ///
    ///   `<mtime-yyyyMMddHHmmss>/<8-hex-fingerprint>`
    ///
    /// The 8-hex fingerprint is the lower 32 bits of
    /// `mtime_seconds XOR file_size`, formatted as zero-padded lowercase
    /// hex. This is not a cryptographic hash — its purpose is purely
    /// build-identity: the value changes on every relink because the
    /// linker always updates the mtime and the output size varies with
    /// code changes. No large file read is performed; only filesystem
    /// metadata attributes are queried (O(1) syscall).
    ///
    /// On any error (unreadable exe path, missing attributes), falls
    /// back to `"unknown"` so the server still starts cleanly.
    public static func deriveBuildSerial() -> String {
        // 1. Env override wins unconditionally.
        let envOverride = ProcessInfo.processInfo.environment["MOOTX01_BUILD_SERIAL"] ?? ""
        if !envOverride.isEmpty { return envOverride }

        // 2. Derive from the running executable's mtime + size.
        let exePath = CommandLine.arguments[0]
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: exePath)
            guard let mtime = attrs[.modificationDate] as? Date,
                  let sizeNS = attrs[.size] as? NSNumber else {
                return "unknown"
            }
            let mtimeSecs = UInt64(max(0, mtime.timeIntervalSince1970))
            let fileSize = UInt64(sizeNS.uint64Value)

            // Compact mtime: yyyyMMddHHmmss in UTC (14 chars, sortable, human-readable).
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyyMMddHHmmss"
            fmt.timeZone = TimeZone(identifier: "UTC")
            let compact = fmt.string(from: mtime)

            // 8-hex fingerprint: lower 32 bits of (mtime_seconds XOR file_size).
            // Changes on every relink (mtime advances; size varies with code delta).
            let fingerprint = UInt32(truncatingIfNeeded: mtimeSecs ^ fileSize)
            let hex = String(format: "%08x", fingerprint)

            return "\(compact)/\(hex)"
        } catch {
            return "unknown"
        }
    }

    /// Resolve the estate a direct tool call targets from its `estateID` argument.
    ///
    /// Omitted `estateID` → default estate (preserves single-estate v1.0 behavior).
    ///
    /// Direct MCP tools are intentionally default-estate only. Additional registered
    /// estates are addressable through `moot_federated_search`, which enforces active,
    /// unexpired, scope-narrowing grants before any cross-estate read or write.
    /// Allowing `estateID` to target any registered estate would bypass that grant gate;
    /// therefore a present `estateID` is accepted only when it names the default estate.
    ///
    /// This is the security gate for Item 3 of secfix/batch2-aria: planned hardening
    /// to prevent a prompt-injected agent from routing reads/writes to estates the
    /// caller is not explicitly authorized to access through the federation surface.
    private func resolveHandle(_ args: [String: JSONValue]) throws -> EstateHandle {
        guard let raw = try optionalString(args["estateID"], argument: "estateID") else { return handle }
        guard let uuid = UUID(uuidString: raw) else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Malformed estateID (not a UUID): \(raw)"
            )
        }
        guard estates[uuid] != nil else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Unknown estateID: \(raw)"
            )
        }
        guard uuid == handle.estateUUID else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Direct estateID routing is limited to the default estate; use moot_federated_search for grant-authorized cross-estate reads."
            )
        }
        return handle
    }

    /// Resolve any registered estate from an `estateID` argument.
    ///
    /// Unlike `resolveHandle`, this function allows targeting any registered estate
    /// — it is used exclusively by the federated comparison lenses (`moot_lens_overlap`,
    /// `moot_lens_divergence`) whose `estateIDB` argument is a peer comparison target,
    /// not a CRUD routing target. Cross-estate reads/writes must go through the federation
    /// surface (`moot_federated_search`) with its grant gate; lens comparisons are
    /// read-only metadata operations that must see both estates.
    internal func resolveAnyRegistered(_ args: [String: JSONValue]) throws -> EstateHandle {
        guard let raw = try optionalString(args["estateID"], argument: "estateID") else { return handle }
        guard let uuid = UUID(uuidString: raw) else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Malformed estateID (not a UUID): \(raw)"
            )
        }
        guard let resolved = estates[uuid] else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Unknown estateID: \(raw)"
            )
        }
        return resolved
    }

    /// Run the tool named `name` with the JSON `arguments` object.
    /// Returns the MCP `tools/call` result payload as a `JSONValue`
    /// (a `content` array of text blocks plus an `isError` flag).
    /// Throws `JSONRPCError` only for out-of-band conditions (unknown
    /// tool, missing required argument, malformed JSON). Substrate
    /// refusals (`VerbError.notSupportedByEstate`, `.expungeNotConfirmed`)
    /// come back as a result with `isError == true` rather than as a
    /// JSON-RPC error: the call did reach the substrate, the substrate
    /// said no, the client should see why.
    ///
    /// Dispatch: admit via v2 catalog → decode typed request → dispatchV2.
    public func dispatch(name: String, arguments: JSONValue) async throws -> JSONValue {
        try await AriaV2Withheld.$call.withValue(AriaV2WithheldCall()) {
            try await AriaV2ChestDiversity.$call.withValue(AriaV2ChestDiversityCall()) {
                try await dispatchWithinCall(name: name, arguments: arguments)
            }
        }
    }

    private func dispatchWithinCall(name: String, arguments: JSONValue) async throws -> JSONValue {
        let decodedArguments = arguments.objectValue
        let args = decodedArguments ?? [:]

        // V2 admits names from its selected catalog before any frozen policy,
        // teachme interception, mode parsing, or session mutation.
        guard decodedArguments != nil else {
            let message = "tools/call arguments must be an object for the active ARIA v2 surface"
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: message,
                data: .object([
                    "code": .string("invalid_argument"),
                    "path": .string("arguments"),
                    "message": .string(message),
                    "correction": .string("Call moot_monitoring_status with an empty arguments object."),
                ])
            )
        }
        // `memory` is intercepted before the admitsDispatch guard because it stays
        // outside the v2 registry. When the flag is off, we return a soft isError
        // refusal rather than a -32601 throw: Anthropic tool-use clients expect a
        // content result from a named tool call, not a protocol-level error.
        // Frozen posture is evaluated per command,
        // not by tool name, using ToolMutationInventory.frozenReadCommands: `view`
        // proceeds; every other command (and a missing or unknown command) is refused
        // before the adapter runs and before session state records the call.
        if name == "memory" {
            let now = benchClock.now()
            guard ToolProjection.memoryToolEnabled(environment: environment) else {
                return Self.errorResult("memory tool is disabled; run `mootx01 enable memory-tool` to activate it")
            }
            if posture == .frozen {
                let command: String?
                if case .string(let s) = args["command"] { command = s } else { command = nil }
                let readCommands = ToolMutationInventory.frozenReadCommands["memory"] ?? []
                let isReadCommand = command.map { readCommands.contains($0) } ?? false
                if !isReadCommand {
                    return Self.errorResult(
                        EstatePosture.refusalMessage(tool: "memory", command: command))
                }
            }
            // Record the admitted call before running the adapter so the session
            // counter reflects every dispatched memory command (refused commands
            // return above and are not counted).
            await modeSessionState.recordCall(toolName: name, mode: nil)
            return try await runMemoryTool(args, now: now)
        }
        guard ToolProjection.admitsDispatch(name: name, environment: environment) else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.methodNotFound,
                message: "Unknown tool: \(name)"
            )
        }

        let modeDeclaration = ariaV2GlobalModeDeclaration(
            toolName: name, arguments: args, environment: environment)

        // Transform phase: run before decode so a hook can remove or inject a key
        // before the strict argument decoder sees the arguments. In production,
        // preDecodeRegistrations holds the mode concern's transform hook (strips the
        // `mode` global modifier, injects sticky recall `answer` for moot_memory_search).
        // Test code that replaces preDecodeRegistrations entirely still works because
        // the field is internal var — the replacement overrides production hooks.
        // Construction fails only on duplicate concern names or positions —
        // programmer errors in the injected list — so try! is appropriate.
        let transformChain = try! AriaV2CallChain(registrations: preDecodeRegistrations)
        let transformOutcome = await transformChain.runTransform(
            toolName: name,
            arguments: .object(args)
        )
        let transformedArgs = transformOutcome.arguments.objectValue ?? args

        let request = try AriaSurfaceDecoder.decode(name: name, arguments: transformedArgs)
        return await dispatchV2(
            request, rawArguments: transformedArgs, modeDeclaration: modeDeclaration)
    }
}

// MARK: - V2 dispatch

private extension ToolDispatcher {
    /// Entry point for every v2 tool call. Handles frozen posture, advances the
    /// §12.5 coaching session counter, dispatches to `executeV2Core`, and applies
    /// any coaching hint and periodic coaching block before returning.
    ///
    /// The record (ingress) phase runs after the frozen guard and after decode.
    /// Counting sits there because a frozen refusal is not a call and a decode
    /// failure is not a call. The transform phase runs in dispatch() before
    /// decode so a hook can remove a key the strict decoder rejects.
    /// Do not inject per-arm inside `executeV2Core`.
    ///
    /// `rawArguments` is the `[String: JSONValue]` map after the transform phase,
    /// forwarded so the record (ingress) chain receives the same arguments that
    /// the decoder accepted.
    private func dispatchV2(
        _ request: AriaSurfaceRequest,
        rawArguments: [String: JSONValue],
        modeDeclaration: ModeDeclaration?
    ) async -> JSONValue {
        // Load estate-provisioned modes preferences on the first v2 call of
        // this session. The outer guard prevents the async estate read from
        // firing on every call — only the first call of the session reaches
        // the coordinator. Falls back silently when the estate has no stored
        // manifest; spec defaults (stickyEnabled=true, coachingCalls=25)
        // remain in effect. Rust twin: dispatcher.rs guards the same block
        // with `if !mode_session_state.is_configured_from_estate()`.
        if await !modeSessionState.configuredFromEstate {
            if let manifest = try? await kit.provisionedModesConfig(for: handle) {
                await modeSessionState.applyPreferences(
                    stickyEnabled: manifest.stickyEnabled,
                    coachingCalls: manifest.coachingCalls
                )
            }
        }

        switch request.operation.effect {
        case .inspection:
            break
        case .mutation:
            if posture == .frozen {
                // Frozen refusal: never recorded in session state.
                return AriaV2Envelope.refusal(
                    tool: request.toolName,
                    error: .init(
                        code: "estate_frozen",
                        message: EstatePosture.refusalMessage(tool: request.toolName),
                        retryable: false
                    )
                )
            }
        }

        // Build the per-call chain from the production factory. Construction
        // fails only on a duplicate name or position, both programmer errors in
        // a hard-coded list — `try!` follows the precedent at executeV2Core's
        // `try! AriaV2CapabilityDigest.digest`.
        //
        // The record (ingress) chain runs after the frozen guard so the session
        // counter does not advance on frozen refusals (which return above) or
        // on decode failures (which throw before dispatchV2 is reached). The
        // transform phase ran in dispatch() before decode; counting runs here
        // because a refused call is not a call.
        let chain = try! AriaV2CallChain(
            registrations: ariaV2ProductionRegistrations(
                request: request,
                modeSessionState: modeSessionState,
                modeDeclaration: modeDeclaration
            )
        )
        // Record phase: the coaching hook calls recordCall on admitted, decoded
        // calls. Refused and decode-failed calls both return before this point.
        let ingressOutcome = await chain.runIngress(
            toolName: request.toolName,
            arguments: .object(rawArguments)
        )

        // Execute the v2 operation — all business logic lives in executeV2Core.
        let coreResult = await executeV2Core(request)

        // Egress: the coaching hook applies hint and periodic block. A halt
        // payload from any future gate registered at egress position 1 is
        // already the result, so it is honoured without additional code here.
        // The `failures` field is not consumed: no concern registered today
        // can throw.
        let egressOutcome = await chain.runEgress(
            toolName: request.toolName,
            result: coreResult,
            ingressOutcome: ingressOutcome
        )
        return egressOutcome.result
    }

    /// All v2 business logic: service setup, the tool dispatch switch, and
    /// error projection. Extracted from `dispatchV2` so coaching can wrap it
    /// at the choke point without injecting per tool arm.
    private func executeV2Core(_ request: AriaSurfaceRequest) async -> JSONValue {
        let now = benchClock.now()
        let effectiveRegistry = AriaV2SelectedCatalog.registry(environment: environment)
        let capabilityDigest = try! AriaV2CapabilityDigest.digest(registry: effectiveRegistry)
        let sensitivityGrant = await sensitivityUnlockLedger.ceilingSensitivity(now: now)
        let maximumSensitivity = sensitivityGrant ?? .elevated
        let memoryOperations = AriaV2MemoryOperations(
            backend: AriaV2GeniusLocusMemoryBackend(kit: kit, handle: handle),
            context: .init(
                estateID: handle.estateUUID,
                callerID: serverIdentity,
                serverIdentity: serverIdentity,
                now: { now },
                maximumSensitivity: maximumSensitivity,
                recallOrigin: posture == .frozen ? .internal : .external,
                usageLedger: DispatcherV2MemoryUsageLedger(
                    surfaced: recallLedger, kit: kit, handle: handle, posture: posture),
                // Carry the un-collapsed grant ceiling (not `maximumSensitivity`,
                // which is already `sensitivityGrant ?? .elevated` above and so
                // cannot distinguish "no grant" from "a grant that ceilings at
                // elevated") so the sensitivity-read-under-grant audit can tell
                // whether a restricted/secret row's admission actually depended
                // on a live grant. Same precedent as `packetOperations` below.
                grantCeiling: sensitivityGrant
            )
        )
        let knowledgeJournal = AriaV2KnowledgeJournalService(
            backend: AriaV2GeniusLocusKnowledgeJournalBackend(kit: kit, handle: handle),
            context: memoryOperations.context)
        let contradictions = AriaV2ContradictionsService(
            kit: kit, handle: handle,
            context: .init(estateID: handle.estateUUID, callerBinding: serverIdentity,
                           authorizationRevision: "selected-v2-public"),
            now: { now })
        let estateDiagnostics = AriaV2EstateDiagnostics(
            provider: AriaV2GeniusLocusEstateDiagnosticsProvider(kit: kit, handle: handle),
            context: .init(
                estateID: handle.estateUUID,
                estateName: handle.estateName,
                callerID: serverIdentity,
                serverIdentity: serverIdentity,
                sessionID: "selected-v2-public",
                buildSerial: buildSerial,
                versionSkewAdvisory: versionSkewAdvisory,
                updateAdvisoryProvider: updateAdvisoryProvider,
                now: { now }))
        let cognitionCatalog = AriaV2CognitionCatalogService(
            estateID: handle.estateUUID,
            callableToolNames: Set(effectiveRegistry.operations.map(\.publicName)),
            buildID: buildSerial,
            capabilityDigest: capabilityDigest,
            projectedTools: ToolProjection.tools())
        let memoryMutations = AriaV2MemoryMutations(
            kit: kit, handle: handle, context: memoryOperations.context)
        let recallLens = AriaV2RecallLensService(
            authority: AriaV2GeniusLocusRecallLensAuthority(kit: kit, handle: handle))
        let lensLower = AriaV2LensLowerService(
            authority: AriaV2GeniusLocusLensLowerAuthority(kit: kit, handle: handle),
            context: .init(estateID: handle.estateUUID, now: now))
        let orchestration = AriaV2Orchestration(
            provider: AriaV2GeniusLocusOrchestrationProvider(
                kit: kit,
                handle: handle,
                // Bind typed federation to the dispatcher-owned local peer
                // registry. The lower adapter excludes this requester before
                // reaching GLK's grant gate, so self recall cannot become a
                // federated success.
                federationSources: estates.values.sorted {
                    $0.estateUUID.uuidString < $1.estateUUID.uuidString
                }),
            context: .init(
                estateID: handle.estateUUID,
                serverIdentity: serverIdentity,
                sessionID: "selected-v2-public",
                now: { now }))
        let dream = AriaV2Dream.Service(
            authority: DispatcherV2DreamAuthority(
                handle: handle, callerBinding: serverIdentity, now: now),
            lower: AriaV2Dream.GeniusLocusLower(kit: kit))
        let dataMobility = AriaV2DataMobility(
            authority: AriaV2SelectedDataMobilityAuthority(
                lifecycle: AriaV2VaultLifecycleAuthority(
                    jobRegistry: jobRegistry, kit: kit, handle: handle,
                    selectedEstateID: handle.estateUUID),
                direct: AriaV2GeniusLocusDataMobilityAuthority(
                    kit: kit, handle: handle, selectedEstateID: handle.estateUUID,
                    now: now, serverIdentity: serverIdentity,
                    maximumSensitivity: maximumSensitivity)))

        do {
            switch request {
            case .help(let helpRequest):
                return AriaV2HelpService(
                    registry: effectiveRegistry, buildID: buildSerial).render(helpRequest)
            case .fileMemory(let fileRequest):
                return try await memoryOperations.file(fileRequest)
            case .memorySearch(let searchRequest):
                return try await memoryOperations.search(searchRequest)
            case .memoryList(let listRequest):
                let authority = DispatcherV2MemoryListAuthorizationAuthority(
                    estateID: handle.estateUUID,
                    callerID: serverIdentity)
                let service = AriaV2MemoryListService(
                    provider: AriaV2MemoryListProductionSnapshotProvider(
                        kit: kit,
                        handle: handle,
                        authorizationAuthority: authority),
                    cursorSession: v2MemoryListCursorSession,
                    defaultEstateID: handle.estateUUID,
                    authorization: .init(
                        callerID: authority.state.callerID,
                        contextID: authority.state.contextID,
                        policyVersion: authority.state.policyVersion),
                    now: { now })
                return try await service.list(listRequest)
            case .memoryGet(let getRequest):
                return try await memoryOperations.get(getRequest)
            case .transcriptRecall(let transcriptRequest):
                let service = AriaV2TranscriptRecallService(
                    backend: AriaV2GeniusLocusTranscriptRecallBackend(kit: kit, handle: handle),
                    context: memoryOperations.context)
                return try await service.recall(transcriptRequest)
            case .similarRecall(let similarRequest):
                let service = AriaV2SimilarRecallService(
                    backend: AriaV2GeniusLocusSimilarRecallBackend(kit: kit, handle: handle),
                    context: memoryOperations.context)
                return try await service.recall(similarRequest)
            case .recallLens(let request):
                if AriaV2LensLower.supported.contains(request.operation) {
                    return try await lensLower.execute(request)
                }
                return try await recallLens.execute(
                    tool: request.operation.rawValue,
                    arguments: .object(request.arguments))
            case .synthesize(let request):
                return try await orchestration.synthesize(request)
            case .dream(let request):
                return try await dream.execute(request)
            case .migrationRun(let request):
                return try await orchestration.runMigration(request)
            case .migrationConfirm(let request):
                return try await orchestration.confirmMigration(request)
            case .federatedRecall(let request):
                return try await orchestration.federatedSearch(request)
            case .huntContradictions(let request):
                return try await contradictions.hunt(request)
            case .proposeContradictions(let request):
                return try await contradictions.propose(request)
            case .connectionSearch(let request):
                return try await knowledgeJournal.connectionSearch(request)
            case .connectionMap(let request):
                return try await knowledgeJournal.connectionMap(request)
            case .fileFact(let request):
                return try await knowledgeJournal.fileFact(request)
            case .factSearch(let request):
                return try await knowledgeJournal.factSearch(request)
            case .retireFact(let request):
                return try await knowledgeJournal.retireFact(request)
            case .factTimeline(let request):
                return try await knowledgeJournal.factTimeline(request)
            case .writeJournal(let request):
                return try await knowledgeJournal.writeJournal(request)
            case .readJournal(let request):
                return try await knowledgeJournal.readJournal(request)
            case .monitoringSet(let monitoringRequest):
                let result = await AriaV2MonitoringSet.execute(
                    monitoringRequest, monitoringControl: monitoringControl)
                return AriaV2MonitoringSet.render(
                    result,
                    buildID: buildSerial,
                    capabilityDigest: capabilityDigest)
            case .monitoringStatus(let request):
                let result = await AriaV2MonitoringInspection.execute(
                    request, monitoringControl: monitoringControl)
                return AriaV2MonitoringInspection.render(
                    result,
                    buildID: buildSerial,
                    capabilityDigest: capabilityDigest)
            case .estatePing:
                return try await estateDiagnostics.ping(arguments: requestArguments(request))
            case .estateStatus:
                return try await estateDiagnostics.status(arguments: requestArguments(request))
            case .estateMap:
                return try await estateDiagnostics.map(arguments: requestArguments(request))
            case .drainStatus:
                return try await estateDiagnostics.drainStatus(arguments: requestArguments(request))
            case .rebuildStatus:
                return try await estateDiagnostics.rebuildStatus(arguments: requestArguments(request))
            case .timingReport:
                return try await estateDiagnostics.timingReport(arguments: requestArguments(request))
            case .listLenses(let request):
                return try cognitionCatalog.lenses(request)
            case .listRecipes(let request):
                return try cognitionCatalog.recipes(request)
            case .updateMemory(let request):
                return try await memoryMutations.update(request)
            case .withdrawMemory(let request):
                return try await memoryMutations.withdraw(request)
            case .eraseMemory(let request):
                return try await memoryMutations.erase(request)
            case .confirmMemory(let request):
                return try await memoryMutations.confirm(request)
            case .moveMemory(let request):
                return try await memoryMutations.move(request)
            case .linkMemories(let request):
                return try await memoryMutations.link(request)
            case .reviewTunnel(let request):
                return try await memoryMutations.review(request)
            case .dataMobility(let request):
                return try await dataMobility.execute(request)
            }
        } catch let error as JSONRPCError where error.code == JSONRPCErrorCode.invalidParams {
            // A SYNTAX ERROR is the CALLER's to fix, so it is reported as one
            // rather than as `operation_failed`, which reads as an estate
            // problem and invites a retry that cannot succeed. The message
            // carries the offending argument and its value; `retryable: false`
            // says plainly that sending the same call again will not help.
            return AriaV2Envelope.refusal(
                tool: request.toolName,
                error: .init(code: "invalid_argument", message: error.message, retryable: false)
            )
        } catch let error as JSONRPCError {
            return AriaV2Envelope.refusal(
                tool: request.toolName,
                error: .init(code: "operation_failed", message: error.message, retryable: false)
            )
        } catch {
            return AriaV2Envelope.refusal(
                tool: request.toolName,
                error: .init(code: "operation_failed", message: String(describing: error), retryable: false)
            )
        }
    }

    private func requestArguments(_ request: AriaSurfaceRequest) -> JSONValue {
        switch request {
        case .estatePing(let request), .estateStatus(let request), .estateMap(let request), .drainStatus(let request), .rebuildStatus(let request), .timingReport(let request):
            if let estateID = request.estateID {
                return .object(["estate_id": .string(estateID.uuidString)])
            }
            return .object([:])
        default:
            return .object([:])
        }
    }

    private func requestArguments(_ request: AriaV2DataMobilityRequest) -> JSONValue {
        switch request {
        case .vaultExport(let path, let scope, let estateID):
            var values: [String: JSONValue] = ["vaultPath": .string(path)]
            if let scope { values["scope"] = .string(scope) }
            if let estateID { values["estate_id"] = .string(AriaV2ArgumentDecoder.canonicalUUID(estateID)) }
            return .object(values)
        case .vaultImport(let path, let mode, let estateID):
            var values: [String: JSONValue] = ["vaultPath": .string(path)]
            if let mode { values["mode"] = .string(mode) }
            if let estateID { values["estate_id"] = .string(AriaV2ArgumentDecoder.canonicalUUID(estateID)) }
            return .object(values)
        case .vaultJob(let jobID):
            return .object(["job_id": .string(AriaV2ArgumentDecoder.canonicalUUID(jobID))])
        default:
            preconditionFailure("unselected data-mobility request reached the v2 dispatcher")
        }
    }
}

// MARK: - Result helpers

extension ToolDispatcher {
    /// MCP `tools/call` success result with a single text content block.
    public static func textResult(_ text: String) -> JSONValue {
        textResultBlocks([text])
    }

    /// MCP `tools/call` success result carrying several text blocks, in order.
    ///
    /// Used where a machine-readable payload travels alongside the prose
    /// receipt (`moot_json_import` with `return_id_map`): the reader parses one
    /// block whole rather than scraping structure out of a sentence.
    ///
    /// Deliberately NOT an overload of `textResult(_:)`. Overloading on
    /// `String` vs `[String]` forces the type-checker to weigh both candidates
    /// at every call site, and the long `+`-chained receipt strings in this
    /// file exceed its time budget when it has to.
    public static func textResultBlocks(_ blocks: [String]) -> JSONValue {
        .object([
            "content": .array(blocks.map { block in
                .object([
                    "type": .string("text"),
                    "text": .string(block),
                ])
            }),
            "isError": .bool(false),
        ])
    }

    /// MCP `tools/call` failure result. Substrate refusals come back
    /// here rather than as JSON-RPC errors so the client retains the
    /// call ID and can render the message in a tool-output panel.
    public static func errorResult(_ text: String) -> JSONValue {
        .object([
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(text),
                ])
            ]),
            "isError": .bool(true),
        ])
    }
}


// MARK: - Decode helpers

extension ToolDispatcher {
    /// Hard ceiling for all caller-supplied `limit`/`count`/`k` arguments at the
    /// MCP tool boundary. Every tool that accepts a numeric quantity must clamp
    /// through `clampLimit` before passing the value into the substrate.
    /// Parity: mirrors `LIMIT_HARD_CEILING` in Rust `dispatch.rs`.
    static let limitHardCeiling = 500

    static func clampLimit(
        _ raw: Int?,
        argument: String,
        default defaultValue: Int = 20,
        ceiling: Int = limitHardCeiling
    ) throws -> Int {
        guard let raw else { return defaultValue }
        guard raw > 0 else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "\(argument) must be 1 or greater; received \(raw)"
            )
        }
        return min(raw, ceiling)
    }

    /// `true` if `chain` already constrains sensitivity in any way — an
    /// exact `.sensitivity` match, an explicit `.sensitivityAtMost`
    /// ceiling (whether from the caller's own `filter` argument or
    /// injected by the sensitivity-grant ceiling), or one nested inside
    /// `.all`/`.any`/`.not`. Mirrors LocusKit `BitmapEvaluator`'s private
    /// `isBitmapSensitivityFilter` classifier — kept as a small local
    /// duplicate rather than exposing that private substrate function,
    /// since this ARIA-boundary use is "should I inject the grant
    /// ceiling", a different question from BitmapEvaluator's own "should
    /// I insert my default" (this function runs BEFORE that one; an ARIA
    /// caller that already has a sensitivity constraint should not also
    /// get a grant-ceiling appended on top of it, which would AND two
    /// constraints together in a caller-surprising way).
    static func isSensitivityFilter(_ f: Filter) -> Bool {
        switch f {
        case .sensitivity, .sensitivityAtMost:
            return true
        case .all(let fs), .any(let fs):
            return fs.contains(where: isSensitivityFilter)
        case .not(let inner):
            return isSensitivityFilter(inner)
        default:
            return false
        }
    }

    func decodeChannel(_ value: JSONValue?) throws -> CaptureChannel {
        guard let name = try optionalString(value, argument: "channel") else { return .importedFile }
        switch name {
        case "typed": return .typed
        case "voiced": return .voiced
        case "ocr": return .ocr
        case "importedFile": return .importedFile
        case "sensor": return .sensor
        default:
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Unknown channel: \(name)"
            )
        }
    }

    func decodeSensitivity(_ value: JSONValue?) throws -> AdjectiveSensitivity {
        guard let name = try optionalString(value, argument: "sensitivity") else { return .normal }
        switch name {
        case "normal": return .normal
        case "elevated": return .elevated
        case "restricted": return .restricted
        case "secret": return .secret
        default:
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Unknown sensitivity: \(name)"
            )
        }
    }

    /// Decode the optional `exportability` arg for a capture or update call.
    ///
    /// Absent → `.private_` (privacy-preserving default; all existing callers
    /// continue to produce private drawers — DEBT-1 write-side fix).
    /// Accepted string values mirror the `AdjectiveExportability` case names:
    /// `"private"` → `.private_`, `"public"` → `.public_`.
    func decodeExportability(_ value: JSONValue?) throws -> AdjectiveExportability {
        guard let name = try optionalString(value, argument: "exportability") else { return .private_ }
        switch name {
        case "private": return .private_
        case "public": return .public_
        default:
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Unknown exportability: \(name). Accepted values: private, public"
            )
        }
    }

    /// Decode the optional `classificationScheme` arg for a capture.
    /// Absent defaults to `.udc`, preserving the prior bare-UDC behavior.
    func decodeClassificationScheme(_ value: JSONValue?) throws -> ClassificationScheme {
        guard let name = try optionalString(value, argument: "classificationScheme") else { return .udc }
        guard let scheme = ClassificationScheme(rawValue: name) else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Unknown classification scheme: \(name)"
            )
        }
        return scheme
    }

    func decodeContentKind(_ value: JSONValue?) throws -> ContentKind {
        guard let name = try optionalString(value, argument: "kind") else { return .prose }
        switch name {
        case "prose": return .prose
        case "code": return .code
        case "transcript": return .transcript
        case "list": return .list
        case "structuredJSON": return .structuredJSON
        case "imageCaption": return .imageCaption
        default:
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Unknown content kind: \(name)"
            )
        }
    }

    func decodeHydration(_ value: JSONValue?) throws -> HydrationLevel {
        // Absent hydrationLevel defaults to .structured.
        // Present but non-string (e.g. a JSON number or null) is a protocol
        // violation — fail loudly with invalidParams rather than silently
        // accepting malformed input as the default. Mirrors the established
        // idiom for decodeMutationKind in this file, and the Rust
        // decode_hydration_level fix in dispatch.rs.
        guard let name = try optionalString(value, argument: "hydrationLevel") else { return .structured }
        switch name {
        case "structured": return .structured
        case "full": return .full
        case "bitmapOnly": return .bitmapOnly
        default:
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Unknown hydration level: \(name)"
            )
        }
    }

    func decodeMutationKind(_ name: String) throws -> MutationKind {
        switch name {
        case "confirm": return .confirm
        case "reject": return .reject
        case "contest": return .contest
        case "resolve": return .resolve
        case "supersede": return .supersede
        case "revive": return .revive
        case "accept": return .accept
        // Exportability axis — DEBT-1 write path.
        // String spellings mirror decodeExportability: "private" and "public"
        // are the human-readable forms; the substrate enum names (.private_,
        // .public_) use trailing underscores to avoid Swift keyword collisions.
        case "correctExportability(private)": return .correctExportability(.private_)
        case "correctExportability(public)": return .correctExportability(.public_)
        default:
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Unsupported mutation kind: \(name). Accepted: confirm, reject, contest, resolve, supersede, revive, accept, correctExportability(private), correctExportability(public), setSubject (with a `subject` argument)"
            )
        }
    }


    // MARK: - Argument decoders

    func requireString(_ args: [String: JSONValue], _ key: String) throws -> String {
        guard let value = args[key]?.stringValue else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Missing required string argument: \(key)"
            )
        }
        return value
    }

    private func optionalString(_ value: JSONValue?, argument: String) throws -> String? {
        guard let value else { return nil }
        guard let name = value.stringValue else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "\(argument) must be a string; omit it to use the default"
            )
        }
        return name
    }

    private func optionalBool(_ value: JSONValue?, argument: String) throws -> Bool? {
        guard let value else { return nil }
        guard let flag = value.boolValue else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "\(argument) must be a boolean; omit it to use the default"
            )
        }
        return flag
    }

    private func optionalInt(_ value: JSONValue?, argument: String) throws -> Int? {
        guard let value else { return nil }
        guard let raw = value.integerValue else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "\(argument) must be an integer; omit it to use the default"
            )
        }
        return Int(raw)
    }

}

extension ToolDispatcher {
    // MARK: - Structured recall results (MXE-SS)

    /// One structured recall row — the typed twin of a rendered row, per the
    /// recall family's structured-results contract (MXE-SS).
    /// Optional fields are OMITTED (never null) when the text analog is
    /// absent: room/content on opaque rows, content at memory_get
    /// depth:subject, subject at memory_get depth:full when the drawer
    /// carries none.
    struct StructuredRecallRow {
        let id: String
        var room: String? = nil
        var content: String? = nil
        var subject: String? = nil

        var asJSONValue: JSONValue {
            var object: [String: JSONValue] = ["id": .string(id)]
            if let room { object["room"] = .string(room) }
            if let content { object["content"] = .string(content) }
            if let subject { object["subject"] = .string(subject) }
            return .object(object)
        }
    }

    /// MCP `tools/call` success result carrying BOTH the text block —
    /// byte-identical to `textResult` — and its typed twin under
    /// `structuredContent`, the MCP-sanctioned structured-result mechanism
    /// the recall family's `outputSchema` declares. Every redaction the text
    /// path applied must already be applied to `results` by the caller;
    /// this helper only shapes the envelope. Wire-identical to Rust
    /// `interface_tools::structured_text_result`.
    static func structuredTextResult(
        _ text: String, results: [StructuredRecallRow]
    ) -> JSONValue {
        .object([
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(text),
                ])
            ]),
            "structuredContent": .object([
                "results": .array(results.map { $0.asJSONValue })
            ]),
            "isError": .bool(false),
        ])
    }

    /// Wrap a `ComposedResult` from the shared `ResultComposer` into the MCP
    /// `tools/call` result envelope: text in `content[0]`, the composer's
    /// structured block in `structuredContent` (omitted when nil), and
    /// `isError: false`. This is the single MCP-envelope conversion point for
    /// all composer-rendered tools; callers supply a `ComposedResult` and never
    /// build the content/isError/structuredContent envelope themselves.
    ///
    /// Mirrors Rust `dispatch.rs::composed_result`.
    static func composedResult(_ result: ComposedResult) -> JSONValue {
        var obj: [String: JSONValue] = [
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(result.text),
                ])
            ]),
            "isError": .bool(false),
        ]
        if let structured = result.structured {
            obj["structuredContent"] = structured
        }
        return .object(obj)
    }

    /// Build the structured row for a drawer the text path renders as a
    /// candidate row. The subject slot applies provenance-sensitivity redaction:
    /// restricted/secret content is replaced by the redaction marker so the
    /// body's access control cannot be bypassed through its summary. Content
    /// values in hand at the recipe call sites (`PreciseMatch.content`) are
    /// PRE-redaction, so they must pass through this switch, never straight
    /// into a row. Mirrors the composer's CandidateRowData sensitivity handling.
    static func structuredRecallRow(
        id: String,
        room: String?,
        content: String?,
        drawer: Drawer
    ) -> StructuredRecallRow {
        switch drawer.sensitivity {
        case .restricted:
            return StructuredRecallRow(
                id: id, room: room,
                content: content == nil ? nil : ResultComposer.restrictedMarker,
                subject: ResultComposer.restrictedMarker)
        case .secret:
            return StructuredRecallRow(
                id: id, room: room,
                content: content == nil ? nil : ResultComposer.secretMarker,
                subject: ResultComposer.secretMarker)
        case .normal, .elevated:
            return StructuredRecallRow(
                id: id, room: room, content: content,
                subject: drawer.subject ?? ResultComposer.noSubjectMarker)
        }
    }

    private func describe(_ error: VerbError) -> String {
        switch error {
        case .notSupportedByEstate(let verb):
            // notSupportedByEstate is a runtime refusal from the estate — not
            // a missing implementation. Estates that do not expose a verb (e.g.
            // propose / associate, which are substrate-driven Brain-layer verbs
            // not callable by external clients) return this error by design.
            return "Verb \(verb) is not callable on this estate: the estate refused the operation. propose and associate are substrate-driven verbs; for other verbs, check the estate's configuration."
        case .expungeNotConfirmed(let rowID):
            // The caller-facing field is "confirmed" — name it exactly so AI consumers
            // can retry with the correct argument rather than dead-ending on a
            // field name mismatch between this message and the tool schema.
            return "expunge of \(rowID) requires confirmed=true."
        case .emptyReanchor(let rowID):
            return "reanchor of \(rowID) requires at least one of toRoom or toUDC."
        case .underlyingEstateFailure(let verb, let reason):
            // Intercept gate-rejection messages before falling through to the
            // generic form. describeGateRejection returns nil for non-gate errors.
            if let msg = Self.describeGateRejection(verb: verb, reason: reason) {
                return msg
            }
            // Strip internal Rust/Swift type-name prefixes that the substrate
            // error chain can prepend (e.g. "InvalidContent: room must not be
            // empty"). These are implementation-private names that must not
            // appear in AI-client-facing messages (B-6 describe-helper contract).
            // The pattern is "TypeName: message" where TypeName contains no
            // spaces. Strip one such prefix if present; the stripped remainder
            // is the plain English message from the underlying validator.
            let cleanedReason = Self.stripEnumPrefix(from: reason)
            return "\(verb) failed: \(cleanedReason)"
        case .rejectedByLexicon(let verb, let noun):
            return "verb \(verb) is not accepted on noun \(noun) by the AriaLexicon acceptance matrix."
        case .crossKitVectorDeleteFailed(let rowID, let reason):
            // The LocusKit storage expunge succeeded (verbatim content is gone) but
            // the vector embedding in SynapseKit or CorpusKit was NOT deleted. Privacy
            // contract: the expunge is INCOMPLETE. The caller must NOT report this
            // row as fully deleted — the vector embedding is still semantically
            // recoverable. Retry the expunge or surface this error to the user.
            return "expunge of \(rowID) is incomplete: the LocusKit content was removed but the vector embedding survived (\(reason)). Retry the expunge — do not report this row as deleted."
        }
    }

    private func describe(_ error: GeniusLocusKitError) -> String {
        "GeniusLocusKit error: \(error)"
    }

    /// Map an illegal-state-transition gate rejection to an actionable English
    /// message, or return `nil` if `reason` does not encode a gate rejection.
    ///
    /// Parses the state and verb names out of the message text produced by
    /// `GateViolation.description` → `RowStateError.description`. The canonical
    /// pattern is "illegal state transition: <state> --<verb>-->". Conservative:
    /// if parsing fails for any reason, returns `nil` so the caller falls
    /// through to the generic "\(verb) failed: \(reason)" form.
    ///
    /// Parity with Rust `describe_gate_rejection` in AriaMcpKit/interface_tools.rs.
    ///
    /// Message table (same rows as the Rust impl):
    ///
    ///     active  + reject          → "cannot reject an active memory; contest or withdraw it first"
    ///     active  + promote/accept  → "only pending memories can be accepted; this memory is already active"
    ///     accepted + reject/contest → "accepted memories are audit-grade and cannot be rejected or
    ///                                   contested; supersede or withdraw instead"
    ///     rejected + reject         → "memory is already rejected"
    ///     rejected + *              → "rejected memories cannot be mutated this way; re-file the
    ///                                   content to start a new memory"
    ///     pending  + supersede      → "cannot supersede a pending memory; confirm or reject it first"
    ///     tombstoned + *            → "memory has been permanently erased and cannot be mutated"
    ///     *        + *              → "the memory's current state (<state>) does not allow this
    ///                                   mutation; check it with moot_memory_search"
    /// Internal and static so the v2 mutation surface can reach it too. It
    /// was private to this type, which is the only reason a v2 gate refusal
    /// came back as a generic "unavailable": the translator existed and
    /// nothing outside the v1 dispatch table could call it.
    static func describeGateRejection(verb: String, reason: String) -> String? {
        let sentinel = "illegal state transition: "
        guard let sentinelRange = reason.range(of: sentinel) else { return nil }
        let tail = String(reason[sentinelRange.upperBound...])
        // Parse "<state> --<verb>-->" out of tail.
        guard let dashRange = tail.range(of: " --") else { return nil }
        let fromStr = String(tail[..<dashRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        let afterDash = String(tail[dashRange.upperBound...])
        guard let endRange = afterDash.range(of: "-->") else { return nil }
        let gateVerb = String(afterDash[..<endRange.lowerBound]).trimmingCharacters(in: .whitespaces)

        let body: String
        switch (fromStr, gateVerb) {
        case ("active", "reject"):
            body = "cannot reject an active memory; contest or withdraw it first"
        case ("active", "promote"), ("active", "accept"):
            body = "only pending memories can be accepted; this memory is already active"
        case ("accepted", "reject"), ("accepted", "contest"):
            body = "accepted memories are audit-grade and cannot be rejected or contested; supersede or withdraw instead"
        case ("rejected", "reject"):
            body = "memory is already rejected"
        case ("rejected", _):
            body = "rejected memories cannot be mutated this way; re-file the content to start a new memory"
        case ("pending", "supersede"):
            body = "cannot supersede a pending memory; confirm or reject it first"
        case ("tombstoned", _):
            body = "memory has been permanently erased and cannot be mutated"
        default:
            body = "the memory's current state (\(fromStr)) does not allow this mutation; check it with moot_memory_search"
        }
        return "\(verb) failed: \(body)"
    }

    /// Test-visible wrapper for `stripEnumPrefix(from:)`. Exposes the private
    /// helper for unit testing without making it fully public.
    /// `@testable import AriaMCP` gives the test target access to `internal`.
    static func stripEnumPrefixForTest(_ reason: String) -> String {
        stripEnumPrefix(from: reason)
    }

    /// Strip a leading `EnumCaseName: ` prefix from a substrate error reason
    /// string, when present. The substrate error chain can prepend type/variant
    /// names like "InvalidContent: " that are internal implementation details
    /// and must not appear in AI-client-facing messages (B-6 describe-helper
    /// contract). Parity with Rust `strip_enum_prefix` in `interface_tools.rs`.
    ///
    /// Strips at most one prefix. The pattern is: a run of non-space, non-colon
    /// characters followed by ": ". If the prefix looks like an enum variant
    /// name (no lowercase word boundary gap, no spaces) the remainder is
    /// returned; otherwise the original is returned unchanged.
    private static func stripEnumPrefix(from reason: String) -> String {
        // Find the first ": " in the string.
        guard let colonRange = reason.range(of: ": ") else { return reason }
        let prefix = String(reason[..<colonRange.lowerBound])
        // A valid enum-case prefix contains only alphanumeric characters and
        // underscores — no spaces, no punctuation other than underscore.
        // "InvalidContent", "BasisViolation", "StateError" all qualify.
        // A plain English sentence fragment like "state mutation rejected by
        // gate" does NOT qualify (it contains spaces).
        let isEnumLike = prefix.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
        guard isEnumLike && !prefix.isEmpty else { return reason }
        // Return the remainder after the ": " separator.
        return String(reason[colonRange.upperBound...])
    }
}


// MARK: - Server-owned defaults

extension ToolDispatcher {
    /// The canonical unclassified-content sentinel UDC code passed to the
    /// capture seam when the caller does not supply an explicit anchor.
    /// The GeniusLocusKit seam (`capture(_:_:mode:)`) classifies the content
    /// via EideticLib.lookup when it sees this sentinel and the content is
    /// non-empty; UNRESOLVED content keeps the sentinel and files at the UDC
    /// root. Matches GeniusLocusKit.unclassifiedSentinel and the Rust
    /// `UNCLASSIFIED_SENTINEL` constant.
    static let defaultLatticeAnchor = LatticeAnchor.udc("000")

    /// Embedding model ID that selects the deterministic vector provider.
    /// GeniusLocusKit resolves "default" to `EmbeddingModelConfig.deterministic`
    /// — the permanent, federation-grade float vector lane (Lane D). The
    /// deterministic provider uses FNV-1a tokenization + FloatSimHash projection,
    /// is model-free, and produces byte-identical vectors cross-device and
    /// cross-port. This is what federation requires: reproducible without any
    /// model bundle or on-device inference runtime.
    ///
    /// The learned semantic vector (the span encoder's MiniLM provider) is an
    /// ADDITIVE v1.1 on-device lane — a richer, model-dependent signal that
    /// enhances on-device search but cannot serve as the federation vector
    /// (model-dependent → not reproducible cross-device). It does not replace
    /// the deterministic vector; both coexist as separate lanes.
    static let defaultEmbeddingModelID = "default"
}

// MARK: - Tier 1: Core Memory runners

extension ToolDispatcher {

    /// `moot_file_memory` — file a new memory drawer into the estate.
    ///
    /// The server owns infrastructure fields: lattice anchor (classified via
    /// The seam classifies via EideticLib.lookup; falls back to UDC "000" for UNRESOLVED content),
    /// embedding model ("default"), capture channel (.actuator, cookbook §2.4 —
    /// actuator-driven capture by an MCP AI agent), source type (.imported),
    /// and addedBy (the dispatcher's `serverIdentity`). The caller supplies content, location,
    /// and optional adjectives (kind, sensitivity, exportability).
    ///
    /// `now` is the dispatch-boundary instant and gates the sensitivity-grant check
    /// below; the `Date()` default covers direct runner calls in tests, the
    /// same convention as `runMemoryGet`.
    func runFileMemory(_ args: [String: JSONValue], now: Date = Date()) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let content = try requireString(args, "content")
        let location = try requireString(args, "location")
        // Subject is REQUIRED at this boundary (PR-02): the calling AI is the
        // only party that knows what the content asserts, and a subject
        // written at capture is the cheapest one the estate will ever get.
        // The error is instructive rather than the generic missing-argument
        // text because the fix is a register, not just a field.
        guard let subject = args["subject"]?.stringValue else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Missing required argument: subject. Provide one sentence "
                    + "(≤\(DrawerStore.subjectLengthContract) chars) stating what this memory "
                    + "asserts, written for the NEXT AI that will scan it — telegraphic, "
                    + "entities and claims front-loaded, no narrative framing. "
                    + "Example: \"Quarterly planning moved to Thursday; Sarah sends invites Monday.\""
            )
        }
        let trimmedSubject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        // This is the v1 `runFileMemory` path. It counts Unicode scalars, not
        // grapheme clusters. The v2 surface (ToolDispatcher.dispatch) and both
        // ports count grapheme clusters for the same contract. The v1 count
        // here is not reached by the shipped v2 dispatch.
        let subjectLength = trimmedSubject.unicodeScalars.count
        guard subjectLength > 0, subjectLength <= DrawerStore.subjectLengthContract else {
            // Return as an isError result rather than throwing a JSON-RPC protocol error.
            // MCP clients render thrown JSON-RPC errors as bare "Tool execution failed"
            // and discard the message. An isError result puts the contract text in front
            // of the model so it can compress and retry. Mirrors the Rust port's
            // TOOL_DISPATCH_FAILURE path in run_file_memory (interface_tools.rs).
            return Self.errorResult(
                "subject must be 1–\(DrawerStore.subjectLengthContract) characters "
                    + "(got \(subjectLength)). One telegraphic sentence in the AI-facing "
                    + "register — compress, don't truncate."
            )
        }
        // SECURITY: a memory filed while a restricted or secret grant is live
        // may carry material recalled under that grant (the context-meter
        // hook's checkpoint and handoff notes do exactly that), so the write
        // side shares the read side's ceiling from the same ledger. An
        // omitted sensitivity files at the grant's tier; an explicit tier
        // below it is refused as an isError result naming the ceiling so the
        // model can retry (a thrown JSON-RPC error would reach it as a bare
        // "Tool execution failed"); an explicit tier at or above it is kept.
        // With no live grant the argument decodes exactly as before, default
        // `.normal`. Mirrors the Rust port's run_file_memory.
        let grantCeiling = await sensitivityUnlockLedger.ceilingSensitivity(now: now)
        let sensitivity: AdjectiveSensitivity
        if args["sensitivity"] == nil {
            sensitivity = grantCeiling ?? .normal
        } else {
            let requested = try decodeSensitivity(args["sensitivity"])
            if let ceiling = grantCeiling, requested.rawValue < ceiling.rawValue {
                return Self.errorResult(Self.sensitivityBelowCeilingMessage(
                    requested: requested, ceiling: ceiling))
            }
            sensitivity = requested
        }
        let exportability = try decodeExportability(args["exportability"])
        let kind = try decodeContentKind(args["kind"])
        let eventTime: Date?
        if let rawEventTime = try optionalString(args["event_time"], argument: "event_time") {
            guard let parsed = ISO8601DateFormatter().date(from: rawEventTime) else {
                throw JSONRPCError(
                    code: JSONRPCErrorCode.invalidParams,
                    message: "event_time is not a valid ISO8601 instant: \(rawEventTime)"
                )
            }
            eventTime = parsed
        } else {
            eventTime = nil
        }
        // D-A: `impatient` is an execution option on the write verb, mirroring
        // how `scoring` is an option on the recall verb — it is threaded to the
        // GLK verb param, NOT stamped onto the CaptureFrame schema. Default
        // false = regular mode (write returns immediately; encoding is
        // background). True = inline-encode before returning.
        let impatient = try optionalBool(args["impatient"], argument: "impatient") ?? false
        let mode: WriteMode = impatient ? .impatient : .regular
        // optional `wing` argument routes this memory into a specific wing.
        // When supplied, the drawer files into that wing.
        // When absent, defaults to LocusKit.defaultWingName ("Agentic Memory") — the AI's
        // working memory wing. `location` maps to room only and never encodes a wing.
        let wing: String? = try optionalString(args["wing"], argument: "wing") ?? LocusKit.defaultWingName
        // location is a caller-facing subject-matter hint; map it to the
        // room field (structural coordinate) only.
        let room = location
        // Pass the unclassified sentinel anchor to the capture seam. The seam
        // (GeniusLocusKit.capture(_:_:mode:)) classifies the content via
        // EideticLib.lookup when it sees the "000" sentinel — one classification
        // door for all capture paths (file_memory, vault import, branch promotion).
        // This removes the per-caller FDC call that was here before the one-door
        // refactor; the seam now owns classification exclusively.
        let frame = CaptureFrame(
            content: content,
            channel: Self.defaultChannel,
            room: room,
            latticeAnchor: Self.defaultLatticeAnchor,
            addedBy: serverIdentity,
            embeddingModelID: Self.defaultEmbeddingModelID,
            sensitivity: sensitivity,
            kind: kind,
            provenanceChannel: .mcpAgent,
            sourceType: .imported,
            eventTime: eventTime,
            exportability: exportability,
            wing: wing,
            subject: trimmedSubject
        )
        // Mode-aware capture: regular enqueues the encode job (background
        // semantic indexing); impatient encodes inline before returning.
        let drawer = try await kit.capture(handle, frame, mode: mode)
        // Resolve the drawer's parentNodeId to a display room name via the
        // node tree (Drawer no longer carries stored wing/room after node-tree integrity).
        let nodeNames = try await kit.resolveNodeNames(handle, 
            parentNodeIds: [drawer.parentNodeId])
        let roomName = nodeNames[drawer.parentNodeId]?.room ?? ""
        var lines = [
            "filed memory \(drawer.id)",
            "room: \(roomName)",
            "lineage: \(drawer.lineageID.uuidString)",
        ]
        // Under a live grant the reply names the tier the memory was filed
        // at, so a caller that omitted the argument learns the floor the
        // server applied. With no grant the reply keeps its prior shape.
        if grantCeiling != nil {
            lines.append("sensitivity: \(Self.sensitivityArgumentName(sensitivity))")
        }
        return Self.textResult(lines.joined(separator: "\n"))
    }

    /// The `sensitivity` argument spelling of a tier, the inverse of
    /// `decodeSensitivity`; used in replies and refusals that name a tier.
    static func sensitivityArgumentName(_ sensitivity: AdjectiveSensitivity) -> String {
        switch sensitivity {
        case .normal: return "normal"
        case .elevated: return "elevated"
        case .restricted: return "restricted"
        case .secret: return "secret"
        }
    }

    /// The refusal text for an explicit `sensitivity` below the live grant
    /// ceiling. Byte-identical in the Rust port (`run_file_memory`) so a
    /// client sees one message whichever port serves it.
    static func sensitivityBelowCeilingMessage(
        requested: AdjectiveSensitivity, ceiling: AdjectiveSensitivity
    ) -> String {
        let want = sensitivityArgumentName(requested)
        let have = sensitivityArgumentName(ceiling)
        return "sensitivity \(want) is below the live grant ceiling \(have): while a \(have) "
            + "grant is live a memory files at \(have) or higher. Omit sensitivity to file "
            + "at the ceiling."
    }


    /// `moot_memory_get` — fetch one memory drawer by id, in full.
    ///
    /// Closes the "fetch-drawer-by-ID" MCP API gap — build-now per Bob's
    /// ruling, not deferred to v1.1.
    ///
    /// Reifies the ARIA `recall` verb (docs/concepts/ARIA_LEXICON.md) applied
    /// to the Drawer noun, constrained by an exact identifier rather than
    /// free-text/criteria — `moot_memory_search`'s degenerate, precise
    /// sibling. Named `memory_get` (noun_verb) per the lexicon's own naming
    /// discipline: "an action tool is verb_noun, a query tool is noun_verb."
    /// `recall` is caller-driven like the mutation verbs, but it is a QUERY,
    /// so it follows `moot_memory_search`'s noun_verb convention, not
    /// `moot_file_memory`/`moot_update_memory`/`moot_withdraw_memory`'s
    /// verb_noun convention (those reify capture/mutate/withdraw, a
    /// different verb class).
    ///
    /// Routes through the SAME frame-faithful by-id load
    /// (`Estate.getDrawers(ids:matchingFrame:hydrationLevel:)`) that backs
    /// `moot_memory_search`'s recall pipeline, with an EMPTY filter chain so
    /// `BitmapEvaluator`'s default gate applies unchanged: currentlyBelieve
    /// state, trustworthy trust, sensitivityAtMost(.elevated) — the
    /// IDENTICAL gate `moot_memory_search` applies by default (no filter
    /// argument on this tool — the by-id door has no adjective knobs to
    /// widen it). A drawer that exists but fails that gate (contested/
    /// superseded/withdrawn/expired/rejected state, derived/proposed/ambient
    /// trust, or restricted/secret ADJECTIVE sensitivity, bits 6-11) is
    /// reported exactly like a genuinely absent id: "Memory not found: <id>".
    /// Provenance sensitivity is a SEPARATE axis and this chain does not check
    /// it — see the second gate below. This is deliberate —
    /// the by-id door must not become a way to confirm the EXISTENCE of
    /// content the estate would otherwise refuse to surface. Tombstoned rows
    /// are always excluded, independent of the chain.
    ///
    /// Hydration is `.full` (verbatim content, matching what was captured) —
    /// never `.structured`, which strips the content blob this tool exists
    /// to return.
    ///
    /// A SECOND gate applies past the RecallFrame chain: provenance
    /// sensitivity (bits 30-35, `Drawer.sensitivity`) is a different axis from
    /// the adjective sensitivity the chain checks. Provenance `.restricted`
    /// and `.secret` stay access-controlled at the MCP boundary and are
    /// reported with the same not-found shape as every other gate failure,
    /// matching `moot_memory_search`'s unconditional preview redaction.
    /// Mirrors Rust `run_memory_get`.
    ///
    /// B-10a reward wiring: after successfully resolving the drawer, `noteUsage`
    /// is called for every returned drawer id. If that id appeared in a prior
    /// `moot_memory_search` result in this session, `noteUsage` calls
    /// `kit.markRecallUsed` so the dreaming daemon's reward sweep later assigns
    /// reward=1.0 (the "used" bit is set on the drawer's recall-trace rows).
    /// This closes the gap where a search-then-get workflow never fired the
    /// reward because memory_get was not a registered dereference verb. Failure
    /// is silenced — reward marking must not break the primary result.
    ///
    /// An active sensitivity-unlock grant lifts the ADJECTIVE ceiling ONLY.
    /// Provenance `.restricted` and `.secret` remain CLOSED under grant in both
    /// verticals: the provenance gate below is unconditional and does not
    /// consult the grant ledger. Rust returns not-found unconditionally, and
    /// matching Swift to it is the conservative reading. If that ruling is
    /// revisited so a grant lifts provenance too, both verticals change
    /// together or the conformance parity breaks.
    /// `now` is threaded from the bench clock seam. Default `Date()` covers
    /// direct runner calls in tests (wall-clock mode; determinism not required there).
    func runMemoryGet(_ args: [String: JSONValue], now: Date = Date()) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        // Hydration depth (PR-03): one verb, three tiers.
        //   subject   — dense row only (travel tier)
        //   distilled — dense row + distilled rendering (confirm tier;
        //               inline rendering via ContextDistillLib — every row
        //               renders without a sweep dependency)
        //   full      — the complete record incl. verbatim content
        //               (terminal tier; the DEFAULT, preserving the
        //               pre-PR-03 single-id reply byte-for-byte-ish shape)
        // Batch `ids:[...]` makes the Case-2 winnow one call: pinpoint a
        // shortlist at depth:subject/distilled without hauling full text.
        let depthName = try optionalString(args["depth"], argument: "depth") ?? "full"
        guard ["subject", "distilled", "skim", "full"].contains(depthName) else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Unknown depth: \(depthName). Valid: subject, distilled, skim, full"
            )
        }
        // `id` (single, the original arg) or `ids` (batch) — at least one.
        // A single `id` is sugar for ids:[id]; the single-id + depth:full
        // path renders the original full record and keeps the original
        // thrown not-found, so existing callers observe no change.
        var rowIDs: [String] = []
        if let single = try optionalString(args["id"], argument: "id") {
            rowIDs.append(single)
        }
        if case let .array(rawIDs)? = args["ids"] {
            for raw in rawIDs {
                guard let s = raw.stringValue else {
                    throw JSONRPCError(
                        code: JSONRPCErrorCode.invalidParams,
                        message: "ids must be an array of memory UUID strings")
                }
                rowIDs.append(s)
            }
        }
        guard !rowIDs.isEmpty else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Provide id (single memory UUID) or ids (array of UUIDs).")
        }
        let singleIDMode = rowIDs.count == 1
        let rowID = rowIDs[0]

        // sensitivity unlock: same grant-ceiling injection as
        // sensitivity unlock: the same containment gate moot_memory_search
        // uses applies here too (per moot_memory_get's doc history), so the grant must
        // lift it here too, or an unlocked restricted/secret row would be
        // visible in search but still "not found" by id — an inconsistent,
        // confusing half-unlock.
        var filterChain: [Filter] = []
        // `now` is threaded from the bench clock seam — not Date() directly.
        var sensitivityCeilingLifted = false
        if let ceiling = await sensitivityUnlockLedger.ceilingFilter(now: now) {
            filterChain.append(ceiling)
            sensitivityCeilingLifted = true
        }
        let frame = RecallFrame(filterChain: filterChain, hydrationLevel: .full)
        let filtered = try await kit.getDrawers(in: handle, 
            ids: rowIDs, matchingFrame: frame, hydrationLevel: .full)
        // Provenance-sensitivity redaction boundary for by-id reads: the
        // RecallFrame gate above checks adjective sensitivity (bits 6-11);
        // Drawer.sensitivity decodes provenance sensitivity (bits 30-35),
        // where Restricted/Secret content is access-controlled and must not
        // be returned verbatim. Unconditional — the grant ledger lifts the
        // adjective ceiling only. Gated rows use the standard not-found
        // shape so by-id lookup is not an oracle for hidden rows.
        // Mirrors Rust `run_memory_get` (conformance parity).
        let admissibleByID = Dictionary(uniqueKeysWithValues: filtered.admissible.compactMap {
            d -> (String, Drawer)? in
            switch d.sensitivity {
            case .restricted, .secret: return nil
            case .normal, .elevated: return (d.id, d)
            }
        })
        // Single-id compat: the original thrown not-found stays. In batch
        // mode gate failures become per-row "not found:" lines instead —
        // fail-loud without sinking the whole winnow call.
        if singleIDMode, admissibleByID[rowID] == nil {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Memory not found: \(rowID)"
            )
        }

        // Batch / shallow-depth rendering (COMPOSER-02B). All paths go through
        // ResultComposer typed intermediates; sensitivity_advisory removed from
        // payload (moved to tool description text per BRR §Part 1).
        //
        // depth:subject  → S2 rows via renderS2BatchGet (S2 row per drawer, no body)
        // depth:distilled → S2 row + distilled continuation per drawer
        // depth:full (batch) → S3 full record per drawer via renderS3Record
        // depth:full (single) → S3 full record via renderS3Record (falls through)
        if !singleIDMode || depthName != "full" {
            // One batched node-name read for room over the admissible rows.
            let getNodeNames = try await kit.resolveNodeNames(handle, 
                parentNodeIds: rowIDs.compactMap { admissibleByID[$0]?.parentNodeId })

            // depth:subject — S2 batch-get shape.
            if depthName == "subject" {
                var entries: [ResultComposer.BatchGetEntry] = []
                for id in rowIDs {
                    guard let d = admissibleByID[id] else {
                        entries.append(.notFound(id)); continue
                    }
                    await noteUsage(id, handle: handle)
                    if sensitivityCeilingLifted {
                        switch d.adjectiveSensitivity {
                        case .restricted, .secret:
                            try? await kit.recordSensitivityReadUnderGrant(
                                handle, tier: d.adjectiveSensitivity, drawerID: d.id, now: now)
                        case .normal, .elevated: break
                        }
                    }
                    entries.append(.found(CandidateRowData(
                        id: d.id,
                        subject: d.subject,
                        eventTime: ResultComposer.iso8601(d.eventTime),
                        room: getNodeNames[d.parentNodeId]?.room)))
                }
                let resolved = entries.filter { if case .found = $0 { true } else { false } }.count
                let composed = ResultComposer.renderS2BatchGet(
                    entries: entries, resolved: resolved, requested: rowIDs.count)
                return Self.composedResult(composed)
            }

            // depth:distilled — S2 row + distilled continuation; depth:full in
            // batch mode — one S3 record per drawer. Both render per-row.
            var lines: [String] = []
            var skimRows: [JSONValue] = []
            for id in rowIDs {
                guard let d = admissibleByID[id] else {
                    lines.append("not found: \(id)"); continue
                }
                await noteUsage(id, handle: handle)
                if sensitivityCeilingLifted {
                    switch d.adjectiveSensitivity {
                    case .restricted, .secret:
                        try? await kit.recordSensitivityReadUnderGrant(
                            handle, tier: d.adjectiveSensitivity, drawerID: d.id, now: now)
                    case .normal, .elevated: break
                    }
                }
                if depthName == "skim" {
                    let skim = try RecallSkim(original: d.content)
                    lines.append(ResultComposer.renderS2Row(CandidateRowData(id: d.id, subject: d.subject, eventTime: ResultComposer.iso8601(d.eventTime))))
                    lines.append(skim.rendered)
                    var row: [String: JSONValue] = ["id": .string(d.id), "skim": skim.json]
                    if let subject = d.subject { row["subject"] = .string(subject) }
                    skimRows.append(.object(row))
                } else if depthName == "distilled" {
                    // S2 row header (no score column) + inline-distilled continuation.
                    // Distillation is computed at read time via ContextDistiller —
                    // the stored distilled column is removed in schema 19 (W1).
                    let row = CandidateRowData(
                        id: d.id,
                        subject: d.subject,
                        bestSpan: d.content.isEmpty ? nil : d.content,
                        // sscFacts: stubbed nil until W1 schema-19 Drawer.sscFacts lands
                        sscFacts: nil,
                        eventTime: ResultComposer.iso8601(d.eventTime),
                        room: getNodeNames[d.parentNodeId]?.room)
                    lines.append(ResultComposer.renderS2Row(row))
                    // Same converter and rendering as the typed v2 get path.
                    let distilledText = RecallDistillation.render(d.content)
                    lines.append("    \(distilledText)")
                } else {
                    // depth:full in batch mode — S3 full record per drawer.
                    let names = getNodeNames[d.parentNodeId] ?? (wing: "", room: "")
                    let allTunnels = try await kit.allTunnels(in: handle)
                    let linked = allTunnels.filter {
                        ($0.sourceDrawerId == d.id || $0.targetDrawerId == d.id)
                            && $0.tombstonedAt == nil && $0.lifecycle == .active
                    }
                    let tunnels = linked.prefix(50).map { tunnel -> FullRecordTunnel in
                        let outgoing = tunnel.sourceDrawerId == d.id
                        let other = outgoing
                            ? (tunnel.targetDrawerId ?? "\(tunnel.targetWing)/\(tunnel.targetRoom)")
                            : (tunnel.sourceDrawerId ?? "\(tunnel.sourceWing)/\(tunnel.sourceRoom)")
                        return FullRecordTunnel(isOutgoing: outgoing, otherID: other, label: tunnel.label)
                    }
                    let record = FullRecordData(
                        id: d.id,
                        room: names.room, wing: names.wing,
                        subject: d.subject,
                        filedAt: ResultComposer.iso8601(d.filedAt),
                        eventTime: ResultComposer.iso8601(d.eventTime),
                        state: String(describing: d.state),
                        trust: String(describing: d.trust),
                        sensitivity: String(describing: d.adjectiveSensitivity),
                        exportability: String(describing: d.exportability),
                        confirmation: String(describing: d.confirmation),
                        lineageID: d.lineageID.uuidString,
                        tunnels: Array(tunnels),
                        content: d.content)
                    lines.append(contentsOf: ResultComposer.renderS3Record(record).text
                        .components(separatedBy: "\n"))
                }
                lines.append("")   // blank separator between multi-row replies
            }
            if lines.last == "" { lines.removeLast() }
            return Self.composedResult(ComposedResult(text: lines.joined(separator: "\n"), structured: depthName == "skim" ? .object(["results": .array(skimRows)]) : nil))
        }

        // Single-id depth:full path — S3 full record via renderS3Record (absorbs fullRecordLines).
        let drawer = admissibleByID[rowID]!

        // B-10a: memory_get is a dereference verb. If this drawer was surfaced
        // by a prior moot_memory_search in this session, fire the reward path
        // so the dreaming daemon assigns reward=1.0. Best-effort: noteUsage
        // never throws to the caller. Same contract as the mutation verbs
        // (moot_update_memory, moot_withdraw_memory, moot_confirm_memory, etc.).
        await noteUsage(rowID, handle: handle)

        // Same read-under-grant audit recording as moot_memory_search — gated on
        // BOTH the ceiling having been lifted AND the drawer's own sensitivity
        // actually being restricted/secret.
        if sensitivityCeilingLifted {
            switch drawer.adjectiveSensitivity {
            case .restricted, .secret:
                try? await kit.recordSensitivityReadUnderGrant(
                    handle, tier: drawer.adjectiveSensitivity, drawerID: drawer.id, now: now)
            case .normal, .elevated:
                break
            }
        }

        // Resolve node names and active tunnels for the S3 record.
        // sensitivity_advisory removed from payload (moved to tool description text).
        let nodeNames = try await kit.resolveNodeNames(handle, parentNodeIds: [drawer.parentNodeId])
        let names = nodeNames[drawer.parentNodeId] ?? (wing: "", room: "")
        let allTunnels = try await kit.allTunnels(in: handle)
        let linked = allTunnels.filter {
            ($0.sourceDrawerId == drawer.id || $0.targetDrawerId == drawer.id)
                && $0.tombstonedAt == nil && $0.lifecycle == .active
        }
        let tunnels = linked.prefix(50).map { tunnel -> FullRecordTunnel in
            let outgoing = tunnel.sourceDrawerId == drawer.id
            let other = outgoing
                ? (tunnel.targetDrawerId ?? "\(tunnel.targetWing)/\(tunnel.targetRoom)")
                : (tunnel.sourceDrawerId ?? "\(tunnel.sourceWing)/\(tunnel.sourceRoom)")
            return FullRecordTunnel(isOutgoing: outgoing, otherID: other, label: tunnel.label)
        }
        let record = FullRecordData(
            id: drawer.id,
            room: names.room, wing: names.wing,
            subject: drawer.subject,
            filedAt: ResultComposer.iso8601(drawer.filedAt),
            eventTime: ResultComposer.iso8601(drawer.eventTime),
            state: String(describing: drawer.state),
            trust: String(describing: drawer.trust),
            sensitivity: String(describing: drawer.adjectiveSensitivity),
            exportability: String(describing: drawer.exportability),
            confirmation: String(describing: drawer.confirmation),
            lineageID: drawer.lineageID.uuidString,
            tunnels: Array(tunnels),
            content: drawer.content)
        return Self.composedResult(ResultComposer.renderS3Record(record))
    }

    /// Records best-effort recall usage for the retained memory-get runner.
    private func noteUsage(_ rowID: String, handle: EstateHandle) async {
        guard posture == .live else { return }
        guard await recallLedger.entry(for: rowID) != nil else { return }
        let now = Date()
        do {
            _ = try await kit.markRecallUsed(handle, target: rowID, now: now)
        } catch {
            // Usage accounting must not fail the primary dereference.
        }
    }

}

// MARK: - Tier 3: Knowledge Graph runners

extension ToolDispatcher {

    /// `moot_fact_search` — retrieve all currently-active KG facts.
    ///
    /// Fact storage is independent of the memory recall pipeline — facts are
    /// filed as LocusKit KGFact rows, not as Drawer rows, so the dense vector
    /// lane (Lane D) does not participate in fact retrieval. When the caller
    /// supplies a query, matching is a case-insensitive substring scan across
    /// subject, predicate, and object.
    ///
    /// When a query is present, a dark-lane probe runs to populate the log
    /// with the dense-lane status. The probe result is NOT appended to the
    /// payload (recall_provenance removed from payload per COMPOSER-02B;
    /// log-side only). Fact search is purely lexical regardless of lane state.
    func runFactSearch(_ args: [String: JSONValue]) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        // Optional query: substring match across subject, predicate, and object.
        // Omitting query returns all active facts (the unfiltered case).
        let queryRaw = try optionalString(args["query"], argument: "query")
        let query = queryRaw?.lowercased()
        let subjectExact = try optionalString(args["subject_exact"], argument: "subject_exact")
        let predicateExact = try optionalString(args["predicate_exact"], argument: "predicate_exact")
        let objectExact = try optionalString(args["object_exact"], argument: "object_exact")
        let sourceExact = try optionalString(args["source_id_exact"], argument: "source_id_exact")
        let limit = try Self.clampLimit(
            optionalInt(args["limit"], argument: "limit"),
            argument: "limit",
            default: 100
        )
        // Push subject and sourceDrawerID equality predicates into SQL when
        // present. The active-cluster guard (g_state_cluster < 16) is always
        // in the SQL WHERE; only rows that satisfy it are decoded in Swift.
        // idx_kg_facts_subject and idx_kg_facts_sourceDrawer let the engine
        // seek rather than scan when these columns are constrained.
        // predicateExact, objectExact, and the substring query remain in-memory.
        let allFactsRaw = try await kit.kgFacts(in: handle, 
            subjectEq: subjectExact,
            sourceDrawerIDEq: sourceExact
        )
        // MCP disclosure ceiling: drop Restricted/Secret facts before any output.
        // Parity with the default BitmapEvaluator ceiling (SensitivityAtMost(Elevated))
        // that normal recall applies via insertDefaults. Filter at the ARIA tool boundary
        // only — recallKGFacts has internal callers that need the full set.
        let allFacts = allFactsRaw.filter { $0.adjectiveSensitivity.isBulkExportable }
        let facts = allFacts.filter { fact in
            let queryMatches = query.map { q in
                fact.subject.lowercased().contains(q) ||
                fact.predicate.lowercased().contains(q) ||
                fact.object.lowercased().contains(q)
            } ?? true
            return queryMatches
                && (predicateExact.map { fact.predicate == $0 } ?? true)
                && (objectExact.map { fact.object == $0 } ?? true)
        }
        // Gate source-drawer IDs: for each distinct sourceDrawerID in the facts we are
        // about to emit, check whether it references an actual drawer row in the estate.
        // If it does AND is Restricted/Secret (outside the default sensitivity ceiling),
        // hide the ID at the MCP boundary. sourceDrawerID holds a local drawer id or "",
        // so the only non-matching value is the empty one, which names no drawer.
        // We use getDrawers(ids:matchingFrame:hydrationLevel:) which returns both the
        // admissible set and the full loadedIDs set — the difference is the blocked set.
        // Parity with Rust run_fact_search.
        let emittedFacts = Array(facts.prefix(limit))
        let distinctSourceIDs = Array(Set(emittedFacts.map { $0.sourceDrawerID }))
        let hiddenSourceIDs: Set<String>
        if distinctSourceIDs.isEmpty {
            hiddenSourceIDs = []
        } else {
            let result = try await kit.getDrawers(in: handle, 
                ids: distinctSourceIDs,
                matchingFrame: RecallFrame(filterChain: []),
                hydrationLevel: .structured
            )
            // loaded but not admissible = exists as a drawer AND is Restricted/Secret
            let admissibleIDs = Set(result.admissible.map { $0.id })
            hiddenSourceIDs = result.loadedIDs.subtracting(admissibleIDs)
        }
        // Build S4 typed rows and render via ResultComposer.renderS4FactSearch
        // (COMPOSER-02B). recall_provenance removed from payload (log-side only
        // per BRR §Part 1); dark-lane probe still runs but the result is logged
        // rather than appended to the payload.
        let formatter = ISO8601DateFormatter()
        let factRows = emittedFacts.map { f -> FactSearchRow in
            let filed = formatter.string(from: f.filedAt)
            // Gate source-drawer ID on sensitivity: hide only when the drawer
            // exists AND is Restricted/Secret. A sourceless fact (empty string)
            // maps to nil → column renders '-'.
            let sourceID: String? = hiddenSourceIDs.contains(f.sourceDrawerID)
                ? nil
                : (f.sourceDrawerID.isEmpty ? nil : f.sourceDrawerID)
            return FactSearchRow(
                factID: f.id,
                subject: f.subject,
                predicate: f.predicate,
                object: f.object,
                sourceDrawerID: sourceID,
                filedAt: filed)
        }
        return Self.composedResult(ResultComposer.renderS4FactSearch(facts: factRows))
    }
}

// MARK: - Server defaults (private)

private extension ToolDispatcher {
    /// Default capture channel for server-filed memories: `actuator` (raw 5,
    /// cookbook §2.4) signals that content is submitted by an MCP AI agent
    /// (actuator-driven capture), not a file import and not typed by a user.
    static let defaultChannel: CaptureChannel = .actuator

    /// Estate-wide floor meta key: after a successful full FDC reclassification
    /// apply, this records the composite classifier/artifact version against
    /// which all active stored anchors have been checked or repaired. Also read
    /// by `moot_estate_status` to report `fdc_recalculation` state.
    static let fdcRecalcedDataVersionMetaKey = "aria.fdc.recalced_data_version"
}

extension ToolDispatcher {
    /// Shared v2 reindex launch seam. The actor prevents duplicate deferred
    /// work while the selected data-mobility operation is in flight.
    private static let reindexGuard = ReindexGuard()

    static func startReindex(
        kit: GeniusLocusKit,
        handle: EstateHandle,
        now: Date
    ) async -> AriaV2ReindexReceipt {
        guard await reindexGuard.tryStart() else {
            return .alreadyRunning
        }
        Task.detached { [kit] in
            defer { Task { await Self.reindexGuard.finish() } }
            do {
                let count = try await kit.reindexMissing(handle: handle, now: now)
                fputs("reindex: background backfill complete — \(count) drawers indexed to full coverage\n", stderr)
            } catch {
                fputs("reindex: background backfill failed: \(error)\n", stderr)
            }
        }
        return .running
    }

    private static func clusterLabel(_ cluster: RowStateCluster) -> String {
        switch cluster {
        case .a: return "A"
        case .b: return "B"
        case .c: return "C"
        }
    }

    /// Shared lifecycle projection retained for the Swift/Rust conformance
    /// suite; the selected timeline surface uses the same state automaton.
    static func lifecycleTag(forAdjectiveBitmap adjectiveBitmap: Int64) -> String {
        let stateRaw = UInt8(adjectiveBitmap & 0x3F)
        switch RowState.cluster(ofRawState: stateRaw) {
        case .a:
            return "active"
        case .some(let cluster):
            return "retired(\(clusterLabel(cluster)))"
        case nil:
            return "unknown(\(stateRaw))"
        }
    }

    /// Shared bounded audit reader retained for the timing-window conformance
    /// test; it is a lower utility, not a retired timing-report renderer.
    func collectTimingWindow(
        handle: EstateHandle,
        sinceMs: Int64,
        maxEvents: Int
    ) async throws -> (events: [NeuronKit.TimingAuditEvent], truncated: Bool) {
        var events: [NeuronKit.TimingAuditEvent] = []
        var truncated = false
        var cursor: HLC? = sinceMs > 0
            ? HLC(physicalTime: sinceMs, logicalCount: 0, nodeID: 0)
            : nil
        let pageSize = 4096
        while true {
            let remaining = maxEvents - events.count
            guard remaining > 0 else {
                truncated = true
                break
            }
            let page = try await kit.auditEvents(handle, after: cursor, limit: pageSize)
            let keep = page.prefix(remaining)
            events.append(contentsOf: keep.map {
                NeuronKit.TimingAuditEvent(
                    verb: $0.verb,
                    physicalTimeMs: $0.hlc.physicalTime,
                    rowID: $0.rowId,
                    reason: $0.reason)
            })
            if page.count > remaining {
                truncated = true
                break
            }
            guard page.count == pageSize, let last = page.last else { break }
            cursor = last.hlc
        }
        return (events, truncated)
    }
}

// MARK: - ClassificationScheme

/// The classification scheme a lattice-anchor code belongs to.
///
/// Per spec §5.8 (dual-scheme model), an anchor code may be a UDC code
/// or an MDCC code. `moot_file_memory` (and other capture paths) accept
/// a `classificationScheme` discriminator so the scheme can be validated
/// and echoed at the ARIA boundary. The substrate's `LatticeAnchor` does
/// not yet carry a scheme tag (that is a separate storage migration),
/// so this type lives in ARIA_MCP, not LocusKit.
public enum ClassificationScheme: String, Sendable, CaseIterable {
    case udc
    case mdcc
}

/// Actor-isolated concurrency guard for reindex (#19/#33).
/// Prevents multiple concurrent reindex runs — a second call returns
/// immediately with "already running" instead of spawning a duplicate.
private actor ReindexGuard {
    private var running = false
    /// True while the detached moot_reindex task holds the guard — the
    /// window `moot_rebuild_status` reports before the GLK span opens.
    var isBusy: Bool { running }
    func tryStart() -> Bool {
        if running { return false }
        running = true
        return true
    }
    func finish() { running = false }
}
