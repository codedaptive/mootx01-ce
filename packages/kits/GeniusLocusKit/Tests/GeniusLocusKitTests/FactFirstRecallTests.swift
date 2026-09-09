import FactExtractionKit
import Foundation
@testable import GeniusLocusKit
import LocusKit
import Testing

@Suite("Fact-first recall gate")
struct FactFirstRecallTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("solid fact carries its source as one family")
    func solidFamily() {
        let jack = fact(
            id: "jack-birthday", subject: "Jack", object: "June 20th",
            source: "source-jack", projection: "Jack birthday June 20th when is Jack birthday")
        let jill = fact(
            id: "jill-birthday", subject: "Jill", object: "May 4th",
            source: "source-jill", projection: "Jill birthday May 18th")
        let sources = [
            "source-jack": drawer(id: "source-jack", content: "Jack's birthday is June 20th."),
            "source-jill": drawer(id: "source-jill", content: "Jill's birthday is May 18th."),
        ]
        let decision = FactFirstRecallStage.decide(
            query: "when is jacks birthday", queryEntities: ["Jack"],
            facts: [jill, jack], sourceDrawers: sources)
        guard case let .solid(family) = decision else {
            Issue.record("expected a solid fact-first result")
            return
        }
        #expect(family.fact.id == "jack-birthday")
        #expect(family.source.id == "source-jack")
        #expect(family.margin >= 0.20)
        #expect(family.entityContainment == 1)
    }

    @Test("missing entity evidence and a tied head both fall through")
    func conservativeGates() {
        let first = fact(
            id: "a", subject: "Jack", object: "June 20th", source: "source-jack",
            projection: "Jack birthday June 20th")
        let second = fact(
            id: "b", subject: "Jack", object: "June 21st", source: "source-jack",
            projection: "Jack birthday June 21st")
        let sources = ["source-jack": drawer(id: "source-jack", content: "source")]
        #expect(FactFirstRecallStage.decide(
            query: "when is jacks birthday", queryEntities: [],
            facts: [first], sourceDrawers: sources) == .fallThrough)
        #expect(FactFirstRecallStage.decide(
            query: "when is jacks birthday", queryEntities: ["Jack"],
            facts: [first, second], sourceDrawers: sources) == .fallThrough)

        let staleSources = [
            "source-jack": drawer(id: "source-jack", content: "edited", settled: false),
        ]
        #expect(FactFirstRecallStage.decide(
            query: "when is jacks birthday", queryEntities: ["Jack"],
            facts: [first], sourceDrawers: staleSources) == .fallThrough)

        let weak = fact(
            id: "weak", subject: "Jack", object: "Seattle", source: "source-jack",
            projection: "Jack Seattle")
        #expect(FactFirstRecallStage.decide(
            query: "when is jacks birthday", queryEntities: ["Jack"],
            facts: [weak], sourceDrawers: sources,
            vectorScores: ["weak": 1]) == .fallThrough)
    }

    private func fact(
        id: String, subject: String, object: String, source: String, projection: String
    ) -> KGFact {
        KGFact(
            id: id, subject: subject, predicate: "birthday", object: object,
            sourceDrawerID: source, searchProjection: projection,
            searchProjectionVersion: FactSearchProjection.version, filedAt: now)
    }

    private func drawer(id: String, content: String, settled: Bool = true) -> Drawer {
        Drawer(
            id: id, content: content, parentNodeId: "room", addedBy: "test",
            filedAt: now, embeddingModelID: "test",
            operationalBitmap: settled ? DrawerFeatureFlags.factsExtracted.rawValue : 0)
    }
}
