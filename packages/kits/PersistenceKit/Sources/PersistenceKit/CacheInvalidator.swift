// CacheInvalidator.swift
//
// Subscribes to `StorageObserver` change events and invalidates the
// corresponding hot-tier entries in a `CachingRowStore`. Used when an
// external writer (one that bypasses the `CachingRowStore` instance)
// mutates the backing store, ensuring the hot tier never serves stale data.
//
// One `CacheInvalidator` manages all specified table subscriptions through
// a single detached `Task` that fans out one child task per table.
// Cancellation (via `cancel()` or `deinit`) cancels the root task, which
// propagates cancellation to every child and stops all observations.

import Foundation
import OSLog

private let invalidatorLogger = Logger(
    subsystem: "com.mootx01.kit",
    category: "CacheInvalidator"
)

/// Drives external invalidation of a `CachingRowStore` from `StorageObserver`
/// events. Attach one per backing store to keep the hot tier consistent when
/// writers bypass the caching decorator.
///
/// ```swift
/// let invalidator = CacheInvalidator(
///     cache: cachingStore,
///     observer: storage.observer,
///     tables: ["things", "metadata"]
/// )
/// // …when done…
/// invalidator.cancel()
/// ```
public final class CacheInvalidator: Sendable {
    // The root task is the handle for the entire fan-out subscription tree.
    private let task: Task<Void, Never>

    /// Initialise and start background observation.
    ///
    /// Subscriptions are created at the start of the background task, before
    /// any suspension point. A write issued immediately after `init` may race
    /// with subscription registration in pathological timing; callers that
    /// require strict ordering should introduce a brief yield (e.g.
    /// `Task.sleep`) before the first write they want guaranteed to be
    /// observed.
    ///
    /// - Parameters:
    ///   - cache:    The `CachingRowStore` whose hot tier should be invalidated.
    ///   - observer: The `StorageObserver` for the same backing store.
    ///   - tables:   Tables to watch. A subscription for `.insert`, `.update`,
    ///               and `.delete` events is started for each listed table.
    public init(
        cache: CachingRowStore,
        observer: any StorageObserver,
        tables: [String]
    ) {
        // Capture all arguments as Sendable values before the Task.detached
        // crossing (Task.detached closures require @Sendable captures).
        let capturedCache = cache
        let capturedObserver = observer
        let capturedTables = tables

        self.task = Task.detached {
            await withTaskGroup(of: Void.self) { group in
                for table in capturedTables {
                    // Subscriptions are created before any await — the task
                    // does not suspend until withTaskGroup waits on the child
                    // tasks, so all subscriptions are live before any child
                    // starts processing events.
                    let stream = capturedObserver.observe(
                        table: table,
                        events: [.insert, .update, .delete]
                    )
                    group.addTask {
                        for await change in stream {
                            guard !Task.isCancelled else { break }
                            invalidatorLogger.debug(
                                "external invalidation \(change.table)/\(change.rowKey?.uuidString ?? "all")"
                            )
                            await capturedCache.invalidate(
                                table: change.table,
                                key: change.rowKey
                            )
                        }
                    }
                }
            }
        }
    }

    /// Cancel all table subscriptions. Safe to call multiple times.
    public func cancel() {
        task.cancel()
    }

    deinit {
        task.cancel()
    }
}
