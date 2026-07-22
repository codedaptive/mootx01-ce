// CorpusSchemaProfile.swift
//
// Explicit operating-profile schema declarations + operating-mode and
// index-unit-policy validation (GLK shared-content 1.1, P1).
//
// CorpusKit publishes exactly two schema profiles:
//
//   STANDALONE — CorpusKit owns canonical documents. `corpus_documents`
//   (+ its change journal), the derived tables, `corpus_index_state`,
//   and — only when passage indexing is enabled — `corpus_passages`
//   (token-budgeted UTF-8 RANGES; a passage row holds no verbatim text).
//
//   ATTACHED — LocusKit Drawers are canonical; GLK owns the adapter. The
//   attached declaration carries ONLY rebuildable derived state, keyed by
//   canonical content ID (the Drawer ID): iix_termfreqs + iix_doclens,
//   corpus_provider_basis + corpus_provider_counts, and
//   corpus_index_state. It EXCLUDES chunks, corpus_metadata,
//   corpus_documents, corpus_passages, and removed_sources — source
//   removal in attached mode is a source change that removes the
//   corresponding derived rows, not a second durable removal truth.
//
// The legacy `BundleStore` declaration (chunks + corpus_metadata) remains
// separately addressable for 1.0 standalone compatibility and migration
// tests. It is NOT part of either profile and must not be imported into
// `GeniusLocusKitSchema` after the P3 cutover.
//
// Rust twin: `rust/src/schema_profile.rs`.

import Foundation
import PersistenceKit

/// The index-unit policy: what one derived index entry covers.
public enum CorpusIndexUnitPolicy: Sendable, Equatable {
    /// One index unit per canonical content row — the DEFAULT everywhere
    /// and the ONLY policy attached mode accepts.
    case wholeContent
#if CORPUSKIT_STANDALONE_PASSAGES
    /// Standalone-only: optional token-budgeted passages. Boundaries use
    /// CorpusKit's versioned tokenizer — never a character-count threshold.
    /// `overlapTokens` may be zero and must be smaller than `windowTokens`.
    /// Passage rows are ranges over canonical text; they never copy text and
    /// never change result identity. This case is not compiled into the
    /// GLK/MOOTx01 dependency build.
    case tokenWindows(windowTokens: Int, overlapTokens: Int)
#endif
}

/// The operating mode a Corpus is constructed in.
public enum CorpusOperatingMode: Sendable, Equatable {
    /// CorpusKit owns canonical documents (`CorpusDocumentStore`).
    case standalone
    /// Content is canonical elsewhere (LocusKit Drawers via the GLK
    /// adapter); CorpusKit stores only rebuildable derived state.
    case attached
}

/// Validated (mode, index-unit) configuration — the constructor-time gate
/// that rejects invalid combinations BEFORE anything is written.
public struct CorpusContentConfiguration: Sendable, Equatable {
    public let mode: CorpusOperatingMode
    public let indexUnit: CorpusIndexUnitPolicy

    /// Validates the combination:
    ///   - attached + passages → `attachedModeViolation` (passage
    ///     production, passage identities, and legacy chunk APIs are dark
    ///     in attached mode);
    ///   - a non-positive token budget → `invalidConfiguration`.
    public init(mode: CorpusOperatingMode, indexUnit: CorpusIndexUnitPolicy) throws {
#if CORPUSKIT_STANDALONE_PASSAGES
        switch (mode, indexUnit) {
        case (.attached, .tokenWindows):
            throw CorpusKitError.attachedModeViolation(
                "attached mode indexes whole Drawers only — passage "
                + "configuration is standalone-only and must be rejected before writing")
        case (_, .tokenWindows(let window, _)) where window <= 0:
            throw CorpusKitError.invalidConfiguration(
                "passage windows require a positive token window, got \(window)")
        case (_, .tokenWindows(let window, let overlap))
            where overlap < 0 || overlap >= window:
            throw CorpusKitError.invalidConfiguration(
                "passage overlap must be non-negative and smaller than the "
                + "window (window=\(window), overlap=\(overlap))")
        default:
            break
        }
#else
        // The GLK/MOOTx01 build has only one representable index unit. Keep
        // the mode parameter because standalone whole-content CorpusKit and
        // attached GLK share the canonical engine.
        _ = mode
#endif
        self.mode = mode
        self.indexUnit = indexUnit
    }

    /// Whether canonical-content mutation (put/remove) is permitted through
    /// CorpusKit. False in attached mode — removal authority is GLK/LocusKit
    /// verbs and source changes.
    public var allowsContentMutation: Bool { mode == .standalone }
}

/// The two published operating-profile declarations.
public enum CorpusSchemaProfile {

