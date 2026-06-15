import Testing
import Foundation
@testable import LocusKit

/// Locus lane latency bench — post-FIX-A-FIX-B measurement.
///
/// Measures recall latency on a 1,040-drawer SQLite estate (the MemPalace
/// reference size, 42ms target). Three scenarios:
///   1. `.structured` recall with no content predicate (Fix A: no blob re-fetch)
///   2. `.full` recall (still loads blobs — establishes the blob-load cost)
///   3. `.structured` recall with explicit limit = 20 (Fix B: trace bound = 20)
///
/// Uses the public `estate.recall(_:)` → drain-all path so the bench covers
/// the complete hot path including RecallStream pagination and trace writes.
/// Single-shot timings; upper bound is generous (500ms) for CI headroom.
/// The printed values are the meaningful signal for MemPalace comparison.
@Suite("Recall lane latency bench — 1,040-drawer estate")
struct RecallLatencyBenchTests {

    private static let drawerCount = 1040

    /// Build a 1,040-drawer SQLite estate in a temp directory.
    private func makeLargeEstate() async throws -> Estate {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("locuskit-latency-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("estate.sqlite3")
        let estate = try await Estate.create(
            storage: TestStorage.sqlite(path),
            owner: OwnerCredentials(ownerIdentifier: "bench-owner")
        )
        for i in 0..<Self.drawerCount {
            let frame = CaptureFrame(
                content: "bench-content-\(i)",
                channel: .typed,
                room: "bench-room",
                latticeAnchor: LatticeAnchor(udcCode: "000"),
                addedBy: "bench-agent",
                embeddingModelID: "minilm-v6"
            )
            _ = try await estate.capture(frame)
        }
        return estate
    }

    /// Drain a RecallStream into a flat array.
    private func drain(_ stream: RecallStream) async -> [Drawer] {
        var rows: [Drawer] = []
        for await page in stream { rows.append(contentsOf: page.rows) }
        return rows
    }

    @Test(".structured recall — no blob re-fetch (Fix A) — 1,040 drawers")
    func structuredRecallLatency() async throws {
        let estate = try await makeLargeEstate()
        let frame = RecallFrame(
            filterChain: [.userConfirmed],
            hydrationLevel: .structured,
            ordering: .byCaptureTimeDesc
        )

        let clock = ContinuousClock()
        let start = clock.now
        let stream = await estate.recall(frame)
        let rows = await drain(stream)
        let elapsed = clock.now - start
        let ms = Double(elapsed.components.seconds) * 1000.0
            + Double(elapsed.components.attoseconds) / 1e15

        print("[RecallLatencyBench] structured 1040-drawer: \(String(format: "%.1f", ms))ms, rows=\(rows.count)")

        // Result bounded by cap.
        #expect(rows.count <= Estate.recallCandidateCap,
            "structured recall must not exceed candidate cap")
        // Content must be empty — Fix A: no blob re-fetch for .structured.
        #expect(rows.allSatisfy { $0.content == "" },
            "Fix A: structured recall must return content-stripped rows (no blob re-fetch)")
        // Must complete well under 500ms even on slow CI machines.
        #expect(ms < 500.0,
            "structured recall on 1040 drawers must complete in < 500ms (got \(String(format: "%.1f", ms))ms)")
    }

    @Test(".full recall — with blob load — 1,040 drawers (baseline comparison)")
    func fullRecallLatency() async throws {
        let estate = try await makeLargeEstate()
        let frame = RecallFrame(
            filterChain: [.userConfirmed],
            hydrationLevel: .full,
            ordering: .byCaptureTimeDesc
        )

        let clock = ContinuousClock()
        let start = clock.now
        let stream = await estate.recall(frame)
        let rows = await drain(stream)
        let elapsed = clock.now - start
        let ms = Double(elapsed.components.seconds) * 1000.0
            + Double(elapsed.components.attoseconds) / 1e15

        print("[RecallLatencyBench] full     1040-drawer: \(String(format: "%.1f", ms))ms, rows=\(rows.count)")

        #expect(rows.count <= Estate.recallCandidateCap)
        // Full hydration must load content.
        #expect(rows.allSatisfy { !$0.content.isEmpty },
            "full recall must return rows with content bodies")
        #expect(ms < 500.0,
            "full recall on 1040 drawers must complete in < 500ms (got \(String(format: "%.1f", ms))ms)")
    }

    @Test(".structured recall limit=20 — trace bounded to 20 (Fix B) — 1,040 drawers")
    func structuredRecallLimitedLatency() async throws {
        let estate = try await makeLargeEstate()
        let frame = RecallFrame(
            filterChain: [.userConfirmed],
            hydrationLevel: .structured,
            limit: 20,
            ordering: .byCaptureTimeDesc
        )

        let clock = ContinuousClock()
        let start = clock.now
        let stream = await estate.recall(frame)
        let rows = await drain(stream)
        let elapsed = clock.now - start
        let ms = Double(elapsed.components.seconds) * 1000.0
            + Double(elapsed.components.attoseconds) / 1e15

        print("[RecallLatencyBench] structured limit=20 1040-drawer: \(String(format: "%.1f", ms))ms, rows=\(rows.count)")

        // RecallStream pagination: limit=20 means pageSize=20; total rows ≤ cap.
        #expect(rows.count <= Estate.recallCandidateCap)
        #expect(ms < 500.0)
    }
}
