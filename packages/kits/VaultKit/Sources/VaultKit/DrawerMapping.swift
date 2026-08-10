import Foundation
import GeniusLocusKit
import LocusKit

/// Maps `NoteIR` ⇄ substrate `Drawer`/`Tunnel` over the GeniusLocusKit
/// and LocusKit **public** API only.
///
/// This is the layer where the bridge meets the substrate. It never
/// reaches a substrate primitive, schema, bitmap, or enum directly — it
/// constructs `CaptureFrame` / `TunnelCaptureFrame` values and issues
/// them through the GLK verb surface (`capture`, `recall`,
/// `recallTunnels`) and, for standalone tunnel capture, through the
/// LocusKit `Estate` actor that GLK hands back from its sanctioned
/// `estate(for:)` access point.
///
/// ## Invariant I-5 (binding)
///
/// `capture` rejects any frame with an empty `content`, `room`,
/// `addedBy`, `embeddingModelID`, or `latticeAnchor.udcCode`. Import
/// therefore supplies all five non-empty on every drawer, or the note is
/// skipped before a malformed frame is ever emitted. The `udcCode` is
/// supplied from explicit frontmatter `udc` when present, and from the
/// deterministic unclassified sentinel `"000"` otherwise. Classification
/// happens in the GeniusLocusKit capture seam (one-door principle) —
/// the seam classifies the sentinel content via EideticLib on the way in
/// (Vault import/export (g)).
public struct DrawerMapping: Sendable {

    /// Default actor identifier stamped on imported drawers and tunnels
    /// when a note's frontmatter does not carry one. Non-empty so I-5's
    /// `addedBy` guard always holds.
    public var addedBy: String

    /// Default embedding-model identifier stamped on imported drawers
    /// when frontmatter does not carry one. Non-empty so I-5's
    /// `embeddingModelID` guard always holds. No vectors are generated
    /// in this mission; the tag exists so a future model bump cannot
    /// silently compare across versions (I-4).
    public var embeddingModelID: String

    /// Retained for API compatibility. Since the one-door refactor, FDC
    /// classification for notes without explicit frontmatter `udc` happens
    /// in the GeniusLocusKit capture seam (`capture(_:_:mode:)`), not here.
    /// This flag no longer triggers in-process EideticLib lookup; it is
    /// preserved so callers compiled against the old API do not break.
    public var classifyOnImport: Bool

    /// The deterministic fallback UDC used when no live FDC anchor and no
    /// explicit frontmatter `udc` is available. `"000"` is the repo's
    /// established sentinel for unclassified/migrated content
    /// (GeniusLocusKit `MigrationAPI`). Lets every import satisfy I-5
    /// without inventing a classification.
    public let fallbackUDC: String = "000"

    public init(
        addedBy: String = "vaultkit-import",
        embeddingModelID: String = importEmbeddingModelID,
        classifyOnImport: Bool = true
    ) {
        self.addedBy = addedBy
        self.embeddingModelID = embeddingModelID
        self.classifyOnImport = classifyOnImport
    }

    // MARK: - Export: estate → IR

    /// The notes an export projects plus the per-tier exclusion counts the
    /// data-movement privacy tiers bulk-channel rules produced. Exclusions are
    /// reported, never silent (zero-loss reporting symmetry with C-13).
    public struct ExportProjection: Sendable {
        /// Drawers that passed the scope filters AND the tier rules,
        /// projected to `NoteIR`.
        public var notes: [NoteIR]
        /// Secret-tier drawers the scope filters admitted but the bulk
        /// channel excluded. Secret never rides bulk export, under any
        /// scope.
        public var excludedSecretTier: Int
        /// Private-tier (`.restricted`) drawers the scope filters admitted
        /// but the bulk channel excluded because the scope does not carry
        /// the explicit private-tier opt-in (`includesPrivateTier`).
        public var excludedPrivateTier: Int
    }

