// AppleAnswerCLI.swift
//
// apple-answer subcommand — reads a prompt from stdin, generates one
// completion through the Apple Foundation Models engine (macOS 26+,
// Apple Intelligence required), prints the answer text to stdout, exits 0.
//
// Non-zero exit (via MCPError → benchmarkerMain exit 1) when the engine is
// unavailable: pre-macOS 26, Apple Intelligence disabled or not downloaded,
// or a non-Apple toolchain without FoundationModels.
//
// Usage:
//   mcp-benchmarker apple-answer [--max-tokens N]   (default 512)
//
// This subcommand satisfies the answer-cmd contract: prompt on stdin, answer
// text on stdout, exit 0 on success. Drop `scripts/apple-reader.sh` into
// `--answer-cmd` to feed it into answer-batch.
//
// The subcommand does NOT provision, read, or write any estate. It is a
// stateless text-in / text-out adapter over the OS-resident model.
//
// Engine construction uses SystemLanguageModel.default directly: no MOOT_MINT_CMD,
// availability probed via SystemLanguageModel.default.availability; greedy sampling
// for cross-arm consistency; a caller-controlled response-token cap. The system
// instructions are neutral — the caller owns prompt framing in the user turn.

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - apple-answer entry point

/// Runs the `apple-answer` subcommand.
///
/// Reads stdin to end-of-file, generates one completion through the Apple
/// Foundation Models engine, and writes the trimmed reply to stdout.
///
/// New flags (all optional; defaults match original single-shot behaviour):
///   --mode single|map-reduce|refine   reader recipe (default single)
///   --context-tokens N                model context window in tokens (default 8192)
///   --round-budget N                  input tokens per round incl. question (default 6000)
///   --note-cap N                      max response tokens per map note / refine draft (default 200)
///
/// In single mode the prompt is sent whole; if it exceeds --context-tokens the
/// command exits non-zero with the engine's over-context error text.
///
/// In map-reduce and refine modes the payload is split on memory boundaries so
/// each round fits within --round-budget.  Final answer text is printed to
/// stdout; a one-line summary is printed to stderr:
///   apple-answer: mode=<m> rounds=<n> chunks=<c> max_round_tokens=<t>
///
/// - Parameter args: Arguments following the `apple-answer` subcommand token.
/// - Throws: `MCPError` when the engine is unavailable or generation fails,
///   which `benchmarkerMain` maps to exit 1.
public func runAppleAnswer(_ args: [String]) async throws {
    // Parse flags — all have safe defaults so behaviour is byte-identical when
    // no new flags are supplied (preserves the original single-shot contract).
    let maxTokens     = optionValue("--max-tokens",      in: args).flatMap(Int.init) ?? 512
    let modeRaw       = optionValue("--mode",            in: args) ?? "single"
    let contextTokens = optionValue("--context-tokens",  in: args).flatMap(Int.init) ?? 8192
    let roundBudget   = optionValue("--round-budget",    in: args).flatMap(Int.init) ?? 6000
    let noteCap       = optionValue("--note-cap",        in: args).flatMap(Int.init) ?? 200
    // --guided: ask the model for a structured answer ({answer, evidence_ids, abstain}).
    let guided        = args.contains("--guided")
    // --pick-k N: pick mode selects at most N records in round 1 (default 3).
    let pickK         = optionValue("--pick-k",          in: args).flatMap(Int.init) ?? 3

    guard let mode = AppleAnswerMode(rawValue: modeRaw) else {
        throw MCPError(description:
            "apple-answer: unknown --mode '\(modeRaw)'; expected single, map-reduce, refine, or pick")
    }

    let raw = FileHandle.standardInput.readDataToEndOfFile()
    let prompt = String(decoding: raw, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty else {
        throw MCPError(description: "apple-answer: empty prompt on stdin")
    }

    #if canImport(FoundationModels)
    guard #available(macOS 26.0, iOS 26.0, *) else {
        // OS version gate: FoundationModels is macOS 26+ / iOS 26+.
        throw MCPError(description:
            "apple-answer: engine unavailable — requires macOS 26 or later")
    }
    // Runtime availability gate: the model may be disabled, not yet
    // downloaded, or unsupported on this device even when the OS supports it.
    guard SystemLanguageModel.default.availability == .available else {
        throw MCPError(description:
            "apple-answer: engine unavailable — Apple Intelligence is off "
            + "or the on-device model has not been downloaded on this system")
    }

    switch mode {
    case .single:
        // Original behaviour: single call, no splitting.
        // Reject over-context prompts before sending so the record shows the refusal.
        let tokenCount = appleAnswerEstimateTokens(prompt)
        if tokenCount > contextTokens {
            throw MCPError(description:
                "apple-answer: Content contains \(tokenCount) tokens, which exceeds "
                + "the maximum allowed context size of \(contextTokens)")
        }
        // Single mode: 1 round, 1 chunk, max_round_tokens = prompt token count.
        var summaryLine = appleAnswerStderrLine(
            mode: mode.rawValue, rounds: 1, chunks: 1, maxRoundTokens: tokenCount)
        if guided {
            let ga = try await generateGuidedAppleAnswer(prompt: prompt, maxTokens: maxTokens)
            summaryLine += " guided=1 evidence=\(ga.evidence_ids.count) abstain=\(ga.abstain ? 1 : 0)"
            fputs(summaryLine + "\n", stderr)
            let answer = ga.abstain ? "I don't know." : ga.answer
            FileHandle.standardOutput.write(Data(answer.utf8))
        } else {
            fputs(summaryLine + "\n", stderr)
            let reply = try await generateAppleAnswer(prompt: prompt, maxTokens: maxTokens)
            FileHandle.standardOutput.write(Data(reply.utf8))
        }

    case .mapReduce:
        // --guided is not currently threaded through map-reduce; the guided flag
        // applies only to the final answer round when the caller uses pick mode or
        // single mode.  Map-reduce ignores it and uses unguided generation, which
        // is the established contract for the notes rounds.
        let reply = try await runAppleAnswerMapReduce(
            prompt: prompt,
            contextTokens: contextTokens,
            roundBudget: roundBudget,
            noteCap: noteCap,
            maxTokens: maxTokens)
        FileHandle.standardOutput.write(Data(reply.utf8))

    case .refine:
        // Same rationale as map-reduce: guided applies to single and pick modes only.
        let reply = try await runAppleAnswerRefine(
            prompt: prompt,
            contextTokens: contextTokens,
            roundBudget: roundBudget,
            noteCap: noteCap,
            maxTokens: maxTokens)
        FileHandle.standardOutput.write(Data(reply.utf8))

    case .pick:
        let reply = try await runAppleAnswerPick(
            prompt: prompt,
            pickK: pickK,
            guided: guided,
            roundBudget: roundBudget,
            maxTokens: maxTokens)
        FileHandle.standardOutput.write(Data(reply.utf8))
    }
    #else
    // Non-Apple toolchain: FoundationModels is not importable.
    throw MCPError(description:
        "apple-answer: engine unavailable — built without FoundationModels "
        + "(requires an Apple toolchain targeting macOS 26+)")
    #endif
}

