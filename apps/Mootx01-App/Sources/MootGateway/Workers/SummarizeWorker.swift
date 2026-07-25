import Foundation
import FoundationModels
import MootIntentKit

// MARK: - Output type

/// Typed suggestion produced by SummarizeWorker. @Generable lets
/// LanguageModelSession produce this as structured output.
@Generable(description: "A suggested summary of recent work visible in the memory estate.")
public struct SummarySuggestion: Sendable {
    @Guide(description: "Two to five sentences covering the main themes and recent activity.")
    public var summary: String

    public init(summary: String) {
        self.summary = summary
    }
}

// MARK: - Input type

/// Parameters for a summarization run.
public struct SummarizeInput: Sendable {
    /// Query sent to moot_memory_search to pull relevant drawers.
    public let query: String
    /// Maximum drawers to sample (capped at 20 by the tool).
    public let limit: Int

    public init(query: String = "recent work", limit: Int = 10) {
        self.query = query
        self.limit = limit
    }
}

// MARK: - Worker

/// Summarizes recent estate activity using Apple Intelligence. Reads drawers
/// via moot_memory_search and returns a typed SummarySuggestion.
/// Never calls mutation verbs; output is a suggestion handed to the caller.
public struct SummarizeWorker: MootWorker {

    public static var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    public init() {}

    public func run(input: SummarizeInput, caller: any MootToolCalling) async throws -> SummarySuggestion {
        let result = await caller.callTool("moot_memory_search", arguments: [
            "query": .string(input.query),
            "limit": .integer(Int64(input.limit)),
        ])
        let context = result.isError ? "(no estate content available)" : result.text

        let session = LanguageModelSession {
            Instructions(WorkerPrompts.summarizeSystem + "\n\nEstate content:\n" + context)
        }
        let response = try await session.respond(to: "Summarize the recent work.", generating: SummarySuggestion.self)
        return response.content
    }

    public func fallback(input: SummarizeInput) -> SummarySuggestion {
        WorkerFallbacks.summarize(input: input)
    }
}
