import Foundation
import FoundationModels
import MootIntentKit

// MARK: - Output types

/// A candidate KG triple extracted from estate content. The isProposed flag
/// is immutably true — every triple this worker produces is a proposal for
/// human review and is NEVER automatically filed to the estate.
public struct ProposedTriple: Sendable, Equatable {
    public let subject: String
    public let predicate: String
    public let object: String
    /// Invariant: always true. Enforced at construction; the property is
    /// private(set) so external callers cannot clear the PROPOSED mark.
    public private(set) var isProposed: Bool

    public init(subject: String, predicate: String, object: String) {
        self.subject = subject
        self.predicate = predicate
        self.object = object
        self.isProposed = true
    }
}

/// Container for the triples produced in one ExtractFacts run.
public struct ExtractFactsResult: Sendable {
    public let triples: [ProposedTriple]

    public init(triples: [ProposedTriple]) {
        self.triples = triples
    }
}

/// Structured extraction output. @Generable yields one triple per generation.
/// Callers collect one per request; batching is handled by the caller, not
/// the model, to keep prompts deterministic.
@Generable(description: "One factual subject-predicate-object triple extracted from estate content.")
public struct ExtractedTripleSuggestion: Sendable {
    @Guide(description: "Named entity or concept that the fact is about.")
    public var subject: String

    @Guide(description: "Relationship or property linking subject to object.")
    public var predicate: String

    @Guide(description: "Value, entity, or concept that the predicate points to.")
    public var object: String

    public init(subject: String, predicate: String, object: String) {
        self.subject = subject
        self.predicate = predicate
        self.object = object
    }
}

// MARK: - Input type

/// Parameters for a fact-extraction run.
public struct ExtractFactsInput: Sendable {
    /// Query sent to moot_memory_search to pull candidate drawers.
    public let query: String
    /// Maximum drawers to sample.
    public let limit: Int

    public init(query: String = "facts people decisions", limit: Int = 15) {
        self.query = query
        self.limit = limit
    }
}

// MARK: - Worker

/// Extracts facts and named entities from estate content as PROPOSED KG
/// triples. Every triple is marked isProposed = true at construction.
/// Never calls mutation verbs; the caller decides whether to review and file.
public struct ExtractFactsWorker: MootWorker {

    public static var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    public init() {}

    public func run(input: ExtractFactsInput, caller: any MootToolCalling) async throws -> ExtractFactsResult {
        let result = await caller.callTool("moot_memory_search", arguments: [
            "query": .string(input.query),
            "limit": .integer(Int64(input.limit)),
        ])
        let context = result.isError ? "(no estate content available)" : result.text

        let session = LanguageModelSession {
            Instructions(WorkerPrompts.extractFactsSystem + "\n\nEstate content:\n" + context)
        }
        let response = try await session.respond(
            to: "Extract the most significant factual triple.",
            generating: ExtractedTripleSuggestion.self
        )
        let suggestion = response.content
        // ProposedTriple.init always stamps isProposed = true — the PROPOSED
        // invariant cannot be cleared by the model output path.
        let triple = ProposedTriple(
            subject: suggestion.subject,
            predicate: suggestion.predicate,
            object: suggestion.object
        )
        return ExtractFactsResult(triples: [triple])
    }

    public func fallback(input: ExtractFactsInput) -> ExtractFactsResult {
        WorkerFallbacks.extractFacts(input: input)
    }
}
