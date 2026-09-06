#if MOOTX01_MINERS
// AdornmentGenerator.swift
//
// Dream-time adornment generation seam for the MOOTx01 adornment feature
// (SPEC_ADORNMENT §3, adornment rebuild 2026-08-23).
//
// The generator is a SEAM, not a model. It delegates to an external command
// via the MOOT_MINT_CMD environment variable (stdin prompt → stdout claim).
// No validators run on this path (SPEC_ADORNMENT §8: the minting model is
// constrained by instruction, never post-hoc mechanical rejection).
//
// Length: non-empty output is silently mechanically truncated to
// ADORNMENT_MAX_LENGTH in code; the prompt asks softly ("less is better")
// and never mentions truncation. Empty output is discarded and the pair
// stays missing. The const value is provisional; see its comment.
//
// Thread safety: all public entry points are `async` and are safe to call
// from concurrent Swift 6 actors. The subprocess I/O is the only
// synchronisation boundary; no mutable state is shared.

import Foundation
import OSLog

private let log = Logger(subsystem: "com.mootx01.kit", category: "AdornmentLib")

// MARK: - Constants

/// Maximum byte length of an adornment string.
///
/// Provisional pending the judging-density study (SPEC_ADORNMENT §2).
/// The density study will run the audition tool at multiple lengths
/// (controlled at runtime via the benchmark harness) and select the
/// length that maximises judged synthesize quality per token of context
/// consumed. The winning length seeds the next production const revision.
///
/// Over-length output is mechanically truncated to this length (Bob
/// ruling 2026-08-24). The prompt asks for under-limit output softly
/// ("less is better") and deliberately never mentions truncation — the
/// ceiling is enforced in code, not negotiated with the model.
public let ADORNMENT_MAX_LENGTH: Int = 280

// MARK: - Prompt template

/// Build the generation prompt for a single drawer.
///
/// Template per SPEC_ADORNMENT §2b as amended by Bob's date ruling
/// (2026-08-24): summarize the meaning tightly; entities named in full
/// (no pronouns, no session-relative references); dates appear ONLY when
/// available in the prompt data — stated in the record, or calculable
/// from a natural-language reference plus the supplied record date;
/// counts explicit when stated; densest-first within the length budget.
///
/// - Parameters:
///   - drawerContent: The verbatim body text of the drawer being adorned.
///   - eventDate: The record's own date (drawer filedAt / corpus session
///     date). When provided it is included in the prompt so relative
///     references ("next month") are calculable; when nil the model is
///     instructed to state only dates the record itself contains.
///   - maxLength: The maximum character length the model must respect.
///     Callers should pass `ADORNMENT_MAX_LENGTH` unless running the
///     benchmark audition tool, which may override for density studies.
/// - Returns: The prompt string to send to the minting model via stdin.
public func buildAdornmentPrompt(
    drawerContent: String,
    eventDate: String? = nil,
    maxLength: Int = ADORNMENT_MAX_LENGTH
) -> String {
    // The prompt instructs the model to produce a self-contained claim
    // block: entities in full, counts explicit, no pronouns, no "this",
    // no "the user". Densest-first so the first sentence carries the most
    // discriminating evidence. Hard character limit stated in the prompt
    // because the model must enforce it — we verify with the length gate
    // below, never rely on it.
    //
    // Date rule (Bob ruling 2026-08-24, replacing "express all dates as
    // absolute"): only include dates if available in the prompt data.
    // The old instruction demanded absolute dates while callers withheld
    // the record's event date, forcing the model to guess a year
    // (measured live: "next month" in a 2023-04-27 session minted as
    // 2026-05). The record-date line is emitted only when provided.
    // Output shape (Bob ruling 2026-08-24): word blobs, not sentences —
    // one dense line of 2-3 word chunks separated by "; ", chunking the
    // knowledge of the record as densely as possible.
    let recordDateLine = eventDate.map { "Record date: \($0)\n\n" } ?? ""
    return """
    \(recordDateLine)Summarize the meaning of the following memory record as ONE dense line of \
    word blobs: 2-3 word chunks separated by "; " — not sentences, no grammar, just the \
    densest possible chunks of the record's knowledge (example: "tomato saplings planted; \
    straw mulch; 12 count"). Requirements:
    - Name every entity in full (no pronouns, no relative references like "the user" or "it").
    - Only include dates if available in the prompt data: dates stated in the record, or \
    calculable from a natural-language reference plus the record date above. Never invent a date.
    - State counts and quantities as numbers only when the record states them.
    - Do not include any opinion, narrative, or commentary.
    - Results should be under \(maxLength) characters, less is better; list blobs in decreasing order of importance.

    Memory record:
    \(drawerContent)

    Adornment:
    """
}

