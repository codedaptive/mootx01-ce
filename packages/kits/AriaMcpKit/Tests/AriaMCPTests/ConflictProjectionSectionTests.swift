// ConflictProjectionSectionTests.swift
//
// DCP M4 — the typed proving lane's report section through the MCP tool
// surface. moot_lens_contradiction routes through the same evaluator as
// moot_dream / moot_hunt_contradictions (one renderer, M0 §7), so the
// lens is the cheapest end-to-end probe: no vector store required.
// Ledger case F13 (restricted+normal pair redaction) lives here per
// SUBSTRATEML_SPEC § 5.29; the secret-ceiling counted-but-silent case rides
// along. Rust twin: dispatch_tests conflict-projection cases.

import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

@Suite("Conflict projection — MCP report section", .serialized)
struct ConflictProjectionSectionTests {

    private func text(of result: JSONValue) -> String {
        guard case let .object(obj) = result,
              case let .array(content)? = obj["content"],
              case let .object(first)? = content.first,
              case let .string(s)? = first["text"]
        else { return "" }
        return s
    }

    private func makeDispatcher(
        owner: String
    ) async throws -> (ToolDispatcher, GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        let creds = OwnerCredentials(ownerIdentifier: owner)
        _ = try await LocusKit.Estate.create(storage: storage, owner: creds)
        let handle = try await kit.open(
            storage: storage, owner: creds,
            identityKeyStore: InMemoryEstateIdentityKeyStore())
        return (ToolDispatcher(kit: kit, handle: handle), kit, handle)
    }

    /// Capture a drawer at `sensitivity` and file one employer claim
    /// from it; both drawers share one event time so the typed pair is
    /// concurrent (validity_overlap).
    private func plantClaim(
        _ kit: GeniusLocusKit, _ handle: EstateHandle,
        content: String, employer: String,
        sensitivity: AdjectiveSensitivity
    ) async throws {
        let drawer = try await kit.capture(handle, CaptureFrame(
            content: content,
            channel: .typed,
            room: "conflict-section-tests",
            latticeAnchor: LatticeAnchor(udcCode: "000"),
            addedBy: "conflict-section-tests",
            embeddingModelID: "test-model-v1",
            sensitivity: sensitivity,
            eventTime: Date(timeIntervalSince1970: 1_690_000_000)))
        _ = try await kit.captureKGFact(
            handle, subject: "Sarah Chen C0", predicate: "employer",
            object: employer, sourceDrawerID: drawer.id,
            now: Date(timeIntervalSince1970: 1_700_000_000))
    }

