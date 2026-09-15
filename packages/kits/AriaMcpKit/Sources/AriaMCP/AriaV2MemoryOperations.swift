import Foundation
import CognitionKit
import GeniusLocusKit
import LocusKit
import AriaMCPWire

/// The v2 memory-operation context is deliberately explicit.  ARIA owns the
/// caller identity, clock, sensitivity ceiling, and usage ledger; the estate
/// backend owns durable capture and retrieval.  This keeps the v2 surface from
/// borrowing mutable state from `ToolDispatcher` or reparsing a legacy reply.
public struct AriaV2MemoryOperationContext: Sendable {
    public let estateID: UUID
    public let callerID: String
    public let serverIdentity: String
    public let now: @Sendable () -> Date
    public let maximumSensitivity: AdjectiveSensitivity
    /// First-party policy may narrow every read to material explicitly marked
    /// exportable. This is additive to the sensitivity ceiling.
    public let exportableOnly: Bool
    public let recallOrigin: RecallOrigin
    public let usageLedger: any AriaV2MemoryUsageLedger
    /// The un-collapsed sensitivity-grant ceiling, `nil` when no grant is
    /// live. `maximumSensitivity` above is the value ALREADY collapsed to
    /// `.elevated` when no grant is live (`sensitivityGrant ?? .elevated` at
    /// the ToolDispatch construction site), so it cannot distinguish "no
    /// grant" from "a grant that ceilings at elevated" — which is exactly
    /// the distinction the sensitivity-read-under-grant audit needs to know
    /// whether a restricted/secret row's admission depended on a live
    /// grant. Carrying the Optional here (rather than a derived Bool) keeps
    /// the same shape `AriaV2PacketOperations.grantCeiling` already
    /// established for the identical problem. Defaults to `nil` so every
    /// existing constructor (including the three test constructors) keeps
    /// compiling unchanged.
    public let grantCeiling: AdjectiveSensitivity?

    public init(
        estateID: UUID,
        callerID: String,
        serverIdentity: String,
        now: @escaping @Sendable () -> Date = { Date() },
        maximumSensitivity: AdjectiveSensitivity = .elevated,
        exportableOnly: Bool = false,
        recallOrigin: RecallOrigin = .external,
        usageLedger: any AriaV2MemoryUsageLedger = AriaV2NoopMemoryUsageLedger(),
        grantCeiling: AdjectiveSensitivity? = nil
    ) {
        self.estateID = estateID
        self.callerID = callerID
        self.serverIdentity = serverIdentity
        self.now = now
        self.maximumSensitivity = maximumSensitivity
        self.exportableOnly = exportableOnly
        self.recallOrigin = recallOrigin
        self.usageLedger = usageLedger
        self.grantCeiling = grantCeiling
    }
}

/// This is the only session-state seam needed by the three memory operations.
/// A production implementation can attach the existing recall usage ledger;
/// tests can prove the same calls without constructing a dispatcher.
public protocol AriaV2MemoryUsageLedger: Sendable {
    func recordSurfaced(_ memoryIDs: [UUID], estateID: UUID, callerID: String, at: Date) async
    func recordDereferenced(_ memoryIDs: [UUID], estateID: UUID, callerID: String, at: Date) async
}

public struct AriaV2NoopMemoryUsageLedger: AriaV2MemoryUsageLedger {
    public init() {}
    public func recordSurfaced(_ memoryIDs: [UUID], estateID: UUID, callerID: String, at: Date) async {}
    public func recordDereferenced(_ memoryIDs: [UUID], estateID: UUID, callerID: String, at: Date) async {}
}

public enum AriaV2MemoryDepth: String, Sendable, Equatable, CaseIterable {
    case subject
    case distilled
    case skim
    case full
}

public enum AriaV2MemorySensitivity: String, Sendable, Equatable, CaseIterable {
    case normal
    case elevated
    case restricted
    case secret

    var locusValue: AdjectiveSensitivity {
        switch self {
        case .normal: .normal
        case .elevated: .elevated
        case .restricted: .restricted
        case .secret: .secret
        }
    }
}

public enum AriaV2MemoryExportability: String, Sendable, Equatable, CaseIterable {
    case `private`
    case `public`

    var locusValue: AdjectiveExportability {
        switch self {
        case .private: .private_
        case .public: .public_
        }
    }
}

public enum AriaV2MemoryKind: String, Sendable, Equatable, CaseIterable {
    case prose
    case code
    case transcript
    case list
    case structuredJSON = "structured_json"
    case imageCaption = "image_caption"

    var locusValue: ContentKind {
        switch self {
        case .prose: .prose
        case .code: .code
        case .transcript: .transcript
        case .list: .list
        case .structuredJSON: .structuredJSON
        case .imageCaption: .imageCaption
        }
    }
}

public struct AriaV2FileMemoryRequest: Sendable, Equatable {
    public let content: String
    public let subject: String
    public let location: String
    public let wing: String?
    public let sensitivity: AriaV2MemorySensitivity
    public let exportability: AriaV2MemoryExportability
    public let kind: AriaV2MemoryKind
    public let eventTime: Date?
    public let impatient: Bool
    public let estateID: UUID?

    public init(arguments: JSONValue) throws {
        let decoder = try AriaV2ArgumentDecoder(arguments, allowedKeys: [
            "content", "subject", "location", "wing", "sensitivity", "exportability",
            "kind", "event_time", "impatient", "estate_id",
        ])
        content = try Self.nonEmpty(decoder.requireString("content"), path: "content")
        subject = try Self.subject(decoder.requireString("subject"))
        location = try Self.nonEmpty(decoder.requireString("location"), path: "location")
        wing = try decoder.optionalString("wing")
        sensitivity = try Self.enumValue(
            try decoder.optionalString("sensitivity") ?? AriaV2MemorySensitivity.normal.rawValue,
            path: "sensitivity", type: AriaV2MemorySensitivity.self)
        exportability = try Self.enumValue(
            try decoder.optionalString("exportability") ?? AriaV2MemoryExportability.private.rawValue,
            path: "exportability", type: AriaV2MemoryExportability.self)
        kind = try Self.enumValue(
            try decoder.optionalString("kind") ?? AriaV2MemoryKind.prose.rawValue,
            path: "kind", type: AriaV2MemoryKind.self)
        eventTime = try Self.date(try decoder.optionalString("event_time"), path: "event_time")
        impatient = try decoder.optionalBoolean("impatient") ?? false
        estateID = try decoder.optionalUUID("estate_id")
    }
}