// MARK: - Map-reduce chunking

/// Character threshold above which a record is minted in pieces.
///
/// The tightest miner window is apple-mint's 8192-token context with a
/// 4-bytes-per-token floor (~32K chars for the WHOLE prompt). 16K chars
/// of record content leaves the template and a wide safety margin.
public let ADORNMENT_CHUNK_THRESHOLD: Int = 16_000

/// Mint an adornment for one record, chunking when the record exceeds
/// the miner window (Bob miner-shape ruling, 2026-08-25).
///
/// Small records: one prompt, one mint. Oversized records: split into
/// deterministic ≤threshold pieces on line boundaries, mint each piece,
/// concatenate the piece-summaries, and feed the combined text back
/// through the model for one final blob line. The caller's `mint`
/// closure performs a single prompt→output call (the production
/// `invokeAdornmentCommand`, or a harness seam).
///
/// - Parameters:
///   - drawerContent: The FULL record text (never pre-parsed).
///   - eventDate: The record's own date for the prompt's record-date line.
///   - maxLength: Contract ceiling; the seam truncates mechanically.
///   - chunkThreshold: Piece-size bound (default ADORNMENT_CHUNK_THRESHOLD).
///   - mint: Single-call seam: prompt in, raw adornment (or nil) out.
/// - Returns: The final adornment. Never nil for non-blank content: when
///   the model refuses or its output normalizes to empty, the return is
///   the MECHANICAL fallback — claim-line extraction over the record
///   content, truncated to `maxLength` (Bob ruling 2026-08-27: a null
///   adornment is not allowed for a non-blank drawer; coverage is
///   guaranteed structurally by mechanical truncation). Nil only when
///   `drawerContent` itself normalizes to empty.
public func mintAdornmentMapReduce(
    drawerContent: String,
    eventDate: String?,
    maxLength: Int = ADORNMENT_MAX_LENGTH,
    chunkThreshold: Int = ADORNMENT_CHUNK_THRESHOLD,
    mint: (String) async -> String?
) async -> String? {
    // Mechanical coverage backstop: deterministic adornment derived from
    // the record itself. Used whenever generation fails (guardrail
    // refusal, empty normalized output) so a non-blank drawer always
    // mints. Deterministic per content — safe across ports and retries.
    func mechanicalFallback() -> String? {
        let line = extractClaimLine(drawerContent)
        guard !line.isEmpty else { return nil }
        return String(line.prefix(maxLength))
    }

    if drawerContent.count <= chunkThreshold {
        let prompt = buildAdornmentPrompt(
            drawerContent: drawerContent, eventDate: eventDate, maxLength: maxLength)
        if let minted = await mint(prompt), !minted.isEmpty { return minted }
        return mechanicalFallback()
    }

    // Split on line boundaries into ≤threshold pieces. A single line
    // longer than the threshold is first hard-split at chunkThreshold
    // CHARACTER boundaries (String.count / Character semantics; the Rust
    // twin counts chars()), so NO piece ever exceeds the threshold: an
    // unsplit over-long line reached the engine as one prompt, and a
    // resident engine that forwards every prompt token builds a
    // seq_len x seq_len attention mask — quadratic memory, daemon OOM
    // (Codex finding a8905b59). Deterministic: same content always
    // yields the same pieces.
    var pieces: [String] = []
    var current = ""
    for line in drawerContent.split(separator: "\n", omittingEmptySubsequences: false) {
        for segment in hardSplit(line, every: chunkThreshold) {
            if current.count + segment.count + 1 > chunkThreshold, !current.isEmpty {
                pieces.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n") + segment
        }
    }
    if !current.isEmpty { pieces.append(current) }

    var pieceSummaries: [String] = []
    for piece in pieces {
        let prompt = buildAdornmentPrompt(
            drawerContent: piece, eventDate: eventDate, maxLength: maxLength)
        if let summary = await mint(prompt) {
            pieceSummaries.append(summary)
        }
    }
    guard !pieceSummaries.isEmpty else { return mechanicalFallback() }

    // Reduce: summarize the combined piece-summaries into the final line.
    let combined = pieceSummaries.joined(separator: "\n")
    let finalPrompt = buildAdornmentPrompt(
        drawerContent: combined, eventDate: eventDate, maxLength: maxLength)
    if let reduced = await mint(finalPrompt), !reduced.isEmpty { return reduced }
    // Reduce failed but piece summaries exist: they are model output —
    // prefer them over the mechanical line, truncated to the contract.
    let joined = pieceSummaries.joined(separator: "; ")
    if !joined.isEmpty { return String(joined.prefix(maxLength)) }
    return mechanicalFallback()
}

/// Cut one line into consecutive slices of at most `limit` Characters,
/// in order, so the map-reduce accumulator never sees a line longer
/// than its piece bound. A line at or under the limit comes back as
/// its single self. `limit` ≤ 0 also returns the line whole: the
/// threshold guard in `mintAdornmentMapReduce` has already routed such
/// a call here only for non-empty content, and a zero step would never
/// advance the cursor.
private func hardSplit(_ line: Substring, every limit: Int) -> [Substring] {
    guard limit > 0, line.count > limit else { return [line] }
    var slices: [Substring] = []
    var start = line.startIndex
    while start < line.endIndex {
        let end = line.index(start, offsetBy: limit, limitedBy: line.endIndex) ?? line.endIndex
        slices.append(line[start..<end])
        start = end
    }
    return slices
}

// MARK: - Generator seam

/// Generate and validate an adornment for a single drawer using the
/// external minting command.
///
/// The command is read from the `MOOT_MINT_CMD` environment variable.
/// The prompt is written to the command's stdin; the command must write
/// the generated adornment text to stdout and exit 0.
///
/// Output handling: empty output is discarded; non-empty output is
/// mechanically truncated to `maxLength` characters (Bob ruling
/// 2026-08-24 — the prompt never mentions truncation; the code
/// enforces the ceiling).
///
/// - Parameters:
///   - prompt: The minting prompt (from `buildAdornmentPrompt`).
///   - maxLength: Length ceiling. Pass `ADORNMENT_MAX_LENGTH` for production;
///     benchmark audition callers may pass a different value.
/// - Returns: The validated adornment string, or `nil` when the command is
///   absent, exits non-zero, or produces output that fails validation.
public func invokeAdornmentCommand(
    prompt: String,
    maxLength: Int = ADORNMENT_MAX_LENGTH
) async -> String? {
    #if os(macOS)
    // Read the mint command path from the environment.
    // MOOT_MINT_CMD must be an absolute path to an executable that reads a
    // prompt from stdin and writes the adornment to stdout. If the variable
    // is absent or empty, the seam is inactive and no adornment is produced.
    guard let mintCmd = ProcessInfo.processInfo.environment["MOOT_MINT_CMD"],
          !mintCmd.isEmpty else {
        log.debug("AdornmentGenerator: MOOT_MINT_CMD not set — seam inactive")
        return nil
    }
    guard let raw = await invokeAdornmentCommand(prompt: prompt, command: mintCmd) else {
        return nil
    }
    let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !candidate.isEmpty else {
        log.warning("AdornmentGenerator: empty output from '\(mintCmd)' — discarded")
        return nil
    }
    // Mechanical truncation at the contract length (Bob ruling 2026-08-24).
    return String(candidate.prefix(maxLength))
    #else
    _ = prompt
    _ = maxLength
    log.debug("AdornmentGenerator: command seam unavailable on this platform")
    return nil
    #endif
}

/// Command-addressed generation core: runs `command` over the mint
/// contract (batch-resident when the capability probe lists "batch",
/// one-shot otherwise) and returns the RAW claim text. Truncation and
/// whitespace policy belong to the callers — engines never truncate.
func invokeAdornmentCommand(
    prompt: String,
    command mintCmd: String,
    arguments: [String] = []
) async -> String? {
    #if os(macOS)

    let invocation = ResidentMintCommand(
        executablePath: mintCmd,
        baseArguments: arguments)

    // Resident batch mode: the minter loads its model ONCE and serves
    // NUL-delimited prompts for the life of the batch. A one-shot spawn
    // costs a full model load (~seconds, multi-GB residency) per
    // 280-character claim — three orders of magnitude of waste when a
    // pass mints hundreds of pairs. The mode is selected by CAPABILITY
    // PROBE, never configuration: the seam runs `CMD --mint-capabilities`
    // once per command (cached) and uses batch when the minter lists
    // "batch". Minters that do not answer the probe are driven one-shot —
    // the end-user product needs no environment or preference wiring.
    if await ResidentMintSession.shared.supportsBatch(command: invocation) {
        return await ResidentMintSession.shared.mint(prompt: prompt, command: invocation)
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: mintCmd)
    process.arguments = arguments

    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    do {
        try process.run()
    } catch {
        log.error("AdornmentGenerator: failed to launch '\(mintCmd)': \(error)")
        return nil
    }

    // Write the prompt to stdin, then close the pipe so the child sees EOF.
    let promptData = Data(prompt.utf8)
    stdinPipe.fileHandleForWriting.write(promptData)
    try? stdinPipe.fileHandleForWriting.close()

    // Wait for the process; treat non-zero exit as validation failure.
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        log.error("AdornmentGenerator: '\(mintCmd)' exited \(process.terminationStatus)")
        return nil
    }

    let rawData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    guard let rawText = String(data: rawData, encoding: .utf8) else {
        log.error("AdornmentGenerator: non-UTF-8 output from '\(mintCmd)'")
        return nil
    }

    // Return the raw text; whitespace and truncation policy belong to the
    // callers (the env entry above; engine consumers apply the seam's
    // mechanical truncation at their own level).
    return rawText
    #else
    // iOS cannot launch child processes. The command engine is macOS-only;
    // on iPhone/iPad the GoldMiner's in-process engines serve this role.
    _ = prompt
    _ = mintCmd
    _ = arguments
    log.debug("AdornmentGenerator: command seam unavailable on this platform")
    return nil
    #endif
}

