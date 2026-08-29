// GoldMiner.swift
//
// The resident gold-miner seam (ADORNMENTLIB_SPEC 0.5.0 § Gold miner).
//
// Requirements (Bob, 2026-08-26 — verbatim constraints):
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
    /// "apple-fm-p1-s1", "qwen2-0.5b-q4km-p1-s1"); the harness command
    /// engine uses its command name. Never a user-facing name.
    var identity: String { get }
    /// Mint one claim. Nil = per-prompt failure; the caller records a
    /// failed pair and continues.
    func mint(prompt: String) async -> String?
}

// MARK: - Resident owner

/// The process-wide resident miner. ONE instance per process; the engine
/// loads when installed and is NEVER unloaded (the resident rule). All
/// mint paths — impatient single writes, dreaming batches, import drains —
/// go through this owner so there is exactly one model residency.
public actor GoldMiner {
    public static let shared = GoldMiner()

    private var engine: (any GoldMinerEngine)?

    /// Install the process's engine. The composition layer calls this once
    /// at startup (or on minter-family activation). Installing a different
    /// engine replaces the old one; the old engine's residency is released
    /// by its own deinit.
    public func install(engine: any GoldMinerEngine) {
        log.info("GoldMiner: engine installed — \(engine.identity)")
        self.engine = engine
    }

    /// The active engine's identity, or nil when no engine is installed.
    public var engineIdentity: String? { engine?.identity }

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

    /// One-off mint for the impatient write path. Resident engine makes
    /// this sub-second; there is no load cost on this path by design.
    public func mintOne(prompt: String) async -> String? {
        guard let engine = effectiveEngine() else {
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
            let options = GenerationOptions(sampling: .greedy)
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
}

#if os(macOS)
// MARK: - Command engine (macOS harness vehicle)

/// External-command engine over the MOOT_MINT_CMD contract. macOS-only —
/// iOS cannot spawn processes; this engine exists for the benchmark
/// harness and for operator-supplied minters, never as the product
/// default. Batch-capable commands (capability probe) run resident via
/// ResidentMintSession; others run one-shot.
public final class CommandEngine: GoldMinerEngine {
    public let identity: String
    private let command: String

    public init(command: String) {
        self.command = command
        self.identity = "command:\((command as NSString).lastPathComponent)"
    }

    public func mint(prompt: String) async -> String? {
        await invokeAdornmentCommand(prompt: prompt, command: command)
    }
}
#endif