    /// The standalone profile: canonical documents + change journal,
    /// derived index sidecars, checkpoint lane, and (optionally) the
    /// passage-range table.
    public static func standaloneDeclaration(
        passageIndexing: Bool = false
    ) -> SchemaDeclaration {
        var components: [SchemaDeclaration] = [
            CorpusDocumentStore.schemaDeclaration,
            CorpusIndexStateStore.schemaDeclaration,
            CorpusProviderCoverageStore.schemaDeclaration,
            CorpusProviderConfigurationStore.schemaDeclaration,
            InvertedIndexStore.schemaDeclaration,
            BasisStore.schemaDeclaration,
            CorpusProviderCountsStore.schemaDeclaration,
        ]
        var tables = CorpusDocumentStore.schemaDeclaration.tables
            + CorpusIndexStateStore.schemaDeclaration.tables
            + CorpusProviderCoverageStore.schemaDeclaration.tables
            + CorpusProviderConfigurationStore.schemaDeclaration.tables
            + InvertedIndexStore.schemaDeclaration.tables
            + BasisStore.schemaDeclaration.tables
            + CorpusProviderCountsStore.schemaDeclaration.tables
        var indices = CorpusDocumentStore.schemaDeclaration.indices
            + CorpusIndexStateStore.schemaDeclaration.indices
            + InvertedIndexStore.schemaDeclaration.indices
#if CORPUSKIT_STANDALONE_PASSAGES
        // The policy row is standalone database authority. It is not part of
        // the attached schema and therefore cannot enter a GLK estate.
        components.append(CorpusIndexConfigurationStore.schemaDeclaration)
        tables += CorpusIndexConfigurationStore.schemaDeclaration.tables
        if passageIndexing {
            tables.append(passagesTable)
            indices.append(IndexDeclaration(
                name: "idx_corpus_passages_content",
                table: "corpus_passages",
                columns: ["content_id"]))
        }
#else
        precondition(!passageIndexing,
                     "standalone passage indexing is not compiled in this build")
#endif
        return SchemaDeclaration(
            kitID: "CorpusKitStandalone",
            version: profileVersion(of: components),
            tables: tables,
            indices: indices)
    }

    /// The attached profile: ONLY rebuildable derived state, keyed by the
    /// canonical content ID (the Drawer ID). No canonical content table of
    /// any kind — opening an attached Corpus creates no place where text
    /// could be copied.
    public static var attachedDeclaration: SchemaDeclaration {
        SchemaDeclaration(
            kitID: "CorpusKitAttached",
            version: profileVersion(of: [
                CorpusIndexStateStore.schemaDeclaration,
                CorpusProviderCoverageStore.schemaDeclaration,
                CorpusProviderConfigurationStore.schemaDeclaration,
                InvertedIndexStore.schemaDeclaration,
                BasisStore.schemaDeclaration,
                CorpusProviderCountsStore.schemaDeclaration
            ]),
            tables: CorpusIndexStateStore.schemaDeclaration.tables
                + CorpusProviderCoverageStore.schemaDeclaration.tables
                + CorpusProviderConfigurationStore.schemaDeclaration.tables
                + InvertedIndexStore.schemaDeclaration.tables
                + BasisStore.schemaDeclaration.tables
                + CorpusProviderCountsStore.schemaDeclaration.tables,
            indices: CorpusIndexStateStore.schemaDeclaration.indices
                + InvertedIndexStore.schemaDeclaration.indices)
    }

    /// Table names a profile must NEVER contain in attached mode — the
    /// exclusion list the profile test and the migration verifier assert.
    public static let attachedExcludedTables: Set<String> = [
        "chunks", "corpus_metadata", "corpus_documents",
        "corpus_passages", "corpus_index_configuration",
        "removed_sources", "corpus_content_changes"
    ]

    /// The standalone passage-range table (declared only when passage
    /// indexing is enabled). A passage row is
    /// (content_id, revision, digest, utf8_start, utf8_length, passage_id)
    /// — a RANGE over canonical text; it holds no verbatim text.
#if CORPUSKIT_STANDALONE_PASSAGES
    static var passagesTable: TableDeclaration {
        TableDeclaration(
            name: "corpus_passages",
            columns: [
                .text("passage_id", nullable: false),
                .text("content_id", nullable: false),
                .int("revision", nullable: false),
                .text("digest", nullable: false),
                .int("utf8_start", nullable: false),
                .int("utf8_length", nullable: false),
                .text("policy_fingerprint", nullable: false)
            ],
            primaryKey: ["passage_id"]
        )
    }
#endif

    /// A profile's version is the sum of its component declarations' live
    /// versions — the same live-sum convention as the GLK composite (never
    /// a hand-copied literal).
    private static func profileVersion(of components: [SchemaDeclaration]) -> Int {
        components.reduce(0) { $0 + $1.version }
    }
}