#if os(macOS)
// MARK: - Resident batch session

/// Lifecycle policy for a capability-probed resident mint child.
///
/// The standard command seam preserves its historical unbounded session and
/// no-retry behavior. The Core AI worker policy bounds one child to 16 logical
/// requests, retries one request after an unexpected child exit, and waits for
/// the worker's clean EOF shutdown before loading its replacement. That process
/// boundary contains Core AI runtime memory without changing any iOS path.
public struct ResidentMintLifecyclePolicy: Sendable, Equatable {
    public let maxRequestsPerProcess: Int?
    public let idleSeconds: UInt64
    public let maxCrashRetries: Int
    public let gracefulEOFShutdown: Bool

    public init(
        maxRequestsPerProcess: Int? = nil,
        idleSeconds: UInt64 = 120,
        maxCrashRetries: Int = 0,
        gracefulEOFShutdown: Bool = false
    ) {
        precondition(maxRequestsPerProcess == nil || maxRequestsPerProcess! > 0)
        precondition((0...1).contains(maxCrashRetries))
        self.maxRequestsPerProcess = maxRequestsPerProcess
        self.idleSeconds = idleSeconds
        self.maxCrashRetries = maxCrashRetries
        self.gracefulEOFShutdown = gracefulEOFShutdown
    }

