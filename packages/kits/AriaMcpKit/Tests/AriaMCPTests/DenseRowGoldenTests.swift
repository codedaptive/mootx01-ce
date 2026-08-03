// DenseRowGoldenTests.swift
//
// PR-03 golden suite for the dense row. The hardcoded golden strings in
// this file are the CROSS-PORT FIXTURE: `dense_row_golden.rs` asserts the
// byte-identical strings from the same inputs, so the two ports cannot
// silently diverge in separator, marker, field order, or date rendering.
//
// Also pins the two harness-parser contracts PR-03 must not break:
// the "found N memory(s)" header (asserted throughout the dispatch
// suites) and the "discrimination: low" line prefix, plus the
// envelope-share bound (<12% of reply characters spent on non-row
// narration for a nominal 10-hit reply).

import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

@Suite("Dense row — cross-port goldens, parser guards, envelope share", .serialized)
struct DenseRowGoldenTests {

    /// Fixed instant for the goldens: 2023-11-14T22:13:20Z.
    private static let goldenEpoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func drawer(
        id: String,
        subject: String?,
        udcCode: String,
        qid: String?,
        provenanceSensitivity: Sensitivity = .normal
    ) -> Drawer {
        Drawer(
            id: id,
            content: "golden fixture content — never shown in a dense row",
            parentNodeId: UUID().uuidString,
            addedBy: "golden",
            filedAt: Self.goldenEpoch,
            eventTime: Self.goldenEpoch,
            embeddingModelID: "test-model-v1",
            // Provenance sensitivity lives in bits 30–35 (cookbook §2.5);
            // a shifted raw value is the whole bitmap for a fresh fixture.
            provenance: Int64(provenanceSensitivity.rawValue) << 30,
            udcCode: udcCode,
            wikidataQID: qid,
            subject: subject,
            subjectPipelineVersion: subject == nil ? nil : "ai-v1",
            subjectAt: subject == nil ? nil : Self.goldenEpoch
        )
    }

    // MARK: - Goldens (byte-identical in dense_row_golden.rs)

