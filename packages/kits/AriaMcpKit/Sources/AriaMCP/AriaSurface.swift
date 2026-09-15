import AriaMCPWire

/// A stable public-operation identity.  Policy is based on this identity,
/// rather than on the spelling a surface used to reach an implementation.
enum AriaOperation: String, Sendable {
    case help
    case fileMemory
    case memorySearch
    case memoryList
    case memoryGet
    case transcriptRecall
    case similarRecall
    case typedRecall
    case synthesize
    case dream
    case migrationRun
    case migrationConfirm
    case federatedRecall
    case huntContradictions
    case proposeContradictions
    case connectionSearch
    case connectionMap
    case fileFact
    case factSearch
    case retireFact
    case factTimeline
    case writeJournal
    case readJournal
    case monitoringSet
    case monitoringStatus
    case estatePing
    case estateStatus
    case estateMap
    case drainStatus
    case rebuildStatus
    case timingReport
    case listLenses
    case listRecipes
    case updateMemory
    case withdrawMemory
    case eraseMemory
    case confirmMemory
    case moveMemory
    case linkMemories
    case reviewTunnel
    case vaultExport
    case vaultImport
    case vaultJob
    case reindex
    case reclassifyFDC
    case palaceImport
    case jsonImport
    case fileDataset
    case datasetQuery
    case datasetStats
    case vaultStatus
    case vaultReconcile

    enum Effect: Sendable {
        case inspection
        case mutation
    }

    var effect: Effect {
        switch self {
        case .help, .memorySearch, .memoryList, .memoryGet, .transcriptRecall, .similarRecall, .typedRecall, .synthesize, .migrationRun, .federatedRecall, .huntContradictions, .connectionSearch, .connectionMap, .factSearch, .factTimeline, .readJournal, .monitoringStatus, .estatePing, .estateStatus, .estateMap, .drainStatus, .rebuildStatus, .timingReport, .listLenses, .listRecipes, .vaultExport, .vaultJob, .datasetQuery, .datasetStats, .vaultStatus:
            return .inspection
        case .fileMemory, .dream, .migrationConfirm, .proposeContradictions, .fileFact, .retireFact, .writeJournal, .monitoringSet, .updateMemory, .withdrawMemory, .eraseMemory, .confirmMemory, .moveMemory, .linkMemories, .reviewTunnel, .vaultImport, .reindex, .reclassifyFDC, .palaceImport, .jsonImport, .fileDataset, .vaultReconcile:
            return .mutation
        }
    }
}

/// A typed request accepted by the selected v2 surface.
enum AriaSurfaceRequest: Sendable {
    case help(AriaV2HelpRequest)
    case fileMemory(AriaV2FileMemoryRequest)
    case memorySearch(AriaV2MemorySearchRequest)
    case memoryList(AriaV2MemoryListRequest)
    case memoryGet(AriaV2MemoryGetRequest)
    case transcriptRecall(AriaV2TranscriptRecallRequest)
    case similarRecall(AriaV2SimilarRecallRequest)
    case recallLens(AriaV2RecallLensRequest)
    case synthesize(AriaV2SynthesizeRequest)
    case dream(AriaV2Dream.Request)
    case migrationRun(AriaV2RunMigrationRequest)
    case migrationConfirm(AriaV2ConfirmMigrationRequest)
    case federatedRecall(AriaV2FederatedSearchRequest)
    case huntContradictions(AriaV2Contradictions.HuntRequest)
    case proposeContradictions(AriaV2Contradictions.ProposeRequest)
    case connectionSearch(AriaV2ConnectionSearchRequest)
    case connectionMap(AriaV2ConnectionMapRequest)
    case fileFact(AriaV2FileFactRequest)
    case factSearch(AriaV2FactSearchRequest)
    case retireFact(AriaV2RetireFactRequest)
    case factTimeline(AriaV2FactTimelineRequest)
    case writeJournal(AriaV2WriteJournalRequest)
    case readJournal(AriaV2ReadJournalRequest)
    case monitoringSet(AriaV2MonitoringSet.Request)
    case monitoringStatus(AriaV2MonitoringInspection.Request)
    case estatePing(AriaV2EstateDiagnosticsRequest)
    case estateStatus(AriaV2EstateDiagnosticsRequest)
    case estateMap(AriaV2EstateDiagnosticsRequest)
    case drainStatus(AriaV2EstateDiagnosticsRequest)
    case rebuildStatus(AriaV2EstateDiagnosticsRequest)
    case timingReport(AriaV2EstateDiagnosticsRequest)
    case listLenses(AriaV2CognitionCatalogRequest)
    case listRecipes(AriaV2CognitionCatalogRequest)
    case updateMemory(AriaV2UpdateMemoryRequest)
    case withdrawMemory(AriaV2WithdrawMemoryRequest)
    case eraseMemory(AriaV2EraseMemoryRequest)
    case confirmMemory(AriaV2ConfirmMemoryRequest)
    case moveMemory(AriaV2MoveMemoryRequest)
    case linkMemories(AriaV2LinkMemoriesRequest)
    case reviewTunnel(AriaV2ReviewTunnelRequest)
    case dataMobility(AriaV2DataMobilityRequest)