    public static let standard = ResidentMintLifecyclePolicy()

    /// Proven containment bound for the macOS Core AI child. Recycling is a
    /// parent policy, not an engine/model default, and therefore never affects
    /// the in-process iOS engine.
    public static let coreAIContainment = ResidentMintLifecyclePolicy(
        maxRequestsPerProcess: 16,
        idleSeconds: 120,
        maxCrashRetries: 1,
        gracefulEOFShutdown: true)
}

/// Monotonic lifecycle totals plus current process-pressure gauges for one
/// resident session (or an aggregate of sessions). Operators can distinguish
/// normal bounded recycling from child crashes and see whether a resident
/// model is still consuming memory.
public struct ResidentMintLifecycleSnapshot: Sendable, Equatable {
    public let logicalRequests: UInt64
    public let requestAttempts: UInt64
    public let processStarts: UInt64
    public let launchFailures: UInt64
    public let boundedRecycles: UInt64
    public let idleReaps: UInt64
    public let unexpectedExits: UInt64
    public let crashRetries: UInt64
    public let perPromptFailures: UInt64
    public let activeChildren: Int
    public let requestsInActiveChildren: UInt64

    static let zero = ResidentMintLifecycleSnapshot(
        logicalRequests: 0,
        requestAttempts: 0,
        processStarts: 0,
        launchFailures: 0,
        boundedRecycles: 0,
        idleReaps: 0,
        unexpectedExits: 0,
        crashRetries: 0,
        perPromptFailures: 0,
        activeChildren: 0,
        requestsInActiveChildren: 0)

