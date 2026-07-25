import Foundation
import FoundationModels
import MootIntentKit

// MARK: - CompareWorker  (two research bodies in, a preserved disagreement out)
//
// Takes two bounded bodies of research — two model answers to the same question,
// two drafts, two readings of the same estate — and returns where they agree,
// where they do not, and what a synthesis could say.
//
// The load-bearing property is structural, not stylistic: a disagreement CANNOT
// be dissolved by this type. Three mechanisms enforce it, all in
// `CompareResult.init` so no construction path can skip them:
//
//  1. Topic collision resolves to disagreement. If the same topic arrives in both
//     `agreements` and `disagreements`, the agreement is dropped. A model that
//     lists a contested topic as agreed cannot make it agreed here.
//  2. Both positions always survive. A disagreement with a missing side keeps the
//     side it has and marks the other `unstatedPosition` — the conflict stays on
//     the record instead of being discarded for being half-stated.
//  3. Silence is never agreement. A result with no agreements AND no
//     disagreements always carries a `notice` explaining why nothing was
//     compared, so an empty result cannot read as "the two bodies matched".
//
// Input shape note: `ResearchBody` is deliberately plain — a label, text, and
// optional reference strings. A Work Packet's body and id fit it without this
// file knowing that WorkPacketKit exists, and nothing here depends on it.

// MARK: - Input types

/// One side of a comparison: where the text came from, and the text.
public struct ResearchBody: Sendable, Equatable {
    /// Display label for this side ("Claude", "GPT-5", "draft-2", a packet id).
    /// Carried into every claim so a reader always knows who said what.
    public let label: String
    /// The research text itself. Bounded by the caller.
    public let text: String
    /// Optional provenance strings the caller already holds (drawer ids, packet
    /// ids, URLs). Carried through untouched for the caller's own audit trail.
    public let references: [String]

    public init(label: String, text: String, references: [String] = []) {
        self.label = label
        self.text = text
        self.references = references
    }
}

/// Parameters for one comparison run.
public struct CompareInput: Sendable {
    public let left: ResearchBody
    public let right: ResearchBody
    /// Upper bound on claims requested per category. Bounds the prompt and the
    /// output; the comparison is a reading aid, not an exhaustive diff.
    public let maxClaims: Int

    public init(left: ResearchBody, right: ResearchBody, maxClaims: Int = 6) {
        self.left = left
        self.right = right
        self.maxClaims = maxClaims
    }
}

// MARK: - Output types

/// A claim both bodies make.
public struct ComparedClaim: Sendable, Equatable, Identifiable {
    /// `agreement:<ordinal>` — stable within one result.
    public let id: String
    /// Normalized subject of the claim. Collision with a disagreement topic is
    /// detected on this field, case- and whitespace-insensitively.
    public let topic: String
    /// The agreed statement, in the comparison's own words.
    public let statement: String
    /// Labels of the bodies that support it.
    public let supportedBy: [String]

    public init(id: String, topic: String, statement: String, supportedBy: [String]) {
        self.id = id
        self.topic = topic
        self.statement = statement
        self.supportedBy = supportedBy
    }
}

/// A topic the two bodies do not agree on. Both sides are always present.
public struct Disagreement: Sendable, Equatable, Identifiable {
    /// `disagreement:<ordinal>` — stable within one result, and the id a
    /// synthesis candidate acknowledges.
    public let id: String
    /// Normalized subject of the dispute.
    public let topic: String
    /// Label of the body holding `leftPosition`.
    public let leftLabel: String
    /// Label of the body holding `rightPosition`.
    public let rightLabel: String
    /// What the left body says. Never empty — see `CompareWorker.unstatedPosition`.
    public let leftPosition: String
    /// What the right body says. Never empty.
    public let rightPosition: String

    public init(
        id: String,
        topic: String,
        leftLabel: String,
        rightLabel: String,
        leftPosition: String,
        rightPosition: String
    ) {
        self.id = id
        self.topic = topic
        self.leftLabel = leftLabel
        self.rightLabel = rightLabel
        // A half-stated conflict is still a conflict. Substituting a marker keeps
        // the row; dropping it would quietly turn a disagreement into agreement.
        self.leftPosition = leftPosition.isEmpty ? CompareWorker.unstatedPosition : leftPosition
        self.rightPosition = rightPosition.isEmpty ? CompareWorker.unstatedPosition : rightPosition
    }
}

/// A statement a reader could take forward, with the conflicts it does not
/// settle named explicitly.
public struct SynthesisCandidate: Sendable, Equatable, Identifiable {
    /// `synthesis:<ordinal>` — stable within one result.
    public let id: String
    /// The candidate statement. A CANDIDATE: nothing here decides anything.
    public let statement: String
    /// Ids of the disagreements this candidate is written in awareness of.
    /// Acknowledging a disagreement does not resolve it — it records that the
    /// statement was written knowing the conflict exists.
    public let acknowledgedDisagreementIDs: [String]

    public init(id: String, statement: String, acknowledgedDisagreementIDs: [String]) {
        self.id = id
        self.statement = statement
        self.acknowledgedDisagreementIDs = acknowledgedDisagreementIDs
    }
}

