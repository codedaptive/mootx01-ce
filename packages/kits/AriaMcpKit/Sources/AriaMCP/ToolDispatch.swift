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
        return await dispatchV2(request, rawArguments: transformedArgs)
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
        rawArguments: [String: JSONValue]
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
                modeSessionState: modeSessionState
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
                    surfaced: recallLedger, kit: kit, handle: handle, posture: posture)
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
                now: { now }))
        let cognitionCatalog = AriaV2CognitionCatalogService(
            estateID: handle.estateUUID,
            callableToolNames: Set(effectiveRegistry.operations.map(\.publicName)),
            buildID: buildSerial,
            capabilityDigest: capabilityDigest)
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
                    now: now, serverIdentity: serverIdentity)))

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

    func decodeFilterChain(_ value: JSONValue?) throws -> [Filter] {
        guard let name = try optionalString(value, argument: "filter") else { return [] }
        switch name {
        case "unconfirmed": return [.unconfirmed]
        case "userConfirmed": return [.userConfirmed]
        case "exportable": return [.exportable]
        case "contained": return [.contained]
        // isPinned filter: constrains recall to user-pinned drawers (bit 16).
        // Activates the container-fingerprint pruning path for the first
        // time in production (.hasFeatureFlag is the only prunable filter
        // case; containers whose OR-fingerprint lacks bit 16 are pruned).
        // Feature-flag adoption §1.
        case "pinned": return [.hasFeatureFlag(.isPinned)]
        default:
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Unknown filter: \(name)"
            )
        }
    }

    func decodeHydration(_ value: JSONValue?) throws -> HydrationLevel {
        // Absent hydrationLevel defaults to .structured.
        // Present but non-string (e.g. a JSON number or null) is a protocol
        // violation — fail loudly with invalidParams rather than silently
        // accepting malformed input as the default. Mirrors the established
        // idiom for decodeFilter, decodeOrdering, and decodeMutationKind in
        // this file, and the Rust decode_hydration_level fix in dispatch.rs.
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

    func decodeOrdering(_ value: JSONValue?) throws -> Ordering {
        guard let name = try optionalString(value, argument: "ordering") else { return .byCaptureTimeDesc }
        switch name {
        case "byCaptureTimeDesc": return .byCaptureTimeDesc
        case "byCaptureTimeAsc": return .byCaptureTimeAsc
        case "byRoomAsc": return .byRoomAsc
        // byRelevanceDesc: LocusKit has no relevance signal in its Ordering
        // enum (that case was removed because LocusKit cannot score). At the
        // ARIA surface the client spelling is preserved as a compatibility
        // input: when a caller sends "byRelevanceDesc", the request is routed
        // to the scored recall path (GLKRecallRequest/recall_scored with
        // mode=unionBest), whose results ARE relevance-ordered by the scoring
        // machinery. The RecallFrame.ordering field is set to byCaptureTimeDesc
        // as a stable tie-break within the scored layer; the final result order
        // is driven by the score values, not the page order.
        // Mirrors Rust decode_ordering in interface_tools.rs.
        case "byRelevanceDesc": return .byCaptureTimeDesc
        default:
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Unknown ordering: \(name)"
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
    /// recall family's `outputSchema` (`ToolProjection.recallResultsOutputSchema`).
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

    /// Opaque structured row for an id the text path renders without a drawer
    /// (gated or unhydrated). Subject is set to `noSubjectMarker` so the
    /// row carries a non-nil subject (structurally admissible) while being
    /// identifiable as opaque; room and content are absent. Readers that
    /// filter on the marker skip opaque rows rather than surfacing them as
    /// "(no subject)" entries for content the caller cannot see.
    static func opaqueStructuredRow(id: String) -> StructuredRecallRow {
        StructuredRecallRow(id: id, subject: ResultComposer.noSubjectMarker)
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
    /// The learned semantic vector (MiniLM/MPNet/Gemma model providers) is an
    /// ADDITIVE v1.1 on-device lane — a richer, model-dependent signal that
    /// enhances on-device search but cannot serve as the federation vector
    /// (model-dependent → not reproducible cross-device). It does not replace
    /// the deterministic vector; both coexist as separate lanes.
    static let defaultEmbeddingModelID = "default"
}

// MARK: - InterfaceTools

/// Static dispatch table for the five-tier AI-client interface tools plus the
/// Maintenance tier.
///
/// Each interface tool (the Tier 1–5 tools plus the Maintenance/admin
/// tools, enumerated in `names` below) has a named `run*` function on
/// `ToolDispatcher`; this type routes from name to function, isolating the
/// dispatch logic from the tool-name string constants. Mirrors the Rust
/// `INTERFACE_TOOLS` constant in `interface_tools.rs`.
enum InterfaceTools {

    private static let names: Set<String> = [
        // Anthropic memory_20250818 adapter (M-MEMTOOL-1)
        "memory",
        // Tier 1 — Core Memory
        "moot_file_memory", "moot_memory_search", "moot_memory_get",
        "moot_memory_list",
        "moot_update_memory", "moot_withdraw_memory", "moot_erase_memory",
        "moot_confirm_memory", "moot_move_memory",
        // Tier 2 — Connections
        "moot_link_memories", "moot_connection_search", "moot_connection_map",
        "moot_review_tunnel",
        // Tier 3 — Knowledge Graph
        "moot_file_fact", "moot_fact_search", "moot_retire_fact",
        "moot_fact_timeline",
        // Tier 4 — Journal
        "moot_write_journal", "moot_read_journal",
        // Tier 5 — Estate
        "moot_estate_status", "moot_estate_map", "moot_estate_ping",
        // Monitoring control — read/write daemon telemetry flag
        "moot_monitoring_status",
        // Maintenance / admin
        "moot_reindex", "moot_drain_status", "moot_rebuild_status",
        "moot_timing_report",
        // Direct palace import (bypass NoteIR)
        "moot_palace_import",
        // Direct seed-file JSON import (schema v1, strict append)
        "moot_json_import",
    ]

    static func isInterfaceTool(_ name: String) -> Bool {
        names.contains(name)
    }

    /// Dispatch an interface-tier tool call.
    ///
    /// `now` is the bench-clock instant computed ONCE by the outer
    /// `ToolDispatcher.dispatch()` call for this tool invocation. Runners
    /// must use this `now` rather than calling `Date()` directly — the bench
    /// clock seam (`MOOT_BENCH_EPOCH_NOW`) requires a single deterministic
    /// instant per tool call.
    static func dispatch(
        name: String,
        args: [String: JSONValue],
        dispatcher: ToolDispatcher,
        now: Date
    ) async throws -> JSONValue {
        switch name {
        // Anthropic memory_20250818 adapter (M-MEMTOOL-1)
        case "memory":                 return try await dispatcher.runMemoryTool(args, now: now)
        // Tier 1
        case "moot_file_memory":       return try await dispatcher.runFileMemory(args, now: now)
        case "moot_memory_search":     return try await dispatcher.runMemorySearch(args, now: now)
        case "moot_memory_list":       return try await dispatcher.runMemoryList(args)
        case "moot_memory_get":        return try await dispatcher.runMemoryGet(args, now: now)
        case "moot_update_memory":     return try await dispatcher.runUpdateMemory(args)
        case "moot_withdraw_memory":   return try await dispatcher.runWithdrawMemory(args)
        case "moot_erase_memory":      return try await dispatcher.runEraseMemory(args)
        case "moot_confirm_memory":    return try await dispatcher.runConfirmMemory(args)
        case "moot_move_memory":       return try await dispatcher.runMoveMemory(args)
        // Tier 2
        case "moot_link_memories":     return try await dispatcher.runLinkMemories(args)
        case "moot_connection_search": return try await dispatcher.runConnectionSearch(args)
        case "moot_connection_map":    return try await dispatcher.runConnectionMap(args)
        case "moot_review_tunnel":     return try await dispatcher.runReviewTunnel(args, now: now)
        // Tier 3
        case "moot_file_fact":         return try await dispatcher.runFileFact(args, now: now)
        case "moot_fact_search":       return try await dispatcher.runFactSearch(args)
        case "moot_retire_fact":       return try await dispatcher.runRetireFact(args)
        case "moot_fact_timeline":     return try await dispatcher.runFactTimeline(args)
        // Tier 4
        case "moot_write_journal":     return try await dispatcher.runWriteJournal(args, now: now)
        case "moot_read_journal":      return try await dispatcher.runReadJournal(args)
        // Tier 5
        case "moot_estate_status":      return try await dispatcher.runEstateStatus(args)
        case "moot_estate_map":         return try await dispatcher.runEstateMap(args)
        case "moot_estate_ping":        return try await dispatcher.runEstatePing(args)
        // Monitoring control
        case "moot_monitoring_status":  return try await dispatcher.runMonitoringStatus(args)
        // Maintenance / admin
        case "moot_reindex":           return try await dispatcher.runReindex(args, now: now)
        case "moot_rebuild_status":    return try await dispatcher.runRebuildStatus(args)
        case "moot_drain_status":      return try await dispatcher.runDrainStatus(args)
        case "moot_timing_report":     return try await dispatcher.runTimingReport(args)
        // Direct palace import
        case "moot_palace_import":     return try await dispatcher.runPalaceImport(args, now: now)
        // Direct seed-file JSON import
        case "moot_json_import":       return try await dispatcher.runJsonImport(args, now: now)
        default:
            throw JSONRPCError(
                code: JSONRPCErrorCode.methodNotFound,
                message: "No handler bound for interface tool \(name)"
            )
        }
    }
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
    /// `now` is the dispatch-boundary instant (`InterfaceTools.dispatch`
    /// threads the bench-clock value) and gates the sensitivity-grant check
    /// below; the `Date()` default covers direct runner calls in tests, the
    /// same convention as `runMemorySearch`.
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
        // Unicode SCALARS, the unit the Rust twin counts (`subject.chars().count()`
        // in interface_tools.rs) and the unit both moot-bridge ports cut on. A
        // grapheme cluster can carry several scalars, so counting Characters
        // here would accept a subject the Rust server refuses and the two ports
        // would disagree on the same input.
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
        let estate = try await kit.estate(for: handle)
        let nodeNames = try await estate.resolveNodeNames(
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

    /// `moot_memory_search` — hybrid BM25+vector recall over the estate.
    ///
    /// Routes through the Recall Director (GLKRecallRequest) using the
    /// `unionBest` mode and `matrixAware` scoring by default, giving the
    /// AI client the best available ranked results without exposing the
    /// multi-lane machinery.
    ///
    /// B-10a: origin is set to `.external` so the RecallDirector writes
    /// recall-trace rows for the reward pipeline. The ARIA_MCP boundary is
    /// the ONLY place that sets `.external` — internal callers (dreaming,
    /// lenses, recipes) must NOT. Full hydration is used (content blobs are
    /// needed for the content preview; `.structured` would strip them).
    /// `now` is threaded from the bench clock seam. In production this is
    /// always provided by `InterfaceTools.dispatch` (which gets it from
    /// `benchClock.now()`). The `Date()` default covers direct runner calls
    /// in tests (wall-clock mode; determinism is not a test concern there).
    func runMemorySearch(_ args: [String: JSONValue], now: Date = Date()) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        // Anchor pivot (PR-03): `near:<uuid>` is accepted as an ALTERNATIVE
        // to `query:` — "find memories similar to this one". Exactly one of
        // the two must be present. The anchor's verbatim content becomes the
        // query text through the SAME scored pipeline (full fusion stack),
        // so the fan-out inherits every shape/filter/limit unchanged; the
        // anchor row itself is excluded from the reply.
        let queryArg = try optionalString(args["query"], argument: "query")
        let nearArg = try optionalString(args["near"], argument: "near")
        let query: String
        var anchorID: String? = nil
        switch (queryArg, nearArg) {
        case (nil, nil):
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Provide either query (text search) or near (UUID of an anchor "
                    + "memory — returns the memories most similar to it)."
            )
        case (.some, .some):
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "query and near are mutually exclusive — pass exactly one."
            )
        case (.some(let q), nil):
            query = q
        case (nil, .some(let anchor)):
            // Anchor fetch under the DEFAULT containment gate (no grant
            // lift, deliberately) AND an explicit provenance check: the
            // RecallFrame gate covers adjective sensitivity (bits 6-11)
            // only, while `Drawer.sensitivity` decodes provenance
            // sensitivity (bits 30-35). Both are needed — a
            // provenance-Secret row with the default adjective-Normal
            // passes the frame. Pivoting through a restricted/secret
            // anchor's content would leak content-derived neighbors past
            // the redaction boundary, so a gated anchor reads as
            // not-found — the same oracle-free shape memory_get uses.
            let estate = try await kit.estate(for: handle)
            let fetched = try await estate.getDrawers(
                ids: [anchor],
                matchingFrame: RecallFrame(filterChain: [], hydrationLevel: .full),
                hydrationLevel: .full)
            // The provenance reject is evaluated BEFORE the empty-content
            // check, so a gated row and an empty row collapse into the one
            // not-found shape below, byte-identical to the message an absent
            // id produces. Ordering discipline and defence in depth: this
            // fetch requests a single id, so `admissible` holds at most one
            // drawer and either order yields the same error today. Should
            // this ever resolve a set, provenance-first is the order that
            // cannot leak.
            let admissibleAnchor = fetched.admissible.first { d in
                switch d.sensitivity {
                case .restricted, .secret: return false
                case .normal, .elevated: return true
                }
            }
            guard let anchorDrawer = admissibleAnchor,
                  !anchorDrawer.content.isEmpty else {
                throw JSONRPCError(
                    code: JSONRPCErrorCode.invalidParams,
                    message: "near: anchor memory not found: \(anchor)"
                )
            }
            query = anchorDrawer.content
            anchorID = anchor
        }
        // Clamp to [1, 500]: reject negative/zero limits (crash downstream range ops)
        // and cap absurdly-large values (DoS via unbounded substrate recall scan).
        // Parity: Rust run_memory_search uses clamp_limit with the same ceiling.
        let limit = try Self.clampLimit(
            try optionalInt(args["limit"], argument: "limit"), argument: "limit")
        // `now` is the bench-clock instant threaded from `InterfaceTools.dispatch`.
        // The SAME instant gates both the sensitivity-grant check below and the
        // surfaced-recall-ledger recording further down — one request, one `now`.
        // Build the base filter chain from the `filter` argument.
        var filterChain = try decodeFilterChain(args["filter"])
        // sensitivity unlock: when a restricted/secret grant is
        // live, inject the grant-lifted ceiling explicitly. This is the
        // seam BitmapEvaluator.insertDefaults documents: "conditional on
        // absence so an explicit sensitivity constraint from the caller
        // suppresses this default" — by appending our own
        // `.sensitivityAtMost` here, the substrate's own narrower default
        // (`.elevated`) never gets inserted. Only applies when the caller's
        // `filter` argument did not already specify a sensitivity
        // constraint of its own (an explicit caller constraint always
        // wins — same precedence BitmapEvaluator already documents).
        var sensitivityCeilingLifted = false
        if !filterChain.contains(where: Self.isSensitivityFilter),
           let ceiling = await sensitivityUnlockLedger.ceilingFilter(now: now) {
            filterChain.append(ceiling)
            sensitivityCeilingLifted = true
        }
        // optional `wing` argument scopes recall to a single wing.
        // When absent, recall spans all wings (existing default behavior unchanged).
        // Appended to the filter chain so it composes with any explicit filter.
        if let wingName = try optionalString(args["wing"], argument: "wing") {
            filterChain.append(.inWing(wingName))
        }
        // optional `media_type` argument: constrains recall to drawers that
        // carry a specific media capture type. "voice" → hasVoice (bit 13),
        // "image" → hasImage (bit 14). Composable with `filter` and `wing`.
        // Re-homed from moot_recollect (retired Wave 1); see completion
        // report §Re-homing hasVoice/hasImage. Feature-flag adoption §4.
        if let mediaType = try optionalString(args["media_type"], argument: "media_type") {
            switch mediaType {
            case "voice": filterChain.append(.hasFeatureFlag(.hasVoice))
            case "image": filterChain.append(.hasFeatureFlag(.hasImage))
            default:
                throw JSONRPCError(
                    code: JSONRPCErrorCode.invalidParams,
                    message: "Unknown media_type: \(mediaType). Valid: voice, image"
                )
            }
        }
        let explain = try optionalBool(args["explain"], argument: "explain") ?? false
        // Decode the answer shape adjective (spec §2). Defaults to "never"
        // (byte-identical to pre-packager path when omitted) UNLESS a Recall
        // variant is sticky from a prior mode declaration this session.
        //
        // Precedence (most-specific wins):
        //   1. Per-call `answer` arg (explicit caller override — always wins)
        //   2. Sticky Recall variant (Recall=Auto/Rows/Answer set earlier this session)
        //   3. Spec default (.never / rows-only)
        //
        // Fail CLOSED on unknown `answer` values — a typo must never silently coerce
        // to "never". This is the opposite of the `mode` arg's fail-open discipline:
        // `answer` controls packager behavior that changes the response shape, so a
        // bad value must surface immediately rather than silently defaulting.
        let answerMode: PackagerAnswerMode
        if let answerStr = try optionalString(args["answer"], argument: "answer") {
            // Per-call explicit arg: fail closed on unknown values.
            guard let decoded = PackagerAnswerMode(rawValue: answerStr) else {
                throw JSONRPCError(
                    code: JSONRPCErrorCode.invalidParams,
                    message: "Unknown answer: \(answerStr). Valid: never, always, auto"
                )
            }
            answerMode = decoded
        } else if let recallVariant = await modeSessionState.stickyDeclaration?.recognizedRecallVariant {
            // Sticky Recall variant: maps Recall=Auto→.auto, Recall=Rows→.never,
            // Recall=Answer→.always. This is the session-default that Recall variants
            // set. Per-call `answer` above always overrides this for the current call.
            let variantRaw = recallVariant.answerModeRawValue
            // The rawValue is a known good value from RecallVariant; force-unwrap is safe.
            answerMode = PackagerAnswerMode(rawValue: variantRaw) ?? .never
        } else {
            // Spec default: rows-only (byte-identical to pre-packager path).
            answerMode = .never
        }
        // Decode scoring via the front-door precedence chain:
        //   explicit door arg > explicit scoring arg > provisioned estate default (A1) > matrixAware
        //
        // `door` is an adjective on the recall verb (ARIA grammar: one verb, adjectives
        // constrain). Valid values:
        //   "guess"          — A1 per-corpus config (optimizer-provisioned DoorManifest).
        //                      Falls back to .matrixAware when no config is provisioned.
        //   <scoring rawValue> ("rrf", "matrixAware", "raw", "discriminative") — direct
        //                      override of the scoring strategy, bypassing A1 config.
        //
        // "hedge" (top-two consensus) and "thorough" (full roster) are reserved names
        // that require recipe-layer wiring not present in this build; they are unknown
        // here and fail CLOSED. Fail-closed on any unknown door string so a typo is
        // never silently coerced to a different door.
        //
        // When `door` is absent, fall through to the explicit `scoring` arg, then A1
        // config, then .matrixAware. Mirrors Rust run_memory_search door decode.
        let scoring: GLKRecallScoring
        if let doorStr = try optionalString(args["door"], argument: "door") {
            switch doorStr {
            case "guess":
                // A1 per-corpus static config: read the DoorManifest provisioned by
                // the quality optimizer. Absent or malformed key → .matrixAware, which
                // is the pre-front-door default (byte-identical behaviour).
                let doorManifest = try await kit.provisionedDoorConfig(for: handle)
                scoring = doorManifest.scoring
            default:
                // Attempt to parse as a direct GLKRecallScoring rawValue (e.g. "rrf").
                // Unknown strings (including reserved "hedge", "thorough") fail CLOSED.
                guard let decoded = GLKRecallScoring(rawValue: doorStr) else {
                    throw JSONRPCError(
                        code: JSONRPCErrorCode.invalidParams,
                        message: "Unknown door: \(doorStr). Valid: guess, raw, rrf, matrixAware, discriminative"
                    )
                }
                scoring = decoded
            }
        } else if let scoringStr = try optionalString(args["scoring"], argument: "scoring") {
            // Explicit scoring arg (no door arg). Fail CLOSED on unknown values —
            // silently coercing to matrixAware would hide a typo.
            guard let decoded = GLKRecallScoring(rawValue: scoringStr) else {
                throw JSONRPCError(
                    code: JSONRPCErrorCode.invalidParams,
                    message: "Unknown scoring: \(scoringStr). Valid: raw, rrf, matrixAware, discriminative"
                )
            }
            scoring = decoded
        } else {
            // Neither door nor scoring supplied: read the A1 per-corpus config.
            // Falls back to .matrixAware when no config is provisioned —
            // byte-identical to today's behaviour for un-provisioned estates.
            let doorManifest = try await kit.provisionedDoorConfig(for: handle)
            scoring = doorManifest.scoring
        }
        // Decode optional ordering. "byRelevanceDesc" is a compatibility spelling
        // that routes through the scored recall pipeline — the results ARE
        // relevance-ordered because recall_scored/unionBest ranks by score.
        // All other orderings are decoded strictly; unknown values throw invalidParams.
        // The decoded ordering goes into the RecallFrame as a stable tie-break;
        // the scored path's final order is determined by scores, not page order.
        // Full hydration: the caller is a human-facing AI client; the content
        // preview in the search result requires the content blob. Structured
        // hydration strips content blobs and would render every result as an
        // empty-content preview.
        let ordering = try decodeOrdering(args["ordering"])
        // optional `anomalous_filter` argument (§11.18 anomalous-flag recall
        // prefilter). Maps to GLKRecallRequest.anomalousFilter:
        //   absent or null → nil (no filter; default)
        //   true  → admit ONLY anomalous drawers (bit 26 set)
        //   false → EXCLUDE anomalous drawers (bit 26 clear)
        // Applied BEFORE scoring in RecallDirector.
        let anomalousFilter = try optionalBool(args["anomalous_filter"], argument: "anomalous_filter")
        // Optional per-call candidate-pool depth override. The GLK engine
        // clamps to [RecallShape.frontierKFloor, RecallShape.frontierKCeiling]
        // ([64, 256]), so out-of-range values are silently clamped rather than
        // rejected at this boundary. Absent → nil → engine default formula
        // min(max(limit × 4, 64), 256), byte-identical to today's behaviour.
        // Mirrors Rust run_memory_search `frontier_k` decode.
        let frontierK = try optionalInt(args["frontier_k"], argument: "frontier_k")
        let frame = RecallFrame(
            filterChain: filterChain,
            hydrationLevel: .full,
            limit: limit,
            // ordering: decoded above. byCaptureTimeDesc is the default and the
            // fallback for "byRelevanceDesc". The scored path (unionBest +
            // queryText) produces relevance-ordered results regardless of this
            // tie-break field.
            ordering: ordering
        )
        let request = GLKRecallRequest(
            frame: frame,
            mode: .unionBest,
            scoring: scoring,
            limit: limit,
            fallback: .allowDegraded,
            queryText: query,
            // B-10a: the ARIA boundary is the one external-origin caller, and
            // external origin is what makes the director write recall-trace
            // rows and enqueue a dreaming item. A frozen dispatcher passes
            // internal origin instead, so a frozen search leaves no trace and
            // no dreaming job — the same path every internal reader takes.
            origin: posture == .frozen ? .internal : .external,
            // W2.5 Track R(a): door identity recorded on every reward-cycle
            // trace row this recall writes. The director derives the
            // composition ("unionBest/<scoring>") since no recipe-level
            // composition exists on this direct search path.
            door: "memory_search",
            frontierK: frontierK,
            anomalousFilter: anomalousFilter,
            // Sub-span scoring is off at the ARIA edge: it is an additive-cost
            // stage, the tool exposes no argument for it, and the edge names
            // the value rather than relying on the request default (ruling
            // 2026-09-07).
            subSpanScoring: .off
        )
        let result = try await kit.recall(handle, request)
        // Anchor exclusion (PR-03): a near: pivot must not hand the anchor
        // back as its own top neighbor. Every consumer below (ledger,
        // discrimination scores, rendering, count) works from this list.
        let hits = anchorID.map { a in result.hits.filter { $0.id != a } } ?? result.hits
        // Record surfaced drawer ids in the session ledger so dereference verbs
        // can trigger reward-trace marking (DESIGN_TRACE_REWARD_2026-06-12
        // § session-ledger). Reuses the `now` hoisted at the top of this
        // function (one request, one wall-clock instant).
        // Use hit.id (always non-optional) rather than hit.drawer?.id so
        // unhydrated hits (drawer == nil, rendered via renderUnhydrated) are
        // also tracked. A drawer can arrive unhydrated when the recall engine
        // returns it but the hydration step cannot load the full record
        // (e.g. vector-only hit on a cold index); the id is still valid and
        // the reward path must fire if the caller later dereferences it.
        let surfacedIDs = hits.map { $0.id }
        if !surfacedIDs.isEmpty {
            await recallLedger.recordSurfaced(surfacedIDs, at: now)
        }
        // record a sensitivityReadUnderGrant audit entry for
        // each hit that was admitted PAST the substrate's own default
        // ceiling specifically because a grant is live. Only rows whose
        // own adjective sensitivity is restricted/secret qualify — an
        // elevated-or-below row would have been admitted regardless of
        // any grant, so recording it here would misrepresent "read under
        // grant" as having happened when it did not. Gated on
        // `sensitivityCeilingLifted` so a query with no live grant never
        // emits (in that case no restricted/secret row could have been
        // admitted in the first place — the default ceiling excludes them).
        if sensitivityCeilingLifted {
            for hit in hits {
                guard let drawer = hit.drawer else { continue }
                switch drawer.adjectiveSensitivity {
                case .restricted, .secret:
                    try? await kit.recordSensitivityReadUnderGrant(
                        handle, tier: drawer.adjectiveSensitivity, drawerID: drawer.id, now: now)
                case .normal, .elevated:
                    continue
                }
            }
        }
        // Compute discrimination before building the result lines so the signal
        // reflects the full ordered hit list, not just the displayed prefix.
        let hitScores = hits.map { Double($0.score.final) }
        let discriminationLevel = RecallDiscrimination.classify(hitScores)
        // Dense-lane dark flag: true when no span rerank stage is registered
        // for the estate. The span stage is the one dense provider, so without
        // it the ranking is lexical-only. Used to cap the discrimination
        // signal so "high, clear top result" is never reported on a purely
        // lexical ranking.
        let denseLaneDark = RecallDiscrimination.denseLaneDark(
            spanRerankRegistered: await kit.isSpanRerankRegistered(for: handle)
        )

        // answer:always|auto — compose an answer via GroundedSynthesis (the one-
        // seam synthesis path shared with moot_synthesize), then route through
        // GLKResultsPackager to select the response level (L0/L1/rowsOnly) and
        // apply the score-cliff row cutoff (spec §2-6). answer:never is the fast
        // path — byte-identical to the pre-packager dense-rows path; the packager
        // still runs but the .never branch returns all hits unchanged with no gate
        // computation.
        //
        // The recall_tuning manifest supplies the packager thresholds; absent key
        // fills with spec defaults so an un-tuned estate behaves as documented.
        let composedAnswer: String?
        if answerMode != .never {
            // Synthesize using the same GroundedSynthesis path as moot_synthesize.
            // cueTerms is intentionally empty here — the scored second lane (query:)
            // already grounds the synthesis on the query text without requiring a
            // cue-term predicate filter on top.
            let synthFrame = LocusKit.RecallFrame(
                filterChain: filterChain,
                hydrationLevel: .structured,
                limit: limit,
                ordering: ordering
            )
            let synthOut = try await GroundedSynthesis().run(
                input: .init(
                    frame: synthFrame,
                    cueTerms: [],
                    cap: limit,
                    query: query,
                    excludeProvenanceSensitive: true
                ),
                estate: handle,
                kit: kit
            )
            composedAnswer = synthOut.context.summary
        } else {
            composedAnswer = nil
        }
        // Build the packaged result. Pass the post-anchor-exclusion hit list
        // (`hits`, already anchor-filtered above) so gate signals (m1 top-margin,
        // m3 span cosine spread) are computed on the same ranked set the caller receives.
        // For near: queries where the anchor is rank-1, computing m1 on the
        // pre-exclusion set would corrupt the margin signal — the anchor's self-
        // comparison dominates rank-1 and inflates m1 artificially.
        // The .never fast path returns all hits unchanged (byte-identical to today).
        // The tuning manifest supplies the confidence thresholds; .default fills
        // absent keys.
        let tuning = try await kit.provisionedRecallTuning(for: handle)
        let packagerResult: GLKRecallResult
        if anchorID != nil {
            // Rebuild the result with the anchor-excluded hit list so the packager's
            // gate math operates on the post-filter ranked set.
            packagerResult = result.replacing(hits: hits)
        } else {
            packagerResult = result
        }
        let packaged = GLKResultsPackager().package(
            result: packagerResult,
            mode: answerMode,
            composedAnswer: composedAnswer,
            thresholds: tuning.packagerThresholds
        )
        // The packager already received the anchor-excluded hit list, so its
        // row output is already anchor-clean.
        let packagedRows = packaged.rows

        // Migrate to the shared ResultComposer (COMPOSER-02B). All text rendering
        // goes through typed intermediates; the composer guarantees parity between
        // the text payload and the structuredContent block.
        //
        // answer:never|rowsOnly → S1 rows only (existing path via composer).
        // answer:always|auto + L0 → answer block only; no rows emitted.
        // answer:always|auto + L1 → answer block then rows (via composer).
        //
        // recall_provenance removed from payload (logged only); the degradation
        // signal is carried in the composer's ControlSignals.degraded flag.
        // sensitivity_advisory removed from payload (moved to tool description).
        // fdc/qid columns removed; scores and adornments now travel in S1 rows.
        let shownHits = packaged.level == .l0AnswerOnly
            ? []
            : Array(packagedRows.prefix(50))
        let searchEstate = try await kit.estate(for: handle)
        let searchNodeNames = try await searchEstate.resolveNodeNames(
            parentNodeIds: shownHits.compactMap { $0.drawer?.parentNodeId })
        // Map hits → CandidateRowData typed intermediates for the composer.
        var candidateRows: [CandidateRowData] = []
        for hit in shownHits {
            if let drawer = hit.drawer {
                // Provenance-sensitivity redaction: subject/bestSpan are
                // content-derived; restricted/secret rows replace them with the
                // redaction marker so the body's access control cannot be
                // bypassed through the summary.
                let (subject, bestSpan): (String?, String?)
                switch drawer.sensitivity {
                case .restricted:
                    (subject, bestSpan) = (ResultComposer.restrictedMarker, nil)
                case .secret:
                    (subject, bestSpan) = (ResultComposer.secretMarker, nil)
                case .normal, .elevated:
                    subject = drawer.subject
                    // Pass full content; composer truncates to 120 chars and
                    // deduplicates against subject (§11.1 rules 2–3).
                    bestSpan = drawer.content.isEmpty ? nil : drawer.content
                }
                candidateRows.append(CandidateRowData(
                    id: drawer.id,
                    subject: subject,
                    bestSpan: bestSpan,
                    // sscFacts: stubbed nil until W1 schema-19 Drawer.sscFacts lands
                    sscFacts: nil,
                    eventTime: ResultComposer.iso8601(drawer.eventTime),
                    score: Double(hit.score.final),
                    room: searchNodeNames[drawer.parentNodeId]?.room))
            } else {
                // Unhydrated hit: id only; all columns render '-'.
                candidateRows.append(CandidateRowData(
                    id: hit.id,
                    subject: nil,
                    eventTime: "-",
                    score: Double(hit.score.final)))
            }
            // Explain lines follow the row they annotate (outside the composer row).
            // The composer does not know about explain output; append after the
            // loop below once the composed text is built.
        }

        // Build ControlSignals (deviation-only per §11.3 absolute trailing order).
        // Discrimination: dense-lane-dark caps "high" → "medium" (same rule as before).
        let effectiveDiscrimination: DiscriminationLevel =
            (denseLaneDark && discriminationLevel == .high) ? .medium : discriminationLevel
        let discriminationArg: String? = switch effectiveDiscrimination {
            case .low:             "low"
            case .medium:          "medium"
            case .high, .notFound, .single: nil   // no discrimination line when high, not-found, or single result
        }
        // Degradation: true when any stage was skipped (replaces the old recall_provenance line;
        // the detail is now logged server-side, not surfaced in the payload).
        let degraded = !result.degradedStages.isEmpty
        // Tie note: non-determinate tie window was exhausted — same wording as before.
        let tieNote = result.degradedStages.contains("tie.nonDeterminate")
        let control = ControlSignals(
            discrimination: discriminationArg,
            degraded: degraded,
            tieNote: tieNote)

        // Compose via the central renderer.
        let composed: ComposedResult
        if candidateRows.isEmpty {
            composed = ResultComposer.renderEmptyS1(hint: nil)
        } else {
            composed = ResultComposer.renderS1Surface(rows: candidateRows, control: control)
        }

        // Prepend the answer block (L0/L1) and, for the explain path, the explain
        // lines after each row. Explain lines are not yet compositor-rendered —
        // they are plain text that follow their row.
        var finalText = composed.text
        if explain {
            // Interleave explain lines after each corresponding row in the text.
            // The composed text is: header\nrow1\nrow2\n...\ncontrol-lines
            // We need to insert explain lines after each row. Parse the text,
            // find the row lines (skip header and control lines), and insert.
            let textLines = finalText.components(separatedBy: "\n")
            // Identify the header line (always first) and control lines (suffix).
            // Rows are the middle section. We walk backward from candidateRows.
            // Simple approach: rebuild from scratch to avoid parse fragility.
            let n = candidateRows.count
            var rebuilt: [String] = []
            let rawLines = textLines
            // Header is rawLines[0]; rows are rawLines[1..<1+n]; control lines follow.
            if rawLines.count > 0 { rebuilt.append(rawLines[0]) }
            for i in 0..<n {
                let rowIdx = 1 + i
                if rowIdx < rawLines.count { rebuilt.append(rawLines[rowIdx]) }
                if i < shownHits.count {
                    for line in shownHits[i].explanation { rebuilt.append("  \(line)") }
                }
            }
            // Append remaining control lines.
            let controlStart = 1 + n
            if controlStart < rawLines.count {
                rebuilt.append(contentsOf: rawLines[controlStart...])
            }
            finalText = rebuilt.joined(separator: "\n")
        }
        if let block = packaged.answerBlock {
            var headerLines = [
                "answer: \(block.text)",
                "confidence: \(block.confidence.rawValue)",
            ]
            if !block.citationIDs.isEmpty {
                headerLines.append("citations: \(block.citationIDs.prefix(5).joined(separator: ", "))")
            }
            headerLines.append(
                "signals: margin=\(block.signals.margin) "
                + "lane_agreement=\(block.signals.laneAgreement) "
                + "dense_spread=\(block.signals.denseSpread) "
                + "containment=\(block.signals.containment)"
            )
            finalText = headerLines.joined(separator: "\n") + "\n" + finalText
        }
        return Self.composedResult(ComposedResult(text: finalText, structured: composed.structured))
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
        guard ["subject", "distilled", "full"].contains(depthName) else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Unknown depth: \(depthName). Valid: subject, distilled, full"
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
        let estate = try await kit.estate(for: handle)

        // sensitivity unlock: same grant-ceiling injection as
        // runMemorySearch — see that function's doc comment. moot_memory_get
        // deliberately uses the SAME containment gate moot_memory_search
        // does (its own doc history says so explicitly), so the grant must
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
        let filtered = try await estate.getDrawers(
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
            let getNodeNames = try await estate.resolveNodeNames(
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
                if depthName == "distilled" {
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
                    // Inline distillation: compute at read time, 17 ms per 4.9k-char record.
                    let distilledText = ContextDistiller().distill(
                        DistillationInput(original: d.content),
                        converter: .intentSpanV23Attributed).aiText
                    lines.append("    \(distilledText)")
                } else {
                    // depth:full in batch mode — S3 full record per drawer.
                    let names = getNodeNames[d.parentNodeId] ?? (wing: "", room: "")
                    let allTunnels = try await estate.allTunnels()
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
            return Self.composedResult(ComposedResult(text: lines.joined(separator: "\n")))
        }

        // Single-id depth:full path — S3 full record via renderS3Record (absorbs fullRecordLines).
        let drawer = admissibleByID[rowID]!

        // B-10a: memory_get is a dereference verb. If this drawer was surfaced
        // by a prior moot_memory_search in this session, fire the reward path
        // so the dreaming daemon assigns reward=1.0. Best-effort: noteUsage
        // never throws to the caller. Same contract as the mutation verbs
        // (moot_update_memory, moot_withdraw_memory, moot_confirm_memory, etc.).
        await noteUsage(rowID, handle: handle)

        // Same read-under-grant audit recording as runMemorySearch — gated on
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
        let nodeNames = try await estate.resolveNodeNames(parentNodeIds: [drawer.parentNodeId])
        let names = nodeNames[drawer.parentNodeId] ?? (wing: "", room: "")
        let allTunnels = try await estate.allTunnels()
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

    /// Note that a drawer id was "used" (acted upon) by a dereference verb.
    ///
    /// If the id is present in the session ledger (i.e., it was surfaced by a
    /// prior `moot_memory_search` in this session), call `kit.markRecallUsed`
    /// so the dreaming daemon's reward sweep assigns reward 1.0 for that
    /// drawer's trace rows (DESIGN_TRACE_REWARD_2026-06-12).
    ///
    /// Layer discipline: ARIA → GLK → LocusKit. `markRecallUsed` is the GLK
    /// verb; we must not call LocusKit directly.
    ///
    /// Failures are silenced — a reward-marking failure must never break the
    /// dereference verb's primary result.
    private func noteUsage(_ rowID: String, handle: EstateHandle) async {
        // Frozen: the ledger still records what a search surfaced (it is
        // session memory, not estate state), but the reward mark is a
        // persistent write and is skipped.
        guard posture == .live else { return }
        guard await recallLedger.entry(for: rowID) != nil else { return }
        // Use current wall time as `now` so the retention window is
        // [Date() - 30 days, Date()]. The RecallDirector stamps trace rows with
        // its own Date() call (inside kit.recall), which runs AFTER the ledger's
        // surfacedAt is captured at the top of runMemorySearch. Under load the
        // recall can take long enough that recalledAt > surfacedAt, which would
        // push the row past the window upper bound and cause markRecallUsed to
        // match 0 rows. Using current wall time guarantees the window covers
        // any trace row written in this session (same-session dereferences are
        // always within the 30-day retention window).
        let now = Date()
        do {
            _ = try await kit.markRecallUsed(handle, target: rowID, now: now)
        } catch {
            // Best-effort: reward marking must not break the primary verb.
        }
    }

    /// `moot_update_memory` — apply a named mutation to a memory.
    func runUpdateMemory(_ args: [String: JSONValue]) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let rowID = try requireString(args, "id")
        let mutationName = try requireString(args, "mutation")
        let kind: MutationKind
        if mutationName == "setSubject" {
            // setSubject carries its payload in a dedicated `subject` arg
            // (the `note` arg stays an audit annotation, as for every other
            // mutation). Boundary-validated here so the caller gets the
            // register guidance, not the bare store error.
            guard let subject = args["subject"]?.stringValue else {
                throw JSONRPCError(
                    code: JSONRPCErrorCode.invalidParams,
                    message: "mutation=setSubject requires a `subject` argument: one sentence "
                        + "(≤\(DrawerStore.subjectLengthContract) chars) in the AI-facing register — "
                        + "telegraphic, entities and claims front-loaded."
                )
            }
            let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
            // Unicode scalars, the unit the Rust twin counts; see runFileMemory.
            let trimmedLength = trimmed.unicodeScalars.count
            guard trimmedLength > 0, trimmedLength <= DrawerStore.subjectLengthContract else {
                // Return as an isError result rather than throwing a JSON-RPC protocol error.
                // MCP clients render thrown JSON-RPC errors as bare "Tool execution failed"
                // and discard the message. An isError result puts the contract text in front
                // of the model so it can compress and retry. Mirrors the Rust port's
                // TOOL_DISPATCH_FAILURE path in run_update_memory (interface_tools.rs).
                return Self.errorResult(
                    "subject must be 1–\(DrawerStore.subjectLengthContract) characters "
                        + "(got \(trimmedLength)). Compress, don't truncate."
                )
            }
            kind = .setSubject(trimmed)
        } else {
            kind = try decodeMutationKind(mutationName)
        }
        let payload = try optionalString(args["note"], argument: "note")
        // Note usage before the primary verb so reward marking is attempted even
        // if the primary verb fails (surfaced id was found, user tried to act on it).
        await noteUsage(rowID, handle: handle)
        let frame = MutateFrame(rowID: rowID, kind: kind, payload: payload)
        try await kit.mutate(handle, frame)
        return Self.textResult("updated memory \(rowID) (\(mutationName))")
    }

    /// `moot_withdraw_memory` — soft-remove a memory from active circulation.
    func runWithdrawMemory(_ args: [String: JSONValue]) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let rowID = try requireString(args, "id")
        let reason = try optionalString(args["reason"], argument: "reason")
        // Note usage: withdrawing a surfaced drawer means the user acted on it.
        await noteUsage(rowID, handle: handle)
        try await kit.withdraw(handle, WithdrawFrame(rowID: rowID, reason: reason))
        return Self.textResult("withdrew memory \(rowID)")
    }

    /// `moot_erase_memory` — hard-erase a memory. Requires `confirmed: true`.
    func runEraseMemory(_ args: [String: JSONValue]) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let rowID = try requireString(args, "id")
        let reason = try requireString(args, "reason")
        // Surface the caller-facing field name "confirmed" but map it to
        // the substrate's ExpungeFrame "confirmation" field.
        let confirmed = try optionalBool(args["confirmed"], argument: "confirmed") ?? false
        // Security gate (Item 1 hardening): refuse at the AriaMcpKit boundary
        // before calling the substrate. Prevents prompt-injected agents from
        // triggering irreversible erasure without an explicit owner acknowledgement.
        // Mirrors the Rust run_erase_memory gate in dispatch.rs.
        guard confirmed else {
            return Self.errorResult(
                "expunge of \(rowID) requires confirmed=true and a reason. " +
                "Set confirmed=true only after the owner has explicitly reviewed and approved the deletion."
            )
        }
        let outcome = try await kit.expunge(
            handle, ExpungeFrame(rowID: rowID, reason: reason, confirmation: confirmed))
        // Honest reporting (SPEC B-8b, MXE-FA): a caller acting on this
        // sentence is making a privacy decision on it. When the audit gate
        // refused accepted lineage siblings, the expunge was partial — say
        // so, name the count, and name the surviving ids. The full-success
        // shape stays byte-identical to the historical response.
        guard outcome.refusedSiblingIDs.isEmpty else {
            let refused = outcome.refusedSiblingIDs
            return Self.textResult(
                "partially erased memory \(rowID): \(refused.count) accepted lineage "
                + "sibling(s) refused erasure and remain readable: "
                + refused.joined(separator: ", ")
            )
        }
        return Self.textResult("erased memory \(rowID)")
    }

    /// `moot_confirm_memory` — shortcut for moot_update_memory with mutation=confirm.
    func runConfirmMemory(_ args: [String: JSONValue]) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let rowID = try requireString(args, "id")
        let payload = try optionalString(args["note"], argument: "note")
        // Note usage: confirming a surfaced drawer means the user acted on it.
        await noteUsage(rowID, handle: handle)
        let frame = MutateFrame(rowID: rowID, kind: .confirm, payload: payload)
        try await kit.mutate(handle, frame)
        return Self.textResult("confirmed memory \(rowID)")
    }

    /// `moot_move_memory` — reanchor a memory to a new location.
    ///
    /// The caller provides a free-form `location` hint; the server maps it
    /// to the substrate's `toRoom` field (same convention as `moot_file_memory`).
    /// An optional `wing` argument triggers a cross-wing move, reanchoring the
    /// drawer into the named wing. When `wing` is omitted, the drawer stays in
    /// its current wing and only the room changes (existing behavior, unchanged).
    func runMoveMemory(_ args: [String: JSONValue]) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let rowID = try requireString(args, "id")
        let location = try requireString(args, "location")
        // optional `wing` moves the drawer into a different wing.
        // When absent, the drawer stays in its current wing — room-only move.
        let wing = try optionalString(args["wing"], argument: "wing")
        // Note usage: moving a surfaced drawer means the user acted on it.
        await noteUsage(rowID, handle: handle)
        // location maps to toRoom; wing (when provided) triggers a cross-wing move.
        try await kit.reanchor(handle, ReanchorFrame(rowID: rowID, toRoom: location, toWing: wing, toLattice: nil))
        if let wing {
            return Self.textResult("moved memory \(rowID) to \(wing)/\(location)")
        }
        return Self.textResult("moved memory \(rowID) to \(location)")
    }
}

