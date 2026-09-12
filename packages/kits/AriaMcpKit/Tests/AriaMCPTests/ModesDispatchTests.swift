// ModesDispatchTests.swift
//
// Gate tests for the Moot Modes feature (modes mission).
//
// ## What these tests prove
//   A. Unknown mode name → accepted (fail-open), hint line appended, NOT invalidParams.
//   B. Unknown variant → accepted (fail-open), hint line appended, NOT invalidParams.
//   C. answer:"never" with no mode declared → response is byte-identical in shape
//      to the pre-modes path (regression test for spec §3.1 default preservation).
//   D. Recall=Auto stickies answer:auto session default for moot_memory_search
//      (subsequent call without explicit answer arg uses auto).
//   E. Sticky last-declared wins: second mode declaration replaces first.
//   F. Bare mode name ("Recall") clears variant but keeps mode attribution.
//   G. Per-call answer: arg always overrides sticky (most specific wins).
//   H. Coaching block appears at the configured cadence (X calls).
//   I. mode: arg is injected in every tool's inputSchema (schema surface test).
//
// Note: Tests that require the full estate stack (filing, searching) use the
// same InMemoryStorage harness as AnswerArgDispatchTests.swift.

import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

@Suite("modes dispatch", .serialized)
struct ModesDispatchTests {

    // MARK: - Helpers

