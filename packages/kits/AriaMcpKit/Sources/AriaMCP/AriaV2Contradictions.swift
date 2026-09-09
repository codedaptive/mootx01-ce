import Foundation
import AriaMCPWire
import GeniusLocusKit
import LocusKit

/// Typed v2 contradiction hunt and selected-candidate custody.
///
/// This file never calls legacy text/JSON runners.  Proposal persistence is
/// deliberately absent: the current `fileProposal` helper is private and its
/// public caller is a non-atomic all-candidate sweep, which cannot satisfy the
/// selected-reference contract.
public enum AriaV2Contradictions {
    public static let huntToolName = "moot_hunt_contradictions"
    public static let proposeToolName = "moot_propose_contradictions"
    public static let analysisLifetime: TimeInterval = 10 * 60
    public static let maximumCandidates = 1_000
    // Bound candidate discovery separately from the requested result count.
    public static let maximumProbeMemories = 1_000

    public struct HuntRequest: Sendable, Equatable {
        public let estateID: UUID?
        public let limit: Int

        public init(arguments: JSONValue) throws {
            let decoder = try AriaV2ArgumentDecoder(arguments, allowedKeys: ["limit", "estate_id"])
            estateID = try decoder.optionalUUID("estate_id")
            let decodedLimit = Int(try decoder.optionalInteger("limit") ?? 50)
            guard (1...AriaV2Contradictions.maximumCandidates).contains(decodedLimit) else {
                throw AriaV2InvalidArgument(
                    path: "limit",
                    message: "limit must be between 1 and \(AriaV2Contradictions.maximumCandidates)."
                ).jsonRPCError
            }
            limit = decodedLimit
        }
    }

    public struct ProposeRequest: Sendable, Equatable {
        public let analysisReference: String
        public let candidateIDs: [String]
        public let estateID: UUID?

        public init(arguments: JSONValue) throws {
            let decoder = try AriaV2ArgumentDecoder(
                arguments,
                allowedKeys: ["analysis_ref", "candidate_ids", "estate_id"]
            )
            let reference = try decoder.requireString("analysis_ref")
            guard !reference.isEmpty else {
                throw AriaV2InvalidArgument(
                    path: "analysis_ref",
                    message: "analysis_ref must be a non-empty opaque reference.",
                    correction: "Use the analysis_ref returned by moot_hunt_contradictions."
                ).jsonRPCError
            }
            analysisReference = reference
            estateID = try decoder.optionalUUID("estate_id")
            guard case .array(let values)? = decoder.arguments["candidate_ids"] else {
                throw AriaV2InvalidArgument(
                    path: "candidate_ids",
                    message: "Argument 'candidate_ids' must be a non-empty array of opaque candidate IDs.",
                    correction: "Provide the candidate_ids returned by moot_hunt_contradictions."
                ).jsonRPCError
            }
            guard !values.isEmpty, values.count <= AriaV2Contradictions.maximumCandidates else {
                throw AriaV2InvalidArgument(
                    path: "candidate_ids",
                    message: "candidate_ids must contain 1...\(AriaV2Contradictions.maximumCandidates) entries.",
                    correction: "Select at least one and at most 1000 candidate IDs."
                ).jsonRPCError
            }
            let ids = try values.enumerated().map { offset, value -> String in
                guard case .string(let id) = value, !id.isEmpty else {
                    throw AriaV2InvalidArgument(
                        path: "candidate_ids[\(offset)]",
                        message: "candidate_ids entries must be non-empty strings.",
                        correction: "Use opaque candidate IDs returned by the hunt result."
                    ).jsonRPCError
                }
                return id
            }
            guard Set(ids).count == ids.count else {
                throw AriaV2InvalidArgument(
                    path: "candidate_ids",
                    message: "candidate_ids must be unique.",
                    correction: "Remove duplicate candidate IDs."
                ).jsonRPCError
            }
            candidateIDs = ids
        }
    }

    /// Caller/estate/revision values are supplied by selected-surface policy;
    /// this core does not infer authorization from a caller-supplied reference.
    public struct AnalysisContext: Sendable, Equatable {
        public let estateID: UUID
        public let callerBinding: String
        public let authorizationRevision: String

        public init(estateID: UUID, callerBinding: String, authorizationRevision: String) {
            self.estateID = estateID
            self.callerBinding = callerBinding
            self.authorizationRevision = authorizationRevision
        }
    }

    /// Metadata only: never persist source text or snippets in temporary state.
    public struct Candidate: Sendable, Equatable {
        public let candidateID: String
        public let tier: Int
        public let pairKey: String
        public let sourceMemoryID: String
        public let targetMemoryID: String
        public let ruleOrCue: String?
        public let evidenceID: String?
        public let proposal: SelectedConflictProposal

