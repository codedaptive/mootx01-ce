import Testing
import Foundation
@testable import mcp_benchmarker

// EstateModeRejectionTests.swift — the CLI boundary rejects the retired
// --no-plaintext-scratch flag and every other unrecognised option, instead of
// ignoring them.
//
// The defect these tests pin: both parsers located options by name and never
// looked at the tokens they did not recognise. --no-plaintext-scratch used to
// select the encrypted scratch posture; after --estate-mode replaced it, an
// invocation still carrying it fell through to the unencrypted default, wrote
// the transient-record plaintext rule, and produced a PLAINTEXT scratch estate while its
// author believed encryption had been requested.
//
// FAIL, DO NOT ALIAS. Accepting the retired name as a synonym for
// `--estate-mode encrypted` would keep it alive indefinitely; rejecting it
// makes the stored invocation get fixed once.

@Suite("CLI retired and unknown option rejection") struct EstateModeRejectionTests {

    /// Every subcommand that reaches parseEstateMode. Four, not three — the
    /// supersession lane gained --estate-mode after the retired flag was
    /// removed, so it never accepted the old name, but an operator typing it
    /// there must get the same answer as everywhere else.
    private static let estateModeSubcommands = ["longmemeval", "locomo", "lmeb", "supersession"]

    // MARK: The retired flag

    @Test("--no-plaintext-scratch is rejected, naming --estate-mode encrypted")
    func retiredFlagIsRejected() {
        for subcommand in Self.estateModeSubcommands {
            do {
                try validateOptions(subcommand: subcommand, in: ["--no-plaintext-scratch"])
                Issue.record("\(subcommand) accepted the retired --no-plaintext-scratch")
            } catch let error as MCPError {
                let text = error.description
                // The message must carry enough to act on: the dead name and
                // the replacement to type instead.
                #expect(text.contains("--no-plaintext-scratch"))
                #expect(text.contains("--estate-mode encrypted"))
            } catch {
                Issue.record("unexpected error type: \(error)")
            }
        }
    }

