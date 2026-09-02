// GoldMiner.swift
//
// The resident gold-miner seam (ADORNMENTLIB_SPEC 0.5.0 § Gold miner).
//
// Requirements (operator ruling 2026-08-26 — verbatim constraints):
//   - EVERY record in the database must be adorned; coverage is a MUST.
//   - Sustained single-record ingest (hundreds/hour) and bulk import both
//     feed the miner; it is NOT a lightly used tool.
//   - The miner is RESIDENT — never load-on-demand — and must not consume
//     gigabytes.
//   - It serves one-off mining (impatient writes) and batch mining
//     (dreaming passes; imports may defer to dreaming).
//   - Swift uses the Apple model ONLY on iOS and by DEFAULT on macOS.
//
// Architecture: the ENGINE is a plug. `GoldMinerEngine` is the only thing
// a model implementation touches; everything above it (resident owner,
// one-off/batch entry points, the adornment pass, map-reduce, truncation)
// is engine-agnostic. Swapping models means implementing one protocol,
// never rewriting the miner.

import Foundation
import OSLog

#if canImport(FoundationModels)
import FoundationModels
#endif

private let log = Logger(subsystem: "com.mootx01.kit", category: "AdornmentLib")

// MARK: - Engine plug

/// One pluggable minting engine: prompt in, claim out.
///
/// Engines own their model residency and synchronization. `mint` returns
/// nil for a per-prompt failure (the pair stays in debt and is retried);
/// it must never throw the whole miner down for one bad prompt.
public protocol GoldMinerEngine: Sendable {
    /// Stable identity for logs, run provenance, and the minter master.
    /// Product engines use their recipe's composed ID (e.g.
    /// "apple-fm-p1-s1", "qwen2-0.5b-q4km-p2-s1"); a generic harness
    /// command engine uses its command name. Never a user-facing name.
    var identity: String { get }
    /// Mint one claim. Nil = per-prompt failure; the caller records a
    /// failed pair and continues.
    func mint(prompt: String) async -> String?
    /// How many `mint` calls this engine serves CONCURRENTLY without
    /// degrading — the fan-out width mint drivers (AdornmentPass) bound
    /// their task groups to. 1 = the engine is serial (a single resident
    /// model context or a single subprocess pipe); >1 requires `mint` to
    /// be safe and productive under that many in-flight calls. The Apple
    /// engine is request-per-call against the OS inference service, which
    /// pipelines concurrent client requests (fleet builds sustained ~60
    /// concurrent minting processes); resident GGUF contexts and command
    /// pipes are 1.
    var maxConcurrentMints: Int { get }
    /// Row-batch transport (operator design 2026-08-30): an engine that can
    /// hold a task-instructed session and answer batches of records as
    /// row data declares true and implements `mintRows`. Transport only —
    /// the minter identity and prompt digest are unchanged. A protocol
    /// REQUIREMENT, never extension-only: `GoldMiner` reads it through
    /// `any GoldMinerEngine`, where an extension-only member statically
    /// dispatches to the default and every concrete override is
    /// unreachable (2026-08-30: rows mode silently fell to singles on
    /// every drain because of exactly that).
    var supportsRowBatching: Bool { get }
    /// Mint one batch of row payloads (see `buildAdornmentRow`). Position
    /// k carries row k's claim, nil for a per-row failure. A protocol
    /// requirement for the same existential-dispatch reason as
    /// `supportsRowBatching`.
    func mintRows(_ rows: [String], maxLength: Int) async -> [String?]
}

public extension GoldMinerEngine {
    /// Serial by default: an engine that does not declare a width is a
    /// single-context engine.
    var maxConcurrentMints: Int { 1 }

    /// Engines that do not speak the row-batch transport inherit these
    /// defaults; the nil-array reply is unreachable behind
    /// `supportsRowBatching == false`.
    var supportsRowBatching: Bool { false }

    func mintRows(_ rows: [String], maxLength: Int) async -> [String?] {
        Array(repeating: nil, count: rows.count)
    }
}