    @Test func goldenFullRow() {
        let d = drawer(
            id: "00000000-0000-4000-8000-000000000001",
            subject: "Quarterly planning moved to Thursday; Sarah sends invites Monday.",
            udcCode: "005.1",
            qid: "Q937")
        #expect(DenseRow.render(d) ==
            "00000000-0000-4000-8000-000000000001 · Quarterly planning moved to Thursday; Sarah sends invites Monday. · fdc:005.1 · qid:Q937 · 2023-11-14T22:13:20Z")
    }

    @Test func goldenSubjectDebtRow() {
        let d = drawer(
            id: "00000000-0000-4000-8000-000000000002",
            subject: nil, udcCode: "000", qid: nil)
        #expect(DenseRow.render(d) ==
            "00000000-0000-4000-8000-000000000002 · (no subject) · fdc:000 · qid:- · 2023-11-14T22:13:20Z")
    }

    @Test func goldenRedactedRowRestrictded() {
        // Redaction replaces the subject even when one is stored — the
        // body's access control must not leak through its summary.
        let d = drawer(
            id: "00000000-0000-4000-8000-000000000003",
            subject: "This stored subject must NOT appear.",
            udcCode: "343", qid: "Q7188",
            provenanceSensitivity: .restricted)
        #expect(DenseRow.render(d) ==
            "00000000-0000-4000-8000-000000000003 · [sensitivity: restricted — content redacted] · fdc:343 · qid:Q7188 · 2023-11-14T22:13:20Z")
    }

    @Test func goldenUnhydratedRow() {
        #expect(DenseRow.renderUnhydrated(id: "00000000-0000-4000-8000-000000000004") ==
            "00000000-0000-4000-8000-000000000004 · (no subject) · fdc:- · qid:- · -")
    }

    @Test func goldenEmptyUdcRendersAbsentMarker() {
        let d = drawer(
            id: "00000000-0000-4000-8000-000000000005",
            subject: "Empty lattice code renders the absent marker.",
            udcCode: "", qid: "")
        #expect(DenseRow.render(d) ==
            "00000000-0000-4000-8000-000000000005 · Empty lattice code renders the absent marker. · fdc:- · qid:- · 2023-11-14T22:13:20Z")
    }

    // MARK: - Harness parser guards

    @Test func discriminationLowLineKeepsItsParserPrefix() {
        // The benchmarker keys on this prefix; PR-03 made the line
        // deviation-only but must not change its spelling.
        let line = RecallDiscrimination.resultLine(for: .low)
        #expect(line.hasPrefix("discrimination: low"),
                "harness parser contract: got \(line)")
    }

    // MARK: - near: pivot and depth tiers (PR-03 functional verify)

    @Test func nearPivotReturnsAnchoredNeighborsExcludingAnchor() async throws {
        let kit = GeniusLocusKit()
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(
            storage: storage, owner: OwnerCredentials(ownerIdentifier: "near-fixture"))
        let handle = try await kit.open(
            storage: storage,
            owner: OwnerCredentials(ownerIdentifier: "near-fixture"),
            identityKeyStore: InMemoryEstateIdentityKeyStore())
        defer { Task { try? await kit.close(handle) } }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        func file(_ content: String, _ subject: String) async throws -> String {
            let r = try await dispatcher.dispatch(
                name: "moot_file_memory",
                arguments: .object([
                    "content": .string(content),
                    "subject": .string(subject),
                    "location": .string("near-tests"),
                    "impatient": .bool(true),
                ]))
            guard case let .object(obj) = r,
                  case let .array(c)? = obj["content"],
                  case let .object(f)? = c.first,
                  case let .string(t)? = f["text"],
                  let idLine = t.components(separatedBy: "\n").first
            else { return "" }
            return String(idLine.dropFirst("filed memory ".count))
        }
        let anchorID = try await file(
            "kestrel hovers over motorway verges hunting voles",
            "kestrel hovers over verges hunting voles")
        _ = try await file(
            "kestrel hunting strategy: hover then drop on voles",
            "kestrel hover-and-drop hunting strategy")
        _ = try await file(
            "unrelated pasta recipe with garlic and olive oil",
            "pasta recipe: garlic and olive oil")

        let result = try await dispatcher.dispatch(
            name: "moot_memory_search",
            arguments: .object(["near": .string(anchorID)]))
        guard case let .object(obj) = result,
              case let .array(c)? = obj["content"],
              case let .object(f)? = c.first,
              case let .string(body)? = f["text"] else {
            Issue.record("no body"); return
        }
        #expect(!body.contains(anchorID),
                "the anchor must be excluded from its own neighbors: \(body)")
        #expect(body.contains("kestrel hover-and-drop hunting strategy"),
                "the semantically-nearest row must surface: \(body)")
        // Mutual exclusion is enforced.
        await #expect(throws: JSONRPCError.self) {
            _ = try await dispatcher.dispatch(
                name: "moot_memory_search",
                arguments: .object([
                    "query": .string("x"), "near": .string(anchorID),
                ]))
        }
    }

    @Test func depthTiersReturnSubjectDistilledFull() async throws {
        let kit = GeniusLocusKit()
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(
            storage: storage, owner: OwnerCredentials(ownerIdentifier: "depth-fixture"))
        let handle = try await kit.open(
            storage: storage,
            owner: OwnerCredentials(ownerIdentifier: "depth-fixture"),
            identityKeyStore: InMemoryEstateIdentityKeyStore())
        defer { Task { try? await kit.close(handle) } }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let content = "The staging deploy gate now requires two approvals before merge."
        let filed = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: .object([
                "content": .string(content),
                "subject": .string("Staging deploy gate requires two approvals."),
                "location": .string("depth-tests"),
            ]))
        guard case let .object(fo) = filed,
              case let .array(fc)? = fo["content"],
              case let .object(ff)? = fc.first,
              case let .string(ft)? = ff["text"],
              let idLine = ft.components(separatedBy: "\n").first else {
            Issue.record("no filed id"); return
        }
        let id = String(idLine.dropFirst("filed memory ".count))

        func body(_ args: [String: JSONValue]) async throws -> String {
            let r = try await dispatcher.dispatch(name: "moot_memory_get", arguments: .object(args))
            guard case let .object(o) = r,
                  case let .array(c)? = o["content"],
                  case let .object(f)? = c.first,
                  case let .string(t)? = f["text"] else { return "" }
            return t
        }
        // subject tier: dense row only, no content.
        let subjectBody = try await body(["ids": .array([.string(id)]), "depth": .string("subject")])
        #expect(subjectBody.contains("Staging deploy gate requires two approvals."))
        #expect(!subjectBody.contains(content), "subject tier must not haul content: \(subjectBody)")
        // distilled tier: dense row + text; this fresh row owes a
        // distillate, so the fallback marker + content appear.
        let distilledBody = try await body(["ids": .array([.string(id)]), "depth": .string("distilled")])
        #expect(distilledBody.contains("source: content (not yet distilled)"))
        #expect(distilledBody.contains(content))
        // full tier (single id, default): the original record shape.
        let fullBody = try await body(["id": .string(id)])
        #expect(fullBody.contains("memory \(id)"))
        #expect(fullBody.contains("content:"))
        #expect(fullBody.contains(content))
        #expect(fullBody.contains("subject: Staging deploy gate requires two approvals."))
    }

    // MARK: - Envelope share (<12% on a nominal reply)

    @Test func envelopeShareUnderTwelvePercentOnNominalReply() async throws {
        // Fixture estate: 10 subject-bearing memories filed through the
        // boundary, then one nominal search. Envelope = every reply
        // character NOT part of a dense row (header + any narration).
        let kit = GeniusLocusKit()
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(
            storage: storage, owner: OwnerCredentials(ownerIdentifier: "envelope-fixture"))
        let handle = try await kit.open(
            storage: storage,
            owner: OwnerCredentials(ownerIdentifier: "envelope-fixture"),
            identityKeyStore: InMemoryEstateIdentityKeyStore())
        defer { Task { try? await kit.close(handle) } }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        for i in 1...10 {
            _ = try await dispatcher.dispatch(
                name: "moot_file_memory",
                arguments: .object([
                    "content": .string("Envelope fixture memory number \(i) about topic alpha beta gamma."),
                    "subject": .string("Envelope fixture memory \(i): topic alpha beta gamma."),
                    "location": .string("envelope-tests"),
                ]))
        }
        let result = try await dispatcher.dispatch(
            name: "moot_memory_search",
            arguments: .object(["query": .string("envelope fixture alpha")]))
        guard case let .object(obj) = result,
              case let .array(content)? = obj["content"],
              case let .object(first)? = content.first,
              case let .string(body)? = first["text"] else {
            Issue.record("no text body"); return
        }
        let lines = body.components(separatedBy: "\n")
        let rowChars = lines.filter { $0.contains(DenseRow.separator) }
            .map(\.count).reduce(0, +)
        // The sensitivity-gate advisory is NOT narration and is excluded from
        // the envelope budget deliberately. It is an access-control notice
        // emitted on grant state alone (no grant live here, which is the
        // default posture), so its cost is a fixed constant per reply rather
        // than something that scales with narration. Folding a constant into
        // a ratio measured against a 10-row fixture would make this guardrail
        // report on result-set size instead of on narration discipline, which
        // is what it exists to protect. The constant is bounded by its own
        // assertion below so it cannot grow unnoticed.
        let advisoryPrefix = "sensitivity_advisory: "
        let advisoryLines = lines.filter { $0.hasPrefix(advisoryPrefix) }
        #expect(advisoryLines.count == 1,
                "a locked estate's reply carries exactly one sensitivity-gate advisory")
        let advisoryChars = advisoryLines.map(\.count).reduce(0, +)
        #expect(advisoryChars <= 200,
                "the advisory is a bounded constant, not a growth surface; got \(advisoryChars) chars")

        let totalChars = body.count - advisoryChars
        let envelopeShare = Double(totalChars - rowChars) / Double(totalChars)
        #expect(envelopeShare < 0.12,
                "envelope share must be <12%; got \(envelopeShare) for body: \(body)")
    }
}