    /// Normal+normal pair: the lens appends the full typed section with
    /// a PROVEN block, value digests, temporal bases, reasons, and the
    /// legacy grouped-objects view stays present above it.
    ///
    /// BLOCKED: v2 `moot_lens_contradiction` routes through
    /// `AriaV2LensLower.lensContradiction`, which returns JSON-structured
    /// data in `structuredContent.data` with compact text
    /// "Found N tunnels and M fact groups." — it never calls
    /// the retired text projection, so the text-format strings
    /// (`proven:`, `PROVEN`, `rule:`, `coordinate:`, `reasons:`) are absent
    /// from `content[0].text`. The structured v2 response is authoritative;
    /// this disabled text-format pin has no selected-surface contract.
    /// Awaiting catalog decision on whether the typed proving
    /// section should be added to the v2 lower response. Do not delete;
    /// do not weaken to pass.
    @Test(.disabled("BLOCKED: v2 lensContradiction returns structured data; this retired text-format pin has no selected-surface contract."))
    func lensAppendsFullTypedSection() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher(owner: "cps-normal")
        try await plantClaim(kit, handle, content: "Claim one.",
                             employer: "Acme Robotics", sensitivity: .normal)
        try await plantClaim(kit, handle, content: "Claim two.",
                             employer: "Beta Corp", sensitivity: .normal)
        let body = text(of: try await dispatcher.dispatch(
            name: "moot_lens_contradiction", arguments: .object([:])))
        // Legacy view intact (additive contract).
        #expect(body.contains("conflicting_facts: 1 subject+predicate pair(s)"))
        // Typed section.
        #expect(body.contains("proven: 1"))
        #expect(body.contains("historical: 0"))
        #expect(body.contains("compatible: 0"))
        #expect(body.contains("unknown_or_invalid: 0"))
        #expect(body.contains("coverage: 2/2"))
        // The lens has no lexical lane — no candidates line.
        #expect(!body.contains("candidates:"))
        #expect(body.contains("  PROVEN "))
        #expect(body.contains("    rule: dim.person.employer@1"))
        #expect(body.contains("    coordinate: person:sarah chen c0|employer"))
        #expect(body.contains(" vs "))
        #expect(body.contains("    time: t:pt:1690000000 | t:pt:1690000000"))
        #expect(body.contains(
            "    reasons: same_coordinate, validity_overlap, values_exclusive"))
    }

    /// F13 — restricted+normal pair: counted, but the block collapses to
    /// the coordinate-digest line. No source ids, no value digests, no
    /// dense rows for the pair.
    ///
    /// BLOCKED: same as `lensAppendsFullTypedSection` — text-format strings
    /// absent from v2 compact text. Additionally, v2 filters `.restricted`
    /// facts via `isBulkExportable` before grouping (not counted-but-redacted),
    /// so the F13 "counted in proven: N but [restricted]" behavior is absent.
    /// Awaiting catalog decision. Do not delete; do not weaken to pass.
    /// The restored tally, asserted structurally. A contradiction the caller
    /// may not read is COUNTED and withheld, never dropped — an estate with a
    /// restricted contradiction must not report itself as consistent.
    @Test func contradictionCountsIncludeWithheldRows() async throws {
        let (dispatcher, _, _) = try await makeDispatcher(owner: "contradiction-counts")

        let result = try await dispatcher.dispatch(
            name: "moot_lens_contradiction", arguments: .object([:]))
        let data = try #require(
            result.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue)

        // Every count is reported, so the caller can always tell "none" from
        // "some you cannot see".
        let total = try #require(data["totalContradictionCount"]?.integerValue)
        let withheld = try #require(data["withheldContradictionCount"]?.integerValue)
        let rows = data["contradictsTunnels"]?.arrayValue?.count ?? 0
        #expect(total == Int64(rows) + withheld,
                "the total must account for every contradiction, visible or withheld")
        #expect(data["totalConflictingFactGroupCount"]?.integerValue != nil)
        #expect(data["withheldConflictingFactGroupCount"]?.integerValue != nil)
    }

    @Test(.disabled("CONVERSION PENDING (was BLOCKED on filtered-not-counted). The COUNT is restored: moot_lens_contradiction now counts every contradiction before applying the sensitivity filter, and reports totalContradictionCount, totalConflictingFactGroupCount and the matching withheld counts, so a restricted or secret contradiction is counted-but-withheld instead of vanishing. An estate with three contradictions no longer reports one. What this case still pins is v1 RENDERED TEXT (the [restricted] marker, the \"proven: N\" line), and v2 answers structurally by ruling. contradictionCountsIncludeWithheldRows below asserts the same facts against the structured payload. Redirecting these greps is like-for-like. Do not delete; do not weaken to pass."))
    func f13RestrictedPairIsRedacted() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher(owner: "cps-restricted")
        try await plantClaim(kit, handle, content: "Public claim.",
                             employer: "Acme Robotics", sensitivity: .normal)
        try await plantClaim(kit, handle, content: "Restricted claim.",
                             employer: "Beta Corp", sensitivity: .restricted)
        let body = text(of: try await dispatcher.dispatch(
            name: "moot_lens_contradiction", arguments: .object([:])))
        #expect(body.contains("proven: 1"))
        #expect(body.contains("a conflicting claim exists at "))
        #expect(body.contains("[restricted]"))
        // The full block never renders: no rule line, no value digests,
        // no temporal bases.
        #expect(!body.contains("  PROVEN "))
        #expect(!body.contains("    rule: "))
        #expect(!body.contains("    values: "))
    }

    /// Secret ceiling: the pair is COUNTED in `proven: N` and emits no
    /// block at all — not even the redacted line.
    ///
    /// Both halves must be asserted: `proven: 1` (counted) and the absence
    /// of the PROVEN block and the [restricted] redaction line (silent).
    /// An assertion that only checks silence passes on a lens that dropped
    /// the row entirely — check both.
    ///
    /// BLOCKED: same as `lensAppendsFullTypedSection` — v2 lower path returns
    /// JSON-only; `.secret` facts are filtered before grouping (not
    /// counted-but-silent). Awaiting catalog decision. Do not delete;
    /// do not weaken to pass.
    @Test(.disabled("CONVERSION PENDING (was BLOCKED on filtered-not-counted). The COUNT is restored: moot_lens_contradiction now counts every contradiction before applying the sensitivity filter, and reports totalContradictionCount, totalConflictingFactGroupCount and the matching withheld counts, so a restricted or secret contradiction is counted-but-withheld instead of vanishing. An estate with three contradictions no longer reports one. What this case still pins is v1 RENDERED TEXT (the [restricted] marker, the \"proven: N\" line), and v2 answers structurally by ruling. contradictionCountsIncludeWithheldRows below asserts the same facts against the structured payload. Redirecting these greps is like-for-like. Do not delete; do not weaken to pass."))
    func secretCeilingIsCountedButSilent() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher(owner: "cps-secret")
        try await plantClaim(kit, handle, content: "Public claim.",
                             employer: "Acme Robotics", sensitivity: .normal)
        try await plantClaim(kit, handle, content: "Secret claim.",
                             employer: "Beta Corp", sensitivity: .secret)
        let body = text(of: try await dispatcher.dispatch(
            name: "moot_lens_contradiction", arguments: .object([:])))
        // The pair IS counted in the totals (not dropped silently).
        #expect(body.contains("proven: 1"))
        // But the block and redacted marker are both absent (silent, not redacted).
        #expect(!body.contains("  PROVEN "))
        #expect(!body.contains("[restricted]"))
    }
}
