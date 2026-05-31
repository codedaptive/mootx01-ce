import Testing
import SubstrateTypes
import Foundation
@testable import LocusKit

/// Conformance for standalone tunnel capture — `Estate.capture(TunnelCaptureFrame)`
/// (mission VERB-CAP-01).
@Suite("CaptureTunnelTests")
struct CaptureTunnelTests {

    /// Build a fresh estate on a unique temp path. Mirrors
    /// `EstateVerbTests.makeEstate`.
    private func makeEstate() async throws -> Estate {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("locuskit-cap-tunnel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("estate.sqlite3")
        return try await Estate.create(
            storage: TestStorage.sqlite(path),
            owner: OwnerCredentials(ownerIdentifier: "test-owner")
        )
    }

    private func sampleFrame(
        label: String = "links",
        kind: TunnelKind = .references,
        sourceDrawerId: String? = nil,
        targetDrawerId: String? = nil
    ) -> TunnelCaptureFrame {
        TunnelCaptureFrame(
            sourceWing: "wing_a", sourceRoom: "room_1",
            targetWing: "wing_b", targetRoom: "room_2",
            label: label,
            addedBy: "bilby",
            sourceDrawerId: sourceDrawerId,
            targetDrawerId: targetDrawerId,
            kind: kind
        )
    }

    private func drawerFrame(_ content: String, lineage: UUID) -> CaptureFrame {
        CaptureFrame(
            content: content,
            channel: .typed,
            room: "test-room",
            latticeAnchor: LatticeAnchor(udcCode: "004"),
            addedBy: "test-agent",
            embeddingModelID: "minilm-v6",
            lineageID: lineage
        )
    }

    @Test("capture returns a well-formed tunnel and persists it")
    func captureRoundTrips() async throws {
        let estate = try await makeEstate()
        let captured = try await estate.capture(sampleFrame())
        #expect(!captured.id.isEmpty)
        #expect(captured.sourceWing == "wing_a")
        #expect(captured.sourceRoom == "room_1")
        #expect(captured.targetWing == "wing_b")
        #expect(captured.targetRoom == "room_2")
        #expect(captured.label == "links")
        #expect(captured.kind == .references)
        #expect(captured.addedBy == "bilby")
        #expect(captured.tombstonedAt == nil)
        #expect(captured.removedByBatch == nil)
        // Field-by-field rather than `loaded == captured`: `filedAt` is a
        // `Date()` whose sub-second precision is truncated by the SQLite
        // ISO8601 round-trip (drawer capture has the same property — see
        // EstateVerbTests, which also asserts fields individually). Every
        // other field must round-trip exactly.
        let loaded = try #require(try await estate._peekTunnel(id: captured.id))
        #expect(loaded.id == captured.id)
        #expect(loaded.sourceWing == captured.sourceWing)
        #expect(loaded.sourceRoom == captured.sourceRoom)
        #expect(loaded.sourceDrawerId == captured.sourceDrawerId)
        #expect(loaded.targetWing == captured.targetWing)
        #expect(loaded.targetRoom == captured.targetRoom)
        #expect(loaded.targetDrawerId == captured.targetDrawerId)
        #expect(loaded.label == captured.label)
        #expect(loaded.kind == captured.kind)
        #expect(loaded.adjectiveBitmap == captured.adjectiveBitmap)
        #expect(loaded.operationalBitmap == captured.operationalBitmap)
        #expect(loaded.provenanceBitmap == captured.provenanceBitmap)
        #expect(loaded.addedBy == captured.addedBy)
        #expect(loaded.tombstonedAt == nil)
        #expect(loaded.removedByBatch == nil)
        #expect(abs(loaded.filedAt.timeIntervalSince1970
                    - captured.filedAt.timeIntervalSince1970) < 1.0)
    }

    @Test("captured tunnel has all-zero bitmaps (matches cascade init)")
    func captureZeroBitmaps() async throws {
        let estate = try await makeEstate()
        let captured = try await estate.capture(sampleFrame())
        #expect(captured.adjectiveBitmap == 0)
        #expect(captured.operationalBitmap == 0)
        #expect(captured.provenanceBitmap == 0)
        let loaded = try #require(try await estate._peekTunnel(id: captured.id))
        #expect(loaded.adjectiveBitmap == 0)
        #expect(loaded.operationalBitmap == 0)
        #expect(loaded.provenanceBitmap == 0)
    }

    @Test("standalone capture is byte-identical to a cascade-born tunnel")
    func byteIdenticalToCascade() async throws {
        let estate = try await makeEstate()
        let lineage = UUID()
        let first = try await estate.capture(drawerFrame("v1", lineage: lineage))
        let second = try await estate.capture(drawerFrame("v2", lineage: lineage))
        let cascadeTunnel = try #require(
            try await estate._peekTunnel(id: "supersedes:\(second.id):\(first.id)"))
        let standalone = try await estate.capture(TunnelCaptureFrame(
            sourceWing: second.wing, sourceRoom: second.room,
            targetWing: first.wing, targetRoom: first.room,
            label: "supersedes", addedBy: "test-agent",
            sourceDrawerId: second.id, targetDrawerId: first.id,
            kind: .supersedes))
        #expect(standalone.sourceWing == cascadeTunnel.sourceWing)
        #expect(standalone.sourceRoom == cascadeTunnel.sourceRoom)
        #expect(standalone.sourceDrawerId == cascadeTunnel.sourceDrawerId)
        #expect(standalone.targetWing == cascadeTunnel.targetWing)
        #expect(standalone.targetRoom == cascadeTunnel.targetRoom)
        #expect(standalone.targetDrawerId == cascadeTunnel.targetDrawerId)
        #expect(standalone.label == cascadeTunnel.label)
        #expect(standalone.kind == cascadeTunnel.kind)
        #expect(standalone.adjectiveBitmap == cascadeTunnel.adjectiveBitmap)
        #expect(standalone.operationalBitmap == cascadeTunnel.operationalBitmap)
        #expect(standalone.provenanceBitmap == cascadeTunnel.provenanceBitmap)
        #expect(standalone.tombstonedAt == cascadeTunnel.tombstonedAt)
        #expect(standalone.removedByBatch == cascadeTunnel.removedByBatch)
    }

    @Test("source/target drawer endpoints resolve on round-trip")
    func endpointsResolve() async throws {
        let estate = try await makeEstate()
        let captured = try await estate.capture(sampleFrame(
            sourceDrawerId: "d-src", targetDrawerId: "d-tgt"))
        let loaded = try #require(try await estate._peekTunnel(id: captured.id))
        #expect(loaded.sourceDrawerId == "d-src")
        #expect(loaded.targetDrawerId == "d-tgt")
        #expect(loaded.sourceWing == "wing_a")
        #expect(loaded.targetWing == "wing_b")
    }

    @Test("nil drawer endpoints mean room-level edges")
    func roomLevelEndpoints() async throws {
        let estate = try await makeEstate()
        let captured = try await estate.capture(sampleFrame())
        let loaded = try #require(try await estate._peekTunnel(id: captured.id))
        #expect(loaded.sourceDrawerId == nil)
        #expect(loaded.targetDrawerId == nil)
    }

    @Test("captured tunnel is recallable from its source wing/room")
    func recallableFromSource() async throws {
        let estate = try await makeEstate()
        let captured = try await estate.capture(sampleFrame())
        let fromSource = try await estate._tunnelsFrom(wing: "wing_a", room: "room_1")
        #expect(fromSource.contains { $0.id == captured.id })
    }

    @Test("captured tunnel is recallable to its target wing")
    func recallableToTarget() async throws {
        let estate = try await makeEstate()
        let captured = try await estate.capture(sampleFrame())
        let toTarget = try await estate._tunnelsTo(wing: "wing_b")
        #expect(toTarget.contains { $0.id == captured.id })
    }

    @Test("kind defaults to .references and round-trips a non-default kind")
    func kindHandling() async throws {
        let estate = try await makeEstate()
        let def = try await estate.capture(sampleFrame())
        #expect(def.kind == .references)
        let blocks = try await estate.capture(sampleFrame(label: "x", kind: .blocks))
        let loaded = try #require(try await estate._peekTunnel(id: blocks.id))
        #expect(loaded.kind == .blocks)
    }

    @Test("empty source wing is rejected")
    func rejectsEmptySourceWing() async throws {
        let estate = try await makeEstate()
        var frame = sampleFrame(); frame.sourceWing = ""
        await #expect(throws: LocusKitError.self) { _ = try await estate.capture(frame) }
    }

    @Test("empty source room is rejected")
    func rejectsEmptySourceRoom() async throws {
        let estate = try await makeEstate()
        var frame = sampleFrame(); frame.sourceRoom = ""
        await #expect(throws: LocusKitError.self) { _ = try await estate.capture(frame) }
    }

    @Test("empty target wing is rejected")
    func rejectsEmptyTargetWing() async throws {
        let estate = try await makeEstate()
        var frame = sampleFrame(); frame.targetWing = ""
        await #expect(throws: LocusKitError.self) { _ = try await estate.capture(frame) }
    }

    @Test("empty target room is rejected")
    func rejectsEmptyTargetRoom() async throws {
        let estate = try await makeEstate()
        var frame = sampleFrame(); frame.targetRoom = ""
        await #expect(throws: LocusKitError.self) { _ = try await estate.capture(frame) }
    }

    @Test("empty label is rejected")
    func rejectsEmptyLabel() async throws {
        let estate = try await makeEstate()
        var frame = sampleFrame(); frame.label = ""
        await #expect(throws: LocusKitError.self) { _ = try await estate.capture(frame) }
    }

    @Test("empty addedBy is rejected")
    func rejectsEmptyAddedBy() async throws {
        let estate = try await makeEstate()
        var frame = sampleFrame(); frame.addedBy = ""
        await #expect(throws: LocusKitError.self) { _ = try await estate.capture(frame) }
    }
}
