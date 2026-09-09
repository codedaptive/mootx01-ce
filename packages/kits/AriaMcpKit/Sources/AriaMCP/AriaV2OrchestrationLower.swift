import AriaMCPWire
import CognitionKit
import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit

/// Typed production adapter for the selected v2 orchestration operations.
///
/// It binds the v2 protocol directly to the lower recipe and federation
/// surfaces.  In particular, it never calls `ToolDispatcher`, and it never
/// projects a legacy `ToolResult` back into typed data.
///
/// `AriaV2FederatedSearchData` represents one grant-authorized source
/// contribution. The v2 operation has no aggregate contribution shape, so a
/// fan-out that authorizes zero or more than one source is refused explicitly
/// rather than returning an incomplete contribution set.
public struct AriaV2GeniusLocusOrchestrationProvider: AriaV2OrchestrationProvider, Sendable {
    public let kit: GeniusLocusKit
    public let handle: EstateHandle
    public let federationSources: [EstateHandle]

    public init(kit: GeniusLocusKit, handle: EstateHandle, federationSources: [EstateHandle]) {
        self.kit = kit
        self.handle = handle
        self.federationSources = federationSources
    }

    /// Compatibility construction for a host that has exactly one candidate
    /// peer. The runtime gate still refuses when that peer is not authorized.
    public init(kit: GeniusLocusKit, handle: EstateHandle, federationSource: EstateHandle) {
        self.init(kit: kit, handle: handle, federationSources: [federationSource])
    }

    public func synthesize(
        _ request: AriaV2SynthesizeRequest,
        context: AriaV2OrchestrationContext
    ) async throws -> AriaV2SynthesisData {
        try requireSelectedEstate(context)
        let output = try await GroundedSynthesis().run(
            input: .init(
                frame: try recallFrame(
                    filter: request.filter,
                    limit: request.limit,
                    ordering: nil,
                    hydrationLevel: .full
                ),
                cueTerms: request.query.map(Self.cueTerms) ?? [],
                cap: request.limit,
                query: request.query,
                // ARIA's public read surface must not feed provenance-sensitive
                // content into an ephemeral synthesis result.
                excludeProvenanceSensitive: true,
                scoredLaneScoring: .matrixAware
            ),
            estate: handle,
            kit: kit
        )
        let estate = try await kit.estate(for: handle)
        let loaded = try await estate.getDrawers(
            ids: output.rankedIDs, hydrationLevel: .full)
        let grouped = Dictionary(grouping: loaded, by: { $0.id.lowercased() })
        let memories = try output.rankedIDs.map { id -> AriaV2CompactMemory in
            guard let memoryID = UUID(uuidString: id),
                  let matches = grouped[id.lowercased()], matches.count == 1,
                  let drawer = matches.first,
                  Self.publicCaptureProvenance(drawer.provenance)
            else { throw AriaV2OrchestrationLowerError.invalidLowerIdentity(id) }
            return .init(
                memoryID: memoryID,
                subject: drawer.subject,
                provenance: String(describing: drawer.sourceType).lowercased(),
                excerpt: drawer.content)
        }
        return .init(
            summary: output.context.summary,
            cues: output.context.patterns,
            results: memories
        )
    }

    public func runMigration(
        _ request: AriaV2RunMigrationRequest,
        context: AriaV2OrchestrationContext
    ) async throws -> AriaV2MigrationData {
        try requireSelectedEstate(context)
        let origin = ExternalCorpus(
            name: request.corpusName,
            entries: request.entries.map { .init(id: $0.id, content: $0.content, tags: $0.tags) }
        )
        let plans = try request.plans.map { plan in
            MigrationPlan(
                name: plan.name,
                room: plan.room,
                latticeCode: plan.latticeCode,
                embeddingModelID: plan.embeddingModelID,
                sensitivity: try Self.sensitivity(plan.sensitivity)
            )
        }
        // MigrationBenchmark evaluates and retains candidate COW branches. It
        // never promotes; confirmation remains a separate tool call.
        let output = try await MigrationBenchmark().run(
            input: .init(origin: origin, plans: plans), estate: handle, kit: kit)
        return .init(
            reports: output.benchmarkReports.map(Self.report),
            winnerBranchID: output.comparisonReport.winnerBranchID,
            winnerPlanName: output.comparisonReport.winnerPlanName,
            rankings: output.comparisonReport.rankings.map {
                AriaV2MigrationRanking(
                    branchID: $0.branchID,
                    planName: $0.planName,
                    combinedScore: Double($0.combinedScore),
                    recallOverlap: Double($0.recallOverlap),
                    meanReciprocalRank: Double($0.meanReciprocalRank)
                )
            },
            disqualified: output.comparisonReport.disqualified.map {
                AriaV2DisqualifiedMigration(branchID: $0.branchID, planName: $0.planName, lostConcepts: $0.lostConcepts)
            }
        )
    }