// MARK: - Tier 2: Connections runners

extension ToolDispatcher {

    /// Valid caller-facing kind strings for `moot_link_memories`.
    ///
    /// Includes both the human-friendly vocabulary exposed to AI clients and the
    /// substrate enum names accepted as pass-through for advanced callers. Any
    /// string not in this set is rejected with an invalidParams error listing the
    /// accepted values. This prevents silent fallback to `.references` for
    /// mistyped or unsupported kinds.
    private static let validKindStrings: Set<String> = [
        // Caller-friendly vocabulary
        "relates", "precedes", "contradicts", "supports", "refines",
        "exemplifies", "extends",
        // Pass-through substrate names (for advanced callers)
        "supersedes", "references", "blocks", "validates", "derivesFrom",
        "covers", "elaborates", "respondsTo",
    ]

    /// Map a validated caller-facing kind string to the substrate's `TunnelKind`
    /// enum. Only called after `validKindStrings` membership is confirmed.
    private static func tunnelKind(for kindString: String) -> TunnelKind {
        switch kindString {
        // Caller-friendly vocabulary
        case "relates":     return .references
        case "precedes":    return .blocks
        case "contradicts": return .contradicts
        case "supports":    return .validates
        case "refines":     return .elaborates
        case "exemplifies": return .covers
        case "extends":     return .derivesFrom
        // Pass-through substrate names (for advanced callers)
        case "supersedes":  return .supersedes
        case "references":  return .references
        case "blocks":      return .blocks
        case "validates":   return .validates
        case "derivesFrom": return .derivesFrom
        case "covers":      return .covers
        case "elaborates":  return .elaborates
        case "respondsTo":  return .respondsTo
        // Unreachable — validKindStrings gate ensures only the above reach here.
        default:            return .references
        }
    }