    var operation: AriaOperation {
        switch self {
        case .help: return .help
        case .fileMemory: return .fileMemory
        case .memorySearch: return .memorySearch
        case .memoryList: return .memoryList
        case .memoryGet: return .memoryGet
        case .transcriptRecall: return .transcriptRecall
        case .similarRecall: return .similarRecall
        case .recallLens: return .typedRecall
        case .synthesize: return .synthesize
        case .dream: return .dream
        case .migrationRun: return .migrationRun
        case .migrationConfirm: return .migrationConfirm
        case .federatedRecall: return .federatedRecall
        case .huntContradictions: return .huntContradictions
        case .proposeContradictions: return .proposeContradictions
        case .connectionSearch: return .connectionSearch
        case .connectionMap: return .connectionMap
        case .fileFact: return .fileFact
        case .factSearch: return .factSearch
        case .retireFact: return .retireFact
        case .factTimeline: return .factTimeline
        case .writeJournal: return .writeJournal
        case .readJournal: return .readJournal
        case .monitoringSet: return .monitoringSet
        case .monitoringStatus: return .monitoringStatus
        case .estatePing: return .estatePing
        case .estateStatus: return .estateStatus
        case .estateMap: return .estateMap
        case .drainStatus: return .drainStatus
        case .rebuildStatus: return .rebuildStatus
        case .timingReport: return .timingReport
        case .listLenses: return .listLenses
        case .listRecipes: return .listRecipes
        case .updateMemory: return .updateMemory
        case .withdrawMemory: return .withdrawMemory
        case .eraseMemory: return .eraseMemory
        case .confirmMemory: return .confirmMemory
        case .moveMemory: return .moveMemory
        case .linkMemories: return .linkMemories
        case .reviewTunnel: return .reviewTunnel
        case .dataMobility(let request):
            switch request {
            case .vaultExport: return .vaultExport
            case .vaultImport: return .vaultImport
            case .vaultJob: return .vaultJob
            case .reindex: return .reindex
            case .reclassifyFDC: return .reclassifyFDC
            case .palaceImport: return .palaceImport
            case .jsonImport: return .jsonImport
            case .fileDataset: return .fileDataset
            case .datasetQuery: return .datasetQuery
            case .datasetStats: return .datasetStats
            case .vaultStatus: return .vaultStatus
            case .vaultReconcile: return .vaultReconcile
            }
        }
    }