        public init(candidateID: String, tier: Int, pairKey: String,
                    sourceMemoryID: String, targetMemoryID: String,
                    ruleOrCue: String?, evidenceID: String?,
                    proposal: SelectedConflictProposal) {
            self.candidateID = candidateID
            self.tier = tier
            self.pairKey = pairKey
            self.sourceMemoryID = sourceMemoryID
            self.targetMemoryID = targetMemoryID
            self.ruleOrCue = ruleOrCue
            self.evidenceID = evidenceID
            self.proposal = proposal
        }
    }

    public struct HuntResult: Sendable, Equatable {
        public let analysisReference: String
        public let expiresAt: Date
        public let candidates: [Candidate]
    }

    public enum HuntRetention: Sendable, Equatable {
        case result(HuntResult)
        case refusal(AriaV2OperationalRefusal)
    }

    public struct SelectedProposal: Sendable, Equatable {
        public let analysisReference: String
        public let context: AnalysisContext
        public let candidates: [Candidate]
    }

    public enum ReferenceResolution: Sendable, Equatable {
        case selected(SelectedProposal)
        case refusal(AriaV2OperationalRefusal)
    }

    /// Run the public, read-only TieredContradictionSearch and retain only the
    /// returned finding metadata behind a server-issued opaque reference.
    public static func hunt(
        request: HuntRequest,
        context: AnalysisContext,
        kit: GeniusLocusKit,
        handle: EstateHandle,
        references: AriaV2ContradictionReferences,
        now: Date
    ) async throws -> HuntRetention {
        guard request.estateID == nil || request.estateID == context.estateID,
              handle.estateUUID == context.estateID else {
            return .refusal(AriaV2OperationalRefusal(
                code: "proposal_mismatch",
                message: "The requested estate does not match this authorized analysis context.",
                retryable: false
            ))
        }
        let report = try await kit.tieredContradictionSearch(
            in: handle, topK: request.limit,
            probeLimit: maximumProbeMemories, now: now)
        let findings = report.tier1 + report.tier2 + report.tier3
        var unissued: [Candidate] = []
        unissued.reserveCapacity(findings.count)
        for finding in findings.prefix(request.limit) {
            guard let proposal = try await kit.selectedConflictProposal(for: finding, in: handle) else {
                throw AriaV2ContradictionFailure.staleFinding
            }
            unissued.append(candidateMetadata(finding, proposal: proposal))
        }
        return await references.retain(context: context, candidates: unissued, now: now)
    }

    /// Validate a selected-reference request without filing anything.  A later
    /// lower-layer atomic primitive must consume this value and revalidate the
    /// source/evidence state in its own transaction before persistence.
    public static func selectForProposal(
        request: ProposeRequest,
        context: AnalysisContext,
        references: AriaV2ContradictionReferences,
        now: Date
    ) async -> ReferenceResolution {
        await references.resolve(request: request, context: context, now: now)
    }

    private static func candidateMetadata(_ finding: TierFinding, proposal: SelectedConflictProposal) -> Candidate {
        Candidate(
            candidateID: "",
            tier: finding.tier.rawValue,
            pairKey: finding.pairKey,
            sourceMemoryID: finding.drawerA,
            targetMemoryID: finding.drawerB,
            ruleOrCue: finding.ruleID ?? finding.cueKind,
            evidenceID: finding.resultID ?? finding.cueKind,
            proposal: proposal
        )
    }
}

enum AriaV2ContradictionFailure: Error, Sendable {
    case staleFinding
}

