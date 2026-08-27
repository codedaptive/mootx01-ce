import Foundation

// MARK: - ReviewKit models  (FAB5-G1 — the Review Center's typed contract)
//
// The value types four review builders produce and FAB5-G2 (views), FAB5-H2
// (review-prep worker), and FAB5-K1 (moot-mgr panes) consume. This file is the
// cross-mission contract: adding a case or a field here is a change every
// consumer sees, so the shapes are deliberately narrow and additive-friendly.
//
// Three properties hold for everything in this file:
//
//  1. Pure data. No estate access, no clock reads, no lens math. A report is
//     built by aggregating responses from EXISTING ARIA surfaces (the five
//     reasoning lenses plus memory/fact/journal reads) — nothing here computes
//     a score of its own.
//  2. Provenance is mandatory. Every ReviewItem names the exact ARIA tool that
//     produced it and carries the verbatim response line it was parsed from, so
//     a consumer can always answer "where did this come from?" without a second
//     query. FAB5-K1's lineage pane is built on this.
//  3. Honest emptiness. A section whose surface returned nothing (or refused)
//     carries a `notice` explaining why and an empty `items` array. Nothing in
//     this layer ever synthesizes a plausible-looking item to fill a gap.
//
// Localization: `title` fields are localization KEYS (e.g. "review.section.momentum"),
// never display prose — the view layer resolves them at render time so it can
// localize. Free-text fields that carry substrate output verbatim (`detail`,
// `notice`) are estate DATA, not UI copy, and are shown as-is.

// MARK: - ReviewKind

/// The four reviews. Raw values are stable wire identifiers — a rename here
/// breaks FAB5-K1's JSON consumption, so they are treated as API.
public enum ReviewKind: String, Codable, Sendable, CaseIterable {
    /// The estate as it stands right now — no time window.
    case dashboard
    /// Today's context plus what is still open.
    case morning
    /// What changed, what was decided, what wants attention.
    case endOfDay
    /// The week's fading, drifted, contradicted, and retire-ready material.
    case weekly
}

// MARK: - ReviewSurface

/// The ARIA tools a review may read. Raw values are the EXACT registered tool
/// names dispatched by AriaMcpKit (`LensTools.lensToolNames` and
/// `ToolDispatcher`'s read verbs) — they are passed straight to
/// `ReviewSurfaceReading.call(_:arguments:)`, so a typo here is a runtime
/// tool-not-found, not a compile error. Verified against
/// packages/kits/AriaMcpKit/Sources/AriaMCP/{LensTools,ToolProjection,ToolDispatch}.swift.
///
/// Read verbs only. No mutation tool is reachable from this enum, which is what
/// makes the whole Review module structurally read-only (same discipline as the
/// FAB5-H1 workers).
public enum ReviewSurface: String, Codable, Sendable, CaseIterable {
    /// Per-room momentum: recent attention share vs historical share.
    case themeWeather = "moot_lens_theme_weather"
    /// Recorded contradictions: `contradicts` tunnels + conflicting KG facts.
    case contradiction = "moot_lens_contradiction"
    /// Load-bearing memories by centrality over a wing's tunnel graph.
    case keystones = "moot_lens_keystones"
    /// Room-distribution divergence across a split instant.
    case drift = "moot_lens_drift"
    /// Lexical odd-ones-out within the recalled set.
    case cohesion = "moot_lens_cohesion"
    /// Hybrid BM25+vector drawer recall.
    case memorySearch = "moot_memory_search"
    /// Active KG facts.
    case factSearch = "moot_fact_search"
    /// Recent journal entries for an agent.
    case journal = "moot_read_journal"
}

// MARK: - ReviewItemStatus

/// Whether the underlying estate record is settled or still awaiting a human
/// call. Modelled as an enum rather than an `isProposed` flag so the review
/// layer carries no boolean state (schema-invariants rule) and so a third
/// lifecycle tier can be added without changing existing call sites.
public enum ReviewItemStatus: String, Codable, Sendable, CaseIterable {
    /// A settled estate record — a confirmed tunnel, an active fact, a drawer.
    case recorded
    /// An agent-derived finding flagged unreviewed by the substrate (the
    /// contradiction lens marks these `[proposed (agent-derived, unreviewed)]`).
    /// Consumers surface these as needing a decision, not as established fact.
    case proposed
}

// MARK: - ReviewProvenance

/// Where one item came from: the tool, the arguments it was called with, and
/// the verbatim response line the item was parsed out of.
///
/// `arguments` is a flat `[String: String]` rather than the `JSONValue` shape
/// the tool call actually takes, because provenance is a display/audit record —
/// it must be `Codable` for FAB5-K1's JSON path and stable to diff. Values are
/// rendered with `String(describing:)` at capture time.
public struct ReviewProvenance: Codable, Sendable, Equatable {
    /// The ARIA tool that produced this item.
    public let surface: ReviewSurface
    /// The arguments the surface was called with, stringified for audit.
    public let arguments: [String: String]
    /// The verbatim response line this item was parsed from. Kept whole so a
    /// consumer can show the raw substrate output beside the parsed item.
    public let responseLine: String

    public init(surface: ReviewSurface, arguments: [String: String] = [:], responseLine: String) {
        self.surface = surface
        self.arguments = arguments
        self.responseLine = responseLine
    }
}

// MARK: - ReviewItem