    /// `moot_link_memories` — create a directed connection between two memories.
    ///
    /// Resolves source and target drawer coordinates (wing/room) by looking up
    /// both drawers by ID via `estate.allDrawers()`, then delegates to
    /// `Estate.capture(TunnelCaptureFrame)` — the same path the existing
    /// tunnel tests use. No GLK kit-level captureTunnel verb exists; the
    /// estate actor is the direct write path.
    ///
    /// Validation: rejects unknown `kind` values (instead of silently defaulting
    /// to `.references`), and rejects self-loops where `from_id == to_id`.
    func runLinkMemories(_ args: [String: JSONValue]) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let fromID = try requireString(args, "from_id")
        let toID = try requireString(args, "to_id")
        let kindString = try requireString(args, "kind")

        // Reject unknown kind strings — silent fallback to .references would
        // accept garbage input and produce a misleadingly-typed tunnel.
        guard Self.validKindStrings.contains(kindString) else {
            let validList = Self.validKindStrings.sorted().joined(separator: ", ")
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Unknown kind: \(kindString). Valid kinds: \(validList)"
            )
        }

        // Reject self-loops — a tunnel from a drawer to itself is semantically
        // meaningless and creates cycles that break graph traversal algorithms.
        guard fromID != toID else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Self-loop not allowed: from_id and to_id are the same (\(fromID))."
            )
        }

        let label = try optionalString(args["label"], argument: "label") ?? kindString
        let kind = Self.tunnelKind(for: kindString)
        // Resolve wing/room by looking up both drawers. `estate.allDrawers()`
        // is public on LocusKit.Estate; GLK has no direct getDrawer(id:) call.
        let estate = try await kit.estate(for: handle)
        let allDrawers = try await estate.allDrawers()
        guard let source = allDrawers.first(where: { $0.id == fromID }) else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Memory not found: \(fromID)"
            )
        }
        guard let target = allDrawers.first(where: { $0.id == toID }) else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Memory not found: \(toID)"
            )
        }
        // Drawer no longer carries stored wing/room. Resolve
        // parentNodeIds via the node tree for TunnelCaptureFrame display names.
        let linkNodeNames = try await estate.resolveNodeNames(
            parentNodeIds: [source.parentNodeId, target.parentNodeId])
        let sourceNames = linkNodeNames[source.parentNodeId] ?? (wing: "", room: "")
        let targetNames = linkNodeNames[target.parentNodeId] ?? (wing: "", room: "")
        // `proposed: true` files the link in the PROPOSED lifecycle — the
        // agent-adjudication path: the caller judged a borderline candidate
        // from moot_hunt_contradictions and records the verdict as a
        // reviewable proposal instead of an immediately-active edge. The
        // user settles it via moot_review_tunnel.
        var proposed = false
        if let raw = args["proposed"] {
            guard case .bool(let flag) = raw else {
                throw JSONRPCError(
                    code: JSONRPCErrorCode.invalidParams,
                    message: "proposed must be a boolean")
            }
            proposed = flag
        }
        let frame = TunnelCaptureFrame(
            sourceWing: sourceNames.wing,
            sourceRoom: sourceNames.room,
            targetWing: targetNames.wing,
            targetRoom: targetNames.room,
            label: label,
            addedBy: serverIdentity,
            sourceDrawerId: fromID,
            targetDrawerId: toID,
            kind: kind,
            originClass: .derived,
            lifecycle: proposed ? .proposed : .active
        )
        let tunnel = try await estate.capture(frame)
        let stateNote = proposed ? " [proposed — review via moot_review_tunnel]" : ""
        return Self.textResult("linked \(fromID) → \(toID) via \(label) (\(tunnel.id))\(stateNote)")
    }

    /// Map a proposal's label family to the tier lens recorded on a
    /// review-ladder vote. The label-family contract is GLK's
    /// (ConflictTunnelLifecycle.swift: "dcp: " → tier 1, "tier2:" → 2,
    /// "tier3:" → 3); this dispatch-layer mirror exists because those
    /// prefixes are internal to GLK. Labels outside the matrix family
    /// (hunter-filed, agent-filed) default to tier 3 — the weakest
    /// epistemic class, so a vote on an unlabeled proposal never
    /// inflates its standing. Parity: Rust `tier_lens_for_label`.
    static func tierLens(forLabel label: String) -> ContradictionTier {
        if label.hasPrefix("dcp: ") { return .typedProven }
        if label.hasPrefix("tier2:") { return .lexicalStructural }
        if label.hasPrefix("tier3:") { return .lexicalValue }
        return .lexicalValue
    }

    /// `moot_review_tunnel` — review a PROPOSED tunnel on the MXE-CT3
    /// review ladder (Rejected / Proposed / Endorsed / Accepted):
    ///
    /// - `accept` (user-only): activates the edge via the existing
    ///   `respondToTunnel` path, recording `reviewed_by` in the review
    ///   ledger. Edge activation is human-authoritative — a model
    ///   reviewer can NEVER activate, no matter how many endorsements
    ///   accumulate.
    /// - `reject` with `reviewed_by` "user": withdraws permanently via
    ///   `respondToTunnel` (durable dedup — never re-proposed).
    /// - `reject` with a model `reviewed_by`: the AI-objection path
    ///   (`objectToTunnel`) — withdraws only when no model endorsement
    ///   exists (reopenable); otherwise the tunnel stays proposed and is
    ///   marked contested for user attention.
    /// - `endorse` (any reviewer, user included): records an endorsement
    ///   vote (`endorseTunnel`) without touching lifecycle; weight feeds
    ///   review-queue ranking only.
    ///
    /// Only tunnels in the proposed lifecycle are reviewable; a settled
    /// edge cannot be rewritten by a stale review.
    /// `now` is threaded from the bench clock seam. Default `Date()` covers
    /// direct runner calls in tests.
    func runReviewTunnel(_ args: [String: JSONValue], now: Date = Date()) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let tunnelID = try requireString(args, "tunnel_id")
        let verdict = try requireString(args, "verdict")
        guard verdict == "accept" || verdict == "reject" || verdict == "endorse" else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "verdict must be \"accept\", \"reject\", or \"endorse\"")
        }
        let reviewedBy = try optionalString(args["reviewed_by"], argument: "reviewed_by") ?? "user"
        guard !reviewedBy.isEmpty else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "reviewed_by must be a non-empty string")
        }
        // The ladder's one hard wall, enforced at the public boundary:
        // edge activation is user-only. Models endorse or reject.
        guard verdict != "accept" || reviewedBy == "user" else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "edge activation is user-only — verdict \"accept\" requires "
                    + "reviewed_by \"user\"; model reviewers use \"endorse\" or \"reject\"")
        }
        let reason = try optionalString(args["reason"], argument: "reason")
        let estate = try await kit.estate(for: handle)

        // Tier lens for ladder votes, derived from the proposal's label
        // family. A missing tunnel falls through to the GLK verb, which
        // owns the not-found error (single validation source).
        let label = try await estate.getTunnel(id: tunnelID)?.label ?? ""
        let lens = Self.tierLens(forLabel: label)
        // `now` is the bench-clock instant threaded from `InterfaceTools.dispatch`,
        // pinned for replay determinism. Review timestamps use this instead of Date().

        switch (verdict, reviewedBy) {
        case ("endorse", _):
            do {
                let outcome = try await kit.endorseTunnel(
                    in: handle, tunnelID: tunnelID,
                    endorserID: reviewedBy, tierLens: lens, now: now)
                let contestedNote = outcome.contested ? ", contested" : ""
                return Self.textResult(
                    "moot_review_tunnel: \(tunnelID) endorsed by \(reviewedBy) "
                        + "(distinct endorsers: \(outcome.distinctEndorsers)\(contestedNote)).")
            } catch let error as LocusKitError {
                return Self.errorResult("moot_review_tunnel: \(error)")
            }
        case ("reject", let reviewer) where reviewer != "user":
            // AI rejection semantics: an objection, not a user verdict.
            do {
                let outcome = try await kit.objectToTunnel(
                    in: handle, tunnelID: tunnelID,
                    reviewerID: reviewer, tierLens: lens, now: now)
                let text = outcome.withdrawn
                    ? "objected by \(reviewer) — withdrawn (no model endorsement on record; the user can reopen it)"
                    : "objected by \(reviewer) — contested: a model endorsement exists, so the proposal stays for user review"
                return Self.textResult("moot_review_tunnel: \(tunnelID) \(text).")
            } catch let error as LocusKitError {
                return Self.errorResult("moot_review_tunnel: \(error)")
            }
        default:
            // User accept/reject — the existing settle path, now
            // recording the reviewer identity in the review ledger.
            do {
                try await estate.respondToTunnel(
                    id: tunnelID,
                    accept: verdict == "accept",
                    changedBy: reviewedBy,
                    reason: reason)
            } catch let error as LocusKitError {
                // Not-found and not-proposed are caller errors, surfaced as clean
                // tool-level messages rather than opaque failures.
                return Self.errorResult("moot_review_tunnel: \(error)")
            }
            let outcome = verdict == "accept"
                ? "accepted — the contradicts link is now active"
                : "rejected — the link is withdrawn and this pair will never be re-proposed"
            return Self.textResult("moot_review_tunnel: \(tunnelID) \(outcome).")
        }
    }

    /// `moot_connection_search` — find connections going out from a memory.
    ///
    /// Pushes `sourceDrawerId == from_id`, tombstone guard, and lifecycle/retirement
    /// bitmap predicates into SQL via `activeTunnelsFrom(drawerId:)` so that
    /// SQLite evaluates them before any row is decoded. The sensitivity gate
    /// (`isBulkExportable`) is applied in-memory on the small returned slice.
    /// Render path: COMPOSER-02B S5 edges via `ResultComposer.renderS5Edges`.
    func runConnectionSearch(_ args: [String: JSONValue]) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let fromID = try requireString(args, "from_id")
        let estate = try await kit.estate(for: handle)
        // activeTunnelsFrom pushes sourceDrawerId equality, tombstone IS NULL,
        // and (operationalBitmap & mask) = 0 into SQL — lifecycle + retirement
        // filters move to the storage layer. Sensitivity ceiling (#58):
        // restricted/secret tunnels are excluded in the in-memory pass below.
        let candidates = try await estate.activeTunnelsFrom(drawerId: fromID)
        let outgoing = candidates.filter { $0.adjectiveSensitivity.isBulkExportable }
        // Load far-endpoint drawers (structured hydration — no content blobs).
        // Room-level endpoints (no targetDrawerId) synthesize a CandidateRowData
        // from the wing/room text as the subject so the row is still meaningful.
        let endpointIDs = outgoing.prefix(50).compactMap { $0.targetDrawerId }
        let drawers = try await RecipeTools.structuredDrawersByID(ids: endpointIDs, estate: estate)
        let edges = outgoing.prefix(50).map { t -> EdgeRow in
            let far: CandidateRowData
            if let tid = t.targetDrawerId, let d = drawers[tid] {
                far = CandidateRowData(
                    id: d.id, subject: d.subject,
                    bestSpan: d.content.isEmpty ? nil : d.content,
                    eventTime: ResultComposer.iso8601(d.eventTime))
            } else if let tid = t.targetDrawerId {
                // Drawer ID referenced but not admissible (gated or missing).
                far = CandidateRowData(id: tid, eventTime: "-")
            } else {
                // Room-level endpoint: no drawer ID; use wing/room as subject.
                far = CandidateRowData(id: "-",
                    subject: "\(t.targetWing)/\(t.targetRoom)", eventTime: "-")
            }
            return EdgeRow(tunnelID: t.id, kindLabel: t.label, farEndpoint: far)
        }
        return Self.composedResult(ResultComposer.renderS5Edges(
            direction: "outgoing", edges: Array(edges)))
    }

    /// `moot_connection_map` — find connections pointing to a memory.
    ///
    /// Pushes `targetDrawerId == to_id`, tombstone guard, and lifecycle/retirement
    /// bitmap predicates into SQL via `activeTunnelsTo(drawerId:)`. The sensitivity
    /// gate is applied in-memory on the small returned slice. Mirror of
    /// `runConnectionSearch` for the incoming-edge direction.
    /// Render path: COMPOSER-02B S5 edges via `ResultComposer.renderS5Edges`.
    func runConnectionMap(_ args: [String: JSONValue]) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let toID = try requireString(args, "to_id")
        let estate = try await kit.estate(for: handle)
        // activeTunnelsTo pushes targetDrawerId equality, tombstone IS NULL, and
        // (operationalBitmap & mask) = 0 into SQL. Sensitivity ceiling (#58):
        // same in-memory gate as connection_search.
        let candidates = try await estate.activeTunnelsTo(drawerId: toID)
        let incoming = candidates.filter { $0.adjectiveSensitivity.isBulkExportable }
        // Load source-endpoint drawers — mirror of connection_search pattern.
        let endpointIDs = incoming.prefix(50).compactMap { $0.sourceDrawerId }
        let drawers = try await RecipeTools.structuredDrawersByID(ids: endpointIDs, estate: estate)
        let edges = incoming.prefix(50).map { t -> EdgeRow in
            let far: CandidateRowData
            if let sid = t.sourceDrawerId, let d = drawers[sid] {
                far = CandidateRowData(
                    id: d.id, subject: d.subject,
                    bestSpan: d.content.isEmpty ? nil : d.content,
                    eventTime: ResultComposer.iso8601(d.eventTime))
            } else if let sid = t.sourceDrawerId {
                far = CandidateRowData(id: sid, eventTime: "-")
            } else {
                far = CandidateRowData(id: "-",
                    subject: "\(t.sourceWing)/\(t.sourceRoom)", eventTime: "-")
            }
            return EdgeRow(tunnelID: t.id, kindLabel: t.label, farEndpoint: far)
        }
        return Self.composedResult(ResultComposer.renderS5Edges(
            direction: "incoming", edges: Array(edges)))
    }
}