    /// Read an estate's drawers and outgoing `.references` tunnels and
    /// project each drawer to a `NoteIR`, enforcing the data-movement privacy tiers
    /// privacy-tier rules and counting what they excluded.
    ///
    /// Drawers are recalled using the `scope` parameter's filter chain plus
    /// an explicit `.sensitivityAtMost(.secret)` filter. The explicit filter
    /// suppresses the recall evaluator's implicit `.sensitivityAtMost(.elevated)`
    /// default and raises the ceiling to secret so all tiers are visible here.
    /// This makes secret/private exclusions countable: the tier rules are then
    /// enforced by partition — secret is always excluded, restricted is excluded
    /// unless `scope.includesPrivateTier`, and each exclusion is counted.
    ///
    /// Tunnels are read per wing; only `.references` edges originating at an
    /// included drawer become wikilinks (Vault import/export (a)/(d)).
    ///
    /// - Parameters:
    ///   - kit: the open `GeniusLocusKit` instance.
    ///   - handle: the estate handle.
    ///   - scope: which drawers to include. Defaults to `.exportable`
    ///     (CAND-032) — only explicitly-exportable drawers; broader scopes are
    ///     explicit opt-ins so a default export never writes private/non-exportable rows.
    public func export(
        kit: GeniusLocusKit,
        handle: EstateHandle,
        scope: VaultExportScope = .exportable
    ) async throws -> ExportProjection {
        // VK-EXPORT-FIX: pass an explicit limit so the GLK convenience overload
        // does not apply its default cap of 50. Export is a full projection of
        // all believed drawers — it is a pure filter scan (no query, no scoring),
        // so returning the complete set in stable order is correct. The limit is
        // set to 10_000_000 (ten million) rather than Int.max because the Recall
        // Director computes `frontierK = min(max(limit * 4, 64), 256)` on line 55
        // of RecallDirector.swift and `Int.max * 4` overflows in Swift debug builds.
        // Ten million is unreachable by any realistic estate; the locusOnly lane
        // drains all pages until exhausted well before this limit.
        let recalled = try await kit.recall(
            handle,
            RecallFrame(
                filterChain: scope.filterChain + [.sensitivityAtMost(.secret)],
                hydrationLevel: .full,
                limit: 10_000_000
            )
        )

        // VK-EXPORT-FAILOUD: if the filtered recall returned nothing, verify
        // whether the estate is genuinely empty (or all drawers legitimately
        // filtered out by scope) versus the corpus being bricked (all rows
        // skipped due to corrupt timestamps by the scan-resilience path).
        //
        // Strategy: two-step check.
        //   Step 1 — raw COUNT(*) on the drawers table. If 0, the estate is
        //            genuinely empty — zero recall is correct, no bricking.
        //   Step 2 — if rows exist in storage, probe with an unfiltered recall
        //            (no scope, no sensitivity filter, limit 1). If THAT also
        //            returns 0, and raw COUNT > 0, then ALL rows are corrupt
        //            and the export must fail loud. If the unfiltered probe
        //            returns >= 1, the scope/sensitivity filter legitimately
        //            excluded everything (e.g. the caller exported with
        //            .unconfirmed but all drawers are confirmed, or all
        //            drawers are secret).
        //
        // This two-step approach avoids false positives from legitimate scope
        // exclusions (e.g. secret-only estate with a non-secret export scope).
        if recalled.isEmpty {
            let rawDrawerCount = try await kit.countDrawerRows(handle)
            if rawDrawerCount > 0 {
                // Storage has rows. Probe with a minimal unfiltered recall to
                // distinguish "scope filtered everything out" from "all rows
                // are corrupt". The probe reads no blobs (structured hydration,
                // limit 1) so it is cheap even on a large estate.
                let unfilteredProbe = try await kit.recall(
                    handle,
                    RecallFrame(
                        filterChain: [],
                        hydrationLevel: .structured,
                        limit: 1
                    )
                )
                if unfilteredProbe.isEmpty {
                    // Storage has rows but even an unfiltered scan returns
                    // nothing — all rows are corrupt (poison timestamps or
                    // other decode failures skipped by scan resilience). The
                    // export must fail loud; a 0-note vault would be silent
                    // data loss.
                    throw VaultKitError.exportBrickedEstate(
                        drawerCount: rawDrawerCount,
                        reason: "recall returned 0 drawers even without scope filters, but storage contains \(rawDrawerCount) drawer rows — likely corrupt timestamps in the drawers table. Run a repair before exporting."
                    )
                }
                // unfilteredProbe returned >= 1 row — scope or sensitivity
                // filters legitimately excluded all drawers. Not bricking.
            }
        }

        // Resolve display names (wing, room) for all recalled drawers in one
        // batch. node-tree integrity removed wing/room from the Drawer struct; consumers
        // obtain them from the node tree via Estate.resolveNodeNames.
        let estate = try await kit.estate(for: handle)
        let allNodeNames = try await estate.resolveNodeNames(
            parentNodeIds: recalled.map(\.parentNodeId))

        // data-movement privacy tiers tier partition. The predicates encode the
        // normative 4→3 mapping (Normal → normal+elevated, Private →
        // restricted, Secret → secret) — see AdjectiveSensitivity in LocusKit.
        var drawers: [Drawer] = []
        var excludedSecret = 0
        var excludedPrivate = 0
        for drawer in recalled {
            // Hint drawers (AI_Charter_Hint room) are normal drawers and export
            // normally. They are user-deletable and recallable like any other
            // drawer, so exporting them reflects the estate's actual content.
            let tier = drawer.adjectiveSensitivity
            if tier.isExcludedFromBulk {
                // Secret never rides bulk channels, under any scope.
                excludedSecret += 1
            } else if tier.requiresOwnerKeyForBulk && !scope.includesPrivateTier {
                // Private tier rides bulk only under the explicit opt-in scope.
                excludedPrivate += 1
            } else {
                drawers.append(drawer)
            }
        }

        // Fetch tunnels once per distinct source wing, not once per drawer.
        // Wing names are resolved from the node tree.
        //
        // CAND-EXP-PROV: the tunnel read mirrors the drawer-side tier rule —
        // the private-scope opt-in (`includesPrivateTier`) also carries
        // provenance tunnels to restricted drawers, so the exported vault
        // keeps its lineage. The default scopes keep the Normal-tier
        // ceiling, and secret-tier edges never export regardless of scope
        // (enforced inside the LocusKit gate, exactly like drawers).
        var tunnelsByWing: [String: [Tunnel]] = [:]
        let resolvedWings = Set(drawers.compactMap { allNodeNames[$0.parentNodeId]?.wing })
        for wing in resolvedWings {
            tunnelsByWing[wing] = try await kit.recallTunnels(
                handle, wing: wing, includingRestricted: scope.includesPrivateTier)
        }

        // Query all KG facts once for the estate, then group by sourceDrawerID
        // so each drawer's tags and kind can be reconstructed without an
        // N-per-drawer round-trip. Drawers with no KG facts get an empty slice.
        //
        // CAND-050: Filter facts to only those anchored to a tier-included drawer.
        // A KG fact anchored to a secret or (scope-excluded) private drawer must
        // not appear in export output, consistent with data-movement privacy tiers tier
        // rules. Without this guard, a secret drawer's tags and kind would leak
        // into export even after the drawer itself was excluded. The included-
        // drawer ID set is computed from the post-partition `drawers` array so
        // the exact same data-movement privacy tiers rules apply to facts that apply to their anchors.
        let includedDrawerIDs = Set(drawers.map(\.id))
        let allKGFacts = try await kit.recallKGFacts(handle)
        var kgFactsByDrawerID: [String: [KGFact]] = [:]
        for fact in allKGFacts {
            // Skip facts whose source anchor was excluded by the tier partition.
            // Facts with an empty sourceDrawerID are estate-level (no anchor);
            // they are not used by the export path and are dropped here silently.
            guard !fact.sourceDrawerID.isEmpty,
                  includedDrawerIDs.contains(fact.sourceDrawerID) else { continue }
            kgFactsByDrawerID[fact.sourceDrawerID, default: []].append(fact)
        }

        let notes = drawers.map { drawer in
            let names = allNodeNames[drawer.parentNodeId] ?? (wing: "", room: "")
            let outgoing = (tunnelsByWing[names.wing] ?? []).filter {
                $0.sourceDrawerId == drawer.id && $0.kind == .references
            }
            let drawerFacts = kgFactsByDrawerID[drawer.id] ?? []
            return Self.noteIR(from: drawer, wing: names.wing, room: names.room, references: outgoing, kgFacts: drawerFacts)
        }
        return ExportProjection(
            notes: notes,
            excludedSecretTier: excludedSecret,
            excludedPrivateTier: excludedPrivate
        )
    }

