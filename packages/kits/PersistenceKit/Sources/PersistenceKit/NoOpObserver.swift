// NoOpObserver.swift
//
// A trivial StorageObserver that returns empty streams. Backends
// can use this as a default until they implement real change
// notification. Useful for the InMemory test path that doesn't
// care about observation.

import Foundation

public final class NoOpObserver: StorageObserver, Sendable {
    public init() {}

    public func observe(table: String, events: Set<StorageEvent>) -> AsyncStream<TableChange> {
        AsyncStream<TableChange> { continuation in
            continuation.finish()
        }
    }

    public func observeBlobs() -> AsyncStream<BlobChange> {
        AsyncStream<BlobChange> { continuation in
            continuation.finish()
        }
    }
}