    @Test("the retired flag is rejected alongside otherwise-valid options")
    func retiredFlagIsRejectedInARealisticInvocation() {
        // The shape a stored script actually has: the retired flag buried in a
        // list of options that are all still current.
        let args = ["--data-dir", "/tmp/lme", "--no-plaintext-scratch",
                    "--limit", "10", "--seed", "20260725"]
        #expect(throws: MCPError.self) {
            try validateOptions(subcommand: "longmemeval", in: args)
        }
    }

    @Test("the retired flag is rejected under every subcommand, including ones that never took it")
    func retiredFlagIsRejectedEverywhere() {
        for subcommand in optionSurfaces.keys {
            #expect(throws: MCPError.self) {
                try validateOptions(subcommand: subcommand, in: ["--no-plaintext-scratch"])
            }
        }
    }

    @Test("the retired flag is not silently aliased to the encrypted posture")
    func retiredFlagIsNotAnAlias() throws {
        // The mission's explicit instruction: fail, do not alias. If the flag
        // were treated as a synonym, parseEstateMode would return
        // encryptedEphemeral for it. It must not — nothing reads the name.
        let posture = try parseEstateMode(in: ["--no-plaintext-scratch"])
        #expect(posture == .plaintextTransient)
        // …and the dispatch-level validator is what stops that posture ever
        // being reached with those arguments.
        #expect(throws: MCPError.self) {
            try validateOptions(subcommand: "longmemeval", in: ["--no-plaintext-scratch"])
        }
    }

    // MARK: Unknown options — the class the retired flag hid in

    @Test("an unrecognised option is rejected, naming it and the accepted set")
    func unknownOptionIsRejected() {
        do {
            try validateOptions(subcommand: "lmeb", in: ["--not-an-option", "7"])
            Issue.record("an unrecognised option was accepted")
        } catch let error as MCPError {
            #expect(error.description.contains("--not-an-option"))
            #expect(error.description.contains("lmeb"))
            #expect(error.description.contains("--estate-mode"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("the --name=value form is rejected — this CLI takes values as separate arguments")
    func joinedValueFormIsRejected() {
        #expect(throws: MCPError.self) {
            try validateOptions(subcommand: "longmemeval", in: ["--estate-mode=encrypted"])
        }
    }

    @Test("a misspelt option name is rejected rather than ignored")
    func misspeltOptionIsRejected() {
        #expect(throws: MCPError.self) {
            try validateOptions(subcommand: "longmemeval", in: ["--estate-mod", "encrypted"])
        }
    }

    @Test("a typo directly after a bare flag is still caught")
    func typoAfterBareFlagIsCaught() {
        // The value-skipping walk must not treat the token after a BARE flag as
        // that flag's value — supersession's --skip-dream takes none.
        #expect(throws: MCPError.self) {
            try validateOptions(subcommand: "supersession", in: ["--skip-dream", "--typo"])
        }
    }

    // MARK: Acceptance — the policy must not reject working invocations

    @Test("every declared option of every subcommand is accepted")
    func declaredOptionsAreAccepted() throws {
        for (subcommand, surface) in optionSurfaces {
            for option in surface.valued {
                try validateOptions(subcommand: subcommand, in: [option, "value"])
            }
            for flag in surface.bare {
                try validateOptions(subcommand: subcommand, in: [flag])
            }
        }
    }

    @Test("a value that starts with a dash is not read as an option")
    func dashLeadingValueIsNotAnOption() throws {
        // --seed -1 is a bad seed, not an unknown option; the count validators
        // own that complaint, not the option walker.
        try validateOptions(subcommand: "journey", in: ["--seed", "-1"])
        try validateOptions(subcommand: "longmemeval", in: ["--judge-cmd", "--flagged-judge"])
    }

    @Test("positional arguments are ignored")
    func positionalsAreIgnored() throws {
        try validateOptions(subcommand: "report", in: ["--report", "out.json", "extra"])
    }

    @Test("the real matrix-script invocations still validate")
    func officialMatrixInvocationsStillValidate() throws {
        // Taken verbatim from scripts/official-matrix-11x-only.sh, the shape the
        // published runs use. If the strict policy broke these, it would have
        // broken every recorded benchmark.
        try validateOptions(subcommand: "longmemeval",
                            in: ["--data-dir", "/d", "--variant", "s",
                                 "--mootx01-binary", "/m", "--limit", "10",
                                 "--seed", "1", "--out", "/o"])
        try validateOptions(subcommand: "locomo",
                            in: ["--data-file", "/f", "--mootx01-binary", "/m",
                                 "--limit", "10", "--seed", "1", "--out", "/o"])
        try validateOptions(subcommand: "lmeb",
                            in: ["--data-dir", "/d", "--evidence-types", "user_evidence",
                                 "--mootx01-binary", "/m", "--limit", "10",
                                 "--seed", "1", "--out", "/o"])
    }

    @Test("a subcommand with no declared surface still gets the retired-option check")
    func undeclaredSubcommandStillRejectsRetiredOptions() {
        #expect(throws: MCPError.self) {
            try validateOptions(subcommand: "not-a-subcommand", in: ["--no-plaintext-scratch"])
        }
    }

    // MARK: The default posture is unchanged — it is not what was wrong

    @Test("--estate-mode encrypted still selects encryptedEphemeral")
    func encryptedModeStillSelectsEphemeral() throws {
        let posture = try parseEstateMode(in: ["--estate-mode", "encrypted"])
        #expect(posture == .encryptedEphemeral)
    }

    @Test("omitting --estate-mode still defaults to plaintextTransient")
    func omittedModeStillDefaultsToPlaintext() throws {
        // The default is deliberately unchanged: it is not what was wrong here.
        let posture = try parseEstateMode(in: [])
        #expect(posture == .plaintextTransient)
    }

    @Test("--estate-mode still rejects a value that is neither mode")
    func invalidModeStillRejected() {
        #expect(throws: MCPError.self) {
            try parseEstateMode(in: ["--estate-mode", "plaintext"])
        }
    }

    // MARK: - RAM shape vs the artifact store

    /// A RAM estate has no file on disk, so pairing it with the artifact store
    /// would snapshot an empty scratch directory under a key that carries no
    /// shape component — and a later disk run under `require` would restore
    /// that empty artifact and report measuring nothing as a success.
    @Test("--shape ram is rejected with every cache mode that touches the store")
    func ramShapeRejectedWithArtifacts() {
        for mode in ["reuse", "require"] {
            #expect(throws: MCPError.self) {
                try validateOptions(
                    subcommand: "membench",
                    in: ["--shape", "ram", "--estate-cache", mode])
            }
        }
    }

    @Test("--shape ram is allowed when the artifact store is not in play")
    func ramShapeAllowedUncached() throws {
        try validateOptions(subcommand: "membench", in: ["--shape", "ram"])
        try validateOptions(
            subcommand: "membench",
            in: ["--shape", "ram", "--estate-cache", "off"])
    }

    @Test("--shape disk is unaffected by the guard")
    func diskShapeUnaffected() throws {
        try validateOptions(
            subcommand: "membench",
            in: ["--shape", "disk", "--estate-cache", "require"])
    }

    // MARK: - Encryption gate (2026-08-18 doctrine)

    /// Accuracy lanes reject --estate-mode encrypted at the runner level with
    /// the doctrine-mandated message: "encryption is tested only by the timing lane".
    /// The OptionSurface still declares --estate-mode (so the option validator
    /// passes), but every accuracy runner throws before doing any work.
    ///
    /// This test verifies the gate condition by confirming that parseEstateMode
    /// returns .encryptedEphemeral for "encrypted" and that the check that each
    /// runner performs would match.
    @Test("parseEstateMode returns encryptedEphemeral for the value accuracy lanes reject")
    func parseEstateModeReturnsEncryptedEphemeralForEncrypted() throws {
        let posture = try parseEstateMode(in: ["--estate-mode", "encrypted"])
        // The accuracy runners all test `posture == .encryptedEphemeral` and throw.
        // Verifying the value here pins the gate's triggering condition.
        #expect(posture == .encryptedEphemeral,
                "encryptedEphemeral is the posture the accuracy-lane gate rejects")
    }

    /// The nine accuracy-lane OptionSurfaces (post 2026-08-18 doctrine) no longer
    /// declare --run-mode. Passing it to any accuracy lane must be rejected by the
    /// option validator (the retired-option mechanism).
    @Test("--run-mode is rejected by all accuracy-lane subcommands")
    func runModeRejectedByAccuracyLanes() {
        let accuracyLanes = [
            "longmemeval", "locomo", "locomo-spec", "lme-spec",
            "membench", "membench-spec", "lmeb", "lmeb-spec", "convomem-spec",
        ]
        for subcommand in accuracyLanes {
            #expect(throws: MCPError.self,
                    "subcommand \(subcommand) must reject --run-mode") {
                try validateOptions(subcommand: subcommand, in: ["--run-mode", "any-value"])
            }
        }
    }
}
