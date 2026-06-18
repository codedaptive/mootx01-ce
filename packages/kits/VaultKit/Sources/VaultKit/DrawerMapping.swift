import Foundation
import GeniusLocusKit
import LocusKit
import EideticLib

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
/// supplied from the FDC anchor when EideticLib resolves it, and from the
/// deterministic fallback `"000"` otherwise (ADR-VAULTKIT-001 (g)).
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

    /// When true, import attempts FDC classification via EideticLib and
    /// uses the live anchor when one resolves. When false (or when the
    /// lookup does not resolve), the note lands with the fallback UDC and
    /// provenance intact — no classification is faked either way.
    public var classifyOnImport: Bool

    /// The deterministic fallback UDC used when no live FDC anchor and no
    /// explicit frontmatter `udc` is available. `"000"` is the repo's
    /// established sentinel for unclassified/migrated content
    /// (GeniusLocusKit `MigrationAPI`). Lets every import satisfy I-5
    /// without inventing a classification.
    public let fallbackUDC: String = "000"

    public init(
        addedBy: String = "vaultkit-import",
        embeddingModelID: String = "vaultkit-noembed-v1",
        classifyOnImport: Bool = true
    ) {
        self.addedBy = addedBy
        self.embeddingModelID = embeddingModelID
        self.classifyOnImport = classifyOnImport
    }

    // MARK: - Export: estate → IR

    /// The notes an export projects plus the per-tier exclusion counts the
    /// ADR-007 Decision 2 bulk-channel rules produced. Exclusions are
    /// reported, never silent (zero-loss reporting symmetry with C-13).
    public struct ExportProjection: Sendable {
        /// Drawers that passed the scope filters AND the tier rules,
        /// projected to `NoteIR`.
        public var notes: [NoteIR]
        /// Secret-tier drawers the scope filters admitted but the bulk
        /// channel excluded. Secret never rides bulk export, under any
        /// scope (ADR-007 Decision 2).
        public var excludedSecretTier: Int
        /// Private-tier (`.restricted`) drawers the scope filters admitted
        /// but the bulk channel excluded because the scope does not carry
        /// the explicit private-tier opt-in (`includesPrivateTier`).
        public var excludedPrivateTier: Int
    }

    /// Read an estate's drawers and outgoing `.references` tunnels and
    /// project each drawer to a `NoteIR`, enforcing the ADR-007 Decision 2
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
    /// included drawer become wikilinks (ADR-VAULTKIT-001 (a)/(d)).
    ///
    /// - Parameters:
    ///   - kit: the open `GeniusLocusKit` instance.
    ///   - handle: the estate handle.
    ///   - scope: which drawers to include. Defaults to `.believed`.
    public func export(
        kit: GeniusLocusKit,
        handle: EstateHandle,
        scope: VaultExportScope = .believed
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

        // ADR-007 Decision 2 tier partition. The predicates encode the
        // normative 4→3 mapping (Normal → normal+elevated, Private →
        // restricted, Secret → secret) — see AdjectiveSensitivity in LocusKit.
        var drawers: [Drawer] = []
        var excludedSecret = 0
        var excludedPrivate = 0
        for drawer in recalled {
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
        var tunnelsByWing: [String: [Tunnel]] = [:]
        for wing in Set(drawers.map(\.wing)) {
            tunnelsByWing[wing] = try await kit.recallTunnels(handle, wing: wing)
        }

        // Query all KG facts once for the estate, then group by sourceDrawerID
        // so each drawer's tags and kind can be reconstructed without an
        // N-per-drawer round-trip. Drawers with no KG facts get an empty slice.
        let allKGFacts = try await kit.recallKGFacts(handle)
        var kgFactsByDrawerID: [String: [KGFact]] = [:]
        for fact in allKGFacts {
            if !fact.sourceDrawerID.isEmpty {
                kgFactsByDrawerID[fact.sourceDrawerID, default: []].append(fact)
            }
        }

        let notes = drawers.map { drawer in
            let outgoing = (tunnelsByWing[drawer.wing] ?? []).filter {
                $0.sourceDrawerId == drawer.id && $0.kind == .references
            }
            let drawerFacts = kgFactsByDrawerID[drawer.id] ?? []
            return Self.noteIR(from: drawer, references: outgoing, kgFacts: drawerFacts)
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
    /// ## Filename / path (Decision cp-vault-bidir)
    ///
    /// The vault path is `"<room>/<slug>.md"` — the wing prefix is dropped
    /// because one vault has one owner (wing rides frontmatter). The slug
    /// is derived from the first markdown heading or the first non-empty
    /// content line, sanitized to a safe filename character set. On
    /// collision within the caller's export set, a short suffix derived
    /// from `drawer.lineageID` is appended. The result is deterministic
    /// given the drawer.
    ///
    /// ## `moot_id` frontmatter (Decision cp-vault-bidir)
    ///
    /// `moot_id` is the STABLE lineage UUID (`drawer.lineageID`) — not
    /// `drawer.id`, which the supersession cascade re-mints on every
    /// write. Re-importing an exported note with `moot_id` maps back to
    /// the same substrate lineage regardless of filename changes.
    static func noteIR(from drawer: Drawer, references: [Tunnel], kgFacts: [KGFact] = []) -> NoteIR {
        // Path: room/slug.md — wing prefix dropped (one vault, one owner;
        // wing rides frontmatter). The stable key carries NO wing prefix.
        let slug = Self.slug(from: drawer.content, id: drawer.lineageID)
        let stableKey = "\(drawer.room)/\(slug)"

        var frontmatter: [String: String] = [
            "wing": drawer.wing,
            "room": drawer.room,
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
        // (ADR-007 Decision 2; import reads the key back into
        // `CaptureFrame.sensitivity`). `.normal` is omitted — it is the
        // capture default, so absence round-trips to the same value and
        // pre-existing exports stay byte-identical.
        if drawer.adjectiveSensitivity != .normal {
            frontmatter["sensitivity"] = Self.sensitivityLabel(drawer.adjectiveSensitivity)
        }

        // Each `.references` tunnel's label carries the raw wikilink text
        // that produced it on import, so export renders it back verbatim.
        let links = references.map { WikiLink(target: $0.label, alias: nil, raw: $0.label) }

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
            originalPath: drawer.room,
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
    }

    /// Import one note: build a `CaptureFrame`, capture the drawer through
    /// the GLK verb surface, then create the note's `.references` tunnels
    /// (de-duplicated against `existingTunnelSignatures` so a re-import
    /// adds no duplicates).
    ///
    /// Idempotency is keyed on `stableSourceKey`: the derived `lineageID`
    /// is deterministic, so a re-import of the same note triggers the
    /// substrate's supersession cascade rather than creating a parallel
    /// drawer. `existingLineageIDs` lets the caller report written vs.
    /// updated without a second probe.
    ///
    /// `existingSensitivityByLineage` carries the current sensitivity tier of
    /// every believed drawer (across ALL tiers) so the sensitivity FLOOR can
    /// be enforced on re-import: a re-import may RAISE a drawer's tier but
    /// never LOWER it. This closes the supersession-downgrade attack — a
    /// hostile vault file carrying a victim's `moot_id` (exposed in exported
    /// notes by design) plus `sensitivity: normal` would otherwise downgrade
    /// the victim drawer via the supersession cascade, after which it would
    /// ride bulk export. Import is ungated for arrival, but it must not be a
    /// declassification channel (ADR-007 Decision 2 threat model).
    public func importNote(
        _ note: NoteIR,
        kit: GeniusLocusKit,
        handle: EstateHandle,
        existingLineageIDs: Set<UUID>,
        existingSensitivityByLineage: [UUID: AdjectiveSensitivity],
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
        let lineage = frame.lineageID ?? Self.lineageID(forStableSourceKey: note.stableSourceKey)
        let isUpdate = existingLineageIDs.contains(lineage)

        // Sensitivity floor: a re-import never lowers an existing drawer's
        // tier. Raw values are tier-ordered (normal 0 < elevated 16 <
        // restricted 32 < secret 48), so a numeric max is the floor.
        if let existingTier = existingSensitivityByLineage[lineage],
           existingTier.rawValue > frame.sensitivity.rawValue {
            frame.sensitivity = existingTier
        }

        // mode: .regular — enqueues an EncodeJob onto the estate's encode queue
        // so the drain worker ingests the drawer into the Corpus (BM25 + vector).
        // The legacy no-mode overload stored the drawer row only, leaving the
        // BM25/vector semantic lanes dark for all imported content (the bug proven
        // on the real estate: 2354 drawers, node_bundles=0). Using .regular here
        // is the correct choice for bulk import: capture returns immediately and
        // encoding is handled in the background, so large imports don't block.
        let drawer = try await kit.capture(handle, frame, mode: .regular)

        // Apply KG facts from the note (ADR-007 Decision 1 / P0 BLOCKER
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

        // Create tunnels for each wikilink, skipping any whose stable
        // endpoint+label signature already exists (re-import dedup; the
        // substrate's standalone tunnel capture performs a bare insert
        // with no native canonicalisation, so the bridge keys idempotency
        // on the signature).
        // `GeniusLocusKit` is an actor; `estate(for:)` is actor-isolated,
        // so the hop is awaited. It returns the live `LocusKit.Estate`
        // actor — GLK's sanctioned access point for the tunnel-capture
        // verb that the GLK verb surface does not itself re-export.
        let estate = try await kit.estate(for: handle)
        var tunnelsCreated = 0
        for link in note.links {
            let targetRoom = link.target.isEmpty ? "unresolved" : link.target
            let signature = Self.tunnelSignature(
                sourceWing: drawer.wing,
                sourceRoom: drawer.room,
                targetRoom: targetRoom,
                label: link.raw,
                kind: .references
            )
            guard !existingTunnelSignatures.contains(signature) else { continue }
            let tunnelFrame = TunnelCaptureFrame(
                sourceWing: drawer.wing,
                sourceRoom: drawer.room,
                targetWing: drawer.wing,
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
    /// a real classification (live FDC anchor or an explicit frontmatter
    /// `udc`) was used, as opposed to the `"000"` fallback.
    ///
    /// Pure with respect to the substrate; the only outside call is the
    /// deterministic, network-free `EideticLib.lookup`.
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
        // Room resolution — priority order:
        //   1. Explicit frontmatter `room` (round-trip identity; always wins).
        //   2. Full hierarchy from `pathComponents` joined with "/" when more than
        //      one component is present (e.g. ["projects","alpha","notes"] →
        //      "projects/alpha/notes"). This maps vault hierarchy to room depth so
        //      the substrate reflects the source structure without loss.
        //   3. The leaf of `originalPath` (back-compat for callers that supply
        //      only originalPath).
        //   4. Hard default "imported" so I-5's non-empty room guard always holds.
        let roomCandidate: String
        if let explicit = note.frontmatter["room"], !explicit.isEmpty {
            roomCandidate = explicit
        } else if note.pathComponents.count > 1 {
            roomCandidate = note.pathComponents.joined(separator: "/")
        } else {
            roomCandidate = note.pathComponents.first
                ?? note.originalPath.split(separator: "/").last.map(String.init)
                ?? ""
        }
        let room = roomCandidate.isEmpty ? "imported" : roomCandidate

        let addedByValue = nonEmpty(note.frontmatter["addedBy"]) ?? addedBy
        let modelValue = nonEmpty(note.frontmatter["embeddingModelID"]) ?? embeddingModelID

        // UDC resolution, in priority order:
        //   1. explicit frontmatter `udc` (a pre-classified note)
        //   2. live FDC anchor from EideticLib (when classifyOnImport)
        //   3. deterministic fallback "000"
        var resolvedUDC = nonEmpty(note.frontmatter["udc"])
        var classified = resolvedUDC != nil
        if resolvedUDC == nil, classifyOnImport {
            let anchor = EideticLib.lookup(content)
            if !anchor.code.isEmpty {
                resolvedUDC = anchor.code
                classified = true
            }
        }
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

        let frame = CaptureFrame(
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
            // (ADR-007 Decision 2 — import is ungated, but the tier rides in).
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