    /// Pure projection of one drawer (+ its outgoing `.references` tunnels
    /// + its anchored KG facts) to a `NoteIR`. No substrate access beyond
    /// the pre-fetched parameters — testable in isolation.
    ///
    /// `wing` and `room` are the display names resolved from the estate's
    /// node tree via `Estate.resolveNodeNames(parentNodeIds:)`. node-tree integrity
    /// removed these stored properties from `Drawer`; callers resolve them
    /// once in batch and pass them in.
    ///
    /// `kgFacts` is the subset of KG facts whose `sourceDrawerID` matches
    /// `drawer.id`. The export path pre-fetches all facts once and groups
    /// by drawer id; this function reconstructs `NoteIR.tags` and
    /// `NoteIR.kind` from the facts:
    ///
    ///   - Facts with `subject.hasPrefix("tag:")` and `predicate == "tagged"`
    ///     become the drawer's tag list (hard-close #29-A round-trip).
    ///   - A fact with `subject == "record:kind"` and `predicate == "is"`
    ///     becomes the drawer's kind discriminator (hard-close #29-B round-trip).
    ///
    /// ## Filename / path (wing organization, Decision cp-vault-bidir)
    ///
    /// The vault path is `"<wing>/<room>/<slug>.md"` — the wing is the
    /// top-level folder so the vault tree mirrors the estate's wing structure
    /// and export/import is wing-scopable (wing organization Consequences). Hint
    /// memories (`AI_Charter_Hint` room) export as `<wing>/AI_Charter_Hint/<slug>.md`
    /// alongside regular content drawers — hint drawers are normal vault entries.
    ///
    /// The slug is derived from the first markdown heading or the first
    /// non-empty content line, sanitized to a safe filename character set. On
    /// collision within the caller's export set, a short suffix derived from
    /// `drawer.lineageID` is appended. The result is deterministic given the
    /// drawer.
    ///
    /// ## `moot_id` frontmatter (Decision cp-vault-bidir)
    ///
    /// `moot_id` is the STABLE lineage UUID (`drawer.lineageID`) — not
    /// `drawer.id`, which the supersession cascade re-mints on every
    /// write. Re-importing an exported note with `moot_id` maps back to
    /// the same substrate lineage regardless of filename changes.
    ///
    /// ## Wing round-trip note
    ///
    /// The wing value is preserved in the vault folder path AND in the
    /// `wing` frontmatter key. On re-import, `makeCaptureFrame` reads the
    /// wing from `frontmatter["wing"]` and (a) strips it from the path
    /// components used for the `room` value and (b) sets `CaptureFrame.wing`
    /// so the capture verb routes the drawer into the correct named wing.
    /// The round-trip is fully faithful: a drawer exported from "User Canon"
    /// re-imports into "User Canon", not into `defaultWingName`.
    static func noteIR(from drawer: Drawer, wing: String, room: String, references: [Tunnel], kgFacts: [KGFact] = []) -> NoteIR {
        // Path: <wing>/<room>/<slug>.md — wing is the top-level vault folder.
        // wing organization Consequences: wing = top folder; all drawers (including hint
        // memories in AI_Charter_Hint room) export normally. Layout is wing-aware.
        let slug = Self.slug(from: drawer.content, id: drawer.lineageID)
        let stableKey = "\(wing)/\(room)/\(slug)"

        var frontmatter: [String: String] = [
            "wing": wing,
            "room": room,
            "udc": drawer.udcCode,
            "addedBy": drawer.addedBy,
            "embeddingModelID": drawer.embeddingModelID,
            "captureChannel": String(drawer.captureChannel.rawValue),
            "contentKind": String(drawer.contentKind.rawValue),
            // Origin date rides frontmatter (no substrate origin-date column
            // in scope). `created:` is the Obsidian key the adapter reads back.
            "created": OccurredAt(date: drawer.eventTime).iso8601,
            // moot_id: the STABLE lineage UUID, not drawer.id. This is the
            // round-trip identity anchor: a re-import maps via moot_id to
            // the same substrate lineage even if the user renames the file.
            "moot_id": drawer.lineageID.uuidString,
        ]
        if let qid = drawer.wikidataQID, !qid.isEmpty {
            frontmatter["wikidataQID"] = qid
        }
        // Sensitivity rides frontmatter so a round-trip preserves the tier
        // (data-movement privacy tiers; import reads the key back into
        // `CaptureFrame.sensitivity`). `.normal` is omitted — it is the
        // capture default, so absence round-trips to the same value and
        // pre-existing exports stay byte-identical.
        if drawer.adjectiveSensitivity != .normal {
            frontmatter["sensitivity"] = Self.sensitivityLabel(drawer.adjectiveSensitivity)
        }

        // Each outgoing `.references` tunnel's label carries the raw wikilink text
        // that produced it on import, so export renders it back verbatim.
        // `_distilled_from` provenance tunnels are retired in 1.1.x per
        // SPEC_DISTILLATION_STORAGE §11.2 and are absent from 1.1.x estates;
        // the filter below is a belt-and-suspenders guard for any stale row.
        // The retired `distilled_from_sources` frontmatter key is no longer emitted
        // (SPEC_DISTILLATION_STORAGE §13.2; import side already ignores it).
        let links = references
            .filter { $0.label != "_distilled_from" }
            .map { WikiLink(target: $0.label, alias: nil, raw: $0.label) }

        // Reconstruct tags from KG facts (hard-close #29-A round-trip).
        // Facts with subject "tag:<t>" and predicate "tagged" were filed on
        // import; the tag value is the suffix after the "tag:" prefix.
        let tags: [String] = kgFacts
            .filter { $0.subject.hasPrefix("tag:") && $0.predicate == "tagged" }
            .map { String($0.subject.dropFirst("tag:".count)) }
            .sorted() // stable order so round-trip produces deterministic arrays

        // Reconstruct kind from KG facts (hard-close #29-B round-trip).
        // A fact with subject "record:kind" and predicate "is" was filed on
        // import when kind != "note"; absence means the default "note" kind.
        let kind: String = kgFacts
            .first { $0.subject == "record:kind" && $0.predicate == "is" }
            .map(\.object) ?? "note"

        return NoteIR(
            stableSourceKey: stableKey,
            body: [Block(kind: "markdown", text: drawer.content)],
            frontmatter: frontmatter,
            links: links,
            tags: tags,
            originalPath: room,
            originDate: OccurredAt(date: drawer.eventTime),
            source: nil,
            mootID: drawer.lineageID,
            kind: kind
        )
    }

    // MARK: - Slug derivation