    static func + (
        lhs: ResidentMintLifecycleSnapshot,
        rhs: ResidentMintLifecycleSnapshot
    ) -> ResidentMintLifecycleSnapshot {
        ResidentMintLifecycleSnapshot(
            logicalRequests: lhs.logicalRequests + rhs.logicalRequests,
            requestAttempts: lhs.requestAttempts + rhs.requestAttempts,
            processStarts: lhs.processStarts + rhs.processStarts,
            launchFailures: lhs.launchFailures + rhs.launchFailures,
            boundedRecycles: lhs.boundedRecycles + rhs.boundedRecycles,
            idleReaps: lhs.idleReaps + rhs.idleReaps,
            unexpectedExits: lhs.unexpectedExits + rhs.unexpectedExits,
            crashRetries: lhs.crashRetries + rhs.crashRetries,
            perPromptFailures: lhs.perPromptFailures + rhs.perPromptFailures,
            activeChildren: lhs.activeChildren + rhs.activeChildren,
            requestsInActiveChildren:
                lhs.requestsInActiveChildren + rhs.requestsInActiveChildren)
    }
}

struct ResidentMintCommand: Hashable, Sendable {
    let executablePath: String
    let baseArguments: [String]

    func arguments(appending protocolArgument: String) -> [String] {
        baseArguments + [protocolArgument]
    }
}

