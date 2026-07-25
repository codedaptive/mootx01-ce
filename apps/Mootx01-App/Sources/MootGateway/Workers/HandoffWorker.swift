import Foundation
import FoundationModels
import MootIntentKit

// MARK: - HandoffWorker  (estate context out to a frontier model, with citations)
//
// Drafts the message a user pastes into a frontier model when the on-device model
// has taken a question as far as it can. The draft's value is its provenance: a
// frontier model gets estate content it cannot see, and the user keeps a record
// of exactly which drawers left the machine.
//
// The citation guarantee is structural. `HandoffDraft.body` is ASSEMBLED by the
// initializer from the narrative plus a references block — there is no
// initializer that accepts a body, so no path exists that produces a draft whose
// text omits a reference it carries. The model writes prose; the worker writes
// the citations.
//
// Context selection is the caller's: pass `context` and the worker cites exactly
// those drawers. Pass none and it recalls `query` through `moot_memory_search`
// (a read verb) and cites what came back — parsed by `DrawerLineParser`, the
// intent layer's own parser for that response shape.

// MARK: - Context / reference type

/// One piece of estate context carried into a handoff, and cited by it.
public struct HandoffContextItem: Sendable, Equatable, Identifiable {
    /// The estate row this came from — a drawer id. Doubles as `Identifiable.id`
    /// so a view can list references without a synthetic key.
    public let subjectID: String
    /// The tool that produced it, by registered name. Recall-sourced items carry
    /// `moot_memory_search`; caller-selected items carry whatever the caller
    /// names, so a hand-picked drawer is distinguishable from a recalled one.
    public let source: String
    /// The content that will be shown to the frontier model. Estate data,
    /// verbatim — truncation is the caller's decision, not this worker's.
    public let excerpt: String

    public var id: String { subjectID }

    public init(subjectID: String, source: String, excerpt: String) {
        self.subjectID = subjectID
        self.source = source
        self.excerpt = excerpt
    }
}

// MARK: - Output type

/// A ready-to-paste handoff. `body` is derived, never supplied.
public struct HandoffDraft: Sendable, Equatable {
    /// What the user wants the frontier model to do. Carried verbatim.
    public let objective: String
    /// Label of the model this draft is addressed to. Display data from the caller.
    public let targetModel: String
    /// Situation paragraph — what the estate shows.
    public let background: String
    /// The request paragraph — what the frontier model is being asked for.
    public let ask: String
    /// Every estate row cited by `body`, in the order it is cited.
    public let references: [HandoffContextItem]
    /// The assembled message. Contains the objective, the background, the ask,
    /// and a references block naming every entry in `references`.
    public let body: String

    /// Assembles `body` from its parts. The absence of a body parameter is the
    /// citation guarantee: every reference is written into the text here, so a
    /// draft cannot carry a reference its body does not mention.
    public init(
        objective: String,
        targetModel: String,
        background: String,
        ask: String,
        references: [HandoffContextItem]
    ) {
        self.objective = objective
        self.targetModel = targetModel
        self.background = background
        self.ask = ask
        self.references = references
        self.body = HandoffDraft.assembleBody(
            objective: objective,
            background: background,
            ask: ask,
            references: references
        )
    }