// MARK: - Generation helper

#if canImport(FoundationModels)
/// Generates one completion through the Apple Foundation Models engine.
///
/// Neutral system instructions let the caller own framing entirely through
/// the prompt. Greedy sampling produces deterministic output across benchmark
/// arms (same model weights + greedy → same tokens given the same prompt).
///
/// - Parameters:
///   - prompt: The full question/context text to answer.
///   - maxTokens: Hard cap on the number of response tokens.
/// - Returns: The model's reply, whitespace-trimmed.
/// - Throws: Propagates any FoundationModels session error.
@available(macOS 26.0, iOS 26.0, *)
private func generateAppleAnswer(prompt: String, maxTokens: Int) async throws -> String {
    // Greedy sampling: deterministic output required for consistent benchmark
    // arms. The same prompt + greedy always produces the same reply from a
    // fixed model version, so results are reproducible across re-runs.
    let options = GenerationOptions(
        samplingMode: .greedy,
        maximumResponseTokens: maxTokens)
    // Neutral instructions: the benchmark prompt already carries all context
    // (question, memory_texts, anscheck framing).
    let session = LanguageModelSession(
        instructions: "Answer the question directly and concisely based on the provided context.")
    let response = try await session.respond(to: prompt, options: options)
    return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
}
#endif

// MARK: - Guided generation types (@Generable, FoundationModels only)

// Public Codable mirrors — GuidedAnswer and PickResult — are defined in
// AppleAnswerChunked.swift so tests can exercise JSON round-trips without a
// model.  The private @Generable types below drive the actual
// session.respond(to:generating:) calls on macOS 26.

