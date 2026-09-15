// EndOfDayTournament.swift
//
// Standing signal 7 (end-of-day-tournament): folds the day's recall traces
// into per-drawer Bradley-Terry ratings stored in `recall_ratings`.

import Foundation
import LocusKit
import SubstrateML

/// Outcome of one end-of-day tournament pass.
public struct TournamentReport: Sendable, Equatable {
    /// Number of preference observations fed to the estimator (one per
    /// minute group with two or more distinct UUID targets).
    public let contests: Int

    /// Number of `recall_ratings` rows written by this pass.
    public let ratedDrawers: Int

    /// Designated initializer.
    public init(contests: Int, ratedDrawers: Int) {
        self.contests = contests
        self.ratedDrawers = ratedDrawers
    }
}

/// Length of the tournament window: every trace with `recalledAt` in
/// `[now - 24h, now]` takes part. Daily cadence matches the signal's spec.
private let tournamentWindowSeconds: TimeInterval = 24 * 60 * 60

/// Grouping bucket for one contest: traces recalled within the same
/// wall-clock minute are treated as one recall result list.
private let contestBucketSeconds: TimeInterval = 60

public extension GeniusLocusKit {
    /// Folds the day's recalls into per-drawer Bradley-Terry ratings: every recall
    /// trace since `now - 24h` is grouped by minute of `recalledAt`; within a group
    /// the first-listed drawer beats the others (one PreferenceObservation per group
    /// with two or more targets); the observations feed a BradleyTerryEstimator
    /// seeded from the stored ratings; the resulting strengths are upserted.
    ///
    /// Drawer ids that are not UUID strings cannot be estimator row ids and are
    /// skipped. A drawer's stored `contests` count is carried forward and
    /// incremented by the number of observations it took part in this pass.
    /// Deterministic: `now` is the caller's clock; nothing reads `Date()`.
    ///
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if the handle is stale.
    func endOfDayTournament(_ handle: EstateHandle, now: Date) async throws -> TournamentReport {
        let estate = try estate(for: handle)
        let since = now.addingTimeInterval(-tournamentWindowSeconds)
        let traces = try await estate.recentRecallTraces(since: since, now: now)

        // Group by minute bucket, preserving the store's ascending order so
        // the first-listed drawer in a group is the earliest trace of that
        // minute. Targets are de-duplicated within a group.
        var bucketOrder: [Int] = []
        var buckets: [Int: [UUID]] = [:]
        for trace in traces {
            guard let id = UUID(uuidString: trace.target) else { continue }
            let bucket = Int((trace.recalledAt.timeIntervalSince1970 / contestBucketSeconds).rounded(.down))
            if buckets[bucket] == nil {
                buckets[bucket] = []
                bucketOrder.append(bucket)
            }
            if buckets[bucket]!.contains(id) == false {
                buckets[bucket]!.append(id)
            }
        }

        var observations: [PreferenceObservation] = []
        var appearances: [UUID: Int] = [:]
        for bucket in bucketOrder {
            let ids = buckets[bucket] ?? []
            guard ids.count >= 2 else { continue }
            observations.append(PreferenceObservation(winnerID: ids[0], losers: Array(ids.dropFirst())))
            for id in ids { appearances[id, default: 0] += 1 }
        }
        guard observations.isEmpty == false else {
            return TournamentReport(contests: 0, ratedDrawers: 0)
        }

        // Seed the estimator from the stored ratings so strengths accumulate
        // across passes; unseen drawers start at the estimator's zero prior.
        let participantIDs = appearances.keys.sorted { $0.uuidString < $1.uuidString }
        let stored = try await estate.recallRatings(ids: participantIDs.map(\.uuidString))
        var theta: [UUID: Double] = [:]
        for id in participantIDs {
            if let prior = stored[id.uuidString] { theta[id] = prior.rating }
        }
        var estimator = BradleyTerryEstimator(theta: theta)
        estimator.observeBatch(observations)

        let ratings: [RecallRating] = participantIDs.map { id in
            RecallRating(
                drawerID: id.uuidString,
                rating: estimator.strength(of: id),
                contests: (stored[id.uuidString]?.contests ?? 0) + (appearances[id] ?? 0),
                updatedAt: now
            )
        }
        try await estate.upsertRecallRatings(ratings)
        return TournamentReport(contests: observations.count, ratedDrawers: ratings.count)
    }
}