// MARK: - Resident owner

/// The process-wide resident miner. ONE instance per process; the engine
/// loads when installed and is NEVER unloaded (the resident rule). All
/// mint paths — impatient single writes, dreaming batches, import drains —
/// go through this owner so there is exactly one model residency.
public actor GoldMiner {
    public static let shared = GoldMiner()

    private var engine: (any GoldMinerEngine)?

    #if MOOTX01_MULTI_MODEL
    /// Per-minter engine registry (multi-model mode, operator ruling
    /// 2026-08-31). DEVELOPER-ONLY, compile-time gated: build with
    /// `-Xswiftc -DMOOTX01_MULTI_MODEL` to enable. The shipped product
    /// runs ONE resident engine (the resident rule bounds memory on user
    /// machines); multi-arm minting is a bench/dev capability. A pair
    /// whose minter id is registered here mints through its own engine;
    /// unregistered minters fall through to the default engine. Engines
    /// on different silicon (FM service / in-process Metal) naturally
    /// overlap under the pass's width fan-out — multi-arm concurrency
    /// needs no orchestration beyond this routing table.
    private var minterEngines: [String: any GoldMinerEngine] = [:]
    #endif

    /// Install the process's DEFAULT engine. The composition layer calls
    /// this once at startup (or on minter-family activation). Installing
    /// a different engine replaces the old one; the old engine's
    /// residency is released by its own deinit.
    public func install(engine: any GoldMinerEngine) {
        log.info("GoldMiner: engine installed — \(engine.identity)")
        self.engine = engine
    }

    #if MOOTX01_MULTI_MODEL
    /// Whether MOOT_MINT_ARMS has been parsed for this process (one-shot;
    /// explicit installs are never overwritten by the env pass).
    private var armsLoaded = false

    /// Load per-minter arm engines from MOOT_MINT_ARMS, once per process.
    ///
    /// Format: `minterID=<engine>[;minterID=<engine>...]` where <engine>
    /// is either a minter-command path (CommandEngine — prompt on stdin,
    /// claim on stdout) or `coreai:<asset.aimodel>:<tokenizer.json>`
    /// (CoreAIEngine — in-process greedy decode, macOS 27+). Explicitly
    /// installed engines win over env entries. Developer-only wiring:
    /// the variable is only read in MOOTX01_MULTI_MODEL builds, and a
    /// shipped product build has no code that looks at it.
    private func loadArmsIfNeeded() async {
        guard !armsLoaded else { return }
        armsLoaded = true
        guard let spec = ProcessInfo.processInfo.environment["MOOT_MINT_ARMS"],
              !spec.isEmpty else { return }
        for entry in spec.split(separator: ";") {
            let parts = entry.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else {
                log.error("GoldMiner: malformed MOOT_MINT_ARMS entry '\(entry)' — skipped")
                continue
            }
            let minterID = String(parts[0])
            let value = String(parts[1])
            guard minterEngines[minterID] == nil else { continue }
            if value.hasPrefix("coreai:") {
                #if canImport(CoreAI)
                guard #available(macOS 27.0, *) else {
                    log.error("GoldMiner: coreai arm \(minterID) needs macOS 27 — skipped")
                    continue
                }
                // coreai:<style>:<asset.aimodel>:<tokenizer.json>
                let paths = value.dropFirst("coreai:".count).split(separator: ":")
                guard paths.count == 3,
                      let style = CoreAIPromptStyle(rawValue: String(paths[0]))
                else {
                    log.error("GoldMiner: coreai arm \(minterID) wants <chat|plain|nuextract>:<asset>:<tokenizer> — skipped")
                    continue
                }
                do {
                    let engine = try await CoreAIEngine(
                        assetPath: String(paths[1]),
                        tokenizerPath: String(paths[2]),
                        identity: minterID,
                        style: style)
                    minterEngines[minterID] = engine
                    log.info("GoldMiner: coreai arm loaded for \(minterID)")
                } catch {
                    log.error("GoldMiner: coreai arm \(minterID) failed to load — \(error)")
                }
                #else
                log.error("GoldMiner: coreai arm \(minterID) — CoreAI unavailable in this build")
                #endif
            } else {
                let engine = CommandEngine(command: value)
                minterEngines[minterID] = engine
                log.info("GoldMiner: arm engine loaded for \(minterID) — \(engine.identity)")
            }
        }
    }

    /// Install an engine for ONE minter id (multi-model mode). Replaces
    /// any prior engine for that minter; the default engine is untouched.
    public func install(engine: any GoldMinerEngine, for minterID: String) {
        log.info("GoldMiner: engine installed for \(minterID) — \(engine.identity)")
        minterEngines[minterID] = engine
    }

    /// Remove one minter's engine registration (its residency is
    /// released by the engine's own deinit). The default engine is
    /// never removed this way.
    public func uninstallEngine(for minterID: String) {
        minterEngines[minterID] = nil
    }
    #endif

    /// Resolve the engine for a minter id: the multi-model registry
    /// first (when compiled in), then the default resolution chain. In
    /// the shipped product build this is exactly the default chain — the
    /// minter id changes nothing.
    private func engine(for minterID: String?) async -> (any GoldMinerEngine)? {
        #if MOOTX01_MULTI_MODEL
        await loadArmsIfNeeded()
        if let minterID, let dedicated = minterEngines[minterID] { return dedicated }
        #else
        _ = minterID
        #endif
        return effectiveEngine()
    }

    /// The active engine's identity, or nil when no engine is installed.
    public var engineIdentity: String? { engine?.identity }

    /// The minter identity carried by the engine that would serve
    /// `minterID` — the reference for the adornment pass's provenance
    /// guard (GENIUSLOCUSKIT_SPEC § 16.1): the pass persists a pair only
    /// when the pair's minter id equals this value, so an engine's text is
    /// never stored under a stale active minter's id.
    ///
    /// Nil means "no minter identity, do not guard": no engine resolves
    /// (the pass then mints mechanically), or the resolved engine is a
    /// generic harness `CommandEngine`, whose identity is its command name
    /// (`command:<name>`), not a minter id. The harness that injects a
    /// minter command owns the active set exactly — the same rule as the
    /// Rust port, where the MOOT_MINT_CMD subprocess seam has no engine
    /// identity and `run_adornment_pass` runs unguarded. Product engines
    /// (Apple's on-device model, CoreAI arms, quantized recipes) carry
    /// their recipe's composed minter id and are always guarded.
    public func servingMinterIdentity(for minterID: String) async -> String? {
        guard let identity = await engine(for: minterID)?.identity else { return nil }
        return identity.hasPrefix(commandEngineIdentityPrefix) ? nil : identity
    }

    /// The identity of the engine that would serve `minterID`, or nil when
    /// no engine resolves — the key the adornment pass groups its
    /// concurrency lanes by (GENIUSLOCUSKIT_SPEC § 16.1): every minter
    /// that resolves to one engine shares that engine's
    /// `maxConcurrentMints` budget instead of each taking the full width.
    /// Unlike `servingMinterIdentity(for:)` this reports the harness
    /// `CommandEngine` too: a command pipe is a width-1 sink, and two
    /// minters sharing it must never drive two subprocess calls at once.
    /// Identity, not object: the resident rule keeps one engine per
    /// identity in a process, and two arms deliberately registered under
    /// one identity serialize together — fewer calls than the engines
    /// could take, never more.
    public func servingEngineIdentity(for minterID: String) async -> String? {
        await engine(for: minterID)?.identity
    }

    /// The effective engine's declared mint fan-out width (resolving the
    /// engine if needed), or 1 when no engine is available. Mint drivers
    /// bound their task groups to this — see
    /// `GoldMinerEngine.maxConcurrentMints`.
    public func mintWidth() async -> Int {
        let base = effectiveEngine()?.maxConcurrentMints ?? 1
        #if MOOTX01_MULTI_MODEL
        // Sum, not max: each registered arm runs its own lane in the
        // pass, so the total in-flight bound is every engine's width
        // together (engines sit on different silicon; one engine's wait
        // is another's runtime).
        await loadArmsIfNeeded()
        let dedicated = minterEngines.values.map(\.maxConcurrentMints).reduce(0, +)
        return max(1, base + dedicated)
        #else
        return max(1, base)
        #endif
    }

    /// The declared width of the engine that serves `minterID` — the
    /// pass sizes each engine lane with this, asking once per lane
    /// through any minter the lane holds (they all resolve to that
    /// lane's engine).
    public func mintWidth(for minterID: String) async -> Int {
        max(1, await engine(for: minterID)?.maxConcurrentMints ?? 1)
    }

    /// Row-batch mint through the effective engine, or nil when the
    /// engine does not speak the row-batch transport — the caller then
    /// mints those rows through the single-record path. See
    /// `GoldMinerEngine.mintRows`.
    public func mintRows(
        _ rows: [String], maxLength: Int, for minterID: String? = nil
    ) async -> [String?]? {
        guard let engine = await engine(for: minterID), engine.supportsRowBatching else { return nil }
        return await engine.mintRows(rows, maxLength: maxLength)
    }

    /// Resolve the effective engine: an installed engine wins; otherwise
    /// an EXPLICIT `MOOT_MINT_CMD` (the harness audition vehicle — an
    /// operator who injected a minter command means it) beats the
    /// self-defaulting platform engine; otherwise Apple's on-device model
    /// (the ONLY engine on iOS, the platform DEFAULT on macOS); else nil
    /// (miner inactive). Ordering matters for auditions: with apple ahead
    /// of the command seam, an audition's injected minter was silently
    /// ignored on every Apple-capable machine (DEFAULT-MINT-01).
    private func effectiveEngine() -> (any GoldMinerEngine)? {
        if let engine { return engine }
        #if os(macOS)
        if let cmd = ProcessInfo.processInfo.environment["MOOT_MINT_CMD"], !cmd.isEmpty {
            let cmdEngine = CommandEngine(command: cmd)
            engine = cmdEngine
            log.info("GoldMiner: defaulted to \(cmdEngine.identity)")
            return cmdEngine
        }
        #endif
        if let apple = AppleFoundationEngine.ifAvailable() {
            engine = apple
            log.info("GoldMiner: defaulted to \(apple.identity)")
            return apple
        }
        return nil
    }

    /// The resolved engine for a minter, for callers that mint OUTSIDE
    /// this actor (the pass's per-engine lanes): holding the actor for
    /// the duration of a generation serializes every lane through one
    /// mutex — with multi-model arms that collapses all concurrency
    /// (measured 2026-08-31: four active lanes produced ~4 mints in six
    /// minutes while queued behind each other).
    public func engineRef(for minterID: String? = nil) async -> (any GoldMinerEngine)? {
        await engine(for: minterID)
    }

    /// One-off mint for the impatient write path. Resident engine makes
    /// this sub-second; there is no load cost on this path by design.
    public func mintOne(prompt: String, for minterID: String? = nil) async -> String? {
        guard let engine = await engine(for: minterID) else {
            log.debug("GoldMiner: no engine — mint skipped")
            return nil
        }
        return await engine.mint(prompt: prompt)
    }

    /// Batch mint for dreaming passes and import drains. Order-preserving;
    /// a nil element is that prompt's per-prompt failure. Runs on the SAME
    /// resident engine as mintOne — batch is an access pattern, not a
    /// second residency.
    public func mintBatch(prompts: [String]) async -> [String?] {
        guard let engine = effectiveEngine() else {
            return Array(repeating: nil, count: prompts.count)
        }
        var out: [String?] = []
        out.reserveCapacity(prompts.count)
        for prompt in prompts {
            out.append(await engine.mint(prompt: prompt))
        }
        return out
    }
}

