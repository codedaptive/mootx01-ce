// NoOpObserverTests.swift
//
// Part 2 coverage gap: NoOpObserver is a shipped source type with no peer suite.
// It is the default StorageObserver for backends that don't implement change
// notification, so its contract — observe() hands back a stream that is already
// finished and yields nothing — is worth pinning so a future "real" observer
// can't silently replace it with one that hangs.

import Testing
import PersistenceKit

struct NoOpObserverTests {

    @Test func observeReturnsAnImmediatelyFinishedEmptyStream() async {
        let observer = NoOpObserver()
        let stream = observer.observe(table: "anything", events: [.insert, .update, .delete])

        var collected: [TableChange] = []
        for await change in stream {
            collected.append(change)
        }
        #expect(collected.isEmpty)
    }

    @Test func observeIsEmptyRegardlessOfEventSet() async {
        let observer = NoOpObserver()
        let stream = observer.observe(table: "t", events: [.insert])

        var count = 0
        for await _ in stream { count += 1 }
        #expect(count == 0)
    }
}