    var toolName: String {
        switch self {
        case .help: return "moot_help"
        case .fileMemory: return "moot_file_memory"
        case .memorySearch: return "moot_memory_search"
        case .memoryList: return AriaV2MemoryListRequest.toolName
        case .memoryGet: return "moot_memory_get"
        case .transcriptRecall: return AriaV2TranscriptRecallRequest.toolName
        case .similarRecall: return AriaV2SimilarRecallRequest.toolName
        case .recallLens(let request): return request.operation.rawValue
        case .synthesize: return AriaV2OrchestrationOperation.synthesize.rawValue
        case .dream: return AriaV2Dream.toolName
        case .migrationRun: return AriaV2OrchestrationOperation.runMigration.rawValue
        case .migrationConfirm: return AriaV2OrchestrationOperation.confirmMigration.rawValue
        case .federatedRecall: return AriaV2OrchestrationOperation.federatedSearch.rawValue
        case .huntContradictions: return AriaV2Contradictions.huntToolName
        case .proposeContradictions: return AriaV2Contradictions.proposeToolName
        case .connectionSearch: return AriaV2KnowledgeJournalOperation.connectionSearch.rawValue
        case .connectionMap: return AriaV2KnowledgeJournalOperation.connectionMap.rawValue
        case .fileFact: return AriaV2KnowledgeJournalOperation.fileFact.rawValue
        case .factSearch: return AriaV2KnowledgeJournalOperation.factSearch.rawValue
        case .retireFact: return AriaV2KnowledgeJournalOperation.retireFact.rawValue
        case .factTimeline: return AriaV2KnowledgeJournalOperation.factTimeline.rawValue
        case .writeJournal: return AriaV2KnowledgeJournalOperation.writeJournal.rawValue
        case .readJournal: return AriaV2KnowledgeJournalOperation.readJournal.rawValue
        case .monitoringSet: return AriaV2MonitoringSet.toolName
        case .monitoringStatus: return AriaV2MonitoringInspection.toolName
        case .estatePing: return AriaV2EstateDiagnosticOperation.estatePing.rawValue
        case .estateStatus: return AriaV2EstateDiagnosticOperation.estateStatus.rawValue
        case .estateMap: return AriaV2EstateDiagnosticOperation.estateMap.rawValue
        case .drainStatus: return AriaV2EstateDiagnosticOperation.drainStatus.rawValue
        case .rebuildStatus: return AriaV2EstateDiagnosticOperation.rebuildStatus.rawValue
        case .timingReport: return AriaV2EstateDiagnosticOperation.timingReport.rawValue
        case .listLenses: return AriaV2CognitionCatalogService.lensesToolName
        case .listRecipes: return AriaV2CognitionCatalogService.recipesToolName
        case .updateMemory: return "moot_update_memory"
        case .withdrawMemory: return "moot_withdraw_memory"
        case .eraseMemory: return "moot_erase_memory"
        case .confirmMemory: return "moot_confirm_memory"
        case .moveMemory: return "moot_move_memory"
        case .linkMemories: return "moot_link_memories"
        case .reviewTunnel: return "moot_review_tunnel"
        case .dataMobility(let request): return request.tool
        }
    }
}

