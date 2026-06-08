// IdentifierTypeTests.swift
//
// Part 2 peer coverage (QK-TEST-01): source types in Job.swift that
// had no dedicated suite after the XCTest→swift-testing conversion —
// StreamID, SessionID, ToolName, and MissionContext (QUEUEKIT_SPEC §7).
// All deterministic: no filesystem, no timing, no shared state.

import Testing
import Foundation
@testable import QueueKit

@Suite("Identifier & context types (QUEUEKIT_SPEC §7)")
struct IdentifierTypeTests {

    // MARK: - StreamID

    @Test func streamIDRawRepresentable() {
        let s = StreamID(rawValue: "my-stream")
        #expect(s.rawValue == "my-stream")
        #expect(StreamID(rawValue: "my-stream") == s)
        #expect(StreamID(rawValue: "other") != s)
    }

    @Test func streamIDCodableRoundTrip() throws {
        // StreamID uses a single-value container (encodes as a bare
        // JSON string), matching the `stream_id` wire field in §6.
        let original = [StreamID(rawValue: "alpha"),
                        StreamID(rawValue: "delta-stream")]
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode([StreamID].self, from: data)
        #expect(decoded == original)
        // Confirm the single-value (bare string) encoding.
        let single = try JSONEncoder().encode(StreamID(rawValue: "x"))
        #expect(String(data: single, encoding: .utf8) == "\"x\"")
    }

    // MARK: - SessionID

    @Test func sessionIDMintIsLowercaseUUID() {
        let id = SessionID.mint()
        // UUID string form: 36 chars, 4 hyphens, lowercased.
        #expect(id.rawValue.count == 36)
        #expect(id.rawValue.filter { $0 == "-" }.count == 4)
        #expect(id.rawValue == id.rawValue.lowercased())
        #expect(!id.rawValue.contains { $0.isUppercase })
    }

    @Test func sessionIDMintIsUnique() {
        #expect(SessionID.mint() != SessionID.mint())
    }

    @Test func sessionIDRawRepresentableAndCodable() throws {
        let s = SessionID(rawValue: "session-123")
        #expect(s.rawValue == "session-123")
        let data = try JSONEncoder().encode([s])
        let decoded = try JSONDecoder().decode([SessionID].self, from: data)
        #expect(decoded == [s])
    }

    // MARK: - ToolName

    @Test func toolNameRawRepresentableAndCodable() throws {
        let t = ToolName(rawValue: "Read")
        #expect(t.rawValue == "Read")
        #expect(ToolName(rawValue: "Read") == t)
        #expect(ToolName(rawValue: "Write") != t)
        let data = try JSONEncoder().encode([t])
        let decoded = try JSONDecoder().decode([ToolName].self, from: data)
        #expect(decoded == [t])
    }

    // MARK: - MissionContext

    @Test func missionContextFullRoundTrip() throws {
        let ctx = MissionContext(
            missionPath: "docs/missions/inflight/MISSION_QK_TEST_01.md",
            worktree: "/tmp/worktrees/qk-queuekit-test-leg",
            branch: "stream/qk-queuekit-test-leg",
            autonomyProfile: "supervised",
            riskClass: "test-only",
            baseCommit: "16c0579",
            priorTrajectoryID: "traj-007",
            inheritedSkills: ["mission-scoping", "swift-testing"])
        let data = try JSONEncoder().encode(ctx)
        let decoded = try JSONDecoder().decode(
            MissionContext.self, from: data)
        #expect(decoded == ctx)
        #expect(decoded.priorTrajectoryID == "traj-007")
        #expect(decoded.inheritedSkills == ["mission-scoping", "swift-testing"])
    }

    @Test func missionContextDefaults() {
        // priorTrajectoryID and inheritedSkills have defaults.
        let ctx = MissionContext(
            missionPath: "m",
            worktree: "w",
            branch: "b",
            autonomyProfile: "a",
            riskClass: "r",
            baseCommit: "c")
        #expect(ctx.priorTrajectoryID == nil)
        #expect(ctx.inheritedSkills.isEmpty)
    }
}