// MARK: - Apple engine (iOS-only engine; macOS default)

/// Apple's bundled on-device model via FoundationModels. Weights are
/// OS-resident (no load, no download, effectively zero added footprint) —
/// the resident rule is satisfied by the OS itself. Generation contract
/// (prompt, settings, identity) comes from `MinterRecipe.apple`.
public final class AppleFoundationEngine: GoldMinerEngine {
    /// The composed recipe ID (`apple-fm-p<N>-s<N>`) — the cross-device
    /// minter identity stamped on this engine's adornment rows.
    public let identity = MinterRecipe.apple.id

    /// Width 1: FoundationModels serializes every in-process session
    /// through the process's single inference-service connection —
    /// measured 2026-08-30: a width-12 in-process task group gained
    /// nothing, while 8 SEPARATE processes scaled 8x at unchanged
    /// per-call latency. Process-level fan-out lives in `CommandEngine`
    /// (a pool of resident minter subprocesses); this engine stays the
    /// serial in-process default.
    public let maxConcurrentMints: Int = 1

    /// Nil when the platform or runtime cannot serve the model (pre-26 OS,
    /// model disabled/not downloaded, non-Apple toolchain).
    public static func ifAvailable() -> AppleFoundationEngine? {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, iOS 26.0, *) else { return nil }
        guard SystemLanguageModel.default.availability == .available else { return nil }
        return AppleFoundationEngine()
        #else
        return nil
        #endif
    }

    public func mint(prompt: String) async -> String? {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, iOS 26.0, *) else { return nil }
        do {
            // Greedy sampling: minting requires deterministic output.
            // (Recipe parameter "sampling": "greedy".)
            let options = GenerationOptions(samplingMode: .greedy)
            let session = LanguageModelSession(
                instructions: MinterRecipe.apple.systemPrompt)
            let raw = try await session.respond(to: prompt, options: options).content
            let claim = normalizeMintOutput(raw, kind: MinterRecipe.apple.output)
            return claim.isEmpty ? nil : claim
        } catch {
            log.error("AppleFoundationEngine: \(error)")
            return nil
        }
        #else
        return nil
        #endif
    }

    // MARK: Row-batch transport

    public var supportsRowBatching: Bool { true }

    public func mintRows(_ rows: [String], maxLength: Int) async -> [String?] {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, iOS 26.0, *) else {
            return Array(repeating: nil, count: rows.count)
        }
        return await mintRowFrame(rows, maxLength: maxLength)
        #else
        return Array(repeating: nil, count: rows.count)
        #endif
    }

    #if canImport(FoundationModels)
    /// One batch = one independent light request (operator ruling 2026-08-30:
    /// batches are stateless by protocol — the previous batch is
    /// answered and gone, never context for the next). Each frame runs
    /// against ONLY the standing instructions plus its own records, so
    /// every request stays at minimum prompt weight; an accumulating
    /// transcript made each frame heavier, forced cache-destroying
    /// resets, and collapsed service throughput (measured 2026-08-30).
    /// The service caches the shared instruction prefix across sessions,
    /// so a fresh session per frame re-pays only its own rows.
    @available(macOS 26.0, iOS 26.0, *)
    private func mintRowFrame(_ rows: [String], maxLength: Int) async -> [String?] {
        let prompt = formatAdornmentBatchPrompt(rows: rows)
        let session = LanguageModelSession(
            instructions: adornmentBatchInstructions(maxLength: maxLength))
        do {
            let raw = try await session.respond(
                to: prompt, options: GenerationOptions(sampling: .greedy)).content
            return parseAdornmentBatchReply(raw, expectedRows: rows.count).map { claim in
                guard let claim else { return nil }
                let normalized = normalizeMintOutput(claim, kind: MinterRecipe.apple.output)
                return normalized.isEmpty ? nil : normalized
            }
        } catch {
            // A batch-level failure (guardrail, context, model error)
            // fails every row; the caller retries them through the
            // single-record path.
            log.error("AppleFoundationEngine batch: \(error)")
            return Array(repeating: nil, count: rows.count)
        }
    }
    #endif
}