/// Decodes selected v2 names into their typed requests.  Admission is owned
/// by `ToolProjection`; this decoder owns the operation-specific contract.
enum AriaSurfaceDecoder {
    static func decode(name: String, arguments: [String: JSONValue]) throws -> AriaSurfaceRequest {
        let object = JSONValue.object(arguments)
        switch name {
        case "moot_help":
            return .help(try AriaV2HelpRequest(arguments: object))
        case "moot_file_memory":
            return .fileMemory(try AriaV2FileMemoryRequest(arguments: object))
        case "moot_memory_search":
            return .memorySearch(try AriaV2MemorySearchRequest(arguments: object))
        case AriaV2MemoryListRequest.toolName:
            return .memoryList(try AriaV2MemoryListRequest(arguments: object))
        case "moot_memory_get":
            return .memoryGet(try AriaV2MemoryGetRequest(arguments: object))
        case AriaV2TranscriptRecallRequest.toolName:
            return .transcriptRecall(try AriaV2TranscriptRecallRequest(arguments: object))
        case AriaV2SimilarRecallRequest.toolName:
            return .similarRecall(try AriaV2SimilarRecallRequest(arguments: object))
        case AriaV2RecallLensOperation.recallPrecise.rawValue:
            return .recallLens(try AriaV2RecallLensRequest(tool: name, arguments: object))
        case AriaV2RecallLensOperation.recallTemporal.rawValue:
            return .recallLens(try AriaV2RecallLensRequest(tool: name, arguments: object))
        case AriaV2RecallLensOperation.recallConnected.rawValue:
            return .recallLens(try AriaV2RecallLensRequest(tool: name, arguments: object))
        case AriaV2RecallLensOperation.recallShaped.rawValue:
            return .recallLens(try AriaV2RecallLensRequest(tool: name, arguments: object))
        case AriaV2RecallLensOperation.recallDistilled.rawValue:
            return .recallLens(try AriaV2RecallLensRequest(tool: name, arguments: object))
        case AriaV2RecallLensOperation.recallVague.rawValue:
            return .recallLens(try AriaV2RecallLensRequest(tool: name, arguments: object))
        case AriaV2RecallLensOperation.recallWalk.rawValue:
            return .recallLens(try AriaV2RecallLensRequest(tool: name, arguments: object))
        case AriaV2RecallLensOperation.lensKeystones.rawValue,
             AriaV2RecallLensOperation.lensConstellation.rawValue,
             AriaV2RecallLensOperation.lensFreeAssociation.rawValue,
             AriaV2RecallLensOperation.lensBias.rawValue,
             AriaV2RecallLensOperation.lensCohesion.rawValue,
             AriaV2RecallLensOperation.lensContradiction.rawValue,
             AriaV2RecallLensOperation.lensThemeWeather.rawValue,
             AriaV2RecallLensOperation.lensLatentThemes.rawValue,
             AriaV2RecallLensOperation.lensDrift.rawValue,
             AriaV2RecallLensOperation.lensTrustSynthesis.rawValue,
             AriaV2RecallLensOperation.lensPartialCue.rawValue,
             AriaV2RecallLensOperation.lensAnticipate.rawValue,
             AriaV2RecallLensOperation.lensNodeMotion.rawValue,
             AriaV2RecallLensOperation.lensSuccessors.rawValue,
             AriaV2RecallLensOperation.lensOverlap.rawValue,
             AriaV2RecallLensOperation.lensDivergence.rawValue,
             AriaV2RecallLensOperation.lensAssociations.rawValue,
             AriaV2RecallLensOperation.lensConcepts.rawValue,
             AriaV2RecallLensOperation.lensApriori.rawValue,
             AriaV2RecallLensOperation.lensMoment.rawValue,
             AriaV2RecallLensOperation.lensRhythm.rawValue,
             AriaV2RecallLensOperation.lensPrecedence.rawValue,
             AriaV2RecallLensOperation.lensComplexity.rawValue:
            return .recallLens(try AriaV2RecallLensRequest(tool: name, arguments: object))
        case AriaV2OrchestrationOperation.synthesize.rawValue:
            return .synthesize(try AriaV2SynthesizeRequest(arguments: object))
        case AriaV2Dream.toolName:
            return .dream(try AriaV2Dream.Request(arguments: object))
        case AriaV2OrchestrationOperation.runMigration.rawValue:
            return .migrationRun(try AriaV2RunMigrationRequest(arguments: object))
        case AriaV2OrchestrationOperation.confirmMigration.rawValue:
            return .migrationConfirm(try AriaV2ConfirmMigrationRequest(arguments: object))
        case AriaV2OrchestrationOperation.federatedSearch.rawValue:
            return .federatedRecall(try AriaV2FederatedSearchRequest(arguments: object))
        case AriaV2Contradictions.huntToolName:
            return .huntContradictions(try AriaV2Contradictions.HuntRequest(arguments: object))
        case AriaV2Contradictions.proposeToolName:
            return .proposeContradictions(try AriaV2Contradictions.ProposeRequest(arguments: object))
        case AriaV2KnowledgeJournalOperation.connectionSearch.rawValue:
            return .connectionSearch(try AriaV2ConnectionSearchRequest(arguments: object))
        case AriaV2KnowledgeJournalOperation.connectionMap.rawValue:
            return .connectionMap(try AriaV2ConnectionMapRequest(arguments: object))
        case AriaV2KnowledgeJournalOperation.fileFact.rawValue:
            return .fileFact(try AriaV2FileFactRequest(arguments: object))
        case AriaV2KnowledgeJournalOperation.factSearch.rawValue:
            return .factSearch(try AriaV2FactSearchRequest(arguments: object))
        case AriaV2KnowledgeJournalOperation.retireFact.rawValue:
            return .retireFact(try AriaV2RetireFactRequest(arguments: object))
        case AriaV2KnowledgeJournalOperation.factTimeline.rawValue:
            return .factTimeline(try AriaV2FactTimelineRequest(arguments: object))
        case AriaV2KnowledgeJournalOperation.writeJournal.rawValue:
            return .writeJournal(try AriaV2WriteJournalRequest(arguments: object))
        case AriaV2KnowledgeJournalOperation.readJournal.rawValue:
            return .readJournal(try AriaV2ReadJournalRequest(arguments: object))
        case AriaV2MonitoringSet.toolName:
            return .monitoringSet(try AriaV2MonitoringSet.Request(arguments: object))
        case AriaV2MonitoringInspection.toolName:
            return .monitoringStatus(try AriaV2MonitoringInspection.Request(arguments: arguments))
        case AriaV2EstateDiagnosticOperation.estatePing.rawValue:
            return .estatePing(try AriaV2EstateDiagnosticsRequest(arguments: object))
        case AriaV2EstateDiagnosticOperation.estateStatus.rawValue:
            return .estateStatus(try AriaV2EstateDiagnosticsRequest(arguments: object))
        case AriaV2EstateDiagnosticOperation.estateMap.rawValue:
            return .estateMap(try AriaV2EstateDiagnosticsRequest(arguments: object))
        case AriaV2EstateDiagnosticOperation.drainStatus.rawValue:
            return .drainStatus(try AriaV2EstateDiagnosticsRequest(arguments: object))
        case AriaV2EstateDiagnosticOperation.rebuildStatus.rawValue:
            return .rebuildStatus(try AriaV2EstateDiagnosticsRequest(arguments: object))
        case AriaV2EstateDiagnosticOperation.timingReport.rawValue:
            return .timingReport(try AriaV2EstateDiagnosticsRequest(arguments: object))
        case AriaV2CognitionCatalogService.lensesToolName:
            return .listLenses(try AriaV2CognitionCatalogRequest(arguments: object))
        case AriaV2CognitionCatalogService.recipesToolName:
            return .listRecipes(try AriaV2CognitionCatalogRequest(arguments: object))
        case "moot_update_memory":
            return .updateMemory(try AriaV2UpdateMemoryRequest(arguments: object))
        case "moot_withdraw_memory":
            return .withdrawMemory(try AriaV2WithdrawMemoryRequest(arguments: object))
        case "moot_erase_memory":
            return .eraseMemory(try AriaV2EraseMemoryRequest(arguments: object))
        case "moot_confirm_memory":
            return .confirmMemory(try AriaV2ConfirmMemoryRequest(arguments: object))
        case "moot_move_memory":
            return .moveMemory(try AriaV2MoveMemoryRequest(arguments: object))
        case "moot_link_memories":
            return .linkMemories(try AriaV2LinkMemoriesRequest(arguments: object))
        case "moot_review_tunnel":
            return .reviewTunnel(try AriaV2ReviewTunnelRequest(arguments: object))
        case "moot_reindex", "moot_reclassify_fdc", "moot_palace_import", "moot_json_import",
             "moot_file_dataset", "moot_dataset_query", "moot_dataset_stats",
             "moot_vault_export", "moot_vault_import", "moot_vault_job",
             "moot_vault_status", "moot_vault_reconcile":
            return .dataMobility(try AriaV2DataMobilityRequest.decode(tool: name, arguments: object))
        default:
            throw JSONRPCError(
                code: JSONRPCErrorCode.methodNotFound,
                message: "Unknown tool: \(name)"
            )
        }
    }
}
