import Foundation
import FoundationModels
import MootIntentKit

// MARK: - ReviewPrepWorker  (narrates a built ReviewReport)
//
// The one worker that reads no estate surface of its own. Its input is an
// already-built `ReviewReport` — the report IS the estate read, performed by the
// Review builders, and re-querying here would pay for the same lens calls twice
// and could describe a different estate than the one the report shows.
//
// Two of the four fields on the output are computed from the report rather than
// generated: the cited surfaces and the item count. A narration may be wrong
// about emphasis; it must not be wrong about which tools produced the material
// or how much of it there was.

// MARK: - Output types

/// Where a brief's prose came from. An enum rather than an `isFallback` flag so
/// callers switch on provenance and so no boolean state exists on the value.
public enum ReviewBriefOrigin: String, Sendable, Equatable, CaseIterable {
    /// Prose written by Apple Intelligence from the report digest.
    case model
    /// Prose assembled deterministically from the report itself.
    case deterministic
}

/// The narrated form of one `ReviewReport`.
public struct ReviewBrief: Sendable, Equatable {
    /// One-line framing of the review.
    public let headline: String
    /// The brief itself — a few sentences a person reads over coffee.
    public let narrative: String
    /// Every ARIA surface that contributed an item to the underlying report, in
    /// `ReviewSurface` declaration order. Copied from the report, never inferred
    /// from the prose.
    public let citedSurfaces: [ReviewSurface]
    /// Items in the underlying report. Copied from the report; the view formats
    /// it, so no count prose is built here.
    public let itemCount: Int
    /// Whether the prose is model-written or deterministic.
    public let origin: ReviewBriefOrigin

    public init(
        headline: String,
        narrative: String,
        citedSurfaces: [ReviewSurface],
        itemCount: Int,
        origin: ReviewBriefOrigin
    ) {
        self.headline = headline
        self.narrative = narrative
        self.citedSurfaces = citedSurfaces
        self.itemCount = itemCount
        self.origin = origin
    }
}

/// Structured narration output. Only the prose is generated — the counts and
/// surfaces on `ReviewBrief` come from the report.
@Generable(description: "A short natural-language brief over a memory-estate review report.")
public struct ReviewBriefSuggestion: Sendable {
    @Guide(description: "One sentence of at most twelve words framing the review.")
    public var headline: String

    @Guide(description: "Two to five sentences covering what the review shows, in the order it matters to the reader.")
    public var narrative: String

    public init(headline: String, narrative: String) {
        self.headline = headline
        self.narrative = narrative
    }
}

// MARK: - Input type

/// Parameters for one narration run.
public struct ReviewPrepInput: Sendable {
    /// The built report to narrate.
    public let report: ReviewReport
    /// Items per section carried into the prompt (and into the deterministic
    /// narrative). Bounds the prompt: a weekly review on a real estate carries
    /// 75+ items, far more than a brief should recite.
    public let maxItemsPerSection: Int

    public init(report: ReviewReport, maxItemsPerSection: Int = 5) {
        self.report = report
        self.maxItemsPerSection = maxItemsPerSection
    }
}

// MARK: - Prompt

extension WorkerPrompts {
    /// Instructions for the ReviewPrepWorker session.
    static let reviewPrepSystem = """
    You are writing a short brief over a review of a user's private memory estate.
    The digest below is the whole of what you know: every line came from a named
    tool. Do not add facts, counts, or names that are absent from it, and do not
    guess at causes. Section titles arrive as localization keys — describe what
    the section holds, never print the key.
    """
}

// MARK: - Worker

/// Narrates a `ReviewReport` as a natural-language brief. Calls no tools: the
/// report already carries everything it describes.
public struct ReviewPrepWorker: MootWorker {

    public static var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    public init() {}

    /// `caller` is unused by design — narration reads the report, not the estate.
    /// The parameter stays to satisfy `MootWorker`, which every worker shares.
    public func run(input: ReviewPrepInput, caller: any MootToolCalling) async throws -> ReviewBrief {
        let digest = Self.digest(input.report, maxItemsPerSection: input.maxItemsPerSection)
        let session = LanguageModelSession {
            Instructions(WorkerPrompts.reviewPrepSystem + "\n\nReview digest:\n" + digest)
        }
        let response = try await session.respond(
            to: "Write the brief for this review.",
            generating: ReviewBriefSuggestion.self
        )
        return ReviewBrief(
            headline: response.content.headline,
            narrative: response.content.narrative,
            citedSurfaces: input.report.contributingSurfaces,
            itemCount: input.report.itemCount,
            origin: .model
        )
    }

    /// Deterministic brief: the digest itself, headed by a localized line saying
    /// the prose was not model-written. Reads no clock and calls no tools. An
    /// empty report still yields a readable brief.
    ///
    /// The headline blames nothing, because this path is reached both when the
    /// model is unavailable and when `run()` throws — and on real estate content
    /// the second happens with Apple Intelligence switched on, as Apple's
    /// guardrail declines some material.
    public func fallback(input: ReviewPrepInput) -> ReviewBrief {
        let advisory = String(
            localized: "worker.reviewPrep.fallback.headline",
            defaultValue: "Review digest — not summarized by the on-device model"
        )
        let digest = Self.digest(input.report, maxItemsPerSection: input.maxItemsPerSection)
        return ReviewBrief(
            headline: advisory,
            narrative: digest,
            citedSurfaces: input.report.contributingSurfaces,
            itemCount: input.report.itemCount,
            origin: .deterministic
        )
    }

    // MARK: Digest

    /// Flatten a report to prompt-sized text. Deterministic and total: the same
    /// report always produces the same digest, and every line is either report
    /// metadata or substrate content carried verbatim.
    ///
    /// Shared by both paths on purpose — the text the model narrates is exactly
    /// the text the deterministic path shows, so the two paths can never
    /// disagree about what was in the report.
    static func digest(_ report: ReviewReport, maxItemsPerSection: Int) -> String {
        var lines: [String] = [
            "review: \(report.kind.rawValue)",
            "generated_at: \(ReviewSchedule.iso8601(report.generatedAt))",
        ]
        for section in report.sections {
            lines.append("section \(section.id) (title key: \(section.title))")
            if let notice = section.notice {
                // The substrate's own words for why the section is thin.
                lines.append("  notice: \(notice)")
            }
            for item in section.items.prefix(max(0, maxItemsPerSection)) {
                var row = "  - \(item.title): \(item.detail)"
                if let magnitude = item.magnitude {
                    // The surface's own score, rendered f64 shortest-round-trip
                    // so the digest reads the same as the tool response did.
                    row += " (magnitude \(magnitude))"
                }
                row += " [via \(item.provenance.surface.rawValue), \(item.status.rawValue)]"
                lines.append(row)
            }
            let withheld = section.items.count - max(0, maxItemsPerSection)
            if withheld > 0 {
                // Stated rather than silently dropped: a brief that recites five
                // of seventy items must say so, or it reads as the whole set.
                lines.append("  (further items in this section: \(withheld))")
            }
        }
        return lines.joined(separator: "\n")
    }
}
