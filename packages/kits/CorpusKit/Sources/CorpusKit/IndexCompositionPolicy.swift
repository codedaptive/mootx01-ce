// IndexCompositionPolicy.swift
//
// Named, recorded policy that controls what text each index lane
// indexes (CDL-03 — Index Composition Policy).
//
// Each policy carries:
//   • lexicalSource — what text feeds the BM25 inverted index
//   • denseSource   — what text feeds the float embedding / dense vector lane
//
// The policy id is a stable string of the form:
//   "lex=<value>;dense=<value>"
//
// The id is stored in corpus_index_state.composition_policy so the
// engine can detect a configuration mismatch at open time and reject it.
//
// Which policy an estate runs under is a stored estate setting (LocusKit
// manifest key `index_composition_policy`), read by GeniusLocusKit at
// every open. The MOOT_INDEX_COMPOSITION environment variable is consulted
// only when that setting is first seeded (estate creation and the
// estate-format 1.3 to 1.4 capsule); a running estate changes policy only
// through `mootx01 db composition --set`, which rebuilds every index lane.
//
// Gauntlet cells:
//   A — lex=original;  dense=distilled           (.current, today's production behaviour)
//   B — lex=originalPlusAdornments; dense=distilled
//   C — lex=original;  dense=distilledPlusAdornments
//   D — lex=originalPlusAdornments; dense=distilledPlusAdornments
//   E — lex=original;  dense=original             (lexical-only baseline for ablation)
//
// Rust twin: CorpusKit/rust/src/index_composition_policy.rs

import Foundation

// MARK: - Lexical source enum

/// What text feeds the BM25 inverted index for one content row.
public enum LexicalIndexSource: String, Sendable, Equatable, Codable, CaseIterable {
    /// The verbatim drawer content — production default (today's behaviour).
    case original = "original"
    /// Verbatim content with all active adornment texts appended on separate
    /// lines in ascending minter-ID order. Adornments are AI-generated
    /// metadata fields (tags, summaries) that boost findability for the
    /// lexical lane. The base content and each adornment are separated by
    /// "\n". Nil distillate / no adornments → same text as `.original`.
    case originalPlusAdornments = "originalPlusAdornments"
    /// The distillate text (drawer.distilled). When nil, falls back to
    /// verbatim content — identical behaviour to `.original` for un-distilled
    /// rows. Useful when the distillate is a tighter, vocabulary-normalised
    /// version of the content that improves BM25 term matching.
    case distilled = "distilled"
    /// Distillate (or verbatim fallback) plus active adornments on separate lines.
    case distilledPlusAdornments = "distilledPlusAdornments"
}

// MARK: - Dense source enum

/// What text feeds the float embedding / dense vector lane.
public enum DenseIndexSource: String, Sendable, Equatable, Codable, CaseIterable {
    /// The distillate text — production default. When nil, falls back to
    /// verbatim via `CorpusContentRecord.effectiveDenseText`. This is the
    /// established dense-over-distillate behaviour (Stream F / MISSION_11X_RECALL_GAP_01).
    case distilled = "distilled"
    /// Distillate with all active adornments appended.
    case distilledPlusAdornments = "distilledPlusAdornments"
    /// Verbatim content. Used for ablation (cell E) where the dense lane
    /// indexes the same text as the default lexical lane.
    case original = "original"
}

// MARK: - Policy struct

/// A named, versioned policy recording which texts each index lane consumes.
///
/// The struct is cheap to construct (two enum values) and Codable so it
/// can survive round-trips through CorpusKit's JSON configuration layer.
/// The `id` is the persistence key — it is stored verbatim in
/// `corpus_index_state.composition_policy`.
public struct IndexCompositionPolicy: Sendable, Equatable, Codable {
    /// What text the BM25 inverted index lane consumes.
    public let lexicalSource: LexicalIndexSource
    /// What text the dense embedding lane consumes.
    public let denseSource: DenseIndexSource