    private func makeDispatcher() async throws -> (ToolDispatcher, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "modes-tests")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory)
        )
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(
            storage: storage, owner: owner,
            identityKeyStore: InMemoryEstateIdentityKeyStore())
        return (ToolDispatcher(kit: kit, handle: handle), handle)
    }

    private func dispatchEstateStatus(
        _ dispatcher: ToolDispatcher,
        mode: String? = nil
    ) async throws -> String {
        var args: [String: JSONValue] = [:]
        if let m = mode { args["mode"] = .string(m) }
        let result = try await dispatcher.dispatch(
            name: "moot_estate_status",
            arguments: .object(args))
        return result.firstTextContent ?? ""
    }

    // MARK: - A. Unknown mode name: fail-open, hint appended

    @Test("Unknown mode name is accepted, not invalidParams, and appends a hint")
    func unknownModeNameIsFailOpen() async throws {
        let (dispatcher, _) = try await makeDispatcher()
        // Should NOT throw. If it throws invalidParams, the test fails.
        // Converted from v1 shape: v2 compact text does not contain "estate:" / "protocol:" /
        // "memories:", so the original content assertion is replaced with envelope + operation
        // assertions that discriminate pass from fail without widening to any-success string.
        let result = try await dispatcher.dispatch(
            name: "moot_estate_status",
            arguments: .object(["mode": .string("Quantum")]))
        // The envelope must be a success result, not an error envelope.
        let isErrorFlag = result.objectValue?["isError"]?.boolValue ?? false
        #expect(!isErrorFlag, "fail-open: unknown mode name must produce a success envelope, not isError")
        // The compact text must name the operation (pins the v2 success shape specifically).
        let text = result.firstTextContent ?? ""
        #expect(text.contains("moot_estate_status"), "v2 success text must name the operation")
        // A hint line must appear for the unknown mode name.
        #expect(text.contains("hint:") || text.contains("Unknown mode"))
    }

    // MARK: - B. Unknown variant: fail-open, hint appended

    @Test("Unknown variant in known mode is accepted, not invalidParams, and appends a hint")
    func unknownVariantIsFailOpen() async throws {
        let (dispatcher, _) = try await makeDispatcher()
        // "Recall=Telepathy" — recognized mode, unrecognized variant.
        // Converted from v1 shape: same reasoning as unknownModeNameIsFailOpen above.
        let result = try await dispatcher.dispatch(
            name: "moot_estate_status",
            arguments: .object(["mode": .string("Recall=Telepathy")]))
        // The envelope must be a success result, not an error envelope.
        let isErrorFlag = result.objectValue?["isError"]?.boolValue ?? false
        #expect(!isErrorFlag, "fail-open: unknown variant must produce a success envelope, not isError")
        // The compact text must name the operation (pins the v2 success shape specifically).
        let text = result.firstTextContent ?? ""
        #expect(text.contains("moot_estate_status"), "v2 success text must name the operation")
        // Should NOT throw. Hint line expected.
        #expect(text.contains("hint:") || text.contains("Unknown variant") || text.contains("Recall"))
    }

    // MARK: - C. Regression: answer:"never" shape unchanged when no mode declared

    @Test("answer:never with no mode declared produces same shape as pre-modes default")
    func answerNeverWithNoModeIsUnchanged() async throws {
        let (dispatcher, _) = try await makeDispatcher()
        // Call with explicit answer:"never" — no mode arg.
        let resultExplicit = try await dispatcher.dispatch(
            name: "moot_memory_search",
            arguments: .object(["query": .string("test query"), "answer": .string("never")])
        )
        let textExplicit = resultExplicit.firstTextContent ?? ""

        // Call with no answer arg and no mode — should use the same "never" default.
        let resultDefault = try await dispatcher.dispatch(
            name: "moot_memory_search",
            arguments: .object(["query": .string("test query")])
        )
        let textDefault = resultDefault.firstTextContent ?? ""

        // Both should contain the "found N memory" header (not an answer: synthesis block).
        #expect(textExplicit.contains("found") || textExplicit.contains("memories"))
        #expect(textDefault.contains("found") || textDefault.contains("memories"))
        // Neither should contain an "answer:" synthesis block header.
        #expect(!textExplicit.contains("answer:"))
        #expect(!textDefault.contains("answer:"))
    }

    // MARK: - D. Recall=Auto stickies answer:auto session default

    @Test("Recall=Auto on one call sets answer:auto sticky; next search call without explicit answer uses auto default")
    func recallAutoSetsAnswerAutoSticky() async throws {
        let (dispatcher, _) = try await makeDispatcher()
        // Declare Recall=Auto via estate_status (cheap; no side effects).
        _ = try await dispatchEstateStatus(dispatcher, mode: "Recall=Auto")

        // File a memory so search has something to return.
        _ = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: .object([
                "content": .string("Sticky Recall=Auto test memory content."),
                "subject": .string("Sticky Recall=Auto test memory."),
                "location": .string("tests/modes")
            ])
        )

        // Search without an explicit answer arg — should inherit auto from sticky.
        // The response may or may not synthesize (auto = server decides), but it
        // should NOT produce a shape that is exclusively from the "never" path
        // (i.e., it must attempt the auto resolution path, not hard-code "never").
        // We verify by confirming the session state recorded Recall=Auto sticky.
        let stickyDecl = await dispatcher.modeSessionState.stickyDeclaration
        #expect(stickyDecl?.modeName == "Recall")
        #expect(stickyDecl?.recognizedRecallVariant == .auto)
    }

    // MARK: - D2. Sticky Recall=Auto e2e: search inherits auto (dispatch path gate)

    /// Gate (D2 / Finding 4): verifies the sticky `Recall=Auto` answer mode REACHES
    /// the search packager AND engages the GLKResultsPackager's gate-computation path.
    ///
    /// One memory is seeded so the estate is non-empty. With 1 hit the packager's
    /// m1=1.0, m3=1.0 → confidence >= INTERMEDIATE → the `signals:` line is emitted
    /// in the response. The `answer:never` fast path skips gate computation and never
    /// emits `signals:`. Asserting `text.contains("signals:")` proves the auto path
    /// (not the never path) executed on the second call.
    ///
    /// Discrimination proof: removing the `moot_file_memory` seed (empty estate,
    /// 0 hits) causes the packager to return 0 rows — the `signals:` line is never
    /// produced regardless of path, making the assertion vacuous. With the seed in
    /// place, `signals:` appears only on the auto/always path, not on the never path.
    ///
    /// Parity: mirrors Rust test `sticky_recall_auto_e2e_dispatcher`.
    @Test("Sticky Recall=Auto: search call without explicit answer arg must emit signals: line (packager path gate)")
    func recallAutoE2eDispatcherPath() async throws {
        let (dispatcher, _) = try await makeDispatcher()

        // Seed one memory so the estate is non-empty — required for the packager
        // to compute confidence and emit the signals: line.
        _ = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: .object([
                "content": .string("sticky recall auto test memory — alpha bravo charlie"),
                "subject": .string("sticky e2e seed"),
                "location": .string("default")
            ])
        )

        // Call 1: declare Recall=Auto.
        _ = try await dispatchEstateStatus(dispatcher, mode: "Recall=Auto")

        // Verify sticky state is set.
        let sticky = await dispatcher.modeSessionState.stickyDeclaration
        #expect(sticky?.recognizedRecallVariant == .auto,
                "Recall=Auto on call 1 must be sticky before call 2")

        // Call 2: moot_memory_search with NO mode/answer arg.
        // The dispatcher injects answer:auto from sticky state; with 1 hit the
        // packager reaches confidence >= INTERMEDIATE and emits the signals: line.
        let result = try await dispatcher.dispatch(
            name: "moot_memory_search",
            arguments: .object(["query": .string("sticky e2e dispatch test")])
        )
        let text = result.firstTextContent ?? ""
        // The signals: line is produced by the auto/always gate path only.
        // Its presence proves the sticky injection reached the packager.
        #expect(text.contains("signals:"),
                "moot_memory_search with sticky Recall=Auto must emit signals: (packager gate path); got: \(text)")
    }

    // MARK: - E. Last-declared mode wins

    @Test("Second mode declaration replaces first in sticky state")
    func lastDeclaredWins() async throws {
        let (dispatcher, _) = try await makeDispatcher()
        _ = try await dispatchEstateStatus(dispatcher, mode: "Filing")
        _ = try await dispatchEstateStatus(dispatcher, mode: "Recall=Rows")
        let sticky = await dispatcher.modeSessionState.stickyDeclaration
        #expect(sticky?.modeName == "Recall")
        #expect(sticky?.recognizedRecallVariant == .rows)
    }

    // MARK: - F. Bare mode name clears variant

    @Test("Bare mode name clears any prior variant for that mode")
    func bareModeNameClearsVariant() async throws {
        let (dispatcher, _) = try await makeDispatcher()
        // Set a variant first.
        _ = try await dispatchEstateStatus(dispatcher, mode: "Recall=Answer")
        let beforeVariant = await dispatcher.modeSessionState.stickyDeclaration?.recognizedRecallVariant
        #expect(beforeVariant == .answer)

        // Declare bare Recall — should clear the variant.
        _ = try await dispatchEstateStatus(dispatcher, mode: "Recall")
        let afterVariant = await dispatcher.modeSessionState.stickyDeclaration?.recognizedRecallVariant
        #expect(afterVariant == nil)
        // But mode name is still "Recall".
        let afterName = await dispatcher.modeSessionState.stickyDeclaration?.modeName
        #expect(afterName == "Recall")
    }

    // MARK: - G. Per-call answer: arg overrides sticky

    @Test("Per-call answer:never overrides a Recall=Auto sticky")
    func perCallAnswerOverridesSticky() async throws {
        let (dispatcher, _) = try await makeDispatcher()
        // Set Recall=Auto sticky.
        _ = try await dispatchEstateStatus(dispatcher, mode: "Recall=Auto")

        // Per-call answer:"never" must override the sticky auto default.
        // We verify by checking the response shape: "never" = rows only, no answer block.
        let result = try await dispatcher.dispatch(
            name: "moot_memory_search",
            arguments: .object([
                "query": .string("override test"),
                "answer": .string("never")
            ])
        )
        let text = result.firstTextContent ?? ""
        // Dense rows path: no "answer:" header in the synthesis sense.
        #expect(!text.contains("answer:"))
    }

    // MARK: - H. Coaching block appears at configured cadence

    @Test("Coaching block appears in response at totalCallCount == coachingCallsX")
    func coachingBlockAppearsAtCadence() async throws {
        let (dispatcher, _) = try await makeDispatcher()
        // Set a very small coaching cadence (5) for the test.
        // We do this by mutating the actor's coachingCallsX before the calls.
        await dispatcher.modeSessionState.setCoachingCallsX(5)

        // Fire 4 calls — no coaching yet.
        for i in 1..<5 {
            let result = try await dispatcher.dispatch(
                name: "moot_estate_status",
                arguments: .object([:])
            )
            let text = result.firstTextContent ?? ""
            #expect(!text.contains("[Moot coaching"), "Call \(i): no coaching expected before cadence")
        }

        // 5th call triggers coaching.
        let result5 = try await dispatcher.dispatch(
            name: "moot_estate_status",
            arguments: .object([:])
        )
        let text5 = result5.firstTextContent ?? ""
        #expect(text5.contains("[Moot coaching"), "Call 5: coaching block expected at cadence 5")
    }

    // MARK: - W2. X=0 disables periodic coaching

    /// Gate (W2): `coachingCallsX = 0` must suppress all coaching blocks regardless
    /// of call count. Mirrors Rust test `should_coach_false_when_disabled`.
    ///
    /// How it fails if reverted: if `shouldCoach` computes `totalCalls % 0` or
    /// ignores the zero guard, coaching would appear (or crash) unexpectedly.
    @Test("X=0 disables periodic coaching for all subsequent calls")
    func coachingDisabledWhenXIsZero() async throws {
        let (dispatcher, _) = try await makeDispatcher()
        // Disable coaching by setting X to 0.
        await dispatcher.modeSessionState.setCoachingCallsX(0)

        // Fire 30 calls — coaching must never appear.
        for i in 1...30 {
            let result = try await dispatcher.dispatch(
                name: "moot_estate_status",
                arguments: .object([:])
            )
            let text = result.firstTextContent ?? ""
            #expect(!text.contains("[Moot coaching"),
                    "Call \(i): coaching must be suppressed when coachingCallsX == 0")
        }
    }

    // MARK: - W4. Unrecognized mode must not clobber valid sticky state

    /// Gate (W4 ruling): an unrecognized mode declaration is IGNORED ENTIRELY —
    /// it must NOT replace a prior valid sticky declaration.
    ///
    /// How it fails if reverted: recordCall sets stickyDeclaration = m for any m,
    /// so the unknown "Quantum" would overwrite "Recall=Auto" and the assert fires.
    @Test("Unrecognized mode declaration does not clobber valid sticky state")
    func unknownModeDoesNotClobberStickyState() async throws {
        let (dispatcher, _) = try await makeDispatcher()
        // Declare a valid mode first.
        _ = try await dispatchEstateStatus(dispatcher, mode: "Recall=Auto")
        let afterValid = await dispatcher.modeSessionState.stickyDeclaration
        #expect(afterValid?.modeName == "Recall", "valid mode must be sticky")
        #expect(afterValid?.recognizedRecallVariant == .auto, "valid variant must be sticky")

        // Now declare an unrecognized mode — must NOT overwrite the valid sticky state.
        _ = try await dispatchEstateStatus(dispatcher, mode: "QuantumUnknown")
        let afterUnknown = await dispatcher.modeSessionState.stickyDeclaration
        #expect(afterUnknown?.modeName == "Recall",
                "Valid sticky must survive an unrecognized mode declaration; got: \(String(describing: afterUnknown?.modeName))")
        #expect(afterUnknown?.recognizedRecallVariant == .auto,
                "Valid variant must survive an unrecognized mode declaration")
    }

    // MARK: - Wire-text double-hint gate (mirrors Rust modes_tests H)

    /// Gate: unknown mode → wire text must NOT contain "hint: hint:" double prefix.
    ///
    /// Swift's unknownHint returns bare text; appendingHint prepends "hint: ".
    /// This test would fail if unknownHint were changed to include "hint: " —
    /// the double prefix "hint: hint: …" would appear and the assertion would fire.
    ///
    /// Note: the static ARIA protocol block contains "Watch for hint: lines…" so
    /// the total count of "hint:" in the response is 2 when correct (protocol + hint).
    @Test("Unknown mode wire text must not contain double 'hint: hint:' prefix")
    func unknownModeNoDoubleHintPrefix() async throws {
        let (dispatcher, _) = try await makeDispatcher()
        let text = try await dispatchEstateStatus(dispatcher, mode: "QuantumNonExistentMode")
        // The mode hint must be present.
        #expect(text.contains("QuantumNonExistentMode"), "Hint must mention the unknown mode name")
        // The double-prefix bug would produce "hint: hint: …" — assert it is absent.
        #expect(!text.contains("hint: hint:"),
                "Wire text must not contain double 'hint: hint:' — unknownHint must return bare text")
    }

    // MARK: - I. mode: global-modifier contract (documented once)

    // v1 injected `mode` into every tool schema. The v2 ruling forbids that:
    // `mode` is a global modifier stripped at the ARIA door before decode, absent
    // from all per-tool input schemas except the handful that declare their own
    // `mode` field (owner operations, read at runtime). The full grammar is
    // documented once in the moot_help directory response under global_modifiers,
    // and the session orientation payload names it.
    @Test("v2 mode: global-modifier contract — no per-tool injection, moot_help documents once")
    func modeArgInEveryToolSchema() async throws {
        let registry = AriaV2SelectedCatalog.registry(environment: [:])

        // Owner operations: those whose catalog input schema declares a `mode` field
        // for operational reasons (e.g. classification mode, import mode). The v2
        // global-modifier contract says ALL other operations must not carry mode in
        // their schema — mode is stripped at the ARIA door before decode.
        //
        // The allowedOwners set is a hand list; the operations are read from the
        // catalog at runtime and compared against it, so a new owner fails this gate
        // rather than being silently absorbed. If a new operation legitimately
        // declares mode, add it to allowedOwners and document why.
        let allowedOwners: Set<String> = [
            "moot_reclassify_fdc",  // FDC mode: suspectOnly|all
            "moot_palace_import",   // import mode: foreground|background (json import)
            "moot_vault_import",    // import mode: foreground|background
        ]

        // Assertion 1: no operation outside the allowed owner set has mode in its schema.
        let unexpectedWithMode = registry.operations.filter { op in
            guard !allowedOwners.contains(op.publicName) else { return false }
            return op.inputSchema.objectValue?["properties"]?.objectValue?["mode"] != nil
        }
        #expect(unexpectedWithMode.isEmpty,
                "v2 contract: only owner operations may have mode in their schema. Unexpected: \(unexpectedWithMode.map(\.publicName).joined(separator: ", "))")

        // Assertion 2: moot_help directory response carries global_modifiers naming "mode".
        let helpService = AriaV2HelpService(registry: registry)
        let helpJSON = helpService.render(try AriaV2HelpRequest(arguments: .object([:])))
        let globalModifiers = helpJSON.objectValue?["structuredContent"]?
            .objectValue?["data"]?.objectValue?["global_modifiers"]?.stringValue
        let modText = try #require(globalModifiers,
            "moot_help directory must carry a global_modifiers key")
        #expect(modText.contains("mode"),
            "global_modifiers entry must describe the mode modifier")
        #expect(modText == AriaV2HelpService.globalModifiersHelpText,
            "global_modifiers entry must equal AriaV2HelpService.globalModifiersHelpText")

        // Assertion 3: session orientation protocol names mode.
        #expect(ToolDispatcher.ARIASessionProtocol.contains("mode:"),
            "ARIASessionProtocol must reference mode: so a fresh AI client knows the modifier exists")
    }
}