/// Identity prefix of a generic harness `CommandEngine`. The explicit Core AI
/// worker constructor carries the product minter id instead, so
/// `GoldMiner.servingMinterIdentity` applies its provenance guard. Declared
/// outside the macOS block because the accessor compiles on every platform.
let commandEngineIdentityPrefix = "command:"

#if os(macOS)
// MARK: - Command engine (macOS process boundary)

/// External-command engine over the MOOT_MINT_CMD contract. macOS-only —
/// iOS cannot spawn processes. The generic initializer is the benchmark and
/// operator seam; the explicit Core AI initializer is the contained product
/// process boundary. Neither becomes the default here. Batch-capable commands
/// (capability probe) run resident via ResidentMintSession; others run one-shot.
public final class CommandEngine: GoldMinerEngine {
    public let identity: String
    private let command: String
    private let commandArguments: [String]
    private let allowsEnvironmentRowBatching: Bool

    /// Process-level fan-out: the OS inference service pipelines SEPARATE
    /// minter processes (measured 2026-08-30: 8 concurrent apple-mint
    /// processes scaled 8x at unchanged per-call latency, while in-process
    /// session concurrency gained nothing). Width comes from
    /// MOOT_MINT_WIDTH (default 1 — the end-user product needs no
    /// environment wiring); width > 1 runs a pool of resident batch
    /// sessions, each owning its own child process, with callers
    /// distributed round-robin. Batch capability is probed per session;
    /// a one-shot minter (no batch protocol) stays width-1 through the
    /// module seam regardless of the requested width.
    public let maxConcurrentMints: Int

