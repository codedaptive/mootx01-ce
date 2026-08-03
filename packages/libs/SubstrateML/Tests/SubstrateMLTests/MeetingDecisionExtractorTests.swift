import Testing
@testable import SubstrateML

/// DCP M6 golden corpus — Swift leg. Mirrors
/// `meeting_decision_extractor.rs` tests one-for-one; the accepted
/// canonical values and reject reasons are the cross-port fixture.
/// Ledger cases F11 (pronoun entity) and F12 (quoted/hypothetical)
/// live here per DCP_M0_CONTRACT §10.
@Suite struct MeetingDecisionExtractorTests {

    static let registry = ConflictRuleRegistry.v01

    /// Form 1 — `Decision: <entity>.<dimension> = <value>`; the bare
    /// dimension reaches the `decision:` namespace.
    @Test func form1DecisionAssignment() {
        let out = MeetingDecisionExtractor.extract(
            transcript: "Decision: project-phoenix.launch_date = 2026-09-15",
            registry: Self.registry)
        #expect(out.rejected.isEmpty)
        let d = try! #require(out.decisions.first)
        #expect(d.entity == "project-phoenix")
        #expect(d.dimension == "decision:launch_date")
        #expect(d.ruleID == "dim.decision.launch_date")
        #expect(d.rawValue == "2026-09-15")
        #expect(d.normalizedValue.canonicalBytes == "dt:2026-09-15")
        #expect(d.replacesID == nil)
        #expect(d.line == 1)
    }

    /// Form 2 — `Approved <dimension> for <entity>: <value>`.
    @Test func form2ApprovedFor() {
        let out = MeetingDecisionExtractor.extract(
            transcript: "Approved employer for Sarah Chen C0: Acme Robotics",
            registry: Self.registry)
        let d = try! #require(out.decisions.first)
        #expect(d.entity == "Sarah Chen C0")
        #expect(d.ruleID == "dim.person.employer")
        #expect(d.normalizedValue.canonicalBytes
            == "e:dim.person.employer#acme robotics")
    }

    /// Form 3 — `Replaces decision <id>: <entity>.<dimension> = <value>`.
    @Test func form3ReplacesDecision() {
        let out = MeetingDecisionExtractor.extract(
            transcript: "Replaces decision abc-123: project-phoenix.budget_ceiling = 1.5m USD",
            registry: Self.registry)
        let d = try! #require(out.decisions.first)
        #expect(d.replacesID == "abc-123")
        #expect(d.ruleID == "dim.decision.budget_ceiling")
        #expect(d.normalizedValue.canonicalBytes == "d:1500000")
    }

    /// F11 — pronoun entity → Unknown (pronoun_entity).
    @Test func f11PronounEntityRejected() {
        let out = MeetingDecisionExtractor.extract(
            transcript: "Decision: they.launch_date = 2026-09-15",
            registry: Self.registry)
        #expect(out.decisions.isEmpty)
        #expect(out.rejected == [RejectedDecisionLine(line: 1, reason: .pronounEntity)])
    }

    /// F12 — quoted span → Unknown (quoted_span).
    @Test func f12QuotedSpanRejected() {
        let out = MeetingDecisionExtractor.extract(
            transcript: "Approved employer for Sarah Chen C0: \"Acme Robotics\"",
            registry: Self.registry)
        #expect(out.rejected == [RejectedDecisionLine(line: 1, reason: .quotedSpan)])
    }

    /// F12 — hypothetical marker anywhere on the line → Unknown.
    @Test func f12HypotheticalRejected() {
        let out = MeetingDecisionExtractor.extract(
            transcript: "Decision: project-phoenix.launch_date = 2026-09-15 if the vendor confirms",
            registry: Self.registry)
        #expect(out.rejected == [RejectedDecisionLine(line: 1, reason: .hypotheticalMarker)])
        let reported = MeetingDecisionExtractor.extract(
            transcript: "Decision: project-phoenix.launch_date = 2026-09-15 according to Sam",
            registry: Self.registry)
        #expect(reported.rejected.first?.reason == .hypotheticalMarker)
    }

    /// Unregistered dimension → Unknown (never a guess).
    @Test func unregisteredDimensionRejected() {
        let out = MeetingDecisionExtractor.extract(
            transcript: "Decision: project-phoenix.headcount = 12",
            registry: Self.registry)
        #expect(out.rejected == [RejectedDecisionLine(line: 1, reason: .unregisteredDimension)])
    }

    /// Ambiguous date form → Unknown (parse_ambiguous, F10 shape).
    @Test func ambiguousDateRejected() {
        let out = MeetingDecisionExtractor.extract(
            transcript: "Decision: project-phoenix.launch_date = 03/04/26",
            registry: Self.registry)
        #expect(out.rejected == [RejectedDecisionLine(line: 1, reason: .parseAmbiguous)])
    }

    /// Multiple `=` on one line → Unknown.
    @Test func multipleEqualsRejected() {
        let out = MeetingDecisionExtractor.extract(
            transcript: "Decision: project-phoenix.launch_date = 2026-09-15 = 2026-10-01",
            registry: Self.registry)
        #expect(out.rejected == [RejectedDecisionLine(line: 1, reason: .multipleEquals)])
    }

    /// Prose lines are ignored entirely — only form-prefixed lines are
    /// parsed or rejected; line numbers stay 1-based transcript positions.
    @Test func proseLinesAreIgnored() {
        let transcript = """
        Attendees: Sarah, Noor, and the platform team.
        We talked about the launch at length.
        Decision: project-phoenix.launch_date = 2026-09-15
        Sarah said she prefers October but did not object.
        Decision: they.launch_date = 2026-10-01
        """
        let out = MeetingDecisionExtractor.extract(
            transcript: transcript, registry: Self.registry)
        #expect(out.decisions.count == 1)
        #expect(out.decisions.first?.line == 3)
        #expect(out.rejected == [RejectedDecisionLine(line: 5, reason: .pronounEntity)])
    }
}
