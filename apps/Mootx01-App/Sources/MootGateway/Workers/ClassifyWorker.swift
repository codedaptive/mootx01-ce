import Foundation
import FoundationModels
import MootIntentKit

// MARK: - Output type

/// Typed room-and-tag suggestion produced by ClassifyWorker.
@Generable(description: "A suggested room label and tags for a memory entry.")
public struct ClassificationSuggestion: Sendable {
    @Guide(description: "Single lowercase room label (e.g. work, health, engineering, personal).")
    public var suggestedRoom: String

    @Guide(description: "One to four lowercase keyword tags describing the specific topic.")
    public var suggestedTags: [String]

    public init(suggestedRoom: String, suggestedTags: [String]) {
        self.suggestedRoom = suggestedRoom
        self.suggestedTags = suggestedTags
    }
}

// MARK: - Input type

/// Parameters for a classification run.
public struct ClassifyInput: Sendable {
    /// Text content of the memory entry to classify.
    public let content: String

    public init(content: String) {
        self.content = content
    }
}

// MARK: - Worker

/// Suggests a room label and tags for a given memory entry using Apple
/// Intelligence. Accepts the content directly (no estate query required).
/// Never calls mutation verbs; output is a suggestion handed to the caller.
public struct ClassifyWorker: MootWorker {

    public static var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    public init() {}

    public func run(input: ClassifyInput, caller: any MootToolCalling) async throws -> ClassificationSuggestion {
        let session = LanguageModelSession {
            Instructions(WorkerPrompts.classifySystem + "\n\nMemory content:\n" + input.content)
        }
        let response = try await session.respond(
            to: "Suggest a room and tags for this memory entry.",
            generating: ClassificationSuggestion.self
        )
        return response.content
    }

    public func fallback(input: ClassifyInput) -> ClassificationSuggestion {
        WorkerFallbacks.classify(input: input)
    }
}