#if canImport(FoundationModels)
/// @Generable answer type.  Greedy sampling plus structured output constrains
/// the model to return JSON conforming to this schema, which is then copied
/// into the public GuidedAnswer value.
@available(macOS 26.0, iOS 26.0, *)
@Generable
private struct _GuidedAnswer: Sendable {
    /// evidence_ids are the record UUIDs the answer relies on.
    @Guide(description: "evidence_ids are the record UUIDs the answer relies on")
    var evidence_ids: [String]
    /// abstain when the records do not contain the answer.
    @Guide(description: "abstain when the records do not contain the answer")
    var abstain: Bool
    /// The direct answer to the question.
    var answer: String
}

/// @Generable pick-list type.  The model returns at most pickK 1-based indices
/// into the candidate list supplied in the round-1 prompt.
@available(macOS 26.0, iOS 26.0, *)
@Generable
private struct _PickResult: Sendable {
    /// Indices of the most relevant candidate records, best first.
    @Guide(description: "Indices of the most relevant candidate records, best first")
    var picks: [Int]
}
#endif

// MARK: - Guided generation helpers

#if canImport(FoundationModels)
/// Generates one guided completion using Apple Foundation Models.
///
/// The model returns a JSON object conforming to `_GuidedAnswer`, which is
/// then copied into the public `GuidedAnswer` type.  Callers check
/// `result.abstain` and print "I don't know." when true; otherwise they
/// print `result.answer`.
@available(macOS 26.0, iOS 26.0, *)
private func generateGuidedAppleAnswer(prompt: String, maxTokens: Int) async throws -> GuidedAnswer {
    // Greedy sampling: same rationale as generateAppleAnswer — deterministic
    // output for consistent benchmark arms.
    let options = GenerationOptions(
        samplingMode: .greedy,
        temperature: nil,
        maximumResponseTokens: maxTokens)
    let session = LanguageModelSession(
        instructions: "Answer the question directly and concisely based on the provided context.")
    let response = try await session.respond(to: prompt, generating: _GuidedAnswer.self, options: options)
    let raw = response.content
    return GuidedAnswer(answer: raw.answer, evidence_ids: raw.evidence_ids, abstain: raw.abstain)
}

/// Generates a pick list through guided generation.
///
/// The model selects at most `pickK` 1-based indices from the candidate list
/// in the prompt.  The raw `_PickResult` is copied into the public `PickResult`
/// type; clamping and dedup happen in the caller.
@available(macOS 26.0, iOS 26.0, *)
private func generatePickList(prompt: String, maxTokens: Int) async throws -> PickResult {
    let options = GenerationOptions(
        samplingMode: .greedy,
        temperature: nil,
        maximumResponseTokens: maxTokens)
    let session = LanguageModelSession(
        instructions: "Select the most relevant records by returning their indices.")
    let response = try await session.respond(to: prompt, generating: _PickResult.self, options: options)
    return PickResult(picks: response.content.picks)
}
#endif

// MARK: - Pick mode runner (FoundationModels only)