public struct AriaV2MemorySearchRequest: Sendable, Equatable {
    public static let defaultLimit = 20
    public static let maximumLimit = 500

    public let query: String?
    public let near: UUID?
    public let limit: Int
    // Eight restored arguments (validated at decode; raw strings stored to preserve Equatable).
    public let filter: String?
    public let wing: String?
    public let mediaType: String?
    public let door: String?
    public let scoringKey: String?
    // ordering defaults to "byCaptureTimeDesc"; "byRelevanceDesc" is a compatibility
    // spelling routed to the scored recall path at the ARIA boundary.
    public let ordering: String
    public let frontierK: Int64?
    public let explain: Bool
    /// Validated at decode; unknown values return -32602 INVALID_PARAMS.
    public let answer: PackagerAnswerMode
    public let estateID: UUID?

    public init(arguments: JSONValue) throws {
        let decoder = try AriaV2ArgumentDecoder(arguments, allowedKeys: [
            "query", "near", "limit", "filter", "wing", "media_type", "explain", "door",
            "scoring", "ordering", "frontier_k", "answer", "estate_id",
        ])
        let selected = try decoder.requireExactlyOne(of: ["query", "near"])
        if selected == "query" {
            query = try AriaV2FileMemoryRequest.nonEmpty(try decoder.requireString("query"), path: "query")
            near = nil
        } else {
            query = nil
            near = try decoder.requireUUID("near")
        }
        if let rawLimit = try decoder.optionalInteger("limit") {
            guard rawLimit >= 1, rawLimit <= Int64(Self.maximumLimit) else {
                throw AriaV2FileMemoryRequest.invalid(path: "limit", message: "Argument 'limit' must be between 1 and \(Self.maximumLimit).")
            }
            limit = Int(rawLimit)
        } else {
            limit = Self.defaultLimit
        }
        // answer: validate at decode; unknown values fail closed — never silently coerce
        // a typo to "never". PackagerAnswerMode.init(rawValue:) returns nil on unknown strings.
        let rawAnswer = try decoder.optionalString("answer") ?? PackagerAnswerMode.never.rawValue
        guard let answerMode = PackagerAnswerMode(rawValue: rawAnswer) else {
            throw AriaV2FileMemoryRequest.invalid(
                path: "answer",
                message: "Unknown answer: \(rawAnswer). Valid: never, always, auto"
            )
        }
        answer = answerMode
        // filter: validate against known values; fail closed on unknown strings.
        let rawFilter = try decoder.optionalString("filter")
        if let f = rawFilter {
            let valid = ["unconfirmed", "userConfirmed", "exportable", "contained", "pinned"]
            guard valid.contains(f) else {
                throw AriaV2FileMemoryRequest.invalid(
                    path: "filter",
                    message: "Unknown filter: \(f). Valid: \(valid.joined(separator: ", "))"
                )
            }
        }
        filter = rawFilter
        // wing: no accept-list — any estate wing name is valid.
        wing = try decoder.optionalString("wing")
        // media_type: constrain to known capture types; unknown values fail closed.
        let rawMediaType = try decoder.optionalString("media_type")
        if let mt = rawMediaType {
            guard ["voice", "image"].contains(mt) else {
                throw AriaV2FileMemoryRequest.invalid(
                    path: "media_type",
                    message: "Unknown media_type: \(mt). Valid: voice, image"
                )
            }
        }
        mediaType = rawMediaType
        // door: 'guess' reads A1 DoorManifest; known scoring rawValues bypass it.
        // Reserved names ('hedge', 'thorough') and any unknown string fail closed.
        let rawDoor = try decoder.optionalString("door")
        if let d = rawDoor {
            let valid = ["guess", "raw", "rrf", "matrixAware", "discriminative"]
            guard valid.contains(d) else {
                throw AriaV2FileMemoryRequest.invalid(
                    path: "door",
                    message: "Unknown door: \(d). Valid: guess, raw, rrf, matrixAware, discriminative"
                )
            }
        }
        door = rawDoor
        // scoring: explicit override when door is absent; fail closed on unknown values.
        let rawScoringKey = try decoder.optionalString("scoring")
        if let s = rawScoringKey {
            guard GLKRecallScoring(rawValue: s) != nil else {
                throw AriaV2FileMemoryRequest.invalid(
                    path: "scoring",
                    message: "Unknown scoring: \(s). Valid: raw, rrf, matrixAware, discriminative"
                )
            }
        }
        scoringKey = rawScoringKey
        // ordering: accept-list includes 'byRelevanceDesc' as a compatibility spelling.
        let rawOrdering = try decoder.optionalString("ordering") ?? "byCaptureTimeDesc"
        let validOrderings = ["byCaptureTimeDesc", "byCaptureTimeAsc", "byRoomAsc", "byRelevanceDesc"]
        guard validOrderings.contains(rawOrdering) else {
            throw AriaV2FileMemoryRequest.invalid(
                path: "ordering",
                message: "Unknown ordering: \(rawOrdering). Valid: \(validOrderings.joined(separator: ", "))"
            )
        }
        ordering = rawOrdering
        // frontier_k: passed through to GLKRecallRequest without clamping here;
        // the GLK engine clamps to [frontierKFloor, frontierKCeiling] internally.
        frontierK = try decoder.optionalInteger("frontier_k")
        explain = try decoder.optionalBoolean("explain") ?? false
        estateID = try decoder.optionalUUID("estate_id")
    }
}

public struct AriaV2MemoryGetRequest: Sendable, Equatable {
    public static let maximumIDs = 50

    public let memoryIDs: [UUID]
    public let depth: AriaV2MemoryDepth
    public let estateID: UUID?

    public init(memoryIDs: [UUID], depth: AriaV2MemoryDepth, estateID: UUID?) {
        self.memoryIDs = memoryIDs
        self.depth = depth
        self.estateID = estateID
    }