    /// Derive a deterministic human-readable slug from a drawer's content.
    ///
    /// Algorithm:
    /// 1. If the content contains a Markdown `# Heading`, use the heading text.
    /// 2. Otherwise use the first non-empty line.
    /// 3. Sanitize: lowercase, replace non-alphanumeric runs with `-`,
    ///    trim leading/trailing hyphens, truncate to 60 chars.
    /// 4. If the result is empty after sanitization, use a fallback derived
    ///    from the first 8 chars of the lineage UUID.
    ///
    /// The `id` parameter is used as the suffix source when the caller needs
    /// to disambiguate collisions within an export set (the caller is
    /// responsible for detecting and applying the suffix — this function
    /// returns the base slug only).
    static func slug(from content: String, id: UUID) -> String {
        let lines = content.split(
            separator: "\n",
            omittingEmptySubsequences: true
        ).map { String($0) }

        // Try the first markdown heading first, else the first line.
        var source = ""
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                // Strip the leading `#` tokens and whitespace.
                let stripped = trimmed.drop(while: { $0 == "#" || $0 == " " })
                if !stripped.isEmpty {
                    source = String(stripped)
                    break
                }
            } else if source.isEmpty, !trimmed.isEmpty {
                source = trimmed
            }
        }

        let sanitized = sanitizeSlug(source)

        if sanitized.isEmpty {
            // No usable text — fall back to a short UUID-derived suffix so the
            // slug is always non-empty and collision-free within the estate.
            return "note-" + id.uuidString.prefix(8).lowercased()
        }
        return sanitized
    }

    /// Sanitize a raw string into a filesystem-safe slug.
    ///
    /// - Lowercases the string.
    /// - Replaces any run of characters that are not `[a-z0-9-]` with a single
    ///   `-` (spaces, punctuation, etc. all collapse to one hyphen).
    /// - Trims leading and trailing hyphens.
    /// - Truncates to 60 characters.
    private static func sanitizeSlug(_ s: String) -> String {
        guard !s.isEmpty else { return "" }
        var result = s.lowercased()
        // Collapse non-alphanumeric runs to a single hyphen.
        var out = ""
        var lastWasHyphen = false
        for ch in result {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                lastWasHyphen = false
            } else {
                if !lastWasHyphen { out.append("-") }
                lastWasHyphen = true
            }
        }
        result = out
        // Trim leading/trailing hyphens.
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        // Truncate.
        if result.count > 60 {
            result = String(result.prefix(60)).trimmingCharacters(
                in: CharacterSet(charactersIn: "-"))
        }
        return result
    }

    // MARK: - Import: IR → estate via the capture seam

    /// Outcome of importing a single note.
    public enum ImportOutcome: Sendable, Equatable {
        /// A drawer was captured for a new lineage.
        case written(tunnelsCreated: Int, fdcClassified: Bool)
        /// A re-import superseded the existing drawer for this lineage.
        case updated(tunnelsCreated: Int, fdcClassified: Bool)
        /// The note could not be imported (e.g. empty content would
        /// violate I-5); nothing was written.
        case skipped(reason: String)
        /// Re-import of a note whose lineage exists and content is
        /// byte-identical to the active drawer. No supersession, no
        /// UUID rotation — idempotent no-op.
        case skippedUnchanged
        /// Re-import of a note whose lineage was previously erased
        /// (withdrawn) in the estate. The tombstone is respected;
        /// the note is NOT resurrected.
        case skippedTombstoned
        /// A DisciplineViolation was raised AFTER the supersession cascade
        /// already wrote the successor drawer row but before the predecessor
        /// state flip completed (e.g. Contested predecessor whose transition
        /// Active→Superseded is illegal). The estate contains an orphaned
        /// successor row alongside the un-flipped predecessor. Unlike plain
        /// `.skipped`, the write was partially applied and the caller must
        /// know: the count is surfaced in `ImportReport.drawersSkippedPartialWrite`
        /// so reconciliation passes can detect the gap. This outcome is NOT
        /// silent — it is reported even though the surface-visible content
        /// appears unchanged.
        case skippedWithPartialWrite(reason: String)
    }

    /// Import one note: build a `CaptureFrame`, capture the drawer through
    /// the GLK verb surface, then create the note's `.references` tunnels
    /// (de-duplicated against `existingTunnelSignatures` so a re-import
    /// adds no duplicates).
    ///
    /// ## Content-idempotent matching (FINDING-1a)
    ///
    /// When a note's lineage matches an existing ACTIVE drawer AND the
    /// flattened content is byte-identical to that drawer's content AND no
    /// sensitivity UPGRADE is requested, the import is a no-op — no
    /// supersession, no UUID rotation. Only when the content or tier actually
    /// changed does the supersession cascade run. Content identity is tested
    /// by comparing the note's flattened body against
    /// `existingContentByLineage[lineage]`; the caller populates this map
    /// from the active-drawer snapshot built before the loop. A sensitivity
    /// UPGRADE (incoming tier strictly higher than stored tier) bypasses the
    /// idempotent guard so the tier raise lands even when content is unchanged.
    ///
    /// ## Tombstone-aware matching (FINDING-1b)
    ///
    /// When a note's lineage appears in `tombstonedLineageIDs` — i.e. its
    /// lineage was previously erased (state: withdrawn/superseded past the
    /// active cluster) — the note is NOT resurrected. The tombstone is
    /// respected and the outcome is `.skippedTombstoned`. The count is
    /// surfaced in `ImportReport.drawersSkippedTombstoned` (never silent).
    ///
    /// ## Sensitivity floor
    ///
    /// `existingSensitivityByLineage` carries the current tier of every
    /// believed drawer (across ALL tiers) so the sensitivity FLOOR can be
    /// enforced: a re-import may RAISE a drawer's tier but never LOWER it.
    /// This closes the supersession-downgrade attack.
    // MARK: - Batch helpers (GLK_BATCH1)

    /// Apply import guards and build a `CaptureFrame` for `note` without
    /// calling `kit.capture`. Returns `nil` (with `report` counters updated
    /// for the skip) when any guard fires. The caller is responsible for
    /// incrementing `drawersWritten`/`drawersUpdated` on a non-nil return.
    ///
    /// Used by `importNotes`' bulk path (when the size gate selects one
    /// transaction): frames are collected first, then submitted in a single
    /// `captureBatch` call; post-capture work (KG
    /// facts, tunnels) runs afterward via `applyNotePostCapture`.
    func buildNoteFrame(
        for note: NoteIR,
        existingLineageIDs: Set<UUID>,
        existingSensitivityByLineage: [UUID: AdjectiveSensitivity],
        tombstonedLineageIDs: Set<UUID>,
        existingContentByLineage: [UUID: String],
        existingStableSourceKeyByLineage: [UUID: String],
        report: inout ImportReport
    ) -> (frame: CaptureFrame, isUpdate: Bool, classified: Bool)? {
        let content = note.flattenedBody
        guard !content.isEmpty else {
            report.itemsSkipped += 1
            return nil
        }
        var (frame, classified) = makeCaptureFrame(for: note, content: content)

        // Security: moot_id lineage-hijack guard. A crafted `moot_id` in
        // imported frontmatter can claim an existing in-estate lineage, causing
        // an imported note to overwrite another note's content.
        //
        // WHAT THIS DEFENDS: a note arriving at a path OTHER than the claimed
        // lineage's expected export path, with changed content, is refiled
        // under its own FNV lineage; the claimed drawer is untouched.
        //
        // WHAT IT DOES NOT DEFEND: a note at the claimed lineage's OWN expected
        // export path is accepted as an update regardless of content. That case
        // is indistinguishable from the legitimate round-trip this feature
        // exists to support (export → edit in Obsidian → re-import): both
        // produce the identical artifact — a changed file at the exported path
        // carrying the exported moot_id. Same-path spoofing is therefore NOT
        // covered, and no discriminator over the file can cover it without
        // breaking the round-trip. Both halves of this boundary are pinned by
        // tests: `samepathHostileContentIsIndistinguishableFromLegitimateEdit`
        // and `mootIDHijackGuardBlocksBodyReplacement`.
        //
        // The recorded key compared below is RECOMPUTED from current estate
        // wing/room/slug on every import (see VaultBridge.existingDrawerState).
        // It is not persisted or authenticated provenance. The vault tree is
        // attacker-controlled input, and nothing inside it — including
        // `.moot/export-manifest.json` — is an authentication anchor: whoever
        // can plant a note can plant a manifest.
        //
        // The guard fires when ALL THREE conditions hold:
        //   1. The claimed UUID is already in the estate (it targets an existing
        //      lineage rather than introducing a new one), AND
        //   2. The note's vault path does NOT match the export path recorded for
        //      the claimed lineage (path-identity discriminator). Fallback when
        //      no export path is recorded: the claimed UUID does not match
        //      FNV(stableSourceKey) — retained only for drawers whose export
        //      path is unknown (e.g. first-time import), AND
        //   3. The incoming CONTENT differs from what the estate has for that
        //      lineage (a content-replacement is being attempted).
        //
        // Condition 3 permits sensitivity-only upgrades on unchanged content —
        // the common and legitimate case where an export/re-import cycle needs
        // to raise a drawer's tier without altering its body.
        let fnvLineage = Self.lineageID(forStableSourceKey: note.stableSourceKey)
        if let claimedID = frame.lineageID,
           existingLineageIDs.contains(claimedID),
           existingContentByLineage[claimedID] != content {
            // Determine whether the note's vault path is foreign to the claimed
            // lineage. Primary check: path-identity. Fallback: FNV check when
            // no export path is recorded for this lineage.
            let isPathForeign: Bool
            if let recordedKey = existingStableSourceKeyByLineage[claimedID] {
                isPathForeign = recordedKey != note.stableSourceKey
            } else {
                isPathForeign = claimedID != fnvLineage
            }
            if isPathForeign {
                // Foreign path claiming an existing lineage with different body —
                // reject the moot_id claim and file under the note's own FNV lineage.
                frame.lineageID = fnvLineage
            }
        }

        let lineage = frame.lineageID ?? fnvLineage
        if tombstonedLineageIDs.contains(lineage) {
            report.drawersSkippedTombstoned += 1
            return nil
        }
        let isUpdate = existingLineageIDs.contains(lineage)
        let requestedSensitivity = frame.sensitivity
        let existingTier = existingSensitivityByLineage[lineage]
        let isSensitivityUpgrade = existingTier.map { requestedSensitivity.rawValue > $0.rawValue } ?? false
        if isUpdate, let existingContent = existingContentByLineage[lineage],
           existingContent == content, !isSensitivityUpgrade {
            report.drawersSkippedUnchanged += 1
            return nil
        }
        if let existingTier = existingSensitivityByLineage[lineage],
           existingTier.rawValue > frame.sensitivity.rawValue {
            frame.sensitivity = existingTier
        }
        return (frame, isUpdate, classified)
    }

    /// Apply post-capture work (KG facts + tunnels) for a note whose drawer
    /// was already inserted by `kit.captureBatch`. Called per-note AFTER the
    /// batch transaction commits so `drawer.id` is available.
    func applyNotePostCapture(
        note: NoteIR,
        frame: CaptureFrame,
        drawer: Drawer,
        kit: GeniusLocusKit,
        handle: EstateHandle,
        existingTunnelSignatures: inout Set<String>,
        now: Date
    ) async throws -> Int {
        for fact in note.facts {
            _ = try await kit.captureKGFact(
                handle,
                subject: fact.subject, predicate: fact.predicate, object: fact.object,
                sourceDrawerID: drawer.id, now: now)
        }
        for (key, value) in note.scope {
            _ = try await kit.captureKGFact(
                handle,
                subject: "scope:\(key)", predicate: "has_value", object: value,
                sourceDrawerID: drawer.id, now: now)
        }
        for tag in note.tags {
            _ = try await kit.captureKGFact(
                handle,
                subject: "tag:\(tag)", predicate: "tagged", object: drawer.id,
                sourceDrawerID: drawer.id, now: now)
        }
        if note.kind != "note" {
            _ = try await kit.captureKGFact(
                handle,
                subject: "record:kind", predicate: "is", object: note.kind,
                sourceDrawerID: drawer.id, now: now)
        }
        let estate = try await kit.estate(for: handle)
        let drawerNodeNames = try await estate.resolveNodeNames(parentNodeIds: [drawer.parentNodeId])
        let drawerWing = drawerNodeNames[drawer.parentNodeId]?.wing ?? ""
        let drawerRoom = drawerNodeNames[drawer.parentNodeId]?.room ?? ""
        var tunnelsCreated = 0
        // `_distilled_from` reconstruction retired (SPEC_DISTILLATION_STORAGE
        // §11.2/§13.2): the factoid tier no longer exists on 1.1.x and NO
        // new-write path may create `_distilled_from` tunnels. A
        // `distilled_from_sources` frontmatter key in an old export is
        // ignored; representations regenerate from content on sweep (§2).
        for link in note.links {
            let targetRoom = link.target.isEmpty ? "unresolved" : link.target
            let signature = Self.tunnelSignature(
                sourceWing: drawerWing, sourceRoom: drawerRoom,
                targetRoom: targetRoom, label: link.raw, kind: .references)
            guard !existingTunnelSignatures.contains(signature) else { continue }
            let tunnelFrame = TunnelCaptureFrame(
                sourceWing: drawerWing, sourceRoom: drawerRoom,
                targetWing: drawerWing, targetRoom: targetRoom,
                label: link.raw, addedBy: frame.addedBy,
                sourceDrawerId: drawer.id, targetDrawerId: nil,
                kind: .references, originClass: .imported)
            _ = try await estate.capture(tunnelFrame)
            existingTunnelSignatures.insert(signature)
            tunnelsCreated += 1
        }
        return tunnelsCreated
    }

    // MARK: - Per-item import

    public func importNote(
        _ note: NoteIR,
        kit: GeniusLocusKit,
        handle: EstateHandle,
        existingLineageIDs: Set<UUID>,
        existingSensitivityByLineage: [UUID: AdjectiveSensitivity],
        tombstonedLineageIDs: Set<UUID>,
        existingContentByLineage: [UUID: String],
        existingStableSourceKeyByLineage: [UUID: String] = [:],
        existingTunnelSignatures: inout Set<String>,
        now: Date
    ) async throws -> ImportOutcome {
        let content = note.flattenedBody
        // I-5: empty content cannot be captured. Skip rather than emit a
        // frame the substrate will reject.
        guard !content.isEmpty else {
            return .skipped(reason: "empty content (I-5: content must be non-empty)")
        }

        var (frame, classified) = makeCaptureFrame(for: note, content: content)

        // Security: moot_id lineage-hijack guard. Mirrors the path-identity
        // discriminator in buildNoteFrame — see that function for the full
        // rationale and the guard's boundary. Fires when (1) the claimed UUID
        // targets an existing lineage, (2) the note's vault path is FOREIGN to
        // the claimed lineage (path does not match the export path recorded for
        // that lineage; FNV fallback when no export path is recorded), AND
        // (3) the incoming body differs from what the estate has for that
        // lineage. Condition 3 permits sensitivity-only upgrades on unchanged
        // content.
        //
        // Boundary, restated so it is not missed at this site: this rejects a
        // content-replacing claim only from a FOREIGN path. A note at the
        // claimed lineage's own expected export path is accepted as an update
        // whatever its content — indistinguishable from the legitimate
        // round-trip edit — so same-path spoofing is not covered here. The
        // recorded key is recomputed from current estate state, not persisted
        // provenance, and the vault tree (including
        // `.moot/export-manifest.json`) is attacker-controlled input, not an
        // authentication anchor.
        let fnvLineage = Self.lineageID(forStableSourceKey: note.stableSourceKey)
        if let claimedID = frame.lineageID,
           existingLineageIDs.contains(claimedID),
           existingContentByLineage[claimedID] != content {
            let isPathForeign: Bool
            if let recordedKey = existingStableSourceKeyByLineage[claimedID] {
                isPathForeign = recordedKey != note.stableSourceKey
            } else {
                isPathForeign = claimedID != fnvLineage
            }
            if isPathForeign {
                frame.lineageID = fnvLineage
            }
        }

        let lineage = frame.lineageID ?? fnvLineage

        // TOMBSTONE-AWARE: if this lineage was previously erased (withdrawn),
        // do not resurrect it. Respect the tombstone and surface the skip count.
        // Tombstone check runs BEFORE the active-lineage check so a lineage
        // that was active and then erased between import runs does not
        // accidentally fall through to supersession.
        if tombstonedLineageIDs.contains(lineage) {
            return .skippedTombstoned
        }

        let isUpdate = existingLineageIDs.contains(lineage)

        // CONTENT-IDEMPOTENT: when the lineage already has an active drawer
        // with byte-identical content AND no sensitivity upgrade requested,
        // skip — no supersession, no UUID rotation. Only supersede when
        // something actually changed. This is the fix for FINDING-1a:
        // previously every re-import triggered the supersession cascade
        // regardless of whether content had changed.
        //
        // Sensitivity exception: if the incoming note requests a HIGHER tier
        // than the stored tier, the upgrade is meaningful and must proceed even
        // when body content is identical (e.g. a note re-tagged `sensitivity:
        // secret` after it was originally captured as `.normal`). A LOWER
        // incoming tier is not meaningful because the floor (applied below)
        // would hold the tier at the existing level regardless.
        let requestedSensitivity = frame.sensitivity
        let existingTier = existingSensitivityByLineage[lineage]
        // A sensitivity upgrade occurs when the incoming tier is strictly
        // higher than the stored tier (rawValue ordering: normal=0, elevated=16,
        // restricted=32, secret=48). Only upgrades block the idempotent skip.
        let isSensitivityUpgrade = existingTier.map { requestedSensitivity.rawValue > $0.rawValue } ?? false
        if isUpdate, let existingContent = existingContentByLineage[lineage],
           existingContent == content, !isSensitivityUpgrade {
            return .skippedUnchanged
        }

        // Sensitivity floor: a re-import never lowers an existing drawer's
        // tier. Raw values are tier-ordered (normal 0 < elevated 16 <
        // restricted 32 < secret 48), so a numeric max is the floor.
        if let existingTier = existingSensitivityByLineage[lineage],
           existingTier.rawValue > frame.sensitivity.rawValue {
            frame.sensitivity = existingTier
        }

        // mode: .regular — enqueues the drawer onto the Corpus's own ingest queue
        // so the drain worker ingests the drawer into the Corpus (BM25 + vector).
        // The legacy no-mode overload stored the drawer row only, leaving the
        // BM25/vector semantic lanes dark for all imported content (the bug proven
        // on the real estate: 2354 drawers, node_bundles=0). Using .regular here
        // is the correct choice for bulk import: capture returns immediately and
        // encoding is handled in the background, so large imports don't block.
        //
        // Idempotency: re-importing an export that was already imported into the
        // same estate triggers a belief-state DisciplineViolation (e.g. Contested
        // → Supersede is an illegal transition). This can arise in two distinct
        // cases that callers must distinguish:
        //
        //   A. NEW lineage (isUpdate == false): the DisciplineViolation fired before
        //      any row was written (e.g. secret+exportable forbidden combination),
        //      or the capture verb itself rejected. No partial write occurred.
        //      Surface as plain `.skipped`.
        //
        //   B. UPDATE path (isUpdate == true): the supersession cascade in
        //      `add_drawer_with_cascade` writes the SUCCESSOR row (Step 1:
        //      `gated_capture`) BEFORE it attempts to flip the predecessor's
        //      belief state (Step 4: `mutate_state`). When Step 4 raises
        //      DisciplineViolation (predecessor in Contested or another non-Active
        //      state), the successor row is already durably committed but the
        //      predecessor is NOT flipped. The estate now has two rows sharing a
        //      lineage with no clean active head. This is NOT a clean skip —
        //      surface as `.skippedWithPartialWrite` so the caller's import report
        //      makes the gap visible. The gap is structural (no transactional
        //      rollback at the PersistenceKit level); a reconciliation pass that
        //      calls `reindexMissing` and inspects the orphaned successor is the
        //      intended remediation path (the open 1.0 Vault posture owner-key ceremony, v1.1).
        let drawer: Drawer
        do {
            drawer = try await kit.capture(handle, frame, mode: .regular)
        } catch let verbErr as VerbError {
            if case .underlyingEstateFailure(_, let reason) = verbErr,
               reason.contains("DisciplineViolation") {
                // Case A vs B: distinguish by whether we were on the update path.
                // An update path (existing lineage) means the cascade was running
                // and may have committed the successor row before the violation.
                if isUpdate {
                    return .skippedWithPartialWrite(
                        reason: "belief-state transition not permitted after successor write "
                            + "(predecessor in non-Active state, supersession cascade Step 4 failed): \(reason)"
                    )
                } else {
                    return .skipped(reason: "belief-state transition not permitted (capture rejected): \(reason)")
                }
            }
            throw verbErr
        }

        // Apply KG facts from the note (data-movement privacy tiers / P0 BLOCKER
        // resolution: facts must land as substrate KG facts, not report-only).
        // Each FactIR triple becomes one KGFact anchored to the captured drawer.
        for fact in note.facts {
            _ = try await kit.captureKGFact(
                handle,
                subject: fact.subject,
                predicate: fact.predicate,
                object: fact.object,
                sourceDrawerID: drawer.id,
                now: now
            )
        }

        // Apply scope entries as KG facts (P0 BLOCKER resolution: scope must land
        // in the substrate, not as report-only drops). Each (key, value) pair
        // becomes a KGFact: subject = "scope:<key>", predicate = "has_value",
        // object = value, anchored to the captured drawer.
        for (key, value) in note.scope {
            _ = try await kit.captureKGFact(
                handle,
                subject: "scope:\(key)",
                predicate: "has_value",
                object: value,
                sourceDrawerID: drawer.id,
                now: now
            )
        }

        // Apply tags as KG facts (hard-close #29-A: user-authored tags must land
        // in a queryable/exportable durable form so they round-trip import→export).
        // Each tag t becomes a KGFact: subject = "tag:<t>", predicate = "tagged",
        // object = drawer.id (the stable drawer identifier), anchored to the drawer.
        // The export path reconstructs `NoteIR.tags` by querying for KG facts
        // whose subject has the "tag:" prefix on the drawer's source facts.
        for tag in note.tags {
            _ = try await kit.captureKGFact(
                handle,
                subject: "tag:\(tag)",
                predicate: "tagged",
                object: drawer.id,
                sourceDrawerID: drawer.id,
                now: now
            )
        }

        // Apply kind discriminator as a KG fact when the note is not the default
        // "note" kind (hard-close #29-B: non-"note" kind must land in a typed
        // durable record, not as a report-only drop). The kind field carries the
        // exchange format's open discriminator vocabulary ("fact", "journal", …).
        // subject = "record:kind", predicate = "is", object = the kind string.
        // The export path reads this fact back to reconstruct `NoteIR.kind`.
        if note.kind != "note" {
            _ = try await kit.captureKGFact(
                handle,
                subject: "record:kind",
                predicate: "is",
                object: note.kind,
                sourceDrawerID: drawer.id,
                now: now
            )
        }

        // `GeniusLocusKit` is an actor; `estate(for:)` is actor-isolated,
        // so the hop is awaited. It returns the live `LocusKit.Estate`
        // actor — GLK's sanctioned access point for the tunnel-capture
        // verb that the GLK verb surface does not itself re-export.
        // Fetched once here and shared by both the provenance-tunnel path
        // (Bug N fix) and the content-wikilink path below.
        let estate = try await kit.estate(for: handle)

        // Resolve the captured drawer's display names from the node tree
        // (node-tree integrity: Drawer no longer stores wing/room). These names are
        // needed for tunnel source endpoints and de-duplication signatures.
        let drawerNodeNames = try await estate.resolveNodeNames(
            parentNodeIds: [drawer.parentNodeId])
        let drawerWing = drawerNodeNames[drawer.parentNodeId]?.wing ?? ""
        let drawerRoom = drawerNodeNames[drawer.parentNodeId]?.room ?? ""
        var tunnelsCreated = 0

        // `_distilled_from` reconstruction retired (SPEC_DISTILLATION_STORAGE
        // §11.2/§13.2): the factoid tier no longer exists on 1.1.x and NO
        // new-write path may create `_distilled_from` tunnels. A
        // `distilled_from_sources` frontmatter key in an old export is
        // ignored; representations regenerate from content on sweep (§2).

        // Create tunnels for each wikilink, skipping any whose stable
        // endpoint+label signature already exists (re-import dedup; the
        // substrate's standalone tunnel capture performs a bare insert
        // with no native canonicalisation, so the bridge keys idempotency
        // on the signature).
        for link in note.links {
            let targetRoom = link.target.isEmpty ? "unresolved" : link.target
            let signature = Self.tunnelSignature(
                sourceWing: drawerWing,
                sourceRoom: drawerRoom,
                targetRoom: targetRoom,
                label: link.raw,
                kind: .references
            )
            guard !existingTunnelSignatures.contains(signature) else { continue }
            let tunnelFrame = TunnelCaptureFrame(
                sourceWing: drawerWing,
                sourceRoom: drawerRoom,
                targetWing: drawerWing,
                targetRoom: targetRoom,
                label: link.raw,
                addedBy: frame.addedBy,
                sourceDrawerId: drawer.id,
                targetDrawerId: nil,
                kind: .references,
                originClass: .imported
            )
            _ = try await estate.capture(tunnelFrame)
            existingTunnelSignatures.insert(signature)
            tunnelsCreated += 1
        }

        return isUpdate
            ? .updated(tunnelsCreated: tunnelsCreated, fdcClassified: classified)
            : .written(tunnelsCreated: tunnelsCreated, fdcClassified: classified)
    }

    /// Build the `CaptureFrame` for a note. Returns the frame plus whether
    /// a real classification (explicit frontmatter `udc`) was used, as
    /// opposed to the `"000"` unclassified sentinel.
    ///
    /// Pure with respect to the substrate. FDC classification for notes
    /// without an explicit frontmatter `udc` now happens in the
    /// GeniusLocusKit capture seam (one-door principle), not here.
    ///
    /// ## Identity resolution (Decision cp-vault-bidir)
    ///
    /// The `lineageID` on the frame is resolved in priority order:
    ///   1. `note.mootID` — the stable lineage UUID stamped on export.
    ///      Present when the note was exported by VaultKit. Wins over the
    ///      filename-derived FNV hash so a human can rename the file freely
    ///      without breaking the round-trip identity.
    ///   2. The frontmatter `moot_id` string parsed as a UUID (defensive
    ///      fallback for notes where `mootID` was not propagated in-process).
    ///   3. `lineageID(forStableSourceKey:)` — FNV-1a over the vault path,
    ///      used for brand-new human notes that were never exported by VaultKit.
    func makeCaptureFrame(for note: NoteIR, content: String) -> (CaptureFrame, classified: Bool) {
        // ## Structural-keys allowlist (CAND-003 injection defense)
        //
        // `makeCaptureFrame` reads only a named set of frontmatter keys that
        // have structural significance. Any key not in this allowlist has NO
        // effect on placement, identity, or privilege — it rides through
        // `note.frontmatter` as opaque pass-through and is re-emitted verbatim
        // on the next export. This means a forged extra key injected by an
        // attacker (e.g. via a newline in a room name that was NOT caught by
        // the export-side YAML quoting) cannot alter the capture frame — the
        // extra key is simply ignored here.
        //
        // STRUCTURAL keys consumed:
        //   room, wing, udc, addedBy, embeddingModelID, moot_id,
        //   wikidataQID, sensitivity,
        //   captureChannel (informational — not re-honored on import),
        //   contentKind (informational — not re-honored on import),
        //   created (→ eventTime via originDate), type (OKF tag — ignored).
        //
        // The export-side YAML quoting (`ObsidianAdapter.yamlScalarQuote`)
        // is the primary defense; this comment documents the secondary
        // (and pre-existing) defense: unknown frontmatter keys are harmless.
        //
        // Room resolution — priority order:
        //   1. Explicit frontmatter `room` (round-trip identity; always wins).
        //      For exports produced by VaultKit after wing organization, the `room`
        //      frontmatter key carries the substrate room verbatim, so re-imports
        //      of VaultKit-exported notes always land in the correct room.
        //   2. Wing-stripped pathComponents: if the vault path's first component
        //      matches the `wing` frontmatter key (wing organization layout: top-level
        //      folder IS the wing), strip it from pathComponents before joining.
        //      This handles human-authored notes placed under a wing folder in the
        //      vault where the frontmatter `room` key is absent. E.g., a note at
        //      "Professional/consulting/note.md" with `wing: Professional` in
        //      frontmatter maps to room = "consulting".
        //   3. Full hierarchy from `pathComponents` joined with "/" when more than
        //      one component is present (e.g. ["projects","alpha","notes"] →
        //      "projects/alpha/notes"). This maps vault hierarchy to room depth so
        //      the substrate reflects the source structure without loss.
        //   4. The leaf of `originalPath` (back-compat for callers that supply
        //      only originalPath).
        //   5. Hard default "imported" so I-5's non-empty room guard always holds.
        //
        // Wing resolution: `CaptureFrame.wing` routes the drawer into
        // a named wing at capture time. Priority order:
        //   1. Frontmatter `wing` key — always written by VaultKit on export, so
        //      a round-trip import restores the original wing faithfully.
        //   2. The first component of pathComponents when it matches no explicit
        //      frontmatter wing key — for human-authored notes placed in vault
        //      folders that follow the wing organization <wing>/<room>/<file>.md layout.
        //   3. nil — falls through to the estate's `defaultWingName` ("Agentic
        //      Memory") at the substrate capture seam. Human notes without any
        //      wing context land in the default wing and are not misassigned.
        let roomCandidate: String
        if let explicit = note.frontmatter["room"], !explicit.isEmpty {
            roomCandidate = explicit
        } else {
            // Determine pathComponents, stripping the wing prefix if the first
            // component matches the `wing` frontmatter value (wing organization vault layout).
            let components = note.pathComponents
            let wingKey = note.frontmatter["wing"] ?? ""
            let contentComponents: [String]
            if !wingKey.isEmpty, components.first == wingKey, components.count > 1 {
                // First component is the wing folder — strip it; the rest is the room path.
                contentComponents = Array(components.dropFirst())
            } else {
                contentComponents = components
            }

            if contentComponents.count > 1 {
                roomCandidate = contentComponents.joined(separator: "/")
            } else {
                roomCandidate = contentComponents.first
                    ?? note.originalPath.split(separator: "/").last.map(String.init)
                    ?? ""
            }
        }
        let room = roomCandidate.isEmpty ? "imported" : roomCandidate

        let addedByValue = nonEmpty(note.frontmatter["addedBy"]) ?? addedBy
        let modelValue = nonEmpty(note.frontmatter["embeddingModelID"]) ?? embeddingModelID

        // UDC resolution, in priority order:
        //   1. explicit frontmatter `udc` (a pre-classified note, preserved as-is)
        //   2. deterministic fallback "000" (the unclassified sentinel)
        //
        // Classification (EideticLib.lookup) was previously done here, but the
        // one-door principle mandates that ALL capture paths classify through the
        // same seam: GeniusLocusKit.capture(_:_:mode:). When the seam receives
        // a frame with sentinel "000" and non-empty content, it classifies via
        // EideticLib.lookup internally. Frontmatter `udc` (priority 1) flows
        // through unchanged because it is never "000" — the seam preserves any
        // non-sentinel anchor. Notes without frontmatter `udc` land with the
        // "000" sentinel and the seam classifies them on the way in.
        let resolvedUDC = nonEmpty(note.frontmatter["udc"])
        let classified = resolvedUDC != nil
        let udcCode = resolvedUDC ?? fallbackUDC

        var flags: DrawerFeatureFlags = []
        if !note.links.isEmpty { flags.insert(.hasLinks) }
        if note.source != nil { flags.insert(.hasAttachments) }

        // Identity resolution (see doc comment above):
        //   1. mootID field (set by ObsidianAdapter when frontmatter has moot_id)
        //   2. moot_id frontmatter string → UUID (defensive parse)
        //   3. FNV derivation from stableSourceKey (brand-new human notes)
        let resolvedLineageID: UUID = note.mootID
            ?? nonEmpty(note.frontmatter["moot_id"]).flatMap { UUID(uuidString: $0) }
            ?? Self.lineageID(forStableSourceKey: note.stableSourceKey)

        // Wing resolution (wing organization, see comment above for full priority order).
        // Frontmatter `wing` was written by VaultKit on export and is the
        // authoritative source for round-trip import. Human-authored notes with
        // no frontmatter wing are assigned nil → defaultWingName at the seam.
        let resolvedWing: String? = nonEmpty(note.frontmatter["wing"])

        var frame = CaptureFrame(
            content: content,
            channel: .importedFile,
            room: room,
            latticeAnchor: LatticeAnchor(
                udcCode: udcCode,
                wikidataQID: nonEmpty(note.frontmatter["wikidataQID"])
            ),
            addedBy: addedByValue,
            embeddingModelID: modelValue,
            // Sensitivity preserved from the IR when the adapter supplies it
            // (data-movement privacy tiers — import is ungated, but the tier rides in).
            // Absent or unrecognised labels land at the `.normal` capture
            // default rather than failing the import.
            sensitivity: nonEmpty(note.frontmatter["sensitivity"])
                .flatMap(Self.sensitivity(fromLabel:)) ?? .normal,
            kind: .prose,
            // Provenance: imported from a file. SourceType.imported (raw 2)
            // and Channel.fileImport (raw 3) record the import origin.
            provenanceChannel: .fileImport,
            sourceType: .imported,
            lineageID: resolvedLineageID,
            // Clamp the origin date to the RFC-3339 round-trippable range before
            // passing it into the CaptureFrame. The write side (ISO8601.string(from:)
            // in SQLiteConnection) also clamps and logs, so this is defence-in-depth:
            // a vault with a wildly out-of-range `created` frontmatter value (e.g.
            // year 58432 or year 0) won't become a poison timestamp in the drawers
            // table. Out-of-range dates are clamped silently here because the
            // ISO8601DateFormatter used by OccurredAt already rejects most poison
            // strings (returning nil), and a parsed-but-extreme Date is extremely
            // unlikely from standard vaults. The write-side clamp remains the
            // canonical guard and logs the clamp via OSLog.
            eventTime: note.originDate?.date.flatMap { d in
                let secs = d.timeIntervalSince1970
                if secs < -62_135_596_800 || secs > 253_402_300_799 {
                    // Return nil: let the substrate use the insertion clock.
                    // The write-side clamp in SQLiteConnection will also catch
                    // any value that slips through as the last line of defence.
                    return nil
                }
                return d
            },
            featureFlags: flags
        )
        // Wire the wing into the frame so the capture verb routes the drawer into
        // the correct wing at write time. nil → defaultWingName at seam.
        frame.wing = resolvedWing
        return (frame, classified: classified)
    }

    // MARK: - Idempotency helpers

    /// Derive a deterministic `lineageID` from a note's stable source key
    /// so a re-import of the same note supersedes its drawer instead of
    /// duplicating it.
    ///
    /// Uses FNV-1a (128-bit) over the key's UTF-8 bytes — a non-
    /// cryptographic but stable, dependency-free, and language-neutral
    /// hash, so the Rust port reproduces the same lineage IDs by
    /// implementing the same well-known algorithm rather than calling a
    /// Swift-only crypto API. Collision resistance is not a security
    /// property here; distinct keys must map to distinct lineages, which
    /// a 128-bit FNV space provides for any realistic vault.
    public static func lineageID(forStableSourceKey key: String) -> UUID {
        // FNV-1a 128-bit constants (offset basis and prime).
        let offset = (high: UInt64(0x6c62272e07bb0142), low: UInt64(0x62b821756295c58d))
        let prime = (high: UInt64(0x0000000001000000), low: UInt64(0x000000000000013B))
        var h = offset
        for byte in key.utf8 {
            // XOR the low byte.
            h.low ^= UInt64(byte)
            // 128-bit multiply h * prime (mod 2^128).
            h = multiply128(h, prime)
        }
        return uuid(fromHigh: h.high, low: h.low)
    }

    /// 128-bit multiply (mod 2^128) of two (high, low) pairs.
    private static func multiply128(
        _ a: (high: UInt64, low: UInt64),
        _ b: (high: UInt64, low: UInt64)
    ) -> (high: UInt64, low: UInt64) {
        // low*low gives the full 128-bit base product; cross terms add into
        // the high word (their overflow beyond 2^128 is discarded mod 2^128).
        let lowProduct = a.low.multipliedFullWidth(by: b.low)
        var high = lowProduct.high
        high = high &+ (a.high &* b.low)
        high = high &+ (a.low &* b.high)
        return (high: high, low: lowProduct.low)
    }

    /// Pack a 128-bit hash into a `UUID`'s 16 bytes (big-endian high then
    /// low). The bytes are used as-is; uniqueness, not RFC-4122 version
    /// semantics, is what the lineage contract needs.
    private static func uuid(fromHigh high: UInt64, low: UInt64) -> UUID {
        func bytes(_ v: UInt64) -> [UInt8] {
            (0..<8).map { UInt8((v >> (56 - $0 * 8)) & 0xFF) }
        }
        let b = bytes(high) + bytes(low)
        return UUID(uuid: (
            b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
            b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]
        ))
    }

    // MARK: - Sensitivity frontmatter labels

    /// Canonical frontmatter label for each sensitivity tier. The labels are
    /// the lowercase case names and are shared verbatim with the Rust port so
    /// vaults round-trip across implementations.
    static func sensitivityLabel(_ s: AdjectiveSensitivity) -> String {
        switch s {
        case .normal: return "normal"
        case .elevated: return "elevated"
        case .restricted: return "restricted"
        case .secret: return "secret"
        }
    }

    /// Inverse of `sensitivityLabel(_:)`. Returns nil for unrecognised
    /// labels; the caller falls back to the `.normal` capture default.
    static func sensitivity(fromLabel label: String) -> AdjectiveSensitivity? {
        switch label {
        case "normal": return .normal
        case "elevated": return .elevated
        case "restricted": return .restricted
        case "secret": return .secret
        default: return nil
        }
    }

    /// Frontmatter label for a drawer's exportability adjective. Inverse
    /// of `exportability(fromLabel:)`.
    static func exportabilityLabel(_ e: AdjectiveExportability) -> String {
        switch e {
        case .private_: return "private"
        case .public_: return "public"
        }
    }

    /// Inverse of `exportabilityLabel(_:)`. Returns nil for unrecognised
    /// labels; the import caller then applies its policy default (public
    /// for already-public palace sources). Mirrors `sensitivity(fromLabel:)`.
    static func exportability(fromLabel label: String) -> AdjectiveExportability? {
        switch label {
        case "private": return .private_
        case "public": return .public_
        default: return nil
        }
    }

    /// Stable signature for tunnel de-duplication. Keyed on the endpoint
    /// wing/room, the target room, the raw label, and the kind — all
    /// stable across re-imports (unlike the source drawer id, which the
    /// supersession cascade re-mints).
    static func tunnelSignature(
        sourceWing: String,
        sourceRoom: String,
        targetRoom: String,
        label: String,
        kind: TunnelKind
    ) -> String {
        "\(sourceWing)\u{1F}\(sourceRoom)\u{1F}\(targetRoom)\u{1F}\(label)\u{1F}\(kind.rawValue)"
    }

    /// Nil when the optional string is nil or empty; the value otherwise.
    private func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}