#if canImport(FoundationModels)
/// Runs the two-round pick reader recipe.
///
/// Round 1: the model receives the question + a one-line candidate list of ALL
/// records (header only) and returns at most `pickK` 1-based
/// indices, best first.  When the full candidate list exceeds `roundBudget`
/// it is chunked; each chunk produces a sub-list of picks and the sub-lists are
/// merged by round-1 order (`pick_rounds=<n>` on stderr).
///
/// Round 2: the question + the full distilled bodies of the picked records are
/// sent to the answer round (guided when `guided` is true).  If round 2 would
/// exceed `roundBudget`, picks are dropped from the tail until it fits
/// (`dropped=<n>` on stderr).
///
/// Summary line on stderr: `apple-answer: mode=pick picks=<list> rounds=<n> max_round_tokens=<t>`.
/// When `--guided`: the summary line gains ` guided=1 evidence=<n> abstain=<0|1>`.
@available(macOS 26.0, iOS 26.0, *)
private func runAppleAnswerPick(
    prompt: String,
    pickK: Int,
    guided: Bool,
    roundBudget: Int,
    maxTokens: Int
) async throws -> String {
    // Parse the standard reader prompt for its memories and question.
    guard let parsed = parseReaderPrompt(prompt) else {
        // Unknown layout: fall back to single-shot and log the reason.
        fputs("apple-answer: layout=unknown falling back to single-shot\n", stderr)
        let tokenCount = appleAnswerEstimateTokens(prompt)
        let summaryLine = appleAnswerStderrLine(
            mode: "pick", rounds: 1, chunks: 1, maxRoundTokens: tokenCount)
        fputs(summaryLine + "\n", stderr)
        if guided {
            let ga = try await generateGuidedAppleAnswer(prompt: prompt, maxTokens: maxTokens)
            fputs("apple-answer: guided=1 evidence=\(ga.evidence_ids.count) abstain=\(ga.abstain ? 1 : 0)\n",
                  stderr)
            return ga.abstain ? "I don't know." : ga.answer
        }
        return try await generateAppleAnswer(prompt: prompt, maxTokens: maxTokens)
    }

    let question = extractQuestion(fromFooter: parsed.footer)
    let totalCount = parsed.memories.count
    var maxRoundTokens = 0
    var rounds = 0

    // Build one candidate line per record.
    let candidateLines = parsed.memories.enumerated().map { (i, mem) in
        buildPickCandidateLine(index: i + 1, memoryText: mem)
    }

    // Round 1: pick the best records.
    // If the full candidate list fits in the budget, one round; otherwise chunk.
    let fullR1Prompt = buildPickRound1Prompt(question: question, candidateLines: candidateLines, pickK: pickK)
    let fullR1Tokens = appleAnswerEstimateTokens(fullR1Prompt)

    var rawPicks: [Int] = []

    if fullR1Tokens <= roundBudget {
        // Single pick round.
        if fullR1Tokens > maxRoundTokens { maxRoundTokens = fullR1Tokens }
        rounds += 1
        // 100 response tokens: the pick list is a handful of comma-separated
        // integers, so this cap holds ~20 indices with room to spare while
        // stopping the model from writing prose instead of a list.
        let pr = try await generatePickList(prompt: fullR1Prompt, maxTokens: 100)
        rawPicks = pr.picks
    } else {
        // Candidate list too large: chunk and run one round-1 per chunk.
        let chunks = buildPickCandidateChunks(
            candidateLines: candidateLines,
            question: question,
            pickK: pickK,
            roundBudget: roundBudget)
        fputs("apple-answer: pick_rounds=\(chunks.count)\n", stderr)
        // SAFETY: candidateLines carry global 1-based labels so the model
        // returns global indices.  resolveChunkedPickIndices validates each
        // returned value against totalCount — no offset arithmetic needed.
        for chunk in chunks {
            let chunkPrompt = buildPickRound1Prompt(
                question: question, candidateLines: chunk, pickK: pickK)
            let ct = appleAnswerEstimateTokens(chunkPrompt)
            if ct > maxRoundTokens { maxRoundTokens = ct }
            rounds += 1
            let pr = try await generatePickList(prompt: chunkPrompt, maxTokens: 100)
            rawPicks += resolveChunkedPickIndices(rawPicks: pr.picks, totalCount: totalCount)
        }
    }

    // Clamp, dedup, and limit to pickK.
    let picks = clampAndDedupPicks(picks: rawPicks, pickK: pickK, totalCount: totalCount)

    // Build the distilled body for each picked record (header line + body).
    // The body text is what round 2 "hydrates" to answer the question.
    let bodyTexts: [String] = picks.map { idx in
        let mem = parsed.memories[idx - 1]  // picks are 1-based
        let (headerLine, body) = parsePickMemory(mem)
        let combined = (headerLine + "\n" + body).trimmingCharacters(in: .whitespacesAndNewlines)
        return combined.isEmpty ? mem : combined
    }

    // Round 2: drop picks from the tail if the answer prompt would overflow the budget.
    var fittedBodyTexts = bodyTexts
    var fittedPicks = picks
    let dropped = dropPicksForRoundBudget(
        pickedBodyTexts: bodyTexts, question: question, roundBudget: roundBudget)
    if dropped > 0 {
        fittedBodyTexts = Array(bodyTexts.dropLast(dropped))
        fittedPicks = Array(picks.dropLast(dropped))
        fputs("apple-answer: dropped=\(dropped)\n", stderr)
    }

    let round2Prompt = buildPickRound2Prompt(question: question, pickedMemories: fittedBodyTexts)
    let r2Tokens = appleAnswerEstimateTokens(round2Prompt)
    if r2Tokens > maxRoundTokens { maxRoundTokens = r2Tokens }
    rounds += 1

    // Emit the pick-mode summary line.
    var summaryLine = appleAnswerPickStderrLine(
        picks: fittedPicks, rounds: rounds, maxRoundTokens: maxRoundTokens)

    if guided {
        let ga = try await generateGuidedAppleAnswer(prompt: round2Prompt, maxTokens: maxTokens)
        summaryLine += " guided=1 evidence=\(ga.evidence_ids.count) abstain=\(ga.abstain ? 1 : 0)"
        fputs(summaryLine + "\n", stderr)
        return ga.abstain ? "I don't know." : ga.answer
    } else {
        fputs(summaryLine + "\n", stderr)
        return try await generateAppleAnswer(prompt: round2Prompt, maxTokens: maxTokens)
    }
}
#endif