    public init(arguments: JSONValue) throws {
        let decoder = try AriaV2ArgumentDecoder(arguments, allowedKeys: ["memory_id", "memory_ids", "depth", "estate_id"])
        let selected = try decoder.requireExactlyOne(of: ["memory_id", "memory_ids"])
        if selected == "memory_id" {
            memoryIDs = [try decoder.requireUUID("memory_id")]
        } else {
            guard let values = decoder.arguments["memory_ids"]?.arrayValue, !values.isEmpty else {
                throw AriaV2FileMemoryRequest.invalid(path: "memory_ids", message: "Argument 'memory_ids' must be a non-empty UUID array.")
            }
            guard values.count <= Self.maximumIDs else {
                throw AriaV2FileMemoryRequest.invalid(path: "memory_ids", message: "Argument 'memory_ids' may contain at most \(Self.maximumIDs) UUIDs.")
            }
            memoryIDs = try values.enumerated().map { index, value in
                guard let raw = value.stringValue, let id = UUID(uuidString: raw) else {
                    throw AriaV2FileMemoryRequest.invalid(path: "memory_ids[\(index)]", message: "Argument 'memory_ids[\(index)]' must be a UUID.")
                }
                return id
            }
            guard Set(memoryIDs).count == memoryIDs.count else {
                throw AriaV2FileMemoryRequest.invalid(path: "memory_ids", message: "Argument 'memory_ids' must not contain duplicates.")
            }
        }
        depth = try AriaV2FileMemoryRequest.enumValue(
            try decoder.optionalString("depth") ?? AriaV2MemoryDepth.full.rawValue,
            path: "depth", type: AriaV2MemoryDepth.self)
        estateID = try decoder.optionalUUID("estate_id")
    }
}

public struct AriaV2MemoryRecord: Sendable, Equatable {
    public let memoryID: UUID
    public let subject: String?
    public let content: String
    public let wing: String
    public let room: String
    public let filedAt: Date
    public let eventTime: Date
    public let state: String
    public let trust: String
    public let sensitivity: String
    public let exportability: String
    public let confirmation: String
    public let lineageID: UUID
    public let provenance: String?
    public let context: String?
    public let isAuthorized: Bool
    /// Active linked tunnels for depth:full. Empty for depth:subject and
    /// depth:distilled (mirrors v1 which only queried tunnels on the full-record
    /// path). Sensitivity-filtered: tunnel sensitivity <= request ceiling, and
    /// far-endpoint drawer (when present) also <= ceiling.
    public let tunnels: [AriaV2TunnelRow]

    public init(memoryID: UUID, subject: String? = nil, content: String = "", wing: String = "", room: String = "", filedAt: Date, eventTime: Date, state: String = "active", trust: String = "verbatim", sensitivity: String = "normal", exportability: String = "private", confirmation: String = "unconfirmed", lineageID: UUID, provenance: String? = nil, context: String? = nil, isAuthorized: Bool = true, tunnels: [AriaV2TunnelRow] = []) {
        self.memoryID = memoryID
        self.subject = subject
        self.content = content
        self.wing = wing
        self.room = room
        self.filedAt = filedAt
        self.eventTime = eventTime
        self.state = state
        self.trust = trust
        self.sensitivity = sensitivity
        self.exportability = exportability
        self.confirmation = confirmation
        self.lineageID = lineageID
        self.provenance = provenance
        self.context = context
        self.isAuthorized = isAuthorized
        self.tunnels = tunnels
    }
}

/// A single tunnel edge attached to a depth:full memory record.
///
/// Carries the minimum fields for a caller to understand who a memory is
/// connected to and follow the connection: the tunnel's own id, relationship
/// kind and current lifecycle, and the far-end drawer id when the far end is
/// a specific drawer rather than a room-level endpoint.
///
/// Sensitivity disclosure follows the connection-tools rule: the tunnel itself
/// must be at or below the request's sensitivity ceiling, and the far-endpoint
/// drawer (when present) must also be at or below that ceiling.
public struct AriaV2TunnelRow: Sendable, Equatable {
    public let tunnelID: UUID
    public let kind: String
    public let lifecycle: String
    public let farEndpointID: UUID?

    public init(tunnelID: UUID, kind: String, lifecycle: String, farEndpointID: UUID?) {
        self.tunnelID = tunnelID
        self.kind = kind
        self.lifecycle = lifecycle
        self.farEndpointID = farEndpointID
    }
}

/// The result of a backend memory search: typed records alongside the optional
/// packager answer block and the post-anchor-exclusion hit count for the
/// "found N candidate memory(ies)" compact text header.
///
/// `FakeMemoryBackend` in tests returns `answerBlock: nil` and uses
/// `records.count` as `totalCount`.
public struct AriaV2SearchResult: Sendable {
    /// Authorized-filterable records for the v2 data response.
    public let records: [(record: AriaV2MemoryRecord, score: Double)]
    /// Optional answer block from the packager (nil when answer:never or when
    /// confidence is WEAK / composedAnswer is unavailable).
    public let answerBlock: GLKAnswerBlock?
    /// Total post-anchor-exclusion hit count for the compact text header.
    /// Equals `packaged.totalCount` from the packager, or `records.count` for
    /// test fakes that skip the packager.
    public let totalCount: Int
    /// True when one or more ranking stages were unavailable during recall,
    /// mirroring `GLKRecallResult.degradedStages.isEmpty == false`. Drives the
    /// "retrieval: degraded" compact text control line — the same control line
    /// the v1 S1 surface emits via ResultComposer.controlLines. Fakes default
    /// to false (no degradation on empty-estate test estates).
    public let degraded: Bool
    /// False when the span rerank stage is not registered, which makes the
    /// ranking lexical-only.
    ///
    /// Discrimination reads this and caps a `.high` verdict down to `.medium`:
    /// a lexical-only ranking cannot justify high confidence, and reporting it
    /// as high tells the caller to trust an ordering that no dense signal
    /// informed. Defaults true so a fake that never sets it keeps the
    /// ordinary, fully-ranked behaviour.
    public let spanRerankRegistered: Bool

    public init(
        records: [(record: AriaV2MemoryRecord, score: Double)],
        answerBlock: GLKAnswerBlock?,
        totalCount: Int,
        degraded: Bool = false,
        spanRerankRegistered: Bool = true
    ) {
        self.records = records
        self.answerBlock = answerBlock
        self.totalCount = totalCount
        self.degraded = degraded
        self.spanRerankRegistered = spanRerankRegistered
    }
}