    /// Dedicated resident sessions for process fan-out or for a configured
    /// invocation such as the Core AI worker. The legacy path-only width-1
    /// command keeps using the module seam's shared session.
    private let pool: [ResidentMintSession]
    private let picker = PoolPicker()

    /// Round-robin distributor. An actor so the counter is race-free
    /// under the pass's task-group callers.
    private actor PoolPicker {
        private var next = 0
        func index(of count: Int) -> Int {
            defer { next = (next + 1) % max(count, 1) }
            return next % max(count, 1)
        }
    }

    private init(
        command: String,
        arguments: [String],
        identity: String,
        lifecyclePolicy: ResidentMintLifecyclePolicy,
        allowsEnvironmentRowBatching: Bool,
        width: Int
    ) {
        self.command = command
        self.commandArguments = arguments
        self.identity = identity
        self.allowsEnvironmentRowBatching = allowsEnvironmentRowBatching
        self.maxConcurrentMints = width
        let needsOwnedSession = width > 1
            || !arguments.isEmpty
            || lifecyclePolicy != .standard
        self.pool = needsOwnedSession
            ? (0..<width).map { _ in ResidentMintSession(policy: lifecyclePolicy) }
            : []
    }

    /// Generic external command. Fixed arguments precede every protocol flag:
    /// capability probing appends `--mint-capabilities`, resident operation
    /// appends `--batch`, and one-shot operation passes only these arguments.
    public convenience init(
        command: String,
        arguments: [String] = [],
        lifecyclePolicy: ResidentMintLifecyclePolicy = .standard
    ) {
        let width: Int
        if let raw = ProcessInfo.processInfo.environment["MOOT_MINT_WIDTH"],
           let parsed = Int(raw), parsed >= 1 {
            width = parsed
        } else {
            width = 1
        }
        self.init(
            command: command,
            arguments: arguments,
            identity: commandEngineIdentityPrefix + (command as NSString).lastPathComponent,
            lifecyclePolicy: lifecyclePolicy,
            allowsEnvironmentRowBatching: true,
            width: width)
    }

