// MiniLLMSubjectProducer.swift
//
// The Apple miniLLM subject rider (PR-10) — the sanctioned miniLLM
// future feature's first landing, single-function by doctrine: it
// produces SUBJECTS ONLY (no distillation, no answering). Built on the
// first-party on-device Foundation Models surface per the Apple-first
// ruling (migrate-when-able posture if the API tier shifts); zero
// vendor SDKs — the BYOAI posture holds.
//
// Apple-only and OPT-IN: nothing registers this producer automatically
// (the tagger precedent — an Apple capability is selectable, never
// silently mandatory). The host surfaces a setting and calls
// `enableAppleSubjectRider(for:)`; the PR-09 dark-default tests pin
// that the lane stays off otherwise. The Rust lane remains dark
// awaiting a model.
//
// Trust ladder (PR-10 ruling): ai-v1 rows are NEVER overwritten — the
// filing AI outranks the fallback model, enforced structurally by the
// regeneration list (only the deterministic tiers consolidation-v1 and
// seed-v1, plus NULL rows, ever enumerate for this producer).
//
// Safety net: the sweep's SubjectRegister gate remains the final
// arbiter — inadmissible model output is skipped, never stored, so a
// misbehaving model degrades to a no-op, not damage.

import Foundation
import LocusKit

#if canImport(FoundationModels)
import FoundationModels

/// On-device subject producer over Apple's Foundation Models.
@available(macOS 26.0, iOS 26.0, *)
public struct MiniLLMSubjectProducer: SubjectProducer {

    /// Provenance tier for every subject this producer writes.
    public let pipelineVersion = DrawerStore.subjectPipelineMiniLLMV1

    /// Regenerates the deterministic tiers only — never ai-v1 (the
    /// filing AI outranks this fallback model), never its own tier
    /// (settled work).
    public let regeneratesPipelines = ["consolidation-v1", "seed-v1"]

    /// Instruction block implementing the PR-09 register contract.
    /// Subjects are AI-facing by design ruling (not UI-visible text),
    /// so no target-locale parameter applies here.
    static let registerInstructions = """
        You write one-line subjects for a memory system. For the text \
        the user provides, reply with EXACTLY ONE sentence of at most \
        120 characters stating what the text asserts. Telegraphic \
        register: entities and claims first, no narrative framing, no \
        preamble like "This is" or "Note:", no quotation marks around \
        the whole line, no trailing ellipsis. Reply with the sentence \
        only.
        """

    /// True when the on-device model is present and ready. The
    /// enablement API refuses when this is false so the setting surface
    /// can explain WHY the rider cannot turn on.
    public static var isModelAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    public init() {}

    public func subject(forContent content: String) async throws -> String {
        // Bound the prompt: subjects summarise the assertion, and the
        // opening of a drawer carries it in practice; a full 100KB blob
        // would waste the on-device budget.
        let prompt = String(content.prefix(2000))
        let session = LanguageModelSession(instructions: Self.registerInstructions)
        var candidate = Self.postProcess(try await session.respond(to: prompt).content)
        // ONE bounded retry on over-length: re-ask with the cap
        // restated. If the model still overruns, return the long form —
        // the sweep's register gate skips it (never stored) and the row
        // stays debt for a later pass.
        if candidate.count > DrawerStore.subjectLengthContract {
            let retry = try await session.respond(
                to: "Too long. Compress to at most 120 characters, one sentence, same claim.")
            candidate = Self.postProcess(retry.content)
        }
        return candidate
    }

    /// Deterministic post-pass: collapse to a single trimmed line and
    /// strip symmetric wrapping quotes the model sometimes adds. Never
    /// truncates — length is the model's job, admission is the gate's.
    static func postProcess(_ raw: String) -> String {
        var line = raw
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("\""), line.hasSuffix("\""), line.count >= 2 {
            line = String(line.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return line
    }
}
#endif

extension GeniusLocusKit {

    /// User-settable enablement of the Apple subject rider (PR-10, the
    /// tagger precedent): the HOST calls this when — and only when —
    /// the user turns the setting on. Throws when the platform or the
    /// on-device model is unavailable, with a reason the setting
    /// surface can show. Never called automatically anywhere.
    public func enableAppleSubjectRider(for handle: EstateHandle) throws {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, iOS 26.0, *) else {
            throw GeniusLocusKitError.underlyingEstateFailure(
                reason: "Apple subject rider requires macOS 26 / iOS 26")
        }
        guard MiniLLMSubjectProducer.isModelAvailable else {
            throw GeniusLocusKitError.underlyingEstateFailure(
                reason: "Apple subject rider: on-device model unavailable "
                    + "(Apple Intelligence disabled or model not downloaded)")
        }
        try registerSubjectProducer(MiniLLMSubjectProducer(), for: handle)
        #else
        throw GeniusLocusKitError.underlyingEstateFailure(
            reason: "Apple subject rider is unavailable on this platform "
                + "(FoundationModels framework absent); the Rust lane stays "
                + "dark awaiting a model")
        #endif
    }
}
