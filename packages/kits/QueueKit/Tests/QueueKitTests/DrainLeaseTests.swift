// DrainLeaseTests.swift — QueueKit DrainLease (ADR-021 T2)
//
// Verifies the stream-keyed heartbeat-TTL lease semantics:
//  - acquire on a free lease succeeds
//  - a second owner cannot acquire while the first holds a fresh lease
//  - isHeldByOther correctly reflects the same condition
//  - after TTL elapses with no heartbeat the lease is re-acquirable
//  - heartbeat keeps the lease held across what would otherwise be expiry
//  - two different stream keys produce independent leases (both acquirable)
//  - release frees the lease immediately

import Testing
import Foundation
@testable import QueueKit

@Suite("DrainLease — ADR-021 T2")
struct DrainLeaseTests {

    // MARK: - Helpers

    /// A temporary directory for one test, cleaned up on scope exit.
    private func withTempDir(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DrainLeaseTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

    // MARK: - Acquire on free lease succeeds

    @Test("acquire on a free lease succeeds")
    func acquireOnFreeLease() throws {
        try withTempDir { dir in
            let lease = DrainLease(directory: dir, stream: "encode", instanceToken: "A")
            let now = Date()
            #expect(lease.tryAcquire(now: now) == true)
        }
    }

    // MARK: - Second owner cannot acquire while first holds a fresh lease

    @Test("second owner cannot acquire while first holds a fresh lease")
    func secondOwnerBlockedWhileLeaseHeld() throws {
        try withTempDir { dir in
            let owner1 = DrainLease(directory: dir, stream: "encode", instanceToken: "owner1")
            let owner2 = DrainLease(directory: dir, stream: "encode", instanceToken: "owner2")
            let now = Date()

            // Owner 1 acquires.
            #expect(owner1.tryAcquire(now: now) == true)

            // Owner 2 cannot acquire while owner 1's lease is fresh.
            #expect(owner2.tryAcquire(now: now) == false)
        }
    }

    // MARK: - isHeldByOther

    @Test("isHeldByOther is true while another fresh lease is held")
    func isHeldByOtherTrue() throws {
        try withTempDir { dir in
            let owner1 = DrainLease(directory: dir, stream: "encode", instanceToken: "owner1")
            let owner2 = DrainLease(directory: dir, stream: "encode", instanceToken: "owner2")
            let now = Date()

            #expect(owner1.tryAcquire(now: now) == true)
            #expect(owner2.isHeldByOther(now: now) == true)
        }
    }

    @Test("isHeldByOther is false when no lease file exists")
    func isHeldByOtherFalseWhenAbsent() throws {
        try withTempDir { dir in
            let lease = DrainLease(directory: dir, stream: "encode", instanceToken: "A")
            #expect(lease.isHeldByOther(now: Date()) == false)
        }
    }

    // MARK: - Expired lease is re-acquirable

    @Test("after TTL elapses with no heartbeat the lease is re-acquirable")
    func expiredLeaseIsReacquirable() throws {
        try withTempDir { dir in
            // Use a very short TTL (0.1 s) to avoid real-time waiting.
            let owner1 = DrainLease(directory: dir, stream: "encode", instanceToken: "owner1", ttl: 0.1)
            let owner2 = DrainLease(directory: dir, stream: "encode", instanceToken: "owner2", ttl: 0.1)

            let t0 = Date()
            #expect(owner1.tryAcquire(now: t0) == true)

            // Advance time by more than the TTL — the lease is stale.
            let expired = t0.addingTimeInterval(1.0)
            #expect(owner2.tryAcquire(now: expired) == true)
            // Owner 1 is no longer the holder.
            #expect(owner1.isHeldByOther(now: expired) == true)
        }
    }

    // MARK: - Heartbeat keeps the lease held

    @Test("heartbeat keeps the lease held across what would otherwise be expiry")
    func heartbeatKeepsLeaseHeld() throws {
        try withTempDir { dir in
            let ttl: TimeInterval = 0.5
            let owner1 = DrainLease(directory: dir, stream: "encode", instanceToken: "owner1", ttl: ttl)
            let owner2 = DrainLease(directory: dir, stream: "encode", instanceToken: "owner2", ttl: ttl)

            let t0 = Date()
            #expect(owner1.tryAcquire(now: t0) == true)

            // Heartbeat at t0 + 0.3 s (within TTL from t0, but past half).
            let t1 = t0.addingTimeInterval(0.3)
            owner1.heartbeat(now: t1)

            // At t0 + 0.7 s the original heartbeat (t0) would have expired,
            // but the refreshed heartbeat (t1 = t0+0.3) is still within TTL.
            let t2 = t0.addingTimeInterval(0.7) // t2 - t1 = 0.4 s < 0.5 s TTL
            #expect(owner2.tryAcquire(now: t2) == false)
            #expect(owner2.isHeldByOther(now: t2) == true)
        }
    }

    // MARK: - Two stream keys produce independent leases

    @Test("two different stream keys yield independent leases — both acquirable simultaneously")
    func independentStreams() throws {
        try withTempDir { dir in
            let encode = DrainLease(directory: dir, stream: "encode", instanceToken: "owner1")
            let dream  = DrainLease(directory: dir, stream: "dreaming", instanceToken: "owner2")
            let now = Date()

            // Both streams can be acquired at the same time by different owners.
            #expect(encode.tryAcquire(now: now) == true)
            #expect(dream.tryAcquire(now: now) == true)

            // Each stream's holder does not see the other's lease as "held by other".
            // (encode is held by owner1; from owner1's view, encode is NOT held by other)
            #expect(encode.isHeldByOther(now: now) == false)
            // (dreaming is held by owner2; from owner2's view, dreaming is NOT held by other)
            #expect(dream.isHeldByOther(now: now) == false)

            // A third party on the encode stream sees it held.
            let encodeObserver = DrainLease(directory: dir, stream: "encode", instanceToken: "observer")
            #expect(encodeObserver.isHeldByOther(now: now) == true)
            #expect(encodeObserver.tryAcquire(now: now) == false)
        }
    }

    // MARK: - Release frees the lease immediately

    @Test("release frees the lease immediately")
    func releaseFreesLease() throws {
        try withTempDir { dir in
            let owner1 = DrainLease(directory: dir, stream: "encode", instanceToken: "owner1")
            let owner2 = DrainLease(directory: dir, stream: "encode", instanceToken: "owner2")
            let now = Date()

            #expect(owner1.tryAcquire(now: now) == true)
            owner1.release()

            // After release, owner2 can acquire immediately.
            #expect(owner2.tryAcquire(now: now) == true)
        }
    }

    // MARK: - Release is a no-op when not the holder

    @Test("release by non-holder does not remove the lease file")
    func releaseByNonHolderIsNoop() throws {
        try withTempDir { dir in
            let owner1 = DrainLease(directory: dir, stream: "encode", instanceToken: "owner1")
            let interloper = DrainLease(directory: dir, stream: "encode", instanceToken: "interloper")
            let now = Date()

            #expect(owner1.tryAcquire(now: now) == true)
            interloper.release()  // Should be a no-op — interloper doesn't hold it.

            // Owner1 still holds it.
            #expect(interloper.isHeldByOther(now: now) == true)
        }
    }

    // MARK: - TTL / heartbeat constant

    @Test("heartbeatInterval constant is less than default TTL")
    func heartbeatIntervalIsWithinTTL() {
        // Structural assertion: the published heartbeat cadence must be < TTL
        // so a continuous heartbeating drainer never lets its lease expire.
        let lease = DrainLease(directory: URL(fileURLWithPath: "/tmp"), stream: "encode", instanceToken: "X")
        #expect(DrainLease.heartbeatInterval < lease.ttl)
    }
}