/// A typed estate seam. It only exchanges request and record values; no JSON
/// runner, text renderer, or legacy dispatch result crosses it.
public protocol AriaV2MemoryBackend: Sendable {
    func file(_ request: AriaV2FileMemoryRequest, context: AriaV2MemoryOperationContext) async throws -> AriaV2MemoryRecord
    func search(_ request: AriaV2MemorySearchRequest, context: AriaV2MemoryOperationContext) async throws -> AriaV2SearchResult
    func get(_ request: AriaV2MemoryGetRequest, context: AriaV2MemoryOperationContext) async throws -> [AriaV2MemoryRecord]
}

/// Direct typed adapter for the current GeniusLocusKit/Estate APIs.  It is
/// optional at construction time because tests and host composition cannot
/// manufacture public EstateHandle values; those callers inject the protocol
/// seam above instead.
public struct AriaV2GeniusLocusMemoryBackend: AriaV2MemoryBackend {
    public let kit: GeniusLocusKit
    public let handle: EstateHandle

    public init(kit: GeniusLocusKit, handle: EstateHandle) {
        self.kit = kit
        self.handle = handle
    }

    public func file(_ request: AriaV2FileMemoryRequest, context: AriaV2MemoryOperationContext) async throws -> AriaV2MemoryRecord {
        try validateEstate(request.estateID, context: context)
        let frame = CaptureFrame(
            content: request.content,
            channel: .actuator,
            room: request.location,
            latticeAnchor: LatticeAnchor(udcCode: "000", udcFacets: nil, wikidataQID: nil, wikidataQidsSecondary: nil),
            addedBy: context.serverIdentity,
            embeddingModelID: "default",
            sensitivity: request.sensitivity.locusValue,
            kind: request.kind.locusValue,
            provenanceChannel: .mcpAgent,
            sourceType: .imported,
            eventTime: request.eventTime,
            exportability: request.exportability.locusValue,
            wing: request.wing ?? LocusKit.defaultWingName,
            subject: request.subject
        )
        let drawer = try await kit.capture(handle, frame, mode: request.impatient ? .impatient : .regular)
        return try await record(for: drawer, authorized: true)
    }

