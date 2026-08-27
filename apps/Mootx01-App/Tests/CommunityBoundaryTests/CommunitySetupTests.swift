import Foundation
import MootCommunityUI
import Testing

@Suite("Community first-run and recovery")
struct CommunitySetupTests {
    private let estate = CommunityEstateSummary(
        id: UUID(uuidString: "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC")!,
        name: "Home",
        schemaVersion: "1.0"
    )

    @MainActor
    @Test("new estate and existing estate outcomes become ready only after daemon receipts")
    func creationAndOpen() async {
        let receipt = CommunityEstateReceipt(
            estate: estate,
            receiptID: UUID(uuidString: "DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD")!
        )
        let service = SetupFixture(states: [.needsCreation, .ready(receipt)])
        let model = CommunitySetupModel(service: service)

        await model.refresh()
        #expect(model.state == .needsCreation)
        await model.create()
        #expect(model.state == .ready(receipt))
    }

    @MainActor
    @Test("a returning user can select and reopen a daemon-supplied estate")
    func openExistingEstate() async {
        let receipt = CommunityEstateReceipt(
            estate: estate,
            receiptID: UUID(uuidString: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB")!
        )
        let service = SetupFixture(states: [.chooseExisting([estate]), .ready(receipt)])
        let model = CommunitySetupModel(service: service)

        await model.refresh()
        #expect(model.state == .chooseExisting([estate]))

        await model.open(estate)
        #expect(model.state == .ready(receipt))
        #expect(await service.openedEstateIDs == [estate.id])
    }

    @MainActor
    @Test("missing key and corruption remain explicit recovery states")
    func recoveryStates() async {
        let choice = CommunityRecoveryChoice(
            id: "restore-backup",
            title: "Restore Backup",
            consequence: "Replaces the damaged estate with the selected backup.",
            isDestructive: true
        )
        let service = SetupFixture(states: [
            .missingKey(estate: estate, choices: [choice]),
            .corrupt(estate: estate, diagnosis: "integrity-check-failed", choices: [choice]),
        ])
        let model = CommunitySetupModel(service: service)

        await model.refresh()
        #expect(model.state == .missingKey(estate: estate, choices: [choice]))
        await model.refresh()
        #expect(model.state == .corrupt(estate: estate, diagnosis: "integrity-check-failed", choices: [choice]))
    }

    @MainActor
    @Test("incompatible schema and unrecoverable refusal remain explicit")
    func incompatibleAndBlockedStates() async {
        let service = SetupFixture(states: [
            .incompatible(estate: estate, reason: "requires-app-1.2"),
            .blocked(reason: "recovery-authority-unavailable"),
        ])
        let model = CommunitySetupModel(service: service)

        await model.refresh()
        #expect(model.state == .incompatible(estate: estate, reason: "requires-app-1.2"))
        await model.refresh()
        #expect(model.state == .blocked(reason: "recovery-authority-unavailable"))
    }

    @MainActor
    @Test("destructive recovery requires a separate explicit confirmation")
    func destructiveConfirmation() async {
        let choice = CommunityRecoveryChoice(
            id: "rebuild",
            title: "Rebuild",
            consequence: "Unrecoverable records may be removed.",
            isDestructive: true
        )
        let service = SetupFixture(states: [.cancelled(resumable: true)])
        let model = CommunitySetupModel(service: service)

        await model.chooseRecovery(choice)
        #expect(model.pendingDestructiveChoice == choice)
        #expect(await service.recoveryCalls == 0)

        await model.confirmDestructiveRecovery()
        #expect(model.pendingDestructiveChoice == nil)
        #expect(await service.recoveryCalls == 1)
        #expect(model.state == .cancelled(resumable: true))
    }

    @MainActor
    @Test("migration exposes versions, progress, interruption and resumability")
    func migrationLifecycle() async {
        let plan = CommunityMigrationPlan(
            id: UUID(uuidString: "EEEEEEEE-EEEE-4EEE-8EEE-EEEEEEEEEEEE")!,
            estate: estate,
            sourceVersion: "1.0",
            targetVersion: "1.1",
            expectedEffect: "Upgrades the estate schema in place."
        )
        let progress = CommunityMigrationProgress(
            operationID: UUID(uuidString: "FFFFFFFF-FFFF-4FFF-8FFF-FFFFFFFFFFFF")!,
            plan: plan,
            completedUnits: 4,
            totalUnits: 10
        )
        let receipt = CommunityEstateReceipt(
            estate: estate,
            receiptID: UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!
        )
        let service = SetupFixture(states: [
            .migrationRequired(plan),
            .migrating(progress),
            .cancelled(resumable: true),
            .ready(receipt),
        ])
        let model = CommunitySetupModel(service: service)

        await model.refresh()
        #expect(model.state == .migrationRequired(plan))
        await model.migrate(plan)
        #expect(model.state == .migrating(progress))
        await model.cancelMigration(progress)
        #expect(model.state == .cancelled(resumable: true))
        await model.migrate(plan)
        #expect(model.state == .ready(receipt))
    }
}

private actor SetupFixture: CommunityEstateLifecycleServicing {
    private var states: [CommunityEstateLifecycleState]
    private(set) var recoveryCalls = 0
    private(set) var openedEstateIDs: [UUID] = []

    init(states: [CommunityEstateLifecycleState]) { self.states = states }

    private func next() -> CommunityEstateLifecycleState {
        states.isEmpty ? .blocked(reason: "fixture-exhausted") : states.removeFirst()
    }

    func inspect() async -> CommunityEstateLifecycleState { next() }
    func createEstate(named name: String) async -> CommunityEstateLifecycleState { next() }
    func openEstate(id: UUID) async -> CommunityEstateLifecycleState {
        openedEstateIDs.append(id)
        return next()
    }
    func beginMigration(planID: UUID) async -> CommunityEstateLifecycleState { next() }
    func recover(choiceID: String) async -> CommunityEstateLifecycleState {
        recoveryCalls += 1
        return next()
    }
    func cancel(operationID: UUID) async -> CommunityEstateLifecycleState { next() }
}