/// Holds one resident minter child for the batch protocol
/// (`MOOT_MINT_BATCH=1`): the command is spawned once with `--batch`,
/// prompts go down its stdin NUL-terminated, responses come back
/// NUL-terminated in order. An idle reaper terminates the child after
/// `idleSeconds` without a mint, so the model's multi-GB residency is
/// released between dream-time fires while a bulk mint keeps it warm.
///
/// Failure policy is explicit per session. The standard seam reports a
/// protocol fault as nil and respawns on the next pass. A contained Core AI
/// session retries the in-flight request once after unexpected child exit;
/// there is no unbounded retry loop.
actor ResidentMintSession {
    static let shared = ResidentMintSession()

    /// Idle window before the resident child is reaped. Long enough that a
    /// pass minting at inference speed never trips it; short enough that a
    /// user machine reclaims the model's memory promptly after a fire.
    private let policy: ResidentMintLifecyclePolicy

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var buffer = Data()
    /// Command the current child was spawned with. A caller presenting a
    /// DIFFERENT command (minter activation changed mid-session) tears the
    /// old child down first — replies from the previous minter must never
    /// answer the new minter's prompts.
    private var spawnedCommand: ResidentMintCommand?
    private var spawnedProtocolArgument: String?
    /// Monotonic use counter — the reaper only fires if no mint happened
    /// since it was scheduled.
    private var useGeneration: UInt64 = 0
    private var requestsInCurrentProcess: UInt64 = 0

    private var logicalRequests: UInt64 = 0
    private var requestAttempts: UInt64 = 0
    private var processStarts: UInt64 = 0
    private var launchFailures: UInt64 = 0
    private var boundedRecycles: UInt64 = 0
    private var idleReaps: UInt64 = 0
    private var unexpectedExits: UInt64 = 0
    private var crashRetries: UInt64 = 0
    private var perPromptFailures: UInt64 = 0

    // Actor isolation alone is not enough here: `mint` yields while a blocking
    // pipe read runs off-executor, so another caller could otherwise enter and
    // read the same ordered byte stream. This lease keeps one complete
    // request/response transaction in flight per child.
    private var mintInProgress = false
    private var mintWaiters: [CheckedContinuation<Void, Never>] = []

    /// Cached capability-probe results per command path.
    private var probeCache: [ResidentMintCommand: Bool] = [:]

    init(policy: ResidentMintLifecyclePolicy = .standard) {
        self.policy = policy
    }

    /// Whether `command` speaks the batch protocol, probed once per path:
    /// `CMD --mint-capabilities` must exit 0 and list "batch" on stdout.
    /// The probe answers before any model load by contract; a minter that
    /// errors on the flag (or hangs past its closed stdin) is one-shot.
    func supportsBatch(command: ResidentMintCommand) async -> Bool {
        if let cached = probeCache[command] { return cached }
        let supported = Self.probeBatch(command: command)
        probeCache[command] = supported
        return supported
    }

    private static func probeBatch(command: ResidentMintCommand) -> Bool {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: command.executablePath)
        probe.arguments = command.arguments(appending: "--mint-capabilities")
        let inPipe = Pipe()
        let outPipe = Pipe()
        probe.standardInput = inPipe
        probe.standardOutput = outPipe
        probe.standardError = FileHandle.nullDevice
        do {
            try probe.run()
        } catch {
            return false
        }
        // Close stdin at once: a pre-probe one-shot minter that ignores the
        // flag sees EOF and exits on its empty-prompt path instead of hanging.
        try? inPipe.fileHandleForWriting.close()
        probe.waitUntilExit()
        guard probe.terminationStatus == 0 else { return false }
        let out = String(
            data: outPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8) ?? ""
        return out.split(separator: "\n").contains("batch")
    }

    /// Mint one prompt through the resident child, spawning it on demand.
    func mint(
        prompt: String,
        command: ResidentMintCommand,
        extraArgument: String = "--batch"
    ) async -> String? {
        logicalRequests &+= 1
        await acquireMintLease()
        defer { releaseMintLease() }

        useGeneration &+= 1
        let generationAtStart = useGeneration
        var retriesRemaining = policy.maxCrashRetries

        while true {
            // The spawn key includes fixed arguments and the protocol mode: a
            // child serving --rows must never answer --batch prompts, and two
            // Core AI assets must never share one child.
            if let limit = policy.maxRequestsPerProcess,
               process?.isRunning == true,
               spawnedCommand == command,
               spawnedProtocolArgument == extraArgument,
               requestsInCurrentProcess >= UInt64(limit) {
                boundedRecycles &+= 1
                teardown(graceful: policy.gracefulEOFShutdown)
            }

            if process != nil, process?.isRunning != true {
                unexpectedExits &+= 1
                teardown()
            }
            if process == nil
                || spawnedCommand != command
                || spawnedProtocolArgument != extraArgument {
                teardown(graceful: policy.gracefulEOFShutdown)
                guard spawn(command: command, argument: extraArgument) else {
                    return nil
                }
            }
            guard let stdinHandle, let stdoutHandle else { return nil }

            requestAttempts &+= 1
            requestsInCurrentProcess &+= 1

            do {
                try stdinHandle.write(contentsOf: Self.batchFrame(prompt))
            } catch {
                log.error("ResidentMintSession: stdin write failed — \(error)")
                unexpectedExits &+= 1
                teardown()
                guard retriesRemaining > 0 else { return nil }
                retriesRemaining -= 1
                crashRetries &+= 1
                continue
            }

            // Read until the response's NUL terminator. Blocking reads run off
            // the actor's executor; the mint lease above keeps later callers
            // queued for this ordered stream without stalling the cooperative
            // pool.
            var childExited = false
            while true {
                if let nulIndex = buffer.firstIndex(of: 0) {
                    let payload = buffer.prefix(upTo: nulIndex)
                    buffer.removeSubrange(...nulIndex)
                    scheduleReaper(after: generationAtStart)
                    guard !payload.isEmpty else {
                        perPromptFailures &+= 1
                        return nil
                    }
                    guard let response = String(data: Data(payload), encoding: .utf8) else {
                        perPromptFailures &+= 1
                        return nil
                    }
                    return response
                }
                let chunk = await Self.blockingRead(stdoutHandle)
                if chunk.isEmpty {
                    childExited = true
                    break
                }
                buffer.append(chunk)
            }

            if childExited {
                log.error("ResidentMintSession: child EOF mid-response — tearing down")
                unexpectedExits &+= 1
                teardown()
                guard retriesRemaining > 0 else { return nil }
                retriesRemaining -= 1
                crashRetries &+= 1
            }
        }
    }

    func lifecycleSnapshot() -> ResidentMintLifecycleSnapshot {
        let running = process?.isRunning == true
        return ResidentMintLifecycleSnapshot(
            logicalRequests: logicalRequests,
            requestAttempts: requestAttempts,
            processStarts: processStarts,
            launchFailures: launchFailures,
            boundedRecycles: boundedRecycles,
            idleReaps: idleReaps,
            unexpectedExits: unexpectedExits,
            crashRetries: crashRetries,
            perPromptFailures: perPromptFailures,
            activeChildren: running ? 1 : 0,
            requestsInActiveChildren: running ? requestsInCurrentProcess : 0)
    }

    func shutdown() async {
        // Do not close a protocol stream while its response is in flight.
        await acquireMintLease()
        defer { releaseMintLease() }
        // Invalidate every previously scheduled idle reaper before closing the
        // child, so a later respawn cannot be reaped by an old generation.
        useGeneration &+= 1
        teardown(graceful: policy.gracefulEOFShutdown)
    }

    private func acquireMintLease() async {
        guard mintInProgress else {
            mintInProgress = true
            return
        }
        await withCheckedContinuation { continuation in
            mintWaiters.append(continuation)
        }
    }

    private func releaseMintLease() {
        guard !mintWaiters.isEmpty else {
            mintInProgress = false
            return
        }
        mintWaiters.removeFirst().resume()
    }

    /// Frame one prompt for the resident child's NUL-delimited stdin
    /// protocol: the prompt's UTF-8 bytes with every U+0000 stripped,
    /// followed by exactly one NUL terminator.
    ///
    /// Drawer content is untrusted and lands in the prompt verbatim. An
    /// embedded NUL would split one prompt into two child frames; the
    /// child answers both, the parent reads one reply per logical
    /// prompt, and every later reply lands on the wrong drawer/minter
    /// pair — a claim minted from a restricted drawer stored under a
    /// normal one (Codex finding 765175da). Stripping at the frame site
    /// keeps the delimiter unambiguous whatever the content carries; a
    /// NUL has no meaning inside prompt text, so nothing is lost.
    /// Pure and deterministic: "ab\u{0}cd" -> [0x61,0x62,0x63,0x64,0x00].
    static func batchFrame(_ prompt: String) -> Data {
        var frame = Data(prompt.utf8.filter { $0 != 0 })
        frame.append(0)
        return frame
    }

    private func spawn(
        command: ResidentMintCommand,
        argument: String = "--batch"
    ) -> Bool {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: command.executablePath)
        child.arguments = command.arguments(appending: argument)
        let inPipe = Pipe()
        let outPipe = Pipe()
        child.standardInput = inPipe
        child.standardOutput = outPipe
        // stderr inherits the host's stderr: the minter's diagnostics land in
        // the serve/daemon log instead of a pipe nobody drains (an undrained
        // stderr pipe deadlocks a chatty child once the buffer fills).
        do {
            try child.run()
        } catch {
            launchFailures &+= 1
            log.error("ResidentMintSession: failed to launch '\(command.executablePath)' \(argument): \(error)")
            return false
        }
        processStarts &+= 1
        process = child
        stdinHandle = inPipe.fileHandleForWriting
        stdoutHandle = outPipe.fileHandleForReading
        buffer.removeAll()
        spawnedCommand = command
        spawnedProtocolArgument = argument
        requestsInCurrentProcess = 0
        log.info("ResidentMintSession: resident minter started (pid \(child.processIdentifier))")
        return true
    }

    private func teardown(graceful: Bool = false) {
        try? stdinHandle?.close()
        if let process, process.isRunning {
            if graceful {
                // Core AI worker exits on stdin EOF. Waiting here prevents the
                // replacement from briefly overlapping the old model's unified
                // memory residency during a bounded recycle.
                process.waitUntilExit()
            } else {
                process.terminate()
            }
        }
        process = nil
        stdinHandle = nil
        stdoutHandle = nil
        buffer.removeAll()
        spawnedCommand = nil
        spawnedProtocolArgument = nil
        requestsInCurrentProcess = 0
    }

    /// Reap the child if no mint has happened for `idleSeconds` after the
    /// mint that scheduled this reaper.
    private func scheduleReaper(after generation: UInt64) {
        Task { [policy] in
            try? await Task.sleep(nanoseconds: policy.idleSeconds * 1_000_000_000)
            self.reapIfIdle(since: generation)
        }
    }

    private func reapIfIdle(since generation: UInt64) {
        guard useGeneration == generation, process != nil else { return }
        idleReaps &+= 1
        log.info("ResidentMintSession: idle — releasing resident minter")
        teardown(graceful: policy.gracefulEOFShutdown)
    }

    /// One blocking `availableData` call moved off the actor executor.
    private static func blockingRead(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: handle.availableData)
            }
        }
    }
}
#endif