// MARK: - Map-reduce and refine runners (FoundationModels only)

#if canImport(FoundationModels)

/// Runs the map-reduce reader recipe.
///
/// Splits `prompt` on its numbered memory boundaries into chunks that each fit
/// within `roundBudget` tokens. Each chunk produces a note (map round, capped
/// at `noteCap` response tokens). The notes are combined into a final answer
/// (reduce round, capped at `maxTokens`).
///
/// If the combined notes themselves would exceed `roundBudget`, a single level
/// of pairwise note reduction is applied: adjacent note pairs are merged first,
/// then the reduced list is combined into the answer.
///
/// Falls back to single-shot when the prompt layout is not recognised (no
/// numbered memory lines found), logging `layout=unknown` on stderr.
@available(macOS 26.0, iOS 26.0, *)
private func runAppleAnswerMapReduce(
    prompt: String,
    contextTokens: Int,
    roundBudget: Int,
    noteCap: Int,
    maxTokens: Int
) async throws -> String {
    guard let parsed = parseReaderPrompt(prompt) else {
        // Unknown layout: fall back to single-shot.
        fputs("apple-answer: layout=unknown falling back to single-shot\n", stderr)
        let tokenCount = appleAnswerEstimateTokens(prompt)
        let summaryLine = appleAnswerStderrLine(
            mode: "map-reduce", rounds: 1, chunks: 1, maxRoundTokens: tokenCount)
        fputs(summaryLine + "\n", stderr)
        return try await generateAppleAnswer(prompt: prompt, maxTokens: maxTokens)
    }

    let question = extractQuestion(fromFooter: parsed.footer)
    let chunks = buildMemoryChunks(
        memories: parsed.memories,
        header: parsed.header,
        footer: parsed.footer,
        roundBudget: roundBudget)

    // Map phase: one note per chunk.
    var notes: [String] = []
    var maxRoundTokens = 0
    var rounds = 0

    for chunk in chunks {
        let roundPrompt = buildMapRoundPrompt(
            header: parsed.header, memories: chunk, footer: parsed.footer)
        let roundTokens = appleAnswerEstimateTokens(roundPrompt)
        if roundTokens > maxRoundTokens { maxRoundTokens = roundTokens }
        rounds += 1
        let note = try await generateAppleAnswer(prompt: roundPrompt, maxTokens: noteCap)
        notes.append(note.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // Pairwise reduction when notes overflow the round budget (one level).
    let finalCandidate = buildMapReduceFinalPrompt(question: question, notes: notes)
    if appleAnswerEstimateTokens(finalCandidate) > roundBudget, notes.count > 1 {
        fputs("apple-answer: notes-overflow=true applying pairwise note reduction\n", stderr)
        var reducedNotes: [String] = []
        var i = 0
        while i < notes.count {
            if i + 1 < notes.count {
                let pairPrompt = buildMapReduceFinalPrompt(
                    question: question, notes: [notes[i], notes[i + 1]])
                rounds += 1
                let merged = try await generateAppleAnswer(
                    prompt: pairPrompt, maxTokens: noteCap)
                reducedNotes.append(merged.trimmingCharacters(in: .whitespacesAndNewlines))
                i += 2
            } else {
                reducedNotes.append(notes[i])
                i += 1
            }
        }
        notes = reducedNotes
    }

    // Reduce phase: combine all notes into the final answer.
    let reducePrompt = buildMapReduceFinalPrompt(question: question, notes: notes)
    let reduceTokens = appleAnswerEstimateTokens(reducePrompt)
    if reduceTokens > maxRoundTokens { maxRoundTokens = reduceTokens }
    rounds += 1
    let answer = try await generateAppleAnswer(prompt: reducePrompt, maxTokens: maxTokens)

    let summaryLine = appleAnswerStderrLine(
        mode: "map-reduce", rounds: rounds, chunks: chunks.count,
        maxRoundTokens: maxRoundTokens)
    fputs(summaryLine + "\n", stderr)

    return answer.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Runs the refine reader recipe.
///
/// Round 1: question + first chunk → draft (capped at `noteCap` response tokens).
/// Each subsequent round: question + draft + next chunk → revised draft.
/// Last round uses `maxTokens` instead of `noteCap` so the final draft can be
/// as long as needed.
///
/// If adding the next chunk would push the round prompt over `roundBudget` while
/// a draft already exists, the current draft is emitted as the final answer and
/// remaining chunks are skipped (`draft-overflow=true` on stderr).
///
/// Falls back to single-shot when the prompt layout is not recognised.
@available(macOS 26.0, iOS 26.0, *)
private func runAppleAnswerRefine(
    prompt: String,
    contextTokens: Int,
    roundBudget: Int,
    noteCap: Int,
    maxTokens: Int
) async throws -> String {
    guard let parsed = parseReaderPrompt(prompt) else {
        // Unknown layout: fall back to single-shot.
        fputs("apple-answer: layout=unknown falling back to single-shot\n", stderr)
        let tokenCount = appleAnswerEstimateTokens(prompt)
        let summaryLine = appleAnswerStderrLine(
            mode: "refine", rounds: 1, chunks: 1, maxRoundTokens: tokenCount)
        fputs(summaryLine + "\n", stderr)
        return try await generateAppleAnswer(prompt: prompt, maxTokens: maxTokens)
    }

    let question = extractQuestion(fromFooter: parsed.footer)
    let chunks = buildMemoryChunks(
        memories: parsed.memories,
        header: parsed.header,
        footer: parsed.footer,
        roundBudget: roundBudget)

    var draft = ""
    var maxRoundTokens = 0
    var rounds = 0
    var draftOverflow = false

    for (idx, chunk) in chunks.enumerated() {
        let isLast = idx == chunks.count - 1
        let responseCap = isLast ? maxTokens : noteCap

        let roundPrompt: String
        if idx == 0 {
            // First round: use the original prompt layout.
            roundPrompt = buildRefineRound1Prompt(
                header: parsed.header, memories: chunk, footer: parsed.footer)
        } else {
            // Subsequent rounds: include the draft accumulated so far.
            let candidate = buildRefineContinuationPrompt(
                question: question, draft: draft, memories: chunk)
            let candidateTokens = appleAnswerEstimateTokens(candidate)
            if candidateTokens > roundBudget {
                // Draft too large to fit with next chunk — stop and emit current draft.
                fputs("apple-answer: draft-overflow=true stopping at chunk \(idx + 1) of \(chunks.count)\n",
                      stderr)
                draftOverflow = true
                break
            }
            roundPrompt = candidate
        }

        let roundTokens = appleAnswerEstimateTokens(roundPrompt)
        if roundTokens > maxRoundTokens { maxRoundTokens = roundTokens }
        rounds += 1
        draft = try await generateAppleAnswer(prompt: roundPrompt, maxTokens: responseCap)
        draft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    _ = draftOverflow  // reported via stderr already

    let summaryLine = appleAnswerStderrLine(
        mode: "refine", rounds: rounds, chunks: chunks.count,
        maxRoundTokens: maxRoundTokens)
    fputs(summaryLine + "\n", stderr)

    return draft
}

#endif

// MARK: - Availability probe (for tests)

/// Returns true when the Apple Foundation Models engine is available on this
/// system at runtime.
///
/// Tests call this to decide whether to skip model-dependent assertions. It is
/// the same availability check `runAppleAnswer` performs before generation.
public func appleAnswerEngineAvailable() -> Bool {
    #if canImport(FoundationModels)
    guard #available(macOS 26.0, iOS 26.0, *) else { return false }
    return SystemLanguageModel.default.availability == .available
    #else
    return false
    #endif
}