/// Bounded, process-local custody for server-issued contradiction analysis
/// references.  It is an actor so LRU eviction and selection resolution are
/// serialized without leaking a reference across authorization contexts.
public actor AriaV2ContradictionReferences {
    public static let shared = AriaV2ContradictionReferences()
    public static let maximumReferencesPerContext = 32
    public static let maximumReferences = 256
    public static let maximumRetainedBytes = 16 * 1_024 * 1_024

    private struct Entry: Sendable {
        var context: AriaV2Contradictions.AnalysisContext
        var expiresAt: Date
        var lastAccessAt: Date
        var candidates: [AriaV2Contradictions.Candidate]
        var byteCount: Int
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    public func retain(
        context: AriaV2Contradictions.AnalysisContext,
        candidates: [AriaV2Contradictions.Candidate],
        now: Date
    ) -> AriaV2Contradictions.HuntRetention {
        purgeExpired(now: now)
        guard candidates.count <= AriaV2Contradictions.maximumCandidates else {
            return .refusal(limitRefusal("An analysis may retain at most 1000 candidates."))
        }

        let analysisReference = "analysis_\(UUID().uuidString.lowercased())"
        let issued = candidates.map { candidate in
            AriaV2Contradictions.Candidate(
                candidateID: "candidate_\(UUID().uuidString.lowercased())",
                tier: candidate.tier,
                pairKey: candidate.pairKey,
                sourceMemoryID: candidate.sourceMemoryID,
                targetMemoryID: candidate.targetMemoryID,
                ruleOrCue: candidate.ruleOrCue,
                evidenceID: candidate.evidenceID,
                proposal: candidate.proposal
            )
        }
        let byteCount = retainedByteCount(context: context, candidates: issued)
        guard byteCount <= Self.maximumRetainedBytes else {
            return .refusal(limitRefusal("This analysis exceeds the 16 MiB retained-reference bound."))
        }

        evictToFit(context: context, incomingBytes: byteCount, now: now)
        guard entries.count < Self.maximumReferences,
              retainedBytes + byteCount <= Self.maximumRetainedBytes,
              entries.values.filter({ $0.context.callerBinding == context.callerBinding }).count
                < Self.maximumReferencesPerContext else {
            return .refusal(limitRefusal("Temporary analysis-reference capacity is exhausted; restart the analysis after references expire."))
        }

        let expiresAt = now.addingTimeInterval(AriaV2Contradictions.analysisLifetime)
        entries[analysisReference] = Entry(
            context: context,
            expiresAt: expiresAt,
            lastAccessAt: now,
            candidates: issued,
            byteCount: byteCount
        )
        return .result(.init(
            analysisReference: analysisReference,
            expiresAt: expiresAt,
            candidates: issued
        ))
    }

    public func resolve(
        request: AriaV2Contradictions.ProposeRequest,
        context: AriaV2Contradictions.AnalysisContext,
        now: Date
    ) -> AriaV2Contradictions.ReferenceResolution {
        purgeExpired(now: now)
        guard var entry = entries[request.analysisReference] else {
            return .refusal(expiredRefusal())
        }
        guard entry.context.callerBinding == context.callerBinding,
              entry.context.estateID == context.estateID,
              request.estateID == nil || request.estateID == context.estateID else {
            return .refusal(AriaV2OperationalRefusal(
                code: "proposal_mismatch",
                message: "The analysis reference is not valid for this caller or estate.",
                retryable: false
            ))
        }
        guard entry.context.authorizationRevision == context.authorizationRevision else {
            return .refusal(AriaV2OperationalRefusal(
                code: "proposal_stale",
                message: "Authorization or analysis state changed; run a fresh contradiction hunt.",
                retryable: true,
                recovery: .object(["tool": .string(AriaV2Contradictions.huntToolName), "arguments": .object([:])])
            ))
        }
        let byID = Dictionary(uniqueKeysWithValues: entry.candidates.map { ($0.candidateID, $0) })
        let selected = request.candidateIDs.compactMap { byID[$0] }
        guard selected.count == request.candidateIDs.count else {
            return .refusal(AriaV2OperationalRefusal(
                code: "invalid_candidate",
                message: "One or more candidate_ids do not belong to this analysis reference.",
                retryable: false
            ))
        }
        entry.lastAccessAt = now
        entries[request.analysisReference] = entry
        return .selected(.init(
            analysisReference: request.analysisReference,
            context: context,
            candidates: selected
        ))
    }

    private var retainedBytes: Int { entries.values.reduce(0) { $0 + $1.byteCount } }

    private func purgeExpired(now: Date) {
        entries = entries.filter { _, entry in entry.expiresAt > now }
    }

    private func evictToFit(
        context: AriaV2Contradictions.AnalysisContext,
        incomingBytes: Int,
        now: Date
    ) {
        while entries.values.filter({ $0.context.callerBinding == context.callerBinding }).count
                >= Self.maximumReferencesPerContext,
              let id = leastRecentlyUsed(where: { $0.context.callerBinding == context.callerBinding }) {
            entries.removeValue(forKey: id)
        }
        while entries.count >= Self.maximumReferences || retainedBytes + incomingBytes > Self.maximumRetainedBytes {
            guard let id = leastRecentlyUsed(where: { _ in true }) else { break }
            entries.removeValue(forKey: id)
        }
        _ = now
    }

    private func leastRecentlyUsed(where predicate: (Entry) -> Bool) -> String? {
        entries
            .filter { predicate($0.value) }
            .min { lhs, rhs in
                lhs.value.lastAccessAt == rhs.value.lastAccessAt
                    ? lhs.key < rhs.key
                    : lhs.value.lastAccessAt < rhs.value.lastAccessAt
            }?
            .key
    }

    private func retainedByteCount(
        context: AriaV2Contradictions.AnalysisContext,
        candidates: [AriaV2Contradictions.Candidate]
    ) -> Int {
        context.callerBinding.utf8.count + context.authorizationRevision.utf8.count + 16
            + candidates.reduce(0) { total, candidate in
                total + candidate.candidateID.utf8.count + candidate.pairKey.utf8.count
                    + candidate.sourceMemoryID.utf8.count + candidate.targetMemoryID.utf8.count
                    + (candidate.ruleOrCue?.utf8.count ?? 0) + (candidate.evidenceID?.utf8.count ?? 0) + 16
                    + candidate.proposal.renewalKey.utf8.count
                    + candidate.proposal.sourceDigest.utf8.count
                    + candidate.proposal.targetDigest.utf8.count
                    + candidate.proposal.evidenceDigest.utf8.count
                    + candidate.proposal.label.utf8.count
            }
    }

    private func limitRefusal(_ message: String) -> AriaV2OperationalRefusal {
        .init(code: "analysis_too_large", message: message, retryable: true,
              recovery: .object(["tool": .string(AriaV2Contradictions.huntToolName), "arguments": .object([:])]))
    }

    private func expiredRefusal() -> AriaV2OperationalRefusal {
        .init(code: "proposal_expired", message: "This analysis reference expired or was evicted; run a fresh contradiction hunt.", retryable: true,
              recovery: .object(["tool": .string(AriaV2Contradictions.huntToolName), "arguments": .object([:])]))
    }
}

/// Selected-surface projection for the contradiction reference flow.  It
/// reaches only the read-only search and the digest-validating atomic lower
/// filing seam; it never dispatches the legacy hunter runner.
public struct AriaV2ContradictionsService: Sendable {
    public let kit: GeniusLocusKit
    public let handle: EstateHandle
    public let context: AriaV2Contradictions.AnalysisContext
    public let references: AriaV2ContradictionReferences
    public let now: @Sendable () -> Date

    public init(kit: GeniusLocusKit, handle: EstateHandle,
                context: AriaV2Contradictions.AnalysisContext,
                references: AriaV2ContradictionReferences = .shared,
                now: @escaping @Sendable () -> Date) {
        self.kit = kit
        self.handle = handle
        self.context = context
        self.references = references
        self.now = now
    }

    public func hunt(_ request: AriaV2Contradictions.HuntRequest) async throws -> JSONValue {
        switch try await AriaV2Contradictions.hunt(
            request: request, context: context, kit: kit, handle: handle,
            references: references, now: now()) {
        case .refusal(let refusal):
            return AriaV2Envelope.refusal(tool: AriaV2Contradictions.huntToolName, error: refusal)
        case .result(let result):
            let candidates = try await publicCandidates(result.candidates)
            return AriaV2Envelope.success(
                tool: AriaV2Contradictions.huntToolName, effect: .read,
                data: .object([
                    "analysis_ref": .string(result.analysisReference),
                    "expires_at": .string(Self.iso8601(result.expiresAt)),
                    "candidates": .array(candidates),
                ]), meta: ["completeness": .string("incomplete")],
                compactText: "Found \(result.candidates.count) contradiction candidates.")
        }
    }

    public func propose(_ request: AriaV2Contradictions.ProposeRequest) async throws -> JSONValue {
        let operationNow = now()
        switch await AriaV2Contradictions.selectForProposal(
            request: request, context: context, references: references, now: operationNow) {
        case .refusal(let refusal):
            return AriaV2Envelope.refusal(tool: AriaV2Contradictions.proposeToolName, error: refusal)
        case .selected(let selected):
            var results: [JSONValue] = []
            for candidate in selected.candidates {
                let outcome = try await kit.fileSelectedConflictProposal(candidate.proposal, in: handle, now: operationNow)
                switch outcome {
                case .created(let tunnel):
                    results.append(Self.tunnelResult(candidateID: candidate.candidateID, status: "created", tunnel: tunnel))
                case .existing(let tunnel):
                    results.append(Self.tunnelResult(candidateID: candidate.candidateID, status: "existing", tunnel: tunnel))
                case .settled:
                    results.append(.object(["candidate_id": .string(candidate.candidateID), "status": .string("settled")]))
                case .stale:
                    return AriaV2Envelope.refusal(tool: AriaV2Contradictions.proposeToolName, error: .init(
                        code: "proposal_stale", message: "A selected candidate changed; run a fresh contradiction hunt.", retryable: true))
                }
            }
            return AriaV2Envelope.success(
                tool: AriaV2Contradictions.proposeToolName, effect: .write,
                data: .object(["results": .array(results)]),
                meta: ["completeness": .string("incomplete")], compactText: "Recorded selected contradiction proposals.")
        }
    }

    static func tunnelResult(candidateID: String, status: String, tunnel: Tunnel) -> JSONValue {
        .object([
            "candidate_id": .string(candidateID),
            "status": .string(status),
            "tunnel_id": .string(tunnel.id.lowercased()),
            "lifecycle": .string(String(describing: tunnel.lifecycle)),
        ])
    }

    /// Hydrate only the endpoints selected by the read-only hunt, through the
    /// default current/trustworthy/elevated frame. The compact excerpts are
    /// returned to this caller only; the retained proposal cache continues to
    /// contain metadata and digests, never memory bodies or snippets.
    private func publicCandidates(
        _ candidates: [AriaV2Contradictions.Candidate]
    ) async throws -> [JSONValue] {
        guard !candidates.isEmpty else { return [] }
        let memoryIDs = try Set(candidates.flatMap { candidate in
            try [memoryUUID(candidate.sourceMemoryID), memoryUUID(candidate.targetMemoryID)]
        })
        let storageIDs = memoryIDs.flatMap(AriaV2ArgumentDecoder.storageIdentitySpellings)
        let estate = try await kit.estate(for: handle)
        let frame = RecallFrame(
            filterChain: [.currentlyBelieve, .trustworthy, .sensitivityAtMost(.elevated)],
            hydrationLevel: .full)
        let loaded = try await estate.getDrawers(
            ids: storageIDs, matchingFrame: frame, hydrationLevel: .full).admissible
        var byID: [String: Drawer] = [:]
        for drawer in loaded {
            guard let id = UUID(uuidString: drawer.id) else { continue }
            let key = id.uuidString.lowercased()
            guard byID[key] == nil else { throw AriaV2ContradictionFailure.staleFinding }
            byID[key] = drawer
        }
        return try candidates.map { candidate in
            let sourceID = try canonicalMemoryID(candidate.sourceMemoryID)
            let targetID = try canonicalMemoryID(candidate.targetMemoryID)
            guard let source = byID[sourceID], let target = byID[targetID] else {
                throw AriaV2ContradictionFailure.staleFinding
            }
            guard !Self.hasRestrictedProvenance(source), !Self.hasRestrictedProvenance(target),
                  AtomicConflictProposalRequest.drawerDigest(id: source.id, content: source.content)
                    == candidate.proposal.sourceDigest,
                  AtomicConflictProposalRequest.drawerDigest(id: target.id, content: target.content)
                    == candidate.proposal.targetDigest else {
                throw AriaV2ContradictionFailure.staleFinding
            }
            return Self.publicCandidate(
                candidate: candidate,
                sourceID: sourceID,
                sourceExcerpt: source.content,
                targetID: targetID,
                targetExcerpt: target.content)
        }
    }

    static func publicCandidate(
        candidate: AriaV2Contradictions.Candidate,
        sourceID: String,
        sourceExcerpt: String,
        targetID: String,
        targetExcerpt: String
    ) -> JSONValue {
        .object([
            "candidate_id": .string(candidate.candidateID),
            "reason": .string(candidate.proposal.renewalKey),
            "source": endpoint(memoryID: sourceID, excerpt: sourceExcerpt),
            "target": endpoint(memoryID: targetID, excerpt: targetExcerpt),
        ])
    }

    private static func endpoint(memoryID: String, excerpt: String) -> JSONValue {
        .object([
            "memory_id": .string(memoryID),
            "excerpt": .string(AriaV2Envelope.compactText(excerpt)),
            "fetch": .object([
                "tool": .string("moot_memory_get"),
                "arguments": .object(["memory_id": .string(memoryID)]),
            ]),
        ])
    }

    private func memoryUUID(_ raw: String) throws -> UUID {
        guard let id = UUID(uuidString: raw) else {
            throw AriaV2ContradictionFailure.staleFinding
        }
        return id
    }

    private func canonicalMemoryID(_ raw: String) throws -> String {
        try memoryUUID(raw).uuidString.lowercased()
    }

    private static func hasRestrictedProvenance(_ drawer: Drawer) -> Bool {
        let raw = (drawer.provenance >> 30) & 0x3f
        return !candidateEvidenceAllowsProvenance(raw)
    }

    static func candidateEvidenceAllowsProvenance(_ raw: Int64) -> Bool {
        raw == Int64(Sensitivity.normal.rawValue)
            || raw == Int64(Sensitivity.elevated.rawValue)
    }

    private static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