    #if canImport(CoreAI)
    /// Contained macOS Core AI worker using the installed `mootx01` binary.
    /// This constructor deliberately forces one child even when a harness left
    /// `MOOT_MINT_WIDTH` set: one model process at a time is the shipping rule.
    public convenience init(
        coreAIWorkerExecutable command: String,
        assetPath: String,
        tokenizerPath: String,
        style: CoreAIPromptStyle,
        maxNewTokens: Int,
        identity: String
    ) {
        self.init(
            command: command,
            arguments: [
                "coreai-mint-worker",
                "--asset", assetPath,
                "--tokenizer", tokenizerPath,
                "--style", style.rawValue,
                "--max-new-tokens", String(maxNewTokens),
                "--identity", identity,
            ],
            identity: identity,
            lifecyclePolicy: .coreAIContainment,
            allowsEnvironmentRowBatching: false,
            width: 1)
    }
    #endif

    public func mint(prompt: String) async -> String? {
        guard !pool.isEmpty else {
            return await invokeAdornmentCommand(
                prompt: prompt,
                command: command,
                arguments: commandArguments)
        }
        let session = pool[await picker.index(of: pool.count)]
        let invocation = ResidentMintCommand(
            executablePath: command,
            baseArguments: commandArguments)
        if await session.supportsBatch(command: invocation) {
            return await session.mint(prompt: prompt, command: invocation)
        }
        // One-shot minters cannot hold a resident child; serve the call
        // through the module seam (spawn-per-prompt) instead.
        return await invokeAdornmentCommand(
            prompt: prompt,
            command: command,
            arguments: commandArguments)
    }