// MARK: - Tier 3: Knowledge Graph runners

extension ToolDispatcher {

    /// `moot_file_fact` — assert a subject–predicate–object triple.
    ///
    /// `now` is sampled at the `InterfaceTools.dispatch` boundary so this
    /// runner is deterministic — it never calls `Date()` itself.
    func runFileFact(_ args: [String: JSONValue], now: Date) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let subject = try requireString(args, "subject")
        let trimmedSubject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        // Unicode scalars, the unit the Rust twin counts; see runFileMemory.
        let subjectLength = trimmedSubject.unicodeScalars.count
        guard subjectLength > 0, subjectLength <= DrawerStore.subjectLengthContract else {
            // Return as an isError result rather than throwing a JSON-RPC protocol error.
            // MCP clients render thrown JSON-RPC errors as bare "Tool execution failed"
            // and discard the message. An isError result puts the contract text in front
            // of the model so it can compress and retry. Mirrors the Rust port's
            // TOOL_DISPATCH_FAILURE path in run_file_fact (interface_tools.rs).
            return Self.errorResult(
                "subject must be 1–\(DrawerStore.subjectLengthContract) characters "
                    + "(got \(subjectLength)). One telegraphic sentence in the AI-facing "
                    + "register — compress, don't truncate."
            )
        }
        let predicate = try requireString(args, "predicate")
        let object = try requireString(args, "object")
        // source_id anchors the fact to a drawer in this estate. It is a local
        // drawer id or nothing — when the caller omits it the fact is filed
        // sourceless, and a value naming no drawer fails the write. The filing
        // binary's identity is provenance about the writer, not about the
        // source, so it is stamped into `addedBy` rather than substituted here.
        let providedSource = try optionalString(args["source_id"], argument: "source_id") ?? ""
        let fact = try await kit.captureKGFact(
            handle,
            subject: trimmedSubject,
            predicate: predicate,
            object: object,
            sourceDrawerID: providedSource,
            addedBy: serverIdentity,
            now: now
        )
        return Self.textResult("filed fact \(fact.id): [\(trimmedSubject)] \(predicate) [\(object)]")
    }

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
        let estate = try await kit.estate(for: handle)
        let allFactsRaw = try await estate.kgFacts(
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
            let result = try await estate.getDrawers(
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

    /// `moot_retire_fact` — invalidate a KG fact by row ID.
    func runRetireFact(_ args: [String: JSONValue]) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let rowID = try requireString(args, "id")
        try await kit.retireKGFact(handle, rowID: rowID)
        return Self.textResult("retired fact \(rowID)")
    }

    /// `moot_fact_timeline` — read all KG facts in chronological order,
    /// including retired ones, to trace how the estate's structured
    /// knowledge evolved.
    ///
    /// Delegates to `GeniusLocusKit.recallKGFactTimeline`, which reads every
    /// row ever filed regardless of lifecycle state (active, withdrawn,
    /// expired, decayed, superseded, rejected, tombstoned).  Each row's
    /// lifecycle tag is derived from the canonical `RowStateAutomaton`
    /// cluster: the state raw in bits 0–5 of `adjectiveBitmap` is classified
    /// by `RowState.cluster(ofRawState:)` (`cluster(s) = (s>>4)&0x3`). Cluster
    /// A is active/believed; clusters B and C are retired. The tag carries the
    /// retired cluster letter, not the raw state.
    ///
    /// Optional `entity` arg: when present, only facts whose subject or
    /// object contains the value (case-insensitive) are returned.  This
    /// matches the Rust port's entity-filter capability so both ports
    /// are parity-aligned on the full tool contract.
    ///
    /// Distinct from `moot_fact_search`, which returns active facts only.

    /// Render a retired lifecycle cluster as its single-letter label for the
    /// fact-timeline tag (`retired(B)` / `retired(C)`). Kept identical to the
    /// Rust port's `cluster_label` so both ports emit byte-identical tags.
    /// Cluster A is never passed here (it renders as the bare `active` tag).
    private static func clusterLabel(_ cluster: RowStateCluster) -> String {
        switch cluster {
        case .a: return "A"
        case .b: return "B"
        case .c: return "C"
        }
    }

    /// Derive the fact-timeline lifecycle tag from an `adjectiveBitmap` value.
    ///
    /// The tag comes from the canonical `RowStateAutomaton` cluster — the SAME
    /// partition (`cluster(s) = (s>>4)&0x3`) the rest of the substrate uses —
    /// never a hand-rolled raw boundary. The state raw lives in bits 0–5 of
    /// `adjectiveBitmap`. Cluster A is the believed/active partition; B
    /// (historical) and C (terminal) are retired. The tag carries the retired
    /// cluster letter, not the raw state, so any future state added inside a
    /// defined cluster classifies correctly. An undefined raw (not one of the
    /// ten cookbook §2.3 states) is reported verbatim as `unknown(raw)`.
    ///
    /// `internal` (not private) so the conformance suite can assert the tag for
    /// every defined state directly against `RowState.cluster`. Mirrors the
    /// Rust `lifecycle_tag_for_adjective_bitmap`.
    static func lifecycleTag(forAdjectiveBitmap adjectiveBitmap: Int64) -> String {
        let stateRaw = UInt8(adjectiveBitmap & 0x3F)
        switch RowState.cluster(ofRawState: stateRaw) {
        case .a:
            return "active"
        case .some(let c):  // .b or .c — both retired
            return "retired(\(clusterLabel(c)))"
        case nil:
            return "unknown(\(stateRaw))"
        }
    }

    func runFactTimeline(_ args: [String: JSONValue]) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let entity = try optionalString(args["entity"], argument: "entity")
        let factsRaw = try await kit.recallKGFactTimeline(handle, entity: entity)
        // MCP disclosure ceiling: drop Restricted/Secret facts before any output.
        // Parity with the default BitmapEvaluator ceiling (SensitivityAtMost(Elevated))
        // that normal recall applies via insertDefaults. Filter at the ARIA tool boundary
        // only — recallKGFactTimeline has internal callers that need the full set.
        let facts = factsRaw.filter { $0.adjectiveSensitivity.isBulkExportable }
        // Gate source-drawer IDs: for each distinct sourceDrawerID in the facts we are
        // about to emit (capped at 200), check whether it references an actual drawer in
        // the estate. If it does AND is Restricted/Secret, hide the ID at the MCP boundary.
        // sourceDrawerID holds a local drawer id or "", so the only non-matching value is
        // the empty one, which names no drawer. loadedIDs − admissible = the blocked
        // (restricted/secret) drawer-reference set. Parity with Rust run_fact_timeline.
        let emittedFacts = Array(facts.prefix(200))
        let distinctSourceIDs = Array(Set(emittedFacts.map { $0.sourceDrawerID }))
        let estate = try await kit.estate(for: handle)
        let hiddenSourceIDs: Set<String>
        if distinctSourceIDs.isEmpty {
            hiddenSourceIDs = []
        } else {
            let result = try await estate.getDrawers(
                ids: distinctSourceIDs,
                matchingFrame: RecallFrame(filterChain: []),
                hydrationLevel: .structured
            )
            let admissibleIDs = Set(result.admissible.map { $0.id })
            hiddenSourceIDs = result.loadedIDs.subtracting(admissibleIDs)
        }
        // Build S4 typed rows and render via ResultComposer.renderS4FactTimeline
        // (COMPOSER-02B). Source-drawer sensitivity gate preserved.
        let formatter = ISO8601DateFormatter()
        let timelineRows = emittedFacts.map { f -> FactTimelineRow in
            let filed = formatter.string(from: f.filedAt)
            let lifecycleTag = Self.lifecycleTag(forAdjectiveBitmap: f.adjectiveBitmap)
            // Gate source-drawer ID on sensitivity: hide when restricted/secret.
            let sourceID: String? = hiddenSourceIDs.contains(f.sourceDrawerID)
                ? nil
                : (f.sourceDrawerID.isEmpty ? nil : f.sourceDrawerID)
            return FactTimelineRow(
                filedAt: filed,
                lifecycle: lifecycleTag,
                factID: f.id,
                subject: f.subject,
                predicate: f.predicate,
                object: f.object,
                sourceDrawerID: sourceID)
        }
        return Self.composedResult(ResultComposer.renderS4FactTimeline(facts: timelineRows))
    }
}