    public func search(_ request: AriaV2MemorySearchRequest, context: AriaV2MemoryOperationContext) async throws -> AriaV2SearchResult {
        try validateEstate(request.estateID, context: context)
        // For near: queries, store the anchor UUID so it can be excluded from the
        // hit list before it reaches the packager. The anchor self-matches as rank-0
        // and would corrupt the m1 (margin) signal if included.
        let anchorID: UUID? = request.near
        let query: String
        if let requestQuery = request.query {
            query = requestQuery
        } else if let near = request.near {
            // This is the BACKEND get, which MARKS each record with
            // `isAuthorized` (via provenanceVisible) but does not filter — the
            // filtering lives one layer up in AriaV2MemoryOperations. Taking
            // `.first` here would use the content of a row the caller may not
            // read, and pivoting through a gated anchor leaks its
            // content-derived neighbours past the redaction boundary. So the
            // verdict this read already computed is applied here rather than
            // discarded.
            //
            // An unauthorized anchor and an absent one both yield an empty
            // result: the caller must not be able to tell which, which is the
            // same oracle-free shape memory_get uses.
            let source = try await get(AriaV2MemoryGetRequest(memoryIDs: [near], depth: .full, estateID: request.estateID), context: context)
            guard let anchor = source.first(where: \.isAuthorized) else {
                return AriaV2SearchResult(records: [], answerBlock: nil, totalCount: 0)
            }
            query = anchor.content
        } else {
            return AriaV2SearchResult(records: [], answerBlock: nil, totalCount: 0)
        }
        // Build filter chain: sensitivity ceiling first (always present), then
        // caller's filter/wing/media_type arguments in composition order.
        // The sensitivity ceiling suppresses the BitmapEvaluator default narrower
        // ceiling (.elevated), matching the precedence documented in ToolDispatch.
        var filterChain: [Filter] = [.sensitivityAtMost(context.maximumSensitivity)]
        if context.exportableOnly { filterChain.append(.exportable) }
        if let filterStr = request.filter {
            switch filterStr {
            case "unconfirmed":   filterChain.append(.unconfirmed)
            case "userConfirmed": filterChain.append(.userConfirmed)
            case "exportable":    filterChain.append(.exportable)
            case "contained":     filterChain.append(.contained)
            // isPinned: container-fingerprint pruning path (Feature-flag adoption §1).
            case "pinned":        filterChain.append(.hasFeatureFlag(.isPinned))
            default: break // validated at decode; impossible at runtime
            }
        }
        // wing: scope recall to a named wing of the estate.
        if let wingName = request.wing {
            filterChain.append(.inWing(wingName))
        }
        // media_type: constrain recall to drawers with a specific media capture type.
        if let mediaType = request.mediaType {
            switch mediaType {
            case "voice": filterChain.append(.hasFeatureFlag(.hasVoice))
            case "image": filterChain.append(.hasFeatureFlag(.hasImage))
            default: break // validated at decode; impossible at runtime
            }
        }
        // Door/scoring precedence: explicit door > explicit scoring > A1 DoorManifest > matrixAware.
        // 'door=guess' reads the optimizer-provisioned per-corpus DoorManifest.
        // Direct door scoring rawValues bypass the A1 config.
        let scoring: GLKRecallScoring
        if let doorStr = request.door {
            switch doorStr {
            case "guess":
                // A1 per-corpus static config: read the DoorManifest provisioned by
                // the quality optimizer. Absent or malformed key falls back to .matrixAware.
                let doorManifest = try await kit.provisionedDoorConfig(for: handle)
                scoring = doorManifest.scoring
            default:
                // doorStr was validated at decode as a GLKRecallScoring rawValue.
                scoring = GLKRecallScoring(rawValue: doorStr) ?? .matrixAware
            }
        } else if let scoringStr = request.scoringKey {
            // scoringStr validated at decode; force-unwrap would be safe but use ?? for safety.
            scoring = GLKRecallScoring(rawValue: scoringStr) ?? .matrixAware
        } else {
            // Neither door nor scoring supplied: read the A1 per-corpus config.
            // Falls back to .matrixAware when no config is provisioned.
            let doorManifest = try await kit.provisionedDoorConfig(for: handle)
            scoring = doorManifest.scoring
        }
        // Decode ordering. 'byRelevanceDesc' maps to .byCaptureTimeDesc as a tie-break
        // within the scored layer; the final result order is driven by scores, not page order.
        let ordering: Ordering
        switch request.ordering {
        case "byCaptureTimeDesc": ordering = .byCaptureTimeDesc
        case "byCaptureTimeAsc":  ordering = .byCaptureTimeAsc
        case "byRoomAsc":         ordering = .byRoomAsc
        // byRelevanceDesc: results are relevance-ordered by the scoring machinery;
        // byCaptureTimeDesc serves as a stable tie-break within the scored layer.
        case "byRelevanceDesc":   ordering = .byCaptureTimeDesc
        default:                  ordering = .byCaptureTimeDesc // validated at decode; impossible
        }
        let frame = RecallFrame(
            filterChain: filterChain,
            hydrationLevel: .full,
            limit: request.limit,
            ordering: ordering
        )
        let result = try await kit.recall(handle, GLKRecallRequest(
            frame: frame,
            mode: .unionBest,
            scoring: scoring,
            limit: request.limit,
            fallback: .allowDegraded,
            queryText: query,
            origin: context.recallOrigin,
            door: "memory_search",
            frontierK: request.frontierK.map { Int($0) },
            subSpanScoring: .off
        ))
        // Exclude the near: anchor from the hit list before the packager so that
        // gate signals (m1 top-margin, m3 span cosine spread) are computed on the
        // same ranked set the caller receives.
        // RecallHit.id is RowID (String); UUID storage may use upper-case or lower-case
        // spellings, so compare against both canonical forms.
        let anchorIDStrings: Set<String> = anchorID.map {
            Set(AriaV2ArgumentDecoder.storageIdentitySpellings($0))
        } ?? []
        let anchorFilteredHits: [RecallHit] = anchorIDStrings.isEmpty
            ? result.hits
            : result.hits.filter { !anchorIDStrings.contains($0.id) }
        // Exclude provenance-restricted rows here, before the packager and the
        // count, so `totalCount` never reveals that a hidden row matched. The
        // Rust port counts after the same exclusion (`core_memory.rs`,
        // `result.rows.len()`); a total that counted hidden rows would be a
        // count oracle for redacted content.
        let filteredHits: [RecallHit] = anchorFilteredHits.filter { hit in
            guard let drawer = hit.drawer else { return true }
            return Self.provenanceVisible(drawer.provenance)
        }

        // record a sensitivityReadUnderGrant audit entry for each hit that
        // was admitted PAST the substrate's own default ceiling specifically
        // because a grant is live. Only rows whose own adjective sensitivity
        // is restricted/secret qualify — an elevated-or-below row would have
        // been admitted regardless of any grant, so recording it here would
        // misrepresent "read under grant" as having happened when it did
        // not. Gated on `context.grantCeiling` being non-nil so a query with
        // no live grant never emits. The guard does not consult the provenance
        // axis: provenance visibility is decided one layer up, in
        // AriaV2MemoryOperations.search(_:), so a provenance-gated hit that
        // also carries a restricted/secret adjective still records here.
        if context.grantCeiling != nil {
            for hit in filteredHits {
                guard let drawer = hit.drawer else { continue }
                switch drawer.adjectiveSensitivity {
                case .restricted, .secret:
                    try? await kit.recordSensitivityReadUnderGrant(
                        handle, tier: drawer.adjectiveSensitivity, drawerID: drawer.id, now: context.now())
                case .normal, .elevated:
                    continue
                }
            }
        }

        // answer:always|auto — compose an answer via GroundedSynthesis, then route
        // through GLKResultsPackager. answer:never is the fast path (no gate math).
        let composedAnswer: String?
        if request.answer != .never {
            let synthFrame = LocusKit.RecallFrame(
                filterChain: filterChain,
                hydrationLevel: .structured,
                limit: request.limit,
                ordering: ordering
            )
            let synthOut = try await GroundedSynthesis().run(
                input: .init(
                    frame: synthFrame,
                    cueTerms: [],
                    cap: request.limit,
                    query: query,
                    excludeProvenanceSensitive: true
                ),
                estate: handle,
                kit: kit
            )
            composedAnswer = synthOut.context.summary
        } else {
            composedAnswer = nil
        }
        // Build the packager result on the anchor-excluded hit list so gate math
        // uses the same ranked set the caller sees. The tuning manifest supplies
        // thresholds; .default fills absent keys.
        let tuning = try await kit.provisionedRecallTuning(for: handle)
        // Always package the filtered list: the anchor exclusion and the
        // provenance exclusion above both have to reach the count.
        let packagerResult = result.replacing(hits: filteredHits)
        let packaged = GLKResultsPackager().package(
            result: packagerResult,
            mode: request.answer,
            composedAnswer: composedAnswer,
            thresholds: tuning.packagerThresholds
        )

        var records: [(record: AriaV2MemoryRecord, score: Double)] = []
        for hit in filteredHits {
            guard let drawer = hit.drawer else { continue }
            // Every remaining hit passed the provenance gate above.
            records.append((try await record(for: drawer, authorized: true), Double(hit.score.final)))
        }
        return AriaV2SearchResult(
            records: records,
            answerBlock: packaged.answerBlock,
            totalCount: packaged.totalCount,
            // Propagate degradation signal from the recall director so the
            // operations layer can emit the "retrieval: degraded" compact text
            // control line — present when recall quality was degraded.
            degraded: !result.degradedStages.isEmpty,
            // The span rerank stage's registration, so discrimination can cap
            // a high verdict on a lexical-only ranking. Without this the
            // operations layer has no way to know the dense lane was dark.
            spanRerankRegistered: await kit.isSpanRerankRegistered(for: handle)
        )
    }

