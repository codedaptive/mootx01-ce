import Foundation
import FoundationModels
import MootIntentKit

// MARK: - MootWorker protocol
//
// Tier-3 read-only worker layer over FoundationModels. Workers read estate
// content through the MootToolCalling caller and return typed suggestions.
// They NEVER call mutation verbs (moot_file_memory, moot_file_fact, etc.).
// Every worker provides a deterministic fallback for when Apple Intelligence
// is unavailable — the UI layer always calls runSafe(), not run() directly.

public protocol MootWorker: Sendable {
    associatedtype Input: Sendable
    associatedtype Output: Sendable

    /// True when Apple Intelligence is available and the worker can run the
    /// model path. Callers use runSafe() which gates on this automatically.
    static var isAvailable: Bool { get }

    /// Run the worker against estate content read via `caller`. Throws on
    /// unrecoverable errors; the UI layer calls runSafe() instead.
    func run(input: Input, caller: any MootToolCalling) async throws -> Output

    /// Deterministic result when Apple Intelligence is unavailable or run()
    /// throws. Must always succeed and never throw.
    func fallback(input: Input) -> Output
}

extension MootWorker {
    /// Safe entry point: returns the model result if Apple Intelligence is
    /// available, or the deterministic fallback if it is not (or if run()
    /// throws). The UI layer always calls this; it never receives a thrown error.
    public func runSafe(input: Input, caller: any MootToolCalling) async -> Output {
        guard Self.isAvailable else { return fallback(input: input) }
        do {
            return try await run(input: input, caller: caller)
        } catch {
            return fallback(input: input)
        }
    }
}

// MARK: - Prompt templates (typed constants)

/// Static prompt templates used by all three workers. Defined once here so
/// they are easy to audit and update without touching worker logic.
enum WorkerPrompts {
    /// Instructions for the SummarizeWorker session.
    static let summarizeSystem = """
    You are summarizing work visible in a user's private memory estate.
    Write 2-5 sentences covering the main themes and recent activity.
    Do not invent facts that are absent from the provided estate content.
    """

    /// Instructions for the ExtractFactsWorker session.
    static let extractFactsSystem = """
    You are extracting one factual subject-predicate-object triple from \
    memory estate content. The subject and object must be named entities \
    or concrete values — not generic terms. This triple is a PROPOSED \
    candidate for human review and is never automatically filed to the estate.
    """

    /// Instructions for the ClassifyWorker session.
    static let classifySystem = """
    You are classifying a memory entry to suggest its best room label and \
    relevant tags. Room must be a single lowercase word \
    (examples: work, health, engineering, personal, finance). \
    Tags must be 1-4 lowercase keywords describing the specific topic.
    """
}
