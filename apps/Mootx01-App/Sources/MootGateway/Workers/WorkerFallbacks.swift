import Foundation

// MARK: - Fallback output types and default values
//
// All fallback values are deterministic (no random, no Date.now). The
// fallback path MUST NOT call any MootToolCalling verb — it is the path
// taken when Apple Intelligence is unavailable and must succeed with zero
// external dependencies.

/// Fallback factory — one method per worker. Kept here so the three worker
/// files contain only model-path logic and remain easy to audit.
enum WorkerFallbacks {

    /// SummarizeWorker fallback: returns a suggestion indicating no summary
    /// is available without Apple Intelligence.
    static func summarize(input: SummarizeInput) -> SummarySuggestion {
        SummarySuggestion(
            summary: String(localized: "Apple Intelligence is not available. Enable it in System Settings to see AI-generated summaries of your recent work.")
        )
    }

    /// ExtractFactsWorker fallback: returns an empty triple set. No partial
    /// or fabricated facts — callers treat an empty result as "nothing to review".
    static func extractFacts(input: ExtractFactsInput) -> ExtractFactsResult {
        ExtractFactsResult(triples: [])
    }

    /// ClassifyWorker fallback: returns an empty classification so callers
    /// present no suggestion rather than a wrong one.
    static func classify(input: ClassifyInput) -> ClassificationSuggestion {
        ClassificationSuggestion(suggestedRoom: "", suggestedTags: [])
    }
}