// MARK: - Tier 4: Journal runners

extension ToolDispatcher {

    /// Server identity written into journal entries filed through the MCP surface.
    private static let mcpAgentName = "mcp-agent"

    /// `moot_write_journal` — write a diary entry for session continuity.
    ///
    /// Encodes `DiaryActorClass.mcpAgent` (raw=2) at bits 7–9 of the
    /// operational bitmap, per DiaryOperational.swift §5.6 layout.
    /// `now` is sampled at the `InterfaceTools.dispatch` boundary so this
    /// runner is deterministic — it never calls `Date()` itself.
    func runWriteJournal(_ args: [String: JSONValue], now: Date) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let entry = try requireString(args, "entry")
        let agentName = try optionalString(args["agent"], argument: "agent") ?? Self.mcpAgentName
        // Encode DiaryActorClass.mcpAgent (raw 2) at bits 7–9 (3-bit field).
        let actorBits = Int64(DiaryActorClass.mcpAgent.rawValue) << 7
        let diaryEntry = DiaryEntry(
            agentName: agentName,
            entry: entry,
            topic: "mcp-session",
            wing: "agents",
            room: "diary",
            filedAt: now,
            embeddingModelID: Self.defaultEmbeddingModelID,
            operationalBitmap: actorBits
        )
        try await kit.addDiaryEntry(in: handle, diaryEntry)
        return Self.textResult("wrote journal entry for \(agentName)")
    }

    /// `moot_read_journal` — read recent journal entries for an agent.
    func runReadJournal(_ args: [String: JSONValue]) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let agentName = try optionalString(args["agent"], argument: "agent") ?? Self.mcpAgentName
        // Clamp `last_n` through the shared boundary funnel: rejects negatives/zero with
        // invalidParams (a bare optionalInt would let -1 through → SQLite LIMIT -1 = all rows),
        // caps at 500 to prevent unbounded diary scans. Default 10 matches the moot_write_journal
        // convention and the Rust port's default. Parity: matches run_read_journal in dispatch.rs.
        let lastN = try Self.clampLimit(
            try optionalInt(args["last_n"], argument: "last_n"),
            argument: "last_n",
            default: 10,
            ceiling: Self.limitHardCeiling
        )
        let entries = try await kit.readDiaryEntries(in: handle, agentName: agentName, lastN: lastN)
        let lines = entries.map { e -> String in
            let filed = ISO8601DateFormatter().string(from: e.filedAt)
            return "[\(filed)]  \(e.entry.prefix(200))"
        }
        let header = "journal for \(agentName): \(entries.count) entry(s)"
        return Self.textResult(([header] + lines).joined(separator: "\n"))
    }
}

