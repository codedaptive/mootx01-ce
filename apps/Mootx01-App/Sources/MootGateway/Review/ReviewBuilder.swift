import Foundation
import AriaMCP   // JSONValue

// MARK: - ReviewBuilder  (FAB5-G1 — protocol + the four builders)
//
// A builder reads existing ARIA surfaces through `ReviewSurfaceReading` and
// assembles a `ReviewReport`. It performs NO lens math: every number in a report
// was computed by a lens and parsed out of that lens's response.
//
// Three invariants hold for all four builders, and the tests assert each:
//
//  1. Deterministic. `now` is a parameter; no builder reads the clock. Same
//     `now` + same responses ⇒ byte-identical report.
//  2. Non-throwing. A refused or unparseable surface becomes a section notice.
//     One dead surface degrades one section; the report still builds.
//  3. Provenance-complete. Every emitted item names the tool that produced it
//     and carries the response line it came from.

// MARK: - ReviewConfiguration

/// The knobs the builders read. One value type so a caller configures a Review
/// Center once and every builder agrees.
public struct ReviewConfiguration: Sendable, Equatable {
    /// The wing whose tunnel graph the keystones lens ranks. `moot_lens_keystones`
    /// REQUIRES a wing (it has no estate-wide mode), so this has to be supplied.
    /// Default matches the substrate's own default wing for agent-filed memories.
    public let wing: String
    /// How many keystones to request (`topK`).
    public let keystoneCount: Int
    /// Row cap for `moot_memory_search` and `moot_fact_search`.
    public let searchLimit: Int
    /// How many journal entries to read (`last_n`).
    public let journalEntryCount: Int
    /// Z-score magnitude threshold for the cohesion lens.
    public let cohesionThreshold: Double
    /// Query text for the "recent context" recall. A query is required by
    /// `moot_memory_search`; this is the estate-neutral default the FAB5-H1
    /// SummarizeWorker also uses.
    public let contextQuery: String
    /// Agent whose journal is read. `nil` = the server's own MCP agent identity
    /// (the `moot_read_journal` default).
    public let journalAgent: String?

    public init(
        wing: String = "Agentic Memory",
        keystoneCount: Int = 5,
        searchLimit: Int = 20,
        journalEntryCount: Int = 10,
        cohesionThreshold: Double = 1.5,
        contextQuery: String = "recent work",
        journalAgent: String? = nil
    ) {
        self.wing = wing
        self.keystoneCount = keystoneCount
        self.searchLimit = searchLimit
        self.journalEntryCount = journalEntryCount
        self.cohesionThreshold = cohesionThreshold
        self.contextQuery = contextQuery
        self.journalAgent = journalAgent
    }
}

// MARK: - ReviewBuilder

/// Builds one kind of review.
public protocol ReviewBuilder: Sendable {
    /// Which review this builder produces. Matches the `kind` of every report
    /// it returns.
    var kind: ReviewKind { get }
    /// The knobs this builder reads.
    var configuration: ReviewConfiguration { get }
    /// The window arithmetic this builder uses.
    var schedule: ReviewSchedule { get }

    /// Build the report.
    ///
    /// - Parameters:
    ///   - now: the instant the review is "as of". Injected — never `Date()`.
    ///   - reader: the read seam. Production passes `MootToolCallingReviewReader`.
    /// - Returns: a report, always. Never throws; degraded surfaces become notices.
    func build(now: Date, reader: any ReviewSurfaceReading) async -> ReviewReport
}

// MARK: - Section assembly (shared by all four builders)

extension ReviewBuilder {

    /// Call one surface and turn its response into a section.
    ///
    /// The single funnel every section goes through, so refusal handling and
    /// empty-notice wording are identical across all four reviews:
    ///  - refusal (`isError`) ⇒ empty items, notice = the substrate's message
    ///  - parsed nothing ⇒ empty items, notice = the response's first line, which
    ///    is the surface's own count line ("theme_weather: 0 result(s)")
    ///  - parsed something ⇒ items, no notice
    func section(
        id: String,
        title: String,
        surface: ReviewSurface,
        arguments: [String: JSONValue],
        reader: any ReviewSurfaceReading,
        parse: (String, ReviewProvenanceContext) -> [ReviewItem]
    ) async -> ReviewSection {
        let response = await reader.call(surface, arguments: arguments)
        let context = ReviewProvenanceContext(
            surface: surface,
            arguments: ReviewProvenance.renderArguments(arguments))
        guard !response.isError else {
            return ReviewSection(
                id: id, title: title, items: [],
                notice: Self.refusalNotice(surface: surface, text: response.text))
        }
        let items = parse(response.text, context)
        guard !items.isEmpty else {
            return ReviewSection(
                id: id, title: title, items: [],
                notice: Self.emptyNotice(surface: surface, text: response.text))
        }
        return ReviewSection(id: id, title: title, items: items, notice: nil)
    }

    /// A section for a facet no existing read-only surface can answer. Named
    /// explicitly rather than silently omitted, and never filled with a plausible
    /// substitute — a consumer must be able to tell "nothing to report" from
    /// "nothing can be reported yet".
    func gapSection(id: String, title: String, gap: String) -> ReviewSection {
        ReviewSection(id: id, title: title, items: [], notice: gap)
    }

    /// Notice text for a refused surface: name the tool, then quote the reason.
    static func refusalNotice(surface: ReviewSurface, text: String) -> String {
        let reason = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return reason.isEmpty
            ? "\(surface.rawValue) refused the call and gave no reason."
            : "\(surface.rawValue): \(reason)"
    }

    /// Notice text for a surface that answered but yielded no items. The first
    /// response line is the surface's own summary ("keystones: 0 result(s)",
    /// "contradicts_tunnels: none"), which is the most honest thing to show.
    static func emptyNotice(surface: ReviewSurface, text: String) -> String {
        let firstLine = text
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return firstLine.isEmpty
            ? "\(surface.rawValue) returned nothing."
            : "\(surface.rawValue): \(firstLine)"
    }
}

/// The provenance fields shared by every item parsed out of one response —
/// passed to the parsers so each item can be stamped without re-rendering the
/// argument dictionary per line.
public struct ReviewProvenanceContext: Sendable, Equatable {
    public let surface: ReviewSurface
    public let arguments: [String: String]

    public init(surface: ReviewSurface, arguments: [String: String]) {
        self.surface = surface
        self.arguments = arguments
    }

    /// Stamp one item's provenance with the line it was parsed from.
    public func provenance(line: String) -> ReviewProvenance {
        ReviewProvenance(surface: surface, arguments: arguments, responseLine: line)
    }
}