    public func get(_ request: AriaV2MemoryGetRequest, context: AriaV2MemoryOperationContext) async throws -> [AriaV2MemoryRecord] {
        try validateEstate(request.estateID, context: context)
        // Swift-authored drawers use UUID.uuidString while Rust-authored
        // portable estates use canonical lowercase. Public v2 references are
        // lowercase, so look up both valid storage spellings without changing
        // the typed UUID identity or exposing which spelling exists.
        let ids = request.memoryIDs.flatMap(AriaV2ArgumentDecoder.storageIdentitySpellings)
        var filters: [Filter] = [.sensitivityAtMost(context.maximumSensitivity)]
        if context.exportableOnly { filters.append(.exportable) }
        let frame = RecallFrame(filterChain: filters, hydrationLevel: .full)
        let loaded = try await kit.getDrawers(in: handle, ids: ids, matchingFrame: frame, hydrationLevel: .full)
        var records: [AriaV2MemoryRecord] = []
        for drawer in loaded.admissible {
            let authorized = Self.provenanceVisible(drawer.provenance)
            // Same read-under-grant audit recording as search — gated on
            // BOTH the ceiling having been lifted AND the drawer's own
            // sensitivity actually being restricted/secret. Also gated on
            // provenance visibility here (unlike search): v1 runMemoryGet's
            // admissibleByID already excludes provenance-restricted/secret
            // rows before its audit fires (ToolDispatch.swift:2584-2590), so
            // a row this v2 path is about to redact via `authorized: false`
            // must not be recorded as read — it was never actually visible
            // to the caller.
            if authorized, context.grantCeiling != nil {
                switch drawer.adjectiveSensitivity {
                case .restricted, .secret:
                    try? await kit.recordSensitivityReadUnderGrant(
                        handle, tier: drawer.adjectiveSensitivity, drawerID: drawer.id, now: context.now())
                case .normal, .elevated:
                    break
                }
            }
            // Tunnel rows are only included for depth:full. depth:subject and
            // depth:distilled carry no tunnels, matching v1 which only queried
            // tunnels on the full-record path (ToolDispatch.swift:2568-2579).
            let tunnels: [AriaV2TunnelRow]
            if request.depth == .full {
                tunnels = try await loadTunnels(for: drawer, ceiling: context.maximumSensitivity)
            } else {
                tunnels = []
            }
            records.append(try await record(for: drawer, authorized: authorized, tunnels: tunnels))
        }
        return records
    }

    private func validateEstate(_ requested: UUID?, context: AriaV2MemoryOperationContext) throws {
        guard requested == nil || requested == context.estateID, context.estateID == handle.estateUUID else {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams, message: "The requested estate is not available to this caller.")
        }
    }

    private func record(for drawer: Drawer, authorized: Bool, tunnels: [AriaV2TunnelRow] = []) async throws -> AriaV2MemoryRecord {
        let names = try await kit.resolveNodeNames(handle, parentNodeIds: [drawer.parentNodeId])
        let location = names[drawer.parentNodeId] ?? (wing: "", room: "")
        guard let memoryID = UUID(uuidString: drawer.id) else {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams, message: "The estate returned a non-UUID memory identifier.")
        }
        return AriaV2MemoryRecord(
            memoryID: memoryID,
            subject: drawer.subject, content: drawer.content, wing: location.wing, room: location.room,
            filedAt: drawer.filedAt, eventTime: drawer.eventTime, state: String(describing: drawer.state),
            trust: String(describing: drawer.trust), sensitivity: String(describing: drawer.adjectiveSensitivity),
            exportability: String(describing: drawer.exportability), confirmation: String(describing: drawer.confirmation),
            lineageID: drawer.lineageID, provenance: String(describing: drawer.sourceType),
            // context carries the drawer's subject so every compact search row exposes
            // the one-sentence assertion the user filed.
            context: drawer.subject,
            isAuthorized: authorized,
            tunnels: tunnels)
    }

    /// Load active linked tunnels for a drawer, filtered by sensitivity ceiling and
    /// the connection-tools endpoint disclosure rule.
    ///
    /// Uses `activeTunnelsFrom(drawerId:)` + `activeTunnelsTo(drawerId:)` so the
    /// lifecycle filter (`tombstonedAt == nil && lifecycle == .active`) runs at
    /// the SQL layer, matching the v1 filter at ToolDispatch.swift:2568-2579.
    /// Cap: 50 rows, matching v1 `linked.prefix(50)`.
    /// Sensitivity: tunnel must be at or below `ceiling`; far-endpoint drawer
    /// (when present and found in the estate) must also be at or below `ceiling`.
    /// A nil far-endpoint (room-level connection) passes through without a drawer check.
    private func loadTunnels(for drawer: Drawer, ceiling: AdjectiveSensitivity) async throws -> [AriaV2TunnelRow] {
        // Active lifecycle + tombstonedAt == nil filtered at the SQL layer via
        // activeTunnelsFrom/To (LocusKit.Estate L947, L955).
        let fromTunnels = try await kit.activeTunnels(in: handle, from: drawer.id)
        let toTunnels = try await kit.activeTunnels(in: handle, to: drawer.id)

        // Deduplicate in case a self-referential tunnel appears in both lists.
        var seen = Set<String>()
        var combined: [Tunnel] = []
        for tunnel in fromTunnels + toTunnels {
            guard seen.insert(tunnel.id).inserted else { continue }
            combined.append(tunnel)
        }

        // Sensitivity gate: drop tunnels whose own sensitivity exceeds the ceiling.
        let withinCeiling = combined.filter { $0.adjectiveSensitivity.rawValue <= ceiling.rawValue }

        // Cap at 50, matching v1 behavior (ToolDispatch.swift:2576 linked.prefix(50)).
        let capped = Array(withinCeiling.prefix(50))
        guard !capped.isEmpty else { return [] }

        // Resolve far-endpoint drawers to apply the connection-tools disclosure
        // rule (AriaV2KnowledgeJournal.swift:399-413 visibleTunnels): drop a
        // tunnel when the far-side drawer is known but its sensitivity exceeds
        // the ceiling. A nil far id (room-level endpoint) passes through.
        let farIDs: [String] = capped.compactMap { tunnel in
            let isOutgoing = tunnel.sourceDrawerId == drawer.id
            return isOutgoing ? tunnel.targetDrawerId : tunnel.sourceDrawerId
        }
        let endpointDrawers = (try? await kit.getDrawers(in: handle, ids: Array(Set(farIDs)), hydrationLevel: .structured)) ?? []
        let visibleEndpointIDs = Set(endpointDrawers.filter { $0.adjectiveSensitivity.rawValue <= ceiling.rawValue }.map(\.id))

        return capped.compactMap { tunnel -> AriaV2TunnelRow? in
            guard let tunnelID = UUID(uuidString: tunnel.id) else { return nil }
            let isOutgoing = tunnel.sourceDrawerId == drawer.id
            let farDrawerID = isOutgoing ? tunnel.targetDrawerId : tunnel.sourceDrawerId
            // Drop the tunnel if the far endpoint is a known drawer over the ceiling.
            if let farID = farDrawerID, !visibleEndpointIDs.contains(farID) { return nil }
            let farEndpointID = farDrawerID.flatMap(UUID.init(uuidString:))
            return AriaV2TunnelRow(
                tunnelID: tunnelID,
                kind: tunnel.kind.wireString,
                lifecycle: String(describing: tunnel.lifecycle),
                farEndpointID: farEndpointID)
        }
    }

    static func provenanceVisible(_ provenance: Int64) -> Bool {
        let raw = (provenance >> 30) & 0x3f
        return raw == Int64(Sensitivity.normal.rawValue)
            || raw == Int64(Sensitivity.elevated.rawValue)
    }
}

