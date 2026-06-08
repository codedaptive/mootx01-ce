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

    /// Read an estate's drawers and outgoing `.references` tunnels and
    /// project each drawer to a `NoteIR`.
    ///
    /// Drawers are recalled using the `scope` parameter's filter chain.
    /// The default scope `.believed` includes currently-believed drawers
    /// with any confirmation state — fixing the confirmed-drop bug that
    /// occurred when the filter was hard-coded to `.unconfirmed` (confirmed
    /// drawers were silently excluded from export). Tunnels are read per
    /// wing; only `.references` edges originating at the drawer become
    /// wikilinks (ADR-VAULTKIT-001 (a)/(d)).
    ///
    /// - Parameters:
    ///   - kit: the open `GeniusLocusKit` instance.
    ///   - handle: the estate handle.
    ///   - scope: which drawers to include. Defaults to `.believed`.
    public func export(
        kit: GeniusLocusKit,
        handle: EstateHandle,
        scope: VaultExportScope = .believed
    ) async throws -> [NoteIR] {
        // VK-EXPORT-FIX: pass an explicit limit so the GLK convenience overload
        // does not apply its default cap of 50. Export is a full projection of
        // all believed drawers — it is a pure filter scan (no query, no scoring),
        // so returning the complete set in stable order is correct. The limit is
        // set to 10_000_000 (ten million) rather than Int.max because the Recall
        // Director computes `frontierK = min(max(limit * 4, 64), 256)` on line 55
        // of RecallDirector.swift and `Int.max * 4` overflows in Swift debug builds.
        // Ten million is unreachable by any realistic estate; the locusOnly lane
        // drains all pages until exhausted well before this limit.
        let drawers = try await kit.recall(
            handle,
            RecallFrame(filterChain: scope.filterChain, hydrationLevel: .full, limit: 10_000_000)
        )
        // Fetch tunnels once per distinct source wing, not once per drawer.
        var tunnelsByWing: [String: [Tunnel]] = [:]
        for wing in Set(drawers.map(\.wing)) {
            tunnelsByWing[wing] = try await kit.recallTunnels(handle, wing: wing)
        }

        return drawers.map { drawer in
            let outgoing = (tunnelsByWing[drawer.wing] ?? []).filter {
                $0.sourceDrawerId == drawer.id && $0.kind == .references
            }
            return Self.noteIR(from: drawer, references: outgoing)
        }
    }

    /// Pure projection of one drawer (+ its outgoing `.references`
    /// tunnels) to a `NoteIR`. No substrate access — testable in isolation.
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
    static func noteIR(from drawer: Drawer, references: [Tunnel]) -> NoteIR {
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

        // Each `.references` tunnel's label carries the raw wikilink text
        // that produced it on import, so export renders it back verbatim.
        let links = references.map { WikiLink(target: $0.label, alias: nil, raw: $0.label) }

        return NoteIR(
            stableSourceKey: stableKey,
            body: [Block(kind: "markdown", text: drawer.content)],
            frontmatter: frontmatter,
            links: links,
            tags: [],
            originalPath: drawer.room,
            originDate: OccurredAt(date: drawer.eventTime),
            source: nil,
            mootID: drawer.lineageID
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
    public func importNote(
        _ note: NoteIR,
        kit: GeniusLocusKit,
        handle: EstateHandle,
        existingLineageIDs: Set<UUID>,
        existingTunnelSignatures: inout Set<String>
    ) async throws -> ImportOutcome {
        let content = note.flattenedBody
        // I-5: empty content cannot be captured. Skip rather than emit a
        // frame the substrate will reject.
        guard !content.isEmpty else {
            return .skipped(reason: "empty content (I-5: content must be non-empty)")
        }

        let (frame, classified) = makeCaptureFrame(for: note, content: content)
        let lineage = frame.lineageID ?? Self.lineageID(forStableSourceKey: note.stableSourceKey)
        let isUpdate = existingLineageIDs.contains(lineage)

        let drawer = try await kit.capture(handle, frame)

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
        // Room: explicit frontmatter wins; else the note's folder; else a
        // non-empty default so I-5's room guard holds.
        let roomCandidate = note.frontmatter["room"]
            ?? note.originalPath.split(separator: "/").last.map(String.init)
            ?? ""
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
            kind: .prose,
            // Provenance: imported from a file. SourceType.imported (raw 2)
            // and Channel.fileImport (raw 3) record the import origin.
            provenanceChannel: .fileImport,
            sourceType: .imported,
            lineageID: resolvedLineageID,
            eventTime: note.originDate?.date,
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
