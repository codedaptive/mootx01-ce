import Foundation
import GeniusLocusKit
import LocusKit
import SubstrateML
import VaultKit
// Scoped imports: pull ONLY the lifecycle-cluster classifier from
// SubstrateTypes. A blanket `import SubstrateTypes` collides with LocusKit
// on `LatticeAnchor.udc` (both modules export `LatticeAnchor`), so we import
// just the two enums the fact-timeline tag needs.
import enum SubstrateTypes.RowState
import enum SubstrateTypes.RowStateCluster

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

    /// ADR-025 sensitivity unlock: daemon-RAM-only grant ledger for the
    /// restricted/secret sensitivity tiers. Actor-isolated (Sendable) — safe
    /// in the immutable Sendable struct. Shared across dispatchers derived
    /// via `registering(_:)` for the same reason `recallLedger` is: exactly
    /// one instance lives for the lifetime of one `mootx01 serve` process,
    /// so "daemon restart = everything locked" (ADR-025 §1) falls out of
    /// `ToolDispatcher` construction rather than needing special-cased
    /// reset logic. See `SensitivityGrantLedger`'s own doc comment.
    let sensitivityUnlockLedger: SensitivityGrantLedger

    /// Injection seam for daemon telemetry monitoring state (ADR-025 wave 8.2).
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

    /// ADR-024 §5: advisory message when the host has detected a version
    /// mismatch between an installed plugin (e.g. Claude Code's
    /// `mootx01@mootx01`) and this running binary — `nil` when no plugin is
    /// detected or its version matches. Computed once by the host at
    /// construction time (see `MootInstallerCore.VersionSkewAdvisory` in the
    /// `mootx01` app layer — kits do not read `~/.claude/plugins/` or know a
    /// product version themselves; the host injects the precomputed string)
    /// and surfaced verbatim in `moot_estate_ping` / `moot_estate_status` so
    /// a stale plugin or stale binary is visible without a separate check.
    public let versionSkewAdvisory: String?

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
                monitoringControl: (any MonitoringControl)? = nil) {
        self.kit = kit
        self.handle = handle
        self.estates = [handle.estateUUID: handle]
        self.jobRegistry = VaultJobRegistry()
        self.recallLedger = SurfacedRecallLedger()
        self.sensitivityUnlockLedger = SensitivityGrantLedger()
        self.buildSerial = buildSerial
        self.serverIdentity = serverIdentity
        self.versionSkewAdvisory = versionSkewAdvisory
        self.monitoringControl = monitoringControl
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
                              versionSkewAdvisory: versionSkewAdvisory)
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
                       versionSkewAdvisory: versionSkewAdvisory)
    }

    /// Private designated initializer carrying an explicit estate map,
    /// a shared job registry, a shared recall ledger, the build serial,
    /// the server identity, and the version-skew advisory. Used by
    /// `registering(_:)`; the public
    /// `init(kit:handle:buildSerial:serverIdentity:versionSkewAdvisory:)` is
    /// the only construction path external callers use.
    private init(
        kit: GeniusLocusKit, handle: EstateHandle,
        estates: [UUID: EstateHandle], jobRegistry: VaultJobRegistry,
        recallLedger: SurfacedRecallLedger,
        sensitivityUnlockLedger: SensitivityGrantLedger,
        monitoringControl: (any MonitoringControl)?,
        buildSerial: String, serverIdentity: String, versionSkewAdvisory: String?
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
    /// Dispatch order: teachme pre-check → federation → recipe → lens → vault → interface → methodNotFound → hint injection.
    public func dispatch(name: String, arguments: JSONValue) async throws -> JSONValue {
        let args = arguments.objectValue ?? [:]
        do {
            // teachme: true — return the usage guide without touching the estate.
            // Intercepted before any runner fires so no side effects occur.
            if try optionalBool(args["teachme"], argument: "teachme") == true {
                return Self.textResult(TeachmeGuides.guide(for: name))
            }
            // Route to the appropriate runner and capture the result so
            // the coaching engine can inspect it before it is returned.
            let runnerResult: JSONValue
            if name == Self.federatedSearchToolName {
                // Federation tool above the interface tier — matched by name.
                runnerResult = try await runFederatedSearch(args)
            } else if RecipeTools.isRecipeTool(name) {
                // CognitionKit behaviour-recipe tools dispatched by name.
                runnerResult = try await RecipeTools.dispatch(
                    name: name, args: args, kit: kit, defaultHandle: handle,
                    resolveHandle: resolveHandle)
            } else if LensTools.isLensTool(name) {
                // Reasoning-lens tools dispatched by name.
                // resolveHandle: restricted to default estate (direct routing gate, Item 3).
                // resolvePeer: unrestricted — lens overlap/divergence need cross-estate access.
                runnerResult = try await LensTools.dispatch(
                    name: name, args: args, kit: kit, defaultHandle: handle,
                    resolveHandle: resolveHandle,
                    resolvePeer: resolveAnyRegistered)
            } else if VaultTools.isVaultTool(name) {
                // VaultKit control-surface tools dispatched by name.
                runnerResult = try await VaultTools.dispatch(
                    name: name, args: args, kit: kit, defaultHandle: handle,
                    resolveHandle: resolveHandle, jobRegistry: jobRegistry)
            } else if InterfaceTools.isInterfaceTool(name) {
                // Five-tier AI-client interface tools dispatched by name.
                runnerResult = try await InterfaceTools.dispatch(
                    name: name, args: args, dispatcher: self)
            } else {
                throw JSONRPCError(
                    code: JSONRPCErrorCode.methodNotFound,
                    message: "Unknown tool: \(name)"
                )
            }
            // Append a coaching hint to non-error results when a trigger fires.
            return applyHint(name: name, args: args, to: runnerResult)
        } catch let error as JSONRPCError {
            throw error
        } catch let error as VerbError {
            // VerbError covers the substrate's own refusals. Emit as a
            // tool-call result with isError set so the client can act on
            // them without losing the call ID.
            return Self.errorResult(describe(error))
        } catch let error as GeniusLocusKitError {
            return Self.errorResult(describe(error))
        } catch {
            // Anything else is genuinely out of band.
            throw JSONRPCError(
                code: JSONRPCErrorCode.toolDispatchFailure,
                message: "\(error)"
            )
        }
    }

    // MARK: - Hint injection

    /// Append a coaching hint to a successful tool result when `CoachingEngine`
    /// detects a suboptimal call pattern. Returns the result unchanged when
    /// `isError == true` or when no trigger fires.
    private func applyHint(name: String, args: [String: JSONValue], to result: JSONValue) -> JSONValue {
        guard let obj = result.objectValue,
              obj["isError"]?.boolValue == false,
              let text = obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue else {
            return result
        }
        guard let hint = CoachingEngine.hint(name: name, args: args, resultText: text) else {
            return result
        }
        return Self.textResult(text + "\nhint: " + hint)
    }

    // MARK: - Federation tool

    /// Tool name for the grant-authorized cross-estate federated search.
    /// Renamed from `crossEstateRecallToolName` (MCP-INT-01) to use the
    /// AI-client-oriented vocabulary.
    public static let federatedSearchToolName = "moot_federated_search"

    /// Run `moot_federated_search`: a grant-authorized federated read that
    /// fans across the locally-open estates the caller is entitled to
    /// read, narrows each contribution to its grant's scope, and returns
    /// the per-estate contributions.
    ///
    /// Authorization is NOT performed here. The per-estate grant gate
    /// lives entirely in GLK's `federatedRecall` — this is the I-13
    /// boundary in practice: ARIA mediates *which* locally-open estates
    /// to attempt; GLK enforces *whether* each read is granted.
    /// A per-estate `.crossEstateReadRefused` is the expected "not granted"
    /// signal and is skipped. If no estate authorizes the caller, the
    /// call is refused cleanly with an `errorResult`.
    private func runFederatedSearch(_ args: [String: JSONValue]) async throws -> JSONValue {
        let requester = try resolveRequester(args)
        let filterChain = try decodeFilterChain(args["filter"])
        // Absent `hydrationLevel` defaults to .full so content blobs are present
        // in the assembled response text — federated search renders drawer content
        // as a preview and the caller cannot evaluate relevance on empty strings.
        // When present, the value is passed through `decodeHydration` which throws
        // `invalidParams` on unknown strings. This is fail-CLOSED: on a federated
        // and privacy-sensitive surface, unknown garbage must never silently grant
        // maximum content exposure. Mirrors the same validation discipline as the
        // Rust `run_federated_search` parser: absent→Full, valid→honored,
        // invalid→error. Both verticals must be identical.
        let hydration: HydrationLevel
        if args["hydrationLevel"] == nil {
            // Absent: default to .full (content preview requires the content blob).
            hydration = .full
        } else {
            // Present: decode strictly — unknown value → invalidParams (fail-closed).
            hydration = try decodeHydration(args["hydrationLevel"])
        }
        let ordering = try decodeOrdering(args["ordering"])
        // Route through clampLimit so negative and over-ceiling values are
        // rejected/clamped at the MCP boundary on the federated surface.
        // Parity: Rust run_federated_search uses clamp_limit with the same ceiling.
        let limit = try Self.clampLimit(
            try optionalInt(args["limit"], argument: "limit"), argument: "limit")
        let frame = RecallFrame(
            filterChain: filterChain,
            hydrationLevel: hydration,
            limit: limit,
            ordering: ordering
        )
        // Visit candidate sources sorted by UUID so the assembled text is
        // deterministic across runs, independent of map iteration order.
        let candidates = estates.values
            .filter { $0.estateUUID != requester.estateUUID }
            .sorted { $0.estateUUID.uuidString < $1.estateUUID.uuidString }
        var sections: [String] = []
        for source in candidates {
            let result: FederatedRecallResult
            do {
                result = try await kit.federatedRecall(frame, from: source, requestedBy: requester)
            } catch let error as GeniusLocusKitError {
                if case .crossEstateReadRefused = error { continue }
                throw error
            }
            let sourceEstate = try await kit.estate(for: source)
            let scoped = try await Self.narrow(
                result.drawers, to: result.grant.scope, estate: sourceEstate)
            sections.append(try await Self.renderContribution(
                source: source, grant: result.grant, drawers: scoped,
                estate: sourceEstate
            ))
        }
        guard !sections.isEmpty else {
            return Self.errorResult(
                "federated_search refused: no open estate holds an active grant naming the requester."
            )
        }
        return Self.textResult(sections.joined(separator: "\n\n"))
    }

    // MARK: - Federation helpers

    /// Resolve the requester estate for a federated search.
    ///
    /// `requesterEstateID` is now OPTIONAL (Item 2 hardening). When omitted the
    /// requester is always the default estate. When supplied it must match the
    /// default estate exactly — supplying a different estate UUID is refused.
    ///
    /// This closes the anti-spoof gap: a caller cannot represent themselves as
    /// a different estate to bypass cross-estate grant scope checks. The
    /// requester identity is always bound to the authenticated caller, which is
    /// the server's own default open estate.
    private func resolveRequester(_ args: [String: JSONValue]) throws -> EstateHandle {
        guard let supplied = args["requesterEstateID"] else {
            // Omitted: bind to the default estate (the authenticated caller).
            return handle
        }
        guard let raw = supplied.stringValue else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "requesterEstateID must be a string when supplied; omit it to use the default caller estate"
            )
        }
        guard let uuid = UUID(uuidString: raw) else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Malformed requesterEstateID (not a UUID): \(raw)"
            )
        }
        guard uuid == handle.estateUUID else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "requesterEstateID does not match the authenticated caller estate; omit requesterEstateID to use the default estate"
            )
        }
        return handle
    }

    /// Narrow a source estate's recalled drawers to the rows inside the
    /// authorizing grant's scope (DECISION §10 answer assembly).
    ///
    /// PRIMARY enforcement is in GLK: `CrossEstateFederation.federatedRecall`
    /// already filtered drawers by `grant.contentLevel` before this is called.
    /// This narrowing is defense-in-depth secondary at the ARIA surface.
    ///
    /// Grants specify human-readable wing/room names, so name-based filtering
    /// requires resolving parentNodeIds to display names via the node tree.
    private static func narrow(
        _ drawers: [Drawer],
        to scope: GrantScope,
        estate: LocusKit.Estate
    ) async throws -> [Drawer] {
        switch scope {
        case .wholeEstate:
            return drawers
        case .wing(let name):
            let nodeNames = try await estate.resolveNodeNames(
                parentNodeIds: drawers.map(\.parentNodeId))
            return drawers.filter { (nodeNames[$0.parentNodeId]?.wing ?? "") == name }
        case .room(let name):
            let nodeNames = try await estate.resolveNodeNames(
                parentNodeIds: drawers.map(\.parentNodeId))
            return drawers.filter { (nodeNames[$0.parentNodeId]?.room ?? "") == name }
        case .latticeSubtree(let code):
            // A drawer is inside the subtree when its UDC code equals `code`
            // or descends from it on a dot boundary. The `+ "."` guard prevents
            // a bare-prefix false match (e.g. "00" vs "001").
            return drawers.filter { $0.udcCode == code || $0.udcCode.hasPrefix(code + ".") }
        case .singleRow(let id):
            return drawers.filter { $0.id == id.uuidString }
        }
    }

    /// Format one estate's authorized contribution for the federated response.
    /// Resolves drawer room names from the node tree for display preview.
    private static func renderContribution(
        source: EstateHandle, grant: Grant, drawers: [Drawer],
        estate: LocusKit.Estate
    ) async throws -> String {
        let nodeNames = try await estate.resolveNodeNames(
            parentNodeIds: drawers.prefix(50).map(\.parentNodeId))
        let header = "estate \(source.estateName) [\(source.estateUUID)] — grant \(grant.id), \(drawers.count) row(s)"
        let lines = drawers.prefix(50).map { drawer in
            let room = nodeNames[drawer.parentNodeId]?.room ?? ""
            return "\(drawer.id)  [\(room)]  \(drawer.content.prefix(80))"
        }
        return ([header] + lines).joined(separator: "\n")
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

    /// Hard ceiling for all caller-supplied `limit`/`count`/`k` arguments at the
    /// MCP tool boundary. Every tool that accepts a numeric quantity must clamp
    /// through `clampLimit` before passing the value into the substrate.
    /// Parity: mirrors `LIMIT_HARD_CEILING` in Rust `dispatch.rs`.
    static let limitHardCeiling = 500

    /// Clamp a caller-supplied `limit`/`count`/`k` to the safe MCP boundary range
    /// `[1, ceiling]`. This is the single clamping funnel for all such arguments
    /// across the ARIA_MCP tool surface (interface tools, recipe tools, lens tools).
    ///
    /// - `nil` (absent arg)  → returns `defaultValue`.
    /// - raw ≤ 0             → throws `invalidParams`; negative/zero values crash
    ///                         downstream range and iterator operations.
    /// - raw > `ceiling`     → silently clamped to `ceiling`; prevents DoS via
    ///                         unbounded substrate scans.
    /// - Otherwise           → returned as-is.
    ///
    /// Parity: mirrors `clamp_limit` in Rust `dispatch.rs`.
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
    /// injected by ADR-025's grant ceiling), or one nested inside
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
                message: "Unsupported mutation kind: \(name). Accepted: confirm, reject, contest, resolve, supersede, revive, accept, correctExportability(private), correctExportability(public)"
            )
        }
    }

    // MARK: - Result helpers

    /// MCP `tools/call` success result with a single text content block.
    public static func textResult(_ text: String) -> JSONValue {
        .object([
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(text),
                ])
            ]),
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
            if let msg = describeGateRejection(verb: verb, reason: reason) {
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
            // the vector embedding in VectorKit or CorpusKit was NOT deleted. Privacy
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
    private func describeGateRejection(verb: String, reason: String) -> String? {
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
/// Each of the 20 Tier 1–5 interface tools plus 1 Maintenance tool (21 total)
/// has a named `run*` function on `ToolDispatcher`; this type routes from name
/// to function, isolating the dispatch logic from the tool-name string
/// constants. Mirrors the Rust `INTERFACE_TOOLS` constant in `interface_tools.rs`.
enum InterfaceTools {

    private static let names: Set<String> = [
        // Tier 1 — Core Memory
        "moot_file_memory", "moot_memory_search", "moot_memory_get",
        "moot_memory_list",
        "moot_update_memory", "moot_withdraw_memory", "moot_erase_memory",
        "moot_confirm_memory", "moot_move_memory",
        // Tier 2 — Connections
        "moot_link_memories", "moot_connection_search", "moot_connection_map",
        // Tier 3 — Knowledge Graph
        "moot_file_fact", "moot_fact_search", "moot_retire_fact",
        "moot_fact_timeline",
        // Tier 4 — Journal
        "moot_write_journal", "moot_read_journal",
        // Tier 5 — Estate
        "moot_estate_status", "moot_estate_map", "moot_estate_ping",
        // Monitoring control (ADR-025 wave 8.2) — read/write daemon telemetry flag
        "moot_monitoring_status",
        // Maintenance / admin
        "moot_reindex", "moot_drain_status",
        // Direct palace import (bypass NoteIR)
        "moot_palace_import",
    ]

    static func isInterfaceTool(_ name: String) -> Bool {
        names.contains(name)
    }

    static func dispatch(
        name: String,
        args: [String: JSONValue],
        dispatcher: ToolDispatcher
    ) async throws -> JSONValue {
        switch name {
        // Tier 1
        case "moot_file_memory":       return try await dispatcher.runFileMemory(args)
        case "moot_memory_search":     return try await dispatcher.runMemorySearch(args)
        case "moot_memory_list":       return try await dispatcher.runMemoryList(args)
        case "moot_memory_get":        return try await dispatcher.runMemoryGet(args)
        case "moot_update_memory":     return try await dispatcher.runUpdateMemory(args)
        case "moot_withdraw_memory":   return try await dispatcher.runWithdrawMemory(args)
        case "moot_erase_memory":      return try await dispatcher.runEraseMemory(args)
        case "moot_confirm_memory":    return try await dispatcher.runConfirmMemory(args)
        case "moot_move_memory":       return try await dispatcher.runMoveMemory(args)
        // Tier 2
        case "moot_link_memories":     return try await dispatcher.runLinkMemories(args)
        case "moot_connection_search": return try await dispatcher.runConnectionSearch(args)
        case "moot_connection_map":    return try await dispatcher.runConnectionMap(args)
        // Tier 3
        case "moot_file_fact":         return try await dispatcher.runFileFact(args, now: Date())
        case "moot_fact_search":       return try await dispatcher.runFactSearch(args)
        case "moot_retire_fact":       return try await dispatcher.runRetireFact(args)
        case "moot_fact_timeline":     return try await dispatcher.runFactTimeline(args)
        // Tier 4
        case "moot_write_journal":     return try await dispatcher.runWriteJournal(args, now: Date())
        case "moot_read_journal":      return try await dispatcher.runReadJournal(args)
        // Tier 5
        case "moot_estate_status":      return try await dispatcher.runEstateStatus(args)
        case "moot_estate_map":         return try await dispatcher.runEstateMap(args)
        case "moot_estate_ping":        return try await dispatcher.runEstatePing(args)
        // Monitoring control (ADR-025 wave 8.2)
        case "moot_monitoring_status":  return try await dispatcher.runMonitoringStatus(args)
        // Maintenance / admin
        case "moot_reindex":           return try await dispatcher.runReindex(args)
        case "moot_drain_status":      return try await dispatcher.runDrainStatus(args)
        // Direct palace import
        case "moot_palace_import":     return try await dispatcher.runPalaceImport(args)
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
    func runFileMemory(_ args: [String: JSONValue]) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let content = try requireString(args, "content")
        let location = try requireString(args, "location")
        let sensitivity = try decodeSensitivity(args["sensitivity"])
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
        // ADR-016 §3: optional `wing` argument routes this memory into a specific wing.
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
            wing: wing
        )
        // Mode-aware capture: regular enqueues the encode job (background
        // semantic indexing); impatient encodes inline before returning.
        let drawer = try await kit.capture(handle, frame, mode: mode)
        // Resolve the drawer's parentNodeId to a display room name via the
        // node tree (Drawer no longer carries stored wing/room after ADR-017).
        let estate = try await kit.estate(for: handle)
        let nodeNames = try await estate.resolveNodeNames(
            parentNodeIds: [drawer.parentNodeId])
        let roomName = nodeNames[drawer.parentNodeId]?.room ?? ""
        return Self.textResult([
            "filed memory \(drawer.id)",
            "room: \(roomName)",
            "lineage: \(drawer.lineageID.uuidString)",
        ].joined(separator: "\n"))
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
    func runMemorySearch(_ args: [String: JSONValue]) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let query = try requireString(args, "query")
        // Clamp to [1, 500]: reject negative/zero limits (crash downstream range ops)
        // and cap absurdly-large values (DoS via unbounded substrate recall scan).
        // Parity: Rust run_memory_search uses clamp_limit with the same ceiling.
        let limit = try Self.clampLimit(
            try optionalInt(args["limit"], argument: "limit"), argument: "limit")
        // Wall-clock time for this request. Hoisted to the top of the
        // function (rather than the later `let now = Date()` this replaces)
        // so the SAME instant gates both the ADR-025 grant check below and
        // the surfaced-recall-ledger recording further down — one request,
        // one `now`.
        let now = Date()
        // Build the base filter chain from the `filter` argument.
        var filterChain = try decodeFilterChain(args["filter"])
        // ADR-025 sensitivity unlock: when a restricted/secret grant is
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
        // ADR-016 §4: optional `wing` argument scopes recall to a single wing.
        // When absent, recall spans all wings (existing default behavior unchanged).
        // Appended to the filter chain so it composes with any explicit filter.
        if let wingName = try optionalString(args["wing"], argument: "wing") {
            filterChain.append(.inWing(wingName))
        }
        let explain = try optionalBool(args["explain"], argument: "explain") ?? false
        // Decode optional `scoring`. Absent keeps the documented default
        // (matrixAware). An unknown NON-EMPTY string is a client error and
        // fails CLOSED with invalidParams — coercing it to matrixAware would
        // silently run a different scoring mode than asked and hide the typo.
        // Mirrors decodeOrdering (strict) and the Rust run_memory_search.
        let scoring: GLKRecallScoring
        if let scoringStr = try optionalString(args["scoring"], argument: "scoring") {
            guard let decoded = GLKRecallScoring(rawValue: scoringStr) else {
                throw JSONRPCError(
                    code: JSONRPCErrorCode.invalidParams,
                    message: "Unknown scoring: \(scoringStr). Valid: raw, rrf, matrixAware"
                )
            }
            scoring = decoded
        } else {
            scoring = .matrixAware
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
            origin: .external  // B-10a: ARIA boundary is external origin
        )
        let result = try await kit.recall(handle, request)
        // Record surfaced drawer ids in the session ledger so dereference verbs
        // can trigger reward-trace marking (DESIGN_TRACE_REWARD_2026-06-12
        // § session-ledger). Reuses the `now` hoisted at the top of this
        // function (one request, one wall-clock instant).
        let surfacedIDs = result.hits.compactMap { $0.drawer?.id }
        if !surfacedIDs.isEmpty {
            await recallLedger.recordSurfaced(surfacedIDs, at: now)
        }
        // ADR-025 §4: record a sensitivityReadUnderGrant audit entry for
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
            for hit in result.hits {
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
        let hitScores = result.hits.map { Double($0.score.final) }
        let discriminationLevel = RecallDiscrimination.classify(hitScores)
        // Dense-lane dark flag: true when the vector lane (Lane D) did not
        // contribute to this ranking. Used to cap the discrimination signal so
        // "high — clear top result" is never reported on a lexical-only ranking
        // (which would violate the signal's trustworthiness contract).
        let denseLaneDark = result.denseLaneStatus != nil

        // ADR-017 §3: Drawer no longer carries stored wing/room. Resolve
        // parentNodeIds to display names via the node tree for result formatting.
        let estate = try await kit.estate(for: handle)
        let hitNodeIds = result.hits.compactMap { $0.drawer?.parentNodeId }
        let hitNodeNames = try await estate.resolveNodeNames(parentNodeIds: hitNodeIds)
        var lines: [String] = ["found \(result.hits.count) memory(s)"]
        for hit in result.hits.prefix(50) {
            let room = hit.drawer.flatMap { hitNodeNames[$0.parentNodeId]?.room } ?? "?"
            // Sensitivity-aware content preview (search-redaction parity fix,
            // Wave 6): LocusKit stores provenance sensitivity in bits 30-35
            // (Drawer.sensitivity, separate from the adjective-axis
            // sensitivity moot_memory_get's containment gate checks). This
            // was previously a Rust-only preview redaction (Rust
            // run_memory_search) — Swift always showed the raw 120-char
            // preview regardless of provenance sensitivity, a pre-existing
            // port divergence. moot_memory_search can surface a Restricted/
            // Secret row for relevance ranking without exposing its body; a
            // raw content preview at the ARIA boundary would leak text the
            // sensitivity designation marks as access-controlled.
            //
            // Normal and Elevated: the bulk-export tiers, safe to preview —
            // proceed to the existing distilled-header / 120-char-preview
            // formatting below, unchanged.
            // Restricted and Secret: replace with a redacted placeholder,
            // even for a `_distilled` row — the security control applies
            // regardless of formatting path.
            let preview: String
            switch hit.drawer?.sensitivity {
            case .restricted:
                preview = "[sensitivity: restricted — retrieve by id for content]"
            case .secret:
                preview = "[sensitivity: secret — content access requires explicit grant]"
            case .normal, .elevated, .none:
                // For _distilled drawers, apply injection-depth formatting so the LLM
                // caller sees factoid prose with calibrated provenance annotations rather
                // than a raw [DIST|…] header string (DISTILLATION_DESIGN.md §2.5).
                if room == "_distilled",
                   let content = hit.drawer?.content,
                   let header = DistilledHeader.parse(content) {
                    preview = Self.injectionDepthFormatted(header: header, drawerID: hit.id)
                } else {
                    preview = hit.drawer.map { String($0.content.prefix(120)) } ?? "(not hydrated)"
                }
            }
            lines.append("\(hit.id)  [\(room)]  \(preview)")
            if explain {
                for line in hit.explanation { lines.append("  \(line)") }
            }
        }
        lines.append(RecallDiscrimination.resultLine(for: discriminationLevel, denseLaneDark: denseLaneDark))
        // Recall provenance: surface the dense-lane status and any degraded stages
        // so callers can distinguish retrieval quality (DECISION_EMBEDDING_INFERENCE_SEAM_2026-06-12).
        //
        // denseLaneStatus non-nil means the dense float vector lane (Lane D) did not
        // contribute hits. Lane D uses the deterministic embedding provider (FNV-1a
        // tokenization + FloatSimHash projection — permanent federation-grade vector,
        // reproducible and model-free). Callers use this to detect when ranking came
        // from structural/BM25 lanes only rather than the vector lane.
        //
        // The learned semantic vector (MiniLM/MPNet/Gemma) is an ADDITIVE v1.1
        // on-device lane — it does not replace the deterministic lane; both coexist.
        //
        // degradedStages lists every pipeline stage that was skipped due to a recoverable
        // error. An empty array means every attempted stage succeeded (happy path).
        //
        // Format: a single "recall_provenance:" status line, always present, never blank.
        // This lets the LLM caller distinguish:
        //   - vector+structural: denseLaneStatus nil, degradedStages empty
        //     (deterministic Lane D + BM25/structural; capture surface, not learned meaning)
        //   - structural-only or BM25-only fallback: denseLaneStatus set (Lane D dark)
        //   - degraded: degradedStages non-empty
        //   - unavailable: denseLaneStatus "dark:…" and degradedStages may overlap
        let provenanceParts: [String]
        if let darkReason = result.denseLaneStatus {
            // Dense vector lane (Lane D) was dark — ranking came from structural/BM25
            // lanes only. Surface the reason so the caller knows vector scoring did not
            // contribute. Honest-labeling requirement per the embedding ADR.
            provenanceParts = ["dense_lane:\(darkReason)"]
        } else {
            // Lane D active: deterministic vector (FNV-1a + FloatSimHash) + structural/BM25 ranking.
            provenanceParts = ["dense_lane:active"]
        }
        let degradedPart: String
        if result.degradedStages.isEmpty {
            degradedPart = "degraded_stages:none"
        } else {
            degradedPart = "degraded_stages:[\(result.degradedStages.joined(separator: ","))]"
        }
        lines.append("recall_provenance: \((provenanceParts + [degradedPart]).joined(separator: " "))")
        // ADR-025 §4: redaction advisory stat (Wave 7.4).
        // When no grant is active, check cheaply whether the estate holds any
        // restricted or secret rows. If so, append an advisory so the AI client
        // knows results may be incomplete and how to request access.
        // Gated on `!sensitivityCeilingLifted` — when a grant IS live, the rows
        // are already included and no advisory is appropriate.
        // The stat uses a private `.internal` limit-1 scan (no trace rows, no
        // BM25/vector cost) — a pure bitmap filter probe. See
        // `estateHasSensitiveRows(handle:)`.
        if !sensitivityCeilingLifted, await estateHasSensitiveRows(handle: handle) {
            lines.append(
                "sensitivity_advisory: results may be hidden by sensitivity tier — " +
                "run `mootx01 unlock private` to include restricted memories, " +
                "`mootx01 unlock secret` for secret memories."
            )
        }
        return Self.textResult(lines.joined(separator: "\n"))
    }

    /// `moot_memory_get` — fetch one memory drawer by id, in full.
    ///
    /// ADR reference: docs_internal/V1_1_PARKING_LOT.md's "MCP API gap:
    /// fetch-drawer-by-ID" (build-now per Bob's ruling, not deferred to v1.1).
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
    /// trust, or restricted/secret sensitivity) is reported exactly like a
    /// genuinely absent id: "Memory not found: <id>". This is deliberate —
    /// the by-id door must not become a way to confirm the EXISTENCE of
    /// content the estate would otherwise refuse to surface. Tombstoned rows
    /// are always excluded, independent of the chain.
    ///
    /// Hydration is `.full` (verbatim content, matching what was captured) —
    /// never `.structured`, which strips the content blob this tool exists
    /// to return.
    func runMemoryGet(_ args: [String: JSONValue]) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let rowID = try requireString(args, "id")
        let estate = try await kit.estate(for: handle)

        // ADR-025 sensitivity unlock: same grant-ceiling injection as
        // runMemorySearch — see that function's doc comment. moot_memory_get
        // deliberately uses the SAME containment gate moot_memory_search
        // does (its own doc history says so explicitly), so the grant must
        // lift it here too, or an unlocked restricted/secret row would be
        // visible in search but still "not found" by id — an inconsistent,
        // confusing half-unlock.
        var filterChain: [Filter] = []
        let now = Date()
        var sensitivityCeilingLifted = false
        if let ceiling = await sensitivityUnlockLedger.ceilingFilter(now: now) {
            filterChain.append(ceiling)
            sensitivityCeilingLifted = true
        }
        let frame = RecallFrame(filterChain: filterChain, hydrationLevel: .full)
        let filtered = try await estate.getDrawers(
            ids: [rowID], matchingFrame: frame, hydrationLevel: .full)
        guard let drawer = filtered.admissible.first else {
            // Same message and error code whether the id is genuinely absent,
            // tombstoned, or exists but failed the gate — see the containment
            // note above. Mirrors moot_link_memories' "Memory not found" shape.
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Memory not found: \(rowID)"
            )
        }
        // ADR-025 §4: same read-under-grant audit recording as
        // runMemorySearch — see that function's comment for why this is
        // gated on BOTH the ceiling having been lifted AND the drawer's
        // own sensitivity actually being restricted/secret.
        if sensitivityCeilingLifted {
            switch drawer.adjectiveSensitivity {
            case .restricted, .secret:
                try? await kit.recordSensitivityReadUnderGrant(
                    handle, tier: drawer.adjectiveSensitivity, drawerID: drawer.id, now: now)
            case .normal, .elevated:
                break
            }
        }

        // ADR-017 §3: Drawer no longer carries stored wing/room; resolve via
        // the node tree, same pattern as every other read tool in this file.
        let nodeNames = try await estate.resolveNodeNames(parentNodeIds: [drawer.parentNodeId])
        let names = nodeNames[drawer.parentNodeId] ?? (wing: "", room: "")

        // Linked tunnel summary: same estate.allTunnels() + tombstone-exclusion
        // pattern moot_connection_search/moot_connection_map already use,
        // scoped to tunnels touching this drawer on either end.
        let allTunnels = try await estate.allTunnels()
        let linked = allTunnels.filter {
            ($0.sourceDrawerId == rowID || $0.targetDrawerId == rowID) && $0.tombstonedAt == nil
        }

        let iso = ISO8601DateFormatter()
        var lines: [String] = [
            "memory \(drawer.id)",
            "room: \(names.room)  wing: \(names.wing)",
            "filed_at: \(iso.string(from: drawer.filedAt))",
            "event_time: \(iso.string(from: drawer.eventTime))",
            "state: \(String(describing: drawer.state))",
            "trust: \(String(describing: drawer.trust))",
            "sensitivity: \(String(describing: drawer.adjectiveSensitivity))",
            "exportability: \(String(describing: drawer.exportability))",
            "confirmation: \(String(describing: drawer.confirmation))",
            "lineage: \(drawer.lineageID.uuidString)",
            "tunnels: \(linked.count)",
        ]
        for tunnel in linked.prefix(50) {
            let outgoing = tunnel.sourceDrawerId == rowID
            let other = outgoing
                ? (tunnel.targetDrawerId ?? "\(tunnel.targetWing)/\(tunnel.targetRoom)")
                : (tunnel.sourceDrawerId ?? "\(tunnel.sourceWing)/\(tunnel.sourceRoom)")
            lines.append("  \(outgoing ? "→" : "←") \(other)  [\(tunnel.label)]")
        }
        // Verbatim content, on its own trailing block — never truncated or
        // previewed (that is moot_memory_search's job). This is the field the
        // tool exists to return.
        lines.append("content:")
        lines.append(drawer.content)
        // ADR-025 §4: redaction advisory stat (Wave 7.4) — same logic as
        // runMemorySearch. When no grant is active, surface an advisory if the
        // estate contains any restricted/secret rows not visible through the
        // default gate. Consistent with search so the AI client receives the
        // same hint from both tools.
        if !sensitivityCeilingLifted, await estateHasSensitiveRows(handle: handle) {
            lines.append(
                "sensitivity_advisory: some memories may be hidden by sensitivity tier — " +
                "run `mootx01 unlock private` to include restricted memories, " +
                "`mootx01 unlock secret` for secret memories."
            )
        }
        return Self.textResult(lines.joined(separator: "\n"))
    }

    /// Returns `true` if the estate has at least one row tagged restricted or secret.
    ///
    /// Used by `runMemorySearch` and `runMemoryGet` to decide whether to append a
    /// sensitivity advisory. The advisory tells the AI client that results may be
    /// incomplete and how to unlock the hidden tier (ADR-025 §4, Wave 7.4).
    ///
    /// Implementation: two limit-1 `GLKRecallRequest` scans with explicit
    /// `Filter.sensitivity(tier)` — these filters suppress the default
    /// `sensitivityAtMost(.elevated)` gate (see `BitmapEvaluator.insertDefaults`),
    /// so restricted/secret rows become visible for counting. Mode `.locusOnly` +
    /// scoring `.raw` skips the BM25/vector pipeline; the scan is a pure bitmap
    /// filter probe — cheap even for large estates.
    ///
    /// `origin: .internal` — must NOT write recall-trace rows (B-10a: only the
    /// ARIA_MCP boundary sets `.external`). This is an internal diagnostic query.
    private func estateHasSensitiveRows(handle: EstateHandle) async -> Bool {
        for tier: AdjectiveSensitivity in [.restricted, .secret] {
            // Limit 1: stop at first match — no need to count.
            let frame = RecallFrame(
                filterChain: [.sensitivity(tier)],
                hydrationLevel: .structured, // No content body needed — existence check only.
                limit: 1,
                ordering: .byCaptureTimeDesc
            )
            let request = GLKRecallRequest(
                frame: frame,
                mode: .locusOnly,     // Skip BM25/vector — pure bitmap probe.
                scoring: .raw,        // No matrix scoring needed.
                limit: 1,
                fallback: .allowDegraded,
                queryText: nil,       // No text query — filter only.
                origin: .internal     // Internal diagnostic — must not write trace rows (B-10a).
            )
            // A nil result (thrown error) is treated as no sensitive rows — fail-safe:
            // don't surface the advisory when we can't confirm sensitive rows exist.
            if let result = try? await kit.recall(handle, request), !result.hits.isEmpty {
                return true
            }
        }
        return false
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
        guard let entry = await recallLedger.entry(for: rowID) else { return }
        // Use the surfaced-at time as `now` so the retention window is
        // anchored to when the memory was shown, not when it was acted on.
        // This matches the Rust note_usage which passes surfaced_at+1s.
        // We use Date() here (current wall time) because the retention window
        // is 30 days and a same-session dereference is always within that window.
        do {
            _ = try await kit.markRecallUsed(handle, target: rowID, now: entry.surfacedAt)
        } catch {
            // Best-effort: reward marking must not break the primary verb.
        }
    }

    /// `moot_update_memory` — apply a named mutation to a memory.
    func runUpdateMemory(_ args: [String: JSONValue]) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let rowID = try requireString(args, "id")
        let mutationName = try requireString(args, "mutation")
        let kind = try decodeMutationKind(mutationName)
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
        try await kit.expunge(handle, ExpungeFrame(rowID: rowID, reason: reason, confirmation: confirmed))
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
        // ADR-016 §3: optional `wing` moves the drawer into a different wing.
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
        // ADR-017 §3: Drawer no longer carries stored wing/room. Resolve
        // parentNodeIds via the node tree for TunnelCaptureFrame display names.
        let linkNodeNames = try await estate.resolveNodeNames(
            parentNodeIds: [source.parentNodeId, target.parentNodeId])
        let sourceNames = linkNodeNames[source.parentNodeId] ?? (wing: "", room: "")
        let targetNames = linkNodeNames[target.parentNodeId] ?? (wing: "", room: "")
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
            originClass: .derived
        )
        let tunnel = try await estate.capture(frame)
        return Self.textResult("linked \(fromID) → \(toID) via \(label) (\(tunnel.id))")
    }

    /// `moot_connection_search` — find connections going out from a memory.
    ///
    /// Reads all tunnels from the estate and filters by `sourceDrawerId`.
    func runConnectionSearch(_ args: [String: JSONValue]) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let fromID = try requireString(args, "from_id")
        let estate = try await kit.estate(for: handle)
        let allTunnels = try await estate.allTunnels()
        // Keep only non-tombstoned, exportable tunnels originating from this
        // drawer. Sensitivity ceiling (#58): restricted/secret tunnels are
        // excluded at the MCP boundary, matching the default recall ceiling.
        let outgoing = allTunnels.filter {
            $0.sourceDrawerId == fromID && $0.tombstonedAt == nil
                && $0.adjectiveSensitivity.isBulkExportable
        }
        let lines = outgoing.prefix(50).map { t -> String in
            "\(t.id)  → \(t.targetDrawerId ?? "\(t.targetWing)/\(t.targetRoom)")  [\(t.label)]"
        }
        let header = "connections from \(fromID): \(outgoing.count)"
        return Self.textResult(([header] + lines).joined(separator: "\n"))
    }

    /// `moot_connection_map` — find connections pointing to a memory.
    ///
    /// Reads all tunnels from the estate and filters by `targetDrawerId`.
    func runConnectionMap(_ args: [String: JSONValue]) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let toID = try requireString(args, "to_id")
        let estate = try await kit.estate(for: handle)
        let allTunnels = try await estate.allTunnels()
        // Keep only non-tombstoned, exportable tunnels pointing to this
        // drawer. Sensitivity ceiling (#58): same gate as connection_search.
        let incoming = allTunnels.filter {
            $0.targetDrawerId == toID && $0.tombstonedAt == nil
                && $0.adjectiveSensitivity.isBulkExportable
        }
        let lines = incoming.prefix(50).map { t -> String in
            "\(t.id)  \(t.sourceDrawerId ?? "\(t.sourceWing)/\(t.sourceRoom)") →  [\(t.label)]"
        }
        let header = "connections to \(toID): \(incoming.count)"
        return Self.textResult(([header] + lines).joined(separator: "\n"))
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
        let predicate = try requireString(args, "predicate")
        let object = try requireString(args, "object")
        // source_id grounds the fact (provenance — KGFact: every fact traces back to
        // a source). When the caller omits it, infer the source as the ingest
        // channel that asserted it, so a fact is never stored unanchored.
        let providedSource = try optionalString(args["source_id"], argument: "source_id") ?? ""
        let sourceDrawerID = providedSource.isEmpty ? serverIdentity : providedSource
        let fact = try await kit.captureKGFact(
            handle,
            subject: subject,
            predicate: predicate,
            object: object,
            sourceDrawerID: sourceDrawerID,
            now: now
        )
        return Self.textResult("filed fact \(fact.id): [\(subject)] \(predicate) [\(object)]")
    }

    /// `moot_fact_search` — retrieve all currently-active KG facts.
    ///
    /// Fact storage is independent of the memory recall pipeline — facts are
    /// filed as LocusKit KGFact rows, not as Drawer rows, so the dense vector
    /// lane (Lane D) does not participate in fact retrieval. When the caller
    /// supplies a query, matching is a case-insensitive substring scan across
    /// subject, predicate, and object.
    ///
    /// When a query is present and the dense lane is dark, a `recall_provenance:`
    /// hint is appended so the AI caller can distinguish "no lexical match" from
    /// "semantic search was not consulted". This mirrors the honest-lane-state
    /// reporting that `moot_memory_search` and `moot_recall_shaped` emit, keeping
    /// the ARIA surface consistent (DECISION_EMBEDDING_INFERENCE_SEAM_2026-06-12).
    func runFactSearch(_ args: [String: JSONValue]) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let allFactsRaw = try await kit.recallKGFacts(handle)
        // MCP disclosure ceiling: drop Restricted/Secret facts before any output.
        // Parity with the default BitmapEvaluator ceiling (SensitivityAtMost(Elevated))
        // that normal recall applies via insertDefaults. Filter at the ARIA tool boundary
        // only — recallKGFacts has internal callers that need the full set.
        let allFacts = allFactsRaw.filter { $0.adjectiveSensitivity.isBulkExportable }
        // Optional query: substring match across subject, predicate, and object.
        // Omitting query returns all active facts (the unfiltered case).
        let queryRaw = try optionalString(args["query"], argument: "query")
        let query = queryRaw?.lowercased()
        let facts = query.map { q in
            allFacts.filter {
                $0.subject.lowercased().contains(q) ||
                $0.predicate.lowercased().contains(q) ||
                $0.object.lowercased().contains(q)
            }
        } ?? allFacts
        // Gate source-drawer IDs: for each distinct sourceDrawerID in the facts we are
        // about to emit, check whether it references an actual drawer row in the estate.
        // If it does AND is Restricted/Secret (outside the default sensitivity ceiling),
        // hide the ID at the MCP boundary. Non-drawer provenance strings (server identity
        // tags like "mootx01") are not found in the estate and pass through unchanged.
        // We use getDrawers(ids:matchingFrame:hydrationLevel:) which returns both the
        // admissible set and the full loadedIDs set — the difference is the blocked set.
        // Parity with Rust run_fact_search.
        let emittedFacts = Array(facts.prefix(100))
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
            // loaded but not admissible = exists as a drawer AND is Restricted/Secret
            let admissibleIDs = Set(result.admissible.map { $0.id })
            hiddenSourceIDs = result.loadedIDs.subtracting(admissibleIDs)
        }
        // Include evaluation fields (filedAt, sourceDrawerID) so callers can
        // reason about provenance and temporal ordering without a separate
        // timeline call. ISO8601 for filedAt; sourceDrawerID gated on admissibility.
        let formatter = ISO8601DateFormatter()
        let lines = emittedFacts.map { f -> String in
            let filed = formatter.string(from: f.filedAt)
            // Gate source= on source-drawer sensitivity: hide only when the drawer
            // exists AND is Restricted/Secret. Non-drawer provenance strings pass through.
            let sourceField = hiddenSourceIDs.contains(f.sourceDrawerID)
                ? "source=<hidden>"
                : "source=\(f.sourceDrawerID)"
            return "\(f.id)  [\(f.subject)] \(f.predicate) [\(f.object)]  filed=\(filed)  \(sourceField)"
        }
        let header = query != nil
            ? "facts matching \"\(queryRaw ?? "")\": \(facts.count)"
            : "facts: \(facts.count)"
        var outputLines = [header] + lines
        // Dark-lane hint: when the caller supplied a query, probe the dense
        // recall lane to determine its status. If dark, append a recall_provenance
        // line so the AI caller knows the match was lexical-only (0 results means
        // "no lexical match found", not "this fact does not exist in semantic
        // space"). Reuses the same probe recall path as moot_memory_search to
        // ensure wording/shape is consistent. The probe is minimal (limit=1, no
        // filter, .unionBest mode) — we only need the denseLaneStatus, not hits.
        if query != nil {
            // Probe the dense lane state with a minimal recall request (limit=1,
            // no filter, bitmapOnly hydration — no blob reads needed). We only
            // use denseLaneStatus from the result, not the hits themselves.
            // queryText is the raw (non-lowercased) form so the embedding path
            // sees unaltered text.
            // origin: .internal — this probe reads ONLY denseLaneStatus; it must
            // NOT participate in the reward cycle. An external origin makes
            // RecallDirector set traceLimit, so LocusKit would persist recall-trace
            // rows for the probe's incidental locus hits — durable reward/audit
            // pollution from an ostensibly read-only fact search (the Rust
            // run_fact_search avoids this entirely by checking has_corpus instead
            // of issuing a recall). Internal origin leaves traceLimit nil → zero
            // trace writes, while denseLaneStatus is still populated.
            let probeRequest = GLKRecallRequest(
                frame: RecallFrame(filterChain: [], hydrationLevel: .bitmapOnly,
                                   limit: 1, ordering: .byCaptureTimeDesc),
                mode: .unionBest,
                scoring: .matrixAware,
                limit: 1,
                fallback: .allowDegraded,
                queryText: queryRaw,  // pass original (not lowercased) for embedding
                origin: .internal
            )
            let probeResult = try await kit.recall(handle, probeRequest)
            if let darkReason = probeResult.denseLaneStatus {
                // Dense lane was dark — the query above was lexical-only.
                // Surface the same recall_provenance format as moot_memory_search
                // so AI callers receive a consistent signal across all search tools.
                outputLines.append("recall_provenance: dense_lane:\(darkReason) degraded_stages:none")
            }
        }
        return Self.textResult(outputLines.joined(separator: "\n"))
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
        // Non-drawer provenance strings (server identity tags) are not in the estate and
        // pass through unchanged. loadedIDs − admissible = the blocked (restricted/secret)
        // drawer-reference set. Parity with Rust run_fact_timeline.
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
        let formatter = ISO8601DateFormatter()
        // Include sourceDrawerID for provenance tracing, gated on source-drawer
        // sensitivity. filedAt present for chronological ordering.
        let lines = emittedFacts.map { f -> String in
            let filed = formatter.string(from: f.filedAt)
            let lifecycleTag = Self.lifecycleTag(forAdjectiveBitmap: f.adjectiveBitmap)
            // Gate source= on source-drawer sensitivity: hide only when the drawer
            // exists AND is Restricted/Secret. Non-drawer provenance strings pass through.
            let sourceField = hiddenSourceIDs.contains(f.sourceDrawerID)
                ? "source=<hidden>"
                : "source=\(f.sourceDrawerID)"
            return "\(filed)  \(lifecycleTag)  \(f.id)  [\(f.subject)] \(f.predicate) [\(f.object)]  \(sourceField)"
        }
        let count = facts.count
        let header: String
        if let entity = entity, !entity.isEmpty {
            header = "fact timeline for \"\(entity)\": \(count)"
        } else {
            header = "fact timeline: \(count)"
        }
        return Self.textResult(([header] + lines).joined(separator: "\n"))
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
        // Sensitivity ceiling (#50): exclude restricted/secret drawers from
        // the wing listing and counts, matching the estate-map ceiling. Wing
        // names derived from restricted/secret drawers can leak topic metadata.
        let visible = active.filter { $0.adjectiveSensitivity.isBulkExportable }
        // "total" counts all non-erased rows (tombstone = erased permanently).
        let total = drawers.filter { $0.tombstonedAt == nil }
        // Resolve parentNodeIds to display names for wing listing. Drawer
        // no longer carries stored wing/room after ADR-017 node-tree migration.
        let activeNodeNames = try await estate.resolveNodeNames(
            parentNodeIds: visible.map(\.parentNodeId))
        let wings = Set(visible.compactMap { activeNodeNames[$0.parentNodeId]?.wing }).sorted()
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
        var stats = [
            "estate: \(handle.estateName) [\(handle.estateUUID)]",
            "memories: \(active.count) active (\(total.count) total)",
            "wings: \(wings.joined(separator: ", "))",
            "kg facts: \(facts.count) active",
            "trace_rows: \(traceRows)",
            "sync: \(syncToken)",
        ]
        // ADR-024 §5: surface a plugin/binary version-skew advisory when the
        // host detected one. Appended only when present so the common
        // no-skew case leaves the response shape unchanged.
        if let versionSkewAdvisory {
            stats.append("version_skew: \(versionSkewAdvisory)")
        }
        return Self.textResult(stats.joined(separator: "\n") + Self.ARIASessionProtocol)
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
    /// supplied — classified in PermissionsWriter.mutationTools, ADR-025 wave 8.2).
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
    /// Drawer no longer carries stored wing/room (ADR-017 node-tree migration).
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

        var matches: [(id: String, room: String, preview: String)] = []
        for d in visible {
            let names = nodeNames[d.parentNodeId]
            let dWing = names?.wing ?? ""
            let dRoom = names?.room ?? ""
            guard dWing == wing else { continue }
            if let room, !room.isEmpty, dRoom != room { continue }
            let preview = String(d.content.prefix(80))
                .replacingOccurrences(of: "\n", with: " ")
            matches.append((id: d.id, room: dRoom, preview: preview))
        }

        let capped = matches.prefix(200)
        var lines: [String] = ["memory_list: \(capped.count) drawer(s) in \(wing)\(room.map { "/\($0)" } ?? "")"]
        if matches.count > 200 {
            lines.append("(showing first 200 of \(matches.count))")
        }
        for m in capped {
            lines.append("  \(m.id) [\(m.room)] \(m.preview)")
        }
        return Self.textResult(lines.joined(separator: "\n"))
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
            // ADR-024 §5: append the version-skew advisory when present —
            // same opt-in shape as moot_estate_status.
            var pong = "pong: estate \(handle.estateName) [\(handle.estateUUID)] is live — build \(buildSerial)"
            if let versionSkewAdvisory {
                pong += "\nversion_skew: \(versionSkewAdvisory)"
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

    func runReindex(_ args: [String: JSONValue]) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let now = Date()
        guard await Self.reindexGuard.tryStart() else {
            return Self.textResult("reindex already running — poll moot_drain_status to watch progress")
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
        return Self.textResult(
            "reindex started: backfilling every unindexed drawer to full coverage in the background — poll moot_drain_status to watch the encode queue converge")
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
    func runPalaceImport(_ args: [String: JSONValue]) async throws -> JSONValue {
        guard ToolProjection.vaultEnabled else {
            return Self.errorResult(
                "vault is disabled; reinstall with mootx01 install --vault-on to enable import/export"
            )
        }
        let handle = try resolveHandle(args)
        let palacePath = try requireString(args, "palace_path")
        let palaceURL = URL(fileURLWithPath: palacePath, isDirectory: true)
        let now = Date()

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
}

// MARK: - Server defaults (private)

private extension ToolDispatcher {
    /// Default capture channel for server-filed memories: `actuator` (raw 5,
    /// cookbook §2.4) signals that content is submitted by an MCP AI agent
    /// (actuator-driven capture), not a file import and not typed by a user.
    static let defaultChannel: CaptureChannel = .actuator

    // NOTE: `serverAddedBy` was removed. The host identity now lives in the
    // `serverIdentity` instance property, injected at construction so the
    // shared dispatcher correctly stamps provenance for whichever binary
    // is hosting it (aria-mcp-server, mootx01 serve, etc.).
}

// MARK: - Injection depth formatting

extension ToolDispatcher {
    /// Format a parsed `_distilled` drawer hit for injection into the LLM context.
    ///
    /// Three cases per DISTILLATION_DESIGN.md §2.5 and the InjectionDepth thresholds:
    ///   conf >= 0.7  (factoidOnly):           prose only — confidence is high; no annotation needed.
    ///   conf ∈ [0.4, 0.7) (factoidWithMeta):  prose + source memory count and confidence.
    ///   conf < 0.4  (factoidWithProvenance):  prose + confidence and source drawer ID for full audit trail.
    /// Preview cap for distilled prose injected into the LLM context.
    ///
    /// Distilled factoids are compressed by definition, but `m.prose` can still
    /// be arbitrarily long. Cap at 300 chars to prevent a single high-confidence
    /// factoid from overwhelming the context window. 300 chars is generous for
    /// compressed factoid prose; normal drawers use 120 chars.
    /// Parity: mirrors `DISTILLED_PROSE_PREVIEW_CAP` in Rust `recipe_tools.rs`.
    static let distilledProseCap = 300

    static func injectionDepthFormatted(header: DistilledHeader, drawerID: RowID) -> String {
        let confStr = String(format: "%.2f", header.confidence)
        // Preview cap: applied before injection to bound context-window consumption.
        let prose = String(header.prose.prefix(Self.distilledProseCap))
        if header.confidence >= 0.7 {
            // factoidOnly: prose only; confidence is high enough to trust without annotation
            return prose
        } else if header.confidence >= 0.4 {
            // factoidWithMeta: append memory count and confidence so the caller can weigh certainty
            return "\(prose)\n[distilled from \(header.sourceCount) memories, conf=\(confStr)]"
        } else {
            // factoidWithProvenance: append confidence and source drawer ID for full traceability
            return "\(prose)\n[distilled, conf=\(confStr), sources: \(drawerID)]"
        }
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
    func tryStart() -> Bool {
        if running { return false }
        running = true
        return true
    }
    func finish() { running = false }
}
