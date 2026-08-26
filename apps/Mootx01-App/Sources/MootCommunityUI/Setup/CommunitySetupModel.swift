import Foundation
import Observation

public struct CommunityEstateSummary: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let name: String
    public let schemaVersion: String

    public init(id: UUID, name: String, schemaVersion: String) {
        self.id = id
        self.name = name
        self.schemaVersion = schemaVersion
    }
}

public struct CommunityEstateReceipt: Sendable, Equatable {
    public let estate: CommunityEstateSummary
    public let receiptID: UUID

    public init(estate: CommunityEstateSummary, receiptID: UUID) {
        self.estate = estate
        self.receiptID = receiptID
    }
}

public struct CommunityMigrationPlan: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let estate: CommunityEstateSummary
    public let sourceVersion: String
    public let targetVersion: String
    public let expectedEffect: String

    public init(
        id: UUID,
        estate: CommunityEstateSummary,
        sourceVersion: String,
        targetVersion: String,
        expectedEffect: String
    ) {
        self.id = id
        self.estate = estate
        self.sourceVersion = sourceVersion
        self.targetVersion = targetVersion
        self.expectedEffect = expectedEffect
    }
}

public struct CommunityMigrationProgress: Sendable, Equatable {
    public let operationID: UUID
    public let plan: CommunityMigrationPlan
    public let completedUnits: Int
    public let totalUnits: Int

    public init(
        operationID: UUID,
        plan: CommunityMigrationPlan,
        completedUnits: Int,
        totalUnits: Int
    ) {
        self.operationID = operationID
        self.plan = plan
        self.completedUnits = completedUnits
        self.totalUnits = totalUnits
    }
}

public struct CommunityRecoveryChoice: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let consequence: String
    public let isDestructive: Bool

    public init(id: String, title: String, consequence: String, isDestructive: Bool) {
        self.id = id
        self.title = title
        self.consequence = consequence
        self.isDestructive = isDestructive
    }
}

public enum CommunityEstateLifecycleState: Sendable, Equatable {
    case checking
    case needsCreation
    case chooseExisting([CommunityEstateSummary])
    case missingKey(estate: CommunityEstateSummary, choices: [CommunityRecoveryChoice])
    case corrupt(estate: CommunityEstateSummary, diagnosis: String, choices: [CommunityRecoveryChoice])
    case incompatible(estate: CommunityEstateSummary, reason: String)
    case migrationRequired(CommunityMigrationPlan)
    case migrating(CommunityMigrationProgress)
    case ready(CommunityEstateReceipt)
    case cancelled(resumable: Bool)
    case blocked(reason: String)
}

public protocol CommunityEstateLifecycleServicing: Actor, Sendable {
    func inspect() async -> CommunityEstateLifecycleState
    func createEstate(named name: String) async -> CommunityEstateLifecycleState
    func openEstate(id: UUID) async -> CommunityEstateLifecycleState
    func beginMigration(planID: UUID) async -> CommunityEstateLifecycleState
    func recover(choiceID: String) async -> CommunityEstateLifecycleState
    func cancel(operationID: UUID) async -> CommunityEstateLifecycleState
}

public actor UnavailableCommunityEstateLifecycleService: CommunityEstateLifecycleServicing {
    public init() {}
    public func inspect() async -> CommunityEstateLifecycleState { .blocked(reason: "daemon-unavailable") }
    public func createEstate(named name: String) async -> CommunityEstateLifecycleState { await inspect() }
    public func openEstate(id: UUID) async -> CommunityEstateLifecycleState { await inspect() }
    public func beginMigration(planID: UUID) async -> CommunityEstateLifecycleState { await inspect() }
    public func recover(choiceID: String) async -> CommunityEstateLifecycleState { await inspect() }
    public func cancel(operationID: UUID) async -> CommunityEstateLifecycleState { .cancelled(resumable: true) }
}

@MainActor
@Observable
public final class CommunitySetupModel {
    public private(set) var state: CommunityEstateLifecycleState = .checking
    public var newEstateName = "My MOOT"
    public private(set) var pendingDestructiveChoice: CommunityRecoveryChoice?
    public private(set) var isWorking = false

    private let service: any CommunityEstateLifecycleServicing

    public init(service: any CommunityEstateLifecycleServicing) {
        self.service = service
    }

    public func refresh() async { await perform { await service.inspect() } }
    public func create() async { await perform { await service.createEstate(named: newEstateName) } }
    public func open(_ estate: CommunityEstateSummary) async {
        await perform { await service.openEstate(id: estate.id) }
    }
    public func migrate(_ plan: CommunityMigrationPlan) async {
        await perform { await service.beginMigration(planID: plan.id) }
    }

    public func chooseRecovery(_ choice: CommunityRecoveryChoice) async {
        if choice.isDestructive {
            pendingDestructiveChoice = choice
        } else {
            await recover(choice)
        }
    }

    public func confirmDestructiveRecovery() async {
        guard let choice = pendingDestructiveChoice else { return }
        pendingDestructiveChoice = nil
        await recover(choice)
    }

    public func dismissDestructiveRecovery() {
        pendingDestructiveChoice = nil
    }

    public func cancelMigration(_ progress: CommunityMigrationProgress) async {
        await perform { await service.cancel(operationID: progress.operationID) }
    }

    private func recover(_ choice: CommunityRecoveryChoice) async {
        await perform { await service.recover(choiceID: choice.id) }
    }

    private func perform(
        _ operation: () async -> CommunityEstateLifecycleState
    ) async {
        guard !isWorking else { return }
        isWorking = true
        let result = await operation()
        state = result
        isWorking = false
    }
}