/// The comparison. See the file header for the three preservation mechanisms
/// this initializer enforces.
public struct CompareResult: Sendable, Equatable {
    public let leftLabel: String
    public let rightLabel: String
    /// Claims both bodies make. Never contains a topic that also appears in
    /// `disagreements`.
    public let agreements: [ComparedClaim]
    /// Every conflict found, both sides intact. Nothing removes an entry here.
    public let disagreements: [Disagreement]
    /// Statements a reader could take forward, each naming the conflicts it was
    /// written in awareness of.
    public let synthesisCandidates: [SynthesisCandidate]
    /// Why the comparison is thin or empty, when it is. Always present when
    /// neither agreements nor disagreements were found.
    public let notice: String?

    public init(
        leftLabel: String,
        rightLabel: String,
        agreements: [ComparedClaim],
        disagreements: [Disagreement],
        synthesisCandidates: [SynthesisCandidate],
        notice: String? = nil
    ) {
        self.leftLabel = leftLabel
        self.rightLabel = rightLabel
        self.disagreements = disagreements

        // Mechanism 1: a contested topic can never be listed as agreed.
        let contested = Set(disagreements.map { CompareResult.normalize($0.topic) })
        self.agreements = agreements.filter { !contested.contains(CompareResult.normalize($0.topic)) }

        // A candidate may only acknowledge disagreements that exist in this
        // result; an id that names nothing would read as coverage it does not have.
        let realIDs = Set(disagreements.map(\.id))
        self.synthesisCandidates = synthesisCandidates.map { candidate in
            SynthesisCandidate(
                id: candidate.id,
                statement: candidate.statement,
                acknowledgedDisagreementIDs: candidate.acknowledgedDisagreementIDs
                    .filter { realIDs.contains($0) }
            )
        }

        // Mechanism 3: an empty comparison explains itself, so silence is never
        // read as agreement. Same "honest emptiness" discipline the review
        // sections follow.
        if let notice {
            self.notice = notice
        } else if self.agreements.isEmpty && disagreements.isEmpty {
            self.notice = String(
                localized: "worker.compare.notice.nothingCompared",
                defaultValue: "No claim-level comparison was made — this is not a finding of agreement."
            )
        } else {
            self.notice = nil
        }
    }

    /// Disagreements no synthesis candidate acknowledges. A non-empty list means
    /// the synthesis is silent about a live conflict — surfaced rather than
    /// smoothed over.
    public var unacknowledgedDisagreements: [Disagreement] {
        let acknowledged = Set(synthesisCandidates.flatMap(\.acknowledgedDisagreementIDs))
        return disagreements.filter { !acknowledged.contains($0.id) }
    }