public struct AriaV2MemoryOperations: Sendable {
    public let backend: any AriaV2MemoryBackend
    public let context: AriaV2MemoryOperationContext

    public init(backend: any AriaV2MemoryBackend, context: AriaV2MemoryOperationContext) {
        self.backend = backend
        self.context = context
    }

    public func file(arguments: JSONValue) async throws -> JSONValue {
        try await file(AriaV2FileMemoryRequest(arguments: arguments))
    }

    public func file(_ request: AriaV2FileMemoryRequest) async throws -> JSONValue {
        let record = try await backend.file(request, context: context)
        let data: JSONValue = .object([
            "memory_id": .string(Self.id(record.memoryID)),
            "placement": .object(["wing": .string(record.wing), "room": .string(record.room)]),
            "fetch": Self.fetch(record.memoryID),
        ])
        return AriaV2Envelope.success(tool: "moot_file_memory", effect: .write, data: data, meta: Self.meta(), compactText: "filed memory \(Self.id(record.memoryID))")
    }

    public func search(arguments: JSONValue) async throws -> JSONValue {
        try await search(AriaV2MemorySearchRequest(arguments: arguments))
    }

    public func search(_ request: AriaV2MemorySearchRequest) async throws -> JSONValue {
        let result = try await backend.search(request, context: context)
        // Lower recall may return a broader candidate pool than the public
        // request limit. Authorization happens first, then the selected v2
        // boundary enforces the caller-visible ceiling.
        let visible = Array(result.records.lazy.filter { $0.record.isAuthorized }.prefix(request.limit))
        await context.usageLedger.recordSurfaced(visible.map { $0.record.memoryID }, estateID: context.estateID, callerID: context.callerID, at: context.now())

        // Build the data object. The answer block is included in `data` when present,
        // as a typed structured object (not text lines) per the v2 response contract.
        var dataFields: [String: JSONValue] = [
            "results": .array(visible.map { Self.compact($0.record, score: $0.score) }),
        ]
        if let block = result.answerBlock {
            // citationIDs are RowID (String) storage identifiers. Canonicalize
            // to lowercase UUID format matching the v2 memory_id convention.
            let canonicalCitations = block.citationIDs.compactMap { rowID -> String? in
                UUID(uuidString: rowID).map { AriaV2ArgumentDecoder.canonicalUUID($0) } ?? rowID.lowercased()
            }
            dataFields["answer"] = .object([
                "text": .string(block.text),
                "confidence": .string(block.confidence.rawValue),
                "citations": .array(canonicalCitations.map { .string($0) }),
                "signals": .object([
                    "margin": .double(block.signals.margin),
                    "lane_agreement": .double(block.signals.laneAgreement),
                    "dense_spread": .double(block.signals.denseSpread),
                    "containment": .bool(block.signals.containment),
                ]),
            ])
        }

        // Build compact text. For answer:never, "found N candidate memory(ies)".
        // For answer:always|auto when an answer block is present, prepend the
        // answer block header lines before the found-N row, matching the v1 wire
        // format. The compact text is clamped to 512 Unicode scalars by the envelope.
        let countWord = result.totalCount == 1 ? "memory" : "memories"
        let foundHeader = "found \(result.totalCount) candidate \(countWord)"
        var compactText: String
        if let block = result.answerBlock {
            var headerLines = [
                "answer: \(block.text)",
                "confidence: \(block.confidence.rawValue)",
            ]
            if !block.citationIDs.isEmpty {
                // citationIDs are RowID (String); canonicalize to lowercase UUID format.
                let citStr = block.citationIDs.prefix(5).map { rowID -> String in
                    UUID(uuidString: rowID).map { AriaV2ArgumentDecoder.canonicalUUID($0) } ?? rowID.lowercased()
                }.joined(separator: ", ")
                headerLines.append("citations: \(citStr)")
            }
            headerLines.append(
                "signals: margin=\(block.signals.margin) "
                + "lane_agreement=\(block.signals.laneAgreement) "
                + "dense_spread=\(block.signals.denseSpread) "
                + "containment=\(block.signals.containment)"
            )
            compactText = headerLines.joined(separator: "\n") + "\n" + foundHeader
        } else {
            compactText = foundHeader
        }
        // explain: append discrimination line when signal warrants it. v1 control
        // line order: discrimination precedes degradation (ResultComposer.controlLines
        // §1 before §3). Only low and medium are surfaced in v2 compact text
        // (high/single/not_found are silent). Mirrors the Rust v2 execute_memory_search
        // explain branch.
        // NOT gated behind `explain`. The discrimination line is a confidence
        // signal the caller needs in order to judge the result it was just
        // handed; hiding it until asked means the ordinary call gets a ranking
        // with no indication of how much to trust it. v1 emitted it on every
        // search and only for LOW and MEDIUM — high, single-result and
        // not-found stay silent because there is nothing to warn about.
        let scores = visible.map { $0.score }
        var discrimination = RecallDiscrimination.classify(scores)
        // A lexical-only ranking cannot support a high verdict. v1 applied the
        // same cap; v2 could not, because nothing told it the span stage was
        // unregistered, so it could report high confidence in an ordering no
        // dense signal had informed.
        if !result.spanRerankRegistered, discrimination == .high {
            discrimination = .medium
        }
        switch discrimination {
        case .low, .medium:
            compactText += "\n" + RecallDiscrimination.resultLine(for: discrimination)
        default:
            break
        }
        // Degradation: append control line AFTER discrimination, matching the v1 S1
        // surface (ResultComposer.controlLines §3 follows §1). rrf on unionBest mode
        // records "unionBest.rrf" in degradedStages; matrixAware runs cleanly with no
        // degradation — the difference discriminates door=rrf from door=matrixAware in
        // the DoorDispatchTests discriminating assertion.
        if result.degraded {
            compactText += "\nretrieval: degraded — one or more ranking stages unavailable"
        }

        return AriaV2Envelope.success(
            tool: "moot_memory_search",
            effect: .read,
            data: .object(dataFields),
            meta: Self.meta(),
            compactText: compactText
        )
    }

