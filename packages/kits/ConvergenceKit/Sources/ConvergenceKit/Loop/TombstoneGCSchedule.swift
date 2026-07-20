// TombstoneGCSchedule.swift
//
// Cadence constant for the periodic tombstone compaction sweep. Shared by
// both sync backends:
//   - CloudKit: wired into AdaptivePollScheduler via the `gcFn` injection
//               point (ConvergenceKitCloudKit).
//   - Federation: called directly from FederationStateActor.pull()
//                 (ConvergenceKitFederation).
//
// Defining the constant in ConvergenceKit (the shared module) makes it
// visible to both product modules without duplication and ensures both
// backends enforce the same daily compaction window.

import Foundation

// MARK: - TombstoneGCSchedule

/// Scheduling constants for the periodic tombstone GC sweep.
public enum TombstoneGCSchedule {

    /// How often (ms) the convergence loop runs tombstone GC.
    /// 24 hours = 86 400 000 ms.
    ///
    /// WHY 24 h: GC pressure is tiny — tombstones accumulate at the delete
    /// rate, not the overall write rate. The retention window is 90d-scale
    /// (SyncTombstone.gcRetentionSeconds = 90 d). A daily sweep is far more
    /// frequent than needed to keep tombstone count bounded; choosing a longer
    /// interval would not meaningfully reduce I/O because the retention window
    /// is 1 200× the GC interval, and every qualifying sweep is cheap (a
    /// query over the `is_deleted = 1` subset of `_ck_sync_meta`).
    public static let gcIntervalMs: Int64 = 86_400_000  // 24 h
}
