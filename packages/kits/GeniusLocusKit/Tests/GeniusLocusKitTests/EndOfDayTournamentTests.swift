// EndOfDayTournamentTests.swift
//
// Two recall traces in the same minute form one contest; the tournament
// writes one recall_ratings row per participating drawer.

import Testing
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import GeniusLocusKit

@Suite("EndOfDayTournament")
struct EndOfDayTournamentTests {

    @Test("two traces in one minute yield one contest and two rating rows")
    func oneContestTwoRatings() async throws {
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        let owner = OwnerCredentials(ownerIdentifier: "tournament-test-owner")
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let kit = GeniusLocusKit()
        let handle = try await kit.open(storage: storage, owner: owner)
        let estate = try await kit.estate(for: handle)

        // Fixed clock: both traces sit inside the same minute, one second apart.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let recalledAt = now.addingTimeInterval(-3600)
        let winner = UUID().uuidString
        let loser = UUID().uuidString
        try await estate.insertRecallTraces([
            RecallTraceItem(target: winner, recalledAt: recalledAt),
            RecallTraceItem(target: loser, recalledAt: recalledAt.addingTimeInterval(1)),
        ])

        let report = try await kit.endOfDayTournament(handle, now: now)
        #expect(report.contests == 1)
        #expect(report.ratedDrawers == 2)

        let ratings = try await estate.recallRatings(ids: [winner, loser])
        #expect(ratings.count == 2)
        #expect(ratings[winner]?.contests == 1)
        #expect(ratings[loser]?.contests == 1)
    }
}