    /// Stable, human-readable key used as the persistence anchor.
    /// Format: `"lex=<lexicalSource.rawValue>;dense=<denseSource.rawValue>"`.
    /// Stored in `corpus_index_state.composition_policy`. Changing the
    /// rawValues of the enums above is a BREAKING change that requires a
    /// migration (existing rows will mismatch every known policy).
    public var id: String {
        "lex=\(lexicalSource.rawValue);dense=\(denseSource.rawValue)"
    }

    public init(lexicalSource: LexicalIndexSource, denseSource: DenseIndexSource) {
        self.lexicalSource = lexicalSource
        self.denseSource = denseSource
    }

    // MARK: - Named policies

    /// Production default — original text for BM25, distillate for dense
    /// (cell A). An estate whose setting was seeded without
    /// MOOT_INDEX_COMPOSITION in the creating process runs this policy.
    public static let current = IndexCompositionPolicy(
        lexicalSource: .original,
        denseSource: .distilled)

    /// Gauntlet cell B — original+adornments for BM25, distillate for dense.
    public static let lexicalAdornments = IndexCompositionPolicy(
        lexicalSource: .originalPlusAdornments,
        denseSource: .distilled)

    /// Gauntlet cell C — original for BM25, distillate+adornments for dense.
    public static let denseAdornments = IndexCompositionPolicy(
        lexicalSource: .original,
        denseSource: .distilledPlusAdornments)

    /// Gauntlet cell D — adornments in both lanes.
    public static let bothAdornments = IndexCompositionPolicy(
        lexicalSource: .originalPlusAdornments,
        denseSource: .distilledPlusAdornments)

    /// Gauntlet cell E — lexical-only ablation (dense = verbatim too).
    public static let lexicalBaseline = IndexCompositionPolicy(
        lexicalSource: .original,
        denseSource: .original)

    // MARK: - Policy id parser

    /// Parse an `IndexCompositionPolicy` from its id string. The stored
    /// estate setting, the `mootx01 db composition --set` argument, and the
    /// creation-time `MOOT_INDEX_COMPOSITION` seed all use this form.
    ///
    /// Accepted values (case-sensitive, matching the `id` format):
    ///   - `"lex=original;dense=distilled"` (default / cell A)
    ///   - `"lex=originalPlusAdornments;dense=distilled"` (cell B)
    ///   - `"lex=original;dense=distilledPlusAdornments"` (cell C)
    ///   - `"lex=originalPlusAdornments;dense=distilledPlusAdornments"` (cell D)
    ///   - `"lex=original;dense=original"` (cell E)
    ///   - Any `"lex=<lex>;dense=<dense>"` string whose parts are valid rawValues.
    ///
    /// Returns nil for unrecognised or malformed strings; the caller decides
    /// whether that means "refuse" (a stored setting, a `--set` argument) or
    /// "seed `.current`" (an unset or malformed creation-time seed).
    public static func fromEnvironmentValue(_ value: String) -> IndexCompositionPolicy? {
        // Expected format: "lex=<lexValue>;dense=<denseValue>"
        let parts = value.split(separator: ";", maxSplits: 2)
        guard parts.count == 2 else { return nil }
        let lexPart = parts[0]
        let densePart = parts[1]
        guard lexPart.hasPrefix("lex="), densePart.hasPrefix("dense=") else { return nil }
        let lexRaw = String(lexPart.dropFirst(4))
        let denseRaw = String(densePart.dropFirst(6))
        guard let lex = LexicalIndexSource(rawValue: lexRaw),
              let dense = DenseIndexSource(rawValue: denseRaw) else { return nil }
        return IndexCompositionPolicy(lexicalSource: lex, denseSource: dense)
    }

    /// Whether this policy requires adornment texts for the lexical lane.
    public var lexicalNeedsAdornments: Bool {
        lexicalSource == .originalPlusAdornments || lexicalSource == .distilledPlusAdornments
    }

    /// Whether this policy requires adornment texts for the dense lane.
    public var denseNeedsAdornments: Bool {
        denseSource == .distilledPlusAdornments
    }

    /// Whether any lane requires adornment texts.
    public var needsAdornments: Bool { lexicalNeedsAdornments || denseNeedsAdornments }
}