    /// Topic comparison key: case-folded and trimmed, so "Latency" and " latency "
    /// are the same topic for collision purposes.
    static func normalize(_ topic: String) -> String {
        topic.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

// MARK: - Generable suggestion shapes

/// One claim both bodies make, as the model reports it.
@Generable(description: "A claim that both research bodies make.")
public struct AgreementSuggestion: Sendable {
    @Guide(description: "Short subject of the claim, two to five words.")
    public var topic: String

    @Guide(description: "The agreed claim in one sentence.")
    public var statement: String

    public init(topic: String, statement: String) {
        self.topic = topic
        self.statement = statement
    }
}

/// One conflict, as the model reports it. Both position fields are requested
/// even when a body is silent, so the conflict survives with a marked gap.
@Generable(description: "A topic the two research bodies do not agree on.")
public struct DisagreementSuggestion: Sendable {
    @Guide(description: "Short subject of the dispute, two to five words.")
    public var topic: String

    @Guide(description: "What the FIRST body says about this topic. Empty only if it says nothing.")
    public var firstPosition: String

    @Guide(description: "What the SECOND body says about this topic. Empty only if it says nothing.")
    public var secondPosition: String

    public init(topic: String, firstPosition: String, secondPosition: String) {
        self.topic = topic
        self.firstPosition = firstPosition
        self.secondPosition = secondPosition
    }
}

/// One synthesis candidate, as the model reports it.
@Generable(description: "A statement a reader could take forward from both bodies.")
public struct SynthesisSuggestion: Sendable {
    @Guide(description: "The candidate statement in one or two sentences.")
    public var statement: String

    @Guide(description: "Subjects of the disputes this statement leaves open, using the same topic wording as the disagreements.")
    public var openTopics: [String]

    public init(statement: String, openTopics: [String]) {
        self.statement = statement
        self.openTopics = openTopics
    }
}

/// The full comparison as one generation. Requested in a single response so the
/// three lists are written against each other rather than in isolation — the
/// model cannot list a topic as agreed in one call and disputed in another.
@Generable(description: "A comparison of two research bodies: agreements, disagreements, and synthesis candidates.")
public struct CompareSuggestion: Sendable {
    @Guide(description: "Claims both bodies make.")
    public var agreements: [AgreementSuggestion]

    @Guide(description: "Topics the bodies conflict on. Never omit a conflict to make the comparison tidy.")
    public var disagreements: [DisagreementSuggestion]

    @Guide(description: "Statements a reader could take forward, each naming the disputes it leaves open.")
    public var synthesis: [SynthesisSuggestion]

    public init(
        agreements: [AgreementSuggestion],
        disagreements: [DisagreementSuggestion],
        synthesis: [SynthesisSuggestion]
    ) {
        self.agreements = agreements
        self.disagreements = disagreements
        self.synthesis = synthesis
    }
}

// MARK: - Prompt

extension WorkerPrompts {
    /// Instructions for the CompareWorker session.
    static let compareSystem = """
    You are comparing two bodies of research on the same question. Report where
    they agree, where they conflict, and what a synthesis could say.
    Preserving conflict is the point of this task: never present a contested
    topic as agreed, never drop a conflict because one side is vague, and never
    invent a claim that neither body makes. If a body is silent on a topic the
    other raises, say so by leaving that side's position empty rather than
    guessing what it would have said.
    """
}

// MARK: - Worker

/// Compares two bounded research bodies and returns agreement, disagreement, and
/// synthesis-candidate structure. Calls no tools — both bodies arrive as input.
public struct CompareWorker: MootWorker {

    /// Stands in for a side that says nothing about a topic the other side
    /// raises. Localized because it is read by a person in the comparison view.
    public static var unstatedPosition: String {
        String(
            localized: "worker.compare.position.unstated",
            defaultValue: "(no position stated in this body)"
        )
    }

    public static var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    public init() {}

    public func run(input: CompareInput, caller: any MootToolCalling) async throws -> CompareResult {
        let session = LanguageModelSession {
            Instructions(WorkerPrompts.compareSystem + "\n\n" + Self.bodyDigest(input))
        }
        let response = try await session.respond(
            to: "Compare the two bodies. List at most \(input.maxClaims) entries per category.",
            generating: CompareSuggestion.self
        )
        return Self.assemble(response.content, input: input)
    }

    /// Deterministic result: no claim-level comparison is possible without the
    /// model, so none is asserted. Zero agreements and an explaining notice —
    /// never an empty result that reads as "they matched".
    ///
    /// The notice names no single cause. This path is reached two ways — the model
    /// is unavailable, or `run()` threw — and the second one happens on real
    /// estate content: Apple's guardrail answers "May contain sensitive content"
    /// for some material, with Apple Intelligence fully available. A notice that
    /// blamed availability would be wrong exactly when a user checked Settings and
    /// found it switched on.
    public func fallback(input: CompareInput) -> CompareResult {
        CompareResult(
            leftLabel: input.left.label,
            rightLabel: input.right.label,
            agreements: [],
            disagreements: [],
            synthesisCandidates: [],
            notice: String(
                localized: "worker.compare.notice.notCompared",
                defaultValue: "The two bodies were not compared — the on-device model was unavailable or declined to answer. Their claims are neither agreed nor reconciled."
            )
        )
    }

    // MARK: Assembly

    /// Map a generated suggestion onto the result types. Ordinal-keyed ids are
    /// assigned here so `CompareResult` can match a synthesis candidate's open
    /// topics to real disagreement ids.
    static func assemble(_ suggestion: CompareSuggestion, input: CompareInput) -> CompareResult {
        let cap = max(0, input.maxClaims)

        let disagreements = suggestion.disagreements.prefix(cap).enumerated().map { ordinal, raw in
            Disagreement(
                id: "disagreement:\(ordinal)",
                topic: raw.topic,
                leftLabel: input.left.label,
                rightLabel: input.right.label,
                leftPosition: raw.firstPosition,
                rightPosition: raw.secondPosition
            )
        }

        let agreements = suggestion.agreements.prefix(cap).enumerated().map { ordinal, raw in
            ComparedClaim(
                id: "agreement:\(ordinal)",
                topic: raw.topic,
                statement: raw.statement,
                supportedBy: [input.left.label, input.right.label]
            )
        }

        // A candidate names its open disputes by topic wording; resolve those to
        // disagreement ids so the acknowledgement is checkable rather than prose.
        let idByTopic = Dictionary(
            disagreements.map { (CompareResult.normalize($0.topic), $0.id) },
            uniquingKeysWith: { first, _ in first }
        )
        let synthesis = suggestion.synthesis.prefix(cap).enumerated().map { ordinal, raw in
            SynthesisCandidate(
                id: "synthesis:\(ordinal)",
                statement: raw.statement,
                acknowledgedDisagreementIDs: raw.openTopics.compactMap {
                    idByTopic[CompareResult.normalize($0)]
                }
            )
        }

        return CompareResult(
            leftLabel: input.left.label,
            rightLabel: input.right.label,
            agreements: Array(agreements),
            disagreements: Array(disagreements),
            synthesisCandidates: Array(synthesis)
        )
    }

    /// Both bodies as prompt text, each labelled so the model can attribute a
    /// position to a side. Deterministic; the text is carried verbatim.
    static func bodyDigest(_ input: CompareInput) -> String {
        """
        FIRST BODY (\(input.left.label)):
        \(input.left.text)

        SECOND BODY (\(input.right.label)):
        \(input.right.text)
        """
    }
}