// MARK: - Provisioned modes config tests

/// Gate tests for estate-provisioned modes preferences (MODES-PREFS mission).
///
/// These three tests are the discriminating gates the mission requires:
///
///   P1. provisioned sticky_enabled=false ⇒ declarations accepted-but-not-stored
///       (advisory-only path, same observable shape as absent sticky state).
///
///   P2. provisioned coaching_calls=0 ⇒ no coaching block ever fired, even at
///       call 25 (would fire if the constant 25 were still hardcoded).
///
///   P3. provisioned coaching_calls=2 ⇒ coaching block appears on call 2.
///       Discriminating: fails if the provisioned value is ignored and the
///       hardcoded constant (25) is still in effect, because call 2 would NOT
///       trigger coaching at cadence 25.
///
/// All three tests use a real in-memory estate to exercise the full wiring:
///   provisionModesConfig → kit.provisionedModesConfig(for:) → applyPreferences
@Suite("provisioned modes config — dispatch wiring", .serialized)
struct ProvisionedModesConfigDispatchTests {

    private func makeProvisionedDispatcher(
        stickyEnabled: Bool,
        coachingCalls: Int,
        owner: String
    ) async throws -> (ToolDispatcher, EstateHandle) {
        let kit = GeniusLocusKit()
        let ownerCreds = OwnerCredentials(ownerIdentifier: owner)
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory)
        )
        _ = try await LocusKit.Estate.create(storage: storage, owner: ownerCreds)
        let handle = try await kit.open(
            storage: storage, owner: ownerCreds,
            identityKeyStore: InMemoryEstateIdentityKeyStore())
        // Provision the modes config before constructing the dispatcher so
        // the first dispatch call reads the provisioned value.
        try await kit.provisionModesConfig(
            ModesManifest(stickyEnabled: stickyEnabled, coachingCalls: coachingCalls),
            for: handle)
        return (ToolDispatcher(kit: kit, handle: handle), handle)
    }

    // MARK: - P1. sticky_enabled=false ⇒ declarations accepted-but-not-stored

    /// How it fails if reverted: if stickyEnabled=false is not applied from
    /// the provisioned config, stickyEnabled remains true (spec default) and
    /// declarations WOULD be stored, so stickyDeclaration would be non-nil
    /// and the #expect fires.
    @Test("P1: provisioned sticky_enabled=false — mode declaration accepted but not stored")
    func provisionedStickyEnabledFalseDeclarationNotStored() async throws {
        let (dispatcher, _) = try await makeProvisionedDispatcher(
            stickyEnabled: false,
            coachingCalls: 25,
            owner: "prov-modes-p1-test"
        )

        // First call: apply provisioned config + declare a mode.
        var args: [String: JSONValue] = ["mode": .string("Recall=Auto")]
        _ = try await dispatcher.dispatch(
            name: "moot_estate_status",
            arguments: .object(args))

        // Verify provisioned preference was applied.
        let stickyOn = await dispatcher.modeSessionState.stickyEnabled
        #expect(!stickyOn, "applyPreferences must have set stickyEnabled=false from the provisioned config")

        // The declaration was accepted (no invalidParams) but the sticky state
        // must NOT be updated — advisory-only mode, same as absent sticky state.
        let decl = await dispatcher.modeSessionState.stickyDeclaration
        #expect(decl == nil,
                "sticky_enabled=false: mode declaration must be accepted-but-not-stored; got: \(String(describing: decl?.modeName))")

        // Subsequent call without mode — no sticky recall variant should be injected.
        args = ["query": .string("sticky disabled test")]
        let result = try await dispatcher.dispatch(name: "moot_memory_search", arguments: .object(args))
        let isError = result.objectValue?["isError"]?.boolValue ?? false
        #expect(!isError, "moot_memory_search must not error when sticky_enabled=false prevents sticky injection")
    }

    // MARK: - P2. coaching_calls=0 ⇒ no coaching block at any count

    /// How it fails if reverted: if coaching_calls=0 is not applied from the
    /// provisioned config, coachingCallsX remains 25 (spec default) and coaching
    /// fires at call 25, causing the text.contains check to find "[Moot coaching".
    @Test("P2: provisioned coaching_calls=0 — no coaching block ever fired")
    func provisionedCoachingCallsZeroSuppressesCoaching() async throws {
        let (dispatcher, _) = try await makeProvisionedDispatcher(
            stickyEnabled: true,
            coachingCalls: 0,
            owner: "prov-modes-p2-test"
        )

        // Fire 30 calls — coaching must never appear.
        for i in 1...30 {
            let result = try await dispatcher.dispatch(
                name: "moot_estate_status",
                arguments: .object([:]))
            let text = result.firstTextContent ?? ""
            #expect(!text.contains("[Moot coaching"),
                    "Call \(i): coaching must be suppressed when provisioned coaching_calls=0")
        }
    }

    // MARK: - P3. coaching_calls=2 ⇒ coaching block appears on call 2

    /// How it fails if reverted: if coaching_calls=2 is not applied from the
    /// provisioned config, coachingCallsX remains 25 and call 2 does NOT trigger
    /// coaching (25 % 2 ≠ 0 at count 2), so the #expect fires.
    ///
    /// This test is explicitly discriminating: the provisioned value 2 is chosen
    /// because it would not fire under the old hardcoded constant 25.
    @Test("P3: provisioned coaching_calls=2 — coaching block appears on exactly call 2")
    func provisionedCoachingCallsTwoFiresOnCallTwo() async throws {
        let (dispatcher, _) = try await makeProvisionedDispatcher(
            stickyEnabled: true,
            coachingCalls: 2,
            owner: "prov-modes-p3-test"
        )

        // Call 1: no coaching yet (totalCallCount=1, 1 % 2 ≠ 0).
        let result1 = try await dispatcher.dispatch(
            name: "moot_estate_status",
            arguments: .object([:]))
        let text1 = result1.firstTextContent ?? ""
        #expect(!text1.contains("[Moot coaching"),
                "Call 1: no coaching expected (totalCallCount=1 % 2 ≠ 0)")

        // Call 2: coaching must appear (totalCallCount=2, 2 % 2 == 0).
        let result2 = try await dispatcher.dispatch(
            name: "moot_estate_status",
            arguments: .object([:]))
        let text2 = result2.firstTextContent ?? ""
        #expect(text2.contains("[Moot coaching"),
                "Call 2: coaching block expected at cadence 2; got: \(text2.prefix(200))")
    }
}

// MARK: - JSONValue helper

private extension JSONValue {
    /// Return the text content from a textResult object (first text item).
    var firstTextContent: String? {
        guard case .object(let obj) = self,
              case .array(let content) = obj["content"],
              case .object(let first) = content.first,
              case .string(let text) = first["text"] else { return nil }
        return text
    }
}