    public func confirmMigration(
        _ request: AriaV2ConfirmMigrationRequest,
        context: AriaV2OrchestrationContext
    ) async throws -> AriaV2MigrationConfirmationData {
        try requireSelectedEstate(context)
        guard let winner = await kit.branchHandle(for: request.winnerBranchID) else {
            throw AriaV2OrchestrationLowerError.unknownMigrationBranch(request.winnerBranchID)
        }
        switch winner.status {
        case .active:
            break
        case .discarded:
            throw AriaV2OrchestrationLowerError.disqualifiedMigrationBranch(request.winnerBranchID)
        case .won, .merged:
            throw AriaV2OrchestrationLowerError.terminalMigrationBranch(
                request.winnerBranchID, status: winner.status.rawValue)
        }

        do {
            let outcomes = try await MigrationBenchmark().confirmPromotion(
                winnerBranchID: request.winnerBranchID,
                discardBranchIDs: request.discardBranchIDs,
                estate: handle,
                kit: kit
            )
            // Promotion has already succeeded here.  A loser cleanup failure is
            // represented by its observed outcome; it must not erase winner identity.
            return .init(
                promotedBranchID: request.winnerBranchID,
                discardedBranchIDs: outcomes.compactMap { outcome in
                    switch outcome.status {
                    case .discarded, .alreadyDiscarded: return outcome.branchID
                    case .winnerSkipped, .unknown, .failed: return nil
                    }
                },
                discardOutcomes: outcomes.map {
                    .init(branchID: $0.branchID, status: Self.discardStatus($0.status))
                }
            )
        } catch let error as RecipeError {
            switch error {
            case .silentConceptLoss:
                throw AriaV2OrchestrationLowerError.disqualifiedMigrationBranch(request.winnerBranchID)
            case .userConfirmationRequired:
                throw AriaV2OrchestrationLowerError.terminalMigrationBranch(
                    request.winnerBranchID, status: winner.status.rawValue)
            default:
                throw error
            }
        }
    }

    public func federatedSearch(
        _ request: AriaV2FederatedSearchRequest,
        context: AriaV2OrchestrationContext
    ) async throws -> AriaV2FederatedSearchData {
        try requireSelectedEstate(context)
        let frame = try recallFrame(
            filter: request.filter,
            limit: request.limit,
            ordering: request.ordering,
            hydrationLevel: try Self.hydration(request.hydrationLevel)
        )
        var seenSources: Set<UUID> = []
        var authorized: [FederatedRecallResult] = []
        for source in federationSources where source.estateUUID != handle.estateUUID {
            guard seenSources.insert(source.estateUUID).inserted else { continue }
            do {
                authorized.append(try await kit.federatedRecall(
                    frame, from: source, requestedBy: handle, now: context.now()))
            } catch let error as GeniusLocusKitError {
                if case .crossEstateReadRefused = error { continue }
                throw error
            }
        }
        guard authorized.count == 1 else {
            throw authorized.isEmpty
                ? AriaV2OrchestrationLowerError.noAuthorizedFederationSource
                : AriaV2OrchestrationLowerError.multipleAuthorizedFederationSources
        }
        let result = authorized[0]
        return .init(
            sourceEstateID: result.sourceHandle.estateUUID,
            requesterEstateID: result.requesterHandle.estateUUID,
            grantID: result.grant.id,
            results: try result.drawers.map(Self.compactMemory)
        )
    }

    private func requireSelectedEstate(_ context: AriaV2OrchestrationContext) throws {
        guard handle.estateUUID == context.estateID else {
            throw AriaV2OrchestrationLowerError.selectedEstateMismatch
        }
    }

    private func recallFrame(
        filter: String?,
        limit: Int?,
        ordering: String?,
        hydrationLevel: HydrationLevel
    ) throws -> RecallFrame {
        .init(
            filterChain: try Self.filterChain(filter),
            hydrationLevel: hydrationLevel,
            limit: limit,
            ordering: try Self.ordering(ordering)
        )
    }