// MARK: - Row batching (transport, not recipe — identity unchanged)

/// Rows per batch round trip (Bob design 2026-08-30): the session is told
/// the task once, then receives batches of records as row data and
/// answers as row data, amortizing the per-request service overhead
/// across the batch while the persistent session preserves the KV cache.
public let ADORNMENT_BATCH_ROWS: Int = 5

/// Per-row payload ceiling for the batch path. Rows above this mint
/// through the single-record path (map-reduce chunking). Sized against
/// the same window the single path proves daily (single prompts up to
/// ADORNMENT_CHUNK_THRESHOLD = 16k chars generate fine): 8k covers
/// 96-98%% of convomem/membench drawers and 92%% of the complete
/// estate (measured 2026-08-30) while a full batch stays inside the
/// window.
public let ADORNMENT_BATCH_ROW_CHAR_LIMIT: Int = 8_000

/// Combined payload ceiling for one batch prompt (a batch packs rows
/// until either ADORNMENT_BATCH_ROWS or this budget is reached) —
/// ~3.5k tokens at the 4-chars/token floor, leaving instruction and
/// answer headroom inside the 8k-token window.
public let ADORNMENT_BATCH_CHAR_BUDGET: Int = 14_000

/// The batch session's standing instructions: the SAME density contract
/// as `buildAdornmentPrompt`, stated once for the whole session, plus
/// the row protocol. The per-record prompt shape is transport detail —
/// identity (minter id, prompt digest) is unchanged (Bob ruling
/// 2026-08-30: the shape of the prompt does not matter).
public func adornmentBatchInstructions(maxLength: Int = ADORNMENT_MAX_LENGTH) -> String {
    """
    You summarize memory records into adornments. Each user message is a batch \
    of records separated by "--- record N ---" markers. For EACH record produce \
    ONE dense line of word blobs: 2-3 word chunks separated by "; " — not \
    sentences, no grammar, just the densest possible chunks of the record's \
    knowledge (example: "tomato saplings planted; straw mulch; 12 count"). \
    Requirements for every line:
    - Name every entity in full (no pronouns, no relative references like "the user" or "it").
    - Only include dates if available in the record: dates stated in the record, \
    or calculable from a natural-language reference plus the record's date line. Never invent a date.
    - State counts and quantities as numbers only when the record states them.
    - Do not include any opinion, narrative, or commentary.
    - Keep each line under \(maxLength) characters, less is better; list blobs in decreasing order of importance.

    Answer with EXACTLY one line per record, in record order, each in the form \
    "N| <adornment>" where N is the record number. Nothing else — no preamble, \
    no blank lines. Then wait for the next batch.
    """
}