    public func get(arguments: JSONValue) async throws -> JSONValue {
        try await get(AriaV2MemoryGetRequest(arguments: arguments))
    }

    public func get(_ request: AriaV2MemoryGetRequest) async throws -> JSONValue {
        let fetched = try await backend.get(request, context: context)
        let records = fetched.filter(\.isAuthorized)
        guard !records.isEmpty else {
            return AriaV2Envelope.refusal(tool: "moot_memory_get", error: .init(
                code: "memory_not_found", message: "No authorized memory matched the requested reference.", retryable: false))
        }
        await context.usageLedger.recordDereferenced(records.map(\.memoryID), estateID: context.estateID, callerID: context.callerID, at: context.now())
        var rows: [JSONValue] = []
        var previews: [String] = []
        for record in records {
            if request.depth == .skim {
                let skim = try RecallSkim(original: record.content)
                var row: [String: JSONValue] = ["memory_id": .string(Self.id(record.memoryID)),
                    "fetch": Self.fetch(record.memoryID), "skim": skim.json]
                if let subject = record.subject { row["subject"] = .string(subject) }
                rows.append(.object(row))
                previews.append("\(Self.id(record.memoryID))\n\(skim.rendered)")
            } else {
                rows.append(Self.full(record, depth: request.depth))
            }
        }
        let data: JSONValue = .object(["memories": .array(rows)])
        let response = AriaV2Envelope.success(tool: "moot_memory_get", effect: .read, data: data, meta: Self.meta(), compactText: "Fetched \(records.count) authorized memories.")
        guard request.depth == .skim, var object = response.objectValue else { return response }
        // Already budgeted per record; the generic 512-scalar summary would
        // truncate the preview a second time and drop its flags/savings.
        object["content"] = .array([.object(["type": .string("text"), "text": .string(previews.joined(separator: "\n\n"))])])
        return .object(object)
    }

    private static func meta() -> [String: JSONValue] { ["completeness": .string("incomplete")] }
    private static func id(_ id: UUID) -> String { AriaV2ArgumentDecoder.canonicalUUID(id) }
    private static func fetch(_ id: UUID) -> JSONValue { .object(["tool": .string("moot_memory_get"), "arguments": .object(["memory_id": .string(Self.id(id))])]) }

    private static func compact(_ record: AriaV2MemoryRecord, score: Double) -> JSONValue {
        var result: [String: JSONValue] = ["memory_id": .string(id(record.memoryID)), "score": .double(score), "fetch": fetch(record.memoryID)]
        if let subject = record.subject { result["subject"] = .string(AriaV2Envelope.compactText(subject)) }
        if let provenance = record.provenance { result["provenance"] = .string(provenance) }
        if let context = record.context { result["context"] = .string(AriaV2Envelope.compactText(context)) }
        if !record.content.isEmpty { result["excerpt"] = .string(AriaV2Envelope.compactText(record.content)) }
        return .object(result)
    }

    private static func full(_ record: AriaV2MemoryRecord, depth: AriaV2MemoryDepth) -> JSONValue {
        var result: [String: JSONValue] = ["memory_id": .string(id(record.memoryID)), "fetch": fetch(record.memoryID)]
        if let subject = record.subject { result["subject"] = .string(subject) }
        if depth != .subject { result["distilled"] = .string(RecallDistillation.render(record.content)) }
        if depth == .full {
            result["content"] = .string(record.content)
            result["placement"] = .object(["wing": .string(record.wing), "room": .string(record.room)])
            result["filed_at"] = .string(Self.iso8601(record.filedAt))
            result["event_time"] = .string(Self.iso8601(record.eventTime))
            result["state"] = .string(record.state)
            result["trust"] = .string(record.trust)
            result["sensitivity"] = .string(record.sensitivity)
            result["exportability"] = .string(record.exportability)
            result["confirmation"] = .string(record.confirmation)
            result["lineage_id"] = .string(id(record.lineageID))
            // Tunnel rows: active linked tunnels, sensitivity-filtered, capped at 50.
            // Always present at depth:full (empty array when no active tunnels are linked).
            // depth:subject and depth:distilled carry no tunnels — those depths omit this key.
            result["tunnels"] = .array(record.tunnels.map { t in
                var row: [String: JSONValue] = [
                    "tunnel_id": .string(Self.id(t.tunnelID)),
                    "kind": .string(t.kind),
                    "lifecycle": .string(t.lifecycle),
                ]
                if let far = t.farEndpointID {
                    row["far_endpoint_id"] = .string(Self.id(far))
                }
                return .object(row)
            })
        }
        return .object(result)
    }

    private static func iso8601(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}

fileprivate extension AriaV2FileMemoryRequest {
    static func nonEmpty(_ value: String, path: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw invalid(path: path, message: "Argument '\(path)' must not be empty.") }
        return trimmed
    }

    static func subject(_ value: String) throws -> String {
        let normalized = try nonEmpty(value, path: "subject")
        guard normalized.count <= DrawerStore.subjectLengthContract else {
            throw invalid(path: "subject", message: "Argument 'subject' must be at most \(DrawerStore.subjectLengthContract) characters.")
        }
        return normalized
    }

    static func date(_ raw: String?, path: String) throws -> Date? {
        guard let raw else { return nil }
        guard let date = ISO8601DateFormatter().date(from: raw) else {
            throw invalid(path: path, message: "Argument '\(path)' must be an ISO-8601 instant.")
        }
        return date
    }

    static func enumValue<T: RawRepresentable & CaseIterable>(_ raw: String, path: String, type: T.Type) throws -> T where T.RawValue == String {
        guard let value = T(rawValue: raw) else {
            // Derive the allowed list from all declared cases so the refusal
            // carries both fields required by the v2 refusal shape rule.
            // jsonRPCError sorts allowed at emission; no sort needed here.
            throw AriaV2InvalidArgument(
                path: path,
                message: "Argument '\(path)' has an unsupported value '\(raw)'.",
                allowed: T.allCases.map(\.rawValue),
                correction: "use a documented \(path) value"
            ).jsonRPCError
        }
        return value
    }

    static func invalid(path: String, message: String) -> JSONRPCError {
        AriaV2InvalidArgument(path: path, message: message).jsonRPCError
    }
}