    /// Section headings are localized; the estate content between them is not —
    /// it is data, carried as filed.
    static func assembleBody(
        objective: String,
        background: String,
        ask: String,
        references: [HandoffContextItem]
    ) -> String {
        var parts: [String] = [
            String(localized: "worker.handoff.section.objective", defaultValue: "Objective") + ": " + objective,
            String(localized: "worker.handoff.section.background", defaultValue: "Background") + ":\n" + background,
            String(localized: "worker.handoff.section.ask", defaultValue: "What I need") + ":\n" + ask,
        ]
        if references.isEmpty {
            // Stated, not implied: a handoff with no estate context is a
            // different thing from one whose citations went missing.
            parts.append(
                String(
                    localized: "worker.handoff.section.noReferences",
                    defaultValue: "Sources: no estate context was attached to this handoff."
                )
            )
        } else {
            let heading = String(localized: "worker.handoff.section.references", defaultValue: "Sources from my memory estate")
            let rows = references.map { "[\($0.subjectID)] (\($0.source)) \($0.excerpt)" }
            parts.append(heading + ":\n" + rows.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }
}

/// Generated prose for a handoff. The citations are not generated — see
/// `HandoffDraft.init`.
@Generable(description: "The prose of a handoff message to a more capable model.")
public struct HandoffNarrativeSuggestion: Sendable {
    @Guide(description: "Two to four sentences of situation: what the memory estate shows about this objective, referring to sources by their bracketed ids.")
    public var background: String

    @Guide(description: "One to three sentences stating precisely what the receiving model should produce.")
    public var ask: String

    public init(background: String, ask: String) {
        self.background = background
        self.ask = ask
    }
}

// MARK: - Input type

/// Parameters for one handoff draft.
public struct HandoffInput: Sendable {
    /// What the user wants done. The draft is built around this.
    public let objective: String
    /// Label of the receiving model, for the draft's own header.
    public let targetModel: String
    /// Caller-selected estate context. When non-empty it is used as given and no
    /// recall happens — selection stays the caller's decision.
    public let context: [HandoffContextItem]
    /// Recall query used only when `context` is empty. Defaults to the objective.
    public let query: String
    /// Maximum drawers to cite from recall.
    public let limit: Int

    public init(
        objective: String,
        targetModel: String = "frontier model",
        context: [HandoffContextItem] = [],
        query: String = "",
        limit: Int = 8
    ) {
        self.objective = objective
        self.targetModel = targetModel
        self.context = context
        // An empty query would recall the whole estate's top-of-ranking rather
        // than anything about this objective.
        self.query = query.isEmpty ? objective : query
        self.limit = limit
    }
}

// MARK: - Prompt

extension WorkerPrompts {
    /// Instructions for the HandoffWorker session.
    static let handoffSystem = """
    You are drafting a message that hands work from an on-device assistant to a
    more capable model. Write only the background and the request. Every factual
    claim about the user's material must come from the numbered sources below and
    must cite the source id in brackets, exactly as given. Do not invent a source
    id, do not describe material that is not in the sources, and do not restate
    the objective — it is already in the draft.
    """
}

// MARK: - Worker

/// Drafts a frontier-model handoff from selected estate context, with a
/// provenance reference for every drawer it carries.
public struct HandoffWorker: MootWorker {

    public static var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    public init() {}

    public func run(input: HandoffInput, caller: any MootToolCalling) async throws -> HandoffDraft {
        let references = await Self.resolveContext(input, caller: caller)
        let session = LanguageModelSession {
            Instructions(WorkerPrompts.handoffSystem + "\n\n" + Self.contextDigest(input, references: references))
        }
        let response = try await session.respond(
            to: "Write the background and the request for this handoff.",
            generating: HandoffNarrativeSuggestion.self
        )
        return HandoffDraft(
            objective: input.objective,
            targetModel: input.targetModel,
            background: response.content.background,
            ask: response.content.ask,
            references: references
        )
    }

    /// Deterministic draft. Prose is localized boilerplate; the caller-selected
    /// context still becomes citations, so the provenance guarantee holds on this
    /// path too. Recall is not attempted — the fallback path calls no tools.
    public func fallback(input: HandoffInput) -> HandoffDraft {
        HandoffDraft(
            objective: input.objective,
            targetModel: input.targetModel,
            background: String(
                localized: "worker.handoff.fallback.background",
                defaultValue: "Apple Intelligence is not available, so this draft was assembled without a written summary. The attached sources are the memory-estate material for this objective, quoted as filed."
            ),
            ask: String(
                localized: "worker.handoff.fallback.ask",
                defaultValue: "Read the sources below and address the objective above."
            ),
            references: input.context
        )
    }

    // MARK: Context resolution

    /// Caller-selected context wins. Otherwise recall `query` through
    /// `moot_memory_search` — a read verb — and cite the drawers it returns.
    /// A refusal or an unparseable response yields no references rather than a
    /// fabricated one; the draft then says so through its no-references line.
    static func resolveContext(_ input: HandoffInput, caller: any MootToolCalling) async -> [HandoffContextItem] {
        guard input.context.isEmpty else { return input.context }
        let result = await caller.callTool("moot_memory_search", arguments: [
            "query": .string(input.query),
            "limit": .integer(Int64(input.limit)),
        ])
        guard !result.isError else { return [] }
        // DrawerLineParser owns the `<uuid>  [room]  content` response shape for
        // the intent layer; reusing it keeps one parser for one format.
        return DrawerLineParser.parse(result.text).prefix(max(0, input.limit)).map { drawer in
            HandoffContextItem(
                subjectID: drawer.id,
                source: "moot_memory_search",
                excerpt: drawer.content
            )
        }
    }

    /// Objective plus numbered sources as prompt text. The ids given here are the
    /// only ids the model is allowed to cite.
    static func contextDigest(_ input: HandoffInput, references: [HandoffContextItem]) -> String {
        var lines = ["Objective: \(input.objective)", "", "Sources:"]
        if references.isEmpty {
            lines.append("(none — the estate returned no material for this objective)")
        } else {
            for reference in references {
                lines.append("[\(reference.subjectID)] \(reference.excerpt)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