/// One record's row payload for the batch path: the record date line
/// (when available — same date rule as the single-record prompt) and the
/// verbatim content.
public func buildAdornmentRow(drawerContent: String, eventDate: String? = nil) -> String {
    let dateLine = eventDate.map { "Record date: \($0)\n" } ?? ""
    return dateLine + drawerContent
}

/// Assemble one batch prompt from row payloads.
public func formatAdornmentBatchPrompt(rows: [String]) -> String {
    var parts: [String] = ["Batch of \(rows.count) record(s):"]
    for (i, row) in rows.enumerated() {
        parts.append("--- record \(i + 1) ---")
        parts.append(row)
    }
    return parts.joined(separator: "\n")
}

/// Parse a batch reply back into per-row claims. Position `k` carries row
/// `k+1`'s claim, nil when the reply omitted that row — the caller
/// retries omitted rows through the single-record path, so a partially
/// well-formed reply still lands its good rows. Tolerates surrounding
/// noise lines; last occurrence of a row number wins (models sometimes
/// restate).
public func parseAdornmentBatchReply(_ reply: String, expectedRows: Int) -> [String?] {
    var out: [String?] = Array(repeating: nil, count: expectedRows)
    for line in reply.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let bar = trimmed.firstIndex(of: "|"),
              let n = Int(trimmed[trimmed.startIndex..<bar].trimmingCharacters(in: .whitespaces)),
              n >= 1, n <= expectedRows else { continue }
        let claim = String(trimmed[trimmed.index(after: bar)...])
            .trimmingCharacters(in: .whitespaces)
        if !claim.isEmpty { out[n - 1] = claim }
    }
    return out
}
#endif // MOOTX01_MINERS