/// One reviewable thing: a rising room, a load-bearing memory, a contradiction,
/// a journal entry. Deliberately flat — the view layer decides presentation.
public struct ReviewItem: Codable, Sendable, Equatable, Identifiable {
    /// Stable within a report: `<tool name>:<subject id or ordinal>`. Stable
    /// ACROSS reports only when `subjectID` is present — ordinal-keyed ids
    /// shift when the underlying ranking shifts, which is correct for a ranked
    /// list and is why SwiftUI keys off this rather than array position.
    public let id: String
    /// Localization key for the item's label, or a substrate identifier when the
    /// label IS estate data (a drawer id, a fact subject). See `detail` for the
    /// human-readable payload.
    public let title: String
    /// Verbatim or lightly-formatted substrate content. Estate data, not UI copy.
    public let detail: String
    /// The estate row this item points at (drawer / tunnel / fact id) when the
    /// surface names one, so consumers can deep-link. `nil` for aggregate items
    /// such as a drift score, which describe a distribution rather than a row.
    public let subjectID: String?
    /// The surface's own ranking number (momentum, centrality, divergence) when
    /// it emits one. Never computed here — parsed, or `nil`.
    public let magnitude: Double?
    /// When the underlying record was filed, for the surfaces that report it
    /// (`moot_fact_search` emits `filed=`, `moot_read_journal` emits a leading
    /// `[<iso>]`). `nil` for surfaces whose text response carries no instant —
    /// notably `moot_memory_search`, which is why recall sections are ordered by
    /// the tool's own recency ranking rather than clipped to the review window.
    public let occurredAt: Date?
    /// Settled vs awaiting review.
    public let status: ReviewItemStatus
    /// Mandatory — there is no initializer that omits it.
    public let provenance: ReviewProvenance

    public init(
        id: String,
        title: String,
        detail: String,
        subjectID: String? = nil,
        magnitude: Double? = nil,
        occurredAt: Date? = nil,
        status: ReviewItemStatus = .recorded,
        provenance: ReviewProvenance
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.subjectID = subjectID
        self.magnitude = magnitude
        self.occurredAt = occurredAt
        self.status = status
        self.provenance = provenance
    }

    /// Compose the conventional item id. Ordinal is used only when the surface
    /// gives no row identifier.
    public static func makeID(surface: ReviewSurface, subjectID: String?, ordinal: Int) -> String {
        "\(surface.rawValue):\(subjectID ?? String(ordinal))"
    }
}

// MARK: - ReviewSection

/// A titled group of items from one or more surfaces.
public struct ReviewSection: Codable, Sendable, Equatable, Identifiable {
    /// Stable slug (e.g. "momentum", "open-work"). Stable across builds — the
    /// view layer may persist per-section UI state against it.
    public let id: String
    /// Localization key (e.g. "review.section.momentum"). Not display prose.
    public let title: String
    /// Ranked items, in the order the surface returned them.
    public let items: [ReviewItem]
    /// Why this section is empty or degraded, in the substrate's own words (a
    /// refusal message, a "0 result(s)" reading, or a named capability gap).
    /// `nil` when the section is populated and nothing needs explaining.
    /// Populated sections never carry a notice; empty ones always do.
    public let notice: String?

    public init(id: String, title: String, items: [ReviewItem], notice: String? = nil) {
        self.id = id
        self.title = title
        self.items = items
        self.notice = notice
    }
}

// MARK: - ReviewReport

/// One built review. The unit FAB5-G2 renders, FAB5-H2 prepares, and FAB5-K1
/// displays lineage for.
public struct ReviewReport: Codable, Sendable, Equatable {
    public let kind: ReviewKind
    /// The `now` the builder was given — never a clock read inside the builder.
    public let generatedAt: Date
    /// The span the review covers. `dashboard` uses the unbounded window.
    public let window: ReviewWindow
    public let sections: [ReviewSection]

    public init(kind: ReviewKind, generatedAt: Date, window: ReviewWindow, sections: [ReviewSection]) {
        self.kind = kind
        self.generatedAt = generatedAt
        self.window = window
        self.sections = sections
    }

    /// True when no section produced an item. An empty report is still a VALID
    /// report — an empty estate must round-trip and render, not fail.
    public var isEmpty: Bool { sections.allSatisfy { $0.items.isEmpty } }

    /// Total items across all sections.
    public var itemCount: Int { sections.reduce(0) { $0 + $1.items.count } }

    /// Every distinct surface that contributed an item, in `ReviewSurface`
    /// declaration order. Used by FAB5-K1's lineage pane.
    public var contributingSurfaces: [ReviewSurface] {
        let used = Set(sections.flatMap { $0.items.map(\.provenance.surface) })
        return ReviewSurface.allCases.filter { used.contains($0) }
    }

    // MARK: Wire coders
    //
    // Dates cross the wire as ISO8601 TEXT, matching the substrate's date
    // convention (TEXT/ISO8601, never a REAL epoch) so a report serialized by
    // the app is the same text a Rust consumer (moot-mgr, FAB5-K1) parses.
    // Consumers MUST use these rather than a default JSONEncoder, whose
    // `.deferredToDate` strategy emits epoch doubles.
    //
    // RESOLUTION IS WHOLE SECONDS. ISO8601 here carries no fractional part, so a
    // report built with a sub-second instant does not survive an encode/decode
    // round-trip byte-identically — the fraction is dropped. This matches every
    // instant the estate itself emits (`filed=`, journal stamps) and every
    // instant `ReviewSchedule` produces, all of which are whole seconds. Callers
    // that need round-trip identity (report diffing, cache keys) must pass a
    // whole-second `now`; passing `Date()` straight through is fine for display
    // but will not compare equal after a round-trip.

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Sorted keys so a serialized report is byte-stable for the same input —
        // required for diffing reports and for fixture-based tests.
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