    private static func cueTerms(_ query: String) -> [String] {
        query.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    private static func filterChain(_ filter: String?) throws -> [Filter] {
        switch filter {
        case nil: return []
        case "unconfirmed": return [.unconfirmed]
        case "userConfirmed": return [.userConfirmed]
        case "exportable": return [.exportable]
        case "contained": return [.contained]
        case "pinned": return [.hasFeatureFlag(.isPinned)]
        case let filter?: throw AriaV2OrchestrationLowerError.unsupportedFilter(filter)
        }
    }

    private static func ordering(_ ordering: String?) throws -> Ordering {
        switch ordering {
        case nil, "byCaptureTimeDesc", "byRelevanceDesc": return .byCaptureTimeDesc
        case "byCaptureTimeAsc": return .byCaptureTimeAsc
        case "byRoomAsc": return .byRoomAsc
        case let ordering?: throw AriaV2OrchestrationLowerError.unsupportedOrdering(ordering)
        }
    }

    private static func hydration(_ hydration: String?) throws -> HydrationLevel {
        switch hydration {
        case nil, "structured": return .structured
        case "full": return .full
        case "bitmapOnly": return .bitmapOnly
        case let hydration?: throw AriaV2OrchestrationLowerError.unsupportedHydration(hydration)
        }
    }

    private static func sensitivity(_ sensitivity: String?) throws -> AdjectiveSensitivity {
        switch sensitivity {
        case nil, "normal": return .normal
        case "elevated": return .elevated
        case "restricted": return .restricted
        case "secret": return .secret
        case let sensitivity?: throw AriaV2OrchestrationLowerError.unsupportedSensitivity(sensitivity)
        }
    }

    private static func report(_ report: BenchmarkReport) -> AriaV2BenchmarkReport {
        .init(
            branchID: report.branchID,
            queryCount: report.queryCount,
            recallOverlap: Double(report.recallOverlap),
            recallPrecision: Double(report.recallPrecision),
            meanReciprocalRank: Double(report.meanReciprocalRank),
            notFoundInBranch: report.notFoundInBranch,
            newInBranch: report.newInBranch,
            evaluatedAt: ISO8601DateFormatter().string(from: report.evaluatedAt)
        )
    }

    private static func compactMemory(_ drawer: Drawer) throws -> AriaV2CompactMemory {
        guard let memoryID = UUID(uuidString: drawer.id),
              publicCaptureProvenance(drawer.provenance)
        else {
            throw AriaV2OrchestrationLowerError.invalidLowerIdentity(drawer.id)
        }
        return .init(
            memoryID: memoryID,
            subject: drawer.subject,
            provenance: String(describing: drawer.sourceType).lowercased(),
            excerpt: drawer.content)
    }

    private static func publicCaptureProvenance(_ provenance: Int64) -> Bool {
        let raw = (provenance >> 30) & 0x3f
        return raw == 0 || raw == 16
    }

    private static func discardStatus(_ status: MigrationDiscardStatus) -> AriaV2DiscardOutcomeStatus {
        switch status {
        case .discarded: return .discarded
        case .alreadyDiscarded: return .alreadyDiscarded
        case .winnerSkipped: return .winnerSkipped
        case .unknown: return .unknown
        case .failed: return .failed
        }
    }
}

/// Stable, typed lower-adapter failures.  Callers can distinguish a branch
/// disqualified by C-13 from a branch that reached another terminal state.
public enum AriaV2OrchestrationLowerError: Error, Sendable, Equatable {
    case selectedEstateMismatch
    case noAuthorizedFederationSource
    case multipleAuthorizedFederationSources
    case invalidLowerIdentity(String)
    case unsupportedFilter(String)
    case unsupportedOrdering(String)
    case unsupportedHydration(String)
    case unsupportedSensitivity(String)
    case unknownMigrationBranch(UUID)
    case disqualifiedMigrationBranch(UUID)
    case terminalMigrationBranch(UUID, status: String)

    public var code: String {
        switch self {
        case .selectedEstateMismatch: return "selected_estate_mismatch"
        case .noAuthorizedFederationSource: return "no_authorized_federation_source"
        case .multipleAuthorizedFederationSources: return "multiple_authorized_federation_sources"
        case .invalidLowerIdentity: return "invalid_lower_identity"
        case .unsupportedFilter: return "unsupported_filter"
        case .unsupportedOrdering: return "unsupported_ordering"
        case .unsupportedHydration: return "unsupported_hydration"
        case .unsupportedSensitivity: return "unsupported_sensitivity"
        case .unknownMigrationBranch: return "unknown_branch"
        case .disqualifiedMigrationBranch: return "disqualified_branch"
        case .terminalMigrationBranch: return "terminal_branch"
        }
    }
}