    /// Aggregate lifecycle and pressure telemetry across this engine's child
    /// slots. Core AI always has exactly one slot; generic harness commands may
    /// opt into more through `MOOT_MINT_WIDTH`. A legacy path-only wrapper
    /// reports the module-wide shared command session by design.
    public func lifecycleSnapshot() async -> ResidentMintLifecycleSnapshot {
        guard !pool.isEmpty else {
            return await ResidentMintSession.shared.lifecycleSnapshot()
        }
        var aggregate = ResidentMintLifecycleSnapshot.zero
        for session in pool {
            aggregate = aggregate + (await session.lifecycleSnapshot())
        }
        return aggregate
    }

    /// Stop every child owned by this engine. The Core AI parent calls this on
    /// deactivation; idle reaping remains the automatic backstop. Legacy
    /// path-only engines use the shared module session and do not own it, so
    /// shutting one of those wrappers down cannot disrupt another caller.
    public func shutdown() async {
        for session in pool {
            await session.shutdown()
        }
    }

    // MARK: Row-batch transport over the pool

    /// Row batching engages only when MOOT_MINT_ROWS=1 marks the command
    /// as speaking the `--rows` frame protocol (apple-fm-mint does; a
    /// generic minter command does not). Combined with width > 1 this is
    /// the batches-x-slots shape: each pool child holds one row-protocol
    /// session and every frame carries a whole multi-record prompt.
    public var supportsRowBatching: Bool {
        allowsEnvironmentRowBatching
            && !pool.isEmpty
            && ProcessInfo.processInfo.environment["MOOT_MINT_ROWS"] == "1"
    }

    public func mintRows(_ rows: [String], maxLength: Int) async -> [String?] {
        guard supportsRowBatching else {
            return Array(repeating: nil, count: rows.count)
        }
        let prompt = formatAdornmentBatchPrompt(rows: rows)
        let session = pool[await picker.index(of: pool.count)]
        let invocation = ResidentMintCommand(
            executablePath: command,
            baseArguments: commandArguments)
        guard let raw = await session.mint(
            prompt: prompt,
            command: invocation,
            extraArgument: "--rows")
        else {
            return Array(repeating: nil, count: rows.count)
        }
        return parseAdornmentBatchReply(raw, expectedRows: rows.count).map { claim in
            guard let claim else { return nil }
            let normalized = normalizeMintOutput(claim, kind: MinterRecipe.apple.output)
            return normalized.isEmpty ? nil : normalized
        }
    }
}
#endif
