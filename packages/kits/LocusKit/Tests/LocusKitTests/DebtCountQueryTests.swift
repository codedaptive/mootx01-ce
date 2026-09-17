import Foundation
import PersistenceKit
import SubstrateTypes
import Testing
@testable import LocusKit

/// F10 regression coverage. `countSpanIndexDebt()` and
/// `countSubjectDebt(includingPipelines:)` used to materialize and decode
/// every matching row (projected to `id` only) just to measure `rows.count`
/// — a duty-tick polling cost paid every five seconds regardless of how
/// large the debt was. The fix routes both through
/// `RowStore.count(table:where:)`, a single `SELECT COUNT(*)`. These tests
/// pin the observable contract the fix must not change: the count still
/// matches exactly what the materialized batch query returns, on a fixture
/// mixing settled and unsettled rows.
@Suite("Debt count queries — COUNT(*) vs. materialized-row parity (F10)")
struct DebtCountQueryTests {

    private func t(_ epoch: TimeInterval) -> Date {
        Date(timeIntervalSince1970: epoch)
    }

    private func makeTempURL() -> URL {
        let name = "locuskit-debt-count-test-\(UUID().uuidString).sqlite"
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(name)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("sqlite-wal"))
        try? FileManager.default.removeItem(at: url.appendingPathExtension("sqlite-shm"))
    }

    private func makeStore() async throws -> (DrawerStore, URL) {
        let url = makeTempURL()
        let store = try await DrawerStore(storage: TestStorage.sqlite(url))
        return (store, url)
    }

    private func drawer(id: String, content: String) -> Drawer {
        Drawer(
            id: TestStorage.tid(id),
            content: content,
            parentNodeId: "test-parent",
            addedBy: "bilby",
            filedAt: t(1_700_000_000),
            embeddingModelID: "minilm-v6"
        )
    }

    @Test("countSpanIndexDebt matches the materialized span-index-debt batch")
    func spanIndexDebtCountMatchesBatch() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }

        // Five candidate rows; two are already span-indexed (settled), so
        // debt is exactly three — a count naively over ALL rows would be
        // wrong, proving this test actually exercises the predicate.
        for i in 1...5 {
            try await store.addDrawer(drawer(id: "d\(i)", content: "span content \(i)"))
        }
        _ = try await store.setSpanIndexed(drawerId: TestStorage.tid("d1"))
        _ = try await store.setSpanIndexed(drawerId: TestStorage.tid("d2"))

        let count = try await store.countSpanIndexDebt()
        let batch = try await store.spanIndexDebtBatch(limit: 1_000)

        #expect(count == 3, "two of five drawers are already span-indexed")
        #expect(count == batch.count, "COUNT(*) must match the materialized debt batch exactly")
    }

    @Test("countSubjectDebt(includingPipelines:) matches the materialized subject-debt batch")
    func subjectDebtCountMatchesBatch() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }

        // Four candidate rows; one already carries a subject under the
        // CURRENT pipeline (settled, excluded from the NULL-only count) and
        // one carries a subject under an OLD pipeline that IS included via
        // `includingPipelines` (tier-aware debt, PR-10) — so the correct
        // count is 3 (2 NULL + 1 old-pipeline), not 4 and not 2.
        for i in 1...4 {
            try await store.addDrawer(drawer(id: "d\(i)", content: "subject content \(i)"))
        }
        _ = try await store.setSubjectRepresentation(
            drawerId: TestStorage.tid("d1"), subject: "current-pipeline subject",
            pipelineVersion: "minillm-v2", at: t(1_700_000_100),
            changedBy: "subject-rider", reason: nil)
        _ = try await store.setSubjectRepresentation(
            drawerId: TestStorage.tid("d2"), subject: "old-pipeline subject",
            pipelineVersion: "minillm-v1", at: t(1_700_000_100),
            changedBy: "subject-rider", reason: nil)

        let count = try await store.countSubjectDebt(includingPipelines: ["minillm-v1"])
        let batch = try await store.subjectDebtBatch(limit: 1_000, includingPipelines: ["minillm-v1"])

        #expect(count == 3, "d2 (old pipeline) and d3/d4 (no subject) are debt; d1 is settled")
        #expect(count == batch.count, "COUNT(*) must match the materialized debt batch exactly")
    }
}