// MARK: - Tier 5: Estate runners

extension ToolDispatcher {

    /// `moot_estate_status` — return a summary of the estate.
    ///
    /// Appends the static `ARIASessionProtocol` block unconditionally
    /// so every cold-start call receives enough context to navigate the
    /// full surface without prior knowledge of ARIA.
    ///
    /// `trace_rows` is included so the reward pipeline's read-log size is
    /// observable — mirrors Rust `run_estate_status` which calls
    /// `count_recall_traces`. Best-effort: a failure here must not break
    /// the status response.
    ///
    /// `sync:` reports the real ConvergenceKit backend state via
    /// `GeniusLocusKit.syncStateToken(for:)`. When no sync engine is
    /// registered the estate is local-only and the field reads
    /// `"sync: local-only"`. The fabricated `"status: connected"` literal
    /// has been removed (OP-1 honesty fix — never fabricate status).
    func runEstateStatus(_ args: [String: JSONValue]) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let estate = try await kit.estate(for: handle)
        let drawers = try await estate.allDrawers()
        // "active" means currently believed: RowState cluster A only.
        // Cluster A is the partition where (stateRaw >> 4) & 0x3 == 0 — the
        // set of states the substrate considers "live" (active, pending, etc.).
        // `tombstonedAt == nil` is NOT sufficient: a rejected drawer has no
        // tombstone timestamp but is NOT in cluster A and must not count as
        // active. `memory_search` filters by cluster A; estate_status must agree.
        // The cluster predicate is read from bits 0–5 of `adjectiveBitmap` via
        // the same `RowState.cluster(ofRawState:)` used by fact-timeline tagging.
        let active = drawers.filter {
            let stateRaw = UInt8($0.adjectiveBitmap & 0x3F)
            return RowState.cluster(ofRawState: stateRaw) == .some(.a)
        }
        // Sensitivity ceiling (#50): restricted/secret drawers contribute
        // nothing to this surface — not the wing listing, and not any count.
        // Wing names derived from restricted/secret drawers leak topic
        // metadata; a count that moves with the restricted set is the same
        // leak in scalar form, since this tool has no sensitivity-grant
        // plumbing and every caller is an ungranted one. Matches the
        // estate-map ceiling. `isBulkExportable` is true for .normal and
        // .elevated, false for .restricted and .secret.
        //
        // EVERY drawer-derived aggregate below reads from `visible` or
        // `visibleTotal`. An aggregate added here inherits that rule: derive
        // it from a filtered set, or the next reader learns the size of a
        // population they cannot see.
        let visible = active.filter { $0.adjectiveSensitivity.isBulkExportable }
        // "total" counts all non-erased rows (tombstone = erased permanently),
        // under the same ceiling — hence the wider cluster scope but the same
        // sensitivity predicate as `visible`.
        let visibleTotal = drawers.filter {
            $0.tombstonedAt == nil && $0.adjectiveSensitivity.isBulkExportable
        }
        // Resolve parentNodeIds to display names for wing listing. Drawer
        // no longer carries stored wing/room after node-tree migration.
        let visibleNodeNames = try await estate.resolveNodeNames(
            parentNodeIds: visible.map(\.parentNodeId))
        let wings = Set(visible.compactMap { visibleNodeNames[$0.parentNodeId]?.wing }).sorted()
        let facts = try await kit.recallKGFacts(handle)
        // Trace row count — the reward pipeline's read log size. A read failure
        // must not break the whole status response, but it must NOT be reported
        // as `0`: a fabricated zero is indistinguishable from a genuinely empty
        // trace table and would lie about reward-pipeline depth. On failure the
        // field reads "unavailable" so the consumer can tell "no traces" from
        // "could not read". Mirrors Rust run_estate_status.
        let traceRows: String
        if let count = try? await kit.countRecallTraces(handle) {
            traceRows = String(count)
        } else {
            traceRows = "unavailable"
        }
        // Sync state — read the real ConvergenceKit backend state via GLK.
        // Best-effort: a syncStateToken failure must not break the status
        // response; fall back to "local-only" so the field is always present
        // and honest. "local-only" means no sync engine is wired for this estate.
        let syncToken = (try? await kit.syncStateToken(for: handle)) ?? "local-only"
        let fdcFloor = try await estate.meta(key: Self.fdcRecalcedDataVersionMetaKey)
        let currentFDCRecalculationVersion = FDC.recalculationVersion
        let fdcRecalculationState: String
        if fdcFloor == currentFDCRecalculationVersion {
            fdcRecalculationState = "current"
        } else if fdcFloor == nil {
            fdcRecalculationState = "missing"
        } else {
            fdcRecalculationState = "stale"
        }
        // Subject-debt counter (PR-04): presence debt over the live
        // sensitivity-visible set — N subject-bearing / M eligible (non-empty
        // content), K missing. It counts `visible`, not `active`, under the
        // ceiling declared above: the debt an ungranted caller is being asked
        // to pay is exactly the debt it is allowed to see, so this counter and
        // the `moot_memory_list filter:missing_subject` enumerator it points
        // the AI at describe one population. This is the every-load reminder
        // that drives the consent-gated interactive backfill (the AI asks the
        // user for time and permission before walking the enumerator →
        // setSubject; standing behavior documented in the estate-status
        // teachme). Presence debt only — pipeline-version regeneration debt
        // stays the store verb countMissingSubject's concern.
        let subjectEligible = visible.filter { !$0.content.isEmpty }
        let subjectBearing = subjectEligible.filter { $0.subject != nil }
        var stats = [
            "estate: \(handle.estateName) [\(handle.estateUUID)]",
            "memories: \(visible.count) active (\(visibleTotal.count) total)",
            "subjects: \(subjectBearing.count)/\(subjectEligible.count) "
                + "(\(subjectEligible.count - subjectBearing.count) missing)",
            "wings: \(wings.joined(separator: ", "))",
            "kg facts: \(facts.count) active",
            "trace_rows: \(traceRows)",
            "sync: \(syncToken)",
            // Frozen posture of this serve (`mootx01 serve --frozen` /
            // MOOTX01_FROZEN=1): true means mutating tools are refused and the
            // read path writes nothing. A process property, not estate state.
            "frozen: \(posture.statusValue)",
            "fdc_recalculation: \(fdcRecalculationState)",
            "fdc_recalculation_floor: \(fdcFloor ?? "none")",
            "fdc_recalculation_current: \(currentFDCRecalculationVersion)",
        ]
        // Shared-content migration/reclaim status (shared-content 1.1 P5):
        // appended only when a migration record exists — fresh estates that
        // never ran detection leave the response shape unchanged. Best-effort:
        // a read failure appends nothing rather than breaking the response.
        if let reclaim = try? await kit.sharedContentReclaimStatus(handle: handle),
           let state = reclaim.state {
            var line = "shared_content_migration: \(state.rawValue)"
            if let estimated = reclaim.estimatedReclaimableBytes {
                line += ", estimated_reclaimable_bytes: \(estimated)"
            }
            if let reclaimed = reclaim.reclaimedBytes {
                line += ", reclaimed_bytes: \(reclaimed)"
            }
            stats.append(line)
        }
        // surface a plugin/binary version-skew advisory when the
        // host detected one. Appended only when present so the common
        // no-skew case leaves the response shape unchanged.
        if let versionSkewAdvisory {
            stats.append("version_skew: \(versionSkewAdvisory)")
        }
        // Upstream-release advisory (see `updateAdvisoryProvider`): evaluated
        // lazily here and in ping only — the host rate-limits the underlying
        // release-feed probe, and the common up-to-date case appends nothing.
        if let updateAdvisoryProvider, let update = await updateAdvisoryProvider() {
            stats.append("update_available: \(update)")
        }
        // Composite condition surface (Bob ruling 2026-08-26): estate_status
        // folds in the drain report and the rebuild status so the AI reads
        // the estate's condition in ONE call; the narrow moot_drain_status /
        // moot_rebuild_status tools stay the cheap machine-polling surfaces.
        let drains = try await kit.drainStatuses(handle)
        if drains.isEmpty {
            stats.append("drains: none")
        } else {
            stats.append("drains: \(drains.count)")
            for d in drains {
                stats.append("  \(d.name): \(d.isDraining ? "draining" : "idle") — pending: \(d.pending), in_flight: \(d.inFlight)")
            }
        }
        let rebuildSpanOpen = await kit.derivedRebuildActive(for: handle)
        let rebuildGuardBusy = await Self.reindexGuard.isBusy
        stats.append("rebuild: \(rebuildSpanOpen || rebuildGuardBusy ? "running" : "idle")")
        return Self.textResult(stats.joined(separator: "\n") + Self.ARIASessionProtocol + Self.modesStatusSection)
    }

    /// Keep host-provided status values on one line so an asset error cannot
    /// forge an additional estate-status field.
    private static func singleLineStatusValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    /// `moot_monitoring_status` — read or write the daemon's telemetry monitoring flag.
    ///
    /// ## Read path (absent `enabled` argument)
    /// Returns the current effective monitoring state without mutation.
    ///
    /// ## Write path (present `enabled: Bool` argument)
    /// Persists `enabled` to the stats store and reports the new effective state.
    /// Writes the `monitoring_source: user` marker so downstream readers can
    /// distinguish operator-driven changes from env-var or default-seeded state.
    ///
    /// ## No-store case
    /// When `monitoringControl` is `nil` (stdio mode, test harnesses, provision-less
    /// contexts), the tool reports `monitoring: unavailable` and never fabricates
    /// a false enabled/disabled state. Mirrors the B-6 honesty discipline.
    ///
    /// Permission tier: `ask` (it can mutate monitoring state when `enabled` is
    /// supplied — classified in ToolMutationInventory.mutationTools, out-of-band sensitivity grants).
    func runMonitoringStatus(_ args: [String: JSONValue]) async throws -> JSONValue {
        guard let control = monitoringControl else {
            // No stats store wired — honest "unavailable" response. Never say
            // "disabled" when the true answer is "no store to read from".
            return Self.textResult("monitoring: unavailable (no telemetry store wired)")
        }

        // Write path: `enabled` argument present → set flag, return new state.
        if let enabledArg = try optionalBool(args["enabled"], argument: "enabled") {
            await control.set(enabledArg)
            // Re-read the persisted value so the response reflects what was
            // actually written, not just what was requested.
            let effective = await control.read()
            var lines = [
                "monitoring: \(effective.map { $0 ? "enabled" : "disabled" } ?? "unavailable")",
                "monitoring_source: user",
            ]
            if effective == nil {
                lines.append("warning: flag was written but could not be re-read; retry moot_monitoring_status to confirm")
            }
            return Self.textResult(lines.joined(separator: "\n"))
        }

        // Read path: no `enabled` argument → report current state only.
        let current = await control.read()
        return Self.textResult("monitoring: \(current.map { $0 ? "enabled" : "disabled" } ?? "unavailable")")
    }

    /// `moot_estate_map` — return the estate's structural map with memory counts.
    ///
    /// All drawers (including hint memories in AI_Charter_Hint) are counted
    /// normally — no special-casing. The map shows wing → rooms → counts.
    ///
    /// Drawer no longer carries stored wing/room (node-tree migration).
    /// All display names are resolved from the node tree via
    /// `Estate.resolveNodeNames(parentNodeIds:)`.
    /// `moot_memory_list` — enumerate drawer IDs in a wing, optionally filtered
    /// by room. No semantic query — this is structural inventory, not search.
    /// Returns each drawer's ID, room, and a content preview (first 80 chars).
    /// Capped at 200 results to prevent unbounded output.
    func runMemoryList(_ args: [String: JSONValue]) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let wing = try requireString(args, "wing")
        let room = try optionalString(args["room"], argument: "room")
        // Optional filter. `missing_subject` is the subject-debt backfill
        // enumerator (PR-02): id-only rows of live drawers whose subject is
        // NULL, so a consenting backfill session can walk them with
        // moot_update_memory mutation=setSubject without hauling content.
        let filterName = try optionalString(args["filter"], argument: "filter")
        let missingSubjectOnly: Bool
        switch filterName {
        case nil: missingSubjectOnly = false
        case "missing_subject": missingSubjectOnly = true
        default:
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Unknown filter: \(filterName ?? ""). Accepted: missing_subject"
            )
        }
        let estate = try await kit.estate(for: handle)
        let drawers = try await estate.allDrawers()
        // Filter to Cluster A (currently-believed) only (#9): withdrawn,
        // superseded, expired, rejected rows have tombstonedAt==nil but are
        // NOT currently-believed. Also apply the sensitivity ceiling.
        let visible = drawers.filter {
            $0.tombstonedAt == nil
            && !$0.isKnewPast && !$0.isTerminal
            && $0.adjectiveSensitivity.isBulkExportable
        }

        let nodeNames = try await estate.resolveNodeNames(
            parentNodeIds: visible.map(\.parentNodeId))

        var matches: [(drawer: Drawer, room: String)] = []
        for d in visible {
            if missingSubjectOnly, d.subject != nil { continue }
            let names = nodeNames[d.parentNodeId]
            let dWing = names?.wing ?? ""
            let dRoom = names?.room ?? ""
            guard dWing == wing else { continue }
            if let room, !room.isEmpty, dRoom != room { continue }
            matches.append((drawer: d, room: dRoom))
        }

        let capped = matches.prefix(200)
        if missingSubjectOnly {
            // Missing-subject backfill path (PR-02): id-only structural inventory
            // so the walker can call moot_update_memory=setSubject without
            // hauling content. Not a semantic row surface — custom format retained.
            let filterSuffix = " [filter: missing_subject]"
            var lines: [String] = ["memory_list: \(capped.count) drawer(s) in \(wing)\(room.map { "/\($0)" } ?? "")\(filterSuffix)"]
            if matches.count > 200 {
                lines.append("(showing first 200 of \(matches.count))")
            }
            for m in capped { lines.append("  \(m.drawer.id) [\(m.room)]") }
            return Self.textResult(lines.joined(separator: "\n"))
        }
        // Normal listing: migrate to ResultComposer.renderS2Listing (COMPOSER-02B).
        // One S2 row per drawer: uuid · subject · bestSpan · sscFacts · eventTime.
        // Adornments not batch-read here (listing is a structural scan, not a
        // recall surface; adornments are surfaced in search/get per spec §11.5).
        let roomLabel = room ?? "(all)"
        let candidateRows: [CandidateRowData] = capped.map { m in
            CandidateRowData(
                id: m.drawer.id,
                subject: m.drawer.subject,
                bestSpan: m.drawer.content.isEmpty ? nil : m.drawer.content,
                eventTime: ResultComposer.iso8601(m.drawer.eventTime))
        }
        var composed = ResultComposer.renderS2Listing(wing: wing, room: roomLabel, rows: candidateRows)
        if matches.count > 200 {
            // Append cap notice after the header; splice before the rows.
            let capNote = "(showing first 200 of \(matches.count))"
            let lines = [composed.text.components(separatedBy: "\n").first ?? ""]
                + [capNote]
                + Array(composed.text.components(separatedBy: "\n").dropFirst())
            composed = ComposedResult(text: lines.joined(separator: "\n"), structured: composed.structured)
        }
        return Self.composedResult(composed)
    }

    func runEstateMap(_ args: [String: JSONValue]) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let estate = try await kit.estate(for: handle)
        let drawers = try await estate.allDrawers()
        // Active = non-tombstoned rows.
        let active = drawers.filter { $0.tombstonedAt == nil }

        // Sensitivity ceiling — matches the default BitmapEvaluator ceiling
        // (SensitivityAtMost(.elevated)) that normal recall applies. Restricted
        // and secret rows are excluded from the public map so their wing/room
        // names and counts are not visible to callers that do not hold an
        // elevated-sensitivity grant. isBulkExportable is true for .normal and
        // .elevated, false for .restricted and .secret.
        let visible = active.filter { $0.adjectiveSensitivity.isBulkExportable }

        // Resolve all visible drawers' parentNodeIds to display names once.
        let nodeNames = try await estate.resolveNodeNames(
            parentNodeIds: visible.map(\.parentNodeId))

        // Group by wing then room, counting visible (sensitivity-gated) drawers
        // per location. Charter drawers (_charter structural drawers) are
        // auto-seeded at normal sensitivity and pass through unchanged.
        var map: [String: [String: Int]] = [:]
        for d in visible {
            let names = nodeNames[d.parentNodeId]
            let wing = names?.wing ?? ""
            let room = names?.room ?? ""
            map[wing, default: [:]][room, default: 0] += 1
        }

        var lines: [String] = ["estate map: \(handle.estateName)"]
        for wing in map.keys.sorted() {
            lines.append("  \(wing)/")
            for room in (map[wing] ?? [:]).keys.sorted() {
                let count = map[wing]?[room] ?? 0
                lines.append("    \(room): \(count)")
            }
        }
        return Self.textResult(lines.joined(separator: "\n"))
    }

    /// `moot_estate_ping` — confirm the estate handle is live and the server
    /// process is reachable.
    ///
    /// ARIA_MCP is a long-running stdio process that opens one estate on
    /// startup and holds it for the session. There is no transient
    /// disconnection state: the handle is either registered (open) or not.
    /// This tool resolves the handle — if it succeeds, the estate is live;
    /// if it throws `estateNotOpen`, the server needs restarting. No drawer
    /// scan is performed; this is a true lightweight ping.
    ///
    /// The response includes a build serial so a driver can confirm it is
    /// talking to the most recently compiled binary (see `buildSerial` and
    /// `ToolDispatcher.deriveBuildSerial()`). The serial changes on every
    /// relink and can be overridden via `MOOTX01_BUILD_SERIAL`.
    func runEstatePing(_ args: [String: JSONValue]) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        // resolveHandle checks only the immutable `estates` dictionary (populated
        // at construction); it cannot detect an estate that was closed or quiesced
        // at runtime. Verify liveness against the GLK registry via mountState(for:),
        // which reads the live mountStates dictionary on the actor. An absent entry
        // or a non-mounted state both indicate the estate is no longer live.
        let state = await kit.mountState(for: handle)
        switch state {
        case .mounted:
            // append the version-skew advisory when present —
            // same opt-in shape as moot_estate_status.
            var pong = "pong: estate \(handle.estateName) [\(handle.estateUUID)] is live — build \(buildSerial)"
            if let versionSkewAdvisory {
                pong += "\nversion_skew: \(versionSkewAdvisory)"
            }
            // Upstream-release advisory — same opt-in shape as version_skew.
            // The provider's TTL cache keeps this a memory read on all but
            // the first ping of each cache window, preserving "true
            // lightweight ping" in the common case.
            if let updateAdvisoryProvider, let update = await updateAdvisoryProvider() {
                pong += "\nupdate_available: \(update)"
            }
            return Self.textResult(pong)
        case .quiesced, .draining:
            // Return a tool-level error (not a JSON-RPC protocol error) so the
            // caller sees an actionable message through the tools/call result.
            return Self.errorResult(
                "estate \(handle.estateName) [\(handle.estateUUID)] is quiesced and not accepting new work"
            )
        case .unmounted, .none:
            // Estate is not in the GLK registry — it may have been closed since
            // this server instance started. Surface as a tool-level error.
            return Self.errorResult(
                "estate \(handle.estateUUID) is not mounted in the GLK registry; re-open or re-provision it"
            )
        }
    }

    /// `moot_reindex` — enqueue encode jobs for drawers not yet in the Corpus.
    ///
    /// This is a maintenance / admin tool, NOT one of the nine ARIA grammar
    /// verbs. It is used to backfill existing content that was captured before
    /// the dual-path intake wiring landed (or after an accidental data loss in
    /// the BM25/vector indexes). All unindexed drawers are enqueued for
    /// background encoding via the estate's encode queue (the same `.regular`
    /// path as normal captures). Encoding is asynchronous — this call returns
    /// as soon as the jobs are enqueued, not after they complete.
    ///
    /// Idempotent: drawers already in the Corpus BundleStore are skipped.
    /// Callers can poll `moot_drain_status` for encode-queue depth or simply
    /// wait for the background drain worker to settle.
    ///
    /// reindexMissing now AUTO-CONTINUES to FULL coverage (enqueue a pass → await
    /// its drain → re-collect), so this runs it on a detached task and returns
    /// immediately; the resident daemon's encode-drain converges in the
    /// background regardless of estate size. Poll `moot_drain_status` to watch it
    /// finish. (Mirrors the palace-import background-processing model — no
    /// repeated calls are needed.)
    /// Concurrency guard (#19/#33): prevent multiple concurrent reindex runs.
    /// A reindex is expensive and idempotent — a second concurrent run wastes
    /// CPU and can enqueue duplicate encode jobs.
    private static let reindexGuard = ReindexGuard()

    /// `now` is threaded from the bench clock seam. Default `Date()` covers
    /// direct runner calls in tests.
    func runReindex(_ args: [String: JSONValue], now: Date = Date()) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        switch await Self.startReindex(kit: kit, handle: handle, now: now) {
        case .alreadyRunning:
            return Self.textResult("reindex already running — poll moot_drain_status to watch progress")
        case .running:
            return Self.textResult(
                "reindex started: backfilling every unindexed drawer to full coverage in the background — poll moot_drain_status to watch the encode queue converge")
        }
    }

    /// Typed shared launch seam for v1 and v2. The same process-wide actor
    /// owns the in-flight state, so a call through either surface observes the
    /// other and never starts duplicate deferred work.
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
                let n = try await kit.reindexMissing(handle: handle, now: now)
                fputs("reindex: background backfill complete — \(n) drawers indexed to full coverage\n", stderr)
            } catch {
                fputs("reindex: background backfill failed: \(error)\n", stderr)
            }
        }
        return .running
    }

    /// `moot_drain_status` — report every long-running background drain the
    /// estate currently runs, for monitoring asynchronous work (e.g. watching
    /// an import's encode queue converge after `moot_palace_import`).
    ///
    /// Lightweight and pollable: unlike `moot_estate_status` it does NOT append
    /// the ARIASessionProtocol orientation block, because this tool is meant to
    /// be called repeatedly while a drain settles — appending the protocol on
    /// every poll would bloat the transcript.
    ///
    /// Today the only drain is `corpus_encode` — the encode/ingest queue that
    /// turns captured/imported text into BM25 + vector content asynchronously.
    /// Each drain reports pending + in-flight job counts, a draining/idle state,
    /// and optional drain-specific detail (the corpus drain reports its live
    /// encoded-chunk count, so forward progress is visible). The report is a
    /// LIST so additional drains surface here automatically when they exist; an
    /// estate with no Corpus registered reports no drains.
    /// Reserved lane name for the subject-backfill drain (PR-04). The
    /// PR-09/10 rider registers a drain under THIS name; the generic
    /// renderer below then carries it with no further dispatcher change.
    /// Its `pending` will be a row-level ELIGIBILITY count (subject debt),
    /// not queue depth — when the rider lands, the benchmarker's
    /// `barrierNonGatingLanes` denylist must gain this name in the same
    /// mission or the encode barrier hangs on healthy estates (the
    /// distillation-lane precedent). Twin: Rust `SUBJECT_BACKFILL_LANE_NAME`.
    static let subjectBackfillLaneName = "subject_backfill"

    /// `moot_rebuild_status` — the derived-state rebuild operation status
    /// (Bob ruling 2026-08-26: a rebuild is an OPERATION, never a drain
    /// lane — drains are queues). Reports `rebuild: running` while either
    /// (a) a GLK derived-rebuild span is open for the estate (reindexMissing
    /// backfill / basis retrain + re-embed, whoever triggered it — the
    /// moot_reindex detached task, a palace-import tail, or the dream
    /// probe), or (b) this dispatcher's reindex guard is busy (the window
    /// between "reindex started" and the detached task opening its span).
    /// `moot_estate_status` composes this line into its condition report;
    /// settle gates poll this tool directly.
    func runRebuildStatus(_ args: [String: JSONValue]) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let spanOpen = await kit.derivedRebuildActive(for: handle)
        let guardBusy = await Self.reindexGuard.isBusy
        return Self.textResult("rebuild: \(spanOpen || guardBusy ? "running" : "idle")")
    }

    func runDrainStatus(_ args: [String: JSONValue]) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let drains = try await kit.drainStatuses(handle)
        guard !drains.isEmpty else {
            // No drains registered (a bare estate with no Corpus). Honest empty
            // report — distinct from "all drains idle", which lists drains at 0.
            return Self.textResult("drains: none")
        }
        var lines: [String] = ["drains: \(drains.count)"]
        for d in drains {
            let state = d.isDraining ? "draining" : "idle"
            var line = "  \(d.name): \(state) — pending: \(d.pending), in_flight: \(d.inFlight)"
            if let detail = d.detail {
                line += ", \(detail)"
            }
            lines.append(line)
        }
        return Self.textResult(lines.joined(separator: "\n"))
    }

    /// `moot_timing_report` — derive INGEST and CYCLE timing metrics from
    /// the estate's audit log (C3+A6, benchmark reset 2026-08-13).
    ///
    /// ONE derivation, TWO consumers (§6b): this tool and the future
    /// performance-health duty both call NeuronKit's `deriveTimings`, so the
    /// benchmark and the product can never disagree about what "INGEST time"
    /// means. Read-only: the audit log is append-only and the derivation is
    /// pure; no timing state is stored server-side. The CALLER keeps the
    /// returned `watermark_ms` and passes it back as `since_ms` for
    /// incremental scans (A6 — a daily full scan is O(corpus) on exactly the
    /// estates the duty exists to protect).
    ///
    /// Like `moot_drain_status`, no orientation block: this tool is called
    /// repeatedly by harnesses and duties, and the protocol would bloat
    /// every poll.
    /// Hard cap on audit events collected per `moot_timing_report` call.
    ///
    /// The MCP tool surface is reachable by any connected client, so an
    /// uncapped `since_ms: 0` scan was a caller-triggerable resource
    /// exhaustion: the 4096-per-page loop bounded peak memory per PAGE, but
    /// the whole window still accumulated in memory before deriving.
    ///
    /// 262,144 = 64 full pages of 4,096. Chosen against measurement, not a
    /// round number: the largest real estate observed (live CE estate,
    /// 2026-08-15) carries 162,860 audit events (33 MB, ~216 B/row), so the
    /// cap is ~1.6× that — every real estate today keeps single-call
    /// full-history semantics, while the worst case is bounded at
    /// ~57 MB transient (262,144 × ~220 B in-memory events) instead of
    /// unbounded. Beyond the cap, the existing `watermark_ms` paging
    /// contract continues the scan (clamp, not reject — rejecting would
    /// break a legitimate first call on a large estate).
    /// Parity: mirrors `TIMING_WINDOW_MAX_EVENTS` in Rust `interface_tools.rs`.
    static let timingWindowMaxEvents = 262_144

    /// Collect the audit window for the timing derivation, capped at
    /// `maxEvents` total events for the call.
    ///
    /// Paging protocol: the HLC cursor is seeded exactly as
    /// EstatePerformanceHealthDuty does — physicalTime = sinceMs,
    /// logicalCount = 0, nodeID = 0 — sitting at the very start of the given
    /// millisecond; events from that same millisecond but with
    /// logicalCount > 0 are re-fetched, but deriveTimings' sinceExclusiveMs
    /// guard excludes their contribution (A6 exactly-once contract). When
    /// sinceMs == 0 the cursor is nil, meaning start from the beginning of
    /// the log; advancing via last.hlc is the standard paging protocol and
    /// the audit-log index makes the resume cheap. 4096 events per page
    /// bounds peak memory per page; `maxEvents` bounds the CALL.
    ///
    /// Truncation semantics: when the cap cuts the window, tier 3/4 pair
    /// captures whose markers land beyond the cut pair-lose for this call
    /// (they surface in the report's `unbounded` counts), and events sharing
    /// the boundary millisecond are excluded by the next call's
    /// sinceExclusiveMs guard. Acceptable for a statistical p50/p95
    /// maintenance metric; the alternative — unbounded collection — was the
    /// defect. `truncated` is true when the window MAY have more events;
    /// the caller pages forward with the returned watermark.
    ///
    /// Internal (not private) so tests can drive truncation with a small
    /// `maxEvents` against a small seeded log.
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
                // Cap landed exactly on a full-page boundary — there may be
                // more events; the watermark lets the caller find out.
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
                // Events from this page were discarded — definitely more left.
                truncated = true
                break
            }
            guard page.count == pageSize, let last = page.last else { break }
            cursor = last.hlc
        }
        return (events, truncated)
    }

    func runTimingReport(_ args: [String: JSONValue]) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let sinceMs = Int64(try optionalInt(args["since_ms"], argument: "since_ms") ?? 0)

        // Collect the window, capped at the call level (see
        // timingWindowMaxEvents for the measured justification). The window
        // up to the cap is collected before deriving — tier 3/4 pair captures
        // have markers that can arrive many pages later.
        let (events, truncated) = try await collectTimingWindow(
            handle: handle, sinceMs: sinceMs, maxEvents: Self.timingWindowMaxEvents)

        let d = NeuronKit.deriveTimings(events: events, sinceExclusiveMs: sinceMs)

        // Percentiles over ascending-sorted samples (nearest-rank).
        func pct(_ sorted: [Int64], _ p: Double) -> String {
            guard !sorted.isEmpty else { return "-" }
            let idx = min(sorted.count - 1, Int(Double(sorted.count) * p))
            return "\(sorted[idx])ms"
        }
        func line(_ label: String, _ sorted: [Int64], unbounded: Int? = nil) -> String {
            var s = "  \(label): n=\(sorted.count), p50=\(pct(sorted, 0.5)), p95=\(pct(sorted, 0.95))"
            if let u = unbounded { s += ", unbounded=\(u)" }
            return s
        }
        var lines = ["timing report (audit-derived, since_ms=\(sinceMs)):"]
        lines.append(line("ingest_exact", d.ingestExactMs))
        if d.ingestBulk.isEmpty {
            lines.append("  ingest_bulk: n=0")
        } else {
            let rows = d.ingestBulk.reduce(0) { $0 + $1.rows }
            let wall = d.ingestBulk.reduce(Int64(0)) { $0 + $1.wallMs }
            let rate = wall > 0 ? String(format: "%.1f", Double(rows) / (Double(wall) / 1000.0)) : "-"
            lines.append("  ingest_bulk: n=\(d.ingestBulk.count) units, rows=\(rows), rows_per_sec=\(rate)")
        }
        lines.append(line("cycle_vector", d.cycleVectorMs))
        lines.append(line("cycle_novel", d.cycleNovelMs, unbounded: d.cycleNovelUnbounded))
        lines.append(line("cycle_dreamt", d.cycleDreamtMs, unbounded: d.cycleDreamtUnbounded))
        lines.append("  watermark_ms: \(d.watermarkMs)")
        if truncated {
            // Only emitted when the cap cut the window, so the untruncated
            // report stays byte-identical to the pre-cap output shape
            // (harness parsers prefix-match lines and skip unknown ones,
            // but there is no reason to churn the common case).
            lines.append("  window: truncated at \(Self.timingWindowMaxEvents) events — pass watermark_ms back as since_ms to continue")
        }
        return Self.textResult(lines.joined(separator: "\n"))
    }
    /// `moot_palace_import` — import a MemPalace directly into the estate,
    /// bypassing NoteIR. Reads palace/chroma.sqlite3, tunnels.json, and
    /// knowledge_graph.sqlite3 from `palace_path`, then applies all four
    /// import guards (tombstone, content-idempotent dedup, sensitivity floor,
    /// tunnel signature dedup). Returns a structured import summary.
    ///
    /// Gated behind `MOOTX01_VAULT` for the same reason as vault import/export:
    /// this tool opens arbitrary SQLite files from the local filesystem (a
    /// potential path-traversal vector if the caller is untrusted). Disabled
    /// installs (MOOTX01_VAULT=0) return a clear tool-level refusal.
    /// `now` is threaded from the bench clock seam. Default `Date()` covers
    /// direct runner calls in tests.
    func runPalaceImport(_ args: [String: JSONValue], now: Date = Date()) async throws -> JSONValue {
        guard ToolProjection.vaultEnabled(environment: environment) else {
            return Self.errorResult(
                "vault is disabled; reinstall with mootx01 install --vault-on to enable import/export"
            )
        }
        let handle = try resolveHandle(args)
        let palacePath = try requireString(args, "palace_path")
        let palaceURL = URL(fileURLWithPath: palacePath, isDirectory: true)
        // `now` is the bench-clock instant threaded from `InterfaceTools.dispatch`.

        // mode (encode SPEED, default foreground): foreground drains the encode
        // queue hard on the performance cores; background yields for very large
        // imports so the drain does not saturate the host. SPEED only — the WRITE
        // strategy (bulk transaction vs per-item stream) is chosen automatically
        // by source size inside PalaceBridge, never by the caller. Fail-closed on
        // an unknown value rather than silently defaulting.
        let modeStr = (try optionalString(args["mode"], argument: "mode")) ?? "foreground"
        let mode: EncodeSpeed
        switch modeStr.lowercased() {
        case "foreground": mode = .foreground
        case "background": mode = .background
        default:
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "mode must be \"foreground\" or \"background\"; omit it to use the default (foreground)"
            )
        }
        let bridge = PalaceBridge(kit: kit)
        let report = try await bridge.importPalace(at: palaceURL, into: handle, now: now,
            progress: { processed, total in
                // Live progress to stderr, fired by the bridge every 10 records.
                // The MCP response is returned only at completion, so stderr is the
                // sole live-progress channel during a long background import.
                fputs("palace import: \(processed)/\(total) drawers\n", stderr)
            },
            mode: mode)

        // DESIGN: the import TRIGGERS its own post-import processing in the BACKGROUND
        // and releases the caller immediately — it does NOT rely on the AI to run
        // moot_reindex / moot_dream next (that is not the design). A detached task runs
        // `reindexMissing`, which enqueues an encode job for every imported drawer (the
        // resident daemon's encode-drain worker then ingests them into the BM25 +
        // vector lanes and rolls up the touched rooms off the write path) and runs the
        // O(N) Merkle full-tree rollup; the governor's dreaming duty builds the
        // association matrix on its cadence. This call returns the moment the import
        // rows are durable, so the AI is freed while indexing/rollup/dreaming proceed
        // in the background on the resident daemon. (In a stdio one-shot the process
        // exits when its input closes, so a caller that needs the background work to
        // finish must keep the connection open — the resident HTTP daemon is the host.)
        Task.detached { [kit] in
            do {
                let n = try await kit.reindexMissing(handle: handle, now: now)
                fputs("palace import: background processing complete — \(n) drawers indexed to full coverage (auto-continued reindex), corpus embedding-basis retrained on the full import, Merkle rolled up; semantic/vector recall now live\n", stderr)
            } catch {
                fputs("palace import: background reindex failed: \(error)\n", stderr)
            }
        }

        return Self.textResult(
            "palace import complete: \(report.drawersWritten) written, " +
            "\(report.drawersUpdated) updated, " +
            "\(report.drawersSkippedUnchanged) unchanged, " +
            "\(report.drawersSkippedTombstoned) tombstoned, " +
            "\(report.tunnelsCreated) tunnels, " +
            "\(report.itemsSkipped) skipped. " +
            "Rows are durable NOW, but recall lights up in stages — background indexing has started and is not yet finished (no follow-up call is needed). " +
            "Keyword (exact-term) and structured (wing/room) recall work almost immediately. " +
            "Full SEMANTIC / vector recall — meaning-based RAG search — becomes available only AFTER background indexing completes: every drawer is chunked and embedded, then the corpus embedding-basis is retrained on the whole import and republished, so recently-imported terms enter the semantic vocabulary. On a large import that takes tens of seconds to a few minutes. " +
            "BE PATIENT: poll moot_drain_status until it reports idle before relying on semantic search over the imported memories, and tell the user that deep meaning-based recall over a fresh import becomes available shortly after import, not instantly."
        )
    }

    /// `moot_json_import` — import a seed file (rigid versioned JSON,
    /// schema v1) into the estate: the bulk seeding lane. The whole file is
    /// validated BEFORE any write; any schema violation or lineage
    /// collision (strict append) returns a tool-level error naming the
    /// offending element with the estate untouched — the zero-partial-write
    /// contract. Canonical format doc:
    /// `packages/kits/VaultKit/docs/JSON_IMPORT_FORMAT.md`.
    ///
    /// Gated behind `MOOTX01_VAULT` for the same reason as vault/palace
    /// import: this tool reads arbitrary files from the local filesystem.
    /// `now` is threaded from the bench clock seam. Default `Date()` covers
    /// direct runner calls in tests.
    func runJsonImport(_ args: [String: JSONValue], now: Date = Date()) async throws -> JSONValue {
        guard ToolProjection.vaultEnabled(environment: environment) else {
            return Self.errorResult(
                "vault is disabled; reinstall with mootx01 install --vault-on to enable import/export"
            )
        }
        let handle = try resolveHandle(args)
        let path = try requireString(args, "path")
        let seedURL = URL(fileURLWithPath: path)
        // `now` is the bench-clock instant threaded from `InterfaceTools.dispatch`.

        // Optional default wing for records that omit `wing`. An explicit
        // empty string is invalid rather than silently ignored.
        let wing = try optionalString(args["wing"], argument: "wing")
        if let wing, wing.isEmpty {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "wing must be non-empty; omit it to use the estate default wing")
        }

        // mode (encode SPEED, default foreground) — SPEED only, mirroring
        // the palace tool's contract: the WRITE strategy is always windowed
        // bulk, never caller-chosen. Fail-closed on an unknown value.
        let modeStr = (try optionalString(args["mode"], argument: "mode")) ?? "foreground"
        let mode: EncodeSpeed
        switch modeStr.lowercased() {
        case "foreground": mode = .foreground
        case "background": mode = .background
        default:
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "mode must be \"foreground\" or \"background\"; omit it to use the default (foreground)"
            )
        }

        // return_id_map: when true the receipt carries a second text block —
        // a JSON object mapping each seed `record.id` to the drawer id capture
        // minted for it. Off by default because the ordinary caller wants the
        // one-line receipt, not N id pairs. A caller that must address what it
        // imported (cross-referencing, per-record reporting, or any harness
        // that scores retrieval against known records) needs this: drawer ids
        // are minted at insert and cannot be derived client-side.
        let returnIDMap = try optionalBool(args["return_id_map"], argument: "return_id_map") ?? false

        let bridge = JsonImportBridge(kit: kit)
        let report: JsonImportReport
        do {
            report = try await bridge.importSeed(
                at: seedURL, into: handle, defaultWing: wing, now: now,
                progress: { processed, total in
                    // Live progress to stderr, fired by the bridge every 10
                    // records — the sole live-progress channel during a
                    // long import.
                    fputs("json import: \(processed)/\(total) drawers\n", stderr)
                },
                mode: mode)
        } catch let VaultKitError.adapterError(message) {
            // Validation / collision failures are tool-level errors: the
            // estate is untouched (zero-partial-write contract) and the
            // message names the first offending element.
            return Self.errorResult(message)
        }

        // Built in parts: as one `+` chain of interpolations this exceeded the
        // type-checker's time budget.
        var receipt = "json import complete: \(report.drawersWritten) drawers, "
        receipt += "\(report.factsWritten) facts, \(report.tunnelsCreated) tunnels "
        receipt += "from seed \"\(report.seedName)\" (strict append — every record is a fresh lineage). "
        receipt += "seedSha256=\(report.seedSha256). "
        receipt += "\(report.enqueuedForEncode) drawers enqueued for semantic encoding; "
        receipt += "keyword and structured recall work almost immediately, and full semantic/vector "
        receipt += "recall lights up after the encode work settles — poll moot_drain_status until idle "
        receipt += "before relying on semantic search over the imported memories."

        guard returnIDMap else { return Self.textResult(receipt) }

        // Second block: `{"id_map":{"<record id>":"<drawer id>",…}}`. Its own
        // block, not appended prose, so a caller parses one whole JSON object
        // instead of scraping the receipt sentence. Keys are sorted so the
        // bytes are identical across runs of the same seed.
        let mapObject = JSONValue.object([
            "id_map": .object(report.drawerIDByRecordID.mapValues { JSONValue.string($0) })
        ])
        let mapJSON: String
        do {
            let data = try JSONSerialization.data(
                withJSONObject: mapObject.foundationObject,
                options: [.sortedKeys, .withoutEscapingSlashes])
            mapJSON = String(decoding: data, as: UTF8.self)
        } catch {
            // Drawer ids are strings by construction, so this cannot fire; if
            // it ever does, fail loudly rather than hand back a receipt whose
            // map is silently missing.
            return Self.errorResult("json import: could not serialize the id map — \(error)")
        }
        return Self.textResultBlocks([receipt, mapJSON])
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
